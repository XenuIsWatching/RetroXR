## e-Reader self-tests — grouping dotcode files into cards, the edge each strip
## is printed on, and the swipe that reads one. Headless, no core, no ROM, no
## card on disk, no headset.
##
##     "$godot" --headless --path RetroXR res://Tests/ereader_tests.tscn
##     "$godot" --headless --path RetroXR res://Tests/ereader_tests.tscn -- --only=swipe
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## Groups:
##   data/     grouping across BOTH suffix families, shape, and the edge table
##   geom/     which edge is in the groove, which way up, and where it seats
##   catalog/  the unit's row, its boot recipe and its firmware
##   library/  scanning a folder of strips back into cards, and sizing them
##   swipe/    a real body through a real Area3D: a full pass, a botched one
extends Node

var _checks := 0
var _failed := 0
var _only := ""

# Signal results live on the instance, NOT in locals captured by a lambda:
# GDScript captures by VALUE, so a handler doing `hits += 1` on a captured local
# increments its own copy and the assertion reads 0 for ever — passing whenever
# it expects 0, which is most of the interesting cases here.
var _swipe_edge := ""
var _swipe_strip := -99
var _swipes := 0
var _aborts := 0
var _entered := 0


func _reset_signals() -> void:
	_swipe_edge = ""
	_swipe_strip = -99
	_swipes = 0
	_aborts = 0
	_entered = 0


func _on_swiped(_c: Node3D, edge: String, strip: int) -> void:
	_swipe_edge = edge
	_swipe_strip = strip
	_swipes += 1


func _on_aborted(_c: Node3D) -> void:
	_aborts += 1


