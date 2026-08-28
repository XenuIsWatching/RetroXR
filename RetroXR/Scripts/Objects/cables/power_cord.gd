class_name PowerCord
extends Node3D

@onready var rope: VerletRope = $VerletRope
@onready var wall_plug: RcaPlug = $WallPlug
@onready var appliance_plug: RcaPlug = $AppliancePlug

func _ready() -> void:
	wall_plug.cable = self
	appliance_plug.cable = self
	call_deferred("_build_rope")

func _build_rope() -> void:
	if not is_inside_tree():
		return
	rope.start_node = wall_plug
	rope.end_node = appliance_plug
	rope.start_anchor_offset = wall_plug.cable_anchor
	rope.end_anchor_offset = appliance_plug.cable_anchor
	rope._init_points()

func on_plug_seating_changed() -> void:
	pass
