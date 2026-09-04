## RetroSystemModelNintendo64 — a primitive stand-in at the real machine's
## figures: 260 x 190 mm on the table, 73 mm to the top of the deck. A low base
## with a raised central deck running front to back, the cartridge mouth at the
## back of that deck and the Expansion Pak well in front of it, POWER and RESET
## straddling the deck (one on each shoulder) and four controller ports across
## the front face.
##
## The bay is the point, and it works the way the hardware does: on TOP of the
## console, in front of the cartridge slot, under a small plastic lid that PULLS
## OFF. Not a hinged door -- the real cover is a separate piece you lift away and
## put down, which is why it is an ExpansionCover pickable rather than a VRHinge
## flap. So the whole sequence a player performs is the real one: pull the cover
## off and set it down, pull the Jumper Pak out, push the Expansion Pak in, put
## the cover back on.
##
## RetroSystem always builds the generic roof-centred ExpansionSocket first
## (_build_expansion_hardware), already the right FACE for this -- the override
## below only moves it forward off the cartridge deck onto ExpansionSeat, and
## adds the cover slot whose occupancy gates it. With the lid on, the socket is
## shut and out of sight; nothing can reach the pak, which is exactly what the
## lid is for.
class_name RetroSystemModelNintendo64
extends RetroSystemModelDefault


const SNAP_ZONE_SCENE := preload("res://addons/godot-xr-tools/objects/snap_zone.tscn")

var _expansion_socket: XRToolsSnapZone = null
var _cover_slot: XRToolsSnapZone = null


## The case is drawn here -- base, deck walls, both openings -- so the cabinet
## drops its own 0.3 x 0.1 x 0.25 box. That box is what made the bay impossible
## at first: its top face sat at the same height as this deck, so it sealed the
## well over completely and the pak could only ever be seen sitting ON TOP of
## the machine. RetroSystemModelDefault says false (it dresses the cabinet's
## box); this says what the base class does.
func brings_own_body() -> bool:
	return true


