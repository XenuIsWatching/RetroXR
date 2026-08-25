## RetroSystemModelPlayStation — the original grey PlayStation (SCPH-1001).
##
## Wires POWER / RESET / OPEN, the power LED, the sprung disc lid, the disc seat
## on the spindle, both controller ports, both memory card slots, the three rear
## RCA jacks and the SERIAL I/O socket the link cable plugs into.
##
## Every position here is READ OFF THE SHELL by mesh name rather than written
## down. Tools/glb/split_playstation.py separates the shell's single Buttons mesh
## into ButtonPower / ButtonReset / ButtonOpen and its single FrontPorts mesh into
## Port1 / Port2 / MemCard1 / MemCard2 precisely so this file can ask the geometry
## where things are instead of carrying a table of hand-measured constants that
## silently rots if the asset is re-exported.
##
## The lid is the interesting part. Unlike the NES flap — whose hinge edge has to
## be computed from the mesh AABB — the artist modelled this lid 50 degrees open
## about its OWN object origin, so that origin IS the hinge and the swing is a
## measurement rather than a guess. See the driver-frame note on _setup_lid.
class_name RetroSystemModelPlayStation
extends RetroSystemModel

const _MODEL_PATH := "res://imported-assets/consoles/playstation/ps1_console.glb"

## Preloaded rather than loaded in build_serial_port, matching default_model: the
## cost is paid once for the class instead of once per console spawned.
const _SERIAL_PORT_SCENE := preload("res://Scenes/Objects/cables/psx_link_port.tscn")

## How far the serial connector's mating face stands proud of the back panel.
## default_model's figure, kept rather than re-derived so both bodies seat the
## same lead the same way.
const SERIAL_PROUD := 0.001

## Measured off the asset: the lid ships modelled at -50 degrees local X, and
## shutting it in the exporter is what makes 0 mean "closed" here.
const _LID_OPEN_DEG := 50.0
const _LID_ANIM_TIME := 0.32

## Caps sit proud of the top face by about 3 mm, so this is a visible press
## without the cap vanishing into the shell.
const BUTTON_DEPRESS_DEPTH := 0.0018

var _glb: Node3D = null
var _power_button: VRButton = null
var _open_button: VRButton = null


# Lid. `_lid` is the shell's own node (its origin is the hinge); `_lid_driver` is
# the hidden frame the VRHinge actually turns — see _setup_lid.
var _lid: Node3D = null
var _lid_driver: Node3D = null
var _lid_hinge: VRSpringLatchedHinge = null
var _lid_amount: float = 0.0
var _lid_tween: Tween = null
var _disc_slot: Node3D = null
var _turntable: Node3D = null


func _ready() -> void:
	var baked := get_node_or_null("Shell") as Node3D
	if baked != null:
		_glb = baked
	else:
		if not ResourceLoader.exists(_MODEL_PATH):
			push_warning("PlayStationModel: %s missing — using placeholder box" % _MODEL_PATH)
			var host := get_parent()
			if host:
				var body := host.get_node_or_null("SystemBody") as MeshInstance3D
				if body:
					body.show()
			return
		var scene := load(_MODEL_PATH) as PackedScene
		if scene == null:
			push_warning("PlayStationModel: failed to load %s" % _MODEL_PATH)
			return
		_glb = scene.instantiate() as Node3D
		# MUST be "Shell" — has_baked_shell() looks for exactly this, and it is how
		# the cabinet knows the console carries its own printed legends and should
		# not get a SystemNameLabel laid across its front.
		_glb.name = "Shell"
		add_child(_glb)

	_hide_seat_previews()

	# The GLB is exported centred on its footprint and resting on y = 0, so this
	# is normally a no-op; kept as a guard against a re-export that is not.
	if baked == null:
		var b := _model_aabb(_glb)
		var c := b.position + b.size * 0.5
		_glb.position = Vector3(-c.x, -b.position.y, -c.z)

	_lid = _glb.find_child("Lid", true, false) as Node3D
	if _lid != null:
		_setup_lid()

	_build_turntable()

	_power_light_mesh = _shell_mesh("PowerLight")
	if _power_light_mesh != null:
		prep_power_light(Color(0.1, 1.0, 0.2), LED_COLOR, LED_ENERGY, 1.0)
		set_power_light(false)


