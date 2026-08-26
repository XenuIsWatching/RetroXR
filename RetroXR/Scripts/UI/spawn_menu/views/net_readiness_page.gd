## The READINESS page -- why a session will or will not work, and what to press.
##
## Two levels on purpose. The top of each row is a verdict a player can act on
## without knowing what a savestate is; pressing it opens the real numbers,
## because the person who tuned their Dolphin options deserves to see that the
## session overrode seven of them rather than guess why nothing changed.
##
## Every verdict comes from NetplayReadiness. This file decides colour and
## layout and nothing else -- a second opinion about whether a core is vetted is
## exactly the bug this whole feature exists to remove.
class_name NetReadinessPage
extends VBoxContainer

const COLOR_OK := Color(0.45, 0.85, 0.45)
const COLOR_WARN := Color(0.95, 0.75, 0.25)
const COLOR_BAD := Color(0.95, 0.40, 0.40)
const COLOR_PENDING := Color(0.60, 0.60, 0.75)

var _rows_box: VBoxContainer = null
var _summary: Label = null
## key -> whether its drill-down is open, so a refresh does not close it.
var _expanded: Dictionary = {}
var _last_blocked: Dictionary = {}


static func create() -> NetReadinessPage:
	var p := NetReadinessPage.new()
	p._build()
	return p


func _build() -> void:
	add_theme_constant_override("separation", 10)
	add_child(MenuStyle.header("READINESS"))
	_summary = MenuStyle.label("", 18, MenuStyle.COLOR_LICENSE)
	_summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_summary)
	_rows_box = MenuStyle.vbox(8)
	add_child(_rows_box)

	if NetworkManager != null:
		NetworkManager.netplay_blocked.connect(_on_blocked)
		NetworkManager.session_started.connect(func(_h: bool) -> void: refresh())
		NetworkManager.session_ended.connect(func(_r: String) -> void: refresh())
		NetworkManager.netplay_session_stopped.connect(func(reason: String) -> void:
			_note(reason))
		NetworkManager.netplay_desync.connect(func(peer_id: int, frame: int) -> void:
			_note("a player's game drifted out of step at frame %d (peer %d)"
				% [frame, peer_id]))
	refresh()


## The machine that could not start, remembered so the page can still explain it
## after the moment has passed -- the signal fires once, the question lasts.
func _on_blocked(reason: String, machine: Object, remedy: Dictionary) -> void:
	_last_blocked = {"reason": reason, "machine": machine, "remedy": remedy}
	refresh()


func _note(text: String) -> void:
	if is_instance_valid(_summary):
		_summary.text = text


func refresh() -> void:
	if not is_instance_valid(_rows_box):
		return
	for c in _rows_box.get_children():
		c.queue_free()

	var rows := _collect()
	if rows.is_empty():
		_summary.text = "Start a game while other players are connected and this page will show whether everyone can join it."
		return

	var worst := NetplayReadiness.overall(rows)
	_summary.text = _summary_text(worst, rows.size())
	for row: Dictionary in rows:
		_rows_box.add_child(_make_row(row))


## Machine rows for everything the room can start, plus a peer row per player
## once a session is actually running.
func _collect() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not _last_blocked.is_empty():
		var machine: Object = _last_blocked.get("machine")
		if is_instance_valid(machine):
			out.append(NetplayReadiness.machine_row(machine,
				_machine_label(machine), machine.get("core_name") if "core_name" in machine else "",
				str(machine.get("systemid")) if "systemid" in machine else ""))

	if NetworkManager == null or not NetworkManager.netplay_running():
		return out

	var system: Object = NetworkManager.netplay_system()
	if is_instance_valid(system):
		var core := ""
		if system.has_method("resolve_core_name"):
			core = str(system.call("resolve_core_name"))
		out.append(NetplayReadiness.machine_row(system, _machine_label(system),
			core, str(system.get("systemid")) if "systemid" in system else ""))
	return out


func _machine_label(machine: Object) -> String:
	if machine == null or not is_instance_valid(machine):
		return "machine"
	if "display_name" in machine and not str(machine.get("display_name")).is_empty():
		return str(machine.get("display_name"))
	return str((machine as Node).name)


func _summary_text(worst: int, count: int) -> String:
	match worst:
		NetplayReadiness.Verdict.READY:
			return "Everything checks out -- %d item(s) ready." % count
		NetplayReadiness.Verdict.PENDING:
			return "Still checking. A core reports its build only once the game has loaded."
		NetplayReadiness.Verdict.WARN:
			return "Playable, with something worth knowing."
		_:
			return "Something here stops other players joining. Open a row for the detail."


