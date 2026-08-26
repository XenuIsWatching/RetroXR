## SpawnMenuCoresView — the menu's CORES tab: the three sub-tabs that get an
## emulator core onto the device and keep it fed.
##
##  * Download — what the buildbot has, grouped by system.
##  * Manager  — what is installed, and what it is set to run.
##  * BIOS / Extras — the firmware and asset files a core needs before it will
##    boot anything, fetched from RomM where the server has them.
##
## Like OPTIONS this is a face over services the menu owns (the core database,
## the download manager, the firmware installer), so they are injected by
## create() rather than reached for. Manager and BIOS are rebuilt on entry
## rather than cached: both are derived from what is on disk, and installing a
## core changes both.
class_name SpawnMenuCoresView
extends VBoxContainer

## The visible sub-tab's scroll changed — the menu drives the thumbstick from it.
signal scroll_changed(scroll: ScrollContainer)
## A system's default core was changed here. The SPAWN tab lists cores per
## system, so it has to repaint.
signal default_core_changed(systemid: String, core_name: String)

var core_db: CoreInfoDatabase = null
var core_defaults: CoreDefaults = null
var download_manager: CoreDownloadManager = null
var romm_config: RommConfig = null
var romm_firmware: RommFirmware = null

## The menu, for raising notifications. Typed Node so the two classes do not
## name each other — see the same note on SpawnMenuOptionsView.
var _menu: Node = null

var _cores_tabs: TabContainer = null

# Download tab
var _download_fetched: bool = false
var _download_widgets: Dictionary = {}
var _download_browser: SystemGridBrowser = null
var _download_cores_by_system: Dictionary = {}
var _recommend_all_btn: Button = null

# Manager tab — drill-down browser + installed cores grouped by systemid:
# sid -> Array[{ "core_name", "display_name" }]
var _manager_browser: SystemGridBrowser = null
## Which core the manager detail is editing options for. Empty shows the core list.
var _editing_options_core: String = ""
## The system that editor was opened from — leaving for another system drops it,
## or picking a different tile would land on the previous system's core.
var _editing_options_system: String = ""
var _manager_cores_by_system: Dictionary = {}

# BIOS / Extras tab
var _bios_browser: SystemGridBrowser = null
var _bios_cores_by_system: Dictionary = {}
var _bios_row_cache: Dictionary = {}
## folder path -> the per-core destination dirs for it. Same lifetime as the row
## cache: both are derived from what is installed, and both are rebuilt together.
var _bios_dest_cache: Dictionary = {}
## Uniform height of a picker row. The virtual list needs it up front — that is
## what lets it decide which rows are on screen without measuring any of them.
const PICKER_ROW_H := 46
var _firmware_installer: FirmwareInstaller = null
var _bios_job_buttons: Dictionary = {}
## Core awaiting its second delete press, "" when nothing is armed. Cleared by a
## rebuild rather than a timer — the row is redrawn on arm, so the armed glyph
## and this are always written together.
var _core_delete_armed := ""
## "<core>|<firmware path>" awaiting its second delete press.
var _bios_delete_armed := ""
## The button showing that armed state, so arming can repaint one control
## instead of rebuilding the tab. Cleared whenever a rebuild frees it.
var _bios_delete_armed_btn: Button = null
var _bios_refreshing := false
var _bios_refresh_queued := false
## "<core>|<folder path>" -> whether that folder's RomM picker is showing.
## Deliberately outlives a rebuild: every install refreshes the whole tab, and a
## picker that closed itself after each file would make choosing several a chore.
var _bios_dir_open: Dictionary = {}

## Toast key -> what that job is fetching, remembered from job_started. Only the
## start carries the name, and every message after it is keyed to the same bar —
## without this a progress tick overwrites "Downloading Snes9x" with a bare size,
## and four bars at once become four identical ones. Both job producers in this
## view fill it; cleared when the job ends.
var _job_labels: Dictionary = {}


static func create(menu: Node) -> SpawnMenuCoresView:
	var v := SpawnMenuCoresView.new()
	v._menu = menu
	v.core_db          = menu.core_db
	v.core_defaults    = menu.core_defaults
	v.download_manager = menu.download_manager
	v.romm_config      = menu.romm_config
	v.romm_firmware    = menu.romm_firmware
	v._build()
	return v


## The scroll belonging to whichever sub-tab is showing.
func active_scroll() -> ScrollContainer:
	var idx := _cores_tabs.current_tab if _cores_tabs else 0
	if idx == 1 and _manager_browser:
		return _manager_browser.get_active_scroll()
	if idx == 2 and _bios_browser:
		return _bios_browser.get_active_scroll()
	if _download_browser:
		return _download_browser.get_active_scroll()
	return null


func _update_cores_active_scroll() -> void:
	scroll_changed.emit(active_scroll())


## Connected to both browsers; reports a page switch inside a sub-tab.
func _on_cores_browser_scroll_changed(s: ScrollContainer) -> void:
	if visible:
		scroll_changed.emit(s)


## Fetch the buildbot list, once, the first time this tab is opened. Not done at
## startup: it is a network round trip for a tab the player may never visit.
func ensure_fetched() -> void:
	if _download_fetched:
		return
	_download_fetched = true
	_start_fetch()


func notify_clear(key: String) -> void:
	if _menu:
		_menu.notify_clear(key)


## Job reporting for the firmware installer, the core downloader and the
## buildbot fetch. Named for RomM because the firmware jobs came first; every
## job-shaped producer in this view goes through it.
##
## Note the argument flip: this takes (dwell, progress) and SpawnMenu2D.notify
## takes (progress, seconds). It used to call a `romm_notify_or_queue` that the
## menu has never had, so every toast raised here failed silently at runtime —
## a call by name on an untyped Node is not checked at parse time.
func _romm_notify_or_queue(key: String, icon: String, msg: String, dwell: float,
						   progress: float = -1.0) -> void:
	if _menu:
		_menu.notify(key, icon, msg, progress, dwell)

func _build() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_cores_tabs = tabs

	var dl_container := _build_download_tab()
	dl_container.name = "Download"
	tabs.add_child(dl_container)

	var mgr_container := _build_manager_tab()
	mgr_container.name = "Manager"
	tabs.add_child(mgr_container)

	var bios_container := _build_bios_tab()
	# The node name cannot hold the "/" — Godot rejects it in node names and
	# TabContainer titles each tab after its child, so it would read "BIOS _
	# Extras". The title has to be set separately, after the add.
	bios_container.name = "BIOSExtras"
	tabs.add_child(bios_container)
	tabs.set_tab_title(tabs.get_tab_count() - 1, "BIOS / Extras")

	# Both the Manager and BIOS lists are derived from what is on disk, so each
	# is rebuilt on entry rather than cached — installing a core changes both.
	tabs.tab_changed.connect(func(idx: int):
		if idx == 1:
			_populate_manager_tab()
		elif idx == 2:
			_populate_bios_tab()
		_update_cores_active_scroll()
	)

	add_child(TabStrip.wrap(tabs))


# ── Manager tab ───────────────────────────────────────────────────────────────────

func _build_manager_tab() -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)

	var hdr := Label.new()
	hdr.text = "Pick a system to set the default core it launches with."
	hdr.add_theme_font_size_override("font_size", 15)
	hdr.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	hdr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	outer.add_child(hdr)

	outer.add_child(HSeparator.new())

	_manager_browser = SystemGridBrowser.new()
	_manager_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_manager_browser.empty_text = "No cores downloaded yet.\nUse the Download tab to install cores."
	_manager_browser.set_detail_populator(_populate_manager_detail)
	_manager_browser.active_scroll_changed.connect(_on_cores_browser_scroll_changed)
	outer.add_child(_manager_browser)

	return outer


## Rebuild the Manager home grid: one tile per system with installed cores,
## badge = its current default core. Rescans the cores dir each call.
func _populate_manager_tab() -> void:
	if not _manager_browser:
		return

	_manager_cores_by_system.clear()
	var system_labels: Dictionary = {}   # systemid -> human label

	var cores_dir := CoreDownloadManager.default_cores_dir()
	var dir := DirAccess.open(cores_dir)
	if dir:
		var seen: Dictionary = {}   # a core can sit there under two naming conventions
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			var cn := "" if dir.current_is_dir() else CoreDownloadManager.core_name_from_lib_filename(fname)
			if not cn.is_empty() and not seen.has(cn):
				seen[cn] = true
				var info: Dictionary = core_db.get_by_core_name(cn)
				# Every platform the core serves, not only its own. A multi-system
				# core is a real choice on each of them, and this loop is what adopts
				# a first default and creates that platform's roms dir.
				var sids := CoreInfoDatabase.systemids_of(info)
				if sids.is_empty():
					sids = ["unknown"] as Array[String]
				for sid: String in sids:
					if not _manager_cores_by_system.has(sid):
						_manager_cores_by_system[sid] = []
						system_labels[sid] = cn if sid == "unknown" else core_db.get_systemname_for_id(sid)
					(_manager_cores_by_system[sid] as Array).append({"core_name": cn,
						"display_name": info.get("corename", cn) if not info.is_empty() else cn})
			fname = dir.get_next()
		dir.list_dir_end()

	var systems: Array = []
	for sid: String in _manager_cores_by_system:
		# Recommended first, so it heads the detail list AND is what the
		# no-default-yet branch below picks up.
		var cores_list: Array = CoreRecommendations.first(
			sid, _manager_cores_by_system[sid] as Array)
		_manager_cores_by_system[sid] = cores_list
		# If no default was saved yet, persist the first available core.
		var current_default: String = core_defaults.get_default_core(sid)
		if current_default.is_empty() and not cores_list.is_empty():
			current_default = (cores_list[0] as Dictionary)["core_name"] as String
			core_defaults.set_default_core(sid, current_default)
			core_defaults.save()
			RomLibrary.ensure_rom_dir(sid)
			default_core_changed.emit(sid, current_default)
		var badge := ""
		for e: Dictionary in cores_list:
			if e["core_name"] == current_default:
				badge = e["display_name"] as String
		systems.append({"systemid": sid, "name": system_labels[sid] as String, "badge": badge})

	_manager_browser.set_systems(systems)


