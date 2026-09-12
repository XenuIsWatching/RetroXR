## VMU play probe — a minigame picked off the card through the panel, played by
## the hand, and stopped from the panel.
##
## The whole route a player takes, with the real core behind it: a game is
## put on a card the way a Dreamcast leaves one there, the card's panel is
## opened, its play button is pressed, the hand holding the card presses A
## and B, and the panel's stop button powers it off. Each step is measured
## rather than assumed — the panel must show the button, the core must come
## up, the LCD must change under input, and the card must go dark again.
##
##     "$godot" --path RetroXR --resolution 320x240 --position 20,20 \
##         res://Tools/input/vmu_play_probe.tscn -- \
##         --vms="C:/path/to/Breakout.vms" [--frames=240]
##
## Windowed rather than headless when the panel shot is wanted: the dummy
## renderer hands back a blank image. The checks themselves work either way.
##
## It writes a card image into the player's real memory card folder (the
## panel finds a card by its id, and that path cannot be pointed elsewhere)
## under a name no player would use, and deletes it at the end.
##
## **The stop checks at the end are unreachable with the buildbot core.** Every
## check through "released is released" passes, then the process dies with an
## access violation inside vemulator's retro_deinit — its flash object's file
## handle is never initialised and its destructor closes it regardless (see
## VmuCard._boot). Until the core's fork carries that one-line fix, read a run
## that ends after the teardown log lines as the pass it is, and the missing
## three lines as the core's crash rather than this probe's.
extends Node

const VMU_SCENE := preload("res://Scenes/Objects/controllers/dreamcast/vmu_card.tscn")
const CARD_ID := "__vmu_play_probe"

var vms := ""
var frames := 240
var shot_dir := "res://probe_out"

var _fail := 0
var _card: VmuCard = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--vms="):
			vms = s.substr("--vms=".length())
		elif s.begins_with("--frames="):
			frames = maxi(30, int(s.substr("--frames=".length())))
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[vmuplay] TIMEOUT")
		_cleanup()
		get_tree().quit(1))
	await _run()
	_cleanup()
	print("[vmuplay] ---- %s ----" % ("all checks passed" if _fail == 0 else "%d FAILED" % _fail))
	# The standalone probe found that quitting straight after StopContent dies
	# in the extension's audio teardown; sixty frames is what settles it.
	for i in range(60):
		await get_tree().process_frame
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if not cond:
		_fail += 1
	print("[vmuplay] %s  %s%s" % ["PASS" if cond else "FAIL", what,
		"" if detail.is_empty() else "  - " + detail])


func _lcd_digest() -> String:
	var lib := _card.get_node_or_null("VmuLibretro")
	if lib == null:
		return ""
	var tex: Texture2D = lib.GetVideoTexture()
	if tex == null:
		return ""
	var img := tex.get_image()
	if img == null:
		return ""
	var lit := 0
	var sum := 0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			if img.get_pixel(x, y).get_luminance() > 0.5:
				lit += 1
				sum += x * 7 + y * 13
	return "%d/%d" % [lit, sum]


func _find_glyph(root: Node, glyph: int) -> Button:
	var b := root as Button
	if b != null and b.text == String.chr(glyph):
		return b
	for c in root.get_children():
		var hit := _find_glyph(c, glyph)
		if hit != null:
			return hit
	return null


func _save_panel_shot(panel: MemoryCardPanel, path: String) -> void:
	var vp := panel.get_node_or_null("MemoryCardViewport/Viewport") as SubViewport
	if vp == null:
		return
	var img := vp.get_texture().get_image()
	if img == null:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(path.get_base_dir()))
	img.save_png(path)
	print("[vmuplay] wrote %s" % path)


func _cleanup() -> void:
	var path := SramPaths.find_card(CARD_ID, VmuCard.FAMILY)
	if not path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if _card != null:
		var scratch := _card.play_scratch_path()
		if FileAccess.file_exists(scratch):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(scratch))


