## SpawnMenuNetView — the menu's NET tab: host or join a session, and see who
## is in it.
##
## Two ways in, and the difference is who can reach you. Hosting online claims a
## room code from the rendezvous and punches a hole; hosting on LAN is what this
## tab always did. The code path can fail in a way the LAN one cannot — some
## networks simply cannot be punched — so the failure is spelled out rather
## than left as a silence, and the LAN row never goes away.
##
## Talks only to NetworkManager, so like the graphics tab it reports nothing back
## to the menu and has no signals. The name and last-used IP persist to
## user://net_prefs.json, kept here rather than in AppPrefs because nothing else
## reads them.
##
## It used to BE its own scroll container. It now hosts three sub-tabs the way
## the options tab does — SESSION (everything this tab always did), READINESS
## (whether the people here can actually play together) and CONTENT (what the
## room needs and what is moving) — so the scroll the thumbstick drives is
## whichever sub-tab is showing, reported through scroll_changed.
##
## The keypad below was entering two digits per tap: a Viewport2Din3D delivered
## one pointer press to a Button as BOTH an InputEventScreenTouch and an
## InputEventMouseButton, and a press-mode Button fires on each. Fixed at the
## source in viewport_2d_in_3d_body.gd, which now sends the mouse pointer mouse
## events only. Release mode was never affected — the second event finds the
## button already released — which is why the rest of the menu was fine.
class_name SpawnMenuNetView
extends VBoxContainer

## The sub-tab changed, so the thumbstick should drive a different scroll.
signal scroll_changed(scroll: ScrollContainer)

const PREFS_PATH := "user://net_prefs.json"

var _tabs: TabContainer = null
var _pages: Array[ScrollContainer] = []
var _readiness: NetReadinessPage = null
var _content_page: NetContentPage = null
var _content: NetplayContent = null

var _status_lbl:   Label = null
var _name_edit:    LineEdit = null
var _ip_edit:      LineEdit = null
var _players_box:  VBoxContainer = null
var _host_btn:     Button = null
var _host_lan_btn: Button = null
var _join_btn:     Button = null
var _join_code_btn: Button = null
var _leave_btn:    Button = null
var _code_edit:    LineEdit = null
var _code_lbl:     Label = null


## `menu` is the SpawnMenu2D, needed only so an in-flight transfer can raise a
## toast that outlives this tab. Optional: the tab works standalone in a probe.
static func create(menu: Node = null) -> SpawnMenuNetView:
	var v := SpawnMenuNetView.new()
	v._menu = menu
	v._build()
	return v


var _menu: Node = null


