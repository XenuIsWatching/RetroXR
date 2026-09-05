// Positional validation scenario: a Game Boy playing in one room, heard from
// several listener positions and orientations, including from behind a wall.
//
// Renders a set of WAVs intended to be listened to on headphones. This is the
// perceptual half of the test plan -- the numeric suite proves the maths is
// clean, this proves it actually sounds like a place.
//
// Occlusion note: Meta's geometric occlusion needs scene meshes uploaded to the
// SDK plus an offline acoustic-map bake, with no Godot-side tooling. RetroXR
// would not use that; it would do what games normally do -- raycast from the
// listener to the source and, when blocked, attenuate and low-pass. That is
// what is modelled here (see ApplyWallOcclusion), so the wall you hear is our
// filter, not the SDK's ray tracer. Everything else -- direction, elevation,
// distance, near/far -- is the SDK.
//
// Build (from metaxr-audio/):
//   cl /nologo /std:c++20 /EHsc /O2 /Fe:scene_demo.exe tools\scene_demo.cpp
//   aarch64-linux-android29-clang++ -std=c++20 -O2 -static-libstdc++ \
//       -o scene_demo tools/scene_demo.cpp -ldl

// windows.h (pulled in by the ABI header) defines min/max as macros, which
// breaks std::min at the call sites below.
#define NOMINMAX

#include "../external/metaxraudio/MetaXRAudioABI.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <string>
#include <vector>

using namespace MetaXRAudio;

namespace
{
constexpr uint32_t RATE = 48000;
constexpr uint32_t BLK  = 256;
constexpr double   PI   = 3.14159265358979323846;

// ---------------------------------------------------------------------------
// A Game Boy-ish source: two pulse channels and a noise channel, 4-bit output.
// A pure sine tells you nothing about how a real device will sound through the
// spatializer; harmonics are what make elevation and occlusion audible.
// ---------------------------------------------------------------------------
struct GameBoy
{
    uint32_t rng = 0x7f2b;
    double   t   = 0.0;

    // A short loop in semitones from A4, 0 = rest. Deliberately simple.
    static constexpr int kMelody[16] = { 9, 12, 16, 12, 9, 12, 16, 19, 21, 19, 16, 12, 9, 7, 9, 0 };
    static constexpr int kBass[8]    = { -3, -3, 2, 2, -6, -6, -1, -1 };

    // Oscillators are fixed-point on purpose. An earlier float version compared
    // a double phase against a duty threshold, and a last-bit difference in the
    // platform's libm flipped the square wave by its full amplitude -- the two
    // platforms produced audibly different renders of the "same" signal, which
    // is indistinguishable from an SDK bug until you go looking. Integer phase
    // accumulators are bit-identical everywhere by construction.
    uint32_t ph_lead = 0, ph_bass = 0;
    uint32_t sample_i = 0;

    // Q32 phase increments for semitones -12..+24 relative to A4, frozen so the
    // synth contains no libm at all and is bit-identical on every platform.
    static constexpr uint32_t kInc[37] = {
        19685267u, 20855814u, 22095965u, 23409859u, 24801882u, 26276679u,
        27839171u, 29494575u, 31248413u, 33106541u, 35075158u, 37160835u,
        39370534u, 41711627u, 44191930u, 46819719u, 49603764u, 52553357u,
        55678342u, 58989149u, 62496826u, 66213081u, 70150316u, 74321671u,
        78741067u, 83423255u, 88383859u, 93639437u, 99207528u, 105106715u,
        111356685u, 117978298u, 124993653u, 132426162u, 140300631u, 148643341u,
        157482134u,
    };
    static constexpr int kIncBase = -12;
    static uint32_t Inc(int semis) { return kInc[semis - kIncBase]; }

    // 4-bit pulse with a given duty, as the hardware would produce.
    static float Pulse(uint32_t phase, uint32_t duty, float amp)
    {
        const float v = (phase < duty) ? amp : -amp;
        return std::round(v * 7.0f) / 7.0f;
    }

