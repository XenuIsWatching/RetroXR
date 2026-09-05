## Reusable drill-down browser for "lots of systems" lists (cores, ROMs, …).
##
## Home page  : optional filter box + a wrapping grid of big system tiles.
## Detail page: a "◀ Back" header + a scroll area filled on demand by the caller's
##              populator with that one system's rows.
##
## Only one page is visible at a time (VR-friendly: one level, big targets, no
## horizontally-scrolling tab strip). The host wires `active_scroll_changed` into
## its VR trigger-scroll plumbing so the visible page scrolls.
##
## Usage:
##   var b := SystemGridBrowser.new()
##   b.set_detail_populator(func(sid, vbox): ...fill vbox with sid's rows...)
##   b.set_systems([{ "systemid": "nes", "name": "Nintendo (NES)", "badge": "3 cores" }, ...])
class_name SystemGridBrowser
extends VBoxContainer

## Emitted whenever the visible page changes (home ↔ detail); carries the
## ScrollContainer the host should treat as the active scroll target.
signal active_scroll_changed(scroll: ScrollContainer)
## Emitted after a system tile is opened.
signal system_opened(systemid: String)
## Emitted after a view preference the grids share is changed here — the hidden
## list, or the compact switch. A host with more than one grid repaints the rest.
signal grid_prefs_changed()

# Palette — mirrors spawn_menu.gd so the widget matches the surrounding UI.
const COLOR_TITLE      := Color(0.9,  0.9,  1.0)
const COLOR_DESC       := Color(0.55, 0.55, 0.68)
const COLOR_LICENSE    := Color(0.65, 0.65, 0.80)
## The half of the corner badge that is already on this device. Green because
## that is what green means everywhere else here — the firmware ticks, the
## Installed labels — so a tile reads without a legend. Kept as a local constant
## rather than MenuIcons.TINT_OK: this browser has no other dependency on the
## menu's icon set and is the poorer for gaining one.
const COLOR_BADGE_HERE := Color(0.62, 0.82, 0.66)
const COLOR_TILE       := Color(0.14, 0.14, 0.28)
const COLOR_TILE_HOVER := Color(0.24, 0.24, 0.46)
## The plate a tile carrying `"alt_tile": true` sits on — same weight as the
## default, hue turned to purple. What it means is the host's to decide: the
## Download grid marks a system with no core installed with it.
const COLOR_TILE_ALT       := Color(0.22, 0.11, 0.30)
const COLOR_TILE_ALT_HOVER := Color(0.37, 0.19, 0.50)

# ── Config (set before the node enters the tree, or any time) ──────────────────
## Show the pointer-first filter box on the home page.
var show_filter: bool = true
## Placeholder shown in the filter box.
var filter_placeholder: String = "Filter systems…"
## Message shown when there are no systems.
var empty_text: String = "Nothing here yet."
## Minimum size of each system tile.
var tile_min_size: Vector2 = Vector2(250, 96)
## Draw each tile with the system's media art — its cartridge, disc or tape —
## instead of the console itself. For grids whose tiles stand for a game.
var use_content_art: bool = false
## Offer the player a Hide button on each system's detail page, and a toggle
## beside the filter box for bringing the hidden ones back. The Cores browser
## leaves this off: hiding a system there would hide the very tile you go to in
## order to install a core for it.
var allow_hiding: bool = false
## Offer the Compact switch, which drops every tile to a square of bare art.
## Same two grids as allow_hiding; the Cores browser reads by core name and
## would be unusable without its labels.
var allow_compact: bool = false

