## InputReceiver — the dongle every receiver is made of.
##
## A receiver is a small box on a 1 m lead that seats in a machine's controller
## port and forwards ONE real input device to it, with nothing held. It exists so
## your hands stay free: put the Quest controllers down and the room still works
## while the game runs on the pad, keyboard or mouse in front of you.
##
## The three subclasses differ only in what they forward:
##   PadReceiver       one named gamepad, chosen when it was spawned
##   KeyboardReceiver  the host keyboard
##   MouseReceiver     the host mouse
##
## The object IS the binding. Nothing is selected, captured or arbitrated — seat
## one per destination, unplug it to stop. Two keyboard receivers in two machines
## is a fan-out, not an ambiguity: there is one real keyboard and both ports get
## it, which is what a splitter does and what you asked for by seating two.
##
## Structurally this is RetroMultitap, not RetroController: an object that lives
## in a controller port without ever being the thing you hold. Cable, plug and
## port plumbing are borrowed from that file almost verbatim.
class_name InputReceiver
extends XRToolsPickable

const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/cables/controller_cable.tscn")

## Every live receiver. Membership is the only bookkeeping any of this needs, and
## Godot drops a freed node from its groups by itself — so there is no claim to
## release and nothing to leak when one is binned mid-session.
const GROUP := &"input_receiver"

## Long enough to sit the receiver on the shelf beside the console rather than
## have it dangle off the port, short enough not to festoon the room. The
## controller lead it is built from is 1.80 m, which is a pad's reach to a sofa —
## a receiver never needs that because the DEVICE is what travels.
const LEAD_LENGTH := 1.0

## Announced to the console when the plug seats. Overridden per subclass.
var device_type: int = 0

## Universal — RetroSystem._accepts_plug reads this off the plug, and an empty
## string fits every console's port.
var systemid: String = ""

# Port connection state (the console port this receiver's plug occupies).
var _connected_system: RetroSystem = null
var _port_index: int = -1

# Cable (same pattern as RetroController / RetroMultitap).
var _cable_instance: Node3D = null
var _cable_plug: ControllerPlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0
var _pending_port_restore: Dictionary = {}

@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _led: MeshInstance3D = $Led
@onready var _label: Label3D = $NameLabel
@onready var _glyph: Label3D = $GlyphLabel

## The glyph's authored spot, above the name. Remembered because a receiver with
## no case text moves it onto the name's spot instead.
@onready var _glyph_home: Vector3 = _glyph.position


func _ready() -> void:
	super._ready()
	press_to_hold = false
	add_to_group("spawned")
	add_to_group(GROUP)
	refresh_label()
	set_led(false)
	_spawn_cable()


# ── What a subclass fills in ──────────────────────────────────────────────────

## What this receiver is called, in logs and to anything that asks. Distinct from
## case_text: a keyboard dongle still wants a name in a print, it just does not
## want the word painted on it next to a glyph that already says so.
func receiver_label() -> String:
	return "RECEIVER"


## The words printed on the case, if any. Empty leaves the glyph to speak for
## itself — which it does for the keyboard and the mouse, where the symbol is
## unambiguous and the word beneath it was noise. A pad keeps its text because the
## glyph cannot say WHICH pad, and that is the one thing you need to read.
func case_text() -> String:
	return receiver_label()


## The device it forwards, printed as Nerd Font glyphs. One symbol says at a
## glance what a box on the floor is for, which a three-letter word does not, and
## the codepoints come from the shared TransportGlyphs table so a dongle and the
## held device's own capture icon cannot drift into two different symbols.
##
## Rendered text rather than a single key, because the wireless devices prefix a
## Bluetooth mark to theirs.
func receiver_glyph() -> String:
	return ""


## True while it has a device to forward. Drives the LED: red means this dongle
## is doing nothing, which is a state and not an error — a receiver restored into
## a room whose pad is switched off says exactly that until the pad comes back.
func is_bound() -> bool:
	return true


## True when seated in a port AND holding a device: the gate every subclass tests
## before writing to a core.
func is_live() -> bool:
	return _connected_system != null and _port_index >= 0 and is_bound()


# ── Port events ───────────────────────────────────────────────────────────────

func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	_adopt_connector(system.systemid)
	set_led(is_bound())
	print("[%s] -> %s port %d" % [receiver_label(), system.systemid, port_index])


func on_unplugged() -> void:
	on_going_idle()
	_connected_system = null
	_port_index = -1
	_adopt_connector("")
	set_led(false)


## Called before the port is let go, for a subclass with something to quieten
## (a rumbling pad, a key still held down).
func on_going_idle() -> void:
	pass


## The console this receiver is plugged into, or null. Read by ScenePersistence,
## which needs the machine to ask it for the cabinet socket.
func get_connected_system() -> RetroSystem:
	return _connected_system if is_instance_valid(_connected_system) else null


## Which port of that console this receiver occupies, or -1 when unplugged.
## The companion to get_connected_system: netplay needs both to say which global
## port a controller supplies.
func get_port_index() -> int:
	return _port_index


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if _cable_plug != null:
		system.restore_controller_plug(port_index, _cable_plug)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


## The connector this receiver should wear in a machine of `sysid`, or "" for the
## generic moulding.
##
## Asked of the SUBCLASS, because the answer depends on what is being forwarded as
## well as where it is plugged. A pad's connector is the console's — an NES 7-pin,
## an Atari DE-9 — while a keyboard or a mouse carries its own regardless of the
## machine, exactly as the held RetroKeyboard and RetroMouse do.
func connector_for(_sysid: String) -> String:
	return ""


