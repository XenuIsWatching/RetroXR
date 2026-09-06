## SpawnMenu2D — 2D Control rendered inside a SubViewport on the VR spawn panel.
## Builds its own UI programmatically so no extra tscn layout work is needed.
## Emits spawn_requested(type) when a spawn button is pressed,
## and close_requested when the ✕ button is pressed.
class_name SpawnMenu2D
extends Control

## Scale factor applied to the entire UI.  Increase this when viewport_size
## is higher than the logical design resolution so content stays the same
## apparent physical size in VR.  Default 2.0 matches viewport_size 2200×1800
## against the 1100×900 design resolution.
@export var ui_scale: float = 2.0

signal close_requested
## Emitted when the user changes a default core in the Manager tab.
signal default_core_changed(systemid: String, core_name: String)
## Emitted when the user clicks a ROM in the Cartridges tab.
signal spawn_cartridge_requested(rom_path: String, game_label: String, systemid: String)

## Emitted when the user clicks a room card that maps directly to a scene (e.g. passthrough).
signal scene_change_requested(scene_id: String)
## Every slot signal names its ROOM as well as its slot: each room keeps its own
## set, and the grid on screen is not always the room the player is standing in.
## Emitted when the user clicks Load on a state card.
signal scene_slot_load_requested(slot_id: String, room_id: String)
## Emitted when the user clicks Save on a state card (overwrite).
signal scene_slot_save_requested(slot_id: String, room_id: String)
## Emitted when the user clicks Delete on a state card.
signal scene_slot_delete_requested(slot_id: String, room_id: String)
## Emitted when the user clicks "Save New".
signal scene_slot_create_requested(room_id: String)
## Emitted when the user confirms a rename via the inline LineEdit.
signal scene_slot_rename_requested(slot_id: String, new_name: String, room_id: String)

## Emitted when the user saves controller bindings (global or per-system).
signal controller_bindings_changed
## Emitted when the user clicks a desktop rebind button. spawn_menu_controller
## captures the next key/mouse press and calls back on_rebind_complete().
signal rebind_started(action_name: String)
## Emitted when the user clicks a GAME CONTROLLER rebind button.
## spawn_menu_controller captures the next joypad press and calls back
## on_pad_rebind_complete().
signal pad_rebind_started(target: String)

## Shared core info database — populated on _ready, used by Download & Manager tabs.
var core_db: CoreInfoDatabase = null

## Download manager — added as a child so HTTPRequest nodes work correctly.
var download_manager: CoreDownloadManager = null

## Core defaults persistence (core_defaults.json).
var core_defaults: CoreDefaults = null

## Scraper infrastructure
var gamelist_manager: GamelistManager = null
var scraper_client: ScreenscraperClient = null
var scraper_config: ScraperConfig = null
## Scrapes a ROM that arrived without anyone browsing for it -- a RomM download,
## or a file matched by hash to join a session.
var auto_scraper: AutoScraper = null

## Web file server (HTTP file manager accessible from a PC browser).
var web_server: WebFileServer = null

## RomM server integration (remote ROM library + cover art).
var romm_config: RommConfig = null
var romm_client: RommClient = null
var romm_catalog: RommCatalog = null
var romm_downloader: RommDownloader = null
var romm_cache: RommCacheManifest = null
var romm_art: RommArtCache = null
## ScreenScraper art (wheel/label/box), decoded off the main thread. Sibling of
## romm_art; needs no config, so it is built with no setup call.
var scraped_art: ScrapedArtCache = null
var romm_firmware: RommFirmware = null
## systemid -> platform dict from /api/platforms (with "systemid" added).
## Slug signature of the last unmapped set announced, so it is reported once.
## Terminal outcomes that happened while the menu was closed, flushed on open.
## Merged local+server row model for the open Cartridges detail page.
## Each entry: {source: "local"|"server"|"both", entry: Dictionary, path, label}
## "all" | "downloaded" | "server" | "local", and a region name or "" for any.
## rom_id -> percent, so a recycled row can show live progress when it scrolls
## back into view mid-download.
## Row index of the in-flight download, resolved once when it starts.
## local_path -> {game, manual_path, has_manual}; binding hits the disk otherwise.
## Row index whose delete button is armed for its second confirming tap.
## Remaining systemids for an explicit "Sync all now".
## "<systemid>/<filename>" -> Texture2D or null.
## Wheel logos are scaled into this box so they cannot inflate the row height.

