## RetroKeyboard — pickable keyboard that plugs into a RetroSystem controller
## port (same cable/plug as a controller). Cores see RETRO_DEVICE_KEYBOARD:
## key presses update the poll bitset AND fire the core's keyboard event
## callback (ScummVM, DOSBox, home computers).
##
## VR typing: the key grid is built procedurally; each hand presses at most the
## single nearest key under its controller tip (so a palm can't mash a row).
## Real-keyboard passthrough is OPT-IN: hold the board and press Scroll Lock — or
## F3, for the many boards that have no Scroll Lock key — to capture, which
## floats a keyboard glyph off its near edge and suspends WASD locomotion so
## the keys reach the core instead of the player. Either key again — or simply
## dropping the board — releases it. Neither reaches the core while capture is on,
## so a literal F3 or Scroll Lock is typed on this board's own F3 and SCR caps.
## Keys route from here, offline straight to the core and in netplay through the
## deterministic schedule, sinking the matching virtual keycap on the way. This is
## the only OS-keyboard path; the extension no longer feeds keys on its own.
class_name RetroKeyboard
extends XRToolsPickable


const CONTROLLER_CABLE_SCENE := preload("res://Scenes/Objects/cables/controller_cable.tscn")
## PC99 purple, the keyboard half of the colour code. Swapped in over the cable
## scene's generic tapered cylinder, which is a 20 mm cone standing in for any
## plug at all — fine for the console controllers that share this cable, twice
## life size for a mini-DIN.
const PLUG_MESH := "res://Scenes/Objects/cables/ps2_plug_keyboard.res"
const RETRO_DEVICE_KEYBOARD := 3

# Key grid geometry (board-local metres). X = right, Z = toward the user.
const KEY_PITCH := 0.021       # 1u - full-size 104-key board is ~50 cm wide
const KEY_GAP := 0.0025        # spacing between caps
const KEY_TOP_Y := 0.014       # resting key-cap top
const PRESS_TRAVEL := 0.0015   # cap sink when pressed: rests 2 mm proud of
							   # the 0.012 plate top, so this leaves it just
							   # barely above rather than buried under it
## Rumble queue slot for a keystroke. Per hand, so both may type at once.
const HAPTIC_KEY := &"kb_key"

const PRESS_Y := 0.010         # tip below this (board-local) = pressed
const RELEASE_Y := 0.0135      # tip must clear this to let go, and to re-arm
const PRESS_FLOOR := -0.05     # driven below this, the tip has left the board

# RETROK_* keycodes (libretro.h).
const RK := {
	"esc": 27, "bksp": 8, "tab": 9, "return": 13, "space": 32, "pause": 19,
	"minus": 45, "equals": 61, "lbracket": 91, "backslash": 92, "rbracket": 93,
	"backquote": 96, "semicolon": 59, "quote": 39, "comma": 44, "period": 46,
	"slash": 47, "delete": 127,
	"up": 273, "down": 274, "right": 275, "left": 276,
	"insert": 277, "home": 278, "end": 279, "pgup": 280, "pgdn": 281,
	"numlock": 300, "capslock": 301, "scrlk": 302,
	"rshift": 303, "lshift": 304, "rctrl": 305, "lctrl": 306,
	"ralt": 307, "lalt": 308, "lsuper": 311, "rsuper": 312,
	"print": 316, "menu": 319,
	"kp0": 256, "kp1": 257, "kp2": 258, "kp3": 259, "kp4": 260, "kp5": 261,
	"kp6": 262, "kp7": 263, "kp8": 264, "kp9": 265, "kp_dot": 266,
	"kp_div": 267, "kp_mul": 268, "kp_minus": 269, "kp_plus": 270,
	"kp_enter": 271,
}

