## Puts everything under this node on render layer 2 so the street can be lit
## independently of the room.
##
## Why this is needed: QualityManager turns shadows OFF on Quest, and an
## unshadowed DirectionalLight3D lights a room's interior as though the walls
## were not there. So the room's "Dusk" light has to stay very dim (0.15) or it
## flattens everything indoors — which leaves the exterior almost black.
##
## Splitting them by cull mask lets the street have a proper golden-hour sun
## while the bedroom keeps its lamplight. The room light masks to layer 1, the
## exterior sun to layer 2, and neither touches the other.
##
## Done in code rather than the .tscn because the houses and trees are instanced
## GLB scenes: their MeshInstance3D nodes live inside the imported hierarchy and
## cannot be given a `layers` value from here without making every one an
## editable child.
extends Node3D

const EXTERIOR_LAYER := 2

## Kenney's houses ship a bright toy palette (salmon walls, mint roofs) and
## Quaternius' trees a vivid summer green. Both read as cartoon next to the
## room's muted dusk. Pull the saturation down and darken slightly so the street
## sits back where it belongs — this is a view through a window, not the subject.
@export var desaturate: float = 0.62
@export var darken: float = 0.62

## How many of the planting-bed shrubs survive on a headset. Nought disables the
## thinning and keeps every one.
##
## The street is set dressing seen through one window, and it is the largest
## single item in this room's frame. Measured on a Quest 3 at eye buffer 1.75x,
## VrApi App time, against a 24.9 ms frame: the whole exterior is 8.2 ms, of
## which the four houses are 1.15 ms, the tree row 2.44 ms, and these nine
## shrubs 4.27 ms - more than the houses and the trees together. They are
## alpha-tested foliage, which a tile-based GPU pays for in overdraw rather than
## in triangles, so their cost is out of all proportion to their size on screen.
##
## Thinned rather than removed: the bed still reads as planted from inside the
## room, which is the only place it is ever seen from.
@export var mobile_foliage_budget: int = 3

## Node-name prefix identifying those shrubs.
const FOLIAGE_PREFIX := "Plant"


## Toned materials, keyed by the instance id of the material they came from.
##
## This cache is the whole point. The first version duplicated per SURFACE, so
## two instances of the same GLB — HouseA and HouseFarB were literally the same
## model — ended up holding two different material objects with identical
## contents, and the renderer cannot batch across those. One duplicate per
## distinct source material means every instance of a model shares one, which is
## what lets them batch again. It matters more the more props go out here.
var _toned: Dictionary = {}


func _ready() -> void:
	_thin_foliage()
	for node in find_children("*", "VisualInstance3D", true, false):
		var vi := node as VisualInstance3D
		vi.layers = EXTERIOR_LAYER
		var mi := vi as MeshInstance3D
		if mi != null:
			_tone_down(mi)


## Drop all but `mobile_foliage_budget` shrubs, on a headset only.
##
## Which ones survive is by scene order rather than by anything clever: they are
## a row in a bed, so keeping the first few keeps the bed planted at one end and
## bare at the other, and the row is authored left to right across the window.
func _thin_foliage() -> void:
	if mobile_foliage_budget <= 0 or OS.get_name() != "Android":
		return
	var kept := 0
	var dropped := 0
	for child in get_children():
		if not (child is Node3D) or not String(child.name).begins_with(FOLIAGE_PREFIX):
			continue
		if kept < mobile_foliage_budget:
			kept += 1
			continue
		(child as Node3D).visible = false
		dropped += 1
	if dropped > 0:
		print("[BedroomExterior] foliage thinned: kept %d, hid %d" % [kept, dropped])


func _tone_down(mi: MeshInstance3D) -> void:
	if mi.mesh == null:
		return
	for i in mi.mesh.get_surface_count():
		# Surface override first: the ground/road/kerb set theirs in the .tscn and
		# are already the colour we want, so leave those alone.
		if mi.get_surface_override_material(i) != null:
			continue
		var mat := _tone(mi.mesh.surface_get_material(i) as BaseMaterial3D)
		if mat != null:
			mi.set_surface_override_material(i, mat)


## The muted copy of one source material, made once and reused.
func _tone(src: BaseMaterial3D) -> BaseMaterial3D:
	if src == null:
		return null
	var key := src.get_instance_id()
	if _toned.has(key):
		return _toned[key] as BaseMaterial3D
	# GLB materials are shared across every instance of the scene, so mutating
	# one in place would retint the other houses too. Duplicate first — the
	# same rule ModelMaterialFix follows.
	var mat := src.duplicate() as BaseMaterial3D

	# Foliage goes in the OPAQUE pass, on the rule poster.gd already set for this
	# project: scissor renders opaque and keeps writing depth.
	#
	# trees.glb declares its leaves "alphaMode": "BLEND", but do NOT assume that
	# means Godot gives them TRANSPARENCY_ALPHA — measured, the importer hands
	# them TRANSPARENCY_ALPHA_DEPTH_PRE_PASS (4), not 1. A first version of this
	# only tested for 1 and therefore silently did nothing at all.
	#
	# That also corrects the reason for doing it. Depth-pre-pass DOES write depth,
	# so the canopies were never mis-sorting; the win is cost, not correctness —
	# it draws the geometry twice, and scissor gets the same depth behaviour in
	# one pass.
	if mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA \
			or mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.5

	var c := mat.albedo_color
	var grey := c.get_luminance()
	mat.albedo_color = Color(
		lerp(c.r, grey, desaturate) * darken,
		lerp(c.g, grey, desaturate) * darken,
		lerp(c.b, grey, desaturate) * darken,
		c.a)
	_toned[key] = mat
	return mat
