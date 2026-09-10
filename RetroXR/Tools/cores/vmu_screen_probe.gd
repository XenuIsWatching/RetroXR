## VMU screen probe — the card's own LCD, live, from a running Dreamcast.
##
## The end of the chain, and the only thing that shows it whole: a real
## RetroSystem, a real pad plugged into it, a real VmuCard seated in slot 1, a
## real flycast running a real disc, and the card's face rendered so the LCD can
## be LOOKED at. Everything before this proves a piece; this proves the piece
## fits.
##
##     "$godot" --path RetroXR --resolution 320x240 --position 20,20 \
##         res://Tools/cores/vmu_screen_probe.tscn -- \
##         --rom="$HOME/retroxr/roms/dreamcast/Crazy Taxi 2 (USA).chd" [--at=26]
##
## Windowed, never headless. The dummy renderer returns a correctly sized frame
## with nothing drawn in it, so a size check passes on a blank image — and here
## the whole question is what the picture looks like.
##
## Two gates have to be open or the LCD stays dark, and both are handled by the
## shipping code this drives rather than by the probe:
##
##   1. A joypad is announced at LOAD, so flycast creates a controller and hence
##      an expansion socket. A VMU is in the controller, not the console.
##   2. The per-slot device options are re-asserted after the first frame, since
##      flycast reads them only once `first_startup` is false.
##
## Writes the player's real flycast.opt and restores it on the way out.
extends Node

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const PAD_SCENE := preload("res://Scenes/Objects/controllers/retro_controller.tscn")
const VMU_SCENE := preload("res://Scenes/Objects/controllers/dreamcast/vmu_card.tscn")

const DEVICE_JOYPAD := 1

var rom := ""
var core := "flycast"
var at := 26.0
var shot := "res://probe_out/vmu_screen.png"

var _root := ""
var _opt_backup := PackedByteArray()
var _sys: RetroSystem = null
var _pad: RetroController = null
var _card: VmuCard = null
var _lib: Node = null
var _load_failed := ""
var _nudged := false


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--rom="):
			rom = s.substr("--rom=".length())
		elif s.begins_with("--core="):
			core = s.substr("--core=".length())
		elif s.begins_with("--at="):
			at = maxf(4.0, float(s.substr("--at=".length())))
		elif s.begins_with("--shot="):
			shot = s.substr("--shot=".length())
	get_tree().create_timer(at * 3.0 + 120.0).timeout.connect(func() -> void:
		print("[vmuscr] TIMEOUT")
		_restore()
		get_tree().quit(1))

	_root = CoreDownloadManager.default_core_root()
	if rom.is_empty() or not FileAccess.file_exists(rom):
		print("[vmuscr] SKIP: pass --rom=<a Dreamcast disc>")
		get_tree().quit(2)
		return
	if CoreDownloadManager.installed_core_lib(core).is_empty():
		print("[vmuscr] SKIP: core '%s' is not installed" % core)
		get_tree().quit(2)
		return
	await _run()


func _opt_path() -> String:
	return _root.path_join("core_options/%s.opt" % core)


func _restore() -> void:
	if _opt_backup.is_empty():
		return
	var f := FileAccess.open(_opt_path(), FileAccess.WRITE)
	if f != null:
		f.store_buffer(_opt_backup)
		f.close()
	print("[vmuscr] restored the player's flycast.opt")