## US layout: keycode -> the CHARACTER produced while shift is held
## (shift+4 = $, shift+; = :, ...). Letters are handled separately.
const SHIFT_MAP := {
	49: 33,   # 1 !
	50: 64,   # 2 @
	51: 35,   # 3 #
	52: 36,   # 4 $
	53: 37,   # 5 %
	54: 94,   # 6 ^
	55: 38,   # 7 &
	56: 42,   # 8 *
	57: 40,   # 9 (
	48: 41,   # 0 )
	45: 95,   # - _
	61: 43,   # = +
	91: 123,  # [ {
	93: 125,  # ] }
	92: 124,  # \ |
	59: 58,   # ; :
	39: 34,   # ' "
	44: 60,   # , <
	46: 62,   # . >
	47: 63,   # / ?
	96: 126,  # ` ~
}

## Layout: array of {z: row position in key units, keys: Array}. Each key is
## [label, retrok, width_u] with optional 4th element height_u (numpad + and
## Enter are 2 rows tall); a null label = spacer gap. Column plan: main block
## 0..15u, nav cluster 15.5..18.5u, numpad 19..23u - the standard US ANSI
## 104-key arrangement.
var _layout: Array = []

## libretro device type reported to the system when plugged in.
var device_type: int = RETRO_DEVICE_KEYBOARD

# Port connection state
var _connected_system: RetroSystem = null
var _port_index: int = -1

# Cable (same pattern as RetroController / RetroMouse)
var _cable_instance: Node3D = null
var _cable_plug: ControllerPlug = null
var _cable_rope: VerletRope = null
var _max_rope_length: float = 0.0
var _pending_port_restore: Dictionary = {}

# Key grid: array of {rect: Rect2 (x,z), keycode, char, mesh, base_y}.
var _keys: Array = []
# Currently pressed keycode per hand tracker name ("" -> keycode or -1).
var _hand_pressed: Dictionary = {}
# Per hand: may it START a press? Set only by rising clear of the caps, so a tip
# driven through the board cannot type again on its way back out.
var _hand_armed: Dictionary = {}
var _controllers: Array = []
# keycode -> key index (visual feedback when a REAL keyboard drives us).
var _key_index_by_code: Dictionary = {}
# True while any hand (VR or desktop) holds the board.
var _held := false
# Scroll Lock capture: while on, real keys go to the core instead of the game.
# Opt-in (holding alone no longer hijacks the keyboard) and always a subset of
# _held, so it can never outlive the grip and strand the player with WASD blocked.
var _capture: ScrollLockCapture = null
var _hint: HeldHint = null
# Key index the desktop pointer / VR laser is currently holding down, or -1,
# and the controller behind it when that pointer is a VR laser.
var _pointer_key := -1
var _pointer_ctrl: XRController3D = null
# Whether the caps currently show their shifted glyphs, and whether a real
# keyboard's Shift is down (so passthrough typing relabels the caps too).
var _labels_shifted := false
var _os_shift_held := false

## Nerd Font: keyboard — shown off the near edge of the board while Scroll Lock
## capture is on.
const ICON_CAPTURE := 0xF11C
const SYMBOL_FONT_PATH := "res://fonts/SymbolsNerdFont-Regular.ttf"
## Height of the capture glyph, in metres.
const ICON_SIZE := 0.035
## Height of the hint popup above the board, in metres.
const HINT_HEIGHT := 0.20

@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _key_root: Node3D = $Keys


func _ready() -> void:
	super._ready()
	press_to_hold = false
	add_to_group("spawned")
	_build_layout()
	_build_keys()
	_spawn_cable()
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	_capture = ScrollLockCapture.attach(self, _can_capture,
		ICON_CAPTURE, ICON_SIZE)
	# No drop row: the board lets go on a plain release on both platforms.
	_hint = HeldHint.attach(self, false, HINT_HEIGHT)
	_hint.add_row(&"capture", HeldHint.PLATFORM_DESKTOP,
		["keyboard_scroll_lock_outline"], "or F3 — send keys here")
	call_deferred("_find_controllers")


func _find_controllers() -> void:
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node)


