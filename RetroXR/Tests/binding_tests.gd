## Binding self-tests — the resolution rules behind per-platform control
## overrides, run headless with no core, no ROM, no headset and no pad.
##
##     "$godot" --headless --path RetroXR res://Tests/binding_tests.tscn
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## Both stores merge default → global → per-system, and a platform's stored
## profile IS its override switch — there is no separate flag. That makes three
## rules load-bearing, and each has a case below: a platform with no profile is
## indistinguishable from global; a profile shadows global completely, including
## global edits made afterwards; and clearing a profile puts that platform back
## on global without touching anyone else's.
##
## What is NOT covered here, on purpose: that a binding reaches a running core.
## That needs a real system, a real controller and the CONSUMER_GROUP fan-out,
## and it lives in Tools/input/binding_live_probe.tscn.
##
## This writes the player's own user://controller_bindings.json and
## user://gamepad_bindings.json — the paths are consts on the two classes and
## cannot be pointed elsewhere — so both are snapshotted up front and restored
## byte-for-byte at the end.
extends Node

## Two platforms, so "clearing one leaves the other standing" is a real
## assertion rather than a tautology. Named so a leaked file is obviously test
## residue and not a console the player owns.
const SYS_A := "__binding_selftest_a"
const SYS_B := "__binding_selftest_b"

var _pass := 0
var _fail := 0

## path -> file contents, or an absent key when there was no file to begin with.
var _saved: Dictionary = {}

## Guards _snapshot() against overwriting the player's data with test data.
var _snapped := false


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		_restore()
		get_tree().quit(1))

	_snapshot()
	_clear()

	_test_no_profile_is_global()
	_test_profile_shadows_global()
	_test_later_global_edit_does_not_leak()
	_test_has_override()
	_test_clear_restores_global()
	_test_empty_systemid_is_global()
	_test_overridden_systems()
	_test_wii_layers_survive_a_save()
	_test_console_pad_art()
	_test_the_editor_writes_the_nunchuk_layer()
	_test_the_wii_diagram_writes_the_wiimote_layer()
	_test_the_sideways_diagram_has_its_own_layer()
	_test_wii_target_table_matches_the_remote()
	_test_pad_art_variants()
	_test_wii_pad_art()
	_test_desktop_layers()
	_test_desktop_legacy_file()
	_test_xr_identity()
	_test_json_store()
	_test_input_latch()

	_restore()
	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


## The filename a diagram actually resolves for a control, or "" for none.
func _glyph_stem(diagram: ConsolePadDiagram, control: String) -> String:
	var tex: Texture2D = diagram._control_glyph(control)
	if tex == null:
		return ""
	return tex.resource_path.get_file().get_basename()


func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s" % name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(got: Variant, want: Variant, name: String) -> void:
	_ok(got == want, name, "got %s, want %s" % [str(got), str(want)])


# ── The player's own files, taken away and put back ───────────────────────────

## Snapshot the player's real bindings. Idempotent ON PURPOSE, and the guard is
## the whole point: every case below starts from a clean slate, so this used to
## be called again at the top of each one — and because it also DELETED the
## files, the second call snapshotted the FIRST case's test data over the
## player's. _restore() then faithfully put the test data back. It overwrote a
## real settings file with `right_grip -> R2` and `a -> btn:9`, which are
## literally _xr_profile() and _pad_profile()'s arguments.
func _snapshot() -> void:
	if _snapped:
		return
	_snapped = true
	for path: String in _stores():
		if FileAccess.file_exists(path):
			_saved[path] = FileAccess.get_file_as_string(path)


## The clean slate each case wants. Deletes only — it never touches the snapshot.
func _clear() -> void:
	for path: String in _stores():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## Every file these cases write. DesktopBindings is here too: it is a third
## store, and forgetting it would leave test key maps in the player's InputMap.
func _stores() -> Array:
	return [ControllerBindings.SAVE_PATH, GamepadBindings.SAVE_PATH,
		DesktopBindings.SAVE_PATH]


func _restore() -> void:
	for path: String in _stores():
		if _saved.has(path):
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f:
				f.store_string(_saved[path] as String)
				f.close()
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## A whole XR profile built off the shipped defaults with one button moved, so
## every key is present — a partial profile would leak later global edits, which
## is exactly what _test_later_global_edit_does_not_leak checks against.
func _xr_profile(source: String, bit: int) -> Array:
	var buttons := ControllerBindings.DEFAULT_BUTTON_MAP.duplicate()
	buttons[source] = bit
	return [buttons, ControllerBindings.DEFAULT_STICK_MAP.duplicate(),
		ControllerBindings.DEFAULT_LIGHTGUN_MAP.duplicate()]


func _pad_profile(target: String, binding: String) -> Array:
	var buttons := GamepadBindings.DEFAULT_BUTTON_MAP.duplicate()
	buttons[target] = binding
	return [buttons, GamepadBindings.DEFAULT_STICK_MAP.duplicate()]


# ---------------------------------------------------------------------------
# A platform with no profile of its own is exactly global.
# ---------------------------------------------------------------------------

