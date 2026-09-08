"""Stage the opaque-prop A/B probe in an isolated project outside the app."""
import argparse
from pathlib import Path
import shutil
import zipfile

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
p = argparse.ArgumentParser(__doc__)
p.add_argument("output", type=Path)
p.add_argument("--android-source", type=Path)
args = p.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
shutil.copytree(ROOT / "RetroXR/addons/godotopenxrvendors", out / "addons/godotopenxrvendors", dirs_exist_ok=True)
if args.android_source:
    build = out / "android/build"
    build.mkdir(parents=True, exist_ok=True)
    if not (build / "build.gradle").exists():
        with zipfile.ZipFile(args.android_source) as z:
            z.extractall(build)
    (out / "android/.build_version").write_text(args.android_source.parent.name)
    (build / ".gdignore").touch()
code = (ROOT / "RetroXR/Shaders/pbr_prop_unshaded.gdshader").read_text()
(out / "prop.gdshader").write_text(code)
# Isolate the opaque-pass fix; UV and normal changes are identical in both arms.
(out / "reference.gdshader").write_text(code.replace("ALBEDO = albedo * light + emission;", "ALBEDO = albedo * light + emission;\n\tALPHA = albedo_color.a;"))
shutil.copy2(HERE / "probe.gd", out / "probe.gd")
(out / "project.godot").write_text('''config_version=5
[application]
config/name="Prop Bench"
run/main_scene="res://probe.tscn"
[display]
window/size/viewport_width=1024
window/size/viewport_height=768
window/vsync/vsync_mode=0
[rendering]
renderer/rendering_method="mobile"
textures/vram_compression/import_etc2_astc=true
anti_aliasing/quality/msaa_3d=1
[xr]
openxr/enabled=false
openxr/enabled.android=true
openxr/foveation_level=0
openxr/foveation_with_subsampled_images=false
shaders/enabled=true
''')
(out / "probe.tscn").write_text('''[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://probe.gd" id="1"]
[node name="PropBench" type="Node3D"]
script = ExtResource("1")
''')
(out / "export_presets.cfg").write_text('''[preset.0]
name="QuestPropBench"
platform="Android"
export_filter="all_resources"
export_path="./prop_bench.apk"
[preset.0.options]
gradle_build/use_gradle_build=true
gradle_build/min_sdk="29"
gradle_build/target_sdk="32"
architectures/armeabi-v7a=false
architectures/arm64-v8a=true
package/unique_name="com.xenu.propbench"
package/name="Prop Bench"
package/signed=true
version/code=1
version/name="1.0"
xr_features/xr_mode=1
xr_features/enable_meta_plugin=true
screen/immersive_mode=true
''')
print(out)
