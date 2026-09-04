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
	if _want("program"):
		_group_program()
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
	_eq(str(((by_key["Mario Party-e (USA)"] as Dictionary)["strips"][0] as Dictionary)["edge"]),
		EReaderCards.EDGE_SIDE, "data/ a single long strip is on a side edge too")

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
	_eq(EReaderCards.strip_for(two_long, EReaderCards.EDGE_SIDE, true), 0,
		"data/ two-long: the near side edge is strip 1")
	_eq(EReaderCards.strip_for(two_long, EReaderCards.EDGE_SIDE_FAR, true), 1,
		"data/ two-long: the far side edge is strip 2")
	_eq(EReaderCards.strip_for(two_long, EReaderCards.EDGE_BOTTOM, true), -1,
		"data/ two-long: and its short edges carry nothing")
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
		var csize := MediaDimensions.CARD_SIZE_EREADER
		var shape_edges: Array = EReaderCards.EDGES[shape]
		_eq(shape_edges.size(), kinds.size(), "data/ %s: every strip has an edge" % shape)
		for i in shape_edges.size():
			var edge := str(shape_edges[i])
			var horizontal: bool = edge == EReaderCards.EDGE_BOTTOM or edge == EReaderCards.EDGE_TOP
			var span: float = csize.x if horizontal else csize.y
			var other: float = csize.y if horizontal else csize.x
			if str(kinds[i]) == EReaderCards.KIND_LONG:
				_check(span > other, "data/ %s: the long strip is on the card's longer edge" % shape)
			else:
				_check(span < other, "data/ %s: the short strip is on the card's shorter edge" % shape)
		# Two strips never share an edge, or the second is unreachable.
		var seen: Dictionary = {}
		for e: Variant in shape_edges:
			seen[str(e)] = true
		_eq(seen.size(), shape_edges.size(), "data/ %s: its strips are on different edges" % shape)

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
	var size := MediaDimensions.CARD_SIZE_EREADER
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

	# The scanner looks along the unit's -Z, so a card reads with its art towards
	# the player -- the same side the reader wears its name on.
	var face_up := Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, half_h, 0.0))
	_check(CardSwipeSlit.is_face_up(face_up, slit),
		"geom/ art towards the player is face up")
	_check(not CardSwipeSlit.is_face_up(upright, slit),
		"geom/ art turned away from the player is face down")

	# A card is PRESENTED before it is read, and the Area3D fires long before
	# that: a hand carrying a card in flat over the roof trips it while offering
	# nothing. Latching there picked an edge off a pose the player never chose --
	# measured, a card held flat a millimetre above the groove answers "side",
	# and the same card turned in its own plane answers "bottom".
	var flat := Transform3D(Basis(Vector3.RIGHT, PI * 0.5), slit * Vector3(0.0, 0.001, 0.0))
	_check(not CardSwipeSlit.is_presenting(flat, size, slit),
		"geom/ a card carried in flat is not presenting")
	var flat_turned := Transform3D(Basis(Vector3.RIGHT, PI * 0.5) * Basis(Vector3.BACK, PI * 0.5),
		slit * Vector3(0.0, 0.001, 0.0))
	_check(not CardSwipeSlit.is_presenting(flat_turned, size, slit),
		"geom/ nor is the same card turned in its own plane")

	# Nearness is the card's CORNER, not an edge midpoint, so a card resting on
	# the groove counts however it is turned.
	_check(is_zero_approx(CardSwipeSlit.corner_distance(_offered(45.0, size), size, slit)),
		"geom/ a tilted card resting on the groove is at zero distance")
	_check(CardSwipeSlit.corner_distance(_offered(45.0, size), size, slit)
			< CardSwipeSlit.edge_depths(_offered(45.0, size), size, slit)[EReaderCards.EDGE_BOTTOM],
		"geom/ and its nearest midpoint sits higher than its corner")

	# Which edge is going in is about how the card is TURNED, not where the hand
	# is holding it. The old rule scored an edge by its distance from the groove
	# line, which counts displacement in Z as well, so a card offered from a
	# little in front of or behind the slot could have its edge decided by the
	# hand's position. Depth along -Y is the slot's own direction and cannot.
	for mm: float in [0.0, 10.0, 20.0, 30.0]:
		var shifted := _offered(0.0, size)
		shifted.origin += Vector3(0.0, 0.0, mm / 1000.0)
		_eq(CardSwipeSlit.presented_edge(shifted, size, slit), EReaderCards.EDGE_BOTTOM,
			"geom/ an upright card %d mm to one side still offers its bottom edge" % int(mm))

	# The case only the flatness test catches: a flat card slid sideways until one
	# side edge lies along the line. Its opposite edge is then a whole card width
	# away, so the distance and margin tests are both satisfied by a card lying
	# face-down across the roof, offering nothing.
	var flat_offset := Transform3D(Basis(Vector3.RIGHT, PI * 0.5),
		slit * Vector3(0.0, 0.001, half_w))
	_check(not CardSwipeSlit.is_presenting(flat_offset, size, slit),
		"geom/ a flat card with one edge on the line is still not presenting")

	# Corner-first is a tie between two edges, and whichever the table listed
	# first would win it. It waits instead.
	# Lowered until its lowest corner is ON the line, so nearness cannot be what
	# rejects it -- only the gap between the two edges meeting at that corner can.
	# 55 degrees is where a 63 x 88 card is genuinely diagonal: measured, its two
	# nearest edge midpoints are 0.6 mm apart there.
	_check(not CardSwipeSlit.is_presenting(_offered(55.0, size), size, slit),
		"geom/ a card offered corner-first waits rather than guessing")

	# But an ordinary imperfect hand is not a diagonal, and must not be made to
	# wait. This is the case that was silently broken: nearness was measured to
	# the edge MIDPOINT, which climbs as the card tilts, so everything past about
	# 28 degrees was refused -- a 40-degree hole a hand falls into constantly.
	for deg: float in [10.0, 25.0, 40.0, 45.0]:
		var pose := _offered(deg, size)
		_check(CardSwipeSlit.is_presenting(pose, size, slit),
			"geom/ a card %d degrees off upright still presents" % int(deg))
		_eq(CardSwipeSlit.presented_edge(pose, size, slit), EReaderCards.EDGE_BOTTOM,
			"geom/ and at %d degrees it is still the bottom edge" % int(deg))
	for deg: float in [70.0, 90.0]:
		var pose := _offered(deg, size)
		_check(CardSwipeSlit.is_presenting(pose, size, slit),
			"geom/ a card %d degrees over presents too" % int(deg))
		_eq(CardSwipeSlit.presented_edge(pose, size, slit), EReaderCards.EDGE_SIDE,
			"geom/ and by %d degrees it is the side edge" % int(deg))

	# What a real presentation looks like: upright, edge on the line.
	var offered := Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, half_h, 0.0))
	_check(CardSwipeSlit.is_presenting(offered, size, slit),
		"geom/ an upright card with its edge on the groove is presenting")
	var offered_side := Transform3D(Basis(Vector3.UP, PI) * Basis(Vector3.BACK, PI * 0.5),
		Vector3(0.0, half_w, 0.0))
	_check(CardSwipeSlit.is_presenting(offered_side, size, slit),
		"geom/ and so is one offered side edge down")
	# Still inside the trigger box, but a whole card away from the line.
	var high := Transform3D(Basis(Vector3.UP, PI), Vector3(0.0, half_h + 0.02, 0.0))
	_check(not CardSwipeSlit.is_presenting(high, size, slit),
		"geom/ merely overlapping the groove is not presenting")

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

	# One unit per reader revision, because a reader IS its dump and the dumps are
	# not interchangeable: cards are region-locked.
	for rev: Array in [["ereader", "PEAJ"], ["ereader_plus", "PSAJ"],
			["ereader_usa", "PSAE"]]:
		var rid := str(rev[0])
		var code := str(rev[1])
		_check(ExpansionCatalog.ROWS.has(rid), "catalog/ %s has a row" % rid)
		_eq(str(ExpansionCatalog.ROWS[rid].get("rom_code", "")), code,
			"catalog/ %s is the %s dump" % [rid, code])
		# Its program is a LIBRARY file now, so the row names no firmware at all
		# and asks for no install. See ExpansionCatalog.firmware_rom_path.
		_eq(ExpansionCatalog.firmware_of(rid), [] as Array,
			"catalog/ %s names no firmware" % rid)
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

	# The battery is in the reader. Without an owner named here the unit is not a
	# cartridge with a save_id and has no bay, so every route in
	# _compose_sram_path answers "" and the core runs with no SRAM file at all --
	# blank flash every launch, and the cards it has taken gone with it.
	var seen_save: Dictionary = {}
	for rid: String in ["ereader", "ereader_plus", "ereader_usa"]:
		_eq(ExpansionCatalog.save_owner_of(rid), ExpansionCatalog.SAVE_OWNER_UNIT,
			"catalog/ %s owns its own flash" % rid)
		var save := SramPaths.unit_save_path("mgba", rid)
		_check(not save.is_empty(), "catalog/ %s resolves to a save file" % rid)
		seen_save[save] = true
	# One file each: the three are different hardware, and a + reader restored
	# from an original's flash is the calibration bug the fork already fixed.
	_eq(seen_save.size(), 3, "catalog/ each revision keeps a flash of its own")

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

	# The Super Game Boy still resolves through the core's system directory, and
	# must keep doing so: its dumps are declared in the VENDORED bsnes .info,
	# which there is no overlay to remove them from. The two adapters work
	# differently on purpose -- this case is here so nobody tidies one branch of
	# firmware_rom_path into the other.
	_eq(ExpansionCatalog.firmware_of("super_game_boy"), ["SGB1.sfc"] as Array,
		"catalog/ a Super Game Boy still names its firmware")
	_check(ExpansionCatalog.firmware_rom_path("super_game_boy").ends_with("SGB1.sfc"),
		"catalog/ and still runs it out of the system directory")

	# The card systemid is where the unit is offered, and it must be the media's.
	_eq(ExpansionCatalog.card_systemid(ID), "ereader", "catalog/ it is carded on the e-Reader tile")
	_check(SystemIcons.has_icon("ereader"), "catalog/ the e-Reader tile has its own art")
	_check(SystemIcons.has_content_icon("ereader"), "catalog/ the card has its own art")