func _test_no_profile_is_global() -> void:
	_clear()
	var xr_global := _xr_profile("right_grip", ControllerBindings.JOYPAD_L)
	ControllerBindings.save_global(xr_global[0], xr_global[1], xr_global[2])
	var pad_global := _pad_profile("a", "btn:5")
	GamepadBindings.save_global(pad_global[0], pad_global[1])

	_eq(ControllerBindings.get_for_system(SYS_A)["buttons"],
		ControllerBindings.get_global()["buttons"],
		"xr/no profile resolves to global")
	_eq(GamepadBindings.get_for_system(SYS_A)["buttons"],
		GamepadBindings.get_global()["buttons"],
		"pad/no profile resolves to global")
	# And the global edit itself took, rather than both sides agreeing on stale
	# defaults — a comparison of two identical wrong answers proves nothing.
	_eq(int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L,
		"xr/global edit took")
	_eq(str((GamepadBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("a")),
		"btn:5",
		"pad/global edit took")


# ---------------------------------------------------------------------------
# A profile shadows global for its own platform and nobody else's.
# ---------------------------------------------------------------------------

func _test_profile_shadows_global() -> void:
	_clear()
	var g := _xr_profile("right_grip", ControllerBindings.JOYPAD_L)
	ControllerBindings.save_global(g[0], g[1], g[2])
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])

	_eq(int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_R2,
		"xr/profile wins for its own platform")
	_eq(int((ControllerBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L,
		"xr/another platform still reads global")
	_eq(int((ControllerBindings.get_global()["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L,
		"xr/the global map itself is untouched")

	var pg := _pad_profile("a", "btn:5")
	GamepadBindings.save_global(pg[0], pg[1])
	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])

	_eq(str((GamepadBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("a")),
		"btn:9", "pad/profile wins for its own platform")
	_eq(str((GamepadBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("a")),
		"btn:5", "pad/another platform still reads global")
	_eq(str((GamepadBindings.get_global()["buttons"] as Dictionary).get("a")),
		"btn:5", "pad/the global map itself is untouched")


# ---------------------------------------------------------------------------
# The reason a profile is written WHOLE: an override must pin a platform against
# global edits made after it, not track them.
# ---------------------------------------------------------------------------

func _test_later_global_edit_does_not_leak() -> void:
	_clear()
	var g := _xr_profile("right_grip", ControllerBindings.JOYPAD_L)
	ControllerBindings.save_global(g[0], g[1], g[2])
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])

	# Move a DIFFERENT button globally, after the override was written.
	var g2 := _xr_profile("left_grip", ControllerBindings.JOYPAD_R3)
	ControllerBindings.save_global(g2[0], g2[1], g2[2])

	_eq(int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("left_grip")),
		ControllerBindings.DEFAULT_BUTTON_MAP["left_grip"],
		"xr/a later global edit does not reach an overridden platform")
	_eq(int((ControllerBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("left_grip")),
		ControllerBindings.JOYPAD_R3,
		"xr/but it does reach an un-overridden one")


# ---------------------------------------------------------------------------
# The switch's own state: the profile IS the flag.
# ---------------------------------------------------------------------------

func _test_has_override() -> void:
	_clear()
	_ok(not ControllerBindings.has_system_override(SYS_A), "xr/no override before a write")
	_ok(not GamepadBindings.has_system_override(SYS_A), "pad/no override before a write")

	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])
	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])

	_ok(ControllerBindings.has_system_override(SYS_A), "xr/override after a write")
	_ok(GamepadBindings.has_system_override(SYS_A), "pad/override after a write")
	_ok(not ControllerBindings.has_system_override(SYS_B), "xr/a sibling platform is unaffected")
	_ok(not GamepadBindings.has_system_override(SYS_B), "pad/a sibling platform is unaffected")
	# The global map must never report as an override, or the switch would come
	# up ON for every platform the moment the player edits the global page.
	_ok(not ControllerBindings.has_system_override(""), "xr/the global scope is not an override")
	_ok(not GamepadBindings.has_system_override(""), "pad/the global scope is not an override")


# ---------------------------------------------------------------------------
# Turning the switch off.
# ---------------------------------------------------------------------------