# ── UI state ──────────────────────────────────────────────────────────────────
var _spawn_view:    SpawnMenuSpawnView = null
var _cores_view:    SpawnMenuCoresView = null
var _controls_view: SpawnMenuControlsView = null
var _options_view:  SpawnMenuOptionsView = null
# Extracted into their own files — see Scripts/UI/spawn_menu/views/. Each owns
# its widgets and its state; this class only shows and hides them.
var _graphics_view: SpawnMenuGraphicsView = null
var _scene_view:    SpawnMenuSceneView = null
var _net_view:      SpawnMenuNetView = null
var _about_view:    SpawnMenuAboutView = null

## The views, for a caller that wants to hear one of them directly.
##
## SpawnMenuController used to reach every view signal through a matching signal
## re-declared on this class and re-emitted by a relay lambda: three
## declarations and two hops for one event. It connects to the view now, and
## this class declares only what it originates itself.
##
## Safe to hold: _build_ui runs once from _ready and no view is ever rebuilt, so
## a connection made after the menu exists stays good for the session.
func spawn_view() -> SpawnMenuSpawnView:
	return _spawn_view


func options_view() -> SpawnMenuOptionsView:
	return _options_view


func scene_view() -> SpawnMenuSceneView:
	return _scene_view


func controls_view() -> SpawnMenuControlsView:
	return _controls_view


var _nav_net_btn:      Button = null
var _nav_spawn_btn:    Button = null
var _nav_cores_btn:    Button = null
var _nav_controls_btn: Button = null
var _nav_options_btn:  Button = null
var _nav_graphics_btn: Button = null
var _nav_scene_btn:    Button = null
var _nav_about_btn:    Button = null
var _nav_buttons: Array[Button] = []

# Cores > Download tab state
# core_name -> { "button": Button, "bar": ProgressBar }
# Drill-down browser + fetched cores grouped by systemid ("__other__" = unknown):
#   sid -> Array[{ "core_name", "remote_date", "info" }]
# Outer Download/Manager TabContainer of the Cores view.

# The ScrollContainer currently in view
var _active_scroll:        ScrollContainer = null

# Spawn view tab ScrollContainers (indexed by tab index)

# Cores > Manager tab state — drill-down browser + installed cores grouped by
# systemid: sid -> Array[{ "core_name", "display_name" }]

## BIOS / Extras tab. `_bios_row_cache` is per-rebuild: the home grid and the
## detail page both need a system's resolved rows, and re-deriving them means
## re-stat'ing (and possibly re-hashing) every declared file.
## job key -> the Button that started it, so progress can be shown in place.
## Rebuilt pages drop their buttons, so entries are validity-checked on use.

## Typing is bursty; one rebuild after the keys stop instead of one per key.
## systemid -> {lowercase basename: rom}. A directory listing, so it is cached
## and dropped whenever something writes to a ROM dir.

# Spawn > Systems tab — drill-down browser, one title card per system
# Spawn > Cartridges tab — drill-down browser, one tile per system
# Spawn > Books tab — rebuilt each time the tab is opened
# Spawn > Videos tab — rebuilt each time the tab is opened

# Scrape popup overlay
## Status bars along the bottom: scrape/notice state, and one toast per
## in-flight download or sync. Owns its own 3D quad — see MenuToasts.
var _toasts: MenuToasts = null
# Game detail side panel
# ROM variants side panel
# Callback connected to scraper_client.media_download_completed so the tab
# refreshes when a wheel image or manual PDF finishes downloading.


