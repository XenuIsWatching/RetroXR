#!/usr/bin/env python3
"""Build every RetroXR GDExtension for one platform, in one command.

    python Tools/build.py windows
    python Tools/build.py android --target release
    python Tools/build.py linux --only vlc-godot
    python Tools/build.py macos --target debug

Six extensions live in this workspace and each needs its OWN scons invocation.
They share one profiled `godot-cpp` static library, which this script builds once
per platform/target before linking the extensions with `build_library=no`. Each
extension also has its own `VariantDir('Temp')`, so it still builds from its own
directory — except libretro-godot, whose SConstruct is the workspace root's.

Asking for `linux` from Windows re-invokes this script inside WSL. Asking for it
from Linux just builds. (Replaces the old Tools/build_linux.sh, which did the
WSL half by hand for one extension.)

Not every extension ships everywhere — metaxr-audio is windows/android only,
and vlc-godot currently has no packaged macOS runtime. A whole-platform run
skips those with a note; naming one via --only is an error.
"""

from __future__ import annotations

import argparse
import os
import platform as host_platform
import shlex
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GODOT_CPP = REPO / "libretro-godot/godot-cpp"
GODOT_CPP_PROFILE = REPO / "Tools/godot_cpp_profile.json"

# name, directory scons runs in (relative to REPO), where the artifacts land, and
# the platforms the extension actually ships on.
# Order matters only for readability of the log; there are no interdependencies.
ALL_PLATFORMS = ("windows", "linux", "macos", "android")

# metaxr-audio wraps Meta's MetaXRAudioUnity blob, which Meta ships for win-x64 and
# android-arm64 only, and metaxr_audio.gdextension has no desktop Unix entry to
# match. Building it there would produce a library nothing ever loads. Skip it
# rather than bank a misleading OK in the results table.
EXTENSIONS = [
    ("libretro-godot", ".", "RetroXR/libretro-godot", ALL_PLATFORMS),
    ("archive-godot", "archive-godot", "RetroXR/archive-godot", ALL_PLATFORMS),
    ("verlet-rope", "verlet-rope", "RetroXR/verlet-rope", ALL_PLATFORMS),
    # A redistributable macOS libVLC runtime/plugin tree is not vendored yet. Do
    # not report a successful extension build that another Mac cannot load.
    ("vlc-godot", "vlc-godot", "RetroXR/vlc-godot", ("windows", "linux", "android")),
    ("godot-pdfium", "godot-pdfium", "RetroXR/godot-pdfium", ALL_PLATFORMS),
    ("metaxr-audio", "metaxr-audio", "RetroXR/metaxr-audio", ("windows", "android")),
]

ARCH = {
    "windows": "x86_64",
    "linux": "x86_64",
    "macos": "arm64" if host_platform.machine().lower() in ("arm64", "aarch64") else "x86_64",
    "android": "arm64",
}

TARGETS = {"debug": ["template_debug"],
           "release": ["template_release"],
           "both": ["template_debug", "template_release"]}

# Only used when scons isn't already on PATH — pip --user installs land here and
# Windows does not add that Scripts dir to PATH by default.
WINDOWS_SCONS_FALLBACKS = [
    Path(os.environ.get("APPDATA", "")) / "Python/Python314/Scripts/scons.exe",
    Path.home() / "AppData/Roaming/Python/Python314/Scripts/scons.exe",
]

DEFAULT_NDK = "C:/android/android-ndk-r27d"
DEFAULT_DISTRO = "Ubuntu"
MACOS_DEPLOYMENT_TARGET = "13.0"


def find_scons() -> str:
    found = shutil.which("scons")
    if found:
        return found
    if sys.platform == "win32":
        for p in WINDOWS_SCONS_FALLBACKS:
            if p.is_file():
                return str(p)
    sys.exit(
        "scons not found on PATH.\n"
        "  Windows: pip install --user scons\n"
        "  Linux:   pip install --user scons   (then ensure ~/.local/bin is on PATH)\n"
        "  macOS:   brew install scons"
    )


def build_env(platform: str, ndk: str) -> dict[str, str]:
    env = os.environ.copy()
    if platform != "android":
        return env
    if not Path(ndk).is_dir():
        sys.exit(f"android: NDK not found at {ndk} (pass --ndk)")
    env["ANDROID_NDK_ROOT"] = ndk
    # Deliberately EMPTY, not unset. godot-cpp prefers ANDROID_HOME when it is
    # set and then wants a full SDK; blanking it forces the NDK path instead.
    env["ANDROID_HOME"] = ""
    return env


