## Cartridge-bay self-tests — how media is offered, how it goes in, and when the
## machine is actually wired to it. Headless, no core, no ROM, no headset.
##
##     "$godot" --headless --path RetroXR res://Tests/bay_tests.tscn
##     "$godot" --headless --path RetroXR res://Tests/bay_tests.tscn -- --only=tray
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## These need a REAL system in the tree — a hardware model, its GLB and its snap
## zones — which is exactly what system_tests.gd cannot have (it builds RetroSystem
## with .new() and never adds it). Hence a suite of their own.
##
## Groups:
##   perch/   what a held cart or plug is SHOWN as, and where a released one lands
##   tray/    the NES ZIF cradle: up, pushed home, lifted, and who is connected
##   plug/    a controller plug offered off its socket and slid in
##   restore/ a save comes back latched, without the slide
##   lid/     a room saved with a disc lid UP comes back with the machine agreeing
##   seat/    the heading a disc keeps from the hand that put it in the well
##   other/   a deck with no push tray is untouched by any of it
##   pak/     the expansion port on an N64 controller, and what each pak asks the
##            running core to fit to that port
extends Node

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")
const PAD_SCENE := preload("res://Scenes/Objects/controllers/retro_controller.tscn")
const N64_PAD_SCENE := preload("res://Scenes/Objects/controllers/n64/n64_controller.tscn")
const RUMBLE_PAK_SCENE := preload("res://Scenes/Objects/controllers/n64/rumble_pak.tscn")
const CONTROLLER_PAK_SCENE := preload("res://Scenes/Objects/controllers/n64/controller_pak.tscn")
const TRANSFER_PAK_SCENE := preload("res://Scenes/Objects/controllers/n64/transfer_pak.tscn")

