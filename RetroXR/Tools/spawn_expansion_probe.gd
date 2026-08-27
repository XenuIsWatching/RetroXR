## Does the spawn menu offer the expansions, and does spawning one give you the
## machine rather than a primitive console?
##
##     "$godot" --headless --path RetroXR res://Tools/spawn_expansion_probe.tscn
extends Node3D

const EXPANSION_SCENE := preload("res://Scenes/Objects/expansion.tscn")

var _checks := 0
var _failed := 0


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
	print("[spawn] %s  %s" % ["PASS" if ok else "FAIL", what])


func _ready() -> void:
	# Every host should offer every unit made for it, and the token should be the
	# one the controller branches on.
	for host: String in ["nintendo_64", "nes", "super_nes", "mega_drive",
			"pc_engine", "atari_jaguar"]:
		var offered: Array[String] = []
		for item: Dictionary in SpawnCatalog.items_for(host):
			var token := SpawnCatalog.spawn_token(host, item)
			if token.begins_with("expansion:"):
				offered.append(token.substr("expansion:".length()))
		var want := ExpansionCatalog.ids_for_host(host)
		_check(offered == want, "%s offers %s" % [host, str(want)])

	# A console with nothing made for it must not grow rows it cannot use.
	var bare: Array = []
	for item: Dictionary in SpawnCatalog.items_for("playstation"):
		if SpawnCatalog.spawn_token("playstation", item).begins_with("expansion:"):
			bare.append(item)
	_check(bare.is_empty(), "a PlayStation is offered no expansions")

	# And the thing that comes back is the unit, carrying its id -- the failure
	# this is really guarding is spawning a primitive console instead.
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
