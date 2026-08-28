## Photographs the cartridge panel's States tab at the real viewport size.
##
## The question it was written to settle: does a third pill make the ribbon strip
## wrap to two rows? TabStrip sizes every pill to the widest title, so
## "Achievements" floors all of them, and three of those may not fit 720 px.
## Also shows what a row actually looks like — thumbnail, times, three buttons —
## which no headless case can.
##
##   godot --path RetroXR --resolution 760x500 --position 20,20 \
##     res://Tools/state/cart_states_probe.tscn -- --case=full
##
## Cases: full, empty, blocked, armed, server, many, saves (the neighbouring tab)
## --host=console renders the EMBEDDED copy at the console panel's 600x500, which
## is the narrower of the two and where layout breaks first.
##
## Windowed, not --headless: a SubViewport renders nothing under the dummy driver.
## PNGs land in res://probe_out/ (gitignored).
extends Node

var _sv: SubViewport = null
var _ui: CartridgeOptions2D = null
var _case := "full"
var _host := "cart"


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--case="):
			_case = arg.split("=")[1]
		elif arg.begins_with("--host="):
			_host = arg.split("=")[1]
	get_tree().create_timer(90.0).timeout.connect(func() -> void:
		print("[cart] TIMEOUT")
		get_tree().quit(1))
	await _run()


## A picture to stand in for a captured frame: a coloured gradient with a band,
## so scaling and aspect are both visible at row size.
func _fake_shot(path: String, w: int, h: int, tint: Color) -> String:
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	for y in range(h):
		for x in range(w):
			var f := float(x) / float(w)
			var c := Color(tint.r * f, tint.g * (1.0 - f), tint.b * 0.5 + 0.5 * f)
			if absi(y - h / 2) < h / 12:
				c = Color(1, 1, 1)
			img.set_pixel(x, y, c)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	img.save_png(path)
	return path


func _rows(n: int) -> Array:
	var dir := "user://__cart_states_probe"
	var out: Array = []
	var now := int(Time.get_unix_time_from_system())
	var tints := [Color(1, 0.4, 0.2), Color(0.3, 1, 0.5), Color(0.4, 0.5, 1),
		Color(1, 0.9, 0.2)]
	for i in range(n):
		# 256x224 and 160x144: the two shapes a row has to hold without reflowing.
		var w := 256 if i % 2 == 0 else 160
		var h := 224 if i % 2 == 0 else 144
		out.append({
			"state_id": "%d-%06x" % [(now - i * 3600) * 1000, i * 4919],
			"path": "",
			"shot": _fake_shot(dir.path_join("shot_%d.png" % i), w, h,
				tints[i % tints.size()]),
			"meta": "",
			"mtime": now - i * 3600,
			"bytes": [13726, 4456448, 62914560, 812345][i % 4],
		})
	return out