## Wear it, or the generic moulding when we are in nothing. An unlisted machine
## gets the generic plug rather than keeping the last one's, which is why this is
## called with "" on unplug rather than simply skipped.
func _adopt_connector(sysid: String) -> void:
	if _cable_plug == null or not is_instance_valid(_cable_plug):
		return
	_cable_plug.set_plug_mesh(connector_for(sysid))
	# And move the cord's end with it. set_plug_mesh recomputes cable_anchor for
	# the new shell, and a rope still ending at the plug's ORIGIN ends on the
	# mating face — which, seated, is buried inside the socket, so the cord looks
	# detached from the connector it is supposed to leave. Every other cabled
	# peripheral sets this once at spawn because its connector never changes; a
	# receiver adopts a new one on every plug-in, so it is re-applied here.
	_apply_cable_anchor()


func _apply_cable_anchor() -> void:
	if _cable_rope == null or not is_instance_valid(_cable_rope) or _cable_plug == null:
		return
	_cable_rope.end_anchor_offset = _cable_plug.cable_anchor
	# And which way it leaves, so an angled connector can say so in its asset
	# rather than in code. End axes are independent: the host attachment at the
	# other end must not inherit an interchangeable connector's orientation.
	_cable_rope.end_exit_axis = _cable_plug.cable_exit_axis


# ── Cable ─────────────────────────────────────────────────────────────────────

func _spawn_cable() -> void:
	_cable_instance = CONTROLLER_CABLE_SCENE.instantiate()
	call_deferred("_add_cable_to_scene")


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
	_cable_instance.add_to_group("spawned")
	_cable_plug = _cable_instance.get_node("ControllerPlug") as ControllerPlug
	_cable_rope = _cable_instance.get_node("VerletRope") as VerletRope
	_cable_plug.set_controller(self)
	_cable_plug.add_collision_exception_with(self)
	# Laid out the way the attach point faces — a plug spawned on the far side
	# would drag the whole cord back around the box on the first frame.
	# In the attach point's OWN frame, not world: a dongle set down turned round
	# would otherwise have its cord laid out through the case.
	_cable_plug.global_position = _cable_attach_point.global_transform * Vector3(0, 0, -0.12)
	_cable_rope.set_rope_length(LEAD_LENGTH)
	_cable_rope.start_node = _cable_attach_point
	_cable_rope.end_node = _cable_plug
	_cable_rope.start_endpoint_role = VerletRope.ENDPOINT_HOST
	_cable_rope.end_endpoint_role = VerletRope.ENDPOINT_AUTO
	_apply_cable_anchor()
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length

	if not _pending_port_restore.is_empty():
		var sys: RetroSystem = _pending_port_restore.get("system")
		var idx: int = _pending_port_restore.get("port_index", -1)
		_pending_port_restore = {}
		if is_instance_valid(sys) and idx >= 0:
			sys.restore_controller_plug(idx, _cable_plug)


func _physics_process(_delta: float) -> void:
	# Cable rope clamp (same as RetroController / RetroMultitap).
	if _cable_plug != null and _cable_attach_point != null and _max_rope_length > 0.0 \
			and not _cable_plug.is_picked_up() and _connected_system == null:
		var attach_pos := _cable_attach_point.global_position
		var diff := _cable_plug.global_position - attach_pos
		var dist := diff.length()
		if dist > _max_rope_length:
			var dir := diff / dist
			_cable_plug.global_position = attach_pos + dir * _max_rope_length
			var outward := dir.dot(_cable_plug.linear_velocity)
			if outward > 0.0:
				_cable_plug.linear_velocity -= dir * outward


# ── Presentation ──────────────────────────────────────────────────────────────

## Red while this dongle is forwarding nothing, lit while it is. It explains
## itself without a panel, which is the whole reason it is an object rather than
## a setting.
func set_led(bound: bool) -> void:
	if _led == null:
		return
	var mat := _led.get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		return
	mat.albedo_color = Color(0.15, 0.85, 0.30) if bound else Color(0.85, 0.12, 0.12)
	mat.emission = mat.albedo_color


func refresh_label() -> void:
	var words := case_text()
	if _label != null:
		_label.text = words
	# A lone glyph moves down to the name's spot, so it reads as centred on the
	# face rather than parked above a line that is not there.
	if _glyph != null and _label != null:
		_glyph.position = _glyph_home if not words.is_empty() else _label.position
	if _glyph != null:
		var glyphs := receiver_glyph()
		_glyph.visible = not glyphs.is_empty()
		if not glyphs.is_empty():
			# The font is a FontVariation chaining the symbol font behind the
			# project default; an unchained label renders the codepoint as tofu.
			_glyph.font = TransportGlyphs.font()
			_glyph.text = glyphs


# ── Teardown ──────────────────────────────────────────────────────────────────

## Take the lead with it. The plug is a separate scene parented to the room, so
## freeing only the body would leave a cord hanging off a freed anchor — the same
## rule RetroController's cable follows.
func drop_and_free() -> void:
	if _cable_plug != null and is_instance_valid(_cable_plug):
		_cable_plug.drop()
	if _cable_instance != null and is_instance_valid(_cable_instance):
		_cable_instance.queue_free()
	# The cord goes at once, the body shrinks away: a VerletRope is a particle
	# sim, so scaling its anchor would drag the cord rather than shrink it.
	Vanish.free_node(self)