## Write a fake GBA dump into a system's real ROM folder and hand back its path.
##
## The real folder, because AdapterRoms derives it from the systemid and there is
## nowhere else production would look. Named so a dead run is obvious.
func _plant_dump(systemid: String, name: String, code: String) -> String:
	var dir := RomLibrary.rom_dir_for_system(systemid)
	DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	var bytes := PackedByteArray()
	bytes.resize(0x100)
	for i in range(4):
		bytes[0xAC + i] = code.unicode_at(i)
	bytes[0xB2] = 0x96
	f.store_buffer(bytes)
	f.close()
	AdapterRoms.invalidate()
	return path


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


## A card held `deg` off upright in its own plane, lowered until its lowest
## corner rests on the groove line — what a hand does when it offers a card.
func _offered(deg: float, size: Vector3) -> Transform3D:
	var b := Basis(Vector3.UP, PI) * Basis(Vector3.BACK, deg_to_rad(deg))
	var lowest := INF
	for c: Vector3 in [Vector3(size.x, size.y, 0.0) * 0.5, Vector3(-size.x, size.y, 0.0) * 0.5,
			Vector3(size.x, -size.y, 0.0) * 0.5, Vector3(-size.x, -size.y, 0.0) * 0.5]:
		lowest = minf(lowest, (b * c).y)
	return Transform3D(b, Vector3(0.0, -lowest, 0.0))


# ── library dumps ─────────────────────────────────────────────────────────────

## The reader's program is an ordinary ROM on the Game Boy Advance shelf.
##
## Every case plants a real file in the real folder and takes it away again,
## because AdapterRoms derives both folders from the systemid and production
## looks nowhere else. Nothing here assumes the shelf is EMPTY: this machine has
## three real reader dumps on it, and a case that only passes on a bare library
## is a case that fails for the person most likely to run it.
func _group_program() -> void:
	const GBA := "game_boy_advance"
	const PLANTED := "__ereader_selftest PEAJ.gba"
	const ORDINARY := "__ereader_selftest ordinary.gba"

	var dump := _plant_dump(GBA, PLANTED, "PEAJ")
	var plain := _plant_dump(GBA, ORDINARY, "AGBJ")

	# Recognised by its header, and the ordinary ROM beside it is not.
	_check(AdapterRoms.is_adapter_rom(GBA, dump),
		"program/ a PEAJ dump on the GBA shelf is a reader")
	_check(not AdapterRoms.is_adapter_rom(GBA, plain),
		"program/ an ordinary GBA ROM is not")

	# The gate and the program both come off a file, with no install anywhere.
	_check(ExpansionCatalog.firmware_present("ereader"),
		"program/ a dump on the shelf makes the reader spawnable")
	var program := ExpansionCatalog.firmware_rom_path("ereader")
	_check(not program.is_empty(), "program/ and names a program to run")
	_eq(ExpansionCatalog.adapter_for_rom(program), "ereader",
		"program/ which is itself a Card e-Reader dump")
	_check(not program.contains("system"),
		"program/ out of the library, not the core's system directory")

	# The tile offers the reader it has a dump for -- the point of the gate.
	var offered := false
	for item: Dictionary in SpawnCatalog.items_for("ereader"):
		if str(item.get("spawn", "")) == "expansion:ereader":
			offered = true
	_check(offered, "program/ the e-Reader tile offers that reader")

	# A dump is HARDWARE and must not be listed as a game; the ordinary ROM
	# beside it must be, or the exclusion is just a broken scan.
	var listed: Dictionary = {}
	for r: Dictionary in RomLibrary.scan_roms(GBA, ["gba"] as Array[String]):
		listed[str(r["path"])] = true
	_check(not listed.has(dump), "program/ the dump is not offered as a game")
	_check(listed.has(plain), "program/ while the ordinary ROM beside it still is")

	# The probe is memoised. This is a promise about COST: scan_roms opens no
	# files at all without it, and it runs on the main thread every time a
	# platform is opened, over libraries of ten thousand entries.
	AdapterRoms.invalidate()
	RomLibrary.scan_roms(GBA, ["gba"] as Array[String])
	AdapterRoms.reset_probe_count()
	RomLibrary.scan_roms(GBA, ["gba"] as Array[String])
	RomLibrary.scan_roms(GBA, ["gba"] as Array[String])
	_eq(AdapterRoms.probe_count, 0, "program/ a cached scan opens no files at all")

	DirAccess.remove_absolute(dump)
	DirAccess.remove_absolute(plain)
	AdapterRoms.invalidate()

	# A dump filed beside the cards is found too, and is not a card: that folder
	# is grouped by EReaderCards, which only ever looks at .raw.
	var beside := _plant_dump(EReaderCards.SYSTEMID, PLANTED, "PEAJ")
	EReaderCards.invalidate()
	_eq(ExpansionCatalog.adapter_for_rom(ExpansionCatalog.firmware_rom_path("ereader")),
		"ereader", "program/ a dump filed with the cards still names a reader")
	var card_paths: Dictionary = {}
	for r: Dictionary in RomLibrary.scan_roms(EReaderCards.SYSTEMID, [] as Array[String]):
		card_paths[str(r["path"])] = true
	_check(not card_paths.has(beside), "program/ a dump filed with the cards is not a card")
	DirAccess.remove_absolute(beside)
	AdapterRoms.invalidate()
	EReaderCards.invalidate()


