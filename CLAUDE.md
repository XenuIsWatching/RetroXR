# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RetroXR is a VR retro-gaming room in Godot 4.7. Its core is `libretro-godot`, a GDExtension (C++, submodule, forked from SKurdt's SK.Libretro.Godot) that runs libretro emulator cores inside Godot and bridges Godot's scene system to the libretro API.

The app is `RetroXR`, package `com.xenu.retroxr`. The Godot project folder is `RetroXR/`,
and the desktop data root stays `~/retroxr/{roms,books,videos,…}` — it holds user ROMs, so
it is deliberately not renamed.

The Godot project in this repo:
- `RetroXR/` — VR arcade room (primary development target, godot-xr-tools based)

## Git Workflow

**Commit directly to `master` unless the user says otherwise.** This is a solo repo —
do not branch-per-feature by default; commit and (when asked) push straight to `master`.
Branch only when the user explicitly requests it.

## Build Commands

Requires SCons and MSVC (Windows), GCC/Clang (Linux), Xcode command-line tools (macOS),
or Android NDK (Android). The godot-cpp submodule must be initialized first:
```bash
git submodule update --init --recursive
```

### One command for every extension

`Tools/build.py` builds all six GDExtensions for one platform. It first builds one
shared, trimmed `godot-cpp` static library for each target, then runs the extensions
sequentially with `build_library=no` (they still cannot share a scons invocation —
see below). Prefer it over the per-extension recipes further down, which are kept
because they document each build's quirks. The shared API allowlist is
`Tools/godot_cpp_profile.json`; add a Godot class there when extension C++ starts
including or calling it.

```bash
python Tools/build.py windows              # both template_debug and template_release
python Tools/build.py android --target release
python Tools/build.py linux --only vlc-godot
python Tools/build.py macos                    # host architecture, macOS 13.0 minimum
python Tools/build.py macos --arch x86_64      # Intel Mac binaries
python Tools/build.py windows --jobs 8 -- verbose=yes    # extra args go to scons
```

Asking for `linux` **from Windows** re-invokes the script inside WSL (`--distro`,
default `Ubuntu`), resetting HOME and PATH — WSL inherits the Windows environment,
whose PATH contains spaces and breaks a bare `export PATH="$HOME/.local/bin:$PATH"`.
Asking for it from Linux just builds. This replaced `Tools/build_linux.sh`.
It reports a per-extension pass/fail table and exits non-zero if anything failed.

**Not all six ship everywhere.** `metaxr-audio` is windows/android only — it wraps
Meta's `MetaXRAudioUnity` blob, which Meta publishes for win-x64 and android-arm64
alone, and `metaxr_audio.gdextension` has no Linux or macOS entry. The C++ compiles for
Linux perfectly well (the loader just finds nothing and `is_available()` returns
false), so the skip is a shipping decision, not a compile failure. A whole-platform
run skips it with a note; `--only metaxr-audio` on Linux or macOS is an error.
`vlc-godot` is also skipped on macOS because no redistributable libVLC runtime/plugin
tree is vendored yet.

**scons is not installed system-wide in either WSL distro** (`Ubuntu` has g++ but no
scons; `FedoraLinux-44` has neither on PATH). Install it into the distro first.
On the native CachyOS box there is no `pip` on PATH at all (Python 3.14, externally
managed) — `uv tool install scons` is the one that works there, and it lands in
`~/.local/bin` just the same.

Build from the **workspace root** (not `-C Temp`):
```bash
# Windows (PowerShell)
$scons = "$env:APPDATA\Python\Python314\Scripts\scons.exe"   # pip install --user scons
& $scons platform=windows arch=x86_64 target=template_debug dev_build=yes
& $scons platform=windows arch=x86_64 target=template_release

# Android / Quest (bash — requires ANDROID_NDK_ROOT)
ANDROID_NDK_ROOT="C:/android/android-ndk-r27d" ANDROID_HOME="" \
  scons platform=android arch=arm64 target=template_debug ANDROID_HOME=""

# Linux desktop x86_64 (bash — GCC/Clang; SCons via `uv tool install scons`)
scons platform=linux arch=x86_64 target=template_debug
scons platform=linux arch=x86_64 target=template_release

# macOS (build arm64 and x86_64 separately; PDFium requires macOS 13.0)
scons platform=macos arch=arm64 target=template_debug macos_deployment_target=13.0
scons platform=macos arch=x86_64 target=template_release macos_deployment_target=13.0
```

The `SConstruct` is at the workspace root; `libretro-godot/Temp/SConscript` does the
actual build logic. (`Temp` is the `VariantDir` the root `SConstruct` declares over
`libretro-godot/`; there is no `Temp/` at the workspace root, so a bare `Temp/SConscript`
path is wrong.) Output libraries go to `RetroXR/libretro-godot/`.

The Linux build links `libvulkan.so.1`, `libSDL3.so.0`, and `libGL.so.1` by soname (no
`-dev`/`-devel` packages needed). All three render paths work on Linux: software, Vulkan
HW-render, and OpenGL HW-render (SDL3-created hidden GL window — needs a display server at
runtime). Desktop Linux support was added 2026-07-13 (Windows x86_64 + Android arm64 were
the original targets).

Linux build internals worth knowing: SCons isn't system-wide here — it's `pip install
--user scons` (lands in `~/.local/bin`, so prefix commands with `PATH="$HOME/.local/bin:$PATH"`).
`CallbackTrampolines.cpp` has a dedicated `EmitTrampolineSysV` (x86-64 System V ABI:
RDI/RSI/RDX/RCX/R8/R9 + XMM0-7 + AL) — the Windows `EmitTrampolineX64` uses the wrong ABI, so
Linux/Windows/Android each need their own trampoline. GDScript platform logic used to be
"Android-vs-else(=Windows)"; several files (`core_download_manager.gd`, `download_manifest.gd`,
`spawn_menu.gd`, `rom_library.gd`) were made explicitly Linux-aware (buildbot URL
`nightly/linux/x86_64/latest/`, `.so` ext, `$HOME/retroxr/...` roots). Runtime emulation of a
real core on Linux is only lightly verified — build + extension-load + type-resolution are proven.

The macOS libretro build currently supports software-rendered cores only: Vulkan needs
MoltenVK and the OpenGL path needs a packaged SDL3 runtime. Core downloads use libretro's
`nightly/apple/osx/<arch>/latest/` dylibs, and desktop data remains under `~/retroxr`.
Both extension architectures target macOS 13.0. An official arm64 2048 core was exercised
for 168 frames in a three-second runtime probe; VLC, Meta XR Audio and a signed/notarized
macOS export preset remain future packaging work.

A hardened Mac export will need library validation disabled for downloaded unsigned cores
and unsigned executable memory for callback trampolines; dynarec cores may also need the
JIT entitlement.

### Sibling GDExtensions (archive-godot, verlet-rope, vlc-godot, godot-pdfium, metaxr-audio)

Five other C++ GDExtensions live beside libretro-godot, each with the same layout (repo-root
`<name>/` with `SConstruct` + `SConscript` + `src/`, reusing `../libretro-godot/godot-cpp`,
deploying to `RetroXR/<name>/`). Build each **from its own directory** (each has its own
`VariantDir('Temp')`), or all at once with `Tools/build.py`.

- **archive-godot** — `RommArchiveExtractor`, a bounded-memory ZIP reader used by RomM
  downloads. It streams archive members directly to temporary files, validates their sizes
  and CRCs, then promotes them into place. It is pure godot-cpp and deliberately separate
  from the libretro emulator bridge.
  ```bash
  cd archive-godot && scons platform=macos arch=arm64 target=template_debug macos_deployment_target=13.0
  ```

