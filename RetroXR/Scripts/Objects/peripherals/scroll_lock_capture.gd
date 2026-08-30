## ScrollLockCapture — shared "the real keyboard drives this device" toggle.
##
## Several held devices consume keyboard input that would otherwise move the
## player: the RetroKeyboard's keys, and the buttons a virtual pad or handheld
## binds to RETRO_JOYPAD_* actions. Holding one used to hijack those keys
## silently. Capture makes it opt-in instead — press Scroll Lock or F3 while
## holding the device to take the keyboard, shown by a glyph floating off its near
## edge, with WASD locomotion suspended for as long as it lasts.
##
## Two keys, because Scroll Lock is the better NAME for this — it reads as a lock,
## and nothing else wants it — but whole classes of keyboard have no such key:
## laptops, TKLs, 60% boards, and most of the Bluetooth boards you would pair with
## a Quest. Those players could not reach capture at all. F3 is on every keyboard,
## is not a modifier (so it needs no gesture beyond a press, the way a bare Alt
## would have), and was otherwise unbound here.
##
## Capture is always a subset of "eligible" (held, and plugged into a system), so
## it can never outlive the grip and strand the player with movement blocked. The
## host clears it on drop by calling refresh().
##
## A physical gamepad is not gated by this and never reaches a held device at all:
## it drives the port its own PadReceiver is plugged into. Nor are the input
## receivers, which are unheld by definition — seating one is already the
## unambiguous act that Scroll Lock exists to supply for a board you might merely
## be carrying. They do honour the typing suspension below.
class_name ScrollLockCapture
extends RefCounted

const SYMBOL_FONT_PATH := "res://fonts/SymbolsNerdFont-Regular.ttf"
## Clear air between the device's +Z face and the near edge of the glyph, in metres.
const ICON_GAP := 0.02
## The keys that toggle capture. Either one does the whole job on its own, and
## both are swallowed while this host is eligible, so neither reaches the core —
## a captured RetroKeyboard sends a literal one from its own SCR or F3 keycap.
## Plain ints rather than Array[Key]: GDScript has no enum-typed arrays.
const TOGGLE_KEYS: Array[int] = [KEY_SCROLLLOCK, KEY_F3]

var _host: Node3D = null
## Callable() -> bool: may this host capture right now (held and plugged)?
var _eligible: Callable = Callable()
var _icon: Label3D = null
var _icon_size := 0.035
var _loco: LocomotionManager = null
var _active := false


## `glyph` is a Nerd Font codepoint; `size` is the glyph's height in metres. Where
## it sits comes from the host's own shapes, so no caller measures its device.
static func attach(host: Node3D, eligible: Callable, glyph: int,
		size := 0.035) -> ScrollLockCapture:
	var cap := ScrollLockCapture.new()
	cap._host = host
	cap._eligible = eligible
	cap._build_icon(glyph, size)
	cap._find_locomotion_manager.call_deferred()
	return cap


## Set while the player is typing into a text field — see TypingGuard. Global
## rather than per-instance: the keyboard is one device, so if it is composing
## text it is not driving any held device.
static var _suspended := false


## Suspend every capture without clearing it, so the Scroll Lock state the player
## chose survives whatever interrupted it.
static func set_suspended(on: bool) -> void:
	_suspended = on


## Read by the input receivers, which have no capture of their own but must still
## keep out of a text field the player is typing into.
static func is_suspended() -> bool:
	return _suspended


func is_active() -> bool:
	return _active and not _suspended and _can_capture()


func _can_capture() -> bool:
	return _eligible.is_valid() and bool(_eligible.call())


## Handle one key event. Returns true only when this host was eligible and so
## actually consumed it — an ineligible device must let a toggle key through, or
## whichever device happens to be first in the tree would swallow it and the one
## actually in your hand would never toggle.
func handle_key(event: InputEventKey) -> bool:
	# Not while typing: a toggle key pressed inside a text field should neither
	# toggle capture nor be swallowed here.
	if not TOGGLE_KEYS.has(event.keycode) or _suspended or not _can_capture():
		return false
	if event.is_pressed():
		set_active(not _active)
	return true