func _run() -> void:
	var f := FileAccess.open(_opt_path(), FileAccess.READ)
	if f != null:
		_opt_backup = f.get_buffer(f.get_length())
		f.close()

	# The room: a Dreamcast, a pad on its first port, a VMU in the front slot.
	# All the shipping objects, wired the way a player wires them.
	_sys = SYSTEM_SCENE.instantiate() as RetroSystem
	_sys.systemid = "dreamcast"
	add_child(_sys)
	_pad = PAD_SCENE.instantiate() as RetroController
	add_child(_pad)
	for i in range(4):
		await get_tree().process_frame

	_pad.on_plugged_in(_sys, 0)
	await get_tree().process_frame
	print("[vmuscr] pad on port 0, vmu slots=%d" % _pad.vmu_slot_count())

	_card = VMU_SCENE.instantiate() as VmuCard
	add_child(_card)
	await get_tree().process_frame
	_pad.restore_vmu(_card, 0)
	await get_tree().process_frame
	await get_tree().process_frame
	print("[vmuscr] card seated in slot 1: %s  (image %s)"
		% [_pad.get_vmu(0) == _card, _card.image_path()])

	# Freeze everything. These are all RigidBody3Ds with no floor under them, so
	# over a 26 second run they fall hundreds of metres and the camera — placed
	# from the card's position at the end — frames empty space. That is exactly
	# what the first attempt rendered.
	for body in [_sys, _pad, _card]:
		if body is RigidBody3D:
			(body as RigidBody3D).freeze = true

	# And move the whole rig well clear of the origin. The camera below shares the
	# window's World3D rather than owning one — it has to, so that the card stays
	# seated in the pad — and the app's own boot splash lives near the origin in
	# that world. The first attempt rendered "RETRO XR / STARTING UP" instead of a
	# memory card.
	_pad.global_position = Vector3(60.0, 0.0, 0.0)
	await get_tree().process_frame

	# Make sure the card has an image, so the game finds a formatted card rather
	# than inventing one.
	SramPaths.ensure_card(VmuCard.FAMILY, _card.card_id)

	# The options the shipping code would pin, pinned the same way.
	var opts := {
		"reicast_device_port1_slot1": "VMU",
		"reicast_device_port1_slot2": "None",
		"reicast_per_content_vmus": "disabled",
	}
	opts.merge(VmuStorage.screen_options(0, true), true)
	CoreOptionsStore.merge_values(_root, core, opts)
	print("[vmuscr] pinned %d options; screen rect for 640x480 = %s"
		% [opts.size(), str(VmuStorage.screen_rect(Vector2i(640, 480)))])

	_lib = _sys.get_libretro_node()
	_lib.connect("content_load_failed", func(reason: String) -> void: _load_failed = reason)
	# Announced BEFORE load: flycast takes its main maple device from this, and a
	# port it never hears about has no expansion socket.
	_lib.SetControllerPortDevice(0, DEVICE_JOYPAD)
	_lib.StartContent(_root, core, rom)

	var t0 := Time.get_ticks_msec()
	while (Time.get_ticks_msec() - t0) < int(at * 1000.0):
		_lib.SetJoypadState(0, 0, 0, 0, 0, 0)
		# The second half of the ordering: flycast reads the slot options only
		# once it has run a frame. This is what VmuStorage.nudge_slots_after_start
		# does in the shipping path, hung off the same one-frame condition.
		if not _nudged and _lib.GetFrameCount() > 0:
			_nudged = true
			_lib.SetCoreOption("reicast_device_port1_slot1", "VMU")
			print("[vmuscr] nudged the slot option after frame 1")
		await get_tree().process_frame
		if not _load_failed.is_empty():
			break

	if not _load_failed.is_empty():
		print("[vmuscr] refused: %s" % _load_failed)
		_finish(false)
		return

	var tex: Texture2D = _sys.get_video_texture()
	print("[vmuscr] frames=%d  core texture=%s"
		% [_lib.GetFrameCount(), str(tex.get_size()) if tex != null else "<none>"])
	print("[vmuscr] card sees a host: %s" % (_card.host_system() != null))
	await _shoot()
	_finish(true)


## Render the card's face close up, plus the core's frame for comparison.
func _shoot() -> void:
	var sv := SubViewport.new()
	sv.size = Vector2i(880, 620)
	# NOT own_world_3d: the card is in the window's world along with the machine
	# it is plugged into, and re-parenting it into a private world would cut it
	# off from the pad. This viewport only supplies a camera and the readback.
	sv.own_world_3d = false
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var key := DirectionalLight3D.new()
	key.light_energy = 0.9
	key.rotation_degrees = Vector3(-35, -30, 0)
	add_child(key)
	var fill := OmniLight3D.new()
	fill.light_energy = 0.8
	fill.omni_range = 1.5
	fill.position = _card.global_position + Vector3(-0.15, 0.12, 0.25)
	add_child(fill)

	var cam := Camera3D.new()
	sv.add_child(cam)
	# Slightly above and off to one side, far enough back that the whole card
	# reads: square on and close, the pad's own analog stick stands in front of
	# the screen.
	cam.global_position = _card.global_position + Vector3(0.035, 0.055, 0.26)
	cam.look_at(_card.global_position + Vector3(0.0, 0.012, 0.0), Vector3.UP)
	cam.fov = 34
	cam.current = true

	for i in range(12):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame

	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(shot.get_base_dir()))
	var img := sv.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	img.save_png(shot)
	print("[vmuscr] wrote %s" % shot)

	var frame: Texture2D = _sys.get_video_texture()
	if frame != null:
		var fi := frame.get_image()
		if fi != null:
			fi.convert(Image.FORMAT_RGB8)
			var p := shot.trim_suffix(".png") + "_frame.png"
			fi.save_png(p)
			print("[vmuscr] wrote %s" % p)


func _finish(ok: bool) -> void:
	if _lib != null and _lib.has_method("StopContent"):
		_lib.StopContent()
	await get_tree().create_timer(1.0).timeout
	_restore()
	# Take the probe's own card off the player's shelf. ensure_card wrote it into
	# the real save/memcards/vmu folder, and a run per attempt would otherwise
	# leave a row of "VMU 1 2", "VMU 1 3" behind for someone to tidy up.
	if is_instance_valid(_card):
		var img := SramPaths.card_save_path(VmuCard.FAMILY, _card.card_id)
		if not img.is_empty() and FileAccess.file_exists(img):
			DirAccess.remove_absolute(img)
			print("[vmuscr] removed the probe's own card image")
	print("[vmuscr] ---- %s ----" % ("done" if ok else "FAILED"))
	get_tree().quit(0 if ok else 1)
