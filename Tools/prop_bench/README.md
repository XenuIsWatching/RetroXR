# Opaque prop shader A/B benchmark

A standalone Godot 4.7 project that measures one change in
`Shaders/pbr_prop_unshaded.gdshader`: the fragment stage no longer writes
`ALPHA`. Writing it, even as a constant 1.0, put every baked prop on Godot's
transparent pass, where `depth_draw_opaque` stops writing depth, so nothing a
prop covered was ever rejected early. Both arms are the shipped shader with
the same UV, normal and GI code; `reference.gdshader` is that file with the
`ALPHA` line put back.

The scene is a synthetic occlusion stress test, not an arcade FPS prediction:
a head-locked grid of 35 boxes, drawn as one layer and then as four layers
stacked in depth, so the second case is mostly covered geometry. Same
geometry, eye resolution, shader arithmetic and textures in both arms.

## Prepare and verify

```powershell
python Tools/prop_bench/prepare.py C:/path/to/prop-bench --android-source C:/path/to/4.7.2.stable/android_source.zip
& $godot --headless --path C:/path/to/prop-bench --editor --import --quit
& $godot --path C:/path/to/prop-bench -- --visual
& $godot --headless --path C:/path/to/prop-bench --export-debug QuestPropBench C:/path/to/prop-bench/prop_bench.apk --quit
```

The visual run renders one box through both arms and checks three things,
exiting non-zero if any fails: the two arms produce byte-identical colour, a
later transparent draw behind the fixed arm's box is rejected by the depth
test, and the same draw shows through the reference arm's box (the bug the
fix removes). A run that could not tell the arms apart would prove nothing.

## Quest measurement

```powershell
adb install -r C:/path/to/prop-bench/prop_bench.apk
adb shell am broadcast -a com.oculus.vrpowermanager.prox_close
adb shell setprop debug.oculus.guardian_pause 1
adb shell am start -n com.xenu.propbench/com.godot.game.GodotAppLauncher
adb logcat -s godot:* VrApi:I
# After [propbench] COMPLETE:
adb exec-out run-as com.xenu.propbench cat files/timings.json > timings.json
python Tools/prop_bench/summarize.py timings.json
```

`com.xenu.propbench` is separate from RetroXR. The probe asks for a 1.5x
render target multiplier (the sharpness the app keeps), 72 Hz, no foveation,
2x MSAA and sustained-high CPU/GPU levels; the eye size it actually got is in
every result line. Both arms warm up; each of three AB/BA/AB pairs then gets
120 settling frames and 600 measured frames per layer count. GPU timing is
`viewport_get_measured_render_time_gpu` over the whole viewport.
