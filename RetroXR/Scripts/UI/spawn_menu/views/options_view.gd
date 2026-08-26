## SpawnMenuOptionsView — the menu's OPTIONS tab: comfort settings, the on/off
## switches, and the RomM / ScreenScraper server setup.
##
## Unlike the other tabs this one is a control surface over services the menu
## owns, so it is handed them by setup() rather than reaching for them. What it
## cannot do itself it asks for by signal; the comfort rows all report upward,
## because applying them means touching the XR rig.
class_name SpawnMenuOptionsView
extends VBoxContainer

## The active sub-tab's scroll changed — the menu drives thumbstick scrolling
## from this, the same way the CORES view reports its own sub-tabs.
signal scroll_changed(scroll: ScrollContainer)

signal turn_style_changed(value: String)
signal snap_angle_changed(degrees: float)
signal height_offset_changed(offset: float)
signal fov_changed(degrees: float)
signal world_scale_changed(scale: float)
signal auto_save_changed(enabled: bool)
## A performance HUD switch moved. Carries nothing: the controller re-reads
## AppPrefs, so five switches and a mount are one signal rather than six.
signal hud_changed
signal aim_crosshair_changed(enabled: bool)
## True to aim a teleport with the left stick, false to slide with it.
signal locomotion_mode_changed(teleport: bool)
## Whether the sticks keep working while passthrough is on. Only the passthrough
## room can act on it, so the controller hands it to whatever room is standing.
signal passthrough_locomotion_changed(enabled: bool)
signal xr_display_mode_changed(mode: int)
signal controller_hands_changed(enabled: bool)
## The system filter was toggled — the CORES download list is built from it.
signal system_filter_changed
## Ask the menu to re-read the RomM platform list. It owns the result, because
## the cartridge browser reads it too.
signal romm_platforms_requested

# Services, injected by setup(). Named exactly as the menu names them so the
# rows below read the same as they did when they lived there.
var romm_config: RommConfig = null
var romm_client: RommClient = null
var romm_catalog: RommCatalog = null
var romm_cache: RommCacheManifest = null
var romm_art: RommArtCache = null
var scraper_config: ScraperConfig = null
var web_server: WebFileServer = null

## The menu, for the two things this view reads rather than owns: the RomM
## platform map (shared with the cartridge browser) and the toast stack. Typed
## as Node, not SpawnMenu2D — the two classes would otherwise name each other,
## which GDScript resolves badly.
var _menu: Node = null

var _server_address_label: Label = null
var _romm_status_label: Label = null
var _storage_usage_label: Label = null
## The Storage page's last scan and which categories are ticked. Held rather than
## rescanned on confirm, so what gets deleted is what was shown.
var _cleanup_panel: VBoxContainer = null
var _cleanup_found: Dictionary = {}
var _cleanup_selected: Dictionary = {}
## Both the scan and the removal run off the main thread — see the note above
## _on_cleanup_scan_pressed. One at a time, and joined before the view goes.
var _cleanup_thread: Thread = null
var _cleanup_busy := false
var _cleanup_scan_btn: Button = null
## "Sync all now" doubles as "Stop syncing" while anything is running.
var _romm_sync_btn: Button = null
## Entries are {sid: String, full: bool}. One queue for the whole app: a second
## caller reaching straight for sync_platform while a sync runs would have its
## request dropped, not deferred.
var _romm_sync_queue: Array[Dictionary] = []

var _tabs: TabContainer = null
var _pages: Array[ScrollContainer] = []

# Kept so a pairing (typed or scanned) can show its result in the fields the
# player is looking at, rather than waiting for the view to be rebuilt.
var _romm_url_edit: LineEdit = null
var _romm_token_edit: LineEdit = null
var _qr_overlay: QrScanOverlay = null
var _last_scan_frame: int = -1

const SCAN_BTN_WIDTH := 64

## Width of the build plate's field-name column, so the values sit in a column.
const PLATE_FIELD_W := 120

# Only one sign-in method applies at a time, so the other one's rows are hidden
# rather than left there to be filled in and quietly ignored.
var _romm_mode_drop: VRDropdown = null
var _romm_token_rows: Array[Control] = []
var _romm_basic_rows: Array[Control] = []

# RetroAchievements. Same hide-the-unused-method idiom as RomM above.
var _ra_mode_drop: VRDropdown = null
var _ra_password_rows: Array[Control] = []
var _ra_token_rows: Array[Control] = []
var _ra_user_edit: LineEdit = null
var _ra_password_edit: LineEdit = null
var _ra_token_edit: LineEdit = null
var _ra_status_label: Label = null
var _ra_signin_btn: Button = null
var _ra_last_signin_frame: int = -1

# The DEBUG page's audio queue depth. Held so the field can be rewritten with
# what the mixer actually took, which is how its clamp becomes visible.
var _audio_buffer_edit: LineEdit = null
var _audio_buffer_hint: Label = null


static func create(menu: Node) -> SpawnMenuOptionsView:
	var v := SpawnMenuOptionsView.new()
	v._menu = menu
	v.romm_config    = menu.romm_config
	v.romm_client    = menu.romm_client
	v.romm_catalog   = menu.romm_catalog
	v.romm_cache     = menu.romm_cache
	v.romm_art       = menu.romm_art
	v.scraper_config = menu.scraper_config
	v.web_server     = menu.web_server
	v._build()
	return v


## SceneManager is an autoload, but every caller in the project guards the
## lookup rather than naming the global, so this does too.
static func _scene_manager() -> Node:
	return Engine.get_main_loop().root.get_node_or_null("SceneManager")


func _platforms() -> Dictionary:
	return _menu.romm_platforms() if _menu else {}


func _unmapped() -> Array:
	return _menu.romm_unmapped() if _menu else []


func notify(key: String, icon: String, msg: String,
			progress: float = -1.0, seconds: float = 0.0) -> void:
	if _menu:
		_menu.notify(key, icon, msg, progress, seconds)


func _build() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL

	_build_general_options(_page("General"))
	_build_system_filter_options(_page("Systems"))
	_build_storage_options(_page("Storage"))
	if OS.get_name() == "Android":
		_build_file_server_options(_page("File Server"))
	_build_romm_options(_page("RomM", MenuIcons.romm_mark()))
	_build_scraper_options(_page("Scraper"))
	_build_retroachievements_options(_page("RetroAchievements"))
	_build_debug_options(_page("Debug"))

	_tabs.tab_changed.connect(func(_i: int) -> void: scroll_changed.emit(active_scroll()))
	add_child(TabStrip.wrap(_tabs))


## A scrolling sub-tab. The TabContainer titles each tab after its child, so the
## node name IS the tab label; the icon has to be set separately.
func _page(title: String, icon: Texture2D = null) -> VBoxContainer:
	var page := MenuStyle.vscroll()
	page.name = title
	var vbox := MenuStyle.vbox(14)
	page.add_child(vbox)
	_tabs.add_child(page)
	_pages.append(page)
	if icon != null:
		_tabs.set_tab_icon(_tabs.get_tab_count() - 1, icon)
	return vbox


## The scroll the thumbstick should drive, i.e. whichever sub-tab is showing.
func active_scroll() -> ScrollContainer:
	if _tabs == null or _pages.is_empty():
		return null
	return _pages[clampi(_tabs.current_tab, 0, _pages.size() - 1)]


## Seconds below a minute read as seconds; past that, minutes with the odd half.
func _interval_text(seconds: float) -> String:
	if seconds < 60.0:
		return "%d s" % int(seconds)
	var mins := seconds / 60.0
	return "%d min" % int(mins) if is_equal_approx(mins, floorf(mins)) else "%.1f min" % mins


