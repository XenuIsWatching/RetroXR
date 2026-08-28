extends Node3D

const SPAWN_MENU_CONTROLLER := preload(
	"res://Scripts/UI/spawn_menu/spawn_menu_controller.gd")
const VIEWPORT_2D_IN_3D := preload(
	"res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")
const SPAWN_MENU := preload("res://Scenes/UI/spawn_menu.tscn")
const CASES := [
	{
		"label": "NEMA 1-15P to C7 Cable",
		"scene": "res://Scenes/Objects/cables/nema_1_15_to_c7_cord.tscn",
	},
	{
		"label": "Polarized NEMA 1-15P to C7P Cable",
		"scene": "res://Scenes/Objects/cables/nema_1_15_polarized_to_c7_polarized_cord.tscn",
	},
]

var failures := 0


func _ready() -> void:
	# Assemble only the production controller and its real 2D-in-3D menu. Using
	# player_rig.tscn here would also start SceneManager and restore the user's
	# last room, which is unrelated to this probe.
	# "test" is an authored, slotless room id, so the controller also skips its
	# startup slot restore without changing the user's persisted preference.
	SceneManager.current_scene_id = "test"
	var controller := Node3D.new()
	controller.name = "SpawnMenuController"
	controller.set_script(SPAWN_MENU_CONTROLLER)
	var menu_viewport := VIEWPORT_2D_IN_3D.instantiate() as XRToolsViewport2DIn3D
	menu_viewport.name = "SpawnMenuViewport"
	menu_viewport.scene = SPAWN_MENU
	controller.add_child(menu_viewport)
	add_child(controller)

	# The controller connects after Viewport2DIn3D instantiates its Control
	# scene. Press the actual generated rows rather than calling its handler.
	for i in 4: await get_tree().process_frame
	for test: Dictionary in CASES:
		var button := _button_named(controller, str(test["label"]))
		_check(button != null, "Objects row exists: %s" % test["label"])
		if button == null:
			continue
		var before := get_tree().get_nodes_in_group("spawned").size()
		button.pressed.emit()
		await get_tree().process_frame
		await get_tree().physics_frame
		var spawned := get_tree().get_nodes_in_group("spawned")
		_check(spawned.size() == before + 1,
			"row spawns exactly one object: %s" % test["label"])
		if spawned.size() <= before:
			continue
		var obj := spawned[-1] as Node3D
		_check(obj.scene_file_path == test["scene"],
			"row maps to %s" % test["scene"])
		_check(obj.get_node_or_null("WallPlug") is PowerPlug,
			"spawned cord has a wall plug")
		_check(obj.get_node_or_null("AppliancePlug") is PowerPlug,
			"spawned cord has an appliance plug")
		var rope := obj.get_node_or_null("VerletRope") as VerletRope
		_check(rope != null and rope.ribbon_count == 2,
			"spawned cord retains its two-conductor ribbon")
		obj.queue_free()
		await get_tree().process_frame
	print("[power-spawn-menu-probe] %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	get_tree().quit(failures)


func _button_named(root: Node, label: String) -> Button:
	for node: Node in root.find_children("*", "Button", true, false):
		var button := node as Button
		if button != null and button.text.strip_edges() == "+  %s" % label:
			return button
	return null


func _check(ok: bool, label: String) -> void:
	if ok:
		print("[power-spawn-menu-probe] OK: %s" % label)
	else:
		failures += 1
		push_error("[power-spawn-menu-probe] FAIL: %s" % label)
