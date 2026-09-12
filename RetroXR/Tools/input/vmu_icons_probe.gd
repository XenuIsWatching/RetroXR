## VMU icons probe — real Dreamcast saves on a card, and their icons moving
## in the card's panel.
##
## The card format's icon decode was proven on a generated fixture, which
## proves the decoder agrees with the generator and nothing about a game's
## art. This takes real saves — the bucanero/dreamcast-saves archive, or any
## folder of .vms files with .vmi sidecars — puts them on a card the way a
## Dreamcast would, opens the card's own panel, and captures it over a few
## seconds so the animation can be WATCHED, which is the only check there is
## for whether it reads as the game's icon or as a smear.
##
##     "$godot" --path RetroXR --resolution 320x240 --position 20,20 \
##         res://Tools/input/vmu_icons_probe.tscn -- \
##         --dir="C:/Users/rymcc/Downloads/dreamcast-saves" \
##         --files=crazytaxi/00000590.VMS,ikaruga/IKARUGA.VMS[,...] \
##         [--captures=48] [--every=5]
##
## Windowed, never headless: the panel is a SubViewport, and the dummy renderer
## hands back a blank image while the size oracle reads correctly. Frames land
## in res://probe_out/vmu_icons/ as PNGs; encode with imageio, mp4 over GIF.
##
## Two things are asserted so the run cannot pass on a blank: every file goes
## onto the card and lists with more than one icon frame, and at least one
## captured frame differs from the first — a panel whose icons never change is
## a decoder that returned one frame three times.
##
## It writes a card image into the player's real memory card folder under a
## name no player would use, and deletes it at the end. Nothing from the
## archive is copied anywhere else.
extends Node

const VMU_SCENE := preload("res://Scenes/Objects/controllers/dreamcast/vmu_card.tscn")
const CARD_ID := "__vmu_icons_probe"

var dir := ""
var files: PackedStringArray = []
var captures := 48
var every := 5
var out_dir := "res://probe_out/vmu_icons"

var _fail := 0
var _card: VmuCard = null


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--dir="):
			dir = s.substr("--dir=".length())
		elif s.begins_with("--files="):
			files = s.substr("--files=".length()).split(",", false)
		elif s.begins_with("--captures="):
			captures = maxi(2, int(s.substr("--captures=".length())))
		elif s.begins_with("--every="):
			every = maxi(1, int(s.substr("--every=".length())))
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[vmuicons] TIMEOUT")
		_cleanup()
		get_tree().quit(1))
	await _run()
	_cleanup()
	print("[vmuicons] ---- %s ----" % ("all checks passed" if _fail == 0 else "%d FAILED" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if not cond:
		_fail += 1
	print("[vmuicons] %s  %s%s" % ["PASS" if cond else "FAIL", what,
		"" if detail.is_empty() else "  - " + detail])


## The 12-char name the save takes on the card, read from its .vmi sidecar,
## or made from the file name when there is none.
func _card_name(vms_path: String) -> String:
	for ext: String in [".vmi", ".VMI"]:
		var vmi := vms_path.get_basename() + ext
		if FileAccess.file_exists(vmi):
			var v := FileAccess.get_file_as_bytes(vmi)
			if v.size() >= 108:
				var n := v.slice(0x58, 0x64).get_string_from_ascii().strip_edges()
				if not n.is_empty():
					return n
	return vms_path.get_file().get_basename().to_upper().left(VMUCard.E_NAME_LEN)


func _cleanup() -> void:
	var path := SramPaths.find_card(CARD_ID, VmuCard.FAMILY)
	if not path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _run() -> void:
	if dir.is_empty() or files.is_empty():
		_ok(false, "--dir and --files were given")
		return

	# --- The card, filled the way a Dreamcast fills one ------------------------
	var image := VMUCard.blank_image()
	var placed := 0
	for rel in files:
		var p := dir.path_join(rel)
		var body := FileAccess.get_file_as_bytes(p)
		if body.is_empty():
			_ok(false, "%s reads" % rel)
			continue
		var dci := VMUCard.dci_from_vms(body, _card_name(p), false)
		var next := VMUCard.insert_save(image, dci)
		_ok(not next.is_empty(), "%s goes onto the card as %s" % [rel, _card_name(p)],
			"%d bytes" % body.size())
		if not next.is_empty():
			image = next
			placed += 1
	var saves := VMUCard.list_saves(image, true)
	_eq_count(saves.size(), placed, "every placed save lists")
	for s: Dictionary in saves:
		var icons: Array = s["icons"]
		_ok(icons.size() > 1, "%s lists with an animated icon" % str(s["title"]),
			"%d frames" % icons.size())

	_card = VMU_SCENE.instantiate() as VmuCard
	_card.card_id = CARD_ID
	_card.card_label = "Real saves"
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
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(image)
	f.close()

	# --- The panel, watched --------------------------------------------------
	_card.toggle_options_ui(cam)
	var panel: MemoryCardPanel = null
	for c in _card.get_children():
		if c is MemoryCardPanel:
			panel = c
	_ok(panel != null, "the card opens its panel")
	if panel == null:
		return
	for i in range(10):
		await get_tree().process_frame
	var vp := panel.get_node_or_null("MemoryCardViewport/Viewport") as SubViewport
	_ok(vp != null, "with a viewport to read")
	if vp == null:
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out_dir))
	var first: PackedByteArray = PackedByteArray()
	var changed := 0
	for i in range(captures):
		for j in range(every):
			await get_tree().process_frame
		var img := vp.get_texture().get_image()
		if img == null:
			continue
		img.save_png(out_dir.path_join("frame_%03d.png" % i))
		var bytes := img.get_data()
		if i == 0:
			first = bytes
		elif bytes != first:
			changed += 1
	print("[vmuicons] wrote %d frames to %s" % [captures, out_dir])
	_ok(changed > 0, "the panel changes between captures, so the icons animate",
		"%d of %d captures differ from the first" % [changed, captures - 1])


func _eq_count(got: int, want: int, what: String) -> void:
	_ok(got == want, what, "%d of %d" % [got, want])
