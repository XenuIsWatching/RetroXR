## NES bay tuner — type numbers, watch the bay rebuild, step through the states.
##
##     "$godot" --path RetroXR --resolution 1600x900 res://Tools/av/bay_tuner.tscn
##     "$godot" --path RetroXR res://Tools/av/bay_tuner.tscn -- --selftest
##
## Windowed, not --headless: the whole point is to look at it.
##
## The fields drive RetroSystemModelNES's static geometry numbers and rebuild the bay through
## retune(). CLEARANCES are measured live off the shell in whatever state is showing
## and turn red when the bay is breaking out of the machine, so a value that looks
## right but pushes the cradle through the lid says so rather than waiting for a
## screenshot. When it looks right, COPY prints the const block to paste into
## Scripts/Objects/system_models/nes_model.gd.
##
## Keys:  SPACE cycle state · 1-4 pick a state · R rebuild · C print the block
##        drag = orbit · wheel = zoom · F/S/T = front / side / three-quarter
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")

## name -> [getter, setter, suffix, step]. Metres unless the suffix says degrees.
const FIELDS := [
	["TRAY_UP_DEG", "deg", 0.5],
	["CRADLE_DROP", "m", 0.001],
	["CART_LIFT", "m", 0.001],
	["CART_SEAT_DEPTH", "m", 0.005],
	["CART_PROUD", "m", 0.005],
	["PLUG_PROUD", "m", 0.002],
]

enum State { EMPTY, OFFERED, SEATED, PUSHED }
const STATE_NAME := ["empty (tray up)", "offered (held at the mouth)",
	"seated (tray up)", "pushed home (latched)"]

var _sys: Node3D = null
var _slot: XRToolsSnapZone = null
var _cart: Node3D = null
var _hand: Node3D = null
var _cam: Camera3D = null
var _state: int = State.SEATED

var _edits: Dictionary = {}          # name -> LineEdit
var _readout: RichTextLabel = null
var _orbit := Vector2(0.30, 0.6)     # pitch (+ is above), yaw
var _dist := 0.62
var _target := Vector3.ZERO
var _dragging := false

# The mouth, read while the flap is still SHUT: once it swings open its box is the
# door standing up, not the hole it covers.
var _lip := 0.0
var _lintel := 0.0
var _front := 0.0
# The cradle's own vertices, in its local space. A rotated mesh's AABB corner is
# not a point on the mesh — using it, a tilted tray reads as breaking the shell
# when it is nowhere near it.
var _cradle_verts := PackedVector3Array()
# Half the cart's own drawn thickness. The dimensions table is a separate claim
# from what the model renders as — the GLB's depth is never fitted, it just falls
# out of its proportions — and a clearance quoted from the table describes a cart
# that is not the one on screen.
var _cart_half := 0.0


func _ready() -> void:
	_build_world()
	_build_ui()
	await _spawn()
	if "--selftest" in OS.get_cmdline_user_args():
		await _selftest()
		get_tree().quit(0)


# --- world ----------------------------------------------------------------------

func _build_world() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.11, 0.12, 0.14)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.80, 0.81, 0.85)
	env.ambient_light_energy = 0.9
	we.environment = env
	add_child(we)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-32, 142, 0)
	sun.light_energy = 1.7
	add_child(sun)
	_cam = Camera3D.new()
	_cam.fov = 38.0
	add_child(_cam)
	_cam.current = true


func _spawn() -> void:
	if is_instance_valid(_sys):
		_sys.queue_free()
	if is_instance_valid(_cart):
		_cart.queue_free()
	await get_tree().process_frame
	_sys = SYSTEM_SCENE.instantiate() as Node3D
	_sys.model_id = "nes"
	_sys.systemid = "nes"
	_sys.freeze = true
	add_child(_sys)
	for i in 90:
		await get_tree().physics_frame
	_slot = _sys.get_node("CartridgeSlot") as XRToolsSnapZone
	_measure_shell()
	_sys._model.play_open()
	_cart = CART_SCENE.instantiate() as Node3D
	_cart.systemid = "nes"
	_cart.freeze = true
	add_child(_cart)
	_cart_half = _drawn_half_thickness(_cart)
	_hand = Node3D.new()
	_hand.set_script(load("res://Scripts/Desktop/desktop_hand_pivot.gd"))
	add_child(_hand)
	_target = _slot.global_position
	await _set_state(_state)


