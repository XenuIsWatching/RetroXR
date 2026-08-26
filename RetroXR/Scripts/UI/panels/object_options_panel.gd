## ObjectOptionsPanel — the menu an object gets when it has no menu of its own.
##
## Every other panel here belongs to one kind of thing and knows what to say
## about it. This one knows nothing except what it is floating over, which is
## the point: it is what a table, a trash can, a cable or a controller opens,
## and the only row on it is the one FloatingObjectPanel3D puts on every panel.
##
## Created on demand and kept as a child of its subject, so it dies with it and
## a second press finds the same instance rather than stacking a new one.
class_name ObjectOptionsPanel
extends FloatingObjectPanel3D

const PANEL_SCENE := preload("res://Scenes/UI/object_options_panel.tscn")
const NODE_NAME := "ObjectOptionsPanel"

## Clear of the object's own geometry. Measured from the top of what it draws
## rather than from its origin, because these are anything from a memory card to
## a table and a fixed offset would open inside the tall ones.
const CLEARANCE := 0.18

var _object: Node3D = null


## Open or close the generic menu for `obj`. Safe to call on anything: an object
## that cannot be locked gets an empty menu, which is still an honest answer to
## "what are this thing's options".
static func toggle_for(obj: Node3D, camera: Node3D) -> void:
	if obj == null or not is_instance_valid(obj):
		return
	var panel := obj.get_node_or_null(NODE_NAME) as ObjectOptionsPanel
	if panel == null:
		panel = PANEL_SCENE.instantiate() as ObjectOptionsPanel
		panel.name = NODE_NAME
		obj.add_child(panel)
	if panel.visible:
		panel.hide_panel()
	else:
		panel.show_for(obj, camera)


func show_for(obj: Node3D, camera: Node3D) -> void:
	_object = obj
	_camera = camera
	global_position = _anchor()
	visible = true
	_populate()


func _anchor() -> Vector3:
	if _object == null or not is_instance_valid(_object):
		return global_position
	return _object.global_position + Vector3(0, _top_offset() + CLEARANCE, 0)


## How far above the object's origin its highest drawn point is. Zero for
## anything with no visible geometry, which puts the panel at the clearance and
## is as good a guess as any.
func _top_offset() -> float:
	var top := 0.0
	for vis: Node in _object.find_children("*", "VisualInstance3D", true, false):
		var v := vis as VisualInstance3D
		if v == self or is_ancestor_of(v):
			continue
		var aabb := v.global_transform * v.get_aabb()
		top = maxf(top, aabb.position.y + aabb.size.y - _object.global_position.y)
	return maxf(top, 0.0)


func _populate() -> void:
	var vp := ($ObjectOptionsViewport as XRToolsViewport2DIn3D).get_node_or_null("Viewport") as SubViewport
	if vp == null or vp.get_child_count() == 0:
		call_deferred("_populate")
		return
	var ui := vp.get_child(0) as ObjectOptions2D
	if ui == null:
		return
	if not _ui_connected:
		ui.close_requested.connect(hide_panel)
		_ui_connected = true
	ui.populate(_display_name())


## The object's own label when it has one, otherwise its node name with the
## spawn suffix Godot appends stripped off.
func _display_name() -> String:
	for prop: String in ["display_name", "game_label", "album_label"]:
		if prop in _object:
			var s := str(_object.get(prop))
			if s != "":
				return s
	var n := str(_object.name)
	var at := n.find("@")
	return n.substr(0, at) if at > 0 else n


func _target_node() -> Node3D:
	return _object