func _build_layout() -> void:
	_layout = []
	var F: Array = []
	for i in range(12):
		F.append(["F%d" % (i + 1), 282 + i, 1.0])

	# Function row (z 0): ESC, F1-F4 / F5-F8 / F9-F12 groups, PrtSc/ScrLk/Pause.
	var func_row: Array = [["ESC", RK.esc, 1.0], [null, 0, 1.0]]
	func_row += F.slice(0, 4) + [[null, 0, 0.5]] + F.slice(4, 8)
	func_row += [[null, 0, 0.5]] + F.slice(8, 12)
	func_row += [[null, 0, 0.5],
		["PRT", RK.print, 1.0], ["SCR", RK.scrlk, 1.0], ["PAU", RK.pause, 1.0]]
	_layout.append({"z": 0.0, "keys": func_row})

	# Main rows sit 0.4u below the function row.
	var digits: Array = [["`", RK.backquote, 1.0]]
	for d in "1234567890":
		digits.append([d, d.unicode_at(0), 1.0])
	digits += [["-", RK.minus, 1.0], ["=", RK.equals, 1.0], ["BKSP", RK.bksp, 2.0]]
	digits += [[null, 0, 0.5],
		["INS", RK.insert, 1.0], ["HOM", RK.home, 1.0], ["PUP", RK.pgup, 1.0],
		[null, 0, 0.5],
		["NUM", RK.numlock, 1.0], ["/", RK.kp_div, 1.0], ["*", RK.kp_mul, 1.0],
		["-", RK.kp_minus, 1.0]]
	_layout.append({"z": 1.4, "keys": digits})

	var qrow: Array = [["TAB", RK.tab, 1.5]]
	for c in "qwertyuiop":
		qrow.append([c.to_upper(), c.unicode_at(0), 1.0])
	qrow += [["[", RK.lbracket, 1.0], ["]", RK.rbracket, 1.0],
		["\\", RK.backslash, 1.5]]
	qrow += [[null, 0, 0.5],
		["DEL", RK.delete, 1.0], ["END", RK.end, 1.0], ["PDN", RK.pgdn, 1.0],
		[null, 0, 0.5],
		["7", RK.kp7, 1.0], ["8", RK.kp8, 1.0], ["9", RK.kp9, 1.0],
		["+", RK.kp_plus, 1.0, 2.0]]
	_layout.append({"z": 2.4, "keys": qrow})

	var arow: Array = [["CAPS", RK.capslock, 1.75]]
	for c in "asdfghjkl":
		arow.append([c.to_upper(), c.unicode_at(0), 1.0])
	arow += [[";", RK.semicolon, 1.0], ["'", RK.quote, 1.0],
		["ENTER", RK["return"], 2.25]]
	arow += [[null, 0, 4.0],
		["4", RK.kp4, 1.0], ["5", RK.kp5, 1.0], ["6", RK.kp6, 1.0]]
	_layout.append({"z": 3.4, "keys": arow})

	var zrow: Array = [["SHIFT", RK.lshift, 2.25]]
	for c in "zxcvbnm":
		zrow.append([c.to_upper(), c.unicode_at(0), 1.0])
	zrow += [[",", RK.comma, 1.0], [".", RK.period, 1.0], ["/", RK.slash, 1.0],
		["SHIFT", RK.rshift, 2.75]]
	zrow += [[null, 0, 1.5], ["↑", RK.up, 1.0], [null, 0, 1.5],
		["1", RK.kp1, 1.0], ["2", RK.kp2, 1.0], ["3", RK.kp3, 1.0],
		["ENT", RK.kp_enter, 1.0, 2.0]]
	_layout.append({"z": 4.4, "keys": zrow})

	var space_row: Array = [
		["CTRL", RK.lctrl, 1.25], ["SUPER", RK.lsuper, 1.25], ["ALT", RK.lalt, 1.25],
		["SPACE", RK.space, 6.25],
		["ALT", RK.ralt, 1.25], ["SUPER", RK.rsuper, 1.25], ["MENU", RK.menu, 1.25],
		["CTRL", RK.rctrl, 1.25],
		[null, 0, 0.5],
		["←", RK.left, 1.0], ["↓", RK.down, 1.0], ["→", RK.right, 1.0],
		[null, 0, 0.5],
		["0", RK.kp0, 2.0], [".", RK.kp_dot, 1.0]]
	_layout.append({"z": 5.4, "keys": space_row})


