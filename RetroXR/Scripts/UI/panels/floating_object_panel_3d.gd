## FloatingObjectPanel3D — a 2D options panel that hangs in the air above the
## thing it belongs to and turns to face the player.
##
## Ten panels had grown their own copy of the same twelve lines: top_level on,
## hidden until asked for, and a _process that parks the panel over its object
## and aims it at the camera. Nine were identical in _ready and hide_panel, six
## in _process too.
##
## Two hooks rather than one shared member, so no panel has to rename anything:
## _target_node() hands back whatever that panel already calls its subject
## (_dvd, _vcr, _card...), and _float_height() how far above it to sit. A panel
## whose placement is not "straight up from the origin" — the television, which
## measures the set's own top, the poster, which steps off the surface it is
## stuck to, and the core panel, which clears the tower — overrides _anchor()
## instead and ignores both.
##
## The double flip in _process is not redundant: look_at points the node's -Z at
## the target, and a Viewport2Din3D's face is +Z, so without the half turn every
## panel would present its back to the player.
class_name FloatingObjectPanel3D
extends Node3D

## Default distance above the subject's origin. Overridden per panel, because it
## depends on how tall the thing underneath is.
const DEFAULT_FLOAT_HEIGHT := 0.3

## The head this panel turns towards. Handed in by show_for; a panel with no
## camera still parks correctly and simply does not rotate.
var _camera: Node3D = null

## Set once the panel's 2D UI has been found and its signals wired. The lookup
## has to be deferred — the SubViewport's child does not exist on the frame the
## panel is added — so this guards against wiring the same signals twice.
var _ui_connected := false


func _ready() -> void:
	# top_level: the panel is positioned in world space every frame, so it must
	# not inherit the transform of whatever it happens to be parented under.
	top_level = true
	visible = false


func _process(_delta: float) -> void:
	if not visible:
		return
	var target := _target_node()
	if target != null and is_instance_valid(target):
		global_position = _anchor()
	_ensure_lock_row()
	if _camera != null and is_instance_valid(_camera):
		look_at(_camera.global_position, Vector3.UP)
		rotate_object_local(Vector3.UP, PI)


func hide_panel() -> void:
	visible = false


# ── Hooks ─────────────────────────────────────────────────────────────────────

## The object this panel belongs to, or null when it is not showing for anything.
func _target_node() -> Node3D:
	return null


## How far above the subject's origin to sit.
func _float_height() -> float:
	return DEFAULT_FLOAT_HEIGHT


## Where the panel should be this frame. Override for a subject whose top is not
## a fixed distance from its origin.
func _anchor() -> Vector3:
	var target := _target_node()
	if target == null or not is_instance_valid(target):
		return global_position
	return target.global_position + Vector3(0, _float_height(), 0)


# ── Lock in place ─────────────────────────────────────────────────────────────
#
# One row, added here rather than ten times over, because it is the same row on
# every panel and reads from nothing the panel knows: its subject is already
# _target_node(), and whether it can be locked is a property of the object, not
# of the menu in front of it. Panels whose subject is not pickable never grow it.
#
# The row is appended to the 2D UI's outermost box, and the viewport is grown by
# exactly its height so nothing that was already laid out is pushed out of view.

const LOCK_ROW_PX := 52
const _COLOR_ROW := Color(0.75, 0.75, 0.88)
const _COLOR_ON := Color(1.0, 0.80, 0.35)

var _lock_btn: Button = null
var _lock_grown := false


## Build the row if the 2D UI is up and the subject can be locked; keep it in
## step with the object's state while it is showing. Called every visible frame:
## a panel that rebuilds its own UI (the cartridge menu does) drops the row with
## it, and this puts it back.
func _ensure_lock_row() -> void:
	if _lock_btn != null and is_instance_valid(_lock_btn) and _lock_btn.is_inside_tree():
		_refresh_lock_row()
		return
	var target := _target_node()
	if not ObjectLock.can_lock(target):
		return
	var box := _lock_box()
	if box == null:
		return

	# The button carries its own label, so the row has no separate one: the
	# narrowest of these panels is 340 px, and a "Placement" caption beside it
	# pushed the button's text out past the panel edge.
	var row := HBoxContainer.new()
	row.name = "LockRow"
	row.add_theme_constant_override("separation", 8)
	_lock_btn = Button.new()
	_lock_btn.toggle_mode = true
	_lock_btn.custom_minimum_size = Vector2(0, 40)
	_lock_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lock_btn.add_theme_font_override("font", MenuIcons.symbols())
	_lock_btn.toggled.connect(_on_lock_toggled)
	row.add_child(_lock_btn)
	box.add_child(row)

	_grow_for_lock_row()
	_refresh_lock_row()


func _on_lock_toggled(pressed: bool) -> void:
	var target := _target_node()
	if target == null or not is_instance_valid(target):
		return
	ObjectLock.set_locked(target, pressed)
	_refresh_lock_row()


func _refresh_lock_row() -> void:
	if _lock_btn == null or not is_instance_valid(_lock_btn):
		return
	var locked := ObjectLock.is_locked(_target_node())
	_lock_btn.set_pressed_no_signal(locked)
	_lock_btn.text = "%s  %s" % [
		String.chr(MenuIcons.LOCK if locked else MenuIcons.LOCK_OPEN),
		"Locked in place" if locked else "Lock in place"]
	_lock_btn.add_theme_color_override("font_color",
		_COLOR_ON if locked else _COLOR_ROW)


## The 2D UI's outermost box — panel_root gives every menu here a
## PanelContainer > MarginContainer > box, so descend through the single-child
## chain and stop at the first box. A panel laid out some other way simply gets
## no row rather than a row in the wrong place.
func _lock_box() -> BoxContainer:
	var v := _viewport_2d()
	if v == null:
		return null
	var sv := v.get_node_or_null("Viewport") as SubViewport
	if sv == null or sv.get_child_count() == 0:
		return null
	var node: Node = sv.get_child(0)
	while node != null:
		if node is BoxContainer:
			return node as BoxContainer
		if node.get_child_count() != 1:
			return null
		node = node.get_child(0)
	return null


func _viewport_2d() -> XRToolsViewport2DIn3D:
	for c in get_children():
		if c is XRToolsViewport2DIn3D:
			return c as XRToolsViewport2DIn3D
	return null


## Make room for the row rather than squeezing the menu that was already there.
##
## The quad and the collision box come out of the packed scene SHARED between
## every panel instance, so they are made unique first — writing screen_size
## without that resizes every other open menu's screen too.
func _grow_for_lock_row() -> void:
	if _lock_grown:
		return
	_lock_grown = true
	var v := _viewport_2d()
	if v == null:
		return
	var screen := v.get_node_or_null("Screen") as MeshInstance3D
	if screen == null or not (screen.mesh is QuadMesh):
		return
	screen.mesh = screen.mesh.duplicate()
	var shape := v.get_node_or_null("StaticBody3D/CollisionShape3D") as CollisionShape3D
	if shape != null and shape.shape != null:
		shape.shape = shape.shape.duplicate()
	var vp: Vector2 = v.viewport_size
	if vp.y <= 0.0:
		return
	var grown := vp.y + LOCK_ROW_PX
	v.screen_size = Vector2(v.screen_size.x, v.screen_size.y * grown / vp.y)
	v.viewport_size = Vector2(vp.x, grown)
