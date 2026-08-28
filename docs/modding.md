# Modding RetroXR

A mod is **one file** dropped in a folder. It can add consoles, whole platforms,
rooms, props, television cabinets and controllers — geometry, procedural animation
and code — or replace something RetroXR ships.

**Nothing here is frozen.** See [Stability](#stability) before you build anything
you intend to maintain.

## Installing one

Put the file in the mods folder and restart:

| platform | folder |
|---|---|
| Windows | `%USERPROFILE%\retroxr\mods\` |
| Linux, macOS | `~/retroxr/mods/` |
| Quest / Android | `/sdcard/Android/data/com.xenu.retroxr/files/mods/` (`adb push`-able) |

Then **OPTIONS → Mods**, enable it, and restart again.

Mods are **disabled when they arrive**. A mod runs with the app's full
permissions — your ROMs, your saves, your RomM credentials, the network — and
Godot has no sandbox to put one in, so nothing loads until you say so. Enabling
is the whole of the trust decision, and it is yours.

RetroXR does not browse, download, host or index mods, and never sends one to
another player. A mod is a file you chose to install, from wherever you chose to
get it, and its contents are between you and whoever made it.

## What a mod looks like

```
xenu.snes.zip
    res://mods/xenu.snes/mod.json        the manifest
    res://mods/xenu.snes/thumbnail.png   optional, shown on the Mods page
    res://mods/xenu.snes/mod_main.gd     the entry script
    res://mods/xenu.snes/...             everything else it ships
```

`.zip` is the recommended format. Godot mounts a zip resource pack exactly as it
does a `.pck`, and a zip can be read member-by-member *without being mounted* —
which is how RetroXR shows you a mod's name, version and thumbnail while it is
still disabled. `.pck` works too, with one limit: its `mod.json` and thumbnail
must be stored uncompressed, or the pack is refused with a message saying so.

### mod.json

```json
{
  "id": "xenu.snes",
  "name": "Super Nintendo",
  "version": "1.0.0",
  "author": "Someone",
  "description": "An SNES, its pad and a cartridge.",
  "api_version": 1,
  "entry": "res://mods/xenu.snes/mod_main.gd",
  "priority": 0,
  "claims": [],
  "platforms": ["Windows", "Linux", "macOS", "Android"]
}
```

- **`id`** — lower-case, `a-z 0-9 . _ -`. Must match the single `res://mods/<id>/`
  folder your pack contains; the loader takes the id from the file list rather
  than trusting the manifest.
- **`api_version`** — see [Stability](#stability).
- **`priority`** — load order, low first; ties broken by id. Only matters when two
  mods touch the same thing.
- **`claims`** — paths **outside** `res://mods/<id>/` your pack writes. Empty is
  the normal case and the safe one.
- **`platforms`** — omit for "everywhere".

There is no field naming the pack file: the manifest is *inside* it.

### The namespace rule

Everything your pack ships lives under `res://mods/<id>/`. A pack containing
anything else is **refused outright** unless that path is in `claims`.

This exists because a resource pack can silently replace any file in the game. A
mod that claims nothing is mounted with replacement switched off and provably
cannot touch a shipped file.

You need a claim only when a subsystem resolves by convention path — system icon
art is the usual case, since `SystemIcons` looks for
`res://Textures/SystemIcons/<systemid>.svg`. The Mods page splits your claims into
those that *add* a new file and those that *shadow* a shipped one, and shows the
second as a warning.

Three files can never be shipped, claimed or not: `project.binary`,
`project.godot` and `.godot/global_script_class_cache.cfg`. A mod exported from
its own Godot project picks these up automatically and any of them would replace
the running game's own — the class cache decides what every `class_name` in
RetroXR resolves to. Strip them, or use the packer below, which excludes them.

## The entry script

```gdscript
extends RetroMod

func register(api: ModApi) -> void:
    api.register_model({
        "id": "xenu.snes:snes",
        "platform": "super_nes",
        "label": "Super Nintendo",
        "scene": "res://mods/xenu.snes/snes.tscn",
        "requires": ["res://mods/xenu.snes/snes.glb"],
    })
```

`register()` is called once, while the room is still being built. A mod that
needs to act later asks for a hook rather than staying resident.

**Ids you introduce must carry your mod's prefix** — `xenu.snes:snes`, not `snes`.
Model ids, room ids and prop types are flat global namespaces that end up written
into save files, so an unprefixed id could collide with a shipped one or with
another mod, and the collision would surface as a save restoring the wrong object.
Registration refuses an unprefixed id.

Every call returns `false` and records a problem rather than throwing. Problems
appear on the Mods page against your mod's name.

## Adding a console

A row is `{id, platform, label, scene | script, handheld?, requires?}` — exactly
one of `scene` or `script`. `requires` lists assets that must be present for the
row to be offered; a row whose assets are missing is hidden rather than broken.

Your model script extends **`RetroSystemModel`**, which is the console extension
point: about forty-five optional virtual methods that `RetroSystem` calls in a
fixed order as it builds the machine. Override what you need and ignore the rest.

The reference implementation is `Scripts/Objects/system_models/nes_model.gd`. It
shows the shape of a detailed console: a GLB instanced as a child named `Shell`,
`Marker3D` seats for ports and cartridges, `VRHinge` / `VRSpringLatchedHinge` /
`VRSlider` for anything that moves, `create_tween()` for scripted travel, a
`PcmOneShot` pool for switch sounds, and `prep_power_light()` for the LED.

Two things you get free by using the shipped widgets rather than animating by
hand: your lid, flap and switches **save and restore automatically** (persistence
walks any spawned object for `VRHinge`/`VRKnob`/`VRSlider` and records them by
node path), and they replicate correctly in a shared room.

### Replacing a shipped console

```gdscript
api.override_model("nes", {...})
```

Replaces the row in place, keeping its id so existing saves still resolve to it.
No file replacement and no claim needed. This is the recommended route.

The alternative — claim a shipped asset path and ship a replacement, e.g. a new
`nes_console.glb` — keeps the shipped logic and swaps only the geometry.

## Adding a whole platform

A console model alone is not a usable platform. `api.register_platform()` takes
the lot and tells you which pieces are missing, because a platform assembled from
four of the six fails much later and far from the cause:

```gdscript
api.register_platform({
    "systemid": "my_console",
    "system_info": load("res://mods/xenu.mod/my_console.tres"),   # SystemInfo
    "models": [ {...} ],
    "pad_art": {...},          # or the Controls remap page has no anchors
    "media": {"cart_size": Vector3(0.09, 0.08, 0.01)},
    "scraper_id": 75,          # or its carts never get art — see below
})
```

Tile art needs no call: ship `res://Textures/SystemIcons/<systemid>.svg` as a
claim and `SystemIcons` finds it.

## Cartridges, discs and scraped art

Three separate things, and only two are yours.

**Sizing** is `api.register_media(systemid, {...})`: `cart_size`, `floppy`,
`disc_diameter`, `disc_finish`, `slot_load`, `front_tray`. The *presence* of
`disc_diameter` is what makes a platform a disc system. Without this your carts
come out a default size and your discs do not exist.

**A real cart model** is optional — with none, the cart is a procedural box sized
from `cart_size`. If you ship a GLB, two rules: the body runs **+Y from the
connector with the label on +Z**, and the swappable label face **must be named
`media_label`** or scraped art never lands on it.

**Scraped art is not yours to ship.** Box, wheel, label and manual art is the
player's own per-ROM data, living outside the game entirely under
`<roms>/<systemid>/media/`, fetched by the in-app scraper. What your platform
needs is to be **mapped**: `api.register_scraper_system(systemid, systemeid)`
against a screenscraper.fr system id. A platform with no mapping can never be
scraped, and the symptom is silent — the carts are simply blank, for ever.

## Rooms, props, cabinets and controllers

```gdscript
api.register_room({"id": "xenu.mod:attic", "path": "res://mods/xenu.mod/attic.tscn",
    "menu_title": "The Attic", "has_slots": true})
api.register_object("xenu.mod:crate", "res://mods/xenu.mod/crate.tscn",
    {"label": "Crate"})
api.register_tv_shell("xenu.mod:portable", "res://mods/xenu.mod/portable.tscn",
    "Portable TV")
api.add_peripherals("nes", [{"label": "My Pad", "spawn": "retro_controller"}])
```

A **room**'s own `.tscn` must set its `XRInit.scene_id` to the same namespaced id.
`has_slots` should be true for a room the player furnishes and false for one whose
contents you authored, or a save slot will restore spawned objects into a room
that already has its own.

A **prop**'s type string is written into save files — permanent once anyone has
used it. Renaming it orphans every copy in every slot.

A **cabinet** extends `RetroTVShell`: geometry plus `Marker3D` seats, while every
functional part stays on the television. Two optional overrides, both defaulting
to doing nothing:

- `screen_shader()` — **null means the stock CRT**, which is what you want unless
  your set genuinely looks different.
- `on_buttons_built(buttons)` — the bezel buttons, so you can adorn them or hang
  your own sounds off them. The stock sets have no button audio at all, so this is
  adding rather than overriding.

A **controller** is simply a scene rooted at `RetroController`. Persistence
already records its scene path and falls back to the generic pad if your mod is
gone; nothing extra is needed.

## Audio and shaders

Ship audio for **your own** hardware and load it yourself — `nes_model.gd` shows
the pattern (a `PcmOneShot` pool and a round-robin voice). There is no mechanism
for replacing a shipped console's sounds, deliberately.

A custom shader is opt-in and never required. Three ways to land:

1. **Do nothing.** Your cabinet gets the same picture every other set has.
2. **Ask for a built-in by name** — `api.shader("crt")`, and likewise `vcr`,
   `static`, `window`, `gameboy_lcd`, `vb_stereo`, `phosphor_decay`,
   `screen_pixel_aa`. You get the resource the game already has loaded, so it
   costs no second compile. Ask by name rather than by path: the shader files are
   free to move.
3. **Write one, reusing ours.** `#include "res://Shaders/crt_filter.gdshaderinc"`
   and `pixel_aa.gdshaderinc` are the tube and pixel-AA stages every shipped
   display shader is built from. Note a `.gdshaderinc` parameter cannot shadow a
   uniform.

Replacing `res://Shaders/crt_effect.gdshader` wholesale is unsupported — it is
`preload`ed, so whether your copy wins depends on load order.

## Attaching to existing code

```gdscript
api.on_node_added(&"RetroSystem", func(sys): ...)   # every console, as it spawns
api.on_scene_content_ready(func(scene_id): ...)     # a room, once it has restored
```

`on_node_added` matches engine classes and `class_name` scripts, and is how you
decorate something without editing it. It is connected only if a mod asks.

Also available and needing nothing from this API: the `"spawned"` group (join it
or your object is not saved), `LoadingOverlay.begin(&"my_mod", ...)` for progress,
`QualityManager.configure_light()` so your lights obey the player's quality
settings, and `JsonStore` with `api.store()` for your own settings file.

## Authoring: work inside a checkout of RetroXR

Clone RetroXR, scaffold your mod inside it, and edit it there:

```bash
python Tools/mods/new_mod.py xenu.snes --name "Super Nintendo" --author "You"
# creates RetroXR/mods/xenu.snes/{mod.json,mod_main.gd}
```

This is not a convenience. It is the only arrangement in which a mod's scenes
resolve correctly, for two reasons:

- **Scenes record a `uid` as well as a `path`** for every script they reference. A
  uid minted in a separate project does not exist in RetroXR, so the reference
  survives only by falling back to the path — and working-by-fallback is not a
  foundation.
- **Copied stubs cannot resolve autoloads.** `RetroSystemModel`, the one class a
  console mod must extend, references `AvLegend`, `ProceduralDiscBay`, `VRButton`,
  `VRSlider` and the `NetworkManager` **autoload**. Autoloads come from
  `project.godot`, which a mod pack cannot add — so a stub tree resolves
  everything except the part that makes it work.

Working in the real project makes both problems vanish by construction: every
class, autoload, shader include and `.uid` is the genuine one.

`RetroXR/mods/` is gitignored and excluded from the app's export presets, so a mod
you are developing cannot end up inside a build of the game.

## Building a pack

```bash
# code, scenes and resources
godot --headless --path RetroXR --script res://Tools/mods/pack_mod.gd -- --id=xenu.snes
```

That writes straight into your mods folder and then **reads the result back
through the loader's own reader**, refusing to finish if the manifest cannot be
found — so a pack that would silently fail to appear in the Mods list fails at
build time instead.

**A mod carrying textures, meshes or audio must go through a real export**, because
those load via `res://.godot/imported/*` artifacts that only an export produces.
Add an export preset whose include filter is `mods/<id>/*` and:

```bash
godot --headless --path RetroXR --export-pack "YourModPreset" xenu.snes.zip
```

`pack_mod.gd` tells you which files it skipped for this reason rather than
producing a pack that is quietly missing its art.

## Stability

**There is none yet, and that is deliberate.** RetroXR is young and moves fast;
the freedom to change internals is currently worth more than a stable mod ABI.
`RetroSystemModel`'s virtuals will keep growing, row shapes may gain fields, and
the classes under `Scripts/Objects/` are fair game.

`api_version` is a **break marker, not a compatibility promise**. It is bumped
whenever something a mod could depend on changes, and the loader refuses a mod
declaring an older one with a message naming what moved. Breakage is loud and
specific rather than silent.

**Expect your mod to break when RetroXR updates.** A mod that stops loading after
an update is the system working as intended, not a bug.

## Limits

- A mod **cannot add a GDExtension**. Mounting a pack does not register native
  code. Mods are GDScript and assets.
- A mod **cannot add an autoload** — `project.godot` is read before any pack is
  mounted.
- A pack **cannot be unmounted**, so enabling or disabling takes effect on the
  next launch.
- Overriding a `preload`ed path is load-order dependent and unsupported.
- Two copies of the same mod are refused, both of them, rather than resolved by a
  rule you cannot see.
- On Quest, remember the mobile renderer: `RetroSystemModel.lamp_glow_supported()`
  is false there, and a tiny light close to a surface renders black or as a flat
  disc. Test on the device.

## What you are responsible for

Everything in your pack is yours. RetroXR does not review, endorse or distribute
mods, and does not check what is in one.

If you intend to share a mod, ship only what you have the right to ship. Console
shells in particular carry wordmarks, logos and trade dress belonging to their
manufacturers. A practical warning from this project's own experience: a mark can
hide in a **normal map** with nothing in the albedo, so open every texture and
render every side before you publish.