func _build() -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tabs = TabContainer.new()
	_tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var vbox := _page("Session")
	_build_readiness_page()
	_build_content_page()

	_tabs.tab_changed.connect(func(_i: int) -> void:
		scroll_changed.emit(active_scroll())
		# Refresh the page being opened, rather than all of them on a timer.
		_refresh_pages())
	add_child(TabStrip.wrap(_tabs))

	var prefs := _load_prefs()

	vbox.add_child(MenuStyle.header("MULTIPLAYER"))

	_status_lbl = MenuStyle.label("Not connected", 18, MenuStyle.COLOR_LICENSE)
	_status_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(_status_lbl)

	# ── Player name ───────────────────────────────────────────────────────────
	var name_row := MenuStyle.hbox(10)
	name_row.custom_minimum_size = Vector2(0, 56)
	vbox.add_child(name_row)
	name_row.add_child(MenuStyle.label("Name", 20, MenuStyle.COLOR_TITLE))
	_name_edit = LineEdit.new()
	_name_edit.text = str(prefs.get("name", "Player"))
	_name_edit.max_length = 24
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.add_theme_font_size_override("font_size", 20)
	name_row.add_child(_name_edit)

	# ── Host ──────────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	_host_btn = _wide_button("Host Online")
	_host_btn.pressed.connect(_on_host_online)
	vbox.add_child(_host_btn)

	# The code, once there is one. Large because it gets read out loud off the
	# panel while the headset is on, which is the whole reason it is six
	# characters of an alphabet with no I, L, O, U, 0 or 1 in it.
	_code_lbl = MenuStyle.label("", 44, MenuStyle.COLOR_TITLE)
	_code_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_code_lbl.visible = false
	vbox.add_child(_code_lbl)

	# Kept, not replaced. A pair that cannot be punched still has a LAN, and
	# this is also the fallback when the rendezvous itself cannot be reached.
	_host_lan_btn = _wide_button("Host on LAN")
	_host_lan_btn.pressed.connect(_on_host)
	vbox.add_child(_host_lan_btn)

	# ── Join ──────────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	var code_row := MenuStyle.hbox(10)
	code_row.custom_minimum_size = Vector2(0, 56)
	vbox.add_child(code_row)
	code_row.add_child(MenuStyle.label("Room code", 20, MenuStyle.COLOR_TITLE))
	_code_edit = LineEdit.new()
	_code_edit.text = str(prefs.get("code", ""))
	_code_edit.placeholder_text = "K7MPQ4"
	_code_edit.max_length = RoomCode.LENGTH
	_code_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code_edit.add_theme_font_size_override("font_size", 20)
	code_row.add_child(_code_edit)
	_join_code_btn = Button.new()
	_join_code_btn.text = "  Join  "
	_join_code_btn.custom_minimum_size = Vector2(120, 52)
	_join_code_btn.add_theme_font_size_override("font_size", 20)
	_join_code_btn.focus_mode = Control.FOCUS_NONE
	_join_code_btn.pressed.connect(_on_join_code)
	var code_rub := Button.new()
	code_rub.text = String.chr(MenuIcons.BACKSPACE)
	code_rub.custom_minimum_size = Vector2(64, 52)
	code_rub.add_theme_font_size_override("font_size", 22)
	code_rub.add_theme_font_override("font", MenuIcons.symbols())
	code_rub.focus_mode = Control.FOCUS_NONE
	code_rub.pressed.connect(func() -> void:
		_code_edit.text = _code_edit.text.left(_code_edit.text.length() - 1))
	code_row.add_child(code_rub)
	code_row.add_child(_join_code_btn)

	# The alphabet, not a keyboard: six columns, five square rows, and only the
	# characters a code can contain — which makes a mistyped O or 1 unreachable
	# rather than merely rejected.
	_keypad(vbox, 6, _alphabet_keys(), _code_edit)

	var join_row := MenuStyle.hbox(10)
	join_row.custom_minimum_size = Vector2(0, 56)
	vbox.add_child(join_row)
	join_row.add_child(MenuStyle.label("Host IP", 20, MenuStyle.COLOR_TITLE))
	_ip_edit = LineEdit.new()
	_ip_edit.text = str(prefs.get("ip", ""))
	_ip_edit.placeholder_text = "192.168.1.10"
	_ip_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ip_edit.add_theme_font_size_override("font_size", 20)
	join_row.add_child(_ip_edit)
	_join_btn = Button.new()
	_join_btn.text = "  Join  "
	_join_btn.custom_minimum_size = Vector2(120, 52)
	_join_btn.add_theme_font_size_override("font_size", 20)
	_join_btn.focus_mode = Control.FOCUS_NONE
	_join_btn.pressed.connect(_on_join)
	join_row.add_child(_join_btn)

	# The IP pad, unchanged in shape. Both pads are built by the same helper so
	# the fix for a Viewport2Din3D delivering two events per tap keeps covering
	# both of them.
	_keypad(vbox, 6, ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", ".",
		String.chr(MenuIcons.BACKSPACE)], _ip_edit)

	# ── Players ───────────────────────────────────────────────────────────────
	vbox.add_child(HSeparator.new())
	vbox.add_child(MenuStyle.label("Players", 18, MenuStyle.COLOR_LICENSE))
	_players_box = MenuStyle.vbox(4, false)
	vbox.add_child(_players_box)

	# ── Disconnect ────────────────────────────────────────────────────────────
	_leave_btn = _wide_button("Disconnect")
	_leave_btn.pressed.connect(func() -> void: NetworkManager.leave_session())
	vbox.add_child(_leave_btn)

	# Live updates from the session.
	NetworkManager.status_changed.connect(func(text: String) -> void:
		if is_instance_valid(_status_lbl):
			_status_lbl.text = text
	)
	NetworkManager.room_code_changed.connect(func(code: String) -> void:
		if not is_instance_valid(_code_lbl):
			return
		_code_lbl.text = code
		_code_lbl.visible = not code.is_empty()
	)
	NetworkManager.session_started.connect(func(_h: bool) -> void: refresh())
	NetworkManager.session_ended.connect(func(_r: String) -> void: refresh())
	NetworkManager.peer_registered.connect(func(_i: int, _d: Dictionary) -> void: refresh())
	NetworkManager.peer_left.connect(func(_i: int) -> void: refresh())

	# Keep ping readouts fresh while the NET view is on screen.
	var ping_timer := Timer.new()
	ping_timer.wait_time = 1.0
	ping_timer.autostart = true
	ping_timer.timeout.connect(func() -> void:
		if NetworkManager.is_active() and visible:
			refresh_session()
	)
	vbox.add_child(ping_timer)


