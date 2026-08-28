## Does a cartridge lag behind the machine it is socketed into when the whole
## stack is carried?
##
## Builds the Tower of Power -- Mega-CD on the floor, Mega Drive bolted on top of
## it, 32X in the console's cartridge slot, a cartridge in the 32X's own slot --
## then sweeps the BASE about and measures, every physics frame, how far each
## thing above it is from where it should be if the stack were rigid.
##
## Each snapped object is driven by its own XRToolsGrabDriver, a RemoteTransform3D
## that reads its socket's transform in _physics_process. Every driver in a
## snap-zone grab is created at the same process_physics_priority, so the order
## the three run in is scene-tree order and nothing else -- and a driver that
## runs BEFORE the one holding its own host reads a pose one frame old. Three
## sockets deep, that is up to three frames of lag, which is what carrying the
## tower looks like.
##
##     "$godot" --headless --path RetroXR res://Tools/perf/stack_lag_probe.tscn
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const EXPANSION_SCENE := preload("res://Scenes/Objects/expansion.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")

## A tenth of a millimetre. Below this the stack is rigid for any purpose a
## player can see.
const RIGID_EPSILON := 0.0001

var _base: RetroExpansion = null
var _console: RetroSystem = null
var _x32: RetroExpansion = null
var _cart: Node3D = null


func _wait(frames: int) -> void:
	for i in frames:
		await get_tree().physics_frame


func _ready() -> void:
	# Assembled LEAF FIRST, which is the order a player naturally works in: put
	# the cartridge in the 32X, then the loaded 32X into the console, then the
	# console onto the Mega-CD.
	#
	# The order matters because every snap-zone grab driver is created at the
	# same process_physics_priority, so which of them runs first each physics
	# frame is decided by nothing but the order they were added to the tree. Root
	# first is the lucky order -- each host has already moved when its guest
	# reads it. Leaf first is the unlucky one, and each hop then reads a pose one
	# frame stale.
	_base = EXPANSION_SCENE.instantiate() as RetroExpansion
	_base.expansion_id = "sega_cd"
	add_child(_base)
	_base.freeze = true
	_base.global_position = Vector3(0.0, 1.0, 0.0)

	_console = SYSTEM_SCENE.instantiate() as RetroSystem
	_console.systemid = "mega_drive"
	add_child(_console)
	_console.freeze = true
	_console.global_position = Vector3(0.9, 1.0, 0.0)

	_x32 = EXPANSION_SCENE.instantiate() as RetroExpansion
	_x32.expansion_id = "sega_32x"
	add_child(_x32)
	_x32.freeze = true
	_x32.global_position = Vector3(0.9, 1.4, 0.0)

	_cart = CART_SCENE.instantiate()
	_cart.systemid = "sega_32x"
	_cart.rom_path = "Z:/roms/sega_32x/demo.32x"
	add_child(_cart)
	_cart.freeze = true
	_cart.global_position = Vector3(0.9, 1.8, 0.0)
	# The console's cartridge slot is built deferred, after its model loads.
	await _wait(80)

	var bay: XRToolsSnapZone = _x32._bay
	var cart_slot: XRToolsSnapZone = _console._cartridge_slot
	var socket := _base.get_socket()
	if bay == null or cart_slot == null or socket == null:
		print("[lag] FAIL  missing zone: bay=%s slot=%s socket=%s"
			% [bay != null, cart_slot != null, socket != null])
		get_tree().quit(1)
		return

	bay.pick_up_object(_cart)
	await _wait(20)
	cart_slot.pick_up_object(_x32)
	await _wait(20)
	socket.pick_up_object(_console)
	await _wait(40)

	# What is actually holding each one up -- a grab driver reading its host every
	# physics frame, or a rigid reparent that cannot lag at all.
	for pair: Array in [["console", _console], ["32x", _x32], ["cart", _cart]]:
		var n: Node3D = pair[1]
		print("[lag] held: %-8s parent=%s driver=%s" % [pair[0],
			n.get_parent().name,
			is_instance_valid(n.get_parent().get_node_or_null("%s_driver" % n.name))])

	# Where everything sits, expressed in the BASE's frame. If the stack is
	# rigid these never change however the base is thrown around.
	var inv := _base.global_transform.affine_inverse()
	var rest := {
		"console": inv * _console.global_transform,
		"32x": inv * _x32.global_transform,
		"cart": inv * _cart.global_transform,
	}
	var nodes := {"console": _console, "32x": _x32, "cart": _cart}
	var worst := {"console": 0.0, "32x": 0.0, "cart": 0.0}
	# Measured a second time against the transform actually DRAWN.
	# physics_interpolation is on, so what a player sees is not the physics pose
	# but a blend of the last two, and a node whose interpolation state is reset
	# (or whose body the server re-integrates a step late) can render behind the
	# thing it is bolted to while agreeing with it perfectly on every physics
	# tick. A probe that samples only physics poses cannot see that at all.
	var worst_drawn := {"console": 0.0, "32x": 0.0, "cart": 0.0}

	# Carry it: a sweep with real rotation in it, because rotation is what pulls
	# a lagging child furthest off its seat.
	for i in 120:
		var t := float(i) / 20.0
		_base.global_transform = Transform3D(
			Basis.from_euler(Vector3(0.0, sin(t) * 0.9, sin(t * 0.7) * 0.35)),
			Vector3(sin(t) * 0.45, 1.0 + sin(t * 1.3) * 0.20, cos(t) * 0.30))
		await get_tree().physics_frame
		if i < 20:
			continue   # let the drivers settle after the first jump
		var drawn_base := _base.get_global_transform_interpolated()
		for key: String in nodes:
			var want: Transform3D = _base.global_transform * (rest[key] as Transform3D)
			var got: Node3D = nodes[key]
			var d: float = want.origin.distance_to(got.global_position)
			worst[key] = maxf(worst[key], d)
			var want_drawn: Transform3D = drawn_base * (rest[key] as Transform3D)
			var dd: float = want_drawn.origin.distance_to(
				got.get_global_transform_interpolated().origin)
			worst_drawn[key] = maxf(worst_drawn[key], dd)

	var failed := 0
	for key: String in worst:
		var d: float = worst[key]
		var dd: float = worst_drawn[key]
		var ok: bool = d <= RIGID_EPSILON and dd <= RIGID_EPSILON
		if not ok:
			failed += 1
		print("[lag] %s  %-8s physics slip %.4f m   drawn slip %.4f m"
			% ["PASS" if ok else "FAIL", key, d, dd])
	print("[lag] RESULT=%s" % ("PASS" if failed == 0 else "FAIL"))
	get_tree().quit(1 if failed > 0 else 0)
