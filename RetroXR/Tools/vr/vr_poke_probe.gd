extends Node

## End-to-end VR fingertip test WITHOUT a headset: registers real
## XRPositionalTrackers (left_hand/right_hand) with valid poses so the rig's
## XRController3D nodes become ACTIVE, boots SM64 DS on a real DS, then steers
## the left hand so its PokeTip lands on the touch screen. If the fingertip
## chain works, the "TOUCH TO START" title advances.

const MAIN := preload("res://Scenes/MainScene.tscn")
const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
## Point this at any NDS cart with a "touch to start" title screen.
static var ROM := (OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")) \
		+ "/retroxr/roms/nds/probe.nds"
const OUT := "user://vr_poke_probe"

var _fail := false
var _left_tracker: XRPositionalTracker = null
var _right_tracker: XRPositionalTracker = null
var _origin: XROrigin3D = null


func _check(cond: bool, msg: String) -> void:
	if cond:
		print("[vrpoke] PASS: %s" % msg)
	else:
		_fail = true
		print("[vrpoke] FAIL: %s" % msg)


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[vrpoke] TIMEOUT")
		get_tree().quit(1))
	DirAccess.make_dir_recursive_absolute(OUT)
	_run.call_deferred()


func _make_tracker(tname: StringName) -> XRPositionalTracker:
	var t := XRPositionalTracker.new()
	t.name = tname
	t.type = XRServer.TRACKER_CONTROLLER
	XRServer.add_tracker(t)
	return t


## Park a tracker so the controller's world transform is `world` (pose is
## relative to the XROrigin3D).
func _set_ctrl_world(t: XRPositionalTracker, world: Transform3D) -> void:
	var rel := _origin.global_transform.affine_inverse() * world
	t.set_pose(&"default", rel, Vector3.ZERO, Vector3.ZERO,
		XRPose.XR_TRACKING_CONFIDENCE_HIGH)


