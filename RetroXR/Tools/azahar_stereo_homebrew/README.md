# azahar stereo test homebrew

A minimal 3DS homebrew that enables stereoscopic 3D and paints the **left eye
red**, the **right eye blue**, and the bottom screen green. It's the test
fixture for `Tools/azahar_probe.gd`, which boots it through the patched azahar
core with `citra_render_3d = side-by-side` and asserts the output frame's left
half ≠ right half (proving genuine per-eye rendering).

## Build (no local devkitPro needed — uses the devkitPro Docker image)

```bash
# in WSL / Linux with podman or docker:
podman pull docker.io/devkitpro/devkitarm:latest
podman run --rm -v "$PWD:/work" -w /work docker.io/devkitpro/devkitarm:latest bash /work/build.sh
# -> stereo_test.3dsx
```

`build.sh` compiles `source/main.c` against libctru and packs the ELF into a
`.3dsx` with `3dsxtool`. The `.3dsx` boots in azahar via HLE with **no console
system files** (verified — it loads through the libretro Vulkan HW path).

## Run the probe

```
godot --path RetroXR --rendering-driver opengl3 \
  res://Tools/cores/azahar_probe.tscn -- "--azahar-rom=<path>/stereo_test.3dsx"
```
Expected: `left-half avg = (1,0,0)`, `right-half avg = (0,0,1)`, `RESULT=PASS`.
Requires the patched `azahar_libretro` core (see the azahar-libretro-vr
build-fork) installed in the RetroXR cores dir.