## Detail page for one system: its installed cores, tap to set the default.
## Doubles as the option editor for one of those cores — same page, because the
## browser owns the detail area and the editor is reached from a row in this list.
func _populate_manager_detail(systemid: String, vbox: VBoxContainer) -> void:
	if not _editing_options_core.is_empty() and _editing_options_system != systemid:
		_editing_options_core = ""
	if not _editing_options_core.is_empty():
		_populate_core_options(systemid, _editing_options_core, vbox)
		return

	var cores: Array = _manager_cores_by_system.get(systemid, [])
	var current: String = core_defaults.get_default_core(systemid)
	for entry: Dictionary in cores:
		var cn: String = entry["core_name"] as String
		var is_def := cn == current

		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		row.custom_minimum_size = Vector2(0, 64)

		var lbl := Label.new()
		lbl.text = ("%s  " % String.chr(MenuIcons.CHECK)
			if is_def else "     ") + (entry["display_name"] as String)
		lbl.add_theme_font_override("font", MenuIcons.symbols())
		lbl.add_theme_font_size_override("font_size", 20)
		lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE if is_def else MenuStyle.COLOR_LICENSE)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		row.add_child(lbl)

		# Its own element rather than a recolour of the name: the name's ✓ and
		# colour already mean "this is your default", and the two states are
		# independent — a core can be recommended without being selected.
		if CoreRecommendations.is_recommended(systemid, cn):
			row.add_child(MenuIcons.recommended_badge(16))

		var netplay_lbl := MenuIcons.netplay_badge(16, cn)
		if netplay_lbl != null:
			row.add_child(netplay_lbl)

		var btn := Button.new()
		btn.text = "Default" if is_def else "Set default"
		btn.disabled = is_def
		btn.custom_minimum_size = Vector2(180, 52)
		btn.add_theme_font_size_override("font_size", 17)
		btn.pressed.connect(func() -> void:
			core_defaults.set_default_core(systemid, cn)
			core_defaults.save()
			RomLibrary.ensure_rom_dir(systemid)
			default_core_changed.emit(systemid, cn)
			# Rebuild tiles (badge) then re-render this detail (checkmarks).
			_populate_manager_tab()
			_manager_browser.open_system(systemid)
		)
		row.add_child(btn)

		# Options are readable straight out of the core file, so this works for a
		# core that has never been launched — which is the point: set it up before
		# the first boot rather than after it goes wrong.
		var opts_btn := Button.new()
		opts_btn.text = String.chr(MenuIcons.SETTINGS)
		opts_btn.add_theme_font_override("font", MenuIcons.symbols())
		opts_btn.add_theme_font_size_override("font_size", 20)
		opts_btn.custom_minimum_size = Vector2(64, 52)
		opts_btn.tooltip_text = "Core options"
		opts_btn.pressed.connect(func() -> void:
			_editing_options_core = cn
			_editing_options_system = systemid
			_manager_browser.open_system(systemid)
		)
		row.add_child(opts_btn)
		row.add_child(_build_core_delete_button(systemid, cn, entry["display_name"] as String))

		vbox.add_child(row)
		vbox.add_child(HSeparator.new())


## Uninstall a core. Two presses, like deleting a ROM — a mis-tap here means
## re-downloading tens of megabytes.
##
## The glyph is DELETE, never DELETE_FOREVER: a core is always on the buildbot,
## which is the distinction those two pictograms carry everywhere else.
func _build_core_delete_button(systemid: String, core_name: String,
							   display_name: String) -> Button:
	var armed := _core_delete_armed == core_name
	var btn := Button.new()
	btn.add_theme_font_override("font", MenuIcons.symbols())
	btn.add_theme_font_size_override("font_size", 20)
	btn.custom_minimum_size = Vector2(64, 52)
	btn.text = String.chr(MenuIcons.ERROR if armed else MenuIcons.DELETE)
	btn.add_theme_color_override("font_color",
		MenuIcons.TINT_WARN if armed else MenuIcons.TINT_DELETE)
	btn.tooltip_text = "Press again to remove this core" if armed \
		else "Remove this core (its BIOS files and settings are kept)"

	btn.pressed.connect(func() -> void:
		# A core is copied to a temp dir when it loads, so removing it under a
		# running machine does not crash — it fails that machine's NEXT start,
		# which is far enough away that nobody connects it to this button.
		var in_use := CoreDownloadManager.systems_using(core_name)
		if not in_use.is_empty():
			_core_delete_armed = ""
			_romm_notify_or_queue("cores:delete", String.chr(MenuIcons.ERROR),
				"%s is in use by %s" % [display_name, ", ".join(in_use)],
				MenuToasts.DWELL_FAIL)
			return

		if not armed:
			_core_delete_armed = core_name
			_romm_notify_or_queue("cores:delete", String.chr(MenuIcons.ERROR),
				"Press again to remove %s" % display_name, 3.0)
			_manager_browser.open_system(systemid)
			return

		_core_delete_armed = ""
		var res := CoreDownloadManager.uninstall(core_name)
		if bool(res["ok"]):
			# The default points at a core that is gone; leaving it would make
			# every spawn of this system fail with nothing on screen to explain it.
			if core_defaults.get_default_core(systemid) == core_name:
				core_defaults.set_default_core(systemid, "")
				core_defaults.save()
				default_core_changed.emit(systemid, "")
			_romm_notify_or_queue("cores:delete", String.chr(MenuIcons.CHECK),
				"Removed %s (%s freed)" % [display_name,
					String.humanize_size(int(res["freed"]))],
				MenuToasts.DWELL_OK)
		else:
			_romm_notify_or_queue("cores:delete", String.chr(MenuIcons.ERROR),
				"%s — %s" % [display_name, str(res["error"])], MenuToasts.DWELL_FAIL)
		refresh_after_core_change()
	)
	return btn


## Re-derive every tab that reads the cores directory. Installing or removing a
## core changes the Download list's state, the Manager grid and the BIOS grid
## alike, and a stale one of those is how a removed core keeps offering options.
func refresh_after_core_change() -> void:
	_populate_manager_tab()
	if not _manager_browser.current_systemid().is_empty():
		_manager_browser.open_system(_manager_browser.current_systemid())
	_refresh_bios_soon()
	refresh_download_systems()


## Option editor for one core, read out of the core file itself so it works before
## that core has ever run. Cores that publish nothing until content is loaded say
## so rather than showing an empty list.
func _populate_core_options(systemid: String, core_name: String, vbox: VBoxContainer) -> void:
	var root := CoreOptionsStore.default_root()

	var back := Button.new()
	back.add_theme_font_override("font", MenuIcons.symbols())
	back.text = "%s  Back to cores" % String.chr(MenuIcons.BACK)
	back.custom_minimum_size = Vector2(0, 52)
	back.add_theme_font_size_override("font_size", 17)
	back.pressed.connect(func() -> void:
		_editing_options_core = ""
		_manager_browser.open_system(systemid)
	)
	vbox.add_child(back)

	_add_frontend_section(core_name, vbox)

	var peeked := CoreOptionsStore.peek(root, core_name)
	if peeked.is_empty():
		var msg := Label.new()
		msg.text = CoreOptionsStore.peek_failure_reason(root, core_name)
		msg.add_theme_font_size_override("font_size", 17)
		msg.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
		msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		msg.custom_minimum_size = Vector2(0, 80)
		vbox.add_child(msg)
		return

	var definitions: Dictionary = peeked["definitions"]
	var values := CoreOptionsStore.effective_values(peeked,
		CoreOptionsStore.load_values(root, core_name))

	vbox.add_child(MenuStyle.header("CORE OPTIONS", 20))

	# Under the heading, not above it: it resets the core's own keys and not the
	# FRONTEND row, and sitting between the two sections it read as covering both.
	var reset := Button.new()
	reset.text = "Reset all to defaults"
	reset.custom_minimum_size = Vector2(0, 52)
	reset.add_theme_font_size_override("font_size", 17)
	reset.pressed.connect(func() -> void:
		CoreOptionsStore.reset_to_defaults(root, core_name, peeked)
		_manager_browser.open_system(systemid)
	)
	vbox.add_child(reset)
	vbox.add_child(HSeparator.new())

	var keys: Array = definitions.keys()
	keys.sort()
	for key: String in keys:
		_add_core_option_row(root, core_name, systemid, key, definitions[key],
			String(values.get(key, "")), vbox)


## What this frontend hands the core, above the core's own options.
##
## Under its own heading rather than folded into the list below, because the
## rows are not the same kind of thing: every CORE OPTIONS row is a key the core
## publishes about itself, written to that core's option file. This one is our
## answer to GET_PREFERRED_HW_RENDER, kept in AppPrefs, and a core that never
## asks the question will never see it. Built before the option peek, so it is
## still here for a core that publishes nothing until content is loaded.
func _add_frontend_section(core_name: String, vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.header("FRONTEND", 20))

	# "" is no override — the entry names the global so the page says what this
	# core will actually get, not merely that it is following something.
	var choices: Array = AppPrefs.hw_render_choices()
	if choices.is_empty():
		vbox.add_child(MenuStyle.hint(
			"Hardware-rendered libretro cores are not available on this platform."))
		vbox.add_child(HSeparator.new())
		return
	var default_label := "Default"
	for choice: Array in choices:
		if str(choice[1]) == AppPrefs.DEFAULT_HW_RENDER:
			default_label = "Default (%s)" % str(choice[0])
	var options: Array = [[default_label, ""]]
	for choice: Array in choices:
		options.append([str(choice[0]), str(choice[1])])

	# VRDropdown, never OptionButton — every Viewport2Din3D click fires twice.
	var drop := VRDropdown.create("Preferred HW Render", options,
		AppPrefs.hw_render_override(core_name), 1, Vector2(260, 56), 18)
	drop.item_selected.connect(func(id: Variant) -> void:
		AppPrefs.set_hw_render_override(core_name, str(id))
	)
	vbox.add_child(drop)

	vbox.add_child(MenuStyle.hint(
		"Which API this core is told the frontend would rather render with. "
		+ "Only cores that can do more than one — Dolphin, Flycast, PPSSPP — "
		+ "act on it; the rest name their own and ignore it. Applied as the "
		+ "core starts, so a machine already switched on keeps what it booted with."))

	vbox.add_child(HSeparator.new())


