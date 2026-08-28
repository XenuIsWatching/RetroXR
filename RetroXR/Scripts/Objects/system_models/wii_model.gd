## RetroSystemModelWii — the Wii, lying flat: 157 wide x 44 high x 215.4 deep.
##
## Primitive geometry authored in wii_primitive.tscn: a white slab, a grey stand, a
## long lit disc slot down the right of the face and the key column beside it. The
## machine is a set of flat panels, one slot and one flap, which is what primitives
## are good at — the same reasoning pc_tower.tscn runs on, and a detailed shell can
## replace the geometry later without touching a line of the wiring here.
##
## The front face is scaled off a photograph of the real panel: POWER, RESET, the SD
## door and EJECT run down the LEFT of the slot, not underneath it, and the keys are
## rounded rectangles with their words printed on the case rather than round caps.
##
## Everything under wii_primitive.tscn is still AUTHORED standing on end — that is
## the frame the front panel was measured in and the frame every baked mesh is
## extruded in — and the scene's root turns the finished machine onto its side. The
## consequence is that this model's local coordinates are not the cabinet's, so every
## hook below that poses a cabinet-owned node (buttons, controller ports, phono
## sockets, the disc slot) works in GLOBAL transforms.
##
## Upright is what the layout was reasoned in, and it still shows: the 44 mm face
## could not swallow a 120 mm disc flat, so the disc rides in on edge, which lying
## down becomes flat again.
##
## Two other things live here: the core options below, which are not cosmetic (the
## Wii Remote does not work at all without them), and the two sockets no other console
## in the room has — the sensor bar jack, and the AV Multi Out that replaces every
## other machine's phono row.
##
## Everything else Wii-shaped — pairing, slot arbitration, the GameCube-vs-Wii
## device ids, what happens when a bar is plugged in — lives in WiiLink, the
## component system.gd attaches to this console. This file is only the hardware
## description.
class_name RetroSystemModelWii
extends RetroSystemModelDefault


const SNAP_ZONE_SCENE := preload("res://addons/godot-xr-tools/objects/snap_zone.tscn")

## How far the SENSOR BAR socket stands proud of the panel it seats on — the
## convention rca_port.tscn is built around. The A/V socket does not use it: a Multi
## Out seats 1 mm proud, not 10, and carries its own constant below.
const AV_PORT_PROUD := 0.010

## Standby red / running green, on the small LED at the left end of the POWER key,
## which is where the real machine puts that light.
const LED_STANDBY := Color(0.80, 0.12, 0.10)
const LED_RUNNING := Color(0.20, 0.90, 0.38)

var _sensor_bar_port: XRToolsSnapZone = null
var _power_cap_mat: StandardMaterial3D = null

@onready var _power_cap: MeshInstance3D = $Front/PowerCap
@onready var _power_led: MeshInstance3D = $Front/PowerCap/PowerLed
@onready var _sd_bay: Node3D = $Front/SdBay

var _sd_hinge: VRHinge = null
var _port_zones: Array = []
var _ctrl_hinge: VRHinge = null
var _mem_hinge: VRHinge = null
## The card snap zones RetroSystem handed us, gated by the memory flap.
var _mem_zones: Array = []
var _ctrl_open := false
var _mem_open := false
var _sync_btn: VRButton = null
var _door_open := false


