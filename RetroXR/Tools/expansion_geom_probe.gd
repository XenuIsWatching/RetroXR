## The reported visual faults on the expansion units, each asserted rather than
## looked at: an invisible OPEN button, a tray that moved nothing, a cartridge
## slot the wrong shape, faces sharing a plane, and a Jaguar CD that sank into
## the Jaguar far enough to bury its own button.
##
##     "$godot" --headless --path RetroXR res://Tools/expansion_geom_probe.tscn
extends Node3D

const EXPANSION_SCENE := preload("res://Scenes/Objects/expansion.tscn")
const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")

var _checks := 0
var _failed := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
	print("[geom] %s  %s" % ["PASS" if ok else "FAIL", what])


func _spawn(id: String) -> RetroExpansion:
	var u := EXPANSION_SCENE.instantiate() as RetroExpansion
	u.expansion_id = id
	add_child(u)
	u.freeze = true
	return u


func _ready() -> void:
	for i in 20:
		await get_tree().physics_frame

	# --- the OPEN button, on every unit that has a drive lid or drawer ---------
	for id: String in ["sega_cd", "pc_engine_cd", "jaguar_cd"]:
		var u := _spawn(id)
		await get_tree().physics_frame
		var btn := u.get_node_or_null("EjectButton") as VRButton
		_check(btn != null, "%s has an OPEN button" % id)
		if btn == null:
			continue
		var cap := btn.get_node_or_null("ButtonMesh") as MeshInstance3D
		# The reported fault exactly: the cap existed and was hidden, so the
		# button was there to press and invisible to find.
		_check(cap != null and cap.is_visible_in_tree(),
			"%s's OPEN cap is actually visible" % id)
		# And it presses INTO the front face rather than sinking downward.
		_check(btn.depress_axis.is_equal_approx(Vector3(0, 0, -1)),
			"%s's OPEN button travels into its front face" % id)
		var s := u.size()
		_check(btn.position.z > s.z * 0.5 - 0.001,
			"%s's OPEN button is proud of the front face" % id)

	# --- the drawer actually moves --------------------------------------------
	for id: String in ["sega_cd", "pc_engine_cd"]:
		var u := _spawn(id)
		await get_tree().physics_frame
		var bay: ProceduralDiscBay = u._disc_bay
		_check(bay != null and bay.slide_pivot != null,
			"%s has a sliding drawer, not just a state" % id)
		if bay == null or bay.slide_pivot == null:
			continue
		var rest: Vector3 = bay.slide_pivot.position
		u._tray.set_open(true, true)
		for i in 70:
			await get_tree().physics_frame
		_check(bay.slide_pivot.position.distance_to(rest) > 0.05,
			"%s's tray runs out when OPEN is pressed (%.3f m)"
				% [id, bay.slide_pivot.position.distance_to(rest)])
	# A lidded unit swings a lid instead, and must NOT grow a drawer as well.
	var jag := _spawn("jaguar_cd")
	await get_tree().physics_frame
	_check(jag._disc_bay == null and jag._tray.lid_pivot != null,
		"the Jaguar CD opens a lid rather than a drawer")

	# --- no two faces in the same plane ---------------------------------------
	for id: String in ["sega_32x", "satellaview", "sega_cd"]:
		var u := _spawn(id)
		await get_tree().physics_frame
		var s := u.size()
		var roof := s.y * 0.5
		var well := u.get_node_or_null("Body/WellMouth") as MeshInstance3D
		if well != null:
			var top: float = well.position.y + _mesh_half_height(well)
			_check(absf(top - roof) > 0.0001,
				"%s's well is not coplanar with its roof (%.4f below)"
					% [id, roof - top])
		var socket := u.get_node_or_null("ExpansionSocket")
		if socket != null:
			var plate := socket.get_node_or_null("ConnectorPlate") as MeshInstance3D
			if plate != null:
				var low: float = socket.position.y + plate.position.y \
					- _mesh_half_height(plate)
				_check(absf(low - roof) > 0.0001,
					"%s's connector plate clears its roof (%.4f proud)"
						% [id, low - roof])

	# --- the cartridge slot is cut to the cartridge ---------------------------
	var x32 := _spawn("sega_32x")
	await get_tree().physics_frame
	var mouth := x32.get_node_or_null("Body/WellMouth") as MeshInstance3D
	var m := MediaDimensions.cart_size("sega_32x")
	if mouth != null and mouth.mesh is BoxMesh:
		var box: Vector3 = (mouth.mesh as BoxMesh).size
		# A slot, not a pit: as wide as the cart and only as deep as it is thick.
		_check(absf(box.x - (m.x + 0.004)) < 0.001 and absf(box.z - (m.z + 0.004)) < 0.001,
			"the 32X's slot is cut to a Mega Drive cartridge (%.3f x %.3f)"
				% [box.x, box.z])
		_check(box.z < box.x * 0.5,
			"...and so reads as a slot rather than a hole")

	# --- a cartridge-mount unit sits ON the console, not IN it ----------------
	var host := SYSTEM_SCENE.instantiate() as RetroSystem
	host.systemid = "atari_jaguar"
	add_child(host)
	host.freeze = true
	host.global_position = Vector3(3.0, 1.0, 0.0)
	for i in 60:
		await get_tree().physics_frame
	var cd := _spawn("jaguar_cd")
	cd.global_position = Vector3(3.0, 1.4, 0.0)
	for i in 10:
		await get_tree().physics_frame
	var slot: XRToolsSnapZone = host._cartridge_slot
	_check(slot != null and slot.is_in_group(ExpansionPort.GROUP_CART_SLOT),
		"the console's cartridge slot is reachable by a unit's connector")
	if slot != null:
		var seated := slot.snap_pose_for(cd)
		# Its underside must clear the height a cartridge's centre sits at --
		# that is the plane it used to land its own middle on.
		var underside: float = seated.origin.y - cd.size().y * 0.5
		_check(underside > slot.global_position.y + 0.001,
			"the Jaguar CD seats above the cartridge plane, not on it (%.3f m clear)"
				% (underside - slot.global_position.y))
		var btn := cd.get_node_or_null("EjectButton") as VRButton
		if btn != null:
			# The actual complaint: the button ended up inside the console.
			var btn_y: float = seated.origin.y + btn.position.y
			_check(btn_y > host.global_position.y,
				"and its OPEN button ends up outside the console")

	print("[geom] %d checks, %d failed" % [_checks, _failed])
	print("[geom] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _mesh_half_height(mi: MeshInstance3D) -> float:
	if mi.mesh is BoxMesh:
		return (mi.mesh as BoxMesh).size.y * 0.5
	if mi.mesh is CylinderMesh:
		return (mi.mesh as CylinderMesh).height * 0.5
	return 0.0