func _ready() -> void:
	SpawnMenuGraphicsView.restore_window_state()
	_init_core_db()
	_init_core_defaults()
	_init_download_manager()
	_init_scraper()
	_init_web_server()
	_init_romm()
	# Always ensure the roms root exists, plus dirs for any already-configured systems
	print("[SpawnMenu] roms root=", RomLibrary.default_roms_root())
	RomLibrary.ensure_roms_root()
	for sid: String in core_defaults.all_defaults():
		RomLibrary.ensure_rom_dir(sid)
	RomLibrary.ensure_books_root()
	RomLibrary.ensure_videos_root()
	RomLibrary.ensure_dvd_root()
	RomLibrary.ensure_music_root()
	RomLibrary.ensure_posters_root()
	_build_ui()


func _init_core_db() -> void:
	core_db = CoreInfoDatabase.new()
	core_db.load_from_project()


func _init_core_defaults() -> void:
	core_defaults = CoreDefaults.new()
	core_defaults.setup(CoreDefaults.default_path())


func _init_download_manager() -> void:
	download_manager = CoreDownloadManager.new()
	download_manager.name = "CoreDownloadManager"
	add_child(download_manager)


func _init_scraper() -> void:
	scraper_config = ScraperConfig.new()
	scraper_config.load_config()
	gamelist_manager = GamelistManager.new()
	scraper_client = ScreenscraperClient.new()
	scraper_client.name = "ScreenscraperClient"
	scraper_client.config = scraper_config
	add_child(scraper_client)
	scraper_client.scrape_status.connect(_update_scrape_status)
	scraper_client.media_download_started.connect(_on_media_download_started)
	scraper_client.media_download_completed.connect(_on_media_download_notice)
	scraper_client.media_download_failed.connect(_on_media_download_notice_failed)

	# Auto-scraping gets its OWN ScreenscraperClient rather than sharing the one
	# above. The signals are the reason: scrape_completed carries a result and
	# not the request it answers, so a manual scrape finishing while the queue
	# was working would be consumed as the queue's own. Two clients cost one
	# node; the account's rate limit is shared either way, and each client
	# serialises its own requests.
	var auto_client := ScreenscraperClient.new()
	auto_client.name = "AutoScrapeClient"
	auto_client.config = scraper_config
	add_child(auto_client)
	auto_scraper = AutoScraper.new()
	auto_scraper.name = "AutoScraper"
	add_child(auto_scraper)
	auto_scraper.setup(auto_client, gamelist_manager, scraper_config)


## RomM: config + client + catalog + downloader + art cache, all wired to the
## toast stack. Nothing here touches the network at startup — the heaviest thing
## that ever runs on launch is one /api/stats ping, and only once the user opens
## the menu with a configured server.
func _init_romm() -> void:
	romm_config = RommConfig.new()
	romm_config.load_config()

	romm_client = RommClient.new()
	romm_client.name = "RommClient"
	romm_client.setup(romm_config)
	add_child(romm_client)

	romm_cache = RommCacheManifest.new()
	romm_cache.load_manifest()

	romm_catalog = RommCatalog.new()
	romm_catalog.name = "RommCatalog"
	romm_catalog.setup(romm_config)
	add_child(romm_catalog)

	romm_downloader = RommDownloader.new()
	romm_downloader.name = "RommDownloader"
	romm_downloader.setup(romm_config, romm_cache)
	add_child(romm_downloader)

	romm_art = RommArtCache.new()
	romm_art.name = "RommArtCache"
	romm_art.setup(romm_config.base_url)
	add_child(romm_art)

	scraped_art = ScrapedArtCache.new()
	scraped_art.name = "ScrapedArtCache"
	add_child(scraped_art)

	romm_firmware = RommFirmware.new()
	romm_firmware.name = "RommFirmware"
	romm_firmware.setup(romm_config)
	add_child(romm_firmware)
	# Redraw once the list lands: rows built before it arrives carry no cloud
	# button, and the tab should not block on a request to show what is on disk.
	# A failure must NOT redraw: the rebuild asks for the listing again, and the
	# toast is keyed so a server that stays down updates one bar in place.
	romm_firmware.listed.connect(func(ok: bool, _n: int, error: String) -> void:
		if not ok:
			notify("romm:firmware", "⚠️", "BIOS List: %s" % error,
				-1.0, MenuToasts.DWELL_FAIL)
			return
		# Takes down Re-check's sticky "Checking RomM…"; a no-op when the listing
		# was the automatic one, which raises nothing.
		notify_clear("romm:firmware")
		if _cores_view != null and _cores_view.showing_bios_tab():
			_cores_view.refresh_bios_view()
	)


