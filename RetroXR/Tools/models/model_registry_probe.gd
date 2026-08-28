extends Node

## Registry health check. Pure data plus a handful of real spawns; runs in seconds.
##
##   godot --headless --path RetroXR res://Tools/models/model_registry_probe.tscn

var _fail := 0


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func(): get_tree().quit(1))
	get_tree().current_scene = self
	_well_formed()
	_placeholder_is_honoured()
	_invariant()
	await _spawns()
	print("[reg] %s" % ("ALL CHECKS PASSED" if _fail == 0 else "%d FAILURE(S)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


func _bad(msg: String) -> void:
	_fail += 1
	print("[reg] FAIL " + msg)


## Every row names a platform, exactly one of scene/script, and paths that exist.
## Catches typos across the hand-authored rows — the likeliest defect here.
func _well_formed() -> void:
	var n := 0
	for id: String in SystemModelRegistry.all_ids():
		var row := SystemModelRegistry.resolve(id, "")
		if row.get("id", "") != id:
			# resolve() fell back, so the row's own assets are missing on this
			# checkout. Fetch it directly to still check its shape.
			row = SystemModelRegistry._row(id)
		n += 1
		if str(row.get("platform", "")).is_empty():
			_bad("%s has no platform" % id)
		var has_scene: bool = not str(row.get("scene", "")).is_empty()
		var has_script: bool = not str(row.get("script", "")).is_empty()
		if has_scene == has_script:
			_bad("%s must have exactly one of scene/script" % id)
		for k in ["scene", "script"]:
			var p: String = str(row.get(k, ""))
			if not p.is_empty() and not ResourceLoader.exists(p):
				_bad("%s %s missing: %s" % [id, k, p])
		for p: String in row.get("requires", []):
			if not ResourceLoader.exists(p):
				_bad("%s requires missing asset: %s" % [id, p])
	print("[reg] well-formed: %d rows" % n)


## Asking for the placeholder by name must GIVE the placeholder, on every platform
## — including ones that have real models. Getting this wrong silently served the
## imported model to the hallway and to the menu's "Primitive System" row.
func _placeholder_is_honoured() -> void:
	var checked := 0
	for id: String in SystemModelRegistry.all_ids():
		var p: String = SystemModelRegistry.platform_of(id)
		var row := SystemModelRegistry.resolve(SystemModelRegistry.PLACEHOLDER_ID, p)
		if row.get("id", "") != SystemModelRegistry.PLACEHOLDER_ID:
			_bad("placeholder on '%s' resolved to '%s'" % [p, row.get("id", "")])
		checked += 1
	print("[reg] placeholder honoured on %d platforms" % checked)


## Every platform must yield at least one spawnable row — asserted twice, the
## second time with every asset-backed row forced unavailable. That second run is
## the stripped-build simulation, and it is the assertion that protects a release.
func _invariant() -> void:
	var platforms := {}
	for id: String in SystemModelRegistry.all_ids():
		platforms[SystemModelRegistry.platform_of(id)] = true
	for sim in [false, true]:
		SystemModelRegistry.simulate_missing_assets = sim
		var bare: Array[String] = []
		for p: String in platforms:
			var row := SystemModelRegistry.resolve("", p)
			if row.is_empty() or SystemModelRegistry.instantiate(row) == null:
				_bad("platform '%s' resolves to nothing (simulate_missing=%s)" % [p, sim])
			if SystemModelRegistry.rows_for(p).is_empty():
				bare.append(p)
		print("[reg] invariant simulate_missing=%-5s : %d platforms, %d fall to the placeholder%s"
			% [sim, platforms.size(), bare.size(), (" -> " + ", ".join(bare)) if bare else ""])
	SystemModelRegistry.simulate_missing_assets = false


## Real spawns through RetroSystem, driven by model_id as everything now does.
func _spawns() -> void:
	# [systemid, model_id, expected scene file]
	var cases := [["game_boy", "", "game_boy_primitive.tscn"],         # "" = platform default
		["game_boy", "game_boy_primitive", "game_boy_primitive.tscn"],
		["3ds", "n3ds_primitive", "n3ds_primitive.tscn"],
		# Rule 3: an id from a save written before the imported models were
		# deleted. The platform has no rows left, so it lands on the box.
		["playstation", "playstation_original", ""],
		["snes", "", ""]]                       # no model at all -> procedural box
	for c in cases:
		var sys: Node3D = load("res://Scenes/Objects/system.tscn").instantiate()
		sys.set("systemid", c[0])
		sys.set("model_id", c[1])
		add_child(sys)
		if sys is RigidBody3D:
			(sys as RigidBody3D).freeze = true
	for i in range(30):
		await get_tree().process_frame
	var i := 0
	for sys in get_children():
		if not (sys is RigidBody3D):
			continue
		var c: Array = cases[i]
		i += 1
		var model: Node = sys.get("_model")
		var got: String = model.scene_file_path.get_file() if model else "<null>"
		var want: String = c[2]
		var ok: bool = (got == want) if not want.is_empty() else (got == "")
		if not ok:
			_bad("spawn %s:%s -> %s (wanted %s)" % [c[0], c[1], got if got else "<procedural>", want if want else "<procedural>"])
		else:
			print("[reg] spawn %-14s %-10s -> %s" % [c[0], c[1], got if got else "<procedural>"])