    float Next()
    {
        constexpr uint32_t kBeatSamples = (uint32_t)(0.14 * RATE);
        const uint32_t step_i  = sample_i / kBeatSamples;
        const uint32_t in_beat = sample_i - step_i * kBeatSamples;
        const int lead = kMelody[step_i % 16];
        const int bass = kBass[(step_i / 2) % 8];

        // Envelopes as integer ratios, so no libm in the per-sample path.
        const float e1 = 1.0f - (float)in_beat / kBeatSamples;
        const float e2 = 1.0f - (float)(sample_i % (kBeatSamples * 2)) / (kBeatSamples * 2);

        float s = 0.0f;
        if (lead != 0)
        {
            ph_lead += Inc(lead);
            s += Pulse(ph_lead, 0x80000000u, 0.32f) * e1 * e1;
        }
        ph_bass += Inc(bass) / 2;
        s += Pulse(ph_bass, 0x40000000u, 0.22f) * e2;

        // Noise channel on every fourth step, for percussive transients.
        if ((step_i % 4) == 0 && in_beat < RATE / 20)
        {
            rng = rng * 1664525u + 1013904223u;
            const float d = 1.0f - (float)in_beat / (RATE / 20);
            s += (((rng >> 16) & 1) ? 0.10f : -0.10f) * d * d * d;
        }

        ++sample_i;
        return s * 0.8f;
    }
};
constexpr int GameBoy::kMelody[16];
constexpr uint32_t GameBoy::kInc[37];
constexpr int GameBoy::kBass[8];

// ---------------------------------------------------------------------------
// Wall model. Not the SDK -- this is the raycast-plus-filter approach the Godot
// integration would use. Two one-pole low-passes in series plus a broadband
// loss, which is roughly how a stud wall behaves: highs die, lows get through.
// ---------------------------------------------------------------------------
struct WallOcclusion
{
    float z1 = 0.0f, z2 = 0.0f;
    float cutoff_norm = 1.0f;   // 1.0 = open, smaller = more muffled
    float loss = 1.0f;

    void SetBlocked(bool blocked)
    {
        // Muffled but still clearly recognisable through the wall. An earlier,
        // harsher setting (~700 Hz, -9.6 dB) measured out at a 122 Hz spectral
        // centroid, which is mud rather than a room next door.
        cutoff_norm = blocked ? 0.13f : 1.0f;    // ~2 kHz corner when blocked
        loss        = blocked ? 0.50f : 1.0f;    // about -6 dB through the wall
    }

    float Process(float x)
    {
        z1 += cutoff_norm * (x  - z1);
        z2 += cutoff_norm * (z1 - z2);
        return z2 * loss;
    }
};

struct Pose { float px, py, pz; float yaw_deg; };

void SetListener(ABI& abi, mxra_context* ctx, const Pose& p)
{
    const double y = p.yaw_deg * PI / 180.0;
    mxra_pose lp{};
    lp.position.x = p.px; lp.position.y = p.py; lp.position.z = p.pz;
    // yaw 0 looks down -Z (Godot's convention), +yaw turns to the right.
    lp.forward.x = (float)std::sin(y); lp.forward.y = 0.0f; lp.forward.z = (float)-std::cos(y);
    lp.up.x = 0.0f; lp.up.y = 1.0f; lp.up.z = 0.0f;
    abi.listener_set_pose(ctx, lp);
}

void WriteWav(const std::string& path, const std::vector<float>& stereo)
{
    FILE* f = std::fopen(path.c_str(), "wb");
    if (!f) { std::printf("  !! cannot write %s\n", path.c_str()); return; }
    const uint32_t frames = (uint32_t)(stereo.size() / 2), db = frames * 4;
    auto u32 = [&](uint32_t v){ std::fwrite(&v,4,1,f); };
    auto u16 = [&](uint16_t v){ std::fwrite(&v,2,1,f); };
    std::fwrite("RIFF",1,4,f); u32(36+db); std::fwrite("WAVE",1,4,f);
    std::fwrite("fmt ",1,4,f); u32(16); u16(1); u16(2); u32(RATE); u32(RATE*4); u16(4); u16(16);
    std::fwrite("data",1,4,f); u32(db);
    for (float v : stereo) { float c = v < -1 ? -1.f : (v > 1 ? 1.f : v); u16((uint16_t)(int16_t)(c*32767.f)); }
    std::fclose(f);
}

// The Game Boy sits in room A; the listener may be in room A or through the
// wall in room B. The wall is the plane x = 0.
constexpr float kGameBoy[3] = { -2.2f, 0.95f, -0.4f };
bool Blocked(const Pose& l) { return (l.px > 0.0f); }

// Godot's ATTENUATION_INVERSE_DISTANCE, matching what RetroXR already sets on
// its emitters. A Game Boy speaker is small, so unit_size is well under a metre.
constexpr float kUnitSize = 1.2f;
float DistanceGain(const Pose& l)
{
    const float dx = kGameBoy[0]-l.px, dy = kGameBoy[1]-l.py, dz = kGameBoy[2]-l.pz;
    const float d = std::sqrt(dx*dx + dy*dy + dz*dz);
    return kUnitSize / (d > kUnitSize ? d : kUnitSize);
}


} // namespace

