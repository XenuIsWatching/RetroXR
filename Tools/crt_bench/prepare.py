"""Stage an isolated Godot project: python Tools/crt_bench/prepare.py OUTPUT_DIR.

The reference replaces only the three optimized functions, so both variants use
the same current callers, sampling, glass, and renderer. Never copies app state.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import zipfile

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
parser = argparse.ArgumentParser(__doc__)
parser.add_argument("output", type=Path)
parser.add_argument("--android-source", type=Path, help="Godot 4.7.stable android_source.zip; installs the isolated Gradle template")
args = parser.parse_args()
out = args.output.resolve()
out.mkdir(parents=True, exist_ok=True)
shutil.copytree(ROOT / "RetroXR/addons/godotopenxrvendors", out / "addons/godotopenxrvendors", dirs_exist_ok=True)
if args.android_source:
    android = out / "android"
    build = android / "build"
    build.mkdir(parents=True, exist_ok=True)
    if not (build / "build.gradle").exists():
        with zipfile.ZipFile(args.android_source) as archive:
            archive.extractall(build)
    (android / ".build_version").write_text("4.7.stable")
    (build / ".gdignore").touch()
shaders = out / "Shaders"
shaders.mkdir(exist_ok=True)
for p in (ROOT / "RetroXR/Shaders").glob("*.gdshader*"):
    if p.suffix != ".uid":
        shutil.copy2(p, shaders / p.name)
current = (shaders / "crt_filter.gdshaderinc").read_text()
reference = current
frozen = (HERE / "reference.gdshaderinc").read_text()
for name in ("crt_band", "crt_mask", "crt_beam"):
    pattern = r"(?:float|vec3) " + name + r"\([^\n]+\) \{.*?^\}"
    old = re.search(pattern, frozen, re.S | re.M)
    assert old, name
    reference, count = re.subn(pattern, lambda _: old.group(), reference, flags=re.S | re.M)
    assert count == 1, name
# Freeze time identically: temporal noise must not contaminate A/B image checks.
for name, code in (("crt_filter", current), ("crt_reference", reference)):
    (shaders / (name + ".gdshaderinc")).write_text(re.sub(r"\bTIME\b", "0.0", code))
for name in ("crt_effect", "screen_window", "vcr_effect", "tv_static"):
    p = shaders / (name + ".gdshader")
    code = re.sub(r"\bTIME\b", "0.0", p.read_text())
    p.write_text(code)
    (shaders / (name + "_reference.gdshader")).write_text(code.replace("crt_filter.gdshaderinc", "crt_reference.gdshaderinc"))
shutil.copy2(HERE / "probe.gd", out / "probe.gd")
shutil.copy2(ROOT / "RetroXR/Scenes/Objects/tv_models/tv_screen_curved.res", out / "screen.res")
shutil.copy2(ROOT / "RetroXR/Textures/app_icon_192.png", out / "icon.png")
(out / "project.godot").write_text('''config_version=5
[application]
config/name="CRT Bench"
config/icon="res://icon.png"
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
openxr/extensions/hand_tracking=true
shaders/enabled=true
''')
(out / "probe.tscn").write_text('''[gd_scene load_steps=2 format=3]
[ext_resource type="Script" path="res://probe.gd" id="1"]
[node name="CRTBench" type="Node3D"]
script = ExtResource("1")
''')
(out / "export_presets.cfg").write_text('''[preset.0]
name="QuestCRTBench"
platform="Android"
export_filter="all_resources"
exclude_filter=""
include_filter="*.json"
export_path="./crt_bench.apk"
[preset.0.options]
gradle_build/use_gradle_build=true
gradle_build/min_sdk="29"
gradle_build/target_sdk="32"
architectures/armeabi-v7a=false
architectures/arm64-v8a=true
package/unique_name="com.xenu.crtbench"
package/name="CRT Bench"
package/signed=true
version/code=1
version/name="1.0"
xr_features/xr_mode=1
xr_features/enable_meta_plugin=true
meta_xr_features/hand_tracking=1
screen/immersive_mode=true
''')
mobile = (shaders / "crt_mobile.gdshaderinc").read_text() + (shaders / "crt_effect_mobile.gdshader").read_text()
(out / "manifest.json").write_text(json.dumps({
    "current_sha256": hashlib.sha256(current.encode()).hexdigest(),
    "reference_sha256": hashlib.sha256(reference.encode()).hexdigest(),
    "mobile_sha256": hashlib.sha256(mobile.encode()).hexdigest(),
    "time_frozen": True,
}, indent=2))
print(out)