## Three of these, and every one is load-bearing for the Wii Remote.
##
## `dolphin_ir_passthrough = "enabled"` is what makes the remote's aim geometric.
## With it on, the frontend projects the sensor bar's two LEDs into the remote's
## own camera and hands Dolphin the pixel coordinates, so the emulated camera sees
## what a real one would — including roll and distance, which a cursor position
## cannot express. Off, the core falls back to rotating a notional remote parked
## two metres from the bar by a scale nobody can derive, and where the game draws
## its hand then depends on a constant fitted per game.
##
## `dolphin_ir_mode = "2"` is the fallback's binding: IR on the libretro POINTER
## device rather than the right analog stick. Pinned even though passthrough
## bypasses it, so that turning passthrough off in the options panel leaves a
## remote that still points instead of one that does nothing.
##
## `dolphin_save_load_settings = "disabled"` is already the core's default, and is
## pinned because of what switching it on does: the core then loads WiimoteNew.ini
## and returns EARLY from its port setup, skipping every built-in mapping —
## including both of the above. A stale profile in the Dolphin system folder would
## silently cost the player their aim, with nothing in the logs to say why.
func get_forced_core_options() -> Dictionary:
	return {
		"dolphin_ir_passthrough": "enabled",
		"dolphin_ir_mode": "2",
		"dolphin_save_load_settings": "disabled",
	}


func _ready() -> void:
	_build_sensor_bar_port()
	_label_keys()
	_build_sd_door()
	_build_gc_flaps()
	_set_power_led(false)


## The slab, the stand and the slot are all drawn here, so the cabinet drops its own
## box — and with it the procedural disc slit, which system.gd only builds for a
## model that has no geometry to put one on.
func brings_own_body() -> bool:
	return true


## The cabinet's box is 0.3 x 0.1 x 0.25 and this machine is not. One box round the
## shell — it is what a hand grabs and what the selection ray has to hit, and at
## 157 x 44 x 215 mm there is nothing worth carving out of it. In HOST space, so
## these are the laid-down dimensions rather than the authored upright ones.
func configure_collision(host: Node3D) -> void:
	var box := Vector3(0.157, 0.044, 0.2154)
	var pos := Vector3(0.0, 0.022, 0.0)
	for path in ["CollisionShape3D", "PointerArea/CollisionShape3D"]:
		var col := host.get_node_or_null(path) as CollisionShape3D
		if col != null and col.shape is BoxShape3D:
			col.shape = col.shape.duplicate()
			(col.shape as BoxShape3D).size = box
			col.position = pos


# --- the disc slot -----------------------------------------------------------

## Where a disc enters, and the pose it inherits: DiscSeat's own basis stands it on
## edge, in the plane of the machine's sides. MediaSlot rides the media along the
## slot's local -Z, which that basis leaves pointing into the console.
func configure_cartridge_slot(slot: Node3D) -> void:
	var seat: Node3D = $Front/DiscSeat
	# GLOBAL: the model root is turned on its side, so its local frame is no longer
	# the cabinet's. Same reason for every other hook that poses a cabinet-owned node.
	slot.global_transform = seat.global_transform
	var v := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if v != null:
		v.visible = false


## 107.7 mm, against the cabinet's 100 mm default — half this machine's 215.4 mm
## depth, which centres a 120 mm disc in the case the way the real drive holds it.
func slot_insert_depth() -> float:
	return 0.1077


# --- ports -------------------------------------------------------------------

## Four GameCube sockets down the controller flap on the +X side, port 1 at the
## FRONT. On a big side and not the machine's end: the two flaps measure 213.84 mm
## between them, and no 44 x 157 end face holds that at any angle.
##
## The grey recess stays VISIBLE, unlike every shell that hides it: on a primitive it
## is not a stand-in for missing geometry, it IS the socket. Its NUMBER goes, for the
## dots this hardware actually prints — see _mark_port.
func configure_controller_ports(port_zones: Array) -> void:
	for i in port_zones.size():
		var zone := port_zones[i] as Node3D
		if zone == null:
			continue
		var seat := get_node_or_null("Top/PortSeat%d" % (i + 1)) as Node3D
		if seat != null:
			zone.global_transform = seat.global_transform
		var lbl := zone.get_node_or_null("PortLabel") as Label3D
		if lbl != null:
			lbl.hide()
		_mark_port(zone, i + 1)
	_port_zones = port_zones
	# DEFERRED. RetroSystem sets each zone's visible/enabled from the port count a few
	# lines after calling this, so hiding them here is overwritten a moment later and
	# the sockets show straight through a shut door. Next idle frame wins.
	_apply_ctrl_gate.call_deferred()


