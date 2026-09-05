// ABI regression test for mxra_source_set_position.
//
// Renders the same static source four times, varying only how often
// set_position is called. All four segments must come out identical -- the
// source never moves, so the call count cannot matter.
//
// It does matter if the position argument is declared as a pointer. That is
// correct on Windows x64 and wrong on AArch64, where a 3-float aggregate is
// passed by value in s0/s1/s2; a pointer declaration leaves the callee reading
// whatever those registers held, so every redundant call flings the source
// somewhere random and the segments diverge. This test once looked like an SDK
// defect on arm64 for exactly that reason -- see issue 1 in
// meta-xr-audio-known-issues.md.
//
// Note it passes on x64 either way, so run it on the device.
//
// The position is the same value in all four cases below; only the number of
// set_position calls varies. Everything else -- context, listener, source,
// input signal -- is held constant.
//
// Build and run on BOTH platforms and compare:
//
//   Windows:
//     cl /nologo /std:c++20 /EHsc /O2 /Fe:repro.exe tools\repro_redundant_setposition.cpp
//     repro.exe MetaXRAudioUnity.dll repro_win.raw
//
//   Quest (adb):
//     aarch64-linux-android29-clang++ -std=c++20 -O2 -ffp-contract=off \
//         -static-libstdc++ -o repro tools/repro_redundant_setposition.cpp -ldl
//     adb push repro libMetaXRAudioUnity.so /data/local/tmp/r/
//     adb shell "cd /data/local/tmp/r && chmod 755 repro && \
//                LD_LIBRARY_PATH=. ./repro ./libMetaXRAudioUnity.so repro_arm.raw"
//
// -ffp-contract=off matters: clang contracts a*b+c into an FMA by default on
// ARM and MSVC does not, which perturbs the test signal and produces phantom
// cross-platform differences. See the note at the end of the issues document.
//
// Then score both files identically (float32, mono, 4 segments of 4 s):
//
//   import numpy as np
//   N = 48000*4
//   x = np.fromfile('repro_win.raw', dtype='<f4').astype(float)
//   for i, label in enumerate(['once','every block','every 4th','every 16th']):
//       s = x[i*N:(i+1)*N]
//       f = np.fft.rfftfreq(len(s), 1/48000)
//       X = np.abs(np.fft.rfft(s*np.hanning(len(s))))**2
//       print(label, X[(f>=430)&(f<450)].sum()/X.sum()*100)
//
// Expected: Windows 100% in all four. arm64 100% for "once", then 80.8% /
// 73.4% / 96.0%.

#include "../external/metaxraudio/MetaXRAudioABI.hpp"

#include <cmath>
#include <cstdio>
#include <vector>

using namespace MetaXRAudio;

namespace
{
constexpr uint32_t RATE = 48000;
constexpr uint32_t BLK  = 256;
constexpr uint32_t SECS = 4;
}

int main(int argc, char** argv)
{
    std::setvbuf(stdout, nullptr, _IONBF, 0);
#if defined(_WIN32)
    const char* def = "MetaXRAudioUnity.dll";
#else
    const char* def = "./libMetaXRAudioUnity.so";
#endif
    const char* lib  = (argc > 1) ? argv[1] : def;
    const char* outp = (argc > 2) ? argv[2] : "repro.raw";

    ABI abi;
    if (!Load(abi, lib)) { std::printf("could not load %s\n", lib); return 1; }

    int32_t maj = 0, min = 0, pat = 0;
    abi.get_version(&maj, &min, &pat);
    std::printf("SDK %d.%d.%d\n\n", maj, min, pat);

    FILE* fo = std::fopen(outp, "wb");
    if (!fo) { std::printf("cannot write %s\n", outp); return 1; }

    // 0 = call set_position once before the loop; N = additionally re-call it
    // every Nth block with the identical value.
    const int modes[] = { 0, 1, 4, 16 };
    const char* labels[] = { "once, never again", "every block", "every 4th block", "every 16th block" };

    for (int m = 0; m < 4; ++m)
    {
        mxra_context_params p{};
        p.size = sizeof(p);
        p.max_num_sources = 8;
        p.sample_rate     = RATE;
        p.buffer_length   = BLK;

        mxra_context* ctx = nullptr;
        if (abi.context_create(&ctx, &p) != MXRA_SUCCESS || !ctx)
        {
            std::printf("  context creation failed\n");
            return 1;
        }

        mxra_pose listener{};
        listener.forward.z = -1.0f;
        listener.up.y      =  1.0f;
        abi.listener_set_pose(ctx, listener);

        const float pos[3] = { 2.0f, 0.0f, 0.0f };   // never changes
        abi.source_set_position(ctx, 0, mxra_vector_3f{ pos[0], pos[1], pos[2] });        // always set once up front

        const uint32_t blocks = RATE * SECS / BLK;
        std::vector<float> tone(BLK), out(BLK * 2), acc;
        acc.reserve(blocks * BLK);

        double phase = 0.0;
        const double inc = 2.0 * 3.14159265358979323846 * 440.0 / RATE;

        for (uint32_t b = 0; b < blocks; ++b)
        {
            for (uint32_t i = 0; i < BLK; ++i) { tone[i] = 0.25f * (float)std::sin(phase); phase += inc; }

            const int every = modes[m];
            if (every > 0 && (b % every) == 0)
                abi.source_set_position(ctx, 0, mxra_vector_3f{ pos[0], pos[1], pos[2] });   // redundant: identical bits

            uint32_t status = 0;
            abi.source_process(ctx, 0, &status, tone.data(), out.data(), MXRA_OUTPUT_INTERLEAVED);
            for (uint32_t i = 0; i < BLK; ++i) acc.push_back(out[i * 2]);   // left channel
        }

        std::fwrite(acc.data(), sizeof(float), acc.size(), fo);
        std::printf("  segment %d: set_position %s\n", m, labels[m]);

        abi.context_shutdown(ctx);
        abi.context_destroy(ctx);
    }

    std::fclose(fo);
    std::printf("\nwrote %s (4 segments x %u float32 samples, mono)\n", outp, RATE * SECS);
    Unload(abi);
    return 0;
}
