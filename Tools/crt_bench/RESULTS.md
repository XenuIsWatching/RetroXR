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

## The mobile tier: Quest 3 results, 2026-09-07

The redesign the section below asked for is implemented as a SEPARATE shader,
`crt_effect_mobile.gdshader` + `crt_mobile.gdshaderinc`, installed by
`RetroTV.crt_shader()` when `QualityManager.crt_fast` is set (the mobile
renderer's default; `crt_fast` in `graphics_prefs.json` overrides it on either
platform). The full shader is untouched and still what the desktop draws.

What it keeps: tube-UV anchoring, the analytic antialiasing of mask and raster,
zero-mean mask and beam (so brightness does not drift with distance), the
brightness-dependent beam, gamma, vignette, the OSD, the aspect fit, the rounded
glass corner and a Fresnel sheen cue. The aperture grille is the same two-harmonic
series evaluated from ONE sin/cos pair, so it matches the full shader's mode 1 to
float precision. The beam is the same pixel-integrated periodic Gaussian
truncated after its second Fourier harmonic, which at the shipped sigmas
(0.18..0.35 scanlines) leaves under 0.6% of the profile out.

What it drops: halation and the CRT-character bloom (four source taps), grain
(a hash per pixel), convergence (colour derivatives), the composite notch and
chroma smear (two taps each), the fingerprint mask (a texture tap), slot and
shadow masks (drawn as the grille), and the lit PBR glass with its clearcoat.
The material is unshaded and OPAQUE: the corner is an alpha scissor rather than
a blended fade, so a screen no longer lives in the transparent pass.
(`alpha_to_coverage` was tried for a smoothed edge and rendered the picture at
half brightness on Forward+, 236 -> 120 on a white block, so the cut is a plain
step.) Minification is a 2x2 box with taps snapped to texel corners, which
covers four texels per axis for four taps where the full shader's 3x3 covers
three; both under-cover past that, and dither at more than four texels per
pixel shimmers on this tier (640-wide content beyond about 2.6 m on a Quest 3,
256-wide beyond about 6.5 m).

### Measured GPU viewport time, current -> mobile

| TVs | Distance | Current ms | Mobile ms | Saved ms | Saved % | Paired savings range ms | Current/mobile p95 ms |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 1 | 0.35 m | 2.998 | 2.239 | +0.759 | +25.3% | +0.740 to +0.759 | 3.099 / 2.361 |
| 1 | 1.00 m | 1.905 | 1.700 | +0.205 | +10.8% | +0.204 to +0.209 | 2.114 / 1.767 |
| 1 | 2.00 m | 1.667 | 1.590 | +0.077 | +4.6% | +0.071 to +0.078 | 1.873 / 1.667 |
| 9 | 0.35 m | 10.626 | 4.570 | +6.056 | +57.0% | +5.625 to +6.063 | 10.931 / 4.778 |
| 9 | 1.00 m | 4.131 | 2.503 | +1.628 | +39.4% | +1.626 to +1.630 | 4.376 / 2.583 |
| 9 | 2.00 m | 2.773 | 2.110 | +0.663 | +23.9% | +0.656 to +0.671 | 2.868 / 2.172 |

Same protocol as the table above: Quest 3, Vulkan Mobile, 1680x1760 per eye,
2x MSAA, foveation off, 72 Hz confirmed after session start, sustained-high
requests, AB/BA/AB pairs of 600 measured frames after 120 settling, 36 runs.
Raw samples: [quest3-mobile-timings.json](results/quest3-mobile-timings.json).
Every paired range is positive and narrow, so unlike the fast-path table these
are not within run-to-run variation. A first run of the same shader WITHOUT the
corner scissor (fully opaque, no discard) measured within 0.2 ms of this table
in every scenario (2.212 / 1.703 / 1.642 / 4.651 / 2.408 / 1.973 ms), so the
scissor costs nothing measurable here.

The nine-screen close case is the one that matters for a room: the eye buffer
is covered several times over by overlapping screens, and an opaque screen is
depth-rejected where a blended one is shaded in full. That is where 6 ms of a
13.9 ms frame comes back. A single screen saves 0.1 to 0.8 ms depending on how
much of the view it fills. These are synthetic-scene GPU timings, not a claim
about whole-game frame rate.

### Appearance

The current/mobile visual pass (89 cases, [mobile-visual.json](results/mobile-visual.json))
does not fail by design; it records the errors. With the default grille and the
shipped settings, the mean absolute difference over the central half of the
picture is 2.9 levels of 255 at 0.2 m, 4.7 at 0.5 m, 1.4 at 1 m and 0.3 at
2 m; the 0.5 m figure is mostly the halation the full shader spreads into dark
gaps between bright blocks. Slot and shadow mask cases read 15-17 levels because
this tier draws the grille for them. The per-pixel maxima (up to 187) are the
corner scissor against the fade and dither cells at footprints past four
texels. A render of `tv.tscn` at Quest 3 density with both shaders, on and off,
confirmed the corner, the collar and the dark glass match; the visible
differences are the missing bloom around bright areas and the missing grain.

Not covered: `screen_window`, `vcr_effect` and `tv_static` keep the full stage
on every platform, so a DS window, a VHS tape and static still cost what they
did on a Quest. The same include-swap would serve them; it was not done here.

### Where the full shader's time goes

`mode.txt` = `ablate` runs the current `crt_effect` with one feature at a time
switched off through its own uniform (each branch skips the work, exactly as
the player's slider does), then everything off, the tube stage off, and the
mobile tier. 300 measured frames after 60 settling, two rounds in opposite
order, medians of the two. Raw: [quest3-ablation.json](results/quest3-ablation.json).

| variant | 1 screen, 0.35 m | saved | 9 screens, 1 m | saved |
|---|---:|---:|---:|---:|
| full | 2.949 ms | | 3.963 ms | |
| no glow (halation + character) | 2.732 | 0.217 | 3.485 | 0.478 |
| no beam (scanlines) | 2.622 | 0.327 | 3.877 | 0.086 |
| no mask | 2.623 | 0.326 | 3.755 | 0.208 |
| no grain | 2.795 | 0.154 | 3.925 | 0.038 |
| no sheen (glass reflection 0) | 2.807 | 0.142 | 3.826 | 0.137 |
| no wear | 2.903 | 0.046 | 3.858 | 0.105 |
| all of the above off | 2.050 | 0.899 | 3.017 | 0.946 |
| crt_enabled off | 2.081 | 0.868 | 2.956 | 1.008 |
| mobile tier | 2.172 | 0.777 | 2.373 | 1.590 |

Close up, where the picture is one source tap, the beam and the mask are the
two largest items at about 0.33 ms each for a screen filling the view (the six
erf evaluations, and the four cosines plus band terms), then the glow, grain and
sheen. Minified, the glow's four extra taps are the largest single item and the
beam has mostly faded out (its early-out fires past 0.8 scanlines per pixel).
The individual savings add to more than the "all off" figure because a skipped
path also frees registers for the others.

The mobile tier beats "everything off" by 0.6 ms in the nine-screen case while
still drawing a mask and a beam: that gap is the structural cost the uniforms
cannot switch off, namely the transparent pass, the 3x3 box (nine taps against
four) and the lit clearcoat glass. Close up, its mask and beam together cost
about 0.12 ms against 0.65 ms for the full versions.

## The design brief this implemented

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