## Dots per port, not a number: one for player 1 up to four for player 4, which is
## how this family marks its sockets.
##
## A quarter turn clockwise from the way they would be printed: they run along the
## zone's local +Y — down the bay, the same way the sockets march — and sit off its
## +X, which is across the bay's 36 mm width.
##
## The offset has to be the ACROSS one either way. On the 28 mm centres this flap
## uses, a group offset along the bay lands nearer its neighbour's socket than its
## own; across, there is nothing for it to collide with.
const PORT_DOT_R := 0.0011
const PORT_DOT_PITCH := 0.0034
const PORT_DOT_OFFSET := 0.012


func _mark_port(zone: Node3D, count: int) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = PORT_DOT_R
	mesh.bottom_radius = PORT_DOT_R
	mesh.height = 0.0006
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.86, 0.86, 0.84)
	mat.roughness = 0.5
	var span: float = PORT_DOT_PITCH * float(count - 1)
	for i in count:
		var dot := MeshInstance3D.new()
		dot.name = "PortDot%d" % (i + 1)
		dot.mesh = mesh
		dot.set_surface_override_material(0, mat)
		# Authored on +Y like every CylinderMesh, so lay it flat against the panel:
		# the zone's local +Z is the way out of the face.
		dot.rotation = Vector3(PI / 2.0, 0.0, 0.0)
		dot.position = Vector3(
			PORT_DOT_OFFSET,
			-span * 0.5 + PORT_DOT_PITCH * float(i),
			0.004)
		zone.add_child(dot)


## ONE socket, not three. The Wii has no phono jacks at all: picture and both audio
## channels leave through a single AV Multi Out shell, and the trio of phonos lives on
## the far end of the lead, at the television.
##
## The channel LIST is still the stereo trio inherited from the default model, which
## is what says this machine's sound is stereo and which speaker each cord feeds. Only
## the packaging differs, which is the whole of what av_ports_are_multi_way says.
func av_ports_are_multi_way() -> bool:
	return true


## Seat that socket on the marker the scene authored, which carries its basis as well
## as its place — the key has to land on the EJECT side of the panel, and no basis
## derived here could say so. See the AvSeat note in wii_primitive.tscn.
##
## Pushed out along the seat's own +Z by the connector's proud offset, the way every
## socket on this machine is: 2 mm for a Multi Out, against the phono row's 10 and the
## DE-15's 7.5. wii_av_port.tscn carries the same number and says why.
const AV_MULTI_PROUD := 0.002


func configure_av_ports(ports: Array) -> void:
	if ports.is_empty():
		return
	var seat: Node3D = $Back/AvSeat
	# GLOBAL, like every other hook here: the sockets belong to the cabinet and this
	# model is lying on its side relative to it.
	var t: Transform3D = seat.global_transform
	(ports[0] as Node3D).global_transform = Transform3D(
		t.basis, t.origin + t.basis.z.normalized() * AV_MULTI_PROUD)


# --- front panel -------------------------------------------------------------

## POWER, RESET and EJECT onto the three caps the scene draws, all three travelling
## INTO the front face along -Z. VRButton defaults to -Y, which is right for a cap on
## a top face and wrong for one facing you: it sinks the cap down through the panel
## instead of into it.
##
## set_button_mesh adopts the real cap AND clears the button's state_tint, so
## RetroSystem stops painting the generic green/red START/STOP colour onto it. That
## is wanted: the standby light belongs on the POWER cap alone, and _set_power_led
## below owns it. The word labels go with it — this machine prints no words on its
## caps, and a floating "START" over a 13 mm disc of plastic is not what it looks
## like.
func configure_buttons(power_btn: VRButton, reset_btn: VRButton, eject_btn: VRButton) -> void:
	_mount_cap(power_btn, _power_cap)
	_mount_cap(reset_btn, $Front/ResetCap)
	_mount_cap(eject_btn, $Front/EjectCap)


