## Save-state UI self-tests — the decisions the States tab makes, headless.
##
##     "$godot" --headless --path RetroXR res://Tests/state_tests.tscn
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## What is here is what can be decided without a core: where the tab sits, which
## list the thumbstick drives, which buttons a blocker greys out, and the
## arm-then-confirm machine that stands between a press and a destroyed file.
## Capturing and restoring need a real core and live in Tools/state/state_probe.tscn;
## how any of this LOOKS needs a GPU and lives in Tools/state/cart_states_probe.tscn.
##
## The tab-order case is the regression record for a landmine this feature
## tripped: _sync_active_scroll() hard-coded `current_tab == 1`, so inserting a
## tab silently pointed the stick at the wrong page — and a corrected constant
## would only have re-armed it.
extends Node

var _pass := 0
var _fail := 0
## The player's romm_sync.json as it was before this run touched it.
var _ledger_before := ""


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[state-ui] TIMEOUT")
		get_tree().quit(1))
	# _test_backup_notice drives SaveSync._id_done on the AUTOLOAD, which
	# persists what it is told -- so a run left a fake id for a ROM that does not
	# exist ("nes/notice_probe.nes" -> 4242) sitting in the player's real ledger.
	# rom_id_for consults that ledger now, so the leak came back on the NEXT run
	# as two failures in this very file. Snapshot it and put it back.
	_ledger_before = FileAccess.get_file_as_string(RommSaveSync.state_path()) 		if FileAccess.file_exists(RommSaveSync.state_path()) else ""
	_test_tab_order()
	_test_active_scroll_follows_the_tab()
	_test_rows()
	_test_blocked()
	_test_armed_row()
	_test_arm_ladder()
	_test_thumb_cache()
	_test_backup_notice()
	_test_panel_chrome()
	await _test_floating_panels()
	_test_panels_with_their_own_anchor()
	_restore_ledger()
	print("[state-ui] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


## Put the player's sync ledger back byte for byte.
func _restore_ledger() -> void:
	var path := RommSaveSync.state_path()
	if _ledger_before.is_empty():
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[state_tests] cannot restore %s" % path)
		return
	f.store_string(_ledger_before)
	f.close()


func _ok(cond: bool, name: String, detail := "") -> void:
	if cond:
		_pass += 1
		print("[state-ui] PASS  %s" % name)
	else:
		_fail += 1
		print("[state-ui] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(got == want, name, "got %s, want %s" % [str(got), str(want)])


## A built view in the tree. Caller frees it.
func _ui() -> CartridgeOptions2D:
	var ui := CartridgeOptions2D.new()
	add_child(ui)
	return ui


func _tabs_of(ui: CartridgeOptions2D) -> TabContainer:
	return _find(ui, "TabContainer") as TabContainer


func _find(node: Node, cls: String) -> Node:
	if node.is_class(cls):
		return node
	for child in node.get_children():
		var got := _find(child, cls)
		if got != null:
			return got
	return null


func _titles(tabs: TabContainer) -> Array:
	var out: Array = []
	for i in range(tabs.get_tab_count()):
		out.append(tabs.get_tab_title(i))
	return out


## Every Button under `node`, in tree order.
func _buttons(node: Node, into: Array = []) -> Array:
	if node is Button:
		into.append(node)
	for child in node.get_children():
		_buttons(child, into)
	return into


## Children that are actually still there. populate_states() frees the old rows
## with queue_free(), which does not take effect until the frame ends, so a
## plain get_child_count() after a second populate counts both lists.
func _live_children(node: Node) -> int:
	var n := 0
	for child in node.get_children():
		if not child.is_queued_for_deletion():
			n += 1
	return n


func _rows(n: int) -> Array:
	var out: Array = []
	for i in range(n):
		out.append({
			"state_id": "%d-%06x" % [1787000000000 + i * 1000, i * 4919],
			"path": "", "shot": "", "meta": "",
			"mtime": 1787000000 - i * 60, "bytes": 4096 * (i + 1),
		})
	return out


# ---------------------------------------------------------------------------

func _test_tab_order() -> void:
	var ui := _ui()
	var tabs := _tabs_of(ui)
	_ok(tabs != null, "tabs/there is a tab strip")
	if tabs != null:
		# The asked-for position: between Saves and Achievements.
		_eq("tabs/order", _titles(tabs), ["Saves", "States", "Achievements"])
	ui.free()


func _test_active_scroll_follows_the_tab() -> void:
	var ui := _ui()
	var tabs := _tabs_of(ui)
	if tabs == null:
		ui.free()
		return
	for i in range(tabs.get_tab_count()):
		tabs.current_tab = i
		# tab_changed drives _sync_active_scroll; call it too so the case does not
		# depend on the signal having been emitted for an unchanged index.
		ui._sync_active_scroll()
		var scroll: ScrollContainer = ui._active_scroll
		var page := tabs.get_current_tab_control()
		_ok(scroll != null and (scroll == page or page.is_ancestor_of(scroll)),
			"scroll/%s drives its own list" % tabs.get_tab_title(i), "tab %d got %s" % [i, str(scroll)])
	ui.free()


func _test_rows() -> void:
	var ui := _ui()
	ui.populate_states(_rows(3), 3 * 4096)
	_eq("rows/one plate per state", _live_children(ui._states_box), 3)
	_ok(ui._state_total_lbl.text.begins_with("3 states"),
		"rows/the header counts them", ui._state_total_lbl.text)
	_ok(ui._state_total_lbl.text.ends_with("KB"), "rows/and sizes them", ui._state_total_lbl.text)

	# The singular matters: "1 states" is the kind of thing nobody notices until
	# it ships.
	ui.populate_states(_rows(1), 4096)
	_ok(ui._state_total_lbl.text.begins_with("1 state "),
		"rows/one state, not one states", ui._state_total_lbl.text)

	ui.populate_states([], 0)
	_eq("rows/empty says so", _live_children(ui._states_box), 1)

	# A server row is offered even with nothing local, or a state pulled to a new
	# device would be invisible.
	ui.populate_states([], 0, {}, [{"state_id": "1787000000000-000001",
		"updated_at": "2026-08-17T21:00:00", "size": 4096}])
	_ok(_live_children(ui._states_box) >= 2, "rows/a server-only state is listed")
	ui.free()


func _test_blocked() -> void:
	var ui := _ui()
	ui.capture_blocked = "no machine is running this game"
	ui.populate_states(_rows(2), 8192)
	_ok(ui._state_capture_btn.disabled, "blocked/capture is disabled")
	_eq("blocked/and says why", ui._state_capture_btn.tooltip_text,
		"no machine is running this game")
	# Overwrite writes too, so the same blocker has to reach it. Missing this is
	# how a greyed-out header sits above three live overwrite buttons.
	var disabled := 0
	var enabled := 0
	for b: Variant in _buttons(ui._states_box):
		if (b as Button).tooltip_text == "no machine is running this game":
			disabled += 1
		elif (b as Button).tooltip_text.begins_with("Save over"):
			enabled += 1
	_eq("blocked/every overwrite button too", [disabled, enabled], [2, 0])

	ui.capture_blocked = ""
	ui.populate_states(_rows(2), 8192)
	_ok(not ui._state_capture_btn.disabled, "blocked/and they come back")
	ui.free()


func _test_armed_row() -> void:
	var ui := _ui()
	var rows := _rows(3)
	ui.states_armed_id = str(rows[1]["state_id"])
	ui.states_armed_action = "overwrite"
	ui.populate_states(rows, 3 * 4096)
	var warned := 0
	for lbl: Variant in _labels(ui._states_box):
		if str((lbl as Label).text).begins_with("Press again to save over"):
			warned += 1
	_eq("armed/exactly one row asks again", warned, 1)

	ui.states_armed_action = "delete"
	ui.populate_states(rows, 3 * 4096)
	var bins := 0
	for lbl: Variant in _labels(ui._states_box):
		if str((lbl as Label).text).begins_with("Press the bin again"):
			bins += 1
	_eq("armed/the bin asks its own question", bins, 1)
	ui.free()


func _labels(node: Node, into: Array = []) -> Array:
	if node is Label:
		into.append(node)
	for child in node.get_children():
		_labels(child, into)
	return into


## Arm, then do — and one arm slot between the two destructive actions, so a row
## is never waiting on two different confirmations at once.
func _test_arm_ladder() -> void:
	var panel := CartridgeOptionsPanel.new()
	add_child(panel)

	_ok(not panel._arm_state("A", "overwrite"), "arm/the first press only arms")
	_eq("arm/and the row remembers which", [panel._states_armed_id, panel._states_armed_action],
		["A", "overwrite"])
	_ok(panel._arm_state("A", "overwrite"), "arm/the second press confirms")
	_eq("arm/and disarms", panel._states_armed_id, "")

	# The other action on the SAME row: arming it must not inherit the first
	# one's confirmation.
	_ok(not panel._arm_state("A", "overwrite"), "arm/overwrite arms")
	_ok(not panel._arm_state("A", "delete"), "arm/then the bin only arms")
	_eq("arm/the bin took the slot", panel._states_armed_action, "delete")
	_ok(not panel._arm_state("A", "overwrite"), "arm/and overwrite is no longer confirmable")

	# A different row takes the slot rather than sharing it.
	_ok(not panel._arm_state("B", "overwrite"), "arm/another row only arms")
	_eq("arm/and owns the slot now", panel._states_armed_id, "B")
	panel.free()


## Why there is no RomM column, when there isn't one.
##
## The bug this pins shipped: with backup on and the server up, a hand-copied ROM
## has no RomM id, so the column vanished and every row read "On this device"
## with nothing anywhere saying why — indistinguishable from the feature being
## missing. Each branch has to name the one thing the player could act on.
func _test_backup_notice() -> void:
	var panel := CartridgeOptionsPanel.new()
	add_child(panel)
	var cfg := RommConfig.new()
	cfg.enabled = true
	cfg.base_url = "http://127.0.0.1:1"
	cfg.token = "x"

	# No server at all is not a problem to report — RomM simply is not part of
	# how this player uses the app, and a nag on every cartridge would be noise.
	var saved_save_cfg: RommConfig = SaveSync.config
	var saved_state_cfg: RommConfig = StateSync.config
	SaveSync.config = RommConfig.new()
	StateSync.config = cfg
	_eq("notice/an unconfigured server says nothing", panel._backup_notice("fceumm", []), "")

	# Configured, but the switch is off: name the switch, not the symptom.
	SaveSync.config = cfg
	cfg.backup_enabled = false
	var off := panel._backup_notice("fceumm", [])
	_ok(off.contains("Back up saves and states") and off.contains("OPTIONS"),
		"notice/the switch being off names the switch", off)

	# Switch on, server up, and a real ROM with no RomM id. The three answers
	# below are the ones that were conflated: "not asked yet", "asked and it is
	# not there", and "could not find out" are different sentences, and telling
	# a player the second when the third is true sends them looking for the
	# wrong problem.
	cfg.backup_enabled = true
	panel._cart = FakeCart.new()
	var rom_path: String = panel._rom()

	_eq("notice/before the lookup runs there is nothing to say",
		panel._backup_notice("fceumm", []), "")

	SaveSync._id_done("nes", rom_path, 0, false)
	_ok(panel._backup_notice("fceumm", []).contains("Could not reach RomM"),
		"notice/a lookup that failed says it could not check", panel._backup_notice("fceumm", []))

	SaveSync._id_done("nes", rom_path, 0, true)
	_ok(panel._backup_notice("fceumm", []).contains("does not have this ROM"),
		"notice/a lookup that answered 'no' says THAT instead", panel._backup_notice("fceumm", []))

	# And a hit says nothing at all — the column is there, so the rows speak.
	SaveSync._id_done("nes", rom_path, 4242, true)
	_eq("notice/a hit says nothing", panel._backup_notice("fceumm", []), "")

	SaveSync._hash_ids.erase("nes/" + rom_path.get_file())
	SaveSync._id_failed.erase("nes/" + rom_path.get_file())
	SaveSync._rom_ids.erase(rom_path)
	SaveSync.config = saved_save_cfg
	StateSync.config = saved_state_cfg
	panel.free()


## The panel reads its target through named properties only, so a bare object
## carrying them stands in for a cartridge.
class FakeCart extends RefCounted:
	var systemid := "nes"
	var rom_path := "/__state_tests/notice_probe.nes"
	var game_label := "Notice Probe"
	var save_id := ""


func _test_thumb_cache() -> void:
	var ui := _ui()
	# A path that decodes to nothing still caches, or every repopulate retries a
	# file that is not there.
	var missing := "user://__no_such_state_shot.png"
	_eq("thumb/a missing picture is null", ui._thumb(missing), null)
	_ok(ui._thumb_cache.has(missing), "thumb/and is remembered as null")

	var path := "user://__state_tests_shot.png"
	var img := Image.create(32, 24, false, Image.FORMAT_RGB8)
	img.fill(Color(0.2, 0.4, 0.8))
	img.save_png(path)
	var first := ui._thumb(path)
	_ok(first != null, "thumb/a real picture decodes")
	_ok(ui._thumb(path) == first, "thumb/and is not decoded twice")
	# An overwrite writes a NEW picture to the SAME path, so the cache has to be
	# told or the row keeps showing the frame it replaced.
	ui.forget_thumb(path)
	_ok(not ui._thumb_cache.has(path), "thumb/forgetting it forces a re-read")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	ui.free()


# ── Panel chrome ──────────────────────────────────────────────────────────────
#
# The rounded background every *_2d panel puts behind itself. Eleven of them
# hand-rolled the four-corner loop; they now call MenuStyle.rounded, which is
# what the menu views already used. Nothing asserted the result before, so a
# swapped colour or a radius typed as 1 instead of 10 would have shipped
# looking almost right.

func _test_panel_chrome() -> void:
	var ui := _ui()
	var panel := _find(ui, "PanelContainer") as PanelContainer
	_ok(panel != null, "chrome/the view has a panel behind it")
	if panel == null:
		ui.free()
		return

	var sb := panel.get_theme_stylebox("panel") as StyleBoxFlat
	_ok(sb != null, "chrome/and it is a flat stylebox")
	if sb != null:
		# All four, not just one: the loop this replaced set them by name, and a
		# hand-written replacement that misses a corner is invisible in review and
		# obvious on screen.
		_eq("chrome/top-left is rounded", sb.corner_radius_top_left, 10)
		_eq("chrome/top-right is rounded", sb.corner_radius_top_right, 10)
		_eq("chrome/bottom-left is rounded", sb.corner_radius_bottom_left, 10)
		_eq("chrome/bottom-right is rounded", sb.corner_radius_bottom_right, 10)
		_ok(sb.bg_color.a > 0.5, "chrome/the background is opaque", str(sb.bg_color))

	# The margin is the builder's other half: ten panels used to add their own
	# PanelContainer and MarginContainer by hand, and the panel is useless if the
	# content sits flush against the rounded edge.
	var margin := _find(ui, "MarginContainer") as MarginContainer
	_ok(margin != null, "chrome/the content is inset from the edge")
	if margin != null:
		for side in ["margin_top", "margin_bottom", "margin_left", "margin_right"]:
			_ok(margin.get_theme_constant(side) > 0,
				"chrome/%s is set" % side, "%s = %d" % [side, margin.get_theme_constant(side)])
		_ok(panel.is_ancestor_of(margin), "chrome/and the margin lives inside the panel")

	# MenuStyle.panel_root builds both halves; prove it directly as well, so a
	# panel that stops using it is the only thing that can break these.
	var host := Node2D.new()
	add_child(host)
	var built := MenuStyle.panel_root(host, Color(0.2, 0.3, 0.4, 1.0), 6, 9)
	_ok(built != null, "chrome/the builder returns a margin")
	_eq("chrome/the builder sets the padding it was given",
		built.get_theme_constant("margin_left"), 9)
	var built_panel := built.get_parent() as PanelContainer
	_ok(built_panel != null, "chrome/wrapped in a panel")
	if built_panel != null:
		var built_sb := built_panel.get_theme_stylebox("panel") as StyleBoxFlat
		_eq("chrome/with the radius it was given",
			built_sb.corner_radius_top_left, 6)
		_eq("chrome/and the colour", built_sb.bg_color, Color(0.2, 0.3, 0.4, 1.0))
		_ok(built_panel.anchor_right == 1.0 and built_panel.anchor_bottom == 1.0,
			"chrome/anchored to fill its host")
	host.free()

	# MenuStyle.rounded is the shared builder; prove it really does produce the
	# same thing the panels used to build by hand, so the swap is not just
	# consistent with itself.
	var made := MenuStyle.rounded(Color(0.1, 0.2, 0.3, 0.9), 7)
	_eq("chrome/the shared builder keeps the colour", made.bg_color,
		Color(0.1, 0.2, 0.3, 0.9))
	for corner in ["corner_radius_top_left", "corner_radius_top_right",
			"corner_radius_bottom_left", "corner_radius_bottom_right"]:
		_eq("chrome/the shared builder sets %s" % corner, made.get(corner), 7)
	ui.free()


# ── Floating 3D panels ────────────────────────────────────────────────────────
#
# Six options panels used to carry their own copy of "park above the subject and
# turn to face the player"; they share FloatingObjectPanel3D now. Nothing tested
# any of it before, and the failure it guards against is not subtle: a panel that
# parks at the origin, or presents its back.
#
# The panels' own scenes host a SubViewport, which hangs a headless run, so these
# drive the base directly through a stub and then check each real panel reports
# the height and subject it always did.

class _StubPanel extends FloatingObjectPanel3D:
	var subject: Node3D = null
	var height := 0.5
	func _target_node() -> Node3D: return subject
	func _float_height() -> float: return height


func _test_floating_panels() -> void:
	var panel := _StubPanel.new()
	var subject := Node3D.new()
	var camera := Node3D.new()
	add_child(panel)
	add_child(subject)
	add_child(camera)

	_ok(not panel.visible, "panel/starts hidden")
	_ok(panel.top_level, "panel/and detached from its parent's transform")

	subject.global_position = Vector3(2, 1, -3)
	panel.subject = subject
	panel._camera = camera
	camera.global_position = Vector3(2, 1.6, 0)

	# Hidden: a panel nobody asked for must not be doing transform work.
	#
	# TWO frames, not one. process_frame is emitted before the node _process
	# callbacks for that frame, so a single await returns having run none of them
	# and the assertion below passes whatever _process does — it was vacuous until
	# a mutation check removed the visibility guard and this stayed green.
	await get_tree().process_frame
	await get_tree().process_frame
	_ok(panel.global_position.is_equal_approx(Vector3.ZERO),
		"panel/a hidden panel does not move", str(panel.global_position))

	panel.visible = true
	await get_tree().process_frame
	_ok(panel.global_position.is_equal_approx(Vector3(2, 1.5, -3)),
		"panel/it parks above its subject", str(panel.global_position))

	# Facing, not merely rotated: the panel's own +Z has to point at the head.
	# look_at aims -Z, so the half turn in _process is what makes this true, and
	# without it every panel would show the player its back.
	var to_camera := (camera.global_position - panel.global_position).normalized()
	_ok(panel.global_transform.basis.z.dot(to_camera) > 0.9,
		"panel/and turns its face to the camera", "dot = %.3f" % panel.global_transform.basis.z.dot(to_camera))

	# Following, not a one-off placement.
	subject.global_position = Vector3(-4, 0.25, 1)
	await get_tree().process_frame
	_ok(panel.global_position.is_equal_approx(Vector3(-4, 0.75, 1)),
		"panel/it follows the subject", str(panel.global_position))

	panel.hide_panel()
	_ok(not panel.visible, "panel/hide_panel hides it")

	# A subject that goes away mid-frame must not take the panel with it.
	panel.visible = true
	panel.subject = null
	await get_tree().process_frame
	_ok(panel.global_position.is_equal_approx(Vector3(-4, 0.75, 1)),
		"panel/a panel whose subject vanished stays put")

	panel.free()
	subject.free()
	camera.free()

	# Each real panel still reports the height it always had, so the shared
	# _process places it exactly where its own _process used to.
	for entry in [["audio_options_panel", "_player", 0.3],
			["book_options_panel", "_book", 0.35],
			["dvd_options_panel", "_dvd", 0.42],
			["mouse_options_panel", "_mouse", 0.3],
			["vcr_options_panel", "_vcr", 0.42],
			["memory_card_panel", "_card", 0.32],
			["cartridge_options_panel", "_cart", 0.25]]:
		var file: String = entry[0]
		var scr := load("res://Scripts/UI/panels/%s.gd" % file) as GDScript
		var base := scr.get_base_script() as GDScript
		_ok(base != null and base.resource_path.ends_with("floating_object_panel_3d.gd"),
			"panel/%s uses the shared base" % file)
		var inst: Node3D = scr.new()
		_eq("panel/%s keeps its float height" % file, inst._float_height(), float(entry[2]))
		_ok(inst._target_node() == null, "panel/%s reports no subject before it is shown" % file)
		inst.free()


## The three panels whose placement is not "straight up from the origin": the
## television measures the set's own top so the panel clears a grown screen, the
## poster steps off the surface it is stuck to, and the core panel clears the
## tower. They share the base's _process and override _anchor instead, so what
## matters is that the override is really theirs and not the base's default.
func _test_panels_with_their_own_anchor() -> void:
	var base := load("res://Scripts/UI/panels/floating_object_panel_3d.gd") as GDScript
	for file in ["tv_options_panel", "poster_options_panel", "core_options_panel"]:
		var scr := load("res://Scripts/UI/panels/%s.gd" % file) as GDScript
		_ok(scr.get_base_script() == base, "anchor/%s uses the shared base" % file)
		# Read from the source, not get_script_method_list(): that reports
		# inherited methods too, so it says every panel has _process whether it
		# declares one or not -- which is how this case first passed while
		# asserting nothing. scene_tests' vlc/ group reads source for the same
		# reason.
		var src := FileAccess.get_file_as_string("res://Scripts/UI/panels/%s.gd" % file)
		_ok(src.contains("func _anchor() -> Vector3:"), "anchor/%s declares its own _anchor" % file)
		_ok(not src.contains("func _process("),
			"anchor/%s no longer carries a copy of _process" % file)
