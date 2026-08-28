extends Node3D

## Round-trips two NES consoles through ScenePersistence — one square to the
## world, one yawed 130 deg — each with a cart seated, one with an NES pad
## plugged in and its bay flap shut. Checks the pad comes back as an NES pad, the
## cart sits the same way in both consoles (so the seat follows the shell rather
## than the world), and the flap keeps the angle it was saved at.
##
##   godot --headless --path RetroXR res://Tools/state/nes_restore_probe.tscn

const SLOT := "probe_nes_restore"
const SYSTEM_SCENE  := preload("res://Scenes/Objects/system.tscn")
const NES_PAD_SCENE := preload("res://Scenes/Objects/controllers/nes/nes_controller.tscn")
const CART_SCENE    := preload("res://Scenes/Objects/media/cartridge.tscn")

var _fail := 0


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[nes] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	var sp := ScenePersistence.new()

	var sys_a := _spawn_system(0.0, Vector3(0, 1, 0))
	var sys_b := _spawn_system(130.0, Vector3(2, 1, 0))
	var cart_a := _spawn_cart(Vector3(0, 1.4, 0))
	var cart_b := _spawn_cart(Vector3(2, 1.4, 0))
	var pad := NES_PAD_SCENE.instantiate() as RetroController
	pad.position = Vector3(2.4, 1, 0)
	add_child(pad)

	await _wait(40)
	sys_a.restore_cartridge(cart_a)
	sys_b.restore_cartridge(cart_b)
	pad.restore_port_connection(sys_b, 0)
	await _wait(40)
	sys_b.set_lid_angle_deg(0.0)     # flap shut over a seated cart
	await _wait(10)

	var before := _snapshot(sys_a, sys_b, cart_a, cart_b, pad)
	_report("before", before)

	if not sp.save_slot(self, SLOT):
		_bad("save_slot failed")
	sp.clear_scene(self)
	await _wait(20)

	var ok: bool = await sp.load_slot_async(self, SLOT)
	if not ok:
		_bad("load_slot_async failed")
	await _wait(60)

	var systems: Array[RetroSystem] = []
	var carts: Array[Node3D] = []
	var pads: Array[RetroController] = []
	for n: Node in get_children():
		if n is RetroSystem:
			systems.append(n as RetroSystem)
		elif n is RetroCartridge:
			carts.append(n as Node3D)
		elif n is RetroController:
			pads.append(n as RetroController)
	if systems.size() != 2 or carts.size() != 2 or pads.size() != 1:
		_bad("restored %d systems / %d carts / %d pads, expected 2 / 2 / 1"
			% [systems.size(), carts.size(), pads.size()])
		_finish()
		return

	# Order is the save file's, which is the "spawned" group's — square console
	# first, yawed one second, matching the build order above.
	var after := _snapshot(systems[0], systems[1], carts[0], carts[1], pads[0])
	_report("after ", after)

	if after["pad_scene"] != NES_PAD_SCENE.resource_path:
		_bad("pad came back as '%s'" % after["pad_scene"])
	if int(after["pad_port"]) != 0:
		_bad("pad port %d, expected 0" % int(after["pad_port"]))
	# The cart's pose IN THE CONSOLE'S OWN FRAME must not care which way the
	# console faces — that is the whole bug: a world-space seat basis parked the
	# cart on a fixed compass heading.
	_same_basis("cart seat, square vs yawed console (after)",
		after["cart_a_basis"], after["cart_b_basis"])
	_same_basis("cart seat A, before vs after", before["cart_a_basis"], after["cart_a_basis"])
	_same_basis("cart seat B, before vs after", before["cart_b_basis"], after["cart_b_basis"])
	_same_angle("flap A", float(before["lid_a"]), float(after["lid_a"]))
	_same_angle("flap B", float(before["lid_b"]), float(after["lid_b"]))
	if float(after["lid_b"]) > 1.0:
		_bad("flap B restored open (%.1f deg), was saved shut" % float(after["lid_b"]))
	_finish()


func _finish() -> void:
	var path := ScenePersistence.ARCADE_DIR + "/" + SLOT + ".json"
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	print("[nes] %s" % ("PASS" if _fail == 0 else "%d FAILURE(S)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


func _spawn_system(yaw_deg: float, pos: Vector3) -> RetroSystem:
	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = "nes"
	sys.model_id = "nes"
	sys.position = pos
	sys.rotation_degrees = Vector3(0, yaw_deg, 0)
	sys.ignore_gravity = true
	add_child(sys)
	sys.add_to_group("spawned")
	return sys


func _spawn_cart(pos: Vector3) -> RetroCartridge:
	var cart := CART_SCENE.instantiate() as RetroCartridge
	cart.systemid = "nes"
	cart.game_label = "PROBE"
	cart.position = pos
	add_child(cart)
	cart.add_to_group("spawned")
	return cart


func _snapshot(sys_a: RetroSystem, sys_b: RetroSystem, cart_a: Node3D, cart_b: Node3D,
		pad: RetroController) -> Dictionary:
	return {
		"pad_scene": pad.scene_file_path,
		"pad_port": pad.get("_port_index"),
		"cart_a_basis": (sys_a.global_transform.affine_inverse() * cart_a.global_transform).basis,
		"cart_b_basis": (sys_b.global_transform.affine_inverse() * cart_b.global_transform).basis,
		"lid_a": sys_a.get_lid_angle_deg(),
		"lid_b": sys_b.get_lid_angle_deg(),
	}


func _report(tag: String, s: Dictionary) -> void:
	print("[nes] %s pad=%s port=%s flapA=%.1f flapB=%.1f" % [tag,
		str(s["pad_scene"]).get_file(), s["pad_port"], s["lid_a"], s["lid_b"]])
	print("[nes] %s   cartA %s" % [tag, _basis_str(s["cart_a_basis"])])
	print("[nes] %s   cartB %s" % [tag, _basis_str(s["cart_b_basis"])])


func _basis_str(b: Basis) -> String:
	return "x(%.2f %.2f %.2f) y(%.2f %.2f %.2f) z(%.2f %.2f %.2f)" % [
		b.x.x, b.x.y, b.x.z, b.y.x, b.y.y, b.y.z, b.z.x, b.z.y, b.z.z]


func _same_basis(what: String, a: Basis, b: Basis) -> void:
	for pair: Array in [[a.x, b.x], [a.y, b.y], [a.z, b.z]]:
		if (pair[0] as Vector3).distance_to(pair[1] as Vector3) > 0.02:
			_bad("%s differ:\n      %s\n      %s" % [what, _basis_str(a), _basis_str(b)])
			return


func _same_angle(what: String, a: float, b: float) -> void:
	if absf(a - b) > 1.0:
		_bad("%s: %.1f deg saved, %.1f deg restored" % [what, a, b])


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().physics_frame


func _bad(m: String) -> void:
	_fail += 1
	print("[nes] FAIL " + m)