## Half the drawn height of an object, in its own frame: the union of what its
## MeshInstance3Ds actually cover.
func _drawn_half_thickness(node: Node3D) -> float:
	var box := AABB()
	var first := true
	for m in node.find_children("*", "MeshInstance3D", true, false):
		var mi := m as MeshInstance3D
		# Hidden meshes still have bounds: a GLB-modelled cart keeps the procedural
		# slab it replaced, and counting it reports a cart nobody can see.
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var world: AABB = mi.global_transform * mi.get_aabb()
		var local: AABB = node.global_transform.affine_inverse() * world
		box = local if first else box.merge(local)
		first = false
	return 0.0 if first else box.size.z * 0.5


## Take the references the clearances are quoted against, while the shell is still
## in its rest pose.
##
## The MOUTH is found in the shell's own front face — the tallest gap in the run of
## geometry there — and not from the flap: a door is bigger than the hole it covers,
## and taking the flap for the opening overstates it by 11 mm, which is most of the
## room a tilted cart needs.
func _measure_shell() -> void:
	var to_m := _sys.global_transform.affine_inverse()
	_find_mouth(to_m)
	var cradle := _sys.find_child("NesCradle", true, false) as MeshInstance3D
	_cradle_verts = PackedVector3Array()
	if cradle != null and cradle.mesh != null:
		for surf in cradle.mesh.get_surface_count():
			var arrays: Array = cradle.mesh.surface_get_arrays(surf)
			_cradle_verts.append_array(arrays[Mesh.ARRAY_VERTEX])


## The cartridge opening: scan the shell's front face for the biggest vertical gap
## across the bay's width.
func _find_mouth(to_m: Transform3D) -> void:
	var ys: Array[float] = []
	var front := -INF
	for name in ["NesDeck", "NesDeckBlack", "NesDeckDark"]:
		var mi := _sys.find_child(name, true, false) as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var x: Transform3D = to_m * mi.global_transform
		for surf in mi.mesh.get_surface_count():
			for v in mi.mesh.surface_get_arrays(surf)[Mesh.ARRAY_VERTEX]:
				var p: Vector3 = x * v
				front = maxf(front, p.z)
	for name in ["NesDeck", "NesDeckBlack", "NesDeckDark"]:
		var mi := _sys.find_child(name, true, false) as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var x: Transform3D = to_m * mi.global_transform
		for surf in mi.mesh.get_surface_count():
			for v in mi.mesh.surface_get_arrays(surf)[Mesh.ARRAY_VERTEX]:
				var p: Vector3 = x * v
				if p.z > front - 0.012 and absf(p.x) < 0.055:
					ys.append(p.y)
	ys.sort()
	var best := 0.0
	for i in ys.size() - 1:
		var gap: float = ys[i + 1] - ys[i]
		if gap > best:
			best = gap
			_lip = ys[i]
			_lintel = ys[i + 1]
	_front = front


## The cradle's highest real point, in the console's frame.
func _cradle_top(cradle: MeshInstance3D, to_m: Transform3D) -> float:
	var x: Transform3D = to_m * cradle.global_transform
	var top := -INF
	for v in _cradle_verts:
		top = maxf(top, (x * v).y)
	return top


## Rebuild the bay from the current numbers without respawning the console.
func _retune() -> void:
	if not is_instance_valid(_sys):
		return
	var keep := _state
	await _set_state(State.EMPTY)
	_sys._model.retune()
	await get_tree().physics_frame
	await _set_state(keep)


# --- states ---------------------------------------------------------------------

