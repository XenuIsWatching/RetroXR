## Wii motion self-tests — what a remote and its Nunchuk report, headless.
##
##     "$godot" --headless --path RetroXR res://Tests/motion_tests.tscn
##     "$godot" --headless --path RetroXR res://Tests/motion_tests.tscn -- --only=accel
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## What is here is what can be decided without a core: the change of basis from
## a tracked pose into the axes an emulated accelerometer reports on, the clock
## that reading is derived on, and which of the two accelerometers a remote is
## carrying at all. Whether either one reaches a running core needs Dolphin and
## a game, and is checked by playing one.
##
## The change of basis is the reason this file exists. It is two coordinate
## changes in a row, nothing downstream complains about a wrong one, and the
## game just tilts the wrong way — so every axis is pinned here against a pose
## whose answer is known from the physics rather than from the code.
extends Node

const NUNCHUK_SCENE := preload("res://Scenes/Objects/controllers/wii/nunchuk.tscn")
const WIIMOTE_SCENE := preload("res://Scenes/Objects/controllers/wii/wiimote.tscn")
const MOTION_PLUS_SCENE := preload("res://Scenes/Objects/controllers/wii/motion_plus.tscn")

## Tolerance on a g reading. Generous, because these are floats through two
## basis inversions; a wrong AXIS is off by a whole g, not by a thousandth.
const EPS := 0.001

