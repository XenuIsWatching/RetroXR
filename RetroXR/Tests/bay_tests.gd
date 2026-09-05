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
extends Node

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")
const PAD_SCENE := preload("res://Scenes/Objects/controllers/retro_controller.tscn")

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
## heading. The trap this group exists for: the snap zone re-poses the body to
## its own grab point BEFORE the well ever hears about it, so a well reading the
## disc's pose when it accepts one reads the zone's heading and always comes up
## square — which is what shipped first.
const DISC_SCENE := preload("res://Scenes/Objects/media/disc.tscn")


## Put a disc into `sys`'s open well at `yaw_deg` and hand back where it ended up.
## `by_hand` false takes the restore path instead, which is the control.
func _seat_disc(sys: Node3D, yaw_deg: float, by_hand: bool) -> Basis:
	var disc: Node3D = DISC_SCENE.instantiate()
	disc.systemid = sys.systemid
	add_child(disc)
	_spawned.append(disc)
	await _wait(5)
	var pose := Transform3D(Basis(Vector3.UP, deg_to_rad(yaw_deg)),
		sys.global_position + Vector3(0.0, 0.3, 0.0))
	if by_hand:
		var hand := Node3D.new()
		hand.set_script(load("res://Scripts/Desktop/desktop_hand_pivot.gd"))
		add_child(hand)
		_spawned.append(hand)
		hand.global_transform = pose
		disc.global_transform = pose
		disc.pick_up(hand)
		await _wait(20)
		disc.let_go(hand, Vector3.ZERO, Vector3.ZERO)
		(sys.get_node("CartridgeSlot") as XRToolsSnapZone).pick_up_object(disc)
	else:
		disc.global_transform = pose
		sys._tray.restore(disc)
	await _wait(10)
	var got := disc.global_basis.orthonormalized()
	sys._tray.release()
	await _wait(5)
	disc.queue_free()
	await _wait(5)
	return got


## The spin from `a` to `b` about the disc's own axis, in degrees.
func _spin_between(a: Basis, b: Basis) -> float:
	var m := (a.inverse() * b).orthonormalized()
	return rad_to_deg(atan2(-m.x.z, m.x.x))


func _group_seat() -> void:
	var gc := await _console("gamecube_primitive", "gamecube")
	gc._on_eject_pressed()
	await _wait(80)
	_ok(gc._tray != null and gc._tray.is_open(), "seat/the well is open")
	if gc._tray == null:
		await _clear()
		return

	var square := await _seat_disc(gc, 0.0, true)
	for yaw: float in [55.0, -110.0]:
		var turned := await _seat_disc(gc, yaw, true)
		_ok(absf(angle_difference(deg_to_rad(_spin_between(square, turned)),
			deg_to_rad(yaw))) < 0.02,
			"seat/a disc handed in at %+.0f seats at %+.0f" % [yaw, yaw])
		# ...and it is no less flat in the well for it. A seat that took the
		# whole hand pose would pass the line above and leave the disc tilted.
		_ok(turned.y.dot(square.y) > 0.9999,
			"seat/and lies exactly as flat as a square one")

	# The control. A restore is a state the room was already in, not a hand, so
	# it keeps the authored heading — and without this every check above would
	# pass on a well that simply never squares anything.
	var r0 := await _seat_disc(gc, 0.0, false)
	var r1 := await _seat_disc(gc, 55.0, false)
	_ok(absf(_spin_between(r0, r1)) < 0.02,
		"seat/a restore ignores the pose and seats as authored")
	await _clear()


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
