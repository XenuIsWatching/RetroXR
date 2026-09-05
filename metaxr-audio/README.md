# metaxr-audio

A GDExtension wrapping the **Meta XR Audio SDK** native C API, giving RetroXR
HRTF spatialisation on Quest. Sibling to `libretro-godot` and `godot-pdfium`:
same layout, reuses `../libretro-godot/godot-cpp`, deploys to
`RetroXR/metaxr-audio/`.

---

## Where the Meta library came from

Downloaded from Meta's **public npm registry**, which serves the Unity packages
and needs no login or token:

```
https://npm.developer.oculus.com/com.meta.xr.sdk.audio/-/com.meta.xr.sdk.audio-85.0.0.tgz
```

Package metadata and the version list (to check for anything newer):

```
https://npm.developer.oculus.com/com.meta.xr.sdk.audio
```

To re-fetch from scratch:

```bash
curl -sSL https://npm.developer.oculus.com/com.meta.xr.sdk.audio/-/com.meta.xr.sdk.audio-85.0.0.tgz -o mxra85.tgz
tar -xzf mxra85.tgz          # 13.6 MB
cp package/Runtime/Plugins/x86_64/MetaXRAudioUnity.dll                     external/metaxraudio/lib/win-x64/
cp package/Runtime/Plugins/Android/libs/arm64-v8a/libMetaXRAudioUnity.so   external/metaxraudio/lib/android-arm64/
cp package/LICENSE.md                                                      external/metaxraudio/
```

| vendored path | source in the package | md5 |
|---|---|---|
| `external/metaxraudio/lib/win-x64/MetaXRAudioUnity.dll` | `Runtime/Plugins/x86_64/` | `7569f2b2e04944966adccdcdc9e5155c` |
| `external/metaxraudio/lib/android-arm64/libMetaXRAudioUnity.so` | `Runtime/Plugins/Android/libs/arm64-v8a/` | `2ca91e8632d0239d7e34ce55d67a8a50` |

**Version:** package `85.0.0`, published 2026-02-10 — the latest on the registry
and, per Meta's download page, the **final** release: the SDK is on feature
freeze with no further updates planned. `mxra_get_version()` reports `1.117.0`,
which is the native library's own version and a different numbering scheme from
the package release.

**Licence:** Oculus SDK License Agreement, vendored as
`external/metaxraudio/LICENSE.md`. Note it restricts use to "MPT approved
hardware" — shipping the Windows DLL on non-Meta hardware is a judgement call.

Why the registry and not the developer site: the download button on
<https://developers.meta.com/horizon/downloads/package/meta-xr-audio-sdk/> is
JS-gated and cannot be fetched programmatically. The registry serves the same
binaries.

⚠️ This is the **Unity** plugin's binary. Meta ships three others —
Unreal (`metaxraudio64.dll`), FMOD (`MetaXRAudioFMOD.dll`) and Wwise — which are
different files and were never version-compared. They are behind the JS-gated
page, not the registry.

## No headers exist for this API

Meta publishes no header and no reference documentation for the `mxra_*` C API,
even though it is clearly the intended stable ABI: 103 undecorated symbols,
byte-identical between the Windows and Android binaries.

`external/metaxraudio/MetaXRAudioABI.hpp` is therefore **reconstructed** from the
shipped binaries:

- the Windows DLL exports MSVC-mangled C++ entry points, and MSVC mangling
  encodes full parameter types, so `undname.exe` recovers the type vocabulary
- the Android `.so` retains Itanium-mangled internals (`llvm-cxxfilt`)
- the `mxra_*` entry points were disassembled to fix arity, argument order and
  which pointers are optional
- `package/Runtime/scripts/MetaXRAudioNativeInterface.cs` is fully doxygen-
  commented and supplies concrete enum values — effectively the missing docs

`external/metaxraudio/RECOVERED_API.txt` holds the 251 recovered C++ signatures.
Everything uncertain lives in that one header, and the loader fails soft.

See `meta-xr-audio-known-issues.md` for the defects found, with confidence
levels. The headline item is the by-value vector ABI, which differs between x64 and
AArch64 and silently mis-positions every source on arm64 if you get it wrong.

## Building

Build from **this directory** — it has its own `VariantDir('Temp')`:

```bash
scons platform=windows arch=x86_64 target=template_debug dev_build=yes
scons platform=windows arch=x86_64 target=template_release
ANDROID_NDK_ROOT="C:/android/android-ndk-r27d" ANDROID_HOME="" \
  scons platform=android arch=arm64 target=template_debug ANDROID_HOME=""
```

There is no Linux target: Meta ships no Linux binary, so `is_available()`
returns false there and callers fall back to `AudioStreamPlayer3D`.

The Meta library is resolved with `dlopen`/`LoadLibraryA` at runtime, never
linked — a frozen, undocumented blob must not be able to stop the extension
loading.

## Tools

- `tools/smoke.cpp` — standalone ABI gate (no Godot). Orbits a 440 Hz sine and
  writes a wav; the check that the reconstructed ABI is actually callable.
- `tools/repro_redundant_setposition.cpp` — ABI regression test: renders the same
  static source while varying how often `mxra_source_set_position` is called. All
  segments must come out identical. They do not if the position argument is declared
  as a pointer on arm64, which is the bug this once mistook for an SDK defect.
- `tools/scene_demo.cpp` — renders positional scenarios to wav for listening.