func _on_entered(_b: Node3D) -> void:
	_entered += 1


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.substr(7)
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[erd] TIMED OUT")
		get_tree().quit(1))
	await _run()
	print("[erd] %d checks, %d failed" % [_checks, _failed])
	print("[erd] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
	print("[erd] %s  %s" % ["PASS" if ok else "FAIL", what])


func _eq(got: Variant, want: Variant, what: String) -> void:
	_check(got == want, "%s (got %s, want %s)" % [what, got, want])


func _want(group: String) -> bool:
	return _only.is_empty() or _only == group


func _wait(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _run() -> void:
	if _want("data"):
		_group_data()
	if _want("geom"):
		_group_geom()
	if _want("catalog"):
		_group_catalog()
	if _want("library"):
		_group_library()
	if _want("swipe"):
		await _group_swipe()


# ── data/ ────────────────────────────────────────────────────────────────────

func _f(name: String, size: int) -> Dictionary:
	return {"path": "/roms/ereader/%s.raw" % name, "size": size}


func _group_data() -> void:
	const LONG := EReaderCards.SIZE_LONG
	const SHORT := EReaderCards.SIZE_SHORT

	# Both suffix families group. Grouping on "(Strip N)" alone was the first
	# attempt and it split every long+short pair into two separate cards.
	var cards := EReaderCards.group([
		_f("Hoppip (USA) (Long Strip)", LONG),
		_f("Hoppip (USA) (Short Strip)", SHORT),
		_f("Boy 1 (USA) (Strip 1)", LONG),
		_f("Boy 1 (USA) (Strip 2)", LONG),
		_f("Mario Party-e (USA)", LONG),
		_f("Nidorino (USA) (Short Strip)", SHORT),
		_f("Tom Nook (USA)", 2911),
		_f("Orphan (USA) (Strip 1)", LONG),
	])
	_eq(cards.size(), 6, "data/ eight files collapse to six cards")

	var by_key: Dictionary = {}
	for c: Dictionary in cards:
		by_key[str(c["key"])] = c

	_eq(str((by_key["Hoppip (USA)"] as Dictionary)["shape"]),
		EReaderCards.SHAPE_LONG_SHORT, "data/ long+short pairs group")
	_eq(str((by_key["Boy 1 (USA)"] as Dictionary)["shape"]),
		EReaderCards.SHAPE_TWO_LONG, "data/ Strip 1 + Strip 2 group")
	_eq(str((by_key["Mario Party-e (USA)"] as Dictionary)["shape"]),
		EReaderCards.SHAPE_LONG, "data/ a lone long strip is a long card")
	_eq(str((by_key["Nidorino (USA)"] as Dictionary)["shape"]),
		EReaderCards.SHAPE_SHORT, "data/ a short strip with no partner is still a card")
	_eq(str((by_key["Tom Nook (USA)"] as Dictionary)["shape"]),
		EReaderCards.SHAPE_BROKEN, "data/ a truncated strip is broken")
	_eq(str((by_key["Orphan (USA)"] as Dictionary)["shape"]),
		EReaderCards.SHAPE_BROKEN, "data/ a lone numbered strip is broken")

	# The edge table. Nothing downstream can re-derive this.
	var hoppip: Dictionary = by_key["Hoppip (USA)"]
	var strips: Array = hoppip["strips"]
	_eq(str(strips[0]["kind"]), EReaderCards.KIND_LONG, "data/ long strip is first")
	_eq(str(strips[0]["edge"]), EReaderCards.EDGE_SIDE, "data/ the long strip is on the side")
	_eq(str(strips[1]["kind"]), EReaderCards.KIND_SHORT, "data/ short strip is second")
	_eq(str(strips[1]["edge"]), EReaderCards.EDGE_BOTTOM, "data/ the short strip is on the bottom")
	_check(bool(hoppip["portrait"]), "data/ a long+short card is a portrait TCG card")
	_check(not bool((by_key["Mario Party-e (USA)"] as Dictionary)["portrait"]),
		"data/ a single-long card is landscape")

	# strip_for is the whole point: which strip a presented edge reads.
	_eq(EReaderCards.strip_for(hoppip, EReaderCards.EDGE_SIDE, true), 0,
		"data/ presenting the side edge reads the long strip")
	_eq(EReaderCards.strip_for(hoppip, EReaderCards.EDGE_BOTTOM, true), 1,
		"data/ presenting the bottom edge reads the short strip")
	_eq(EReaderCards.strip_for(hoppip, EReaderCards.EDGE_TOP, true), -1,
		"data/ presenting an uncoded edge reads nothing")
	_eq(EReaderCards.strip_for(hoppip, EReaderCards.EDGE_SIDE_FAR, true), -1,
		"data/ presenting the far side reads nothing")
	_eq(EReaderCards.strip_for(hoppip, EReaderCards.EDGE_SIDE, false), -1,
		"data/ a card swiped face-down reads nothing")
	_eq(EReaderCards.strip_for(by_key["Tom Nook (USA)"], EReaderCards.EDGE_BOTTOM, true), -1,
		"data/ a broken card reads nothing")

	var two_long: Dictionary = by_key["Boy 1 (USA)"]
	_eq(EReaderCards.strip_for(two_long, EReaderCards.EDGE_BOTTOM, true), 0,
		"data/ two-long: bottom edge is strip 1")
	_eq(EReaderCards.strip_for(two_long, EReaderCards.EDGE_TOP, true), 1,
		"data/ two-long: top edge is strip 2")
	_eq(EReaderCards.coded_edges(two_long).size(), 2, "data/ a two-strip card has two coded edges")
	_eq(EReaderCards.coded_edges(by_key["Tom Nook (USA)"]).size(), 0,
		"data/ a broken card has no coded edges")

	# EDGES and the card's dimensions are authored in separate files, and nothing
	# above relates them: every case so far would pass with the TCG card's width
	# and height swapped, which would read a 2912-byte strip off a 63 mm edge.
	var shape_kinds := {
		EReaderCards.SHAPE_LONG: [EReaderCards.KIND_LONG],
		EReaderCards.SHAPE_SHORT: [EReaderCards.KIND_SHORT],
		EReaderCards.SHAPE_LONG_SHORT: [EReaderCards.KIND_LONG, EReaderCards.KIND_SHORT],
		EReaderCards.SHAPE_TWO_LONG: [EReaderCards.KIND_LONG, EReaderCards.KIND_LONG],
	}
	for shape: String in EReaderCards.EDGES:
		var kinds: Array = shape_kinds[shape]
		var portrait: bool = shape == EReaderCards.SHAPE_LONG_SHORT or shape == EReaderCards.SHAPE_SHORT
		var csize := MediaDimensions.ereader_card_size(portrait)
		var shape_edges: Array = EReaderCards.EDGES[shape]
		for i in shape_edges.size():
			var edge := str(shape_edges[i])
			var horizontal: bool = edge == EReaderCards.EDGE_BOTTOM or edge == EReaderCards.EDGE_TOP
			var span: float = csize.x if horizontal else csize.y
			var other: float = csize.y if horizontal else csize.x
			if str(kinds[i]) == EReaderCards.KIND_LONG:
				_check(span > other, "data/ %s: the long strip is on the card's longer edge" % shape)
			else:
				_check(span < other, "data/ %s: the short strip is on the card's shorter edge" % shape)

	# Sizes, against what GBACartEReaderScan actually decodes.
	_check(EReaderCards.is_scannable_size(1872), "data/ 1872 is a short strip")
	_check(EReaderCards.is_scannable_size(2912), "data/ 2912 is a long strip")
	_check(not EReaderCards.is_scannable_size(2911), "data/ 2911 is not scannable")
	_check(not EReaderCards.is_scannable_size(0), "data/ an empty file is not scannable")
	_eq(EReaderCards.kind_of_size(2912), EReaderCards.KIND_LONG, "data/ 2912 is KIND_LONG")
	_eq(EReaderCards.kind_of_size(1872), EReaderCards.KIND_SHORT, "data/ 1872 is KIND_SHORT")
	_eq(EReaderCards.kind_of_size(2076), "", "data/ an accepted size that is not a strip has no kind")

	# split_suffix, since the grouping stands on it.
	_eq(str(EReaderCards.split_suffix("A (Long Strip)")["base"]), "A", "data/ splits (Long Strip)")
	_eq(str(EReaderCards.split_suffix("A (Short Strip)")["base"]), "A", "data/ splits (Short Strip)")
	_eq(str(EReaderCards.split_suffix("A (Strip 2)")["base"]), "A", "data/ splits (Strip 2)")
	_eq(int(EReaderCards.split_suffix("A (Strip 2)")["order"]), 1, "data/ Strip 2 sorts second")
	_eq(str(EReaderCards.split_suffix("Air Hockey-e (USA) (Promo)")["base"]),
		"Air Hockey-e (USA) (Promo)", "data/ a trailing paren that is not a strip is kept")


# ── geom/ ────────────────────────────────────────────────────────────────────

func _group_geom() -> void:
	var slit := Transform3D.IDENTITY
	var size := MediaDimensions.CARD_SIZE_EREADER_TCG
	var half_h := size.y * 0.5
	var half_w := size.x * 0.5

	# A card standing upright, centre half a card above the groove: its BOTTOM
	# edge is the one in the groove.
	var upright := Transform3D(Basis.IDENTITY, Vector3(0.0, half_h, 0.0))
	_eq(CardSwipeSlit.presented_edge(upright, size, slit), EReaderCards.EDGE_BOTTOM,
		"geom/ an upright card presents its bottom edge")

	# Turned 180 degrees in plane, the TOP edge is down.
	var flipped := Transform3D(Basis(Vector3.BACK, PI), Vector3(0.0, half_h, 0.0))
	_eq(CardSwipeSlit.presented_edge(flipped, size, slit), EReaderCards.EDGE_TOP,
		"geom/ a card turned 180 in plane presents its top edge")

	# Turned a quarter so the -X edge is down: that is the SIDE edge, and now the
	# card's WIDTH is what stands up.
	var quarter := Transform3D(Basis(Vector3.BACK, PI * 0.5), Vector3(0.0, half_w, 0.0))
	_eq(CardSwipeSlit.presented_edge(quarter, size, slit), EReaderCards.EDGE_SIDE,
		"geom/ a quarter turn presents the side edge")
	var quarter_back := Transform3D(Basis(Vector3.BACK, -PI * 0.5), Vector3(0.0, half_w, 0.0))
	_eq(CardSwipeSlit.presented_edge(quarter_back, size, slit), EReaderCards.EDGE_SIDE_FAR,
		"geom/ the other quarter turn presents the far side")

	# Which edge is in the groove must not change as the card travels along it.
	var moved := Transform3D(Basis.IDENTITY, Vector3(0.04, half_h, 0.0))
	_eq(CardSwipeSlit.presented_edge(moved, size, slit), EReaderCards.EDGE_BOTTOM,
		"geom/ travelling along the groove does not change the presented edge")

	_check(CardSwipeSlit.is_face_up(upright, slit), "geom/ printed face towards the reader is face up")
	var face_down := Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, half_h, 0.0))
	_check(not CardSwipeSlit.is_face_up(face_down, slit), "geom/ turned over is face down")

	_check(is_equal_approx(CardSwipeSlit.travel_of(moved, slit), 0.04), "geom/ travel is measured along the groove")
	_check(is_zero_approx(CardSwipeSlit.travel_of(upright, slit)), "geom/ a centred card is at travel zero")

	_check(is_equal_approx(CardSwipeSlit.stand_half(EReaderCards.EDGE_BOTTOM, size), half_h),
		"geom/ a bottom-edge card stands by its height")
	_check(is_equal_approx(CardSwipeSlit.stand_half(EReaderCards.EDGE_SIDE, size), half_w),
		"geom/ a side-edge card stands by its width")

	# seated_basis is the orientation oracle: whatever edge was presented must end
	# up pointing DOWN into the groove, and the printed face towards the reader. A
	# blank slab looks identical either way round, so this is checked by where the
	# edge lands, not by eye.
	for edge: String in [EReaderCards.EDGE_BOTTOM, EReaderCards.EDGE_TOP,
			EReaderCards.EDGE_SIDE, EReaderCards.EDGE_SIDE_FAR]:
		var b := CardSwipeSlit.seated_basis(edge, true, slit)
		var stand := CardSwipeSlit.stand_half(edge, size)
		var seated := Transform3D(b, Vector3(0.0, stand, 0.0))
		_eq(CardSwipeSlit.presented_edge(seated, size, slit), edge,
			"geom/ seating %s keeps %s in the groove" % [edge, edge])
		_check(CardSwipeSlit.is_face_up(seated, slit),
			"geom/ seating %s face up stays face up" % edge)
		var b_down := CardSwipeSlit.seated_basis(edge, false, slit)
		var seated_down := Transform3D(b_down, Vector3(0.0, stand, 0.0))
		_eq(CardSwipeSlit.presented_edge(seated_down, size, slit), edge,
			"geom/ seating %s face down keeps %s in the groove" % [edge, edge])
		_check(not CardSwipeSlit.is_face_up(seated_down, slit),
			"geom/ seating %s face down stays face down" % edge)


