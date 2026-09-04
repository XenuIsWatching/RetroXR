## SpawnMenuSpawnView — the menu's SPAWN tab, and everything that feeds it.
##
## Ten sub-tabs of things the player can pull into the room: systems, cartridges,
## TVs, books, videos, DVDs, CDs, tapes, objects, controllers. Each one asks for
## a spawn by signal and the menu relays it out to the controller.
##
## Three subsystems live here rather than beside it, because all three exist to
## keep this list right:
##
##  * the virtualized ROM row list — a few recycled rows over a list of
##    thousands, so scrolling a big platform does not allocate;
##  * the ScreenScraper client's UI — hashing a ROM, showing what came back,
##    and the game-detail and ROM-variants panels built from it;
##  * the RomM handlers — sync, download, cache. They read as notification code
##    but every one of them ends by rebuilding a row, a list or an index here.
class_name SpawnMenuSpawnView
extends Control

signal spawn_requested(type: String)
signal spawn_cartridge_requested(rom_path: String, game_label: String, systemid: String)
signal spawn_manual_requested(pdf_path: String)
signal spawn_poster_requested(image_path: String)
signal spawn_video_requested(video_path: String)
signal spawn_dvd_requested(dvd_path: String)
signal spawn_cd_requested(album_path: String)
signal spawn_cassette_requested(album_path: String)
signal spawn_record_requested(album_path: String)
signal default_core_changed(systemid: String, core_name: String)
## Which scroll the thumbstick should drive — the sub-tabs each own one, and the
## two grid browsers own one per page.
signal scroll_changed(scroll: ScrollContainer)
## A RomM sync or download changed something the OPTIONS readout shows.
signal romm_state_changed

const WHEEL_BOX := Vector2i(300, 76)
## Poster row thumbnails. Bounded for the same reason WHEEL_BOX is: an unbounded
## Button.icon with expand_icon draws far past its row and spills into the
## neighbours.
const POSTER_THUMB_BOX := Vector2i(96, 72)
const MAX_POSTER_THUMBS := 200
## Typing in the ROM filter rebuilds the list; this waits for a pause first.
const SEARCH_DEBOUNCE_SEC := 0.18

## Applied to a whole row rather than its label: a server-only title with the
## server down has no working control on it, and dimming only the icon reads as
## decoration rather than as "none of this does anything".
const UNREACHABLE_DIM := Color(1.0, 1.0, 1.0, 0.45)

var core_db: CoreInfoDatabase = null
var core_defaults: CoreDefaults = null
var gamelist_manager: GamelistManager = null
var scraper_client: ScreenscraperClient = null
var romm_config: RommConfig = null
var romm_client: RommClient = null
var romm_catalog: RommCatalog = null
var romm_downloader: RommDownloader = null
var romm_cache: RommCacheManifest = null
var romm_art: RommArtCache = null
## The same treatment for ScreenScraper art. Built here rather than injected:
## it needs no config, unlike romm_art which needs the server URL.
var scraped_art: ScrapedArtCache = null

## The menu, for raising notices. Typed Node so the classes do not name each
## other — same reason as SpawnMenuOptionsView.
var _menu: Node = null

## Mirrors _active_scroll on the menu; assigning it emits scroll_changed, so the
## many places below that just set it keep reading the way they did.
var _active_scroll: ScrollContainer = null:
	set(value):
		_active_scroll = value
		scroll_changed.emit(value)

# ── RomM state ────────────────────────────────────────────────────────────────
## systemid -> platform dict from /api/platforms (with "systemid" added).
var _romm_platforms: Dictionary = {}
var _romm_unmapped: Array = []
## Slug signature of the last unmapped set announced, so it is reported once.
var _romm_unmapped_announced: String = ""
## Terminal outcomes that happened while the menu was closed, flushed on open.
var _romm_pending_notices: Array[Dictionary] = []
## Merged local+server row model for the open Cartridges detail page.
## Each entry: {source: "local"|"server"|"both", entry: Dictionary, path, label}
var _romm_rows: Array[Dictionary] = []
var _romm_detail_systemid: String = ""
var _romm_detail_exts: Array[String] = []
var _romm_filter: String = ""
## "all" | "downloaded" | "server" | "local", and a region name or "" for any.
var _romm_source_filter: String = "all"
var _romm_region_filter: String = ""
var _romm_region_drop: VRDropdown = null
var _romm_region_options: Array[String] = []
var _romm_list: VirtualRowList = null
var _romm_empty_label: Label = null
## The toolbar's RETRY button, which doubles as this platform's stop button
## while it is the one syncing.
var _romm_resync_btn: Button = null
## rom_id -> percent, so a recycled row can show live progress when it scrolls
## back into view mid-download.
var _romm_progress_pct: Dictionary = {}
## rom_id -> game name, remembered from the start of the download. Only the
## started signal carries it, and looking it up again per tick would mean a
## catalog scan thousands of times over one ROM — the same reason the row index
## below is resolved once.
var _romm_dl_labels: Dictionary = {}
## rom_id -> which attempt is running, 0 for the first. Shown on the progress bar
## so a transfer that silently started over is visible as one.
var _romm_dl_attempt: Dictionary = {}
## Row index of the in-flight download, resolved once when it starts.
var _romm_dl_row_index: int = -1
## local_path -> {game, manual_path, has_manual}; binding hits the disk otherwise.
var _romm_meta_cache: Dictionary = {}
## Row index whose delete button is armed for its second confirming tap.
var _romm_delete_armed: int = -1
## Typing is bursty; one rebuild after the keys stop instead of one per key.
var _romm_search_timer: Timer = null
## Poster thumbnails, memoized with misses — most entries have no thumbnail.
var _poster_thumb_cache: Dictionary = {}
var _poster_thumb_order: Array[String] = []
## systemid -> {lowercase basename: rom}. A directory listing, so it is cached
## and dropped whenever something writes to a ROM dir.
var _local_scan_cache: Dictionary = {}

# ── Tabs ──────────────────────────────────────────────────────────────────────
## Per-tab ScrollContainers, indexed by tab index. Systems and Cartridges own
## their own scroll inside a SystemGridBrowser, so their slot is null.
var _spawn_tab_scrolls: Array[ScrollContainer] = []
var _spawn_tabs: TabContainer = null
var _systems_browser: SystemGridBrowser = null
var _cartridges_browser: SystemGridBrowser = null
## Held because its tail is one row per connected gamepad, rebuilt whenever a pad
## is paired or unpaired.
var _controllers_vbox: VBoxContainer = null
var _books_vbox: VBoxContainer = null
var _videos_vbox: VBoxContainer = null
var _dvds_vbox: VBoxContainer = null
var _cds_vbox: VBoxContainer = null
var _tapes_vbox: VBoxContainer = null
var _records_vbox: VBoxContainer = null
var _posters_vbox: VBoxContainer = null

# ── Scraper / detail panels ───────────────────────────────────────────────────
var _scrape_popup: PanelContainer = null
var _scrape_in_progress: bool = false
var _game_detail_panel: PanelContainer = null
var _rom_variants_panel: PanelContainer = null
## The saves-and-achievements page for one ROM, and the CartridgeOptionsPanel
## driving it — both live only as long as the page is open.
var _game_saves_panel: PanelContainer = null
var _game_saves_driver: CartridgeOptionsPanel = null
var _pack_contents_panel: PanelContainer = null
## Connected to scraper_client.media_download_completed so the tab refreshes
## when a wheel image or manual PDF finishes downloading.
var _media_dl_refresh_cb: Callable = Callable()

## Driven by the menu, which hears it from the controller — this Control is
## always visible, it is the Viewport2Din3D in the world that gets toggled.
var _menu_shown: bool = false

static func create(menu: Node) -> SpawnMenuSpawnView:
	var v := SpawnMenuSpawnView.new()
	v._menu = menu
	v.core_db          = menu.core_db
	v.core_defaults    = menu.core_defaults
	v.gamelist_manager = menu.gamelist_manager
	v.scraper_client   = menu.scraper_client
	v.romm_config      = menu.romm_config
	v.romm_client      = menu.romm_client
	v.romm_catalog     = menu.romm_catalog
	v.romm_downloader  = menu.romm_downloader
	v.romm_cache       = menu.romm_cache
	v.romm_art         = menu.romm_art
	v.scraped_art      = menu.scraped_art
	v._connect_romm()
	v._build()
	return v


## The RomM services are the menu's, but every one of these handlers ends by
## rebuilding a row, a list or an index in this view — so the wiring lives here.
func _connect_romm() -> void:
	romm_client.auth_failed.connect(_on_romm_auth_failed)
	romm_client.reachability_changed.connect(_on_romm_reachability_changed)
	romm_cache.changed.connect(_on_romm_cache_changed)
	romm_catalog.sync_started.connect(_on_romm_sync_started)
	romm_catalog.sync_progress.connect(_on_romm_sync_progress)
	romm_catalog.sync_finished.connect(_on_romm_sync_finished)
	romm_catalog.sync_aborted.connect(_on_romm_sync_aborted)
	# The warm thread works out a platform's shown count after the grid is
	# already up, so the tile it belongs to has to be redrawn.
	romm_catalog.index_stats_ready.connect(func(_sid: String) -> void:
		_populate_cartridges_tab()
	)
	romm_downloader.download_started.connect(_on_romm_dl_started)
	romm_downloader.download_progress.connect(_on_romm_dl_progress)
	romm_downloader.download_retrying.connect(_on_romm_dl_retrying)
	romm_downloader.download_finished.connect(_on_romm_dl_finished)
	romm_downloader.download_cancelled.connect(_on_romm_dl_cancelled)
	romm_downloader.cache_evicted.connect(_on_romm_cache_evicted)
	romm_art.art_ready.connect(_on_romm_art_ready)
	if scraped_art != null:
		scraped_art.art_ready.connect(_on_scraped_art_ready)
	# Show last run's platforms immediately; a refresh only corrects it.
	for sid: String in romm_config.cached_platforms:
		var p: Variant = romm_config.cached_platforms[sid]
		if p is Dictionary:
			_romm_platforms[sid] = p


## Read by the OPTIONS tab, which shows what the server holds.
func romm_platforms() -> Dictionary:
	return _romm_platforms


func romm_unmapped() -> Array:
	return _romm_unmapped


## The scroll the visible sub-tab owns, re-reported after a tab switch.
func refresh_active_scroll() -> void:
	_update_spawn_active_scroll(_spawn_tabs.current_tab if _spawn_tabs else 0)


func notify(key: String, icon: String, msg: String,
			progress: float = -1.0, seconds: float = 0.0) -> void:
	if _menu:
		_menu.notify(key, icon, msg, progress, seconds)


func notify_clear(key: String) -> void:
	if _menu:
		_menu.notify_clear(key)


func show_notice(msg: String, seconds := 2.5) -> void:
	if _menu:
		_menu.show_notice(msg, seconds)


func _show_scrape_status(msg: String) -> void:
	if _menu:
		_menu.show_scrape_status(msg)


func _hide_scrape_status() -> void:
	if _menu:
		_menu.hide_scrape_status()

## Systems and Cartridges are SystemGridBrowsers that own their own scroll, and
## their slot in _spawn_tab_scrolls is null; every other tab is a plain
## ScrollContainer at the matching index. Keyed on title rather than position for
## the same reason the populate dispatch is.
func _update_spawn_active_scroll(tab_idx: int) -> void:
	var title := _spawn_tabs.get_tab_title(tab_idx) if _spawn_tabs != null \
		and tab_idx >= 0 and tab_idx < _spawn_tabs.get_tab_count() else ""
	if title == "Systems":
		_update_systems_inner_scroll()
	elif title == "Games":
		_update_cartridges_inner_scroll()
	elif tab_idx >= 0 and tab_idx < _spawn_tab_scrolls.size():
		_active_scroll = _spawn_tab_scrolls[tab_idx]
	else:
		_active_scroll = null


func _update_systems_inner_scroll() -> void:
	if _systems_browser:
		_active_scroll = _systems_browser.get_active_scroll()
	else:
		_active_scroll = null


func _update_cartridges_inner_scroll() -> void:
	if _cartridges_browser:
		_active_scroll = _cartridges_browser.get_active_scroll()
	else:
		_active_scroll = null