func _test_clear_restores_global() -> void:
	_clear()
	var g := _xr_profile("right_grip", ControllerBindings.JOYPAD_L)
	ControllerBindings.save_global(g[0], g[1], g[2])
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])
	var b := _xr_profile("right_grip", ControllerBindings.JOYPAD_L2)
	ControllerBindings.save_for_system(SYS_B, b[0], b[1], b[2])

	ControllerBindings.clear_system_override(SYS_A)

	_ok(not ControllerBindings.has_system_override(SYS_A), "xr/clear drops the override")
	_eq(int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L,
		"xr/cleared platform is back on global")
	_ok(ControllerBindings.has_system_override(SYS_B), "xr/the other platform's profile stands")
	_eq(int((ControllerBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L2,
		"xr/and still resolves to its own value")
	_eq(int((ControllerBindings.get_global()["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L,
		"xr/global survives the clear")

	var pg := _pad_profile("a", "btn:5")
	GamepadBindings.save_global(pg[0], pg[1])
	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])
	GamepadBindings.clear_system_override(SYS_A)
	_ok(not GamepadBindings.has_system_override(SYS_A), "pad/clear drops the override")
	_eq(str((GamepadBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("a")),
		"btn:5", "pad/cleared platform is back on global")

	# Clearing a platform that never had one is a no-op, not a crash — the switch
	# can be flicked off on a page that was never overridden.
	ControllerBindings.clear_system_override("__never_written")
	GamepadBindings.clear_system_override("__never_written")
	_ok(true, "clearing an absent profile is harmless")


# ---------------------------------------------------------------------------
# The fall-through the shared binding editor is built on: one editor class
# serves both pages because an empty systemid means "global".
# ---------------------------------------------------------------------------

func _test_empty_systemid_is_global() -> void:
	_clear()
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system("", a[0], a[1], a[2])
	_eq(int((ControllerBindings.get_global()["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_R2,
		"xr/save_for_system(\"\") writes global")

	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system("", pa[0], pa[1])
	_eq(str((GamepadBindings.get_global()["buttons"] as Dictionary).get("a")),
		"btn:9", "pad/save_for_system(\"\") writes global")

	_eq(ControllerBindings.get_for_system("")["buttons"],
		ControllerBindings.get_global()["buttons"],
		"xr/get_for_system(\"\") is get_global")
	_eq(GamepadBindings.get_for_system("")["buttons"],
		GamepadBindings.get_global()["buttons"],
		"pad/get_for_system(\"\") is get_global")

	# A global write must not invent a per_system entry, or every platform tile
	# would come up badged the first time the global page is touched.
	_ok(ControllerBindings.overridden_systems().is_empty(),
		"xr/a global write creates no per-system entry")
	_ok(GamepadBindings.overridden_systems().is_empty(),
		"pad/a global write creates no per-system entry")


# ---------------------------------------------------------------------------
# What the tile badges are painted from.
# ---------------------------------------------------------------------------

func _test_overridden_systems() -> void:
	_clear()
	_ok(ControllerBindings.overridden_systems().is_empty(),
		"xr/nothing overridden on a fresh store")

	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])
	var b := _xr_profile("right_grip", ControllerBindings.JOYPAD_L2)
	ControllerBindings.save_for_system(SYS_B, b[0], b[1], b[2])

	var listed := ControllerBindings.overridden_systems()
	listed.sort()
	_eq(listed, [SYS_A, SYS_B], "xr/lists exactly the overridden platforms")

	ControllerBindings.clear_system_override(SYS_A)
	_eq(ControllerBindings.overridden_systems(),
		[SYS_B], "xr/a cleared platform leaves the list")

	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])
	_eq(GamepadBindings.overridden_systems(),
		[SYS_A], "pad/lists its own overridden platforms")
	# The two stores are independent: a pad override alone must still badge the
	# tile, which is why the view asks both.
	_ok(GamepadBindings.has_system_override(SYS_A) and not ControllerBindings.has_system_override(SYS_A),
		"the two stores disagree independently")


# ---------------------------------------------------------------------------
# ConsolePadArt — the table a platform's own controller is drawn from.
# ---------------------------------------------------------------------------

## The Wii Remote's diagram, and the one thing about it that can silently rot:
## the art speaks RETROPAD targets while the remote itself speaks the names
## printed on its shell, and the two have to agree about which cap is which.
# ---------------------------------------------------------------------------
# A console can be held more than one way, and each way relabels the same
# RetroPad bits. Those are art VARIANTS, not platforms, and the difference is
# load-bearing: a variant that answered has() would grow a tile in the platform
# grid for a console nobody owns.
# ---------------------------------------------------------------------------

## The editor's own path to the store, which the writer case cannot reach.
##
## save_for_system carries a stored Nunchuk layer over only when the caller
## offers nothing, so an editor that forgot to pass its working copy would look
## exactly like one that worked: the old value stays, the new one is dropped, and
## nothing anywhere errors.
func _test_the_editor_writes_the_nunchuk_layer() -> void:
	_clear()
	var ed := ControlsBindingEditor.new()
	add_child(ed)
	ed._systemid = "wii"
	ed._build_xr_controls(ed)

	_eq(str(ed._edit_nunchuk_map.get("c")),
		"ax_button", "editor/starts from the stored map")

	ed._edit_nunchuk_map["c"] = "grip"
	ed._apply_xr_bindings()
	_eq(str((ControllerBindings.get_for_system("wii")["nunchuk"] as Dictionary).get("c")),
		"grip",
		"editor/a change to C reaches the store")
	# And did not take the other key with it.
	_eq(str((ControllerBindings.get_for_system("wii")["nunchuk"] as Dictionary).get("z")),
		"trigger",
		"editor/while Z keeps its default")

	# The rows exist and are the two that can be bound. The stick is not among
	# them on purpose — it is whichever hand is holding the Nunchuk.
	_ok(ed._controls_opts.has("nc:c"), "editor/there is a row for C")
	_ok(ed._controls_opts.has("nc:z"), "editor/and one for Z")
	_ok(not ed._controls_opts.has("nc:stick"), "editor/and none for the stick")

	# A Wii Remote has a D-pad and no analog stick, and the two joypad stick rows
	# are not merely meaningless on that page — the remote reads its own layer and
	# never the joypad stick map, so they were live-looking controls that did
	# nothing at all.
	_ok(not ed._controls_opts.has("stick:stick_left"),
		"editor/the wii page offers no left stick row")
	_ok(not ed._controls_opts.has("stick:stick_right"), "editor/nor a right stick row")
	ed.queue_free()

	# A platform whose pad really has sticks still gets them, so the case above is
	# a gate rather than a deletion.
	var other := ControlsBindingEditor.new()
	add_child(other)
	other._systemid = SYS_A
	other._build_xr_controls(other)
	_ok(other._controls_opts.has("stick:stick_left") and other._controls_opts.has("stick:stick_right"),
		"editor/a platform with sticks still gets its rows")
	other.queue_free()


## The remote's picture must edit the map the remote READS.
##
## This is the defect the stick rows were a corner of: wiimote.gd resolves
## get_for_system(...)["wiimote"] and nothing else, so a diagram writing the
## joypad map was eleven live-looking dropdowns that changed nothing.
func _test_the_wii_diagram_writes_the_wiimote_layer() -> void:
	_clear()
	var ed := ControlsBindingEditor.new()
	add_child(ed)
	ed._systemid = "wii"
	ed._build_xr_controls(ed)

	# The picture is anchored on RetroPad targets; the remote is bound by control
	# name. "x" is the 1 button, and grip carries it by default.
	_eq(ed._wiimote_source_for("x"),
		"grip", "wii-xr/the picture reads the remote's own map")
	_eq(ed._wiimote_source_for("b"), "trigger", "wii-xr/and B is the trigger")

	# Moving a control takes the source off whatever it was on, and lands in the
	# layer the remote reads.
	ed._on_console_xr_changed("x", "by_button")
	var stored: Dictionary = ControllerBindings.get_for_system("wii")["wiimote"]
	_eq(str(stored.get("by_button")), "one", "wii-xr/a change lands in the wiimote layer")
	_eq(str(stored.get("grip")), "none", "wii-xr/and the source it displaced is freed")
	_eq(ed._wiimote_source_for("x"), "by_button", "wii-xr/the picture agrees afterwards")

	# It must NOT have gone into the joypad map, which is the map that was being
	# written before and the one the remote never reads.
	var joypad: Dictionary = ControllerBindings.get_for_system("wii")["buttons"]
	_eq(int(joypad.get("right_grip", -99)),
		int((ControllerBindings.DEFAULT_BUTTON_MAP as Dictionary).get("right_grip", -99)),
		"wii-xr/and not into the joypad map")

	# Every control the picture draws can be bound, including the cross. The page
	# has always said the D-pad is bindable; for this remote it was not.
	var unbindable: Array = []
	for control: String in ConsolePadArt.controls("wii"):
		if String(ControllerBindings.WIIMOTE_CONTROL_OF_TARGET.get(control, "")).is_empty():
			unbindable.append(control)
	_eq(unbindable, [], "wii-xr/every drawn control maps to a remote control")
	ed.queue_free()


func _test_the_sideways_diagram_has_its_own_layer() -> void:
	_clear()
	var ed := ControlsBindingEditor.new()
	add_child(ed)
	ed._systemid = "wii"
	ed._build_xr_controls(ed)

	_eq(ed._wiimote_source_for("y", ConsolePadArt.WII_SIDEWAYS),
		"left_trigger", "wii-sideways/left trigger works physical B")
	_eq(ed._wiimote_source_for("b", ConsolePadArt.WII_SIDEWAYS),
		"right_by_button", "wii-sideways/right B works physical 1")
	_eq(ed._wiimote_source_for("a", ConsolePadArt.WII_SIDEWAYS),
		"right_ax_button", "wii-sideways/right A works physical 2")
	_eq(ed._wiimote_source_for("select", ConsolePadArt.WII_SIDEWAYS),
		"left_primary_click",
		"wii-sideways/left click works minus")
	_eq(ed._wiimote_source_for("start", ConsolePadArt.WII_SIDEWAYS),
		"right_primary_click",
		"wii-sideways/right click works plus")
	_eq(str(ControllerBindings.WIIMOTE_SIDEWAYS_CONTROL_OF_TARGET.get("left")),
		"up", "wii-sideways/logical Left is the physical Up arm")
	_eq(str(ControllerBindings.WIIMOTE_SIDEWAYS_CONTROL_OF_TARGET.get("up")),
		"right", "wii-sideways/logical Up is the physical Right arm")

	# Rebinding the sideways picture changes only its hand-specific layer.
	ed._on_console_xr_changed("b", "right_trigger", ConsolePadArt.WII_SIDEWAYS)
	var resolved := ControllerBindings.get_for_system("wii")
	var sideways: Dictionary = resolved["wiimote_sideways"]
	_eq(str(sideways.get("right_trigger")),
		"one", "wii-sideways/a change lands in the sideways layer")
	_eq(str(sideways.get("right_by_button")),
		"none", "wii-sideways/and frees the old source")
	_eq(str((resolved["wiimote"] as Dictionary).get("trigger")),
		"b", "wii-sideways/upright trigger remains B")
	_eq(ed._wiimote_source_for("b", ConsolePadArt.WII_SIDEWAYS),
		"right_trigger", "wii-sideways/the sideways picture agrees")
	ed.queue_free()


## The crossing table and the remote's own desktop map must agree, since they are
## two statements of the same fact in files that cannot import each other.
func _test_wii_target_table_matches_the_remote() -> void:
	for retro_name: String in Wiimote.DESKTOP_BUTTON_MAP:
		var target := retro_name.trim_prefix("RETRO_JOYPAD_").to_lower()
		_eq(str(ControllerBindings.WIIMOTE_CONTROL_OF_TARGET.get(target, "")),
			str(Wiimote.DESKTOP_BUTTON_MAP[retro_name]),
			"wii-xr/%s agrees with DESKTOP_BUTTON_MAP" % target)


func _test_pad_art_variants() -> void:
	_ok(not ConsolePadArt.has(ConsolePadArt.WII_SIDEWAYS), "variant/sideways is not a platform")
	_ok(not ConsolePadArt.has(ConsolePadArt.RETROPAD), "variant/nor is the generic pad")
	_ok(not ConsolePadArt.row(ConsolePadArt.WII_SIDEWAYS).is_empty(), "variant/but it has a row")
	_ok(ResourceLoader.exists(String(ConsolePadArt.row(ConsolePadArt.WII_SIDEWAYS)["art"])),
		"variant/and its art loads")

	# The Wii draws two pictures; everyone else draws one; the global page draws
	# none. Order matters — the upright remote is the one a player meets first.
	_eq(ConsolePadArt.variants_for("wii"),
		["wii", ConsolePadArt.WII_SIDEWAYS], "variant/the wii lists both ways it is held")
	_eq(ConsolePadArt.variants_for("nes"),
		["nes"], "variant/a one-way console lists just itself")
	_eq(ConsolePadArt.variants_for(""), [], "variant/the global scope lists none")

	# Same bits, different names. Sideways is a picture and a set of labels, not a
	# second binding map, so it must carry exactly the controls the upright remote
	# does — a variant that dropped one would leave that button unbindable on a
	# page the player might be looking at.
	var upright := ConsolePadArt.controls("wii").duplicate()
	var sideways := ConsolePadArt.controls(ConsolePadArt.WII_SIDEWAYS).duplicate()
	upright.sort()
	sideways.sort()
	_eq(sideways, upright, "variant/sideways carries the same controls as upright")

	# Every control is drawn and every drawn control is listed. A missing anchor
	# is a lead to nowhere; a missing row entry is a control the page will not
	# draw, which is a control the player cannot rebind.
	var anchors: Dictionary = ConsolePadArt.row(ConsolePadArt.WII_SIDEWAYS)["anchors"]
	var glyphs: Dictionary = ConsolePadArt.row(ConsolePadArt.WII_SIDEWAYS)["glyphs"]
	var missing_anchor: Array = []
	var missing_glyph: Array = []
	for control: String in sideways:
		if not anchors.has(control):
			missing_anchor.append(control)
		if not glyphs.has(control):
			missing_glyph.append(control)
	_eq(missing_anchor, [], "variant/every sideways control has an anchor")
	_eq(missing_glyph, [], "variant/and a glyph")
	_eq(anchors.size(), sideways.size(), "variant/and no anchor is left unlisted")

	# The re-keying, which is the whole reason this variant exists and the one
	# thing no picture can check. Dolphin's descWiimoteSideways puts 1 on B and 2
	# on A, so the anchors for b and a must sit where 1 and 2 are drawn — which
	# is the far end of the shell, past the speaker, not up by the d-pad.
	_ok((anchors["b"] as Vector2).x > 0.6, "variant/b points at the 1 button, away from the d-pad")
	_ok((anchors["a"] as Vector2).x > (anchors["b"] as Vector2).x,
		"variant/a points at the 2 button, further still")
	_ok((anchors["x"] as Vector2).x < 0.4, "variant/x points at the A button, up by the d-pad")

	# A lead crosses another when the anchors' left-to-right order disagrees with
	# the row's. Ties are the trap: two controls at the same x are decided by
	# which is NEARER the row, because the shorter drop slants harder.
	for side: String in ["top", "bottom"]:
		var listed: Array = ConsolePadArt.row(ConsolePadArt.WII_SIDEWAYS)[side]
		var crossings := 0
		for i: int in listed.size():
			for j: int in range(i + 1, listed.size()):
				var a: Vector2 = anchors[listed[i]]
				var b: Vector2 = anchors[listed[j]]
				if a.x > b.x:
					crossings += 1
				elif is_equal_approx(a.x, b.x):
					# Same x: the one closer to this row must come first.
					var a_near: float = a.y if side == "bottom" else -a.y
					var b_near: float = b.y if side == "bottom" else -b.y
					if a_near < b_near:
						crossings += 1
		_eq(crossings, 0, "variant/no leads cross on the %s row" % side)


func _test_wii_pad_art() -> void:
	_ok(ConsolePadArt.has("wii"), "wii/has a pad")
	_ok(ResourceLoader.exists(String(ConsolePadArt.row("wii")["art"])), "wii/the art loads")

	var row := ConsolePadArt.row("wii")
	var controls := ConsolePadArt.controls("wii")

	# Derived from the remote's OWN map rather than typed out again here. That map
	# is what reaches the core, so if someone re-points 1 or 2 there and not here,
	# the page would go on drawing a lead to the cap the core no longer means.
	# "shake" is excluded on purpose: it is a motion gesture with no cap to press,
	# so it has nothing for a lead to point at.
	var want: Array = []
	for retro_name: String in Wiimote.DESKTOP_BUTTON_MAP:
		if String(Wiimote.DESKTOP_BUTTON_MAP[retro_name]) == "shake":
			continue
		want.append(retro_name.trim_prefix("RETRO_JOYPAD_").to_lower())
	for dir in ["up", "down", "left", "right"]:
		want.append(dir)
	want.sort()
	var got := controls.duplicate()
	got.sort()
	_eq(got, want, "wii/carries exactly the controls the remote drives")
	_ok(not controls.has("r2"), "wii/the shake gesture is not drawn")

	# Same structural rule the NES gets: a row entry with no anchor draws a lead
	# to the origin, and an anchor with no row entry silently cannot be bound.
	var anchors: Dictionary = row["anchors"]
	var listed: Array = (row["left"] as Array) + (row["right"] as Array)
	var listed_sorted := listed.duplicate()
	listed_sorted.sort()
	_eq(listed_sorted, want, "wii/every control appears in exactly one column")
	var anchor_keys: Array = anchors.keys()
	anchor_keys.sort()
	_eq(anchor_keys, want, "wii/every anchor is a control")

	var in_range := true
	for key: String in anchors:
		var v: Vector2 = anchors[key]
		if v.x < 0.0 or v.x > 1.0 or v.y < 0.0 or v.y > 1.0:
			in_range = false
	_ok(in_range, "wii/every anchor is inside the picture")

	# Each column ordered by height, which is what keeps the leads from crossing.
	for side in ["left", "right"]:
		var last := -1.0
		var sorted_ok := true
		for key: String in row[side]:
			var y: float = (anchors[key] as Vector2).y
			if y < last:
				sorted_ok = false
			last = y
		_ok(sorted_ok, "wii/the %s column runs down the picture" % side)

	_ok(String(row.get("layout", "rows")) == "columns",
		"wii/portrait art lays its labels in columns")
	# Colour art: tinting it would take the whole white shell to one flat blue.
	_ok(row.get("tint", true) == false, "wii/the colour art is not tinted")
	_ok(String(row.get("note", "")).contains("other"), "wii/carries the other-hand note")

	# The chips. Falling back to the shared RETROPAD map put a PlayStation R3 on
	# Home and a PlayStation Start on plus — names for buttons a Wii Remote does
	# not have. Every control must name a Wii glyph, and every one of those files
	# must actually be there: a missing texture is a blank chip, not an error.
	var glyphs: Dictionary = row.get("glyphs", {})
	var glyph_keys: Array = glyphs.keys()
	glyph_keys.sort()
	_eq(glyph_keys, want, "wii/every control has a glyph of its own")
	var all_wii := true
	var all_present := true
	for key: String in glyphs:
		var g := String(glyphs[key])
		if not g.begins_with("wii_"):
			all_wii = false
		if not ResourceLoader.exists(ConsolePadDiagram.GLYPH_DIR + g
				+ ConsolePadDiagram.GLYPH_EXT):
			all_present = false
			print("[test]        missing glyph: %s" % g)
	_ok(all_wii, "wii/every glyph is a Wii one, not a borrowed RetroPad picture")
	_ok(all_present, "wii/every glyph file is present")
	# The two that were actually wrong on screen.
	_eq(String(glyphs.get("start", "")), "wii_button_plus_outline",
		"wii/plus is a plus, not Start")
	_eq(String(glyphs.get("r3", "")), "wii_button_home_outline",
		"wii/home is a house, not R3")

	# And the external-pad page is replaced rather than drawn: a Wii Remote is
	# pointed and swung, and none of that maps onto a gamepad.
	var gp_note := String(row.get("gamepad_note", ""))
	_ok(not gp_note.is_empty(), "wii/says why there is no gamepad remapping")
	_ok(gp_note.contains("infrared") or gp_note.contains("accelerometer"),
		"wii/the reason names the sensors, not just the shape")
	# Every OTHER console must keep its remapping page.
	_ok(String(ConsolePadArt.row("nes").get("gamepad_note", "")).is_empty(),
		"art/the nes still gets a gamepad page")

	# End to end, through the panel that actually picks the picture. The cases
	# above only prove the row DECLARES Wii glyphs; this proves the diagram reads
	# them, which is the half that was broken — the data was fine and the lookup
	# went to the shared RetroPad map regardless.
	var diagram := ConsolePadDiagram.new()
	add_child(diagram)
	diagram.setup("wii", [], {})
	_eq(_glyph_stem(diagram, "start"),
		"wii_button_plus_outline", "wii/the diagram resolves plus to the Wii glyph")
	_eq(_glyph_stem(diagram, "r3"),
		"wii_button_home_outline", "wii/the diagram resolves home to the Wii glyph")
	_eq(_glyph_stem(diagram, "up"),
		"wii_dpad_up_outline", "wii/the diagram resolves the d-pad to Wii glyphs")
	diagram.queue_free()

	# EVERY glyph any panel can ask for must resolve. These are Kenney vectors now,
	# rasterised at import, and the extension lives in one constant — so a name that
	# has no file is not an error anywhere, it is a silently blank chip. This walks
	# all four maps rather than the handful the Wii happens to use.
	var all_names: Array = []
	for v: String in GamepadDiagram.TARGET_GLYPHS.values():
		all_names.append(v)
	for k: String in GamepadDiagram.INPUTS:
		all_names.append(String((GamepadDiagram.INPUTS[k] as Dictionary).get("glyph", "")))
	for v: String in ControllerDiagram.GLYPHS.values():
		all_names.append(v)
	for v: String in ControllerDiagram.RETROPAD_GLYPHS.values():
		all_names.append(v)
	for sysid: String in ["wii"]:
		for v: String in (ConsolePadArt.row(sysid).get("glyphs", {}) as Dictionary).values():
			all_names.append(v)
	var absent: Array = []
	for name_text: String in all_names:
		if name_text.is_empty():
			continue
		if not ResourceLoader.exists(ConsolePadDiagram.GLYPH_DIR + name_text
				+ ConsolePadDiagram.GLYPH_EXT):
			if not absent.has(name_text):
				absent.append(name_text)
	_ok(absent.is_empty(),
		"art/every glyph every panel names has a file (%d checked)" % all_names.size(), "missing: %s" % str(absent))

	# A pad that declares none still gets the shared picture — the fallback is
	# right for a console whose controls really are RetroPad-shaped.
	var nes_diagram := ConsolePadDiagram.new()
	add_child(nes_diagram)
	nes_diagram.setup("nes", [], {})
	_eq(_glyph_stem(nes_diagram, "start"),
		"playstation3_button_start_outline", "art/a pad with no glyphs of its own falls back to the shared map")
	nes_diagram.queue_free()


# ---------------------------------------------------------------------------
# The wiimote and nunchuk layers are stored beside buttons/sticks/lightgun and
# resolved by the same merge, but they are written by a DIFFERENT page. That
# makes them the one thing a save can silently take with it.
# ---------------------------------------------------------------------------

func _test_wii_layers_survive_a_save() -> void:
	_clear()

	# A per-platform Nunchuk map, written whole the way an override is.
	var nunchuk := {"c": "grip", "z": "by_button"}
	var wiimote := {"shake": "grip"}
	var sideways := {"right_trigger": "one"}
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2], wiimote, nunchuk,
		sideways)

	_eq(str((ControllerBindings.get_for_system(SYS_A)["nunchuk"] as Dictionary).get("c")),
		"grip",
		"wii/the nunchuk layer round-trips")
	_eq(str((ControllerBindings.get_for_system(SYS_A)["wiimote"] as Dictionary).get("shake")),
		"grip",
		"wii/and the wiimote layer with it")
	_eq(str((ControllerBindings.get_for_system(SYS_A)["wiimote_sideways"] as Dictionary)
			.get("right_trigger")),
		"one", "wii/and the sideways layer with it")

	# THE GUARD. Saving any OTHER binding for the same platform used to replace
	# the whole per-system entry with buttons/sticks/lightgun, taking these two
	# layers with it — so binding one thing silently reset another page. A caller
	# that has no Nunchuk map to offer must leave the stored one alone.
	var b := _xr_profile("left_grip", ControllerBindings.JOYPAD_L2)
	ControllerBindings.save_for_system(SYS_A, b[0], b[1], b[2])

	_eq(str((ControllerBindings.get_for_system(SYS_A)["nunchuk"] as Dictionary).get("c")),
		"grip",
		"wii/an unrelated save leaves the nunchuk layer standing")
	_eq(str((ControllerBindings.get_for_system(SYS_A)["wiimote"] as Dictionary).get("shake")),
		"grip",
		"wii/and the wiimote layer standing")
	_eq(str((ControllerBindings.get_for_system(SYS_A)["wiimote_sideways"] as Dictionary)
			.get("right_trigger")),
		"one", "wii/and the sideways layer standing")
	_eq(int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("left_grip")),
		ControllerBindings.JOYPAD_L2,
		"wii/while the new binding did take")

	# The global layer has the same shape and the same hazard.
	ControllerBindings.save_global(a[0], a[1], a[2], wiimote, nunchuk, sideways)
	var g := _xr_profile("right_trigger", ControllerBindings.JOYPAD_A)
	ControllerBindings.save_global(g[0], g[1], g[2])
	_eq(str((ControllerBindings.get_global()["nunchuk"] as Dictionary).get("z")),
		"by_button",
		"wii/a global save leaves the global nunchuk layer standing")
	_eq(str((ControllerBindings.get_global()["wiimote_sideways"] as Dictionary)
			.get("right_trigger")),
		"one", "wii/and leaves the global sideways layer standing")

	# And a platform with no Nunchuk map of its own still reads the global one,
	# which is what makes the layer worth storing per platform at all.
	_eq(str((ControllerBindings.get_for_system(SYS_B)["nunchuk"] as Dictionary).get("c")),
		"grip",
		"wii/another platform falls back to the global nunchuk map")