func _make_row(row: Dictionary) -> Control:
	var key := "%s:%s" % [str(row.get("kind", "")), str(row.get("label", ""))]
	var box := MenuStyle.vbox(4)

	var head := MenuStyle.hbox(10)
	head.custom_minimum_size = Vector2(0, 56)
	var swatch := ColorRect.new()
	swatch.color = _tint(int(row.get("verdict", 0)))
	swatch.custom_minimum_size = Vector2(10, 44)
	head.add_child(swatch)

	var text := MenuStyle.vbox(0)
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_child(MenuStyle.label("%s  --  %s" % [str(row.get("label", "")),
		NetplayReadiness.verdict_word(int(row.get("verdict", 0)))],
		20, MenuStyle.COLOR_TITLE))
	var head_lbl := MenuStyle.label(str(row.get("headline", "")), 16,
		_tint(int(row.get("verdict", 0))))
	head_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(head_lbl)
	head.add_child(text)

	var remedy: Dictionary = row.get("remedy", {})
	if not remedy.is_empty():
		head.add_child(_remedy_button(remedy))

	var toggle := MenuStyle.row_button("Details", 16, 120, 44, false)
	toggle.focus_mode = Control.FOCUS_NONE
	toggle.pressed.connect(func() -> void:
		_expanded[key] = not bool(_expanded.get(key, false))
		refresh())
	head.add_child(toggle)
	box.add_child(head)

	if bool(_expanded.get(key, false)):
		box.add_child(_detail_box(row.get("detail", []) as Array))
	return box


## The drill-down. Deliberately plain rows of name/value rather than prose: the
## person who opened this wants the actual strings to compare.
func _detail_box(detail: Array) -> Control:
	var panel := MenuStyle.vbox(2)
	panel.add_theme_constant_override("separation", 2)
	for d: Dictionary in detail:
		var line := MenuStyle.hbox(8)
		var name_lbl := MenuStyle.label(str(d.get("name", "")), 15, MenuStyle.COLOR_DESC)
		name_lbl.custom_minimum_size = Vector2(220, 0)
		line.add_child(name_lbl)
		var value := MenuStyle.label(str(d.get("value", "")), 15, MenuStyle.COLOR_LICENSE)
		value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		line.add_child(value)
		panel.add_child(line)
	return panel


## One button, whatever the remedy is. A swap names the core AND what it buys,
## because "use mGBA instead" without "rollback, late join" is a instruction
## rather than a choice.
func _remedy_button(remedy: Dictionary) -> Button:
	var kind := str(remedy.get("kind", ""))
	var text := "Fix"
	match kind:
		"swap_core":
			text = "Switch to %s" % str(remedy.get("core", "?"))
		"fetch_rom":
			text = "Get from RomM"
		"open_bios":
			text = "BIOS settings"
	var b := MenuStyle.row_button(text, 18, 260, 48, false)
	b.focus_mode = Control.FOCUS_NONE
	var strategy := int(remedy.get("strategy", -1))
	if kind == "swap_core" and strategy >= 0:
		b.tooltip_text = "%s netplay" % NetplaySession.strategy_str(strategy).capitalize()
		b.add_theme_color_override("font_color", MenuIcons.netplay_tint(strategy))
	b.pressed.connect(func() -> void: _apply_remedy(remedy))
	return b


## Routes through the machine's own core selection rather than introducing a
## second way to change a core.
func _apply_remedy(remedy: Dictionary) -> void:
	match str(remedy.get("kind", "")):
		"swap_core":
			var machine: Object = remedy.get("machine")
			var core := str(remedy.get("core", ""))
			if is_instance_valid(machine) and not core.is_empty() \
					and "core_name" in machine:
				machine.set("core_name", core)
				_note("Switched to %s. Power the machine on again to start a session." % core)
				_last_blocked.clear()
				refresh()
		"open_bios":
			_note("Open the CORES tab to install or repair this system's BIOS.")
		"fetch_rom":
			_note("Open the CONTENT tab to fetch this game from your RomM server.")


func _tint(verdict: int) -> Color:
	match verdict:
		NetplayReadiness.Verdict.READY:
			return COLOR_OK
		NetplayReadiness.Verdict.WARN:
			return COLOR_WARN
		NetplayReadiness.Verdict.BLOCKED:
			return COLOR_BAD
		_:
			return COLOR_PENDING
