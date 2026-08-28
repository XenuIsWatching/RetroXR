## Times the menu operations that stutter, on whatever device it runs on.
##
## Booted by NetworkManager when user://perfprobe.cfg exists, so it can run on
## the Quest with nobody wearing it. Desktop numbers were misleading here: the
## costs are dominated by storage, and Quest internal storage is far slower.
##
## Prints [perf] lines and quits. Delete the .cfg after a run.
extends Node

const BIG := "game_boy_advance"

var _lines: PackedStringArray = PackedStringArray()


func _t() -> int:
	return Time.get_ticks_usec()


func _ms(a: int) -> float:
	return float(Time.get_ticks_usec() - a) / 1000.0


func _say(fmt: String, args: Array = []) -> void:
	var s: String = fmt % args if not args.is_empty() else fmt
	_lines.append(s)
	print("[perf] " + s)


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		_say("TIMEOUT")
		get_tree().quit(1))
	_run()


func _run() -> void:
	_say("device=%s  storage=%s", [OS.get_name(), OS.get_user_data_dir()])

	var cfg := RommConfig.new()
	cfg.load_config()
	_say("romm configured=%s  url=%s", [cfg.is_configured(), cfg.base_url])

	# ---- 1. Raw index cost, cold vs warm ----------------------------------
	# The single biggest desktop cost, and the one most likely to be worse here.
	var synced: Array[String] = []
	for sid: String in ["game_boy_advance", "nds", "nes", "mega_drive", "3ds"]:
		if RommCatalog.has_index(sid):
			synced.append(sid)
	_say("platforms with an index on device: %s", [str(synced)])

	for sid: String in synced:
		var c := RommCatalog.new()
		c.setup(cfg)
		add_child(c)
		var t := _t()
		var ok := c.load_index(sid)
		var cold := _ms(t)
		var n := c.count()
		c.unload_index()
		t = _t()
		c.load_index(sid)
		var warm := _ms(t)
		_say("load_index %-18s cold %8.2f ms   warm %7.2f ms   rows=%d ok=%s",
			[sid, cold, warm, n, ok])
		c.queue_free()

	# ---- 2. Prewarm on a worker, then measure the main-thread load ---------
	if not synced.is_empty():
		var sid: String = synced[0]
		var c2 := RommCatalog.new()
		c2.setup(cfg)
		add_child(c2)
		var t := _t()
		c2.prewarm_index(sid)
		var spun := 0
		while bool(c2.get("_warming")) and spun < 600:
			await get_tree().process_frame
			spun += 1
		_say("prewarm %s finished off-thread in %.0f ms (%d frames)", [sid, _ms(t), spun])
		t = _t()
		c2.load_index(sid)
		_say("load_index after prewarm      %8.2f ms   <-- what the UI pays", [_ms(t)])
		c2.queue_free()

	# ---- 3. Directory listing ---------------------------------------------
	for sid: String in synced:
		var t := _t()
		var roms := RomLibrary.scan_roms(sid, [] as Array[String])
		_say("scan_roms %-18s %8.2f ms   %d local files", [sid, _ms(t), roms.size()])

	# ---- 4. The real menu ---------------------------------------------------
	var sv := SubViewport.new()
	sv.size = Vector2i(2200, 1500)
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)

	var t_build := _t()
	var menu: Control = load("res://Scenes/UI/spawn_menu.tscn").instantiate()
	menu.set_anchors_preset(Control.PRESET_FULL_RECT)
	sv.add_child(menu)
	for i in range(30):
		await get_tree().process_frame
	_say("menu instantiate + first frames  %8.2f ms", [_ms(t_build)])

	# Let the platform fetch land so the grid is populated as in real use.
	for i in range(120):
		await get_tree().process_frame

	var t := _t()
	menu.call("_populate_cartridges_tab")
	_say("_populate_cartridges_tab         %8.2f ms", [_ms(t)])

	var browser: Object = menu.get("_cartridges_browser")
	if browser != null:
		var target := BIG if BIG in synced else (synced[0] if not synced.is_empty() else "")
		if not target.is_empty():
			t = _t()
			browser.call("open_system", target)
			var open_ms := _ms(t)
			for i in range(4):
				await get_tree().process_frame
			var rows: Array = menu.get("_romm_rows")
			_say("open_system(%s)  %8.2f ms   %d rows  <-- the stutter",
				[target, open_ms, rows.size()])

			# Typing, one keystroke at a time, rebuilding synchronously so the
			# per-key cost is visible even though the UI now debounces it.
			for term: String in ["m", "ma", "mar", "mari", "mario"]:
				menu.set("_romm_filter", term)
				t = _t()
				menu.call("_rebuild_romm_rows")
				_say("  rebuild filter=%-6s        %8.2f ms   %d rows",
					['"' + term + '"', _ms(t), (menu.get("_romm_rows") as Array).size()])

	# ---- 4b. What the per-row loop actually costs ---------------------------
	# open_system is ~0.13 ms/row on device; this splits that between the parts
	# so the fix targets the right one instead of the plausible one.
	if not synced.is_empty():
		var sid: String = BIG if BIG in synced else synced[0]
		var c3 := RommCatalog.new()
		c3.setup(cfg)
		add_child(c3)
		c3.load_index(sid)
		var n := c3.count()

		t = _t()
		for i in n:
			var _l := c3.name_at(i)
		_say("loop: name_at only            %8.2f ms   (%d rows)", [_ms(t), n])

		t = _t()
		for i in n:
			var _k := c3.fs_basename_at(i)
		_say("loop: fs_basename_at only     %8.2f ms", [_ms(t)])

		t = _t()
		for i in n:
			var _r := c3.regions_at(i)
		_say("loop: regions_at only         %8.2f ms   <-- a split() per row", [_ms(t)])

		t = _t()
		var sink: Array = []
		for i in n:
			sink.append({"source": "server", "index": i, "path": "", "label": ""})
		_say("loop: one Dictionary per row  %8.2f ms", [_ms(t)])

		t = _t()
		var sink2 := PackedInt32Array()
		sink2.resize(n)
		for i in n:
			sink2[i] = i
		_say("loop: PackedInt32Array fill   %8.2f ms   <-- the slim alternative", [_ms(t)])

		t = _t()
		var seen: Dictionary = {}
		for i in n:
			for r: String in c3.regions_at(i):
				seen[r] = true
		_say("loop: regions_at + set build  %8.2f ms   %d distinct", [_ms(t), seen.size()])
		c3.queue_free()

	# ---- 5. Dropdown first build -------------------------------------------
	t = _t()
	menu.call("_prewarm_dropdowns")
	_say("_prewarm_dropdowns               %8.2f ms", [_ms(t)])

	_say("---- done ----")
	# Leave the results where adb can read them without racing logcat.
	var f := FileAccess.open("user://perf_result.txt", FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(_lines))
		f.close()
	get_tree().quit(0)
