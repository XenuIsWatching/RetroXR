## Does a second accelerometer actually cross into a running core?
##
##     "$godot" --path RetroXR res://Tools/models/nunchuk_probe.tscn 2>&1 | grep -a "sub-device"
##
## Needs a real Dolphin core and a real Wii disc, which is why this is a probe
## and not a test. Everything decidable without one is in Tests/motion_tests.
##
## The oracle is the FRONTEND's own log, not anything printed here. InputHandler
## prints one line per sub-device a core enables, so a good run reads:
##
##     Sensor: accelerometer enabled on port 0 sub-device 0 rate=60
##     Sensor: gyroscope enabled on port 0 sub-device 0 rate=60
##     Sensor: accelerometer enabled on port 0 sub-device 1 rate=60
##
## That third line is the whole handshake: the core encoded the sub-device into
## the action, the frontend decoded it, and answered yes. Its absence with the
## first two present is a core that never asked. There is deliberately no
## gyroscope line for sub-device 1, because a Nunchuk has no gyroscope.
##
## It is also how the compatibility claim was checked. Build the frontend with
## MAX_SENSOR_INDEX at 1 and run this again: the sub-device 1 line goes away,
## sub-device 0 is untouched, and the core boots and runs on regardless — which
## is exactly what a frontend that has never heard of any of this does.
##
## What it does NOT show is a Nunchuk arm moving in a game. Driving a commercial
## Wii menu from a script means driving the pointer, and the pointer follows
## whichever IR mode the core options file happens to be carrying; put the
## headset on for that.
##
## KNOWN BROKEN, 2026-08-21: the d-pad walk below no longer leaves the main menu.
## A run gets as far as nc_boxing_highlighted.png with Tennis still selected, and
## every shot after it — ring, guard_card, remote_only_*, both_raised_* — is that
## same menu under a different name. So the guard-card oracle in _run() DID NOT
## RUN, and a run that prints all its shot lines and exits 0 still proves nothing
## about either accelerometer. Read the PNGs before believing a green run. The
## sensor-enable lines above are unaffected: those come from the boot, before any
## navigation.
extends Node

const RETRO_DEVICE_WIIMOTE_NC := 769

var core := "dolphin"
var rom := ""
var root_dir := ""

## When the port device is announced. "late" waits for the core to be running,
## which is what this probe always did. "early" announces from options_ready,
## which is what RetroSystem actually does — and options_ready is emitted just
## before the emulation loop starts, so it races InitSensors(), which is where
## Dolphin turns the sensors on. The accelerometer and gyroscope are bound
## INSIDE retro_set_controller_port_device and only if that flag is already set,
## and nothing rebinds afterwards, so losing that race costs a remote its motion
## for the whole session.
var announce := "late"

var _lib: Node = null


func _ready() -> void:
	var home := OS.get_environment("USERPROFILE").replace("\\", "/")
	if home.is_empty():
		home = OS.get_environment("HOME")
	root_dir = home + "/retroxr/libretro"
	rom = home + "/retroxr/roms/wii/Wii Sports (USA) (Rev 1).rvz"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--nc-rom="):
			rom = arg.trim_prefix("--nc-rom=")
		elif arg.begins_with("--nc-core="):
			core = arg.trim_prefix("--nc-core=")
		elif arg.begins_with("--nc-root="):
			root_dir = arg.trim_prefix("--nc-root=")
		elif arg.begins_with("--nc-announce="):
			announce = arg.trim_prefix("--nc-announce=")

	get_tree().create_timer(900.0).timeout.connect(func() -> void:
		print("[nunchuk] TIMEOUT")
		get_tree().quit(1))

	if not FileAccess.file_exists(rom):
		print("[nunchuk] SKIP: no disc at %s" % rom)
		get_tree().quit(0)
		return

	var obj: Object = ClassDB.instantiate("Libretro")
	_lib = obj as Node
	add_child(_lib)
	if announce == "early":
		_lib.connect("options_ready", _on_options_ready)
	_run()


func _on_options_ready(_c: Dictionary, _d: Dictionary, _v: Dictionary) -> void:
	print("[nunchuk] announcing at options_ready, core frame %d"
		% int(_lib.GetFrameCount()))
	_lib.SetControllerPortDevice(0, RETRO_DEVICE_WIIMOTE_NC)


func _wait_core_frames(n: int) -> void:
	var target: int = int(_lib.GetFrameCount()) + n
	var deadline := Time.get_ticks_msec() + int(n * 1000.0 / 20.0) + 8000
	while int(_lib.GetFrameCount()) < target and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame


