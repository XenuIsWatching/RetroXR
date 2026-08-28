#!/usr/bin/env python3
"""Scaffold a mod, inside a checkout of RetroXR.

    python Tools/mods/new_mod.py xenu.snes --name "Super Nintendo"

Mods are authored INSIDE the game project, under RetroXR/mods/<id>/, and packed
from there. That is not a convenience -- it is the only arrangement in which a
mod's .tscn files resolve correctly.

A scene records both a `uid` and a `path` for every script it references. Author
a scene in a separate project against copied stubs and the uid it records is one
RetroXR has never heard of, so the reference survives only by falling back to
the path. Working-by-fallback is not a foundation.

Copying our scripts into a standalone project does not fix that and cannot: the
one class a console mod must extend, RetroSystemModel, references AvLegend,
ProceduralDiscBay, VRButton, VRSlider and the NetworkManager AUTOLOAD. Autoloads
come from project.godot, which a mod pack cannot add, so a stub tree resolves
everything except the thing that makes it work.

Authoring in the real project makes both problems disappear by construction:
every class, autoload, shader include and .uid is the genuine one.

RetroXR/mods/ is gitignored and excluded from the app's own export, so a mod
being developed here cannot end up inside the shipped build.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
MODS_DIR = REPO / "RetroXR" / "mods"

ID_RE = re.compile(r"^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$")

MOD_MAIN = '''## {name} — a RetroXR mod.
##
## register() is called once, while the room is still being built. Everything a
## mod introduces must be namespaced "{mod_id}:something": model ids, room ids
## and prop types are flat global namespaces that end up in save files.
extends RetroMod


func register(api: ModApi) -> void:
\tapi.log_line("registering")

\t# A prop. The type string is written into save slots, so it is permanent
\t# once anyone has used it -- renaming it orphans every copy in every slot.
\t# api.register_object("{mod_id}:crate", "res://mods/{mod_id}/crate.tscn",
\t# \t{{"label": "Crate"}})

\t# A console. Exactly one of scene/script; `requires` lists assets that must
\t# be present for the row to be offered at all.
\t# api.register_model({{
\t# \t"id": "{mod_id}:console", "platform": "nes", "label": "My Console",
\t# \t"scene": "res://mods/{mod_id}/console.tscn",
\t# }})

\t# Decorate something you cannot edit, as it spawns.
\t# api.on_node_added(&"RetroSystem", func(sys): pass)
'''


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("id", help="mod id, e.g. xenu.snes")
    ap.add_argument("--name", default="", help="display name")
    ap.add_argument("--author", default="", help="your name")
    ap.add_argument("--force", action="store_true", help="overwrite an existing mod")
    args = ap.parse_args()

    mod_id: str = args.id
    if not ID_RE.match(mod_id):
        print(f"error: '{mod_id}' must be lower-case a-z 0-9 . _ - "
              "(it becomes a res:// path segment and a save-file key)")
        return 1

    dest = MODS_DIR / mod_id
    if dest.exists() and not args.force:
        print(f"error: {dest} already exists (use --force)")
        return 1
    dest.mkdir(parents=True, exist_ok=True)

    name = args.name or mod_id
    manifest = {
        "id": mod_id,
        "name": name,
        "version": "0.1.0",
        "author": args.author,
        "description": "",
        "api_version": 1,
        "entry": f"res://mods/{mod_id}/mod_main.gd",
        "priority": 0,
        "claims": [],
    }
    (dest / "mod.json").write_text(json.dumps(manifest, indent=2) + "\n",
                                   encoding="utf-8")
    (dest / "mod_main.gd").write_text(
        MOD_MAIN.format(name=name, mod_id=mod_id), encoding="utf-8")

    rel = dest.relative_to(REPO).as_posix()
    print(f"created {rel}/")
    print("  mod.json")
    print("  mod_main.gd")
    print()
    print("Open RetroXR in Godot and edit it there, so every class, autoload and")
    print("uid resolves. When it is ready:")
    print()
    print(f'  godot --headless --path RetroXR --script res://Tools/mods/pack_mod.gd '
          f'-- --id={mod_id}')
    return 0


if __name__ == "__main__":
    sys.exit(main())