- **verlet-rope** — `Xenu::VerletRope`, the simulated cable hanging off every controller and
  A/V plug. Lived inside `libretro-godot` until 2026-08-02 and was moved out (and purged from
  that submodule's history) because it never belonged there: it includes nothing from libretro
  and libretro includes nothing from it. Pure godot-cpp, no third-party dependency, so it is
  one of the simplest extensions to build.
  ```bash
  cd verlet-rope && scons platform=windows arch=x86_64 target=template_debug
  cd verlet-rope && scons platform=macos arch=arm64 target=template_debug macos_deployment_target=13.0
  ```

- **vlc-godot** — libVLC-backed `VlcPlayer`, used by both the DVD player **and** the VHS/VCR
  (the old `eirteam.ffmpeg` addon was dropped 2026-07-14 — libVLC is the single video backend;
  it also handles x265/HEVC, which eirteam.ffmpeg did not).
  ```bash
  cd vlc-godot
  PATH="$HOME/.local/bin:$PATH" scons platform=linux arch=x86_64 target=template_debug
  PATH="$HOME/.local/bin:$PATH" scons platform=linux arch=x86_64 target=template_release
  ```
  Linux links the system `libvlc` (Fedora `vlc-devel` provides `/lib64/libvlc.so` + headers;
  runtime needs `vlc-libs`). HEVC works out of the box via VLC's system plugin dir — no plugin
  bundling on Linux. Output: `RetroXR/vlc-godot/libvlc_godot.linux.template_{debug,release}.x86_64.so`.

- **godot-pdfium** — `PDFRenderer` (opens a PDF, renders a page to a Godot `Image`), backed by
  the bblanchon/pdfium-binaries `libpdfium`. Every platform's prebuilt is committed, so a fresh
  clone needs no fetch; `Tools/download_pdfium.sh` refreshes them when you do (it replaced the
  PowerShell script, which only knew win-x64 + android-arm64):
  ```bash
  Tools/download_pdfium.sh -p linux     # just this platform's lib; include/ untouched
  Tools/download_pdfium.sh -p mac       # macOS arm64 (`mac-x64` for Intel)
  cd godot-pdfium
  PATH="$HOME/.local/bin:$PATH" scons platform=linux arch=x86_64 target=template_debug
  PATH="$HOME/.local/bin:$PATH" scons platform=linux arch=x86_64 target=template_release
  scons platform=macos arch=arm64 target=template_debug macos_deployment_target=13.0
  ```
  On macOS, the two runtime dylibs coexist under `mac-arm64/` and `mac-x64/`; each extension
  uses an architecture-specific `@loader_path` load command. **Linux rpath gotcha:** the
  shipped `libpdfium.so` shares its SONAME with the Android arm64 copy
  that sits in the output-dir root (tracked in git, referenced by the android `[dependencies]`
  block). An x86_64 lib with the same name would clobber it and break Quest exports, so the
  Linux lib installs to a `linux-x64/` **subdir** and the SConscript adds
  `LINKFLAGS=["-Wl,-R,'$$ORIGIN/linux-x64'"]` (quote exactly like godot-cpp's `tools/linux.py` —
  an unquoted `$$ORIGIN` collapses to a bare `/linux-x64` under this SCons). godot-cpp already
  injects a bare `$ORIGIN` entry, so final RUNPATH is `$ORIGIN:$ORIGIN/linux-x64`; the loader
  skips the arch-mismatched arm64 lib and falls through to the x86_64 subdir. Verify with
  `objdump -p …so | grep RUNPATH` and `ldd …so | grep pdfium` (must resolve, not "not found").
  Added 2026-07-15.

## Headless Testing & Validation

There is no unit-test framework in the xUnit sense, but there **is** a runner and it
gates CI. `Tools/run_tests.py` runs every `RetroXR/Tests/*.tscn` that has a `.gd` beside
it, in a stable order, and `.github/workflows/tests.yml` builds the six extensions and
runs it on every push. Beyond that the project is validated by running the Godot editor
**headless** for compile/scene checks, plus small "probe" scenes for functional tests.
All of it works without a VR headset (desktop fallback) and without a display.

```bash
python Tools/run_tests.py            # every suite
python Tools/run_tests.py --list     # name them and exit
python Tools/run_tests.py --update-baseline   # after deliberately adding cases
```

**A case count that DROPS fails the run.** `Tools/test_baseline.json` records each
suite's count, and the runner compares against it — because a suite whose group
quietly stops running still passes every case it did run and still exits 0,
which is the same blind spot as a suite nested in a subfolder. Only a drop
fails: a rise is how the suites grow, and a suite missing from the file is new
rather than broken, so adding cases never needs a second commit. A filtered run
(`--only`, or a forwarded `--only=<group>`) skips the check, since a lower count
there is the point. When a drop is deliberate, re-run with `--update-baseline`
and commit the JSON with the change that caused it.

Because the runner globs `Tests/*.tscn` **non-recursively**, `Tests/` stays flat. Do not
nest it into subfolders — a suite in a subdirectory is silently never run, which is the
one failure mode a green CI cannot show you. (`RetroXR/Tools/` is the opposite: it is
foldered by topic, see below.)

**The bar for living in `RetroXR/Tests/` is exact:** a scene that checks itself, runs
unattended with no ROM, core, headset or device, and **exits non-zero on failure**, so it
can gate a commit. The 21 suites, with their measured case counts and runtimes (Windows,
debug build, 2026-08-27 — all passing):

| suite | cases | time | covers |
|---|---|---|---|
| `netplay_tests` | 685 | 32 s | the whole lockstep stack, two NetworkManagers deep (§2f) |
| `romm_tests` | 312 | 17 s | the pure-logic half of the RomM stack |
| `binding_tests` | 176 | 12 s | which control map a platform resolves to |
| `object_sync_tests` | 127 | 8 s | the shared-room network layer, 2–3 real ENet peers |
| `scene_tests` | 120 | 10 s | SceneManager and the save gates around it |
| `poster_tests` | 112 | 11 s | the posters feature, stick/peel/conform |
| `rope_tests` | 82 | 69 s | what a cable does when it meets furniture |
| `av_tests` | 41 | 35 s | what reaches a television's inputs (§2c) |
| `system_tests` | — | — | the machine controller's port, pad, save and disc rules |
| `link_tests` | — | — | which socket each end of a link lead belongs in |
| `state_tests` | — | — | savestate capture/restore rules |
| `expansion_tests` | — | — | the expansion units and their catalog |
| `bay_tests` | — | — | cartridge bays |
| `card_tests` / `deck_tests` | — | — | memory cards; the video decks |
| `motion_tests` | — | — | accel/gyro/IR device frames |
| `screen_cast_light_tests` | — | — | light the screen throws into the room |
| `time_of_day_tests` | — | — | the day/night cycle |
| `tv_resize_tests` | — | — | the TV's own geometry |
| `web_server_tests` | — | — | the built-in file server |

Counts are what the suite printed, not a target — they drift upward as cases are added,
so re-measure rather than trusting this table, and treat an unexplained DROP as a signal.

**Everything else is a probe and lives under `RetroXR/Tools/<topic>/`**, including the
ones that assert: they want real cores and ROMs (`cores/azahar_probe`, `cores/sram_probe`,
`cores/vb_probe`, `cores/nds_probe`, `cores/handheld_probe`, `cores/gl_video_probe`), a
headset or a Quest (`netplay/netplay_spike`), or they are reproductions of open bugs and
report failures BY DESIGN (`rope/three_plug_probe`). Moving one of those into `Tests/`
would make a red run meaningless.

### Where the probes live

`RetroXR/Tools/` is foldered by topic. A probe's scene, script and `.uid` sit together,
and a scene refers to its script by literal path, so a probe moved between folders needs
its `.tscn` rewritten too.

| folder | what it holds |
|---|---|
| `av/` | TVs, tuners, phosphor, decks, spatial audio |
| `cores/` | core behaviour, BIOS boot, options, dual-screen, GL video |
| `gen/` | mesh/material generators run with `--script` (no scene); `gen/plug_materials.gd` is the shared one |
| `input/` | controllers, bindings, mice, lightguns, memory cards |
| `link/` | link cables and two-core buses (§2e, §2g) |
| `models/` | geometry authoring, shell audits, model registry, room renders |
| `netplay/` | sessions, rollback, determinism, state transfer (§2f) |
| `perf/` | Quest device probes, spawn/menu cost, VRAM census |
| `room/` | tables, spawn menus, furniture placement |
| `rope/` | cables — the bit-exact oracles `rope/rope_bench` and `rope/rope_stress` |
| `state/` | save/restore, persistence, scene soak |
| `vr/` | grabs, pokes, pointers, sliders, capsense |

Three data directories sit beside them and are deliberately not foldered by topic:
`gblink/` (the ROMs `Tools/gen_gblink_rom.py` writes), `scan/` and
`azahar_stereo_homebrew/`.

`RetroXR/Tests/rope_tests.tscn` is the behaviour half of the rope's cover. Two kinds of
case: where a cord LIES (contact/ — table, over a corner to a floor socket, round a pipe,
on a ledge, heaped, bridging a gap; loose/ — a whole lead dropped flat, across an edge,
from height) and what a player DOES to one (handling/ — a real lead's plug yanked at
5 m/s, towed 2.5 m across the floor, pulled out through a 100 mm slot, carried over a
partition, a cord wrapped round a post and hauled tight), plus inextensibility,
determinism, anchor pinning, teleport re-lay, `set_rope_length` and sleep/wake. 82 cases,
~70 s, no GPU. It complements rather than replaces the two BIT-EXACT oracles in `Tools/`
(`rope_bench --settle` prints `still_awake=12`, `rope_stress` diffs a 22-row table): those
catch arithmetic drift, this catches a cord that jitters, tunnels or will not settle.
(The bench printed 15 until 2026-08-17: DepenetrateLay freed wedged lays and three more
bench ropes settle; the stress rows that moved are the two impossible lays. Re-baselined
deliberately — an UNINTENDED move in these numbers is still a stop-everything signal.)
Two defects this suite caught and got fixed the same day: `AlignAnchorPlug` used to apply
uncapped rotation steps about the cable anchor, a per-tick transform teleport that carried
a dropped lead's plug through a 100 mm floor (now capped at MAX_ALIGN_STEP); and a cord
laid straight through furniture — every restore/teleport re-lay can do this — left
particles wedged inside it for ever (now freed by `DepenetrateLay` on the first tick after
a lay). `Tools/rope/rope_video_probe.tscn` renders the same cases to PNG frames (windowed, not
`--headless`) for when a case has to be WATCHED — most of the traps below were caught on
its footage, not by an assertion.
```bash
"$godot" --headless --path RetroXR res://Tests/rope_tests.tscn
"$godot" --headless --path RetroXR res://Tests/rope_tests.tscn -- --only=contact
```
Four traps it already hit. **Measuring jitter after a rope sleeps measures nothing** —
`step()` on a sleeping rope is a no-op, so the answer is a confident 0.000 mm however
badly it chattered; the cases hold the cord awake with `wake()` and measure the tail
window of the hold (the first wakes just finish a slump sleep froze mid-way). **A rope
built with `VerletRope.new()` takes the C++ defaults**, which are softer than anything
that ships — these mirror `cable.tscn` (8 iterations, `collision_radius` 0.0045,
self-collision on) or every threshold describes a cord the room does not contain.
**Never initialise a cord in a state no hand can produce**: a straight lay from a
table-top socket to a floor socket passes through the slab and wedges particles 11 mm
inside it (a particle born inside a solid has no contact plane), and a lay pre-compressed
between close sockets buckles into a 318 mm standing arch and sleeps there — the cases
lay the cord clear and `_carry()` the end to its socket the way a hand does. And **a
long free-hanging span cannot be held awake at all**: `wake()` every tick feeds the edge
contact's chatter into the span's pendulum mode and pumps a 0.4 m swing the room cannot
reach, because the sleep system cuts that loop off — the corner case asserts what the
room actually does (brushed awake once, asleep again in 30 ticks, 8 mm of drift).
Everything else measures 0.0003–0.07 mm/tick held awake, heaps included.

`RetroXR/Tests/romm_tests.tscn` asserts the pure-logic half of the RomM stack — pair-QR
parsing, slug mapping and systemid collision, the sync fingerprint, cache path safety,
and the `scan_roms` disk walk. 312 cases, ~17 s, no server, no headset, no network.
```bash
"$godot" --headless --path RetroXR res://Tests/romm_tests.tscn 2>&1 | grep -a "\[test\]"
```
Every case in it is a bug that actually shipped, so it doubles as the regression record —
add to it when you fix something in that layer rather than starting a new probe. It uses a
scratch `__romm_selftest` system folder under the real roms root (the path is derived from
the systemid and cannot be pointed elsewhere) and removes it at both ends.

`RetroXR/Tests/scene_tests.tscn` covers SceneManager and the save gates around it — which
rooms keep slots, the per-room active slot and its prefs round-trip (including the legacy
single-room key), the `is_room_ready` / `is_scene_content_ready` boundaries, the transition
state machine's coalescing, the periodic autosave, clearing and reloading the room you are
standing in, two restores racing into one room, a machine's core outliving its machine, the room's own
movable furniture, the video decks' teardown contract, and slot-manifest CRUD.
120 cases, ~10 s.
```bash
"$godot" --headless --path RetroXR res://Tests/scene_tests.tscn
"$godot" --headless --path RetroXR res://Tests/scene_tests.tscn -- --only=autosave
```
It deliberately does **not** drive a real transition: `change_scene()` loads MainScene.tscn,
whose SubViewports render every frame, and a headless run has no GPU to service them — that
hangs rather than fails (see the SubViewport gotcha below). The cases drive `_transitioning`
and `_pending_scene_id` directly and assert the decisions made from them.

Two traps it hit that the next case will hit too. A spawned system also registers its
captive cable in the `"spawned"` group, so the group is always bigger than the entry list —
measure a baseline rather than hardcoding a count. And tear a group's room down with
`clear_scene()`, not by freeing the systems: freeing only those leaves the cables standing
in the next group's room.

It writes to the player's real `user://scenes` — the slot dir is derived from the room id
and cannot be pointed elsewhere — so it snapshots `prefs.json`, the arcade manifest and the
active slots up front and restores them byte-for-byte at the end. Restoring the manifest
matters beyond deleting the test's own entry: any rewrite round-trips it through JSON, which
turns its version int into `1.0`.

`RetroXR/Tests/poster_tests.tscn` covers the posters feature — the image load and the
sheet it sizes (alpha scissor vs opaque, mipmaps, aspect, per-instance sub-resources),
sticking to a surface on release, riding the object it stuck to, peeling, conforming to
a curved shell, the options-menu contract, and the save/restore round trip. 112 cases, ~11 s.
```bash
"$godot" --headless --path RetroXR res://Tests/poster_tests.tscn
"$godot" --headless --path RetroXR res://Tests/poster_tests.tscn -- --only=conform
```
Physics runs fine headless — the dummy renderer stubs RENDERING, not Jolt — so the stick
and conform cases are real raycasts against real bodies. It writes its own PNG into the
player's posters folder (`scan_posters` derives that path) and removes it at both ends.

Two traps worth knowing before adding a case. A stuck poster is REPARENTED under its
host, so anything that walks the host's meshes sees the poster's own sheet — that is what
made the first conform sample every interior ray at depth zero. And a poster is placed by
RAY as often as by hand, where `dropped` never fires; a release has to be detected from
`freeze`, so a test that only simulates a hand grab proves nothing about the real gesture.

`RetroXR/Tests/binding_tests.tscn` covers the resolution rules behind per-platform
control overrides. Both stores — `ControllerBindings` (VR controllers) and
`GamepadBindings` (a real pad) — merge default → global → per-system, and a platform's
stored profile IS its override switch; there is no separate flag. So three rules are
load-bearing and each has cases here: a platform with no profile is indistinguishable
from global, a profile shadows global completely INCLUDING global edits made after it
(which is why a profile is always written whole), and clearing one puts that platform
back on global without touching anyone else's. DesktopBindings is the odd one
and has its own cases: its consumers all read the process-global InputMap, so a
platform's keys cannot be looked up per system — they are APPLIED, and the Scroll
Lock capture decides when (RetroController._sync_desktop_scope). Its legacy flat
file is read as the global layer, which is covered too, because losing it would
wipe every desktop player's key map on first launch. It also covers ConsolePadArt, the
table a platform's own controller is drawn from — that a control key's index in
GamepadBindings.TARGET_ORDER really is its RetroPad bit (the trick that lets one
table serve both the XR and the physical-pad sections), and that every control
has an anchor and a row. 176 cases, ~12 s.
```bash
"$godot" --headless --path RetroXR res://Tests/binding_tests.tscn
```
It writes the player's real `user://controller_bindings.json` and
`user://gamepad_bindings.json` — the paths are consts on the two classes and cannot be
pointed elsewhere — so both are snapshotted up front and restored at the end.

`RetroXR/Tests/object_sync_tests.tscn` covers the shared-room network layer with
two and three real in-process ENet peers: initial and replacement snapshots,
host/client spawning and despawning, rigid-body transform flow, grab arbitration,
release velocities, disconnect cleanup, event relay, plain + spring-latched
hinge mechanics (including push-push trays), knobs, plain + spring-return
sliders, levers, and remote head/hand avatars. Momentary button depression is
deliberately not replicated;
the semantic action it triggers is. The event cases cover platform power/reset,
tray/eject and media insertion, every TV bezel/remote action (power, volume,
mute, CRT, stereo/audio modes, aspect, source and channel), deck transports,
cables/ports, book controls, wall and pull-chain lights, blinds and time of day.
Late-join snapshots also carry the TV control state and those fixed room controls,
not only spawned objects. Articulated updates are capped at 64 per reliable
packet, with overflow retained for following packets rather than discarded. It
has no ROM, headset or display dependency.
Each group is independently runnable.
```bash
"$godot" --headless --path RetroXR res://Tests/object_sync_tests.tscn
"$godot" --headless --path RetroXR res://Tests/object_sync_tests.tscn -- --only=hinges
```

That a binding reaches a RUNNING core is deliberately not here: it needs a real system,
a real controller and the `binding_consumers` fan-out, and lives in
`Tools/input/binding_live_probe.tscn`. Drive that probe through the view's OWN
`_global_editor` rather than a fresh `ControlsBindingEditor` — a detached editor writes
to disk and reaches nobody, so every "applies immediately" case fails for a reason the
player never sees.

**For anything visual, a photo (or a VIDEO if it's animated — mp4 preferred over
animated GIF) is the preferred proof of validation, delivered inline in the chat.**
Headless runs catch parse/scene/shader errors but cannot confirm how something *looks*
(glyphs, layout, colors, animation). When a change is visual, capture a screenshot or
short recording and surface it inline — don't just report that the headless import
passed. To encode mp4 from probe PNG frames: `imageio` + `imageio-ffmpeg` are pip-installed
(`imageio.get_writer("out.mp4", fps=15, codec="libx264", pixelformat="yuv420p")`).

Godot binary (Windows) — use **Godot 4.7** (the project targets 4.7):
```
C:\Program Files\Godot\Godot_v4.7-stable_win64\Godot_v4.7-stable_win64_console.exe
```
Use the `_console.exe` variant so stdout/stderr is captured. `$proj` below is the
`RetroXR/` folder inside your checkout.

Godot binary (Linux): `~/Godot/Godot_v4.7-stable_linux.x86_64`
(the project targets Godot 4.7 — see `project.godot config/features`; `Godot_v4.6.3` also
sits in that dir). `$proj` on Linux is `<checkout>/RetroXR`. Note Godot
4.7 promoted "Not all code paths return a value" to a hard parse error for `Variant`-returning
virtual overrides (bit two `_property_get_revert` overrides in godot-xr-tools — fixed with a
trailing `return null`).

### 1. Compile / import check (catches parse, shader & scene-load errors)
```bash
"$godot" --headless --path "$proj" --editor --quit
```
This reimports resources, recompiles every GDScript, compiles shaders, and (critically)
**regenerates the global `class_name` cache**. Run it after adding or renaming any
`class_name`, or a probe that references the new class will fail with
`Could not find type "X" in the current scope`. Filter output for
`SCRIPT ERROR|Parse Error|SHADER ERROR|Failed to load|Failed to instantiate`.

### 2. Functional probe (exercises real code paths)
Write a tiny `probe.gd` (`extends Node`) + `probe.tscn`, run it, print `[probe] ...`
lines, then `get_tree().quit(0)`:
```bash
"$godot" --headless --path "$proj" res://probe.tscn 2>&1 | grep -a "\[probe\]"
```
Always **delete the probe `.gd`/`.tscn` (and generated `.uid`/`.import`) when done.**
Include a `get_tree().create_timer(5.0).timeout.connect(...quit)` safety net so a probe
can never hang the run.

### Gotchas
- **Warnings are treated as errors** for some warnings — notably inferring a `:=`
  variable from a `Variant` (e.g. `var x := ClassDB.instantiate(...)`). Use an explicit
  type (`var x: Object = ...`). `unsafe_method_access` (calling a method not on the
  static type, i.e. duck typing) is **not** an error, so it's fine.
- **A `SubViewport` with `render_target_update_mode = ALWAYS` hangs a headless run**
  (no GPU to service the render target). It renders fine in a real session — just don't
  drive extra `await process_frame`s over such a viewport in a headless probe; test the
  logic/wiring instead and eyeball the visual on-device.
- **Known headless noise to filter out** (pre-existing, not your change): OpenXR
  `xrCreateInstance failed`, missing GDExtension DLLs in the `template_debug` path
  (`libgodotopenxrvendors`, `godot-pdfium`, `libretro_godot`), `.NET Sdk not found`, and
  `xr_staging_shim.gd ... is_xr_class ... placeholder instance`. Grep these out.
- **A renamed/deleted source texture can leave the editor filesystem cache
  pointing at a dead `.godot/imported/*.ctex`.** Re-running an ordinary import
  may keep trusting that stale entry. Move/delete
  `RetroXR/.godot/editor/filesystem_cache*`, then run `--editor --import --quit`;
  Godot rebuilds the class cache and replacement texture imports. This is
  generated local state, not a file to commit.
- **A `.tscn` `Transform3D` lists the basis by ROWS**, not the columns the
  `Transform3D(x_axis, y_axis, z_axis, origin)` constructor takes. For a rotation the
  two differ by a transpose — an inverse — so a hand-written rotation comes out
  backwards. Copyable forms: `R_y(+90)`, local +Z → world +X, is
  `0, 0, 1, 0, 1, 0, -1, 0, 0`; `R_y(-90)` is `0, 0, -1, 0, 1, 0, 1, 0, 0`;
  `R_x(-90)` is `1, 0, 0, 0, -4.371139e-08, 1, 0, -1, -4.371139e-08`. **Never check one
  against a 180° or an otherwise symmetric matrix** — those read the same under both
  conventions and confirm whichever reading you already had, which is how the Wii
  ports and then the Game Boy link socket were both authored inside out. Print
  `node.transform.basis.x/.y/.z` from a throwaway probe and compare it with what you
  meant, before rendering anything.
- **PowerShell buffers `& $godot ... | Out-String` until the process exits**, so a
  backgrounded run shows an empty output file until it finishes. The Bash tool with
  `timeout 90 "$godot" ... 2>&1 | grep` streams and bounds the run — prefer it.

### Verify with a check that can fail

**A green check that cannot tell the two outcomes apart is not a check.** Ask what
the WRONG version would look like before believing the right one; if the answer is
"the same", that is not the check to use.

Two of them in a row cost the Game Boy link socket a whole round trip. It was
authored facing INTO the shell, and the render looked identical because a
rectangular port recess is symmetric, while the room probe passed either way because
a snap zone does not care which way round a plug goes in. Both were green and
neither could have gone red. What settles a facing is a printed basis, or a render
of something ASYMMETRIC — a seated lead, not an empty socket.

**And read the note before authoring, not after the bug.** The gotchas above and the
session memory are each one line in an index, which is enough to recognise a topic
and not enough to act on; acting from the summary is how the same mistake arrives a
second time. `.tscn` transforms, a model's facing and a port's seat all have notes,
and all three were sitting in the index while that socket was written backwards.

`libretro-godot/tests/run_tests.py` is the small Godot-free C++ harness for the
link coordinator and sensor-id encoding.

**`RetroXR/Tests/archive_tests.tscn` is the one GDExtension with a self-checking
suite**, because `RommArchiveExtractor` is the one that needs no display, codec,
core or server. 34 checks over a well-formed archive, the plan validation, a
damaged/truncated/non-ZIP/missing one, and cancellation; every fixture is built
under `user://` at run time, so it carries no binary.

Two of its cases are hand-built STORED archives, and that is not fussiness.
**For a DEFLATED member the declared CRC is handed to `StreamPeerGZIP` as a gzip
trailer**, so a corrupt payload dies inside decompression and
`RommArchiveExtractor`'s own `crc != entry.crc32` comparison is never reached — a
"bad CRC" case built by flipping payload bytes passes with that check compiled
out. Only a STORED member isolates it. `ZIPPacker` always deflates, hence the
hand-rolled fixture.

The other four extensions stay probes and rebuild-plus-load: `verlet-rope` has
the bit-exact oracles in `Tools/rope/`, and `vlc-godot`, `godot-pdfium` and
`metaxr-audio` all need a display, a codec or Meta's blob. Adding a suite for
one of those would mean a red run that depends on the machine it ran on.

### 2b. The bedroom's saved visual probe

`RetroXR/Tools/models/bedroom_probe.tscn` — do NOT hand-roll another one. It carries the
still framings for that room (overview, bed, desk, window, TV corner, bookcases,
wardrobe, light switch) plus a flythrough: 360 deg in place at the room centre,
then a lap walking forward round a circle sized to clear the furniture.

```bash
"$godot" --path RetroXR --resolution 320x240 --position 20,20     res://Tools/models/bedroom_probe.tscn -- --mode=stills      # or flythrough, both
```

Windowed, not `--headless` — the dummy renderer returns a blank image. PNGs land
in `res://probe_out/` (gitignored). Encode a flythrough at 24 fps with imageio and
**pass `-crf 24`**: the default quality puts an 11 s clip at 21 MB, CRF 24 at 2 MB
with no visible difference.

It forces the ceiling-light energy to 0.6 on purpose. The scene authors 1.2 and
`QualityManager._adjust_lights` has not run that early, so a naive probe renders
the room brighter than any player sees it.

**Overwriting a texture in place needs a reimport.** A game run keeps serving the
cached `.ctex`, so two successive recolours of the bed's atlas appeared to do
nothing at all. Run `--editor --quit` between the overwrite and the render.

### 2c. The A/V suite — the one thing here that is an actual test suite

`RetroXR/Tests/av_tests.tscn` — 41 cases over what reaches a television's inputs and
what it shows. Headless, ~35 s, **exits non-zero on failure**, so it is the one probe
that can be run as a gate rather than read.

```bash
"$godot" --headless --path RetroXR res://Tests/av_tests.tscn
"$godot" --headless --path RetroXR res://Tests/av_tests.tscn -- --only=display
```

Groups: `routing/` (real TV + VCR + composite leads — cords into the wrong sockets, a
crossed pair, two leads on one deck, a cord pulled), `display/` (which input is shown,
what a blank input paints, a source that stops, a set switched off, snow on an
untuned aerial channel, a VGA monitor with no phono row, a source's own shader
stage, two sets sharing one machine), `guard/` (`can_paint` / `paint_screen` /
`release_screen`) and `audio/` (only the selected input is heard; a machine wired to
nothing is silent). Every case is a bug that shipped at least once.

Three things it took to make routing cases behave, all of them real behaviour rather
than test scaffolding:
- **Pulling a plug needs the whole panel shut.** Dropping one leaves it standing in a
  60 mm grab zone with four video sockets 18 mm apart around it, and the log reads
  `pulled VIDEO on TV` immediately followed by `seated VIDEO on TV`. `_unplug()` shuts
  every RcaPort in the room for the move.
- **And the plug frozen.** A live one falls back down past the panel and is caught by a
  socket on the way, ending up a perfectly good picture cord in the wrong input.
- **The phosphor accumulator hides the source.** With persistence on, the CRT material's
  `source_tex` is the ping-pong buffer, so the oracle is the set's own `_crt_source_tex`.

It is mutation-tested: reverting the deck to reading one cable, disabling the paint
guard, or restoring the frozen-frame bug each fails exactly the cases that name them.
Adding a case that cannot fail is worse than no case, so break the code and watch it go
red before believing a new one.

### 2d. The BIOS-boot survey — a probe that must stay one core per process

`RetroXR/Tools/cores/bios_boot_probe.tscn` + `Tools/bios_boot_survey.sh` are the provenance
of the `BiosBoot` table, and the only way to refresh it when a core is updated. The
probe reports one core's firmware status, its boot-ROM-ish option keys, and whether it
will start with no content; the survey drives every candidate and prints a table.

```bash
Tools/bios_boot_survey.sh                # every candidate
Tools/bios_boot_survey.sh mgba flycast   # just these
```

**Never loop cores inside one Godot process.** Starting a core with a game info it did
not expect runs code its author may never have exercised, and the extension is built
`-fno-exceptions` with no sandbox: of sixteen cores surveyed 2026-08-20, **six killed the
process** — mgba and parallel_n64 dereference a null `retro_game_info`, and
mednafen_saturn, neocd, dolphin and same_cdi die on a zeroed one. One process per attempt
is what makes a casualty cost one table row instead of the run.

Two things the survey settled that are easy to re-derive wrongly:

- **`supports_no_game` in the `.info` is useless here** — all sixteen candidates declare
  it `false`, and it is *also* true that none of them starts without content. The flag is
  not consulted anywhere; the table records what was measured.
- **The mechanism is empty MEDIA, not an empty path.** Only pcsx_rearmed accepts a
  zero-byte image, and it gives the real PS1 BIOS. flycast (gdi/cdi/chd),
  mednafen_saturn, mednafen_pce and neocd all refuse one.

It **writes the player's real `core_options/`** — a core serialises its whole option set
on shutdown, and a crashed run can leave a key moved (a crashed mgba run flipped
`mgba_skip_bios` to `ON`). The survey snapshots the directory up front and restores it on
exit, including on failure. A probe run by hand does not, so restore by hand or re-run the
survey afterwards.

### 2e. The Game Boy link probes — three layers, two cores, two clocks

`RetroXR/Tools/link/gb_link_probe.tscn` drives the bus directly, `gb_link_room_probe.tscn`
drives the path a player uses (pick a lead up, push a plug into a socket), and
`gb_tetris_link_probe.tscn` runs a commercial two-player game over the result.
Probes rather than tests: they want a real core and, for Tetris, a real ROM.

```bash
"$godot" --headless --path RetroXR res://Tools/link/gb_link_probe.tscn -- --core=mgba
"$godot" --headless --path RetroXR res://Tools/link/gb_link_room_probe.tscn
"$godot" --headless --path RetroXR res://Tools/link/gb_tetris_link_probe.tscn -- --roms=Z:/roms --core=gambatte --core2=mgba
```

**Both cores, and between them.** gambatte and mGBA each carry a Game Boy, both
answer `RETRO_ENVIRONMENT_GET_LINK_INTERFACE`, and both call the wire `gb-sio-1`
with the same message layout -- so a gambatte Game Boy and an mGBA one join the
same cable, which `--core2` is there to prove. mGBA needs its GB driver as well
as its GBA one: they are separate cores with separate serial ports, and before
`gb_sio_netlink.c` a lead between two mGBA Game Boys carried nothing, silently.

The ROMs the first two run come from `Tools/gen_gblink_rom.py` and swap a known
byte for ever, painting the screen white while the byte coming back is right. No
assertion is made against an absolute shade -- a core picks a palette per game --
only that a cabled screen is neither of the two an uncabled pair shows. The
`_fast` pair is the same exchange at the Game Boy Color's 262144 Hz clock, a
transfer of 128 cycles against 4096, which is the one path a Game Boy cannot
reach: SC bit 1 reads back as one on a DMG whatever is written.

**Drive the two machines one at a time.** Tetris settles which unit owns the
clock by having both send 0x29 until one is listening when the other calls, so
two machines driven on the same emulated frame both call and neither listens --
the trace reads as two masters clocking the same tick for ever, each getting the
0xFF of a cable nobody is holding. Real hardware cannot stay there because two
people are never frame-perfect; a script can, and will. The same probe also
presses START and then LOOKS, because in Tetris that button picks a game type,
confirms a level, starts the match AND pauses it, and the pause travels down the
wire.

**Tetris DX is not a usable target.** Its 1PLAYER and 2PLAYER entries are greyed
out until a profile exists, so each machine needs a scripted name entry through
an on-screen keyboard first, and the two routes drift apart. The Game Boy Color
path is covered by the `_fast` ROMs instead.

### 2f. Netplay — a suite, and the one thing it cannot cover

`RetroXR/Tests/netplay_tests.tscn` is 685 cases over the whole lockstep stack,
headless, ~32 s, exits non-zero. Groups: `cores/` (the determinism allowlist),
`identity/` (which core builds may play each other), `wire/` (every packed
block's round trip, including per-port accelerometer, gyro, IR/touch and
lightgun state), `owners/` (who supplies which port on which frame),
`assemble/` (frame completion and pruning), `start/` (the asynchronous cold
start), `lockstep/`, `desync/`, `join/`, `leave/`, `rollback/`, `link/` (a
cabled pair as one session).

```bash
"$godot" --headless --path RetroXR res://Tests/netplay_tests.tscn
"$godot" --headless --path RetroXR res://Tests/netplay_tests.tscn -- --only=start
```

**It runs two — for the join cases, three — complete NetworkManagers in ONE
process**, each under its own `SceneMultiplayer`, over real loopback ENet. Do
not reach for two OS processes instead: the RPCs, channels, serialization and
handshake are already the real ones, and one process keeps the run deterministic
and headless. It replaced `Tools/netplay_session_probe.tscn`, which was the same
idea at a quarter of the coverage.

Godot 4.7 currently prints a fixed `ObjectDB` shutdown warning after these
in-process branch-ENet suites (`18 RefCounted` objects in the ordinary netplay
run). It is the engine's RPC cache interaction with the project's NetworkManager
autoload, not an accumulating session leak: one pair and many sequential pairs
leave the same fixed count, a raw ENet pair in this project reproduces it, and
the same raw pair in a minimal project without the autoload is clean. Removing
the autoload before connecting suppresses the warning but leaves Godot with a
dangling autoload singleton and eventually crashes the full suite, so do not
hide it that way. The passing case count and exit status remain the gate.

What no suite here can cover is a real core's arithmetic. That is
`Tools/netplay/netplay_spike.gd`, and it now has a **cross-machine leg**, which is the
only thing that tests the one payload lockstep actually puts on the wire — a
savestate, shipped for a late join or a desync resync:

```bash
machine 1:  ... res://Tools/netplay/netplay_spike.tscn -- --spike-state-out=Z:/np.bin
machine 2:  ... res://Tools/netplay/netplay_spike.tscn -- --spike-state-in=Z:/np.bin
```

Machine 1 writes its state, the frame, its core identity and its whole phase-A
CRC table; machine 2 loads that state into ITS core and replays the same input
timeline against machine 1's CRCs. Run it x86_64 → arm64 and back. Cold-start
CRC determinism was verified across those two in 2026-07-06; a foreign savestate
crossing between them was not, and a libretro state is a struct dump for most
cores.

**ROM/device validation still owed:** the automated suite proves that lightgun,
accelerometer, gyroscope and multi-point IR/touch values survive the network,
reach the native input handler and keep their sub-device index. It does not prove
that a real content core consumes those values correctly. In particular, Wii
Remote accel/gyro/IR through Dolphin and a real lightgun title still need a ROM,
the matching core and preferably the real controller. The user does not plan to
obtain a ROM, so leave this as an explicit unverified hardware/content check; do
not represent the mock/no-ROM suite as that proof.

**Cross-platform play is a build-identity problem before it is a determinism
problem.** `core_download_manager.gd` points every platform at
`nightly/<platform>/latest/`, so five separate builds are in play (win-x64,
linux-x64, android-arm64, osx-arm64, osx-x64) cut at five different times from
five different commits. Two Windows players who downloaded the same day are
byte-identical; a Windows player and a Quest player essentially never are. The
core FILE can therefore never be compared — what is compared is
`Libretro.GetCoreIdentity()`, which the C++ publishes from the emulation thread
once `retro_load_game` succeeds: `library_name`, `library_version`,
`api_version`, `serialize_size`. fceumm puts its git hash in the version
(`FCEUmm (SVN) 5cd4a43`), so nightly skew really is visible there.

That dictionary is **empty until content has loaded and empty again after it
stops**, which makes it the readiness test as well as the identity. That matters
more than it sounds: `StartContent` spins the emulation thread and returns, so a
core that is missing, refused or wedged fails ASYNCHRONOUSLY — a real fceumm
took **34 frames** to come up in a probe here. Reporting a peer ready before
then is reporting a peer with no core.

**The identity is published in two halves, at the two moments each half is safe
at, and both constraints are load-bearing:**

- `library_name`/`library_version`/`api_version` land **at load**. They were
  read from `retro_get_system_info` during `Core::Load` and cost no call into
  the core, so they are safe everywhere.
- `serialize_size` lands **after the first `retro_run`**, and is 0 until then.
  Dolphin answers `retro_serialize_size` by marshalling onto its CPU thread and
  walking every subsystem, so asking at load segfaults it on a machine that does
  not exist yet — and because the publish sat on the unconditional load path,
  that broke every Dolphin boot, not just netplay.

It cannot simply move to after the first frame either: **the netplay gate does
not run frame 0 until every peer reports ready, and readiness is this dictionary
being non-empty.** Requiring a frame deadlocks every cold start — measured, the
identity never arrived in 2888 ticks — and the symptom is a 10 s timeout saying
"core did not come up". So a reader comparing sizes across peers must treat 0 as
"not measured yet" rather than as a difference; at cold start both peers are
usually 0 and the version comparison carries the weight.

`RetroXR/Tools/netplay/core_identity_probe.tscn` is the guard for all of that, and it
needs a real core so it stays a probe. It runs the same core twice, gated (a
netplay cold start: identity must arrive with ZERO frames run) and ungated (the
size must really get measured), and exits non-zero.

```bash
"$godot" --headless --path RetroXR res://Tools/netplay/core_identity_probe.tscn -- \
  --ident-core=fceumm "--ident-rom=$HOME/retroxr/roms/nes/rom.nes"
```

**Run it against dolphin, not just a quick NES core** — fceumm cannot fail the
half that matters. And give Dolphin `--ident-leg=gated` and `--ident-leg=ungated`
in separate processes: both legs in one run means a restart, Dolphin is one of
the cores that will not unwind, and the abandoned thread segfaults on the way
out looking exactly like an identity crash.

### 2g. Netplay over a link cable — one session, two machines

**A link cable never crosses the network.** `LinkCoordinator` is a process-wide
singleton joining two cores in the SAME process, so under netplay every peer
replicates BOTH machines and it is determinism, not a wire, that keeps the two
buses agreeing. A cabled pair is therefore ONE session over TWO machines, which
is why `NetplaySession` holds a `_group` rather than a system.

Ports are named `machine * PORTS_PER_MACHINE + port`, so both machines' pads fit
in one assembled frame; each core is handed only its own 20-int block plus that
machine's aux and key blocks. Aux (tilt, touch) and keyboard ride with each
machine's own port-0 owner — copying the anchor's tilt into every linked handheld
is just as wrong as dropping the far handheld's input. A linked late join pauses
every local core at one boundary and transfers both core savestates plus
`LinkCoordinator`'s clock horizons and queued messages. The joiner restores the
physical bus first, then its external bus snapshot, then the core states, so it
cannot resume half of an in-flight serial conversation.

The per-machine launch spec also records `rom`, `empty_media`, or `no_content`.
That last mode is the cartridge-less GBA in single-pak play: it cold-boots mGBA
with the BIOS only, then an ordinary core savestate carries the downloaded
program, RAM, registers and link state just like a cartridge-backed machine.
Empty-disc BIOS menus use `empty_media` instead and regenerate the zero-byte
image locally; BIOS files themselves are never transferred. Every peer must
already have matching firmware. The no-ROM tests cover this launch/state
plumbing with mock cores. mGBA IS now in `NetplayCores` (verified, with
ROLLBACK/LOCKSTEP/DETERMINISM), so the core is no longer the blocker it once
was — but a real single-pak netplay run still needs a payload-carrying game ROM,
which the user does not plan to obtain. Leave THAT validation noted as
outstanding; do not read mGBA's presence in the table as proof single-pak play
was exercised end to end.

Late-join state is a bounded stream, not one RPC: 64 KiB reliable chunks, eight
in flight, cumulative acknowledgements, SHA-256 per payload, and a 256 MiB total
cap. The metadata is a chunked payload too, because it contains SRAM and the
external link-bus queues. Capture, transfer, core startup and state load all have
progress deadlines; a timeout tears the newcomer down, makes it a spectator and
releases the existing players. Firmware matching hashes every path declared by
the core (including directory contents), not only the files used to draw a BIOS
screen.

Two things this had to get right, and both are the same rule:

- **Every machine on every connected wire is in the session.** When it held one, the far end
  was ungated on the host and not running at all on a client, so the client's
  gated core sat on a bus whose other end never published — and the coordinator
  waits for a peer that is behind rather than guessing, with deliberately no
  timeout. Host fine, client wedged. A console can have several independent
  leads (four GameCube-to-GBA cables are the obvious case), so the group is the
  transitive merge of every cable bus touching the anchor, not the first match.
- **All THREE leads, not just the handheld one.** Every lead that can put two
  cores on a wire answers `linked_machines()` / `held_machines()`, and a machine
  finds its bus by asking the leads rather than searching its own sockets. That
  is not tidiness: a GameCube-to-GBA lead puts its wide end in a **controller**
  socket, so there is no `LinkPort` on the console side to walk out of, and a
  search from the machine would have decided a cabled GameCube was on no bus at
  all. `net_link_bus` therefore sweeps both the `link_plug` and `controller_plug`
  groups. (That the GC end is in `controller_plug` and not `link_plug` is pinned
  by `link_tests`; the same suite seats both ends through their real socket APIs
  and verifies that `net_link_bus` discovers the console through
  `controller_plug`.)
- **A plug seated mid-game lands on ONE agreed frame.** `LinkCoordinator.hpp`
  says so itself: the thing it cannot enforce is that Connect and Disconnect
  happen on the same emulated frame on every peer, and that is the caller's job.
  Nothing was doing it. The host now waits for every peer to acknowledge the
  reliable topology command, then holds the boundary until every local core has
  finished the preceding frame; only then does it change the bus and release
  that frame to any core. `link_cable._resolve` hands the decision to the host
  instead of joining on the spot whenever a hand moves.

`RetroXR/Tools/netplay/netplay_link_probe.tscn` is the real-core half — two gambatte
Game Boys, the real bus, ROMs from `Tools/gen_gblink_rom.py`:

```bash
python Tools/gen_gblink_rom.py     # once, into RetroXR/Tools/gblink/
"$godot" --headless --path RetroXR res://Tools/netplay/netplay_link_probe.tscn
```

Its two legs pull opposite ways and both must hold. Fed on both machines, the
pair runs and trades bytes (240 frames, 293/431 messages). Fed on only the near
one — a client before the group existed — **the near core reaches frame 2 and
stops dead.** That second leg is the reproduction, and a green there would mean
the bus had stopped waiting, which is worse than the hang: a cabled netplay pair
would desync instead of stalling.

`RetroXR/Tools/link/gc_gba_link_probe.tscn` is the same thing for the ASYMMETRIC
lead, which had been reasoned about and unit-tested and never once run with the
cores that actually speak the JOY bus. It wants Dolphin, mGBA and two commercial
ROMs, so it is a probe. It reproduces what `GcGbaCable` does on seating, in
order: `SetControllerPortDevice(port, (7 << 8) | 0)` then
`LinkConnect(gba, console_port, GBA_JOY_PORT)`.

```bash
"$godot" --headless --path RetroXR res://Tools/link/gc_gba_link_probe.tscn
"$godot" --headless --path RetroXR res://Tools/link/gc_gba_link_probe.tscn -- --gba-empty
```

First run, 2026-08-21, Four Swords Adventures against Super Mario Advance:
Dolphin attaches `gba-joy-1` at 486 MHz, mGBA at 16777216 Hz, `bus 0 [P1 on,
P2 on]`, peers 2/2, and **6247/6248 messages** over 1574 frames with both cores
in step. So the console-port end of the lead works with real cores.

**`--gba-empty` is the pairing the game actually wants**, and the difference is
stark: with no cartridge in the handheld the same run trades **82407/82408**
messages, thirteen times as many. Four Swords Adventures uses the GBA as a
screen and pad and uploads its own program over the wire, so a handheld holding
its own commercial cartridge is a legitimate cabling but not a conversation
either title was written for. Do not read a low byte count in the cartridge case
as a fault.

**The bus is cheap, and the teardown cost report does not say otherwise.**
Measured with `--no-cable`, which boots both cores side by side and never joins
them: uncabled **57.1 / 57.3 fps**, cabled **54.8 / 54.6 fps** over the same
28.4 s. About 4%. The report's "22368 ms blocked" over a 28.4 s run looks
alarming and is not lost time — the two cores are on separate threads, so one
blocking IS the other one working. Read the fps, not the blocked total.

What the report is good for is STALLS, and there is one real artifact: a single
~1 s hitch early on (967 ms on the console at 1034 ms in, 1197 ms on the
handheld at 2394 ms in), with only 1 and 6 further events over 20 ms in the
whole run. It lands during the program upload and does not recur. On a desktop
that is a hitch; in a headset it would be felt once, and it is the one number
worth watching if this ever reaches a Quest.

Both cores are now in `NetplayCores` (they were not when this section was first
written): `mgba` is `verified` with ROLLBACK/LOCKSTEP/DETERMINISM, `dolphin` is
`verified: false`, `state_transfer: false`, DETERMINISM only. So a session over
this pair can now be started — but note what the probes above do and do not
prove: they exercise the BUS with real cores, not a netplay session over it.
Dolphin having no transferable state is why it is DETERMINISM-only, which in
turn means no late join and no desync repair.

### 2h. The Super Game Boy — an adapter cartridge, and the core that can run one

A Super Game Boy is a Super Famicom cartridge with a Game Boy slot in its roof, so
it is the same three-layer object as the BS-X cartridge and is modelled the same
way: `ExpansionCatalog.MOUNT_CARTRIDGE`, a cartridge to the console and a console
to the cartridge. Two units, `super_game_boy` and `super_game_boy_2`.

**Snes9x cannot serve it at any price, and this is not obvious from the source.**
`libretro/libretro.cpp` defines `RETRO_GAME_TYPE_SUPER_GAME_BOY 0x104|0x1000`
right beside the BS-X and Sufami Turbo constants, so grepping for it finds a hit
and suggests support. It is vestigial: the `subsystems[]` array actually passed to
`RETRO_ENVIRONMENT_SET_SUBSYSTEM_INFO` holds only `multicart_addon` and `bsx`, and
`retro_load_game_special` drops that game type into `default:` and reports the load
failed. The row therefore pins **bsnes**, which is why `RetroSystem._resolve_core`
letting a stack's core beat the console's default is load-bearing here rather than
a nicety — a Super Famicom is a snes9x machine until one of these goes into it.

Verified in bsnes-libretro, `bsnes/target-libretro/libretro.cpp`:

```c
sgb_roms[]   = { "Game Boy ROM" (gb|gbc), "Super Game Boy ROM" (smc|sfc|swc|fig) }
subsystems[] = { "Super Game Boy", "sgb", sgb_roms, 2, RETRO_GAME_TYPE_SGB }
```
with `retro_load_game_special` assigning `gameBoy.location = info[0]` and
`superFamicom.location = info[1]`. So the ident is `sgb` and the **handheld's**
cartridge goes FIRST — the reverse of the BS-X pairing, which is shell-first. The
two orders are written out per row for exactly that reason; do not assume one from
the other.

**A BIOS is required, and it is the adapter's own cartridge**: `SGB1.sfc`
(md5 `b15ddb15721c657d82c5bab6db982ee9`) and `SGB2.sfc`, declared in
`bsnes_libretro.info` and installed to `libretro/system/bsnes/`. Each unit names
one and is gated on it independently, so a player with one dump is offered one
adapter. `rom_from_firmware` on the row is what lets the adapter find its own
program there: unlike the BS-X cartridge, which is spawned from a `.sfc` in the
library and carries it in `rom_path`, a Super Game Boy is spawned from a menu and
has no library file at all — without that flag its `rom_path` stays empty, the
pair comes up one short and degrades to a plain load **silently**.

The SGB2 is a real difference and costs nothing to model: the original derives its
clock from the SNES and runs the handheld about 2.4% fast, the revision carries its
own crystal. Because the cartridge IS the program the console runs, handing the
core a different dump is the whole of the change — a core that emulated the adapter
internally would have needed an option instead.

**What actually picks the revision is the dump's own SNES header, not its
filename.** Verified at source and against both files: the titles at `0x7FC0` read
`Super GAMEBOY` and `Super GAMEBOY2`, bsnes matches those against its bundled board
database, and `Cartridge::loadICD` reads `icd.Revision`/the oscillator out of the
board that matched. `icd.cpp` then branches on that single number, with its own
comment saying why — *"SGB1 uses the CPU oscillator (~2.4% faster than a real Game
Boy), SGB2 uses a dedicated oscillator"* — and it settles three things at once:

