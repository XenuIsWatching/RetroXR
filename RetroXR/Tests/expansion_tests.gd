## Console-expansion self-tests — the 64DD under an N64, the Mega-CD under a Mega
## Drive, the 32X on top of it. Headless, no core, no ROM, no headset.
##
##     "$godot" --headless --path RetroXR res://Tests/expansion_tests.tscn
##     "$godot" --headless --path RetroXR res://Tests/expansion_tests.tscn -- --only=tower
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## These need REAL objects in the tree — snap zones, grab points, measured
## bodies — which is why they are here and not in system_tests.gd, whose whole
## method is building RetroSystem with .new() and never adding it.
##
## Groups:
##   fit/     which unit accepts which console, and refuses everything else
##   join/    bolting a console on and taking it off, from both sides
##   tower/   Mega Drive + Mega-CD + 32X, assembled in both directions
##   media/   the unit's own bay, and which media the assembled machine boots from
##   launch/  which core the combination resolves to, and its pinned options
extends Node

const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const EXPANSION_SCENE := preload("res://Scenes/Objects/expansion.tscn")
const CART_SCENE := preload("res://Scenes/Objects/media/cartridge.tscn")

var _checks := 0
var _failed := 0
var _only := ""
var _spawned: Array[Node] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.substr(7)
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[exp] TIMED OUT")
		get_tree().quit(1))
	await _run()
	print("[exp] %d checks, %d failed" % [_checks, _failed])
	print("[exp] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _wait(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _check(ok: bool, what: String) -> void:
	_checks += 1
	if not ok:
		_failed += 1
	print("[exp] %s  %s" % ["PASS" if ok else "FAIL", what])


func _want(group: String) -> bool:
	return _only.is_empty() or _only == group


# ── fixtures ──────────────────────────────────────────────────────────────────


## A console in the tree, on the plain box — every platform below has one, and
## the port is measured off whatever body the model turned out to have.
func _console(systemid: String) -> RetroSystem:
	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = systemid
	sys.position = Vector3(_spawned.size() * 2.0, 1, 0)
	sys.freeze = true
	add_child(sys)
	sys.add_to_group("spawned")
	_spawned.append(sys)
	await _wait(30)
	return sys


func _unit(expansion_id: String) -> RetroExpansion:
	var unit := EXPANSION_SCENE.instantiate() as RetroExpansion
	unit.expansion_id = expansion_id
	unit.position = Vector3(_spawned.size() * 2.0, 1, 0)
	unit.freeze = true
	add_child(unit)
	unit.add_to_group("spawned")
	_spawned.append(unit)
	await _wait(10)
	return unit


func _cart(systemid: String, path: String) -> Node3D:
	var cart := CART_SCENE.instantiate() as Node3D
	cart.systemid = systemid
	cart.rom_path = path
	cart.position = Vector3(0, 3, 0)
	cart.freeze = true
	add_child(cart)
	_spawned.append(cart)
	await _wait(10)
	return cart


func _clear() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.queue_free()
	_spawned.clear()
	await _wait(10)


## Bolt `sys` onto `unit`, whichever of the two owns the socket. The same call a
## hand makes, minus the hand: XRToolsSnapZone.pick_up_object is what a release
## into the zone ends in.
func _bolt(sys: RetroSystem, unit: RetroExpansion) -> void:
	if ExpansionCatalog.mount_of(unit.expansion_id) == ExpansionCatalog.MOUNT_BELOW:
		unit.get_socket().pick_up_object(sys)
	else:
		sys.restore_expansion(unit)
	await _wait(5)


## Take whatever `zone` is holding back off it.
##
## forget_object first, and not drop_object alone: a snap zone in DROPPED mode
## listens for the released object's `dropped` signal for as long as the object is
## still inside its grab sphere, so letting go of a console that has not MOVED yet
## puts it straight back in the socket. That is right in the room — you have to
## lift the machine clear — and wrong in a test, where nothing is carrying it away.
## This is the same call the netplay restore uses to close a socket it is about to
## move a plug out of.
func _unbolt(zone: XRToolsSnapZone, obj: Node3D) -> void:
	zone.forget_object(obj)
	zone.drop_object()
	await _wait(5)


# ── fit ───────────────────────────────────────────────────────────────────────


func _group_fit() -> void:
	var dd := await _unit("nintendo_64dd")
	var n64 := await _console("nintendo_64")
	var snes := await _console("super_nes")

	var socket := dd.get_socket()
	_check(socket != null, "fit/ a unit the console stands on wears the socket")
	_check(socket != null and socket.snap_require == ExpansionPort.GROUP_SYSTEM,
		"fit/ that socket takes consoles, so the snap ghost can draw")
	_check(socket != null and socket.snap_filter.call(n64),
		"fit/ the 64DD socket takes a Nintendo 64")
	_check(socket != null and not socket.snap_filter.call(snes),
		"fit/ and refuses a Super NES")

	# The other kind: a unit that IS a cartridge. It goes into the console's own
	# slot and fills it, so neither machine grows a connector for it — a Mega
	# Drive has no port on its roof, and modelling the 32X as a box that stands
	# there put one on every console that takes one.
	var thirty_two_x := await _unit("sega_32x")
	var md := await _console("mega_drive")
	_check(thirty_two_x.get_socket() == null, "fit/ a cartridge-shaped unit has no socket")
	_check(thirty_two_x.get_node_or_null("ExpansionFoot") == null,
		"fit/ and no foot either — the console's cartridge slot takes it")
	_check(md.get_node_or_null("ExpansionSocket") == null,
		"fit/ so the Mega Drive grows nothing on its roof")
	_check(thirty_two_x.is_in_group("cartridge"),
		"fit/ it joins the group the cartridge slot accepts")
	_check(md._accepts_media(thirty_two_x), "fit/ the Mega Drive's slot takes a 32X")
	_check(not md._accepts_media(dd),
		"fit/ and refuses a 64DD, which belongs to another console entirely")

	# A console nothing mounts above must not grow a socket — an empty one would
	# still light a snap ghost and offer a join that does not exist.
	_check(n64.get_node_or_null("ExpansionSocket") == null,
		"fit/ a Nintendo 64 has nothing standing on it, so no roof socket")
	_check(n64.get_node_or_null("ExpansionFoot") != null,
		"fit/ but it does stand on something, so it has a foot")
	await _clear()


# ── join ──────────────────────────────────────────────────────────────────────


func _group_join() -> void:
	var dd := await _unit("nintendo_64dd")
	var n64 := await _console("nintendo_64")
	await _bolt(n64, dd)

	_check(n64.expansion_ids() == ["nintendo_64dd"], "join/ the console knows what is under it")
	_check(dd.get_host() == n64, "join/ and the unit knows what is on it")
	_check("Nintendo 64DD" in n64._display_name(),
		"join/ the assembled machine says what it has become")

	# The console rides the base through the scene graph: moving the base moves
	# the machine standing on it, which is the whole point of a physical join.
	var before := n64.global_position
	dd.global_position += Vector3(0.5, 0, 0)
	await _wait(5)
	_check(n64.global_position.distance_to(before + Vector3(0.5, 0, 0)) < 0.05,
		"join/ the console travels with the base it is standing on")

	await _unbolt(dd.get_socket(), n64)
	_check(n64.expansion_ids().is_empty(), "join/ lifting the console off unbolts it")
	_check(dd.get_host() == null, "join/ from the unit's side too")
	await _clear()

	# The other direction, driven by the console's own socket.
	var md := await _console("mega_drive")
	var thirty_two_x := await _unit("sega_32x")
	await _bolt(md, thirty_two_x)
	_check(md.expansion_ids() == ["sega_32x"], "join/ a unit in the cartridge slot is bolted on")
	_check(thirty_two_x.get_host() == md, "join/ and knows which console it is on")
	await _unbolt(md._cartridge_slot, thirty_two_x)
	_check(md.expansion_ids().is_empty(), "join/ taking it out of the slot unbolts it")
	await _clear()


# ── tower ─────────────────────────────────────────────────────────────────────


func _group_tower() -> void:
	# Mega-CD on the floor, Mega Drive on it, 32X on the Mega Drive. Two
	# independent joins, no code anywhere that knows what a tower is.
	var cd := await _unit("sega_cd")
	var md := await _console("mega_drive")
	var x := await _unit("sega_32x")
	await _bolt(md, cd)
	await _bolt(md, x)

	_check(md.expansion_ids() == ["sega_cd", "sega_32x"],
		"tower/ the Mega Drive reports both, in catalog order")
	_check(md._display_name().ends_with("Mega-CD + 32X"),
		"tower/ and names the machine it has become")
	_check(md.resolve_core_name() == "picodrive",
		"tower/ the full tower is a picodrive machine, not a genesis_plus_gx one")
	await _clear()

	# Assembled the other way round — 32X first, base second. The reported
	# combination must not depend on the order a player built it in.
	var cd2 := await _unit("sega_cd")
	var md2 := await _console("mega_drive")
	var x2 := await _unit("sega_32x")
	await _bolt(md2, x2)
	await _bolt(md2, cd2)
	_check(md2.expansion_ids() == ["sega_cd", "sega_32x"],
		"tower/ built top-down, the same combination comes out")
	await _clear()


# ── media ─────────────────────────────────────────────────────────────────────


func _group_media() -> void:
	var dd := await _unit("nintendo_64dd")
	var n64 := await _console("nintendo_64")
	await _bolt(n64, dd)

	var disk := await _cart("nintendo_64dd", "/roms/n64dd/disk.ndd")
	var wrong := await _cart("nes", "/roms/nes/other.nes")
	var bay := dd.get_node("MediaBay") as XRToolsSnapZone
	_check(bay != null, "media/ a 64DD has a bay of its own")
	_check(bay != null and bay.snap_filter.call(disk), "media/ which takes a 64DD disk")
	_check(bay != null and not bay.snap_filter.call(wrong), "media/ and refuses an NES cart")

	dd.restore_media(disk)
	await _wait(5)
	_check(dd.get_media_path() == "/roms/n64dd/disk.ndd", "media/ the bay reports its disk")

	# The cartridge in the CONSOLE and the disk in the DRIVE are two different
	# pieces of media on one machine, which is the fact this whole feature exists
	# to represent.
	var cart := await _cart("nintendo_64", "/roms/n64/game.z64")
	n64.restore_cartridge(cart)
	await _wait(5)
	var spec := n64.expansion_boot()
	var roms: Array = n64._expansion_roms(spec)
	_check(roms.size() == 2, "media/ the assembled machine has two pieces of media")
	_check(roms.size() == 2 and roms[0] == "/roms/n64/game.z64" and roms[1] == "/roms/n64dd/disk.ndd",
		"media/ the cartridge is what the core is handed, the disk is what it finds")

	# The list is resolved from the CARTRIDGE, not from rom_path — which
	# _apply_expansion_launch moves onto the boot media. Without that, asking twice
	# reported the disk as the console's own cart and handed the same path in twice.
	n64._apply_expansion_launch()
	var again: Array = n64._expansion_roms(n64.expansion_boot())
	_check(again == roms, "media/ and asking again after a launch gives the same two")
	await _clear()


# ── launch ────────────────────────────────────────────────────────────────────


func _group_launch() -> void:
	# A bare console is untouched by any of this: no unit, no recipe, and the
	# core resolution it always had.
	var bare := await _console("mega_drive")
	_check(bare.expansion_boot().is_empty(), "launch/ a bare console has no recipe")
	await _clear()

	var cd := await _unit("sega_cd")
	var md := await _console("mega_drive")
	await _bolt(md, cd)
	_check(md.resolve_core_name() == "genesis_plus_gx",
		"launch/ a Mega Drive on a Mega-CD resolves to the combination's core")
	_check(md._all_forced_options("genesis_plus_gx") != null,
		"launch/ and the forced-options path survives a combination with none")
	await _clear()

	var dd := await _unit("nintendo_64dd")
	var n64 := await _console("nintendo_64")
	await _bolt(n64, dd)
	# A bare drive is a parallel_n64 machine: mupen64plus-next does not take a
	# lone .ndd, and the core that does is the one BiosBoot already knows about.
	_check(n64.resolve_core_name() == "parallel_n64",
		"launch/ a 64DD with nothing in the console is a parallel_n64 machine")
	var disk := await _cart("nintendo_64dd", "/roms/n64dd/disk.ndd")
	dd.restore_media(disk)
	await _wait(5)
	n64._apply_expansion_launch()
	_check(n64.rom_path == "/roms/n64dd/disk.ndd", "launch/ and boots from the disk")

	# Put a cartridge in and the SAME hardware becomes a different machine: the
	# core that takes a cart and finds the disk beside it.
	var cart := await _cart("nintendo_64", "/roms/n64/game.z64")
	n64.restore_cartridge(cart)
	await _wait(5)
	_check(n64.resolve_core_name() == "mupen64plus_next",
		"launch/ with a cartridge in, it is a mupen64plus_next machine")
	n64._apply_expansion_launch()
	_check(n64.rom_path == "/roms/n64/game.z64",
		"launch/ and the core is handed the cartridge, not the disk")
	_check(not n64._all_forced_options("mupen64plus_next").has("mupen64plus-64dd-hardware"),
		"launch/ and pins no 64dd option, because that core has none")
	await _clear()


func _run() -> void:
	if _want("fit"):
		await _group_fit()
	if _want("join"):
		await _group_join()
	if _want("tower"):
		await _group_tower()
	if _want("media"):
		await _group_media()
	if _want("launch"):
		await _group_launch()
