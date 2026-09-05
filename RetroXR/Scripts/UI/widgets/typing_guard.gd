## TypingGuard — while a text field has focus, the keyboard belongs to the field
## and nothing else.
##
## On desktop the same keys do several jobs at once: WASD walks, and a held pad
## or keyboard with Scroll Lock capture on forwards keystrokes to the core. Type
## "mario" into the cartridge search and the A walks you sideways while the M and
## R reach the game. Focus is the signal that the player is composing text, so
## for as long as it lasts this blocks desktop locomotion and suspends capture.
##
## Released on Enter, on Escape, or on losing focus by any other route.
##
## Registered as an autoload and patched onto every LineEdit and TextEdit as it
## enters the tree — same mechanism as VRKeyboardFix, so a new text field is
## covered with no work at the call site.
##
## Naturally desktop-only: CHANNEL_DESKTOP_MOVE gates only the desktop movement
## providers, and ScrollLockCapture is unreachable unless something is
## desktop-held. In VR this costs nothing and blocks nothing.
class_name TypingGuard
extends Node

const OWNER := &"typing"

## The field currently being typed into, or null.
var _field: Control = null
var _loco: LocomotionManager = null


func _ready() -> void:
	get_tree().node_added.connect(_on_node_added)
	# Anything built before this autoload was ready.
	_patch_tree(get_tree().root)


func _on_node_added(node: Node) -> void:
	if node is LineEdit or node is TextEdit:
		_watch(node as Control)


func _patch_tree(root: Node) -> void:
	if root is LineEdit or root is TextEdit:
		_watch(root as Control)
	for c in root.get_children():
		_patch_tree(c)


## Idempotent, so a field that is re-parented or patched twice is unaffected.
func _watch(field: Control) -> void:
	if field.has_meta("typing_guard"):
		return
	field.set_meta("typing_guard", true)
	field.focus_entered.connect(_on_focus.bind(field))
	field.focus_exited.connect(_on_blur.bind(field))
	field.gui_input.connect(_on_gui_input.bind(field))
	var le := field as LineEdit
	if le != null:
		# Enter. Dropping focus is what releases the block, so this and the
		# Escape path below both end up in _on_blur.
		le.text_submitted.connect(func(_text: String) -> void: le.release_focus())


func _on_gui_input(event: InputEvent, field: Control) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed:
		return
	# Escape from any field, and Enter from a TextEdit — a LineEdit reports Enter
	# as text_submitted instead, and a TextEdit would otherwise just add a line.
	var done := key.keycode == KEY_ESCAPE \
		or (field is TextEdit and key.keycode in [KEY_ENTER, KEY_KP_ENTER])
	if done:
		field.release_focus()
		field.accept_event()


func _on_focus(field: Control) -> void:
	_field = field
	_apply(true)


func _on_blur(field: Control) -> void:
	if _field != field:
		return
	_field = null
	_apply(false)


## A field freed while focused emits nothing, and a movement block that outlives
## its owner strands the player with no way to walk. Cheap insurance.
func _process(_delta: float) -> void:
	if _field == null:
		return
	if not is_instance_valid(_field) or not _field.has_focus():
		_field = null
		_apply(false)


func _apply(typing: bool) -> void:
	ScrollLockCapture.set_suspended(typing)
	var loco := _locomotion()
	if loco != null:
		loco.set_block(OWNER, LocomotionManager.CHANNEL_DESKTOP_MOVE, typing)


## Re-resolved when stale: the manager belongs to the player rig, so a scene
## change frees it while this autoload lives on.
func _locomotion() -> LocomotionManager:
	if is_instance_valid(_loco):
		return _loco
	_loco = get_tree().root.find_child("LocomotionManager", true, false) as LocomotionManager
	return _loco