func _build_general_options(vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.spacer(10))

	if MenuStyle.is_vr_mode():
		# Turn Style option (XR only)
		var turn_opt := VRDropdown.create("Turn Style",
			[["SNAP", "SNAP"], ["SMOOTH", "SMOOTH"]], "SNAP",
			1, Vector2(220, 56), 22)
		turn_opt.item_selected.connect(func(id: Variant) -> void:
			turn_style_changed.emit(str(id))
		)
		vbox.add_child(turn_opt)

		# Snap Turn Angle option (XR only)
		var sa_opt := VRDropdown.create("Snap Angle",
			[["30°", 30.0], ["45°", 45.0], ["60°", 60.0]], 45.0,
			1, Vector2(140, 56), 22)
		sa_opt.item_selected.connect(func(id: Variant) -> void:
			snap_angle_changed.emit(float(id))
		)
		vbox.add_child(sa_opt)

		vbox.add_child(HSeparator.new())
	else:
		# FOV slider (desktop only)
		var fov_header := HBoxContainer.new()
		fov_header.add_theme_constant_override("separation", 10)
		vbox.add_child(fov_header)

		var fov_lbl := Label.new()
		fov_lbl.text = "Field of View"
		fov_lbl.add_theme_font_size_override("font_size", 22)
		fov_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
		fov_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fov_header.add_child(fov_lbl)

		var fov_val := Label.new()
		fov_val.text = "75°"
		fov_val.add_theme_font_size_override("font_size", 20)
		fov_val.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
		fov_val.custom_minimum_size = Vector2(60, 0)
		fov_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		fov_header.add_child(fov_val)

		var fov_slider := HSlider.new()
		fov_slider.min_value = 60.0
		fov_slider.max_value = 110.0
		fov_slider.step = 1.0
		fov_slider.value = 75.0
		fov_slider.custom_minimum_size = Vector2(0, 48)
		fov_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(fov_slider)

		fov_slider.value_changed.connect(func(v: float) -> void:
			fov_val.text = "%d°" % int(v)
			fov_changed.emit(v)
		)

		vbox.add_child(HSeparator.new())

	# Height Offset slider
	var ho_header := HBoxContainer.new()
	ho_header.add_theme_constant_override("separation", 10)
	vbox.add_child(ho_header)

	var ho_lbl := Label.new()
	ho_lbl.text = "Height Offset"
	ho_lbl.add_theme_font_size_override("font_size", 22)
	ho_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	ho_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ho_header.add_child(ho_lbl)

	var ho_val := Label.new()
	ho_val.text = "0.00 m"
	ho_val.add_theme_font_size_override("font_size", 20)
	ho_val.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	ho_val.custom_minimum_size = Vector2(80, 0)
	ho_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ho_header.add_child(ho_val)

	var ho_slider := HSlider.new()
	ho_slider.min_value = -1.0
	ho_slider.max_value = 1.0
	ho_slider.step = 0.01
	ho_slider.value = 0.0
	ho_slider.custom_minimum_size = Vector2(0, 48)
	ho_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ho_slider.add_theme_constant_override("grabber_offset", 0)
	vbox.add_child(ho_slider)

	ho_slider.value_changed.connect(func(v: float) -> void:
		ho_val.text = "%+.2f m" % v
		height_offset_changed.emit(v)
	)

	vbox.add_child(HSeparator.new())

	# World Scale slider — below 1.0 makes you feel smaller and the room bigger.
	# XR only, like Turn Style above: on desktop it only moves the eye height,
	# which is what the Height Offset slider already does more directly.
	if MenuStyle.is_vr_mode():
		var ws_header := HBoxContainer.new()
		ws_header.add_theme_constant_override("separation", 10)
		vbox.add_child(ws_header)

		var ws_lbl := Label.new()
		ws_lbl.text = "World Scale"
		ws_lbl.add_theme_font_size_override("font_size", 22)
		ws_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
		ws_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ws_header.add_child(ws_lbl)

		var ws_val := Label.new()
		ws_val.add_theme_font_size_override("font_size", 20)
		ws_val.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
		ws_val.custom_minimum_size = Vector2(80, 0)
		ws_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		ws_header.add_child(ws_val)

		var ws_slider := HSlider.new()
		ws_slider.min_value = 0.4
		ws_slider.max_value = 1.5
		ws_slider.step = 0.05
		# Default matches DEFAULT_WORLD_SCALE in spawn_menu_controller.gd (applied
		# at startup). Hardcoded rather than read from XRServer.world_scale because
		# this view is built before the controller's deferred setup applies it.
		ws_slider.value = 0.85
		ws_val.text = "%.2f×" % ws_slider.value
		ws_slider.custom_minimum_size = Vector2(0, 48)
		ws_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_child(ws_slider)

		ws_slider.value_changed.connect(func(v: float) -> void:
			ws_val.text = "%.2f×" % v
			world_scale_changed.emit(v)
		)

		# Passthrough pins the scale to 1.0 so the virtual room stays registered
		# with the real one. Shown as such rather than left live and inert.
		var sm_ws := _scene_manager()
		if sm_ws and sm_ws.current_scene_id == "passthrough":
			ws_slider.value = 1.0
			ws_slider.editable = false
			ws_val.text = "1.00× (passthrough)"

		# Inside the guard too, or hiding the slider leaves two rules stacked.
		vbox.add_child(HSeparator.new())

	# Auto-save scene on switch option
	var as_row := HBoxContainer.new()
	as_row.add_theme_constant_override("separation", 10)
	as_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(as_row)

	var as_lbl := Label.new()
	# Named for when it fires now that there is a second auto-save below it: on its
	# own, "Auto-save Scene" reads as though it covers both.
	as_lbl.text = "Auto-save on Room Change"
	as_lbl.add_theme_font_size_override("font_size", 22)
	as_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	as_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	as_row.add_child(as_lbl)

	as_row.add_child(VRToggle.create(AppPrefs.auto_save_scene, func(on: bool) -> void:
		AppPrefs.auto_save_scene = on
		AppPrefs.save_prefs()
		auto_save_changed.emit(on)
	))

	vbox.add_child(HSeparator.new())

	# Periodic auto-save, and how often. Only the two furnishable rooms keep slots,
	# so this does nothing in the den or the bedroom — the same as the switch above,
	# and not worth a second explanation in the row.
	var ap_row := HBoxContainer.new()
	ap_row.add_theme_constant_override("separation", 10)
	ap_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(ap_row)

	var ap_lbl := Label.new()
	ap_lbl.text = "Auto-save Periodically"
	ap_lbl.add_theme_font_size_override("font_size", 22)
	ap_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	ap_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ap_row.add_child(ap_lbl)

	var ai_header := HBoxContainer.new()
	ai_header.add_theme_constant_override("separation", 10)
	vbox.add_child(ai_header)

	var ai_lbl := Label.new()
	ai_lbl.text = "Auto-save Interval"
	ai_lbl.add_theme_font_size_override("font_size", 22)
	ai_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	ai_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ai_header.add_child(ai_lbl)

	var ai_val := Label.new()
	ai_val.add_theme_font_size_override("font_size", 20)
	ai_val.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	ai_val.custom_minimum_size = Vector2(80, 0)
	ai_val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	ai_header.add_child(ai_val)

	var ai_slider := HSlider.new()
	ai_slider.min_value = AppPrefs.AUTOSAVE_INTERVAL_MIN
	ai_slider.max_value = AppPrefs.AUTOSAVE_INTERVAL_MAX
	ai_slider.step = 15.0
	ai_slider.value = AppPrefs.autosave_interval
	ai_val.text = _interval_text(ai_slider.value)
	ai_slider.custom_minimum_size = Vector2(0, 48)
	ai_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ai_slider.add_theme_constant_override("grabber_offset", 0)
	vbox.add_child(ai_slider)

	ai_slider.value_changed.connect(func(v: float) -> void:
		ai_val.text = _interval_text(v)
		AppPrefs.autosave_interval = v
		AppPrefs.save_prefs()
	)

	# The interval means nothing with the switch off, so it reads as switched off
	# too rather than sitting there live and ignored.
	var ap_apply := func(on: bool) -> void:
		ai_slider.editable = on
		var dim: Color = MenuStyle.COLOR_TITLE if on else MenuStyle.COLOR_LICENSE
		ai_lbl.add_theme_color_override("font_color", dim)
	ap_apply.call(AppPrefs.autosave_periodic)

	ap_row.add_child(VRToggle.create(AppPrefs.autosave_periodic, func(on: bool) -> void:
		AppPrefs.autosave_periodic = on
		AppPrefs.save_prefs()
		ap_apply.call(on)
	))

	vbox.add_child(HSeparator.new())

	# Spatial audio backend. Desktop only: in a headset the SDK's binaural
	# rendering is simply right, and offering the swap there would only be a way
	# to make it worse. On a desk it is a real choice -- over speakers the HRTF
	# fights the room, and a surround rig gets no centre channel from a renderer
	# that produces two channels by design.
	var meta_audio: Object = (Engine.get_singleton("MetaXRAudio")
		if Engine.has_singleton("MetaXRAudio") else null)
	if (QualityManager.is_desktop() and meta_audio != null
			and bool(meta_audio.call("is_available"))):
		var spatial_row := HBoxContainer.new()
		spatial_row.add_theme_constant_override("separation", 10)
		spatial_row.custom_minimum_size = Vector2(0, 68)
		vbox.add_child(spatial_row)

		var spatial_lbl := Label.new()
		spatial_lbl.text = "Meta XR Spatial Audio"
		spatial_lbl.add_theme_font_size_override("font_size", 22)
		spatial_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
		spatial_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spatial_row.add_child(spatial_lbl)

		# Applied straight away for everything in the room. A system that is
		# already switched on keeps the backend it booted with; see
		# SpatialAudioListener.set_sdk_enabled.
		spatial_row.add_child(VRToggle.create(AppPrefs.spatial_audio_sdk, func(on: bool) -> void:
			AppPrefs.spatial_audio_sdk = on
			AppPrefs.save_prefs()
			SpatialAudioListener.set_sdk_enabled(on)
		))

		vbox.add_child(HSeparator.new())

	# Movement style. Both verbs are on the left stick and only one can be live,
	# so this is a choice, not a switch — hence a dropdown rather than a toggle.
	# VRDropdown, never OptionButton: every Viewport2Din3D click fires twice.
	var move_drop := VRDropdown.create("Movement",
		[["Slide", "slide"], ["Teleport", "teleport"]],
		"teleport" if AppPrefs.locomotion_teleport else "slide",
		2, Vector2(220, 52), 18)
	move_drop.item_selected.connect(func(id: Variant) -> void:
		AppPrefs.locomotion_teleport = str(id) == "teleport"
		AppPrefs.save_prefs()
		locomotion_mode_changed.emit(AppPrefs.locomotion_teleport)
	)
	vbox.add_child(move_drop)

	vbox.add_child(HSeparator.new())

	# Whether that movement still works in passthrough. XR only, like Turn Style:
	# passthrough is not reachable outside a headset. Shown whatever this headset
	# supports — the answer is only knowable once the OpenXR session is up, well
	# after this page is built, and a switch that appears on the second visit reads
	# worse than one that is simply inert on hardware without passthrough.
	if MenuStyle.is_vr_mode():
		var ptm_row := HBoxContainer.new()
		ptm_row.add_theme_constant_override("separation", 10)
		ptm_row.custom_minimum_size = Vector2(0, 68)
		vbox.add_child(ptm_row)

		var ptm_lbl := Label.new()
		ptm_lbl.text = "Move in Passthrough"
		ptm_lbl.add_theme_font_size_override("font_size", 22)
		ptm_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
		ptm_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		ptm_row.add_child(ptm_lbl)

		ptm_row.add_child(VRToggle.create(AppPrefs.passthrough_locomotion,
			func(on: bool) -> void:
				AppPrefs.passthrough_locomotion = on
				AppPrefs.save_prefs()
				passthrough_locomotion_changed.emit(on)
		))

		vbox.add_child(HSeparator.new())

	# Light Gun crosshair option
	var xhair_row := HBoxContainer.new()
	xhair_row.add_theme_constant_override("separation", 10)
	xhair_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(xhair_row)

	var xhair_lbl := Label.new()
	xhair_lbl.text = "Light Gun Crosshair"
	xhair_lbl.add_theme_font_size_override("font_size", 22)
	xhair_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	xhair_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	xhair_row.add_child(xhair_lbl)

	xhair_row.add_child(VRToggle.create(AppPrefs.aim_crosshair, func(on: bool) -> void:
		AppPrefs.aim_crosshair = on
		AppPrefs.save_prefs()
		aim_crosshair_changed.emit(on)
	))

	vbox.add_child(HSeparator.new())

	# Hint popups over held devices (drop combo, Scroll Lock capture)
	var hints_row := HBoxContainer.new()
	hints_row.add_theme_constant_override("separation", 10)
	hints_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(hints_row)

	var hints_lbl := Label.new()
	hints_lbl.text = "Held Device Hints"
	hints_lbl.add_theme_font_size_override("font_size", 22)
	hints_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	hints_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hints_row.add_child(hints_lbl)

	# No signal: HeldHint reads AppPrefs when the object is picked up, so nothing
	# has to be told. Clearing the counts is what makes re-enabling visible —
	# without it anyone already past HeldHint.LEARNED_AFTER sees no change.
	hints_row.add_child(VRToggle.create(AppPrefs.show_hints, func(on: bool) -> void:
		AppPrefs.show_hints = on
		if on:
			AppPrefs.hint_uses.clear()
		AppPrefs.save_prefs()
	))

	vbox.add_child(HSeparator.new())

	# Physical XR device presentation. The mode updates the live rig; the runtime
	# hand mesh falls back to controller art if joints or geometry are absent.
	if MenuStyle.is_vr_mode():
		var display_drop := VRDropdown.create("XR Display", [
			["Controllers", AppPrefs.XRDisplayMode.CONTROLLERS],
			["Hands", AppPrefs.XRDisplayMode.HANDS],
			["Controllers + Hands", AppPrefs.XRDisplayMode.BOTH],
		], AppPrefs.xr_display_mode, 1, Vector2(300, 52), 18)
		display_drop.item_selected.connect(func(id: Variant) -> void:
			AppPrefs.xr_display_mode = int(id) as AppPrefs.XRDisplayMode
			AppPrefs.save_prefs()
			xr_display_mode_changed.emit(AppPrefs.xr_display_mode)
		)
		vbox.add_child(display_drop)
		vbox.add_child(HSeparator.new())

	# Authored wrap-around hands on virtual peripherals (default off). This is
	# intentionally independent of the native Capsense display mode above.
	var hands_row := HBoxContainer.new()
	hands_row.add_theme_constant_override("separation", 10)
	hands_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(hands_row)

	var hands_lbl := Label.new()
	hands_lbl.text = "Hands on Game Controllers"
	hands_lbl.add_theme_font_size_override("font_size", 22)
	hands_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	hands_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hands_row.add_child(hands_lbl)

	hands_row.add_child(VRToggle.create(AppPrefs.controller_hands, func(on: bool) -> void:
		AppPrefs.controller_hands = on
		AppPrefs.save_prefs()
		controller_hands_changed.emit(on)
	))