func _wide_button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 56)
	b.add_theme_font_size_override("font_size", 20)
	b.focus_mode = Control.FOCUS_NONE
	return b


## Every key a code can contain. Built from RoomCode.ALPHABET so the pad cannot
## drift from what the validator accepts: a key that types a character the gate
## refuses is a trap with no way out on a panel that has no other keyboard.
##
## The rubout is deliberately not in here. Thirty keys make five rows of six;
## a thirty-first left it orphaned on a row of its own, so it sits next to the
## field it edits instead.
func _alphabet_keys() -> Array:
	var keys: Array = []
	for c in RoomCode.ALPHABET:
		keys.append(c)
	return keys


## One on-panel pad. Press mode, one event per tap.
func _keypad(parent: Node, columns: int, keys: Array, target: LineEdit) -> void:
	var pad := GridContainer.new()
	pad.columns = columns
	pad.add_theme_constant_override("h_separation", 6)
	pad.add_theme_constant_override("v_separation", 6)
	parent.add_child(pad)
	var rub := String.chr(MenuIcons.BACKSPACE)
	for key: String in keys:
		var kb := Button.new()
		kb.text = key
		kb.custom_minimum_size = Vector2(0, 52)
		kb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		kb.add_theme_font_size_override("font_size", 22)
		kb.add_theme_font_override("font", MenuIcons.symbols())
		kb.focus_mode = Control.FOCUS_NONE
		var captured := key
		kb.pressed.connect(func() -> void:
			if not is_instance_valid(target):
				return
			if captured == rub:
				target.text = target.text.left(target.text.length() - 1)
			else:
				target.text += captured
		)
		pad.add_child(kb)


func _on_host_online() -> void:
	NetworkManager.player_name = _name_edit.text.strip_edges()
	_save_prefs()
	_set_busy(true)
	var err: Error = await NetworkManager.host_online(NetworkManager.player_name)
	_set_busy(false)
	# NetworkManager has already said what went wrong through status_changed,
	# and it says it better than this view can: it knows whether the rendezvous
	# was unreachable or the punch simply failed. Repeating it here would only
	# overwrite the specific message with a vaguer one.
	if err == OK:
		refresh()


func _on_join_code() -> void:
	var code := RoomCode.normalize(_code_edit.text)
	if not RoomCode.is_valid(code):
		if is_instance_valid(_status_lbl):
			_status_lbl.text = "A room code is %d characters, like K7MPQ4." % RoomCode.LENGTH
		return
	_code_edit.text = code
	NetworkManager.player_name = _name_edit.text.strip_edges()
	_save_prefs()
	_set_busy(true)
	var err: Error = await NetworkManager.join_by_code(code)
	_set_busy(false)
	if err == OK:
		refresh()


## A punch takes seconds, not frames. Without this the panel looks idle while it
## works and the player presses the button again.
func _set_busy(busy: bool) -> void:
	for b: Button in [_host_btn, _host_lan_btn, _join_btn, _join_code_btn]:
		if is_instance_valid(b):
			b.disabled = busy


func _on_host() -> void:
	NetworkManager.player_name = _name_edit.text.strip_edges()
	_save_prefs()
	NetworkManager.host_game()


func _on_join() -> void:
	var ip := _ip_edit.text.strip_edges()
	if not ip.is_valid_ip_address():
		if is_instance_valid(_status_lbl):
			_status_lbl.text = "Invalid IP address: '%s'" % ip
		return
	NetworkManager.player_name = _name_edit.text.strip_edges()
	_save_prefs()
	NetworkManager.join_game(ip)


## Re-read the session and repaint.
## Everything, including the two sub-pages. For opening the tab, changing
## sub-tab, and session events -- NOT for the ping timer.
func refresh() -> void:
	_refresh_pages()
	refresh_session()


## The sub-pages, which cost real work: the content page stats files and walks a
## ROM folder, and both rebuild their rows. Only called when something actually
## changed.
func _refresh_pages() -> void:
	if is_instance_valid(_readiness):
		_readiness.refresh()
	if is_instance_valid(_content_page):
		_content_page.refresh()


