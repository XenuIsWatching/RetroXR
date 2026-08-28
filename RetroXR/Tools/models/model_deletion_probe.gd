extends Node

## Deletion readiness. For every model backed by imported assets, report exactly
## what removing it would take and whether anything still blocks it.
##
## Deleting a model should be: drop its registry row, drop its scene, drop its
## imported files. This proves that per model, and names the exceptions — a script
## shared with a surviving model (must stay), or a reference from somewhere that
## does not go through the registry (must be fixed first).
##
##   godot --headless --path RetroXR res://Tools/models/model_deletion_probe.tscn

const SCAN_DIRS := ["res://Scripts", "res://Scenes", "res://Tools"]

var _blocked := 0


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func(): get_tree().quit(1))
	var sources := _collect_sources()

	# script path -> [model ids using it], so "shared" is a fact not a guess.
	var script_users := {}
	for id: String in SystemModelRegistry.all_ids():
		var sp := _scene_script(SystemModelRegistry._row(id).get("scene", ""))
		if sp.is_empty():
			continue
		if not script_users.has(sp):
			script_users[sp] = []
		script_users[sp].append(id)

	var ready_ids: Array[String] = []
	for id: String in SystemModelRegistry.all_ids():
		var row := SystemModelRegistry._row(id)
		var req: Array = row.get("requires", [])
		if req.is_empty():
			continue                       # nothing imported; nothing to delete
		var scene: String = row.get("scene", "")
		var platform: String = row.get("platform", "")

		# What survives on this platform once the row is gone?
		var others: Array[String] = []
		for other: String in SystemModelRegistry.all_ids():
			if other != id and SystemModelRegistry.platform_of(other) == platform:
				others.append(other)
		var lands: String = others[0] if not others.is_empty() else "<procedural box>"

		# Anything outside the registry that LOADS this scene. Matches the full
		# res:// path, not the basename — a comment naming a scene is not a
		# dependency, and matching loosely reported every model as blocked by its
		# own script's doc comment.
		var refs: Array[String] = []
		if not scene.is_empty():
			for f: String in sources:
				if f == scene or f.ends_with("model_registry.gd"):
					continue
				if sources[f].contains(scene):
					refs.append(f.replace("res://", ""))

		var shared := ""
		var sp := _scene_script(scene)
		if not sp.is_empty() and (script_users[sp] as Array).size() > 1:
			var keep: Array = (script_users[sp] as Array).filter(func(x): return x != id)
			shared = "%s (kept for %s)" % [sp.get_file(), ", ".join(keep)]

		var ok: bool = refs.is_empty()
		if not ok:
			_blocked += 1
		print("[del] %-24s %s" % [id, "READY" if ok else "BLOCKED"])
		print("[del]      delete : %s" % scene.get_file())
		for r: String in req:
			print("[del]               %s" % r.replace("res://imported-assets/", ""))
		if not shared.is_empty():
			print("[del]      keep   : %s" % shared)
		print("[del]      falls to: %s" % lands)
		if not refs.is_empty():
			print("[del]      BLOCKED BY: %s" % ", ".join(refs))
		if ok:
			ready_ids.append(id)

	print("[del] ---")
	print("[del] %d imported models, %d ready to delete, %d blocked"
		% [ready_ids.size() + _blocked, ready_ids.size(), _blocked])
	get_tree().quit(0)


## Root script of a .tscn, read from its text (no need to load the scene).
func _scene_script(scene_path: String) -> String:
	if scene_path.is_empty() or not FileAccess.file_exists(scene_path):
		return ""
	var txt := FileAccess.get_file_as_string(scene_path)
	var i := txt.find('path="res://Scripts/Objects/system_models/')
	if i < 0:
		return ""
	var j := txt.find('"', i + 6)
	return txt.substr(i + 6, j - i - 6)


func _collect_sources() -> Dictionary:
	var out := {}
	for d: String in SCAN_DIRS:
		_walk(d, out)
	return out


func _walk(dir: String, out: Dictionary) -> void:
	var d := DirAccess.open(dir)
	if d == null:
		return
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		var p := dir + "/" + f
		if d.current_is_dir():
			_walk(p, out)
		elif f.ends_with(".gd") or f.ends_with(".tscn"):
			out[p] = FileAccess.get_file_as_string(p)
		f = d.get_next()
	d.list_dir_end()