## Edge of the square the console art is fitted into, inside a tile.
const ICON_PX := 60.0
## Minimum width of a COMPACT tile. Small, because the whole point is to get a
## lot of them on screen; _update_tile_columns then squares them off against
## whatever width the row actually shares out.
const COMPACT_TILE_PX := 132.0
## What the art gives up to the tile edge in compact mode, so neighbouring
## machines do not read as one continuous strip.
const COMPACT_INSET_PX := 10.0
## Source-badge mark in the tile's bottom-right corner.
const BADGE_MARK_PX := 26.0
## Right margin the name column gives up so it cannot run under that badge.
## One value, whether the badge shows one number or two. A wider reserve for the
## pair cost the name column more than the badge gained: at 86 px names began
## breaking mid-word — "Famico|m Disk", "GameC|ube" — because this label wraps
## before it ellipsizes. The badge is an overlay growing leftward from the
## corner and may reach a little past this line; the reserve only has to stop the
## name running UNDER it, and the ellipsis lands well before that.
const BADGE_RESERVE_PX := 52.0
## Right margin given up for a top-right corner glyph when there is no source
## badge below it. Narrower than BADGE_RESERVE_PX because a glyph carries no
## count beside it; when both show, the wider reserve covers each.
const CORNER_GLYPH_RESERVE_PX := 34.0

# ── State ──────────────────────────────────────────────────────────────────────
# Each entry: { "systemid": String, "name": String, "badge": String (optional),
#               "alt_tile": bool (optional),
#               "corner_glyph": String, "corner_glyph_color": Color,
#               "corner_glyph_tip": String (all optional) }
var _systems: Array = []
var _detail_populator: Callable = Callable()
var _current_systemid: String = ""
var _built: bool = false
## Set only while refresh() re-runs the populator. A populator that owns filter
## state reads this to tell a background rebuild from the user opening the page:
## navigation clears filters, a rebuild must leave them alone.
var _refreshing: bool = false
var _hide_btn: Button = null
var _show_hidden_btn: Button = null
var _compact_btn: Button = null

# ── Nodes ──────────────────────────────────────────────────────────────────────
var _home_page:    VBoxContainer   = null
var _detail_page:  VBoxContainer   = null
var _filter_edit:  LineEdit        = null
var _home_toolbar: HBoxContainer   = null
var _home_scroll:  ScrollContainer = null
var _tiles_grid:   GridContainer   = null
var _home_empty:   Label           = null
var _detail_scroll: ScrollContainer = null
var _detail_vbox:  VBoxContainer   = null
var _detail_title: Label           = null
## The nested page's back step, and the system title to restore when it ends.
var _subpage_back: Callable = Callable()
var _detail_home_title := ""
var _detail_toolbar: HBoxContainer = null


func _ready() -> void:
	_ensure_built()


# ── Public API ─────────────────────────────────────────────────────────────────

## Replace the system list and rebuild the home grid. Keeps the current page.
func set_systems(systems: Array) -> void:
	_ensure_built()
	_systems = systems.duplicate(true)
	_systems.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a.get("name", "") as String).naturalnocasecmp_to(b.get("name", "")) < 0
	)
	_rebuild_tiles()


## Provide the callback that fills a system's detail page:
## `func(systemid: String, vbox: VBoxContainer) -> void`.
func set_detail_populator(cb: Callable) -> void:
	_detail_populator = cb


## Open a system's detail page and (re)run the populator for it.
## Pinned row above the detail scroll area, for search and filters. Cleared on
## every open_system; add children from the detail populator.
func detail_toolbar() -> HBoxContainer:
	_ensure_built()
	return _detail_toolbar


## Pinned row on the HOME page, between the filter box and the tile grid — for a
## control that acts on the whole list rather than on one system, and so has no
## meaning once you have drilled into one.
##
## Unlike detail_toolbar this is built once and never cleared: the home page is
## not rebuilt on navigation, so the host fills it during its own build and the
## row survives every trip in and out of a system.
##
## Asking for it is what shows it — an empty row would otherwise take a slice of
## the grid's height on every browser that has no use for one.
func home_toolbar() -> HBoxContainer:
	_ensure_built()
	_home_toolbar.visible = true
	return _home_toolbar