# ── catalog/ ─────────────────────────────────────────────────────────────────

func _group_catalog() -> void:
	const ID := "ereader"
	_check(ExpansionCatalog.ROWS.has(ID), "catalog/ the e-Reader has a row")
	_eq(ExpansionCatalog.host_of(ID), "game_boy_advance", "catalog/ it bolts to a GBA")
	_eq(ExpansionCatalog.media_of(ID), "ereader", "catalog/ its media is the card")
	_eq(ExpansionCatalog.loader_of(ID), MediaDimensions.LOADER_SWIPE, "catalog/ it is a swipe loader")
	_eq(ExpansionCatalog.mount_of(ID), ExpansionCatalog.MOUNT_CARTRIDGE, "catalog/ it is a cartridge")

	# The unit id is the media systemid, which is what makes the e-Reader tile its
	# own card. With them apart, items_for falls through to the generic console
	# path and the tile offers a Primitive System, a pad and a composite lead.
	_check(ExpansionCatalog.has_own_card(ID), "catalog/ the reader owns its card")

	# The card page filters its rows by extension, and "raw" is declared as a
	# SECONDARY extension on mGBA's entry -- the entry's own supported_extensions
	# is the GBA's. A page that asked the entry rather than the database saw no
	# extension a card could have and listed none of the 3217 on disk.
	_check("raw" in CoreInfoDatabase.extensions_for_systemid("ereader"),
		"catalog/ a dotcode strip is an extension the platform accepts")
	var entry_exts: Array[String] = []
	for entry: Dictionary in CoreInfoDatabase.shared().get_by_systemid("ereader"):
		for e: String in str(entry.get("supported_extensions", "")).split("|"):
			entry_exts.append(e.strip_edges().to_lower())
	_check("raw" not in entry_exts,
		"catalog/ and its core's own entry does not carry it")
	# Readers and nothing else on the tile -- whichever revisions are installed.
	var readers := ["expansion:ereader", "expansion:ereader_plus", "expansion:ereader_usa"]
	for item: Dictionary in SpawnCatalog.items_for(ID):
		_check(str(item.get("spawn", "")) in readers,
			"catalog/ its tile offers only readers, not %s" % str(item.get("label", "")))

	# One unit per reader revision, because a reader IS its dump: cards are
	# region-locked, and firmware_rom_path deliberately takes the FIRST name
	# rather than any that happens to be on disk. Naming all three as
	# alternatives on one row would gate correctly and then hand every player
	# the Japanese program.
	for rev: Array in [["ereader", "ereader.gba"], ["ereader_plus", "ereader_plus.gba"],
			["ereader_usa", "ereader_usa.gba"]]:
		var rid := str(rev[0])
		var dump := str(rev[1])
		_check(ExpansionCatalog.ROWS.has(rid), "catalog/ %s has a row" % rid)
		_eq(ExpansionCatalog.firmware_of(rid), [dump] as Array,
			"catalog/ %s wants %s and only that" % [rid, dump])
		_check(ExpansionCatalog.firmware_rom_path(rid).ends_with(dump),
			"catalog/ %s runs %s" % [rid, dump])
		_eq(ExpansionCatalog.media_of(rid), "ereader", "catalog/ %s reads the same cards" % rid)
		_eq(ExpansionCatalog.card_systemid(rid), "ereader",
			"catalog/ %s is offered from the e-Reader tile" % rid)
		_eq(str(ExpansionCatalog.boot_for("game_boy_advance", [rid]).get("core", "")), "mgba",
			"catalog/ %s boots on mgba" % rid)

	# A dump in the GBA library IS the reader, recognised by the game code at 0xAC
	# the same way a Super Game Boy dump is recognised by its header title. Built
	# here rather than read off disk so the case runs on a machine with no dumps.
	for rev: Array in [["PEAJ", "ereader"], ["PSAJ", "ereader_plus"], ["PSAE", "ereader_usa"]]:
		var made := _fake_gba(str(rev[0]), 0x96)
		_eq(ExpansionCatalog.adapter_for_rom(made), str(rev[1]),
			"catalog/ a %s dump spawns %s" % [str(rev[0]), str(rev[1])])
		DirAccess.remove_absolute(made)

	# An ordinary GBA game is still a cartridge, and the 0x96 at 0xB2 is what
	# stops four bytes of some other machine's dump reading as a game code.
	var plain := _fake_gba("AGBJ", 0x96)
	_eq(ExpansionCatalog.adapter_for_rom(plain), "", "catalog/ an ordinary GBA dump is not a reader")
	DirAccess.remove_absolute(plain)
	var not_gba := _fake_gba("PSAE", 0x00)
	_eq(ExpansionCatalog.adapter_for_rom(not_gba), "",
		"catalog/ and a file without a GBA header is not one either")
	DirAccess.remove_absolute(not_gba)

	# And the two later revisions have no tile of their own: three tiles over one
	# shelf of cards would be two empty libraries.
	for rid: String in ["ereader_plus", "ereader_usa"]:
		_check(not ExpansionCatalog.has_own_card(rid),
			"catalog/ %s does not claim a card of its own" % rid)
		_check(ExpansionCatalog.ids_carded_on("ereader").has(rid),
			"catalog/ %s is carded on the e-Reader" % rid)

	# LOADER_SWIPE must be its own value: sharing one with LOADER_NONE would build
	# the well bay this unit must not have.
	_check(MediaDimensions.LOADER_SWIPE != MediaDimensions.LOADER_NONE
		and MediaDimensions.LOADER_SWIPE != MediaDimensions.LOADER_SLOT
		and MediaDimensions.LOADER_SWIPE != MediaDimensions.LOADER_TRAY,
		"catalog/ LOADER_SWIPE is distinct from every other loader")

	var boot := ExpansionCatalog.boot_for("game_boy_advance", [ID])
	_eq(str(boot.get("core", "")), "mgba", "catalog/ it boots on mgba")
	_check(not boot.has("subsystem"),
		"catalog/ no subsystem — mgba's retro_load_game_special is a stub")

	_eq(ExpansionCatalog.firmware_of(ID), ["ereader.gba"] as Array,
		"catalog/ it wants the e-Reader cartridge dump")
	_check(ExpansionCatalog.firmware_rom_path(ID).ends_with("ereader.gba"),
		"catalog/ its own program comes from the firmware dir")

	# The card systemid is where the unit is offered, and it must be the media's.
	_eq(ExpansionCatalog.card_systemid(ID), "ereader", "catalog/ it is carded on the e-Reader tile")
	_check(SystemIcons.has_icon("ereader"), "catalog/ the e-Reader tile has its own art")
	_check(SystemIcons.has_content_icon("ereader"), "catalog/ the card has its own art")