## The DEBUG sub-tab: which build this is, the overlays that draw over the room,
## and the graphics API a core is offered.
##
## What separates these from General is that none of them change how the app
## behaves for someone playing it — they are ways of looking at it, and two of
## them are worth nothing without the build identity at the top of the page to
## quote alongside what they showed.
func _build_debug_options(vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.spacer(10))
	_build_plate(vbox)
	vbox.add_child(MenuStyle.spacer(4))

	vbox.add_child(MenuStyle.header("PERFORMANCE HUD", 20))

	# A switch per section rather than one for the lot: they answer different
	# questions, and a section that is off is never sampled, so leaving the
	# expensive ones out has a real cost attached to it.
	MenuStyle.switch_row(vbox, "Frame rate and timing", PerfHud.show_frame) \
		.toggled.connect(func(on: bool) -> void:
			PerfHud.show_frame = on
			hud_changed.emit())
	MenuStyle.switch_row(vbox, "Memory", PerfHud.show_memory) \
		.toggled.connect(func(on: bool) -> void:
			PerfHud.show_memory = on
			hud_changed.emit())
	MenuStyle.switch_row(vbox, "Scene load", PerfHud.show_scene) \
		.toggled.connect(func(on: bool) -> void:
			PerfHud.show_scene = on
			hud_changed.emit())
	MenuStyle.switch_row(vbox, "Emulation", PerfHud.show_emulation) \
		.toggled.connect(func(on: bool) -> void:
			PerfHud.show_emulation = on
			hud_changed.emit())

	# XR only. On a monitor the HUD is a panel in the corner of the window, so
	# there is nowhere for it to be mounted and nothing to choose between.
	if MenuStyle.is_vr_mode():
		var mount := VRDropdown.create("Mount",
			[["In view", "head"], ["Left wrist", "wrist"]],
			"wrist" if PerfHud.wrist_mount else "head",
			1, Vector2(220, 56), 22)
		mount.item_selected.connect(func(id: Variant) -> void:
			PerfHud.wrist_mount = str(id) == "wrist"
			hud_changed.emit())
		vbox.add_child(mount)
		vbox.add_child(MenuStyle.hint(
			"On the wrist it reads when you turn your left hand over, like a watch."))
	vbox.add_child(MenuStyle.hint(
		"Not saved: the HUD is off again next launch, like the overlay below."))

	vbox.add_child(HSeparator.new())
	vbox.add_child(MenuStyle.header("OVERLAYS", 20))

	# Collision shapes. Deliberately NOT persisted: it is a look at the room, not
	# a setting, and one left on across a restart reads as a rendering bug.
	var col_row := HBoxContainer.new()
	col_row.add_theme_constant_override("separation", 10)
	col_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(col_row)

	var col_lbl := Label.new()
	col_lbl.text = "Collision Shapes"
	col_lbl.add_theme_font_size_override("font_size", 22)
	col_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	col_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col_row.add_child(col_lbl)

	col_row.add_child(VRToggle.create(CollisionDebug.is_enabled(), func(on: bool) -> void:
		CollisionDebug.set_enabled(self, on)
	))

	vbox.add_child(HSeparator.new())
	vbox.add_child(MenuStyle.header("NETPLAY", 20))

	# The allowlist refuses to start an unvetted core rather than risk a silent
	# desync, which also forecloses its own evidence: a core cannot be shown
	# deterministic if nothing may run it. This is how one gets measured.
	MenuStyle.switch_row(vbox, "Allow unvetted cores",
		NetplayCores.debug_allow_unverified) \
		.toggled.connect(func(on: bool) -> void:
			NetplayCores.debug_allow_unverified = on)
	vbox.add_child(MenuStyle.hint(
		"Not saved. Every machine will offer netplay, including cores never "
		+ "checked for determinism — expect desyncs. A late join still refuses "
		+ "an unvetted core, because a state that will not restore proves nothing."))

	_build_audio_buffer_row(vbox)


## The queue depth every producer pushes towards — the dominant term in the whole
## audio latency budget, and a straight trade against underruns: the queue has to
## survive the longest main-thread stall this device suffers, so the value that
## holds on a desktop crackles on a headset dropping frames.
##
## Set in FRAMES, which is what the mixer stores and what its limits are cut to.
## Milliseconds are the derived figure: the same 2048-frame queue is 43 ms on a
## desktop and 46 on a Quest, which mixes at 44.1 kHz whatever project.godot asks
## for, so a duration typed here would mean a different queue on each.
##
## Not persisted, like everything else on this page. It is a measurement you take
## with the HUD's underrun row open, not a preference, and one that came back
## after a restart would read as an audio bug rather than a setting.
func _build_audio_buffer_row(vbox: VBoxContainer) -> void:
	var mx: Object = _meta_audio()
	if mx == null:
		return

	vbox.add_child(HSeparator.new())
	vbox.add_child(MenuStyle.header("SPATIAL AUDIO", 20))

	_audio_buffer_edit = _add_options_text_field(vbox, "Buffer (frames)",
		str(_audio_buffer_frames(mx)),
		func(text: String) -> void: _apply_audio_buffer(text),
		false, true)

	_audio_buffer_hint = MenuStyle.hint("")
	vbox.add_child(_audio_buffer_hint)
	_refresh_audio_buffer_row()


func _apply_audio_buffer(text: String) -> void:
	var mx: Object = _meta_audio()
	if mx == null:
		return
	var frames := text.strip_edges().to_int()
	if frames > 0:
		# The mixer takes milliseconds and converts back by truncation, so a
		# frame count handed over exactly can land one frame low. Half a frame of
		# slack is far larger than the float error and far smaller than the step.
		mx.call("set_target_latency_ms", (frames + 0.5) * 1000.0 / AudioServer.get_mix_rate())
		# Every underrun counted so far was counted against the old depth, so
		# leaving the total standing would make the HUD's row describe a queue
		# that is no longer running.
		mx.call("reset_underrun_count")
	# Unparseable or out of range: the field is rewritten from the mixer below,
	# so what the player is left looking at is what actually took effect.
	_refresh_audio_buffer_row()


func _refresh_audio_buffer_row() -> void:
	var mx: Object = _meta_audio()
	if mx == null:
		return
	var frames := _audio_buffer_frames(mx)

	if is_instance_valid(_audio_buffer_edit):
		_audio_buffer_edit.text = str(frames)
	if is_instance_valid(_audio_buffer_hint):
		_audio_buffer_hint.text = (
			"Now %d frames — %.0f ms at %s kHz. Default 2048. Lower is tighter but "
			% [frames, float(mx.call("get_target_latency_ms")),
				_khz(AudioServer.get_mix_rate())]
			+ "underruns sooner, and a value the ring cannot hold snaps back. "
			+ "Not saved.")