## Just the cheap parts: button states, the room code, the player list and its
## ping readouts.
##
## Split out because the 1 s timer below drives it. Running the whole refresh at
## 1 Hz meant re-statting every file in the room, re-walking a ROM directory and
## kicking a background hash sweep once a second, for the sake of a ping number.
func refresh_session() -> void:
	if not is_instance_valid(_players_box):
		return
	var active: bool = NetworkManager.is_active()
	_host_btn.disabled = active
	_host_lan_btn.disabled = active
	_join_btn.disabled = active
	_join_code_btn.disabled = active
	_leave_btn.disabled = not active
	_name_edit.editable = not active
	# The code belongs to a live session. Leaving one has to take it off the
	# panel, or the next player reads out a code that resolves to nothing.
	var code: String = NetworkManager.room_code()
	_code_lbl.text = code
	_code_lbl.visible = not code.is_empty()

	for child in _players_box.get_children():
		child.queue_free()
	var self_id: int = NetworkManager.multiplayer.get_unique_id() if active else -1
	# Which pad each player is actually holding. _owners is the map the input
	# scheduler samples from, so it cannot drift from what is being played, and
	# a peer holding no port at all is a spectator.
	var ports := _ports_by_peer()
	for id: int in NetworkManager.peers:
		var info: Dictionary = NetworkManager.peers[id]
		var row := MenuStyle.hbox(10)
		var swatch := ColorRect.new()
		swatch.color = NetworkManager.PLAYER_COLORS[int(info.get("color_idx", 0)) % NetworkManager.PLAYER_COLORS.size()]
		swatch.custom_minimum_size = Vector2(26, 26)
		row.add_child(swatch)
		var suffix := ""
		if id == 1:
			suffix += "  (host)"
		if id == self_id:
			suffix += "  (you)"
		if NetworkManager.netplay_running():
			var held: Array = ports.get(id, [])
			suffix += "  --  %s" % ("spectator" if held.is_empty()
				else ", ".join(PackedStringArray(held)))
		var ping: int = NetworkManager.ping_ms(id)
		if ping > 0:
			suffix += "  %d ms" % ping
		row.add_child(MenuStyle.label("%s%s" % [info.get("name", "?"), suffix],
			18, MenuStyle.COLOR_TITLE))
		_players_box.add_child(row)


## peer_id -> ["Port 1", "Machine 2 Port 1", ...].
##
## The machine is named only when there is more than one, because a cabled pair
## is one session over two machines and "Port 1" alone would be ambiguous there
## while being noise everywhere else.
func _ports_by_peer() -> Dictionary:
	var out: Dictionary = {}
	var owners := NetworkManager.netplay_owners()
	var machines: Dictionary = {}
	for global_port: int in owners:
		machines[NetworkManager.netplay_machine_of(global_port)] = true
	var many := machines.size() > 1
	for global_port: int in owners:
		var peer := int(owners[global_port])
		var port := NetworkManager.netplay_port_of(global_port) + 1
		var text := "Port %d" % port
		if many:
			text = "Machine %d Port %d" % [
				NetworkManager.netplay_machine_of(global_port) + 1, port]
		if not out.has(peer):
			out[peer] = []
		(out[peer] as Array).append(text)
	return out


## A scrolling sub-tab. The TabContainer titles each tab after its child, so the
## node name IS the label.
func _page(title: String) -> VBoxContainer:
	var page := MenuStyle.vscroll()
	page.name = title
	var vbox := MenuStyle.vbox(10)
	page.add_child(vbox)
	_tabs.add_child(page)
	_pages.append(page)
	return vbox


func _build_readiness_page() -> void:
	_readiness = NetReadinessPage.create()
	_page("Readiness").add_child(_readiness)


## The content page needs the RomM client and downloader, which the menu owns.
## Without a menu it still builds and simply has no RomM route -- a missing ROM
## then reads as missing rather than as fetchable, which is the truth.
func _build_content_page() -> void:
	_content = NetplayContent.new()
	_content.name = "NetplayContent"
	add_child(_content)
	var client: RommClient = null
	var downloader: RommDownloader = null
	var scraper: AutoScraper = null
	if _menu != null:
		if "romm_client" in _menu:
			client = _menu.get("romm_client")
		if "romm_downloader" in _menu:
			downloader = _menu.get("romm_downloader")
		if "auto_scraper" in _menu:
			scraper = _menu.get("auto_scraper")
	_content.setup(NetworkManager, client, downloader, scraper)
	_content_page = NetContentPage.create(_content, _menu)
	_page("Content").add_child(_content_page)


## The scroll the thumbstick should drive, i.e. whichever sub-tab is showing.
func active_scroll() -> ScrollContainer:
	if _tabs == null or _pages.is_empty():
		return null
	return _pages[clampi(_tabs.current_tab, 0, _pages.size() - 1)]


func _load_prefs() -> Dictionary:
	if not FileAccess.file_exists(PREFS_PATH):
		return {}
	var f := FileAccess.open(PREFS_PATH, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}


func _save_prefs() -> void:
	var f := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({
			"name": _name_edit.text.strip_edges(),
			"ip": _ip_edit.text.strip_edges(),
			"code": RoomCode.normalize(_code_edit.text),
		}))