## SYNC onto the red cap in the SD bay, which is where the real machine hides it —
## behind the same door as the card slot, and the reason it is the one control on this
## console anybody has to be told about.
##
## Placed from here rather than in configure_buttons because the cabinet does not
## build this button with the other three: it grows one only for hardware that pairs
## wireless pads, later in the sequence. Left alone it keeps system.tscn's pose,
## which is on the procedural box's top face and, on this body, mid-air.
##
## Kept INERT while the door is shut, not merely hidden — a snap zone or a button
## that stops drawing goes on catching hands, so `set_active` is the switch and
## `visible` alone is not.
func configure_sync_button(sync_btn: VRButton) -> void:
	_sync_btn = sync_btn
	_mount_cap(sync_btn, $Front/SdBay/SyncCap)
	sync_btn.set_active(_door_open)


# --- the SD door -------------------------------------------------------------

## How far the door swings. 105 degrees, a little past square, which is where a flap
## on a vertical hinge sits once it has been pushed out of the way.
const SD_DOOR_OPEN_DEG := 105.0
## Past this the bay behind counts as reachable.
const SD_DOOR_OPEN_AT := 25.0


## Hang the SD door on a hinge, the way the real one hangs: on its LEFT edge, swinging
## sideways out of the way rather than dropping down.
##
## Everything about that direction is in the MOUNT's authored basis. VRHinge turns its
## target about the target's PARENT frame's X — not the target's own, whatever the
## class comment says — so the basis has to sit one level up and the pivot it drives
## has to stay at identity. Every offset below is in that mount frame: local X runs
## DOWN the face, local Y across it to the right, local Z out of it.
##
## grip_engages, like the NES's cartridge flap: nobody picks a console up by a 22 mm
## door, so the squeeze is free to mean "open this", and the hinge mutes that hand's
## pickup while it is inside the grab box so the machine stays on the shelf.
func _build_sd_door() -> void:
	# The PIVOT, not the mount above it: VRHinge writes target.rotation.x, and Euler
	# rotation is composed in the parent's frame, so the axis it turns about is the
	# MOUNT's X. The pivot itself must stay at identity — see wii_primitive.tscn.
	var pivot := $Front/SdDoorMount/SdDoorPivot as Node3D
	if pivot == null:
		return
	_sd_hinge = VRHinge.new()
	_sd_hinge.name = "SdDoorGrab"
	_sd_hinge.target = pivot
	_sd_hinge.min_deg = 0.0
	_sd_hinge.max_deg = SD_DOOR_OPEN_DEG
	_sd_hinge.grip_engages = true
	_sd_hinge.engage_radius = 0.045
	pivot.add_child(_sd_hinge)
	# On the door's free (right-hand) half, where a hand actually takes hold of a flap.
	# Measured from the HINGE, which now sits out on the chamfer, so the free edge is
	# a little over 20 mm away round the bend rather than 19 across a flat.
	_sd_hinge.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.017, 0.006))
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	# 60 mm down the door, 14 across it, 16 deep — sized in the PIVOT's frame, so the
	# long axis is the vertical one.
	box.size = Vector3(0.060, 0.014, 0.016)
	col.shape = box
	_sd_hinge.add_child(col)
	# Hint just past the free edge, in the door's own plane.
	_sd_hinge.place_hint(Vector3(0.0, 0.013, 0.006))
	_sd_hinge.rotation_changed.connect(_on_sd_door_moved)


func _on_sd_door_moved(deg: float) -> void:
	var open := deg > SD_DOOR_OPEN_AT
	if open == _door_open:
		return
	_door_open = open
	if _sd_bay != null:
		_sd_bay.visible = open
	if _sync_btn != null and is_instance_valid(_sync_btn):
		_sync_btn.set_active(open)


# --- the GameCube flaps ------------------------------------------------------

