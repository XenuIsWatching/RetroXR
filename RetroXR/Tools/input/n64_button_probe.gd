## Checks that every control on the N64 pad animates, from the right bit, in the
## right direction, by the right amount -- and renders the pressed poses so the
## result can be looked at as well as asserted.
##
## Exits non-zero on failure. Needs no core, ROM, headset or display for the
## assertions; pass --shots to also write renders, which needs a real window
## (--headless gives back correctly sized frames with nothing drawn in them).
##
##   godot --headless --path RetroXR res://Tools/input/n64_button_probe.tscn
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/input/n64_button_probe.tscn -- --shots
##
## It drives ControlAnimator.animate() directly rather than pushing joypad state
## through a running system. That is the same call the live path makes, and it is
## the half this probe is about -- which mesh answers to which bit and travels
## which way. Whether a binding reaches a RUNNING core is a different question,
## and lives in Tools/input/binding_live_probe.tscn.
extends Node

const PAD := "res://Scenes/Objects/controllers/n64/n64_controller.tscn"
const SHOT := Vector2i(900, 900)

## How far a measured displacement may sit off the direction the script asked
## for. Generous because the shoulder and Z directions are measured normals
## rounded to three places, not exact axes.
const DIR_TOLERANCE := 0.02
## Travel is compared against the entry's own declared depth.
const DEPTH_TOLERANCE := 1e-5

# ── Video capture pacing (nothing here affects the shipped pad) ──────────────
## Per-frame lerp weight while recording. Well under the live pad's ~0.28 at
## 72 Hz, so the throw is spread across enough DISPLAYED frames to read as a
## press rather than a snap.
const VIDEO_LERP := 0.16
## Frames a control is held, and released, at 24 fps: ~0.75 s down, 0.5 s up.
const HOLD_FRAMES := 18
const RELEASE_FRAMES := 12
## A full circle of the stick, at 24 fps: ~2.7 s, roughly a thumb pace.
const SWEEP_FRAMES := 64

var _fail := 0
var _pass := 0