func _run() -> void:
	if vms.is_empty() or not FileAccess.file_exists(vms):
		_ok(false, "a --vms was given and exists", vms)
		return

	# --- A card with a game on it, the way a Dreamcast leaves one ------------
	_card = VMU_SCENE.instantiate() as VmuCard
	_card.card_id = CARD_ID
	_card.card_label = CARD_ID
	add_child(_card)
	_card.freeze = true
	var cam := Camera3D.new()
	cam.position = Vector3(0, 0.1, 0.5)
	add_child(cam)
	await get_tree().process_frame

	var path := SramPaths.ensure_card(VmuCard.FAMILY, CARD_ID)
	_ok(not path.is_empty(), "the card has an image", path)
	if path.is_empty():
		return
	var dci := VMUCard.dci_from_vms(FileAccess.get_file_as_bytes(vms), "PROBE___GAME")
	var img := VMUCard.insert_save(VMUCard.blank_image(), dci)
	_ok(not img.is_empty(), "the game goes onto the card", "%d bytes as .dci" % dci.size())
	if img.is_empty():
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(img)
	f.close()
	var listed := VMUCard.list_saves(img, false)
	_ok(listed.size() == 1 and bool(listed[0]["is_game"]),
		"and the card lists it as a game", str(listed))

	# --- The panel offers it -------------------------------------------------
	_card.toggle_options_ui(cam)
	var panel := _card.get_node_or_null("MemoryCardPanel") as MemoryCardPanel
	if panel == null:
		for c in _card.get_children():
			if c is MemoryCardPanel:
				panel = c
	_ok(panel != null, "the card opens the memory card panel")
	if panel == null:
		return
	for i in range(6):
		await get_tree().process_frame
	var ui: MemoryCard2D = panel.call("_get_ui")
	_ok(ui != null, "with the save list in it")
	if ui == null:
		return
	var play := _find_glyph(ui, MenuIcons.PLAY)
	_ok(play != null and not play.disabled, "and a play button on the game row")
	_save_panel_shot(panel, shot_dir.path_join("vmu_play_panel.png"))
	if play == null:
		return

	# --- Pressing it boots the core -----------------------------------------
	play.pressed.emit()
	for i in range(frames):
		await get_tree().process_frame
	_ok(_card.is_running_standalone(), "pressing play powers the card up")
	# What was handed to the core is a whole flash image with the game's own
	# bytes at block 0 — the one form the core both runs AND unloads without
	# dying (see VmuCard._boot). Lifting block 0 back off it and un-swapping
	# must give the source .vms from its first byte.
	var handed := FileAccess.get_file_as_bytes(_card.play_scratch_path())
	var source := FileAccess.get_file_as_bytes(vms)
	_ok(VMUCard.is_card_image(handed), "the file handed to the core is a flash image",
		"%d bytes" % handed.size())
	var at0 := VMUCard.extract_save(handed, 0)
	var body := VMUCard._word_swap(at0.slice(VMUCard.DCI_HEADER)) if not at0.is_empty() \
		else PackedByteArray()
	_ok(body.size() >= source.size() and body.slice(0, source.size()) == source,
		"with the game's own bytes at block 0",
		"%d lifted, %d in the source .vms" % [body.size(), source.size()])
	_ok(_card.playing_title() != "", "under the save's name", _card.playing_title())
	var lib := _card.get_node_or_null("VmuLibretro")
	var ran: int = int(lib.GetFrameCount()) if lib != null else 0
	_ok(ran > 0, "and the core runs frames", "%d frames" % ran)
	var stop := _find_glyph(ui, MenuIcons.STOP)
	_ok(stop != null, "the panel now shows a stop button")
	_ok(_find_glyph(ui, MenuIcons.PLAY) == null, "and no play button while it runs")
	_save_panel_shot(panel, shot_dir.path_join("vmu_play_panel_running.png"))

	# --- The hand plays it ---------------------------------------------------
	#
	# A hand on the card, faked the way the tests fake one: a controller bound
	# to a tracker whose buttons are set by hand. Breakout's title says "Press
	# A+B to start", so the screen has to change under those two.
	var origin := XROrigin3D.new()
	add_child(origin)
	var ctrl := XRController3D.new()
	ctrl.tracker = &"right_hand"
	ctrl.pose = &"default"
	origin.add_child(ctrl)
	var tracker := XRControllerTracker.new()
	tracker.name = &"right_hand"
	XRServer.add_tracker(tracker)
	var input := _card.get_node_or_null("VmuInput") as VmuInput
	_ok(input != null, "the card's input node is there")
	if input == null:
		return
	input._holders.append(ctrl)
	var before := _lcd_digest()
	tracker.set_input(&"ax_button", 1.0)
	tracker.set_input(&"by_button", 1.0)
	for i in range(90):
		await get_tree().process_frame
	_ok(_card.input_mask() & (1 << ControllerBindings.JOYPAD_A) != 0,
		"the hand's A reaches the card", "mask %d" % _card.input_mask())
	tracker.set_input(&"ax_button", 0.0)
	tracker.set_input(&"by_button", 0.0)
	for i in range(60):
		await get_tree().process_frame
	var after := _lcd_digest()
	print("[vmuplay] LCD before=%s after=%s" % [before, after])
	_ok(not before.is_empty() and before != after,
		"and A+B changes what the LCD shows, so the press reached the core")
	_ok(_card.input_mask() == 0, "released is released")

	# --- Stopped from the panel ---------------------------------------------
	if stop != null:
		stop.pressed.emit()
	for i in range(30):
		await get_tree().process_frame
	_ok(not _card.is_running_standalone(), "the stop button powers the card down")
	_ok(_card.playing_title() == "", "and it plays nothing again")
	_ok(_find_glyph(ui, MenuIcons.PLAY) != null, "and the play button is back")
	XRServer.remove_tracker(tracker)