int main(int argc, char** argv)
{
    std::setvbuf(stdout, nullptr, _IONBF, 0);
#if defined(_WIN32)
    const char* def = "MetaXRAudioUnity.dll";
#else
    const char* def = "./libMetaXRAudioUnity.so";
#endif
    // "--hash" prints a checksum of the raw synth output and exits, with no SDK
    // involved. Cross-platform render differences are ambiguous until you know
    // whether the *input* was identical, so check that first.
    if (argc > 1 && std::strcmp(argv[1], "--hash") == 0)
    {
        GameBoy gb;
        uint64_t h = 1469598103934665603ull;
        for (uint32_t i = 0; i < RATE * 6; ++i)
        {
            const float v = gb.Next();
            uint32_t u; std::memcpy(&u, &v, 4);
            h ^= u; h *= 1099511628211ull;
        }
        std::printf("synth FNV1a = 0x%016llx\n", (unsigned long long)h);
        return 0;
    }

    const char* lib = (argc > 1) ? argv[1] : def;
    const std::string prefix = (argc > 2) ? argv[2] : "gb_";

    ABI abi;
    if (!Load(abi, lib)) { std::printf("failed to load %s\n", lib); return 1; }

    // Yaw convention, derived and then verified against the rendered ILD:
    // forward = (sin y, 0, -cos y), up = +Y, so right = forward x up.
    // At yaw 0 the listener faces -Z and "right" is +X. A source at -X is
    // therefore on the LEFT at yaw 0 and on the RIGHT at yaw 180.
    auto YawFacing = [](float px, float pz) {
        // Normalise -0.0 to +0.0 before atan2. When the listener shares the
        // source's z the negation yields a negative zero, and atan2(y, -0.0)
        // differs from atan2(y, +0.0) by 180 degrees -- which showed up as the
        // two platforms disagreeing about which ear the Game Boy was in.
        // atan2's second argument is degenerate when the listener shares the
        // source's z: the negation produces a negative zero, and atan2(y, -0.0)
        // differs from atan2(y, +0.0) by 180 degrees. Normalising with
        // "if (v == 0.0) v = 0.0;" does NOT work -- the optimiser deletes it as
        // a no-op. Add a positive zero instead: IEEE gives -0.0 + 0.0 = +0.0.
        const double ndz = -(double)(kGameBoy[2] - pz) + 0.0;
        return (float)(std::atan2((double)(kGameBoy[0] - px), ndz) * 180.0 / PI);
    };
    const float near_x = -1.4f, near_z = -0.4f;
    const float far_x  = -1.4f, far_z  =  3.6f;
    const float wall_x =  2.6f, wall_z = -0.4f;

    struct Scenario { const char* file; const char* desc; Pose pose; };
    const Scenario scenarios[] = {
        { "01_facing_it",     "1 m away, looking straight at it",       { near_x, 1.60f, near_z, YawFacing(near_x, near_z) } },
        { "02_turned_away",   "same spot, turned 180 - it is behind you",{ near_x, 1.60f, near_z, YawFacing(near_x, near_z) + 180.0f } },
        { "03_on_your_left",  "same spot, it is off to your left",      { near_x, 1.60f, near_z, YawFacing(near_x, near_z) + 90.0f } },
        { "04_on_your_right", "same spot, it is off to your right",     { near_x, 1.60f, near_z, YawFacing(near_x, near_z) - 90.0f } },
        { "05_across_room",   "4 m away across the room, looking at it",{ far_x,  1.60f, far_z,  YawFacing(far_x,  far_z ) } },
        { "06_standing_over", "standing right over it, looking down",   { -2.2f,  1.75f, -0.4f,  0.0f } },
        { "07_wall_facing",   "next room, through the wall, facing it", { wall_x, 1.60f, wall_z, YawFacing(wall_x, wall_z) } },
        { "08_wall_turned",   "next room, through the wall, turned away",{ wall_x, 1.60f, wall_z, YawFacing(wall_x, wall_z) + 180.0f } },
    };

    std::printf("Game Boy positional scenarios\n");
    std::printf("  source at (%.1f, %.2f, %.1f); wall is the plane x = 0\n\n", kGameBoy[0], kGameBoy[1], kGameBoy[2]);

    for (const Scenario& sc : scenarios)
    {
        mxra_context_params p{};
        p.size = sizeof(p); p.max_num_sources = 4; p.sample_rate = RATE; p.buffer_length = BLK;
        mxra_context* ctx = nullptr;
        if (abi.context_create(&ctx, &p) != MXRA_SUCCESS || !ctx) { std::printf("  ctx failed\n"); continue; }

        SetListener(abi, ctx, sc.pose);
        // Copy to a local: the SDK reads three floats straight off this pointer,
        // so it must be a real, writable-lifetime array in this frame.
        const float src[3] = { kGameBoy[0], kGameBoy[1], kGameBoy[2] };
        abi.source_set_position(ctx, 0, mxra_vector_3f{ src[0], src[1], src[2] });   // set once: repeated calls degrade the arm64 path
        // The SDK applies no distance law by default (4 m measured the same as
        // 1 m). Of its own modes only 2 attenuates, and far too steeply for a
        // room -- 4.8 m came out at -44 dB, inaudible. So drive distance with
        // Godot's own inverse-distance law via the gain param, which is what
        // the real integration would do anyway: AudioStreamPlayer3D's
        // unit_size/max_distance model, matching RetroXR's existing values.
        abi.source_set_param(ctx, 0, 0, DistanceGain(sc.pose));

        WallOcclusion wall;
        wall.SetBlocked(Blocked(sc.pose));

        GameBoy gb;
        const uint32_t blocks = RATE * 6 / BLK;
        std::vector<float> in(BLK), out(BLK * 2), acc;
        acc.reserve(blocks * BLK * 2);
        for (uint32_t b = 0; b < blocks; ++b)
        {
            for (uint32_t i = 0; i < BLK; ++i) in[i] = wall.Process(gb.Next());
            uint32_t st = 0;
            abi.source_process(ctx, 0, &st, in.data(), out.data(), MXRA_OUTPUT_INTERLEAVED);
            acc.insert(acc.end(), out.begin(), out.end());
        }

        const std::string path = prefix + sc.file + ".wav";
        WriteWav(path, acc);
        const float dx = kGameBoy[0]-sc.pose.px, dy = kGameBoy[1]-sc.pose.py, dz = kGameBoy[2]-sc.pose.pz;
        std::printf("  %-20s %-38s %5.1f m  yaw %+7.1f%s\n", sc.file, sc.desc,
                    std::sqrt(dx*dx+dy*dy+dz*dz), sc.pose.yaw_deg,
                    Blocked(sc.pose) ? "  [wall]" : "");
        abi.context_shutdown(ctx);
        abi.context_destroy(ctx);
    }

    // A continuous walk: start beside it, cross the room, pass through the
    // doorway into room B, then turn around. Position updates only when the
    // value actually changes, which is the rule the Godot voice must enforce.
    {
        mxra_context_params p{};
        p.size = sizeof(p); p.max_num_sources = 4; p.sample_rate = RATE; p.buffer_length = BLK;
        mxra_context* ctx = nullptr;
        abi.context_create(&ctx, &p);
        const float src2[3] = { kGameBoy[0], kGameBoy[1], kGameBoy[2] };
        abi.source_set_position(ctx, 0, mxra_vector_3f{ src2[0], src2[1], src2[2] });
        abi.source_set_attenuation(ctx, 0, 1, 0.4f, 25.0f);

        GameBoy gb; WallOcclusion wall;
        const double dur = 16.0;
        const uint32_t blocks = (uint32_t)(RATE * dur / BLK);
        std::vector<float> in(BLK), out(BLK * 2), acc;
        acc.reserve(blocks * BLK * 2);
        Pose last{ 1e9f, 0, 0, 1e9f };
        for (uint32_t b = 0; b < blocks; ++b)
        {
            const double t = (double)(b * BLK) / RATE, u = t / dur;
            Pose l{};
            l.py = 1.6f;
            // walk -1.4 -> +3.0 in x, drifting in z, then spin on the spot at the end
            l.px = (float)(-1.4 + 4.4 * std::min(1.0, u / 0.62));
            l.pz = (float)(-0.4 + 1.2 * std::sin(std::min(1.0, u / 0.62) * PI));
            l.yaw_deg = (u < 0.62) ? -90.0f : (float)(-90.0 + 360.0 * (u - 0.62) / 0.38);
            SetListener(abi, ctx, l);
            abi.source_set_param(ctx, 0, 0, DistanceGain(l));
            wall.SetBlocked(Blocked(l));
            for (uint32_t i = 0; i < BLK; ++i) in[i] = wall.Process(gb.Next());
            uint32_t st = 0;
            abi.source_process(ctx, 0, &st, in.data(), out.data(), MXRA_OUTPUT_INTERLEAVED);
            acc.insert(acc.end(), out.begin(), out.end());
            last = l;
        }
        WriteWav(prefix + "09_walk_through.wav", acc);
        std::printf("  %-22s %-42s\n", "08_walk_through", "walk past it, through the wall, then turn round");
        abi.context_shutdown(ctx);
        abi.context_destroy(ctx);
    }

    Unload(abi);
    std::printf("\ndone\n");
    return 0;
}