func _ready() -> void:
	var shots := ""
	for a in OS.get_cmdline_user_args():
		if a == "--shots":
			shots = "stills"
		elif a == "--video":
			shots = "video"
	await _run(shots)
	print("[n64btn] %d passed, %d failed" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("[n64btn] FAIL %s %s" % [what, detail])


func _run(shots: String) -> void:
	var packed: PackedScene = load(PAD)
	if packed == null:
		_fail += 1
		print("[n64btn] FAIL could not load " + PAD)
		return
	var pad: Node3D = packed.instantiate()
	# Freeze it: the pad is a RigidBody3D and an unfrozen one falls under gravity
	# while this probe measures, so the clearance ray below and the cap AABB it
	# is compared against can be read at two different heights.
	if pad is RigidBody3D:
		(pad as RigidBody3D).freeze = true
	add_child(pad)
	await get_tree().process_frame

	var anim: ControlAnimator = pad._anim
	# AnimatedController._animate() pushes these into the engine every frame, and
	# calling ControlAnimator.animate() directly skips that. Without them the
	# D-pad rocks with the ENGINE's default pitch sign instead of this pad's, and
	# the D-pad cases fail against code that is correct.
	anim.dpad_tilt_deg = pad._dpad_tilt_deg()
	anim.dpad_pitch_sign = pad._dpad_pitch_sign()

	_ok("bindings/buttons", anim.buttons.size() == 10,
		"expected 10 button entries, got %d" % anim.buttons.size())
	_ok("bindings/dpad", not anim.dpad.is_empty())
	_ok("bindings/stick", not anim.stick_l.is_empty())

	# Every entry must name a distinct mesh: a typo in a mesh stem makes
	# _find_mesh's prefix match land on a NEIGHBOUR (Btn_C_Up would answer for
	# Btn_C, say), and two entries driving one mesh is invisible in a render
	# because the last one written wins.
	var seen: Dictionary = {}
	for e: Dictionary in anim.buttons:
		var n: MeshInstance3D = e["node"]
		_ok("bindings/distinct", not seen.has(n.name), "%s bound twice" % n.name)
		seen[n.name] = true

	_check_directions(anim)
	await _check_travel_fits(pad, anim)
	_check_presses(anim)
	_check_c_stick(anim)
	_check_dpad(anim)
	_check_release(anim)
	await _check_process_relaxes(pad, anim)

	if not shots.is_empty():
		await _render(pad, shots)


## How closely a press direction must oppose the surface it pushes on.
## 0.9 is about 26 degrees -- loose enough for the shoulders, whose faces are
## angled and whose constants are measured normals rounded to three places, and
## tight enough that any control travelling along the wrong axis fails.
const CAP_AGREEMENT := 0.9


## Every press direction must be checked against the MESH, not against the
## constant that produced it.
##
## _check_presses compares the movement to the entry's own "dir", so it proves
## the animator applied what it was told and nothing more -- give a control a
## wrong direction and both sides of that comparison move together and it still
## passes. Setting Z_DIR to a plain -Y instead of the trigger's real outward
## normal leaves that check green. The independent oracle is the control's own
## outward surface normal, computed here from its geometry: a button travels
## INTO the face a finger presses on, so the direction must oppose that face.
func _check_directions(anim: ControlAnimator) -> void:
	for e: Dictionary in anim.buttons:
		var node: MeshInstance3D = e["node"]
		var dir: Vector3 = (e.get("dir", anim.press_dir) as Vector3).normalized()
		var cap := _cap_normal(node)
		if cap == Vector3.ZERO:
			_ok("geometry/%s has a surface" % node.name, false, "no usable faces")
			continue
		_ok("geometry/%s presses into its own face" % node.name,
			dir.dot(-cap) > CAP_AGREEMENT,
			"press %v vs outward normal %v (dot %.3f)" % [dir, cap, dir.dot(-cap)])


## The area-weighted outward normal of a control's pressable face.
##
## Face direction comes from the mesh's own NORMAL array, never from the winding
## of its indices. Godot's front face is CLOCKWISE while glTF's is
## counter-clockwise, so the importer flips the winding and a cross product of
## (b-a) x (c-a) comes back pointing INTO the solid, which makes every control
## read as pressing out of its own face. The stored normals are authoritative
## and carry no convention to get wrong.
##
## Averaging every face would cancel to nothing on a closed cap, so this takes
## the mean first and then re-averages only the faces that agree with it, which
## is the outward half.
func _cap_normal(mi: MeshInstance3D) -> Vector3:
	if mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return Vector3.ZERO
	var arrays: Array = mi.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if verts.is_empty() or norms.is_empty() or idx.is_empty():
		return Vector3.ZERO
	var normals: Array[Vector3] = []
	var areas: Array[float] = []
	var total := Vector3.ZERO
	for i in range(0, idx.size(), 3):
		var area: float = (verts[idx[i + 1]] - verts[idx[i]]).cross(
			verts[idx[i + 2]] - verts[idx[i]]).length() * 0.5
		var n: Vector3 = norms[idx[i]] + norms[idx[i + 1]] + norms[idx[i + 2]]
		if area <= 0.0 or n.length() < 1e-9:
			continue
		n = n.normalized()
		normals.append(n)
		areas.append(area)
		total += n * area
	if total.length() < 1e-9:
		return Vector3.ZERO
	var mean := total.normalized()
	var cap := Vector3.ZERO
	for i in normals.size():
		if normals[i].dot(mean) > 0.5:
			cap += normals[i] * areas[i]
	if cap.length() < 1e-9:
		return Vector3.ZERO
	# Into the node's parent space, which is where press directions are given.
	return (mi.transform.basis * cap).normalized()


## How much of a cap must still stand proud of the shell at full press. Below
## about this the button has visibly swallowed itself.
const MIN_STANDING := 0.0008
## Only controls pressing roughly straight into the button face are checked for
## sinking. The shoulders and Z travel into the pad's rear and underside, where
## "how far it stands proud" is not a downward measurement at all.
const FACE_PRESS_DOT := 0.9
## A layer nothing in the pad uses, so the clearance ray meets only the shell.
const SHELL_PROBE_LAYER := 1 << 18


## No control may press further than it stands proud of the shell.
##
## The depth constants exist to be TUNED, and the failure mode of tuning them is
## a cap that disappears into its own aperture at full press -- which no other
## case here notices, because travelling the declared distance in the declared
## direction is exactly what a too-deep press does.
##
## The clearance is measured BY RAYCAST against the shell, not from the shell's
## vertices: at 2102 triangles its vertices near a button lie on panels
## centimetres away, and sampling them answers between 4 and 29 mm for the same
## button. Physics runs fine headless -- the dummy renderer stubs rendering, not
## Jolt -- so this is a real ray against real geometry.
func _check_travel_fits(pad: Node3D, anim: ControlAnimator) -> void:
	var shell: MeshInstance3D = null
	for n: Node in pad.find_children("*", "MeshInstance3D", true, false):
		if n.name == "Body":
			shell = n as MeshInstance3D
	_ok("clearance/shell found", shell != null)
	if shell == null or shell.mesh == null:
		return

	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	# Its own layer, and the query masks only that layer. The pad already
	# carries two colliders that a downward ray meets FIRST -- its own body box
	# and the pointer box, whose top stands 2 mm above the whole controller --
	# so an unmasked ray reports every cap as sunk 4 to 6 mm INTO the shell,
	# which is a confident, precise, entirely wrong answer.
	col.shape = shell.mesh.create_trimesh_shape()
	body.collision_layer = SHELL_PROBE_LAYER
	body.collision_mask = 0
	body.add_child(col)
	pad.add_child(body)
	body.global_transform = shell.global_transform
	await get_tree().physics_frame

	var space := pad.get_world_3d().direct_space_state
	for e: Dictionary in anim.buttons:
		var node: MeshInstance3D = e["node"]
		var dir: Vector3 = (e.get("dir", anim.press_dir) as Vector3).normalized()
		if dir.dot(Vector3(0, -1, 0)) < FACE_PRESS_DOT:
			continue
		var aabb: AABB = node.global_transform * node.get_aabb()
		var top: float = aabb.position.y + aabb.size.y
		var centre: Vector3 = aabb.get_center()
		var q := PhysicsRayQueryParameters3D.create(
			Vector3(centre.x, top + 0.05, centre.z), Vector3(centre.x, top - 0.05, centre.z))
		q.collide_with_areas = false
		q.collision_mask = SHELL_PROBE_LAYER
		var hit: Dictionary = space.intersect_ray(q)
		if hit.is_empty():
			_ok("clearance/%s sits over the shell" % node.name, false, "no shell under the cap")
			continue
		var exposed: float = top - (hit["position"] as Vector3).y
		_ok("clearance/%s travel fits its clearance" % node.name,
			float(e["depth"]) <= exposed - MIN_STANDING,
			"travels %.2f mm but stands only %.2f mm proud (needs %.2f mm spare)"
			% [float(e["depth"]) * 1000.0, exposed * 1000.0, MIN_STANDING * 1000.0])
	body.queue_free()
	await get_tree().process_frame


## Each entry, pressed on its own: the mesh must travel its declared depth along
## its declared direction, and nothing else may move at all.
func _check_presses(anim: ControlAnimator) -> void:
	for e: Dictionary in anim.buttons:
		if not e.has("bit"):
			continue                      # stick-only; covered by _check_c_stick
		var node: MeshInstance3D = e["node"]
		var rest: Transform3D = e["rest"]
		var depth: float = float(e["depth"])
		var dir: Vector3 = e.get("dir", anim.press_dir)
		_pose(anim, 1 << int(e["bit"]))
		var moved: Vector3 = node.transform.origin - rest.origin
		_ok("press/%s travel" % node.name, absf(moved.length() - depth) < DEPTH_TOLERANCE,
			"moved %.5f m, expected %.5f" % [moved.length(), depth])
		_ok("press/%s direction" % node.name,
			moved.normalized().distance_to(dir.normalized()) < DIR_TOLERANCE,
			"moved along %v, expected %v" % [moved.normalized(), dir.normalized()])
		# Into the shell, never out of it: the face normal points away from the
		# body, so a press must have a negative component along it. This is the
		# case that catches a sign flip, which a travel-distance check cannot.
		_ok("press/%s goes inward" % node.name, moved.dot(dir) > 0.0)

		var strays: Array[String] = []
		for other: Dictionary in anim.buttons:
			if other["node"] == node:
				continue
			var on: MeshInstance3D = other["node"]
			if on.transform.origin.distance_to((other["rest"] as Transform3D).origin) > 1e-6:
				strays.append(on.name)
		_ok("press/%s moves nothing else" % node.name, strays.is_empty(), str(strays))


## The C cluster answers to the right analog stick. C-Left and C-Right have no
## bit of their own here (theirs are the shoulders' -- see n64_controller.gd), so
## the stick is the ONLY thing that can move them, and a regression that dropped
## stick_dir support would show up here and nowhere else.
func _check_c_stick(anim: ControlAnimator) -> void:
	var cases: Dictionary = {
		"Btn_C_Up": Vector2(0, -1), "Btn_C_Down": Vector2(0, 1),
		"Btn_C_Left": Vector2(-1, 0), "Btn_C_Right": Vector2(1, 0),
	}
	for stem: String in cases:
		var want: Vector2 = cases[stem]
		_pose(anim, 0, Vector2.ZERO, want)
		for e: Dictionary in anim.buttons:
			var node: MeshInstance3D = e["node"]
			var d: float = node.transform.origin.distance_to((e["rest"] as Transform3D).origin)
			if node.name == stem:
				_ok("cstick/%s presses" % stem, d > 1e-6, "did not move")
			elif node.name.begins_with("Btn_C_"):
				_ok("cstick/%s stays put for %s" % [node.name, stem], d < 1e-6)

	# A stick barely off centre must NOT press anything, or the cluster flutters
	# whenever the thumb rests on the stick.
	_pose(anim, 0, Vector2.ZERO, Vector2(0.2, 0))
	var pressed := 0
	for e: Dictionary in anim.buttons:
		if (e["node"] as MeshInstance3D).transform.origin.distance_to(
				(e["rest"] as Transform3D).origin) > 1e-6:
			pressed += 1
	_ok("cstick/deadzone", pressed == 0, "%d controls pressed at 20%% deflection" % pressed)


## UP must push the D-pad's UP arm DOWN. The arm lies on -Z, which is the side a
## positive pitch LIFTS, so this is the case that pins _dpad_pitch_sign() -- and
## a sign flip here is invisible in a still render of a symmetric cross.
func _check_dpad(anim: ControlAnimator) -> void:
	var node: MeshInstance3D = anim.dpad["node"]
	var rest: Transform3D = anim.dpad["rest"]
	var pivot: Vector3 = anim.dpad["pivot"]
	var up_arm: Vector3 = pivot + Vector3(0, 0, -0.010)
	var down_arm: Vector3 = pivot + Vector3(0, 0, 0.010)
	var right_arm: Vector3 = pivot + Vector3(0.010, 0, 0)

	_pose(anim, 1 << ControllerBindings.JOYPAD_UP)
	var t: Transform3D = node.transform * rest.affine_inverse()
	_ok("dpad/up dips the up arm", (t * up_arm).y < up_arm.y - 1e-5,
		"up arm y %.5f -> %.5f" % [up_arm.y, (t * up_arm).y])
	_ok("dpad/up lifts the down arm", (t * down_arm).y > down_arm.y + 1e-5)

	_pose(anim, 1 << ControllerBindings.JOYPAD_RIGHT)
	t = node.transform * rest.affine_inverse()
	_ok("dpad/right dips the right arm", (t * right_arm).y < right_arm.y - 1e-5,
		"right arm y %.5f -> %.5f" % [right_arm.y, (t * right_arm).y])


## Everything must come back to rest when nothing is held -- otherwise a control
## pressed once stays pressed for the life of the pad.
func _check_release(anim: ControlAnimator) -> void:
	_pose(anim, 0xffff, Vector2(1, 1), Vector2(1, 1))
	_pose(anim, 0)
	for e: Dictionary in anim.buttons:
		var node: MeshInstance3D = e["node"]
		_ok("release/%s" % node.name,
			node.transform.origin.distance_to((e["rest"] as Transform3D).origin) < 1e-6)
	_ok("release/dpad", (anim.dpad["node"] as MeshInstance3D).transform.is_equal_approx(
		anim.dpad["rest"]))
	_ok("release/stick", (anim.stick_l["node"] as MeshInstance3D).transform.is_equal_approx(
		anim.stick_l["rest"]))


## The pad's OWN _process pulls every control back to rest when no joypad state
## arrived that frame -- and that is correct: an unplugged, unheld pad should
## not sit with a button held down. It is pinned here because it is invisible
## and consequential: this probe poses controls by calling animate() directly,
## so with the pad still processing every posed frame is immediately half-undone
## and a recorded video shows the caps twitching around rest instead of
## pressing. _render() switches processing off for that reason, and if this
## behaviour ever changes that comment stops making sense.
func _check_process_relaxes(pad: Node3D, anim: ControlAnimator) -> void:
	var node: MeshInstance3D = null
	var rest := Transform3D()
	for e: Dictionary in anim.buttons:
		if (e["node"] as MeshInstance3D).name == "Btn_A":
			node = e["node"]
			rest = e["rest"]
	if node == null:
		_ok("process/found Btn_A", false)
		return
	_pose(anim, 1 << ControllerBindings.JOYPAD_B)
	var pressed: float = node.transform.origin.distance_to(rest.origin)
	pad.set_process(true)
	await get_tree().process_frame
	await get_tree().process_frame
	var after: float = node.transform.origin.distance_to(rest.origin)
	_ok("process/relaxes a posed control when nothing drives it", after < pressed,
		"held at %.5f m from rest across two frames of _process" % after)
	pad.set_process(false)
	_pose(anim, 0)


## Weight 1.0 jumps straight to the target pose, so a case measures the pose it
## asked for rather than however far a lerp happened to get.
func _pose(anim: ControlAnimator, btn: int, lstick := Vector2.ZERO,
		rstick := Vector2.ZERO) -> void:
	anim.animate(btn, lstick, rstick, 1.0)


## The camera and lighting the shots share.
func _stage(pad: Node3D) -> SubViewport:
	var sv := SubViewport.new()
	sv.size = SHOT
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.18, 0.19, 0.22)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.57, 0.62)
	env.environment = e
	sv.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-50, -35, 0)
	key.light_energy = 1.6
	sv.add_child(key)

	# Stop the pad driving its own controls, or it fights this probe every frame
	# and NOTHING visibly moves.
	#
	# AnimatedController._process() relaxes every control toward rest whenever no
	# joypad state arrived that frame, which is always here -- there is no system
	# and no hand. Left on, each captured frame is: animate() pushes the cap 16%
	# of the way down, then _process pulls it ~28% of the way back up. The cap
	# hovers within half a pixel of rest, wobbling as antialiasing flips edge
	# pixels, and reads on screen as a twitch rather than a press.
	#
	# The assertions above cannot see that: they call animate() and measure in
	# the same frame, before _process gets a turn. Only a sequence of RENDERED
	# frames spans the boundary, so the video is not decoration here -- it is the
	# only thing that covers this failure.
	pad.set_process(false)

	var model: Node3D = pad.get_node("Model")
	pad.remove_child(model)
	sv.add_child(model)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 0.118
	cam.near = 0.001
	cam.far = 10.0
	sv.add_child(cam)
	# A RAKING view of the button face, not an overhead one, and that is the
	# whole reason this camera is placed by hand.
	#
	# The controls press along -Y. A camera looking straight down -Y sees that
	# motion end-on and projects almost none of it: measured, a near-overhead
	# framing turned a 1.8 mm press into 3.4 pixels of screen travel, which reads
	# as nothing moving. This sits about 54 degrees off vertical, so roughly 80%
	# of the press projects onto the screen, and crops to the control cluster
	# rather than the whole pad to buy the rest.
	cam.position = Vector3(0.007, 0.072, 0.100)
	cam.look_at(Vector3(0.007, -0.008, -0.018), Vector3(0, 1, 0))
	cam.current = true
	return sv