## Both doors over the controller and memory card bays, each on its own hinge.
##
## Same three-node shape as the SD door and for the same reason — VRHinge turns its
## target about the target's PARENT frame's X — so the scene carries the basis on a
## static mount and these drive the identity pivot under it.
##
## grip_engages, like the NES's cartridge flap: nobody picks a console up by a 36 mm
## door, so the squeeze is free to mean "open this", and the hinge mutes that hand's
## pickup while it is inside the grab box so the machine stays on the shelf.
func _build_gc_flaps() -> void:
	_ctrl_hinge = _hang_flap("Top/CtrlFlapMount/CtrlFlapPivot", "CtrlFlapGrab", 0.123)
	if _ctrl_hinge != null:
		_ctrl_hinge.rotation_changed.connect(_on_ctrl_flap_moved)
	_mem_hinge = _hang_flap("Top/MemFlapMount/MemFlapPivot", "MemFlapGrab", 0.06434)
	if _mem_hinge != null:
		_mem_hinge.rotation_changed.connect(_on_mem_flap_moved)


func _hang_flap(pivot_path: String, grab_name: String, band: float) -> VRHinge:
	var pivot := get_node_or_null(pivot_path) as Node3D
	if pivot == null:
		return null
	var hinge := VRHinge.new()
	hinge.name = grab_name
	hinge.target = pivot
	hinge.min_deg = 0.0
	hinge.max_deg = FLAP_OPEN_DEG
	hinge.grip_engages = true
	hinge.engage_radius = 0.05
	pivot.add_child(hinge)
	# On the door's free half, measured in the mount's frame: local X along the hinge,
	# local Y across the face, local Z out of it.
	hinge.transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.028, 0.003))
	var col := CollisionShape3D.new()
	col.name = "CollisionShape3D"
	var box := BoxShape3D.new()
	box.size = Vector3(band * 0.7, 0.016, 0.014)
	col.shape = box
	hinge.add_child(col)
	hinge.place_hint(Vector3(0.0, 0.012, 0.006))
	return hinge


## Past this a bay counts as reachable.
const FLAP_OPEN_AT := 25.0
## How far a door swings — a little past square, where a flap pushed out of the way
## sits.
const FLAP_OPEN_DEG := 105.0


func _on_ctrl_flap_moved(deg: float) -> void:
	var open := deg > FLAP_OPEN_AT
	if open == _ctrl_open:
		return
	_ctrl_open = open
	_apply_ctrl_gate()


## The bay and its sockets follow the controller door. `enabled` as well as `visible`:
## a snap zone that merely stops drawing goes on catching plugs, so a pad could be
## pushed through a shut flap — which the real machine does not allow either.
func _apply_ctrl_gate() -> void:
	var grp := get_node_or_null("Top/CtrlGroup") as Node3D
	if grp != null:
		grp.visible = _ctrl_open
	for z in _port_zones:
		var zone := z as Node3D
		if zone != null and is_instance_valid(zone):
			zone.set("enabled", _ctrl_open)
			zone.visible = _ctrl_open


func _on_mem_flap_moved(deg: float) -> void:
	var open := deg > FLAP_OPEN_AT
	if open == _mem_open:
		return
	_mem_open = open
	_apply_mem_gate()


## Two GameCube card slots, in the bay under the memory flap.
func card_slot_count() -> int:
	return 2


## How far a seated card's CENTRE sits outside the bay face. A GameCube card is
## 51 mm long and goes in about half its length, the same as the PlayStation's
## does, so its middle ends up close to the face and roughly half stands out
## where a hand can reach it.
const MEMCARD_PROUD := 0.001


