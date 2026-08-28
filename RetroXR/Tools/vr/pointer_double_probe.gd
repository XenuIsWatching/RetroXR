extends Node3D

## Does ONE trigger pull on the laser pointer enter ONE character?
##
## Every earlier test called XRToolsPointerEvent directly, which assumes the
## pointer emits exactly one PRESSED per pull. This drives the real thing: a
## real XRToolsFunctionPointer, its real RayCast against the real panel
## collider, fired by the controller's real button_pressed signal. Only the
## tracker pose is faked, so it runs without a headset — on the desktop or on
## the Quest.
##
## Runs on-device too: prints to stdout, which lands in `adb logcat -s godot`.

const TAG := "[ptrdbl]"

var _origin: XROrigin3D = null
var _ctrl: XRController3D = null
var _pointer: XRToolsFunctionPointer = null
var _panel: XRToolsViewport2DIn3D = null
var _tracker: XRControllerTracker = null
var _fail := 0


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("%s TIMEOUT" % TAG)
		get_tree().quit(1))
	_run.call_deferred()


func _run() -> void:
	_origin = XROrigin3D.new()
	add_child(_origin)
	var cam := XRCamera3D.new()
	_origin.add_child(cam)

	_ctrl = XRController3D.new()
	_ctrl.tracker = &"right_hand"
	_origin.add_child(_ctrl)

	_pointer = load("res://addons/godot-xr-tools/functions/function_pointer.tscn").instantiate()
	_ctrl.add_child(_pointer)

	# The panel, 1 m in front, facing the pointer.
	_panel = load("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn").instantiate()
	_panel.screen_size = Vector2(1.1, 0.75)
	_panel.viewport_size = Vector2(2200, 1500)
	_panel.update_mode = XRToolsViewport2DIn3D.UpdateMode.UPDATE_ALWAYS
	_panel.scene = load("res://Scenes/UI/spawn_menu.tscn")
	add_child(_panel)
	_panel.global_position = Vector3(0, 1.4, -1.0)

	# XRControllerTracker, not XRPositionalTracker: XRController3D expects the
	# controller subclass and rejects the base one at assignment.
	_tracker = XRControllerTracker.new()
	_tracker.name = &"right_hand"
	XRServer.add_tracker(_tracker)

	# The Quest starts in whatever posture the runtime reports; give the probe a
	# heartbeat so "process died" is distinguishable from "running, not ticking".
	_heartbeat()

	for i in range(180):
		await get_tree().process_frame

	_say("panel layer=%d  pointer mask=%d  overlap=%s" % [
		_panel.collision_layer, _pointer.collision_mask,
		(_panel.collision_layer & _pointer.collision_mask) != 0])
	_check((_panel.collision_layer & _pointer.collision_mask) != 0,
		"the laser can actually see the panel")

	var menu: Control = _panel.get_scene_instance()
	if menu == null:
		_check(false, "menu instantiated")
		_done()
		return
	menu._show_net_view()
	for i in range(30):
		await get_tree().process_frame

	var net: Control = menu._net_view
	var ip: LineEdit = net._ip_edit
	ip.text = ""

	# Aim at each key in turn and pull the trigger once.
	var typed := ""
	for ch in ["1", "9", "2", "."]:
		var btn := _find(net, ch)
		if btn == null:
			_check(false, "found key '%s'" % ch)
			continue
		if not await _pull_trigger_at(btn):
			_check(false, "laser hit key '%s'" % ch)
			continue
		typed += ch
	_say("typed %s -> %s" % [typed, ip.text])
	_check(ip.text == typed, "one trigger pull = one character")

	# And the count of presses, directly.
	var k7 := _find(net, "7")
	var n := [0]
	k7.pressed.connect(func() -> void: n[0] += 1)
	ip.text = ""
	await _pull_trigger_at(k7)
	_say("one pull on '7' -> Button.pressed x%d" % n[0])
	_check(n[0] == 1, "the button fires once per pull")

	# The decisive one. Release mode was never affected, so the paragraph above
	# passes with or without the body fix. Put the button into press mode — the
	# state that used to double — and pull once more. This fails on the
	# unpatched addon and passes on the patched one.
	k7.action_mode = BaseButton.ACTION_MODE_BUTTON_PRESS
	n[0] = 0
	ip.text = ""
	await _pull_trigger_at(k7)
	_say("one pull on a PRESS-mode key -> Button.pressed x%d, text=%s" % [n[0], ip.text])
	_check(n[0] == 1, "press mode no longer doubles at the source")
	k7.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE

	_done()


