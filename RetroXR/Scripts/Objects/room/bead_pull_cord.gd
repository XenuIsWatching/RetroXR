## A ball-chain pull cord that hangs from a lamp, swings, and toggles it.
##
## The simulation is VerletRope's, not a second one. A pull cord is the free-end
## case that rope already supports: pin the head, leave `end_node` null, and the
## tail hangs. It also sleeps when it settles and wakes when disturbed, which
## matters here — GDScript verlet cables are what saturated the main thread in the
## 20 fps Quest diagnosis, so a cord that costs nothing while still is the whole
## point.
##
## What this adds is the LOOK and the interaction:
##
##  * Beads, not a tube. VerletRope renders an ArrayMesh tube and rebuilds it
##    whenever the rope moves; a chain wants discrete balls, and a MultiMesh draws
##    however many of them in ONE call with no mesh rebuild at all — cheaper than
##    the thing it replaces. Beads are resampled along the curve rather than
##    placed per particle, so ~10 simulated points render as ~26 beads.
##  * A pull. Proximity plus TRIGGER, via VRButton's require_trigger mode, which
##    is this project's interaction model for contextual actions — not a touch
##    button, which fires on any drifting hand.
##
## Yanking displaces the tail particle and lets the solver do the rest, so the
## swing afterwards is simulated rather than animated. That is the "flow".
class_name BeadPullCord
extends Node3D


## Fired on each pull, after the yank is applied.
signal pulled(on: bool)


## The light this cord switches, as a PATH. It has to be a NodePath rather than a
## `Light3D` export: object exports are stored as resource references in a .tscn
## and silently ignore `NodePath(...)`, so an assignment that looks right leaves
## the property null. Toggled by `visible`, never by energy — QualityManager owns
## light_energy for anything in the ceiling_light group, and although these lamps
## are deliberately outside it, visibility is safe either way.
@export var light_path: NodePath

## Extra nodes to switch with the light — a GlowMesh shade, say.
@export var glow: NodePath

@export var cord_length: float = 0.2
@export var segments: int = 9
## Draw beads, or leave the rope's own tube as a plain cord. A lamp switch is a
## ball chain; a blind cord is a flat string, and drawing beads on one reads wrong.
@export var beads: bool = true
## Tube radius used when `beads` is false.
@export var cord_radius: float = 0.0022

@export var bead_count: int = 26
@export var bead_radius: float = 0.0055
@export var bead_color: Color = Color(0.72, 0.68, 0.44)

## How hard a pull yanks the tail, in metres of displacement.
@export var yank: float = 0.055

## Cord state at startup, matched to how the scene authors the lamp.
@export var lit: bool = true

const _SIM_SEGMENTS_MIN := 4

## The switch click. ONE clip for both directions on purpose: a pull-chain switch
## is the same detent going over centre either way, so it genuinely sounds the
## same turning on as off.
const PULL_CLIP := "res://Audio/lamp/chain_pull.wav"

var _sfx: PcmOneShot = null
var _pull_frames: PackedVector2Array = []
var _rope: VerletRope = null
var _beads: MultiMeshInstance3D = null
var _button: VRButton = null
var _tail := Vector3.ZERO


var light: Light3D = null


func _ready() -> void:
	if not light_path.is_empty():
		light = get_node_or_null(light_path) as Light3D
	_build_rope()
	if beads:
		_build_beads()
	_build_button()
	_build_sfx()
	_apply()


func _build_sfx() -> void:
	_pull_frames = PcmClip.load_frames(PULL_CLIP)
	_sfx = PcmOneShot.new()
	_sfx.name = "PullSfx"
	# Closer and quieter than the CRT hum: a click is a small, local event, and
	# the cord is something you have to be within arm's reach of to pull anyway.
	_sfx.unit_size = 0.6
	_sfx.max_distance = 3.0
	_sfx.volume = 0.5
	add_child(_sfx)


