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
## and it lives in Tools/binding_live_probe.tscn.
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
	_test_wii_target_table_matches_the_remote()
	_test_pad_art_variants()
	_test_wii_pad_art()
	_test_desktop_layers()
	_test_desktop_legacy_file()
	_test_xr_identity()
	_test_json_store()

	_restore()
	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


## The filename a diagram actually resolves for a control, or "" for none.
func _glyph_stem(diagram: ConsolePadDiagram, control: String) -> String:
	var tex: Texture2D = diagram._control_glyph(control)
	if tex == null:
		return ""
	return tex.resource_path.get_file().get_basename()


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s" % name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


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

	_eq("xr/no profile resolves to global",
		ControllerBindings.get_for_system(SYS_A)["buttons"],
		ControllerBindings.get_global()["buttons"])
	_eq("pad/no profile resolves to global",
		GamepadBindings.get_for_system(SYS_A)["buttons"],
		GamepadBindings.get_global()["buttons"])
	# And the global edit itself took, rather than both sides agreeing on stale
	# defaults — a comparison of two identical wrong answers proves nothing.
	_eq("xr/global edit took",
		int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L)
	_eq("pad/global edit took",
		str((GamepadBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("a")),
		"btn:5")


# ---------------------------------------------------------------------------
# A profile shadows global for its own platform and nobody else's.
# ---------------------------------------------------------------------------

func _test_profile_shadows_global() -> void:
	_clear()
	var g := _xr_profile("right_grip", ControllerBindings.JOYPAD_L)
	ControllerBindings.save_global(g[0], g[1], g[2])
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])

	_eq("xr/profile wins for its own platform",
		int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_R2)
	_eq("xr/another platform still reads global",
		int((ControllerBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L)
	_eq("xr/the global map itself is untouched",
		int((ControllerBindings.get_global()["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L)

	var pg := _pad_profile("a", "btn:5")
	GamepadBindings.save_global(pg[0], pg[1])
	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])

	_eq("pad/profile wins for its own platform",
		str((GamepadBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("a")), "btn:9")
	_eq("pad/another platform still reads global",
		str((GamepadBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("a")), "btn:5")
	_eq("pad/the global map itself is untouched",
		str((GamepadBindings.get_global()["buttons"] as Dictionary).get("a")), "btn:5")


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

	_eq("xr/a later global edit does not reach an overridden platform",
		int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("left_grip")),
		ControllerBindings.DEFAULT_BUTTON_MAP["left_grip"])
	_eq("xr/but it does reach an un-overridden one",
		int((ControllerBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("left_grip")),
		ControllerBindings.JOYPAD_R3)


# ---------------------------------------------------------------------------
# The switch's own state: the profile IS the flag.
# ---------------------------------------------------------------------------

func _test_has_override() -> void:
	_clear()
	_ok("xr/no override before a write", not ControllerBindings.has_system_override(SYS_A))
	_ok("pad/no override before a write", not GamepadBindings.has_system_override(SYS_A))

	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])
	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])

	_ok("xr/override after a write", ControllerBindings.has_system_override(SYS_A))
	_ok("pad/override after a write", GamepadBindings.has_system_override(SYS_A))
	_ok("xr/a sibling platform is unaffected", not ControllerBindings.has_system_override(SYS_B))
	_ok("pad/a sibling platform is unaffected", not GamepadBindings.has_system_override(SYS_B))
	# The global map must never report as an override, or the switch would come
	# up ON for every platform the moment the player edits the global page.
	_ok("xr/the global scope is not an override", not ControllerBindings.has_system_override(""))
	_ok("pad/the global scope is not an override", not GamepadBindings.has_system_override(""))


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

	_ok("xr/clear drops the override", not ControllerBindings.has_system_override(SYS_A))
	_eq("xr/cleared platform is back on global",
		int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L)
	_ok("xr/the other platform's profile stands",
		ControllerBindings.has_system_override(SYS_B))
	_eq("xr/and still resolves to its own value",
		int((ControllerBindings.get_for_system(SYS_B)["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L2)
	_eq("xr/global survives the clear",
		int((ControllerBindings.get_global()["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_L)

	var pg := _pad_profile("a", "btn:5")
	GamepadBindings.save_global(pg[0], pg[1])
	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])
	GamepadBindings.clear_system_override(SYS_A)
	_ok("pad/clear drops the override", not GamepadBindings.has_system_override(SYS_A))
	_eq("pad/cleared platform is back on global",
		str((GamepadBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("a")), "btn:5")

	# Clearing a platform that never had one is a no-op, not a crash — the switch
	# can be flicked off on a page that was never overridden.
	ControllerBindings.clear_system_override("__never_written")
	GamepadBindings.clear_system_override("__never_written")
	_ok("clearing an absent profile is harmless", true)


# ---------------------------------------------------------------------------
# The fall-through the shared binding editor is built on: one editor class
# serves both pages because an empty systemid means "global".
# ---------------------------------------------------------------------------

func _test_empty_systemid_is_global() -> void:
	_clear()
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system("", a[0], a[1], a[2])
	_eq("xr/save_for_system(\"\") writes global",
		int((ControllerBindings.get_global()["buttons"] as Dictionary).get("right_grip")),
		ControllerBindings.JOYPAD_R2)

	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system("", pa[0], pa[1])
	_eq("pad/save_for_system(\"\") writes global",
		str((GamepadBindings.get_global()["buttons"] as Dictionary).get("a")), "btn:9")

	_eq("xr/get_for_system(\"\") is get_global",
		ControllerBindings.get_for_system("")["buttons"],
		ControllerBindings.get_global()["buttons"])
	_eq("pad/get_for_system(\"\") is get_global",
		GamepadBindings.get_for_system("")["buttons"],
		GamepadBindings.get_global()["buttons"])

	# A global write must not invent a per_system entry, or every platform tile
	# would come up badged the first time the global page is touched.
	_ok("xr/a global write creates no per-system entry",
		ControllerBindings.overridden_systems().is_empty())
	_ok("pad/a global write creates no per-system entry",
		GamepadBindings.overridden_systems().is_empty())


# ---------------------------------------------------------------------------
# What the tile badges are painted from.
# ---------------------------------------------------------------------------

func _test_overridden_systems() -> void:
	_clear()
	_ok("xr/nothing overridden on a fresh store",
		ControllerBindings.overridden_systems().is_empty())

	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2])
	var b := _xr_profile("right_grip", ControllerBindings.JOYPAD_L2)
	ControllerBindings.save_for_system(SYS_B, b[0], b[1], b[2])

	var listed := ControllerBindings.overridden_systems()
	listed.sort()
	_eq("xr/lists exactly the overridden platforms", listed, [SYS_A, SYS_B])

	ControllerBindings.clear_system_override(SYS_A)
	_eq("xr/a cleared platform leaves the list",
		ControllerBindings.overridden_systems(), [SYS_B])

	var pa := _pad_profile("a", "btn:9")
	GamepadBindings.save_for_system(SYS_A, pa[0], pa[1])
	_eq("pad/lists its own overridden platforms",
		GamepadBindings.overridden_systems(), [SYS_A])
	# The two stores are independent: a pad override alone must still badge the
	# tile, which is why the view asks both.
	_ok("the two stores disagree independently",
		GamepadBindings.has_system_override(SYS_A)
			and not ControllerBindings.has_system_override(SYS_A))


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

	_eq("editor/starts from the stored map",
		str(ed._edit_nunchuk_map.get("c")), "ax_button")

	ed._edit_nunchuk_map["c"] = "grip"
	ed._apply_xr_bindings()
	_eq("editor/a change to C reaches the store",
		str((ControllerBindings.get_for_system("wii")["nunchuk"] as Dictionary).get("c")),
		"grip")
	# And did not take the other key with it.
	_eq("editor/while Z keeps its default",
		str((ControllerBindings.get_for_system("wii")["nunchuk"] as Dictionary).get("z")),
		"trigger")

	# The rows exist and are the two that can be bound. The stick is not among
	# them on purpose — it is whichever hand is holding the Nunchuk.
	_ok("editor/there is a row for C", ed._controls_opts.has("nc:c"))
	_ok("editor/and one for Z", ed._controls_opts.has("nc:z"))
	_ok("editor/and none for the stick", not ed._controls_opts.has("nc:stick"))

	# A Wii Remote has a D-pad and no analog stick, and the two joypad stick rows
	# are not merely meaningless on that page — the remote reads its own layer and
	# never the joypad stick map, so they were live-looking controls that did
	# nothing at all.
	_ok("editor/the wii page offers no left stick row",
		not ed._controls_opts.has("stick:stick_left"))
	_ok("editor/nor a right stick row",
		not ed._controls_opts.has("stick:stick_right"))
	ed.queue_free()

	# A platform whose pad really has sticks still gets them, so the case above is
	# a gate rather than a deletion.
	var other := ControlsBindingEditor.new()
	add_child(other)
	other._systemid = SYS_A
	other._build_xr_controls(other)
	_ok("editor/a platform with sticks still gets its rows",
		other._controls_opts.has("stick:stick_left")
			and other._controls_opts.has("stick:stick_right"))
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
	_eq("wii-xr/the picture reads the remote's own map",
		ed._wiimote_source_for("x"), "grip")
	_eq("wii-xr/and B is the trigger", ed._wiimote_source_for("b"), "trigger")

	# Moving a control takes the source off whatever it was on, and lands in the
	# layer the remote reads.
	ed._on_console_xr_changed("x", "by_button")
	var stored: Dictionary = ControllerBindings.get_for_system("wii")["wiimote"]
	_eq("wii-xr/a change lands in the wiimote layer", str(stored.get("by_button")), "one")
	_eq("wii-xr/and the source it displaced is freed", str(stored.get("grip")), "none")
	_eq("wii-xr/the picture agrees afterwards", ed._wiimote_source_for("x"), "by_button")

	# It must NOT have gone into the joypad map, which is the map that was being
	# written before and the one the remote never reads.
	var joypad: Dictionary = ControllerBindings.get_for_system("wii")["buttons"]
	_eq("wii-xr/and not into the joypad map",
		int(joypad.get("right_grip", -99)),
		int((ControllerBindings.DEFAULT_BUTTON_MAP as Dictionary).get("right_grip", -99)))

	# Every control the picture draws can be bound, including the cross. The page
	# has always said the D-pad is bindable; for this remote it was not.
	var unbindable: Array = []
	for control: String in ConsolePadArt.controls("wii"):
		if String(ControllerBindings.WIIMOTE_CONTROL_OF_TARGET.get(control, "")).is_empty():
			unbindable.append(control)
	_eq("wii-xr/every drawn control maps to a remote control", unbindable, [])
	ed.queue_free()


## The crossing table and the remote's own desktop map must agree, since they are
## two statements of the same fact in files that cannot import each other.
func _test_wii_target_table_matches_the_remote() -> void:
	for retro_name: String in Wiimote.DESKTOP_BUTTON_MAP:
		var target := retro_name.trim_prefix("RETRO_JOYPAD_").to_lower()
		_eq("wii-xr/%s agrees with DESKTOP_BUTTON_MAP" % target,
			str(ControllerBindings.WIIMOTE_CONTROL_OF_TARGET.get(target, "")),
			str(Wiimote.DESKTOP_BUTTON_MAP[retro_name]))


func _test_pad_art_variants() -> void:
	_ok("variant/sideways is not a platform",
		not ConsolePadArt.has(ConsolePadArt.WII_SIDEWAYS))
	_ok("variant/nor is the generic pad", not ConsolePadArt.has(ConsolePadArt.RETROPAD))
	_ok("variant/but it has a row", not ConsolePadArt.row(ConsolePadArt.WII_SIDEWAYS).is_empty())
	_ok("variant/and its art loads",
		ResourceLoader.exists(String(ConsolePadArt.row(ConsolePadArt.WII_SIDEWAYS)["art"])))

	# The Wii draws two pictures; everyone else draws one; the global page draws
	# none. Order matters — the upright remote is the one a player meets first.
	_eq("variant/the wii lists both ways it is held",
		ConsolePadArt.variants_for("wii"), ["wii", ConsolePadArt.WII_SIDEWAYS])
	_eq("variant/a one-way console lists just itself",
		ConsolePadArt.variants_for("nes"), ["nes"])
	_eq("variant/the global scope lists none", ConsolePadArt.variants_for(""), [])

	# Same bits, different names. Sideways is a picture and a set of labels, not a
	# second binding map, so it must carry exactly the controls the upright remote
	# does — a variant that dropped one would leave that button unbindable on a
	# page the player might be looking at.
	var upright := ConsolePadArt.controls("wii").duplicate()
	var sideways := ConsolePadArt.controls(ConsolePadArt.WII_SIDEWAYS).duplicate()
	upright.sort()
	sideways.sort()
	_eq("variant/sideways carries the same controls as upright", sideways, upright)

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
	_eq("variant/every sideways control has an anchor", missing_anchor, [])
	_eq("variant/and a glyph", missing_glyph, [])
	_eq("variant/and no anchor is left unlisted", anchors.size(), sideways.size())

	# The re-keying, which is the whole reason this variant exists and the one
	# thing no picture can check. Dolphin's descWiimoteSideways puts 1 on B and 2
	# on A, so the anchors for b and a must sit where 1 and 2 are drawn — which
	# is the far end of the shell, past the speaker, not up by the d-pad.
	_ok("variant/b points at the 1 button, away from the d-pad",
		(anchors["b"] as Vector2).x > 0.6)
	_ok("variant/a points at the 2 button, further still",
		(anchors["a"] as Vector2).x > (anchors["b"] as Vector2).x)
	_ok("variant/x points at the A button, up by the d-pad",
		(anchors["x"] as Vector2).x < 0.4)

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
		_eq("variant/no leads cross on the %s row" % side, crossings, 0)


func _test_wii_pad_art() -> void:
	_ok("wii/has a pad", ConsolePadArt.has("wii"))
	_ok("wii/the art loads",
		ResourceLoader.exists(String(ConsolePadArt.row("wii")["art"])))

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
	_eq("wii/carries exactly the controls the remote drives", got, want)
	_ok("wii/the shake gesture is not drawn", not controls.has("r2"))

	# Same structural rule the NES gets: a row entry with no anchor draws a lead
	# to the origin, and an anchor with no row entry silently cannot be bound.
	var anchors: Dictionary = row["anchors"]
	var listed: Array = (row["left"] as Array) + (row["right"] as Array)
	var listed_sorted := listed.duplicate()
	listed_sorted.sort()
	_eq("wii/every control appears in exactly one column", listed_sorted, want)
	var anchor_keys: Array = anchors.keys()
	anchor_keys.sort()
	_eq("wii/every anchor is a control", anchor_keys, want)

	var in_range := true
	for key: String in anchors:
		var v: Vector2 = anchors[key]
		if v.x < 0.0 or v.x > 1.0 or v.y < 0.0 or v.y > 1.0:
			in_range = false
	_ok("wii/every anchor is inside the picture", in_range)

	# Each column ordered by height, which is what keeps the leads from crossing.
	for side in ["left", "right"]:
		var last := -1.0
		var sorted_ok := true
		for key: String in row[side]:
			var y: float = (anchors[key] as Vector2).y
			if y < last:
				sorted_ok = false
			last = y
		_ok("wii/the %s column runs down the picture" % side, sorted_ok)

	_ok("wii/portrait art lays its labels in columns",
		String(row.get("layout", "rows")) == "columns")
	# Colour art: tinting it would take the whole white shell to one flat blue.
	_ok("wii/the colour art is not tinted", row.get("tint", true) == false)
	_ok("wii/carries the other-hand note",
		String(row.get("note", "")).contains("other"))

	# The chips. Falling back to the shared RETROPAD map put a PlayStation R3 on
	# Home and a PlayStation Start on plus — names for buttons a Wii Remote does
	# not have. Every control must name a Wii glyph, and every one of those files
	# must actually be there: a missing texture is a blank chip, not an error.
	var glyphs: Dictionary = row.get("glyphs", {})
	var glyph_keys: Array = glyphs.keys()
	glyph_keys.sort()
	_eq("wii/every control has a glyph of its own", glyph_keys, want)
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
	_ok("wii/every glyph is a Wii one, not a borrowed RetroPad picture", all_wii)
	_ok("wii/every glyph file is present", all_present)
	# The two that were actually wrong on screen.
	_eq("wii/plus is a plus, not Start", String(glyphs.get("start", "")),
		"wii_button_plus_outline")
	_eq("wii/home is a house, not R3", String(glyphs.get("r3", "")),
		"wii_button_home_outline")

	# And the external-pad page is replaced rather than drawn: a Wii Remote is
	# pointed and swung, and none of that maps onto a gamepad.
	var gp_note := String(row.get("gamepad_note", ""))
	_ok("wii/says why there is no gamepad remapping", not gp_note.is_empty())
	_ok("wii/the reason names the sensors, not just the shape",
		gp_note.contains("infrared") or gp_note.contains("accelerometer"))
	# Every OTHER console must keep its remapping page.
	_ok("art/the nes still gets a gamepad page",
		String(ConsolePadArt.row("nes").get("gamepad_note", "")).is_empty())

	# End to end, through the panel that actually picks the picture. The cases
	# above only prove the row DECLARES Wii glyphs; this proves the diagram reads
	# them, which is the half that was broken — the data was fine and the lookup
	# went to the shared RetroPad map regardless.
	var diagram := ConsolePadDiagram.new()
	add_child(diagram)
	diagram.setup("wii", [], {})
	_eq("wii/the diagram resolves plus to the Wii glyph",
		_glyph_stem(diagram, "start"), "wii_button_plus_outline")
	_eq("wii/the diagram resolves home to the Wii glyph",
		_glyph_stem(diagram, "r3"), "wii_button_home_outline")
	_eq("wii/the diagram resolves the d-pad to Wii glyphs",
		_glyph_stem(diagram, "up"), "wii_dpad_up_outline")
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
	_ok("art/every glyph every panel names has a file (%d checked)" % all_names.size(),
		absent.is_empty(), "missing: %s" % str(absent))

	# A pad that declares none still gets the shared picture — the fallback is
	# right for a console whose controls really are RetroPad-shaped.
	var nes_diagram := ConsolePadDiagram.new()
	add_child(nes_diagram)
	nes_diagram.setup("nes", [], {})
	_eq("art/a pad with no glyphs of its own falls back to the shared map",
		_glyph_stem(nes_diagram, "start"), "playstation3_button_start_outline")
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
	var a := _xr_profile("right_grip", ControllerBindings.JOYPAD_R2)
	ControllerBindings.save_for_system(SYS_A, a[0], a[1], a[2], wiimote, nunchuk)

	_eq("wii/the nunchuk layer round-trips",
		str((ControllerBindings.get_for_system(SYS_A)["nunchuk"] as Dictionary).get("c")),
		"grip")
	_eq("wii/and the wiimote layer with it",
		str((ControllerBindings.get_for_system(SYS_A)["wiimote"] as Dictionary).get("shake")),
		"grip")

	# THE GUARD. Saving any OTHER binding for the same platform used to replace
	# the whole per-system entry with buttons/sticks/lightgun, taking these two
	# layers with it — so binding one thing silently reset another page. A caller
	# that has no Nunchuk map to offer must leave the stored one alone.
	var b := _xr_profile("left_grip", ControllerBindings.JOYPAD_L2)
	ControllerBindings.save_for_system(SYS_A, b[0], b[1], b[2])

	_eq("wii/an unrelated save leaves the nunchuk layer standing",
		str((ControllerBindings.get_for_system(SYS_A)["nunchuk"] as Dictionary).get("c")),
		"grip")
	_eq("wii/and the wiimote layer standing",
		str((ControllerBindings.get_for_system(SYS_A)["wiimote"] as Dictionary).get("shake")),
		"grip")
	_eq("wii/while the new binding did take",
		int((ControllerBindings.get_for_system(SYS_A)["buttons"] as Dictionary).get("left_grip")),
		ControllerBindings.JOYPAD_L2)

	# The global layer has the same shape and the same hazard.
	ControllerBindings.save_global(a[0], a[1], a[2], wiimote, nunchuk)
	var g := _xr_profile("right_trigger", ControllerBindings.JOYPAD_A)
	ControllerBindings.save_global(g[0], g[1], g[2])
	_eq("wii/a global save leaves the global nunchuk layer standing",
		str((ControllerBindings.get_global()["nunchuk"] as Dictionary).get("z")),
		"by_button")

	# And a platform with no Nunchuk map of its own still reads the global one,
	# which is what makes the layer worth storing per platform at all.
	_eq("wii/another platform falls back to the global nunchuk map",
		str((ControllerBindings.get_for_system(SYS_B)["nunchuk"] as Dictionary).get("c")),
		"grip")


func _test_console_pad_art() -> void:
	_ok("art/nes has a pad", ConsolePadArt.has("nes"))
	_ok("art/a platform without one says so", not ConsolePadArt.has("super_nes"))
	# The global page passes "" as its systemid, and it must never draw a console.
	_ok("art/the global scope has no pad", not ConsolePadArt.has(""))

	var controls := ConsolePadArt.controls("nes")
	var want := ["up", "down", "left", "right", "select", "start", "b", "a"]
	var got := controls.duplicate()
	got.sort()
	want.sort()
	_eq("art/nes carries exactly its eight controls", got, want)

	# The whole two-sections-one-table trick rests on this: a control key is a
	# GamepadBindings target, and that array's index IS the RetroPad bit. If the
	# two ever disagree, the XR half silently binds the wrong button.
	_eq("art/a maps to JOYPAD_A", ConsolePadArt.bit_of("a"), ControllerBindings.JOYPAD_A)
	_eq("art/b maps to JOYPAD_B", ConsolePadArt.bit_of("b"), ControllerBindings.JOYPAD_B)
	_eq("art/select maps to JOYPAD_SELECT",
		ConsolePadArt.bit_of("select"), ControllerBindings.JOYPAD_SELECT)
	_eq("art/start maps to JOYPAD_START",
		ConsolePadArt.bit_of("start"), ControllerBindings.JOYPAD_START)
	_eq("art/up maps to JOYPAD_UP", ConsolePadArt.bit_of("up"), ControllerBindings.JOYPAD_UP)
	_eq("art/down maps to JOYPAD_DOWN",
		ConsolePadArt.bit_of("down"), ControllerBindings.JOYPAD_DOWN)
	_eq("art/left maps to JOYPAD_LEFT",
		ConsolePadArt.bit_of("left"), ControllerBindings.JOYPAD_LEFT)
	_eq("art/right maps to JOYPAD_RIGHT",
		ConsolePadArt.bit_of("right"), ControllerBindings.JOYPAD_RIGHT)

	# Structural check for whoever adds the next console: every control needs an
	# anchor and a row, and every anchor needs to be a control. A row entry with
	# no anchor draws a lead to the origin; an anchor with no row draws nothing
	# and its control silently cannot be bound.
	var row := ConsolePadArt.row("nes")
	var anchors: Dictionary = row["anchors"]
	var listed: Array = (row["top"] as Array) + (row["bottom"] as Array)
	var listed_sorted := listed.duplicate()
	listed_sorted.sort()
	_eq("art/every control appears in exactly one row", listed_sorted, want)
	var anchor_keys: Array = anchors.keys()
	anchor_keys.sort()
	_eq("art/anchors and controls are the same set", anchor_keys, want)

	var in_range := true
	for control: String in anchors:
		var uv: Vector2 = anchors[control]
		if uv.x < 0.0 or uv.x > 1.0 or uv.y < 0.0 or uv.y > 1.0:
			in_range = false
	_ok("art/anchors are normalized to the art", in_range)

	_ok("art/the texture loads", ConsolePadArt.texture("nes") != null)
	_ok("art/an uncovered platform has no texture", ConsolePadArt.texture("super_nes") == null)


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
	_ok("desktop/the action has a project default", shipped != 0)

	# Global layer.
	_bind_key(_DESK_ACTION, KEY_J)
	DesktopBindings.save()
	_ok("desktop/no override before a platform is written",
		not DesktopBindings.has_system_override(SYS_A))

	# A platform profile on top.
	_bind_key(_DESK_ACTION, KEY_K)
	DesktopBindings.save_for_system(SYS_A)
	_ok("desktop/writing a platform profile turns its override on",
		DesktopBindings.has_system_override(SYS_A))

	DesktopBindings.apply_for_system(SYS_A)
	_eq("desktop/the platform's key applies", _bound_key(_DESK_ACTION), KEY_K)
	DesktopBindings.apply_for_system(SYS_B)
	_eq("desktop/another platform gets the global key", _bound_key(_DESK_ACTION), KEY_J)
	DesktopBindings.apply_for_system("")
	_eq("desktop/the global scope is untouched", _bound_key(_DESK_ACTION), KEY_J)

	# A later global edit must not reach the overridden platform — the same rule
	# the other two stores keep, and the reason a whole layer is written.
	_bind_key(_DESK_ACTION, KEY_L)
	DesktopBindings.save()
	DesktopBindings.apply_for_system(SYS_A)
	_eq("desktop/a later global edit does not reach an overridden platform",
		_bound_key(_DESK_ACTION), KEY_K)
	DesktopBindings.apply_for_system(SYS_B)
	_eq("desktop/but it does reach an un-overridden one", _bound_key(_DESK_ACTION), KEY_L)

	# Clearing puts the platform back on global.
	DesktopBindings.clear_system_override(SYS_A)
	_ok("desktop/clear drops the override",
		not DesktopBindings.has_system_override(SYS_A))
	DesktopBindings.apply_for_system(SYS_A)
	_eq("desktop/cleared platform is back on global", _bound_key(_DESK_ACTION), KEY_L)

	_eq("desktop/overridden_systems lists nothing now",
		DesktopBindings.overridden_systems(), [])

	# save_for_system("") is save(), the fall-through the shared editor needs.
	_bind_key(_DESK_ACTION, KEY_M)
	DesktopBindings.save_for_system("")
	DesktopBindings.apply_for_system("")
	_eq("desktop/save_for_system(\"\") writes global", _bound_key(_DESK_ACTION), KEY_M)
	_ok("desktop/and creates no per-system entry",
		DesktopBindings.overridden_systems().is_empty())

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
	_eq("desktop/an unnamed action returns to its project default",
		_bound_key("RETRO_JOYPAD_START"), start_default)

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
	_eq("desktop/a legacy flat file still applies", _bound_key(_DESK_ACTION), KEY_N)
	_ok("desktop/and reads as global, not as a platform",
		DesktopBindings.overridden_systems().is_empty())

	# And once it is re-saved it comes back in the layered shape.
	DesktopBindings.save()
	var text := FileAccess.get_file_as_string(DesktopBindings.SAVE_PATH)
	var parsed: Variant = JSON.parse_string(text)
	_ok("desktop/a re-save migrates it to layers",
		parsed is Dictionary and (parsed as Dictionary).has("global"))

	InputMap.load_from_project_settings()


## Which joypads count as gamepads, tested through the identity rather than the
## device so it runs with no hardware. The Quest is the case that matters: Godot
## on Android passes only InputDevice.getName(), and the Touch controllers have
## no driver name.
func _test_xr_identity() -> void:
	_ok("pads/an Android Quest controller is not a gamepad",
		GamepadBindings.is_xr_identity("Device 0x9873603F55A1038", "", {}))
	_ok("pads/nor its other hand",
		GamepadBindings.is_xr_identity("Device 0x5DC1A0F42B77021", "", {}))
	_ok("pads/a named pad on the same headset still is one",
		not GamepadBindings.is_xr_identity("Xbox Wireless Controller", "", {}))
	_ok("pads/8BitDo too",
		not GamepadBindings.is_xr_identity("8BitDo SN30 Pro", "", {}))
	_ok("pads/a Meta vendor id is enough on its own",
		GamepadBindings.is_xr_identity("Wireless Controller", "", {"vendor_id": 0x2833}))
	_ok("pads/and so is the vendor an SDL GUID carries",
		GamepadBindings.is_xr_identity("Wireless Controller",
			"0300000033280000502400000100000000", {}))
	_eq("pads/the GUID vendor field is read low byte first",
		GamepadBindings.vendor_from_guid("0300000033280000502400000100000000"), 0x2833)


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

	_ok("json/a missing file reads as empty",
		JsonStore.read_dict(path).is_empty())

	_ok("json/a write reports success", JsonStore.write_dict(path, {"a": 1}))
	_eq("json/and round-trips", int(JsonStore.read_dict(path).get("a", 0)), 1)
	# The staging file is an implementation detail the caller must never find.
	_ok("json/no staging file is left behind",
		not FileAccess.file_exists(path + ".part"))

	# The whole point of staging: a half-written store must not replace a good
	# one. Simulated by leaving a stale .part in the way, which is what a process
	# killed mid-write leaves behind.
	var stale := FileAccess.open(path + ".part", FileAccess.WRITE)
	stale.store_string("{ truncated")
	stale.close()
	_ok("json/a stale staging file does not become the store",
		int(JsonStore.read_dict(path).get("a", 0)) == 1)
	_ok("json/and the next write clears it", JsonStore.write_dict(path, {"a": 2}))
	_ok("json/leaving none behind", not FileAccess.file_exists(path + ".part"))
	_eq("json/with the new value", int(JsonStore.read_dict(path).get("a", 0)), 2)

	# A corrupt store reads as empty rather than throwing, because every caller
	# treats {} as "nothing saved yet" and would otherwise take the parse error
	# on a code path that has no way to report it.
	var bad := FileAccess.open(path, FileAccess.WRITE)
	bad.store_string("{ this is not json")
	bad.close()
	_ok("json/a corrupt store reads as empty", JsonStore.read_dict(path).is_empty())

	# A JSON array is valid JSON and not a store.
	var arr := FileAccess.open(path, FileAccess.WRITE)
	arr.store_string("[1, 2, 3]")
	arr.close()
	_ok("json/so does a file holding the wrong shape",
		JsonStore.read_dict(path).is_empty())

	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path + ".part")
	DirAccess.remove_absolute(JS_DIR)