func _build() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var tabs := TabContainer.new()
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_spawn_tabs = tabs
	_spawn_tab_scrolls.clear()

	# Systems tab — drill-down browser, one title card per system (like Cores).
	# Opening a system lists its spawnable items (console model(s) + peripherals).
	_systems_browser = SystemGridBrowser.new()
	_systems_browser.name = "Systems"
	_systems_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_systems_browser.empty_text = "No default cores set.\nGo to Cores ▸ Manager to configure systems."
	_systems_browser.allow_hiding = true
	_systems_browser.allow_compact = true
	_systems_browser.set_detail_populator(_populate_systems_detail)
	# The hidden list and the compact switch both serve BOTH grids, so either one
	# changing has to repaint the other or the two disagree until you switch tabs
	# twice.
	_systems_browser.grid_prefs_changed.connect(func() -> void:
		if _cartridges_browser:
			_cartridges_browser.refresh()
	)
	_systems_browser.active_scroll_changed.connect(func(_s: ScrollContainer):
		_update_systems_inner_scroll()
	)
	tabs.add_child(_systems_browser)
	_spawn_tab_scrolls.append(null)  # index 0 handled via _update_systems_inner_scroll
	_populate_systems_tab()

	# Rebuild systems/cartridges lists whenever the user sets/changes a default
	default_core_changed.connect(func(_sid: String, _cn: String): refresh_after_core_change())

	# Cartridges tab — drill-down browser, one tile per system
	_cartridges_browser = SystemGridBrowser.new()
	_cartridges_browser.name = "Games"
	_cartridges_browser.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# These tiles stand for the media, not the machine, so show the cartridge.
	_cartridges_browser.use_content_art = true
	_cartridges_browser.empty_text = "No default cores set.\nGo to Cores ▸ Manager to configure systems."
	_cartridges_browser.allow_hiding = true
	_cartridges_browser.allow_compact = true
	_cartridges_browser.set_detail_populator(_populate_cartridges_detail)
	_cartridges_browser.grid_prefs_changed.connect(func() -> void:
		if _systems_browser:
			_systems_browser.refresh()
	)
	_cartridges_browser.active_scroll_changed.connect(func(_s: ScrollContainer):
		_update_cartridges_inner_scroll()
	)
	tabs.add_child(_cartridges_browser)
	# Its own browser owns the scroll, so this slot stays empty — see
	# _update_spawn_active_scroll.
	_spawn_tab_scrolls.append(null)
	_populate_cartridges_tab()

	# "tv:<shell>" names a cabinet variant, the way "model:<systemid>:<model_id>"
	# names a console's. A future shell costs a row here and nothing else.
	_add_spawn_tab(tabs, "TVs", [["TV", "tv"], ["Plain Monitor", "tv:crt_plain"]])

	# Books tab — lists PDFs from the books root directory
	var books_scroll := ScrollContainer.new()
	books_scroll.name = "Books"
	tabs.add_child(books_scroll)
	_spawn_tab_scrolls.append(books_scroll)
	MenuStyle.fat_vscroll_bar(books_scroll)
	_books_vbox = VBoxContainer.new()
	_books_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_books_vbox.add_theme_constant_override("separation", 10)
	books_scroll.add_child(_books_vbox)
	_populate_books_tab()

	# Videos tab — lists video files from the videos root directory
	var videos_scroll := ScrollContainer.new()
	videos_scroll.name = "Videos"
	tabs.add_child(videos_scroll)
	_spawn_tab_scrolls.append(videos_scroll)
	MenuStyle.fat_vscroll_bar(videos_scroll)
	_videos_vbox = VBoxContainer.new()
	_videos_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_videos_vbox.add_theme_constant_override("separation", 10)
	videos_scroll.add_child(_videos_vbox)
	_populate_videos_tab()

	# DVDs tab — lists DVD images (VIDEO_TS folders / .iso / .img) from the dvd root
	var dvds_scroll := ScrollContainer.new()
	dvds_scroll.name = "DVDs"
	tabs.add_child(dvds_scroll)
	_spawn_tab_scrolls.append(dvds_scroll)
	MenuStyle.fat_vscroll_bar(dvds_scroll)
	_dvds_vbox = VBoxContainer.new()
	_dvds_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_dvds_vbox.add_theme_constant_override("separation", 10)
	dvds_scroll.add_child(_dvds_vbox)
	_populate_dvds_tab()

	# CDs tab — lists music albums (folders of audio files / loose files) from the
	# music root; each spawns an AudioDisc for the CD player.
	var cds_scroll := ScrollContainer.new()
	cds_scroll.name = "CDs"
	tabs.add_child(cds_scroll)
	_spawn_tab_scrolls.append(cds_scroll)
	MenuStyle.fat_vscroll_bar(cds_scroll)
	_cds_vbox = VBoxContainer.new()
	_cds_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cds_vbox.add_theme_constant_override("separation", 10)
	cds_scroll.add_child(_cds_vbox)
	_populate_cds_tab()

	# Tapes tab — same music library, each spawns an AudioCassette for the deck.
	var tapes_scroll := ScrollContainer.new()
	tapes_scroll.name = "Tapes"
	tabs.add_child(tapes_scroll)
	_spawn_tab_scrolls.append(tapes_scroll)
	MenuStyle.fat_vscroll_bar(tapes_scroll)
	_tapes_vbox = VBoxContainer.new()
	_tapes_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tapes_vbox.add_theme_constant_override("separation", 10)
	tapes_scroll.add_child(_tapes_vbox)
	_populate_tapes_tab()

	# Records tab — the same music library again, each row spawning a VinylRecord
	# for the turntable.
	var records_scroll := ScrollContainer.new()
	records_scroll.name = "Records"
	tabs.add_child(records_scroll)
	_spawn_tab_scrolls.append(records_scroll)
	MenuStyle.fat_vscroll_bar(records_scroll)
	_records_vbox = VBoxContainer.new()
	_records_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_records_vbox.add_theme_constant_override("separation", 10)
	records_scroll.add_child(_records_vbox)
	_populate_records_tab()

	# Posters tab — lists images from the posters root directory
	var posters_scroll := ScrollContainer.new()
	posters_scroll.name = "Posters"
	tabs.add_child(posters_scroll)
	_spawn_tab_scrolls.append(posters_scroll)
	MenuStyle.fat_vscroll_bar(posters_scroll)
	_posters_vbox = VBoxContainer.new()
	_posters_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_posters_vbox.add_theme_constant_override("separation", 10)
	posters_scroll.add_child(_posters_vbox)
	_populate_posters_tab()

	_add_spawn_tab(tabs, "Objects", [
		["Table",           "table"],
		["Storage Box",     "trash_can"],
		["VCR",             "vcr_player"],
		["DVD Player",      "dvd_player"],
		["CD Player",       "cd_player"],
		["Cassette Player", "cassette_player"],
		["Record Player",   "record_player"],
		["TV Remote",       "tv_remote"],
		["Composite Cable", "composite_cable"],
		["Mono Composite Cable", "mono_composite_cable"],
		["VGA Cable",       "vga_cable"],
		["3.5 mm Cable",   "trs_cable"],
		["Link Cable",     "link_cable"],
		["GB Link Cable",  "gb_link_cable"],
		["GC-GBA Cable",   "gc_gba_cable"],
		["PS Link Cable",  "psx_link_cable"],
		["Speakers",       "speaker_pair"],
		# Not under Controllers: nobody holds it, and it is no more a controller
		# than the aerial is. It plugs into the Wii and stands on the television.
		["Sensor Bar",     "sensor_bar"],
		# The way a console reached a television before anything had a composite
		# input: phono into the deck, coax into the aerial socket.
		["RF Switch (RXR-003)", "rf_switch"],
	])

	# Mains leads, on their own tab rather than lost among the A/V ones. What
	# picks one is the shape of the socket on the back of the machine, not what
	# the machine is for, and a player hunting the right plug should not have to
	# read past the record player to find it.
	_add_spawn_tab(tabs, "Power", [
		["NEMA 5-15P to C13 Cable", "power_cord"],
		["NEMA 1-15P to C7 Cable", "nema_1_15_to_c7_cord"],
		["Polarized NEMA 1-15P to C7P Cable",
			"nema_1_15_polarized_to_c7_polarized_cord"],
	])

	# Rebuilt at runtime, unlike the other const tabs: its tail is one row per
	# physical gamepad currently connected, which nothing knows at build time.
	_controllers_vbox = _add_spawn_tab(tabs, "Controllers", [])
	_populate_controllers_tab()
	# A pad plugged in or unplugged changes the list while the menu is open.
	Input.joy_connection_changed.connect(
		func(_device: int, _connected: bool) -> void: _populate_controllers_tab())

	# Refresh on tab switch — picks up files added to disk since last open
	# Also update _active_scroll to the current tab's ScrollContainer
	# Dispatched on the tab's title, not its index. These were index compares, and
	# reordering two tabs then meant finding every hardcoded position — four of
	# them, spread over three functions — with nothing to catch a miss but the
	# wrong list quietly refreshing.
	tabs.tab_changed.connect(func(idx: int):
		match tabs.get_tab_title(idx):
			"Systems": _populate_systems_tab()
			"Games": _populate_cartridges_tab()
			"Books": _populate_books_tab()
			"Videos": _populate_videos_tab()
			"DVDs": _populate_dvds_tab()
			"CDs": _populate_cds_tab()
			"Tapes": _populate_tapes_tab()
			"Records": _populate_records_tab()
			"Posters": _populate_posters_tab()
		_update_spawn_active_scroll(idx)
	)

	# The strip and the TabContainer come back in one VBox; it fills this view,
	# which is anchored over the whole content area.
	var wrapped := TabStrip.wrap(tabs)
	wrapped.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(wrapped)


func _clear_vbox(vbox: VBoxContainer) -> void:
	for child in vbox.get_children():
		child.queue_free()
	vbox.add_child(MenuStyle.spacer(10))


## A system gained (or changed) its default core, so both grids keyed off
## CoreDefaults have a tile to add or relabel. The one entry point for that,
## called from this view's own default_core_changed AND by SpawnMenu when the
## Cores view reports a download — the two grids must never refresh
## independently again, which is how Cartridges came to update while Systems
## silently did not.
func refresh_after_core_change() -> void:
	_populate_systems_tab()
	_populate_cartridges_tab()


## Rebuild the Systems home grid: one tile per system that has a default core.
## Spawnable items are listed lazily, only when a system tile is opened.
func _populate_systems_tab() -> void:
	if not _systems_browser:
		return
	var systems: Array = []
	for systemid: String in core_defaults.all_defaults():
		var sysname: String = core_db.get_systemname_for_id(systemid)
		var entry := {"systemid": systemid, "name": sysname}
		var n := SpawnCatalog.items_for(systemid, sysname).size()
		if n > 1:
			entry["badge"] = "%d items" % n
		systems.append(entry)
	_systems_browser.set_systems(systems)
	# If a system detail is open, re-run it so catalog changes appear.
	_systems_browser.refresh()


## Detail page for one system: each spawnable item — the console model(s) plus
## that system's controllers/peripherals. Tap to spawn; the menu stays open so
## several items can be spawned in a row.
func _populate_systems_detail(systemid: String, vbox: VBoxContainer) -> void:
	vbox.add_child(MenuStyle.spacer(4))
	for item: Dictionary in SpawnCatalog.items_for(systemid, core_db.get_systemname_for_id(systemid)):
		var btn := Button.new()
		btn.text = "  +  " + str(item.get("label", "Console"))
		btn.custom_minimum_size = Vector2(0, 80)
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 26)
		var token := SpawnCatalog.spawn_token(systemid, item)
		# A shelf is only offered for a console that actually takes cards — one
		# with no card_family gets the plain row, because browsing another
		# console's cards from it would be a lie about what it can hold.
		var card_fmt := CardFormats.for_system(systemid)
		if token.ends_with("memory_card") and card_fmt != null:
			# This row does one of two different things, so it says which. With
			# cards saved it opens the shelf and drops the +, because every other
			# + on this page puts something in the room on the first press.
			var cards := MemoryCardBrowser.card_count(card_fmt.id())
			if cards > 0:
				btn.text = "     %s      %d card%s" \
					% [str(item.get("label", "Memory Card")), cards, "" if cards == 1 else "s"]
			btn.pressed.connect(
				_on_system_memcard_pressed.bind(systemid, card_fmt.id(), vbox))
		else:
			btn.pressed.connect(spawn_requested.emit.bind(token))
		vbox.add_child(btn)
	vbox.add_child(MenuStyle.spacer(8))


## A console's card shelf, opened from its own page. It takes that page over, so
## Back returns to the console you came from.
##
## Nothing saved yet means there is nothing to choose between, so the row keeps
## its plain behaviour and spawns a blank card.
func _on_system_memcard_pressed(systemid: String, family: String,
		vbox: VBoxContainer) -> void:
	if not MemoryCardBrowser.has_cards(family):
		spawn_requested.emit("%s_memory_card" % family)
		return
	_clear_children(vbox)
	var b := MemoryCardBrowser.new()
	b.family = family
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_constant_override("separation", 10)
	# Deferred: both handlers tear down the browser that is emitting them.
	b.spawn_requested.connect(func(t: String) -> void:
		spawn_requested.emit(t)
		_restore_system_detail.call_deferred(systemid, vbox))
	b.closed.connect(func() -> void:
		_restore_system_detail.call_deferred(systemid, vbox))
	b.notice.connect(show_notice)
	# One Back button for the whole trail: the shelf's pages announce themselves
	# to the console page's header rather than stacking a second one under it.
	b.page_changed.connect(func(title: String, on_back: Callable) -> void:
		if _systems_browser != null:
			_systems_browser.push_subpage(title, on_back))
	vbox.add_child(b)
	b.open()


func _restore_system_detail(systemid: String, vbox: VBoxContainer) -> void:
	if _systems_browser != null:
		_systems_browser.clear_subpage()
	_clear_children(vbox)
	_populate_systems_detail(systemid, vbox)


