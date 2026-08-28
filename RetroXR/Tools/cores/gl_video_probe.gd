## Hardware-render video probe: does a HW-render core actually put a picture on
## the screen mesh? Boots a core + ROM with no UI around it and samples the
## emission texture the VideoHandler writes, so a black screen can be pinned to
## the GL/Vulkan readback rather than to anything in the room.
##
## Written to settle a suspected GLES2-vs-GLES3 black screen on Quest, where the
## only way in is adb: NetworkManager boots this scene when user://glprobe.cfg
## exists (one --glprobe-* per line), the same hook shape as netplay_spike. It
## found the context type was innocent — mupen64plus_next_gles2 draws nothing
## while parallel_n64, also GLES2, renders fine in the same context.
##
##   --glprobe-core=mupen64plus_next_gles2
##   --glprobe-rom=/sdcard/Android/data/com.xenu.retroxr/files/roms/…/rom.z64
##   --glprobe-root=/data/user/0/com.xenu.retroxr/files/libretro   (optional)
##   --glprobe-out=/sdcard/Android/data/com.xenu.retroxr/files/glprobe   (optional)
##   --glprobe-hwapi=vulkan|d3d11|d3d12   (optional; what GET_PREFERRED_HW_RENDER
##                                         answers, so a multi-API core such as
##                                         Dolphin picks that backend)
##
## Desktop: godot --path RetroXR res://Tools/cores/gl_video_probe.tscn \
##   -- --glprobe-core=mupen64plus_next "--glprobe-rom=C:/…/rom.z64"
extends Node3D

var core := ""
var rom := ""
var root_dir := ""
var out_prefix := ""
var hwapi := ""

## retro_hw_context_type values, for SetPreferredHwRender.
const HW_API := {"opengl": 1, "glcore": 3, "vulkan": 6, "d3d11": 7, "d3d12": 9}

## Sample points (seconds since StartContent). A N64 core spends the first
## seconds in the boot/IPL sequence, which is legitimately black — one late
## sample alone can't tell "still booting" from "never draws".
## Out to 95 s because a Wii disc image is not an N64 cartridge: Wii Sports from
## an .rvz spent the whole of a 22 s run still black with the right geometry
## reported, and the same game renders fine in the room within ~90 s of the core
## starting. A window that ends before first paint reports FAIL for a core that
## works.
const SAMPLE_AT := [4.0, 8.0, 14.0, 22.0, 35.0, 50.0, 70.0, 95.0]

var _lib: Node = null
var _screen: MeshInstance3D = null
var _lit_best := 0.0


func _ready() -> void:
	var cfg_args: PackedStringArray = []
	# user:// first, then the external dir — a release build is not debuggable, so
	# `adb run-as` cannot write user://, and release is the only build that runs
	# properly on the Quest. Deleted on sight either way, so a crash mid-run
	# cannot wedge the app into the probe.
	for cfg_path: String in ["user://glprobe.cfg", NetworkManager.GLPROBE_EXTERNAL_CFG]:
		if not FileAccess.file_exists(cfg_path):
			continue
		var f := FileAccess.open(cfg_path, FileAccess.READ)
		if f:
			cfg_args = f.get_as_text().split("\n", false)
			f.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(cfg_path))
		break
	for arg: String in OS.get_cmdline_user_args() + cfg_args:
		arg = arg.strip_edges()
		if arg.begins_with("--glprobe-core="):
			core = arg.trim_prefix("--glprobe-core=")
		elif arg.begins_with("--glprobe-rom="):
			rom = arg.trim_prefix("--glprobe-rom=")
		elif arg.begins_with("--glprobe-root="):
			root_dir = arg.trim_prefix("--glprobe-root=")
		elif arg.begins_with("--glprobe-out="):
			out_prefix = arg.trim_prefix("--glprobe-out=")
		elif arg.begins_with("--glprobe-hwapi="):
			hwapi = arg.trim_prefix("--glprobe-hwapi=").to_lower()
	if root_dir.is_empty():
		root_dir = CoreDownloadManager.default_core_root()
	if out_prefix.is_empty():
		out_prefix = "/sdcard/Android/data/com.xenu.retroxr/files/glprobe" \
				if OS.get_name() == "Android" else "res://glprobe"

	get_tree().create_timer(SAMPLE_AT[-1] + 40.0).timeout.connect(func() -> void:
		print("[glprobe] TIMEOUT")
		get_tree().quit(1))

	if core.is_empty() or rom.is_empty():
		print("[glprobe] SKIP: need --glprobe-core= and --glprobe-rom=")
		get_tree().quit(0)
		return
	if not FileAccess.file_exists(rom):
		print("[glprobe] SKIP: rom not found: %s" % rom)
		get_tree().quit(0)
		return
	_run()