func _grab(sv: SubViewport, path: String) -> void:
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	var img := sv.get_texture().get_image()
	# The frame carries an unfilled alpha channel; flatten it, or the PNG writes
	# fully transparent and every viewer paints it blank white.
	img.convert(Image.FORMAT_RGB8)
	img.save_png(path)


func _render(pad: Node3D, mode: String) -> void:
	var sv := _stage(pad)
	var anim: ControlAnimator = pad._anim
	var out := "res://probe_out"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	if mode == "stills":
		var poses: Array = [
			{"name": "rest", "btn": 0, "r": Vector2.ZERO},
			{"name": "all", "btn": 0xffff, "r": Vector2.ZERO},
			{"name": "c_left", "btn": 0, "r": Vector2(-1, 0)},
		]
		for p: Dictionary in poses:
			_pose(anim, int(p["btn"]), Vector2.ZERO, p["r"] as Vector2)
			for i in range(6):
				await get_tree().process_frame
			var path: String = "%s/n64_press_%s.png" % [out, p["name"]]
			await _grab(sv, path)
			print("[n64btn] wrote %s" % path)
		return

	# Video: every control in turn, then the stick and D-pad swept.
	#
	# VIDEO_LERP is deliberately far below the live pad's per-frame weight, and
	# the holds are long. The animation is the same exponential settle either
	# way, but the live pad samples it at 72 Hz -- five samples across ~70 ms,
	# which the eye reads as a press. Replaying that same curve at 24 fps puts
	# 45% of the travel in the FIRST displayed frame and creeps through the
	# rest, which reads as a twitch, and firing ten controls back to back at a
	# third of a second each reads as a machine gun. Neither is anything the
	# shipped pad does; both are artifacts of capture rate alone.
	var dir := out + "/n64_press_video"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var steps: Array = []
	var order: Array = ["Btn_A", "Btn_B", "Btn_C_Up", "Btn_C_Right", "Btn_C_Down",
		"Btn_C_Left", "Btn_Start", "Btn_Z", "Btn_L", "Btn_R"]
	for stem: String in order:
		var bit := -1
		var stick := Vector2.ZERO
		for e: Dictionary in anim.buttons:
			if (e["node"] as MeshInstance3D).name == stem:
				bit = int(e.get("bit", -1))
				stick = e.get("stick_dir", Vector2.ZERO)
		for i in range(HOLD_FRAMES):
			steps.append({"btn": (1 << bit) if bit >= 0 else 0, "r": stick, "l": Vector2.ZERO})
		for i in range(RELEASE_FRAMES):
			steps.append({"btn": 0, "r": Vector2.ZERO, "l": Vector2.ZERO})
	for i in range(SWEEP_FRAMES):                  # stick sweeps a full circle
		var a: float = TAU * float(i) / float(SWEEP_FRAMES)
		steps.append({"btn": 0, "r": Vector2.ZERO, "l": Vector2(sin(a), -cos(a))})
	for i in range(10):
		steps.append({"btn": 0, "r": Vector2.ZERO, "l": Vector2.ZERO})
	for bit: int in [ControllerBindings.JOYPAD_UP, ControllerBindings.JOYPAD_RIGHT,
			ControllerBindings.JOYPAD_DOWN, ControllerBindings.JOYPAD_LEFT]:
		for i in range(HOLD_FRAMES):
			steps.append({"btn": 1 << bit, "r": Vector2.ZERO, "l": Vector2.ZERO})
		for i in range(RELEASE_FRAMES):
			steps.append({"btn": 0, "r": Vector2.ZERO, "l": Vector2.ZERO})
	for i in range(10):
		steps.append({"btn": 0, "r": Vector2.ZERO, "l": Vector2.ZERO})

	var n := 0
	for s: Dictionary in steps:
		anim.animate(int(s["btn"]), s["l"] as Vector2, s["r"] as Vector2, VIDEO_LERP)
		await get_tree().process_frame
		await _grab(sv, "%s/f%04d.png" % [dir, n])
		n += 1
	print("[n64btn] wrote %d frames to %s" % [n, dir])
