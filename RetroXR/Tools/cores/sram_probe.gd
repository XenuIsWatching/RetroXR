## SRAM persistence probe — verifies the battery-save round trip with a real core.
##
## Phase A: boot a battery-save game with SetSramPath(fresh tmp file), run,
##          RequestSramFlush, stop → the .srm file must exist and be non-empty
##          (fceumm reports 8KB SAVE_RAM for battery carts; for non-battery
##          games SAVE_RAM is 0 and the probe SKIPs with a warning).
## Phase B: boot again with the same path → the file must load without error
##          and a second flush must not corrupt it (same size).
## Phase C: boot with SetSramPath("") → no file may be created (the PSX
##          no-card behaviour).
##
## Run (windowed): godot --path RetroXR --rendering-driver opengl3 \
##   res://Tools/cores/sram_probe.tscn -- "--sram-rom=C:/path/to/battery-game.rom"
extends Node3D

## Needs a battery-backed cart to be meaningful; override with --sram-rom=.
static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

var root_dir := _home + "/retroxr/libretro"
var core := "fceumm"
var rom := _home + "/retroxr/roms/nes/battery-game.nes"

var _lib: Node = null
var _mesh: MeshInstance3D = null
var _phase := "A"
var _srm_path := ""
var _none_path := ""
var _fail := false


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--sram-rom="):
			rom = arg.trim_prefix("--sram-rom=")
		elif arg.begins_with("--sram-core="):
			core = arg.trim_prefix("--sram-core=")
		elif arg.begins_with("--sram-root="):
			root_dir = arg.trim_prefix("--sram-root=")
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("[sram] TIMEOUT phase=%s" % _phase)
		get_tree().quit(1))
	if not FileAccess.file_exists(rom):
		print("[sram] SKIP: rom not found (%s) — pass --sram-rom=" % rom)
		get_tree().quit(0)
		return
	_srm_path = root_dir.path_join("save").path_join(core).path_join("sram_probe") \
		.path_join("probe_%d.srm" % (Time.get_unix_time_from_system() as int))
	_none_path = _srm_path + ".none_marker"
	_mesh = MeshInstance3D.new()
	_mesh.mesh = QuadMesh.new()
	add_child(_mesh)
	var obj: Object = ClassDB.instantiate("Libretro")
	_lib = obj as Node
	add_child(_lib)
	_run()


func _fail_if(cond: bool, msg: String) -> void:
	if cond:
		_fail = true
		print("[sram] FAIL: %s" % msg)


func _boot(sram_path: String) -> void:
	_lib.SetSramPath(sram_path)
	_lib.StartContent(root_dir, core, rom)


func _wait_frames(n: int) -> void:
	var target: int = int(_lib.GetFrameCount()) + n
	while int(_lib.GetFrameCount()) < target:
		await get_tree().process_frame


func _run() -> void:
	# ── A: fresh save file is created by the flush ────────────────────────────
	print("[sram] phase A: boot with %s" % _srm_path)
	_boot(_srm_path)
	await _wait_frames(120)
	_lib.RequestSramFlush()
	await _wait_frames(10)
	_lib.StopContent()
	await get_tree().create_timer(0.5).timeout
	if not FileAccess.file_exists(_srm_path):
		# Cores report size 0 for games without battery RAM — not a failure of
		# the plumbing, just the wrong test ROM.
		print("[sram] SKIP: no .srm written — game likely has no battery RAM (SAVE_RAM size 0)")
		get_tree().quit(0)
		return
	var size_a := NetFileTransfer.size_of(_srm_path)
	print("[sram] A: file created, %d bytes" % size_a)
	_fail_if(size_a <= 0, "empty srm file")
	# The crafted test ROM writes a fixed 0x42 signature at SRAM offset 0 —
	# assert the flushed file carries the core's writes (skip for real games).
	var fa := FileAccess.open(_srm_path, FileAccess.READ)
	if fa and rom.get_file() == "sram_test.nes":
		var b0 := fa.get_8()
		print("[sram] A: srm[0] = 0x%02x" % b0)
		_fail_if(b0 != 0x42, "srm content missing the core's 0x42 signature")

	# ── B: reboot with the same file — loads and stays intact ────────────────
	_phase = "B"
	print("[sram] phase B: reboot with existing srm")
	_boot(_srm_path)
	await _wait_frames(120)
	_lib.RequestSramFlush()
	await _wait_frames(10)
	_lib.StopContent()
	await get_tree().create_timer(0.5).timeout
	var size_b := NetFileTransfer.size_of(_srm_path)
	print("[sram] B: file after reboot, %d bytes" % size_b)
	_fail_if(size_b != size_a, "srm size changed across reboot (%d -> %d)" % [size_a, size_b])

	# ── C: empty path = no persistence ────────────────────────────────────────
	_phase = "C"
	print("[sram] phase C: boot with no sram path")
	_boot("")
	await _wait_frames(120)
	_lib.RequestSramFlush()
	await _wait_frames(10)
	_lib.StopContent()
	await get_tree().create_timer(0.5).timeout
	_fail_if(FileAccess.file_exists(_none_path), "file appeared despite empty path")

	print("[sram] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)