func _init_web_server() -> void:
	if OS.get_name() != "Android":
		return
	web_server = WebFileServer.new()
	web_server.name = "WebFileServer"
	web_server.pin = scraper_config.ensure_web_server_pin()
	add_child(web_server)
	if scraper_config.web_server_enabled:
		web_server.start()


# ── Top-level UI ──────────────────────────────────────────────────────────────

func _build_ui() -> void:
	# Scale the entire UI so it fills the same apparent physical area regardless
	# of viewport_size.  pivot_offset keeps scaling centred on the panel.
	scale = Vector2(ui_scale, ui_scale)
	anchor_right  = 1.0 / ui_scale
	anchor_bottom = 1.0 / ui_scale

	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := StyleBoxFlat.new()
	bg.bg_color = MenuStyle.COLOR_BG
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		bg.set(k, 10)
	panel.add_theme_stylebox_override("panel", bg)
	add_child(panel)

	var margin := MarginContainer.new()
	for side in ["margin_top","margin_bottom","margin_left","margin_right"]:
		margin.add_theme_constant_override(side, 14)
	panel.add_child(margin)

	var root_vbox := VBoxContainer.new()
	root_vbox.add_theme_constant_override("separation", 8)
	margin.add_child(root_vbox)

	MenuStyle.close_button(MenuStyle.title_row(root_vbox, "RETROXR MENU", 28),
		func() -> void: close_requested.emit(), true, 0.0, 24)

	root_vbox.add_child(HSeparator.new())

	# Top nav bar
	var nav_bar := HBoxContainer.new()
	nav_bar.add_theme_constant_override("separation", 6)
	root_vbox.add_child(nav_bar)
	_nav_spawn_btn    = _make_nav_button("SPAWN")
	_nav_cores_btn    = _make_nav_button("CORES")
	_nav_controls_btn = _make_nav_button("CONTROLS")
	_nav_options_btn  = _make_nav_button("OPTIONS")
	_nav_graphics_btn = _make_nav_button("GRAPHICS")
	_nav_scene_btn    = _make_nav_button("SCENE")
	_nav_net_btn      = _make_nav_button("NET")
	_nav_about_btn    = _make_nav_button("ABOUT")
	_nav_spawn_btn.pressed.connect(_show_spawn_view)
	_nav_cores_btn.pressed.connect(_show_cores_view)
	_nav_controls_btn.pressed.connect(_show_controls_view)
	_nav_options_btn.pressed.connect(_show_options_view)
	_nav_graphics_btn.pressed.connect(_show_graphics_view)
	_nav_scene_btn.pressed.connect(_show_scene_view)
	_nav_net_btn.pressed.connect(_show_net_view)
	_nav_about_btn.pressed.connect(_show_about_view)
	_nav_buttons = [_nav_spawn_btn, _nav_cores_btn, _nav_controls_btn, _nav_options_btn,
		_nav_graphics_btn, _nav_scene_btn, _nav_net_btn, _nav_about_btn]
	for btn in _nav_buttons:
		nav_bar.add_child(btn)

	root_vbox.add_child(HSeparator.new())

	# Content area — holds spawn_view, cores_view, and options_view
	var content := Control.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	root_vbox.add_child(content)

	_spawn_view = SpawnMenuSpawnView.create(self)
	_spawn_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_spawn_view.spawn_cartridge_requested.connect(
		func(p: String, l: String, sid: String) -> void:
			spawn_cartridge_requested.emit(p, l, sid))
	_spawn_view.default_core_changed.connect(
		func(sid: String, cn: String) -> void: default_core_changed.emit(sid, cn))
	_spawn_view.scroll_changed.connect(func(sc: ScrollContainer) -> void:
		if _spawn_view.visible:
			_active_scroll = sc)
	# A finished sync moves the OPTIONS readout, whichever tab is on screen.
	_spawn_view.romm_state_changed.connect(func() -> void:
		if _options_view:
			_options_view.update_romm_status_label()
			_options_view.pump_romm_sync_queue())
	content.add_child(_spawn_view)

	_cores_view = SpawnMenuCoresView.create(self)
	_cores_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_cores_view.scroll_changed.connect(func(s: ScrollContainer) -> void:
		if _cores_view.visible:
			_active_scroll = s)
	# Downloading a core in the Cores view makes a system playable, so the spawn
	# view's Systems and Cartridges grids both have a new tile to show. SpawnView
	# rebuilds them from ITS OWN default_core_changed, which nothing else emits —
	# so relaying this only outward left both grids stale. Cartridges appeared to
	# work because the tab-switch handler happens to repopulate it; Systems has no
	# such case and so never refreshed at all.
	_cores_view.default_core_changed.connect(
		func(sid: String, cn: String) -> void:
			if is_instance_valid(_spawn_view):
				_spawn_view.refresh_after_core_change()
			default_core_changed.emit(sid, cn))
	content.add_child(_cores_view)

	_controls_view = SpawnMenuControlsView.create(core_defaults, core_db)
	_controls_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_controls_view.rebind_started.connect(
		func(action: String) -> void: rebind_started.emit(action))
	_controls_view.pad_rebind_started.connect(
		func(target: String) -> void: pad_rebind_started.emit(target))
	_controls_view.controller_bindings_changed.connect(
		func() -> void: controller_bindings_changed.emit())
	# The tab is built once and never rebuilt on a switch, so the per-platform
	# grid has to be told when a system gains a default core. Connected to the
	# menu-level signal, which both the CORES and SPAWN paths already emit.
	default_core_changed.connect(
		func(_sid: String, _cn: String) -> void:
			if is_instance_valid(_controls_view):
				_controls_view.refresh_platforms())
	content.add_child(_controls_view)

	_options_view = SpawnMenuOptionsView.create(self)
	_options_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_options_view.system_filter_changed.connect(_cores_view.refresh_download_systems)
	_options_view.romm_platforms_requested.connect(_spawn_view.romm_fetch_platforms)
	_options_view.scroll_changed.connect(func(s: ScrollContainer) -> void:
		if _options_view.visible:
			_active_scroll = s)
	content.add_child(_options_view)

	_graphics_view = SpawnMenuGraphicsView.create(_is_vr_mode())
	_graphics_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_graphics_view)

	_scene_view = SpawnMenuSceneView.create()
	_scene_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Relayed rather than re-declared, so the controller's wiring is unchanged.
	_scene_view.scene_change_requested.connect(
		func(id: String) -> void: scene_change_requested.emit(id))
	_scene_view.slot_load_requested.connect(
		func(id: String, room: String) -> void: scene_slot_load_requested.emit(id, room))
	_scene_view.slot_save_requested.connect(
		func(id: String, room: String) -> void: scene_slot_save_requested.emit(id, room))
	_scene_view.slot_delete_requested.connect(
		func(id: String, room: String) -> void: scene_slot_delete_requested.emit(id, room))
	_scene_view.slot_create_requested.connect(
		func(room: String) -> void: scene_slot_create_requested.emit(room))
	_scene_view.slot_rename_requested.connect(
		func(id: String, n: String, room: String) -> void:
			scene_slot_rename_requested.emit(id, n, room))
	_scene_view.scroll_changed.connect(func(s: ScrollContainer) -> void:
		if _scene_view.visible:
			_active_scroll = s)
	content.add_child(_scene_view)

	_net_view = SpawnMenuNetView.create(self)
	_net_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_net_view)
	_net_view.scroll_changed.connect(func(sc: ScrollContainer) -> void:
		if _net_view.visible:
			_active_scroll = sc)

	_about_view = SpawnMenuAboutView.create()
	_about_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	content.add_child(_about_view)

	# Over the views, not inside one: a download raised on the SPAWN tab must stay
	# up when the player switches to CORES.
	_toasts = MenuToasts.create()
	add_child(_toasts)

	_show_spawn_view()