func _model_aabb(inst: Node3D) -> AABB:
	var acc := AABB()
	var first := true
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for ch in n.get_children():
			stack.append(ch)
	return acc


## The MeshInstance3D for a named part of the shell.
##
## Some names in the GLB are the MESH (the separated buttons, ports and jacks);
## others are the PARENT node the exporter kept, with the mesh under it carrying
## Sketchfab's long original name — Spindle and PowerLight are both of those.
## Casting the parent straight to MeshInstance3D returns null, which silently
## cost the disc its seat and the power LED its glow, so descend when needed.
func _shell_mesh(part_name: String) -> MeshInstance3D:
	if _glb == null:
		return null
	var n := _glb.find_child(part_name, true, false)
	if n == null:
		return null
	var mi := n as MeshInstance3D
	if mi != null:
		return mi
	for child in n.find_children("*", "MeshInstance3D", true, false):
		return child as MeshInstance3D
	return null


## World-space centre of a named mesh in the shell, or this model's origin.
func _mesh_center(mesh_name: String) -> Vector3:
	var m := _shell_mesh(mesh_name)
	return (m.global_transform * m.get_aabb().get_center()) if m != null else global_position


## Local-space centre of a named mesh, for the constants the ports need.
func _mesh_center_local(mesh_name: String) -> Vector3:
	return global_transform.affine_inverse() * _mesh_center(mesh_name)


## Local-space bounds of a named mesh. A socket wants a FACE, not a centre: the
## recess it is given has to start where the shell's own metal starts.
func _mesh_aabb_local(mesh_name: String) -> AABB:
	var m := _shell_mesh(mesh_name)
	if m == null:
		return AABB()
	return (global_transform.affine_inverse() * m.global_transform) * m.get_aabb()


func get_controller_port_count() -> int:
	return 2


## CD-era hardware: saves live on a removable card, not on the media. One slot
## -- the shell moulds a second, but nothing in the room fills it and the core is
## told memcard2 is absent either way.
func card_slot_count() -> int:
	return 1


## The shell models its own OPEN button and this model mounts a widget on it, so
## the cabinet must not also build a generic eject button claiming the same job.
func has_eject_button() -> bool:
	return true


# --- power LED --------------------------------------------------------------

# --- power LED --------------------------------------------------------------

const LED_ENERGY := 0.0000288

## Green, where the NES is red. Taken from the ASSET rather than from a
## photograph: the shell's own material for this lens is a dark green
## (0, 0.133, 0), which is a green LED that happens to be off, and the emissive
## this file already drove was green to match. Changing the hue here would put
## the lit state at odds with the unlit one the artist modelled.
const LED_COLOR := Color(0.15, 1.0, 0.25)


# --- buttons ----------------------------------------------------------------

## POWER latches in; RESET and OPEN are momentary. All three caps sit on the
## console's TOP face and press straight down into it, so the depress axis is the
## model's own -Y rather than anything read off the cap.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_power_button = power_btn
	_open_button = eject_btn
	if _glb == null:
		return
	var into_face: Vector3 = -global_transform.basis.y.normalized()
	var wiring := [
		[power_btn, "ButtonPower"],
		[reset_btn, "ButtonReset"],
		[eject_btn, "ButtonOpen"],
	]
	for pair: Array in wiring:
		var btn: VRButton = pair[0]
		if btn == null:
			continue
		btn.depress_depth = BUTTON_DEPRESS_DEPTH
		btn.set_latched_pressed(false)
		var cap := _shell_mesh(String(pair[1]))
		if cap == null:
			push_warning("PlayStationModel: %s missing from the shell" % pair[1])
			continue
		# set_button_mesh also hides the cabinet's placeholder box, and is what
		# makes the real cap travel when the button is pressed.
		btn.set_button_mesh(cap)
		btn.global_position = _mesh_center(String(pair[1]))
		btn.set_depress_axis_world(into_face)
		var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
		if lbl != null:
			lbl.hide()


func on_power_on() -> void:
	super()
	if _power_button != null:
		_power_button.set_latched_pressed(true)
	set_power_light(true)


func on_power_off() -> void:
	super()
	if _power_button != null:
		_power_button.set_latched_pressed(false)
	set_power_light(false)


# --- disc lid ---------------------------------------------------------------

