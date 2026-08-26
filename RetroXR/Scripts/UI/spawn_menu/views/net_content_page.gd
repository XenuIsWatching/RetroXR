## The CONTENT page -- what the shared room needs, what is moving, and what this
## player is simply missing.
##
## The distinction the layout has to carry: a row that is DOWNLOADING and a row
## that is MISSING AND CANNOT BE SENT look similar and mean opposite things. A
## game ROM is never offered as a transfer, so its missing row gets words rather
## than a bar, and "Download all" steps over it instead of pretending.
##
## Rows are patched in place from progress signals, never rebuilt: a full list
## rebuild costs hundreds of milliseconds on the headset, which is why
## cores_view grew _refresh_bios_soon(). Same lesson, applied up front.
class_name NetContentPage
extends VBoxContainer

const COLOR_OK := Color(0.45, 0.85, 0.45)
const COLOR_BAD := Color(0.95, 0.40, 0.40)

var _content: NetplayContent = null
var _menu: Node = null

var _rows_box: VBoxContainer = null
var _summary: Label = null
var _all_btn: Button = null
var _join_bar: ProgressBar = null
var _join_lbl: Label = null
## key -> {row, status, bar}
var _widgets: Dictionary = {}
var _busy := false


static func create(content: NetplayContent, menu: Node) -> NetContentPage:
	var p := NetContentPage.new()
	p._content = content
	p._menu = menu
	p._build()
	return p


func _build() -> void:
	add_theme_constant_override("separation", 10)
	add_child(MenuStyle.header("CONTENT"))
	_summary = MenuStyle.label("", 18, MenuStyle.COLOR_LICENSE)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_summary)

	_all_btn = MenuStyle.row_button("Download all", 20, 0, 60, false)
	_all_btn.focus_mode = Control.FOCUS_NONE
	_all_btn.pressed.connect(_on_all_pressed)
	add_child(_all_btn)

	# The late-join stream gets its own bar above the list: it is the one
	# transfer that blocks the player from doing anything at all.
	_join_lbl = MenuStyle.label("", 16, MenuStyle.COLOR_NETPLAY)
	_join_lbl.visible = false
	add_child(_join_lbl)
	_join_bar = _make_bar()
	_join_bar.visible = false
	add_child(_join_bar)

	_rows_box = MenuStyle.vbox(6)
	add_child(_rows_box)

	if _content != null:
		_content.item_changed.connect(_on_item_changed)
		_content.manifest_changed.connect(_rebuild)
	if NetworkManager != null:
		NetworkManager.session_started.connect(func(_h: bool) -> void: refresh())
		NetworkManager.session_ended.connect(func(_r: String) -> void: refresh())
	refresh()


func refresh() -> void:
	if _content != null:
		_content.rebuild()
	else:
		_rebuild()


func _rebuild() -> void:
	if not is_instance_valid(_rows_box):
		return
	for c in _rows_box.get_children():
		c.queue_free()
	_widgets.clear()

	var rows: Array[Dictionary] = _content.rows() if _content != null else ([] as Array[Dictionary])
	if rows.is_empty():
		_summary.text = "Nothing shared yet. Books, tapes, discs and posters in the room appear here, along with the game each machine is running."
		_all_btn.disabled = true
		_all_btn.text = "Download all"
		return

	for row: Dictionary in rows:
		_rows_box.add_child(_make_row(row))
	_update_summary(rows)


func _update_summary(rows: Array) -> void:
	var have := 0
	for row: Dictionary in rows:
		if str(row.get("state", "")) == NetplayContent.STATE_HAVE:
			have += 1
	var actionable: Array = _content.actionable() if _content != null else []
	var bytes: int = _content.actionable_bytes() if _content != null else 0
	_summary.text = "%d of %d items ready." % [have, rows.size()]

	if _busy:
		_all_btn.disabled = false
		_all_btn.text = "Stop"
		return
	if actionable.is_empty():
		_all_btn.disabled = true
		# Say WHY there is nothing to press, or a disabled button reads as broken.
		var blocked := 0
		for row: Dictionary in rows:
			if str(row.get("state", "")) != NetplayContent.STATE_HAVE \
					and not bool(row.get("transferable", false)):
				blocked += 1
		_all_btn.text = "Nothing to download" if blocked == 0 \
			else "Nothing that can be sent (%d must be found locally)" % blocked
		return
	_all_btn.disabled = false
	# The size goes on the button because a room full of videos is a real number
	# and a headset is usually on Wi-Fi.
	_all_btn.text = "Download all -- %d items, %s" % [actionable.size(),
		MenuStyle.human_bytes(bytes)]


func _make_row(row: Dictionary) -> Control:
	var key := NetplayContent.key_for(str(row.get("class", "")), str(row.get("md5", "")))
	var box := MenuStyle.vbox(2)
	var line := MenuStyle.hbox(10)
	line.custom_minimum_size = Vector2(0, 48)

	var icon := MenuStyle.label(_glyph(row), 20, _tint(row))
	icon.add_theme_font_override("font", MenuIcons.symbols())
	icon.custom_minimum_size = Vector2(34, 0)
	line.add_child(icon)

	var name_lbl := MenuStyle.label("%s  (%s)" % [str(row.get("label", "")),
		str(row.get("class", ""))], 18, MenuStyle.COLOR_TITLE)
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(name_lbl)

	var status := MenuStyle.label(_status_text(row), 15, _tint(row))
	status.custom_minimum_size = Vector2(320, 0)
	status.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	line.add_child(status)
	box.add_child(line)

	var bar := _make_bar()
	bar.visible = str(row.get("state", "")) == NetplayContent.STATE_FETCHING
	box.add_child(bar)

	_widgets[key] = {"row": box, "status": status, "bar": bar}
	return box