func _clear_children(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()


## Rebuild the Cartridges home grid: one tile per system that has a default core
## OR a mapped RomM platform. ROMs are scanned/synced lazily, only when a system
## tile is opened — a full library sync at launch would be minutes of transfer
## before the user could do anything.
func _populate_cartridges_tab() -> void:
	if not _cartridges_browser:
		return

	var seen: Dictionary = {}
	var systems: Array = []
	for systemid: String in core_defaults.all_defaults():
		seen[systemid] = true
		systems.append({"systemid": systemid, "name": core_db.get_systemname_for_id(systemid)})

	for systemid: String in _romm_platforms:
		if not seen.has(systemid):
			systems.append({"systemid": systemid, "name": _system_label(systemid)})

	# Mark tiles backed by the server with the RomM isotipo and its ROM count.
	#
	# The server's own rom_count counts every row it holds, disc tracks included
	# — 59,346 for a PlayStation library whose list shows 9,927. Once a platform
	# is synced its index knows what the list will show, so that wins; the server
	# count is the fallback for a platform never synced, where a number that is
	# too big still beats no number at all.
	var mark: Texture2D = MenuIcons.romm_mark()
	for s: Dictionary in systems:
		var sid: String = s["systemid"]
		var remote := 0
		if _romm_platforms.has(sid):
			remote = int((_romm_platforms[sid] as Dictionary).get("rom_count", 0))
		var shown := RommCatalog.shown_count(sid)
		if shown >= 0:
			remote = shown
		if remote > 0 and mark != null:
			s["badge_icon"] = mark
			s["badge_count"] = remote
			# What is already on this device, shown as the left half of the pair.
			#
			# From the cache manifest rather than the ROM folder: it is an
			# in-memory walk with no disk I/O, and this runs once per platform on
			# every repopulate — _local_by_name() would mean a synchronous
			# directory scan per tile, and it counts gamelist.json and other
			# sidecars that the detail list filters out again later.
			#
			# So the number means "downloaded from this server", not "files in the
			# folder": a ROM copied in by hand is not counted. That is the reading
			# the RomM mark above it promises.
			if romm_cache != null:
				s["badge_here"] = romm_cache.rom_ids_for_system(sid).size()

	# One directory scan, shared by both passes.
	var by_system := FirmwareRequirements.installed_cores_by_system()
	_mark_systems_without_a_core(systems, by_system)
	_mark_netplay_systems(systems, by_system)

	_cartridges_browser.set_systems(systems)
	# If a system detail is open, re-run it so newly-added ROMs appear. Detail
	# only: set_systems has just rebuilt the tiles, and refresh() would build all
	# 68 of them again for nothing.
	_cartridges_browser.refresh_detail()

	# Pull the largest synced platforms' sidecars into the file cache while the
	# user is still looking at the grid. Opening one is disk-bound the first
	# time — 25-37 ms on desktop, considerably worse on Quest storage — and this
	# spends that on a worker thread before the tap rather than during it.
	_prewarm_top_platforms(systems)


## Purple a platform you cannot actually play yet, the same plate the Cores tab's
## Download grid uses for a system with nothing installed. The two grids answer
## the same question from opposite ends — one lists what you could install, the
## other what you could load — so a platform that is purple in one and plain in
## the other would be reading the same library two different ways.
##
## A platform counts as covered when any installed core is filed under it, or when
## the core it would actually boot is installed. Both, because a core often serves
## a platform it is not filed under: the default is what a cartridge here launches.
func _mark_systems_without_a_core(systems: Array, by_system: Dictionary) -> void:
	var installed_names: Dictionary = {}
	for sid: String in by_system:
		for e: Dictionary in (by_system[sid] as Array):
			installed_names[str(e.get("core_name", ""))] = true

	for s: Dictionary in systems:
		var sid: String = str(s.get("systemid", ""))
		var covered: bool = by_system.has(sid) and not (by_system[sid] as Array).is_empty()
		if not covered and core_defaults != null:
			var dflt := core_defaults.get_default_core(sid)
			covered = not dflt.is_empty() and installed_names.has(dflt)
		s["alt_tile"] = not covered


## The netplay mark, in the tile's top-right corner: an installed core for this
## system is vetted for online play, tinted by the strongest strategy any of them
## offers. Takes the installed map rather than fetching it, so the directory scan
## behind it runs once for the whole grid instead of once per tile.
##
## Installed, not merely known: the mark says what this device can do now, which
## is the question a cartridge tile is answering.
func _mark_netplay_systems(systems: Array, by_system: Dictionary) -> void:
	for s: Dictionary in systems:
		var sid: String = str(s.get("systemid", ""))
		var best := -1
		for e: Dictionary in (by_system.get(sid, []) as Array):
			var strategy := NetplayCores.listed_strategy(str(e.get("core_name", "")))
			if strategy < 0:
				continue
			if best < 0 or NetplayCores.STRATEGY_ORDER.find(strategy) \
					< NetplayCores.STRATEGY_ORDER.find(best):
				best = strategy
		if best < 0:
			continue
		s["corner_glyph"] = String.chr(MenuIcons.NETPLAY)
		s["corner_glyph_color"] = MenuIcons.netplay_tint(best)
		s["corner_glyph_tip"] = "Online play: %s" % NetplaySession.strategy_str(best).capitalize()



## One /api/platforms call, cached. Local systems are already on screen by the
## time this returns — server platforms just merge in.
func romm_fetch_platforms() -> void:
	if romm_config == null or not romm_config.is_configured():
		return
	romm_client.platforms(func(ok: bool, platforms: Array) -> void:
		if not ok:
			return
		var part := RommPlatforms.partition(platforms, romm_config.platform_overrides)
		var collapsed := RommPlatforms.collapse_by_systemid(part["mapped"])
		_romm_platforms = collapsed["platforms"]
		# Shadowed platforms ride the unmapped channel: both are platforms with
		# ROMs that the grid will not show, and both are fixed by the same
		# platform_overrides entry.
		_romm_unmapped = part["unmapped"]
		_romm_unmapped.append_array(collapsed["shadowed"])

		# Only announce when the set actually changes. Most unmapped platforms
		# stay unmapped forever (no systemid or 3D model exists for them), so
		# re-reporting the same list on every menu open is pure noise.
		# Worded "not shown" from here down: the list also carries platforms that
		# mapped fine and then lost their systemid to a bigger library, and
		# calling those unmapped sends you hunting for a mapping that exists.
		var signature := ""
		for p: Dictionary in _romm_unmapped:
			signature += str(p.get("slug", "")) + ","
		if not _romm_unmapped.is_empty() and signature != _romm_unmapped_announced:
			notify("romm:map", "⚠", "%d RomM platform%s not shown — see OPTIONS"
				% [_romm_unmapped.size(), "" if _romm_unmapped.size() == 1 else "s"],
				-1.0, 4.0)
		_romm_unmapped_announced = signature

		# Rebuilding the tab means re-deriving every tile. The platform set
		# almost never changes between launches — it is already persisted and
		# used to draw the grid at startup — so only rebuild when it actually
		# moved. This ran on the same frame as a 70 KB JSON parse, which is
		# what made opening the menu hitch.
		var changed := _romm_platforms.size() != romm_config.cached_platforms.size()
		if not changed:
			for sid: String in _romm_platforms:
				if not romm_config.cached_platforms.has(sid):
					changed = true
					break
				var was: Dictionary = romm_config.cached_platforms[sid]
				if int(was.get("rom_count", -1)) != int((_romm_platforms[sid] as Dictionary).get("rom_count", -2)):
					changed = true
					break

		if changed:
			romm_config.cached_platforms = _romm_platforms.duplicate()
			romm_config.save_config()
			_populate_cartridges_tab()
		romm_state_changed.emit()
	)


## Detail page for one system: local ROMs and the RomM library, merged.
##
## Local files render immediately; the server list appears when its index is
## ready (syncing that platform in the background if it has never been synced).
## The rows go into a VirtualRowList, so a 100k-entry platform costs the same as
## a 12-entry one.
func _populate_cartridges_detail(systemid: String, vbox: VBoxContainer) -> void:
	RomLibrary.ensure_rom_dir(systemid)
	# A rebuild of the page you are already on is not a fresh open: clearing the
	# search here is what threw you back to row one of the whole library after
	# accepting a scrape, because the 12 rows you were looking at were a filtered
	# view and the restored scroll offset then indexed into all 2744.
	var keep_filters := _cartridges_browser.is_refreshing() and systemid == _romm_detail_systemid
	_romm_detail_systemid = systemid
	_romm_rows.clear()
	if not keep_filters:
		_romm_filter = ""
	# Opening a platform must see the disk as it is now, not as it was.
	_invalidate_local_scan(systemid)

	# Collect all supported extensions for this system across all its cores.
	#
	# Through CoreInfoDatabase rather than by walking get_by_systemid here: a
	# SECONDARY platform is indexed under its parent core's entry, whose own
	# extension list is the parent's. Walking it gave the e-Reader mGBA's
	# gba|gbc|gb, none of which a dotcode strip is, so every one of the 3217
	# cards on disk was filtered out of its own page and the platform looked
	# empty. extensions_for_systemid adds the secondary extensions the .info
	# declared, which is where "raw" lives.
	_romm_detail_exts = CoreInfoDatabase.extensions_for_systemid(systemid)

	# Search and filters live in the browser's pinned toolbar, not in the scroll
	# area — they must stay reachable however far down the list you are.
	var toolbar := _cartridges_browser.detail_toolbar()
	toolbar.visible = true

	# Local filter over the cached names: instant at 100k rows, works offline.
	var search := LineEdit.new()
	search.placeholder_text = "Search %s…" % _system_label(systemid)
	search.clear_button_enabled = true
	search.custom_minimum_size = Vector2(0, 52)
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.add_theme_font_size_override("font_size", 20)
	# Assigning text does not emit text_changed, so this cannot re-arm the
	# debounce timer — the rows below are already built from _romm_filter.
	search.text = _romm_filter
	search.text_changed.connect(_on_romm_search_changed)
	toolbar.add_child(search)

	var sep := VSeparator.new()
	sep.add_theme_constant_override("separation", 16)
	toolbar.add_child(sep)

	if not keep_filters:
		_romm_source_filter = "all"
		_romm_region_filter = ""
	# The options cache belongs to the widget, and this is a new one — a stale
	# cache matches, returns early, and leaves the fresh dropdown holding nothing
	# but "All regions".
	_romm_region_options = []

	var source_drop := VRDropdown.create("", [
		["All", "all"],
		["Downloaded", "downloaded"],
		["Not downloaded", "server"],
		["Local only", "local"],
	], _romm_source_filter, 1, Vector2(210, 52), 18)
	source_drop.size_flags_horizontal = Control.SIZE_SHRINK_END
	source_drop.float_panel = true
	source_drop.set_toggle_glyph(MenuIcons.FILTER, MenuIcons.symbols())
	source_drop.item_selected.connect(func(id: Variant) -> void:
		_romm_source_filter = str(id)
		_rebuild_romm_rows()
	)
	toolbar.add_child(source_drop)

	_romm_region_drop = VRDropdown.create("", [["All regions", ""]], _romm_region_filter,
		1, Vector2(210, 52), 18)
	_romm_region_drop.size_flags_horizontal = Control.SIZE_SHRINK_END
	_romm_region_drop.float_panel = true
	_romm_region_drop.set_toggle_glyph(MenuIcons.REGION, MenuIcons.symbols())
	_romm_region_drop.item_selected.connect(func(id: Variant) -> void:
		_romm_region_filter = str(id)
		_rebuild_romm_rows()
	)
	toolbar.add_child(_romm_region_drop)

	# A platform syncs on its first open and never again on its own, so without
	# this there is no way to pick up a game added to the server since.
	var resync := Button.new()
	resync.text = String.chr(MenuIcons.RETRY)
	resync.add_theme_font_override("font", MenuIcons.symbols())
	resync.add_theme_font_size_override("font_size", 22)
	resync.custom_minimum_size = Vector2(64, 52)
	resync.size_flags_horizontal = Control.SIZE_SHRINK_END
	resync.pressed.connect(_on_romm_resync_pressed.bind(systemid))
	toolbar.add_child(resync)
	_romm_resync_btn = resync
	_romm_update_resync_btn()

	# A blank 8M Memory Pack is a thing you BUY, not a thing that exists: the
	# Satellaview downloads onto a pack and there is nowhere to put a programme
	# without one. Every other platform's media arrives as a dump, so this is the
	# one shelf that has to be able to mint a new medium — the way the memory-card
	# shelf does.
	if systemid == "satellaview":
		var new_pack := Button.new()
		new_pack.text = "  +  %s  New Memory Pack  " % String.chr(MenuIcons.BSX_MEMORY_PACK)
		# symbols() is the theme font with the glyph table BEHIND it, so the Latin
		# half of this label still renders; the Nerd Font on its own has no letters.
		new_pack.add_theme_font_override("font", MenuIcons.symbols())
		new_pack.add_theme_font_size_override("font_size", 18)
		new_pack.custom_minimum_size = Vector2(0, 52)
		new_pack.size_flags_horizontal = Control.SIZE_SHRINK_END
		new_pack.pressed.connect(_on_new_pack_pressed.bind(systemid))
		toolbar.add_child(new_pack)

	_romm_empty_label = Label.new()
	_romm_empty_label.add_theme_font_size_override("font_size", 18)
	_romm_empty_label.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
	_romm_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_romm_empty_label.visible = false
	vbox.add_child(_romm_empty_label)

	_romm_list = VirtualRowList.new()
	_romm_list.row_height = 100
	_romm_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_romm_list.set_row_builder(_build_blank_rom_row)
	_romm_list.set_row_binder(_bind_rom_row)
	vbox.add_child(_romm_list)

	# Start before the first rebuild, or the empty list reads "add ROMs here"
	# while a sync is in fact already running.
	if _romm_platforms.has(systemid) and not RommCatalog.has_index(systemid):
		var pid := int((_romm_platforms[systemid] as Dictionary).get("id", 0))
		if pid > 0:
			romm_catalog.sync_platform(systemid, pid, true)

	_rebuild_romm_rows()


## Build the merged row model: every local file, plus every server entry, with
## entries that are both collapsed into one row.
##
## Dedupe is by filename first — cheap and correct for the overwhelmingly common
## case. Hashing 361 GiB to build a list is not an option, so MD5 is only
## consulted when a local hash happens to be cached already.
func _rebuild_romm_rows() -> void:
	var systemid := _romm_detail_systemid
	if systemid.is_empty():
		return

	_romm_rows.clear()
	var regions_seen: Dictionary = {}

	# 1. Local files, keyed by lowercase basename.
	#
	# Scanned WITHOUT the extension filter: RomM stores ROMs as .zip, which is
	# not in any core's supported_extensions, so a filtered scan cannot see a
	# freshly downloaded file and every row stays stuck on "download me".
	# Keying on the basename also survives the archive being unpacked, where
	# X.zip becomes X.3ds.
	# Cached: this is a directory listing, and a rebuild happens on every filter
	# change. Invalidated whenever something writes to the ROM dir — see
	# _invalidate_local_scan.
	var local_by_name: Dictionary = _local_by_name(systemid)

	# 2. Server entries. Everything here comes from sidecars already in RAM —
	# no seek and no JSON parse per row, or opening a 3k-ROM platform stalls the
	# frame for a second building rows nobody is looking at yet. The row's real
	# data is read on demand in _bind_rom_row, for the dozen rows on screen.
	var have_index := romm_catalog.load_index(systemid)
	var matched: Dictionary = {}
	# rom_id -> local path for everything this system has downloaded, resolved
	# once. Asking the manifest per row formats a key and probes two dictionaries
	# 49,000 times to find the thirteen entries that exist — 60 ms of the rebuild.
	var cached_by_rom: Dictionary = romm_cache.cached_paths_for_system(systemid) \
		if romm_cache != null else {}
	if have_index:
		var fast := romm_catalog.has_fast_sidecars()
		var indices := PackedInt32Array()
		if _romm_filter.is_empty():
			indices.resize(romm_catalog.count())
			for i in romm_catalog.count():
				indices[i] = i
		else:
			indices = romm_catalog.search(_romm_filter)

		for i: int in indices:
			# The tracks of a disc are rows in their own right when the library
			# keeps them as loose files. They are not games and downloading one
			# alone gets you nothing — RommDownloader pulls them in behind their
			# cue — so they never reach the list.
			if romm_catalog.is_track_at(i):
				continue
			var key := ""
			var label := ""
			var regions := PackedStringArray()
			if fast:
				key = romm_catalog.fs_basename_at(i)
				label = romm_catalog.name_at(i)
				regions = romm_catalog.regions_at(i)
			else:
				# Index predates the sidecars; fall back to the slow path so an
				# un-resynced platform still works.
				var entry := romm_catalog.row(i)
				if entry.is_empty():
					continue
				key = str(entry.get("fs_name", "")).get_basename().to_lower()
				label = str(entry.get("name", key))
				var rl: Array = entry.get("regions", []) if entry.get("regions") is Array else []
				for r: Variant in rl:
					regions.append(str(r))

			# A multi-file server ROM is keyed by its deleted source archive in the
			# cache but launches an m3u/cue below it. Resolve by stable RomM id before
			# falling back to basename matching.
			var cached_path := str(cached_by_rom.get(romm_catalog.rom_id_at(i), ""))
			var local: Dictionary = {"path": cached_path, "label": label} \
				if not cached_path.is_empty() else local_by_name.get(key, {})
			if not local.is_empty():
				matched[key] = true
				matched[str(local.get("path", "")).get_file().get_basename().to_lower()] = true

			for r: String in regions:
				regions_seen[r] = true

			var src := "both" if not local.is_empty() else "server"
			if not _romm_row_passes(src, regions):
				continue
			_romm_rows.append({
				"source": src,
				"index": i,
				"path": str(local.get("path", "")),
				"label": label,
			})

	# 3. Local-only files the server doesn't know about. The extension filter
	# skipped in step 1 applies here, or gamelist.json lists itself as a ROM.
	for key: String in local_by_name:
		if matched.has(key):
			continue
		var rom: Dictionary = local_by_name[key]
		# Skipping a cache-owned file is only safe when there was an index to
		# match it against — step 2 is where it earns its row back. With no
		# index the row never comes, and a game sitting on disk is listed
		# nowhere at all.
		if have_index and romm_cache != null and romm_cache.owns_file(systemid,
				RommCacheManifest.relative_path(systemid, str(rom["path"]))):
			continue
		var ext := str(rom["path"]).get_extension().to_lower()
		if not _romm_detail_exts.is_empty() and ext not in _romm_detail_exts:
			continue
		var label := str(rom["label"])
		if not _romm_filter.is_empty() and not label.containsn(_romm_filter):
			continue
		# A local-only file has no server metadata, so it has no region to match.
		if not _romm_row_passes("local", PackedStringArray()):
			continue
		_romm_rows.append({
			"source": "local",
			"index": -1,
			"path": str(rom["path"]),
			"label": label,
		})

	_romm_refresh_region_options(regions_seen)

	if _romm_list != null and is_instance_valid(_romm_list):
		_romm_list.set_row_count(_romm_rows.size())

	_romm_update_empty_label()


## Split out of the rebuild so a reachability transition can correct the wording
## without rebuilding every row.
func _romm_update_empty_label() -> void:
	if _romm_empty_label == null or not is_instance_valid(_romm_empty_label):
		return
	_romm_empty_label.visible = _romm_rows.is_empty()
	if not _romm_rows.is_empty():
		return
	if not _romm_filter.is_empty():
		_romm_empty_label.text = "No games match “%s”." % _romm_filter
	elif not romm_client.is_reachable():
		# Ahead of the sync check: a sync that is still "running" against a dead
		# server is not news the player can use.
		_romm_empty_label.text = "RomM is unreachable — only local files are listed."
	elif romm_catalog.is_syncing():
		_romm_empty_label.text = "Syncing from RomM…"
	else:
		_romm_empty_label.text = "Add ROMs to %s/ to see them here." \
			% RomLibrary.rom_dir_for_system(_romm_detail_systemid)


## Warm the sidecars for the platforms most likely to be opened next.
##
## Biggest first, because cost scales with row count and those are the ones that
## stutter. Capped: the warm worker handles one platform at a time and a long
## queue would still be running when the user taps.
func _prewarm_top_platforms(systems: Array) -> void:
	if romm_catalog == null:
		return
	var sized: Array = []
	for s: Dictionary in systems:
		var sid: String = s["systemid"]
		if int(s.get("badge_count", 0)) > 0:
			sized.append([int(s["badge_count"]), sid])
	sized.sort_custom(func(a: Array, b: Array) -> bool: return int(a[0]) > int(b[0]))
	# Every synced platform, not just the first few: the worker also backfills
	# missing sidecars, which is a one-time repair worth doing for all of them
	# rather than only the ones that happen to be biggest.
	for e: Array in sized:
		romm_catalog.prewarm_index(str(e[1]))


## Local ROM files for one system, keyed by lowercase basename.
##
## Scanned WITHOUT the extension filter: RomM stores ROMs as .zip, which is not
## in any core's supported_extensions, so a filtered scan cannot see a freshly
## downloaded file and every row stays stuck on "download me". Keying on the
## basename also survives the archive being unpacked, where X.zip becomes X.3ds.
func _local_by_name(systemid: String) -> Dictionary:
	if _local_scan_cache.has(systemid):
		return _local_scan_cache[systemid]
	# Same-stem collisions are resolved by RomLibrary: a manifest beats its tracks,
	# and a real game beats a save or savestate that happens to sit beside it.
	var by_name := RomLibrary.index_by_basename(
		RomLibrary.scan_roms(systemid, [] as Array[String]),
		CoreInfoDatabase.extensions_for_systemid(systemid))
	_local_scan_cache[systemid] = by_name
	return by_name


## Mint a blank pack into the broadcast folder and show it straight away.
##
## It lands beside the channel packets on purpose: snes9x reads its broadcast
## directory from the loaded ROM's own folder, so a pack kept anywhere else boots
## perfectly and receives nothing.
func _on_new_pack_pressed(systemid: String) -> void:
	var path := BsxPack.create_blank(RomLibrary.rom_dir_for_system(systemid))
	if path.is_empty():
		push_warning("[spawn] could not create a memory pack in %s" % systemid)
		return
	print("[spawn] new memory pack: %s" % path)
	_invalidate_local_scan(systemid)
	if _cartridges_browser:
		_cartridges_browser.refresh_detail()


## Drop the cached listing after anything that writes to a ROM directory —
## a download landing, an eviction, a scrape, a manual refresh.
func _invalidate_local_scan(systemid: String = "") -> void:
	if systemid.is_empty():
		_local_scan_cache.clear()
	else:
		_local_scan_cache.erase(systemid)


func _romm_row_passes(source: String, regions: PackedStringArray) -> bool:
	match _romm_source_filter:
		"downloaded":
			if source == "server":
				return false
		"server":
			if source != "server":
				return false
		"local":
			if source != "local":
				return false

	# Local-only rows are exempt. The dropdown's options are built from server
	# rows alone (_romm_refresh_region_options), and a local file carries no
	# region at all — so it can never match any option, and picking a region
	# silently emptied the list of the files the player actually owns.
	if source != "local" and not _romm_region_filter.is_empty():
		if _romm_region_filter not in regions:
			return false
	return true


## Rebuild the region list from what the platform actually contains, keeping the
## current selection if it survives.
func _romm_refresh_region_options(seen: Dictionary) -> void:
	var names: Array[String] = []
	for r: String in seen:
		if not r.is_empty():
			names.append(r)
	names.sort()
	if names == _romm_region_options:
		return
	_romm_region_options = names

	# A selection that no longer exists on this platform would silently empty
	# the list.
	if not _romm_region_filter.is_empty() and _romm_region_filter not in names:
		_romm_region_filter = ""

	if _romm_region_drop == null or not is_instance_valid(_romm_region_drop):
		return
	var opts: Array = [["All regions", ""]]
	for r: String in names:
		opts.append([r, r])
	_romm_region_drop.set_options(opts, _romm_region_filter)


## Debounced: a rebuild scans the ROM dir, runs the filter over every server
## row and rebuilds the model, which is tens of milliseconds on a 3k platform
## on Quest. Doing that per keystroke made typing stutter; typing is bursty, so
## coalescing to one rebuild once the keys stop costs nothing in responsiveness.
func _on_romm_search_changed(text: String) -> void:
	_romm_filter = text.strip_edges().to_lower()
	if _romm_search_timer == null:
		_romm_search_timer = Timer.new()
		_romm_search_timer.one_shot = true
		_romm_search_timer.wait_time = SEARCH_DEBOUNCE_SEC
		_romm_search_timer.timeout.connect(_rebuild_romm_rows)
		add_child(_romm_search_timer)
	_romm_search_timer.start(SEARCH_DEBOUNCE_SEC)


# ── Virtualized ROM rows ──────────────────────────────────────────────────────
# Glyph codepoints verified present in RetroXR/fonts/SymbolsNerdFont-Regular.ttf.
# Two different delete glyphs is deliberate: the pictogram encodes whether the
# file can be got back. (At row size the two trash cans look near-identical, so
# the confirm text carries the real distinction — the glyph is a support cue.)


## Allocate one blank recyclable row. Called ~12 times total, not once per ROM.
func _build_blank_rom_row() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)

	var state := Button.new()
	state.name = "State"
	state.custom_minimum_size = Vector2(76, 100)
	state.add_theme_font_override("font", MenuIcons.symbols())
	state.add_theme_font_size_override("font_size", 40)
	row.add_child(state)

	var pct := Label.new()
	pct.name = "Pct"
	pct.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pct.add_theme_font_size_override("font_size", 15)
	pct.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pct.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	pct.offset_top = -32
	pct.offset_bottom = -14
	pct.visible = false
	state.add_child(pct)

	var cover := TextureRect.new()
	cover.name = "Cover"
	cover.custom_minimum_size = Vector2(72, 96)
	# IGNORE_SIZE: FIT_HEIGHT_PROPORTIONAL reports a minimum height of
	# width * aspect, which pushes a portrait cover's row past row_height.
	cover.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	cover.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	row.add_child(cover)

	# A pack this room minted, marked before the title. Its own Label rather than
	# a prefix on the title: MarqueeButton draws through an internal label and
	# clips to its own width, so a glyph put in the text scrolls away with it.
	var pack_mark := Label.new()
	pack_mark.name = "PackMark"
	pack_mark.add_theme_font_override("font", MenuIcons.symbols())
	pack_mark.add_theme_font_size_override("font_size", 26)
	pack_mark.add_theme_color_override("font_color", MenuIcons.TINT_OK)
	pack_mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	pack_mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pack_mark.text = String.chr(MenuIcons.BSX_MEMORY_PACK)
	pack_mark.visible = false
	row.add_child(pack_mark)

	var main := MarqueeButton.create("", 22)
	main.name = "Main"
	main.custom_minimum_size = Vector2(0, 100)
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(main)

	# What a dotcode card's strips are — "L", "S", "L+S", "L+L" — under the title
	# it belongs to, in the description grey so it reads as an annotation rather
	# than part of the name. A child of the title button for the same reason Pct
	# is a child of State: a Control's children draw over it, where a prefix put
	# in the text would scroll away with the marquee.
	var strips := Label.new()
	strips.name = "Strips"
	strips.mouse_filter = Control.MOUSE_FILTER_IGNORE
	strips.add_theme_font_size_override("font_size", 15)
	strips.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
	strips.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	strips.offset_left = 10
	strips.offset_top = -30
	strips.offset_bottom = -10
	strips.visible = false
	main.add_child(strips)

	# "Pack" is last and shows only for a .bs: what is written on a Satellaview
	# memory pack, which the row itself can only summarise.
	for n: String in ["Detail", "Saves", "Manual", "Scrape", "Pack"]:
		var b := Button.new()
		b.name = n
		b.custom_minimum_size = Vector2(66, 100)
		b.add_theme_font_override("font", MenuIcons.symbols())
		b.add_theme_font_size_override("font_size", 26)
		b.add_theme_color_override("font_color", Color(0.72, 0.72, 0.86))
		row.add_child(b)

	return row