## One option row: description, then < value > to cycle. Writes straight through
## to the core's option file — there is no Apply, because the file IS the state
## the next launch reads.
func _add_core_option_row(root: String, core_name: String, _systemid: String, key: String,
		defn: Object, current_val: String, vbox: VBoxContainer) -> void:
	var values_arr: Array = defn.GetValues()
	if values_arr.is_empty():
		return

	var desc: String = defn.GetDescription()
	if desc.is_empty():
		desc = key
	# Two reasons a key can be locked here, and they say different things to the
	# player: the hardware one cannot be unlocked at all, the BIOS one is a switch
	# in OPTIONS > Systems. HARDWARE_PINNED deliberately does not carry the BIOS
	# keys — it also drives reset_to_defaults, which must keep restoring them.
	var hardware_pinned: bool = CoreOptionsStore.HARDWARE_PINNED.has(key)
	var bios_pinned: bool = not AppPrefs.bios_boot_override \
		and BiosBoot.pinned_keys_for_core(core_name).has(key)
	var pinned: bool = hardware_pinned or bios_pinned

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.custom_minimum_size = Vector2(0, 56)

	var lbl := Label.new()
	lbl.text = desc
	lbl.add_theme_font_size_override("font_size", 17)
	lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(lbl)

	# Its own Label rather than appended to the description: the note is the part
	# that needs to stand out, and a single Label can only carry one colour.
	if pinned:
		var note := Label.new()
		note.text = "(fixed by the hardware)" if hardware_pinned else "(fixed for BIOS boot)"
		note.add_theme_font_size_override("font_size", 15)
		note.add_theme_color_override("font_color", MenuIcons.TINT_WARN)
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(note)

	var idx := 0
	for i in range(values_arr.size()):
		if values_arr[i].GetValue() == current_val:
			idx = i
			break

	var prev_btn := Button.new()
	prev_btn.text = " < "
	prev_btn.custom_minimum_size = Vector2(52, 48)
	prev_btn.disabled = pinned
	row.add_child(prev_btn)

	var val_lbl := Label.new()
	val_lbl.custom_minimum_size = Vector2(170, 0)
	val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val_lbl.add_theme_font_size_override("font_size", 16)
	val_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	val_lbl.clip_text = true
	val_lbl.text = _option_value_label(values_arr[idx])
	row.add_child(val_lbl)

	var next_btn := Button.new()
	next_btn.text = " > "
	next_btn.custom_minimum_size = Vector2(52, 48)
	next_btn.disabled = pinned
	row.add_child(next_btn)

	# Boxed so both lambdas share one cursor; a plain local is captured by value.
	var idx_ref := [idx]
	var step := func(delta: int) -> void:
		idx_ref[0] = (idx_ref[0] + delta + values_arr.size()) % values_arr.size()
		var v: Object = values_arr[idx_ref[0]]
		val_lbl.text = _option_value_label(v)
		CoreOptionsStore.set_value(root, core_name, key, v.GetValue())
	prev_btn.pressed.connect(func() -> void: step.call(-1))
	next_btn.pressed.connect(func() -> void: step.call(1))

	vbox.add_child(row)
	vbox.add_child(HSeparator.new())


func _option_value_label(v: Object) -> String:
	var lbl: String = v.GetLabel()
	return lbl if not lbl.is_empty() else v.GetValue()


# ── BIOS / Extras tab ─────────────────────────────────────────────────────────
#
# Every installed core declares, in its .info, the files it wants in its system
# directory. Nothing surfaced them before, so a core that cannot boot without a
# BIOS just failed silently. This lists them per system, marks what is there,
# and (Phase 2/3) fetches what is not.
#
# Required and optional are shown very differently on purpose: of the ~149
# entries a typical install declares, only about 6 are actually required. A red
# cross on every missing optional would paint every system as broken.

func _build_bios_tab() -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)

	var hdr_row := MenuStyle.hbox(10)

	var hdr := Label.new()
	hdr.text = "Files each core needs in its system folder. Only missing required files stop a game from running."
	hdr.add_theme_font_size_override("font_size", 15)
	hdr.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	hdr.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hdr_row.add_child(hdr)

	# The disk is rescanned on every entry to this tab, but the RomM listing is
	# fetched once per session — firmware uploaded to the server after that first
	# look is invisible until a restart without this.
	var recheck := Button.new()
	recheck.text = "%s  Re-check" % String.chr(MenuIcons.RETRY)
	recheck.add_theme_font_override("font", MenuIcons.symbols())
	recheck.add_theme_font_size_override("font_size", 16)
	recheck.custom_minimum_size = Vector2(150, 44)
	recheck.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	recheck.tooltip_text = "Rescan the system folders and ask RomM for its firmware list again"
	recheck.pressed.connect(_on_bios_recheck_pressed)
	hdr_row.add_child(recheck)

	outer.add_child(hdr_row)

	outer.add_child(HSeparator.new())

	_bios_browser = SystemGridBrowser.new()
	_bios_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_bios_browser.empty_text = "No cores downloaded yet.\nUse the Download tab to install cores."
	_bios_browser.filter_placeholder = "Filter systems…"
	_bios_browser.set_detail_populator(_populate_bios_detail)
	_bios_browser.active_scroll_changed.connect(_on_cores_browser_scroll_changed)
	outer.add_child(_bios_browser)

	_firmware_installer = FirmwareInstaller.new()
	_firmware_installer.name = "FirmwareInstaller"
	_firmware_installer.job_started.connect(_on_firmware_started)
	_firmware_installer.job_progress.connect(_on_firmware_progress)
	_firmware_installer.job_retrying.connect(_on_firmware_retrying)
	_firmware_installer.job_finished.connect(_on_firmware_finished)
	_firmware_installer.job_cancelled.connect(_on_firmware_cancelled)
	add_child(_firmware_installer)

	return outer


# ── Install progress ──────────────────────────────────────────────────────────

## What a job's bar reads while it runs. The name comes first and stays there:
## several of these can be up at once, and a bar saying only "43%" or "12.4 MiB"
## belongs to any of them.
##
## The size is appended once it is known rather than at the start — the core
## downloader emits job_started with a total of 0, because the buildbot's
## Content-Length is not in hand until the response arrives.
func _job_text(key: String, total: int) -> String:
	var label := str(_job_labels.get(key, ""))
	if label.is_empty():
		label = "…"
	if total <= 0:
		return "Downloading %s" % label
	return "Downloading %s  (%s)" % [label, String.humanize_size(total)]


## For a message that ends the job. "Installed" alone left four finished bars
## saying the same word.
func _job_label(key: String) -> String:
	var label := str(_job_labels.get(key, ""))
	return label if not label.is_empty() else "Download"


func _on_firmware_started(key: String, label: String, total: int) -> void:
	_job_labels[key] = label
	_romm_notify_or_queue(key, String.chr(MenuIcons.BUSY),
		_job_text(key, total), 0.0, 0.0)


func _on_firmware_progress(key: String, received: int, total: int) -> void:
	var frac := 0.0 if total <= 0 else clampf(float(received) / float(total), 0.0, 1.0)
	var btn := _bios_job_buttons.get(key) as Button
	if btn != null and is_instance_valid(btn):
		btn.text = "%d%%" % int(frac * 100.0)
	_romm_notify_or_queue(key, String.chr(MenuIcons.BUSY),
		_job_text(key, total), 0.0, frac)


func _on_firmware_retrying(key: String, attempt: int, total: int, reason: String) -> void:
	_romm_notify_or_queue(key, String.chr(MenuIcons.RETRY),
		"%s — retry %d of %d: %s" % [_job_label(key), attempt, total, reason], 0.0)


func _on_firmware_finished(key: String, ok: bool, error: String) -> void:
	_bios_job_buttons.erase(key)
	if ok:
		_romm_notify_or_queue(key, String.chr(MenuIcons.CHECK),
			"%s installed" % _job_label(key), MenuToasts.DWELL_OK)
	else:
		_romm_notify_or_queue(key, String.chr(MenuIcons.ERROR),
			"%s — %s" % [_job_label(key),
				error if not error.is_empty() else "install failed"],
			MenuToasts.DWELL_FAIL)
	_job_labels.erase(key)
	_refresh_bios_soon()


func _on_firmware_cancelled(key: String) -> void:
	_bios_job_buttons.erase(key)
	_job_labels.erase(key)
	notify_clear(key)
	_refresh_bios_soon()


## One rebuild per frame, however many jobs report in it. Stopping a fetch-all
## cancels every queued file at once, and a full rescan-and-redraw each time
## froze the panel for as long as the list was.
func _refresh_bios_soon() -> void:
	# Once per BATCH, not once per file. A full rebuild measures 63 ms on a
	# desktop and several hundred on a headset — rescanning every installed
	# core's requirements and rebuilding a 68-row picker — and Get all fires this
	# on every one of 68 completions. Coalescing to one per frame was not enough:
	# the frames themselves were the stall.
	#
	# Nothing is lost by waiting. A running file's own button is driven directly
	# from _bios_job_buttons by the progress handler, so the row the user is
	# watching stays live; only the status glyphs lag, and they are settled by
	# the rebuild the last completion triggers.
	if _firmware_installer != null and _firmware_installer.queued_count() > 0:
		return
	if _bios_refresh_queued:
		return
	_bios_refresh_queued = true
	_do_refresh_bios_soon.call_deferred()


func _do_refresh_bios_soon() -> void:
	_bios_refresh_queued = false
	refresh_bios_view()


## The only caller that forces a re-listing. `_populate_bios_tab` must not: it
## also runs after every install and cancel, so forcing there would spend a
## request per job.
##
## Ordered force-then-redraw — the redraw's own bare refresh() is swallowed by
## `_in_flight`, so this is one request, not two. The repaint that shows the new
## firmware comes from `listed`, which the menu already routes back here.
func _on_bios_recheck_pressed() -> void:
	if romm_firmware != null and romm_config != null and romm_config.is_configured():
		# Sticky: cleared or replaced when `listed` lands. Only raised once the
		# request is certain to be dispatched, or nothing would ever take it down.
		_romm_notify_or_queue("romm:firmware", String.chr(MenuIcons.BUSY),
			"Checking RomM…", 0.0)
		romm_firmware.refresh(true)
	refresh_bios_view()


## Re-derive status and redraw, keeping the user where they were.
## Guarded: a rebuild touches the RomM list and the installer, either of which
## can call back into here.
## Public: the menu owns the RomM firmware listing and asks for a repaint when
## it lands.
func refresh_bios_view() -> void:
	if _bios_browser == null or _bios_refreshing:
		return
	_bios_refreshing = true
	var open_sid := _bios_browser.current_systemid()
	_populate_bios_tab()
	if not open_sid.is_empty():
		_bios_browser.open_system(open_sid)
	_bios_refreshing = false