func _run() -> void:
	var main: Node = MAIN.instantiate()
	add_child(main)
	for i in 8:
		await get_tree().process_frame

	_origin = get_tree().root.find_child("XROrigin3D", true, false) as XROrigin3D
	_check(_origin != null, "found XROrigin3D")

	_left_tracker = _make_tracker(&"left_hand")
	_right_tracker = _make_tracker(&"right_hand")
	# Park both hands out of the way, poses valid.
	_set_ctrl_world(_left_tracker, Transform3D(Basis.IDENTITY, _origin.global_position + Vector3(-0.4, 1.2, 0)))
	_set_ctrl_world(_right_tracker, Transform3D(Basis.IDENTITY, _origin.global_position + Vector3(0.4, 1.2, 0)))
	await get_tree().process_frame

	var left_ctrl := get_tree().root.find_child("LeftController", true, false) as XRController3D
	_check(left_ctrl != null, "found LeftController")
	_check(left_ctrl.get_is_active(), "LeftController ACTIVE via fake tracker")

	# ── DS with SM64DS, floating in front of the player ───────────────────────
	var core := "melonds"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--core="):
			core = arg.trim_prefix("--core=")
	print("[vrpoke] core = %s" % core)
	var nds: RetroSystem = SYSTEM_SCENE.instantiate()
	nds.systemid = "nds"
	nds.core_name = core
	nds.freeze = true
	get_tree().current_scene.add_child(nds)
	nds.add_to_group("spawned")
	nds.global_position = _origin.global_position + Vector3(0, 1.2, -0.6)
	nds.rotation_degrees = Vector3(25, 0, 0)   # tilted toward the player
	for i in 4:
		await get_tree().process_frame

	var model: Node = nds._model
	_check(model._touch_controllers.size() >= 2, "model collected controllers (%d)" % model._touch_controllers.size())

	nds.rom_path = ROM
	nds.power_on()
	_check(nds.is_powered_on, "powered on")
	await get_tree().create_timer(13.0).timeout   # boot to TOUCH TO START

	# Snapshot the bottom half of the composite before the poke.
	var before_img := _composite_img(model)
	before_img.save_png(OUT + "/before.png")

	# ── The poke: steer the left hand so the PokeTip apex lands on the pad ────
	var touch: Area3D = model._touch
	var pad_center: Vector3 = touch.global_transform * Vector3(0, 0.002, 0)
	# Controller basis: -Z aims INTO the pad (tip = ctrl_pos - basis.z * 0.06).
	var aim := -touch.global_transform.basis.y   # poke straight down at the pad
	var ctrl_basis := Basis.looking_at(aim, touch.global_transform.basis.z)
	var ctrl_pos := pad_center - (-ctrl_basis.z) * 0.06   # tip lands on pad_center
	_set_ctrl_world(_left_tracker, Transform3D(ctrl_basis, ctrl_pos))
	await get_tree().process_frame
	await get_tree().process_frame

	var tip := PokeTip.tip_of(left_ctrl)
	print("[vrpoke] tip=%s pad=%s dist=%.4f on_screen=%s" %
		[tip, pad_center, tip.distance_to(pad_center), model._tip_on_screen(tip, 1.0)])
	_check(model._tip_on_screen(tip, 1.0), "steered tip registers on the pad")

	# Hold the poke ~0.4 s, then withdraw.
	await get_tree().create_timer(0.4).timeout
	print("[vrpoke] engaged ctrl during poke = %s" % model._touch_ctrl)
	_check(model._touch_ctrl == left_ctrl, "fingertip loop engaged the left hand")
	_set_ctrl_world(_left_tracker, Transform3D(Basis.IDENTITY, _origin.global_position + Vector3(-0.4, 1.2, 0)))
	await get_tree().create_timer(3.5).timeout

	var after_img := _composite_img(model)
	after_img.save_png(OUT + "/after.png")

	# Title reacts: the composite changes far more than idle sparkle noise.
	var diff := _img_diff(before_img, after_img)
	print("[vrpoke] composite diff after poke = %.4f" % diff)
	_check(diff > 0.02, "game state changed after the poke (diff %.4f)" % diff)

	# ── Round 2: the user's exact scenario — DS HELD in the right hand,
	# poking with the left hand's fingertip ────────────────────────────────────
	var right_ctrl := get_tree().root.find_child("RightController", true, false) as XRController3D
	var right_pickup := XRToolsFunctionPickup.find_instance(right_ctrl)
	_check(right_pickup != null, "found right FunctionPickup")
	# Hold the DS mid-air in front of the player.
	_set_ctrl_world(_right_tracker, Transform3D(Basis.IDENTITY,
		_origin.global_position + Vector3(0.1, 1.2, -0.5)))
	await get_tree().process_frame
	right_pickup._pick_up_object(nds)
	await get_tree().create_timer(0.6).timeout
	_check(nds.is_picked_up(), "DS held by the right hand")
	print("[vrpoke] held: touch_ctrl=%s (should be null — holding hand excluded)" % model._touch_ctrl)
	_check(model._touch_ctrl == null or model._touch_ctrl != right_ctrl,
		"holding hand not locked onto the touch screen")

	var before2 := _composite_img(model)
	before2.save_png(OUT + "/held_before.png")

	# Poke the (now hand-held, tilted) pad with the left fingertip.
	var touch2: Area3D = model._touch
	var pad2: Vector3 = touch2.global_transform * Vector3(0, 0.002, 0)
	var aim2 := -touch2.global_transform.basis.y
	var basis2 := Basis.looking_at(aim2, touch2.global_transform.basis.z)
	var pos2 := pad2 - (-basis2.z) * 0.06
	_set_ctrl_world(_left_tracker, Transform3D(basis2, pos2))
	await get_tree().process_frame
	await get_tree().process_frame
	print("[vrpoke] held poke: on_screen=%s engaged=%s" %
		[model._tip_on_screen(PokeTip.tip_of(left_ctrl), 1.0), model._touch_ctrl])
	_check(model._touch_ctrl == left_ctrl, "left hand pokes the HELD DS")
	await get_tree().create_timer(0.4).timeout
	_set_ctrl_world(_left_tracker, Transform3D(Basis.IDENTITY,
		_origin.global_position + Vector3(-0.4, 1.2, 0)))
	await get_tree().create_timer(3.0).timeout

	var after2 := _composite_img(model)
	after2.save_png(OUT + "/held_after.png")
	var diff2 := _img_diff(before2, after2)
	print("[vrpoke] held composite diff = %.4f" % diff2)
	_check(diff2 > 0.02, "held-DS poke reaches the game (diff %.4f)" % diff2)

	nds.power_off()
	print("[vrpoke] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	await get_tree().create_timer(0.3).timeout
	get_tree().quit(1 if _fail else 0)


func _composite_img(model: Node) -> Image:
	var proxy: MeshInstance3D = model.get_builtin_screen()
	var mat := proxy.get_surface_override_material(0)
	if mat is StandardMaterial3D and (mat as StandardMaterial3D).emission_texture:
		return (mat as StandardMaterial3D).emission_texture.get_image()
	var img := Image.create(4, 4, false, Image.FORMAT_RGB8)
	return img


func _img_diff(a: Image, b: Image) -> float:
	if a.get_size() != b.get_size():
		return 1.0
	var total := 0.0
	var n := 0
	var w := a.get_width()
	var h := a.get_height()
	for y in range(0, h, 8):
		for x in range(0, w, 8):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			total += absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			n += 1
	return total / maxf(1.0, float(n))