## Fill a recycled row for `index`. Runs on every scroll, so it must be cheap
## and must disconnect anything it connected last time.
func _bind_rom_row(row: Control, index: int) -> void:
	if index < 0 or index >= _romm_rows.size():
		return
	var model: Dictionary = _romm_rows[index]
	# Read on demand: this is the only place a row's JSON is parsed.
	var cat_index := int(model.get("index", -1))
	var entry: Dictionary = romm_catalog.row(cat_index) if cat_index >= 0 else {}
	var systemid := _romm_detail_systemid
	var source := str(model["source"])
	var label := str(model["label"])
	var rom_id := int(entry.get("id", 0))
	var local_path := str(model["path"])

	var state := row.get_node("State") as Button
	var pct := state.get_node("Pct") as Label
	var cover := row.get_node("Cover") as TextureRect
	var main := row.get_node("Main") as MarqueeButton
	var detail := row.get_node("Detail") as Button
	var saves := row.get_node("Saves") as Button
	var manual := row.get_node("Manual") as Button
	var scrape := row.get_node("Scrape") as Button
	var pack := row.get_node("Pack") as Button

	_disconnect_all(state.pressed)
	_disconnect_all(main.pressed)
	_disconnect_all(detail.pressed)
	_disconnect_all(saves.pressed)
	_disconnect_all(manual.pressed)
	_disconnect_all(scrape.pressed)
	_disconnect_all(pack.pressed)

	# Rows are pooled, so anything a branch below only sets conditionally has to
	# be cleared here — otherwise one dead-server row leaves every title it later
	# recycles into greyed out and unpressable.
	row.modulate = Color(1.0, 1.0, 1.0, 1.0)
	state.disabled = false
	main.disabled = false

	# Rows are pooled, so this is set on EVERY bind and not only when true --
	# otherwise one pack leaves its mark on every title it later recycles into.
	var pack_mark := row.get_node("PackMark") as Label
	pack_mark.visible = BsxPack.is_own_pack_path(local_path)
	pack_mark.tooltip_text = "A memory pack made here — the Satellaview writes downloads to this one"

	# Set on every bind for the same reason, and off any platform but the cards.
	var strips := main.get_node("Strips") as Label
	strips.text = ""
	if systemid == EReaderCards.SYSTEMID and not local_path.is_empty():
		strips.text = EReaderCards.strip_summary(EReaderCards.card_for_path(local_path))
	strips.visible = not strips.text.is_empty()

	# A scraped wheel logo replaces the title text entirely; otherwise the title
	# scrolls. MarqueeButton extends Button, so it carries the icon itself.
	var wheel: Texture2D = null
	if not local_path.is_empty():
		wheel = scraped_art.get_or_request(systemid, local_path.get_file(), "wheel", WHEEL_BOX)
	if wheel != null:
		main.icon = wheel
		main.expand_icon = false
		main.add_theme_constant_override("icon_max_width", WHEEL_BOX.x)
		main.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		main.set_marquee_text("")
	else:
		main.icon = null
		main.expand_icon = false
		# MarqueeButton keeps its own `text` empty and draws via an internal
		# label — setting `text` directly would fight its width clipping.
		main.set_marquee_text("  " + label)

	# ── Leading state icon ──────────────────────────────────────────────────
	var downloading := rom_id > 0 and romm_downloader.current_rom_id() == rom_id
	pct.visible = false

	if downloading:
		state.text = String.chr(MenuIcons.BUSY)
		state.add_theme_color_override("font_color", MenuIcons.TINT_BUSY)
		state.tooltip_text = "Cancel download"
		pct.visible = true
		pct.add_theme_color_override("font_color", MenuIcons.TINT_BUSY)
		pct.text = "%d%%" % _romm_progress_pct.get(rom_id, 0)
		state.pressed.connect(func() -> void: romm_downloader.cancel_current())
	elif source == "server":
		# The cloud glyph is visually lighter than the trash glyphs at the same
		# size — a small bump evens the weight out.
		state.add_theme_font_size_override("font_size", 44)
		if romm_client.is_reachable():
			state.text = String.chr(MenuIcons.DOWNLOAD)
			state.add_theme_color_override("font_color", MenuIcons.TINT_DOWNLOAD)
			state.tooltip_text = "Download from RomM (%s)" % MenuStyle.human_bytes(int(entry.get("fs_size_bytes", 0)))
			state.pressed.connect(func() -> void: romm_downloader.enqueue(entry, systemid))
		else:
			# The index is on disk, so these keep listing with the server down.
			# The row is the only place that can say so: the unreachable toast is
			# long gone by the time you have scrolled to the one you wanted.
			state.text = String.chr(MenuIcons.SYNC_OFF)
			state.add_theme_color_override("font_color", MenuIcons.TINT_MUTED)
			state.tooltip_text = "RomM is unreachable — this title is on the server only"
			state.disabled = true
			row.modulate = UNREACHABLE_DIM
	else:
		state.add_theme_font_size_override("font_size", 40)
		var forever := source == "local"
		state.text = String.chr(MenuIcons.DELETE_FOREVER if forever else MenuIcons.DELETE)
		state.add_theme_color_override("font_color", MenuIcons.TINT_DELETE)
		state.tooltip_text = "Delete permanently" if forever else "Delete local copy"
		state.pressed.connect(_on_rom_delete_pressed.bind(index, state))

	# ── Cover ───────────────────────────────────────────────────────────────
	cover.texture = null
	if rom_id > 0:
		cover.texture = romm_art.get_or_request(rom_id, str(entry.get("cover_small", "")), systemid)
	if cover.texture == null and not model["path"].is_empty():
		# Mipmapped: these are photographic scans read at a glancing angle in VR.
		# Was MediaDimensions.load_label_texture, which decoded and generated mips
		# inline with no cache at all — 4.1 ms per row on every scroll step.
		cover.texture = scraped_art.get_or_request(
			systemid, str(model["path"]), "label", Vector2i.ZERO, true)
	cover.visible = cover.texture != null

	# ── Launch ──────────────────────────────────────────────────────────────
	if not local_path.is_empty():
		main.pressed.connect(func() -> void:
			if romm_cache != null:
				romm_cache.touch(systemid,
					RommCacheManifest.relative_path(systemid, local_path))
			spawn_cartridge_requested.emit(local_path, label, systemid)
		)
	elif romm_client.is_reachable():
		# Not downloaded yet — tapping the title fetches it, same as the icon.
		main.pressed.connect(func() -> void: romm_downloader.enqueue(entry, systemid))
	else:
		main.disabled = true

	# ── Trailing cluster ────────────────────────────────────────────────────
	# A Satellaview memory pack is a MEDIUM, not a game, and half this cluster is
	# about games. Worked out before the buttons rather than beside each one,
	# because more than one of them asks.
	var is_pack: bool = systemid == "satellaview" and not local_path.is_empty() \
			and BsxPack.is_pack_path(local_path)

	var meta := _romm_row_meta(systemid, local_path)
	var game: Dictionary = meta["game"]
	detail.text = String.chr(MenuIcons.GAMEPAD)
	# Not for a pack: there is no game to describe. A pack whose filename happens
	# to match a catalog entry would otherwise offer that game's page, which is a
	# different thing than the medium in front of you.
	detail.visible = not game.is_empty() and not is_pack
	if detail.visible:
		detail.pressed.connect(_show_game_detail_panel.bind(game, systemid))

	# The game's saves and achievements, the same page the cartridge's own menu
	# shows — reachable here so you can look before you spawn anything. Needs a
	# local ROM: a save is keyed by the file's path, and a title that is still only
	# on the server has none on this device.
	saves.text = String.chr(MenuIcons.CARD_SAVES)
	saves.visible = not local_path.is_empty()
	saves.tooltip_text = "Saves and achievements"
	if not local_path.is_empty():
		saves.pressed.connect(
			_show_game_saves_panel.bind(systemid, local_path, label))

	# ── Memory packs ────────────────────────────────────────────────────────
	# A pack is called by what is WRITTEN ON IT, read out of its own header, not
	# by its filename. The two are unrelated: a pack downloaded from the server
	# arrives named for the broadcast that filled it, and one minted here is named
	# whatever kept it unique on disk. An unused pack says so rather than showing
	# the placeholder title a blank carries.
	# A pack is named by EVERY programme written on it, not by the first: several
	# live on one medium, and naming it after block 0 leaves the rest invisible.
	if is_pack:
		main.set_marquee_text("  " + BsxPack.display_name(local_path))
	# Set on every bind, not only when true: rows are pooled, and a pack's button
	# left visible would offer a pack's contents for whatever title recycles here.
	pack.text = String.chr(MenuIcons.BSX_PACK_CONTENTS)
	pack.visible = is_pack
	pack.tooltip_text = "What is written on this pack"
	if is_pack:
		pack.pressed.connect(_show_pack_contents_panel.bind(local_path))

	var has_manual: bool = meta["has_manual"]
	var manual_path: String = meta["manual_path"]
	manual.text = String.chr(MenuIcons.BOOK)
	manual.visible = has_manual
	if has_manual:
		manual.pressed.connect(spawn_manual_requested.emit.bind(manual_path))

	# Scraping hashes the local file, so it needs one on disk. Not for a pack:
	# ScreenScraper has no entry for a medium, and a pack's hash changes every
	# time the player downloads onto it, so there is nothing stable to match.
	# disabled is reset here or a mid-scrape scroll leaves it stuck on whichever
	# row later reuses this pooled button.
	scrape.text = String.chr(MenuIcons.SCRAPE)
	scrape.disabled = false
	scrape.visible = not local_path.is_empty() and not is_pack
	scrape.tooltip_text = "Scrape artwork and details from ScreenScraper"
	if scrape.visible:
		scrape.pressed.connect(_on_scrape_pressed.bind(local_path, systemid, scrape))