## What the mixer is actually holding, in frames. It reports milliseconds, but
## the value behind them is a whole frame count, so this rounds rather than
## truncating — the conversion cannot land between two frames.
func _audio_buffer_frames(mx: Object) -> int:
	return roundi(float(mx.call("get_target_latency_ms")) * AudioServer.get_mix_rate() / 1000.0)


static func _khz(rate: float) -> String:
	return ("%.1f" % (rate / 1000.0)).trim_suffix(".0")


## The mixer, or null where there is none to tune: the extension ships on Windows
## and Android only, and reports itself unavailable when the desktop switch has
## handed spatial audio back to Godot's own panner.
func _meta_audio() -> Object:
	if not Engine.has_singleton("MetaXRAudio"):
		return null
	var mx: Object = Engine.get_singleton("MetaXRAudio")
	if mx == null or not bool(mx.call("is_available")):
		return null
	return mx


## The build plate at the top of DEBUG.
##
## The headline is `git describe` verbatim, because that one string answers all
## three questions at once — nearest tag, distance past it, commit — and is the
## thing worth reading out loud. The rows under it break the same value back
## apart so a report can quote one field instead of a compound one, and add the
## two things a description cannot carry: when the build was made and what it
## was made for.
func _build_plate(vbox: VBoxContainer) -> void:
	var plate := PanelContainer.new()
	var style := MenuStyle.rounded(MenuStyle.COLOR_NAV_INACTIVE, 8)
	style.content_margin_left = 18
	style.content_margin_right = 18
	style.content_margin_top = 14
	style.content_margin_bottom = 14
	plate.add_theme_stylebox_override("panel", style)
	vbox.add_child(plate)

	var col := MenuStyle.vbox(8)
	plate.add_child(col)

	var head := MenuStyle.hbox(10)
	col.add_child(head)

	var desc := MenuStyle.label(BuildInfo.describe(), 28, MenuStyle.COLOR_TITLE)
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(desc)

	# A chip rather than a row: it is a warning about the line beside it, not
	# another field. A dirty build's hash does not describe what is running.
	if BuildInfo.is_dirty():
		head.add_child(_plate_chip("UNCOMMITTED", MenuStyle.COLOR_BTN_UPD))

	col.add_child(HSeparator.new())

	var when := BuildInfo.commit_date()
	_plate_row(col, "Commit", BuildInfo.commit_hash()
		+ ("" if when.is_empty() else "   " + BuildInfo.short_date(when)))

	var tag := BuildInfo.tag()
	if tag.is_empty():
		_plate_row(col, "Tag", "none in this repository")
	else:
		var since := BuildInfo.commits_since_tag()
		var distance := "this commit" if since == 0 \
			else "+%d commit%s" % [since, "" if since == 1 else "s"]
		_plate_row(col, "Tag", "%s   %s" % [tag, distance])

	var built := BuildInfo.built_at()
	_plate_row(col, "Built", "%s UTC" % built if not built.is_empty()
		else "not an export — running from source")

	_plate_row(col, "Target", BuildInfo.target_line())


## One field of the plate: a fixed-width name so the values line up into a
## column, and a value that wraps rather than running under the scroll bar.
func _plate_row(col: VBoxContainer, field: String, value: String) -> void:
	var row := MenuStyle.hbox(12)
	col.add_child(row)

	var name_lbl := MenuStyle.label(field, 16, MenuStyle.COLOR_DESC)
	name_lbl.custom_minimum_size = Vector2(PLATE_FIELD_W, 0)
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	row.add_child(name_lbl)

	var value_lbl := MenuStyle.label(value, 18, MenuStyle.COLOR_LICENSE)
	value_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(value_lbl)


func _plate_chip(text: String, color: Color) -> Control:
	var chip := PanelContainer.new()
	var style := MenuStyle.rounded(color, 6)
	style.content_margin_left = 12
	style.content_margin_right = 12
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	chip.add_theme_stylebox_override("panel", style)
	chip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	chip.add_child(MenuStyle.label(text, 16, MenuStyle.COLOR_TITLE))
	return chip


## System Filter option — off shows the media players, test core and
## single-game cores that SystemFilter keeps out of the Download grid.
# ── Storage ───────────────────────────────────────────────────────────────────
#
# Where everything lives, what it costs, and what nothing claims any more.
#
# On its own page rather than under BIOS / Extras, where this started: that tab
# is built from the cores you have installed, so it lists no page at all for a
# system without one, and a sweep that spans ROM artwork, library rows and save
# folders has nothing to do with any single core. It is also not RomM's — the
# leftovers it finds include ScreenScraper art and core settings — so it sits
# beside the RomM page rather than inside it.

func _build_storage_options(vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.spacer(10))
	vbox.add_child(MenuStyle.header("WHERE THINGS LIVE", 20))
	_add_storage_path(vbox, "ROMs", RomLibrary.default_roms_root())
	_add_storage_path(vbox, "Cores and saves", CoreDownloadManager.default_core_root())
	_add_storage_path(vbox, "Books", RomLibrary.default_books_root())
	_add_storage_path(vbox, "Videos", RomLibrary.default_videos_root())

	_storage_usage_label = MenuStyle.label("", 15, MenuStyle.COLOR_DESC)
	_storage_usage_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_storage_usage_label)
	_refresh_storage_usage()

	vbox.add_child(MenuStyle.spacer(16))
	vbox.add_child(MenuStyle.header("CLEAN UP", 20))
	vbox.add_child(MenuStyle.hint(
		"Artwork, settings and library entries left behind by games and cores you "
		+ "removed. Nothing is deleted until you choose it."))

	var scan_row := MenuStyle.hbox(10)
	_cleanup_scan_btn = Button.new()
	_cleanup_scan_btn.text = "%s  Scan for leftovers" % String.chr(MenuIcons.SCRAPE)
	_cleanup_scan_btn.add_theme_font_override("font", MenuIcons.symbols())
	_cleanup_scan_btn.add_theme_font_size_override("font_size", 17)
	_cleanup_scan_btn.custom_minimum_size = Vector2(280, 52)
	_cleanup_scan_btn.pressed.connect(_on_cleanup_scan_pressed)
	scan_row.add_child(_cleanup_scan_btn)
	var pad := Control.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scan_row.add_child(pad)
	vbox.add_child(scan_row)

	_cleanup_panel = VBoxContainer.new()
	_cleanup_panel.add_theme_constant_override("separation", 4)
	vbox.add_child(_cleanup_panel)


func _add_storage_path(vbox: VBoxContainer, label_text: String, path: String) -> void:
	var row := MenuStyle.hbox(10)
	var name_lbl := MenuStyle.label(label_text, 16, MenuStyle.COLOR_TITLE)
	name_lbl.custom_minimum_size = Vector2(220, 0)
	row.add_child(name_lbl)
	var path_lbl := MenuStyle.label(path, 15, MenuStyle.COLOR_LICENSE)
	path_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_lbl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	row.add_child(path_lbl)
	vbox.add_child(row)


func _refresh_storage_usage() -> void:
	if _storage_usage_label == null or not is_instance_valid(_storage_usage_label):
		return
	var parts: Array[String] = []
	if romm_cache != null and romm_config != null:
		parts.append("%s of downloaded games cached, %.0f GB budget"
			% [MenuStyle.human_bytes(romm_cache.total_bytes()), romm_config.cache_budget_gb])
	var cores := 0
	var dir := DirAccess.open(CoreDownloadManager.default_cores_dir())
	if dir != null:
		dir.list_dir_begin()
		var fname := dir.get_next()
		while fname != "":
			if not dir.current_is_dir() \
					and not CoreDownloadManager.core_name_from_lib_filename(fname).is_empty():
				cores += 1
			fname = dir.get_next()
		dir.list_dir_end()
	parts.append("%d core%s installed" % [cores, "" if cores == 1 else "s"])
	_storage_usage_label.text = " · ".join(PackedStringArray(parts))


# Both halves run on a worker thread, and both must.
#
# Measured on a 72-system library: the scan is ~160 ms, which is fourteen dropped
# frames at 90 Hz — a visible judder in a headset, not a pause. Removing is far
# worse: the same library offered 3,164 files to unlink, and that is seconds.
#
# StorageCleanup is static and shares nothing — each call builds its own
# GamelistManager and RommCacheManifest — so the worker touches no state the main
# thread can see. Results come back through call_deferred, and only the main
# thread ever builds a Control.

func _exit_tree() -> void:
	# A Thread freed while running prints "destroyed without its completion having
	# been realized" and leaves the worker writing into a freed view.
	_join_cleanup_thread()


func _join_cleanup_thread() -> void:
	if _cleanup_thread != null:
		if _cleanup_thread.is_started():
			_cleanup_thread.wait_to_finish()
		_cleanup_thread = null


## Scan and render. Idempotent — pressing it again rescans, which is what you
## want after removing a core.
func _on_cleanup_scan_pressed() -> void:
	if _cleanup_panel == null or _cleanup_busy:
		return
	# A live transfer's .part is indistinguishable from an abandoned one, and the
	# sweep would offer to delete the download in progress.
	var dl: Object = _menu.romm_downloader if _menu != null else null
	if dl != null and dl.is_busy():
		notify("cleanup", String.chr(MenuIcons.ERROR),
			"Finish the download first — a running transfer looks like leftovers",
			-1.0, MenuToasts.DWELL_FAIL)
		return

	_set_cleanup_busy(true)
	_show_cleanup_status("Looking through your library…")
	_join_cleanup_thread()
	_cleanup_thread = Thread.new()
	_cleanup_thread.start(_cleanup_scan_worker)