func _set_state(to: int) -> void:
	_state = to
	if not is_instance_valid(_sys) or not is_instance_valid(_cart):
		return
	await _empty_the_bay()

	match to:
		State.EMPTY:
			pass
		State.OFFERED:
			# Held, with the hand parked where the ghost wants it: the snap preview
			# then draws the cart at the offer, which is the pose being tuned.
			_hand.global_transform = _slot.preview_pose_for(_cart)
			_cart.global_transform = _hand.global_transform
			await get_tree().physics_frame
			_cart.pick_up(_hand)
			for i in 20:
				await get_tree().physics_frame
		State.SEATED, State.PUSHED:
			# Stand it AT the seat before the socket takes it. RetroSystemModelNES's
			# insert animation reads the seat off wherever the cart happens to be
			# when the zone catches it — that is true in the room, where a cart is
			# released at the mouth, but a cart parked anywhere else makes the slide
			# tween fight the socket and nothing appears to move at all.
			_cart.global_transform = _slot.snap_pose_for(_cart)
			await get_tree().physics_frame
			_slot.pick_up_object(_cart)
			for i in 26:
				await get_tree().physics_frame
			if to == State.PUSHED:
				_sys.toggle_cart_tray()
				for i in 16:
					await get_tree().physics_frame


## Put the bay back to empty, whatever it was holding.
##
## The zone is shut for the move: a cart let go inside its own grab sphere is
## caught straight back by it a frame later, so without this the bay never
## actually empties and every state after it starts from the wrong place.
func _empty_the_bay() -> void:
	if _sys.is_tray_down():
		_sys.toggle_cart_tray()
	_slot.enabled = false
	if _cart.is_picked_up():
		var by: Node3D = _cart._grab_driver.primary.by if _cart._grab_driver else null
		if by is XRToolsSnapZone:
			_slot.drop_object()
		else:
			_cart.let_go(_hand, Vector3.ZERO, Vector3.ZERO)
	_cart.global_position = _slot.global_position + Vector3(0, 0.4, 0)
	for i in 6:
		await get_tree().physics_frame
	_slot.enabled = true
	await get_tree().physics_frame


# --- UI -------------------------------------------------------------------------

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	panel.position = Vector2(-330, 12)
	panel.custom_minimum_size = Vector2(318, 0)
	layer.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	panel.add_child(box)

	var title := Label.new()
	title.text = "NES bay"
	box.add_child(title)

	for f in FIELDS:
		var row := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = f[0]
		name_label.custom_minimum_size = Vector2(150, 0)
		row.add_child(name_label)
		var edit := LineEdit.new()
		edit.custom_minimum_size = Vector2(92, 0)
		edit.text = _fmt(_read(f[0]), f[1])
		edit.text_submitted.connect(func(_t: String) -> void: _apply())
		row.add_child(edit)
		var minus := Button.new()
		minus.text = "-"
		minus.pressed.connect(func() -> void: _nudge(f[0], -f[2]))
		row.add_child(minus)
		var plus := Button.new()
		plus.text = "+"
		plus.pressed.connect(func() -> void: _nudge(f[0], f[2]))
		row.add_child(plus)
		_edits[f[0]] = edit
		box.add_child(row)

	var buttons := HBoxContainer.new()
	for spec in [["apply", func() -> void: _apply()],
			["state", func() -> void: _cycle()],
			["copy", func() -> void: _print_block()]]:
		var b := Button.new()
		b.text = spec[0]
		b.pressed.connect(spec[1])
		buttons.add_child(b)
	box.add_child(buttons)

	_readout = RichTextLabel.new()
	_readout.bbcode_enabled = true
	_readout.fit_content = true
	_readout.custom_minimum_size = Vector2(300, 210)
	box.add_child(_readout)


## Object.get()/set() do not reach a class's STATIC vars — they are not properties
## of the script object — so the knobs are named here explicitly.
func _read(name: String) -> float:
	match name:
		"TRAY_UP_DEG": return RetroSystemModelNES.TRAY_UP_DEG
		"CRADLE_DROP": return RetroSystemModelNES.CRADLE_DROP
		"CART_LIFT": return RetroSystemModelNES.CART_LIFT
		"CART_SEAT_DEPTH": return RetroSystemModelNES.CART_SEAT_DEPTH
		"CART_PROUD": return RetroSystemModelNES.CART_PROUD
		"PLUG_PROUD": return RetroSystemModelNES.PLUG_PROUD
	return 0.0


