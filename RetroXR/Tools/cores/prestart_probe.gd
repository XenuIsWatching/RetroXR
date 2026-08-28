## A Wii Remote paired BEFORE the machine is powered on — does its accelerometer
## ever get bound?
##
##     "$godot" --headless --path RetroXR res://Tools/cores/prestart_probe.tscn
##
## Dolphin binds the remote's accelerometer and gyroscope INSIDE
## retro_set_controller_port_device, and only if sensor_enabled[port] is already
## set. It sets that in InitSensors(), at the top of the first retro_run.
##
## A device announced while the core is running is queued as an emu-thread
## command and lands between frames, safely after that. But a device announced
## while the machine is OFF goes into Wrapper's m_pending_port_devices and is
## applied right after retro_load_game — before the loop starts, so before
## InitSensors. Nothing rebinds afterwards unless the extension changes.
##
## Both log lines below are printed from the emulation thread, so their order in
## the output is the real order, not a cross-thread interleaving artifact.
extends Node

const RETRO_DEVICE_WIIMOTE_NC := 769

var _lib: Node = null


func _ready() -> void:
	var home := OS.get_environment("USERPROFILE").replace("\\", "/")
	if home.is_empty():
		home = OS.get_environment("HOME")
	var root := home + "/retroxr/libretro"
	var rom := home + "/retroxr/roms/wii/Wii Sports (USA) (Rev 1).rvz"
	if not FileAccess.file_exists(rom):
		print("[prestart] SKIP: no disc at %s" % rom)
		get_tree().quit(0)
		return

	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[prestart] TIMEOUT")
		get_tree().quit(1))

	var obj: Object = ClassDB.instantiate("Libretro")
	_lib = obj as Node
	add_child(_lib)

	# The whole point: the remote is paired while the machine is off, which is
	# the ordinary way round — you pick a remote up and press SYNC, then you
	# switch the console on.
	print("[prestart] announcing WIIMOTE_NC with no core running")
	_lib.SetControllerPortDevice(0, RETRO_DEVICE_WIIMOTE_NC)

	print("[prestart] StartContent")
	_lib.StartContent(root, "dolphin", rom)

	# The remedy RetroSystem._ensure_port_devices_bound applies: say it again,
	# once the core has actually completed a frame. If the ordering above is the
	# whole problem, this second announcement is the one that binds.
	var t0 := Time.get_ticks_msec()
	while int(_lib.GetFrameCount()) <= 0 and Time.get_ticks_msec() - t0 < 30000.0:
		await get_tree().process_frame
	print("[prestart] core completed frame %d — re-announcing"
		% int(_lib.GetFrameCount()))
	_lib.SetControllerPortDevice(0, RETRO_DEVICE_WIIMOTE_NC)

	while Time.get_ticks_msec() - t0 < 25000.0:
		await get_tree().process_frame

	print("[prestart] core reached frame %d" % int(_lib.GetFrameCount()))
	_lib.StopContent()
	await get_tree().create_timer(2.0).timeout
	get_tree().quit(0)