## Mount the sprung lid.
##
## The hinge does NOT drive the lid node directly. VRHinge turns its target about
## the target's local +X and VRSpringLatchedHinge defines closed = min_deg and
## open = max_deg > 0 — but this lid opens on NEGATIVE X (the hinge is the rear
## edge, so lifting the front edge is a negative rotation). Pointing the hinge at
## the lid would need max_deg < min_deg and invert the latch.
##
## So the hinge turns a hidden driver frame over 0..+50, and the reported angle is
## mirrored onto the lid's own rotation. Same idiom as the NES flap's FlapHinge
## frame, for the same reason: keep the widget's convention and the mesh's
## geometry from having to agree.
##
## The driver is not a bare frame at the model's origin, and both halves of its
## placement are load-bearing — VRHinge._angle_at reads the hand's angle in the
## TARGET's frame, about the TARGET's origin, so a driver that does not stand
## where the lid's hinge stands and turn the way the lid turns maps the hand's
## motion onto a different arc than the one the player can see:
##   • ORIGIN — the lid's own origin IS the hinge line (rear edge, ~85 mm behind
##     and 42 mm above the model origin). Measuring from the model origin instead
##     put a hand at the lid's front edge in the wrong quadrant entirely, where
##     pushing DOWN increased the angle. That is the reported bug: the lid would
##     not shut when you brought your hand down with it, but did shut when the
##     hand swung back over the console.
##   • YAW — VRSpringLatchedHinge.mount's Basis(UP, PI), for the reason its own
##     note gives. The lid opens on NEGATIVE local X, so without the half turn a
##     driver aligned with the model tracks the hand backwards.
func _setup_lid() -> void:
	_lid_driver = Node3D.new()
	_lid_driver.name = "LidDriver"
	add_child(_lid_driver)
	_lid_driver.transform = Transform3D(Basis(Vector3.UP, PI),
		to_local(_lid.global_position))

	var hinge := VRSpringLatchedHinge.new()
	hinge.name = "LidHinge"
	hinge.target = _lid_driver
	hinge.min_deg = 0.0
	hinge.max_deg = _LID_OPEN_DEG
	hinge.start_closed = true
	# Squeeze to swing it. Nobody lifts a console by its disc lid, so the grip is
	# free to mean "close this" here.
	hinge.grip_engages = true
	hinge.collision_layer = 1 | (1 << 20)

	var ab: AABB = _lid_aabb()
	hinge.engage_radius = clampf(maxf(ab.size.x, ab.size.z) * 0.35, 0.03, 0.09)
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	# Only the FREE half of the lid — the front, away from the rear hinge — so a
	# hand reaching for the lid is not also grabbing the hinge line.
	box.size = Vector3(ab.size.x * 0.8, maxf(ab.size.y, 0.012) + 0.012, ab.size.z * 0.5)
	col.shape = box
	hinge.add_child(col)
	_lid.add_child(hinge)
	# Ride the lid mesh, so the grab box, the proximity sphere and the hint icon
	# all track the lid as it swings.
	hinge.global_position = Vector3(ab.get_center().x,
		ab.position.y + ab.size.y, ab.position.z + ab.size.z * 0.75)
	hinge.place_hint(Vector3(0.0, 0.02, 0.0))
	hinge.rotation_changed.connect(_on_lid_swung)
	_lid_hinge = hinge


func _lid_aabb() -> AABB:
	var acc := AABB()
	var first := true
	var stack: Array[Node] = [_lid]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			var ab: AABB = mi.global_transform * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for ch in n.get_children():
			stack.append(ch)
	return acc


## Pose the lid: 0 = shut, 1 = fully open. The lid node's own origin is the
## hinge, so this is a plain rotation — no about-a-pivot composition needed.
func _set_lid(amount: float) -> void:
	_lid_amount = clampf(amount, 0.0, 1.0)
	if _lid != null:
		_lid.rotation.x = deg_to_rad(-_LID_OPEN_DEG * _lid_amount)


func _tween_lid(to: float) -> void:
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()
	_lid_tween = create_tween()
	_lid_tween.tween_method(_set_lid, _lid_amount, to, _LID_ANIM_TIME) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