## With the cabinet's box hidden, its collision has to be resized to this case or
## a hand grabs 300 x 100 x 250 mm of empty air around a smaller machine -- the
## same correction wii_model.gd makes, for the same reason. The case stands from
## y 0 to 0.073 (base 0.045, deck 0.028 above it) rather than straddling the
## origin the way the cabinet's box does.
func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.26, 0.073, 0.19)
	var pos := Vector3(0.0, 0.0365, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos


## The cabinet authors its ports at z 0.125 and its buttons at y 0.06 / z 0.10 --
## the faces of the 0.3 x 0.1 x 0.25 box it draws for a model with no body of
## its own. This case is 0.26 x 0.073 x 0.19, so left alone all six of them hang
## in the air off the front. Both hooks below put them back onto real faces.
func configure_controller_ports(port_zones: Array) -> void:
	for i in port_zones.size():
		var zone := port_zones[i] as Node3D
		if zone == null:
			continue
		var seat := get_node_or_null("Front/PortSeat%d" % (i + 1)) as Node3D
		if seat != null:
			zone.global_transform = seat.global_transform
		# PortRecess stays SHOWN. It is the socket itself, not decoration on the
		# cabinet's box -- hidden, the front face keeps the four numbers and
		# loses the four holes they label, which is worse than the generic look.


## Also SHRINKS them: the cabinet's caps are scaled for a 300 mm box and read as
## boulders on a machine this size -- the green one covered a third of the deck.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	super(power_btn, reset_btn, eject_btn)
	_seat_button(power_btn, "Front/PowerSeat")
	_seat_button(reset_btn, "Front/ResetSeat")


func _seat_button(btn: Node3D, seat_path: String) -> void:
	if btn == null:
		return
	var seat := get_node_or_null(seat_path) as Node3D
	if seat == null:
		return
	btn.global_transform = seat.global_transform
	btn.scale = Vector3(0.45, 0.45, 0.45)


func configure_cartridge_slot(slot: Node3D) -> void:
	var seat := get_node_or_null("CartSeat") as Node3D
	if seat != null:
		slot.global_transform = seat.global_transform
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false


## The cabinet places its nameplate at 18% of the body height, which on the
## 100 mm generic box sat below the controller ports and on this 73 mm case
## lands straight across them -- "Nintendo 64 + Nintendo 64DD" printed over the
## port numbers.
##
## BELOW the row, not above it. Above looks like the roomier gap (15 mm of face
## between the ports and the deck against 12 mm under them) and is not: each
## port carries its NUMBER above its socket, so the usable space up there is
## about 6 mm, and a first attempt at v_center 0.50 printed the name straight
## through "1 2 3 4". The clear strip is the one under the sockets.
##
## Width needs no saying -- the cabinet already scales the label to 85% of the
## body -- so a long stack name just comes out shorter than a short one.
func name_label_placement() -> Dictionary:
	return {"upright": true, "v_center": 0.085, "h_frac": 0.10}


## Moves the generic ExpansionSocket from the roof centre (where RetroSystem
## built it, centred over the deck) forward onto ExpansionSeat, in front of the
## cartridge mouth, and builds the cover slot over it. No rotation is needed --
## unlike a bay on the underside would, this stays on the same top face the
## generic placement already used, so the socket's connector plate/pins
## (ExpansionPort._add_plate, always facing the socket's own local +Y) already
## face the right way; only the position moves.
func configure_expansion_socket(socket: Node3D) -> void:
	var seat := get_node_or_null("ExpansionBay/ExpansionSeat") as Node3D
	if seat == null:
		return
	socket.global_transform = seat.global_transform
	_expansion_socket = socket as XRToolsSnapZone
	_shrink_connector(socket)
	_build_cover_slot()
	_apply_cover_gate()


## ExpansionPort sizes its connector plate off the HOST's footprint -- 60% of
## the console's narrower span, which is right for a unit that stacks on a whole
## machine and is 114 mm here, against a well only 60 mm across. Left alone the
## plate and its pin row run straight through the deck walls and out of the
## case. Scaled rather than rebuilt because the plate belongs to ExpansionPort:
## every other console still gets the connector it always did.
func _shrink_connector(socket: Node3D) -> void:
	const BAY := Vector2(0.052, 0.036)          # inside the 60 x 50 mm opening
	const PLATE := Vector2(0.114, 0.051)        # what _add_plate built it as
	var s := Vector3(BAY.x / PLATE.x, 1.0, BAY.y / PLATE.y)
	for name in ["ConnectorPlate", "ConnectorPins"]:
		var part := socket.get_node_or_null(NodePath(name)) as Node3D
		if part != null:
			part.scale = s


## The slot the lid goes back into. Handed out so RetroSystem can answer what a
## save needs to know -- whether this console's cover is on it or lying on a
## table somewhere -- without persistence having to know the geometry.
func expansion_cover_slot() -> XRToolsSnapZone:
	return _cover_slot


func _build_cover_slot() -> void:
	if _cover_slot != null:
		return
	var seat := get_node_or_null("ExpansionBay/CoverSeat") as Node3D
	if seat == null:
		return
	var zone := SNAP_ZONE_SCENE.instantiate() as XRToolsSnapZone
	zone.name = "ExpansionCoverSlot"
	zone.snap_require = ExpansionCover.GROUP
	# Close: a lid is pushed back onto its own recess, not lowered onto a
	# console from across the table the way a whole expansion unit is.
	zone.grab_distance = 0.06
	add_child(zone)
	zone.global_transform = seat.global_transform
	zone.has_picked_up.connect(_on_cover_changed)
	zone.has_dropped.connect(_apply_cover_gate)
	_cover_slot = zone


func _on_cover_changed(_obj: Node3D) -> void:
	_apply_cover_gate()


## Lid on, bay shut. Both `enabled` AND `visible`, the same pairing every Wii
## door uses: visible alone would leave a covered socket still catching a drop,
## and whatever is seated in it -- the Jumper Pak on every fresh console -- rides
## the socket's own visibility, so this is also what puts the pak out of sight
## until the lid comes off.
func _apply_cover_gate() -> void:
	if _expansion_socket == null or not is_instance_valid(_expansion_socket):
		return
	var covered := _cover_slot != null and _cover_slot.has_snapped_object()
	_expansion_socket.set("enabled", not covered)
	_expansion_socket.visible = not covered