func _test_console_pad_art() -> void:
	_ok(ConsolePadArt.has("nes"), "art/nes has a pad")
	_ok(not ConsolePadArt.has("super_nes"), "art/a platform without one says so")
	# The global page passes "" as its systemid, and it must never draw a console.
	_ok(not ConsolePadArt.has(""), "art/the global scope has no pad")

	var controls := ConsolePadArt.controls("nes")
	var want := ["up", "down", "left", "right", "select", "start", "b", "a"]
	var got := controls.duplicate()
	got.sort()
	want.sort()
	_eq(got, want, "art/nes carries exactly its eight controls")

	# The whole two-sections-one-table trick rests on this: a control key is a
	# GamepadBindings target, and that array's index IS the RetroPad bit. If the
	# two ever disagree, the XR half silently binds the wrong button.
	_eq(ConsolePadArt.bit_of("a"), ControllerBindings.JOYPAD_A, "art/a maps to JOYPAD_A")
	_eq(ConsolePadArt.bit_of("b"), ControllerBindings.JOYPAD_B, "art/b maps to JOYPAD_B")
	_eq(ConsolePadArt.bit_of("select"),
		ControllerBindings.JOYPAD_SELECT, "art/select maps to JOYPAD_SELECT")
	_eq(ConsolePadArt.bit_of("start"),
		ControllerBindings.JOYPAD_START, "art/start maps to JOYPAD_START")
	_eq(ConsolePadArt.bit_of("up"), ControllerBindings.JOYPAD_UP, "art/up maps to JOYPAD_UP")
	_eq(ConsolePadArt.bit_of("down"),
		ControllerBindings.JOYPAD_DOWN, "art/down maps to JOYPAD_DOWN")
	_eq(ConsolePadArt.bit_of("left"),
		ControllerBindings.JOYPAD_LEFT, "art/left maps to JOYPAD_LEFT")
	_eq(ConsolePadArt.bit_of("right"),
		ControllerBindings.JOYPAD_RIGHT, "art/right maps to JOYPAD_RIGHT")

	# Structural check for whoever adds the next console: every control needs an
	# anchor and a row, and every anchor needs to be a control. A row entry with
	# no anchor draws a lead to the origin; an anchor with no row draws nothing
	# and its control silently cannot be bound.
	var row := ConsolePadArt.row("nes")
	var anchors: Dictionary = row["anchors"]
	var listed: Array = (row["top"] as Array) + (row["bottom"] as Array)
	var listed_sorted := listed.duplicate()
	listed_sorted.sort()
	_eq(listed_sorted, want, "art/every control appears in exactly one row")
	var anchor_keys: Array = anchors.keys()
	anchor_keys.sort()
	_eq(anchor_keys, want, "art/anchors and controls are the same set")

	var in_range := true
	for control: String in anchors:
		var uv: Vector2 = anchors[control]
		if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
			in_range = false
	_ok(in_range, "art/anchors are normalized to the art")

	_ok(ConsolePadArt.texture("nes") != null, "art/the texture loads")
	_ok(ConsolePadArt.texture("super_nes") == null, "art/an uncovered platform has no texture")


