extends Node

## Saves and netplay both carry model identity, and both go through
## ScenePersistence. This round-trips a save through it and asserts the hardware
## comes back.
##
##   godot --headless --path RetroXR res://Tools/state/save_restore_probe.tscn

var _fail := 0


func _ready() -> void:
	get_tree().create_timer(90.0).timeout.connect(func(): get_tree().quit(1))
	get_tree().current_scene = self

	var entries := [
		{"id": 0, "type": "system", "systemid": "3ds", "model_id": "n3ds_primitive",
			"position": [0, 0, 0], "rotation": [0, 0, 0]},
		{"id": 1, "type": "system", "systemid": "game_boy", "model_id": "game_boy_primitive",
			"position": [1, 0, 0], "rotation": [0, 0, 0]},
		# No model_id at all: the platform's default. The NES has no model since
		# the imported shells were dropped, so its default is the procedural box —
		# which is exactly the case a save written on an older build restores into.
		{"id": 2, "type": "system", "systemid": "nes",
			"position": [2, 0, 0], "rotation": [0, 0, 0]},
	]
	# What must be STORED on the node (entry 2 has no key, so it stays empty —
	# "empty" is a real value meaning "this platform's default", not a miss).
	var want_id := {0: "n3ds_primitive", 1: "game_boy_primitive", 2: ""}
	# What must actually be WORN, which is the part that matters to the player.
	var want_model := {0: "n3ds_model.gd", 1: "game_boy_model.gd",
		2: "default_model.gd"}

	var sp := ScenePersistence.new()
	sp.instantiate_objects(self, entries)
	for i in range(40):
		await get_tree().physics_frame

	var systems: Array = []
	for n in get_children():
		if n is RetroSystem:
			systems.append(n)
	if systems.size() != entries.size():
		_bad("restored %d systems, expected %d" % [systems.size(), entries.size()])

	for idx in range(systems.size()):
		var sys: RetroSystem = systems[idx]
		var expect: String = want_id[idx]
		if sys.model_id != expect:
			_bad("entry %d: model_id '%s', expected '%s'" % [idx, sys.model_id, expect])
		if sys.get("_model") == null:
			_bad("entry %d: no model instantiated" % idx)
		else:
			var got_model: String = (sys.get("_model") as Node).get_script().resource_path.get_file()
			if got_model != want_model[idx]:
				_bad("entry %d: wearing %s, expected %s" % [idx, got_model, want_model[idx]])
			print("[save] %-14s model_id '%s' -> %s" % [
				sys.systemid, sys.model_id,
				(sys.get("_model") as Node).get_script().resource_path.get_file()])

	# And what goes back out must be the NEW shape.
	var out: Dictionary = sp._serialize_node(systems[0], 0, {})
	if not out.has("model_id"):
		_bad("re-serialized entry has no model_id")
	print("[save] re-serialized model_id=%s" % out.get("model_id", "<none>"))

	print("[save] %s" % ("PASS" if _fail == 0 else "%d FAILURE(S)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


func _bad(m: String) -> void:
	_fail += 1
	print("[save] FAIL " + m)