## Rebuild the home grid: one tile per system that has an installed core, badged
## with what that system is still missing. Rescans the cores dir and the system
## dirs on every call, so installing a core or dropping a BIOS in by hand shows
## up without a restart.
func _populate_bios_tab() -> void:
	if not _bios_browser:
		return

	# Dropped in by hand or by the web uploader since the last look — the whole
	# point of the tab is that it reflects the disk, so nothing survives a rebuild.
	_bios_row_cache.clear()
	_bios_dest_cache.clear()
	_bios_cores_by_system = FirmwareRequirements.installed_cores_by_system()

	# One request per session, and the grid does not wait for it — `listed`
	# redraws when it lands.
	if romm_firmware != null and romm_config != null and romm_config.is_configured():
		romm_firmware.refresh()

	var systems: Array = []
	for sid: String in _bios_cores_by_system:
		var rows: Array[Dictionary] = []
		for c: Dictionary in _bios_cores_by_system[sid]:
			rows.append_array(_bios_rows_for_core(str(c["core_name"])))
		# A core with nothing to declare is not "complete", it is silent — no
		# tile, so the grid only shows systems where there is something to know.
		if rows.is_empty():
			continue
		systems.append({
			"systemid": sid,
			"name": core_db.get_systemname_for_id(sid) if sid != "unknown" else "Other",
			"badge": str(FirmwareState.summarise(rows)["badge"]),
		})

	_bios_browser.set_systems(systems)


## Resolved status rows for one core, memoised for the life of this rebuild.
func _bios_rows_for_core(core_name: String) -> Array[Dictionary]:
	if _bios_row_cache.has(core_name):
		return _bios_row_cache[core_name]
	var rows := FirmwareState.shared().evaluate(
		core_name, FirmwareRequirements.for_core(core_name))
	# Carried on the row so a detail row knows which core's system dir it is
	# talking about without the builder having to be told separately.
	for r: Dictionary in rows:
		r["core_name"] = core_name
	_bios_row_cache[core_name] = rows
	return rows


## Detail page: every declared file for every installed core of this system.
## Grouped by core, with the heading shown only when there is more than one —
## the requirements genuinely differ between cores for the same machine.
func _populate_bios_detail(systemid: String, vbox: VBoxContainer) -> void:
	var cores: Array = _bios_cores_by_system.get(systemid, [])
	var multi := cores.size() > 1

	var path_row := HBoxContainer.new()
	var path_lbl := Label.new()
	path_lbl.text = "Files go in:  %s" % CoreDownloadManager.default_system_dir("<core>")
	path_lbl.add_theme_font_size_override("font_size", 14)
	path_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
	path_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	path_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_row.add_child(path_lbl)
	vbox.add_child(path_row)
	vbox.add_child(HSeparator.new())

	for entry: Dictionary in cores:
		var cn: String = entry["core_name"]
		var rows := _bios_rows_for_core(cn)
		if rows.is_empty():
			continue

		if multi:
			vbox.add_child(MenuStyle.label(str(entry["display_name"]), 20, MenuStyle.COLOR_TITLE))

		if SystemAssetCatalog.has_archive(cn):
			vbox.add_child(_build_bios_archive_row(cn, rows))

		for r: Dictionary in rows:
			vbox.add_child(_build_bios_row(r, systemid))
			if bool(r.get("is_dir", false)) and _bios_dir_is_open(cn, str(r.get("path", ""))):
				vbox.add_child(_build_bios_picker(r, systemid))

		vbox.add_child(HSeparator.new())


## The one-tap route for cores whose support files libretro redistributes.
## An archive unpacks straight over the declared paths, so it fills in every row
## it covers at once — for ScummVM that is all 39.
func _build_bios_archive_row(core_name: String, rows: Array[Dictionary]) -> Control:
	var key := "bios:zip:%s" % core_name

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 60)

	var lbl := Label.new()
	lbl.text = SystemAssetCatalog.button_label(core_name)
	lbl.add_theme_font_size_override("font_size", 17)
	lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(lbl)

	var running := _firmware_installer != null and _firmware_installer.is_queued(key)

	# "Every row present" is not a usable test for whether the archive ran:
	# Dolphin.zip carries one of the four files dolphin declares and never the
	# three GameCube IPL dumps, so it can never reach zero outstanding. The
	# recorded install is what makes those cases readable; the zero-outstanding
	# case still counts, so a tree that predates this feature reads correctly.
	var outstanding := 0
	for r: Dictionary in rows:
		if int(r.get("status", 0)) != FirmwareState.Status.PRESENT:
			outstanding += 1
	var installed := SystemAssetCatalog.is_installed(core_name) or outstanding == 0

	if installed and not running:
		var done := Label.new()
		done.text = "Installed"
		done.add_theme_font_size_override("font_size", 15)
		done.add_theme_color_override("font_color", MenuIcons.TINT_OK)
		done.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(done)

	var btn := Button.new()
	btn.add_theme_font_override("font", MenuIcons.symbols())
	btn.add_theme_font_size_override("font_size", 22)
	btn.custom_minimum_size = Vector2(120, 52)
	if running:
		btn.text = String.chr(MenuIcons.BUSY)
		btn.add_theme_color_override("font_color", MenuIcons.TINT_BUSY)
		btn.tooltip_text = "Downloading — press to cancel"
	elif installed:
		# Still pressable: re-running the archive is how you repair a file that
		# went bad, so the affordance stays and only its reading changes.
		btn.text = String.chr(MenuIcons.RETRY)
		btn.add_theme_color_override("font_color", MenuIcons.TINT_MUTED)
		btn.tooltip_text = "Already installed — download again to replace these files"
	else:
		btn.text = String.chr(MenuIcons.DOWNLOAD)
		btn.add_theme_color_override("font_color", MenuIcons.TINT_DOWNLOAD)
		btn.tooltip_text = "Download and unpack into this core's system folder"
	btn.pressed.connect(func() -> void:
		if _firmware_installer == null:
			return
		if _firmware_installer.is_queued(key):
			_firmware_installer.cancel_current()
			return
		_bios_job_buttons[key] = btn
		_firmware_installer.enqueue_archive(key, core_name)
		btn.text = "0%"
		btn.add_theme_color_override("font_color", MenuIcons.TINT_BUSY)
	)
	row.add_child(btn)

	var gutter := Control.new()
	gutter.custom_minimum_size = Vector2(44, 0)
	gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gutter)

	return row


## One firmware row: status glyph, path, description, and an Optional tag.
func _build_bios_row(r: Dictionary, systemid: String) -> Control:
	var status := int(r.get("status", FirmwareState.Status.PRESENT))
	var optional: bool = bool(r.get("optional", true))

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 56)

	var glyph := Label.new()
	glyph.add_theme_font_override("font", MenuIcons.symbols())
	glyph.add_theme_font_size_override("font_size", 26)
	glyph.custom_minimum_size = Vector2(40, 0)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	match status:
		FirmwareState.Status.PRESENT:
			glyph.text = String.chr(MenuIcons.CHECK)
			glyph.add_theme_color_override("font_color", MenuIcons.TINT_OK)
		FirmwareState.Status.MISMATCH:
			glyph.text = String.chr(MenuIcons.ERROR)
			glyph.add_theme_color_override("font_color", MenuIcons.TINT_WARN)
		FirmwareState.Status.MISSING_REQUIRED:
			glyph.text = String.chr(MenuIcons.CROSS)
			glyph.add_theme_color_override("font_color", MenuIcons.TINT_DELETE)
		_:
			glyph.text = String.chr(MenuIcons.DASH)
			glyph.add_theme_color_override("font_color", MenuIcons.TINT_MUTED)
	row.add_child(glyph)

	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 0)
	row.add_child(col)

	var name_lbl := Label.new()
	name_lbl.text = str(r.get("path", ""))
	name_lbl.add_theme_font_size_override("font_size", 19)
	name_lbl.add_theme_color_override("font_color",
		MenuStyle.COLOR_TITLE if status != FirmwareState.Status.MISSING_OPTIONAL else MenuStyle.COLOR_LICENSE)
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	col.add_child(name_lbl)

	var desc := _bios_desc_for(str(r.get("path", "")), str(r.get("desc", "")))
	if not desc.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = desc
		desc_lbl.add_theme_font_size_override("font_size", 15)
		desc_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
		desc_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		col.add_child(desc_lbl)

	var tag := Label.new()
	tag.add_theme_font_size_override("font_size", 15)
	tag.custom_minimum_size = Vector2(170, 0)
	tag.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	tag.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	if status == FirmwareState.Status.MISMATCH:
		tag.text = "Wrong file"
		tag.add_theme_color_override("font_color", MenuIcons.TINT_WARN)
	elif optional:
		tag.text = "Optional"
		tag.add_theme_color_override("font_color", MenuIcons.TINT_MUTED)
	else:
		tag.text = "Required"
		tag.add_theme_color_override("font_color",
			MenuIcons.TINT_DELETE if status == FirmwareState.Status.MISSING_REQUIRED else MenuStyle.COLOR_LICENSE)
	row.add_child(tag)

	row.add_child(_build_bios_action(r, systemid))

	# The detail list scrolls, and its scrollbar is 40 px wide and drawn over the
	# content — without this the tag sits underneath it.
	var gutter := Control.new()
	gutter.custom_minimum_size = Vector2(44, 0)
	gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gutter)

	return row