func open_system(systemid: String) -> void:
	_ensure_built()
	_current_systemid = systemid
	for c in _detail_vbox.get_children():
		c.queue_free()
	for c in _detail_toolbar.get_children():
		_detail_toolbar.remove_child(c)
		c.queue_free()
	_detail_toolbar.visible = false
	var display_name := systemid
	for s: Dictionary in _systems:
		if s.get("systemid", "") == systemid:
			display_name = s.get("name", systemid)
			break
	_detail_title.text = display_name
	_subpage_back = Callable()
	_detail_home_title = display_name
	_sync_hide_button()
	if _detail_populator.is_valid():
		_detail_populator.call(systemid, _detail_vbox)
	_home_page.visible = false
	_detail_page.visible = true
	_detail_scroll.scroll_vertical = 0
	system_opened.emit(systemid)
	active_scroll_changed.emit(_detail_scroll)


## A page opened INSIDE a system's detail page — the memory-card shelf, say.
##
## The detail page already has a Back button and a title, so a nested page that
## draws its own leaves two stacked Back buttons and two titles. Instead it hands
## its title and its own back action here, and the ONE header does the work:
## Back walks the trail one step, and only returns to the grid once the trail is
## empty. Each step re-declares the step behind it, so this holds a single level
## rather than a stack.
func push_subpage(title: String, on_back: Callable) -> void:
	_ensure_built()
	if _subpage_back.is_valid() == false:
		_detail_home_title = _detail_title.text
	_subpage_back = on_back
	_detail_title.text = title


## Drop back to the system's own page, restoring its title.
func clear_subpage() -> void:
	_ensure_built()
	_subpage_back = Callable()
	if not _detail_home_title.is_empty():
		_detail_title.text = _detail_home_title


func _on_detail_back() -> void:
	if _subpage_back.is_valid():
		var step := _subpage_back
		_subpage_back = Callable()
		step.call()
		return
	show_home()


## Return to the home grid.
func show_home() -> void:
	_ensure_built()
	_current_systemid = ""
	_detail_page.visible = false
	_home_page.visible = true
	active_scroll_changed.emit(_home_scroll)


## Rebuild home tiles; if a detail page is open, re-run its populator.
## Keeps your place in the list. A refresh is not navigation — it fires when a
## scrape finishes, when a wheel image finally downloads, when a sync lands — and
## open_system() below rightly scrolls to the top, which threw you back to row
## one of a thousand-ROM list because something completed in the background.
##
## The scroll offset alone is not your place: a populator that filters its rows
## must keep that filter too, or the offset is restored into a different list.
func refresh() -> void:
	_ensure_built()
	_rebuild_tiles()
	refresh_detail()


## Re-run the populator for the open system, leaving the tile grid alone.
##
## For a host that has just called set_systems(), which rebuilt the tiles as part
## of its own work — refresh() would then build all of them a second time, and
## that is 19 ms on a 68-tile grid.
func refresh_detail() -> void:
	_ensure_built()
	if _detail_page.visible and not _current_systemid.is_empty():
		var at := _detail_scroll.scroll_vertical
		_refreshing = true
		open_system(_current_systemid)
		_refreshing = false
		_restore_detail_scroll(at)


## True while the detail populator is being re-run by refresh() rather than by
## the user opening a system.
func is_refreshing() -> bool:
	return _refreshing


## Hide or unhide whichever system's detail page is open, then go back — the
## page you are standing on is about to vanish from the grid behind it, and
## staying there would leave you looking at a system the grid says is gone.
func _on_hide_pressed() -> void:
	if _current_systemid.is_empty():
		return
	var now_hidden := not AppPrefs.is_system_hidden(_current_systemid)
	AppPrefs.set_system_hidden(_current_systemid, now_hidden)
	_rebuild_tiles()
	grid_prefs_changed.emit()
	# Unhiding is done FROM the hidden list, so stay put and just relabel; the
	# tile is already back behind you.
	if now_hidden:
		show_home()
	else:
		_sync_hide_button()


## Match the header button to the open system's state.
func _sync_hide_button() -> void:
	if _hide_btn == null:
		return
	_hide_btn.visible = allow_hiding and not _current_systemid.is_empty()
	_hide_btn.text = "Unhide" if AppPrefs.is_system_hidden(_current_systemid) else "Hide"