## A file with a Game Boy Advance header and nothing else: the four-character
## game code at 0xAC and the fixed byte at 0xB2. Returned as an absolute path.
func _fake_gba(code: String, fixed: int) -> String:
	var path := OS.get_user_data_dir().path_join("__ereader_%s_%d.gba" % [code, fixed])
	var f := FileAccess.open(path, FileAccess.WRITE)
	var bytes := PackedByteArray()
	bytes.resize(0x100)
	for i in range(4):
		bytes[0xAC + i] = code.unicode_at(i)
	bytes[0xB2] = fixed
	f.store_buffer(bytes)
	f.close()
	return path


# ── swipe/ ───────────────────────────────────────────────────────────────────

## A card double: a real body a real Area3D detects, reporting only what comes
## from elsewhere in production — whether a hand has it, and what card it is.
class CardDouble:
	extends RigidBody3D

	var card_data: Dictionary = {}
	var held: bool = true
	var card_size: Vector3 = MediaDimensions.CARD_SIZE_EREADER_TCG

	func is_picked_up() -> bool:
		return held

	func get_card_data() -> Dictionary:
		return card_data

	func get_card_size() -> Vector3:
		return card_size


func _make_slit() -> CardSwipeSlit:
	var slit := CardSwipeSlit.new()
	slit.travel = 0.10
	slit.snap_time = 0.0
	# The layers the ROOM uses, not layer 1. Forcing both sides onto 1 made these
	# cases pass while the real groove detected nothing: a unit-built slit set no
	# mask at all, so it never saw a cartridge on layer 3.
	slit.collision_mask = 0b0000_0000_0000_0001_0000_0000_0000_0100
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.10, 0.05, 0.02)
	shape.shape = box
	slit.add_child(shape)
	add_child(slit)
	return slit