func _is_vr_mode() -> bool:
	return MenuStyle.is_vr_mode()


func _make_nav_button(lbl: String) -> Button:
	var btn := Button.new()
	btn.text = lbl
	btn.add_theme_font_size_override("font_size", 22)
	btn.custom_minimum_size = Vector2(0, 52)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return btn


func _show_view(view: Control, scroll: ScrollContainer, nav_btn: Button) -> void:
	for v: Control in [_spawn_view, _cores_view, _controls_view, _options_view, _graphics_view, _scene_view, _net_view, _about_view]:
		v.visible = v == view
	_active_scroll = scroll
	_set_nav_active(nav_btn)


func _show_spawn_view() -> void:
	_show_view(_spawn_view, null, _nav_spawn_btn)
	_spawn_view.refresh_active_scroll()


func _show_cores_view() -> void:
	_show_view(_cores_view, null, _nav_cores_btn)
	_active_scroll = _cores_view.active_scroll()
	_cores_view.ensure_fetched()


func _show_controls_view() -> void:
	_show_view(_controls_view, _controls_view, _nav_controls_btn)
	# A platform can gain or lose an override from anywhere the tab is not
	# looking, and the badges are painted from the store.
	_controls_view.refresh_platforms()


func _show_options_view() -> void:
	# The view is a tab host now, not a scroll — the live scroll is whichever
	# sub-tab is showing, exactly as the CORES view works.
	_show_view(_options_view, null, _nav_options_btn)
	_active_scroll = _options_view.active_scroll()


