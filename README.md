# RetroXR

**[retroxr.app](https://retroxr.app)** — how to install it, how to play it, and the devlog.

A VR retro-gaming room in Godot 4: real emulated hardware you pick up, plug in and
play with, driven by libretro cores.

The goal is for this to be an open project aimed at recreating what it was like to own a
console at the time, forgoing all the emulation windows and setup hassle.
You just spawn the consoles, TVs, and cartridges, and pop everything together naturally.
This means plugging in the AV cables, plugging in the disc or cartridge, and plugging in
the controller as well.

Right now, all models of consoles just have primitive stand-ins. These are just gray or
red boxes.
**If you are a modeller and can help out, please do! Just note that all models must be**
**free of any trademarked text or images.**

This project also aims to be the same for DVDs, VHS, CDs, cassettes, and books/magazines.
Just copy over your book, DVD image, video file, or audio file to the directory via the
web interface and you're good to go!

This project also supports RomM connections. Generate an API key from your RomM server,
and even scan the QR code to link it from your Quest with the external camera!

This has the Meta XR Audio SDK integrated as well, so for any sound you hear you can
always tell where it's coming from thanks to the HRTF processing.

There is netplay as well with a roll-back netcode, but it is very untested!

## Libretro Cores

### Downloader

Each platform can have multiple cores. Select the one you want. For some there's a highly
recommended core — for example, the Azahar core supports stereoscopic imaging in VR.

<img src="docs/images/cores_scrolled.png" width="640" alt="The core Downloader: the CORES tab's Download view, a scrollable grid of systems with the number of available cores for each." />

### Manager

Select the default core for each platform in here. Also set or reset core options.

<img src="docs/images/cores_manager.png" width="640" alt="The core Manager: pick a system to set the default core it launches with, shown as a grid of systems each labeled with its currently selected core." />

### BIOS / Extra

Manage and see if any BIOS are required or optional. If RomM is set up, it can download
them from there.

<img src="docs/images/cores_bios.png" width="640" alt="The BIOS / Extras overview: a grid of systems, each showing its BIOS status (e.g. complete, a number of optional files, or required files missing)." />

<img src="docs/images/cores_bios_psx.png" width="640" alt="The BIOS / Extras view for PlayStation, listing the PS1 BIOS files (scph5500/5501/5502.bin and psxonpsp660.bin) with their required/optional status and per-file download buttons." />

### Forked cores

Most cores come from libretro's buildbot unmodified. These eight are forks, because
RetroXR needs something the upstream core does not do — mostly carrying a link cable
between two cores in one process, which has no upstream equivalent. Each links to the
branch RetroXR builds from.

| Core | Branch | What the fork adds |
| --- | --- | --- |
| [gambatte](https://github.com/XenuIsWatching/gambatte-libretro/tree/retroxr) | `retroxr` | Game Boy link cable over the frontend's link bus, and three savestate fixes — a lossy `ppu.endx` restore, an uninitialised `rambankMode`, and frame duplication that slipped a reloaded state one frame against the run it came from. |
| [mGBA](https://github.com/XenuIsWatching/mgba/tree/retroxr) | `retroxr` | Link cable for its Game Boy driver as well as its GBA one (separate cores, separate serial ports), normal-mode multi-player, a GameCube port on the bus, and an RCNT/SIOCNT mirror that was stale at serialize time. |
| [PCSX-ReARMed](https://github.com/XenuIsWatching/pcsx_rearmed/tree/retroxr) | `retroxr` | An emulated SIO1 serial port and the PlayStation link cable over the link bus, plus memory cards that can be ejected and reinserted while running. |
| [Dolphin](https://github.com/XenuIsWatching/dolphin/tree/retroxr) | `retroxr` | GameCube-to-GBA over the link bus, Wiimote IR passthrough, gyroscope and Nunchuk accelerometer, deterministic mode for netplay, real memory cards per slot, and Vulkan semaphore propagation. |
| [Azahar](https://github.com/XenuIsWatching/azahar/tree/libretro-stereo-options) | `libretro-stereo-options` | `render_3d` / `factor_3d` core options, so the 3DS core's stereoscopy can be driven from VR. |
| [Play!](https://github.com/XenuIsWatching/Play-/tree/retroxr) | `retroxr` | Takes its data directory from the frontend instead of assuming `/sdcard` (which is not writable on a Quest), and covers the pixels the GS samples when rasterising a sprite, which left vertical seams. |
| [Snes9x](https://github.com/XenuIsWatching/snes9x/tree/retroxr) | `retroxr` | The Satellaview's 8M Memory Pack as a memory region of its own rather than borrowing the BS-X cartridge's PSRAM id, an empty pack slot the shell can detect instead of always believing a pack is inserted, the ACCESS lamp through the LED interface, and a subsystem load that takes its directory from the cartridge — without which the BS-X looked for its satellite stream at the root of a drive and reported no signal. |
| [mupen64plus-next](https://github.com/XenuIsWatching/mupen64plus-libretro-nx/tree/retroxr) | `retroxr` | Booting a bare 64DD disk with no cartridge, which the core could already do but no code path could reach — plus the NULL/`SIZE_MAX` memory descriptor a cartridge-less boot handed the frontend, and a block-number mix-up in the 64DD disk format scan. |

## Objects

### System

Spawn a system for any platform you have at least one libretro core for. In here you can
spawn controllers, peripherals, and the console itself by selecting them.

<img src="docs/images/obj_console_cart.png" width="480" alt="A console stand-in: a grey box with a RESET button, a green START button, four numbered controller ports, and a cartridge seated in the top slot." />

### Cartridge

Spawn a Cartridge which is linked to a supported file for the platform.

### DVD player

Like the VCR, the DVD player renders onto a connected TV through the in-tree `vlc-godot`
GDExtension — the same [libVLC](https://www.videolan.org/vlc/libvlc.html)-backed `VlcPlayer`
is the single video backend for both. VLC's bundled `libdvdnav`/`libdvdread` plugins give it
real disc menus and chapter navigation.

The packaged libVLC backend currently ships on Windows, Linux and Android, not macOS.

1. Drop DVD images into the `dvd/` folder (next to `roms/`, `books/` and `videos/`):
   - Windows: `%USERPROFILE%\retroxr\dvd`
   - Linux / macOS: `~/retroxr/dvd`
   - Quest/Android: `/sdcard/Android/data/com.xenu.retroxr/files/dvd`
   - Supported: a folder containing a `VIDEO_TS/` directory, or a standalone `.iso` / `.img` file.
2. Open the spawn menu (`Tab`), go to the **DVDs** tab, and click a title to spawn a
   **DVD disc** carrying that image's path (like a VHS tape carries a video path).
3. From the **Objects** tab, spawn a **DVD Player** and a **TV**.
4. Plug the DVD player's cable into the TV (same cable/plug the emulator systems and VCR use).
5. Insert the disc into the player's slot, then press **Play** — inserting alone never
   auto-starts playback.

On-unit buttons: **PLAY**, **PAUSE**, **STOP**, **EJECT**, **|&lt;&lt;** / **&gt;&gt;|**
(previous / next chapter), **&lt;&lt;** / **&gt;&gt;** (rewind / fast-forward scan), **MENU**
(return to the disc's root menu), a **UP** / **DOWN** / **LEFT** / **RIGHT** / **SEL** cluster
for navigating disc menus, and **LANG** / **SUB** to cycle audio and subtitle tracks. Point at
the player and press the menu button to open a floating panel that picks audio/subtitle tracks
by name.

As with the VCR, the video renders onto the connected TV's screen, and the TV's volume/power
buttons drive the DVD player's audio and screen just like a system.

<img src="docs/images/obj_dvd.png" width="480" alt="The DVD player stand-in: a black deck with a disc slot and on-unit buttons — PLAY, PAUSE, STOP, LANG, SUB, MENU, rewind/fast-forward, previous/next chapter, EJECT, and a LEFT/RIGHT/UP/DOWN/SEL cluster for disc menus." />

### Books / Magazines

Books and magazines are physical objects you pick up and read by turning the pages with your
hands. Pages are rendered from the file by the in-tree `godot-pdfium` GDExtension — a
[PDFium](https://pdfium.googlesource.com/pdfium/)-backed `PDFRenderer` that rasterises each
page to a texture (asynchronously, and cached to disk so re-opening a book is instant).

1. Drop books into the `books/` folder (next to `roms/`, `dvd/` and `videos/`):
   - Windows: `%USERPROFILE%\retroxr\books`
   - Linux / macOS: `~/retroxr/books`
   - Quest/Android: `/sdcard/Android/data/com.xenu.retroxr/files/books`
   - Supported: `.pdf` and `.cbz` (a ZIP of `.jpg`/`.png`/`.webp` page images). CBR and loose
     image files are not listed.
2. Open the spawn menu (`Tab`), go to the **Books** tab, and click a title to spawn it — the
   book drops straight into the hand that clicked. (Scraped game manuals also spawn from the
   📖 button on a ROM's row in the **Cartridges** tab.)
3. Turn the pages:
   - **VR**: hover a controller over a page's outer edge, hold the **trigger**, and drag the
     page across — release past halfway to complete the turn, or short of it to let it spring
     back. Or, holding the book one-handed, poke the far edge with your other hand and squeeze
     **grip** to flip.
   - **Desktop**: with the book held, `E` = next page, `Q` = previous page.
4. Point at the book and press the menu button to open **Book Settings**: a size slider
   (0.5×–2.5×) and a "half pages" toggle that splits scanned two-page spreads down the middle.

Set a book down on any shelf or desk to leave it out, and pick it back up with grip (VR) or
the pointer ray.

<img src="docs/images/book_flip.gif" width="480" alt="Animated demo of turning a page: a hand grabs the outer edge of the page and drags it across, and the page folds over to reveal the next spread." />

### Video player (VCR)

Besides emulator systems, the arcade room can play video files on the same TVs, driven by
the in-tree `vlc-godot` GDExtension — a [libVLC](https://www.videolan.org/vlc/libvlc.html)
backed `VlcPlayer`. It is the single video backend for both the VCR and the DVD player,
and it handles x265/HEVC.

The packaged libVLC backend currently ships on Windows, Linux and Android, not macOS.

1. Drop video files into the `videos/` folder (next to `roms/` and `books/`):
   - Windows: `%USERPROFILE%\retroxr\videos`
   - Linux / macOS: `~/retroxr/videos`
   - Quest/Android: `/sdcard/Android/data/com.xenu.retroxr/files/videos`
   - Supported: `.mp4`, `.mkv`, `.avi`, `.webm`, `.mov`
2. Open the spawn menu (`Tab`), go to the **Videos** tab, and click a video to spawn a
   **VHS tape** carrying that file's path (like a cartridge carries a ROM path).
3. From the **Objects** tab, spawn a **VCR** and a **TV**.
4. Plug the VCR's cable into the TV (same cable/plug the emulator systems use).
5. Insert the tape into the VCR's slot, then use the on-unit buttons:
   **Play**, **Pause**, **Stop** (eject/blank), **&lt;&lt;** (rewind), **&gt;&gt;** (fast-forward).

The video renders onto the connected TV's screen, and the TV's volume/power buttons
control the VCR's audio and screen just like a system.

<img src="docs/images/obj_vcr.png" width="480" alt="The VCR stand-in: a black deck with a tape slot, a glowing counter/clock display, and PLAY, PAUSE, STOP, rewind, fast-forward and EJECT buttons." />

### TV remote

Spawn a **TV Remote** from the spawn menu's **Objects** tab. While held, point it at a
TV, VCR, DVD player, or CD/cassette deck — the target is outlined maroon and a small menu
pops up above the remote:

- **TV**: `POWER` / `VOL −` / `MUTE` / `VOL +`
- **VCR**: `EJECT` / `PLAY` / `PAUSE` / `STOP` / `FF` / `REW`
- **DVD player**: `EJECT` / `PLAY` / `PAUSE` / `STOP` / `FF` / `REW`, chapter skip
  (`|<<` / `>>|`), `MENU` and a `UP` / `DOWN` / `LEFT` / `RIGHT` / `OK` cluster for the
  disc's own menus, and `AUDIO` / `SUB` track cycling. Menu-navigation cells light up only
  while a disc menu is showing; `AUDIO` / `SUB` only during playback.
- **CD / cassette deck**: `PLAY` / `PAUSE` / `STOP` / `FF` / `REW`, plus track skip
  (`|<<` / `>>|`) on the CD player (a cassette can't skip tracks, so those cells stay greyed).

On the remote itself `PLAY`/`PAUSE` is a single cell whose icon toggles with playback state,
and the buttons show as icons rather than text — the word labels above are how each action
reads on the TV's on-screen display.

**VR**: flick the thumbstick up/down to move the selection, press the primary button
(`A`/`X`) or click the thumbstick to activate.

**Desktop**: the remote snaps to the lower-right corner aiming where you look (like the
light gun). `Arrow Up`/`Arrow Down` move the selection, `Enter` activates, and — because
it is FPS-snapped — dropping it requires **`Ctrl` + Left-click** (plain click won't drop it).

<img src="docs/images/obj_remote.png" width="310" alt="The TV remote, held in a hand, with its floating command menu popped up above it: eject, a D-pad with a centre OK, transport buttons, a menu button, and audio/subtitle cells." />

## Development

### Building

Almost everything interesting here is C++. Six GDExtensions have to be compiled
before the Godot project will run — a fresh clone has the sources but not the
libraries. Miss one and Godot says so on startup, then every scene using its types
fails to parse:

```
ERROR: GDExtension dynamic library not found: 'res://verlet-rope/verlet_rope.gdextension'.
SCRIPT ERROR: Parse Error: Could not find type "VerletRope" in the current scope.
```

| Extension | Provides | Built from | Deploys to |
|---|---|---|---|
| `libretro-godot` | `Libretro` — runs the emulator cores (submodule) | repo root | `RetroXR/libretro-godot/` |
| `archive-godot` | `RommArchiveExtractor` — streams ZIP members to disk | `archive-godot/` | `RetroXR/archive-godot/` |
| `verlet-rope` | `VerletRope` — the simulated cables | `verlet-rope/` | `RetroXR/verlet-rope/` |
| `vlc-godot` | `VlcPlayer` — video for the VCR and DVD player | `vlc-godot/` | `RetroXR/vlc-godot/` |
| `godot-pdfium` | `PDFRenderer` — renders manual pages | `godot-pdfium/` | `RetroXR/godot-pdfium/` |
| `metaxr-audio` | HRTF spatial audio on Quest | `metaxr-audio/` | `RetroXR/metaxr-audio/` |

**Each needs its own `scons` invocation.** They share the `godot-cpp` submodule, and
godot-cpp's `SConstruct` can only run once per process, so a single scons run can never
cover two of them. Each also has its own `VariantDir('Temp')`, which is why each builds
from its own directory — except `libretro-godot`, whose SConstruct is the repo root's.

#### Prerequisites

```bash
git submodule update --init --recursive     # godot-cpp, libretro-common, vulkan-headers
pip install --user scons                    # ensure the Scripts/bin dir is on PATH
```

Plus a compiler: **MSVC** on Windows, **GCC/Clang** on Linux, **Xcode command-line
tools** on macOS, or the **Android NDK** for Quest (set `ANDROID_NDK_ROOT`;
`ANDROID_HOME` must be *empty*, not unset, or godot-cpp looks for a full SDK).

Every third-party binary these link against is already committed — including PDFium for
Windows, Linux, Android and both macOS architectures. **libVLC on Linux** links the system
library (Fedora: `vlc-devel` to build, `vlc-libs` to run). macOS currently builds
libretro-godot, archive-godot, verlet-rope and godot-pdfium; vlc-godot has no packaged Mac runtime and
Meta publishes its audio blob only for Windows and Android, so those two are skipped.

#### One command

```bash
python Tools/build.py windows                 # all six, debug + release
python Tools/build.py android --target release
python Tools/build.py linux --only vlc-godot
python Tools/build.py macos                      # host architecture (arm64 on Apple Silicon)
python Tools/build.py macos --arch x86_64        # Intel Mac binaries
python Tools/build.py windows --jobs 8 -- verbose=yes    # extra args go to scons
```

It builds one shared, trimmed `godot-cpp` library per target, then runs every eligible
extension build in sequence, prints a pass/fail table, and exits non-zero if any failed.
Architecture follows the platform: `x86_64` for Windows and Linux, `arm64` for Android,
and the host architecture for macOS. Mac builds target macOS 13.0 by default; build each
architecture separately when both are needed. Libretro Vulkan hardware rendering on macOS
uses the MoltenVK runtime embedded in official Godot builds.

Asking for `linux` **from Windows** re-invokes the script inside WSL (`--distro`, default
`Ubuntu`) with `HOME` and `PATH` reset — WSL inherits the Windows environment, whose PATH
contains spaces and breaks a bare `export PATH="$HOME/.local/bin:$PATH"`. From Linux it
just builds. *(scons is not currently installed in either WSL distro here; `pip install
--user scons` inside the distro first.)*

#### Or one at a time

```bash
scons platform=windows arch=x86_64 target=template_debug          # libretro-godot, from the root
cd archive-godot && scons platform=macos arch=arm64 target=template_debug macos_deployment_target=13.0
cd verlet-rope && scons platform=linux arch=x86_64 target=template_release
cd godot-pdfium && scons platform=android arch=arm64 target=template_debug ANDROID_HOME=
scons platform=macos arch=arm64 target=template_debug macos_deployment_target=13.0
```

Each writes a `lib<name>.<platform>.<target>.<arch>.so`, `.dll` or `.dylib` next to the
`.gdextension` file that points at it.

#### Exporting

`RetroXR/export_presets.cfg` is committed, so the `Quest` and `Windows Desktop`
presets come with the clone and a headless export works straight away:

```bash
"$godot" --headless --path RetroXR --export-release "Quest" RetroXR.apk
```

There is not yet a committed macOS export/signing preset; the Mac work above supports
editor/runtime development and produces both architectures' GDExtensions. A future
hardened export must permit downloaded unsigned cores and executable callback trampolines;
dynamic-recompiler cores may additionally need the JIT entitlement.

Signing is the one thing you have to supply yourself. Since Godot 4.5 the keystore
path, user and password live in `RetroXR/.godot/export_credentials.cfg`, which is not
committed (`.godot/` is ignored wholesale). Set yours in the editor under *Project →
Export → Android → Keystore*, or for CI pass them as environment variables
(`GODOT_ANDROID_KEYSTORE_RELEASE_PATH` / `_USER` / `_PASSWORD`) so they can come from
repo secrets rather than a file.

Three fields in the preset are shared state, and are worth knowing about before you
commit a change to it:

- **`custom_features` must stay empty.** A feature tag there pairs with a
  `run/main_scene.<tag>` override in `project.godot` and reroutes the boot scene for
  *every* APK exported from the tree, not just yours. It is the standard way to boot a
  probe scene locally; just don't commit it.
- **`gradle_build/target_sdk="32"`** overrides the Android template's default of 36
  (`RetroXR/android/build/config.gradle`). Quest needs `min_sdk` 29 and Meta requires a
  target of 32 or higher. Verify on device before raising it.
- **`version/code` / `version/name`** are the shipped release numbers. Bump them
  deliberately; two people bumping in parallel conflict.

The Meta feature flags are gated twice: `meta_xr_features/*` in the preset only reaches
the manifest if the matching `xr/openxr/extensions/*` setting is on in `project.godot`.
Hand tracking and passthrough are on; eye, face and body tracking are off in both
places. Check the generated `RetroXR/android/build/src/debug/AndroidManifest.xml` after
an export to see what actually landed.

#### Releasing

`.github/workflows/release.yml` does the whole thing on a `v*` tag: builds the six
GDExtensions for Android and Windows, exports the signed `Quest` APK and the Windows
desktop build, publishes a GitHub Release with both attached, and points the SideQuest
listing at the new APK.

```bash
# bump BOTH in RetroXR/export_presets.cfg, then commit
#   version/code=5
#   version/name="0.2.1"
git tag v0.2.1 && git push --tags
```

The tag must match `version/name`, and `version/code` must be higher than the previous
tag's — SideQuest refuses a build whose versionCode is not greater than the one already
listed. A `preflight` job checks both in seconds so a mismatch fails before the
half-hour build rather than after it.

Running it from the Actions tab instead (**Run workflow**) builds everything and
uploads the APK and Windows zip as run artifacts, without creating a release or
touching the listing. That is the way to test a build; tick `publish` / `notify` only
when you mean it.

Signing comes from three repo secrets — `ANDROID_KEYSTORE_BASE64` (the `.keystore`
base64'd), `ANDROID_KEYSTORE_USER`, `ANDROID_KEYSTORE_PASSWORD` — which CI feeds to
Godot through `GODOT_ANDROID_KEYSTORE_RELEASE_*`, so no `export_credentials.cfg` is
ever written. It has to be the same keystore you sign with locally or the APK will not
install over an existing one.

`.github/workflows/sidequest.yml` remains the fallback for a release published by hand
in the web UI. A release created by CI does not fire it — GitHub does not emit
`release: published` for a release created with `GITHUB_TOKEN` — which is why
`release.yml` calls SideQuest's version-webhook itself.

## Desktop mode controls

When no VR headset is detected, RetroXR falls back to a desktop mode with mouse/keyboard controls.

**Movement / camera**
- `WASD` — move
- Mouse — look
- `Ctrl` (hold) — crouch
- `Caps Lock` (hold) — walk (move slower, finer-grained control)

**Interaction**
- Left-click — grab/pick up object under cursor (or shoot, if holding the light gun)
- `Ctrl` + Left-click — drop held object (required for FPS-snapped objects: light gun,
  TV remote; plain click also drops everything else)
- Scroll wheel — push/pull held object along view ray (disabled while FPS-snapped)
- Middle-mouse drag — rotate held object in place
- `Tab` — toggle spawn menu

**Retro joypad** (when a Libretro node has input focus)
- D-pad: `W`/`A`/`S`/`D`
- Face buttons: Numpad `1`=B, `2`=A, `3`=Y, `4`=X
- Shoulders: `L`=`Q`/`R`/Numpad3, `R`=`E`/`Y`/Numpad6
- Triggers: `L2`=`Z`, `R2`=`X`
- Stick clicks: `L3`=`C`, `R3`=`V`
- `Shift`=Select, `Enter`=Start
- Left stick: `T`/`G`/`F`/`H` (up/down/left/right)
- Right stick: `I`/`K`/`J`/`L` (up/down/left/right)

## Licensing

Copyright (C) 2026 Ryan McClelland.

RetroXR is licensed under the **GNU General Public License, version 3** — see
[LICENSE](LICENSE) — with one additional permission, in
[LICENSE-EXCEPTION.md](LICENSE-EXCEPTION.md), allowing the program to be linked
against Meta's proprietary XR Audio SDK and the Oculus-SDK-licensed parts of the
godot-openxr-vendors Meta plugin. Those components remain licensed to you by Meta
under the [Oculus SDK License Agreement](https://developers.meta.com/horizon/licenses/oculussdk/),
not under the GPL.

The `libretro-godot` GDExtension is a separate submodule under the MIT licence.
It began as a fork of SK.Libretro.Godot by SKurdt.

Bundled third-party libraries and assets keep their own licences — MIT, BSD,
Apache-2.0, zlib, LGPL-2.1 (libVLC), GPL-2.0+ (several VLC plugins), CC0 and
CC BY 4.0. Several of the 3D models are CC BY and **attribution is a licence
condition**: the full credit list is in the app under OPTIONS → ABOUT, and each
asset directory carries its own `LICENSE-*` file.

The controller you see in your hands is supplied by the XR runtime at runtime
(OpenXR render models), so no headset vendor's controller art is shipped here.