func _write(name: String, v: float) -> void:
	match name:
		"TRAY_UP_DEG": RetroSystemModelNES.TRAY_UP_DEG = v
		"CRADLE_DROP": RetroSystemModelNES.CRADLE_DROP = v
		"CART_LIFT": RetroSystemModelNES.CART_LIFT = v
		"CART_SEAT_DEPTH": RetroSystemModelNES.CART_SEAT_DEPTH = v
		"CART_PROUD": RetroSystemModelNES.CART_PROUD = v
		"PLUG_PROUD": RetroSystemModelNES.PLUG_PROUD = v


func _fmt(v: Variant, kind: String) -> String:
	return ("%.2f" % float(v)) if kind == "deg" else ("%.4f" % float(v))


func _nudge(name: String, by: float) -> void:
	(_edits[name] as LineEdit).text = _fmt(_read(name) + by,
		"deg" if name.ends_with("DEG") else "m")
	_apply()


## Read every field onto the model's statics and lay the bay out again.
func _apply() -> void:
	for f in FIELDS:
		var text: String = (_edits[f[0]] as LineEdit).text
		if text.is_valid_float():
			_write(f[0], text.to_float())
	await _retune()


func _cycle() -> void:
	await _set_state((_state + 1) % 4)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and (event as InputEventKey).pressed:
		match (event as InputEventKey).keycode:
			KEY_SPACE: _cycle()
			KEY_1: _set_state(State.EMPTY)
			KEY_2: _set_state(State.OFFERED)
			KEY_3: _set_state(State.SEATED)
			KEY_4: _set_state(State.PUSHED)
			KEY_R: _apply()
			KEY_C: _print_block()
			KEY_F: _orbit = Vector2(0.10, 0.0)
			KEY_S: _orbit = Vector2(0.05, 1.45)
			KEY_T: _orbit = Vector2(0.30, 0.6)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
		elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_dist = maxf(0.18, _dist - 0.03)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_dist = minf(2.0, _dist + 0.03)
	elif event is InputEventMouseMotion and _dragging:
		var rel := (event as InputEventMouseMotion).relative
		_orbit.x = clampf(_orbit.x - rel.y * 0.005, -1.4, 1.4)
		_orbit.y -= rel.x * 0.005


func _process(_delta: float) -> void:
	if _cam == null:
		return
	var dir := Vector3(
		cos(_orbit.x) * sin(_orbit.y), sin(_orbit.x), cos(_orbit.x) * cos(_orbit.y))
	_cam.global_position = _target + dir * _dist
	_cam.look_at(_target)
	_readout.text = _report()


# --- what the numbers came out as -----------------------------------------------