func _build_keys() -> void:
	var cap_mat := StandardMaterial3D.new()
	cap_mat.albedo_color = Color(0.22, 0.22, 0.26)

	# Board extents from the layout (key units), centred on the body.
	var max_xu := 0.0
	var max_zu := 0.0
	for rowd: Dictionary in _layout:
		var xu := 0.0
		var hz := 1.0
		for k: Array in rowd["keys"]:
			xu += float(k[2])
			if k.size() > 3:
				hz = maxf(hz, float(k[3]))
		max_xu = maxf(max_xu, xu)
		max_zu = maxf(max_zu, float(rowd["z"]) + hz)
	var x0 := -(max_xu * KEY_PITCH) / 2.0
	var z0 := -(max_zu * KEY_PITCH) / 2.0

	for rowd: Dictionary in _layout:
		var zr := float(rowd["z"])
		var x := x0
		for k: Array in rowd["keys"]:
			var w := float(k[2]) * KEY_PITCH
			if k[0] == null:
				x += w   # spacer gap
				continue
			var hu := float(k[3]) if k.size() > 3 else 1.0
			var d := hu * KEY_PITCH
			var mesh := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(w - KEY_GAP, 0.008, d - KEY_GAP)
			mesh.mesh = box
			mesh.set_surface_override_material(0, cap_mat)
			var cz := z0 + (zr + hu / 2.0) * KEY_PITCH
			mesh.position = Vector3(x + w / 2.0, KEY_TOP_Y - 0.004, cz)
			_key_root.add_child(mesh)
			var lbl := Label3D.new()
			var base_text := str(k[0])
			lbl.text = base_text
			lbl.pixel_size = 0.0004
			lbl.font_size = 18 if base_text.length() == 1 else 9
			lbl.rotation_degrees = Vector3(-90, 0, 0)
			lbl.position = Vector3(x + w / 2.0, KEY_TOP_Y + 0.001, cz)
			_key_root.add_child(lbl)
			# Glyph shown while shift is held: number-row / punctuation keys swap
			# to their US shifted symbol; letters already read uppercase so they
			# (and every non-symbol key) keep their label.
			var shift_text := base_text
			if SHIFT_MAP.has(int(k[1])):
				shift_text = String.chr(int(SHIFT_MAP[int(k[1])]))
			_keys.append({
				"rect": Rect2(x, z0 + zr * KEY_PITCH, w, d),
				"keycode": int(k[1]),
				"mesh": mesh,
				"label": lbl,
				"base_text": base_text,
				"shift_text": shift_text,
				"base_y": mesh.position.y,
				"label_base_y": lbl.position.y,
			})
			# First physical key wins the visual-feedback slot (left modifiers).
			if not _key_index_by_code.has(int(k[1])):
				_key_index_by_code[int(k[1])] = _keys.size() - 1
			x += w

	# Fit the body + collision to the computed grid (the tscn ships a
	# placeholder size; resources are duplicated so instances never share).
	var bw := max_xu * KEY_PITCH + 0.024
	var bd := max_zu * KEY_PITCH + 0.024
	var base := get_node_or_null("BaseMesh") as MeshInstance3D
	if base and base.mesh is BoxMesh:
		var bm := base.mesh.duplicate() as BoxMesh
		bm.size = Vector3(bw, 0.012, bd)
		base.mesh = bm
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		var shape := col.shape.duplicate() as BoxShape3D
		shape.size = Vector3(bw, 0.02, bd)
		col.shape = shape
	var attach := get_node_or_null("CableAttachPoint") as Node3D
	if attach:
		attach.position = Vector3(0, 0.008, -bd / 2.0)

	# Pointer-clickable key field. One thin box over the whole grid — the caps
	# are bare meshes with no colliders, so _key_at() resolves which one was hit.
	if get_node_or_null("KeyPointerField") == null:
		var field := KeyboardKeyField.create(self,
			Vector3(0.0, KEY_TOP_Y + 0.002, 0.0),
			Vector3(max_xu * KEY_PITCH, 0.006, max_zu * KEY_PITCH))
		add_child(field)