## Match the home toggle to how many systems are hidden. Hidden entirely at zero:
## a button reading "Hidden (0)" is a control with nothing to control.
func _sync_hidden_toggle(count: int) -> void:
	if _show_hidden_btn == null:
		return
	_show_hidden_btn.visible = count > 0
	_show_hidden_btn.set_pressed_no_signal(AppPrefs.show_hidden_systems)
	_show_hidden_btn.text = "Hidden (%d)" % count


## The page was just rebuilt, so its height is not settled until the containers
## have re-laid out; assigning scroll_vertical before that clamps it against the
## old, shorter content and quietly lands short.
func _restore_detail_scroll(at: int) -> void:
	if at <= 0:
		return
	await get_tree().process_frame
	await get_tree().process_frame
	if is_instance_valid(_detail_scroll):
		_detail_scroll.scroll_vertical = at


## The system whose detail page is open, or "" on the home grid.
func current_systemid() -> String:
	return _current_systemid


## The ScrollContainer of the currently-visible page (for _active_scroll wiring).
func get_active_scroll() -> ScrollContainer:
	_ensure_built()
	return _detail_scroll if _detail_page.visible else _home_scroll


# ── Build ──────────────────────────────────────────────────────────────────────

func _ensure_built() -> void:
	if _built:
		return
	_built = true

	# Home page ---------------------------------------------------------------
	_home_page = VBoxContainer.new()
	_home_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_home_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_home_page.add_theme_constant_override("separation", 8)
	add_child(_home_page)

	if show_filter or allow_hiding or allow_compact:
		var filter_row := HBoxContainer.new()
		filter_row.add_theme_constant_override("separation", 8)
		_home_page.add_child(filter_row)

		if show_filter:
			_filter_edit = LineEdit.new()
			_filter_edit.placeholder_text = filter_placeholder
			_filter_edit.clear_button_enabled = true
			_filter_edit.custom_minimum_size = Vector2(0, 52)
			_filter_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_filter_edit.add_theme_font_size_override("font_size", 20)
			# Do NOT grab_focus() programmatically — Android EditText desync
			# (Godot #72969). Tap-to-focus opens the overlay keyboard naturally.
			_filter_edit.text_changed.connect(_on_filter_changed)
			filter_row.add_child(_filter_edit)

		if allow_hiding:
			# Here as well as in OPTIONS because this is where you are standing
			# when you notice something missing; walking out to OPTIONS and back
			# to unhide one system is a long trip in a headset. Same pref either
			# way. Shown only when there IS something hidden — otherwise it is a
			# control that does nothing.
			_show_hidden_btn = Button.new()
			_show_hidden_btn.toggle_mode = true
			_show_hidden_btn.custom_minimum_size = Vector2(190, 52)
			_show_hidden_btn.add_theme_font_size_override("font_size", 18)
			_show_hidden_btn.toggled.connect(func(on: bool) -> void:
				AppPrefs.show_hidden_systems = on
				AppPrefs.save_prefs()
				_rebuild_tiles()
				grid_prefs_changed.emit()
			)
			filter_row.add_child(_show_hidden_btn)

		if allow_compact:
			_compact_btn = Button.new()
			_compact_btn.toggle_mode = true
			_compact_btn.text = "Compact"
			_compact_btn.custom_minimum_size = Vector2(150, 52)
			_compact_btn.add_theme_font_size_override("font_size", 18)
			_compact_btn.set_pressed_no_signal(AppPrefs.compact_tiles)
			_compact_btn.toggled.connect(func(on: bool) -> void:
				AppPrefs.compact_tiles = on
				AppPrefs.save_prefs()
				_rebuild_tiles()
				grid_prefs_changed.emit()
			)
			filter_row.add_child(_compact_btn)

	_home_toolbar = HBoxContainer.new()
	_home_toolbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_home_toolbar.add_theme_constant_override("separation", 8)
	_home_toolbar.visible = false
	_home_page.add_child(_home_toolbar)

	_home_scroll = ScrollContainer.new()
	_home_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_home_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_home_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_home_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	MenuStyle.fat_vscroll_bar(_home_scroll)
	_home_scroll.resized.connect(_update_tile_columns)
	_home_page.add_child(_home_scroll)

	# A GridContainer, not an HFlowContainer. A flow packs its children at their
	# minimum width and leaves whatever is left over as a gutter down the right
	# edge; a grid whose children EXPAND_FILL shares each row out evenly, so
	# widening the panel stretches the tiles until another whole one fits.
	_tiles_grid = GridContainer.new()
	_tiles_grid.columns = 1
	_tiles_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tiles_grid.add_theme_constant_override("h_separation", 10)
	_tiles_grid.add_theme_constant_override("v_separation", 10)
	_home_scroll.add_child(_tiles_grid)

	_home_empty = Label.new()
	_home_empty.text = empty_text
	_home_empty.add_theme_font_size_override("font_size", 18)
	_home_empty.add_theme_color_override("font_color", COLOR_LICENSE)
	_home_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_home_empty.visible = false
	_home_page.add_child(_home_empty)

	# Detail page -------------------------------------------------------------
	_detail_page = VBoxContainer.new()
	_detail_page.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_page.add_theme_constant_override("separation", 8)
	_detail_page.visible = false
	add_child(_detail_page)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	_detail_page.add_child(header)

	var back := Button.new()
	back.add_theme_font_override("font", MenuIcons.symbols())
	back.text = "%s  Back" % String.chr(MenuIcons.BACK)
	back.custom_minimum_size = Vector2(150, 52)
	back.add_theme_font_size_override("font_size", 20)
	back.pressed.connect(_on_detail_back)
	header.add_child(back)

	_detail_title = Label.new()
	_detail_title.add_theme_font_size_override("font_size", 24)
	_detail_title.add_theme_color_override("font_color", COLOR_TITLE)
	_detail_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_detail_title.clip_text = true
	header.add_child(_detail_title)

	# In the header rather than _detail_toolbar: the toolbar is cleared and
	# refilled by the host's populator on every open_system, and the Cartridges
	# tab already fills it with search. Here it is built once and cannot collide.
	_hide_btn = Button.new()
	_hide_btn.custom_minimum_size = Vector2(150, 52)
	_hide_btn.add_theme_font_size_override("font_size", 20)
	_hide_btn.visible = allow_hiding
	_hide_btn.pressed.connect(_on_hide_pressed)
	header.add_child(_hide_btn)

	_detail_page.add_child(HSeparator.new())

	# Sits outside the scroll area, so search and filters stay put while the
	# list scrolls under them. Filled by the host's detail populator.
	_detail_toolbar = HBoxContainer.new()
	_detail_toolbar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_toolbar.add_theme_constant_override("separation", 8)
	_detail_toolbar.visible = false
	_detail_page.add_child(_detail_toolbar)

	_detail_scroll = ScrollContainer.new()
	_detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_scroll.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_detail_scroll.vertical_scroll_mode   = ScrollContainer.SCROLL_MODE_SHOW_ALWAYS
	MenuStyle.fat_vscroll_bar(_detail_scroll)
	_detail_page.add_child(_detail_scroll)

	_detail_vbox = VBoxContainer.new()
	_detail_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_vbox.add_theme_constant_override("separation", 6)
	_detail_scroll.add_child(_detail_vbox)