# ---------------------------------------------------------------------------
# DesktopBindings — the third store, and the odd one out: it cannot be READ per
# system, because every consumer goes through the process-global InputMap. A
# scope is APPLIED instead, so these cases assert on the InputMap.
# ---------------------------------------------------------------------------

const _DESK_ACTION := "RETRO_JOYPAD_A"


## The physical key currently bound to an action, as a keycode, or 0 for none.
func _bound_key(action: String) -> int:
	if not InputMap.has_action(action):
		return 0
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return 0
	var k := events[0] as InputEventKey
	return int(k.physical_keycode) if k != null else 0


func _bind_key(action: String, code: Key) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = code
	ev.keycode = code
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, ev)


func _test_desktop_layers() -> void:
	_clear()
	InputMap.load_from_project_settings()
	var shipped := _bound_key(_DESK_ACTION)
	_ok(shipped != 0, "desktop/the action has a project default")

	# Global layer.
	_bind_key(_DESK_ACTION, KEY_J)
	DesktopBindings.save()
	_ok(not DesktopBindings.has_system_override(SYS_A),
		"desktop/no override before a platform is written")

	# A platform profile on top.
	_bind_key(_DESK_ACTION, KEY_K)
	DesktopBindings.save_for_system(SYS_A)
	_ok(DesktopBindings.has_system_override(SYS_A),
		"desktop/writing a platform profile turns its override on")

	DesktopBindings.apply_for_system(SYS_A)
	_eq(_bound_key(_DESK_ACTION), KEY_K, "desktop/the platform's key applies")
	DesktopBindings.apply_for_system(SYS_B)
	_eq(_bound_key(_DESK_ACTION), KEY_J, "desktop/another platform gets the global key")
	DesktopBindings.apply_for_system("")
	_eq(_bound_key(_DESK_ACTION), KEY_J, "desktop/the global scope is untouched")

	# A later global edit must not reach the overridden platform — the same rule
	# the other two stores keep, and the reason a whole layer is written.
	_bind_key(_DESK_ACTION, KEY_L)
	DesktopBindings.save()
	DesktopBindings.apply_for_system(SYS_A)
	_eq(_bound_key(_DESK_ACTION),
		KEY_K, "desktop/a later global edit does not reach an overridden platform")
	DesktopBindings.apply_for_system(SYS_B)
	_eq(_bound_key(_DESK_ACTION), KEY_L, "desktop/but it does reach an un-overridden one")

	# Clearing puts the platform back on global.
	DesktopBindings.clear_system_override(SYS_A)
	_ok(not DesktopBindings.has_system_override(SYS_A), "desktop/clear drops the override")
	DesktopBindings.apply_for_system(SYS_A)
	_eq(_bound_key(_DESK_ACTION), KEY_L, "desktop/cleared platform is back on global")

	_eq(DesktopBindings.overridden_systems(),
		[], "desktop/overridden_systems lists nothing now")

	# save_for_system("") is save(), the fall-through the shared editor needs.
	_bind_key(_DESK_ACTION, KEY_M)
	DesktopBindings.save_for_system("")
	DesktopBindings.apply_for_system("")
	_eq(_bound_key(_DESK_ACTION), KEY_M, "desktop/save_for_system(\"\") writes global")
	_ok(DesktopBindings.overridden_systems().is_empty(), "desktop/and creates no per-system entry")

	# An action NOT named by any layer must come back as its project default
	# rather than keeping the previous scope's key — that is what makes
	# apply_for_system a scope SWITCH and not a merge.
	_clear()
	InputMap.load_from_project_settings()
	var start_default := _bound_key("RETRO_JOYPAD_START")
	_bind_key("RETRO_JOYPAD_START", KEY_F13)
	DesktopBindings.save_for_system(SYS_A)
	DesktopBindings.clear_system_override(SYS_A)
	DesktopBindings.apply_for_system(SYS_A)
	_eq(_bound_key("RETRO_JOYPAD_START"),
		start_default, "desktop/an unnamed action returns to its project default")

	InputMap.load_from_project_settings()