func _show_graphics_view() -> void:
	_show_view(_graphics_view, _graphics_view, _nav_graphics_btn)


func _show_scene_view() -> void:
	_show_view(_scene_view, null, _nav_scene_btn)
	# The view owns which of its two panels is up, and reports the scroll back
	# through scroll_changed — including when its own Back button switches them.
	_scene_view.show_rooms()


func _show_about_view() -> void:
	_show_view(_about_view, _about_view, _nav_about_btn)


func _show_net_view() -> void:
	# The view is no longer its own ScrollContainer — it hosts sub-tabs, so the
	# scroll the thumbstick drives is whichever one is showing.
	_show_view(_net_view, _net_view.active_scroll(), _nav_net_btn)
	_net_view.refresh()


## The RomM platform map and the systems RomM reports that we cannot map. Owned
## here because both the OPTIONS tab and the cartridge browser read them.
func romm_platforms() -> Dictionary:
	return _spawn_view.romm_platforms() if _spawn_view else {}


func romm_unmapped() -> Array:
	return _spawn_view.romm_unmapped() if _spawn_view else []


## Driven by the controller's _show_menu/_hide_menu — this Control is always
## visible, it is the Viewport2Din3D node in the world that gets toggled.
func on_menu_shown() -> void:
	if _spawn_view:
		_spawn_view.on_menu_shown()
	# Deferred so it lands after the menu has finished appearing rather than in
	# the same frame: the first dropdown opened otherwise pays for instancing
	# its quad, SubViewport and option scene right when it is tapped.
	_prewarm_dropdowns.call_deferred()


