# RenderDoc for Meta Quest — RetroXR capture

`renderdoc-oculus` (installed at `C:\Program Files\RenderDocForMetaQuest`) captures
RetroXR frames from the Quest and reports per-drawcall GPU counters.

## Capture

```bash
bash Tools/renderdoc/capture_quest.sh          # writes ./renderdoc_out/<pkg>_<ts>_frameN.rdc
FRAMES=3 BOOT_WAIT=45 bash Tools/renderdoc/capture_quest.sh
```

RetroXR's Android export is `DEBUGGABLE`, so injection uses the GPU debug-layer
path: no root, no JDWP, no reboot. `renderer/rendering_method.android="mobile"`
is Vulkan, which is the supported capture API.

## Gotchas

- **Warm the on-device remote server first.** `adb-launch*` starts
  `com.oculus.renderdoccmd.arm64/.Loader -e renderdoccmd remoteserver` and connects
  to `localabstract:renderdoc_19920`; if it is not listening yet the launch fails
  with `Failed to connect to remote server: Network I/O operation failed`. The
  script starts it and waits.
- **Read the `ident` from the launch JSON.** It is not a fixed port. Guessing
  gives `Failed to create target control for ident <n>`.
- **`adb-launch*` clears the `gpu_debug_*` globals as it tears down.** A relaunched
  app has no layer, and `@renderdoc_<ident>` disappears from `/proc/net/unix`.
  Check that socket before capturing.
- A capture is ~300 MB and lands in the working directory. Keep it out of the repo.

## Analysis

`start_drawcall_profile_session` on the `.rdc` gives PIL counters for every draw
in one O(N) pass. Godot's shaders are SPIR-V only in the capture — there is no
GLSL decompile, so attribute a draw by its render target, bound textures and
index count rather than by shader source.