## Seat one card zone on the MemSlot mesh that draws it, and shut it again if the
## flap is closed.
##
## The gate is re-applied here rather than only from the hinge because
## RetroSystem enables every slot it is showing a moment before calling this, and
## the door starts shut — without it a card could be pushed into a closed machine
## on the first frame.
func configure_memory_card_slot(slot: Node3D, index: int) -> void:
	var anchor := get_node_or_null("Top/MemGroup/MemSlot%d" % (index + 1)) as Node3D
	if anchor == null or slot == null:
		return
	# NOT a straight copy of the anchor's transform, which is what a controller
	# port takes: a plug disappears into its socket, and a card must not. Copied
	# outright, a seated card sat wholly inside the shell -- invisible, and with
	# nothing standing out to take hold of.
	#
	# The anchor is the slit drawn on the bay's face. Its local Z runs ALONG that
	# slit and its local Y is the face normal, so the card is turned to enter
	# edge-first: its width across the slit, its length along the normal.
	# Constructed by columns, which is what Basis(x, y, z) takes -- the transpose
	# of the row-major form a .tscn prints.
	const CARD_TURN := Basis(Vector3(0, 0, 1), Vector3(1, 0, 0), Vector3(0, 1, 0))
	var t := anchor.global_transform
	slot.global_transform = Transform3D(t.basis * CARD_TURN,
		t.origin + t.basis.y.normalized() * MEMCARD_PROUD)
	if not _mem_zones.has(slot):
		_mem_zones.append(slot)
	_apply_mem_gate.call_deferred()


## The Wii keeps its GameCube card slots under a door, so a card can only go in
## when the door is open.
##
## `enabled` as well as `visible`, for the same reason _apply_ctrl_gate sets
## both: a snap zone that has merely stopped drawing goes on catching what is
## dropped near it, so a card would vanish into a shut machine.
func _apply_mem_gate() -> void:
	var grp := get_node_or_null("Top/MemGroup") as Node3D
	if grp != null:
		grp.visible = _mem_open
	for z in _mem_zones:
		var zone := z as Node3D
		if zone != null and is_instance_valid(zone):
			zone.set("enabled", _mem_open)
			zone.visible = _mem_open


# --- printed legends ---------------------------------------------------------

## The two symbols the front panel prints ON its keys, as opposed to the words it
## prints on the case beside them.
##
## Set here rather than in the scene because a .tscn cannot chain the symbol font
## behind the project default, and these codepoints are private-use: authored there
## they would both render as tofu. Same arrangement pc_tower_model.gd uses for its
## back-panel icons.
const KEY_GLYPHS := {
	"Front/PowerCap/PowerGlyph": "power",
	"Front/EjectCap/EjectGlyph": "eject",
}


func _label_keys() -> void:
	for path: String in KEY_GLYPHS:
		var lbl := get_node_or_null(path) as Label3D
		if lbl == null:
			continue
		lbl.font = TransportGlyphs.font()
		lbl.text = TransportGlyphs.glyph(str(KEY_GLYPHS[path]))


func _mount_cap(btn: VRButton, cap: MeshInstance3D) -> void:
	if btn == null or cap == null:
		return
	btn.global_transform = Transform3D(cap.global_transform.basis, cap.global_position)
	# 0.8 mm, against the 2.5 mm these keys stand proud of the front face (the
	# baked cap meshes reach z 0.1102, the body ends at 0.1077). It used to be
	# 1.5 mm, which cleared the panel by a millimetre on paper but swallowed 60%
	# of the key on every press, and with the dark seam plate drawn behind each
	# one that reads as the cap sinking through the case rather than clicking.
	#
	# A real key on this machine barely moves. Travel is for feedback here, not
	# for depth, so it wants to be a fraction of what stands proud.
	btn.depress_depth = 0.0008
	btn.depress_axis = Vector3(0, 0, -1)
	btn.set_button_mesh(cap)
	var lbl := btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl != null:
		lbl.hide()


func on_power_on() -> void:
	super.on_power_on()
	_set_power_led(true)


func on_power_off() -> void:
	super.on_power_off()
	_set_power_led(false)