func _run() -> void:
	_screen = MeshInstance3D.new()
	_screen.mesh = QuadMesh.new()
	add_child(_screen)

	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	if _lib == null:
		print("[glprobe] FAIL: could not instantiate Libretro node")
		get_tree().quit(1)
		return
	add_child(_lib)

	print("[glprobe] core=%s" % core)
	print("[glprobe] rom=%s" % rom)
	print("[glprobe] root=%s" % root_dir)
	# Must precede StartContent: the core asks during its own init.
	if not hwapi.is_empty():
		if not HW_API.has(hwapi):
			print("[glprobe] FAIL: unknown --glprobe-hwapi=%s" % hwapi)
			get_tree().quit(1)
			return
		var api_id: int = HW_API[hwapi]
		ClassDB.class_call_static("Libretro", "SetPreferredHwRender", api_id)
		print("[glprobe] preferred hw render = %s (%d)" % [hwapi, api_id])
	_lib.StartContent(root_dir, core, rom)

	var t0 := Time.get_ticks_msec()
	for at: float in SAMPLE_AT:
		while (Time.get_ticks_msec() - t0) < int(at * 1000.0):
			await get_tree().process_frame
		_sample(at, (Time.get_ticks_msec() - t0) / 1000.0)

	print("[glprobe] best lit fraction across samples = %.4f" % _lit_best)
	# A booted N64 title is never near-uniformly black; 0.5% lit is a floor no
	# real frame sits under, and a black readback sits at exactly 0.
	var ok := _lit_best > 0.005
	print("[glprobe] RESULT=%s" % ("PASS" if ok else "FAIL (screen is black)"))
	_lib.StopContent()
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(0 if ok else 1)


func _sample(at: float, elapsed: float) -> void:
	var frames: int = int(_lib.GetFrameCount()) if _lib.has_method("GetFrameCount") else -1
	var mat := _screen.get_surface_override_material(0)
	if mat == null or not (mat is StandardMaterial3D):
		print("[glprobe] t=%.1f (%.1f) frames=%d — no core material on the mesh yet" % [at, elapsed, frames])
		return
	var tex: Texture2D = (mat as StandardMaterial3D).get_texture(BaseMaterial3D.TEXTURE_EMISSION)
	if tex == null:
		print("[glprobe] t=%.1f (%.1f) frames=%d — material has no emission texture yet" % [at, elapsed, frames])
		return
	var img := tex.get_image()
	if img == null or img.is_empty():
		print("[glprobe] t=%.1f (%.1f) frames=%d — emission texture has no image" % [at, elapsed, frames])
		return

	var w := img.get_width()
	var h := img.get_height()
	var lit := 0
	var n := 0
	var sum := Color(0, 0, 0)
	var peak := 0.0
	var xstep: int = maxi(1, w / 64)
	var ystep: int = maxi(1, h / 64)
	for y in range(0, h, ystep):
		for x in range(0, w, xstep):
			var c := img.get_pixel(x, y)
			sum += c
			var v: float = maxf(c.r, maxf(c.g, c.b))
			peak = maxf(peak, v)
			if v > 0.03:
				lit += 1
			n += 1
	var frac := float(lit) / float(maxi(n, 1))
	_lit_best = maxf(_lit_best, frac)
	print("[glprobe] t=%.1f (%.1f) frames=%d tex=%dx%d avg=(%.3f,%.3f,%.3f) peak=%.3f lit=%.4f" % [
			at, elapsed, frames, w, h,
			sum.r / n, sum.g / n, sum.b / n, peak, frac])

	var png := "%s_%02d.png" % [out_prefix, int(at)]
	var err := img.save_png(ProjectSettings.globalize_path(png))
	print("[glprobe] wrote %s (err=%d)" % [png, err])
