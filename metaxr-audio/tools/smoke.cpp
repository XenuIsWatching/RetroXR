// Phase 0 gate for the Meta XR Audio SDK binding. Standalone — no Godot.
//
// Proves the reconstructed ABI in external/metaxraudio/MetaXRAudioABI.hpp is
// actually callable, by orbiting a 440 Hz sine once around the listener's head
// and writing the spatialized result to orbit.wav. If the binding is right the
// file has an audible left-right sweep with a front/back and elevation cue; if a
// signature is wrong this fails loudly at the step that is wrong rather than
// producing quiet garbage.
//
// Build (from metaxr-audio/):
//   cl /std:c++20 /EHsc /Fe:smoke.exe tools\smoke.cpp
// Run from a directory containing MetaXRAudioUnity.dll, or pass its path:
//   smoke.exe [path-to-library] [out.wav]

#include "../external/metaxraudio/MetaXRAudioABI.hpp"

#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

using namespace MetaXRAudio;

namespace
{

constexpr uint32_t kSampleRate  = 48000;
constexpr uint32_t kBlockFrames = 256;
constexpr uint32_t kMaxSources  = 8;
constexpr float    kDurationSec = 4.0f;
constexpr float    kOrbitRadius = 2.0f;
constexpr float    kToneHz      = 440.0f;

int g_step = 0;

bool Step(bool ok, const char* what, const char* detail = nullptr)
{
    std::printf("  [%d] %-46s %s", ++g_step, what, ok ? "ok" : "FAILED");
    if (detail && *detail)
        std::printf("  (%s)", detail);
    std::printf("\n");
    return ok;
}

bool Check(mxra_result r, const char* what)
{
    char detail[64] = {};
    if (r != MXRA_SUCCESS)
        std::snprintf(detail, sizeof(detail), "mxra_result=%u", static_cast<unsigned>(r));
    return Step(r == MXRA_SUCCESS, what, detail);
}

void WriteWav(const char* path, const std::vector<float>& interleaved_stereo, uint32_t rate)
{
    const uint32_t frames    = static_cast<uint32_t>(interleaved_stereo.size() / 2);
    const uint32_t data_bytes = frames * 2 * sizeof(int16_t);

    FILE* f = std::fopen(path, "wb");
    if (!f)
    {
        std::printf("  !! could not open %s for writing\n", path);
        return;
    }

    auto u32 = [&](uint32_t v) { std::fwrite(&v, 4, 1, f); };
    auto u16 = [&](uint16_t v) { std::fwrite(&v, 2, 1, f); };

    std::fwrite("RIFF", 1, 4, f);  u32(36 + data_bytes);  std::fwrite("WAVE", 1, 4, f);
    std::fwrite("fmt ", 1, 4, f);  u32(16); u16(1); u16(2);
    u32(rate); u32(rate * 2 * sizeof(int16_t)); u16(2 * sizeof(int16_t)); u16(16);
    std::fwrite("data", 1, 4, f);  u32(data_bytes);

    for (float s : interleaved_stereo)
    {
        const float clamped = s < -1.0f ? -1.0f : (s > 1.0f ? 1.0f : s);
        u16(static_cast<uint16_t>(static_cast<int16_t>(clamped * 32767.0f)));
    }
    std::fclose(f);
}

/// Mean absolute amplitude per channel, in eight equal slices of the orbit, so
/// the caller can see the pan sweep as numbers rather than trusting their ears.
void ReportEnvelope(const std::vector<float>& stereo)
{
    constexpr int kSlices = 8;
    const size_t frames = stereo.size() / 2;
    std::printf("\n  orbit envelope (mean |amplitude| per eighth turn)\n");
    std::printf("    %-10s %8s %8s   %s\n", "angle", "left", "right", "balance");
    for (int s = 0; s < kSlices; ++s)
    {
        const size_t lo = frames * s / kSlices;
        const size_t hi = frames * (s + 1) / kSlices;
        double l = 0.0, r = 0.0;
        for (size_t i = lo; i < hi; ++i)
        {
            l += std::fabs(stereo[i * 2]);
            r += std::fabs(stereo[i * 2 + 1]);
        }
        const size_t n = (hi > lo) ? (hi - lo) : 1;
        l /= n; r /= n;
        const double total = l + r;
        const double bal   = total > 1e-9 ? (r - l) / total : 0.0;
        char bar[41];
        const int pos = static_cast<int>((bal + 1.0) * 20.0);
        for (int c = 0; c < 40; ++c) bar[c] = (c == (pos < 0 ? 0 : (pos > 39 ? 39 : pos))) ? '#' : '-';
        bar[40] = '\0';
        std::printf("    %4d deg   %8.5f %8.5f   %s\n", s * 360 / kSlices, l, r, bar);
    }
    std::printf("    (L)%36s(R)\n", "");
}

} // namespace