## Clearances measured off the shell in the state currently showing. The three that
## bound the swing (see RetroSystemModelNES's own notes) plus what the player can actually see.
func _report() -> String:
	if not is_instance_valid(_sys) or not is_instance_valid(_cart):
		return "(no console)"
	var model: Node3D = _sys._model
	var deck := _sys.find_child("NesDeck", true, false) as MeshInstance3D
	var cradle := _sys.find_child("NesCradle", true, false) as MeshInstance3D
	if deck == null or cradle == null:
		return "(shell not loaded)"
	var to_m := _sys.global_transform.affine_inverse()
	var deck_box: AABB = (to_m * deck.global_transform) * deck.get_aabb()
	var skin: float = deck_box.end.y
	var front: float = deck_box.end.z
	var half: float = MediaDimensions.cart_size("nes").y * 0.5
	var thick: float = _cart_half if _cart_half > 0.0 \
		else MediaDimensions.cart_size("nes").z * 0.5
	var cart_m: Vector3 = to_m * _cart.global_position
	var axis: Vector3 = (to_m.basis * model.get_cartridge_insert_direction()).normalized()

	var out: Array[String] = []
	out.append("[b]%s[/b]" % STATE_NAME[_state])
	out.append("tray %5.2f deg off the shell" % _angle(cradle, deck))
	out.append("cart face %+6.1f mm past the front" % ((cart_m.z + half * axis.z - front) * 1000.0))
	out.append("")
	var at_mouth: float = cart_m.y + (front - cart_m.z) * axis.y
	var belly := (at_mouth - thick - _lip) * 1000.0
	var head := (skin - _cradle_top(cradle, to_m)) * 1000.0
	var mouth_top := (_lintel - (at_mouth + thick)) * 1000.0
	out.append(_line("cradle under the skin", head, 0.0))
	if _state == State.EMPTY:
		# The cart is parked clear of the machine, so anything measured from it
		# describes thin air.
		out.append("[i]cart clearances: put a cart in (2-4)[/i]")
	else:
		# Quoted AT the mouth plane, whether or not the cart is standing there now:
		# it rides the tray, so this is the height it will have when it passes, and
		# a cart that cannot pass cannot be put in however good it looks seated.
		out.append(_line("belly over the lip, at the mouth", belly, 0.0))
		out.append(_line("head under the lintel, at it", mouth_top, 0.0))
	out.append("mouth %.1f mm tall · cart drawn %.1f mm"
		% [(_lintel - _lip) * 1000.0, thick * 2000.0])
	out.append("")
	out.append("[i]space cycle · 1-4 state · r apply · c copy[/i]")
	return "\n".join(out)


func _line(what: String, mm: float, floor_mm: float) -> String:
	var colour := "#e06c6c" if mm < floor_mm else ("#d0b060" if mm < 1.0 else "#8fbf7f")
	return "[color=%s]%-26s %6.1f mm[/color]" % [colour, what, mm]


func _angle(a: Node3D, b: Node3D) -> float:
	return rad_to_deg(a.global_transform.basis.get_rotation_quaternion().angle_to(
		b.global_transform.basis.get_rotation_quaternion()))


## A window grab, for checking the states without standing over the thing.
func _shot(name: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png("res://probe_out/%s.png" % name)


func _print_block() -> void:
	print("--- paste into Scripts/Objects/system_models/nes_model.gd ---")
	for f in FIELDS:
		var v: float = _read(f[0])
		print("static var %s := %s" % [f[0], _fmt(v, f[1] if f[1] == "deg" else "m")])
	print("---")


# --- unattended check that the thing works --------------------------------------

func _selftest() -> void:
	for st in [State.EMPTY, State.OFFERED, State.SEATED, State.PUSHED]:
		await _set_state(st)
		var where: Vector3 = _sys.global_transform.affine_inverse() * _cart.global_position
		print("[tuner] %s" % STATE_NAME[st])
		for row in _report().split("\n"):
			var clean := row.strip_edges()
			if clean != "" and not clean.begins_with("[i]space"):
				print("          %s" % clean.replace("[b]", "").replace("[/b]", "")
					.replace("[i]", "").replace("[/i]", "")
					.replace("[/color]", "").replace("[color=#e06c6c]", "!! ")
					.replace("[color=#d0b060]", " ~ ").replace("[color=#8fbf7f]", "   "))
		print("          cart y=%+.4f z=%+.4f" % [where.y, where.z])
		await _shot("state%d" % st)
	# Retune, and read the angle back with the tray UP — pushed home it is level
	# whatever the number says, which would prove nothing.
	for deg in ["3.00", "6.00"]:
		(_edits["TRAY_UP_DEG"] as LineEdit).text = deg
		await _apply()
		await _set_state(State.SEATED)
		print("[tuner] retuned to %s deg     | %s"
			% [deg, _report().split("
")[1].strip_edges()])
	_print_block()
	if DisplayServer.get_name() != "headless":
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))
		await RenderingServer.frame_post_draw
		await get_tree().process_frame
		get_viewport().get_texture().get_image().save_png("res://probe_out/tuner.png")
		print("[tuner] shot saved")