## As many whole tiles across as fit at their minimum width; the row then shares
## out what is left over, so there is no ragged gutter down the right.
##
## Measured from the SCROLL, never from the grid. A grid's minimum width is
## columns * tile_min_size.x, so reading its own size to choose the column count
## is a feedback loop: too many columns inflates the minimum, the grid overflows
## the scroll instead of shrinking, and the inflated width justifies the column
## count that caused it. It latches on the first wide measurement and never
## recovers — the Cartridges grid sat at 6 columns / 1550 px at every panel size
## while Systems, which happened to be measured narrow first, tracked correctly.
func _update_tile_columns() -> void:
	if _tiles_grid == null or _home_scroll == null:
		return
	var avail := _home_scroll.size.x
	var bar := _home_scroll.get_v_scroll_bar()
	if bar != null and bar.visible:
		avail -= bar.size.x
	if avail <= 0.0:
		return
	var sep := float(_tiles_grid.get_theme_constant("h_separation"))
	var min_w := COMPACT_TILE_PX if _compact() else tile_min_size.x
	var per := maxf(min_w, 1.0) + sep
	var n := maxi(1, int(floor((avail + sep) / per)))
	if _tiles_grid.columns != n:
		_tiles_grid.columns = n

	# A square tile cannot ask for its own height: the width is whatever the row
	# shares out, which is known only here. Setting the HEIGHT is safe where
	# setting a width would not be — height never feeds back into the width this
	# count was measured from.
	if _compact():
		var w := (avail - sep * (n - 1)) / float(n)
		for c in _tiles_grid.get_children():
			var tile := c as Control
			if tile != null:
				tile.custom_minimum_size.y = maxf(w, COMPACT_TILE_PX)