## The right-hand cell of a firmware row.
##
## A cloud button when RomM is holding this file, and otherwise a plain note
## saying so — most declared BIOSes are console dumps no server redistributes,
## and a dead button on every one of them would read as broken.
func _build_bios_action(r: Dictionary, systemid: String) -> Control:
	var status := int(r.get("status", FirmwareState.Status.PRESENT))
	var path := str(r.get("path", ""))

	var cell := HBoxContainer.new()
	cell.custom_minimum_size = Vector2(230, 0)
	cell.alignment = BoxContainer.ALIGNMENT_END
	cell.add_theme_constant_override("separation", 10)

	# A folder requirement names no file, so there is nothing to look up by name.
	# It gets a picker over everything RomM holds for this system instead — and
	# it keeps that picker once satisfied, because "the folder exists" is a much
	# weaker thing to know than which dumps are in it.
	if bool(r.get("is_dir", false)):
		return _build_bios_dir_action(r, systemid, cell)

	# A file that is here can be removed — the only reason to, and the reason this
	# is worth having, is a MISMATCH: the classic wrong-region BIOS that the app
	# can already see is wrong but previously had no way to get rid of.
	if status == FirmwareState.Status.PRESENT or status == FirmwareState.Status.MISMATCH:
		cell.add_child(_build_firmware_delete_button(
			str(r.get("core_name", "")), path, str(r.get("dest", ""))))
		if status == FirmwareState.Status.PRESENT:
			return cell

	var hit: Dictionary = romm_firmware.find(path) if romm_firmware != null else {}
	if hit.is_empty():
		var note := Label.new()
		note.text = "Not on RomM" if _romm_ready() else ""
		note.add_theme_font_size_override("font_size", 14)
		note.add_theme_color_override("font_color", MenuIcons.TINT_MUTED)
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cell.add_child(note)
		return cell

	var core_name := str(r.get("core_name", ""))
	var key := "bios:file:%s:%s" % [core_name, path]
	var running := _firmware_installer != null and _firmware_installer.is_queued(key)

	# The mark says WHERE the file is coming from; the cloud says what pressing
	# it does. The rows beside it read "Not on RomM" as words, so the source
	# needs to be as legible as the absence of one.
	var mark := MenuIcons.romm_mark()
	if mark != null:
		var mark_rect := TextureRect.new()
		mark_rect.texture = mark
		mark_rect.custom_minimum_size = Vector2(30, 30)
		mark_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mark_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		mark_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mark_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark_rect.tooltip_text = "On your RomM server"
		cell.add_child(mark_rect)

	var btn := Button.new()
	btn.add_theme_font_override("font", MenuIcons.symbols())
	btn.add_theme_font_size_override("font_size", 22)
	btn.custom_minimum_size = Vector2(110, 48)
	btn.text = String.chr(MenuIcons.BUSY if running else MenuIcons.DOWNLOAD)
	btn.add_theme_color_override("font_color", MenuIcons.TINT_BUSY if running else MenuIcons.TINT_DOWNLOAD)
	btn.tooltip_text = "Download %s from RomM (%s)" % [
		str(hit["file_name"]), String.humanize_size(int(hit["size"]))]
	btn.pressed.connect(func() -> void:
		if _firmware_installer == null:
			return
		if _firmware_installer.is_queued(key):
			_firmware_installer.cancel_current()
			return
		_bios_job_buttons[key] = btn
		# One download, written to every installed core that declares this same
		# file — the system dir is per-core, so they each need their own copy.
		var dests := _bios_destinations_for(path)
		_firmware_installer.enqueue_file(
			key, path.get_file(), romm_config.base_url,
			RommFirmware.content_path(int(hit["id"]), str(hit["file_name"])),
			romm_config.auth_headers(), dests,
			int(hit["size"]), str(hit["md5"]))
		btn.text = "0%"
		btn.add_theme_color_override("font_color", MenuIcons.TINT_BUSY)
	)
	cell.add_child(btn)
	return cell


# ── Folder requirements ───────────────────────────────────────────────────────
#
# The PS2 cores declare "pcsx2/bios", a directory, and never say what belongs in
# it — any valid dump will do, and which one you want is a regional choice no
# .info can make. Matching by filename is therefore impossible; the join that
# does work is the platform, since RomM files its firmware under bios/<fs_slug>.

## Is this directory requirement one that BIOS dumps belong in?
##
## RomM's firmware store is BIOS files, so the picker must not be offered for a
## folder that wants something else. Only eight directory requirements exist in
## the whole info database and they split cleanly on the leaf name:
##
##   pcsx2/bios          pcsx2, pcee2, yaps2   — BIOS dumps
##   pcsx2/resources     pcee2, yaps2          — shaders, GameIndex.yaml, fonts
##   mkxp-z/RTP/...      mkxp-z                — RPG Maker Run Time Packages
##
## Without this the resources row got the same 68 PS2 BIOS files as the bios row,
## and pressing Get all on it filed twenty of them under pcsx2/resources on a
## real headset.
static func _is_bios_folder(path: String) -> bool:
	return path.trim_suffix("/").get_file().to_lower() == "bios"


## Everything the folder could hold: what RomM offers, plus what is already in
## it that RomM has never heard of.
##
## The second half is what makes the picker a manager rather than a download
## list. A BIOS dropped in by hand — which is how most people get one — was
## invisible here and therefore undeletable, so the row could say "complete"
## while holding a file the user wanted gone.
##
## Returns [{file_name, size, id, md5, on_server, here}], name-sorted.
func _bios_dir_entries(r: Dictionary, systemid: String) -> Array:
	var dir: String = FirmwareRequirements.destination(
		str(r.get("core_name", "")), str(r.get("path", "")))

	var out: Array = []
	var seen: Dictionary = {}
	# The server half is offered only where BIOS dumps belong. A non-BIOS folder
	# still lists what is already inside it, so its contents stay inspectable and
	# deletable — it just gets nothing pushed at it.
	var from_server: Array = romm_firmware.find_for_system(systemid) \
		if romm_firmware != null and _is_bios_folder(str(r.get("path", ""))) else []
	for e: Dictionary in from_server:
		var name := str(e["file_name"])
		seen[name.to_lower()] = true
		var row := e.duplicate()
		row["on_server"] = true
		row["here"] = FileAccess.file_exists(dir.path_join(name))
		out.append(row)

	var d := DirAccess.open(dir)
	if d != null:
		d.list_dir_begin()
		var fname := d.get_next()
		while fname != "":
			if not d.current_is_dir() and not fname.begins_with(".") \
					and not seen.has(fname.to_lower()):
				var f := FileAccess.open(dir.path_join(fname), FileAccess.READ)
				var size := int(f.get_length()) if f != null else 0
				if f != null:
					f.close()
				out.append({"file_name": fname, "size": size, "id": 0, "md5": "",
					"on_server": false, "here": true})
			fname = d.get_next()
		d.list_dir_end()

	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["file_name"]).naturalnocasecmp_to(str(b["file_name"])) < 0)
	return out


## The folder row's own cell: a count and a toggle for the list underneath.
func _build_bios_dir_action(r: Dictionary, systemid: String, cell: HBoxContainer) -> Control:
	var entries := _bios_dir_entries(r, systemid)
	if entries.is_empty():
		var note := Label.new()
		note.text = "Not on RomM" if _romm_ready() else ""
		note.add_theme_font_size_override("font_size", 14)
		note.add_theme_color_override("font_color", MenuIcons.TINT_MUTED)
		note.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cell.add_child(note)
		return cell

	var on_server := 0
	var here := 0
	for e: Dictionary in entries:
		if bool(e["on_server"]):
			on_server += 1
		if bool(e["here"]):
			here += 1

	# The mark says the server is the source of some of these. It is dropped when
	# none of them came from there, so a folder holding only hand-copied dumps
	# does not claim a provenance it hasn't got.
	var mark := MenuIcons.romm_mark() if on_server > 0 else null
	if mark != null:
		var mark_rect := TextureRect.new()
		mark_rect.texture = mark
		mark_rect.custom_minimum_size = Vector2(30, 30)
		mark_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mark_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		mark_rect.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		mark_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark_rect.tooltip_text = "On your RomM server"
		cell.add_child(mark_rect)

	var open := _bios_dir_is_open(str(r.get("core_name", "")), str(r.get("path", "")))
	var btn := Button.new()
	btn.add_theme_font_override("font", MenuIcons.symbols())
	btn.add_theme_font_size_override("font_size", 20)
	btn.custom_minimum_size = Vector2(110, 48)
	btn.text = "%d  %s" % [entries.size(),
		String.chr(MenuIcons.COLLAPSE if open else MenuIcons.EXPAND)]
	btn.add_theme_color_override("font_color",
		MenuIcons.TINT_OK if here > 0 else MenuIcons.TINT_DOWNLOAD)
	btn.tooltip_text = "%d in this folder, %d available on RomM" % [here, on_server]
	btn.pressed.connect(func() -> void:
		_bios_dir_open[_bios_dir_key(str(r.get("core_name", "")), str(r.get("path", "")))] = not open
		refresh_bios_view()
	)
	cell.add_child(btn)
	return cell


## The list itself, indented under its folder row: a fetch-all across the top,
## then one row per file — what the server holds, and what is already installed.
func _build_bios_picker(r: Dictionary, systemid: String) -> Control:
	var entries := _bios_dir_entries(r, systemid)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 50)
	margin.add_theme_constant_override("margin_bottom", 8)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	margin.add_child(box)

	var path := str(r.get("path", ""))
	var dir: String = FirmwareRequirements.destination(str(r.get("core_name", "")), path)

	# Outstanding drives both the button's wording and what it queues, so it is
	# computed once here rather than asked for twice.
	var outstanding: Array = []
	var outstanding_bytes := 0
	var in_flight := 0
	for e: Dictionary in entries:
		# Already here, or here only — a hand-copied file has no id to fetch.
		if bool(e["here"]) or not bool(e["on_server"]):
			continue
		outstanding.append(e)
		outstanding_bytes += int(e["size"])
		if _firmware_installer != null and _firmware_installer.is_queued(_bios_dir_job_key(path, str(e["file_name"]))):
			in_flight += 1

	box.add_child(_build_bios_picker_header(path, entries, outstanding, outstanding_bytes, in_flight))

	# A VirtualRowList, not one Control per file. PS2 offers 68 files and each
	# row is six Controls, so building them all cost ~400 allocations every time
	# this page was drawn — and the page is drawn again on every install, every
	# delete and every toggle. The pool only ever holds the rows on screen, so
	# the count stops mattering.
	var core_name := str(r.get("core_name", ""))
	var list := VirtualRowList.new()
	list.row_height = PICKER_ROW_H
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.set_row_builder(_build_blank_picker_row)
	list.set_row_binder(func(row: Control, i: int) -> void:
		if i >= 0 and i < entries.size():
			_bind_bios_picker_row(row, entries[i] as Dictionary, core_name, path, dir))
	box.add_child(list)
	list.set_row_count(entries.size())

	return margin