func _cleanup_scan_worker() -> void:
	_on_cleanup_scanned.call_deferred(StorageCleanup.scan())


func _on_cleanup_scanned(found: Dictionary) -> void:
	_set_cleanup_busy(false)
	_cleanup_found = found
	_cleanup_selected.clear()
	# Everything safe starts ticked; saves never do. The user came here to clean
	# up, so the safe set is the default — but nothing irreversible is opted in
	# on their behalf.
	for kind: String in StorageCleanup.DEFAULT_SELECTED:
		if _cleanup_found.has(kind):
			_cleanup_selected[kind] = true
	_rebuild_cleanup_panel()


## A one-line placeholder in the results area while a worker runs, so the page
## says what is happening rather than looking inert.
func _set_cleanup_busy(busy: bool) -> void:
	_cleanup_busy = busy
	if _cleanup_scan_btn != null and is_instance_valid(_cleanup_scan_btn):
		_cleanup_scan_btn.disabled = busy


func _show_cleanup_status(text: String) -> void:
	if _cleanup_panel == null or not is_instance_valid(_cleanup_panel):
		return
	for c in _cleanup_panel.get_children():
		c.queue_free()
	var lbl := MenuStyle.label("%s  %s" % [String.chr(MenuIcons.BUSY), text],
		16, MenuIcons.TINT_BUSY)
	lbl.add_theme_font_override("font", MenuIcons.symbols())
	_cleanup_panel.add_child(lbl)


func _rebuild_cleanup_panel() -> void:
	for c in _cleanup_panel.get_children():
		c.queue_free()

	if _cleanup_found.is_empty():
		_cleanup_panel.add_child(MenuStyle.label(
			"Nothing to clean up — everything on disk is in use.", 16, MenuIcons.TINT_OK))
		return

	# A VRCheck, not a CheckBox and not a VRToggle. These rows are a selection out
	# of a list, which is what a tickbox means; an ON/OFF switch reads as a
	# setting that persists. Godot's own CheckBox is unusable here twice over: its
	# ~16 px indicator is a few faint pixels at panel distance, and it defaults to
	# ACTION_MODE_BUTTON_PRESS while every click inside a Viewport2DIn3D arrives
	# as TWO presses — each tap flipped it twice and left it where it started.
	for kind: String in _cleanup_found:
		var entry: Dictionary = _cleanup_found[kind]
		var is_saves := kind == StorageCleanup.SAVES

		var row := MenuStyle.hbox(10)
		row.custom_minimum_size = Vector2(0, 62)

		var lbl := MenuStyle.label("%s  —  %d item%s" % [str(entry["label"]),
			int(entry["count"]), "" if int(entry["count"]) == 1 else "s"], 18,
			# Saves read differently from the rest, and the colour is the only
			# warning that survives being skim-read.
			MenuIcons.TINT_WARN if is_saves else MenuStyle.COLOR_TITLE)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		if is_saves:
			lbl.tooltip_text = "Game progress. Once deleted it cannot be downloaded again."
		row.add_child(lbl)

		var size_lbl := MenuStyle.label(
			String.humanize_size(int(entry["bytes"])), 16, MenuIcons.TINT_MUTED)
		size_lbl.custom_minimum_size = Vector2(130, 0)
		size_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		size_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		row.add_child(size_lbl)

		row.add_child(VRCheck.create(bool(_cleanup_selected.get(kind, false)),
			func(on: bool) -> void: _cleanup_selected[kind] = on))

		# The scrollbar is 40 px and drawn over the content, so without this the
		# switch sits underneath it — the same gutter every other list here keeps.
		var gutter := Control.new()
		gutter.custom_minimum_size = Vector2(44, 0)
		gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(gutter)

		_cleanup_panel.add_child(row)

	var actions := MenuStyle.hbox(10)
	actions.custom_minimum_size = Vector2(0, 56)
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(spacer)

	var close := Button.new()
	close.text = "Close"
	close.custom_minimum_size = Vector2(140, 50)
	close.add_theme_font_size_override("font_size", 17)
	close.pressed.connect(func() -> void:
		_cleanup_found.clear()
		_cleanup_selected.clear()
		_rebuild_cleanup_panel()
		for c in _cleanup_panel.get_children():
			c.queue_free())
	actions.add_child(close)

	var go := Button.new()
	go.add_theme_font_override("font", MenuIcons.symbols())
	go.add_theme_font_size_override("font_size", 17)
	go.custom_minimum_size = Vector2(230, 50)
	go.text = "%s  Delete selected" % String.chr(MenuIcons.DELETE_FOREVER)
	go.add_theme_color_override("font_color", MenuIcons.TINT_DELETE)
	go.pressed.connect(_on_cleanup_confirm)
	actions.add_child(go)

	var act_gutter := Control.new()
	act_gutter.custom_minimum_size = Vector2(44, 0)
	act_gutter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	actions.add_child(act_gutter)

	_cleanup_panel.add_child(actions)


func _on_cleanup_confirm() -> void:
	if _cleanup_busy:
		return
	var kinds: Array = []
	for kind: String in _cleanup_selected:
		if bool(_cleanup_selected[kind]):
			kinds.append(kind)
	if kinds.is_empty():
		notify("cleanup", String.chr(MenuIcons.ERROR), "Nothing selected",
			-1.0, MenuToasts.DWELL_OK)
		return

	var total := 0
	for kind: String in kinds:
		total += int((_cleanup_found[kind] as Dictionary)["count"])

	_set_cleanup_busy(true)
	_show_cleanup_status("Removing %d item%s…" % [total, "" if total == 1 else "s"])
	# The findings are handed to the worker by value so a repaint on this side
	# cannot mutate what is being deleted halfway through.
	var snapshot := _cleanup_found.duplicate(true)
	_join_cleanup_thread()
	_cleanup_thread = Thread.new()
	_cleanup_thread.start(_cleanup_remove_worker.bind(snapshot, kinds))


func _cleanup_remove_worker(found: Dictionary, kinds: Array) -> void:
	var res := StorageCleanup.remove(found, kinds)
	# Rescanned on the worker too, rather than assuming: a category may have been
	# partly undeletable, and the panel would otherwise claim work it did not do.
	res["found"] = StorageCleanup.scan()
	_on_cleanup_removed.call_deferred(res)


func _on_cleanup_removed(res: Dictionary) -> void:
	_set_cleanup_busy(false)
	notify("cleanup", String.chr(MenuIcons.CHECK),
		"Removed %d item%s, freed %s" % [int(res["removed"]),
			"" if int(res["removed"]) == 1 else "s",
			String.humanize_size(int(res["freed"]))],
		-1.0, MenuToasts.DWELL_OK)

	_cleanup_found = res.get("found", {}) as Dictionary
	_cleanup_selected.clear()
	for kind: String in StorageCleanup.DEFAULT_SELECTED:
		if _cleanup_found.has(kind):
			_cleanup_selected[kind] = true
	_rebuild_cleanup_panel()
	_refresh_storage_usage()


func _build_system_filter_options(vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.spacer(10))

	var sf_row := HBoxContainer.new()
	sf_row.add_theme_constant_override("separation", 10)
	sf_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(sf_row)

	var sf_col := VBoxContainer.new()
	sf_col.add_theme_constant_override("separation", 0)
	sf_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sf_row.add_child(sf_col)

	sf_col.add_child(MenuStyle.label("Libretro System Filter", 22, MenuStyle.COLOR_TITLE))

	sf_col.add_child(MenuStyle.label("Hide %d non-console systems" % SystemFilter.hidden_ids().size(), 16, MenuStyle.COLOR_LICENSE))

	sf_row.add_child(VRToggle.create(AppPrefs.system_filter, func(on: bool) -> void:
		AppPrefs.system_filter = on
		AppPrefs.save_prefs()
		SystemFilter.enabled = on
		system_filter_changed.emit()
	))

	_build_bios_boot_override(vbox)


## The switch that hands the BIOS-boot core options back to the player.
##
## Nothing to emit: the pins are re-read when a machine powers on and when an
## options list is populated, so an open panel does not need telling.
func _build_bios_boot_override(vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.spacer(10))

	var bb_row := HBoxContainer.new()
	bb_row.add_theme_constant_override("separation", 10)
	bb_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(bb_row)

	var bb_col := VBoxContainer.new()
	bb_col.add_theme_constant_override("separation", 0)
	bb_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bb_row.add_child(bb_col)

	bb_col.add_child(MenuStyle.label("Override BIOS Boot Options", 22, MenuStyle.COLOR_TITLE))
	bb_col.add_child(MenuStyle.label(
		"Let the core options that play a machine's boot screen be changed",
		16, MenuStyle.COLOR_LICENSE))

	bb_row.add_child(VRToggle.create(AppPrefs.bios_boot_override, func(on: bool) -> void:
		AppPrefs.bios_boot_override = on
		AppPrefs.save_prefs()
	))


## Android / Quest only — the tab is not built on desktop at all.
func _build_file_server_options(vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.spacer(10))

	var fs_row := HBoxContainer.new()
	fs_row.add_theme_constant_override("separation", 10)
	fs_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(fs_row)

	var fs_lbl := Label.new()
	fs_lbl.text = "Web File Manager"
	fs_lbl.add_theme_font_size_override("font_size", 20)
	fs_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	fs_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	fs_row.add_child(fs_lbl)

	var fs_toggle := VRToggle.create(scraper_config.web_server_enabled, func(on: bool) -> void:
		if on:
			web_server.start()
		else:
			web_server.stop()
		scraper_config.web_server_enabled = on
		scraper_config.save_config()
		_server_address_label.visible = on
	)
	fs_row.add_child(fs_toggle)

	_server_address_label = Label.new()
	_server_address_label.add_theme_font_size_override("font_size", 16)
	_server_address_label.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
	_server_address_label.text = "http://%s:8080   PIN: %s" % \
		[WebFileServer.local_ip(), scraper_config.ensure_web_server_pin()]
	_server_address_label.visible = scraper_config.web_server_enabled
	vbox.add_child(_server_address_label)