func _rebuild_tiles() -> void:
	for c in _tiles_grid.get_children():
		c.queue_free()
	# Filtered here rather than by the host, so set_systems() keeps the whole
	# list and unhiding needs no round trip back to whoever built it.
	var shown: Array = []
	var hidden_count := 0
	for s: Dictionary in _systems:
		if allow_hiding and AppPrefs.is_system_hidden(str(s.get("systemid", ""))):
			hidden_count += 1
			if not AppPrefs.show_hidden_systems:
				continue
		shown.append(s)
	_sync_hidden_toggle(hidden_count)
	_home_empty.visible = shown.is_empty()
	_home_scroll.visible = not shown.is_empty()
	for s: Dictionary in shown:
		_tiles_grid.add_child(_make_tile(s))
	_update_tile_columns()
	if _filter_edit and not _filter_edit.text.is_empty():
		_on_filter_changed(_filter_edit.text)


func _make_tile(s: Dictionary) -> Button:
	var sid: String   = s.get("systemid", "")
	var display_name: String = s.get("name", sid)
	var badge: String = s.get("badge", "")
	var alt: bool     = bool(s.get("alt_tile", false))

	var btn := Button.new()
	# Height only. A width minimum here would become the grid's minimum, and
	# with horizontal scrolling disabled the ScrollContainer inherits that as
	# ITS minimum — so a wide grid widens the very container the column count is
	# measured against, and the count can never come back down. tile_min_size.x
	# is honoured by _update_tile_columns deciding how many fit instead.
	# Compact tiles are squared off by _update_tile_columns once it knows how
	# wide a column actually came out; this is only the floor.
	btn.custom_minimum_size = Vector2(0, COMPACT_TILE_PX if _compact() else tile_min_size.y)
	# EXPAND_FILL is what makes the grid divide each row between its tiles
	# rather than leaving every one at its minimum with the slack on the right.
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.set_meta("filter_name", display_name.to_lower())

	# A hidden tile only appears at all while the Hidden toggle is on, so it is
	# dimmed to say why it is here — otherwise turning the toggle on just makes
	# the grid longer with no clue which rows are the hidden ones.
	if allow_hiding and AppPrefs.is_system_hidden(sid):
		btn.modulate = Color(1, 1, 1, 0.45)

	var art_compact := SystemIcons.for_content(sid) if use_content_art \
		else SystemIcons.for_system(sid)
	if _compact():
		# Nothing but the art. The name goes to the tooltip rather than nowhere:
		# two Sega add-ons are hard to tell apart at this size, and the detail
		# page is one press away either way.
		btn.tooltip_text = display_name
		if art_compact:
			var big := TextureRect.new()
			big.texture = art_compact
			big.set_anchors_preset(Control.PRESET_FULL_RECT)
			big.offset_left = COMPACT_INSET_PX
			big.offset_top = COMPACT_INSET_PX
			big.offset_right = -COMPACT_INSET_PX
			big.offset_bottom = -COMPACT_INSET_PX
			big.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			big.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			big.mouse_filter = Control.MOUSE_FILTER_IGNORE
			btn.add_child(big)
		style_tile(btn, alt)
		btn.pressed.connect(open_system.bind(sid))
		return btn

	# Console art on the left, name (and badge) on the right. Laid out as child
	# controls rather than Button.icon + Button.text: Button draws its icon at
	# the texture's own size, and these SVGs import ~165 px on the long edge.
	var mark: Texture2D = s.get("badge_icon")
	var mark_count := int(s.get("badge_count", 0))
	var has_mark := mark != null and mark_count > 0
	# -1, not 0: a host that sets no local count gets the single-number badge it
	# always had, while a host that genuinely counted zero still shows "0 / N".
	var mark_here := int(s.get("badge_here", -1))
	var has_pair := has_mark and mark_here >= 0

	# A glyph for the top-right corner, supplied by the host the same way the
	# source badge is. Kept as text plus a colour rather than a lookup here, so
	# this browser stays clear of whatever the mark happens to mean.
	var corner_glyph: String = s.get("corner_glyph", "")
	var has_glyph := corner_glyph != ""

	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 12
	# Keep the name clear of the corner badge, which is an overlay and so does
	# not take part in this layout.
	var right_reserve := -12.0
	if has_mark:
		right_reserve = -BADGE_RESERVE_PX
	elif has_glyph:
		right_reserve = -CORNER_GLYPH_RESERVE_PX
	row.offset_right = right_reserve
	row.add_theme_constant_override("separation", 10)
	btn.add_child(row)

	var art := SystemIcons.for_content(sid) if use_content_art else SystemIcons.for_system(sid)
	if art:
		var ico := TextureRect.new()
		ico.texture = art
		ico.custom_minimum_size = Vector2(ICON_PX, ICON_PX)
		ico.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ico.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		ico.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		ico.mouse_filter = Control.MOUSE_FILTER_IGNORE
		row.add_child(ico)

	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.add_theme_constant_override("separation", 2)
	row.add_child(col)

	var name_lbl := Label.new()
	name_lbl.text = display_name
	name_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# "Super Nintendo Entertainment System" is three lines in the space left
	# beside the art — cap it and ellipsize so a long name can't push the badge
	# out of the tile. The detail page header shows the name in full.
	name_lbl.max_lines_visible = 2
	name_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_lbl.add_theme_font_size_override("font_size", 20)
	name_lbl.add_theme_color_override("font_color", COLOR_TITLE)
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(name_lbl)

	if not badge.is_empty():
		var badge_lbl := Label.new()
		badge_lbl.text = badge
		# Same treatment as the name: a Label's minimum width is its whole string
		# unless it is allowed to trim, and that minimum wins over the column it
		# sits in — so a long core name ("Mupen64Plus-Next") drew straight out
		# past the right edge of the tile instead of shrinking to fit it.
		badge_lbl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		badge_lbl.add_theme_font_size_override("font_size", 16)
		badge_lbl.add_theme_color_override("font_color", COLOR_LICENSE)
		badge_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_child(badge_lbl)

	# The host's glyph, pinned to the top-right corner — the mirror of the source
	# badge below it, and an overlay for the same reason.
	if has_glyph:
		var glyph_lbl := Label.new()
		glyph_lbl.text = corner_glyph
		glyph_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		glyph_lbl.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		glyph_lbl.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		glyph_lbl.grow_vertical = Control.GROW_DIRECTION_END
		glyph_lbl.offset_right = -8
		glyph_lbl.offset_top = 6
		glyph_lbl.add_theme_font_override("font", MenuIcons.symbols())
		glyph_lbl.add_theme_font_size_override("font_size", 22)
		glyph_lbl.add_theme_color_override("font_color",
			s.get("corner_glyph_color", Color(1, 1, 1)))
		glyph_lbl.tooltip_text = s.get("corner_glyph_tip", "")
		btn.add_child(glyph_lbl)

	# Source badge, pinned to the bottom-right corner: a small mark plus a count,
	# outside the name column so a long name cannot push it around.
	if has_mark:
		var corner := VBoxContainer.new()
		corner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		corner.alignment = BoxContainer.ALIGNMENT_CENTER
		corner.add_theme_constant_override("separation", 0)
		corner.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
		corner.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		corner.grow_vertical = Control.GROW_DIRECTION_BEGIN
		corner.offset_right = -8
		corner.offset_bottom = -6
		btn.add_child(corner)

		var mark_rect := TextureRect.new()
		mark_rect.texture = mark
		mark_rect.custom_minimum_size = Vector2(BADGE_MARK_PX, BADGE_MARK_PX)
		mark_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		mark_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		mark_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
		corner.add_child(mark_rect)

		if has_pair:
			# "12 / 388" — how many are on this device, then how many the server
			# has. Three labels rather than one RichTextLabel: a tile is rebuilt
			# on every repopulate and there can be seventy of them, so this is
			# three of the cheapest Control there is against a BBCode parse.
			#
			# The slash is white and the numbers are not, which is what lets the
			# pair be read as one value at 14 px — the eye takes the bright pip in
			# the middle as the divider and the two tints as the two halves.
			var pair := HBoxContainer.new()
			pair.mouse_filter = Control.MOUSE_FILTER_IGNORE
			pair.alignment = BoxContainer.ALIGNMENT_CENTER
			pair.add_theme_constant_override("separation", 0)
			corner.add_child(pair)
			pair.add_child(_badge_number(_compact_count(mark_here), COLOR_BADGE_HERE))
			pair.add_child(_badge_number(" / ", Color.WHITE))
			pair.add_child(_badge_number(_compact_count(mark_count), COLOR_LICENSE))
		else:
			corner.add_child(_badge_number(_compact_count(mark_count), COLOR_LICENSE))

	style_tile(btn, alt)
	btn.pressed.connect(open_system.bind(sid))
	return btn


