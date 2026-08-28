## Windowed probe: proves the patched azahar core produces genuine per-eye
## side-by-side stereo output — the payoff of the render_3d/factor_3d patch.
##
## Boots a stereoscopic .3dsx homebrew (left eye RED, right eye BLUE) with
## citra_render_3d = side-by-side and a single (top) screen layout, so the core's
## output frame becomes [ left-eye | right-eye ] = [ red | blue ]. Samples the
## emission texture's left half vs right half and asserts they are distinct and
## correctly colored — direct evidence each eye is a separate image (the thing a
## per-eye VR shader needs).
##
## Run: godot --path RetroXR --rendering-driver opengl3 \
##   res://Tools/cores/azahar_probe.tscn -- "--azahar-rom=C:/path/stereo_test.3dsx"
extends Node3D

var rom := ""
const CORE := "azahar"

var _lib: Node = null
var _screen: MeshInstance3D = null
var _fail := false


func _fail_if(cond: bool, msg: String) -> void:
	if cond:
		_fail = true
		print("[azahar] FAIL: %s" % msg)


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--azahar-rom="):
			rom = arg.trim_prefix("--azahar-rom=")
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[azahar] TIMEOUT")
		get_tree().quit(1))
	var root := CoreDownloadManager.default_core_root()
	var dll := root.path_join("cores").path_join(CORE + "_libretro.dll")
	if rom.is_empty() or not FileAccess.file_exists(rom) or not FileAccess.file_exists(dll):
		print("[azahar] SKIP: need --azahar-rom= and the %s core installed" % CORE)
		get_tree().quit(0)
		return
	_run(root)


func _avg(img: Image, x0: int, x1: int) -> Color:
	var r := 0.0
	var g := 0.0
	var b := 0.0
	var n := 0
	var ystep: int = maxi(1, img.get_height() / 32)
	var xstep: int = maxi(1, (x1 - x0) / 32)
	for y in range(0, img.get_height(), ystep):
		for x in range(x0, x1, xstep):
			var c := img.get_pixel(x, y)
			r += c.r; g += c.g; b += c.b; n += 1
	return Color(r / n, g / n, b / n)


func _run(root: String) -> void:
	# Force the stereo options the core needs (written to the .opt the core
	# reads at boot). single_screen top + side-by-side => frame is just [L|R].
	var optdir := root.path_join("core_options")
	DirAccess.make_dir_recursive_absolute(optdir)
	var f := FileAccess.open(optdir.path_join(CORE + ".opt"), FileAccess.WRITE)
	f.store_string("citra_render_3d = \"side-by-side\"\n")
	f.store_string("citra_factor_3d = \"100\"\n")
	f.store_string("citra_layout_option = \"single_screen\"\n")
	f.store_string("citra_swap_screen = \"Top\"\n")
	f.close()

	_screen = MeshInstance3D.new()
	_screen.mesh = QuadMesh.new()
	add_child(_screen)

	_lib = ClassDB.instantiate("Libretro") as Node
	_fail_if(_lib == null, "could not instantiate Libretro node")
	if _lib == null:
		_finish()
		return
	add_child(_lib)
	_lib.StartContent(root, CORE, rom)

	# Wait (wall-clock) for the core to boot the homebrew and render frames —
	# azahar's Vulkan device + shader init takes several seconds before the
	# first retro_run completes, so poll on time, not process-frame count.
	var t0 := Time.get_ticks_msec()
	var last_report := 0
	while int(_lib.GetFrameCount()) < 120 and (Time.get_ticks_msec() - t0) < 75000:
		await get_tree().process_frame
		var el := Time.get_ticks_msec() - t0
		if el - last_report >= 3000:
			last_report = el
			print("[azahar] booting… t=%.1fs frames=%d" % [el / 1000.0, int(_lib.GetFrameCount())])
	print("[azahar] frames=%d after %.1fs" % [int(_lib.GetFrameCount()), (Time.get_ticks_msec() - t0) / 1000.0])
	_fail_if(int(_lib.GetFrameCount()) < 1, "core never advanced a frame (boot failed?)")
	if int(_lib.GetFrameCount()) < 1:
		_finish()
		return

	var mat := _screen.get_surface_override_material(0)
	_fail_if(mat == null or not (mat is StandardMaterial3D), "no core material on screen")
	if mat == null or not (mat is StandardMaterial3D):
		_finish()
		return
	var tex: Texture2D = (mat as StandardMaterial3D).get_texture(BaseMaterial3D.TEXTURE_EMISSION)
	_fail_if(tex == null, "no emission texture")
	if tex == null:
		_finish()
		return
	var img := tex.get_image()
	var w := img.get_width()
	var h := img.get_height()
	print("[azahar] framebuffer %dx%d" % [w, h])

	var left := _avg(img, 0, w / 2)
	var right := _avg(img, w / 2, w)
	print("[azahar] left-half  avg = %s" % left)
	print("[azahar] right-half avg = %s" % right)

	# Core proof: the two halves are distinct (per-eye), not one mono image.
	var diff := absf(left.r - right.r) + absf(left.g - right.g) + absf(left.b - right.b)
	print("[azahar] half-to-half color distance = %.3f" % diff)
	_fail_if(diff < 0.3, "left/right halves nearly identical — not rendering per-eye (%.3f)" % diff)

	# Directional: left eye should read red-dominant, right eye blue-dominant.
	_fail_if(not (left.r > left.b), "left eye not red-dominant (%s)" % left)
	_fail_if(not (right.b > right.r), "right eye not blue-dominant (%s)" % right)

	_finish()


func _finish() -> void:
	print("[azahar] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	await get_tree().create_timer(0.5).timeout
	get_tree().quit(1 if _fail else 0)