## Two-stage delete: the first press arms it, the second within 3 s commits.
## A single mis-tap must never delete a 4 GB download, and every
## Viewport2Din3D click already fires twice.
func _on_rom_delete_pressed(index: int, state: Button) -> void:
	if index < 0 or index >= _romm_rows.size():
		return
	var model: Dictionary = _romm_rows[index]
	var local_path := str(model["path"])
	if local_path.is_empty():
		return

	if _romm_delete_armed != index:
		_romm_delete_armed = index
		state.text = String.chr(MenuIcons.ERROR)
		var forever := str(model["source"]) == "local"
		show_notice("Tap again to %s" % ("delete permanently" if forever else "delete local copy"), 3.0)
		get_tree().create_timer(3.0).timeout.connect(func() -> void:
			if _romm_delete_armed == index:
				_romm_delete_armed = -1
				if _romm_list != null and is_instance_valid(_romm_list):
					_romm_list.rebind_visible()
		)
		return

	_romm_delete_armed = -1
	var systemid := _romm_detail_systemid
	var fname := local_path.get_file()
	var relative := RommCacheManifest.relative_path(systemid, local_path)

	# Read BEFORE the ROM goes, because the artwork lookup keys on the ROM's own
	# basename and the RomM cover on the server id. A hand-copied ROM has no
	# catalog row and yields 0, which matches no cover — correct, it has none.
	var catalog_index := int(model.get("index", -1))
	var rom_id := romm_catalog.rom_id_at(catalog_index) if \
		romm_catalog != null and catalog_index >= 0 else 0
	var metadata := StorageCleanup.metadata_for_rom(systemid, relative, rom_id)

	var removed_group := romm_cache != null \
		and romm_cache.remove_for_file(systemid, relative) >= 0
	if not removed_group and FileAccess.file_exists(local_path):
		DirAccess.remove_absolute(local_path)

	# Library row and artwork go with it. Saves deliberately do not: a game can be
	# fetched again and a save cannot, so orphaned saves are surfaced by the
	# Clean up sweep as their own explicitly-confirmed category instead.
	var freed := StorageCleanup.purge_rom_metadata(systemid, relative, rom_id)
	# The purge edited gamelist.json through its own manager, so this view's
	# cached copy is now a frame behind the disk.
	if gamelist_manager != null:
		gamelist_manager.invalidate(systemid)

	show_notice("Deleted %s%s" % [fname,
		"" if metadata.is_empty() else " and %d metadata file%s (%s)" % [
			metadata.size(), "" if metadata.size() == 1 else "s",
			MenuStyle.human_bytes(freed)]], 2.5)
	_romm_meta_cache.clear()
	_invalidate_local_scan(systemid)
	_rebuild_romm_rows()


## Gamelist entry and manual path for a row. Memoized because the raw form is a
## linear scan of gamelist.json plus two file_exists calls, run per row on every
## bind — which is every scroll step and, previously, every download progress tick.
func _romm_row_meta(systemid: String, local_path: String) -> Dictionary:
	if local_path.is_empty():
		return {"game": {}, "manual_path": "", "has_manual": false}
	if _romm_meta_cache.has(local_path):
		return _romm_meta_cache[local_path]

	var manual_path := RomLibrary.scraped_manual_path(systemid, local_path.get_file())
	var meta := {
		"game": gamelist_manager.get_game_for_rom(systemid, local_path),
		"manual_path": manual_path,
		"has_manual": FileAccess.file_exists(manual_path),
	}
	_romm_meta_cache[local_path] = meta
	return meta


## Rows are recycled, so every connection from the previous bind must go.
static func _disconnect_all(sig: Signal) -> void:
	for c: Dictionary in sig.get_connections():
		sig.disconnect(c["callable"])


func _populate_books_tab() -> void:
	if not _books_vbox:
		return
	_clear_vbox(_books_vbox)
	var books := RomLibrary.scan_books()
	if books.is_empty():
		var hint := Label.new()
		hint.text = "No PDFs found in books folder."
		hint.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_books_vbox.add_child(hint)
		return
	for book: Dictionary in books:
		var btn := Button.new()
		btn.text = "  📖  " + book["label"]
		btn.custom_minimum_size = Vector2(0, 72)
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(spawn_manual_requested.emit.bind(book["path"]))
		_books_vbox.add_child(btn)
	_books_vbox.add_child(MenuStyle.spacer(8))


func _populate_videos_tab() -> void:
	if not _videos_vbox:
		return
	_clear_vbox(_videos_vbox)
	var videos := RomLibrary.scan_videos()
	if videos.is_empty():
		var hint := Label.new()
		hint.text = "No videos found in videos folder."
		hint.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_videos_vbox.add_child(hint)
		return
	for video: Dictionary in videos:
		var btn := Button.new()
		btn.text = "  📼  " + video["label"]
		btn.custom_minimum_size = Vector2(0, 72)
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(spawn_video_requested.emit.bind(video["path"]))
		_videos_vbox.add_child(btn)
	_videos_vbox.add_child(MenuStyle.spacer(8))


func _populate_dvds_tab() -> void:
	if not _dvds_vbox:
		return
	_clear_vbox(_dvds_vbox)
	var dvds := RomLibrary.scan_dvds()
	if dvds.is_empty():
		var hint := Label.new()
		hint.text = "No DVD images found in dvd folder."
		hint.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_dvds_vbox.add_child(hint)
		return
	for dvd: Dictionary in dvds:
		var btn := Button.new()
		btn.text = "  💿  " + dvd["label"]
		btn.custom_minimum_size = Vector2(0, 72)
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(spawn_dvd_requested.emit.bind(dvd["path"]))
		_dvds_vbox.add_child(btn)
	_dvds_vbox.add_child(MenuStyle.spacer(8))


func _populate_cds_tab() -> void:
	_populate_music_vbox(_cds_vbox, "💿", spawn_cd_requested)


func _populate_tapes_tab() -> void:
	_populate_music_vbox(_tapes_vbox, "🎵", spawn_cassette_requested)


func _populate_records_tab() -> void:
	_populate_music_vbox(_records_vbox, "🎶", spawn_record_requested)


## Shared list builder for the CDs / Tapes / Records tabs — all three list the same
## music albums, differing only in the icon and which spawn signal a row fires.
func _populate_music_vbox(vbox: VBoxContainer, icon: String, sig: Signal) -> void:
	if not vbox:
		return
	_clear_vbox(vbox)
	var albums := RomLibrary.scan_music()
	if albums.is_empty():
		var hint := Label.new()
		hint.text = "No music found in music folder."
		hint.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		vbox.add_child(hint)
		return
	for album: Dictionary in albums:
		var btn := Button.new()
		btn.text = "  %s  %s" % [icon, album["label"]]
		btn.custom_minimum_size = Vector2(0, 72)
		btn.add_theme_font_size_override("font_size", 24)
		btn.pressed.connect(sig.emit.bind(album["path"]))
		vbox.add_child(btn)
	vbox.add_child(MenuStyle.spacer(8))


## Returns the vbox, so a tab whose contents change at runtime can keep hold of
## it and repopulate. The const tabs ignore the return.
func _add_spawn_tab(tabs: TabContainer, tab_title: String, items: Array) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = tab_title
	tabs.add_child(scroll)
	_spawn_tab_scrolls.append(scroll)
	MenuStyle.fat_vscroll_bar(scroll)
	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 14)
	scroll.add_child(vbox)
	vbox.add_child(MenuStyle.spacer(10))
	for item: Array in items:
		var btn := Button.new()
		btn.text = "  +  " + item[0]
		btn.custom_minimum_size = Vector2(0, 80)
		btn.add_theme_font_size_override("font_size", 26)
		btn.pressed.connect(spawn_requested.emit.bind(item[1]))
		vbox.add_child(btn)
	return vbox