## ScreenScraper.fr credentials and scrape preferences.
func _build_scraper_options(vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.spacer(10))

	# User credentials
	_add_options_text_field(vbox, "Username (ssid)", scraper_config.ssid, func(text: String):
		scraper_config.ssid = text
		scraper_config.save_config()
	)
	_add_options_text_field(vbox, "Password", scraper_config.sspassword, func(text: String):
		scraper_config.sspassword = text
		scraper_config.save_config()
	, true)

	# Region priorities
	_add_options_text_field(vbox, "Region Priority", ", ".join(scraper_config.region_priorities), func(text: String):
		var parts: Array[String] = []
		for p in text.split(","):
			var trimmed := p.strip_edges().to_lower()
			if not trimmed.is_empty():
				parts.append(trimmed)
		if not parts.is_empty():
			scraper_config.region_priorities = parts
			scraper_config.save_config()
	)

	# Language priorities
	_add_options_text_field(vbox, "Language Priority", ", ".join(scraper_config.language_priorities), func(text: String):
		var parts: Array[String] = []
		for p in text.split(","):
			var trimmed := p.strip_edges().to_lower()
			if not trimmed.is_empty():
				parts.append(trimmed)
		if not parts.is_empty():
			scraper_config.language_priorities = parts
			scraper_config.save_config()
	)


## RomM server connection and sync settings. The sub-tab carries the name and
## the logo, so there is no in-body header here.
## Persist the RomM config AND hand it to the sync layer.
##
## RommSaveSync.setup() has existed since that layer landed and nothing ever
## called it, so a server, a token or a switch changed here stayed invisible to
## it until the app was restarted — the sync thread went on using the config it
## read at boot. Every write in this tab goes through here now.
func _save_romm_config() -> void:
	romm_config.save_config()
	SaveSync.setup(romm_config)
	# BOTH sync layers, or the one that was added second inherits exactly the
	# bug this helper exists to fix: StateSync would go on using the config it
	# read at boot, so a server set up during the session would leave the States
	# tab reporting "on this device" for every row until the app restarted.
	StateSync.setup(romm_config)


func _build_romm_options(vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.spacer(10))

	var enable_row := HBoxContainer.new()
	enable_row.custom_minimum_size = Vector2(0, 68)
	enable_row.add_theme_constant_override("separation", 10)
	vbox.add_child(enable_row)

	var enable_lbl := Label.new()
	enable_lbl.text = "Enable RomM library"
	enable_lbl.add_theme_font_size_override("font_size", 20)
	enable_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	enable_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enable_row.add_child(enable_lbl)

	enable_row.add_child(VRToggle.create(romm_config.enabled, func(on: bool) -> void:
		romm_config.enabled = on
		_save_romm_config()
		if on:
			romm_platforms_requested.emit()
	))

	var backup_row := HBoxContainer.new()
	backup_row.custom_minimum_size = Vector2(0, 68)
	backup_row.add_theme_constant_override("separation", 10)
	vbox.add_child(backup_row)

	var backup_lbl := Label.new()
	backup_lbl.text = "Back up saves and states"
	backup_lbl.add_theme_font_size_override("font_size", 20)
	backup_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	backup_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	backup_lbl.tooltip_text = "Upload battery saves and save states to RomM as they are written"
	backup_row.add_child(backup_lbl)

	backup_row.add_child(VRToggle.create(romm_config.backup_enabled, func(on: bool) -> void:
		romm_config.backup_enabled = on
		_save_romm_config()
	))

	_romm_url_edit = _add_options_text_field(vbox, "Server URL", romm_config.base_url,
		func(text: String) -> void:
			romm_config.base_url = RommConfig.normalize_url(text)
			_save_romm_config()
			if romm_art != null:
				romm_art.setup(romm_config.base_url)
	)

	# On this row rather than the API token: the QR carries the server address
	# too, and this row stays visible in both sign-in modes. Quest 3/3S only —
	# everywhere else the row looks exactly as it always has.
	if QrScanner.is_available():
		var scan_btn := Button.new()
		scan_btn.text = String.chr(MenuIcons.SCAN_QR)
		scan_btn.add_theme_font_override("font", MenuIcons.symbols())
		scan_btn.add_theme_font_size_override("font_size", 26)
		scan_btn.add_theme_color_override("font_color", MenuIcons.TINT_DOWNLOAD)
		scan_btn.custom_minimum_size = Vector2(SCAN_BTN_WIDTH, 48)
		scan_btn.focus_mode = Control.FOCUS_NONE
		scan_btn.tooltip_text = "Scan RomM pairing QR"
		scan_btn.pressed.connect(_on_scan_qr_pressed)

		var url_row := _romm_url_edit.get_parent()
		url_row.add_child(scan_btn)
		# Index 1: after the label, before the field. The label absorbs the
		# slack, so the field keeps its width and its right edge still lines up
		# with every other row.
		url_row.move_child(scan_btn, 1)

	# VRDropdown, never OptionButton — every Viewport2Din3D click fires twice.
	_romm_mode_drop = VRDropdown.create("Sign in with",
		[["API token", RommConfig.AUTH_TOKEN],
		 ["Username + password", RommConfig.AUTH_BASIC]],
		romm_config.auth_mode, 1, Vector2(300, 56), 18)
	_romm_mode_drop.item_selected.connect(func(id: Variant) -> void:
		romm_config.auth_mode = str(id)
		_save_romm_config()
		_apply_romm_auth_rows()
	)
	vbox.add_child(_romm_mode_drop)

	_romm_token_edit = _add_options_text_field(vbox, "API token", romm_config.token,
		func(text: String) -> void:
			romm_config.token = text.strip_edges()
			_save_romm_config()
	, true)

	var user_edit := _add_options_text_field(vbox, "Username", romm_config.username,
		func(text: String) -> void:
			romm_config.username = text.strip_edges()
			_save_romm_config()
	)

	var pass_edit := _add_options_text_field(vbox, "Password", romm_config.password,
		func(text: String) -> void:
			romm_config.password = text
			_save_romm_config()
	, true)

	# Device pairing: type a short code instead of a 68-character token in VR.
	# The code is alphanumeric and dashed (RomM issues e.g. MXWT-SDZE), so it is
	# not length- or digit-checked here — the server is the authority on format.
	var pair_edit := _add_options_text_field(vbox, "Pair code", "", func(text: String) -> void:
		var code := text.strip_edges()
		if code.is_empty():
			return
		if code.length() > RommPairUrl.MAX_CODE_LEN:
			notify("romm:conn", "❌", "That doesn't look like a pair code",
				-1.0, MenuToasts.DWELL_FAIL)
			return
		_apply_pair_code(code)
	)

	# Pairing yields a token, so it belongs with the token method.
	_romm_token_rows = [_romm_token_edit.get_parent(), pair_edit.get_parent()]
	_romm_basic_rows = [user_edit.get_parent(), pass_edit.get_parent()]
	_apply_romm_auth_rows()

	_add_options_text_field(vbox, "Cache budget (GB)", str(romm_config.cache_budget_gb),
		func(text: String) -> void:
			var v := text.strip_edges().to_float()
			if v > 0.0:
				romm_config.cache_budget_gb = v
				_save_romm_config()
				update_romm_status_label()
	)

	# Actions
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	vbox.add_child(actions)

	var test_btn := Button.new()
	test_btn.text = "  Test connection  "
	test_btn.custom_minimum_size = Vector2(0, 56)
	test_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	test_btn.add_theme_font_size_override("font_size", 18)
	test_btn.pressed.connect(func() -> void:
		notify("romm:conn", "⏳", "Contacting RomM…", -1.0)
		romm_client.test_connection(func(ok: bool, summary: String) -> void:
			notify("romm:conn", "✅" if ok else "❌", summary, -1.0,
				MenuToasts.DWELL_OK if ok else MenuToasts.DWELL_FAIL)
			if ok:
				romm_platforms_requested.emit()
		)
	)
	actions.add_child(test_btn)

	var sync_btn := Button.new()
	sync_btn.custom_minimum_size = Vector2(0, 56)
	sync_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sync_btn.add_theme_font_size_override("font_size", 18)
	sync_btn.pressed.connect(_on_romm_sync_all_pressed)
	actions.add_child(sync_btn)
	_romm_sync_btn = sync_btn
	_update_romm_sync_btn()

	_romm_status_label = Label.new()
	_romm_status_label.add_theme_font_size_override("font_size", 16)
	_romm_status_label.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
	_romm_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_romm_status_label)
	update_romm_status_label()

	vbox.add_child(HSeparator.new())


## Show only the rows the selected sign-in method uses.
func _apply_romm_auth_rows() -> void:
	var token_mode := romm_config.auth_mode == RommConfig.AUTH_TOKEN
	for row in _romm_token_rows:
		if is_instance_valid(row):
			row.visible = token_mode
	for row in _romm_basic_rows:
		if is_instance_valid(row):
			row.visible = not token_mode


## Exchange a pairing code for a scoped token. Shared by the typed field and the
## QR scanner, so both report the same way and both refresh the token field.
func _apply_pair_code(code: String) -> void:
	notify("romm:conn", "⏳", "Pairing with RomM…", -1.0)
	romm_client.pair_with_code(code, func(ok: bool, token: String, err: String) -> void:
		if not ok:
			notify("romm:conn", "❌", err, -1.0, MenuToasts.DWELL_FAIL)
			return
		romm_config.auth_mode = RommConfig.AUTH_TOKEN
		romm_config.token = token
		romm_config.enabled = true
		romm_config.save_config()
		if _romm_token_edit != null:
			_romm_token_edit.text = token
		# Pairing switches the method, so the dropdown and rows follow it.
		if is_instance_valid(_romm_mode_drop):
			_romm_mode_drop.select_id(RommConfig.AUTH_TOKEN)
		_apply_romm_auth_rows()
		var where := romm_config.base_url.trim_prefix("http://").trim_prefix("https://")
		notify("romm:conn", "✅",
			"Paired with RomM" if where.is_empty() else "Paired with RomM at %s" % where,
			-1.0, MenuToasts.DWELL_OK)
		romm_platforms_requested.emit()
	)


