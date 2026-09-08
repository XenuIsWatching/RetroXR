# CRT fast paths: Quest 3 results, 2026-09-07

Implemented invisible-detail fast paths in the shared CRT include. No public
uniform changes; source sampling, glass, geometry and feature defaults remain as
before. The original three functions are frozen in the benchmark reference.

## Measured GPU viewport time

| TVs | Distance | Before ms | After ms | Saved ms | Saved % | Paired savings range ms | Before/after p95 ms |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.35 m | 3.038 | 3.046 | -0.008 | -0.3% | -0.229 to +0.263 | 3.214 / 3.198 |
| 1 | 1.00 m | 2.065 | 2.035 | +0.030 | +1.5% | -0.130 to +0.030 | 2.182 / 2.154 |
| 1 | 2.00 m | 1.760 | 1.749 | +0.011 | +0.6% | +0.007 to +0.127 | 1.890 / 1.859 |
| 9 | 0.35 m | 9.922 | 9.937 | -0.015 | -0.2% | -0.108 to +0.000 | 10.117 / 10.159 |
| 9 | 1.00 m | 4.026 | 3.778 | +0.248 | +6.2% | +0.030 to +0.258 | 4.260 / 3.933 |
| 9 | 2.00 m | 2.872 | 2.790 | +0.082 | +2.9% | +0.081 to +0.087 | 2.966 / 2.871 |

Each value is the median of three run medians (p95 is likewise the median of
three run p95 values). Each run has 600 measured frames after 120 settling frames;
36 runs total, 21,600 measured frames. AB/BA/AB ordering follows warming both
variants. Positive savings means faster. Raw samples are in
[quest3-timings.json](results/quest3-timings.json).

Quest 3 / Adreno 740, Godot 4.7.stable Vulkan Mobile, stereo 1680x1760 per eye,
2x MSAA, foveation off, 72 Hz confirmed in VrApi logs. The initial metadata query
reported 90 Hz before the runtime applied the request; it was **not** the measured
refresh rate. Screens used the production curved mesh and shader, a frozen
640x480 test image, and fixed head-relative layouts. At 0.35 m, some outer screens
of the nine-screen grid are clipped by the field of view. No image readbacks
ran during timing. This measures a synthetic scene, not the full game.

The best repeatable case was nine screens at 2 m: all three pairs saved
0.081–0.087 ms at the same 492 MHz GPU clock. The 1 m nine-screen case saved
0.030–0.258 ms across the pairs; the median paired saving was 0.117 ms, while
the difference between run medians was 0.248 ms. Do not interpret 6.2% as a
universal improvement. GPU clocks remained at 545 MHz except during the last
optimized 1 m run, when they fell to 492 MHz. Near views were effectively
unchanged. Single-screen results are too small/noisy for a strong benefit claim.

Runtime GPU clocks varied between 492 and 545 MHz despite the sustained-high
performance requests; battery temperature rose approximately 37–40 C. Paired
ranges are reported rather than treating all frames as independent statistical
samples. Clock transitions also affected the single-screen 2 m and nine-screen
close-up cases. The original VrApi log and captures remain in the staging
folder `C:/Users/rymcc/AppData/Local/Temp/retroxr-crt-bench`.

## Correctness

Separate RenderDoc captures were collected for both variants at nine screens /
1 m. The reference exposes detailed shader counters, but the optimized capture
omits fragment/ALU/EFU counters even after a targeted retry. Draw clocks were
available, but a single replay per variant is not a robust timing comparison;
the headline results above use the repeated uninstrumented runs. Raw counter
responses are in [reference-counters.json](results/reference-counters.json) and
[optimized-counters.json](results/optimized-counters.json). No instruction-count
speedup is claimed from these incomplete counters.

All 209 image comparisons passed with **zero differing channel values** on both
the desktop Vulkan Mobile renderer (RTX 5070 Ti) and the Quest 3 (Adreno 740).
Coverage: CRT/VHS/static/packed-screen callers, all mask modes, left/right view
offsets and explicitly selected packed stereo regions, close/distant/oblique
views, cutoff neighborhoods and disabled mask/beam strengths. The on-device
comparison uses controlled mono SubViewports; the timing scene exercises actual
OpenXR multiview. This is not a claim of exhaustive binocular visual validation.

[Quest visual results](results/quest3-visual.json). Representative PNG pairs are
in the desktop probe's `user://visual` directory. Shader import, APK export and
`git diff --check` passed. The benchmark app is separate from RetroXR.

## Larger mobile redesign

The next high-impact experiment should be a separate mobile shader, beginning
with an opaque unshaded picture and adding features one at a time. Use rounded
screen geometry for the silhouette before removing ALPHA; verify bezel and
passthrough appearance. Keep a small analytic Fresnel/reflection cue if needed,
but remove PBR clearcoat and scratch sampling from the low tier.

Replace the nine-tap minification path with a properly filtered/mipmapped source,
retaining the sharp single-tap pixel-AA path under magnification. Generate mipmaps
or a reduced-resolution source once per new source frame, shared between eyes
and TVs displaying that source. Packed screens need independent filtering to
prevent cross-screen bleed. Measure preprocessing and bandwidth as part of the
whole cost: a prepass is not automatically cheaper on a tiled mobile GPU.

Drop halation in the lowest tier, or sample a shared preblurred source rather
than running four glow taps per eye fragment. A lightweight final stage can use
one antialiased scanline harmonic and optional aperture-grille detail. Retain
tube-UV anchoring, derivative-based fades and mean brightness. Keep these
view-dependent effects in the final pass, rather than baking them at emulator
resolution. Drop convergence, grain and complex slot/shadow modes from this tier.
Smear and notch are already off by default, so removing them alone cannot explain
a default-path speedup. No larger redesign is implemented by this change, and
its gains require a fresh on-device comparison.
