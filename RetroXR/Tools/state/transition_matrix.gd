## Exhaustive shakedown of room changes: every ordered pair of rooms, repeated
## laps watched for leaks, and the adversarial cases that a player can actually
## produce (double-tapping a room, leaving mid-restore, carrying something out).
##
## Every step ends with the same invariant check, and every step prints a marked
## banner so the errors Godot writes to stderr can be attributed to the step that
## caused them. Run windowed, not --headless: the arcade's SubViewports never
## service a render target under the dummy driver.
##
##   godot --path RetroXR --resolution 480x360 res://Tools/state/transition_matrix.tscn
extends Node

const ROOMS := ["arcade", "den", "bedroom", "test"]

## With `-- --core`, every room gets a console powered on in it before we leave
## again, so each transition tears a running libretro core down rather than only
## the three scene_soak.gd covers. Needs the core installed and a ROM at
## user://roms/smb.nes; without either, the run says so and carries on.
const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const CORE_NAME := "fceumm"
const CORE_SYSTEMID := "nes"
const CORE_ROM := "/roms/smb.nes"

var _with_core := false
var _rom := ""
var _powered := 0

var _step := 0
var _failures: Array[String] = []
var _min_y := 999.0
var _watch := false


func _ready() -> void:
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	SceneManager.scene_ready.connect(_on_scene_ready)
	_run.call_deferred()


## Covers every exit, including the timeout and a failing run — not just the
## happy path, which is all _run() reaches.
func _exit_tree() -> void:
	_release_scratch_slot()


func _process(_d: float) -> void:
	if not _watch:
		return
	var rig := _rig()
	if rig != null:
		_min_y = minf(_min_y, rig.camera.global_position.y)


func _run() -> void:
	var tree := get_tree()
	tree.create_timer(1800.0).timeout.connect(func() -> void:
		print("[matrix] TIMEOUT"); tree.quit(2))
	_claim_scratch_slot()
	_with_core = "--core" in OS.get_cmdline_user_args()
	if _with_core:
		_rom = OS.get_user_data_dir() + CORE_ROM
		if not FileAccess.file_exists(_rom):
			print("[matrix] no ROM at %s — running without a core" % _rom)
			_with_core = false

	var arcade: Node = (load("res://Scenes/MainScene.tscn") as PackedScene).instantiate()
	tree.root.add_child(arcade)
	tree.current_scene = arcade
	await _settle(8.0)
	print("[matrix] baseline: %s" % _counts())

	await _phase_pairs()
	await _phase_laps()
	await _phase_adversarial()
	await _phase_still_works()

	if _with_core:
		print("[matrix] cores powered on and torn down: %d" % _powered)
	print("[matrix] ===== %d step(s), %d invariant failure(s) =====" % [_step, _failures.size()])
	for f: String in _failures:
		print("[matrix] FAIL %s" % f)
	tree.quit(1 if not _failures.is_empty() else 0)


## Work on a copy of the player's save, never the real one.
##
## Turning auto_save_on_switch off is NOT enough: SpawnMenuController's deferred
## setup calls _on_auto_save_changed(AppPrefs.auto_save_scene) a moment after the
## room comes up, which silently turns it back on from the player's prefs. A run
## of this file then auto-saves the probe's idea of the room over their arcade on
## every single change — it overwrote a 39-object save with a 1-object one before
## this guard existed. Pointing the active slot at a scratch id means every write
## lands in a file nobody else reads. (Copying to it keeps the restore path
## covered; "clean" would be safe too but restores nothing.)
##
## EVERY room that keeps slots, not just the arcade: this walk enters passthrough
## too, and passthrough auto-saves on the way out exactly as the arcade does.
const SCRATCH_SLOT := "zz_probe_scratch"


func _claim_scratch_slot() -> void:
	SceneManager.auto_save_on_switch = false
	for room: String in RoomCatalog.slot_rooms():
		var dir := ScenePersistence.new(room).slot_dir()
		var source := "%s/%s.json" % [dir, SceneManager.active_slot(room)]
		if FileAccess.file_exists(source):
			DirAccess.copy_absolute(source, "%s/%s.json" % [dir, SCRATCH_SLOT])
		SceneManager.active_slots[room] = SCRATCH_SLOT
		print("[matrix] %s: using scratch slot '%s' (copied from '%s')"
			% [room, SCRATCH_SLOT, source])


func _release_scratch_slot() -> void:
	for room: String in RoomCatalog.slot_rooms():
		var scratch := "%s/%s.json" % [ScenePersistence.new(room).slot_dir(), SCRATCH_SLOT]
		if FileAccess.file_exists(scratch):
			DirAccess.remove_absolute(scratch)


# ── Phases ────────────────────────────────────────────────────────────────────

## Every ordered pair of rooms, as one continuous walk.
func _phase_pairs() -> void:
	print("[matrix] ### phase: every ordered pair")
	for a: String in ROOMS:
		for b: String in ROOMS:
			if a == b:
				continue
			if SceneManager.current_scene_id != a:
				await _go(a)
			await _go(b)


## The same lap over and over, watching what does not get cleaned up.
##
## Read the counters on a run WITHOUT --core. With it, every room gets a console
## added to the "spawned" group and the auto-save writes them into the scratch
## slot, which restores more of them next lap — the growth is this probe's, not
## the product's. A clean run holds nodes and orphans flat.
func _phase_laps() -> void:
	print("[matrix] ### phase: repeat laps (leak watch)")
	await _go("arcade")
	for lap in range(6):
		await _go("bedroom")
		await _go("arcade")
		print("[matrix] lap %d: %s" % [lap + 1, _counts()])


## The things a player does that the happy path never covers.
func _phase_adversarial() -> void:
	print("[matrix] ### phase: adversarial")
	var tree := get_tree()

	await _mark("double change_scene in one frame")
	SceneManager.change_scene("den")
	SceneManager.change_scene("bedroom")
	await _settle(10.0)
	if SceneManager.current_scene_id != "bedroom":
		_fail("double change_scene", "latest room request was not installed")
	_check("double change_scene")

	await _mark("change_scene interrupting a transition in flight")
	SceneManager.change_scene("arcade")
	await tree.create_timer(0.30).timeout
	SceneManager.change_scene("den")
	await _settle(12.0)
	if SceneManager.current_scene_id != "den":
		_fail("interrupted transition", "latest room request was not installed")
	_check("interrupted transition")

	await _mark("leave a room while a slot restore is running")
	# The ARCADE's slot, named rather than taken from active_slot_id: slots are per
	# room, and this step runs while standing in a room that keeps none — which read
	# "clean" and skipped both restore cases without saying so.
	var slot: String = SceneManager.active_slot("arcade")
	if slot != "clean":
		ScenePersistence.new().load_slot_async(tree.current_scene, slot)
		await tree.create_timer(0.35).timeout
		SceneManager.change_scene("arcade")
		await _settle(12.0)
		_check("scene change mid-restore")

		await _mark("two slot restores at once")
		ScenePersistence.new().load_slot_async(tree.current_scene, slot)
		ScenePersistence.new().load_slot_async(tree.current_scene, slot)
		await _settle(10.0)
		_check("overlapping restores")
	else:
		print("[matrix] (no save slot on this machine — restore cases skipped)")

	await _mark("carry a held object out of the room")
	var held := _grab_something()
	print("[matrix] holding: %s" % held)
	await _go("bedroom")
	_check("transition while holding")

	await _mark("change to the room we are already in")
	var before := tree.current_scene
	SceneManager.change_scene("bedroom")
	await _settle(3.0)
	if tree.current_scene != before:
		_failures.append("no-op change_scene rebuilt the room")
	_check("no-op change_scene")


## Structural invariants say the rig is present and shaped right. This asks
## whether it still DOES anything after being dragged through every room — the
## thing carrying it instead of rebuilding it puts at risk.
func _phase_still_works() -> void:
	print("[matrix] ### phase: the carried rig still works")
	await _mark("menu, pointers, locomotion and grabbing after all of that")

	var menu_vp := _rig_node("SpawnMenuController/SpawnMenuViewport/Viewport")
	if menu_vp == null or menu_vp.get_child_count() == 0:
		_fail("still works", "spawn menu 2D scene is gone")
	var ctl := _rig_node("SpawnMenuController")
	if ctl == null:
		_fail("still works", "no SpawnMenuController")
	else:
		ctl._show_menu()
		await get_tree().create_timer(0.75).timeout
		if not ctl._viewport_node.visible:
			_fail("still works", "menu would not open")
		if ctl._get_menu() == null:
			_fail("still works", "menu 2D root is not a SpawnMenu2D")
		ctl._hide_menu()
		await get_tree().create_timer(0.5).timeout
		if ctl._viewport_node.visible:
			_fail("still works", "menu would not close")

	var pointers := get_tree().root.find_children("*", "XRToolsFunctionPointer", true, false)
	if pointers.size() < 2:
		_fail("still works", "%d pointers left on the rig" % pointers.size())

	var loco := _rig_node("LocomotionManager")
	if loco != null and loco.is_blocked(LocomotionManager.CHANNEL_ALL):
		_fail("still works", "locomotion is stuck blocked")

	# Grab something, carry it a moment, put it down.
	var pickups := get_tree().root.find_children("*", "XRToolsFunctionPickup", true, false)
	if pickups.is_empty():
		_fail("still works", "no pickup function on the rig")
	else:
		var pickup: XRToolsFunctionPickup = pickups[0]
		var target: Node3D = null
		for node: Node in get_tree().get_nodes_in_group("spawned"):
			if node is XRToolsPickable and not (node as XRToolsPickable).is_picked_up():
				target = node as Node3D
				break
		if target == null:
			print("[matrix] (nothing pickable in this room — grab check skipped)")
		else:
			pickup._pick_up_object(target)
			await get_tree().create_timer(0.5).timeout
			if pickup.picked_up_object != target:
				_fail("still works", "could not pick '%s' up" % target.name)
			pickup.drop_object()
			await get_tree().create_timer(0.5).timeout
			if pickup.picked_up_object != null:
				_fail("still works", "could not put '%s' down" % target.name)
	_check("after the functional pass")


# ── Machinery ─────────────────────────────────────────────────────────────────

func _go(room: String) -> void:
	await _mark("change_scene('%s')" % room)
	_min_y = 999.0
	_watch = true
	SceneManager.change_scene(room)
	await _settle(12.0)
	_watch = false
	if _min_y < 0.5:
		_failures.append("step %d: fell to y=%.2f entering %s" % [_step, _min_y, room])
	_check("in %s" % room)
	if _with_core:
		await _power_on_a_console(room)


## Stand a console in this room with a core actually running, and leave it
## running — the next room change is then a teardown of live emulation, which is
## where the C++ side (thread join, texture lifetime) meets the scene swap.
func _power_on_a_console(room: String) -> void:
	var tree := get_tree()
	var scene := tree.current_scene
	if scene == null:
		return
	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = CORE_SYSTEMID
	sys.core_name = CORE_NAME
	sys._video_out_from_save = 1
	scene.add_child(sys)
	sys.add_to_group("spawned")
	sys.global_position = Vector3(0.6, 0.85, -0.4)
	for ch in sys.get_channel_count():
		var tv := TV_SCENE.instantiate() as RetroTV
		scene.add_child(tv)
		tv.add_to_group("spawned")
		tv.global_position = Vector3(-0.5, 0.95 + 0.42 * float(ch), -0.5)
		tv.freeze = true
		sys.restore_cable_connection(tv, ch)
	for i in 30:
		await tree.process_frame

	sys.rom_path = _rom
	sys.power_on()
	for i in 90:
		await tree.process_frame
	if not sys.is_powered_on:
		_fail("core in %s" % room, "console would not power on")
		return
	_powered += 1
	var tv0: RetroTV = sys.get_channel_tv(0)
	if tv0 == null or tv0.get_screen_mesh() == null \
			or tv0.get_screen_mesh().get_surface_override_material(0) == null:
		_fail("core in %s" % room, "core is running but nothing is bound to a screen")


func _mark(what: String) -> void:
	_step += 1
	print("[matrix] --- step %d: %s" % [_step, what])
	await get_tree().process_frame


## Wait for the transition to finish, then let the room settle.
func _settle(limit: float) -> void:
	var tree := get_tree()
	var waited := 0.0
	while waited < limit:
		await tree.create_timer(0.25).timeout
		waited += 0.25
		if not SceneManager._transitioning and tree.current_scene != null and waited >= 2.0:
			break
	await tree.create_timer(1.5).timeout


func _check(where: String) -> void:
	var tree := get_tree()
	var scene := tree.current_scene
	if scene == null:
		_fail(where, "no current_scene")
		return

	var origins := tree.root.find_children("*", "XROrigin3D", true, false)
	var cams := tree.root.find_children("*", "XRCamera3D", true, false)
	var vp_cam := tree.root.get_viewport().get_camera_3d()
	if origins.size() != 1:
		_fail(where, "%d XROrigin3D in the tree" % origins.size())
	if cams.size() != 1:
		_fail(where, "%d XRCamera3D in the tree" % cams.size())
	if vp_cam == null or not (vp_cam is XRCamera3D):
		_fail(where, "viewport camera is %s" % [vp_cam.name if vp_cam else "<none>"])
	if tree.root.get_node_or_null("LoadingRig") != null:
		_fail(where, "loading rig left in the tree")
	if SceneManager._transitioning:
		_fail(where, "still marked _transitioning")
	var expected_path: String = RoomCatalog.path_of(SceneManager.current_scene_id)
	if scene.scene_file_path != expected_path:
		_fail(where, "scene id '%s' points at '%s', but '%s' is loaded" % [
			SceneManager.current_scene_id, expected_path, scene.scene_file_path])

	var rig := scene.get_node_or_null("PlayerRig") as PlayerRig
	if rig == null:
		_fail(where, "PlayerRig is not under the current scene")
		return
	if not rig.body.enabled:
		_fail(where, "player body left disabled")
	if not rig.body.on_ground:
		_fail(where, "player is not on the ground")
	if rig.body._fade_value > 0.01:
		_fail(where, "view faded (%.2f)" % rig.body._fade_value)
	var y := rig.camera.global_position.y
	if y < 0.5 or y > 2.5:
		_fail(where, "camera y=%.2f" % y)


func _on_scene_ready(scene_id: String) -> void:
	var scene := get_tree().current_scene
	var expected_path: String = RoomCatalog.path_of(scene_id)
	if scene_id != SceneManager.current_scene_id:
		_fail("scene_ready", "announced '%s' while current id is '%s'" % [
			scene_id, SceneManager.current_scene_id])
	elif scene == null or scene.scene_file_path != expected_path:
		_fail("scene_ready", "announced '%s' while '%s' is loaded" % [
			scene_id, scene.scene_file_path if scene != null else "<none>"])


func _fail(where: String, what: String) -> void:
	var msg := "step %d (%s): %s" % [_step, where, what]
	_failures.append(msg)
	print("[matrix] FAIL %s" % msg)


func _counts() -> String:
	return "nodes=%d orphans=%d objects=%d resources=%d spawned=%d" % [
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT),
		Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT),
		Performance.get_monitor(Performance.OBJECT_COUNT),
		Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT),
		get_tree().get_nodes_in_group("spawned").size()]


## Put something in the player's hand the way a pickup would.
func _grab_something() -> String:
	var pickups := get_tree().root.find_children("*", "XRToolsFunctionPickup", true, false)
	if pickups.is_empty():
		return "<no pickup function>"
	var pickup: XRToolsFunctionPickup = pickups[0]
	for node: Node in get_tree().get_nodes_in_group("spawned"):
		if node is XRToolsPickable and not (node as XRToolsPickable).is_picked_up():
			pickup._pick_up_object(node as Node3D)
			return node.name
	return "<nothing pickable spawned>"


## Whichever rig is currently seated, wherever it is mid-transition.
func _rig() -> PlayerRig:
	var scene := get_tree().current_scene
	var rig := scene.get_node_or_null("PlayerRig") if scene != null else null
	if rig == null:
		rig = get_tree().root.get_node_or_null("PlayerRig")
	return rig as PlayerRig


func _rig_node(path: String) -> Node:
	var rig := _rig()
	return rig.get_node_or_null(path) if rig != null else null