## Red asleep, green awake, on the small LED at the left end of the POWER key — which
## is where the real machine puts it. The key itself stays the case's own off-white.
##
## Emissive either way: these rooms light with a flat ambient and no radiance map, so
## an unlit red dot is just a dark dot. Its own material, built here rather than
## overridden from the scene's, because the LED has no other state to inherit.
func _set_power_led(on: bool) -> void:
	if _power_led == null:
		return
	if _power_cap_mat == null:
		_power_cap_mat = StandardMaterial3D.new()
		_power_cap_mat.emission_enabled = true
		_power_cap_mat.roughness = 0.4
		_power_led.set_surface_override_material(0, _power_cap_mat)
	var c: Color = LED_RUNNING if on else LED_STANDBY
	_power_cap_mat.albedo_color = c
	_power_cap_mat.emission = c
	_power_cap_mat.emission_energy_multiplier = 1.4 if on else 0.5


# --- nameplate ---------------------------------------------------------------

## The scene prints "Wii" at the foot of the front face itself, small and grey, where
## the machine has it. The cabinet's own nameplate would put the full system name —
## "NINTENDO WII" — across the whole 44 mm width in its place.
func prints_own_name() -> bool:
	return true


# --- sensor bar --------------------------------------------------------------

## The sensor bar jack, or null before _ready. WiiLink wires the handlers; this
## only builds the socket, because a socket is hardware and this file is the
## hardware description.
func get_sensor_bar_port() -> XRToolsSnapZone:
	return _sensor_bar_port


## The console's own SENSOR BAR connector, seated on the marker the scene authored.
##
## Built here rather than in system.tscn because no other console has one. The cabinet
## scene is shared by every machine in the room, and a jack only a Wii can use would
## sit dead on all of them — the same reason the disc tray is grown by the model that
## needs it instead of shipped with the box.
##
## The zone accepts only SensorBar.PLUG_GROUP, which nothing else joins, so the filter
## needs no callback: a controller plug bounces off it and its own plug fits nothing
## else. The KEY does the rest — one corner of the mouth is cut and the plug's barrel
## carries the matching cut on the OPPOSITE corner of its own section, because a snap
## zone relates the two by a reflection rather than a rotation. See
## Tools/gen/gen_wii_sensor.gd.
##
## Under $Back like the A/V socket, and for the reason that one records: the seat is a
## local position in the back panel's frame, so a zone parented to the model would
## ignore whatever transform that panel carries.
##
## The printed word is authored in the scene beside the socket, not built here. It
## belongs to the FACE — it has to read the way the rest of the case printing does —
## and a label parented to a socket inherits that socket's frame instead.
func _build_sensor_bar_port() -> void:
	var seat: Node3D = $Back/SensorSeat
	_sensor_bar_port = SNAP_ZONE_SCENE.instantiate() as XRToolsSnapZone
	_sensor_bar_port.name = "SensorBarPort"
	_sensor_bar_port.grab_distance = 0.03
	_sensor_bar_port.snap_require = String(SensorBar.PLUG_GROUP)
	($Back as Node3D).add_child(_sensor_bar_port)
	# Where a seated plug's ORIGIN belongs, which is its hood face: 1.5 mm proud, the
	# red moulding's own thickness. Against the phono row's 10 and the Multi Out's 1.
	_sensor_bar_port.transform = Transform3D(seat.transform.basis,
		seat.position + seat.transform.basis.z.normalized() * SENSOR_PROUD)
	# The jack pushed back by that much so its panel face lands on the case — the rule
	# rca_port.tscn is built around, applied to a socket grown in code.
	var jack := MeshInstance3D.new()
	jack.name = "WiiSensorJack"
	jack.mesh = load("res://Scenes/Objects/system_models/wii/wii_sensor_jack.res")
	jack.position = Vector3(0.0, 0.0, -SENSOR_PROUD)
	_sensor_bar_port.add_child(jack)


## The proud offset for this connector. Its own number, like every socket on this
## machine — see the MATING note in Tools/gen/gen_wii_sensor.gd.
const SENSOR_PROUD := 0.0015