var _pass := 0
var _fail := 0
var _only := ""


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			_only = arg.substr(7)
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[motion] TIMEOUT")
		get_tree().quit(1))

	if _wants("accel"):
		await _test_at_rest_upright()
		await _test_as_authored_is_not_at_rest()
		await _test_at_rest_inverted()
		await _test_nose_up_reads_forward()
		await _test_top_right_reads_left()
		await _test_always_one_g_at_rest()
		await _test_smoothing_settles_on_rest()
		await _test_both_devices_agree_in_one_attitude()
	if _wants("clock"):
		await _test_a_carried_nunchuk_reads_the_path_it_is_carried_on()
		await _test_a_gentle_carry_keeps_the_pose()
		await _test_motion_is_not_a_button()
	if _wants("noise"):
		await _test_a_still_hand_reports_a_still_device()
		await _test_the_deadband_leaves_a_punch_alone()
	if _wants("pair"):
		_test_the_extension_takes_a_sub_device()
		await _test_bare_remote()
		await _test_a_seated_nunchuk()
		await _test_two_hands_turn_it_sideways()
		await _test_a_real_release_turns_it_back()
		await _test_a_nunchuk_beats_a_second_hand()
		await _test_a_dongle_has_its_own_sideways_id()
		await _test_a_nunchuk_behind_a_dongle()
		await _test_pulling_the_extension()

	print("[motion] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _wants(group: String) -> bool:
	return _only.is_empty() or _only == group


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("[motion] PASS %s" % name)
	else:
		_fail += 1
		print("[motion] FAIL %s%s" % [name, "" if detail.is_empty() else "  (%s)" % detail])


func _vec_ok(name: String, got: Vector3, want: Vector3) -> void:
	_ok(name, got.distance_to(want) < EPS, "got %v, want %v" % [got, want])


# ── The accelerometer's frame ────────────────────────────────────────────────
# Dolphin's IMUAccelerometer reports on the device's OWN axes: +X left, +Y back,
# +Z up. Proper acceleration is what an accelerometer measures, so a device at
# rest reads +1 g along whichever of its own axes happens to point at the sky.
# Each case below tips the shell a known way and names the axis that should be
# reading, which is a fact about gravity rather than a restatement of the code.

## A Nunchuk added to the tree and left alone: no velocity, so at rest.
##
## Frozen, and that is load-bearing rather than tidiness. Added to a bare test
## scene it is a loose rigid body over no floor, so it falls — and a falling
## accelerometer correctly reads WEIGHTLESS, which is the one thing none of the
## cases below mean by "at rest". Every one of them wants a device sitting on
## something.
func _at_rest_nunchuk() -> Nunchuk:
	var nc: Nunchuk = NUNCHUK_SCENE.instantiate()
	nc.freeze = true
	add_child(nc)
	await get_tree().process_frame
	return nc


## Hold the pose for long enough that the low-pass has nothing left to converge
## on. A single frame would be testing the smoothing, not the basis change.
func _settle(nc: Nunchuk) -> void:
	for i in range(60):
		nc._update_accel(1.0 / 60.0)


## The Nunchuk's REST attitude, as a rotation of the model.
##
## Not the identity, and that is the whole of what these cases got wrong until
## 2026-08-24. gen_nunchuk.gd authors this shell STANDING ON ITS TAIL — spine
## along Y, nose at +0.056, cord tail at -0.057, stick set into the +Z face — so
## the model at identity is a Nunchuk balanced on its cable, not one at rest.
##
## Rest is how the thing lies on a table: spine level, stick up, buttons down.
## That is Rx(-90) from the model, which is also exactly the attitude
## Tools/nunchuk_views.gd calls "the pose every reference photograph of this
## thing is taken in". In it, the device's own axes line up with the world's:
## up is +Y, back is +Z, left is -X.
const REST := Vector3(-PI / 2.0, 0.0, 0.0)


func _rest_basis() -> Basis:
	return Basis(Vector3.RIGHT, REST.x)


func _test_at_rest_upright() -> void:
	var nc := await _at_rest_nunchuk()
	nc.global_transform = Transform3D(_rest_basis(), Vector3.ZERO)
	_settle(nc)
	# Lying flat and right side up, which is the attitude Dolphin's own resting
	# default describes — IMUAccelerometer returns (0, 0, +1g) when nothing is
	# bound to it. Anything else here means the core is told a Nunchuk sitting on
	# a table is being held at an angle.
	_vec_ok("at rest, flat and stick up, reads one g on the up axis",
		nc.accel_in_nunchuk_frame(), Vector3(0, 0, 1))
	nc.queue_free()


func _test_as_authored_is_not_at_rest() -> void:
	var nc := await _at_rest_nunchuk()
	nc.global_transform = Transform3D.IDENTITY
	_settle(nc)
	# The model at identity is stood on its cable end, nose at the ceiling. The
	# sky is then off the device's NOSE, and the nose is its forward, so the
	# reading is one g along -back. This case exists to stop the identity pose
	# ever being mistaken for rest again: it read (0, 0, 1) here for as long as
	# the mapping was a quarter turn out, which is precisely what made the error
	# invisible.
	_vec_ok("stood on its tail reads one g on the forward axis",
		nc.accel_in_nunchuk_frame(), Vector3(0, -1, 0))
	nc.queue_free()


func _test_at_rest_inverted() -> void:
	var nc := await _at_rest_nunchuk()
	# Turned over from rest about its own spine: stick down, buttons up.
	nc.global_transform = Transform3D(Basis(Vector3.BACK, PI) * _rest_basis(), Vector3.ZERO)
	_settle(nc)
	_vec_ok("upside down reads one g the other way",
		nc.accel_in_nunchuk_frame(), Vector3(0, 0, -1))
	nc.queue_free()


func _test_nose_up_reads_forward() -> void:
	var nc := await _at_rest_nunchuk()
	# Stood up from rest so the nose points at the ceiling. The sky is off the
	# device's front, and Dolphin's +Y is BACK, so a nose-up device reads -1
	# there. The remote must answer the same in the same attitude — see
	# _test_both_devices_agree_in_one_attitude, which is the case that can
	# actually catch a wrong frame.
	nc.global_transform = Transform3D(Basis(Vector3.RIGHT, PI / 2.0) * _rest_basis(),
		Vector3.ZERO)
	_settle(nc)
	_vec_ok("nose up reads one g on the forward axis",
		nc.accel_in_nunchuk_frame(), Vector3(0, -1, 0))
	nc.queue_free()


func _test_top_right_reads_left() -> void:
	var nc := await _at_rest_nunchuk()
	# Rolled to the right from rest, so the sky is off the shell's LEFT flank,
	# which is the axis Dolphin calls +X.
	nc.global_transform = Transform3D(Basis(Vector3.BACK, -PI / 2.0) * _rest_basis(),
		Vector3.ZERO)
	_settle(nc)
	_vec_ok("rolled right reads one g on the left axis",
		nc.accel_in_nunchuk_frame(), Vector3(1, 0, 0))
	nc.queue_free()


## The case that can catch a wrong frame, which none of the ones above can.
##
## Every case above pins ONE device against poses reasoned about in that device's
## own terms, and a mapping that is a whole quarter turn out is still perfectly
## self-consistent under that: turn the shell, the reading turns with it, every
## assertion agrees. The Nunchuk's mapping was wrong from the day it was written
## and six cases here were written to match it.
##
## Two devices are what breaks the symmetry. A remote and a Nunchuk held in the
## SAME physical attitude are feeling the same gravity, and they report on the
## same axis names, so their answers must be equal — whatever those answers are.
## No knowledge of either shell's authored orientation is needed to say so, which
## is exactly why this case survives the mistake that produced the others.
func _test_both_devices_agree_in_one_attitude() -> void:
	var nc := await _at_rest_nunchuk()
	var wm: Wiimote = WIIMOTE_SCENE.instantiate()
	wm.freeze = true
	add_child(wm)
	await get_tree().process_frame

	# Each device's own rest, then the same rotation applied to both. The
	# remote's rest IS its authored pose; the Nunchuk's is Rx(-90) off it.
	for pose in [["at rest", Basis.IDENTITY],
				 ["nose up", Basis(Vector3.RIGHT, PI / 2.0)],
				 ["rolled right", Basis(Vector3.BACK, -PI / 2.0)],
				 ["nose down", Basis(Vector3.RIGHT, -PI / 2.0)]]:
		var turn: Basis = pose[1]
		nc.global_transform = Transform3D(turn * _rest_basis(), Vector3.ZERO)
		wm.global_transform = Transform3D(turn, Vector3.ZERO)
		_settle(nc)
		wm.set("_accel_smoothed", Vector3.UP * Nunchuk.G)
		var n_vec := nc.accel_in_nunchuk_frame()
		var w_vec: Vector3 = wm.accel_in_wiimote_frame()
		_ok("%s: the remote and the Nunchuk report the same gravity" % pose[0],
			n_vec.distance_to(w_vec) < EPS,
			"nunchuk %v against remote %v" % [n_vec, w_vec])
	wm.queue_free()
	nc.queue_free()


func _test_always_one_g_at_rest() -> void:
	var nc := await _at_rest_nunchuk()
	# However it is lying, a still device feels exactly one gravity. A basis
	# change that scaled or skewed would still pass an axis case pointing the
	# right way, and would fail here.
	var worst := 0.0
	for step in range(12):
		var a := TAU * float(step) / 12.0
		nc.global_transform = Transform3D(
			Basis(Vector3(0.6, 0.8, 0.0).normalized(), a), Vector3.ZERO)
		_settle(nc)
		worst = maxf(worst, absf(nc.accel_in_nunchuk_frame().length() - 1.0))
	_ok("a still Nunchuk reads one g whichever way it lies", worst < EPS,
		"worst error %f g" % worst)
	nc.queue_free()


func _test_smoothing_settles_on_rest() -> void:
	var nc := await _at_rest_nunchuk()
	nc.global_transform = Transform3D(_rest_basis(), Vector3.ZERO)
	# Straight out of the scene, before anything has driven it. A smoothed value
	# starting at zero would read as freefall for the first tenth of a second,
	# which is a Nunchuk that has been dropped rather than one just picked up.
	_vec_ok("a Nunchuk reads at rest before it is ever driven",
		nc.accel_in_nunchuk_frame(), Vector3(0, 0, 1))
	nc.queue_free()


# ── Which clock the reading is derived on ────────────────────────────────────
# The cases above hand _update_accel a velocity and a delta, so they cannot tell
# WHO calls it — and that is the whole of the defect these two exist for. A held
# Nunchuk is a frozen kinematic body the grab driver moves in its own
# _physics_process, so linear_velocity changes on the physics tick and nowhere
# else. Differentiated from _process it is a step function sampled off-phase and
# divided by the wrong number, which over-read a brisk 30 cm wave by 3.7x and
# swung the pose the core reads a hand's position from by up to 84 degrees.
#
# So these drive a real body along a known path through real physics and check
# the arithmetic against what the path says the answer is.

## Carry a Nunchuk along x = amp*sin(2*PI*hz*t) for one second of physics, the
## way a hand carries it: frozen kinematic, moved on the physics tick.
##
## Three numbers, and which one a case reads matters. "peak" is the DERIVED
## acceleration, straight off _accel_smoothed, so it measures the differentiation
## and nothing after it. "out" and "tilt" come through accel_in_nunchuk_frame —
## the public path, deadband included — so they measure what the core is actually
## handed. A case that means to guard the filter must read the latter, or it is
## reading past the thing it is checking.
func _carry(nc: Nunchuk, amp: float, hz: float, jitter := 0.0) -> Dictionary:
	nc.freeze = true
	nc.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	# Carried in its REST attitude, not at identity. The two lines below that
	# subtract (0, 0, 1) are only arithmetic if gravity really does fall on the
	# device's up axis, and at identity this shell is stood on its cable end. It
	# used to be carried that way: `out` then had a whole spurious g folded into
	# it, which the punch case survived only because its assertion is a lower
	# bound, and `tilt` sat at a permanent 90 degrees.
	nc.global_transform = Transform3D(_rest_basis(), Vector3(0, 1.2, 0))
	var t := 0.0
	var peak := 0.0
	var out := 0.0
	var tilt := 0.0
	# A settling lap first: the low-pass starts at rest and the first ticks are
	# it catching up, not the path.
	for tick in range(int(1.5 * Engine.physics_ticks_per_second)):
		t += 1.0 / float(Engine.physics_ticks_per_second)
		var x := amp * sin(TAU * hz * t)
		if jitter > 0.0:
			x += randf_range(-jitter, jitter)
		# The whole transform, not just the origin. Writing .global_position on a
		# frozen kinematic body round-trips through the physics server, which
		# hands back the basis it has rather than the one just written — so the
		# attitude set above is quietly replaced by identity on the first tick
		# and the carry happens in the wrong pose.
		nc.global_transform = Transform3D(_rest_basis(), Vector3(x, 1.2, 0))
		await get_tree().physics_frame
		if t < 0.5:
			continue
		peak = maxf(peak, (nc._accel_smoothed - Vector3.UP * Nunchuk.G).length())
		# Upright the whole way, so the reading should be one g on the device's
		# own up axis, leaned over by exactly as much as the motion justifies —
		# which also makes gravity exactly (0, 0, 1) in the reported frame, so
		# what is left after subtracting it is the motion the core receives.
		var g_vec := nc.accel_in_nunchuk_frame()
		out = maxf(out, ((g_vec - Vector3(0, 0, 1)) * Nunchuk.G).length())
		if g_vec.length() > 0.001:
			tilt = maxf(tilt, rad_to_deg(g_vec.normalized().angle_to(Vector3(0, 0, 1))))
	return {"peak": peak, "out": out, "tilt": tilt}


func _test_a_carried_nunchuk_reads_the_path_it_is_carried_on() -> void:
	var nc := await _at_rest_nunchuk()
	# 30 cm peak to peak at 2 Hz — a brisk wave of the arm, well inside what a
	# player does. Its acceleration is amp*(2*PI*hz)^2 and nothing else.
	var amp := 0.15
	var hz := 2.0
	var got: Dictionary = await _carry(nc, amp, hz)
	var want := amp * pow(TAU * hz, 2.0)
	var ratio: float = float(got["peak"]) / want
	# The band is wide on purpose: the low-pass costs about a tenth at this rate
	# and a second difference is not a derivative. It is nowhere near wide enough
	# to admit a reading taken off the render clock.
	_ok("a carried Nunchuk reports the acceleration of the path it is on",
		ratio > 0.7 and ratio < 1.3,
		"%.1f m/s^2 against a true %.1f (%.2fx)" % [got["peak"], want, ratio])
	nc.queue_free()


func _test_a_gentle_carry_keeps_the_pose() -> void:
	var nc := await _at_rest_nunchuk()
	# 10 cm at half a hertz: 0.49 m/s^2, a twentieth of a g. A real
	# accelerometer leans by atan(0.49/9.81) = 2.9 degrees under it and no more,
	# and that lean IS the hand position Dolphin's IMUAccelerometer draws from.
	var got: Dictionary = await _carry(nc, 0.05, 0.5)
	_ok("a gently carried Nunchuk still reports which way is up",
		float(got["tilt"]) < 5.0, "worst pose error %.1f degrees" % got["tilt"])
	nc.queue_free()


# ── The noise floor ──────────────────────────────────────────────────────────
# A held device's acceleration is a second difference of a TRACKED pose, so
# position noise arrives multiplied by the frame rate squared. It does not read
# as noise on screen: it tilts the vector the game takes the controller's pose
# from, so a still hand wobbles. See MotionFilter.


func _test_a_still_hand_reports_a_still_device() -> void:
	var nc := await _at_rest_nunchuk()
	# A millimetre of jitter with the hand going nowhere. Twice what a Quest
	# controller actually shows at rest, so passing here has margin.
	var got: Dictionary = await _carry(nc, 0.0, 0.0, 0.001)
	_ok("a still hand with tracking jitter reports a still device",
		float(got["tilt"]) < 1.0, "worst pose error %.1f degrees" % got["tilt"])
	nc.queue_free()


func _test_the_deadband_leaves_a_punch_alone() -> void:
	var nc := await _at_rest_nunchuk()
	# The deadband is only defensible if a real thrust survives it. 40 cm at
	# 3 Hz is a punch; it must come through within a tenth of the path's own
	# acceleration, not merely be non-zero.
	var amp := 0.20
	var hz := 3.0
	var got: Dictionary = await _carry(nc, amp, hz)
	var want := amp * pow(TAU * hz, 2.0)
	# Read through the public path, so a deadband set too high fails here — off
	# _accel_smoothed it would pass however much the filter swallowed.
	var ratio: float = float(got["out"]) / want
	_ok("and a real punch still comes through it",
		ratio > 0.6, "%.1f m/s^2 against a true %.1f (%.2fx)"
			% [got["out"], want, ratio])
	nc.queue_free()


## Motion used to double as a button: a magnitude over a threshold set L2, the
## core's "Shake Nunchuk", which Dolphin composes ON TOP of the accelerometer as
## a canned burst. With a real accelerometer behind it that is a second and
## larger punch behind every real one, and it fired on hand tremor — two
## millimetres of tracking jitter cleared it on 40% of frames.
func _test_motion_is_not_a_button() -> void:
	var wm: Wiimote = WIIMOTE_SCENE.instantiate()
	var nc: Nunchuk = NUNCHUK_SCENE.instantiate()
	add_child(wm)
	add_child(nc)
	await get_tree().process_frame
	wm._on_extension_seated(nc)
	_ok("a Nunchuk reports no shake", not nc.get_state().has("shake"))
	# Thrown hard enough that any threshold anyone would pick is behind it.
	nc.linear_velocity = Vector3.ZERO
	nc._update_accel(1.0 / 90.0)
	nc.linear_velocity = Vector3(6.0, 0.0, 0.0)
	nc._update_accel(1.0 / 90.0)
	var mask: int = wm._button_mask(wm._pressed_now())
	_ok("and however hard it is thrown, the remote sends no L2",
		mask & (1 << ControllerBindings.JOYPAD_L2) == 0,
		"mask %d" % mask)
	wm.queue_free()
	nc.queue_free()
	nc.queue_free()


# ── Which accelerometers a remote is carrying ────────────────────────────────
# The remote owns the libretro slot and makes every call for the pair, so the
# question "is there a second accelerometer" is answered here and nowhere else.

## The remote passes a sub-device index to the extension, and an extension built
## before that existed would take the call and drop the argument on the floor —
## a Nunchuk whose motion silently lands on the remote's own accelerometer. The
## binding is checked rather than the call, because there is no reader for sensor
## state to assert against, and a case that cannot fail is worse than none.
func _test_the_extension_takes_a_sub_device() -> void:
	var arity := -1
	for method: Dictionary in ClassDB.class_get_method_list("Libretro"):
		if str(method.get("name", "")) == "SetSensorAccel":
			arity = (method.get("args", []) as Array).size()
			break
	_ok("the extension's SetSensorAccel takes a sub-device index", arity == 5,
		"found %d arguments, want 5" % arity)


func _test_bare_remote() -> void:
	var wm: Wiimote = WIIMOTE_SCENE.instantiate()
	add_child(wm)
	await get_tree().process_frame
	_ok("a bare remote is a plain Wiimote", wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE)
	_ok("and reports no Nunchuk", not wm._has_nunchuk())
	wm.queue_free()


func _test_a_seated_nunchuk() -> void:
	var wm: Wiimote = WIIMOTE_SCENE.instantiate()
	var nc: Nunchuk = NUNCHUK_SCENE.instantiate()
	add_child(wm)
	add_child(nc)
	await get_tree().process_frame
	wm._on_extension_seated(nc)
	_ok("a seated Nunchuk makes it a Nunchuk remote",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE_NC)
	_ok("and the remote can reach it", wm._nunchuk == nc)
	_ok("so it will send a second accelerometer", wm._has_nunchuk())
	wm.queue_free()
	nc.queue_free()


# ── Held in two hands ────────────────────────────────────────────────────────
# A second hand on the remote is how a player asks for sideways. The core has to
# be told, because it swaps the d-pad's bitmasks and renames four buttons — none
# of which the room can do on its behalf.


## Put the remote in one hand, two, or none.
##
## A REAL XRToolsGrabDriver carrying real Grabs, because _grab_driver is typed
## and will not take a stand-in. Grabber only needs a Node3D — it asks that node
## for a pickup and a controller and is content with null for both — so a plain
## Node3D stands in for a hand without a headset anywhere.
func _hold(wm: Wiimote, hands: int) -> void:
	if hands == 0:
		wm._grab_driver = null
		wm._refresh_device_type()
		return
	var driver := XRToolsGrabDriver.new()
	# The driver reports releases as "<target> > <hand> released", so a driver
	# built without one dies on target.name the moment a hand lets go.
	driver.target = wm
	driver.primary = Grab.new(Grabber.new(_hand()), wm, null, false)
	if hands >= 2:
		driver.secondary = Grab.new(Grabber.new(_hand()), wm, null, false)
	wm._grab_driver = driver
	wm._refresh_device_type()


func _hand() -> Node3D:
	var n := Node3D.new()
	add_child(n)
	return n


func _test_two_hands_turn_it_sideways() -> void:
	var wm: Wiimote = WIIMOTE_SCENE.instantiate()
	add_child(wm)
	await get_tree().process_frame

	_hold(wm, 1)
	_ok("one hand leaves the remote upright",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE)
	_hold(wm, 2)
	_ok("a second hand turns it sideways",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE_SW)
	# The half with no signal behind it: xr-tools emits `grabbed` for a second
	# hand and nothing at all for a second RELEASE, so a remote that only watched
	# the signals would turn sideways and stay there.
	_hold(wm, 1)
	_ok("letting the second hand go turns it back",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE)
	_hold(wm, 0)
	_ok("and putting it down leaves it upright",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE)
	wm.queue_free()


## The WIRING, as opposed to the rule the cases above pin.
##
## _hold calls _refresh_device_type itself, so it proves what the remote decides
## and nothing about what makes it decide. This one lets a hand go through the
## real let_go and checks the device followed — which is the half that has no
## signal behind it and would otherwise be discovered by a player.
func _test_a_real_release_turns_it_back() -> void:
	var wm: Wiimote = WIIMOTE_SCENE.instantiate()
	add_child(wm)
	await get_tree().process_frame

	var first := _hand()
	var second := _hand()
	var driver := XRToolsGrabDriver.new()
	driver.target = wm
	driver.primary = Grab.new(Grabber.new(first), wm, null, false)
	driver.secondary = Grab.new(Grabber.new(second), wm, null, false)
	wm._grab_driver = driver
	wm._refresh_device_type()
	_ok("two real grabs read as sideways",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE_SW)

	wm.let_go(second, Vector3.ZERO, Vector3.ZERO)
	_ok("and a real release of the second hand turns it upright again",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE)
	wm.queue_free()


func _test_a_nunchuk_beats_a_second_hand() -> void:
	var wm: Wiimote = WIIMOTE_SCENE.instantiate()
	var nc: Nunchuk = NUNCHUK_SCENE.instantiate()
	add_child(wm)
	add_child(nc)
	await get_tree().process_frame
	wm._on_extension_seated(nc)

	# You cannot hold a Nunchuk and the far end of the remote with the same hand,
	# and the core has no id for the combination either — so the Nunchuk wins and
	# the second hand is just a second hand.
	_hold(wm, 2)
	_ok("a Nunchuk outranks a two-handed grab",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE_NC)
	_ok("and the remote still reports its Nunchuk", wm._has_nunchuk())

	# Pull it and the same two hands mean sideways after all.
	wm._on_extension_removed()
	_hold(wm, 2)
	_ok("pulling it lets the two hands mean sideways",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE_SW)
	wm.queue_free()
	nc.queue_free()


func _test_a_dongle_has_its_own_sideways_id() -> void:
	var wm: Wiimote = WIIMOTE_SCENE.instantiate()
	var mp: MotionPlus = MOTION_PLUS_SCENE.instantiate()
	add_child(wm)
	add_child(mp)
	await get_tree().process_frame
	wm._on_extension_seated(mp)

	_hold(wm, 1)
	_ok("a dongle alone is a MotionPlus remote",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE_MP)
	# Four ids became six for this reason: sideways and the dongle are independent
	# of each other, so every combination needs its own, and falling back to the
	# plain sideways id would silently detach a MotionPlus the room can see.
	_hold(wm, 2)
	_ok("a dongle held in two hands has an id of its own",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE_MP_SW)
	wm.queue_free()
	mp.queue_free()


func _test_a_nunchuk_behind_a_dongle() -> void:
	var wm: Wiimote = WIIMOTE_SCENE.instantiate()
	var mp: MotionPlus = MOTION_PLUS_SCENE.instantiate()
	var nc: Nunchuk = NUNCHUK_SCENE.instantiate()
	add_child(wm)
	add_child(mp)
	add_child(nc)
	await get_tree().process_frame
	# Dongle first, then the Nunchuk into the dongle's own pass-through. The
	# remote cannot see that zone, so this only works if it followed the chain.
	wm._on_extension_seated(mp)
	mp._on_nunchuk_seated(nc)
	_ok("a Nunchuk behind a dongle is still reachable", wm._nunchuk == nc)
	_ok("the pair is a MotionPlus Nunchuk remote",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE_MP_NC)
	_ok("and it still sends a second accelerometer", wm._has_nunchuk())
	wm.queue_free()
	mp.queue_free()
	nc.queue_free()


func _test_pulling_the_extension() -> void:
	var wm: Wiimote = WIIMOTE_SCENE.instantiate()
	var nc: Nunchuk = NUNCHUK_SCENE.instantiate()
	add_child(wm)
	add_child(nc)
	await get_tree().process_frame
	wm._on_extension_seated(nc)
	wm._on_extension_removed()
	_ok("pulling the Nunchuk puts the remote back",
		wm.device_type == Wiimote.RETRO_DEVICE_WIIMOTE)
	_ok("and it stops claiming a second accelerometer", not wm._has_nunchuk())
	wm.queue_free()
	nc.queue_free()
