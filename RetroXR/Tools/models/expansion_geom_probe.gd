## The reported visual faults on the expansion units, each asserted rather than
## looked at: an invisible OPEN button, a tray that moved nothing, a cartridge
## slot the wrong shape, faces sharing a plane, and a Jaguar CD that sank into
## the Jaguar far enough to bury its own button.
##
##     "$godot" --headless --path RetroXR res://Tools/models/expansion_geom_probe.tscn
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
	# --- and it runs out BELOW the lettering, not through it -------------------
	for id: String in ["sega_cd", "pc_engine_cd"]:
		var u := _spawn(id)
		await get_tree().physics_frame
		var s := u.size()
		var plate := u.get_node_or_null("NameLabel") as Label3D
		var mouth := u.get_node_or_null("DiscBayMouth") as MeshInstance3D
		if plate == null or mouth == null:
			_check(false, "%s has both a nameplate and a bay mouth" % id)
			continue
		var mouth_top: float = mouth.position.y + _mesh_half_height(mouth)
		# The nameplate's own baseline. The mouth has to finish below it, or the
		# disc rides out across the machine's name.
		_check(mouth_top < plate.position.y - 0.004,
			"%s's tray clears its nameplate (mouth top %.4f, plate %.4f)"
				% [id, mouth_top, plate.position.y])
		# And the OPEN button must not sit in the mouth it opens.
		var btn := u.get_node_or_null("EjectButton") as VRButton
		if btn != null:
			var mouth_half: float = (mouth.mesh as BoxMesh).size.x * 0.5
			_check(absf(btn.position.x) - 0.013 > mouth_half,
				"%s's OPEN button clears the tray mouth (%.4f vs %.4f)"
					% [id, absf(btn.position.x) - 0.013, mouth_half])
			_check(absf(btn.position.x) + 0.013 < s.x * 0.5,
				"%s's OPEN button is still on the machine" % id)

	# --- and a disc laid on it LIES ON the shelf rather than in it ------------
	for id: String in ["sega_cd", "pc_engine_cd"]:
		var u := _spawn(id)
		await get_tree().physics_frame
		var disc := (load("res://Scenes/Objects/media/disc.tscn") as PackedScene) 			.instantiate() as RetroDisc
		disc.systemid = ExpansionCatalog.media_of(id)
		disc.rom_path = "Z:/roms/%s/probe.cue" % id
		add_child(disc)
		disc.freeze = true
		await get_tree().physics_frame
		u._tray.set_open(true, false)
		u._tray.restore(disc)
		for i in 5:
			await get_tree().physics_frame
		var pivot: Node3D = u._disc_bay.slide_pivot
		var well := pivot.get_node_or_null("DiscTrayWell") as MeshInstance3D
		var local: Vector3 = pivot.global_transform.affine_inverse() * disc.global_position
		var well_top: float = well.position.y + _mesh_half_height(well)
		# The reported fault: seated at the pivot's own origin the disc sat
		# INSIDE the well cylinder, under its opaque top face, and disappeared.
		_check(local.y > well_top,
			"%s's disc lies on the shelf, not inside the well (%.4f vs %.4f)"
				% [id, local.y, well_top])
		_check(disc.is_visible_in_tree(), "%s's seated disc is still drawn" % id)

	# --- a top-mounting unit keeps its button off the console's own panel -----
	# It stands on the console with its front face flush above the console's, so
	# a button off to one side lands over whatever that machine keeps there --
	# START, on the consoles these attach to, which covered the unit's button.
	for id: String in ["jaguar_cd"]:
		var u := _spawn(id)
		await get_tree().physics_frame
		var btn := u.get_node_or_null("EjectButton") as VRButton
		var plate := u.get_node_or_null("NameLabel") as Label3D
		if btn == null or plate == null:
			_check(false, "%s has a button and a nameplate" % id)
			continue
		_check(absf(btn.position.x) < 0.001,
			"%s's OPEN button is centred on its face (%.4f)" % [id, btn.position.x])
		# And clear of its own lettering, which is 20 mm of text in the bottom of
		# that same face -- centring alone would have put OPEN straight on it.
		var word := btn.get_node_or_null("Label3D") as Label3D
		var word_y: float = btn.position.y + (word.position.y if word != null else 0.0)
		var plate_top: float = plate.position.y + plate.get_aabb().end.y
		_check(word_y > plate_top,
			"%s's OPEN label clears its nameplate (%.4f vs %.4f)"
				% [id, word_y, plate_top])
		_check(btn.position.y + 0.006 < u.size().y * 0.5,
			"%s's OPEN button is still on the front face" % id)

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
			# Two conditions, and the first version of this only had the second.
			# A well SUNK a millimetre into an opaque body clears the z-fight and
			# cannot be seen at all -- so it must stand proud, and by enough to
			# break the depth tie.
			_check(top > roof, "%s's well is visible above its roof (%+.4f)"
				% [id, top - roof])
			_check(absf(top - roof) > 0.0001,
				"...and is not coplanar with it (%s)" % id)
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
	# Both directions of the same fault: seated by its centre it sank into the
	# console far enough to bury its own button, and lifted by a cartridge's
	# height instead it hung in the air above it.
	var pairs := [["atari_jaguar", "jaguar_cd"], ["mega_drive", "sega_32x"]]
	for pair: Array in pairs:
		var host_id: String = pair[0]
		var unit_id: String = pair[1]
		var host := SYSTEM_SCENE.instantiate() as RetroSystem
		host.systemid = host_id
		add_child(host)
		host.freeze = true
		host.global_position = Vector3(3.0 + pairs.find(pair) * 2.0, 1.0, 0.0)
		for i in 70:
			await get_tree().physics_frame
		var unit := _spawn(unit_id)
		unit.global_position = host.global_position + Vector3(0.0, 0.4, 0.0)
		for i in 10:
			await get_tree().physics_frame

		var slot: XRToolsSnapZone = host._cartridge_slot
		_check(slot != null and slot.is_in_group(ExpansionPort.GROUP_CART_SLOT),
			"%s's cartridge slot is reachable by a unit's connector" % host_id)
		if slot == null:
			continue
		# Signed, and it turns out to be NEGATIVE on both of these: the slot sits
		# a few millimetres PROUD of the shell rather than buried in it, which is
		# why seating a unit by its origin half-sank it rather than swallowing it
		# whole. What matters is only that the figure is a real measurement --
		# a machine whose model has not loaded answers a flat zero.
		var lift := host.roof_above_cartridge_slot()
		_check(absf(lift) > 0.0001 and absf(lift) < 0.05,
			"%s measures its roof against its slot (%+.4f m)" % [host_id, lift])

		var seated := slot.snap_pose_for(unit)
		var underside: float = seated.origin.y - unit.size().y * 0.5
		var roof_y: float = slot.global_position.y + lift
		# One check, both directions. Buried (the original fault) puts the
		# underside below the roof; floating (the fault the first fix caused)
		# puts it above. Resting is the only pose that satisfies this, and it is
		# the only one that looks like the hardware.
		_check(absf(underside - roof_y) < 0.002,
			"%s stands ON the %s's roof, neither in it nor above it (%+.4f m)"
				% [unit_id, host_id, underside - roof_y])

		var btn := unit.get_node_or_null("EjectButton") as VRButton
		if btn != null:
			_check(seated.origin.y + btn.position.y > roof_y - 0.001,
				"%s's OPEN button ends up outside the console" % unit_id)

	print("[geom] %d checks, %d failed" % [_checks, _failed])
	print("[geom] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _mesh_half_height(mi: MeshInstance3D) -> float:
	if mi.mesh is BoxMesh:
		return (mi.mesh as BoxMesh).size.y * 0.5
	if mi.mesh is CylinderMesh:
		return (mi.mesh as CylinderMesh).height * 0.5
	return 0.0