```cpp
if(Frequency == 0) { GB_init(&sameboy, GB_MODEL_SGB_NO_SFC);
                     GB_load_boot_rom_from_buffer(&sameboy, &SGB1BootROM[0], 256); }
else               { GB_init(&sameboy, GB_MODEL_SGB2_NO_SFC);
                     GB_load_boot_rom_from_buffer(&sameboy, &SGB2BootROM[0], 256); }
```
with `frequency()` returning `Frequency ? Frequency : system.cpuFrequency()`.

Two things follow. **The boot ROMs are compiled into bsnes**, so `sgb1.boot.rom` and
`sgb2.boot.rom` are never wanted here even though higan and bsnes-mercury ask for
them — a Super Game Boy runs on this core with nothing but the two `.sfc`. And
**`SGB1.sfc`/`SGB2.sfc` are only where RetroXR looks**: an SGB1 dump installed under
the other name yields two adapters that are both an SGB1, and the spawn gate will
not catch it, because `firmware_present` accepts a `MISMATCH` md5 on purpose (see
BS-X.bin). The BIOS / Extras tab is where that verdict is visible.

They are carded on the **Game Boy** tile, not the Super Famicom's, because
`ExpansionCatalog.card_systemid` files a unit under its media and these run Game
Boy cartridges. That is also where a player is standing when they want one.