func set_active(active: bool) -> void:
	var want := active and _can_capture()
	if want == _active:
		return
	_active = want
	if _active:
		# The one place a capture actually turns on, so the one place the hint
		# advertising it can count as learned.
		HeldHint.note_on(_host, &"capture")
	_apply()


## Re-check eligibility — call on grab/drop/plug. Capture cannot survive losing
## the grip, so this is what clears it.
func refresh() -> void:
	if _active and not _can_capture():
		_active = false
	_apply()


## Drop the locomotion block; for the host's _exit_tree.
func release() -> void:
	_active = false
	if _loco != null:
		_loco.set_block(_owner(), LocomotionManager.CHANNEL_DESKTOP_MOVE, false)
	if is_instance_valid(_icon):
		_icon.visible = false


func _apply() -> void:
	if is_instance_valid(_icon):
		if _active:
			_place_icon()
		_icon.visible = _active
	if _loco != null:
		_loco.set_block(_owner(), LocomotionManager.CHANNEL_DESKTOP_MOVE, _active)


## Per-instance, so two held devices cannot clear each other's block.
func _owner() -> StringName:
	return StringName("capture_%d" % _host.get_instance_id())


func _find_locomotion_manager() -> void:
	if not is_instance_valid(_host) or not _host.is_inside_tree():
		return
	_loco = _host.get_tree().root.find_child(
		"LocomotionManager", true, false) as LocomotionManager
	_apply()


## Sit the glyph just past the +Z face of the device, measured on every show: a
## shell model can resize the body long after attach.
func _place_icon() -> void:
	_icon.position = Vector3(0.0, 0.0, _body_reach_z() + _icon_size * 0.5 + ICON_GAP)


## How far the host's own body reaches along its local +Z. Only the shapes that
## body owns count — an Area3D button, a pointer volume and the hands wrapped
## round the device are all children of the host, and none of them is its edge.
func _body_reach_z() -> float:
	var body := _host as CollisionObject3D
	if body == null:
		return 0.0
	var reach := 0.0
	for owner_id: int in body.get_shape_owners():
		if body.is_shape_owner_disabled(owner_id):
			continue
		var xf: Transform3D = body.shape_owner_get_transform(owner_id)
		for i in range(body.shape_owner_get_shape_count(owner_id)):
			var shape: Shape3D = body.shape_owner_get_shape(owner_id, i)
			if shape == null:
				continue
			reach = maxf(reach, (xf * shape.get_debug_mesh().get_aabb()).end.z)
	return reach


## Same recipe as vr_hinge.gd's _build_icon: billboarded Label3D with the Symbols
## Nerd Font as a fallback, sized in metres, drawn over geometry.
func _build_icon(glyph: int, size: float) -> void:
	var existing := _host.get_node_or_null("CaptureHint") as Label3D
	if existing != null:
		_icon = existing
	else:
		_icon = Label3D.new()
		_icon.name = "CaptureHint"
		_host.add_child(_icon)
	var fv := FontVariation.new()
	fv.base_font = ThemeDB.fallback_font
	var symbols: Font = load(SYMBOL_FONT_PATH)
	if symbols:
		fv.fallbacks = [symbols]
	_icon_size = size
	_icon.font = fv
	_icon.font_size = 96
	_icon.pixel_size = size / 96.0
	_icon.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_icon.no_depth_test = true
	_icon.render_priority = 2
	_icon.outline_size = 18
	_icon.outline_modulate = Color(0.0, 0.0, 0.0, 0.7)
	_icon.text = String.chr(glyph)
	_icon.modulate = Color(1.0, 0.82, 0.28)
	_place_icon()
	_icon.visible = false
