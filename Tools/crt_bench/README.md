# CRT shader A/B benchmark

This standalone Godot 4.7 project compares three variants of the tube stage:

- `reference` — the frozen pre-optimization `crt_band`, `crt_mask` and `crt_beam`
  in `reference.gdshaderinc`, spliced into a copy of the current include.
- `current` — the shipped `crt_filter.gdshaderinc`, through every caller.
- `mobile` — `crt_effect_mobile.gdshader` + `crt_mobile.gdshaderinc`, the
  unshaded opaque tier RetroTV installs on the mobile renderer. It exists for
  the `crt_effect` caller only.

A run compares one PAIR: `--pair=current,mobile` on the command line, or the
second word of `user://mode.txt` on device (`benchmark current,mobile`). The
default pair is `current,mobile`. `reference,current` is an identity check and
the visual run fails on any difference above one 8-bit level; a pair that
includes `mobile` differs by design, so that run reports per-case max/mean
errors (whole image and central half), writes every image pair, and exits 0.
The project is staged outside the checkout; no game autoloads or preferences run.

## Prepare and verify

```powershell
python Tools/crt_bench/prepare.py C:/path/to/crt-bench --android-source C:/path/to/4.7.stable/android_source.zip
& $godot --headless --path C:/path/to/crt-bench --editor --import --quit
& $godot --path C:/path/to/crt-bench -- --visual
& $godot --headless --path C:/path/to/crt-bench --export-debug QuestCRTBench C:/path/to/crt-bench/crt_bench.apk --quit
```

Use a Godot 4.7.stable editor with configured Android SDK/JDK and the repository's
installed `godotopenxrvendors` binaries. The template is extracted only on first
preparation. `--quit` is needed for unattended exports with the vendor plugin.

The visual run renders 209 original/optimized pairs: all four CRT callers, all
mask modes, close/distant/oblique views, left/right camera offsets, exact
antialiasing cutoff neighborhoods, and disabled scanline/mask strengths.
Packed stereo regions are explicitly selected for the mono comparison cameras.
It exits nonzero for differences greater than one 8-bit channel level and writes
`user://visual.json`, representative PNG pairs, and every failed image pair.
Both variants freeze shader TIME at zero, so grain/VHS/static are deterministic.

## Quest measurement

```powershell
adb install -r C:/path/to/crt-bench/crt_bench.apk
# Optional: pick the pair (default current,mobile). Under MSYS_NO_PATHCONV=1 in
# Git Bash, give adb the C:/ form of the apk path or the install fails to stat it.
echo "benchmark current,mobile" | adb shell "run-as com.xenu.crtbench sh -c 'cat > files/mode.txt'"
adb shell am start -n com.xenu.crtbench/com.godot.game.GodotAppLauncher
adb logcat -s godot:I VrApi:I '*:S'
# After [crtbench] COMPLETE:
adb exec-out run-as com.xenu.crtbench cat files/timings.json > timings.json
python Tools/crt_bench/summarize.py timings.json
```

`com.xenu.crtbench` is separate from RetroXR. Put the headset in a stable position
and keep it rendering. If using the existing repository's unattended profiling
setup, record and restore `debug.oculus.guardian_pause` and end the temporary
`com.oculus.vrpowermanager.prox_close` override afterward.

The timing run uses the real curved screen mesh with synthetic 640x480 content,
the production lit/transparent CRT material, one/nine screens, and distances of
0.35/1/2 m. Screen transforms follow the head to keep projection stable. At the
nearest nine-screen pose, outer screens are partly outside the field of view.
Both shaders warm up; each of three AB/BA/AB pairs then gets 120 settling frames
and 600 measured frames. GPU timing covers the whole application viewport, not
just the CRT draw. No image readbacks occur during timing.

Settings: Vulkan Mobile, 2x MSAA, no foveation, native recommended eye target,
72 Hz request, and sustained-high CPU/GPU performance requests. Check actual
refresh, clocks, temperature, and frame delivery in VrApi logs: OpenXR's refresh
request applies after session startup. Treat paired differences that change sign
or fall within run-to-run variation as inconclusive. These are synthetic scene
results, not a claim about whole-game performance or FPS gains.

## On-device visual checks and RenderDoc

`user://mode.txt` selects `visual`, `capture_reference`, `capture_optimized`, or
the default `benchmark`. On Android, `user://` is the app's **internal** files
directory, accessible with `adb shell run-as com.xenu.crtbench`.
Write the mode using stdin to `run-as ... sh -c 'cat > files/mode.txt'`.
Force-stop only the benchmark app, then launch it again to select visual mode.

Capture modes hold nine screens at 1 m and print `CAPTURE READY` after shader
warmup. They reread the mode file every 720 frames, allowing reference/optimized
captures from one injected session. Use `Tools/renderdoc` with
`PKG=com.xenu.crtbench`; capture after the matching ready message. Keep captures
outside the repo and use `adb-fetch-counters` for per-draw metrics. Profiling
captures are separate from normal viewport timings because injection changes
the execution environment.