`RetroXR/Tools/cores/sgb_probe.tscn` is the measurement, and it needs a real core,
a real `.gb` and the SGB dump, so it is a probe. **The oracle is the frame size,
and it cannot pass by accident**: a Game Boy frame is 160×144 and a Super Game Boy
frame is 256×224, because in SGB mode the SNES is the machine drawing. It does not
depend on the ROM having any SGB support — a game that sends no border packets
still gets the adapter's default frame — so a generated test ROM answers it.

```bash
"$godot" --path RetroXR --resolution 320x240 --position 20,20 \
  res://Tools/cores/sgb_probe.tscn -- --core=bsnes \
  --rom="$HOME/retroxr/roms/game_boy/game.gb" --leg=subsystem --shot=res://sgb.png
```

One core AND one leg per process.

**Measured 2026-08-30, and the half that needs no copyrighted dump is settled.**
bsnes publishes, at runtime:

```
Subsystem 'sgb' (Super Game Boy): 2 rom(s), id=4353
Subsystem 'bsx' (BS-X Satellaview): 2 rom(s), id=4368
```

so the ident and the rom count in the catalog row are confirmed against the
running core, not only against its source. **Note the two ids**: bsnes calls SGB
4353, and snes9x calls BS-X 4353. The same number means two different machines in
two different cores, which is exactly why `_start_subsystem_content` resolves by
IDENT and lets the core's own published table supply the id. Never hardcode one.