## The virtual controllers, then a receiver per connected physical pad.
##
## A receiver is how a real gamepad reaches a console: plug one into a controller
## port and that port is driven by its pad, with nothing held. So the list has to
## follow what is actually paired right now, which is why this tab is rebuilt
## rather than authored like the others.
func _populate_controllers_tab() -> void:
	if _controllers_vbox == null or not is_instance_valid(_controllers_vbox):
		return
	_clear_vbox(_controllers_vbox)
	_controllers_vbox.add_child(MenuStyle.spacer(10))
	for item: Array in [
			["Primitive Controller", "retro_controller"],
			["Light Gun",          "light_gun"],
			["Mouse",              "retro_mouse"],
			["Keyboard",           "retro_keyboard"],
			["Wiimote",            "wiimote"],
			["Nunchuk",            "nunchuk"],
			["Wii MotionPlus",     "motion_plus"]]:
		_controllers_vbox.add_child(_spawn_row(str(item[0]), str(item[1])))

	# The keyboard and mouse dongles, VR only. On desktop the real keyboard and
	# mouse ARE the player — WASD walks and mouse-look drags the virtual mouse —
	# so a dongle quietly forwarding them to a core would fight the controls you
	# are standing on, and there is nothing to gain: the point of a receiver is to
	# free the Quest controllers, and a desktop player has none.
	if MenuStyle.is_vr_mode():
		_controllers_vbox.add_child(_spawn_row("Keyboard Receiver", "keyboard_receiver"))
		_controllers_vbox.add_child(_spawn_row("Mouse Receiver", "mouse_receiver"))

	_controllers_vbox.add_child(HSeparator.new())
	_controllers_vbox.add_child(MenuStyle.header("DETECTED PADS", 20))
	var pads := GamepadBindings.usable_pads()
	if pads.is_empty():
		_controllers_vbox.add_child(MenuStyle.hint(
			"No gamepad connected. Pair one and it appears here."))
		return
	for device: int in pads:
		var id := GamepadBindings.identify_device(device)
		var label := "%s Receiver" % str(id["name"])
		var token := "pad_receiver:%s:%d" % [str(id["guid"]), int(id["ordinal"])]
		_controllers_vbox.add_child(_spawn_row(label, token))


func _spawn_row(label: String, token: String) -> Button:
	var btn := Button.new()
	btn.text = "  +  " + label
	btn.custom_minimum_size = Vector2(0, 80)
	btn.add_theme_font_size_override("font_size", 26)
	btn.pressed.connect(spawn_requested.emit.bind(token))
	return btn


# ── Scraper ──────────────────────────────────────────────────────────────────

func _on_scrape_pressed(rom_path: String, systemid: String, btn: Button) -> void:
	if _scrape_in_progress:
		print("[SpawnMenu] Scrape already in progress, ignoring request for: %s" % rom_path.get_file())
		# A toast, not a notice: the status slot is showing the running scrape's
		# own progress, and a notice would replace that text.
		notify("scrape:busy", "⚠️", "Scrape Already In Progress",
			-1.0, MenuToasts.DWELL_INFO)
		return
	_scrape_in_progress = true
	btn.text = "⏳"
	btn.disabled = true
	_show_scrape_status("Hashing ROM...")

	# Compute checksums on a background thread to avoid UI freeze.
	# Thread.wait_to_finish() returns the callable's return value directly,
	# avoiding the WorkerThreadPool lambda-environment copy issue where
	# variable reassignment inside add_task() doesn't propagate back.
	var thread := Thread.new()
	thread.start(func() -> Dictionary: return RomHasher.compute_checksums(rom_path))
	while thread.is_alive():
		await get_tree().process_frame
	var checksums: Dictionary = thread.wait_to_finish()
	print("[SpawnMenu] Checksums done: ", checksums)

	if checksums.is_empty():
		_scrape_in_progress = false
		btn.text = String.chr(MenuIcons.SCRAPE)
		btn.disabled = false
		_hide_scrape_status()
		push_warning("[SpawnMenu] Failed to compute checksums for: %s" % rom_path)
		return

	# Connect one-shot signals for this scrape
	var completed_cb: Callable
	var failed_cb: Callable

	completed_cb = func(result: Dictionary):
		scraper_client.scrape_completed.disconnect(completed_cb)
		scraper_client.scrape_failed.disconnect(failed_cb)
		_scrape_in_progress = false
		if is_instance_valid(btn):
			btn.text = String.chr(MenuIcons.SCRAPE)
			btn.disabled = false
		_hide_scrape_status()
		print("[SpawnMenu] Scrape completed for: %s" % rom_path.get_file())
		_show_scrape_popup(rom_path, systemid, result)

	failed_cb = func(error: String):
		scraper_client.scrape_completed.disconnect(completed_cb)
		scraper_client.scrape_failed.disconnect(failed_cb)
		_scrape_in_progress = false
		if is_instance_valid(btn):
			btn.text = String.chr(MenuIcons.SCRAPE)
			btn.disabled = false
		_hide_scrape_status()
		push_warning("[SpawnMenu] Scrape failed: %s" % error)
		_show_scrape_error_popup(error)

	scraper_client.scrape_completed.connect(completed_cb)
	scraper_client.scrape_failed.connect(failed_cb)
	scraper_client.scrape_rom(rom_path, systemid, checksums)


func _show_scrape_popup(rom_path: String, systemid: String, result: Dictionary) -> void:
	_close_scrape_popup()

	_scrape_popup = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.1, 0.2, 0.98)
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		bg.set(k, 8)
	_scrape_popup.add_theme_stylebox_override("panel", bg)
	_scrape_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["margin_top","margin_bottom","margin_left","margin_right"]:
		margin.add_theme_constant_override(side, 14)
	_scrape_popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	margin.add_child(vbox)

	# Title
	vbox.add_child(MenuStyle.label("SCRAPE RESULT", 24, MenuStyle.COLOR_TITLE))
	vbox.add_child(HSeparator.new())

	# Metadata
	_add_scrape_info_row(vbox, "Game", result.get("name", "Unknown"))
	_add_scrape_info_row(vbox, "Developer", result.get("developer", ""))
	_add_scrape_info_row(vbox, "Publisher", result.get("publisher", ""))
	_add_scrape_info_row(vbox, "Genre", result.get("genre", ""))
	_add_scrape_info_row(vbox, "Region", result.get("rom_region", ""))
	_add_scrape_info_row(vbox, "Release", result.get("releasedate", ""))

	vbox.add_child(HSeparator.new())

	# Media availability
	var media: Dictionary = result.get("media", {})
	vbox.add_child(MenuStyle.label("MEDIA", 18, MenuStyle.COLOR_TITLE))

	for mtype: String in ["wheel", "box", "label", "manual"]:
		var has_it: bool = not (media.get(mtype, "") as String).is_empty()
		var icon := "✅" if has_it else "❌"
		_add_scrape_info_row(vbox, mtype.capitalize(), icon)

	vbox.add_child(HSeparator.new())

	# Buttons
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 10)
	vbox.add_child(btn_row)

	var accept_btn := Button.new()
	accept_btn.text = "  ACCEPT  "
	accept_btn.custom_minimum_size = Vector2(0, 56)
	accept_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	accept_btn.add_theme_font_size_override("font_size", 20)
	var accept_style := StyleBoxFlat.new()
	accept_style.bg_color = MenuStyle.COLOR_BTN_DL
	for k2 in ["corner_radius_top_left","corner_radius_top_right",
			   "corner_radius_bottom_left","corner_radius_bottom_right"]:
		accept_style.set(k2, 5)
	for state in ["normal", "hover", "pressed"]:
		accept_btn.add_theme_stylebox_override(state, accept_style)
	accept_btn.pressed.connect(_on_scrape_accepted.bind(rom_path, systemid, result))
	btn_row.add_child(accept_btn)

	var close_btn := Button.new()
	close_btn.text = "  CLOSE  "
	close_btn.custom_minimum_size = Vector2(0, 56)
	close_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.pressed.connect(_close_scrape_popup)
	btn_row.add_child(close_btn)

	# Add popup as sibling of the spawn view content
	get_parent().add_child(_scrape_popup)


func _show_scrape_error_popup(error: String) -> void:
	_close_scrape_popup()

	_scrape_popup = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.2, 0.08, 0.08, 0.98)
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		bg.set(k, 8)
	_scrape_popup.add_theme_stylebox_override("panel", bg)
	_scrape_popup.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["margin_top","margin_bottom","margin_left","margin_right"]:
		margin.add_theme_constant_override(side, 14)
	_scrape_popup.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 12)
	margin.add_child(vbox)

	var title := Label.new()
	title.text = "SCRAPE FAILED"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Color(1, 0.4, 0.4))
	vbox.add_child(title)

	var err_lbl := Label.new()
	err_lbl.text = error
	err_lbl.add_theme_font_size_override("font_size", 18)
	err_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	err_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(err_lbl)

	var close_btn := Button.new()
	close_btn.text = "  CLOSE  "
	close_btn.custom_minimum_size = Vector2(0, 56)
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.pressed.connect(_close_scrape_popup)
	vbox.add_child(close_btn)

	get_parent().add_child(_scrape_popup)


func _close_scrape_popup() -> void:
	if _scrape_popup and is_instance_valid(_scrape_popup):
		_scrape_popup.queue_free()
	_scrape_popup = null


# ── RomM notifications ────────────────────────────────────────────────────────
# All of these land in the same bottom-of-menu toast stack the scraper uses.
# Keys are namespaced "romm:" so they cannot collide with the scraper's
# box/wheel/label/manual keys.


## Called when the menu panel becomes visible in the world.
func on_menu_shown() -> void:
	_menu_shown = true
	_flush_romm_notices()
	_romm_check_for_changes()



func on_menu_hidden() -> void:
	_menu_shown = false


## The cheapest possible "did anything change?" — /api/stats is public and ~100
## bytes. If the fingerprint matches, the library provably hasn't changed and no
## /api/roms call is made at all.
func _romm_check_for_changes() -> void:
	if romm_config == null or not romm_config.is_configured():
		return
	romm_client.stats(func(ok: bool, stats: Dictionary) -> void:
		if not ok or stats.is_empty():
			return
		var changed := not romm_config.stats_unchanged(stats)
		if changed:
			romm_config.last_stats = stats
			romm_config.save_config()
		# The cached list is already on screen; this corrects it in the
		# background and costs nothing visible.
		romm_fetch_platforms()
		if changed:
			_queue_delta_syncs()
	)


## The library moved since we last looked, so at least one synced platform is
## stale. Delta, not full: the watermark turns "one game was added" into a single
## small page instead of every page of the platform.
##
## Only platforms that already have an index are queued. One that has never been
## opened has nothing to bring up to date, and syncing it here would fetch a
## library the player has not asked to browse.
##
## Deletions are NOT reconciled by a delta — the merge only adds and updates, so
## a game removed on the server survives until a full sync. OPTIONS > Sync All
## remains the reconcile.
func _queue_delta_syncs() -> void:
	var stale: Array[String] = []
	for sid: String in _romm_platforms:
		if RommCatalog.has_index(sid):
			stale.append(sid)
	if stale.is_empty() or _menu == null:
		return
	_menu.queue_romm_sync(stale, false)


## Toasts can only be seen while the menu panel is open. A 4 GB download keeps
## running while the user plays, so terminal outcomes are queued and flushed
## (coalesced) the next time the menu opens, rather than vanishing unseen.
func _romm_notify_or_queue(key: String, icon: String, msg: String, dwell: float,
						   progress: float = -1.0) -> void:
	if _menu_shown:
		notify(key, icon, msg, progress, dwell)
	elif progress < 0.0:
		# Only outcomes are worth keeping for later. Queueing progress ticks
		# would bank hundreds of them and then replay a finished download.
		_romm_pending_notices.append({"ok": icon == "✅", "msg": msg})


## Called when the menu becomes visible.
func _flush_romm_notices() -> void:
	if _romm_pending_notices.is_empty():
		return
	var done := 0
	var failed := 0
	for n: Dictionary in _romm_pending_notices:
		if bool(n["ok"]):
			done += 1
		else:
			failed += 1
	_romm_pending_notices.clear()

	# One summary, not a replay of every toast.
	if done > 0 and failed == 0:
		notify("romm:flush", "✅", "%d download%s finished" % [done, "" if done == 1 else "s"],
			-1.0, MenuToasts.DWELL_INFO)
	elif done == 0 and failed > 0:
		notify("romm:flush", "❌", "%d download%s failed" % [failed, "" if failed == 1 else "s"],
			-1.0, MenuToasts.DWELL_FAIL)
	else:
		notify("romm:flush", "✅", "%d finished · %d failed" % [done, failed],
			-1.0, MenuToasts.DWELL_FAIL)


func _on_romm_auth_failed(detail: String) -> void:
	push_warning("[RomM] auth failed: %s" % detail)
	notify("romm:conn", "❌", "RomM sign-in expired — check OPTIONS", -1.0, MenuToasts.DWELL_FAIL)


## Fires only on a transition, so a dead server can't produce a toast stream.
##
## Repaints in BOTH directions: the cached index keeps listing server-only titles
## whether or not the server answers, so the rows have to say which of them can
## still be acted on — and say it again when it comes back.
func _on_romm_reachability_changed(reachable: bool) -> void:
	if _romm_list != null and is_instance_valid(_romm_list):
		_romm_list.rebind_visible()
	_romm_update_empty_label()
	if reachable:
		return
	notify("romm:conn", "❌", "RomM unreachable", -1.0, MenuToasts.DWELL_FAIL)


## Fires twice: once before the first request, then again with the real total
## once page one lands. The toast updates in place.
func _on_romm_sync_started(systemid: String, total: int) -> void:
	var label := _system_label(systemid)
	if total <= 0:
		notify("romm:sync:" + systemid, "⏳", "Fetching the %s list from RomM…" % label, -1.0)
	else:
		notify("romm:sync:" + systemid, "⏳",
			"Syncing %s · 0 / %s" % [label, _commas(total)], 0.0)
	# The toolbar button is this platform's stop button for as long as this runs.
	_romm_update_resync_btn()


func _on_romm_sync_progress(systemid: String, done: int, total: int) -> void:
	var frac := (float(done) / float(total)) if total > 0 else -1.0
	notify("romm:sync:" + systemid, "⏳",
		"Syncing %s · %s / %s" % [_system_label(systemid), _commas(done), _commas(total)], frac)