func _build_bios_picker_header(path: String, entries: Array, outstanding: Array,
							   outstanding_bytes: int, in_flight: int) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 48)

	var here := 0
	for e: Dictionary in entries:
		if bool(e["here"]):
			here += 1
	var lbl := Label.new()
	lbl.text = "%d in this folder · %d more on RomM" % [here, outstanding.size()]
	lbl.add_theme_font_size_override("font_size", 15)
	lbl.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(lbl)

	var btn := Button.new()
	btn.add_theme_font_override("font", MenuIcons.symbols())
	btn.add_theme_font_size_override("font_size", 16)
	btn.custom_minimum_size = Vector2(230, 44)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	if outstanding.is_empty():
		btn.text = "All installed"
		btn.disabled = true
		btn.add_theme_color_override("font_color_disabled", MenuIcons.TINT_OK)
	elif in_flight > 0:
		btn.text = "%s  Stop %d" % [String.chr(MenuIcons.BUSY), in_flight]
		btn.add_theme_color_override("font_color", MenuIcons.TINT_BUSY)
		btn.tooltip_text = "Cancel the files queued for this folder"
		btn.pressed.connect(func() -> void:
			if _firmware_installer == null:
				return
			for e: Dictionary in outstanding:
				_firmware_installer.cancel(_bios_dir_job_key(path, str(e["file_name"])))
		)
	else:
		# The size is on the button and not in a tooltip: these are whole BIOS
		# sets, and the PS2's is 68 files. Pressing it should not be a surprise.
		btn.text = "%s  Get all %d  (%s)" % [String.chr(MenuIcons.DOWNLOAD),
			outstanding.size(), String.humanize_size(outstanding_bytes)]
		btn.add_theme_color_override("font_color", MenuIcons.TINT_DOWNLOAD)
		btn.tooltip_text = "Download every file this system's folder is missing"
		btn.pressed.connect(func() -> void:
			var queued := 0
			for e: Dictionary in outstanding:
				if _enqueue_bios_dir_file(e, path):
					queued += 1
			if queued > 0:
				# Every row's button has to redraw as queued, and the alternative
				# is the header lying about what is happening.
				refresh_bios_view()
		)
	row.add_child(btn)

	var gutter := Control.new()
	gutter.custom_minimum_size = Vector2(44, 0)
	gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gutter)

	return row


## A blank picker row: the Controls, no data. Built at most pool-size times and
## then re-bound as the list scrolls, so nothing here may depend on which file
## it will show.
func _build_blank_picker_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, PICKER_ROW_H)

	var glyph := Label.new()
	glyph.name = "Glyph"
	glyph.add_theme_font_override("font", MenuIcons.symbols())
	glyph.add_theme_font_size_override("font_size", 20)
	glyph.custom_minimum_size = Vector2(30, 0)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(glyph)

	var name_lbl := Label.new()
	name_lbl.name = "Name"
	name_lbl.add_theme_font_size_override("font_size", 17)
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(name_lbl)

	var size_lbl := Label.new()
	size_lbl.name = "Size"
	size_lbl.add_theme_font_size_override("font_size", 14)
	size_lbl.add_theme_color_override("font_color", MenuIcons.TINT_MUTED)
	size_lbl.custom_minimum_size = Vector2(100, 0)
	size_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	size_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(size_lbl)

	var btn := Button.new()
	btn.name = "Action"
	btn.add_theme_font_override("font", MenuIcons.symbols())
	btn.add_theme_font_size_override("font_size", 20)
	btn.custom_minimum_size = Vector2(100, 40)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(btn)

	# Always present, shown only for a file that is here. A row whose children
	# come and go would change width as it is re-bound.
	var del := Button.new()
	del.name = "Delete"
	del.add_theme_font_override("font", MenuIcons.symbols())
	del.add_theme_font_size_override("font_size", 20)
	del.custom_minimum_size = Vector2(64, 44)
	del.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(del)

	var gutter := Control.new()
	gutter.custom_minimum_size = Vector2(44, 0)
	gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(gutter)

	return row


## Fill a pooled row for one file.
##
## Every signal is disconnected first: the same Control is re-bound to a
## different file as the list scrolls, and a stale `pressed` handler would
## download or delete whatever the row used to be.
func _bind_bios_picker_row(row: Control, e: Dictionary, core_name: String,
						   path: String, dir: String) -> void:
	var file_name := str(e["file_name"])
	var here := bool(e["here"])
	var on_server := bool(e["on_server"])
	var key := _bios_dir_job_key(path, file_name)
	var running := _firmware_installer != null and _firmware_installer.is_queued(key)

	var glyph := row.get_node("Glyph") as Label
	glyph.text = String.chr(MenuIcons.CHECK if here else MenuIcons.DASH)
	glyph.add_theme_color_override("font_color",
		MenuIcons.TINT_OK if here else MenuIcons.TINT_MUTED)

	var name_lbl := row.get_node("Name") as Label
	name_lbl.text = file_name
	name_lbl.add_theme_color_override("font_color",
		MenuStyle.COLOR_TITLE if here else MenuStyle.COLOR_LICENSE)

	(row.get_node("Size") as Label).text = String.humanize_size(int(e["size"]))

	var btn := row.get_node("Action") as Button
	_clear_pressed(btn)
	btn.disabled = false
	btn.flat = false
	if running:
		btn.text = String.chr(MenuIcons.BUSY)
		btn.add_theme_color_override("font_color", MenuIcons.TINT_BUSY)
		btn.tooltip_text = "Downloading — press to cancel"
	elif here and not on_server:
		# Dropped in by hand. There is nothing to re-fetch, and a button that
		# looks pressable but cannot act is worse than no button.
		btn.text = ""
		btn.disabled = true
		btn.flat = true
		btn.tooltip_text = "Not on RomM — this copy came from somewhere else"
	elif here:
		# Still pressable, for the same reason the archive row is: re-fetching is
		# how a bad dump gets repaired.
		btn.text = String.chr(MenuIcons.RETRY)
		btn.add_theme_color_override("font_color", MenuIcons.TINT_MUTED)
		btn.tooltip_text = "Already in the folder — download again to replace it"
	else:
		btn.text = String.chr(MenuIcons.DOWNLOAD)
		btn.add_theme_color_override("font_color", MenuIcons.TINT_DOWNLOAD)
		btn.tooltip_text = "Download %s from RomM (%s)" % [
			file_name, String.humanize_size(int(e["size"]))]
	if not btn.disabled:
		btn.pressed.connect(func() -> void:
			if _firmware_installer == null:
				return
			if _firmware_installer.is_queued(key):
				_firmware_installer.cancel(key)
				return
			_bios_job_buttons[key] = btn
			if _enqueue_bios_dir_file(e, path):
				btn.text = "0%"
				btn.add_theme_color_override("font_color", MenuIcons.TINT_BUSY)
		)

	# Only a file that is actually here can be deleted, and the arming key is the
	# file's own path inside the folder — arming on the folder row's key would
	# arm every file in it at once.
	var del := row.get_node("Delete") as Button
	_clear_pressed(del)
	del.visible = here
	if here:
		_wire_firmware_delete(del, core_name, path.path_join(file_name),
			dir.path_join(file_name))


## Drop every `pressed` handler a pooled Control picked up on its last binding.
static func _clear_pressed(btn: BaseButton) -> void:
	for c: Dictionary in btn.pressed.get_connections():
		btn.pressed.disconnect(c["callable"])


## Queue one file into every core's copy of this folder. False when it was
## already queued, so a caller can count what it actually started.
func _enqueue_bios_dir_file(e: Dictionary, path: String) -> bool:
	if _firmware_installer == null or romm_config == null:
		return false
	var file_name := str(e["file_name"])
	var key := _bios_dir_job_key(path, file_name)
	if _firmware_installer.is_queued(key):
		return false
	var dests := _bios_dir_destinations_for(path, file_name)
	if dests.is_empty():
		return false
	_firmware_installer.enqueue_file(
		key, file_name, romm_config.base_url,
		RommFirmware.content_path(int(e["id"]), file_name),
		romm_config.auth_headers(), dests,
		int(e["size"]), str(e["md5"]))
	return true


## Keyed on the folder and the file, never on a core: the fan-out below already
## writes it to every core that declares the folder, so a per-core key would
## queue the same download twice and have each one overwrite the other.
static func _bios_dir_job_key(path: String, file_name: String) -> String:
	return "bios:dir:%s:%s" % [path, file_name]


static func _bios_dir_key(core_name: String, path: String) -> String:
	return "%s|%s" % [core_name, path]


func _bios_dir_is_open(core_name: String, path: String) -> bool:
	return bool(_bios_dir_open.get(_bios_dir_key(core_name, path), false))


## The same fan-out a named file gets, one level down inside the folder.
func _bios_dir_destinations_for(path: String, file_name: String) -> Array[String]:
	var dests: Array[String] = []
	for d: String in _bios_destinations_for(path):
		dests.append(d.path_join(file_name))
	return dests


## Remove one installed firmware file. Two presses, like every other delete here.
##
## Scoped to ONE core's copy, not to every core that declares the same file. The
## fan-out on download is a convenience; the fan-out on delete would be a
## surprise — removing a shared BIOS from the row you were looking at would
## silently break three other cores.
func _build_firmware_delete_button(core_name: String, path: String, dest: String) -> Button:
	var btn := Button.new()
	btn.add_theme_font_override("font", MenuIcons.symbols())
	btn.add_theme_font_size_override("font_size", 20)
	btn.custom_minimum_size = Vector2(64, 44)
	btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_wire_firmware_delete(btn, core_name, path, dest)
	return btn


## Paint and connect an existing button. Separate from allocating one because a
## pooled picker row supplies its own and only needs re-wiring for the file it
## now shows.
func _wire_firmware_delete(btn: Button, core_name: String, path: String,
						   dest: String) -> void:
	var key := _bios_dir_key(core_name, path)
	_paint_delete_button(btn, _bios_delete_armed == key, core_name)

	btn.pressed.connect(func() -> void:
		if _bios_delete_armed != key:
			# Arming is UI state and nothing else, so it repaints one button.
			# It used to rebuild the whole tab — 63 ms on a desktop and several
			# hundred on a headset, which is the stutter felt on the FIRST press
			# of a button that had not deleted anything yet.
			_disarm_firmware_delete()
			_bios_delete_armed = key
			_bios_delete_armed_btn = btn
			_paint_delete_button(btn, true, core_name)
			_romm_notify_or_queue("bios:delete", String.chr(MenuIcons.ERROR),
				"Press again to delete %s" % path.get_file(), 3.0)
			# Matches the toast: an armed delete must not stay armed once the
			# prompt that explained it has gone.
			get_tree().create_timer(3.0).timeout.connect(func() -> void:
				if _bios_delete_armed == key:
					_disarm_firmware_delete(core_name))
			return

		_disarm_firmware_delete()
		if not FileAccess.file_exists(dest):
			refresh_bios_view()
			return
		if DirAccess.remove_absolute(dest) == OK:
			# The status cache is keyed on size+mtime, and a path that comes back
			# with the same two would otherwise read as the file we just removed.
			# Not saved here: evaluate() persists when it finds the cache dirty,
			# and the rebuild below runs it anyway.
			FirmwareState.shared().invalidate(core_name, path)
			_romm_notify_or_queue("bios:delete", String.chr(MenuIcons.CHECK),
				"Deleted %s" % path.get_file(), MenuToasts.DWELL_OK)
		else:
			_romm_notify_or_queue("bios:delete", String.chr(MenuIcons.ERROR),
				"Could not delete %s" % path.get_file(), MenuToasts.DWELL_FAIL)
		# The row's status really did change, so this one rebuild is earned.
		refresh_bios_view()
	)