## The hand swung the lid — mirror the driver's positive angle onto the lid, gate
## the disc bay, and tell the host when the lid reaches home.
##
## That last part is not optional. OPEN on a spring-latched lid is a LATCH
## RELEASE, so RetroSystem._on_eject_pressed deliberately does nothing when it
## already believes the tray is up. Close the lid by hand without saying so and
## that belief never changes: the lid is shut, the machine thinks it is open, and
## the next press of OPEN is correctly ignored — which reads as a dead button.
##
## Gated on the hinge being LATCHED rather than on the angle, which is psp_model's
## rule for its UMD door and avoids reporting a state change part-way through a
## drag, where request_tray_state would tween the lid out from under the hand.
func _on_lid_swung(deg: float) -> void:
	# The hand is authoritative. play_open starts a 0.32 s tween, and a hand that
	# takes the lid inside that window would otherwise be fighting it: both drive
	# _set_lid every frame, and the tween wins because it runs last. Caught by
	# mutation-testing the report below -- with the report removed, the lid still
	# read 50 degrees after being pushed shut, because the open tween had simply
	# carried on.
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()
	_set_lid(deg / _LID_OPEN_DEG)
	if _disc_slot != null:
		_disc_slot.enabled = _lid_amount > 0.5
	# Both directions. Reporting only the latch clicking shut was enough while the
	# only way this lid opened was the OPEN button, which reports for itself — but
	# a restore reapplies the saved angle and latch straight onto the hinge, and
	# the machine heard nothing. See RetroSystem._on_lid_swung.
	if _lid_hinge != null:
		var host := get_parent()
		if host != null and host.has_method("lid_reports_open"):
			host.lid_reports_open(not _lid_hinge.is_latched_closed(), _lid_hinge)


func has_spring_latched_lid() -> bool:
	return _lid_hinge != null


## OPEN pressed: unlatch, and let the spring take it up.
func play_open() -> void:
	if _lid_hinge != null:
		_lid_hinge.open()
	_tween_lid(1.0)
	if _disc_slot != null:
		_disc_slot.enabled = true


func play_close() -> void:
	if _lid_hinge != null:
		_lid_hinge.latch_closed()
	_tween_lid(0.0)
	if _disc_slot != null:
		_disc_slot.enabled = false


func get_lid_angle_deg() -> float:
	return _lid_amount * _LID_OPEN_DEG


## Restore a saved lid pose with no animation — a restore is a state the room was
## already in, not something the player just did.
func set_lid_angle_deg(open_deg: float) -> void:
	if _lid_tween != null and _lid_tween.is_valid():
		_lid_tween.kill()
	var amount := clampf(open_deg / _LID_OPEN_DEG, 0.0, 1.0)
	_set_lid(amount)
	if _lid_hinge != null:
		_lid_hinge.set_rotation_deg_no_signal(_LID_OPEN_DEG * amount)
	if _disc_slot != null:
		_disc_slot.enabled = amount > 0.5


## The same half-way rule set_lid_angle_deg gates the well on, so the machine
## and the shell cannot disagree about a restored lid.
func is_lid_open() -> bool:
	return _lid_amount > 0.5


# --- disc -------------------------------------------------------------------

## The parts of the shell that turn with the platter, gathered under one pivot on
## the spindle axis.
##
## Two of the seven meshes in the disc mechanism, and only two. The BALL GRIP is
## the clamp that stands in the disc's centre hole -- 10.4 x 11.0 mm against a
## CD's 15 mm hole, so it is the one piece of the mechanism still VISIBLE with a
## disc seated, and a platter revolving around a stationary hub is the tell. The
## RUBBER is the 25.2 mm turntable mat the disc is driven by; it is hidden under
## the platter while one is loaded, but it is the same rotating assembly and
## leaving it behind would show the moment the lid came up on a spinning drive.
##
## The other five do NOT turn, and none of them is an oversight: DiscCradle is
## the moulded well the disc sits in, LaserBed is the rail, and the three
## LaserTrolley meshes are the pickup -- which on real hardware tracks RADIALLY
## along that rail while the disc spins. That is a different motion, not this one,
## and nothing here drives it.
##
## A pivot rather than rotating each mesh in place: neither part's own origin is
## on the spindle axis (the rubber is a child of ShellTop, positioned in the
## shell's frame), so turning them about themselves would swing them around the
## bay instead of spinning them.
## Where the mechanism actually turns, in the shell's frame.
##
## Measured off the RUBBER and not off the ball grip, though the grip is the
## obvious candidate and was what this used first. After the decimation cut the
## grip is a 24-triangle blob: its plan is 10.37 x 11.03 mm (aspect 0.940) and
## its AABB centre and vertex centroid disagree by 1.3 mm, so neither is its
## axis. Building the pivot from it put the centre 0.97 mm out, and a 25 mm mat
## turning about a point a millimetre outside itself wobbles visibly.
##
## The rubber is 25.16 x 25.15 (aspect 1.000) with centre and centroid agreeing
## to five microns. It is a solid of revolution, so its centre IS the axis --
## which is also what it is physically: the platter the disc is driven by.
##
## Only x and z are returned. A rotation about Y through a point is the same at
## every height on it.
func _turntable_axis() -> Vector3:
	var mat := _shell_mesh_by_suffix("_Disc_Rubber_0")
	if mat == null:
		mat = _shell_mesh("Spindle")          # nothing better; wobbles, but turns
	if mat == null:
		return Vector3.ZERO
	var to_glb := _glb.global_transform.affine_inverse() * mat.global_transform
	var c: Vector3 = to_glb * mat.get_aabb().get_center()
	return Vector3(c.x, 0.0, c.z)