func _done() -> void:
	print("%s FAILURES: %d" % [TAG, _fail])
	print("%s DONE" % TAG)
	get_tree().quit(0)


## Point the controller at `ctrl`'s centre, let the raycast settle, then send a
## real trigger press and release through the controller's own signals.
func _pull_trigger_at(target_ctrl: Control) -> bool:
	var want_px := target_ctrl.get_global_rect().get_center()
	var body: StaticBody3D = _panel.get_node("StaticBody3D")
	var ray: RayCast3D = _pointer.get_node("RayCast")

	# The laser does not leave from the controller's origin — function_pointer
	# offsets its RayCast (y_offset) and the rig adds its own transform — so
	# aiming the controller AT the target misses it by a fixed ~35x75 px. Rather
	# than model that, aim, measure where the laser really lands, and correct.
	var aim_px := want_px
	var hit_px := Vector2.ZERO
	for attempt in range(6):
		var world := _panel_point(aim_px)
		var from := _origin.global_position + Vector3(0.2, 1.4, 0.0)
		var basis := Basis.looking_at(world - from, Vector3.UP)
		var rel := _origin.global_transform.affine_inverse() * Transform3D(basis, from)
		_tracker.set_pose(&"default", rel, Vector3.ZERO, Vector3.ZERO,
			XRPose.XR_TRACKING_CONFIDENCE_HIGH)
		for i in range(4):
			await get_tree().process_frame
		if not ray.is_colliding():
			return false
		hit_px = body.global_to_viewport(ray.get_collision_point())
		if target_ctrl.get_global_rect().has_point(hit_px):
			break
		aim_px += want_px - hit_px

	# Fire only when the laser is provably ON the key. A probe that aims
	# somewhere else and still reports PASS is worse than no probe at all.
	var under := _button_at(_panel.get_scene_instance(), hit_px)
	_say("  aim '%s' want=%s hit=%s under=%s" % [
		target_ctrl.text, want_px.round(), hit_px.round(),
		under.text if under != null else "<none>"])
	if under != target_ctrl:
		return false

	_ctrl.button_pressed.emit("trigger_click")
	for i in range(3):
		await get_tree().process_frame
	_ctrl.button_released.emit("trigger_click")
	for i in range(3):
		await get_tree().process_frame
	return true


## World position of a viewport pixel on the panel.
func _panel_point(px: Vector2) -> Vector3:
	var body: StaticBody3D = _panel.get_node("StaticBody3D")
	var cs: CollisionShape3D = body.get_node("CollisionShape3D")
	var ss: Vector2 = body.screen_size
	var vs: Vector2 = body.viewport_size
	return cs.global_transform * Vector3(
		((px.x / vs.x) - 0.5) * ss.x, (0.5 - (px.y / vs.y)) * ss.y, 0.0)


## The deepest visible Button whose rect contains `px` (viewport pixels).
func _button_at(root: Node, px: Vector2) -> Button:
	var best: Button = null
	for b in _all_buttons(root):
		if b.is_visible_in_tree() and b.get_global_rect().has_point(px):
			best = b
	return best


func _all_buttons(root: Node) -> Array[Button]:
	var out: Array[Button] = []
	for c in root.get_children():
		var b := c as Button
		if b != null:
			out.append(b)
		out.append_array(_all_buttons(c))
	return out


func _find(root: Node, text: String) -> Button:
	for c in root.get_children():
		var b := c as Button
		if b != null and b.text == text:
			return b
		var f := _find(c, text)
		if f != null:
			return f
	return null


## Prints every second until the run finishes. See quest-launch-blocked-by-os-dialog:
## a launch that never starts looks identical to one that started and stalled.
func _heartbeat() -> void:
	var t := 0
	while is_inside_tree() and _fail >= 0:
		await get_tree().create_timer(1.0).timeout
		t += 1
		print("%s alive t=%ds frames=%d" % [TAG, t, Engine.get_frames_drawn()])
		if t > 170:
			return


func _say(msg: String) -> void:
	print("%s %s" % [TAG, msg])


func _check(ok: bool, what: String) -> void:
	if not ok:
		_fail += 1
	print("%s %s %s" % [TAG, "PASS" if ok else "FAIL", what])
