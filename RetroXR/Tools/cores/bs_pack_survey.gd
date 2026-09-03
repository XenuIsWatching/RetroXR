## Lists what is written on every .bs in a folder, so a screenshot can be taken
## of a pack that actually has something interesting on it.
##
##     "$godot" --headless --path RetroXR --script res://Tools/cores/bs_pack_survey.gd -- --dir=<path>
extends SceneTree


func _init() -> void:
	var dir_path := ""
	for a in OS.get_cmdline_user_args():
		if String(a).begins_with("--dir="):
			dir_path = String(a).trim_prefix("--dir=")
	if dir_path.is_empty():
		push_error("need --dir=")
		quit(1)
		return
	var d := DirAccess.open(dir_path)
	if d == null:
		push_error("cannot open " + dir_path)
		quit(1)
		return
	for f in d.get_files():
		if f.get_extension().to_lower() != "bs":
			continue
		var data := FileAccess.get_file_as_bytes(dir_path.path_join(f))
		var progs: Array = BsxPack.programmes_of(data)
		var free: int = BsxPack.free_blocks(data)
		var names := PackedStringArray()
		for p: Dictionary in progs:
			names.append("%s%s" % [str(p.get("name", "?")), str(p.get("blocks", []))])
		print("[bs] %-58s progs=%d free=%d %s" % [f, progs.size(), free, " | ".join(names)])
	quit(0)