func _build_turntable() -> void:
	if _glb == null or _turntable != null:
		return
	var hub := _shell_mesh("Spindle")
	if hub == null:
		return
	_turntable = Node3D.new()
	_turntable.name = "Turntable"
	_glb.add_child(_turntable)
	_turntable.position = _turntable_axis()
	for part in [hub.get_parent() as Node3D, _shell_mesh_by_suffix("_Disc_Rubber_0")]:
		if part != null and part != _glb and part.get_parent() != _turntable:
			part.reparent(_turntable, true)


## The rubber has no name of its own -- it is one mesh among twelve inside
## ShellTop, still wearing Sketchfab's, so it is found by what the exporter left
## on the end rather than by a name split_playstation.py never gave it.
func _shell_mesh_by_suffix(suffix: String) -> MeshInstance3D:
	if _glb == null:
		return null
	for n in _glb.find_children("*", "MeshInstance3D", true, false):
		if String(n.name).ends_with(suffix):
			return n as MeshInstance3D
	return null


## Turn the mechanism with the motor. See RetroSystemModel.spin_disc_mechanism:
## the ramp, and the decision that it is spinning at all, both live in RetroSystem.
func spin_disc_mechanism(radians: float) -> void:
	if _turntable != null:
		_turntable.rotate_object_local(Vector3.UP, radians)

## Seat the disc on the spindle. Read off the Spindle mesh rather than written
## down, and lifted to the spindle's top face so the platter rests ON it.
##
## Note the shell's disc well is generous — it measures ~160 mm across against a
## CD's 120 — because the artist drew an oversized disc to fill it. A correctly
## sized 120 mm RetroDisc therefore sits with visible clearance around its rim.
func configure_cartridge_slot(slot: Node3D) -> void:
	_disc_slot = slot
	var seat := _seat_marker("DiscSeat")
	if seat != null:
		slot.global_transform = seat.global_transform
	elif _glb != null:
		var sp := _shell_mesh("Spindle")
		if sp != null:
			# HEIGHT off the spindle -- the platter rests on its top face -- but
			# the CENTRE off the turntable axis. The grip's own plan centre is
			# 0.97 mm off it (see _turntable_axis), which is a disc seated a
			# millimetre out of the well it is sitting in.
			var ab: AABB = sp.global_transform * sp.get_aabb()
			var axis: Vector3 = _glb.global_transform * _turntable_axis()
			slot.global_position = Vector3(axis.x,
				ab.position.y + ab.size.y, axis.z)
			slot.global_basis = global_transform.basis.orthonormalized()
	var slot_visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if slot_visual != null:
		slot_visual.hide()
	# Spindle console: the disc rests on the BASE and only the lid swings, so the
	# bay is gated by the lid rather than carried by it (get_disc_lid_pivot stays
	# null, unlike the PSP's flip-open door).
	slot.enabled = _lid_amount > 0.5


## Straight down onto the spindle.
func get_cartridge_insert_direction() -> Vector3:
	return -global_transform.basis.y.normalized()


# --- controller ports & memory cards ----------------------------------------

## The grab point's own 180-degree flip about X, which the zone has to undo.
const _GRAB_FLIP := PI