# ── Cable (mirrors RetroController) ──────────────────────────────────────────

func _spawn_cable() -> void:
	_cable_instance = CONTROLLER_CABLE_SCENE.instantiate()
	call_deferred("_add_cable_to_scene")


func _add_cable_to_scene() -> void:
	get_tree().current_scene.add_child(_cable_instance)
	_cable_instance.add_to_group("spawned")
	_cable_plug = _cable_instance.get_node("ControllerPlug") as ControllerPlug
	_cable_rope = _cable_instance.get_node("VerletRope") as VerletRope
	_cable_plug.set_plug_mesh(PLUG_MESH)
	_cable_plug.set_controller(self)
	_cable_plug.add_collision_exception_with(self)
	_cable_plug.global_position = _cable_attach_point.global_position + Vector3(0, 0, -0.12)
	_cable_rope.start_node = _cable_attach_point
	_cable_rope.end_node = _cable_plug
	# End the cord AT the connector's cable boss. The plug's origin is its
	# SEATING reference, buried up at the collar, so a zero offset runs the tube
	# out through the barrel.
	_cable_rope.end_anchor_offset = _cable_plug.cable_anchor
	_cable_rope._init_points()
	_max_rope_length = _cable_rope.segment_count * _cable_rope.segment_length

	if not _pending_port_restore.is_empty():
		var sys: RetroSystem = _pending_port_restore.get("system")
		var idx: int = _pending_port_restore.get("port_index", -1)
		_pending_port_restore = {}
		if is_instance_valid(sys) and idx >= 0:
			sys.restore_controller_plug(idx, _cable_plug)


# ── Port events (duck-typed contract used by RetroSystem) ────────────────────

func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	_connected_system = system
	_port_index = port_index
	print("[RetroKeyboard] plugged into system port %d" % port_index)
	# Plugging in only makes capture *possible*; the player still opts in.
	if _capture:
		_capture.refresh()


func on_unplugged() -> void:
	print("[RetroKeyboard] unplugged from port %d" % _port_index)
	_release_all()
	_set_capture(false)
	_connected_system = null
	_port_index = -1


func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	_held = true
	if _hint:
		_hint.on_grabbed(by)
	if _capture:
		_capture.refresh()


func _on_dropped_signal(_pickable: Node3D) -> void:
	_held = false
	if _hint:
		_hint.on_dropped()
	# Capture never outlives the grip — otherwise WASD stays blocked with no way
	# to walk back to the board and press Scroll Lock (or F3) again.
	_set_capture(false)
	if _capture:
		_capture.refresh()


## True while this board owns the real keyboard: Scroll Lock capture is on, a
## hand holds it, and it is plugged into a system. Real keys (desktop OS keyboard,
## or a Bluetooth keyboard paired to the Quest) then route through here, netplay
## schedule included. There is no longer a raw C++ keyboard path to suppress.
func _os_capture_active() -> bool:
	return _capture != null and _capture.is_active()


## Whether capture could be turned on right now — held and plugged into a port.
func _can_capture() -> bool:
	return _held and _connected_system != null and _port_index >= 0


func _set_capture(active: bool) -> void:
	if _capture == null:
		return
	var was := _capture.is_active()
	_capture.set_active(active)
	if was and not _capture.is_active():
		_release_all()


func restore_port_connection(system: RetroSystem, port_index: int) -> void:
	if _cable_plug != null:
		system.restore_controller_plug(port_index, _cable_plug)
	else:
		_pending_port_restore = {"system": system, "port_index": port_index}


# ── VR key pressing ───────────────────────────────────────────────────────────

func _physics_process(_delta: float) -> void:
	# Cable rope clamp (same as RetroController).
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

	_scan_hands()