func _on_romm_sync_finished(systemid: String, ok: bool, added: int, removed: int, error: String) -> void:
	var key := "romm:sync:" + systemid
	var label := _system_label(systemid)
	# Back to offering a resync, whichever way this ended.
	_romm_update_resync_btn()

	if not ok:
		notify(key, "❌", "RomM sync failed — %s" % error, -1.0, MenuToasts.DWELL_FAIL)
		# Still announced: this is what pumps the sync queue, so returning
		# quietly strands every platform behind the one that failed.
		romm_state_changed.emit()
		return

	# Record the watermark so the next open can skip the network entirely.
	var meta := RommCatalog.read_meta(systemid)
	romm_config.set_sync_state(systemid, str(meta.get("updated_after", "")), int(meta.get("total", 0)))
	romm_config.save_config()

	if added > 0:
		notify(key, "✅", "%s · %d new game%s" % [label, added, "" if added == 1 else "s"],
			-1.0, MenuToasts.DWELL_INFO)
	elif removed > 0:
		notify(key, "✅", "%s · %d game%s removed" % [label, removed, "" if removed == 1 else "s"],
			-1.0, MenuToasts.DWELL_INFO)
	else:
		notify(key, "✅", "%s · up to date" % label, -1.0, 1.5)

	# The open detail page is showing a stale list — rebuild it against the new index.
	if systemid == _romm_detail_systemid:
		_rebuild_romm_rows()
	romm_state_changed.emit()


## Delta by default — this is the "I just added a game" button, and a full
## re-fetch of a large platform is ~20 pages. A platform with no index yet is
## already having a full sync started for it by the open itself.
## Paint the toolbar button for what pressing it will do right now — resync this
## platform, or stop the sync that is already running on it.
func _romm_update_resync_btn() -> void:
	if _romm_resync_btn == null or not is_instance_valid(_romm_resync_btn):
		return
	var label := _system_label(_romm_detail_systemid)
	if _romm_syncing_this_platform():
		_romm_resync_btn.text = String.chr(MenuIcons.CROSS)
		_romm_resync_btn.add_theme_color_override("font_color", MenuIcons.TINT_DELETE)
		_romm_resync_btn.tooltip_text = "Stop syncing %s" % label
	else:
		_romm_resync_btn.text = String.chr(MenuIcons.RETRY)
		_romm_resync_btn.remove_theme_color_override("font_color")
		_romm_resync_btn.tooltip_text = \
			"Check RomM for changes to %s, and drop entries the server has lost" % label


func _romm_syncing_this_platform() -> bool:
	return romm_catalog != null and romm_catalog.is_syncing() \
		and romm_catalog.syncing_systemid() == _romm_detail_systemid


## Resync, or stop — whichever the button is currently offering. Everything the
## stop needs to tidy up happens in _on_romm_sync_aborted, so that a cancel from
## OPTIONS cleans up identically.
func _on_romm_resync_pressed(systemid: String) -> void:
	if _menu == null:
		return
	if romm_catalog != null and romm_catalog.is_syncing() \
			and romm_catalog.syncing_systemid() == systemid:
		romm_catalog.abort_sync()
		return
	if not RommCatalog.has_index(systemid):
		return
	_menu.queue_romm_sync([systemid], false)


## Tidy up after a cancelled sync, from wherever it was cancelled.
##
## The half-written index is not a concern — pages go to index.jsonl.part and
## swap in atomically at the end, so the previous index survives untouched.
## Emitting romm_state_changed is what advances the queue: only this platform
## was stopped, and anything queued behind it still wants to run. OPTIONS clears
## the queue before it aborts, so its Stop really does stop everything.
func _on_romm_sync_aborted(systemid: String) -> void:
	# abort_sync is also the teardown path, so this can fire while the menu is on
	# its way out. `if _menu` inside the notify wrappers is not enough — a freed
	# Object is still truthy in GDScript.
	if not is_instance_valid(_menu):
		return
	notify_clear("romm:sync:" + systemid)
	notify("romm:conn", "⏹", "Stopped syncing %s" % _system_label(systemid),
		-1.0, MenuToasts.DWELL_OK)
	_romm_update_resync_btn()
	_romm_update_empty_label()
	romm_state_changed.emit()


func _on_romm_dl_started(rom_id: int, label: String, total_bytes: int) -> void:
	_romm_dl_labels[rom_id] = label
	# A ROM tapped again after a failed run must not inherit that run's count.
	_romm_dl_attempt[rom_id] = 0
	notify_clear("romm:dl:%d:why" % rom_id)
	notify("romm:dl:%d" % rom_id, "⬇", "%s · %s" % [label, MenuStyle.human_bytes(total_bytes)], 0.0)
	# Resolved once; a scan per progress tick would be O(rows) on an 11k list.
	_romm_dl_row_index = -1
	for i in _romm_rows.size():
		if romm_catalog.rom_id_at(int(_romm_rows[i].get("index", -1))) == rom_id:
			_romm_dl_row_index = i
			break


## Progress arrives every 256 KB — ~700 times for a 178 MB ROM, ~16,000 for a
## 4 GB one. Rebinding the whole visible window each time meant thousands of
## row binds, each doing a gamelist scan and several file_exists calls on the
## main thread; with an emulator running that reads as a hard freeze. Only act
## when the displayed percentage actually changes, and touch one row.
func _on_romm_dl_progress(rom_id: int, received: int, total: int) -> void:
	# Clamped because the total is the catalog's size for the ROM, while the body
	# may be a container the server generated around it — a few hundred bytes
	# larger. "101%" reads as a bug in the bar rather than what it is.
	var frac := clampf(float(received) / float(total), 0.0, 1.0) if total > 0 else -1.0
	var pct := int(frac * 100.0) if frac >= 0.0 else 0
	if int(_romm_progress_pct.get(rom_id, -1)) == pct:
		return
	_romm_progress_pct[rom_id] = pct
	var attempt := int(_romm_dl_attempt.get(rom_id, 0))
	notify("romm:dl:%d" % rom_id, "⬇",
		"%s%s · %d%% · %s / %s" % [_romm_dl_label(rom_id),
			"" if attempt <= 0 else "  (attempt %d)" % attempt, pct,
			MenuStyle.human_bytes(received), MenuStyle.human_bytes(total)], frac)
	if _romm_list != null and is_instance_valid(_romm_list):
		_romm_list.rebind_index(_romm_dl_row_index)


## The reason gets a toast of its own, not the download's.
##
## A retry resumes within its backoff and the first progress tick lands 256 KB
## later, which on a LAN is immediate — sharing the download's key meant the only
## place the failure was ever named got overwritten before it could be read, and
## a run that failed three times looked like one that simply stopped. This one
## dwells like any other failure, beside the bar rather than on top of it.
func _on_romm_dl_retrying(rom_id: int, attempt: int, max_attempts: int, reason: String) -> void:
	_romm_dl_attempt[rom_id] = attempt
	notify("romm:dl:%d" % rom_id, "⏳",
		"%s — retry %d/%d" % [_romm_dl_label(rom_id), attempt, max_attempts], -1.0)
	notify("romm:dl:%d:why" % rom_id, "⚠",
		"%s — %s" % [_romm_dl_label(rom_id),
			reason if not reason.is_empty() else "the transfer failed"],
		-1.0, MenuToasts.DWELL_FAIL)


## What this download is fetching, for every bar after the first.
func _romm_dl_label(rom_id: int) -> String:
	var label := str(_romm_dl_labels.get(rom_id, ""))
	return label if not label.is_empty() else "Download"


func _on_romm_dl_finished(rom_id: int, ok: bool, path: String, error: String) -> void:
	var key := "romm:dl:%d" % rom_id
	if ok:
		_romm_notify_or_queue(key, "✅", "%s ready" % path.get_file().get_basename(), MenuToasts.DWELL_OK)
		# A ROM that arrived by download is one nobody browsed to, so nobody is
		# going to press Scrape on it either. Queued, not fetched now: the
		# scraper is rate-limited and a batch download would outrun it.
		if _menu != null and "auto_scraper" in _menu:
			var scraper: AutoScraper = _menu.get("auto_scraper")
			if scraper != null:
				scraper.request(path, AutoScraper.systemid_for_path(path))
	else:
		_romm_notify_or_queue(key, "❌", "%s — %s" % [_romm_dl_label(rom_id), error],
			MenuToasts.DWELL_FAIL)
		# The server answered that this row's file is gone, which is the one
		# failure that will never come good on a retry. Take the row out now
		# rather than leaving a button that can only fail again — the next sync
		# would have done it, but not before the player pressed it twice.
		if error == RommHttp.ERR_GONE and romm_catalog != null \
				and not _romm_detail_systemid.is_empty():
			romm_catalog.remove_rows(_romm_detail_systemid, [rom_id])
	_romm_dl_labels.erase(rom_id)
	_romm_dl_attempt.erase(rom_id)
	# The final message names the same failure, so leaving the retry note up
	# would say it twice.
	notify_clear("romm:dl:%d:why" % rom_id)
	_romm_dl_row_index = -1
	_romm_meta_cache.clear()
	_invalidate_local_scan()
	_rebuild_romm_rows()


func _on_romm_dl_cancelled(rom_id: int) -> void:
	_romm_dl_labels.erase(rom_id)
	_romm_dl_attempt.erase(rom_id)
	notify_clear("romm:dl:%d" % rom_id)
	notify_clear("romm:dl:%d:why" % rom_id)
	_rebuild_romm_rows()


## Files silently vanishing from a library reads as data loss — always say so.
func _on_romm_cache_evicted(freed_bytes: int, count: int) -> void:
	notify("romm:cache", "🗑", "Freed %s — removed %d game%s"
		% [MenuStyle.human_bytes(freed_bytes), count, "" if count == 1 else "s"], -1.0, 4.0)


## Eviction can change a server row from local to downloadable and can remove
## companion-only rows, so rebuild the model rather than merely re-binding it.
func _on_romm_cache_changed() -> void:
	_romm_meta_cache.clear()
	_invalidate_local_scan()
	_rebuild_romm_rows()




func _on_romm_art_ready(_rom_id: int, _texture: Texture2D) -> void:
	if _romm_list != null and is_instance_valid(_romm_list):
		_romm_list.rebind_visible()


## A wheel or label finished decoding. Only the visible rows are re-bound, and
## the cache's per-frame budget means at most two of these land in one frame.
func _on_scraped_art_ready(_key: String, _texture: Texture2D) -> void:
	if _romm_list != null and is_instance_valid(_romm_list):
		_romm_list.rebind_visible()


func _system_label(systemid: String) -> String:
	var sysname := core_db.get_systemname_for_id(systemid)
	return sysname if not sysname.is_empty() else systemid


static func _commas(n: int) -> String:
	var s := str(n)
	var out := ""
	var c := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		c += 1
		if c % 3 == 0 and i > 0:
			out = "," + out
	return out


func _on_scrape_accepted(rom_path: String, systemid: String, result: Dictionary) -> void:
	_close_scrape_popup()

	var game_data := {
		"game_id": result.get("game_id", ""),
		"name": result.get("name", ""),
		"desc": result.get("desc", ""),
		"developer": result.get("developer", ""),
		"publisher": result.get("publisher", ""),
		"genre": result.get("genre", ""),
	}
	var rom_data := {
		"path": "./" + rom_path.get_file(),
		"romname": rom_path.get_file(),
		"releasedate": result.get("releasedate", ""),
		"region": result.get("rom_region", ""),
	}

	gamelist_manager.add_or_merge_rom(systemid, game_data, rom_data)
	gamelist_manager.save_gamelist(systemid)

	# Disconnect any stale media refresh callback from a previous accept
	if _media_dl_refresh_cb.is_valid() and \
			scraper_client.media_download_completed.is_connected(_media_dl_refresh_cb):
		scraper_client.media_download_completed.disconnect(_media_dl_refresh_cb)

	# Re-populate when a piece of art a row DRAWS finishes downloading, so the
	# list updates without requiring a manual tab switch.
	# Scoped to the ROM that was just scraped, and coalesced.
	#
	# This used to clear the whole art memo and rebuild both the tile grid and
	# the row model on EVERY file. download_all_media fetches up to four per
	# game and two of them landed here, so one accept ran that cycle twice and a
	# batch ran it dozens of times — each pass throwing away every other row's
	# decoded art and forcing it all to be read again. Measured before this:
	# 2.4 ms per wheel and 4.1 ms per label to re-decode, times every visible row.
	var scraped_rom := rom_path
	# LABEL is in this list because the row's thumbnail IS the label: a row with
	# no RomM cover falls back to the scraped label, and leaving it out meant the
	# one piece of art a freshly scraped game always has was the one piece that
	# never appeared until the platform was closed and reopened. Box is not, since
	# no row draws it.
	_media_dl_refresh_cb = func(mtype: String, _path: String) -> void:
		if mtype != "wheel" and mtype != "label" and mtype != "manual":
			return
		# Drop what cached a miss for this ROM before the art existed.
		if scraped_art != null:
			scraped_art.forget(systemid, scraped_rom)
		_romm_meta_cache.erase(scraped_rom)
		# ...then repaint the rows on screen, and nothing else.
		#
		# A piece of art landing changes neither the tile grid nor the row model
		# — only what an already-bound row draws. Rebuilding both cost 134 ms
		# measured, because _populate_cartridges_tab ends in browser.refresh(),
		# which re-runs the detail populator over every row of the open system:
		# 9,927 of them on this library, and then _rebuild_romm_rows did it a
		# second time. The name and metadata that DO change are handled by the
		# single _populate_cartridges_tab this accept already runs below.
		if _romm_list != null and is_instance_valid(_romm_list):
			_romm_list.rebind_visible()
	scraper_client.media_download_completed.connect(_media_dl_refresh_cb)

	# Download media files asynchronously
	var rom_basename := rom_path.get_file().get_basename()
	scraper_client.download_all_media(result, systemid, rom_basename)

	# Refresh immediately so the game name / metadata shows right away
	_populate_cartridges_tab()


func _add_scrape_info_row(parent: VBoxContainer, key: String, value: String) -> void:
	if value.is_empty():
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var k_lbl := Label.new()
	k_lbl.text = key + ":"
	k_lbl.add_theme_font_size_override("font_size", 17)
	k_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
	k_lbl.custom_minimum_size = Vector2(110, 0)
	row.add_child(k_lbl)

	var v_lbl := Label.new()
	v_lbl.text = value
	v_lbl.add_theme_font_size_override("font_size", 17)
	v_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	v_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	row.add_child(v_lbl)