## DELETE_FOREVER, not DELETE: most BIOS dumps are not on any server, so for the
## usual case this really is the last copy the app can reach.
static func _paint_delete_button(btn: Button, armed: bool, core_name: String) -> void:
	btn.text = String.chr(MenuIcons.ERROR if armed else MenuIcons.DELETE_FOREVER)
	btn.add_theme_color_override("font_color",
		MenuIcons.TINT_WARN if armed else MenuIcons.TINT_DELETE)
	btn.tooltip_text = "Press again to delete this file" if armed \
		else "Delete this file from %s's system folder" % core_name


## Clear the armed delete and repaint whatever button was showing it. The button
## may have been freed by a rebuild in between, which is why it is checked.
func _disarm_firmware_delete(core_name: String = "") -> void:
	_bios_delete_armed = ""
	if _bios_delete_armed_btn != null and is_instance_valid(_bios_delete_armed_btn):
		_paint_delete_button(_bios_delete_armed_btn, false, core_name)
	_bios_delete_armed_btn = null


## Every installed core that declares this exact firmware path wants its own
## copy, so one fetch fills them all.
##
## Memoised for the life of a rebuild, because the fetch-all calls it once PER
## FILE. It walks every installed core and rebuilds that core's whole
## requirement list through FirmwareRequirements.for_core, which re-parses the
## `notes` checksum table each time — cheap once, and 68 files against ~40 cores
## on a headset froze the app solid the moment Get all was pressed. The scan does
## not depend on the file, only on the folder, so it never needed repeating.
func _bios_destinations_for(path: String) -> Array[String]:
	if _bios_dest_cache.has(path):
		return _bios_dest_cache[path]

	var dests: Array[String] = []
	for sid: String in _bios_cores_by_system:
		for c: Dictionary in _bios_cores_by_system[sid]:
			var cn := str(c["core_name"])
			for req: Dictionary in FirmwareRequirements.for_core(cn):
				if str(req["path"]) == path:
					dests.append(FirmwareRequirements.destination(cn, path))
					break
	_bios_dest_cache[path] = dests
	return dests


func _romm_ready() -> bool:
	return romm_firmware != null and romm_firmware.is_loaded()


## The .info `desc` almost always restates the filename before adding anything
## useful ("scph5500.bin (PS1 JP BIOS)"), which reads as a stutter under a label
## that is already the path. Drop the repeated part and keep the rest.
static func _bios_desc_for(path: String, desc: String) -> String:
	if desc.is_empty():
		return ""
	var rest := desc
	for prefix: String in [path, path.get_file()]:
		if not prefix.is_empty() and rest.begins_with(prefix):
			rest = rest.substr(prefix.length())
			break
	rest = rest.strip_edges().lstrip("-–—:").strip_edges()
	if rest.begins_with("(") and rest.ends_with(")"):
		rest = rest.substr(1, rest.length() - 2).strip_edges()
	# Nothing left means the desc was only ever the filename.
	return "" if rest == path or rest == path.get_file() else rest


# ── Download tab ──────────────────────────────────────────────────────────────

func _build_download_tab() -> Control:
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 6)

	# Cores directory path display
	var path_row := HBoxContainer.new()
	outer.add_child(path_row)
	path_row.add_child(MenuStyle.label("Cores dir:  ", 14, MenuStyle.COLOR_LICENSE))
	var path_val := Label.new()
	path_val.text = CoreDownloadManager.default_cores_dir()
	path_val.add_theme_font_size_override("font_size", 14)
	path_val.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
	path_val.clip_contents = true
	path_val.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_row.add_child(path_val)

	outer.add_child(HSeparator.new())

	# Job reporting is the same shape as the firmware installer's, so both
	# report through toasts keyed on the job rather than through row widgets.
	download_manager.job_started.connect(_on_core_job_started)
	download_manager.job_progress.connect(_on_core_job_progress)
	download_manager.job_retrying.connect(_on_core_job_retrying)
	download_manager.job_finished.connect(_on_core_job_finished)
	download_manager.job_cancelled.connect(_on_core_job_cancelled)

	# Drill-down browser: pick a system, then see its cores.
	_download_browser = SystemGridBrowser.new()
	_download_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_download_browser.empty_text = "No cores available."
	_download_browser.set_detail_populator(_populate_download_detail)
	_download_browser.active_scroll_changed.connect(_on_cores_browser_scroll_changed)
	outer.add_child(_download_browser)

	# One press to get a working set: the recommendation table names exactly one
	# core per system, so this can never install two cores for one machine.
	#
	# In the browser's home toolbar, under the filter and above the grid, so it
	# goes away on drill-down — inside a system it would be a button offering to
	# install 47 cores for other machines.
	_recommend_all_btn = Button.new()
	_recommend_all_btn.custom_minimum_size = Vector2(0, 56)
	_recommend_all_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_recommend_all_btn.add_theme_font_size_override("font_size", 18)
	_recommend_all_btn.add_theme_color_override("font_color", MenuStyle.COLOR_RECOMMENDED)
	_recommend_all_btn.focus_mode = Control.FOCUS_NONE
	_recommend_all_btn.pressed.connect(_on_download_all_recommended)
	_download_browser.home_toolbar().add_child(_recommend_all_btn)
	_refresh_recommend_all_button()

	return outer


const FETCH_KEY := "cores:fetch"


func _start_fetch() -> void:
	_romm_notify_or_queue(FETCH_KEY, String.chr(MenuIcons.BUSY),
		"Fetching the core list…", 0.0)
	_download_widgets.clear()
	download_manager.fetch_available_cores(_on_cores_fetched)


func _on_cores_fetched(cores: Array) -> void:
	if cores.is_empty():
		_romm_notify_or_queue(FETCH_KEY, String.chr(MenuIcons.ERROR),
			"Could not reach the buildbot", MenuToasts.DWELL_FAIL)
	else:
		notify_clear(FETCH_KEY)
	if cores.is_empty():
		return
	# Group the flat buildbot list by system; cores unknown to the DB go in a
	# single "Other" bucket. SystemFilter keeps non-console systems out of the
	# grid — see _refresh_download_systems.
	_download_cores_by_system.clear()
	for entry: Dictionary in cores:
		var core_name: String   = entry["core_name"]
		var remote_date: String = entry["remote_date"]
		var info: Dictionary    = core_db.get_by_core_name(core_name)
		# Listed under every platform it serves, so browsing to Game Gear offers
		# the Mega Drive cores that emulate it rather than an empty tile.
		var sids := CoreInfoDatabase.systemids_of(info)
		if sids.is_empty():
			sids = ["__other__"] as Array[String]
		for sid: String in sids:
			if not _download_cores_by_system.has(sid):
				_download_cores_by_system[sid] = []
			(_download_cores_by_system[sid] as Array).append(
				{"core_name": core_name, "remote_date": remote_date, "info": info})
	refresh_download_systems()
	_refresh_recommend_all_button()


## Build the Download home grid from the grouped fetch results.
## Public: OPTIONS owns the system-filter switch, and the list is built from it.
func refresh_download_systems() -> void:
	if not _download_browser:
		return
	var installed := _installed_core_names()
	var systems: Array = []
	for sid: String in _download_cores_by_system:
		if SystemFilter.is_hidden(sid):
			continue
		var arr: Array = _download_cores_by_system[sid] as Array
		var sysname := "Other / Uncategorized" if sid == "__other__" else core_db.get_systemname_for_id(sid)
		var n := arr.size()
		# Counted over the tile's own list, which holds every core that serves this
		# platform rather than only the ones filed under it — the same reading the
		# detail page gives, so a purple tile always opens on nothing installed.
		var have := false
		for e: Dictionary in arr:
			if installed.has(str(e["core_name"])):
				have = true
				break
		systems.append({"systemid": sid, "name": sysname,
			"badge": "%d core%s" % [n, "" if n == 1 else "s"],
			"alt_tile": not have})
	_download_browser.set_systems(systems)


const RECOMMEND_ALL_KEY := "cores:recommended"


## The recommended cores this platform is missing, as {core_name, remote_date}.
##
## Intersected with the buildbot listing rather than taken from the table alone:
## the table names a core per system for every platform, and one that is not
## published for this one would otherwise be queued only to work its way through
## every filename candidate and fail.
##
## Installed counts from the DISK, not the manifest, the same reading the tiles
## and the Manager tab take — a core dropped in by hand is installed. An UPDATE
## is still offered, because that is the same core rather than a second one.
func _pending_recommended() -> Array[Dictionary]:
	var wanted: Dictionary = {}
	for core_name: String in CoreRecommendations.core_names():
		wanted[core_name] = true

	var installed := _installed_core_names()
	var out: Array[Dictionary] = []
	for entry: Dictionary in download_manager.available_cores:
		var cn := str(entry.get("core_name", ""))
		if not wanted.has(cn):
			continue
		var remote := str(entry.get("remote_date", ""))
		var state := download_manager.get_core_state(cn, remote)
		if state == "BUSY":
			continue
		if installed.has(cn) and state != "UPDATE":
			continue
		out.append({"core_name": cn, "remote_date": remote})
	return out


## Queue every recommended core this platform is missing, in one press.
##
## No double-press guard of its own: enqueueing turns each core BUSY, which drops
## it out of _pending_recommended, so the refresh below disables the button — and
## a disabled Button never emits the second press a Viewport2DIn3D click sends.
func _on_download_all_recommended() -> void:
	var pending := _pending_recommended()
	if pending.is_empty():
		return
	for entry: Dictionary in pending:
		_on_download_pressed(str(entry["core_name"]), str(entry["remote_date"]))
	_romm_notify_or_queue(RECOMMEND_ALL_KEY, String.chr(MenuIcons.DOWNLOAD),
		"Queued %d recommended core%s" % [pending.size(), "" if pending.size() == 1 else "s"],
		MenuToasts.DWELL_OK)
	_refresh_recommend_all_button()


