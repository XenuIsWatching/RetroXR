## MouseOptionsPanel — floating 3D panel that displays settings for a RetroMouse.
##
## Parented to a RetroMouse node but uses top_level=true so it inherits no
## transform. Each frame it repositions itself above the owning mouse and faces
## the camera. Opened/closed via show_for()/hide_panel(); also has an in-UI ✕.
## Mirrors TVOptionsPanel / BookOptionsPanel.
class_name MouseOptionsPanel
extends FloatingObjectPanel3D

## Height above the mouse's origin at which the panel floats.
const FLOAT_HEIGHT := 0.3

var _mouse: RetroMouse = null

@onready var _viewport_node: XRToolsViewport2DIn3D = $MouseOptionsViewport


# ── Public API ─────────────────────────────────────────────────────────────────

func show_for(mouse: RetroMouse, camera: Node3D) -> void:
	_mouse = mouse
	_camera = camera
	if _mouse:
		global_position = _mouse.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	visible = true
	_ensure_ui_connected()
	_populate()


# ── Internal helpers ───────────────────────────────────────────────────────────

func _get_ui() -> MouseOptions2D:
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		return null
	return vp.get_child(0) as MouseOptions2D


func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_ensure_ui_connected")
		return
	ui.sensitivity_changed.connect(_on_sens_changed)
	ui.sensitivity_committed.connect(_on_sens_committed)
	ui.stick_changed.connect(_on_stick_changed)
	ui.stick_committed.connect(_on_stick_committed)
	ui.close_requested.connect(hide_panel)
	_ui_connected = true


func _populate() -> void:
	if not _mouse:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_populate")
		return
	ui.populate(_mouse.sensitivity, _mouse.stick_distance)


## Live while the slider is dragged.
func _on_sens_changed(value: float) -> void:
	if _mouse and is_instance_valid(_mouse):
		_mouse.sensitivity = value


## Drag finished — sensitivity is a local-feel preference (it scales the
## deltas THIS player produces), so no net replication; persistence picks it
## up from the mouse's exported property on the next save.
func _on_sens_committed(value: float) -> void:
	if _mouse and is_instance_valid(_mouse):
		_mouse.sensitivity = value


## Live while the slider is dragged.
func _on_stick_changed(value: float) -> void:
	if _mouse and is_instance_valid(_mouse):
		_mouse.stick_distance = value


## Drag finished. Like sensitivity, how far a hand may hover before the mouse
## lands is this player's feel and not room state, so it is not replicated.
func _on_stick_committed(value: float) -> void:
	if _mouse and is_instance_valid(_mouse):
		_mouse.stick_distance = value


# ── Placement, for FloatingObjectPanel3D ─────────────────────────────────────

func _target_node() -> Node3D:
	return _mouse


func _float_height() -> float:
	return FLOAT_HEIGHT