func _on_scan_qr_pressed() -> void:
	# Opening the overlay is not idempotent and every Viewport2Din3D click
	# arrives twice.
	var frame := Engine.get_process_frames()
	if frame == _last_scan_frame:
		return
	_last_scan_frame = frame

	if is_instance_valid(_qr_overlay):
		return

	if not QrScanner.has_permission():
		QrScanner.request_permission()
		notify("romm:qr", "⏳", "Allow camera access, then tap scan again",
			-1.0, MenuToasts.DWELL_INFO)
		return

	var host: Control = get_parent()
	if host == null:
		return

	_qr_overlay = QrScanOverlay.create(self)
	_qr_overlay.scanned.connect(_on_qr_scanned)
	host.add_child(_qr_overlay)


func _on_qr_scanned(payload: String) -> void:
	var parsed := RommPairUrl.parse(payload)
	var url := str(parsed.get("url", ""))
	var code := str(parsed.get("code", ""))

	if code.is_empty():
		notify("romm:qr", "❌", "That QR isn't a RomM pairing code",
			-1.0, MenuToasts.DWELL_FAIL)
		if is_instance_valid(_qr_overlay):
			_qr_overlay.set_status("Not a RomM pairing code — still looking…")
			_qr_overlay.resume()
		return

	var current := romm_config.base_url
	if not url.is_empty() and not current.is_empty() and url != current:
		if is_instance_valid(_qr_overlay):
			_qr_overlay.ask("Switch to %s?" % url,
				func() -> void: _commit_scan(url, code))
			return

	_commit_scan(url, code)


## The URL must be committed before the exchange — RommClient builds the request
## against the configured host. A failed exchange leaves the new URL in place so
## it stays visible and editable; silently restoring a stale address would be
## harder to recover from than a wrong one you can see.
##
## In memory only. A QR carries whatever address the browser that drew it was
## open at, which is regularly one the headset cannot reach (localhost, a proxy
## hostname), so a scan is a likely way to LOSE a working server. Persisting is
## left to _apply_pair_code, which saves once the exchange succeeds — the URL
## stays on screen and editable either way, and a restart recovers the address
## that was actually working.
func _commit_scan(url: String, code: String) -> void:
	if not url.is_empty():
		romm_config.base_url = url
		if _romm_url_edit != null:
			_romm_url_edit.text = url
		if romm_art != null:
			romm_art.setup(url)

	if is_instance_valid(_qr_overlay):
		_qr_overlay.close()
		_qr_overlay = null

	_apply_pair_code(code)


## Sync every mapped platform, one after another — for deliberate offline
## browsing. Normal use never needs this; platforms sync when you open them.
## The button reads "Sync all now" or "Stop syncing" depending on what is
## happening, so this is both. Called from update_romm_status_label, which the
## menu already runs on every sync transition.
func _update_romm_sync_btn() -> void:
	if _romm_sync_btn == null or not is_instance_valid(_romm_sync_btn):
		return
	var busy := romm_catalog != null and romm_catalog.is_syncing()
	if busy:
		var queued := _romm_sync_queue.size()
		_romm_sync_btn.text = "  Stop syncing  " if queued == 0 \
			else "  Stop syncing (%d queued)  " % queued
	else:
		_romm_sync_btn.text = "  Sync all now  "


func _on_romm_sync_all_pressed() -> void:
	# Stop, when there is something to stop. Everything queued goes too: this is
	# the control that queued them, and cancelling one platform only to watch the
	# next start immediately does not read as a cancel.
	if romm_catalog != null and romm_catalog.is_syncing():
		var dropped := _romm_sync_queue.size()
		# Cleared BEFORE the abort: aborting announces itself, and the SPAWN tab
		# answers that by advancing the queue. Stopping one platform only to
		# watch the next start does not read as a cancel.
		_romm_sync_queue.clear()
		romm_catalog.abort_sync()
		if dropped > 0:
			notify("romm:sync:queue", "⏹", "%d queued platform%s dropped"
				% [dropped, "" if dropped == 1 else "s"], -1.0, MenuToasts.DWELL_OK)
		update_romm_status_label()
		return

	if not romm_config.is_configured():
		notify("romm:conn", "❌", "Set a server URL and sign-in first", -1.0, MenuToasts.DWELL_FAIL)
		return
	if _platforms().is_empty():
		romm_platforms_requested.emit()
		return
	_romm_sync_queue.clear()
	for systemid: String in _platforms():
		_romm_sync_queue.append({"sid": systemid, "full": true})
	pump_romm_sync_queue()
	_update_romm_sync_btn()


## Add platforms to the queue without disturbing what is already in it. `full`
## re-fetches every page; otherwise only the rows changed since that platform's
## recorded watermark.
##
## Public: the SPAWN tab queues deltas when the server's stats fingerprint moves,
## and the per-platform re-sync button queues one.
func queue_romm_sync(systemids: Array, full: bool) -> void:
	for sid: String in systemids:
		if not _is_queued(sid) and sid != romm_catalog.syncing_systemid():
			_romm_sync_queue.append({"sid": sid, "full": full})
	pump_romm_sync_queue()


func _is_queued(sid: String) -> bool:
	for e: Dictionary in _romm_sync_queue:
		if str(e.get("sid", "")) == sid:
			return true
	return false


## Public for the same reason: the queue advances when a sync finishes, which
## the menu hears, not this view.
##
## Loops rather than returning on a dud entry. A platform with no server id
## starts no sync, and nothing pumps the queue again except a sync FINISHING —
## so one unmapped platform used to strand every entry behind it.
func pump_romm_sync_queue() -> void:
	if romm_catalog.is_syncing():
		return
	while not _romm_sync_queue.is_empty():
		var entry: Dictionary = _romm_sync_queue.pop_front()
		var systemid := str(entry.get("sid", ""))
		var pid := int((_platforms().get(systemid, {}) as Dictionary).get("id", 0))
		if pid > 0 and romm_catalog.sync_platform(systemid, pid, bool(entry.get("full", true))):
			return


## Public: the menu owns the RomM sync signals, and a finished sync must move
## this readout even when the OPTIONS tab is not the one on screen.
func update_romm_status_label() -> void:
	# The menu calls this on every sync transition, which is exactly when the
	# button has to flip between starting and stopping.
	_update_romm_sync_btn()
	if _romm_status_label == null or not is_instance_valid(_romm_status_label):
		return

	var parts: Array[String] = []
	if not romm_client.server_version.is_empty():
		parts.append("RomM %s" % romm_client.server_version)
	if not _platforms().is_empty():
		var total := 0
		for sid: String in _platforms():
			total += int((_platforms()[sid] as Dictionary).get("rom_count", 0))
		parts.append("%d games across %d platforms" % [total, _platforms().size()])
	if romm_cache != null:
		parts.append("%s cached / %.0f GB budget"
			% [MenuStyle.human_bytes(romm_cache.total_bytes()), romm_config.cache_budget_gb])

	var text := " · ".join(PackedStringArray(parts)) if not parts.is_empty() \
		else "Not connected."

	if not _unmapped().is_empty():
		# Biggest first, capped — a full list runs to dozens of engine cores and
		# one-ROM oddities that will never have a systemid.
		var sorted_un := _unmapped().duplicate()
		sorted_un.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a.get("rom_count", 0)) > int(b.get("rom_count", 0))
		)
		var names: Array[String] = []
		for i in mini(sorted_un.size(), 6):
			var p: Dictionary = sorted_un[i]
			names.append("%s (%d)" % [RommPlatforms.display_name(p), int(p.get("rom_count", 0))])
		text += "\n%d unmapped: " % _unmapped().size() + ", ".join(PackedStringArray(names))
		if sorted_un.size() > 6:
			text += " and %d more" % (sorted_un.size() - 6)

	_romm_status_label.text = text


## Returns the LineEdit so a caller can hang a button off its row
## (edit.get_parent()) or write a value back into it.
##
## `digits` makes it a whole-number field: anything else is dropped as it is
## typed, and the headset's overlay keyboard opens on its number layout. Godot
## has no numeric LineEdit, and a SpinBox is unusable through a laser pointer at
## this size, so the restriction is the field's own.
func _add_options_text_field(parent: VBoxContainer, label_text: String,
							 initial_value: String, on_changed: Callable,
							 secret: bool = false, digits: bool = false) -> LineEdit:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.custom_minimum_size = Vector2(0, 56)
	parent.add_child(row)

	var lbl := Label.new()
	lbl.text = label_text
	lbl.add_theme_font_size_override("font_size", 18)
	lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(lbl)

	var edit := LineEdit.new()
	edit.text = initial_value
	edit.custom_minimum_size = Vector2(260, 48)
	edit.add_theme_font_size_override("font_size", 16)
	edit.secret = secret

	if digits:
		# Read by VRKeyboardFix when it raises the overlay keyboard.
		edit.set_meta("vr_kb_type", DisplayServer.KEYBOARD_TYPE_NUMBER)
		# Assigning .text does not re-emit text_changed, so this cannot recurse.
		edit.text_changed.connect(func(text: String) -> void:
			var kept := ""
			for c in text:
				if c >= "0" and c <= "9":
					kept += c
			if kept != text:
				var caret := edit.caret_column - (text.length() - kept.length())
				edit.text = kept
				edit.caret_column = maxi(0, caret)
		)

	# Keyboard dismissal is handled globally by the VRKeyboard autoload.
	edit.text_submitted.connect(func(text: String) -> void: on_changed.call(text))
	edit.focus_exited.connect(func() -> void: on_changed.call(edit.text))

	row.add_child(edit)
	return edit


