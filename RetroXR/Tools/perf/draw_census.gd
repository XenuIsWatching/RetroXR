extends Node
## Draw census: what each spawnable kind costs the renderer, headless.
##
## The mobile renderer issues one draw per visible mesh surface and batches
## nothing, so a room's draw count is the sum of these tables. Each kind is
## instantiated the way the room does it (a system by systemid, so it attaches
## its real model), given a few frames to build, then every MeshInstance3D
## visible in the tree is counted: meshes, surfaces (= draws) and distinct
## materials (the floor a merge can reach - a merge collapses meshes, not
## materials). The top rows are then listed node by node so the movers a merge
## must leave alone can be picked by name.
##
##   godot --headless --path RetroXR res://Tools/perf/draw_census.tscn
##   ... -- --systems=wii,playstation --detail=3

const DEFAULT_SYSTEMS := [
	"wii", "gamecube", "playstation", "super_nes", "nes", "game_boy",
	"game_boy_advance", "nintendo_ds", "playstation_portable", "n3ds",
	"atari_2600", "virtual_boy", "dos",
]
const SCENES := {
	"tv": "res://Scenes/Objects/tv.tscn",
	"composite_cable": "res://Scenes/Objects/cables/composite_cable.tscn",
	"controller_cable": "res://Scenes/Objects/cables/controller_cable.tscn",
	"gc_gba_cable": "res://Scenes/Objects/cables/gc_gba_cable.tscn",
	"gb_link_cable": "res://Scenes/Objects/cables/gb_link_cable.tscn",
	"power_cord": "res://Scenes/Objects/cables/power_cord.tscn",
	"retro_controller": "res://Scenes/Objects/controllers/retro_controller.tscn",
	"nes_controller": "res://Scenes/Objects/controllers/nes/nes_controller.tscn",
	"ps1_dualshock": "res://Scenes/Objects/controllers/playstation/ps1_dualshock.tscn",
	"wiimote": "res://Scenes/Objects/controllers/wii/wiimote.tscn",
	"nunchuk": "res://Scenes/Objects/controllers/wii/nunchuk.tscn",
	"sensor_bar": "res://Scenes/Objects/system_models/wii/sensor_bar.tscn",
	"disc": "res://Scenes/Objects/media/disc.tscn",
	"cartridge": "res://Scenes/Objects/media/cartridge.tscn",
	"memory_card": "res://Scenes/Objects/media/memory_card.tscn",
}
const SETTLE_FRAMES := 12

var _rows: Array = []
var _detail := 4


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		printerr("[census] timed out")
		get_tree().quit(2))
	var systems: Array = DEFAULT_SYSTEMS
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--systems="):
			systems = arg.trim_prefix("--systems=").split(",", false)
		elif arg.begins_with("--detail="):
			_detail = int(arg.trim_prefix("--detail="))
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	for sysid: String in systems:
		var sys: Node = sys_scene.instantiate()
		sys.set("systemid", sysid)
		await _measure("system:" + sysid, sys)
	for kind: String in SCENES:
		var path: String = SCENES[kind]
		if not ResourceLoader.exists(path):
			print("[census] %s: no scene at %s" % [kind, path])
			continue
		var node: Node = (load(path) as PackedScene).instantiate()
		await _measure(kind, node)
	_report()
	get_tree().quit(0)


func _measure(kind: String, node: Node) -> void:
	add_child(node)
	for i in SETTLE_FRAMES:
		await get_tree().process_frame
	var meshes: Array = []
	_collect(node, meshes)
	var surfaces := 0
	var materials: Dictionary = {}
	var per_node: Array = []
	for mi: MeshInstance3D in meshes:
		var n := mi.mesh.get_surface_count()
		surfaces += n
		var mats: Array = []
		for s in n:
			var mat := mi.get_active_material(s)
			var key := mat.get_instance_id() if mat != null else 0
			materials[key] = true
			# Named by resource where the import gave it one, else by instance,
			# so a merge plan can see which siblings already share a material.
			var label := "-"
			if mat != null:
				label = mat.resource_name if not mat.resource_name.is_empty() else "#%d" % key
			mats.append(label)
		per_node.append([n, String(node.get_path_to(mi)), mats])
	per_node.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	_rows.append({"kind": kind, "meshes": meshes.size(), "surfaces": surfaces,
		"materials": materials.size(), "nodes": per_node})
	# A pickable's drop_and_free is the room's own teardown; anything else
	# just goes.
	if node.has_method("drop_and_free"):
		node.call("drop_and_free")
	else:
		node.queue_free()
	for i in 4:
		await get_tree().process_frame


func _collect(node: Node, out: Array) -> void:
	var mi := node as MeshInstance3D
	if mi != null and mi.mesh != null and mi.is_visible_in_tree():
		out.append(mi)
	for child in node.get_children():
		_collect(child, out)


func _report() -> void:
	_rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["surfaces"]) > int(b["surfaces"]))
	print("[census] %-28s %6s %6s %9s" % ["kind", "meshes", "draws", "materials"])
	for r: Dictionary in _rows:
		print("[census] %-28s %6d %6d %9d" % [r["kind"], r["meshes"], r["surfaces"], r["materials"]])
	print("[census]")
	for i in mini(_detail, _rows.size()):
		var r: Dictionary = _rows[i]
		print("[census] -- %s: %d draws over %d meshes" % [r["kind"], r["surfaces"], r["meshes"]])
		var shown := 0
		for entry: Array in r["nodes"]:
			if shown >= 40:
				print("[census]      ... %d more" % (r["nodes"].size() - shown))
				break
			print("[census]   %2d  %s  [%s]" % [entry[0], entry[1], ", ".join(entry[2])])
			shown += 1
