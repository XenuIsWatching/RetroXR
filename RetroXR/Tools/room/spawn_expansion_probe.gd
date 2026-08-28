## Where does the spawn menu offer an expansion, and does pressing it give you
## the machine rather than a primitive console?
##
## The bug this guards: nearly every unit is ALSO a systemid, so it already had a
## tile in the systems list -- and that tile opened on "Primitive System", which
## spawned an imaginary "Nintendo 64DD console". The unit belongs on its own
## tile; the host's card must not list it a second time.
##
##     "$godot" --headless --path RetroXR res://Tools/room/spawn_expansion_probe.tscn
extends Node3D

const EXPANSION_SCENE := preload("res://Scenes/Objects/expansion.tscn")

var _checks := 0
var _failed := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
	print("[spawn] %s  %s" % ["PASS" if ok else "FAIL", what])


## The expansion tokens a card offers, in order.
func _units_on(systemid: String) -> Array[String]:
	var out: Array[String] = []
	for item: Dictionary in SpawnCatalog.items_for(systemid):
		var token := SpawnCatalog.spawn_token(systemid, item)
		if token.begins_with("expansion:"):
			out.append(token.substr("expansion:".length()))
	return out


func _ready() -> void:
	# 1. A unit with a card of its own IS that card, and is the whole of it.
	for id: String in ExpansionCatalog.ROWS:
		if not ExpansionCatalog.has_own_card(id):
			continue
		var items: Array = SpawnCatalog.items_for(id)
		var want: Array[String] = [id]
		_check(items.size() == 1 and _units_on(id) == want,
			"the %s card offers the unit and nothing else" % id)

	# 2. ...and no card anywhere still offers the primitive box for one, which is
	# the actual reported symptom.
	for id: String in ExpansionCatalog.ROWS:
		if not ExpansionCatalog.has_own_card(id):
			continue
		var primitive := false
		for item: Dictionary in SpawnCatalog.items_for(id):
			if str(item.get("model_id", "")) == SystemModelRegistry.PLACEHOLDER_ID:
				primitive = true
		_check(not primitive, "the %s card no longer spawns a primitive system" % id)

	# 3. The host's card must not list a unit that has a tile -- that is the
	# duplication the tile placement is meant to remove.
	for host: String in ["nintendo_64", "nes", "super_nes", "mega_drive", "pc_engine"]:
		_check(_units_on(host).is_empty(),
			"the %s card lists no unit that has its own tile" % host)

	# 4. But a unit with NO tile has nowhere else to go, so the console keeps it.
	# The Jaguar CD runs the Jaguar's own media and names no systemid of its own.
	var jag: Array[String] = ["jaguar_cd"]
	_check(_units_on("atari_jaguar") == jag,
		"the Atari Jaguar card still offers the Jaguar CD, which has no tile")
	_check(not ExpansionCatalog.has_own_card("jaguar_cd"),
		"...because that is exactly the unit with no card of its own")

	# 5. Every unit is reachable from exactly one card. This is the invariant the
	# two rules above exist to hold, so it is worth asserting directly rather
	# than trusting that they compose.
	var hosts: Array[String] = []
	for id: String in ExpansionCatalog.ROWS:
		var h := ExpansionCatalog.host_of(id)
		if not hosts.has(h):
			hosts.append(h)
	for id: String in ExpansionCatalog.ROWS:
		var seen := 0
		for card: String in hosts + ExpansionCatalog.ROWS.keys():
			if _units_on(card).has(id):
				seen += 1
		_check(seen == 1, "%s is reachable from exactly one card (%d)" % [id, seen])

	# 6. A console with nothing made for it must not grow rows it cannot use.
	_check(_units_on("playstation").is_empty(), "a PlayStation is offered no expansions")

	# 7. And the thing that comes back is the unit, carrying its id -- the
	# failure this is really guarding is spawning a primitive console instead.
	var unit := EXPANSION_SCENE.instantiate() as RetroExpansion
	unit.expansion_id = "sega_cd"
	add_child(unit)
	await get_tree().process_frame
	# `unit is RetroSystem` will not even compile -- the two types are unrelated,
	# which is the strongest form the "not a primitive console" check can take.
	_check(unit.expansion_id == "sega_cd", "a spawned unit carries the id it was asked for")
	_check(unit.get_socket() != null, "and has built its own socket, so it is the real unit")

	print("[spawn] %d checks, %d failed" % [_checks, _failed])
	print("[spawn] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)
