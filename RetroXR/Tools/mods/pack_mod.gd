## pack_mod — build a mod pack out of res://mods/<id>/, and prove it is loadable.
##
##   godot --headless --path RetroXR --script res://Tools/mods/pack_mod.gd -- --id=xenu.snes
##   godot --headless --path RetroXR --script res://Tools/mods/pack_mod.gd -- --id=xenu.snes --out=Z:/xenu.snes.zip
##
## Writes a .zip resource pack, which is the recommended format: Godot mounts one
## exactly as it does a .pck, and it can be read member-by-member WITHOUT being
## mounted, which is how the Mods page shows a disabled mod's name and thumbnail.
##
## SOURCE FILES ONLY. This packs .gd, .tscn, .tres, .json, .gdshader and the like
## verbatim. It is the right tool for a mod that is code and scenes.
##
## A mod carrying textures, meshes or audio must be built by a real Godot export
## instead, because those load through res://.godot/imported/* artifacts that only
## an export produces:
##
##   godot --headless --path RetroXR --export-pack "<preset>" out.zip
##
## with an export preset whose include filter is mods/<id>/*.
##
## Whichever route, the result is read back through ModPackReader before this
## exits. A pack whose manifest the loader cannot find is a mod that silently
## fails to appear in the list, and finding that out at pack time is much cheaper
## than finding it out on a headset.
extends SceneTree

## Never packed, whatever a mod's folder happens to contain. Each of these would
## replace the running game's own copy rather than merely failing.
const FORBIDDEN_NAMES := ["project.binary", "project.godot",
	"global_script_class_cache.cfg", "uid_cache.bin"]

## Packed verbatim. Anything else needs an export to carry its imported form.
const SOURCE_EXTS := ["gd", "tscn", "tres", "json", "txt", "md",
	"gdshader", "gdshaderinc", "uid", "png", "svg"]


func _init() -> void:
	var mod_id := ""
	var out := ""
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--id="):
			mod_id = a.substr(5)
		elif a.begins_with("--out="):
			out = a.substr(6)
	if mod_id.is_empty():
		print("usage: --id=<mod id> [--out=<path>]")
		quit(1)
		return

	var src := "res://mods/%s" % mod_id
	if not DirAccess.dir_exists_absolute(src):
		print("[pack] no such mod: %s" % src)
		quit(1)
		return
	var manifest_path := src + "/mod.json"
	if not FileAccess.file_exists(manifest_path):
		print("[pack] %s has no mod.json" % src)
		quit(1)
		return

	var manifest := ModManifest.parse(JsonStore.read_dict(manifest_path, "pack_mod"))
	if not manifest.error.is_empty():
		print("[pack] mod.json is not usable: %s" % manifest.error)
		quit(1)
		return
	if manifest.id != mod_id:
		print("[pack] mod.json says id '%s' but it lives in mods/%s/"
			% [manifest.id, mod_id])
		quit(1)
		return

	if out.is_empty():
		out = "%s/%s.zip" % [RomLibrary.default_mods_root(), mod_id]
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())

	var members := PackedStringArray()
	_collect(src, members)
	if members.is_empty():
		print("[pack] nothing to pack in %s" % src)
		quit(1)
		return

	var z := ZIPPacker.new()
	var err := z.open(out)
	if err != OK:
		print("[pack] cannot write %s (error %d)" % [out, err])
		quit(1)
		return
	var skipped := PackedStringArray()
	var packed := 0
	for path: String in members:
		var base := path.get_file()
		if FORBIDDEN_NAMES.has(base):
			skipped.append(path + "  (would replace the game's own)")
			continue
		if not SOURCE_EXTS.has(path.get_extension().to_lower()):
			skipped.append(path + "  (needs an export to carry its imported form)")
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f == null:
			skipped.append(path + "  (unreadable)")
			continue
		var data := f.get_buffer(f.get_length())
		f.close()
		# Stored without the res:// prefix, which is how a zip resource pack is
		# laid out and what ModPackReader expects.
		z.start_file(path.trim_prefix("res://"))
		z.write_file(data)
		z.close_file()
		packed += 1
	z.close()

	for s: String in skipped:
		print("[pack] skipped %s" % s)
	print("[pack] wrote %s (%d files)" % [out, packed])
	quit(0 if _verify(out, manifest) else 1)


## Walk the mod's folder. Uses DirAccess rather than a res:// glob so it also
## works on a folder that has not been imported yet.
func _collect(dir_path: String, into: PackedStringArray) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			_collect(full, into)
		else:
			into.append(full)
		name = dir.get_next()
	dir.list_dir_end()


## Read the finished pack back the way the loader will. This is the check that
## matters: everything above can succeed and still produce a pack the Mods page
## never shows.
func _verify(path: String, manifest: ModManifest) -> bool:
	var r := ModPackReader.open(path)
	if not r.error.is_empty():
		print("[pack] FAILED verification: %s" % r.error)
		return false
	var files := r.files()
	var found := ModManifest.parse(r.read_json(manifest.own_root() + "mod.json"))
	r.close()
	if not found.error.is_empty():
		print("[pack] FAILED verification: manifest unreadable: %s" % found.error)
		return false
	if found.id != manifest.id:
		print("[pack] FAILED verification: manifest id changed in the pack")
		return false
	var inventory := manifest.inventory_error(files)
	if not inventory.is_empty():
		print("[pack] FAILED verification: the loader would refuse this pack: %s"
			% inventory)
		return false
	if not ResourceLoader.exists(manifest.entry) and not files.has(manifest.entry):
		print("[pack] FAILED verification: entry script %s is not in the pack"
			% manifest.entry)
		return false
	print("[pack] verified: the loader can read %s %s"
		% [manifest.id, manifest.version])
	return true