int main(int argc, char** argv)
{
    // Unbuffered: a wrong ABI guess crashes rather than returns, and a buffered
    // stdout would lose exactly the line naming the call that died.
    std::setvbuf(stdout, nullptr, _IONBF, 0);

    const char* lib_path = (argc > 1) ? argv[1] : "MetaXRAudioUnity.dll";
    const char* out_path = (argc > 2) ? argv[2] : "orbit.wav";

    std::printf("Meta XR Audio SDK — Phase 0 ABI smoke test\n");
    std::printf("library: %s\n\n", lib_path);

    ABI abi;
    if (!Step(Load(abi, lib_path), "load library + resolve 19 mxra_* symbols"))
    {
        std::printf("\nFAILED: could not load or a symbol is missing.\n");
        return 1;
    }

    // 1. Version. Unambiguous, no structs involved — if this is wrong, nothing
    //    else is worth attempting.
    int32_t major = -1, minor = -1, patch = -1;
    const char* version_str = abi.get_version(&major, &minor, &patch);
    {
        char detail[128];
        std::snprintf(detail, sizeof(detail), "%d.%d.%d  \"%s\"",
                      major, minor, patch, version_str ? version_str : "(null)");
        if (!Step(major == 1 && minor == 117, "mxra_get_version reports 1.117.x", detail))
        {
            std::printf("\nFAILED: version mismatch — the vendored binary is not v85.\n");
            Unload(abi);
            return 1;
        }
    }

    // 2. Context. Passing params to create() also initialises it — create()
    //    forwards them straight to the same code path mxra_context_init uses.
    mxra_context_params params = {};
    params.size            = sizeof(params);
    params.max_num_sources = kMaxSources;
    params.sample_rate     = kSampleRate;
    params.buffer_length   = kBlockFrames;

    mxra_context* ctx = nullptr;
    if (!Check(abi.context_create(&ctx, &params), "mxra_context_create(+params)"))
    {
        std::printf("\nFAILED at context creation — the params struct layout is wrong.\n");
        Unload(abi);
        return 1;
    }
    if (!Step(ctx != nullptr, "context handle is non-null"))
    {
        Unload(abi);
        return 1;
    }

    uint32_t max_sources = 0;
    if (abi.context_get_max_source_count(ctx, &max_sources) == MXRA_SUCCESS)
    {
        char detail[64];
        std::snprintf(detail, sizeof(detail), "reports %u, asked for %u", max_sources, kMaxSources);
        Step(max_sources == kMaxSources, "max source count round-trips", detail);
    }

    // 3. Listener at the origin, looking down -Z the way Godot's camera does,
    //    expressed in this API's +forward convention.
    mxra_pose listener = {};
    listener.position.x = 0.0f; listener.position.y = 0.0f; listener.position.z = 0.0f;
    listener.forward.x  = 0.0f; listener.forward.y  = 0.0f; listener.forward.z  = -1.0f;
    listener.up.x       = 0.0f; listener.up.y       = 1.0f; listener.up.z       =  0.0f;
    if (!Check(abi.listener_set_pose(ctx, listener), "mxra_listener_set_pose"))
    {
        std::printf("\nFAILED: mxra_pose layout is wrong.\n");
        Unload(abi);
        return 1;
    }

    // 4. One source, placed to the right, to prove positioning is accepted before
    //    the render loop starts moving it.
    const float start_pos[3] = { kOrbitRadius, 0.0f, 0.0f };
    Check(abi.source_set_position(ctx, 0, mxra_vector_3f{ start_pos[0], start_pos[1], start_pos[2] }), "mxra_source_set_position");

    // 5. Render the orbit.
    const uint32_t total_frames = static_cast<uint32_t>(kDurationSec * kSampleRate);
    const uint32_t blocks       = total_frames / kBlockFrames;

    std::vector<float> mono(kBlockFrames, 0.0f);
    std::vector<float> block_out(kBlockFrames * 2, 0.0f);
    std::vector<float> rendered;
    rendered.reserve(static_cast<size_t>(blocks) * kBlockFrames * 2);

    double phase = 0.0;
    const double phase_step = 2.0 * 3.14159265358979323846 * kToneHz / kSampleRate;

    bool process_ok = true;
    for (uint32_t b = 0; b < blocks && process_ok; ++b)
    {
        for (uint32_t i = 0; i < kBlockFrames; ++i)
        {
            mono[i] = 0.25f * static_cast<float>(std::sin(phase));
            phase += phase_step;
        }

        // One full anticlockwise turn in the horizontal plane over the whole file,
        // starting directly to the listener's right.
        const double t     = static_cast<double>(b) / blocks;
        const double angle = t * 2.0 * 3.14159265358979323846;
        const float  pos[3] = { static_cast<float>(kOrbitRadius * std::cos(angle)),
                                0.0f,
                                static_cast<float>(kOrbitRadius * std::sin(angle)) };
        abi.source_set_position(ctx, 0, mxra_vector_3f{ pos[0], pos[1], pos[2] });

        uint32_t status = 0;
        std::fill(block_out.begin(), block_out.end(), 0.0f);
        const mxra_result r = abi.source_process(ctx, 0, &status, mono.data(),
                                                 block_out.data(), MXRA_OUTPUT_INTERLEAVED);
        if (r != MXRA_SUCCESS)
        {
            char detail[64];
            std::snprintf(detail, sizeof(detail), "block %u, mxra_result=%u", b, static_cast<unsigned>(r));
            Step(false, "mxra_source_process", detail);
            process_ok = false;
            break;
        }
        rendered.insert(rendered.end(), block_out.begin(), block_out.end());
    }

    if (process_ok)
    {
        char detail[64];
        std::snprintf(detail, sizeof(detail), "%u blocks x %u frames", blocks, kBlockFrames);
        Step(true, "mxra_source_process over the full orbit", detail);
    }
    else
    {
        std::printf("\nFAILED: the spatializer rejected our call.\n");
        abi.context_shutdown(ctx);
        abi.context_destroy(ctx);
        Unload(abi);
        return 1;
    }

    // 6. The output must actually be non-silent and must differ between channels;
    //    a correct-looking return code with a zero buffer is the failure mode this
    //    catches.
    double peak = 0.0, channel_diff = 0.0;
    for (size_t i = 0; i + 1 < rendered.size(); i += 2)
    {
        peak = std::fmax(peak, std::fmax(std::fabs(rendered[i]), std::fabs(rendered[i + 1])));
        channel_diff += std::fabs(rendered[i] - rendered[i + 1]);
    }
    channel_diff /= (rendered.size() / 2);

    {
        char detail[64];
        std::snprintf(detail, sizeof(detail), "peak %.4f", peak);
        Step(peak > 1e-4, "output is non-silent", detail);
        std::snprintf(detail, sizeof(detail), "mean |L-R| %.5f", channel_diff);
        Step(channel_diff > 1e-5, "channels differ (spatialization happened)", detail);
    }

    WriteWav(out_path, rendered, kSampleRate);
    Step(true, "wrote wav", out_path);

    ReportEnvelope(rendered);

    abi.context_shutdown(ctx);
    abi.context_destroy(ctx);
    Unload(abi);

    const bool pass = peak > 1e-4 && channel_diff > 1e-5;
    std::printf("\n%s\n", pass ? "PASS — ABI is callable and spatializing."
                               : "FAIL — calls succeeded but the output is not spatialized.");
    return pass ? 0 : 1;
}