func _build_retroachievements_options(vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.spacer(10))

	if not RA.is_available():
		vbox.add_child(MenuStyle.hint(
			"The libretro extension did not load, so achievements are unavailable."))
		return

	var enable_row := HBoxContainer.new()
	enable_row.custom_minimum_size = Vector2(0, 68)
	enable_row.add_theme_constant_override("separation", 10)
	vbox.add_child(enable_row)

	var enable_lbl := Label.new()
	enable_lbl.text = "Enable RetroAchievements"
	enable_lbl.add_theme_font_size_override("font_size", 20)
	enable_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	enable_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	enable_row.add_child(enable_lbl)

	enable_row.add_child(VRToggle.create(RA.config.enabled, func(on: bool) -> void:
		RA.set_enabled(on)
		_update_ra_status()
	))

	# VRDropdown, never OptionButton — every Viewport2Din3D click fires twice.
	_ra_mode_drop = VRDropdown.create("Sign in with",
		[["Username + password", RaConfig.AUTH_PASSWORD],
		 ["Connect token", RaConfig.AUTH_TOKEN]],
		RA.config.auth_mode, 1, Vector2(300, 56), 18)
	_ra_mode_drop.item_selected.connect(func(id: Variant) -> void:
		RA.config.auth_mode = str(id)
		RA.config.save_config()
		_apply_ra_auth_rows()
	)
	vbox.add_child(_ra_mode_drop)

	_ra_user_edit = _add_options_text_field(vbox, "Username", RA.config.username,
		func(text: String) -> void:
			RA.config.username = text.strip_edges()
			RA.config.save_config()
	)

	# Never written to disk — RaConfig has no password field. It is passed to
	# rcheevos once, exchanged for a connect token, and forgotten.
	_ra_password_edit = _add_options_text_field(vbox, "Password", "",
		func(_text: String) -> void: pass, true)

	_ra_token_edit = _add_options_text_field(vbox, "Connect token", RA.config.token,
		func(text: String) -> void:
			RA.config.token = text.strip_edges()
			RA.config.save_config()
	, true)

	# The single most common RetroAchievements support issue: the site's control
	# panel shows a "Web API key", which is a different and longer value used for
	# read-only queries. It cannot unlock anything. The token wanted here is the
	# one RetroArch caches as cheevos_token.
	vbox.add_child(MenuStyle.hint(
		"The connect token is what RetroArch stores as cheevos_token — not the "
		+ "Web API key from the website, which cannot unlock achievements. "
		+ "Signing in with a password fetches the right token for you."))

	_ra_password_rows = [_ra_user_edit.get_parent(), _ra_password_edit.get_parent()]
	_ra_token_rows = [_ra_token_edit.get_parent()]
	_apply_ra_auth_rows()

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 10)
	vbox.add_child(actions)

	_ra_signin_btn = Button.new()
	_ra_signin_btn.text = "  Sign in  "
	_ra_signin_btn.custom_minimum_size = Vector2(0, 56)
	_ra_signin_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ra_signin_btn.add_theme_font_size_override("font_size", 18)
	_ra_signin_btn.pressed.connect(_on_ra_signin_pressed)
	actions.add_child(_ra_signin_btn)

	var signout_btn := Button.new()
	signout_btn.text = "  Sign out  "
	signout_btn.custom_minimum_size = Vector2(0, 56)
	signout_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	signout_btn.add_theme_font_size_override("font_size", 18)
	signout_btn.pressed.connect(func() -> void:
		RA.sign_out()
		if _ra_token_edit != null:
			_ra_token_edit.text = ""
		notify("ra:auth", "✅", "Signed out of RetroAchievements", -1.0, MenuToasts.DWELL_OK)
	)
	actions.add_child(signout_btn)

	_ra_status_label = Label.new()
	_ra_status_label.add_theme_font_size_override("font_size", 16)
	_ra_status_label.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
	_ra_status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_ra_status_label)

	vbox.add_child(HSeparator.new())

	var notify_row := HBoxContainer.new()
	notify_row.custom_minimum_size = Vector2(0, 68)
	notify_row.add_theme_constant_override("separation", 10)
	vbox.add_child(notify_row)
	var notify_lbl := Label.new()
	notify_lbl.text = "Show unlock notifications"
	notify_lbl.add_theme_font_size_override("font_size", 20)
	notify_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	notify_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	notify_row.add_child(notify_lbl)
	notify_row.add_child(VRToggle.create(RA.config.show_notifications, func(on: bool) -> void:
		RA.config.show_notifications = on
		RA.config.save_config()
	))

	var presence_row := HBoxContainer.new()
	presence_row.custom_minimum_size = Vector2(0, 68)
	presence_row.add_theme_constant_override("separation", 10)
	vbox.add_child(presence_row)
	var presence_lbl := Label.new()
	presence_lbl.text = "Rich presence"
	presence_lbl.add_theme_font_size_override("font_size", 20)
	presence_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	presence_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	presence_row.add_child(presence_lbl)
	presence_row.add_child(VRToggle.create(RA.config.rich_presence, func(on: bool) -> void:
		RA.config.rich_presence = on
		RA.config.save_config()
	))

	# No hardcore row. rc_client runs with hardcore off and there is nothing to
	# expose: RetroAchievements only grants hardcore credit to clients it has
	# approved, and until RetroXR is on that list the server records every unlock
	# as softcore whatever the client claims. The switch goes in when the approval
	# does, alongside the save-state and rollback gating the mode requires.

	# The per-game achievement list lives on the cartridge menu, not here — it is
	# a property of the game in your hand rather than of the app's settings.

	# Resolves the "Signing in…" toast. The login result is what the player is
	# waiting on, so it has to reuse the ra:auth key rather than only updating the
	# status label further down the page.
	RA.login_changed.connect(func(ok: bool, display_name: String, err: String) -> void:
		_update_ra_status()
		if ok:
			notify("ra:auth", "✅", "Signed in as %s" % display_name,
				-1.0, MenuToasts.DWELL_OK)
		elif not err.is_empty():
			notify("ra:auth", "❌", err, -1.0, MenuToasts.DWELL_FAIL)
	)
	RA.game_loaded.connect(func(_ok: bool, _t: String, _n: int, _u: int, _e: String) -> void:
		_update_ra_status())
	RA.achievement_unlocked.connect(func(_id: int, _t: String, _d: String,
			_p: int, _b: Texture2D) -> void:
		_update_ra_status())

	_update_ra_status()


## Show only the rows the selected sign-in method uses.
func _apply_ra_auth_rows() -> void:
	var password_mode := RA.config.auth_mode == RaConfig.AUTH_PASSWORD
	# The username is needed by both methods, so it stays put; only the secret
	# field swaps.
	for row in _ra_password_rows:
		if is_instance_valid(row):
			row.visible = true
	if is_instance_valid(_ra_password_edit) and _ra_password_edit.get_parent() != null:
		_ra_password_edit.get_parent().visible = password_mode
	for row in _ra_token_rows:
		if is_instance_valid(row):
			row.visible = not password_mode


func _on_ra_signin_pressed() -> void:
	# Signing in is not idempotent and every Viewport2Din3D click arrives twice.
	var frame := Engine.get_process_frames()
	if frame == _ra_last_signin_frame:
		return
	_ra_last_signin_frame = frame

	var username := _ra_user_edit.text.strip_edges() if is_instance_valid(_ra_user_edit) else ""
	if username.is_empty():
		notify("ra:auth", "❌", "Enter your RetroAchievements username",
			-1.0, MenuToasts.DWELL_FAIL)
		return

	notify("ra:auth", "⏳", "Signing in to RetroAchievements…", -1.0)

	if RA.config.auth_mode == RaConfig.AUTH_TOKEN:
		var token := _ra_token_edit.text.strip_edges() if is_instance_valid(_ra_token_edit) else ""
		if token.is_empty():
			notify("ra:auth", "❌", "Enter your connect token", -1.0, MenuToasts.DWELL_FAIL)
			return
		RA.sign_in_with_token(username, token)
		return

	var password := _ra_password_edit.text if is_instance_valid(_ra_password_edit) else ""
	if password.is_empty():
		notify("ra:auth", "❌", "Enter your password", -1.0, MenuToasts.DWELL_FAIL)
		return
	RA.sign_in_with_password(username, password)
	# Cleared as soon as it is handed over; it is never stored and there is no
	# reason for it to sit in a field afterwards.
	_ra_password_edit.text = ""


func _update_ra_status() -> void:
	if not is_instance_valid(_ra_status_label):
		return

	if not RA.config.enabled:
		_ra_status_label.text = "RetroAchievements is off."
		return

	if not RA.is_logged_in():
		_ra_status_label.text = "Not signed in."
		return

	var user := RA.user_info()
	var line := "Signed in as %s — %d points (softcore)" % [
		str(user.get("display_name", RA.config.username)),
		int(user.get("score_softcore", 0)),
	]

	var game := RA.game_info()
	if not game.is_empty() and int(game.get("num_achievements", 0)) > 0:
		line += "\n%s — %d of %d unlocked" % [
			str(game.get("title", "")),
			int(game.get("num_unlocked", 0)),
			int(game.get("num_achievements", 0)),
		]
	# Refresh the token field: a password sign-in has just produced one, and this
	# is the value the player would need to sign in on another device.
	if is_instance_valid(_ra_token_edit) and _ra_token_edit.text != RA.config.token:
		_ra_token_edit.text = RA.config.token

	_ra_status_label.text = line