func _show_game_detail_panel(game: Dictionary, systemid: String) -> void:
	_close_game_detail_panel()

	_game_detail_panel = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.1, 0.2, 0.98)
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		bg.set(k, 8)
	_game_detail_panel.add_theme_stylebox_override("panel", bg)
	_game_detail_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["margin_top","margin_bottom","margin_left","margin_right"]:
		margin.add_theme_constant_override(side, 14)
	_game_detail_panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	MenuStyle.fat_vscroll_bar(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	# Title
	var title := Label.new()
	title.text = game.get("name", "Unknown")
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(title)
	vbox.add_child(HSeparator.new())

	# Metadata
	_add_scrape_info_row(vbox, "Developer", game.get("developer", ""))
	_add_scrape_info_row(vbox, "Publisher", game.get("publisher", ""))
	_add_scrape_info_row(vbox, "Genre", game.get("genre", ""))

	vbox.add_child(HSeparator.new())

	# Description
	var desc: String = game.get("desc", "")
	if not desc.is_empty():
		var desc_lbl := Label.new()
		desc_lbl.text = desc
		desc_lbl.add_theme_font_size_override("font_size", 16)
		desc_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
		desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		vbox.add_child(desc_lbl)
		vbox.add_child(HSeparator.new())

	# ROM variants button (if game has more than 1 ROM)
	var roms: Array = game.get("roms", [])
	if roms.size() > 1:
		var variants_btn := Button.new()
		variants_btn.text = "  ROM Variants (%d)  " % roms.size()
		variants_btn.custom_minimum_size = Vector2(0, 56)
		variants_btn.add_theme_font_size_override("font_size", 20)
		variants_btn.pressed.connect(_show_rom_variants_panel.bind(game, systemid))
		vbox.add_child(variants_btn)

	# Close button
	var close_btn := Button.new()
	close_btn.text = "  CLOSE  "
	close_btn.custom_minimum_size = Vector2(0, 56)
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.pressed.connect(_close_game_detail_panel)
	vbox.add_child(close_btn)

	get_parent().add_child(_game_detail_panel)


func _close_game_detail_panel() -> void:
	_close_rom_variants_panel()
	if _game_detail_panel and is_instance_valid(_game_detail_panel):
		_game_detail_panel.queue_free()
	_game_detail_panel = null


## A game's saves and achievements, without going and finding the cartridge.
##
## The page IS the cartridge menu's — an embedded CartridgeOptions2D driven by a
## CartridgeOptionsPanel — so save recovery, RomM sync and the achievement list
## behave here exactly as they do there, and are written once.
##
## What it is pointed at depends on the room: the actual cartridge when one for
## this ROM has been spawned, so choosing a save binds it the way it always did;
## otherwise a CartridgeSaveTarget standing in for the ROM, which reads and syncs
## but has nothing to bind to.
func _show_game_saves_panel(systemid: String, rom_path: String, label: String) -> void:
	_close_game_saves_panel()

	_game_saves_panel = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	# Opaque: a list of save timestamps with the library's rows showing through it
	# is unreadable, and this page covers the whole content area.
	bg.bg_color = Color(0.1, 0.1, 0.2)
	for k in ["corner_radius_top_left", "corner_radius_top_right",
			  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
		bg.set(k, 8)
	_game_saves_panel.add_theme_stylebox_override("panel", bg)
	_game_saves_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
		margin.add_theme_constant_override(side, 14)
	_game_saves_panel.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	var ui := CartridgeOptions2D.create_embedded()
	vbox.add_child(ui)

	var close_btn := Button.new()
	close_btn.text = "  CLOSE  "
	close_btn.custom_minimum_size = Vector2(0, 56)
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.pressed.connect(_close_game_saves_panel)
	vbox.add_child(close_btn)

	get_parent().add_child(_game_saves_panel)

	# The driver goes in the page, so closing the page takes it with it. It is a
	# bare CartridgeOptionsPanel — no quad of its own, external UI only.
	_game_saves_driver = CartridgeOptionsPanel.new()
	_game_saves_panel.add_child(_game_saves_driver)
	var target: Object = _spawned_cartridge_for(rom_path)
	if target == null:
		target = CartridgeSaveTarget.create(systemid, rom_path, label)
	_game_saves_driver.adopt_external_ui(ui, target)


## The cartridge in the room holding this ROM, or null.
func _spawned_cartridge_for(rom_path: String) -> RetroCartridge:
	if rom_path.is_empty():
		return null
	for n: Node in get_tree().get_nodes_in_group("cartridge"):
		var cart := n as RetroCartridge
		if cart != null and cart.rom_path == rom_path:
			return cart
	return null


func _close_game_saves_panel() -> void:
	if _game_saves_panel and is_instance_valid(_game_saves_panel):
		_game_saves_panel.queue_free()
	_game_saves_panel = null
	_game_saves_driver = null


## What is written on a memory pack, without spawning it first.
##
## The same BsxPackContents2D the in-world panel floats beside the pack, embedded
## here — one list, two ways of reaching it. No driver object: unlike the saves
## page, which needs a CartridgeOptionsPanel to act on a real cartridge, a pack
## listing is read straight out of the file and acts on nothing.
func _show_pack_contents_panel(pack_path: String) -> void:
	_close_pack_contents_panel()

	_pack_contents_panel = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.1, 0.1, 0.2)
	_pack_contents_panel.add_theme_stylebox_override("panel", bg)
	_pack_contents_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 14)
	_pack_contents_panel.add_child(margin)

	var col := MenuStyle.vbox(10)
	margin.add_child(col)

	var ui := BsxPackContents2D.create_embedded()
	ui.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(ui)

	var close := MenuStyle.row_button("  CLOSE  ", 22, 0, 56, false)
	close.pressed.connect(_close_pack_contents_panel)
	col.add_child(close)

	get_parent().add_child(_pack_contents_panel)

	# After the tree add: populate() walks the node it built in _ready().
	var data := FileAccess.get_file_as_bytes(pack_path)
	ui.populate(pack_path.get_file().get_basename(),
		BsxPack.programmes_of(data),
		BsxPack.free_blocks(data),
		BsxPack.BLOCK_COUNT)


func _close_pack_contents_panel() -> void:
	if _pack_contents_panel and is_instance_valid(_pack_contents_panel):
		_pack_contents_panel.queue_free()
	_pack_contents_panel = null


func _show_rom_variants_panel(game: Dictionary, systemid: String) -> void:
	_close_rom_variants_panel()

	_rom_variants_panel = PanelContainer.new()
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.12, 0.12, 0.22, 0.98)
	for k in ["corner_radius_top_left","corner_radius_top_right",
			  "corner_radius_bottom_left","corner_radius_bottom_right"]:
		bg.set(k, 8)
	_rom_variants_panel.add_theme_stylebox_override("panel", bg)
	_rom_variants_panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var margin := MarginContainer.new()
	for side in ["margin_top","margin_bottom","margin_left","margin_right"]:
		margin.add_theme_constant_override(side, 14)
	_rom_variants_panel.add_child(margin)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	MenuStyle.fat_vscroll_bar(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(vbox)

	vbox.add_child(MenuStyle.label("ROM VARIANTS", 22, MenuStyle.COLOR_TITLE))
	vbox.add_child(HSeparator.new())

	var game_id: String = game.get("game_id", "")
	var roms: Array = game.get("roms", [])

	for rom: Dictionary in roms:
		var row := HBoxContainer.new()
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.custom_minimum_size = Vector2(0, 64)

		# Star (preferred) button
		var is_preferred: bool = rom.get("preferred", false)
		var star_btn := Button.new()
		star_btn.text = "⭐" if is_preferred else "☆"
		star_btn.custom_minimum_size = Vector2(56, 56)
		star_btn.add_theme_font_size_override("font_size", 22)
		var rom_path_rel: String = rom.get("path", "")
		star_btn.pressed.connect(func():
			gamelist_manager.set_preferred_rom(systemid, game_id, rom_path_rel)
			gamelist_manager.save_gamelist(systemid)
			gamelist_manager.invalidate(systemid)
			var updated_game := _find_game_by_id(systemid, game_id)
			if not updated_game.is_empty():
				_show_rom_variants_panel(updated_game, systemid)
			_populate_cartridges_tab()
		)
		row.add_child(star_btn)

		# ROM name / wheel
		var rom_btn := Button.new()
		rom_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rom_btn.custom_minimum_size = Vector2(0, 56)
		rom_btn.add_theme_font_size_override("font_size", 18)

		var romname: String = rom.get("romname", "")
		var wheel_tex := _load_wheel_texture(systemid, romname)
		if wheel_tex:
			rom_btn.icon = wheel_tex
			rom_btn.text = ""
			rom_btn.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			rom_btn.expand_icon = true
		else:
			rom_btn.text = romname.get_basename()

		var abs_path := GamelistManager.to_absolute_path(systemid, rom.get("path", ""))
		rom_btn.pressed.connect(spawn_cartridge_requested.emit.bind(abs_path, romname.get_basename(), systemid))

		row.add_child(rom_btn)

		# Region label
		var region_str: String = rom.get("region", "")
		if not region_str.is_empty():
			var region_lbl := Label.new()
			region_lbl.text = region_str
			region_lbl.add_theme_font_size_override("font_size", 14)
			region_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_LICENSE)
			region_lbl.custom_minimum_size = Vector2(50, 0)
			row.add_child(region_lbl)

		# Manual button
		if _has_scraped_manual(systemid, romname):
			var manual_btn := Button.new()
			manual_btn.text = "📖"
			manual_btn.custom_minimum_size = Vector2(56, 56)
			manual_btn.add_theme_font_size_override("font_size", 22)
			var pdf_path := RomLibrary.scraped_manual_path(systemid, romname)
			manual_btn.pressed.connect(spawn_manual_requested.emit.bind(pdf_path))
			row.add_child(manual_btn)

		vbox.add_child(row)

	vbox.add_child(HSeparator.new())

	var close_btn := Button.new()
	close_btn.text = "  CLOSE  "
	close_btn.custom_minimum_size = Vector2(0, 56)
	close_btn.add_theme_font_size_override("font_size", 20)
	close_btn.pressed.connect(_close_rom_variants_panel)
	vbox.add_child(close_btn)

	get_parent().add_child(_rom_variants_panel)


func _close_rom_variants_panel() -> void:
	if _rom_variants_panel and is_instance_valid(_rom_variants_panel):
		_rom_variants_panel.queue_free()
	_rom_variants_panel = null


func _load_wheel_texture(systemid: String, romname: String) -> Texture2D:
	if romname.is_empty():
		return null
	var base := romname.get_basename()
	var media_dir := RomLibrary.rom_dir_for_system(systemid).path_join("media/wheel")
	# Try common image extensions
	for ext in [".png", ".jpg", ".jpeg", ".webp"]:
		var path := media_dir.path_join(base + ext)
		if FileAccess.file_exists(path):
			var img := Image.load_from_file(path)
			if img:
				_fit_within(img, WHEEL_BOX)
				return ImageTexture.create_from_image(img)
	return null


## Scale an image down to fit a box, preserving aspect.
##
## Wheel logos are full-res (600x300 is typical) and were drawn via expand_icon,
## which scales them to a button far wider than it is tall — so the logo rendered
## much larger than its 100 px row and spilled across the boundary into the rows
## either side. Bounding the texture keeps it inside the row whatever its aspect;
## icon_max_width alone caps width only, which cannot bound a square-ish logo.
## (Measured: expand_icon does NOT inflate the button's minimum height, so this
## was a drawing-size problem, not a layout one.)
static func _fit_within(img: Image, box: Vector2i) -> void:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0 or (w <= box.x and h <= box.y):
		return
	var factor: float = minf(float(box.x) / float(w), float(box.y) / float(h))
	img.resize(maxi(1, int(round(w * factor))), maxi(1, int(round(h * factor))),
		Image.INTERPOLATE_LANCZOS)


func _populate_posters_tab() -> void:
	if not _posters_vbox:
		return
	_clear_vbox(_posters_vbox)
	var posters := RomLibrary.scan_posters()
	if posters.is_empty():
		var hint := Label.new()
		hint.text = "No images found in posters folder."
		hint.add_theme_color_override("font_color", MenuStyle.COLOR_DESC)
		hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_posters_vbox.add_child(hint)
		return
	for poster: Dictionary in posters:
		var btn := Button.new()
		btn.text = "  " + str(poster["label"])
		btn.custom_minimum_size = Vector2(0, 84)
		btn.add_theme_font_size_override("font_size", 24)
		var thumb := _cached_poster_thumb(str(poster["path"]))
		if thumb != null:
			btn.icon = thumb
			btn.add_theme_constant_override("icon_max_width", POSTER_THUMB_BOX.x)
		else:
			btn.text = "  🖼  " + str(poster["label"])
		btn.pressed.connect(spawn_poster_requested.emit.bind(poster["path"]))
		_posters_vbox.add_child(btn)
	_posters_vbox.add_child(MenuStyle.spacer(8))


## Memoized, misses included — a folder of large images would otherwise be decoded
## again on every tab entry.
func _cached_poster_thumb(path: String) -> Texture2D:
	if _poster_thumb_cache.has(path):
		return _poster_thumb_cache[path]
	var tex := _load_poster_thumb(path)
	_poster_thumb_cache[path] = tex
	_poster_thumb_order.append(path)
	while _poster_thumb_order.size() > MAX_POSTER_THUMBS:
		_poster_thumb_cache.erase(_poster_thumb_order.pop_front())
	return tex


## No mipmaps: this is a 2D icon drawn at one size, not print art on a wall.
func _load_poster_thumb(path: String) -> Texture2D:
	if not FileAccess.file_exists(path):
		return null
	var img := Image.load_from_file(path)
	if img == null:
		return null
	_fit_within(img, POSTER_THUMB_BOX)
	return ImageTexture.create_from_image(img)


func _has_scraped_manual(systemid: String, romname: String) -> bool:
	if romname.is_empty():
		return false
	return FileAccess.file_exists(RomLibrary.scraped_manual_path(systemid, romname))


func _find_game_by_id(systemid: String, game_id: String) -> Dictionary:
	var gamelist := gamelist_manager.load_gamelist(systemid)
	for g: Dictionary in gamelist.get("games", []):
		if g.get("game_id", "") == game_id:
			return g
	return {}
