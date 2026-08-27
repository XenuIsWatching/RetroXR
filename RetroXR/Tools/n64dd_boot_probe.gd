## End-to-end: assemble an N64 on a 64DD, load both halves, and power it on.
##
## Everything else about the expansions is checked without a core -- the joins,
## the recipe, which core the combination resolves to. This is the one that
## actually starts the machine and looks at the screen, because the interesting
## claim is not "the catalog says mupen64plus_next" but "F-Zero X boots with its
## Expansion Kit attached", and only a running core can settle that.
##
##     "$godot" --path RetroXR --resolution 960x720 --position 20,20 \
##         res://Tools/n64dd_boot_probe.tscn -- --root=C:/cores --shot=C:/out.png
##
## Windowed, never --headless: the core renders through a real GL context and the
## picture IS the result here.
extends Node3D

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const EXPANSION_SCENE := preload("res://Scenes/Objects/expansion.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")

## A 64DD boot spends its first seconds on the IPL animation, so an early-only
## sample cannot tell "still starting" from "never gets anywhere".
const SAMPLE_AT := [4.0, 8.0, 14.0, 20.0, 26.0]

var root_dir := ""
var shot := ""
var host_id := "nintendo_64"
var unit_id := "nintendo_64dd"
## A second unit, for a tower: Mega Drive + Mega-CD + 32X is its own combination
## with its own core, not the two-unit recipes added together.
var unit2_id := ""
## Empty is meaningful: a console with nothing in its own slot is how most of
## these combinations actually run, and how the 64DD picks its other core.
var cart_path := ""
var disk_path := ""
var _sys: RetroSystem


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--root="):
			root_dir = s.trim_prefix("--root=")
		elif s.begins_with("--shot="):
			shot = s.trim_prefix("--shot=")
		elif s.begins_with("--cart="):
			cart_path = s.trim_prefix("--cart=")
		elif s.begins_with("--disk="):
			disk_path = s.trim_prefix("--disk=")
		elif s.begins_with("--host="):
			host_id = s.trim_prefix("--host=")
		elif s.begins_with("--unit="):
			unit_id = s.trim_prefix("--unit=")
		elif s.begins_with("--unit2="):
			unit2_id = s.trim_prefix("--unit2=")

	get_tree().create_timer(SAMPLE_AT[-1] + 45.0).timeout.connect(func() -> void:
		print("[n64dd] TIMEOUT")
		get_tree().quit(1))

	await _run()
	get_tree().quit(0)


func _wait(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _run() -> void:
	# An empty --unit models a machine that IS the platform rather than a console
	# with something bolted under it: a nintendo_64dd spawned from the library
	# holds its disk in its own slot.
	var dd: RetroExpansion = null
	if not unit_id.is_empty():
		dd = EXPANSION_SCENE.instantiate() as RetroExpansion
		dd.expansion_id = unit_id
		dd.freeze = true
		add_child(dd)
		dd.global_position = Vector3(0, 1, 0)
		await _wait(20)

	var n64 := SYSTEM_SCENE.instantiate() as RetroSystem
	n64.systemid = host_id
	if not root_dir.is_empty():
		n64.core_directory = root_dir
	n64.freeze = true
	add_child(n64)
	n64.global_position = Vector3(0, 1.3, 0)
	await _wait(30)
	_sys = n64

	# Bolt the two together. Which of them wears the socket depends on which way
	# the pair stacks -- a 64DD is a base, a 32X sits on top -- and
	# restore_expansion takes either direction.
	if dd != null:
		n64.restore_expansion(dd)
	await _wait(10)

	if not unit2_id.is_empty():
		var dd2 := EXPANSION_SCENE.instantiate() as RetroExpansion
		dd2.expansion_id = unit2_id
		dd2.freeze = true
		add_child(dd2)
		await _wait(20)
		n64.restore_expansion(dd2)
		await _wait(10)

	print("[n64dd] stack=%s" % str(n64.expansion_ids()))

	# The cartridge into the console, the disk into the drive underneath.
	if not cart_path.is_empty():
		var cart := CART_SCENE.instantiate() as Node3D
		cart.systemid = host_id
		cart.rom_path = cart_path
		cart.freeze = true
		add_child(cart)
		await _wait(10)
		n64.restore_cartridge(cart)

	if not disk_path.is_empty() and dd != null:
		var disk := CART_SCENE.instantiate() as Node3D
		disk.systemid = ExpansionCatalog.media_of(unit_id)
		disk.rom_path = disk_path
		disk.freeze = true
		add_child(disk)
		await _wait(10)
		dd.restore_media(disk)
	await _wait(10)

	var spec := n64.expansion_boot()
	print("[n64dd] core=%s cart=%s disk=%s" % [
		n64.resolve_core_name(), n64._host_media_path(),
		(dd.get_media_path() if dd != null else "-")])
	print("[n64dd] subsystem=%s pairing=%s" % [
		str(spec.get("subsystem", {}).get("ident", "-")),
		str(n64._expansion_roms(spec.get("subsystem", {})))])

	n64.power_on()

	var t0 := Time.get_ticks_msec()
	var best_lit := 0.0
	for at: float in SAMPLE_AT:
		while (Time.get_ticks_msec() - t0) < int(at * 1000.0):
			await get_tree().process_frame
		var frames: int = int(n64._libretro.GetFrameCount())
		var lit := -1.0
		var img: Image = n64._libretro.GetVideoImage()
		if img != null and not img.is_empty():
			lit = _lit_fraction(img)
			best_lit = maxf(best_lit, lit)
			if not shot.is_empty():
				img.save_png(shot.replace(".png", "_%02d.png" % int(at)))
		print("[n64dd] t=%4.1f frames=%-6d lit=%s" % [
			at, frames, ("%.4f" % lit) if lit >= 0.0 else "(no image)"])

	print("[n64dd] RESULT %s+%s frames=%d lit=%.4f" % [
		host_id, unit_id, int(n64._libretro.GetFrameCount()), best_lit])


func _lit_fraction(img: Image) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var xs: int = maxi(1, w / 64)
	var ys: int = maxi(1, h / 64)
	var lit := 0
	var n := 0
	for y in range(0, h, ys):
		for x in range(0, w, xs):
			var c := img.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) > 0.03:
				lit += 1
			n += 1
	return float(lit) / float(maxi(n, 1))