var _checks := 0
var _failed := 0
var _cases_failed := 0
var _only := ""
var _spawned: Array[Node] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.substr(7)
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[bay] TIMED OUT")
		get_tree().quit(1))
	await _run()
	print("[bay] %d checks, %d case(s) failed" % [_checks, _cases_failed])
	print("[bay] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _wait(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _ok(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
		_cases_failed += 1
	print("[bay] %s  %s" % ["PASS" if ok else "FAIL", what])


func _want(group: String) -> bool:
	return _only.is_empty() or _only == group


## Angle between two nodes' orientations, in degrees. The cradle and the deck are
## authored in the same frame under pure-translation parents, so at rest this is
## zero — which makes the deck a free reference for how far the tray has swung,
## with no authored basis to write down.
func _basis_angle(a: Node3D, b: Node3D) -> float:
	return rad_to_deg(a.global_transform.basis.get_rotation_quaternion().angle_to(
		b.global_transform.basis.get_rotation_quaternion()))


func _box_aabb_in(frame: Node3D, shape: CollisionShape3D) -> AABB:
	var size: Vector3 = (shape.shape as BoxShape3D).size
	return (frame.global_transform.affine_inverse() * shape.global_transform) \
		* AABB(-size * 0.5, size)


## Wait for the tray to stop moving. The travel is a spring one way and a tween the
## other, and both scale with TRAY_UP_DEG — a fixed frame count reads mid-swing the
## moment the angle is retuned, which is a failure that says nothing about the bay.
func _settle_tray(sys: Node3D) -> void:
	var last := INF
	var still := 0
	for i in 150:
		await get_tree().physics_frame
		var deg: float = rad_to_deg(sys._model._tray_pivot.rotation.x)
		still = (still + 1) if is_equal_approx(deg, last) else 0
		last = deg
		if still >= 4 and i >= 10:
			return


## A console in the tree, modelled and cabled up the way the room spawns one.
func _console(model_id: String, systemid: String) -> Node3D:
	var sys := SYSTEM_SCENE.instantiate() as Node3D
	sys.model_id = model_id
	sys.systemid = systemid
	sys.position = Vector3(_spawned.size() * 2.0, 1, 0)
	sys.freeze = true
	add_child(sys)
	sys.add_to_group("spawned")
	_spawned.append(sys)
	await _wait(90)          # the shell's GLB has to land before the bay is placed
	return sys


func _cart(systemid: String) -> Node3D:
	var cart := CART_SCENE.instantiate() as Node3D
	cart.systemid = systemid
	cart.position = Vector3(0, 3, 0)
	cart.freeze = true
	add_child(cart)
	_spawned.append(cart)
	await _wait(10)
	return cart


func _clear() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.queue_free()
	_spawned.clear()
	await _wait(10)


# --- perch ----------------------------------------------------------------------

func _group_perch() -> void:
	var sys := await _console("nes", "nes")
	var slot := sys.get_node("CartridgeSlot") as XRToolsSnapZone
	var cart := await _cart("nes")

	_ok(slot.preview_offset.length() > 0.02,
		"perch/the bay stands a held cart proud of the mouth")

	# The offer runs along the TRAY's axis, which is tilted up while the tray is
	# up — not along the console's level front.
	var seat := slot.snap_pose_for(cart)
	var ghost := slot.preview_pose_for(cart)
	var axis: Vector3 = sys._model.get_cartridge_insert_direction()
	var offer := ghost.origin - seat.origin
	var along := offer.dot(axis)
	_ok(along > 0.02, "perch/the offer is out of the machine, not into it")
	_ok((offer - axis * along).length() < 0.002, "perch/and square to the mouth")
	var level: Vector3 = sys.global_transform.basis.z.normalized()
	_ok(axis.dot(level) < 0.9995,
		"perch/the mouth is tilted up, so the offer is too")

	# The point of measuring the offer rather than writing one down: the ghost has to
	# reach the shell's front face, and this bay seats a cart well inside it, so a
	# stand-off quoted from the seat would leave the ghost buried in the machine.
	var deck := sys.find_child("NesDeck", true, false) as MeshInstance3D
	var to_model := sys.global_transform.affine_inverse()
	var front_z: float = ((to_model * deck.global_transform) * deck.get_aabb()).end.z
	var half: float = MediaDimensions.cart_size("nes").y * 0.5
	var face_z: float = (to_model * (ghost.origin + axis * half)).z
	_ok(face_z >= front_z - 0.001,
		"perch/the ghost's cart reaches the front face")

	slot.pick_up_object(cart)
	_ok(cart.freeze,
		"perch/the insertion keeps the snapped cart out of rigid-body physics")
	await _wait(40)
	_ok(cart.global_position.distance_to(slot.snap_pose_for(cart).origin) < 0.003,
		"perch/a released cart ends at the seat, not the perch")

	# Taking hold of it again pulls it back out to the mouth — as a SLIDE. The
	# stand-off is 30-odd mm, which flicked in one frame is a teleport.
	var hand := Node3D.new()
	hand.set_script(load("res://Scripts/Desktop/desktop_hand_pivot.gd"))
	add_child(hand)
	_spawned.append(hand)
	hand.global_transform = cart.global_transform
	await _wait(2)
	var seat_o := slot.snap_pose_for(cart).origin
	var stand: float = slot.preview_offset.length()
	# The socket has to let go first — a pickable it still holds refuses every
	# grab, which is why the grab paths drop before they take.
	slot.drop_object()
	cart.pick_up(hand)
	await _wait(1)
	var first: float = cart.global_position.distance_to(seat_o)
	_ok(first < stand * 0.5, "perch/taking hold of it eases it out, not flicks it")
	await _wait(30)
	_ok(cart.global_position.distance_to(seat_o) > stand * 0.9,
		"perch/and it does reach the mouth")
	await _clear()


# --- tray -----------------------------------------------------------------------

func _group_tray() -> void:
	var sys := await _console("nes", "nes")
	var slot := sys.get_node("CartridgeSlot") as XRToolsSnapZone
	var cart := await _cart("nes")
	var model := sys._model as RetroSystemModelNES
	var flap := model._flap_hinge as VRHinge
	var flap_shape := flap.find_child("LidActivationBox", false, false) as CollisionShape3D
	var lid := model._lid_mesh as MeshInstance3D
	var lid_box: AABB = (model.global_transform.affine_inverse() * lid.global_transform) \
		* lid.get_aabb()
	var flap_box := _box_aabb_in(model, flap_shape)
	_ok(flap.box_engages and flap_shape.shape is BoxShape3D,
		"tray/the flap uses its box for VR activation")
	_ok(absf(flap_box.position.z - lid_box.position.z) < 0.0001,
		"tray/the flap box stops at the lid's inward face")
	_ok(flap_box.end.y > lid_box.end.y + 0.015,
		"tray/the flap box reaches above the lid")
	_ok(flap_box.end.z > lid_box.end.z + 0.020,
		"tray/the flap box reaches out in front")
	var flap_half: Vector3 = (flap_shape.shape as BoxShape3D).size * 0.5
	var behind_flap: Vector3 = flap_shape.global_transform \
		* Vector3(0, 0, -flap_half.z - 0.005)
	_ok(not flap._tip_in_activation_region(behind_flap),
		"tray/a hand behind the flap box cannot activate it")
	var lid_poke_top := flap.find_child("LidPokeTop", false, false) as CollisionShape3D
	var lid_poke_front := flap.find_child("LidPokeFront", false, false) as CollisionShape3D
	var top_half: Vector3 = (lid_poke_top.shape as BoxShape3D).size * 0.5
	var front_half: Vector3 = (lid_poke_front.shape as BoxShape3D).size * 0.5
	_ok(lid_poke_top != flap_shape and lid_poke_front != flap_shape
		and flap._poke_shapes().size() == 2,
		"tray/the lid pokes use two surfaces separate from its trigger box")
	_ok(top_half.y < 0.002 and front_half.z < 0.004,
		"tray/the lid poke boxes are thin planes, not another volume")
	var lid_bottom: Vector3 = lid_poke_front.global_transform \
		* Vector3(0, -front_half.y, 0)
	var lid_top: Vector3 = lid_poke_top.global_transform \
		* Vector3(0, top_half.y, 0)
	var lid_front: Vector3 = lid_poke_front.global_transform \
		* Vector3(0, 0, front_half.z)
	var lid_front_bottom_seam: Vector3 = lid_poke_front.global_transform \
		* Vector3(0, -front_half.y, front_half.z)
	var top_front_corner: Vector3 = lid_poke_top.global_transform \
		* Vector3(0, top_half.y, top_half.z)
	var front_top_corner: Vector3 = lid_poke_front.global_transform \
		* Vector3(0, front_half.y, front_half.z)
	var lid_top_front_seam := top_front_corner.lerp(front_top_corner, 0.5)
	_ok(flap._face_at_tip(lid_bottom, 0.001) == VRHinge.FACE_Y_NEG
		and flap._face_at_tip(lid_front, 0.001) == VRHinge.FACE_Z_POS,
		"tray/the front plane's thin bottom and broad outward faces accept pokes")
	_ok((flap._shape_faces(lid_poke_front, &"poke_open_faces", 0)
			& VRHinge.FACE_Y_NEG) != 0
		and (flap._shape_faces(lid_poke_front, &"poke_torque_faces", 0)
			& VRHinge.FACE_Z_POS) != 0,
		"tray/the front bottom opens while its outward face follows torque")
	var front_approach: Vector3 = -flap._face_world_normal(
		VRHinge.FACE_Z_POS, lid_poke_front) * 0.005
	var top_approach: Vector3 = -flap._face_world_normal(
		VRHinge.FACE_Y_POS, lid_poke_top) * 0.005
	_ok(flap._face_at_tip(lid_front_bottom_seam, 0.001, -1, front_approach)
		== VRHinge.FACE_Z_POS,
		"tray/frontward intent wins the front/bottom seam")
	_ok(flap._face_at_tip(lid_top_front_seam, 0.002, -1, front_approach)
		== VRHinge.FACE_Z_POS,
		"tray/frontward approach selects +Z at the front/top seam")
	_ok(flap._face_at_tip(lid_top_front_seam, 0.002, -1, top_approach)
		== VRHinge.FACE_Y_POS,
		"tray/downward approach selects +Y at the front/top seam")
	_ok(flap._face_at_tip(lid_top, 0.001) == VRHinge.FACE_Y_POS,
		"tray/the lid's top face pokes it closed")
	var face_follow_ctrl := XRController3D.new()
	add_child(face_follow_ctrl)
	flap._poke_ctrl = face_follow_ctrl
	flap._poke_shape = lid_poke_front
	flap._poke_face = VRHinge.FACE_Z_POS
	flap._poke_mode = VRHinge.POKE_TORQUE
	flap._begin_track(lid_top_front_seam)
	flap._update_active_poke_face(lid_top, top_approach)
	_ok(flap._poke_shape == lid_poke_top
		and flap._poke_face == VRHinge.FACE_Y_POS
		and flap._poke_mode == VRHinge.POKE_CLOSE,
		"tray/an active lid poke follows onto the top face and changes to close")
	flap._update_active_poke_face(lid_front, front_approach)
	_ok(flap._poke_shape == lid_poke_front
		and flap._poke_face == VRHinge.FACE_Z_POS
		and flap._poke_mode == VRHinge.POKE_TORQUE,
		"tray/an active lid poke follows back onto the front face and changes to torque")
	flap._poke_ctrl = null
	flap._poke_shape = null
	flap._poke_face = 0
	flap._poke_mode = 0
	face_follow_ctrl.queue_free()
	var top_underside: Vector3 = lid_poke_top.global_transform \
		* Vector3(0, -top_half.y, 0)
	_ok(flap._face_at_tip(top_underside, 0.001) == VRHinge.FACE_Y_NEG
		and (flap._shape_faces(lid_poke_top, &"poke_open_faces", 0)
			& VRHinge.FACE_Y_NEG) != 0,
		"tray/the top plane's underside is explicitly open-only")
	flap._begin_track(lid_bottom)
	flap._on_poke_motion(lid_bottom + Vector3.UP * 0.03, VRHinge.POKE_OPEN)
	_ok(model.get_lid_angle_deg() > 40.0,
		"tray/an upward bottom-face poke lifts the lid")
	model.set_lid_angle_deg(0.0)
	var top_underside_lever: Vector3 = lid_poke_top.global_transform \
		* Vector3(0, -top_half.y, top_half.z - 0.002)
	flap._begin_track(top_underside_lever)
	flap._on_poke_motion(top_underside_lever + Vector3.UP * 0.03, VRHinge.POKE_OPEN)
	_ok(model.get_lid_angle_deg() > 40.0,
		"tray/an upward poke under the top plane lifts the lid")
	model.set_lid_angle_deg(0.0)
	lid_front = lid_poke_front.global_transform * Vector3(0, 0, front_half.z)
	flap._begin_track(lid_front)
	flap._on_poke_motion(lid_front + Vector3.UP * 0.03, VRHinge.POKE_TORQUE)
	_ok(model.get_lid_angle_deg() > 20.0,
		"tray/upward torque on the front face lifts the lid")
	_ok(flap.poke_release_momentum,
		"tray/the NES lid carries angular poke motion through release")
	var momentum_axis: Vector3 = model._flap_pivot.global_transform.basis.x.normalized()
	var momentum_origin: Vector3 = model._flap_pivot.global_position
	var momentum_next: Vector3 = momentum_origin + Basis(momentum_axis,
		deg_to_rad(4.0)) * (lid_front - momentum_origin)
	flap._poke_release_velocity_deg = 0.0
	flap._sample_poke_release_velocity(momentum_next, lid_front, 0.02)
	_ok(flap._poke_release_velocity_deg > flap.poke_momentum_min_deg_per_sec,
		"tray/a tangential pull-off gives the lid angular release momentum")
	model.set_lid_angle_deg(45.0)
	var momentum_before := rad_to_deg(model._flap_pivot.rotation.x)
	flap._release_angular_velocity_deg = flap._poke_release_velocity_deg
	flap._step_release_momentum(0.02)
	var momentum_after := rad_to_deg(model._flap_pivot.rotation.x)
	_ok((momentum_after - momentum_before) * flap._poke_release_velocity_deg > 0.0,
		"tray/the released lid coasts in the fingertip's angular direction")
	model.set_lid_angle_deg(105.0)
	lid_front = lid_poke_front.global_transform * Vector3(0, 0, front_half.z)
	var hinge_axis: Vector3 = model._flap_pivot.global_transform.basis.x.normalized()
	var hinge_origin: Vector3 = model._flap_pivot.global_position
	var close_arc: Vector3 = hinge_origin + Basis(hinge_axis, deg_to_rad(20.0)) \
		* (lid_front - hinge_origin)
	flap._begin_track(lid_front)
	flap._on_poke_motion(close_arc, VRHinge.POKE_TORQUE)
	_ok(model.get_lid_angle_deg() < 100.0,
		"tray/closing torque on the front face lowers the lid")
	model.set_lid_angle_deg(105.0)
	lid_top = lid_poke_top.global_transform * Vector3(0, top_half.y, 0)
	var top_inward: Vector3 = -flap._face_world_normal(VRHinge.FACE_Y_POS, lid_poke_top)
	flap._begin_track(lid_top)
	flap._on_poke_motion(lid_top + top_inward * 0.03, VRHinge.POKE_CLOSE)
	_ok(model.get_lid_angle_deg() < 90.0,
		"tray/an inward top-face poke lowers the lid")
	model.set_lid_angle_deg(0.0)

	var tray_hinge := model._tray_hinge as VRHinge
	var tray_shape := tray_hinge.find_child("CradleActivationBox", false, false) as CollisionShape3D
	var cradle_geom := model._cradle_mesh() as MeshInstance3D
	_ok(tray_hinge.box_engages and tray_shape.shape is BoxShape3D,
		"tray/the cradle uses its box for VR activation")
	var tray_size: Vector3 = (tray_shape.shape as BoxShape3D).size
	var want_size := Vector3(0.114543, 0.021835938, 0.037454814)
	_ok(tray_size.distance_to(want_size) < 0.000001,
		"tray/the authored cradle box size reaches runtime")
	var tray_in_cradle: Transform3D = cradle_geom.global_transform.affine_inverse() \
		* tray_shape.global_transform
	var want_origin := Vector3(-0.000053, 0.0150039685, 0.099778757)
	_ok(tray_in_cradle.origin.distance_to(want_origin) < 0.000001,
		"tray/the authored cradle box offset reaches runtime")
	var tray_half: Vector3 = (tray_shape.shape as BoxShape3D).size * 0.5
	var behind_tray: Vector3 = tray_shape.global_transform \
		* Vector3(0, 0, tray_half.z + 0.005)
	_ok(not tray_hinge._tip_in_activation_region(behind_tray),
		"tray/a hand deeper inside the shell cannot activate the cradle")
	var tray_top: Vector3 = tray_shape.global_transform \
		* Vector3(0, tray_half.y, 0)
	_ok(tray_hinge._face_at_tip(tray_top, 0.001) == VRHinge.FACE_Y_POS,
		"tray/only the cradle's top face accepts a poke")

	_ok(sys.has_push_tray_bay(), "tray/the NES bay is a push tray")
	_ok(not sys._model.is_tray_down(), "tray/an empty bay rests up")

	slot.pick_up_object(cart)
	await _wait(40)
	var up_pose := cart.global_transform
	# How far the mouth points up: sin(TRAY_UP_DEG) while the tray is sprung up,
	# nothing at all once it is home.
	var up_axis_rise: float = sys._model.get_cartridge_insert_direction().y
	_ok(sys._snapped_cartridge == null,
		"tray/a cart laid in is not read yet")
	_ok(sys._tray_cartridge == cart, "tray/but the bay knows it is lying there")

	var cradle_up: Transform3D = Transform3D.IDENTITY
	var cradle_node := sys.find_child("NesCradle", true, false) as MeshInstance3D
	if cradle_node != null:
		cradle_up = cradle_node.global_transform

	sys.toggle_cart_tray()
	await _settle_tray(sys)
	var down_axis_rise: float = sys._model.get_cartridge_insert_direction().y
	_ok(sys._model.is_tray_down(), "tray/a click pushes it home")
	_ok(sys._snapped_cartridge == cart, "tray/and only then is it read")

	# Pushed home, the tray is LEVEL with the console — not merely "somewhere else
	# than it was". Measured absolutely, because a cradle inverted about its own
	# rest pose still travels the right number of degrees.
	var deck := sys.find_child("NesDeck", true, false) as MeshInstance3D
	var cradle_now := sys.find_child("NesCradle", true, false) as MeshInstance3D
	if deck != null and cradle_now != null:
		_ok(_basis_angle(cradle_now, deck) < 0.5,
			"tray/the cradle is level when it is pushed home")
	else:
		_ok(false, "tray/the cradle is level when it is pushed home")

	# The cart travels with the tray: its nose drops as the cradle levels out.
	var down_pose := cart.global_transform
	_ok(up_pose.origin.y - down_pose.origin.y > 0.0005,
		"tray/the cart comes down with the tray")
	_ok(down_axis_rise < up_axis_rise and absf(down_axis_rise) < 0.005,
		"tray/and levels out as it goes")

	# The tray the player can SEE moves, not just the cart riding an invisible frame.
	# The tray hinges about its own back edge, so the mesh's NODE origin barely
	# moves — its body is what travels.
	var cradle := sys.find_child("NesCradle", true, false) as MeshInstance3D
	if cradle != null:
		var now: Vector3 = (cradle.global_transform * cradle.get_aabb()).get_center()
		var was: Vector3 = (cradle_up * cradle.get_aabb()).get_center()
		_ok(now.distance_to(was) > 0.001, "tray/the cradle travels with it")
		var swung := rad_to_deg(cradle_up.basis.get_rotation_quaternion().angle_to(
			cradle.global_transform.basis.get_rotation_quaternion()))
		_ok(swung > 2.0, "tray/and swings through the tray's own angle")
	else:
		_ok(false, "tray/the cradle travels with it")

	# Clamped home: no hand, beam or drag takes it until the tray is let up.
	_ok(cart.is_clamped(), "tray/a cart pushed home cannot be taken")
	# A click means "push/lift" only while the cart is in the tray. Everywhere else
	# it has to mean "pick me up", or a cart lying on the floor cannot be taken by
	# clicking it at all — which is how every other object in the room behaves.
	_ok(cart.desktop_click_available(),
		"tray/a cart in the tray claims the click")
	# ...and the refusal happens before the socket lets go, so a grab that is
	# turned down leaves the cart where it was rather than loose in the machine.
	_ok(slot.picked_up_object == cart, "tray/a refused grab leaves it seated")

	sys.toggle_cart_tray()
	await _settle_tray(sys)
	_ok(not cart.is_clamped(), "tray/letting it up frees the cart again")
	_ok(not sys._model.is_tray_down(), "tray/a second click lifts it")
	_ok(sys._snapped_cartridge == null,
		"tray/lifting takes the cart off the machine")
	_ok(slot.picked_up_object == cart, "tray/but leaves it lying in the tray")

	# ...and sprung back up it carries the cart at the cart's own angle. Both halves
	# matter: a tray that swings the right distance from the wrong rest pose ends up
	# flat here, with the cart's nose lifting out of the tray holding it.
	if deck != null and cradle_now != null:
		var tray_up := _basis_angle(cradle_now, deck)
		var cart_turned := rad_to_deg(cart.global_transform.basis.get_rotation_quaternion()
			.angle_to(down_pose.basis.get_rotation_quaternion()))
		var want: float = RetroSystemModelNES.TRAY_UP_DEG
		_ok(absf(tray_up - want) < 0.5 and absf(tray_up - cart_turned) < 0.5,
			"tray/and carries the cart at its own angle when up")

	# A direct top-face press must cross BELOW the normal locked rest angle before
	# the push-push latch catches. Releasing at home without that overtravel springs
	# back up; crossing it latches below home and then rebounds slightly to zero.
	var tray_axis: Vector3 = model._tray_pivot.global_transform.basis.x.normalized()
	var tray_origin: Vector3 = model._tray_pivot.global_position
	tray_top = tray_shape.global_transform * Vector3(0, tray_half.y, 0)
	tray_hinge._begin_track(tray_top)
	tray_hinge._on_poke_started(tray_top,
		tray_hinge._face_world_normal(VRHinge.FACE_Y_POS), VRHinge.POKE_CLOSE)
	var home_arc: Vector3 = tray_origin + Basis(tray_axis,
		deg_to_rad(-RetroSystemModelNES.TRAY_UP_DEG)) * (tray_top - tray_origin)
	tray_hinge._on_poke_motion(home_arc, VRHinge.POKE_CLOSE)
	tray_hinge._on_poke_ended()
	await _settle_tray(sys)
	_ok(not tray_hinge.is_latched_closed()
		and absf(rad_to_deg(model._tray_pivot.rotation.x)
			- RetroSystemModelNES.TRAY_UP_DEG) < 0.5,
		"tray/a top poke released at home has not crossed the latch")

	tray_top = tray_shape.global_transform * Vector3(0, tray_half.y, 0)
	tray_hinge._begin_track(tray_top)
	tray_hinge._on_poke_started(tray_top,
		tray_hinge._face_world_normal(VRHinge.FACE_Y_POS), VRHinge.POKE_CLOSE)
	var latch_arc: Vector3 = tray_origin + Basis(tray_axis, deg_to_rad(
		-(RetroSystemModelNES.TRAY_UP_DEG + tray_hinge.push_push_overtravel_deg + 0.5))) \
		* (tray_top - tray_origin)
	var held_latch_finger := XRController3D.new()
	add_child(held_latch_finger)
	tray_hinge._poke_ctrl = held_latch_finger
	tray_hinge._on_poke_motion(latch_arc, VRHinge.POKE_CLOSE)
	_ok(tray_hinge.is_latched_closed(),
		"tray/a top poke crossing below home catches the latch")
	_ok(rad_to_deg(model._tray_pivot.rotation.x) < -0.5,
		"tray/the first latch press visibly overtravels below home")
	_ok(tray_hinge._poke_ctrl == held_latch_finger and tray_hinge._poke_consumed,
		"tray/the caught latch keeps the same poke captured")
	_ok(tray_hinge._latch_feedback_ctrl == held_latch_finger,
		"tray/the latch remembers which controller receives its resting feedback")
	var held_latch_angle: float = rad_to_deg(model._tray_pivot.rotation.x)
	tray_hinge._on_poke_motion(latch_arc, VRHinge.POKE_CLOSE)
	_ok(is_equal_approx(rad_to_deg(model._tray_pivot.rotation.x), held_latch_angle),
		"tray/the caught latch does not rebound through a stationary fingertip")
	tray_hinge._on_poke_motion(home_arc, VRHinge.POKE_CLOSE)
	_ok(rad_to_deg(model._tray_pivot.rotation.x) > held_latch_angle,
		"tray/the caught latch follows the fingertip upward")
	_ok(tray_hinge._latch_feedback_ctrl == null,
		"tray/the resting latch consumes its pending light feedback once")
	# The test has no tracked hand to leave the face, so simulate that physical exit.
	tray_hinge._poke_ctrl = null
	tray_hinge._on_poke_ended()
	tray_hinge._skip_next_release = false
	held_latch_finger.queue_free()
	tray_hinge._icon.visible = true
	tray_hinge._update_icon()
	_ok(not tray_hinge._icon.visible,
		"tray/the latched cradle clears its poke glyph when the hand leaves")
	await _settle_tray(sys)
	_ok(absf(rad_to_deg(model._tray_pivot.rotation.x)) < 0.1,
		"tray/the caught latch rebounds up to its locked rest angle")
	_ok(cart.is_clamped() and model.is_tray_down(),
		"tray/the rebounded carriage is locked with the cart connected")

	# Pressing that same top face while latched uses linear overtravel to release;
	# once it trips, the spring owns the carriage all the way back up.
	tray_top = tray_shape.global_transform * Vector3(0, tray_half.y, 0)
	var poke_normal: Vector3 = tray_hinge._face_world_normal(VRHinge.FACE_Y_POS)
	tray_hinge._begin_track(tray_top)
	tray_hinge._on_poke_started(tray_top, poke_normal, VRHinge.POKE_CLOSE)
	var held_release_finger := XRController3D.new()
	add_child(held_release_finger)
	tray_hinge._poke_ctrl = held_release_finger
	tray_hinge._on_poke_motion(tray_top
		- poke_normal * (tray_hinge.push_push_unlatch_depth + 0.001), VRHinge.POKE_CLOSE)
	_ok(not tray_hinge.is_latched_closed(),
		"tray/a second top poke releases the push-push latch")
	_ok(rad_to_deg(model._tray_pivot.rotation.x) < -0.5,
		"tray/the release press visibly overtravels below home")
	_ok(tray_hinge._poke_ctrl == held_release_finger and tray_hinge._poke_consumed,
		"tray/the released latch follows the poke instead of dropping it")
	var held_release_angle: float = rad_to_deg(model._tray_pivot.rotation.x)
	var release_tip: Vector3 = tray_top \
		- poke_normal * (tray_hinge.push_push_unlatch_depth + 0.001)
	tray_hinge._on_poke_motion(release_tip, VRHinge.POKE_CLOSE)
	_ok(is_equal_approx(rad_to_deg(model._tray_pivot.rotation.x), held_release_angle),
		"tray/the released latch does not spring through a stationary fingertip")
	tray_hinge._on_poke_motion(tray_top, VRHinge.POKE_CLOSE)
	_ok(rad_to_deg(model._tray_pivot.rotation.x) > held_release_angle,
		"tray/the released latch follows the fingertip upward")
	tray_hinge._poke_ctrl = null
	tray_hinge._on_poke_ended()
	tray_hinge._skip_next_release = false
	held_release_finger.queue_free()
	model._set_tray_down(false)
	await _settle_tray(sys)
	_ok(absf(rad_to_deg(model._tray_pivot.rotation.x) - RetroSystemModelNES.TRAY_UP_DEG) < 0.5,
		"tray/the released poke springs the cradle all the way up")
	# Shut the bay for the move: a cart let go inside its own grab sphere is caught
	# straight back by it, which is the room's behaviour and not what this asks.
	slot.enabled = false
	slot.drop_object()
	cart.global_position += Vector3(0, 0.5, 0)
	await _wait(20)
	_ok(sys._tray_cartridge == null, "tray/taking it out empties the bay")
	_ok(not cart.desktop_click_available(),
		"tray/and a loose cart goes back to click-to-take")

	await _clear()


# --- plug -----------------------------------------------------------------------

func _group_plug() -> void:
	var sys := await _console("nes", "nes")
	var port := sys.get_node("ControllerPort1") as XRToolsSnapZone
	_ok(port.preview_offset.length() > 0.005,
		"plug/a plug is offered off the socket, not inside it")

	var pad := PAD_SCENE.instantiate() as Node3D
	pad.position = Vector3(0, 2, 0)
	add_child(pad)
	_spawned.append(pad)
	await _wait(30)
	# RetroController hangs its cable off the current scene, not off itself.
	var plug := get_tree().current_scene.find_child("ControllerPlug", true, false) as Node3D
	if plug != null and is_instance_valid(plug.get_parent()):
		_spawned.append(plug.get_parent())
	if plug == null:
		_ok(false, "plug/the pad has a plug on its cord")
		await _clear()
		return

	var ghost := port.preview_pose_for(plug)
	var seat := port.snap_pose_for(plug)
	var out: Vector3 = port.global_transform.basis.z.normalized()
	_ok((ghost.origin - seat.origin).dot(out) > 0.005,
		"plug/the offer stands off the socket's own axis")

	port.pick_up_object(plug)
	_ok(plug.freeze,
		"plug/the insertion keeps the snapped plug out of rigid-body physics")
	await _wait(40)
	_ok(plug.global_position.distance_to(port.snap_pose_for(plug).origin) < 0.003,
		"plug/a released plug ends in the socket")
	await _clear()


# --- restore --------------------------------------------------------------------

func _group_restore() -> void:
	var sys := await _console("nes", "nes")
	var cart := await _cart("nes")

	sys.restore_cartridge(cart)
	await _wait(4)
	# Four frames is far inside the 0.25 s slide: a restore that animated would
	# still be out at the perch here.
	var slot := sys.get_node("CartridgeSlot") as XRToolsSnapZone
	_ok(cart.global_position.distance_to(slot.snap_pose_for(cart).origin) < 0.003,
		"restore/a restored cart does not slide in")
	_ok(sys._model.is_tray_down(), "restore/it comes back with the tray home")
	_ok(sys._snapped_cartridge == cart, "restore/and the machine reading it")

	# The cradle is ALSO persisted as an articulated control, and that half of the
	# reload runs before the media half — outside _restoring_media, writing the
	# latch back with the same rotation_changed a push emits. Driven through the
	# real ScenePersistence calls, on the real record, because the shape of that
	# record is what decides whether the latch comes back at all.
	var persistence := ScenePersistence.new()
	var records: Array = persistence._serialize_articulated_controls(sys)
	sys._model.lift_tray()
	await _wait(30)
	_ok(not sys._model.is_tray_down(), "restore/the tray lifts before the reload")
	# Without a bank there is nothing to catch playing and the case below is green
	# whatever the model does, so say so here rather than let it pass silently.
	_ok(not sys._model._sfx_tray_down.is_empty(),
		"restore/the cradle has a tray sound that could be heard")
	sys._model._sfx_last.erase("tray")
	persistence._restore_articulated_controls(sys, records)
	_ok(sys._model.is_tray_down(), "restore/a saved cradle comes back latched")
	_ok(not sys._model._sfx_last.has("tray"),
		"restore/and lands without clicking the tray shut")
	await _clear()


# --- other ----------------------------------------------------------------------

func _group_other() -> void:
	var sys := await _console("atari_2600", "atari2600")
	var slot := sys.get_node("CartridgeSlot") as XRToolsSnapZone
	var cart := await _cart("atari2600")

	_ok(not sys.has_push_tray_bay(), "other/a plain deck has no push tray")
	_ok(slot.preview_offset == Vector3.ZERO,
		"other/and offers its cart at the seat, as before")

	slot.pick_up_object(cart)
	await _wait(40)
	_ok(sys._snapped_cartridge == cart,
		"other/a cart it takes is read straight away")
	await _clear()


# --- lid ------------------------------------------------------------------------

## A room saved with a disc lid standing open has to come back with the MACHINE
## open too, not just the shell. The lid pose and the machine's tray state are
## separate things and each console carries the pose home by its own route: a
## procedural spring lid (GameCube, Dreamcast) rides the saved hinge angle and
## latch, the PlayStation's bespoke lid rides the saved lid_angle. Both used to
## arrive with the lid drawn open over a machine that still believed it was shut,
## and its bay then refused every disc until the lid was pushed home and reopened.
##
## Its own throwaway room id, so the player's arcade slot is never touched.
const LID_ROOM := "__bay_tests_lid"
const LID_SLOT := "lid"


func _saved_lid_room(model_id: String, systemid: String) -> Node3D:
	var sp := ScenePersistence.new(LID_ROOM)
	var sys := await _console(model_id, systemid)
	sys._on_eject_pressed()
	await _wait(80)
	sp.save_slot(self, LID_SLOT)
	ScenePersistence.flush_pending_writes()
	await _wait(10)
	sp.load_slot_async(self, LID_SLOT)
	await _wait(150)
	# The console the load built, not the one that was saved.
	for n in get_tree().get_nodes_in_group("spawned"):
		if n is RetroSystem:
			_spawned.append(n)
			return n
	return null


func _drop_lid_room() -> void:
	var dir := "user://scenes/%s" % LID_ROOM
	var d := DirAccess.open(dir)
	if d != null:
		for f in d.get_files():
			d.remove(f)
	var rooms := DirAccess.open("user://scenes")
	if rooms != null:
		rooms.remove(LID_ROOM)


func _group_lid() -> void:
	# A procedural spring lid: the saved HINGE carries the pose home.
	var gc := await _saved_lid_room("gamecube_primitive", "gamecube")
	_ok(gc != null, "lid/the saved room comes back")
	if gc != null:
		_ok(gc._disc_bay.lid_hinge.get_rotation_deg() > 1.0,
			"lid/a spring lid comes back standing open")
		_ok(gc._tray_open, "lid/and the machine says it is open")
		_ok(gc._tray.is_open(), "lid/so does the well")
		_ok((gc.get_node("CartridgeSlot") as XRToolsSnapZone).enabled,
			"lid/which is what lets a disc go in")
	await _clear()

	# A bespoke lid: the saved lid_angle carries the pose home instead.
	var ps := await _saved_lid_room("playstation", "playstation")
	if ps != null:
		_ok(ps.get_lid_angle_deg() > 1.0,
			"lid/a bespoke lid comes back standing open")
		_ok(ps._tray_open, "lid/and that machine says it is open too")
		_ok(ps._tray.is_open(), "lid/well included")
	await _clear()

	# The control. Without it every check above passes on a machine that simply
	# always reports open, which would be a worse bug than the one being tested.
	var sp := ScenePersistence.new(LID_ROOM)
	var shut := await _console("gamecube_primitive", "gamecube")
	sp.save_slot(self, LID_SLOT)
	ScenePersistence.flush_pending_writes()
	await _wait(10)
	sp.load_slot_async(self, LID_SLOT)
	await _wait(150)
	var back: Node3D = null
	for n in get_tree().get_nodes_in_group("spawned"):
		if n is RetroSystem:
			back = n
			_spawned.append(n)
			break
	if back != null:
		_ok(not back._tray_open, "lid/a lid saved SHUT comes back shut")
		_ok(not (back.get_node("CartridgeSlot") as XRToolsSnapZone).enabled,
			"lid/with its bay closed")
	await _clear()
	_drop_lid_room()


# --- seat -------------------------------------------------------------------------

## A disc is round, so the well can seat it at any spin and still be right. It
## takes the one the hand let go at, rather than snapping every disc to the same
## heading. Two traps this group exists for, both of which shipped once:
##   * the snap zone re-poses the body to its own grab point BEFORE the well ever
##     hears about it, so a well reading the disc's pose when it accepts one
##     reads the zone's heading;
##   * the socket PREVIEW re-poses the body onto the zone while the hand is still
##     holding it, so even the pose at let-go is the zone's, and a test that
##     hands the disc straight to the zone without a grab driver never sees it.
## So the by-hand path here holds the disc over the well through a real grab
## driver, lets the preview engage and blend all the way, and only then lets go.
const DISC_SCENE := preload("res://Scenes/Objects/media/disc.tscn")

## The spin the well reported for the last disc _seat_disc seated, in radians.
var _last_seat_yaw := 0.0


## Put a disc into `sys`'s open well and hand back where it ended up. `offer` is
## the hand's pose for the disc relative to a square, flat seat: a yaw, or a yaw
## with a tilt or a flip on top of it. `by_hand` false takes the restore path
## instead, at `restore_yaw`.
func _seat_disc(sys: Node3D, offer: Basis, by_hand: bool,
		restore_yaw: float = 0.0) -> Basis:
	var disc: Node3D = DISC_SCENE.instantiate()
	disc.systemid = sys.systemid
	add_child(disc)
	_spawned.append(disc)
	await _wait(5)
	var zone := sys.get_node("CartridgeSlot") as XRToolsSnapZone
	if by_hand:
		# Over the well, inside the zone's reach, so the preview engages; a
		# little above the seat so it has a blend to run rather than seeding.
		var pose := Transform3D(zone.global_basis.orthonormalized() * offer,
			zone.global_position + Vector3(0.0, 0.04, 0.0))
		var hand := Node3D.new()
		hand.set_script(load("res://Scripts/Desktop/desktop_hand_pivot.gd"))
		add_child(hand)
		_spawned.append(hand)
		hand.global_transform = pose
		disc.global_transform = pose
		disc.pick_up(hand)
		# PREVIEW_BLEND_SPEED is 8/s: well past a full blend at 60 Hz.
		await _wait(40)
		disc.let_go(hand, Vector3.ZERO, Vector3.ZERO)
		# The zone's own dropped hook captures it; if the filter turned it away
		# the zone is handed it directly, which reads the same recorded pose.
		await _wait(5)
		if not sys._tray.has_media():
			zone.pick_up_object(disc)
	else:
		disc.global_transform = Transform3D(offer, sys.global_position + Vector3.UP * 0.3)
		sys._tray.restore(disc, restore_yaw)
	await _wait(10)
	var got := disc.global_basis.orthonormalized()
	_last_seat_yaw = sys.cartridge_seat_yaw()
	sys._tray.release()
	await _wait(5)
	disc.queue_free()
	await _wait(5)
	return got


## The spin from `a` to `b` about the disc's own axis, in degrees.
func _spin_between(a: Basis, b: Basis) -> float:
	return rad_to_deg(RetroDisc.spin_of(a, b))


func _group_seat() -> void:
	# The math on its own first: a yaw reads back whether the disc is flat,
	# tipped or flipped, and the seat it builds is always flat and label-up.
	var seat := Basis(Vector3.UP, 0.4) * Basis(Vector3.RIGHT, 0.2)
	var yaw := deg_to_rad(55.0)
	var flat := seat * Basis(Vector3.UP, yaw)
	var tipped := flat * Basis(Vector3.RIGHT, deg_to_rad(40.0))
	var flipped := flat * Basis(Vector3.RIGHT, PI)
	_ok(absf(RetroDisc.spin_of(seat, flat) - yaw) < 0.001,
		"seat/spin_of reads a flat disc's yaw")
	_ok(absf(RetroDisc.spin_of(seat, tipped) - yaw) < 0.001,
		"seat/spin_of reads the same yaw off a disc tipped 40 degrees")
	_ok(absf(RetroDisc.spin_of(seat, flipped) - yaw) < 0.001,
		"seat/spin_of reads the same yaw off a disc offered label-down")
	var built := RetroDisc.spin_basis(seat, tipped)
	_ok(built.y.dot(seat.y) > 0.9999 and built.is_equal_approx(flat),
		"seat/spin_basis lies flat in the seat at that yaw")
	_ok(absf(RetroDisc.spin_of(seat, seat * Basis(Vector3.UP, deg_to_rad(350.0)))
		- deg_to_rad(-10.0)) < 0.001,
		"seat/spin_of wraps: 350 degrees round is -10")

	var gc := await _console("gamecube_primitive", "gamecube")
	gc._on_eject_pressed()
	await _wait(80)
	_ok(gc._tray != null and gc._tray.is_open(), "seat/the well is open")
	if gc._tray == null:
		await _clear()
		return

	var square := await _seat_disc(gc, Basis.IDENTITY, true)
	for deg: float in [55.0, -110.0]:
		var turned := await _seat_disc(gc, Basis(Vector3.UP, deg_to_rad(deg)), true)
		_ok(absf(angle_difference(deg_to_rad(_spin_between(square, turned)),
			deg_to_rad(deg))) < 0.02,
			"seat/a disc handed in at %+.0f seats at %+.0f" % [deg, deg])
		# ...and it is no less flat in the well for it. A seat that took the
		# whole hand pose would pass the line above and leave the disc tilted.
		_ok(turned.y.dot(square.y) > 0.9999,
			"seat/and lies exactly as flat as a square one")
		_ok(absf(angle_difference(_last_seat_yaw, deg_to_rad(deg))) < 0.02,
			"seat/and the console reports that spin for the save")

	# Held tipped: the yaw still comes through, and the seat is still flat.
	var tipped_in := await _seat_disc(gc,
		Basis(Vector3.UP, deg_to_rad(55.0)) * Basis(Vector3.RIGHT, deg_to_rad(40.0)), true)
	_ok(absf(angle_difference(deg_to_rad(_spin_between(square, tipped_in)),
		deg_to_rad(55.0))) < 0.02 and tipped_in.y.dot(square.y) > 0.9999,
		"seat/a disc handed in tipped 40 degrees seats flat at its yaw")
	# Offered label-down: righted, at the same yaw.
	var flipped_in := await _seat_disc(gc,
		Basis(Vector3.UP, deg_to_rad(55.0)) * Basis(Vector3.RIGHT, PI), true)
	_ok(absf(angle_difference(deg_to_rad(_spin_between(square, flipped_in)),
		deg_to_rad(55.0))) < 0.02 and flipped_in.y.dot(square.y) > 0.9999,
		"seat/a disc handed in label-down seats label-up at its yaw")

	# A restore seats at the yaw it is GIVEN, not the pose the disc happens to
	# have: that is what a save and a peer's insert event carry.
	var r0 := await _seat_disc(gc, Basis.IDENTITY, false)
	var r1 := await _seat_disc(gc, Basis(Vector3.UP, deg_to_rad(20.0)), false)
	_ok(absf(_spin_between(r0, r1)) < 0.02,
		"seat/a restore ignores the disc's own pose")
	var r2 := await _seat_disc(gc, Basis.IDENTITY, false, deg_to_rad(55.0))
	_ok(absf(angle_difference(deg_to_rad(_spin_between(r0, r2)), deg_to_rad(55.0))) < 0.02
		and absf(angle_difference(_last_seat_yaw, deg_to_rad(55.0))) < 0.02,
		"seat/a restore at 55 degrees seats there and reads back 55")

	# And the spin survives a room save: the console writes it, the load seats
	# the disc back at it. Left seated for the save, unlike every disc above.
	var kept: Node3D = DISC_SCENE.instantiate()
	kept.systemid = gc.systemid
	add_child(kept)
	kept.add_to_group("spawned")
	_spawned.append(kept)
	await _wait(5)
	gc._tray.restore(kept, deg_to_rad(-70.0))
	await _wait(5)
	var sp := ScenePersistence.new(LID_ROOM)
	sp.save_slot(self, LID_SLOT)
	ScenePersistence.flush_pending_writes()
	await _wait(10)
	await _clear()
	sp.load_slot_async(self, LID_SLOT)
	await _wait(150)
	var back: RetroSystem = null
	for n in get_tree().get_nodes_in_group("spawned"):
		_spawned.append(n)
		if n is RetroSystem:
			back = n
	_ok(back != null and back.get_snapped_cartridge() != null,
		"seat/the saved room comes back with its disc in the well")
	if back != null:
		_ok(absf(angle_difference(back.cartridge_seat_yaw(), deg_to_rad(-70.0))) < 0.02,
			"seat/and the disc is at the spin it was saved at")
	await _clear()
	_drop_lid_room()


func _run() -> void:
	if _want("perch"):
		await _group_perch()
	if _want("tray"):
		await _group_tray()
	if _want("plug"):
		await _group_plug()
	if _want("restore"):
		await _group_restore()
	if _want("lid"):
		await _group_lid()
	if _want("seat"):
		await _group_seat()
	if _want("other"):
		await _group_other()
	if _want("pak"):
		await _group_pak()


# --- pak/ : the expansion port on the back of an N64 controller ----------------

func _n64_pad() -> Node3D:
	var pad := N64_PAD_SCENE.instantiate() as Node3D
	pad.position = Vector3(_spawned.size() * 2.0, 1, 0)
	add_child(pad)
	_spawned.append(pad)
	return pad


func _pak(scene: PackedScene) -> Node3D:
	var pak := scene.instantiate() as Node3D
	pak.position = Vector3(_spawned.size() * 2.0, 1.4, 0)
	add_child(pak)
	_spawned.append(pak)
	return pak


func _group_pak() -> void:
	var pad := _n64_pad()
	await _wait(4)
	var port := pad.get_node_or_null("ExpansionPort") as XRToolsSnapZone
	_ok(port != null, "pak/the pad has an expansion port")
	if port == null:
		return

	# A pad that HAS a port and nothing in it says so. A pad with no port at all
	# must stay silent instead, or it would pull out the Controller Pak
	# mupen64plus-next fits to port 1 by default.
	_ok(pad.pak_option_value() == "none", "pak/an empty port reports none")
	var plain := PAD_SCENE.instantiate() as Node3D
	add_child(plain)
	_spawned.append(plain)
	await _wait(4)
	_ok(plain.pak_option_value() == "", "pak/a pad with no port reports nothing at all")

	var rumble := _pak(RUMBLE_PAK_SCENE)
	var cpak := _pak(CONTROLLER_PAK_SCENE)
	var tpak := _pak(TRANSFER_PAK_SCENE)
	await _wait(4)

	_ok(port.snap_filter.call(rumble), "pak/the port takes a Rumble Pak")
	_ok(port.snap_filter.call(cpak), "pak/and a Controller Pak")
	_ok(port.snap_filter.call(tpak), "pak/and a Transfer Pak")

	# snap_require alone would take any cable end — every ControllerPlug is in the
	# same group. The pak group is what makes this socket the paks' and nothing
	# else's.
	var cart := CART_SCENE.instantiate() as Node3D
	cart.systemid = "nintendo_64"
	add_child(cart)
	_spawned.append(cart)
	await _wait(4)
	_ok(not port.snap_filter.call(cart), "pak/but refuses a cartridge")

	port.pick_up_object(rumble)
	await _wait(6)
	_ok(pad.get_pak() == rumble, "pak/a seated Rumble Pak is the pad's pak")
	_ok(pad.pak_option_value() == "rumble", "pak/and asks the port for rumble")

	port.drop_object()
	await _wait(6)
	_ok(pad.get_pak() == null, "pak/pulling it leaves the port empty")
	_ok(pad.pak_option_value() == "none", "pak/reporting none again")

	port.pick_up_object(cpak)
	await _wait(6)
	_ok(pad.pak_option_value() == "memory", "pak/a Controller Pak asks for memory")
	port.drop_object()
	await _wait(6)

	port.pick_up_object(tpak)
	await _wait(6)
	_ok(pad.pak_option_value() == "transfer", "pak/a Transfer Pak asks for transfer")

	# The Transfer Pak's own bay. A Game Boy cartridge and nothing else.
	var bay := tpak.get_node_or_null("CartridgeBay") as XRToolsSnapZone
	_ok(bay != null, "pak/the Transfer Pak has a cartridge bay")
	if bay != null:
		var gb := CART_SCENE.instantiate() as Node3D
		gb.systemid = "game_boy"
		add_child(gb)
		_spawned.append(gb)
		var snes := CART_SCENE.instantiate() as Node3D
		snes.systemid = "super_nes"
		add_child(snes)
		_spawned.append(snes)
		await _wait(4)
		_ok(bay.snap_filter.call(gb), "pak/the bay takes a Game Boy cartridge")
		_ok(not bay.snap_filter.call(snes), "pak/and refuses a Super Famicom one")

		# snap_filter and pick_up_object are BOTH blind to snap_require, so a bay
		# missing it passes every case above and cannot be loaded by hand: no ghost
		# lights, and a ray grab -- which seats through the ghost and nothing else --
		# drops the cartridge on the floor. can_preview is the gate a player meets.
		_ok(bay.can_preview(gb), "pak/a Game Boy cartridge previews in the bay")
		_ok(not bay.can_preview(snes), "pak/a Super Famicom one does not")
		_ok(XRToolsSnapZone.find_preview_zone(gb, bay.global_position, 0.033) == bay,
			"pak/and the bay is the zone a held cartridge finds")

		bay.pick_up_object(gb)
		await _wait(6)
		_ok(tpak.get_cart() == gb, "pak/a seated cartridge is the pak's cartridge")

		# WHICH WAY it seats, and this is about the real accessory rather than
		# about tidiness. A Transfer Pak takes its cartridge FLAT, sliding in
		# across the back of the unit -- Wikipedia describes the back as holding
		# "a receptacle slot for a Game Boy game cartridge to slide in parallel
		# to the back", and the retail copy has you slide the cartridge in
		# before plugging the Pak into the controller. It does NOT swallow the
		# cartridge lengthways in line with its own plug.
		#
		# A cartridge is authored standing up, label toward +Y and edge
		# connector at -Y, so seating it flat means a quarter turn: contacts
		# toward the pak's +Z, broad faces up and down.
		var pak_basis: Basis = tpak.global_transform.basis
		var cart_basis: Basis = gb.global_transform.basis
		# The connector is the cartridge's -Y end.
		_ok((-cart_basis.y).dot(pak_basis.z) > 0.9,
			"pak/a seated cartridge goes in contacts-first, from the back")
		# Its broad face is +Z in its own frame, and must end up facing up or
		# down. A half turn leaves it facing sideways and fails here, which is
		# the point: a half turn is its own transpose, so it could never catch a
		# row/column mix-up in the .tscn either.
		_ok(absf(cart_basis.z.dot(pak_basis.y)) > 0.9,
			"pak/and lies flat in the pak rather than standing upright")
		var label := gb.get_node_or_null("LabelMesh") as Node3D
		_ok(label != null and tpak.to_local(label.global_position).z < -0.031,
			"pak/so its printed end clears the mouth instead of hiding inside")

	# The decision itself, against both N64 cores' real vocabularies. A pak the
	# running core cannot serve must leave the port alone rather than fit
	# something the player did not ask for.
	const MUPEN := ["none", "memory", "rumble", "transfer"]
	const PARALLEL := ["none", "memory", "rumble", "biosensor"]
	_ok(RetroSystem._decide_pak(MUPEN, "transfer", "memory") == "transfer",
		"pak/mupen64plus takes a Transfer Pak")
	_ok(RetroSystem._decide_pak(PARALLEL, "transfer", "memory") == "",
		"pak/parallel_n64 has no transfer value, so the port is left alone")
	_ok(RetroSystem._decide_pak(PARALLEL, "rumble", "none") == "rumble",
		"pak/but it does take a Rumble Pak")
	_ok(RetroSystem._decide_pak(MUPEN, "memory", "memory") == "",
		"pak/an unchanged value is not rewritten")
	_ok(RetroSystem._decide_pak(MUPEN, "", "memory") == "",
		"pak/a pad with no port never writes the option")
	_ok(RetroSystem._decide_pak([], "rumble", "") == "",
		"pak/nor does a core that has no such option")

	# Where each pak's 32 KiB sits inside the one SAVE_RAM block both N64 cores
	# publish. Written as literals rather than recomputed from the consts: this is
	# a measurement of somebody else's struct, and checking the arithmetic against
	# the same constants it used would pass however wrong they are.
	#
	# A slip here does not error — it writes a perfectly valid pak image over the
	# EEPROM, or over the pak next door.
	_ok(RetroSystem.MEMPAK_BASE_OFFSET == 0x800, "pak/the paks begin after the eeprom")
	_ok(RetroSystem.MEMPAK_SIZE == 0x8000, "pak/and are 32 KiB each")
	var want := [0x00800, 0x08800, 0x10800, 0x18800]
	var offsets_ok := true
	for slot in 4:
		if RetroSystem.MEMPAK_BASE_OFFSET + slot * RetroSystem.MEMPAK_SIZE != want[slot]:
			offsets_ok = false
	_ok(offsets_ok, "pak/so port N starts at 0x800 + N * 0x8000")
	_ok(N64Card.CARD_SIZE == RetroSystem.MEMPAK_SIZE,
		"pak/and a pak image is exactly one port's worth")

	# The round trip a saved room puts a pak through. A Controller Pak is a
	# PLAIN_SCENES row — so the spawn menu can build one from its token — and
	# that branch of _deserialize_object runs BEFORE the type match, which is
	# why the card fields have to be carried across there. Restored without
	# them, the pak reaches _ready with an empty card_id, mints itself a fresh
	# one and reads exactly like a wiped set of notes.
	var sp := ScenePersistence.new()
	var saved := _pak(CONTROLLER_PAK_SCENE) as ControllerPak
	await _wait(4)
	saved.card_id = "PAK_ROUNDTRIP"
	saved.card_label = "ROUNDTRIP"
	var rec: Dictionary = sp._serialize_node(saved, 0, {})
	_ok(str(rec.get("type", "")) == "controller_pak",
		"pak/a saved pak is recorded as a controller_pak")
	_ok(str(rec.get("card_id", "")) == "PAK_ROUNDTRIP",
		"pak/carrying the card id its notes live under")
	var back := sp._deserialize_object(rec) as ControllerPak
	_ok(back != null, "pak/and is rebuilt from that record")
	if back != null:
		_ok(back.card_id == "PAK_ROUNDTRIP",
			"pak/as the same pak, not a freshly minted blank")
		_ok(back.card_label == "ROUNDTRIP", "pak/keeping the label on its face")
		back.free()