def scons_command(platform: str, arch: str, target: str, scons: str,
                  jobs: int, extra: list[str]) -> list[str]:
    cmd = [scons, f"platform={platform}", f"arch={arch}", f"target={target}", f"-j{jobs}"]
    if platform == "android":
        cmd.append("ANDROID_HOME=")
        # Native TLS for the Quest: see Tools/scons_tools/android.py.
        cmd.append(f"custom_tools={(REPO / 'Tools/scons_tools').as_posix()}")
    if platform == "macos":
        # Keep the default reproducible instead of inheriting the build host's
        # SDK version. Extra args are appended after this, so an intentional
        # macos_deployment_target= override still wins.
        cmd.append(f"macos_deployment_target={MACOS_DEPLOYMENT_TARGET}")
    cmd += extra
    return cmd


def run_build(name: str, cwd: Path, platform: str, arch: str, target: str,
              scons: str, env: dict[str, str], jobs: int,
              extra: list[str]) -> tuple[bool, float]:
    cmd = scons_command(platform, arch, target, scons, jobs, extra)
    print(f"\n=== {name}  [{platform} {arch} {target}] ===", flush=True)
    print(f"    {cwd}$ {' '.join(cmd)}", flush=True)
    t0 = time.monotonic()
    rc = subprocess.run(cmd, cwd=cwd, env=env).returncode
    return rc == 0, time.monotonic() - t0


def run_one(name: str, subdir: str, platform: str, arch: str, target: str,
            scons: str, env: dict[str, str], jobs: int,
            extra: list[str]) -> tuple[bool, float]:
    return run_build(name, REPO / subdir, platform, arch, target,
                     scons, env, jobs, extra)


def to_wsl_path(p: Path) -> str:
    """C:\\Users\\x\\repo -> /mnt/c/Users/x/repo"""
    s = str(p).replace("\\", "/")
    if len(s) > 1 and s[1] == ":":
        return f"/mnt/{s[0].lower()}{s[2:]}"
    return s