## Both sockets, measured off Port1/Port2 rather than mirrored from one another.
##
## They DO come out symmetric here (+/-0.0294) — but that is a measurement, not an
## assumption: the 2600's two ports sit 30 mm apart in magnitude and mirroring one
## onto the other was wrong there.
##
## The zone is not the plug's pose. XRTools aligns a plug's SnapGrabPoint — which
## carries its own 180-degree flip about X (controller_cable.tscn) — to the zone,
## so the placed pose has to be composed with that flip. A front-facing socket
## then needs a ROLL of 180 about Z, not a yaw: composed with the grab flip, a
## roll sends the plug's +Z connector into the shell and keeps it upright, while
## a yaw sends the connector back out and turns the plug over.
func configure_controller_ports(port_zones: Array) -> void:
	for i in range(port_zones.size()):
		var zone: Node3D = port_zones[i]
		var seat := find_child("PortSeat%d" % (i + 1), true, false) as Node3D
		if seat != null:
			zone.global_transform = seat.global_transform
			continue
		var mesh_name := "Port%d" % (i + 1)
		if _shell_mesh(mesh_name) == null:
			continue
		zone.position = _mesh_center_local(mesh_name)
		zone.rotation_degrees = Vector3(0.0, 0.0, 180.0)
	hide_port_placeholders(port_zones)


## The cabinet wires one card slot; use port 1's, the upper of the two openings
## on the left half of the front face.
##
## NO rotation at all, and in particular not the roll about Z the controller
## ports take, even though both are front-facing sockets on the same face. The
## difference is the thing being seated: a controller plug carries a SnapGrabPoint
## with its own 180 about X (controller_cable.tscn), so a roll composed with that
## flip comes out upright with the connector inward. A memory card has NO grab
## point, so there is nothing for the roll to compose with -- the roll simply
## turns the card over, which is how it first shipped, label down.
##
## Which end goes in has to be MEASURED, and the card's own names are a trap:
## MCard_Top.001 is the front tab you hold, the white insert that stands proud of
## the console at z +27.5 mm, while the edge connector is MCard_Board, spanning
## z -26.2 to +4.7. So the card mates along its own -Z. The shell's front face is
## +Z (MemCard1 sits at z +86 mm, JackSerial on the back panel at -86), so -Z is
## already into the console and the card wants leaving alone. Reading the +27.5 mm
## insert as the connector is what put a yaw here and seated every card backwards.
func configure_memory_card_slot(slot: Node3D, index: int) -> void:
	# Slot A only: this shell seats one card, and card_slot_count says so, but the
	# base calls once per slot the machine shows and a stray index must not land a
	# second card on top of the first.
	if _glb == null or slot == null or index != 0:
		return
	var seat := find_child("MemCardSeat", true, false) as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform
		return
	if _shell_mesh("MemCard1") == null:
		return
	slot.position = _mesh_center_local("MemCard1")
	slot.rotation_degrees = Vector3.ZERO


# --- A/V --------------------------------------------------------------------