func _run() -> void:
	var embedded := _host == "console"
	_sv = SubViewport.new()
	# Read off the panel scenes rather than copied from them, so this cannot
	# quietly photograph a size no panel has any more.
	_sv.size = _panel_viewport("res://Scenes/UI/core_options_panel.tscn" if embedded
		else "res://Scenes/UI/cartridge_options_panel.tscn")
	print("[cart] rendering at %dx%d" % [_sv.size.x, _sv.size.y])
	_sv.transparent_bg = false
	_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(_sv)

	if embedded:
		# The console panel wraps the embedded copy in a margin; approximate it
		# so the width the strip actually gets is the width it gets in the game.
		var margin := MarginContainer.new()
		margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
			margin.add_theme_constant_override(side, 10)
		var bg := ColorRect.new()
		bg.color = CartridgeOptions2D.COLOR_BG
		bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_sv.add_child(bg)
		_sv.add_child(margin)
		_ui = CartridgeOptions2D.create_embedded()
		margin.add_child(_ui)
	else:
		_ui = CartridgeOptions2D.new()
		_sv.add_child(_ui)
	await get_tree().process_frame
	await get_tree().process_frame

	_ui.populate("Super Mario Bros. (World)",
		"C:/Users/you/retroxr/roms/nes/Super Mario Bros. (World).nes",
		[{"save_id": "a1b2c3d4e5f6", "mtime": int(Time.get_unix_time_from_system()),
		  "size": 8192}],
		"a1b2c3d4e5f6", true, {"a1b2c3d4e5f6": "on"}, [], true)
	_ui.populate_achievements([], {}, "Sign in to RetroAchievements in OPTIONS.")

	var rows: Array = []
	var server: Array = []
	var total := 0
	var backup := {}
	var notice := ""
	var romm := true
	match _case:
		"empty":
			pass
		"blocked":
			_ui.capture_blocked = "no machine is running this game"
		"unknown":
			# Backup is on and the server is up, but RomM has never heard of this
			# ROM — the commonest reason the column is missing.
			rows = _rows(2)
			notice = "RomM does not have this game, so its save states stay on this device."
			romm = false
		"switchedoff":
			rows = _rows(2)
			notice = "Backing up is off — turn on \"Back up saves and states\" in OPTIONS ▸ RomM."
			romm = false
		"armed":
			rows = _rows(3)
			_ui.states_armed_id = str(rows[1]["state_id"])
			_ui.states_armed_action = "overwrite"
		"server":
			rows = _rows(1)
			server = [{"state_id": "1786900000000-0a1b2c",
				"updated_at": "2026-08-16T21:14:02", "size": 4456448}]
		"many":
			rows = _rows(24)
		_:
			rows = _rows(4)
			notice = "RomM rejected these uploads — the paired token has no write access."
	for i in range(rows.size()):
		backup[str(rows[i]["state_id"])] = ["on", "busy", "failed", "off"][i % 4]
		total += int(rows[i]["bytes"])
	_ui.populate_states(rows, total, backup, server, notice, romm)

	var tabs := _find_tabs(_ui)
	if tabs != null:
		# The States tab, wherever it landed — asserting on an index here would
		# just plant the same landmine this change removed.
		for i in range(tabs.get_tab_count()):
			if tabs.get_tab_title(i) == "States":
				tabs.current_tab = i
		print("[cart] tabs: %s (showing %d)"
			% [str(range(tabs.get_tab_count()).map(func(i: int) -> String:
				return tabs.get_tab_title(i))), tabs.current_tab])

	for f in range(20):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame

	# Does the strip wrap? Measure it rather than eyeballing the PNG.
	var strip := _find_strip(_ui)
	if strip != null:
		print("[cart] tab strip is %.0f x %.0f px in a %d px viewport"
			% [strip.size.x, strip.size.y, _sv.size.x])

	DirAccess.make_dir_recursive_absolute("res://probe_out")
	var out := "res://probe_out/cart_states_%s_%s.png" % [_host, _case]
	_sv.get_texture().get_image().save_png(out)
	print("[cart] saved %s" % out)
	get_tree().quit(0)


## The viewport_size the given panel scene gives its Viewport2Din3D.
func _panel_viewport(scene_path: String) -> Vector2i:
	var packed := load(scene_path) as PackedScene
	if packed == null:
		return Vector2i(720, 460)
	var inst := packed.instantiate()
	var size := Vector2i(720, 460)
	for child in inst.get_children():
		var v: Variant = child.get("viewport_size")
		if v != null:
			size = Vector2i(v as Vector2)
			break
	inst.queue_free()
	return size


func _find_tabs(n: Node) -> TabContainer:
	if n is TabContainer:
		return n as TabContainer
	for c in n.get_children():
		var found := _find_tabs(c)
		if found != null:
			return found
	return null


## The row of pills TabStrip builds above the pages.
func _find_strip(n: Node) -> Control:
	if n is HFlowContainer:
		return n as Control
	for c in n.get_children():
		var found := _find_strip(c)
		if found != null:
			return found
	return null
