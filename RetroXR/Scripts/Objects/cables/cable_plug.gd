## CablePlug — the grabbable end of a cable that snaps into a TV's CompositePort.
## Must be in the "composite_plug" group so the TV's snap zone accepts it.
## Holds a back-reference to the host that owns the cable. The host is any node
## implementing the TV contract (on_tv_connected/on_tv_disconnected/
## set_audio_volume/set_screen_enabled) — a RetroSystem or a VCRPlayer.
class_name CablePlug
extends XRToolsPickable


## The host this cable belongs to (set by the host when the cable is instantiated)
var _system: Node3D = null

## Which of the host's video-out channels this cable carries (multi-output
## hardware: 0 = TOP, 1 = BOTTOM on a dual-screen handheld). Single-cable
## hosts leave it 0.
var channel: int = 0

## Cable tag ("TOP"/"BOTTOM"); "" on single-cable hosts. Not printed on the plug —
## a lead is told from its neighbour by what it is, a trio or a lone cord, the way
## the hardware is (see RetroSystem._decorate_channel_plug).
var channel_label: String = ""

## Colour of the connector's plastic body.
##
## The bake is composite yellow, so the picture cord needs no override and the
## audio pair beside it says white and red. Surface 0 is the plastic and surface 1
## the metal — the split exists for exactly this (Tools/gen/gen_rca_plug.gd) — and the
## plating is deliberately not tintable, since plated shells are the same on every
## connector.
@export var plug_color: Color = RcaJack.COMPOSITE_YELLOW:
	set(value):
		plug_color = value
		_apply_plug_color()

## Where the cord meets this plug, in plug-local space — for
## VerletRope.end_anchor_offset.
##
## The plug's ORIGIN is its SEATING reference, the point the snap zone lines up
## with the port, and on a real connector body that sits at the collar some 40 mm
## forward of where the cable actually enters. Ending the rope at the origin runs
## the tube straight out through the barrel.
##
## Derived from the mesh rather than hardcoded, so reshaping the connector cannot
## silently desync this. Mirrors ControllerPlug.cable_anchor.
var cable_anchor: Vector3 = Vector3.ZERO


func _ready() -> void:
	super._ready()
	# Add to the snap group so TV's CompositePort (snap_require = "composite_plug") accepts us
	add_to_group("composite_plug")
	_derive_cable_anchor()
	_apply_plug_color()
	picked_up.connect(func(_p: Variant) -> void: PlugAim.aim(self))


## Tint the connector body, leaving the plating alone.
##
## The baked material belongs to the .res every plug in the room shares, so it is
## duplicated before a colour goes into it — writing straight into it would
## recolour the lot. Same rule, and the same surface, as RcaJack._apply_color;
## the exported value may also be assigned before PlugTip exists, which is why
## _ready calls this again.
func _apply_plug_color() -> void:
	var tip := get_node_or_null("PlugTip") as MeshInstance3D
	if tip == null or tip.mesh == null or tip.mesh.get_surface_count() == 0:
		return
	var base := tip.mesh.surface_get_material(0) as StandardMaterial3D
	if base == null:
		return
	# The bake is already this colour, so an override would be nothing but a second
	# copy of it — and dropping it is also what returns a plug recoloured twice to
	# the yellow it started as.
	if base.albedo_color.is_equal_approx(plug_color):
		tip.set_surface_override_material(0, null)
		return
	var mat := tip.get_surface_override_material(0) as StandardMaterial3D
	if mat == null:
		mat = base.duplicate() as StandardMaterial3D
		tip.set_surface_override_material(0, mat)
	mat.albedo_color = plug_color


func _derive_cable_anchor() -> void:
	var tip := get_node_or_null("PlugTip") as MeshInstance3D
	if tip == null or tip.mesh == null:
		return
	# One rule, stated in PlugExit rather than here as well: the cable trails -Z,
	# matching VerletRope.plug_exit_axis, so the boss is at the mesh's min Z.
	# RcaPlug already derives it this way; inlining the formula a second time is
	# how the two drift.
	cable_anchor = tip.transform * PlugExit.derive_from_mesh(tip.mesh).origin


## How far this plug may stray, as {anchor: Vector3, length: float}, or {} when
## the cable isn't built yet. Read by function_pickup so a ray grab reels the
## plug along the beam only as far as the cord actually reaches.
##
## Derived from the sibling rope rather than the host: every host already sets
## `start_node` and sizes the rope, and there are six of them (RetroSystem, VCR,
## DVD player, ...) that would otherwise each need the same accessor.
func get_tether() -> Dictionary:
	var rope := get_parent().get_node_or_null("VerletRope")
	if rope == null or not is_instance_valid(rope.start_node):
		return {}
	return {
		"anchor": (rope.start_node as Node3D).global_position,
		"length": float(rope.segment_count) * rope.segment_length,
	}


## Returns the host this cable belongs to
func get_system() -> Node3D:
	return _system


## Set the owning host (called by the host when creating the cable)
func set_system(system: Node3D) -> void:
	_system = system