## Three moulded RCA jacks on the rear, so the console wears sockets and no
## captive lead — the player runs a composite lead to the set, as you did.
## The SERIAL I/O socket, measured off the shell instead of placed on the box.
##
## default_model puts this at a chosen x = 0.045 and says so plainly: it is a
## stand-in that is not a PlayStation shape, and "a shell that draws its own back
## panel puts the socket where the mould actually has it by overriding this".
## This is that override, and it is the reason split_playstation.py now separates
## the rear Silver row — SERIAL I/O and AV MULTI OUT shipped inside one mesh with
## the three phono barrels, so until they were named there was nothing to ask.
##
## The socket really is beside the phono row rather than away from it: JackSerial
## centres 44.0 mm off the middle against the red AUDIO_R jack's 23.6, so 20 mm
## separates them and a hand reaching for one can catch the other. That is a fact
## about the hardware, not a spacing to fix — default_model's 37 mm gap was a
## luxury it could afford by not being a PlayStation.
##
## Same turn as configure_av_ports (180 about X, so the socket's local +Z points
## out of the panel). The shell MOULDS this socket, so nothing here draws one --
## the port arrives as a snap zone with its recess and its legend both turned off,
## exactly as the phono sockets arrive with show_jack off. Everything the player
## sees is the console's own geometry.
##
## Which leaves one job: say where a plug goes. That is JackSerial's front face,
## less SERIAL_PROUD -- this connector's origin is its mating face, and it stops
## just proud of the socket rather than flush with it. default_model uses the same
## millimetre for the same connector on the stand-in box (port at -0.126 against a
## panel at -0.125).
##
## It was placed against the model AABB's minimum z instead, which is a bulge
## somewhere else on the shell entirely: -93.37 against a socket face at -86.06.
## So the recess it was still drawing stood 7 mm out in the air behind the
## console, and read as exactly what it was.
func build_serial_port(host: Node3D, systemid: String) -> void:
	var info := SystemInfo.for_system(systemid)
	if info == null or not info.serial_port:
		return
	var m := _shell_mesh("JackSerial")
	if m == null:
		push_warning("PlayStationModel: no JackSerial in the shell; no serial socket")
		return
	var port := _SERIAL_PORT_SCENE.instantiate() as Node3D
	if port == null:
		return
	host.add_child(port)
	# The shell draws the socket and prints its name. Both of the port's own are
	# turned off, so it adds nothing to the panel and only marks the seat.
	port.set("show_legend", false)
	port.set("show_recess", false)
	var socket := _mesh_aabb_local("JackSerial")
	var c := socket.get_center()
	port.global_position = global_transform * Vector3(
		c.x, c.y, socket.position.z - SERIAL_PROUD)
	# Turned relative to the CONSOLE, not to the room. global_rotation here reads
	# as "180 about the world's X" -- so a console standing at any angle other
	# than dead ahead had its socket twisted off the panel, and a lead seated into
	# it went in crooked. configure_av_ports sets rotation, not global_rotation,
	# and has always been right for the same reason.
	port.global_basis = global_transform.basis * Basis(Vector3(1.0, 0.0, 0.0), PI)


func av_port_channels() -> Array:
	return [RcaPort.Channel.VIDEO, RcaPort.Channel.AUDIO_L, RcaPort.Channel.AUDIO_R]


## Named at export by the shell's own jack COLOURS rather than by position: the
## three inserts carry flat materials of (0.8, 0.8, 0) yellow, (0.8, 0.8, 0.8)
## white and (0.8, 0, 0) red, which is video / left / right. Reading them
## left-to-right off a render would have got it wrong — the row is not evenly
## spaced, because the grey RF DC OUT sits between the white and yellow jacks.
##
## They are RENAMED in split_playstation.py rather than resolved by their
## Sketchfab names: those contain a dot ("..._Material.001_0"), and Godot strips
## dots when it sanitises node names on import, so find_child() on the exported
## name silently matches nothing and every jack lookup here returned null.
const _JACK_MESHES := ["JackVideo", "JackAudioL", "JackAudioR"]


## Rotated 180 about X, NOT left at identity like the cable attach point below.
## The two want opposite things: a rope leaves an attach point along its local -Z,
## while a socket RECEIVES a plug along its local +Z. Identity here would face
## every socket into the console and seat every plug backwards.
func configure_av_ports(ports: Array) -> void:
	if _glb == null:
		return
	for i in mini(ports.size(), _JACK_MESHES.size()):
		var port: Node3D = ports[i]
		var m := _shell_mesh(_JACK_MESHES[i])
		if m == null:
			continue
		port.global_position = m.global_transform * m.get_aabb().get_center()
		port.rotation = Vector3(PI, 0.0, 0.0)
		if port.has_method("set"):
			port.set("show_jack", false)


## Unused while the shell wears sockets — RetroSystem builds no cable for it — but
## the attach point is still created and posed for every system.
func configure_cable_attach(attach_point: Node3D) -> void:
	if _glb != null:
		var m := _shell_mesh(_JACK_MESHES[0])
		if m != null:
			attach_point.global_position = m.global_transform * m.get_aabb().get_center()
	# The rear panel faces -Z and VerletRope leaves the attach point along its own
	# local -Z, so identity already trails the cord straight out the back and aims
	# PortVisual's +Z connector into the jack.
	attach_point.rotation = Vector3.ZERO


# --- placement ---------------------------------------------------------------

## Rest the console on whatever it is placed on. Sized to the measured shell:
## 0.2646 x 0.0544 x 0.1867 m, against a real SCPH-1001's ~265 x 52 x 185 mm.
func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.265, 0.055, 0.187)
	var pos := Vector3(0.0, 0.0275, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos
