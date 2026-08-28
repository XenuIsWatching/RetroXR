## binding_live_probe — a rebind in the options panel must reach the core with no
## further action from the player.
##
## Run: godot --headless --path RetroXR res://Tools/input/binding_live_probe.tscn
##
## This exists because it did not. The XR binding editor wrote to a scratch map
## that only reached disk when you pressed "Save as Global" — a button at the very
## bottom of a scrolling panel, below the joypad, analog-stick and lightgun
## sections. Change a dropdown, walk away, and nothing had happened.
##
## Both stores are covered: ControllerBindings (XR thumbsticks and buttons, read
## by a held pad) and GamepadBindings (a physical pad, read by a PadReceiver).
## They are separate files with separate editors, and the GAME CONTROLLER half
## went on skipping the write long after the XR half was fixed.
##
## The per-platform half is covered too: an override written on one platform's
## page must reach a controller plugged into that platform and no other, and
## pulling that controller out must put it back on the global map.
extends Node

const MAIN := preload("res://Scenes/MainScene.tscn")
const PAD := "res://Scenes/Objects/controllers/retro_controller.tscn"
const RX := "res://Scenes/Objects/controllers/pad_receiver.tscn"
const SYSTEM := "res://Scenes/Objects/system.tscn"

var _fail := false
# The player's own bindings, taken away for the run and put back before quitting.
# Taken away because every assertion below starts from a shipped default, and a
# machine that has ever opened the CONTROLS tab has a file that overrides one.
# Put back because this probe writes both stores and ends on a reset, so without
# it a run wipes real settings.
var _saved: Dictionary = {}


func _check(c: bool, m: String) -> void:
	print("[probe] %s: %s" % ["PASS" if c else "FAIL", m])
	if not c:
		_fail = true


func _ready() -> void:
	get_tree().create_timer(200.0).timeout.connect(func() -> void:
		_restore()
		get_tree().quit(1))
	_run.call_deferred()


func _backup() -> void:
	for path: String in [ControllerBindings.SAVE_PATH, GamepadBindings.SAVE_PATH,
			DesktopBindings.SAVE_PATH]:
		if FileAccess.file_exists(path):
			_saved[path] = FileAccess.get_file_as_string(path)
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _restore() -> void:
	for path: String in [ControllerBindings.SAVE_PATH, GamepadBindings.SAVE_PATH,
			DesktopBindings.SAVE_PATH]:
		if _saved.has(path):
			var f := FileAccess.open(path, FileAccess.WRITE)
			if f != null:
				f.store_string(str(_saved[path]))
				f.close()
		else:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _quit(code: int) -> void:
	_restore()
	get_tree().quit(code)


## The physical keycode bound to an action, or 0 for none.
func _first_key(action: String) -> int:
	if not InputMap.has_action(action):
		return 0
	var events := InputMap.action_get_events(action)
	if events.is_empty():
		return 0
	var k := events[0] as InputEventKey
	return int(k.physical_keycode) if k != null else 0


func _stick(store: Dictionary) -> String:
	return str(store.get("stick_left", ""))