**bsnes refuses a bare `.gb`** — `retro_load_game` came back false, "This core
refused the game", zero frames — so there is no plain-load path to fall back on
and the subsystem really is the mechanism. (That control run had no `SGB1.sfc`
installed, so it does not distinguish "bsnes has no standalone Game Boy mode"
from "bsnes wanted SGB mode and could not find the cartridge"; either reading
leaves the row as written.)

**The subsystem leg passes end to end**, measured against Donkey Kong (World)
(Rev A) (SGB Enhanced) with the No-Intro `SGB1.sfc`
(md5 `b15ddb15721c657d82c5bab6db982ee9`, 256 KB) in `libretro/system/bsnes/`:
1596 frames at **256×224**, and the arcade-cabinet border rendered in colour with
the Game Boy screen inset. The whole path is proven — catalog row, ident, pair
order, firmware lookup and core.

**Two traps the picture cost, and neither shows up in a log.** The core's frame
carries an alpha channel it never fills, so a straight `img.save_png` writes a
fully transparent image — 13 KB of real picture that every viewer paints as a
blank white rectangle. `sgb_probe` flattens to `FORMAT_RGB8` before saving. And
`--headless` gives back a correctly SIZED frame with nothing drawn into it, so
the size oracle reads 256×224 and passes while the shot is blank; run windowed
whenever the border is what you are checking.