func _build_rope() -> void:
	_rope = VerletRope.new()
	_rope.name = "Cord"
	_rope.segment_count = maxi(_SIM_SEGMENTS_MIN, segments)
	_rope.segment_length = cord_length / float(_rope.segment_count)
	# Inextensible, floppy, and cheap: a chain does not stretch and does not resist
	# bending. Six iterations, not two — at two a 0.16 m cord hung 0.181 m, since
	# stiffness is remapped per iteration and two passes cannot hold a 10-particle
	# chain rigid under gravity.
	_rope.stretch_stiffness = 1.0
	_rope.bend_stiffness = 0.0
	_rope.constraint_iterations = 6
	_rope.damping = 0.06
	_rope.tube_radius = 0.0016 if beads else cord_radius
	_rope.tube_sides = 3
	# start_node pins the head to this node; end_node stays NULL so the tail is
	# free, which is what makes it a pull cord rather than a slung cable.
	_rope.start_node = self
	_rope.end_node = null
	# No _init_points() call here: VerletRope._ready does it, and add_child fires
	# _ready immediately since we are already in the tree. Calling it again would
	# rebuild the particles a second time.
	add_child(_rope)


func _build_beads() -> void:
	var sphere := SphereMesh.new()
	sphere.radius = bead_radius
	sphere.height = bead_radius * 2.0
	sphere.radial_segments = 6
	sphere.rings = 3

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = sphere
	mm.instance_count = bead_count

	var mat := StandardMaterial3D.new()
	mat.albedo_color = bead_color
	mat.metallic = 0.75
	mat.roughness = 0.35

	_beads = MultiMeshInstance3D.new()
	_beads.name = "Beads"
	_beads.multimesh = mm
	_beads.material_override = mat
	# The beads are placed in GLOBAL space from the rope's own points, so this
	# must not inherit our transform on top of that.
	_beads.top_level = true
	add_child(_beads)


func _build_button() -> void:
	_button = VRButton.new()
	_button.name = "PullZone"
	_button.collision_layer = 0
	_button.collision_mask = 0
	# Trigger, not touch: a touch button fires on any hand that drifts near, and
	# a cord dangling at head height would toggle the lamp constantly.
	_button.require_trigger = true
	_button.interact_margin = 0.045
	_button.depress_depth = 0.0
	_button.top_level = true

	var mesh := MeshInstance3D.new()
	mesh.name = "ButtonMesh"
	var cap := SphereMesh.new()
	cap.radius = bead_radius * 1.9
	cap.height = bead_radius * 3.8
	cap.radial_segments = 6
	cap.rings = 3
	mesh.mesh = cap
	var mat := StandardMaterial3D.new()
	mat.albedo_color = bead_color.darkened(0.15)
	mat.metallic = 0.7
	mat.roughness = 0.4
	mesh.material_override = mat
	_button.add_child(mesh)

	var col := CollisionShape3D.new()
	var shape := SphereShape3D.new()
	shape.radius = bead_radius * 3.4
	col.shape = shape
	_button.add_child(col)

	add_child(_button)
	_button.button_pressed.connect(_on_pulled)


func _process(_delta: float) -> void:
	if _rope == null:
		return
	var pts: PackedVector3Array = _rope.get_points()
	if pts.size() < 2:
		return
	_tail = pts[pts.size() - 1]
	if _beads != null:
		_place_beads(pts)
	# The grab zone rides the tail, so it is always where the handle actually is.
	_button.global_position = _tail


## Resample the simulated curve to `bead_count` evenly-spaced beads. Placing one
## bead per particle would give 2 cm balls on a 20 cm cord; this decouples how
## finely the cord is SIMULATED from how finely it is DRAWN.
func _place_beads(pts: PackedVector3Array) -> void:
	var mm := _beads.multimesh
	var last := pts.size() - 1
	for i in bead_count:
		var t: float = float(i) / float(maxi(1, bead_count - 1)) * float(last)
		var seg: int = clampi(int(t), 0, last - 1)
		var f: float = t - float(seg)
		var p: Vector3 = pts[seg].lerp(pts[seg + 1], f)
		mm.set_instance_transform(i, Transform3D(Basis(), p))


func _on_pulled() -> void:
	# Displace the tail and hand it back to the solver — the swing that follows is
	# simulated, not keyframed.
	if _rope != null:
		_rope.nudge_point(_rope.get_points().size() - 1, Vector3(0.0, -yank, 0.0))
	if _sfx != null:
		_sfx.play(_pull_frames)
	lit = not lit
	_apply()
	pulled.emit(lit)
	if light != null or not glow.is_empty():
		NetworkManager.report_event(NetEvents.Event.EV_PULL_LIGHT,
			{"cord": self, "on": lit})


func set_lit_remote(on: bool) -> void:
	lit = on
	_apply()


func _apply() -> void:
	if light != null:
		light.visible = lit
	if not glow.is_empty():
		var n := get_node_or_null(glow)
		if n != null and n.has_method("set_lit"):
			n.call("set_lit", lit)