func on_menu_hidden() -> void:
	if _spawn_view:
		_spawn_view.on_menu_hidden()


## Every VRDropdown currently in the menu builds its popout now. Cheap after the
## first time — each one guards on already having built it.
func _prewarm_dropdowns() -> void:
	for d: Node in _find_dropdowns(self):
		d.call("prewarm")


func _find_dropdowns(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for c: Node in node.get_children():
		if c is VRDropdown:
			out.append(c)
		out.append_array(_find_dropdowns(c))
	return out


# ── Notifications ─────────────────────────────────────────────────────────────
# Thin forwarders onto MenuToasts. Public because background services (RomM
# sync and downloads, cache eviction) and the controller all raise notices
# through the menu rather than reaching for the stack themselves.

func notify(key: String, icon_text: String, msg: String,
			progress: float = -1.0, seconds: float = 0.0) -> void:
	if _toasts:
		_toasts.notify(key, icon_text, msg, progress, seconds)


func notify_clear(key: String) -> void:
	if _toasts:
		_toasts.clear(key)


## Forwarded onto the OPTIONS tab, which owns the one sync queue.
func queue_romm_sync(systemids: Array, full: bool) -> void:
	if _options_view:
		_options_view.queue_romm_sync(systemids, full)


func show_notice(msg: String, seconds := 2.5) -> void:
	if _toasts:
		_toasts.notice(msg, seconds)


func show_scrape_status(msg: String) -> void:
	if _toasts:
		_toasts.status(msg)


func _update_scrape_status(msg: String) -> void:
	if _toasts:
		_toasts.status_update(msg)


func hide_scrape_status() -> void:
	if _toasts:
		_toasts.status_clear()


func _on_media_download_started(media_type: String) -> void:
	notify(media_type, "⏳", "Downloading %s…" % media_type.capitalize())


func _on_media_download_notice(media_type: String, _path: String) -> void:
	if _toasts:
		_toasts.finish(media_type, "✅", "%s downloaded" % media_type.capitalize())


func _on_media_download_notice_failed(media_type: String, _error: String) -> void:
	if _toasts:
		_toasts.finish(media_type, "❌", "%s failed" % media_type.capitalize())


## Answers to rebind_started / pad_rebind_started. The capture happens in
## spawn_menu_controller, where raw input arrives; these hand the result to the
## view that asked. `event` is null, and `binding` "", when the user cancelled.
func on_rebind_complete(action: String, event: InputEvent) -> void:
	if _controls_view:
		_controls_view.on_rebind_complete(action, event)


func on_pad_rebind_complete(target: String, binding: String) -> void:
	if _controls_view:
		_controls_view.on_pad_rebind_complete(target, binding)


## The arcade's save slots, repainted after the controller has actually saved,
## loaded or deleted one. Public because that lands on SceneManager rather than
## in the menu, so nothing here knows it happened.
func rebuild_states_grid() -> void:
	if _scene_view:
		_scene_view.rebuild_states_grid()


func _set_nav_active(active: Button) -> void:
	for btn: Button in _nav_buttons:
		var is_active := (btn == active)
		var s := StyleBoxFlat.new()
		s.bg_color = MenuStyle.COLOR_NAV_ACTIVE if is_active else MenuStyle.COLOR_NAV_INACTIVE
		for k in ["corner_radius_top_left","corner_radius_top_right",
				  "corner_radius_bottom_left","corner_radius_bottom_right"]:
			s.set(k, 6)
		for state in ["normal", "hover", "pressed"]:
			btn.add_theme_stylebox_override(state, s)


## Called by SpawnMenuController each frame while trigger is held.
## pixels > 0 scrolls down, < 0 scrolls up.
func scroll_active(pixels: float) -> void:
	if _active_scroll:
		_active_scroll.scroll_vertical += int(pixels)
