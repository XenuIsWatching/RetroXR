extends Node3D

## Throwaway: loads a room and reports where its GPU memory goes — Godot's own
## VRAM monitors, every SubViewport with its pixel count, and the unique textures
## reachable from the scene's materials, ranked.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##     res://Tools/perf/vram_census_probe.tscn -- --scene=res://Scenes/MainScene.tscn

var _scene_path := "res://Scenes/MainScene.tscn"
var _settle := 12.0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--scene="):
			_scene_path = a.substr(8)
		elif a.begins_with("--settle="):
			_settle = float(a.substr(9))
		elif a.begins_with("--reflcount="):
			ProjectSettings.set_setting(
				"rendering/reflections/reflection_atlas/reflection_count", int(a.substr(12)))
			print("[vram] reflection_count -> %d" % int(a.substr(12)))
		elif a.begins_with("--reflsize="):
			ProjectSettings.set_setting(
				"rendering/reflections/reflection_atlas/reflection_size", int(a.substr(11)))
			print("[vram] reflection_size -> %d" % int(a.substr(11)))
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("[vram] TIMEOUT")
		get_tree().quit(1))
	_run()


func _run() -> void:
	print("[vram] baseline  tex=%.1f MiB  buf=%.1f MiB  total=%.1f MiB" % _mon())
	var packed := load(_scene_path) as PackedScene
	if packed == null:
		print("[vram] could not load %s" % _scene_path)
		get_tree().quit(1)
		return
	var room := packed.instantiate()
	if OS.get_cmdline_user_args().has("--additive"):
		await _additive(room)
		print("[vram] DONE")
		get_tree().quit(0)
		return
	add_child(room)
	get_tree().current_scene = room
	var t := Time.get_ticks_usec()
	var next := 1.0
	while (Time.get_ticks_usec() - t) / 1000000.0 < _settle:
		await get_tree().process_frame
		var el := (Time.get_ticks_usec() - t) / 1000000.0
		if el >= next:
			next += 1.0
			print("[vram]  t=%4.1fs  tex=%7.1f  buf=%6.1f  total=%7.1f MiB" % ([el] + _mon_array()))
	print("[vram] loaded '%s'  tex=%.1f MiB  buf=%.1f MiB  total=%.1f MiB"
		% ([_scene_path] + _mon_array()))

	_viewport_census()
	_texture_census()
	await _ablate(room)
	print("[vram] DONE")
	get_tree().quit(0)


## Remove one suspect at a time and re-read the meter. The delta is what that
## thing was actually holding — cheaper to believe than an estimate.
func _ablate(room: Node) -> void:
	var before: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	for step: Array in [
		["ReflectionProbe", "ReflectionProbe"],
		["OmniLight3D shadows", "OmniLight3D"],
		["TV", "RetroTV"],
		["System", "RetroSystem"],
	]:
		var what: String = step[0]
		var cls: String = step[1]
		for n: Node in room.find_children("*", cls, true, false):
			if what.ends_with("shadows"):
				(n as Light3D).shadow_enabled = false
			else:
				n.queue_free()
		for i in range(6):
			await get_tree().process_frame
		var now: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
		print("[vram] ablate %-22s -> tex=%7.1f MiB  (freed %6.1f)" % [what, now, before - now])
		before = now


## Attribute the cost: detach every top-level child before the room enters the
## tree, then add them back one at a time. Allocation happens on entry, so each
## delta belongs to exactly one child — unlike ablation, which cannot free the
## renderer's shared atlases once they exist.
func _additive(room: Node) -> void:
	var kids: Array[Node] = []
	for c in room.get_children():
		kids.append(c)
	for c in kids:
		room.remove_child(c)
	add_child(room)
	get_tree().current_scene = room
	for i in range(8):
		await get_tree().process_frame
	var prev: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
	print("[vram] empty room root                 tex=%7.1f MiB" % prev)
	for c in kids:
		room.add_child(c)
		for i in range(10):
			await get_tree().process_frame
		var now: float = Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
		if absf(now - prev) >= 0.5:
			print("[vram] + %-34s tex=%7.1f MiB  (+%.1f)" % [c.name, now, now - prev])
		prev = now


func _mon() -> Array:
	return _mon_array()


func _mon_array() -> Array:
	return [
		Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
	]


## Every SubViewport in the tree. A render target costs width*height*bytes for
## colour plus depth, doubled again by MSAA, and it is paid whether or not
## anything is drawing into it.
func _viewport_census() -> void:
	var rows: Array[Dictionary] = []
	var total_px := 0
	for n: Node in get_tree().root.find_children("*", "SubViewport", true, false):
		var sv := n as SubViewport
		var px: int = sv.size.x * sv.size.y
		total_px += px
		rows.append({
			"path": str(sv.get_path()).right(70),
			"size": "%dx%d" % [sv.size.x, sv.size.y],
			"px": px,
			"mode": sv.render_target_update_mode,
			"msaa": sv.msaa_3d,
		})
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["px"] > b["px"])
	print("[vram] %d SubViewports, %.1f Mpx total (~%.0f MiB at RGBA8+depth, before MSAA)"
		% [rows.size(), total_px / 1048576.0, total_px * 8.0 / 1048576.0])
	for r: Dictionary in rows.slice(0, 15):
		print("[vram]   %9s  update=%d msaa=%d  %s"
			% [r["size"], r["mode"], r["msaa"], r["path"]])


## Unique textures reachable from the scene's meshes, by decoded VRAM size.
## compress/mode matters more than file size: a "Lossless" import decodes to
## RGBA8 in VRAM, eight times an ETC2/ASTC one.
func _texture_census() -> void:
	var seen: Dictionary = {}
	for n: Node in get_tree().root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		var mats: Array[Material] = []
		if mi.material_override != null:
			mats.append(mi.material_override)
		if mi.mesh != null:
			for s in range(mi.mesh.get_surface_count()):
				var m := mi.get_active_material(s)
				if m != null:
					mats.append(m)
		for m: Material in mats:
			var bm := m as BaseMaterial3D
			if bm == null:
				continue
			for slot in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL,
					BaseMaterial3D.TEXTURE_ORM, BaseMaterial3D.TEXTURE_ROUGHNESS,
					BaseMaterial3D.TEXTURE_METALLIC, BaseMaterial3D.TEXTURE_EMISSION]:
				var t := bm.get_texture(slot)
				if t == null:
					continue
				var key := t.resource_path if not t.resource_path.is_empty() else str(t.get_instance_id())
				if seen.has(key):
					continue
				seen[key] = {"w": t.get_width(), "h": t.get_height(), "path": key}
	var rows: Array = seen.values()
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["w"] * a["h"] > b["w"] * b["h"])
	var px := 0
	for r: Dictionary in rows:
		px += int(r["w"]) * int(r["h"])
	print("[vram] %d unique material textures, %.1f Mpx (%.0f MiB if RGBA8, %.0f MiB if ETC2)"
		% [rows.size(), px / 1048576.0, px * 4.0 / 1048576.0, px * 1.0 / 1048576.0])
	for r: Dictionary in rows.slice(0, 15):
		print("[vram]   %5dx%-5d  %s" % [r["w"], r["h"], str(r["path"]).get_file()])