## The rounded plate a tile sits on. Shared by both tile shapes so the compact
## grid is visibly the same furniture, only smaller, and public so the CONTROLS
## tab's per-platform grid wears the same plate without owning a browser.
static func style_tile(btn: Button, alt: bool = false) -> void:
	var base := StyleBoxFlat.new()
	base.bg_color = COLOR_TILE_ALT if alt else COLOR_TILE
	var hover := StyleBoxFlat.new()
	hover.bg_color = COLOR_TILE_ALT_HOVER if alt else COLOR_TILE_HOVER
	for st: StyleBoxFlat in [base, hover]:
		for k in ["corner_radius_top_left", "corner_radius_top_right",
				  "corner_radius_bottom_left", "corner_radius_bottom_right"]:
			st.set(k, 8)
		for m in ["content_margin_left", "content_margin_right"]:
			st.set(m, 12)
	btn.add_theme_stylebox_override("normal",  base)
	btn.add_theme_stylebox_override("hover",   hover)
	btn.add_theme_stylebox_override("pressed", hover)


## True when this grid is drawing bare squares rather than labelled rows.
func _compact() -> bool:
	return allow_compact and AppPrefs.compact_tiles


## One cell of the corner badge.
static func _badge_number(text: String, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", 14)
	lbl.add_theme_color_override("font_color", color)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return lbl


## 78911 in a 26 px corner is unreadable — 78.9k is not.
static func _compact_count(n: int) -> String:
	if n >= 1000000:
		return "%.1fM" % (float(n) / 1000000.0)
	if n >= 10000:
		return "%dk" % int(round(float(n) / 1000.0))
	if n >= 1000:
		return "%.1fk" % (float(n) / 1000.0)
	return str(n)


func _on_filter_changed(text: String) -> void:
	var needle := text.strip_edges().to_lower()
	for tile: Node in _tiles_grid.get_children():
		if tile is Button:
			var hay: String = tile.get_meta("filter_name", "")
			tile.visible = needle.is_empty() or hay.contains(needle)