## An empty listing is "not fetched yet", not "nothing left to do" — the two read
## identically from the count alone, and calling the first one done would tell a
## player with no network that they have every core.
func _refresh_recommend_all_button() -> void:
	if not is_instance_valid(_recommend_all_btn):
		return
	if download_manager.available_cores.is_empty():
		_recommend_all_btn.text = "Download All Recommended"
		_recommend_all_btn.tooltip_text = "Waiting for the core list"
		_recommend_all_btn.disabled = true
		return
	var n := _pending_recommended().size()
	if n == 0:
		_recommend_all_btn.text = "Every Recommended Core Is Installed"
		_recommend_all_btn.tooltip_text = ""
		_recommend_all_btn.disabled = true
		return
	_recommend_all_btn.text = "Download All Recommended  (%d)" % n
	_recommend_all_btn.tooltip_text = \
		"One core per system, the best default for this platform. Cores you already have are skipped."
	_recommend_all_btn.disabled = false


## Core names sitting in the cores dir, as a set.
##
## The disk rather than the download manifest: the Manager and BIOS tabs both
## read it that way, so a core dropped in by hand counts here as it does there.
static func _installed_core_names() -> Dictionary:
	var names: Dictionary = {}
	var dir := DirAccess.open(CoreDownloadManager.default_cores_dir())
	if dir == null:
		return names
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		# A core can sit there under two naming conventions, and both resolve to
		# the one name the buildbot list uses.
		var cn := "" if dir.current_is_dir() else CoreDownloadManager.core_name_from_lib_filename(fname)
		if not cn.is_empty():
			names[cn] = true
		fname = dir.get_next()
	dir.list_dir_end()
	return names


## Detail page for one system: its downloadable cores (built lazily on open).
func _populate_download_detail(systemid: String, vbox: VBoxContainer) -> void:
	var arr: Array = _download_cores_by_system.get(systemid, [])
	arr.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var an: String = a["info"].get("display_name", a["core_name"]) if not (a["info"] as Dictionary).is_empty() else a["core_name"]
		var bn: String = b["info"].get("display_name", b["core_name"]) if not (b["info"] as Dictionary).is_empty() else b["core_name"]
		return an.naturalnocasecmp_to(bn) < 0
	)
	arr = CoreRecommendations.first(systemid, arr)
	for e: Dictionary in arr:
		vbox.add_child(_build_core_entry(systemid, e["core_name"], e["remote_date"], e["info"]))
	vbox.add_child(MenuStyle.spacer(20))


## `systemid` is the page's, never the core's own. A multi-system core is listed
## under every platform it serves, and the recommendation is per platform: asking
## the core which system it belongs to puts PicoDrive's Mega Drive answer on the
## 32X page, where PicoDrive is the pick and would have shown no badge at all.
func _build_core_entry(systemid: String, core_name: String, remote_date: String,
					   info: Dictionary) -> Control:
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 76)
	col.add_child(row)

	# Left: display name, license, description
	var left := VBoxContainer.new()
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 2)
	row.add_child(left)

	var display_name: String = info.get("display_name", core_name + "  [CORE UNKNOWN]")
	var name_lbl := Label.new()
	name_lbl.text = display_name
	name_lbl.add_theme_font_size_override("font_size", 18)
	name_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	name_lbl.clip_contents = true
	left.add_child(name_lbl)

	# Recommended first when a core is both: the pick for this system is the more
	# useful fact, and the caveat reads as a qualifier under it rather than as a
	# competing verdict.
	if CoreRecommendations.is_recommended(systemid, core_name):
		left.add_child(MenuIcons.recommended_badge(13))
	if MenuIcons.is_experimental(info):
		left.add_child(MenuIcons.experimental_badge(13))
	var netplay_lbl := MenuIcons.netplay_badge(13, core_name)
	if netplay_lbl != null:
		left.add_child(netplay_lbl)

	if not info.is_empty():
		left.add_child(MenuStyle.label(info.get("license", ""), 13, MenuStyle.COLOR_LICENSE))

		var desc: String = info.get("description", "")
		if desc != "":
			var desc_lbl := Label.new()
			desc_lbl.text = desc
			desc_lbl.add_theme_font_size_override("font_size", 12)
			desc_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
			desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			left.add_child(desc_lbl)

	# Right: one icon button. Progress lives in the toast, not here — a bar on
	# the row dies with the row, and detail pages are built lazily and freed.
	var dl_btn := Button.new()
	dl_btn.custom_minimum_size = Vector2(84, 52)
	dl_btn.focus_mode = Control.FOCUS_NONE
	dl_btn.pressed.connect(_on_download_pressed.bind(core_name, remote_date))
	row.add_child(dl_btn)

	_download_widgets[core_name] = {"button": dl_btn}
	_style_dl_button(dl_btn, download_manager.get_core_state(core_name, remote_date))

	col.add_child(HSeparator.new())
	return col


## The glyph says what pressing it does; "Re-Download" and "UPDATE" differ only
## in whether the buildbot has something newer, so they get different icons
## rather than different words.
func _style_dl_button(btn: Button, state: String) -> void:
	var glyph := MenuIcons.DOWNLOAD
	var tint := MenuIcons.TINT_DOWNLOAD
	var tip := "Download this core"
	match state:
		"UPDATE":
			glyph = MenuIcons.UPDATE
			tint = MenuIcons.TINT_WARN
			tip = "A newer build is available"
		"Re-Download":
			glyph = MenuIcons.CHECK
			tint = MenuIcons.TINT_OK
			tip = "Installed and up to date — download again"
		"BUSY":
			glyph = MenuIcons.BUSY
			tint = MenuIcons.TINT_BUSY
			tip = "Downloading…"

	btn.text = String.chr(glyph)
	btn.add_theme_font_override("font", MenuIcons.symbols())
	btn.add_theme_font_size_override("font_size", 26)
	btn.add_theme_color_override("font_color", tint)
	btn.add_theme_color_override("font_disabled_color", tint)
	btn.tooltip_text = tip
	btn.disabled = (state == "BUSY")


## is_queued() is the double-press guard: every Viewport2Din3D click arrives
## twice, and enqueue_core ignores a core already in flight.
func _on_download_pressed(core_name: String, remote_date: String) -> void:
	if download_manager.is_queued(core_name):
		return
	var display := core_name
	var entry := core_db.get_by_core_name(core_name)
	if not entry.is_empty():
		display = str(entry.get("display_name", core_name))
	download_manager.enqueue_core(core_name, remote_date, display)
	_refresh_download_button(core_name)


func _refresh_download_button(core_name: String) -> void:
	var widgets: Dictionary = _download_widgets.get(core_name, {})
	if widgets.is_empty():
		return
	var btn: Button = widgets["button"]
	if not is_instance_valid(btn):
		return
	var remote := ""
	for e: Dictionary in download_manager.available_cores:
		if e.get("core_name", "") == core_name:
			remote = str(e.get("remote_date", ""))
			break
	_style_dl_button(btn, download_manager.get_core_state(core_name, remote))


## core:<core_name> -> core_name, or "" for a key from another producer.
func _core_from_key(key: String) -> String:
	if not key.begins_with(CoreDownloadManager.JOB_PREFIX):
		return ""
	return key.substr(CoreDownloadManager.JOB_PREFIX.length())


func _on_core_job_started(key: String, label: String, total: int) -> void:
	_job_labels[key] = label
	_romm_notify_or_queue(key, String.chr(MenuIcons.BUSY), _job_text(key, total), 0.0, 0.0)
	_refresh_download_button(_core_from_key(key))
	_refresh_recommend_all_button()


func _on_core_job_progress(key: String, received: int, total: int) -> void:
	var frac := 0.0 if total <= 0 else clampf(float(received) / float(total), 0.0, 1.0)
	_romm_notify_or_queue(key, String.chr(MenuIcons.BUSY),
		_job_text(key, total), 0.0, frac)


func _on_core_job_retrying(key: String, attempt: int, total: int, reason: String) -> void:
	_romm_notify_or_queue(key, String.chr(MenuIcons.RETRY),
		"%s — retry %d of %d: %s" % [_job_label(key), attempt, total, reason], 0.0)


func _on_core_job_cancelled(key: String) -> void:
	_job_labels.erase(key)
	notify_clear(key)
	_refresh_download_button(_core_from_key(key))
	_refresh_recommend_all_button()


func _on_core_job_finished(key: String, ok: bool, error: String) -> void:
	var core_name := _core_from_key(key)
	var label := _job_label(key)
	_job_labels.erase(key)
	if not ok:
		_romm_notify_or_queue(key, String.chr(MenuIcons.ERROR),
			"%s — %s" % [label, error if not error.is_empty() else "download failed"],
			MenuToasts.DWELL_FAIL)
		_refresh_download_button(core_name)
		_refresh_recommend_all_button()
		return

	_romm_notify_or_queue(key, String.chr(MenuIcons.CHECK),
		"%s installed" % label, MenuToasts.DWELL_OK)
	_refresh_download_button(core_name)
	_refresh_recommend_all_button()
	call_deferred("_populate_manager_tab")
	# Rebuilds the home grid only, so the detail page this was pressed on is left
	# alone — the tile behind it drops its purple.
	call_deferred("refresh_download_systems")

	var dl_sids := CoreInfoDatabase.systemids_of(core_db.get_by_core_name(core_name))
	if dl_sids.is_empty():
		return
	# The Cartridges and Systems tabs live on SpawnView, not here, and
	# default_core_changed is the signal it already listens to for exactly this.
	# The default itself is adopted by the deferred _populate_manager_tab above
	# when this is the system's first core, so read it back rather than assuming
	# it is this one. Once per platform the core serves: a multi-system core
	# fills several roms dirs and lights up several tiles.
	for dl_sid: String in dl_sids:
		RomLibrary.ensure_rom_dir(dl_sid)
		default_core_changed.emit(dl_sid, core_defaults.get_default_core(dl_sid))


## True while BIOS / Extras is the sub-tab on screen.
func showing_bios_tab() -> bool:
	return _cores_tabs != null and _cores_tabs.current_tab == 2