## One key per hand, on a press-down / rise-to-release cycle. There is nothing
## solid under a controller, so a hand pushing a key keeps going and ends up
## BELOW the board; the press therefore has to survive that, and the way back up
## must not read as a fresh keystroke. Hence the two rules: the band reaches well
## past the underside (PRESS_FLOOR), and only a hand that has risen clear of the
## caps is armed to begin a press at all.
func _scan_hands() -> void:
	for ctrl: Node in _controllers:
		if not is_instance_valid(ctrl) or not (ctrl as XRController3D).get_is_active():
			continue
		var name_key := str((ctrl as XRController3D).tracker)
		var tip: Vector3 = to_local(PokeTip.tip_of(ctrl as Node3D))
		var prev: int = _hand_pressed.get(name_key, -1)
		if tip.y > RELEASE_Y:
			_hand_armed[name_key] = true
		# Hysteresis: a key goes down at PRESS_Y and only lets go at the higher
		# RELEASE_Y, so a tip resting on the threshold cannot chatter.
		var enter := RELEASE_Y if prev >= 0 else PRESS_Y
		var hit := -1
		if tip.y <= enter and tip.y >= PRESS_FLOOR:
			var k := _key_at(Vector2(tip.x, tip.z))
			# A hand already holding a key may slide onto its neighbour.
			if k >= 0 and (prev >= 0 or bool(_hand_armed.get(name_key, false))):
				hit = k
		if hit >= 0:
			_hand_armed[name_key] = false
		if hit == prev:
			continue
		if prev >= 0:
			_set_key(prev, false)
		if hit >= 0:
			_set_key(hit, true)
		# The cap has no travel you can feel, so the tick is the whole of the
		# key's feedback. Sliding onto a neighbour reads as a fresh press.
		Haptics.click(ctrl as XRController3D, hit >= 0, HAPTIC_KEY)
		_hand_pressed[name_key] = hit
	_refresh_shift_labels()


## Pointer (desktop reticle / VR laser) pressed or dragged onto the key field.
## `at` is a global point; KeyboardKeyField routes it here. Independent of Scroll
## Lock capture — clicking a specific cap is unambiguous intent and cannot
## collide with WASD the way raw keyboard input does.
## `by` is the pointer node behind the press; the laser's rumbles, the desktop
## reticle's resolves to no controller and silently does not.
## True when a cap lies under this world point. KeyboardKeyField asks before
## claiming a press, so aims that land between the keys reach the board instead.
func has_key_at(at: Vector3) -> bool:
	var local := to_local(at)
	return _key_at(Vector2(local.x, local.z)) >= 0


func pointer_press_at(at: Vector3, by: Node3D = null) -> void:
	var local := to_local(at)
	var hit := _key_at(Vector2(local.x, local.z))
	if by != null:
		_pointer_ctrl = Haptics.controller_of(by)
	if hit == _pointer_key:
		return
	if _pointer_key >= 0:
		_set_key(_pointer_key, false)
	if hit >= 0:
		_set_key(hit, true)
	Haptics.click(_pointer_ctrl, hit >= 0, HAPTIC_KEY)
	_pointer_key = hit


## Pointer released or left the field — let go of whatever it was holding.
func pointer_release() -> void:
	if _pointer_key >= 0:
		_set_key(_pointer_key, false)
		_pointer_key = -1
		Haptics.click(_pointer_ctrl, false, HAPTIC_KEY)
	_pointer_ctrl = null


func _key_at(p: Vector2) -> int:
	for i in range(_keys.size()):
		if (_keys[i]["rect"] as Rect2).has_point(p):
			return i
	return -1


func _set_key(index: int, down: bool) -> void:
	var k: Dictionary = _keys[index]
	_set_cap_pressed(k, down)
	_send_key(int(k["keycode"]), down)


## Sink or raise one cap. The legend is a separate Label3D floating just above the
## cap, so it has to travel with it or a pressed key keeps its lettering hovering
## at rest height. Single place for the move: the real-keyboard path used to
## duplicate it and could only ever drift.
func _set_cap_pressed(k: Dictionary, down: bool) -> void:
	var sink := PRESS_TRAVEL if down else 0.0
	(k["mesh"] as MeshInstance3D).position.y = float(k["base_y"]) - sink
	var lbl := k["label"] as Label3D
	if lbl != null:
		lbl.position.y = float(k["label_base_y"]) - sink