## The file shipped before there were layers is a flat action -> event dict.
## Reading it as anything other than the global layer loses every desktop
## player's key map on first launch of this build.
func _test_desktop_legacy_file() -> void:
	_clear()
	InputMap.load_from_project_settings()
	var f := FileAccess.open(DesktopBindings.SAVE_PATH, FileAccess.WRITE)
	f.store_string(JSON.stringify({
		_DESK_ACTION: {"type": "key", "physical_keycode": KEY_N, "keycode": KEY_N},
	}))
	f.close()

	DesktopBindings.apply_for_system("")
	_eq(_bound_key(_DESK_ACTION), KEY_N, "desktop/a legacy flat file still applies")
	_ok(DesktopBindings.overridden_systems().is_empty(),
		"desktop/and reads as global, not as a platform")

	# And once it is re-saved it comes back in the layered shape.
	DesktopBindings.save()
	var text := FileAccess.get_file_as_string(DesktopBindings.SAVE_PATH)
	var parsed: Variant = JSON.parse_string(text)
	_ok(parsed is Dictionary and (parsed as Dictionary).has("global"),
		"desktop/a re-save migrates it to layers")

	InputMap.load_from_project_settings()


## Which joypads count as gamepads, tested through the identity rather than the
## device so it runs with no hardware. The Quest is the case that matters: Godot
## on Android passes only InputDevice.getName(), and the Touch controllers have
## no driver name.
func _test_xr_identity() -> void:
	_ok(GamepadBindings.is_xr_identity("Device 0x9873603F55A1038", "", {}),
		"pads/an Android Quest controller is not a gamepad")
	_ok(GamepadBindings.is_xr_identity("Device 0x5DC1A0F42B77021", "", {}),
		"pads/nor its other hand")
	_ok(not GamepadBindings.is_xr_identity("Xbox Wireless Controller", "", {}),
		"pads/a named pad on the same headset still is one")
	_ok(not GamepadBindings.is_xr_identity("8BitDo SN30 Pro", "", {}), "pads/8BitDo too")
	_ok(GamepadBindings.is_xr_identity("Wireless Controller", "", {"vendor_id": 0x2833}),
		"pads/a Meta vendor id is enough on its own")
	_ok(GamepadBindings.is_xr_identity("Wireless Controller", "0300000033280000502400000100000000", {}),
		"pads/and so is the vendor an SDL GUID carries")
	_eq(GamepadBindings.vendor_from_guid("0300000033280000502400000100000000"),
		0x2833, "pads/the GUID vendor field is read low byte first")