func _make_card(data: Dictionary) -> CardDouble:
	var card := CardDouble.new()
	card.card_data = data
	# Kinematic, the freeze mode a held XRToolsPickable actually runs at: a
	# STATIC-frozen body does not report itself moving to an Area3D's broadphase.
	card.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	card.freeze = true
	card.gravity_scale = 0.0
	card.collision_layer = 0b100
	card.add_to_group("cartridge")
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = card.card_size
	shape.shape = box
	card.add_child(shape)
	add_child(card)
	return card


## Drive a card along the groove from `from` to `to`, the way a hand would.
func _drag(card: CardDouble, slit: CardSwipeSlit, from: float, to: float,
		steps: int, stand: float) -> void:
	for i in range(steps + 1):
		var t: float = lerpf(from, to, float(i) / float(steps))
		card.global_transform = Transform3D(
			card.global_transform.basis, slit.global_transform * Vector3(t, stand, 0.0))
		await get_tree().physics_frame



func _group_swipe() -> void:
	var long_short := EReaderCards.group([
		_f("Hoppip (USA) (Long Strip)", EReaderCards.SIZE_LONG),
		_f("Hoppip (USA) (Short Strip)", EReaderCards.SIZE_SHORT),
	])[0]
	var stand: float = MediaDimensions.CARD_SIZE_EREADER_TCG.y * 0.5

	# A full pass with the BOTTOM edge in the groove reads the short strip.
	var slit := _make_slit()
	var card := _make_card(long_short)
	_reset_signals()
	slit.swiped.connect(_on_swiped)
	slit.aborted.connect(_on_aborted)
	slit.body_entered.connect(_on_entered)
	card.global_transform = Transform3D(Basis.IDENTITY,
		slit.global_transform * Vector3(-0.05, stand, 0.0))
	await _wait(2)
	await _drag(card, slit, -0.05, 0.05, 12, stand)
	await _wait(2)
	_check(_entered > 0, "swipe/ the groove detects the card")
	_eq(_swipes, 1, "swipe/ a full pass reads exactly once")
	_eq(_swipe_edge, EReaderCards.EDGE_BOTTOM, "swipe/ it reports the edge in the groove")
	_eq(_swipe_strip, 1, "swipe/ the bottom edge reads the short strip")
	_eq(_aborts, 0, "swipe/ a full pass does not also abort")
	card.queue_free()
	slit.queue_free()
	await _wait(2)

	# The SIDE edge in the groove reads the long strip instead. Same card, same
	# groove; only the way it is held differs.
	slit = _make_slit()
	card = _make_card(long_short)
	_reset_signals()
	slit.swiped.connect(_on_swiped)
	var side_stand: float = MediaDimensions.CARD_SIZE_EREADER_TCG.x * 0.5
	card.global_transform = Transform3D(Basis(Vector3.BACK, PI * 0.5),
		slit.global_transform * Vector3(-0.05, side_stand, 0.0))
	await _wait(2)
	await _drag(card, slit, -0.05, 0.05, 12, side_stand)
	await _wait(2)
	_eq(_swipe_edge, EReaderCards.EDGE_SIDE, "swipe/ a quarter turn presents the side edge")
	_eq(_swipe_strip, 0, "swipe/ the side edge reads the long strip")
	card.queue_free()
	slit.queue_free()
	await _wait(2)

	# Backing out the way it came in reads nothing.
	slit = _make_slit()
	card = _make_card(long_short)
	_reset_signals()
	slit.swiped.connect(_on_swiped)
	slit.aborted.connect(_on_aborted)
	card.global_transform = Transform3D(Basis.IDENTITY,
		slit.global_transform * Vector3(-0.05, stand, 0.0))
	await _wait(2)
	await _drag(card, slit, -0.05, -0.015, 6, stand)
	await _drag(card, slit, -0.015, -0.05, 6, stand)
	await _wait(2)
	_eq(_swipes, 0, "swipe/ a pass backed out reads nothing")
	_check(_aborts >= 1, "swipe/ a pass backed out aborts")
	card.queue_free()
	slit.queue_free()
	await _wait(2)

	# A card nobody is holding does not scan by falling through.
	slit = _make_slit()
	card = _make_card(long_short)
	card.held = false
	_reset_signals()
	slit.swiped.connect(_on_swiped)
	card.global_transform = Transform3D(Basis.IDENTITY,
		slit.global_transform * Vector3(-0.05, stand, 0.0))
	await _wait(2)
	await _drag(card, slit, -0.05, 0.05, 12, stand)
	await _wait(2)
	_eq(_swipes, 0, "swipe/ an unheld card does not scan")
	card.queue_free()
	slit.queue_free()
	await _wait(2)

	# Face-down completes the pass and reads nothing: a dotcode is printed on one
	# side, so the card has to be the right way up.
	slit = _make_slit()
	card = _make_card(long_short)
	_reset_signals()
	slit.swiped.connect(_on_swiped)
	card.global_transform = Transform3D(Basis(Vector3.UP, PI),
		slit.global_transform * Vector3(-0.05, stand, 0.0))
	await _wait(2)
	await _drag(card, slit, -0.05, 0.05, 12, stand)
	await _wait(2)
	_eq(_swipes, 1, "swipe/ a face-down pass still completes")
	_eq(_swipe_strip, -1, "swipe/ a card swiped face-down reads nothing")
	card.queue_free()
	slit.queue_free()
	await _wait(2)

	# The unit builds a groove and NO snap zone: one would grab the card mid-pass.
	var unit := preload("res://Scenes/Objects/expansion.tscn").instantiate() as RetroExpansion
	unit.expansion_id = "ereader"
	add_child(unit)
	await _wait(30)
	var zones := 0
	var grooves := 0
	for child in unit.get_children():
		if child is XRToolsSnapZone:
			zones += 1
		if child is CardSwipeSlit:
			grooves += 1
	_eq(zones, 0, "swipe/ a swipe unit builds no snap zone")
	_eq(grooves, 1, "swipe/ a swipe unit builds one groove")
	unit.queue_free()
	await _wait(2)