func _release_all() -> void:
	pointer_release()
	for name_key: String in _hand_pressed:
		var idx: int = _hand_pressed[name_key]
		if idx >= 0:
			_set_key(idx, false)
	_hand_pressed.clear()
	_os_shift_held = false
	_refresh_shift_labels()


## True while a SHIFT is held — either on-board cap (either hand) or a real
## keyboard's Shift while this board owns the OS-keyboard feed.
func _shift_held() -> bool:
	if _os_shift_held:
		return true
	for name_key: String in _hand_pressed:
		var idx: int = _hand_pressed[name_key]
		if idx >= 0 and int(_keys[idx]["keycode"]) in [RK.lshift, RK.rshift]:
			return true
	return false


## Swap every keycap's label between its normal and shifted glyph to match the
## current shift state. Cheap: only touches labels when the state flips.
func _refresh_shift_labels() -> void:
	var want := _shift_held()
	if want == _labels_shifted:
		return
	_labels_shifted = want
	for k: Dictionary in _keys:
		var lbl := k["label"] as Label3D
		var text: String = k["shift_text"] if want else k["base_text"]
		if lbl.text == text:
			continue
		lbl.text = text
		lbl.font_size = 18 if text.length() == 1 else 9


# ── Key routing ───────────────────────────────────────────────────────────────

func _send_key(keycode: int, down: bool) -> void:
	if _connected_system == null:
		return
	var character := 0
	if keycode >= 32 and keycode <= 126:
		character = keycode
		if _shift_held():
			if keycode >= 97 and keycode <= 122:
				character = keycode - 32           # uppercase letters
			elif SHIFT_MAP.has(keycode):
				character = int(SHIFT_MAP[keycode])  # US shifted symbols ($, :, ...)
	# Netplay: key events ride the deterministic frame schedule.
	if NetworkManager.netplay_queue_key(_connected_system, keycode, down, character):
		return
	_connected_system.get_libretro_node().SetKeyState(0, keycode, down, character)


## Real-keyboard passthrough: while this board is PICKED UP and plugged, keys
## from a physical keyboard (desktop OS, or a Bluetooth keyboard on Quest)
## drive it — offline straight to the core, during netplay through the
## deterministic schedule. The matching virtual keycap sinks for feedback.
## (The C++ raw OS path is suppressed via SetOsKeyboardCapture while active.)
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or key.is_echo():
		return

	# Scroll Lock and F3 both toggle capture. Tested BEFORE the capture
	# gate below — behind it, the toggle could only ever switch capture off.
	if _capture != null and _capture.handle_key(key):
		get_viewport().set_input_as_handled()
		return

	if not _os_capture_active():
		return
	if _handle_os_key(key, key.is_pressed()):
		get_viewport().set_input_as_handled()


## Route one real-keyboard transition. Returns true when consumed.
## Takes the whole event: GodotKeyToRetroKey reads its `location` to tell the
## left and right Shift/Ctrl/Alt/Super apart, which a bare keycode cannot.
func _handle_os_key(event: InputEventKey, pressed: bool) -> bool:
	var lib: Libretro = _connected_system.get_libretro_node()
	if lib == null:
		return false
	var keycode: int = lib.GodotKeyToRetroKey(event)
	if keycode == 0:
		return false
	var unicode := int(event.unicode)
	# A real Shift relabels the caps just like an on-board SHIFT does.
	if keycode in [RK.lshift, RK.rshift]:
		_os_shift_held = pressed
		_refresh_shift_labels()
	# Visual: sink the matching virtual keycap.
	var idx: int = _key_index_by_code.get(keycode, -1)
	if idx >= 0:
		_set_cap_pressed(_keys[idx], pressed)
	var character := unicode
	if character == 0 and keycode >= 32 and keycode <= 126:
		character = keycode
	if NetworkManager.netplay_queue_key(_connected_system, keycode, pressed, character):
		return true
	_connected_system.get_libretro_node().SetKeyState(0, keycode, pressed, character)
	return true

# ── Capture teardown ──────────────────────────────────────────────────────────

func _exit_tree() -> void:
	if _capture:
		_capture.release()
	super._exit_tree()