# ── JsonStore ─────────────────────────────────────────────────────────────────
#
# The store all three binding files now read and write through. The round-trip
# cases above already prove it loads and saves; these cover the property it was
# extracted to add, which none of them can see: a write either lands whole or
# leaves what was there alone.

const JS_DIR := "user://__jsonstore_selftest"


func _test_json_store() -> void:
	DirAccess.make_dir_recursive_absolute(JS_DIR)
	var path := JS_DIR.path_join("store.json")

	_ok(JsonStore.read_dict(path).is_empty(), "json/a missing file reads as empty")

	_ok(JsonStore.write_dict(path, {"a": 1}), "json/a write reports success")
	_eq(int(JsonStore.read_dict(path).get("a", 0)), 1, "json/and round-trips")
	# The staging file is an implementation detail the caller must never find.
	_ok(not FileAccess.file_exists(path + ".part"), "json/no staging file is left behind")

	# The whole point of staging: a half-written store must not replace a good
	# one. Simulated by leaving a stale .part in the way, which is what a process
	# killed mid-write leaves behind.
	var stale := FileAccess.open(path + ".part", FileAccess.WRITE)
	stale.store_string("{ truncated")
	stale.close()
	_ok(int(JsonStore.read_dict(path).get("a", 0)) == 1,
		"json/a stale staging file does not become the store")
	_ok(JsonStore.write_dict(path, {"a": 2}), "json/and the next write clears it")
	_ok(not FileAccess.file_exists(path + ".part"), "json/leaving none behind")
	_eq(int(JsonStore.read_dict(path).get("a", 0)), 2, "json/with the new value")

	# A corrupt store reads as empty rather than throwing, because every caller
	# treats {} as "nothing saved yet" and would otherwise take the parse error
	# on a code path that has no way to report it.
	var bad := FileAccess.open(path, FileAccess.WRITE)
	bad.store_string("{ this is not json")
	bad.close()
	_ok(JsonStore.read_dict(path).is_empty(), "json/a corrupt store reads as empty")

	# A JSON array is valid JSON and not a store.
	var arr := FileAccess.open(path, FileAccess.WRITE)
	arr.store_string("[1, 2, 3]")
	arr.close()
	_ok(JsonStore.read_dict(path).is_empty(), "json/so does a file holding the wrong shape")

	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path + ".part")
	DirAccess.remove_absolute(JS_DIR)