# ── swipe/ ───────────────────────────────────────────────────────────────────

## A card double: a real body a real Area3D detects, reporting only what comes
## from elsewhere in production — whether a hand has it, and what card it is.
class CardDouble:
	extends RigidBody3D

	var card_data: Dictionary = {}
	var held: bool = true
	var card_size: Vector3 = MediaDimensions.CARD_SIZE_EREADER

	func is_picked_up() -> bool:
		return held

	func get_card_data() -> Dictionary:
		return card_data

	func get_card_size() -> Vector3:
		return card_size


## The groove, cut into a body the way the real one is.
##
## Parented to a PhysicsBody3D on purpose: the slit exempts the card from
## colliding with its host for the length of a pass, and a slit hanging off a
## plain Node has no host to exempt it from -- which would make that case pass
## without exercising anything.
func _make_slit() -> CardSwipeSlit:
	var host := StaticBody3D.new()
	host.collision_layer = 0b100
	var host_shape := CollisionShape3D.new()
	var host_box := BoxShape3D.new()
	host_box.size = Vector3(0.10, 0.06, 0.03)
	host_shape.shape = host_box
	host.add_child(host_shape)
	add_child(host)
	_slit_host = host

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
	host.add_child(slit)
	return slit


## The host of the most recent _make_slit, for the collision-exception cases.
var _slit_host: StaticBody3D = null


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
	var stand: float = MediaDimensions.CARD_SIZE_EREADER.y * 0.5

	# A full pass with the BOTTOM edge in the groove reads the short strip.
	var slit := _make_slit()
	var card := _make_card(long_short)
	_reset_signals()
	slit.swiped.connect(_on_swiped)
	slit.aborted.connect(_on_aborted)
	slit.body_entered.connect(_on_entered)
	# Art towards the player, which is the side the scanner looks from. A half
	# turn about Y flips the face and leaves the bottom edge in the groove.
	card.global_transform = Transform3D(Basis(Vector3.UP, PI),
		slit.global_transform * Vector3(-0.05, stand, 0.0))
	await _wait(2)
	# Half the pass, then look: the card must be exempt from its host WHILE it is
	# being drawn through, which is when the two would otherwise fight.
	await _drag(card, slit, -0.05, 0.0, 6, stand)
	_check(card.get_collision_exceptions().has(_slit_host),
		"swipe/ mid-pass the card does not collide with the machine")
	await _drag(card, slit, 0.0, 0.05, 6, stand)
	await _wait(2)
	_check(_entered > 0, "swipe/ the groove detects the card")
	# While a pass is running the card must not be fighting the machine it is
	# being drawn through: they share a collision layer, and a card rides with its
	# edge ON the case, so the solver pushes it out on the same step this
	# constraint teleports it back. That is the jitter, and the exception is
	# lifted again by _finish -- a card that kept it would fall through the
	# machine for the rest of the session.
	_check(not card.get_collision_exceptions().has(_slit_host),
		"swipe/ the card and the machine collide again once the pass is over")
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
	var side_stand: float = MediaDimensions.CARD_SIZE_EREADER.x * 0.5
	card.global_transform = Transform3D(Basis(Vector3.UP, PI) * Basis(Vector3.BACK, PI * 0.5),
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
	card.global_transform = Transform3D(Basis.IDENTITY,
		slit.global_transform * Vector3(-0.05, stand, 0.0))
	await _wait(2)
	await _drag(card, slit, -0.05, 0.05, 12, stand)
	await _wait(2)
	_eq(_swipes, 1, "swipe/ a face-down pass still completes")
	_eq(_swipe_strip, -1, "swipe/ a card swiped face-down reads nothing")
	card.queue_free()
	slit.queue_free()
	await _wait(2)

	# A pass presented in the MIDDLE of the groove goes where the hand takes it.
	#
	# The direction used to be read off the card's position the instant it armed,
	# falling back to "the +X end" near the middle -- so a card offered mid-groove
	# was given a direction by a coin toss and judged to have backed out the
	# moment the hand pushed the other way. Snap in, abort, snap in again: the
	# flapping is what this case is here for.
	slit = _make_slit()
	card = _make_card(long_short)
	_reset_signals()
	slit.swiped.connect(_on_swiped)
	slit.aborted.connect(_on_aborted)
	card.global_transform = Transform3D(Basis(Vector3.UP, PI),
		slit.global_transform * Vector3(0.0, stand, 0.0))
	await _wait(2)
	# Out through the +X end, having started at zero — the direction the old code
	# called "backing out".
	await _drag(card, slit, 0.0, 0.05, 10, stand)
	await _wait(2)
	_eq(_aborts, 0, "swipe/ a pass from the middle does not abort as it moves off")
	_eq(_swipes, 1, "swipe/ and it completes when it leaves the far end")
	card.queue_free()
	slit.queue_free()
	await _wait(2)

	# And a pass that HAS ended does not start another while the card is still
	# standing in the groove: it would read the same strip again, every frame.
	slit = _make_slit()
	card = _make_card(long_short)
	_reset_signals()
	slit.swiped.connect(_on_swiped)
	card.global_transform = Transform3D(Basis(Vector3.UP, PI),
		slit.global_transform * Vector3(-0.05, stand, 0.0))
	await _wait(2)
	await _drag(card, slit, -0.05, 0.05, 12, stand)
	await _wait(20)
	_eq(_swipes, 1, "swipe/ one pass reads once, however long the card is left there")
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

	# The volume that WATCHES for a card has to be findable by a hand. Cut to the
	# card's own thickness it was 6.8 mm deep, so a card had to be within 3.4 mm
	# of the groove plane before the groove noticed it at all -- an invisible
	# tolerance, and it read as the slot ignoring the card. It can be sloppy now
	# that is_presenting, not entry, decides when a pass starts.
	var groove := unit.find_child("SwipeSlit", true, false) as CardSwipeSlit
	var card_size := MediaDimensions.CARD_SIZE_EREADER
	if groove != null:
		var gshape := groove.get_child(0) as CollisionShape3D
		var gbox := gshape.shape as BoxShape3D
		_check(gbox.size.z >= card_size.z * 10.0,
			"swipe/ the groove watches well clear of its own plane")
		_check(gbox.size.y >= card_size.y * 0.9,
			"swipe/ and up the height of a card")
		_check(gbox.size.x > unit.size().x,
			"swipe/ and past both ends, which a pass has to clear")
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

	# Every card is the same portrait trading card, whatever its strips are: the
	# size is a constant, and the shape says only which edges are coded.
	_check(MediaDimensions.CARD_SIZE_EREADER.y > MediaDimensions.CARD_SIZE_EREADER.x,
		"library/ a card is taller than it is wide")
	_check(MediaDimensions.cart_size("ereader", solo) == MediaDimensions.CARD_SIZE_EREADER,
		"library/ a single-long card is that size")
	_check(MediaDimensions.cart_size("ereader", long_a) == MediaDimensions.CARD_SIZE_EREADER,
		"library/ and so is a long+short one")

	# The strip summary a card's row shows under its title.
	_eq(EReaderCards.strip_summary(from_long), "L+S", "library/ a long+short card summarises as L+S")
	_eq(EReaderCards.strip_summary(EReaderCards.card_for_path(solo, dir)), "L",
		"library/ a single long card summarises as L")
	_eq(EReaderCards.strip_summary(EReaderCards.card_for_path(bad, dir)), "",
		"library/ a broken card summarises as nothing, since it cannot be swiped")

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
	_check(cart.get_card_size() == MediaDimensions.CARD_SIZE_EREADER,
		"library/ a long+short card is sized as a trading card")
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