def dispatch_to_wsl(argv: list[str], distro: str) -> int:
    """Re-run this script inside WSL.

    WSL inherits the Windows environment, so PATH arrives wrong — it contains
    spaces and Windows directories, which breaks a bare
    `export PATH="$HOME/.local/bin:$PATH"`. Reset it.

    HOME is only replaced when a better answer is actually found. On this
    machine `getent passwd "$(id -u)"` returns NOTHING even with a correct PATH,
    so the previous unconditional `export HOME="$(getent ...)"` set HOME to the
    empty string. That put Python's user site-packages at "/.local/lib/..." and
    made every pip --user install invisible, which is why scons was reported
    missing while being installed and importable. WSL's own inherited HOME was
    right all along, so it is the fallback.
    """
    if not shutil.which("wsl"):
        sys.exit("linux builds from Windows need WSL, which was not found on PATH.")
    inner = (
        '_h="$(getent passwd "$(id -u)" 2>/dev/null | cut -d: -f6)"; '
        '[ -d "$_h" ] || _h="$(eval echo ~"$(id -un)" 2>/dev/null)"; '
        '[ -d "$_h" ] && export HOME="$_h"; '
        '[ -d "$HOME" ] || { echo "cannot determine a home directory in WSL" >&2; exit 1; }; '
        'export PATH="$HOME/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"; '
        f'cd "{to_wsl_path(REPO)}" || exit 1; '
        f'exec python3 Tools/build.py {shlex.join(argv)}'
    )
    print(f"[build] host is Windows; dispatching linux build into WSL ({distro})", flush=True)
    return subprocess.run(["wsl", "-d", distro, "--", "bash", "-c", inner]).returncode


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("platform", choices=["windows", "linux", "macos", "android"])
    ap.add_argument("--target", choices=list(TARGETS), default="both",
                    help="which build target(s) to produce (default: both)")
    ap.add_argument("--arch", help="override the per-platform default")
    ap.add_argument("--only", help="comma-separated subset of: "
                                   + ", ".join(n for n, _, _, _ in EXTENSIONS))
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--ndk", default=os.environ.get("ANDROID_NDK_ROOT") or DEFAULT_NDK)
    ap.add_argument("--distro", default=DEFAULT_DISTRO, help="WSL distro for linux-from-Windows")
    ap.add_argument("scons_args", nargs="*", help="extra args passed through to scons")
    args = ap.parse_args()

    if any(arg.startswith("build_library=") for arg in args.scons_args):
        ap.error("build_library is managed by build.py")

    # linux asked for from Windows -> hand the whole thing to WSL and stop here.
    if args.platform == "linux" and sys.platform == "win32":
        passthrough: list[str] = []
        skip_next = False
        for arg in sys.argv[1:]:
            if skip_next:
                skip_next = False
                continue
            if arg == "--distro":
                skip_next = True
                continue
            if arg.startswith("--distro="):
                continue
            passthrough.append(arg)
        return dispatch_to_wsl(passthrough, args.distro)

    if args.platform == "windows" and sys.platform != "win32":
        sys.exit("windows builds need MSVC; run this from Windows.")
    if args.platform == "linux" and not sys.platform.startswith("linux"):
        sys.exit("linux builds need a Linux host (or WSL when invoked from Windows).")
    if args.platform == "macos" and sys.platform != "darwin":
        sys.exit("macos builds need a macOS host with Xcode command-line tools.")

    exts = EXTENSIONS
    if args.only:
        wanted = {s.strip() for s in args.only.split(",")}
        known = {n for n, _, _, _ in EXTENSIONS}
        if unknown := wanted - known:
            sys.exit(f"unknown extension(s): {', '.join(sorted(unknown))}")
        exts = [e for e in EXTENSIONS if e[0] in wanted]

    # An extension that doesn't ship on this platform is skipped, loudly. Asking
    # for it by name is an error instead — you meant something, and silently
    # building nothing is the wrong answer to it.
    skipped = [e for e in exts if args.platform not in e[3]]
    exts = [e for e in exts if args.platform in e[3]]
    if skipped and args.only:
        sys.exit(f"not shipped on {args.platform}: "
                 + ", ".join(f"{n} (only {'/'.join(p)})" for n, _, _, p in skipped))
    if not exts:
        sys.exit(f"nothing to build for {args.platform}")

    arch = args.arch or ARCH[args.platform]
    scons = find_scons()
    env = build_env(args.platform, args.ndk)
    profile_arg = f"build_profile={GODOT_CPP_PROFILE}"

    print(f"[build] {args.platform}/{arch}  targets={','.join(TARGETS[args.target])}  "
          f"jobs={args.jobs}\n[build] scons: {scons}")
    print(f"[build] extensions: {', '.join(n for n, _, _, _ in exts)}")
    for name, _s, _o, plats in skipped:
        print(f"[build] skipping {name} — not shipped on {args.platform} "
              f"(only {'/'.join(plats)})")

    results: list[tuple[str, str, bool, float]] = []
    for target in TARGETS[args.target]:
        # All extensions use the same godot-cpp ABI and build profile. Build its
        # static library once from a canonical working directory; otherwise six
        # independent SCons databases repeatedly compile/archive the same ~1,000
        # generated wrappers. Extension-only flags also cannot leak back into
        # this library when the later invocations use build_library=no.
        godot_cpp_args = [profile_arg]
        if (target != "template_release"
                and not any(arg.startswith("debug_symbols=") for arg in args.scons_args)):
            # Preserve the historical local-build default. CI can override this
            # with debug_symbols=no for its load-only DLLs.
            godot_cpp_args.append("debug_symbols=yes")
        godot_cpp_args += args.scons_args
        ok, secs = run_build("godot-cpp", GODOT_CPP, args.platform, arch,
                             target, scons, env, args.jobs, godot_cpp_args)
        results.append(("godot-cpp", target, ok, secs))
        if not ok:
            continue

        extension_args = [profile_arg, "build_library=no", *args.scons_args]
        for name, subdir, _out, _plats in exts:
            ok, secs = run_one(name, subdir, args.platform, arch, target,
                               scons, env, args.jobs, extension_args)
            results.append((name, target, ok, secs))

    print("\n" + "=" * 62)
    for name, target, ok, secs in results:
        print(f"  {'OK  ' if ok else 'FAIL'}  {name:<16} {target:<18} {secs:6.1f}s")
    failed = [f"{n} ({t})" for n, t, ok, _ in results if not ok]
    if failed:
        print(f"\n{len(failed)} of {len(results)} builds FAILED: {', '.join(failed)}")
        return 1
    print(f"\nall {len(results)} build steps OK -> RetroXR/")
    return 0


if __name__ == "__main__":
    sys.exit(main())
