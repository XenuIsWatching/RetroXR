"""Swap RetroXR's patched Godot engine into the Android build template's AAR.

The release workflow installs Godot's stock 4.7.2 Android build template and
exports with it, so an engine patch only ships if its libgodot_android.so
replaces the stock one inside godot-lib.template_<target>.aar first. The
prebuilt library lives under Tools/engine/ (Git LFS) and is built from the
`retroxr/discardable-4.7.2` branch of the engine: 4.7.2-stable plus the three
patches in docs/godot-4.7.2-*.patch. Rebuild it whenever those change.

    python Tools/place_engine.py --target release      # CI, before --export-release
    python Tools/place_engine.py --target debug        # local Quest exports
    python Tools/place_engine.py --target debug --restore

The stock AAR is kept beside the patched one as .aar.orig; --restore puts it
back. Only arm64-v8a is replaced, which is the only ABI the Quest preset builds.
"""
import argparse, os, shutil, sys, zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ENTRY = "jni/arm64-v8a/libgodot_android.so"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--target", choices=("debug", "release"), required=True)
    ap.add_argument("--so", default=None, help="library to place; default Tools/engine/android/arm64-v8a/libgodot_android.template_<target>.so")
    ap.add_argument("--restore", action="store_true")
    a = ap.parse_args()
    aar = os.path.join(ROOT, "RetroXR", "android", "build", "libs", a.target, f"godot-lib.template_{a.target}.aar")
    bak = aar + ".orig"
    if not os.path.exists(aar):
        print(f"no build template AAR at {aar}", file=sys.stderr)
        return 1
    if a.restore:
        if not os.path.exists(bak):
            print("nothing to restore", file=sys.stderr)
            return 1
        os.replace(bak, aar)
        print("restored stock AAR", os.path.getsize(aar))
        return 0
    so = a.so or os.path.join(ROOT, "Tools", "engine", "android", "arm64-v8a", f"libgodot_android.template_{a.target}.so")
    if not os.path.exists(so) or os.path.getsize(so) < 1_000_000:
        print(f"engine library missing or an LFS pointer: {so} (run `git lfs pull`)", file=sys.stderr)
        return 1
    if not os.path.exists(bak):
        shutil.copyfile(aar, bak)
    tmp = aar + ".tmp"
    replaced = False
    with zipfile.ZipFile(bak) as zin, zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            if item.filename == ENTRY:
                zout.write(so, item.filename)
                replaced = True
            else:
                zout.writestr(item, zin.read(item.filename))
    if not replaced:
        os.remove(tmp)
        print(f"{ENTRY} not found in {aar}", file=sys.stderr)
        return 1
    os.replace(tmp, aar)
    print(f"placed {os.path.basename(so)} ({os.path.getsize(so)} bytes) into {os.path.relpath(aar, ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