# ── library/ ─────────────────────────────────────────────────────────────────

## A scratch folder of real files, because the scan reads sizes off disk. Named
## like romm_tests' own so it is obvious what left it behind if a run dies.
const SELFTEST_DIR := "__ereader_selftest"


func _write_strip(dir: String, name: String, size: int) -> String:
	var path := dir.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return ""
	var buf := PackedByteArray()
	buf.resize(size)
	f.store_buffer(buf)
	f.close()
	return path


func _group_library() -> void:
	var dir := RomLibrary.default_roms_root().path_join(SELFTEST_DIR)
	DirAccess.make_dir_recursive_absolute(dir)

	var long_a := _write_strip(dir, "Hoppip (USA) (Long Strip).raw", EReaderCards.SIZE_LONG)
	var short_a := _write_strip(dir, "Hoppip (USA) (Short Strip).raw", EReaderCards.SIZE_SHORT)
	var solo := _write_strip(dir, "Mario Party-e (USA).raw", EReaderCards.SIZE_LONG)
	var bad := _write_strip(dir, "Tom Nook (USA).raw", 2911)
	EReaderCards.invalidate()

	var cards := EReaderCards.cards(dir)
	_eq(cards.size(), 3, "library/ four files scan back as three cards")

	# The path a card object carries finds the whole card again, which is what
	# lets a restore work with nothing extra saved.
	var from_long := EReaderCards.card_for_path(long_a, dir)
	_eq(str(from_long.get("key", "")), "Hoppip (USA)", "library/ the long strip finds its card")
	var from_short := EReaderCards.card_for_path(short_a, dir)
	_eq(str(from_short.get("key", "")), "Hoppip (USA)", "library/ the short strip finds the SAME card")
	_eq(str(from_short.get("shape", "")), EReaderCards.SHAPE_LONG_SHORT,
		"library/ and it is the long+short shape")
	_check(EReaderCards.card_for_path(dir.path_join("nothing.raw"), dir).is_empty(),
		"library/ a path not in the library finds no card")

	# Sizing follows the card's shape, not the systemid: both are "ereader".
	_check(MediaDimensions.ereader_card_size(true) == MediaDimensions.CARD_SIZE_EREADER_TCG,
		"library/ a portrait card is TCG sized")
	_check(MediaDimensions.ereader_card_size(false) == MediaDimensions.CARD_SIZE_EREADER,
		"library/ a landscape card is e-Reader sized")
	_check(MediaDimensions.CARD_SIZE_EREADER_TCG.y > MediaDimensions.CARD_SIZE_EREADER_TCG.x,
		"library/ the TCG card is taller than it is wide")
	_check(MediaDimensions.CARD_SIZE_EREADER.x > MediaDimensions.CARD_SIZE_EREADER.y,
		"library/ the e-Reader card is wider than it is tall")

	_check(bool(EReaderCards.card_for_path(solo, dir).get("portrait", true)) == false,
		"library/ a single-long card is not portrait")

	# The broken dump is grouped, so it can be reported, but must never be spawned.
	var broken := EReaderCards.card_for_path(bad, dir)
	_eq(str(broken.get("shape", "")), EReaderCards.SHAPE_BROKEN,
		"library/ a wrong-length strip groups as broken")

	for p in [long_a, short_a, solo, bad]:
		if not p.is_empty():
			DirAccess.remove_absolute(p)
	DirAccess.remove_absolute(dir)
	EReaderCards.invalidate()

	# A card object resolves against the CANONICAL library folder, because that
	# is the one path it carries and the only place production looks. Testing it
	# anywhere else would prove a lookup the room never performs, so the fixture
	# goes where the real cards live and is taken away again.
	var real_dir := RomLibrary.rom_dir_for_system(EReaderCards.SYSTEMID)
	DirAccess.make_dir_recursive_absolute(real_dir)
	var fix_long := _write_strip(real_dir, "__selftest Hoppip (Long Strip).raw", EReaderCards.SIZE_LONG)
	var fix_short := _write_strip(real_dir, "__selftest Hoppip (Short Strip).raw", EReaderCards.SIZE_SHORT)
	EReaderCards.invalidate()

	var cart := preload("res://Scenes/Objects/media/cartridge.tscn").instantiate() as RetroCartridge
	cart.systemid = EReaderCards.SYSTEMID
	cart.rom_path = fix_long
	add_child(cart)
	_eq(str(cart.get_card_data().get("key", "")), "__selftest Hoppip",
		"library/ a card object finds its card from rom_path alone")
	_eq(str(cart.get_card_data().get("shape", "")), EReaderCards.SHAPE_LONG_SHORT,
		"library/ and it sees both of its strips")
	_check(cart.get_card_size() == MediaDimensions.CARD_SIZE_EREADER_TCG,
		"library/ a long+short card is sized as a portrait TCG card")
	cart.systemid = "nes"
	_check(cart.get_card_data().is_empty(),
		"library/ an ordinary cartridge is not a card")
	cart.queue_free()

	# scan_roms must offer the CARD once, not each strip.
	var rows := RomLibrary.scan_roms(EReaderCards.SYSTEMID, [] as Array[String])
	var mine := 0
	for r: Dictionary in rows:
		if str(r["label"]).begins_with("__selftest"):
			mine += 1
	_eq(mine, 1, "library/ scan_roms lists a two-strip card once")

	for p in [fix_long, fix_short]:
		if not p.is_empty():
			DirAccess.remove_absolute(p)
	EReaderCards.invalidate()