func _run() -> void:
	_backup()
	add_child(MAIN.instantiate())
	for i in 30:
		await get_tree().process_frame
	var views: Array[Node] = get_tree().root.find_children(
		"*", "SpawnMenuControlsView", true, false)
	_check(views.size() == 1, "the CONTROLS view exists (found %d)" % views.size())
	if views.is_empty():
		_quit(1)
		return
	var menu: Node = views[0]

	var pad: Node3D = (load(PAD) as PackedScene).instantiate()
	get_tree().current_scene.add_child(pad)
	pad.set("freeze", true)
	var rx: Node3D = (load(RX) as PackedScene).instantiate()
	get_tree().current_scene.add_child(rx)
	rx.set("freeze", true)
	for i in 12:
		await get_tree().process_frame

	# Drive the view's OWN global editor, not a detached one. Its
	# controller_bindings_changed is already relayed to SpawnMenuController,
	# which is what fans reload_bindings() out over the consumer group — a
	# stand-alone editor writes to disk and reaches nobody, so every "applies
	# immediately" case below would fail for a reason the player never sees.
	# Headless reports no OpenXR, so the view built its desktop branch and the
	# XR rows are missing; _build_xr_controls is the same function the headset
	# path runs. The gamepad rows are built unconditionally and are already there.
	var editor: Node = menu.get("_global_editor")
	_check(editor != null, "the view exposes its global editor")
	if editor == null:
		_quit(1)
		return
	editor.call("_build_xr_controls", editor)
	await get_tree().process_frame
	var opts: Dictionary = editor.get("_controls_opts")

	# ── XR: a held pad reads ControllerBindings ───────────────────────────────
	var edit: Dictionary = editor.get("_edit_button_map")
	_check(edit.size() > 0, "the editor loads the current bindings (%d entries)" % edit.size())
	_check(int((pad.get("_button_map") as Dictionary).get("right_ax_button")) == 8,
		"the pad starts on the default: right A -> RetroPad A")

	# Select RetroPad X on the "Right A" row, exactly as a player would, and then
	# do NOTHING else. No save, no confirm.
	var drop: Node = opts.get("btn:right_ax_button")
	_check(drop != null, "the Right A dropdown exists")
	if drop != null:
		drop.emit_signal("item_selected", 9)
		await get_tree().process_frame
		await get_tree().process_frame
	var now: Variant = (pad.get("_button_map") as Dictionary).get("right_ax_button")
	_check(int(now) == 9, "picking X applies immediately, with no Save (got %s)" % str(now))
	_check(int((ControllerBindings.get_global()["buttons"] as Dictionary)
		.get("right_ax_button")) == 9, "and it reached disk")

	# The analog-stick rows are dropdowns on the same panel and were never covered.
	_check(_stick(pad.get("_stick_map")) == "left+dpad",
		"the pad's left stick starts on Left Analog + D-pad")
	var sdrop: Node = opts.get("stick:stick_left")
	_check(sdrop != null, "the XR Left Stick dropdown exists")
	if sdrop != null:
		sdrop.emit_signal("item_selected", "left")
		await get_tree().process_frame
		await get_tree().process_frame
	_check(_stick(pad.get("_stick_map")) == "left",
		"dropping the D-pad off the left stick applies immediately (got %s)"
			% _stick(pad.get("_stick_map")))
	_check(_stick(ControllerBindings.get_global()["sticks"]) == "left",
		"and it reached disk")

	# Reset must be live too — it used to need the same missing button.
	editor.call("_on_controls_reset")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(int((pad.get("_button_map") as Dictionary).get("right_ax_button")) == 8,
		"Reset to Default is live as well")
	_check(_stick(pad.get("_stick_map")) == "left+dpad",
		"and it puts the left stick back")

	# ── GAME CONTROLLER: a PadReceiver reads GamepadBindings ──────────────────
	_check(_stick(rx.get("_pad_stick_map")) == "left+dpad",
		"the receiver's left stick starts on Left Analog + D-pad")
	var pdrop: Node = opts.get("padstick:stick_left")
	_check(pdrop != null, "the pad Left Stick dropdown exists")
	if pdrop != null:
		pdrop.emit_signal("item_selected", "left")
		await get_tree().process_frame
		await get_tree().process_frame
	_check(_stick(rx.get("_pad_stick_map")) == "left",
		"picking Left Analog applies immediately (got %s)" % _stick(rx.get("_pad_stick_map")))
	_check(_stick(GamepadBindings.get_global()["sticks"]) == "left",
		"and it reached disk")

	# The pad half's Reset repainted the UI and wrote nothing at all, so the
	# defaults it showed were a lie until the player also pressed Save.
	editor.call("_on_pad_controls_reset")
	await get_tree().process_frame
	await get_tree().process_frame
	_check(_stick(rx.get("_pad_stick_map")) == "left+dpad",
		"the pad Reset to Default is live (got %s)" % _stick(rx.get("_pad_stick_map")))
	_check(_stick(GamepadBindings.get_global()["sticks"]) == "left+dpad",
		"and it reached disk")

	# ── PER-PLATFORM: an override reaches its own platform and no other ───────
	# A platform page's editor is the same class with a systemid on it, so this
	# drives the identical dropdown and watches where the write lands.
	_check(menu.has_method("refresh_platforms"),
		"the CONTROLS view exposes the per-platform grid")
	_check(not ControllerBindings.has_system_override("nes"),
		"nes has no override before the page is touched")

	# Stand a real NES up and plug the pad into it FIRST, so the edit below has
	# to reach a machine already in the room rather than being read on the way in.
	var nes_sys: Node = (load(SYSTEM) as PackedScene).instantiate()
	nes_sys.set("systemid", "nes")
	get_tree().current_scene.add_child(nes_sys)
	for i in 12:
		await get_tree().process_frame
	pad.call("on_plugged_in", nes_sys, 0)
	await get_tree().process_frame
	_check(int((pad.get("_button_map") as Dictionary).get("right_ax_button"))
		== ControllerBindings.JOYPAD_A,
		"a pad in the nes starts on the global map")

	var nes_editor: Node = ControlsBindingEditor.new()
	nes_editor.set("_systemid", "nes")
	add_child(nes_editor)
	# Relayed the way SpawnMenuControlsView._wire_editor relays a platform page's
	# editor, because the fan-out is the whole point of the case.
	nes_editor.connect("controller_bindings_changed",
		func() -> void: menu.emit_signal("controller_bindings_changed"))
	nes_editor.call("_build_xr_controls", nes_editor)
	await get_tree().process_frame

	# The NES page draws a NES pad, so the row to drive is the console control
	# "a" — not a "btn:<source>" dropdown, which this page does not have.
	var nes_diagram: Node = nes_editor.get("_console_xr_diagram")
	_check(nes_diagram != null, "the NES page built its own controller")
	var ndrop: Node = nes_diagram.call("get_dropdown", "a") if nes_diagram else null
	_check(ndrop != null, "the platform page's A dropdown exists")
	if ndrop != null:
		ndrop.emit_signal("item_selected", "right_trigger")
		await get_tree().process_frame
		await get_tree().process_frame

	_check(ControllerBindings.has_system_override("nes"),
		"editing a platform row is what turns its override on")
	_check(int((ControllerBindings.get_for_system("nes")["buttons"] as Dictionary)
		.get("right_trigger", -1)) == ControllerBindings.JOYPAD_A,
		"the override reached disk for nes")
	_check(int((ControllerBindings.get_global()["buttons"] as Dictionary)
		.get("right_trigger", -1)) != ControllerBindings.JOYPAD_A,
		"and left the global map alone")
	_check(int((ControllerBindings.get_for_system("super_nes")["buttons"] as Dictionary)
		.get("right_trigger", -1)) != ControllerBindings.JOYPAD_A,
		"and left every other platform alone")
	_check(int((pad.get("_button_map") as Dictionary).get("right_trigger", -1))
		== ControllerBindings.JOYPAD_A,
		"the pad already in the nes picks it up with no re-plug (got %s)"
			% str((pad.get("_button_map") as Dictionary).get("right_trigger")))

	# The receiver is plugged into nothing, so the same fan-out must leave it on
	# the global map — an override is not a global edit wearing a systemid.
	_check(_stick(rx.get("_pad_stick_map")) == "left+dpad",
		"a receiver in no console is untouched by a platform override (got %s)"
			% _stick(rx.get("_pad_stick_map")))

	# ── The desktop key map follows whoever holds the keyboard ───────────────
	# This store is the odd one: every consumer reads the process-global
	# InputMap, so a platform's keys are APPLIED rather than looked up, and the
	# Scroll Lock capture is what decides when. Nothing else asserts that hookup.
	InputMap.load_from_project_settings()
	var global_key := _first_key("RETRO_JOYPAD_A")
	_check(global_key != 0, "RETRO_JOYPAD_A has a project default")
	DesktopBindings.save()

	var nes_key := KEY_F14
	var ev := InputEventKey.new()
	ev.physical_keycode = nes_key
	ev.keycode = nes_key
	InputMap.action_erase_events("RETRO_JOYPAD_A")
	InputMap.action_add_event("RETRO_JOYPAD_A", ev)
	DesktopBindings.save_for_system("nes")
	DesktopBindings.apply_for_system("")
	_check(_first_key("RETRO_JOYPAD_A") == global_key,
		"the global key map is what stands with nobody captured")

	# Capture is only eligible for a pad HELD at a desk and plugged into a port
	# (RetroController._can_capture). It is already plugged; this is the hold.
	pad.set("_desktop_held", true)
	var cap: Object = pad.get("_capture")
	_check(cap != null, "the pad has a Scroll Lock capture")
	if cap != null:
		cap.call("refresh")
		cap.call("set_active", true)
		await get_tree().process_frame
		await get_tree().process_frame
		_check(_first_key("RETRO_JOYPAD_A") == nes_key,
			"taking the keyboard at a NES loads the NES key map (got %d, want %d)"
				% [_first_key("RETRO_JOYPAD_A"), nes_key])

		cap.call("set_active", false)
		await get_tree().process_frame
		await get_tree().process_frame
		_check(_first_key("RETRO_JOYPAD_A") == global_key,
			"and letting it go puts the global map back (got %d, want %d)"
				% [_first_key("RETRO_JOYPAD_A"), global_key])

	# Pulling the pad out has to put it back on global, or a pad carried away
	# from a console keeps playing that console's layout in your hand.
	pad.call("on_unplugged")
	await get_tree().process_frame
	_check(int((pad.get("_button_map") as Dictionary).get("right_ax_button"))
		== ControllerBindings.JOYPAD_A,
		"and unplugging puts it back on the global map (got %s)"
			% str((pad.get("_button_map") as Dictionary).get("right_ax_button")))

	# ── The console's own pad drives the same two stores ─────────────────────
	# A NES page draws a NES pad and asks the inverse question — this button,
	# what drives it? — so the write has to invert back onto maps keyed the other
	# way. That inversion is the part with somewhere to go wrong.
	var nes_editor2: Node = ControlsBindingEditor.new()
	nes_editor2.set("_systemid", "nes")
	add_child(nes_editor2)
	nes_editor2.call("_build_xr_controls", nes_editor2)
	nes_editor2.call("_build_gamepad_controls", nes_editor2)
	await get_tree().process_frame

	_check(nes_editor2.get("_console_xr_diagram") != null,
		"a platform with pad art gets its own controller, not the Quest picture")
	_check(nes_editor2.get("_console_pad_diagram") != null,
		"and its own controller in the GAME CONTROLLER section too")

	# The fallback is the whole reason the registry has a `has()`: 65 of the 66
	# configured platforms have no art and must still be bindable.
	var snes_editor: Node = ControlsBindingEditor.new()
	snes_editor.set("_systemid", "super_nes")
	add_child(snes_editor)
	snes_editor.call("_build_xr_controls", snes_editor)
	snes_editor.call("_build_gamepad_controls", snes_editor)
	await get_tree().process_frame
	_check(snes_editor.get("_console_xr_diagram") == null
		and snes_editor.get("_pad_diagram") != null,
		"a platform without pad art falls back to the generic diagrams")

	# Releasing the old input is the half the store assertions above cannot see:
	# two inputs on one button would still read as bound.
	var after: Dictionary = nes_editor2.get("_edit_button_map")
	_check(int(after.get("right_ax_button", -1)) != ControllerBindings.JOYPAD_A,
		"binding A to a new input released the one that held it (%s)"
			% str(after.get("right_ax_button")))

	# Physical pad: give the NES's B whatever currently drives its A. A is a
	# control this pad SHOWS, so it has to be released.
	var pad_before: Dictionary = nes_editor2.get("_edit_pad_button_map")
	var a_bind := String(pad_before.get("a", "none"))
	_check(a_bind != "none", "the NES A has a gamepad button to begin with (%s)" % a_bind)
	nes_editor2.call("_on_console_pad_changed", "b", a_bind)
	await get_tree().process_frame
	var pad_after: Dictionary = nes_editor2.get("_edit_pad_button_map")
	_check(String(pad_after.get("b", "none")) == a_bind,
		"picking a gamepad button for B binds it")
	_check(String(pad_after.get("a", "none")) == "none",
		"and takes it off A, which this pad shows (got %s)" % str(pad_after.get("a")))
	# A target the NES pad does NOT draw keeps whatever it had: the console has no
	# such button, and clearing a binding the player cannot see would be worse.
	_check(String(pad_after.get("x", "none")) == String(pad_before.get("x", "none")),
		"but leaves a button the NES does not have alone")

	print("[probe] RESULT %s" % ("PASS" if not _fail else "FAIL"))
	_quit(1 if _fail else 0)