Sample late, and more than once. The frame is 256×224 from the very first frame,
because the SNES draws the whole field whether or not the border has arrived —
the border lands when the game sends its SGB packets, which for Donkey Kong is
somewhere past ten seconds. `--at=8,16,26` rather than one fixed moment.

**bsnes saves through its own VFS, not through RetroXR's SRAM path, and this is
true of every bsnes machine rather than only the Super Game Boy.** Read at source
and confirmed on disk:

```cpp
void *retro_get_memory_data(unsigned id) { return nullptr; }
size_t retro_get_memory_size(unsigned id) { return 0; }
```

Every id, `RETRO_MEMORY_SAVE_RAM` included — so `SetSramPath` and everything
`SramPaths` composes reaches nothing. bsnes instead answers `save.ram` out of
`program.cpp`'s VFS by asking for `RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY` and
appending the loaded ROM's base name, which lands at
`libretro/save/bsnes/<rom>.srm`. Playing a Game Boy game through the adapter
leaves exactly that file, and no `cart_save_dir` subdirectory is created at all.

The save is therefore the Game Boy cartridge's, which is right — the battery is
in the cartridge, not the adapter, and `ExpansionCatalog` deliberately gives the
adapter no `save_owner` for that reason. But it is keyed to the ROM's **filename**
where every other core's is keyed to the cartridge's `save_id`, so renaming a ROM
orphans its save, and two copies under different names keep separate ones. The
Saves panel, save backup and netplay's SRAM transfer all read the `SramPaths`
file, which for this core is not the one being written. Not yet reconciled;
`expansion_tests` pins RetroXR's half and says in as many words that it is not
claiming the core's.

### 2i. The Sufami Turbo — two cartridges in one adapter

The Bandai adapter that goes in a Super Famicom slot and takes **two** small
cartridges, nine of whose thirteen games link the one in slot B into the game in
slot A. It is the only unit in `ExpansionCatalog` with more than one bay, and the
reason a bay is addressed by index at all.

**snes9x has the same dead constant here that it has for the Super Game Boy.**
`RETRO_GAME_TYPE_SUFAMI_TURBO` is `#define`d *and* has a working `case` in
`retro_load_game_special`, and is registered in no subsystem — so no frontend can
reach it. Do not be fooled by the grep hit; that is twice now in one core.

What IS advertised, confirmed at runtime, is:

```
Subsystem 'multicart_addon' (Multi-Cart Link): 2 rom(s), id=4357
Subsystem 'bsx' (BS-X): 2 rom(s), id=4353
```

The Multi-Cart Link case sniffs the FIRST cartridge with `is_SufamiTurbo_Cart`
(size in `0x80000..0x100000`, `"BANDAI SFC-ADX"` at 0, and *not* `"SFC-ADX BACKUP"`
at 0x10 — that marker is what makes STBIOS.bin the BIOS rather than a cartridge),
loads `STBIOS.bin`, and calls `LoadMultiCartMem(A, B, bios)`. One cartridge is a
first-class configuration, not half a pair: `retro_load_game` sniffs the same
header and maps slot B empty.

**A missing STBIOS.bin does not silently degrade** — measured, because the obvious
guess was wrong. `rom_loaded` stays false and the load is refused outright: zero
frames, `content_load_failed`. Note `Cart is Sufami Turbo...` prints in that case
too, so that line alone is not a pass. The line that means it really mapped is
`Map_SufamiTurboLoROMMap`.

**Measured 2026-08-30** with the No-Intro set: SD Ultra Battle Ultraman Densetsu
in slot A and Seven Densetsu in slot B, 767 frames at 256×224, and the game
itself reporting the B cassette's backup state — which is the proof the link is
live, since a game that could not see slot B would not mention it. Poi Poi Ninja
World runs the single-cartridge path.

**Both cartridges keep their saves, and it took a bridge change to do it.**
`retro_get_memory_size` answers `RETRO_MEMORY_SAVE_RAM` and
`RETRO_MEMORY_SNES_SUFAMI_TURBO_A_RAM` from the same case — slot A alone — while
slot B sits under `_B_RAM` at `(4 << 8) | RETRO_MEMORY_SAVE_RAM`, a core-specific
id defined in snes9x's own `libretro.cpp` rather than in `libretro.h`. Reading
only `SAVE_RAM` gave 16384 bytes whether one cartridge was in or two, so a linked
pair kept half its progress; SD Ultra Battle said as much every launch, reporting
that the B cassette's backup was not initialised.

`Libretro.SetSramBPath` now carries slot B to a file of its own, with ordinary
save semantics — read back at content load, written when it changes — unlike
`SetPackPath`, which writes over the medium and never reads. The A id is
deliberately NOT used: the core answers it and plain `SAVE_RAM` from one case, so
asking for both would write one cartridge's save to two files.

The path is keyed off the **cartridge**, not the slot (`RetroSystem._slot_b_save_path`),
so a game carries its save between the two wells and lending it to a different
pairing does not overwrite it.

**Every dump is named `.sfc`, not `.st`.** `libretro-core-info-retroxr/snes9x_libretro.info`
overrides `sufami_turbo:st,sfc` for that reason — otherwise the library files them
under `super_nes` and the adapter's bay refuses them. That override is a WHOLE
copy of the vendored file: the overlay replaces an entry rather than merging, so
a one-line file would delete snes9x's firmware declarations with it.

```bash
"$godot" --path RetroXR --resolution 320x240 --position 20,20 \
  res://Tools/cores/sufami_probe.tscn -- \
  "--a=$HOME/retroxr/roms/sufami_turbo/<A>.sfc" \
  "--b=$HOME/retroxr/roms/sufami_turbo/<B>.sfc" --sram=/tmp/t.srm
```

The probe cannot read its own log — `Libretro` publishes no log signal — so the
branch is asserted by the CALLER grepping the run. `--sram` reports the flushed
size, which is how the save limit above was measured.