## The analog latch behind every VR game button. A grip is an axis, not a switch:
## one squeeze crosses its threshold, dips back under it as the hand settles, and
## climbs again, which without hysteresis reaches the core as two presses. These
## cases are the sequences that used to double.
func _test_input_latch() -> void:
	var l := InputLatch.new()

	_ok(not l.pressed("g", 0.20, 0.3), "latch/below the threshold is not pressed")
	_ok(l.pressed("g", 0.35, 0.3), "latch/above it is")

	# The defect, in one line. A settle dip that clears the press threshold but
	# not the release threshold must not read as a release. Set RELEASE_MARGIN to
	# 0 and this is the case that goes red.
	_ok(l.pressed("g", 0.24, 0.3), "latch/a settle dip under the threshold stays pressed")
	_ok(l.pressed("g", 0.40, 0.3), "latch/and the squeeze that follows is still one press")

	# It must still let go, or a latched button is worse than a doubled one.
	_ok(not l.pressed("g", 0.05, 0.3), "latch/a real release clears it")
	_ok(not l.pressed("g", 0.24, 0.3), "latch/and stays clear at the old dip level")

	# An axis resting at a small non-zero value must not stay latched for ever,
	# which is what MIN_RELEASE is for: a 0.10 threshold cannot release at -0.02.
	_ok(l.pressed("g", 0.30, 0.10) and not l.pressed("g", 0.01, 0.10),
		"latch/a low threshold still releases")

	# Two hands hold their own state — the key carries the controller, so the
	# left hand's squeeze can never latch the right hand's button.
	_ok(l.pressed("left:grip", 0.9, 0.3), "latch/one key does not press another")
	_ok(not l.pressed("right:grip", 0.24, 0.3), "latch/the other key is independent")

	l.clear()
	_ok(not l.pressed("left:grip", 0.24, 0.3), "latch/clear releases everything")