const BTN_B := 1 << 0
const BTN_DOWN := 1 << 5
const BTN_A := 1 << 8

## What each hand's accelerometer reads while the arm hangs. Dolphin's frame:
## +X left, +Y back, +Z up, in g.
const REST := Vector3(0.0, 0.0, 1.0)
## A thrust away from the player is -Y, hard enough to read as a punch.
const JAB := Vector3(0.0, -8.0, 1.0)
## Held upright in front of the face: the nose points up, so the 1 g of gravity
## moves off +Z and onto -Y in Dolphin's frame.
const GUARD := Vector3(0.0, -1.0, 0.0)

var _wm_accel := REST
var _nc_accel := REST


func _run() -> void:
	print("[nunchuk] booting %s" % rom.get_file())
	print("[nunchuk] announce=%s" % announce)
	_lib.StartContent(root_dir, core, rom)
	await _wait_core_frames(60)
	if announce == "late":
		print("[nunchuk] announcing late, core frame %d" % int(_lib.GetFrameCount()))
		_lib.SetControllerPortDevice(0, RETRO_DEVICE_WIIMOTE_NC)
	await _wait_core_frames(60)
	DirAccess.make_dir_recursive_absolute("res://probe_out")

	# The health screen wants A and the title wants A and B, hundreds of frames
	# apart with no way to ask which is showing. Press the pair in bursts across
	# the whole boot; A is a subset of it and neither screen has anything else
	# to hit.
	for burst in range(22):
		await _hold(BTN_A | BTN_B, 20)
		await _hold(0, 20)
	await _hold(0, 150)

	# The menu takes the d-pad, so no pointer is needed. Boxing is four below
	# Tennis. Discrete presses with a gap: held, it reads as one press.
	for i in range(4):
		await _press(BTN_DOWN)
	_shot("boxing_highlighted")

	# Through the player count and the Mii, then the grip check, which asks for
	# A and B together and is not cleared by A alone.
	for i in range(7):
		await _press(BTN_A)
		await _hold(0, 100)
	for i in range(6):
		await _press(BTN_A | BTN_B)
		await _hold(0, 100)
	_shot("ring")

	# ── The thing this whole probe exists for ────────────────────────────────
	# Boxing opens with a training sequence, and "Guard your face!" will not
	# advance for a button: it wants both controllers raised. That makes the
	# tutorial a better oracle than any pixel diff, because the GAME decides,
	# and it decides on whether it can see the Nunchuk.
	#
	# So: offer the guard pose on the remote alone first. If the card still
	# stands, nothing about one hand satisfies it. Then offer the same pose on
	# both. If it advances only then, the Nunchuk's accelerometer reached the
	# core, and no amount of arguing about noise floors is needed.
	await _hold(0, 60)
	_shot("guard_card")

	_wm_accel = GUARD
	_nc_accel = REST
	for i in range(6):
		await _hold(0, 60)
		_shot("remote_only_%d" % i)

	_wm_accel = GUARD
	_nc_accel = GUARD
	for i in range(6):
		await _hold(0, 60)
		_shot("both_raised_%d" % i)

	_wm_accel = REST
	_nc_accel = REST
	await _hold(0, 90)
	_shot("after")

	print("[nunchuk] done at core frame %d" % int(_lib.GetFrameCount()))
	_lib.StopContent()
	await get_tree().create_timer(1.5).timeout
	get_tree().quit(0)


## A single button press. Held briefly and released, because the menus debounce:
## held down, it reads as one press however long it lasts.
func _press(mask: int) -> void:
	await _hold(mask, 8)
	await _hold(0, 25)


## Hold a button mask for n core frames, feeding both accelerometers throughout.
func _hold(mask: int, n: int) -> void:
	var target: int = int(_lib.GetFrameCount()) + n
	var deadline := Time.get_ticks_msec() + int(n * 1000.0 / 10.0) + 8000
	while int(_lib.GetFrameCount()) < target and Time.get_ticks_msec() < deadline:
		_lib.SetJoypadState(0, mask, 0, 0, 0, 0)
		_lib.SetSensorAccel(0, _wm_accel.x, _wm_accel.y, _wm_accel.z, 0)
		_lib.SetSensorAccel(0, _nc_accel.x, _nc_accel.y, _nc_accel.z, 1)
		await get_tree().process_frame


func _shot(name: String) -> void:
	var img: Image = _lib.GetVideoImage()
	if img == null:
		print("[nunchuk] no picture for %s" % name)
		return
	img.save_png("res://probe_out/nc_%s.png" % name)
	print("[nunchuk] %s at core frame %d" % [name, int(_lib.GetFrameCount())])