### 3. Capturing a real screenshot on Linux (for visual validation)
`--headless` uses the dummy renderer — it **cannot** produce a screenshot (a probe that awaits
`RenderingServer.frame_post_draw` just hangs; `get_image()` is blank). To actually render a
RetroXR scene on this box, run Godot **on the real display** (`DISPLAY=:0`,
Vulkan Forward+ — a window briefly appears on the desktop, ok'd for validation) and draw into a
**`SubViewport`**, not the window viewport (the uncomposited window swapchain reads back as
clear-colour only). Xvfb does not work here (bwrap/glycin abort in the sandbox). Recipe:
```gdscript
var sv := SubViewport.new()
sv.size = Vector2i(1000, 750)
sv.own_world_3d = true
sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
add_child(sv)   # add WorldEnvironment + DirectionalLight3D + your scene + Camera3D as children
cam.current = true              # make_current() does NOT work inside a SubViewport
for i in range(8): await get_tree().process_frame
await RenderingServer.frame_post_draw
await get_tree().process_frame
sv.get_texture().get_image().save_png("res://shot.png")
```
Run `DISPLAY=:0 "$godot" --path "$proj" res://shot.tscn` (import first with `--headless … --import`).
Then **surface the PNG inline via the Read tool** — the user sees it through the Claude app (the
terminal itself doesn't paint it). Don't save renders to a folder; delete the probe + PNG when done.

## On-Device Testing (Quest over adb, nobody wearing the headset)

The Quest 3 usually sits on the desk on USB (`adb devices` → authorized; USB keeps it
charged). RetroXR can be exported, installed, launched, and probed on it fully
unattended. Verified end-to-end 2026-07-06 (x64↔arm64 netplay determinism run).

In Git Bash, `export MSYS_NO_PATHCONV=1` first or `/sdcard/...` args get mangled into
`C:/Program Files/Git/sdcard/...`.

### Export + install
```bash
"$godot" --headless --path "$proj" --export-debug "Quest" out.apk
adb install -r out.apk        # -r keeps app data
```
- **Stale-script trap**: the gradle export can silently ship an old compiled script —
  `RetroXR/android/build/src/main/assets/**.gdc` is not always re-staged after a source
  edit. If an on-device change doesn't take: `rm -rf RetroXR/android/build/src/main/assets
  RetroXR/android/build/build/intermediates/assets` and re-export. To verify before
  installing: a `.gdc` is a 12-byte `GDSC` header + zstd; decompress with Python 3.14's
  `compression.zstd` and grep the payload for a string you just added.
- `FileAccess.file_exists("res://….tscn")` is **false in exported builds** (paths are
  remapped into the pck) — use `ResourceLoader.exists()`.

### Launching with no one wearing it — ALL three are required
```bash
adb shell am broadcast -a com.oculus.vrpowermanager.prox_close   # fake "worn"
adb shell setprop debug.oculus.guardian_pause 1                  # else a Guardian dialog blocks
adb shell monkey -p com.xenu.retroxr 1                           # GodotApp isn't exported; am start = Permission Denial
```
- The manifest must declare `oculus.software.handtracking` or the shell blocks with a
  controllers-required dialog (controllers are off/dead). That needs BOTH the export
  preset `meta_xr_features/hand_tracking=1` AND project.godot
  `xr/openxr/extensions/hand_tracking=true` — the vendors plugin only injects the
  manifest feature when the OpenXR project setting is on (enabled since b9f1481).
- If an OS dialog is showing, the launch is **cached** and fires once it clears
  (`adb shell input keyevent KEYCODE_BACK` can dismiss).
- Cleanup when done: `guardian_pause 0`, broadcast `prox_open`, `am force-stop`.

### Paths on device
- `user://` = **internal** `/data/user/0/com.xenu.retroxr/files/` — readable/writable via
  `run-as com.xenu.retroxr` (debug builds). Cores + system dirs live there
  (`files/libretro/…`, populated by the in-app CoreDownloadManager).
- ROMs/books/videos live on the **external** dir `/sdcard/Android/data/com.xenu.retroxr/files/`
  (plain `adb push`/`ls` works there).
- **Never `adb push` over a file, or into a directory, that the app itself writes.** The
  app is `other` for everything `shell` creates in its own tree, and no chmod fixes that
  sanely. Confirm the group list before theorising — `cat /proc/$(pidof
  com.xenu.retroxr)/status` reports `Groups: 3003 9997 20198 50198`, i.e. `inet`,
  `everybody`, `<uid>_cache` and `all_a<uid>`. **`ext_data_rw` (1078) is not among them**,
  and it is the group on every `adb`-created file and directory here. Owner is `shell`,
  group is unreachable, so only the `other` bits apply:
  - `adb push` lands a file `0644` — other `r--`. The app can read it forever and can
    never overwrite it. Fine for ROMs, fatal for state files.
  - `adb` creates directories `0770` — other `---`. The app cannot create anything inside
    one, so a system folder made by push gets no `.romm/` index. `romm_catalog.gd` ignores
    the return of `make_dir_recursive_absolute`, so this surfaces one line later and one
    level down as "Cannot write to …/nintendo_64/.romm".
  - Granting the app access through the bits alone would mean `0666` on files and `0777`
    on directories, because the group is useless to it. Don't. Let the app own what it
    writes: delete the pushed copy and let it be recreated in-app.
  - **`chmod 660` is actively harmful here** — it clears the `other` read bit the app was
    relying on, and grants write to a group the app is not in. A config the app can no
    longer read looks exactly like a config that was wiped.
  - Diagnose by owner, not by logs, and never with `run-as com.xenu.retroxr test -w …` —
    that shell does not get the app's storage mount view and reports NOT-WRITABLE for
    files the app demonstrably just wrote. The reliable tell is that every `.romm/` on the
    device is owned by the same uid as its parent directory, never a mix.
- Extra cores: same source the app uses (core_download_manager.gd) —
  `buildbot.libretro.com/nightly/android/latest/arm64-v8a/<core>_libretro_android.so.zip`.

### Running the netplay determinism spike on-device
NetworkManager boots `Tools/netplay/netplay_spike.tscn` at startup when `user://spike.cfg`
exists (the spike deletes the cfg immediately, so a crash can't wedge the app):
```bash
printf -- '--spike-core=fceumm\n--spike-rom=/sdcard/Android/data/com.xenu.retroxr/files/roms/nes/ROM.nes\n--spike-root=/data/user/0/com.xenu.retroxr/files/libretro\n' > spike.cfg
adb push spike.cfg /data/local/tmp/
adb shell "cat /data/local/tmp/spike.cfg | run-as com.xenu.retroxr sh -c 'cat > files/spike.cfg'"
```
Then launch (above) and compare the `[crc]` lines against a Windows spike run.

### Log capture
The logcat ring buffer rotates away in **under a minute** (VrApi spam) — poll-grepping
loses boot output. Stream from before the launch instead:
```bash
adb logcat -c && adb logcat -s godot:* > quest.log &
```

## CI

Three workflows in `.github/workflows/`:

- **`tests.yml`** — the gate. Builds the six GDExtensions for windows x86_64 debug via
  `python Tools/build.py windows --target debug`, installs Godot, imports the project,
  fails on any script or shader error, then runs `python Tools/run_tests.py`.
- **`release.yml`** — `preflight` → `quest` + `windows` → `release`, on a tag push or
  `workflow_dispatch`.
- **`sidequest.yml`** — the SideQuest listing.

Because `tests.yml` runs `Tools/run_tests.py`, which globs `Tests/*.tscn` non-recursively,
a suite added to `Tests/` is picked up with no CI edit — and a suite nested in a
subdirectory is silently skipped. See the testing section above.

## Mods

A mod is ONE file — a `.zip` (recommended) or `.pck` resource pack — in
`<data root>/mods/`. It can add consoles, platforms, rooms, props, TV cabinets and
controllers, or replace something shipped. `docs/modding.md` is the author-facing
guide; this section is what a maintainer needs.

`Scripts/Mods/` holds the loader: `mod_manager.gd` (the `Mods` autoload, placed
before `AppPrefs`), `mod_manifest.gd`, `mod_pack_reader.gd`, `mod_api.gd`,
`retro_mod.gd`, `mod_hooks.gd`, `mod_shaders.gd`.

**The load order is the design.** A pack is opened, listed, its `mod.json` and
thumbnail read, and its inventory checked — all WITHOUT mounting — before anything
is loaded. That matters because `ProjectSettings.load_resource_pack` cannot be
undone: mounting to find out what a mod is would commit to every mod on disk.
Reading without mounting is also what lets the Mods page show a disabled mod's
name and art, which is when the player is deciding whether to trust it. Enabling
or disabling therefore takes effect on the NEXT launch, and the page says so.

**`ModPackReader` handles both containers.** Zip is `ZIPReader`. Pck parses the
pack directory and reads members at their recorded offsets — written against a
pack this engine actually produced, because **Godot 4.7 writes pck format 4**,
whose header differs from the 4.0-era format 2 (flags, then `file_base`, then a
`dir_offset` the directory must be SEEKED to; paths stored without the `res://`
prefix; offsets relative to `file_base` when the `REL_FILEBASE` flag is set). A
`.pck` storing `mod.json` compressed is refused rather than decompressed.

**The namespace rule is the enforcement.** Everything a pack ships must live under
`res://mods/<id>/`; anything else must be in the manifest's `claims`, or the pack
is refused. A mod claiming nothing is mounted with `replace_files` off and
provably cannot touch a shipped file. This is also what stops an author's stale
copy of `vr_hinge.gd` replacing the real one, and `project.binary` /
`global_script_class_cache.cfg` are refused even if claimed.

**Overlays, never edits.** The shipped `const` tables stay the base layer and each
gained a `static var` overlay merged by a small accessor: `SystemModelRegistry`
(plus `validate_row()`, extracted from `model_registry_probe` so probe and loader
share one definition), `SystemInfo`, `ConsolePadArt`, `MediaDimensions`,
`ScreenscraperSystems`, `SpawnCatalog`, `ScenePersistence.PLAIN_SCENES`,
`RetroTV._SHELL_SCENES`, `RoomCatalog`.

**Mod models are deliberately kept out of `ModelWarmer`'s boot warm** and warmed
lazily on first spawn, so boot time is not a function of how many mods are
installed. `stand_in_ids()` / `bespoke_ids()` / `shell_assets()` read `_ROWS`
directly for that reason — do not "fix" them to use `_table()`.

**`RoomCatalog`** (`Scripts/Data/room_catalog.gd`) replaced four hand-synced tables
for one fact: `SceneManager.SCENE_PATHS` / `SCENE_TITLES` / `SLOT_ROOMS` and
`scene_view.gd`'s `ROOM_TITLES`. Those three consts are GONE, not shimmed.

**A mod is never distributed by the app.** No in-app browser, no download, and
netplay sends only a fingerprint (`id@version`) in the existing `_register`
handshake, rejecting a mismatch rather than shipping the pack to the peer. Keep it
that way: a mod is a file the player chose to install, and the moment the app
becomes the transport it owns what is inside one.

`RetroXR/Tests/mod_tests.tscn` is 137 headless checks and needs no mod installed;
fixtures are built into `user://` at run time. Almost none of it mounts anything,
for the reason above.

```bash
python Tools/mods/new_mod.py xenu.snes --name "Super Nintendo"
"$godot" --headless --path RetroXR --script res://Tools/mods/pack_mod.gd -- --id=xenu.snes
"$godot" --headless --path RetroXR res://Tests/mod_tests.tscn -- --only=removal
```

**Mods are authored INSIDE a checkout of RetroXR**, in `RetroXR/mods/<id>/`
(gitignored, and excluded from every export preset). Not a convenience: a `.tscn`
records a `uid` as well as a path, and a uid minted elsewhere does not exist here;
and a stub tree cannot resolve `NetworkManager`, which `RetroSystemModel` needs and
which is an autoload a pack can never add.

**Two invariants that were documented but unenforced, and both were already
broken** — `mod_tests` `consistency/` now checks them. `SystemInfo.media_type` is
read by NOTHING (`MediaDimensions.disc_loader` is what the cabinet uses) and had
drifted: `playstation2` and `playstation_portable` claimed `DISC_INSERT` though a
sliding tray and a hinged UMD door are both `DISC_TRAY`, and `scummvm` claimed
`CARTRIDGE` though it is deliberately a CD system. `DISC_INSERT` means the Wii and
only the Wii.

## Android plugin

`qr-scanner-android/` is a Gradle/Kotlin Godot Android plugin (not a GDExtension, not
built by `Tools/build.py`). Its Godot-side half is `RetroXR/addons/retroxr_qr`. The other
in-repo addon that is ours rather than vendored is `RetroXR/addons/retroxr_build_stamp`,
which writes the `res://build_info.json` that `Scripts/Data/build_info.gd` reads.

## Architecture

### Multi-Instance Design (post-refactor)
Each `Libretro` GDExtension Node owns its own `Wrapper` instance and emulation thread. Multiple `Libretro` nodes can run simultaneously in the same scene, each with a different core/content. This replaced an earlier singleton design.

### Threading Model
Emulation runs on a dedicated `std::thread` owned by `Wrapper`. The main Godot thread communicates with it via a lock-free `ReaderWriterQueue` using a **command pattern** (`ThreadCommand` subclasses: `ThreadCommandCreateTexture`, `ThreadCommandInitAudio`, `ThreadCommandUpdateTexture`). The `Libretro` node's `_process()` drains this queue each frame.

Because libretro callbacks are static C functions, the correct `Wrapper*` is found via a `thread_local` pointer:
```cpp
// Set at emulation thread start, cleared at end:
thread_local Wrapper* t_current_wrapper = nullptr;

// All handlers and Core call:
Wrapper* w = Wrapper::GetCurrentThreadWrapper();
```
ThreadCommands that execute on the main thread carry an explicit `Wrapper*` and call `SetCurrentThreadWrapper` around their work so handler callbacks invoked during Execute() can also resolve the right instance.

### Key Classes (libretro-godot/src/)

- **Wrapper** — Per-instance emulation orchestrator. Owns the emulation thread, all handlers, the command queue, and a back-pointer `Libretro* m_libretro_node`. Exposes `GetCurrentThreadWrapper()` / `SetCurrentThreadWrapper(Wrapper*)` as static helpers for the thread-local pattern.
- **Core** — Dynamically loads a libretro core (`.dll` on Windows, `.so` on Linux/Android,
  `.dylib` on macOS) via `DynLib.hpp`, copies it to a temp directory for isolation, and
  binds all libretro callback function pointers. All callbacks resolve the current wrapper
  via `GetCurrentThreadWrapper()`.
- **Libretro** — The GDExtension Node exposed to GDScript. Instance methods only (`StartContent`, `StopContent`, `SetCoreOption`). Owns a `std::unique_ptr<Wrapper> m_wrapper`. Emits the `options_ready` signal via `NotifyOptionsReady()` (called from Wrapper across the thread boundary using `call_deferred`).

### Handler Subsystems
Each handler is owned by a `Wrapper` instance and manages one libretro subsystem:
- **VideoHandler** — Texture creation/updates, hardware rendering, rotation. It owns the
  HW-render contexts, and there are more than the software/Vulkan/OpenGL trio named
  elsewhere in this file: `VulkanContext` (with a `VulkanContextStub` for platforms
  without it), `D3D11Context` and `D3D12Context` on Windows, and `MacMetalLayer.mm` on
  macOS. `PixelSwizzle.hpp` handles the format conversions between them.
- **AudioHandler** — Audio stream generation and playback
- **InputHandler** — Per-port input state and joypad/mouse/keyboard mapping (Godot keycodes ↔ libretro keycodes). It does **not** read the global Godot `Input` singleton — there is not one reference to it in `InputHandler.cpp`. State is PUSHED in from GDScript, per port: `Libretro.SetJoypadState(port, buttons, alx, aly, arx, ary)` plus `SetMousePosition`/`SetMouseButtons`, `SetKeyState`, `SetLightgunPosition`/`SetLightgunButtons`, `SetPointerIndexState` (multi-touch/IR), `SetAnalogLeft`/`Right`, `SetSensorAccel`/`SetSensorGyro` and `SetPortDevice`. So two `Libretro` nodes in one scene have entirely independent controller state, which is what lets one room hold several machines — and what lets netplay replay a remote peer's port without touching local hardware. The callers are `retro_controller.gd`, `pad_receiver.gd`, `wiimote.gd`, `handheld_input.gd` and `netplay_session.gd`.
- **EnvironmentHandler** — Libretro environment callbacks (system dirs, VFS, disk control)
- **OptionsHandler** — Core option parsing (v1/v2 formats), categorization, persistence
- **MessageHandler** — Notification/message interface
- **LogHandler** — Log callback forwarding
- **RetroAchievements** — `RetroAchievements.cpp/.hpp`, backed by the `external/rcheevos`
  submodule, whose `src/`, `src/rcheevos/`, `src/rapi/` and `src/rhash/` trees are
  compiled straight into the extension (no external dependency). It hashes content by
  RetroAchievements' own console-specific rules rather than by plain file digest. The
  GDScript half lives in `RetroXR/Scripts/Data/ra/` (`ra_config`, `ra_consoles`,
  `ra_session`) and `RetroXR/Scripts/Net/ra/ra_http_bridge.gd`.
- **LinkCoordinator** — `LinkCoordinator.cpp/.hpp` + `LinkInterface.hpp`. A process-wide
  singleton joining two cores on one emulated wire; see §2g. Not per-`Wrapper`, unlike
  everything else in this list.

### Data Flow
```
GDScript UI → Libretro Node (instance) → Wrapper (per-node) → Core + Handlers → Libretro Core (.dll/.so/.dylib)
                                               ↑ ThreadCommand queue (ReaderWriterQueue) ↓
                                         Main thread (_process drains queue)
```

### GDScript Side
- `RetroXR/Scripts/Objects/systems/system.gd` — Per-arcade-cabinet controller. Has `@onready var _libretro: Libretro = $Libretro` wired to a child `Libretro` node in the scene tree.
- `RetroXR/Scenes/Objects/system.tscn` — Cabinet scene. Contains a `Libretro` child node. Its `unique_id` is the value 4000000010, but Godot writes it SIGNED, so the file reads `unique_id=-294967286` — grep for that, not for the decimal above.
- GDExtension registration at `MODULE_INITIALIZATION_LEVEL_SCENE`.

## Dependencies

- **godot-cpp** (submodule, 4.5 branch) — Godot C++ bindings
- **SDL3** — On Windows: core DLL loading (`DynLib.hpp`) + the OpenGL HW-render window. On Linux: the OpenGL HW-render window only (core loading uses `dlopen`); linked against the system `libSDL3.so.0` by soname, headers from `libretro-godot/external/SDL3/`. Not used on Android (`dlopen` + EGL via `DynLib.hpp`).
- **libretro-common** — Reference implementations for VFS, audio conversion, etc. (`libretro-godot/external/libretro-common/`)
- **rcheevos** (submodule, `libretro-godot/external/rcheevos/`) — RetroAchievements support, compiled into the extension. Carries no external dependency of its own.
- **Vulkan-Headers** (submodule, `libretro-godot/external/vulkan-headers/`) — headers for the Vulkan HW-render path.
- **moodycamel::ReaderWriterQueue** — Lock-free SPSC queue for cross-thread communication
- **godot-xr-tools v4.5.1 — FORKED IN PLACE, not a vendored drop-in.** VR locomotion,
  interactions, finger poses (`RetroXR/addons/godot-xr-tools/`). `plugin.cfg` still
  says 4.5.1 and it is no longer that: 30 commits have landed on it here, 59 files,
  +2841/-381, in snap_zone, player_body, the grab driver and pickable teardown —
  the local patch behind `function_pickup._on_grip_pressed` asking a controller
  whether it wants the grip, the snap zone releasing what it holds when it leaves
  the tree, and the `_property_get_revert` returns Godot 4.7 made mandatory.
  **Dropping a fresh upstream copy over this silently reverts all of it**, and the
  symptoms are grabs and teardown, which no headless suite covers. Diff before
  upgrading: `git log --oneline -- RetroXR/addons/godot-xr-tools`.
- **vlc-godot** (libVLC) — the `VlcPlayer` GDExtension; single video backend for both the DVD
  player and the VHS/VCR. Replaced `eirteam.ffmpeg` (dropped 2026-07-14; libVLC also does x265).
- **godot-pdfium** (PDFium) — the `PDFRenderer` GDExtension for rendering PDF pages (books) to
  Godot `Image`s. Prebuilt `libpdfium` from bblanchon/pdfium-binaries.

## Code Conventions

- C++latest standard (MSVC on Windows), C++20 (GCC/Clang/NDK elsewhere)
- Debug logging via `Log`, `LogOK`, `LogWarning`, `LogError` macros
- Libretro option data exposed to GDScript as `LibretroOptionCategory`, `LibretroOptionDefinition`, `LibretroOptionValue` objects
- Callback-based design throughout (video_refresh, audio_sample, input_poll, environment)
- All static libretro callbacks resolve their `Wrapper*` via `Wrapper::GetCurrentThreadWrapper()` — never store a raw global pointer
- `call_deferred` used when Wrapper needs to signal back to the `Libretro` node on the main thread (e.g. `NotifyOptionsReady`)

## Tools

Reusable, out-of-band scripts live in the repo-root `Tools/` (distinct from `RetroXR/Tools/`,
which holds in-editor probe scenes like `netplay_spike`).

What they need is declared in `Tools/requirements.txt` — numpy, pillow, scipy and
the imageio pair — so a fresh checkout does not discover them one ImportError at a
time: `python -m pip install -r Tools/requirements.txt`. Blender's `bpy`/`bmesh`/
`mathutils` are deliberately absent: `Tools/glb/*.py` run inside
`blender --background --python`, never as plain Python.

`RetroXR/imported-assets/` holds the CC BY / CC0 room and prop assets, which carry
LICENSE files and are credited in the About panel. The hardware wears the procedural
stand-ins in `RetroXR/Scenes/Objects/system_models/`.

**Only add 3D assets this project has the right to ship.** Everything in the repo must
be either our own work or licensed for redistribution, with its licence and attribution
carried alongside it.
- **`Tools/download_pdfium.sh`** — fetches prebuilt PDFium from bblanchon/pdfium-binaries into
  `godot-pdfium/external/pdfium/`. All five packages by default (`-p
  linux|win|mac|mac-x64|android` for one, `-r <tag>` to pin a release, `-n` to dry-run).
  Bash, so it runs on Linux, WSL, macOS and Git Bash; it superseded
  `Tools/download_pdfium.ps1`, which had no Linux or macOS platform at all. The `.ps1` is
  still in the tree but is NOT maintained — use the `.sh`. The
  `include/` headers are shared by all packages, so a **partial** run leaves them alone by
  default (`--headers` to force) — new declarations against an unrefreshed binary is how you
  get a link error on the platform you weren't building. Each `lib/<plat>/` carries a `VERSION`
  stamp of the release it came from, and the top-level one belongs to `include/`; they are
  allowed to differ, and the script prints them so you can see when they do.
- **Controller art** — three sources feed the Controls remap diagrams, and the
  licence of each is recorded in `RetroXR/Textures/Controllers/ATTRIBUTIONS.txt`.
  `bake_controller_art.py` bakes the Quest Touch art from a glTF (MIT), because a
  Touch controller's shape cannot be guessed. `gen_gamepad_art.py` DRAWS its pad —
  circles, capsules and a cross on a symmetric body — which keeps the anchors as
  chosen coordinates that cannot drift from a render; it is an Xbox *layout* and
  deliberately not an Xbox, so there is no mark being borrowed. The NES pad is a
  Wikimedia Commons drawing by Fant0men used under **CC BY-SA 3.0** with the
  Nintendo wordmark's eleven paths deleted — the repo's ONLY share-alike asset,
  so it carries two live obligations: the About panel must keep crediting it,
  and the modified file stays CC BY-SA (it does not relicense anything else).
  Its anchors are MEASURED out of a Godot render by
  `Tools/art/nes_pad_anchors.py` (red discs → A/B, black cross → d-pad, black pills →
  Select/Start) rather than chosen. That tool also counts leader-line
  intersections over a sweep of panel sizes, and the count must stay 0.
  ```bash
  python Tools/art/nes_pad_anchors.py RetroXR/probe_out/nes_colour_raw.png
  ```
  **A console pad's art is drawn inside `_draw()`, not parented as a TextureRect**
  — a Control renders its own `_draw()` behind its children, so a child texture
  hides the leader lines and anchor dots. Invisible with line art, whose body is
  nearly transparent; total with a colour illustration.
- **`Tools/gen_gblink_rom.py`** — builds the four Game Boy ROMs the link probes run,
  two at the Game Boy's clock and two at the Game Boy Color's. Ours, so they ship
  freely; the header logo carries only its first four bytes, which is the signature
  a loader matches to decide a file is a Game Boy ROM at all (mGBA refuses one
  without them) and not the artwork.
- **`Tools/glb/decimate_glb.py`** — Blender-headless triangle reduction for a downloaded shell.
  Sketchfab assets arrive subdivided for renders: the Atari 2600 console shipped 1,080,733
  triangles and 57.7 MB, against 27,893 for the NES. **Weld first** — these exports are
  triangle soup (that console was 230,787 disconnected islands, median one triangle), and
  Collapse cannot reduce an isolated triangle, so without the weld the body floors at 54 k
  however low you aim. Also drop the custom split normals and re-derive shading by angle:
  carried through a 98% cut they describe a surface that is gone, which showed up as a smeared
  cartridge slot and starburst facets across flat panels.
  ```bash
  "/c/Program Files/Blender Foundation/Blender 5.1/blender.exe" --background \
    --python Tools/glb/decimate_glb.py -- --in <src>.glb --out <dst>.glb --target 25000
  ```
  `Tools/glb/glb_report.py` dumps a GLB's node tree, world AABBs and triangle budget;
  `Tools/glb/glb_diff.py` compares two and is the check that matters — every model's seat,
  port and jack constant is a hand-measured position in the GLB's frame, so a round trip has
  to preserve names, hierarchy, world placement and image names. Note the GLBs are **Git LFS**,
  so `git show HEAD:<path>` yields a pointer: pipe it through `git lfs smudge` to get a
  baseline to diff against.