## A missing ROM says the quiet part out loud. Everything else states its size.
func _status_text(row: Dictionary) -> String:
	var state := str(row.get("state", ""))
	var size := int(row.get("size", 0))
	match state:
		NetplayContent.STATE_HAVE:
			return MenuStyle.human_bytes(size) if size > 0 else "ready"
		NetplayContent.STATE_FETCHING:
			return "transferring..."
		NetplayContent.STATE_ROMM:
			return "on your RomM server"
		_:
			if not bool(row.get("transferable", false)):
				return "missing -- cannot be sent between players"
			return "missing"


func _glyph(row: Dictionary) -> String:
	match str(row.get("state", "")):
		NetplayContent.STATE_HAVE:
			return String.chr(MenuIcons.CHECK)
		NetplayContent.STATE_FETCHING:
			return String.chr(MenuIcons.BUSY)
		NetplayContent.STATE_ROMM:
			return String.chr(MenuIcons.RETRY)
		_:
			return String.chr(MenuIcons.ERROR)


func _tint(row: Dictionary) -> Color:
	match str(row.get("state", "")):
		NetplayContent.STATE_HAVE:
			return COLOR_OK
		NetplayContent.STATE_FETCHING:
			return MenuStyle.COLOR_NETPLAY
		NetplayContent.STATE_ROMM:
			return MenuStyle.COLOR_NETPLAY
		_:
			return COLOR_BAD


## Same bar the toasts use, so a transfer looks the same wherever it is seen.
func _make_bar() -> ProgressBar:
	var bar := ProgressBar.new()
	bar.custom_minimum_size = Vector2(0, 5)
	bar.show_percentage = false
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.max_value = 100.0
	bar.value = 0.0
	bar.add_theme_stylebox_override("fill",
		MenuStyle.rounded(MenuStyle.COLOR_NETPLAY, 3))
	bar.add_theme_stylebox_override("background",
		MenuStyle.rounded(MenuStyle.COLOR_SCROLL_TRACK, 3))
	return bar


## Patch one row rather than rebuilding the list -- the whole reason the widget
## dictionary exists.
func _on_item_changed(key: String, state: String, received: int, total: int) -> void:
	if key == "netjoin:state":
		_show_join_phase(state, received, total)
		return
	var w: Dictionary = _widgets.get(key, {})
	if w.is_empty():
		return
	var bar: ProgressBar = w["bar"]
	var status: Label = w["status"]
	if not is_instance_valid(bar) or not is_instance_valid(status):
		return
	if state == NetplayContent.STATE_FETCHING:
		bar.visible = true
		bar.value = 100.0 * float(received) / maxf(1.0, float(total))
		status.text = "%s / %s" % [MenuStyle.human_bytes(received),
			MenuStyle.human_bytes(total)]
		status.add_theme_color_override("font_color", MenuStyle.COLOR_NETPLAY)
	else:
		bar.visible = false
		status.text = state
		if state == NetplayContent.STATE_HAVE:
			status.add_theme_color_override("font_color", COLOR_OK)
			_maybe_finished()


## The four phases of a late join, named. "capturing" and "loading" carry no
## byte count because neither is a byte count -- they are waits, and the point
## of showing them is that a wait is not a hang.
func _show_join_phase(phase: String, received: int, total: int) -> void:
	if not is_instance_valid(_join_bar) or not is_instance_valid(_join_lbl):
		return
	var words := {
		"capturing": "Pausing the game to take a snapshot...",
		"transferring": "Sending the game state...",
		"verifying": "Checking the snapshot...",
		"loading": "Starting your copy of the game...",
	}
	_join_lbl.text = str(words.get(phase, phase))
	_join_lbl.visible = true
	if phase == "transferring" and total > 0:
		_join_bar.visible = true
		_join_bar.value = 100.0 * float(received) / float(total)
		_join_lbl.text = "%s  %s / %s" % [_join_lbl.text,
			MenuStyle.human_bytes(received), MenuStyle.human_bytes(total)]
	else:
		_join_bar.visible = false
	if _menu != null and _menu.has_method("notify"):
		_menu.call("notify", "netjoin:state", String.chr(MenuIcons.BUSY),
			str(words.get(phase, phase)),
			float(received) / maxf(1.0, float(total)) if total > 0 else -1.0, 0.0)


func _maybe_finished() -> void:
	if _content == null:
		return
	if _content.actionable().is_empty():
		_busy = false
	_update_summary(_content.rows())


func _on_all_pressed() -> void:
	if _content == null:
		return
	if _busy:
		_content.cancel_all()
		_busy = false
		_update_summary(_content.rows())
		return
	var started := _content.download_all()
	_busy = started > 0
	_update_summary(_content.rows())
