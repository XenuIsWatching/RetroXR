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

	# A machine booted from the STACK still gets a save file. The path is composed
	# from the console's own cartridge, and with the slot empty that returned "" --
	# so a 64DD disk or a Mega-CD disc, both battery-backed, ran with nowhere to
	# write and silently never saved. The bay's medium is the fallback.
	n64._snapped_cartridge = null
	var stack_save := n64._memcards._compose_sram_path("mupen64plus_next")
	_check(not stack_save.is_empty(),
		"save/ media in an expansion bay still resolves a save path")
	_check(stack_save.contains(str(dd.get_media().get("save_id"))),
		"save/ and it is keyed by that medium's own save_id")

	# The console's own slot still wins when both are loaded: the cartridge is the
	# game, the disk is its expansion. Set back the way it was cleared, since
	# restore_cartridge is a no-op on a cart already seated in the slot.
	n64._snapped_cartridge = cart
	_check(n64._memcards._compose_sram_path("mupen64plus_next")
			.contains(str(cart.get("save_id"))),
		"save/ a cartridge in the console still takes precedence")
	await _clear()

	# The Satellaview is the exception: a base station with NO mouth on it. Its
	# cartridge goes into the Super Famicom standing on top of it, so the unit must
	# build no bay at all -- one on its roof is under the console, and the pack
	# disappeared into the join between the two machines.
	var bs := await _unit("satellaview")
	var sfc := await _console("super_nes")
	await _bolt(sfc, bs)
	_check(bs.get_node_or_null("MediaBay") == null,
		"media/ a Satellaview has no bay of its own")
	_check(bs.get_media() == null, "media/ and reports nothing in one")

	var pack := await _cart("satellaview", "/roms/satellaview/BS-X.bs")
	var not_ours := await _cart("nes", "/roms/nes/other.nes")
	var slot := sfc._cartridge_slot as XRToolsSnapZone
	_check(slot != null and slot.snap_filter.call(pack),
		"media/ the console's own slot takes the pack instead")
	_check(slot != null and slot.snap_filter.call(await _cart("super_nes", "/roms/snes/g.sfc")),
		"media/ without losing its own cartridges")
	_check(slot != null and not slot.snap_filter.call(not_ours),
		"media/ and still refuses an NES cart")

	sfc.restore_cartridge(pack)
	await _wait(5)
	var bs_spec := sfc.expansion_boot()
	_check(str(bs_spec.get("core", "")) == "snes9x", "media/ the stack pins snes9x")
	_check(sfc._expansion_roms(bs_spec) == ["/roms/satellaview/BS-X.bs"],
		"media/ and boots the pack from the console's slot, not the unit's")
	await _clear()

	# The BS-X CARTRIDGE: the middle layer of the real three, and the only object
	# here that a player puts a cartridge into and then puts into a console. The
	# pack goes in its slot, it goes in the Super Famicom's.
	var nest_bsx := await _unit("bsx_cart")
	var nest_sfc := await _console("super_nes")
	_check(nest_bsx.is_in_group("cartridge"),
		"nest/ the BS-X cart is itself a cartridge")
	var nest_slot := nest_sfc._cartridge_slot as XRToolsSnapZone
	_check(nest_slot != null and nest_slot.snap_filter.call(nest_bsx),
		"nest/ and the console's slot takes it")
	_check(nest_bsx.get_node_or_null("MediaBay") != null,
		"nest/ unlike the base station it HAS a slot of its own")

	var nest_pack := await _cart("satellaview", "/roms/satellaview/PACK.bs")
	_check(nest_bsx._accepts_media(nest_pack), "nest/ that slot takes an 8M pack")
	_check(not nest_bsx._accepts_media(await _cart("nes", "/roms/nes/x.nes")),
		"nest/ and refuses what is not one")

	nest_sfc.restore_cartridge(nest_bsx)
	nest_bsx.restore_media(nest_pack)
	await _wait(5)
	var nest_boot := nest_sfc.expansion_boot()
	_check(str(nest_boot.get("core", "")) == "snes9x", "nest/ the stack pins snes9x")
	# The PACK is the content. The BS-X cartridge is never handed over: snes9x
	# sources BS-X.bin from the system directory itself.
	_check(nest_sfc._expansion_roms(nest_boot) == ["/roms/satellaview/PACK.bs"],
		"nest/ and the core is handed the pack, not the cartridge carrying it")

	# It must also run with no base station bolted on, as the hardware does.
	_check(not ExpansionCatalog.boot_for("super_nes", ["bsx_cart"]).is_empty(),
		"nest/ the cartridge alone is a bootable machine")
	_check(not ExpansionCatalog.boot_for("super_nes", ["bsx_cart", "satellaview"]).is_empty(),
		"nest/ and so is the full stack")

	# A BS-X cartridge spawned from the shell ROM carries that ROM itself, and an
	# empty one is still a bootable machine -- the hardware boots the town with no
	# pack in it. The bay outranks it: put a pack in and the pack is the content.
	nest_bsx.rom_path = "/roms/satellaview/BS-X.sfc"

	# Shell + pack as a PAIR, in the core's declared order. This is the only way
	# the shell in the cartridge is the one that runs: handed a pack alone, the
	# core takes its shell from BS-X.bin in the system directory instead, so a
	# translated BS-X was silently dropped the moment a pack went in.
	var nest_sub: Dictionary = nest_sfc.expansion_boot().get("subsystem", {})
	_check(str(nest_sub.get("ident", "")) == "bsx", "nest/ the stack declares the bsx pairing")
	_check(nest_sfc._expansion_roms(nest_sub)
			== ["/roms/satellaview/BS-X.sfc", "/roms/satellaview/PACK.bs"],
		"nest/ which is the shell first, then the pack")

	# An empty bay must NOT complete the pair. The plain token falls back to the
	# shell, so a pairing that fell back too would hand the core the same ROM
	# twice and look perfectly valid doing it.
	await _unbolt(nest_bsx.get_node("MediaBay") as XRToolsSnapZone, nest_pack)
	_check(nest_sfc._expansion_roms(nest_sub).size() == 1,
		"nest/ an empty bay leaves the pair incomplete, so the plain load runs")
	_check(nest_sfc._expansion_roms(nest_sfc.expansion_boot())
			== ["/roms/satellaview/BS-X.sfc"],
		"nest/ an empty BS-X cart boots the shell it carries")
	nest_bsx.restore_media(nest_pack)
	await _wait(5)
	_check(nest_sfc._expansion_roms(nest_sfc.expansion_boot())
			== ["/roms/satellaview/PACK.bs"],
		"nest/ and a pack in the bay outranks it")

	# Which half of the pair is the writable MEDIUM, not a read-only ROM. The
	# bridge writes a download back over that file, so an index naming the shell
	# would flush the pack's contents over the BS-X cartridge itself.
	_check(int(nest_sub.get("writable", -1)) == 1,
		"nest/ the pack is the writable half of the pair")
	_check(nest_sfc._expansion_roms(nest_sub)[int(nest_sub["writable"])]
			== "/roms/satellaview/PACK.bs",
		"nest/ and that index really lands on the pack")

	# The BS-X cartridge holds its OWN battery: the 32 KB is the player's name and
	# town, and it belongs to the cart, not to whatever pack is in its bay. Keyed
	# to the medium, every new pack read as a different BS-X and the shell asked
	# for a name again.
	_check(ExpansionCatalog.save_owner_of("bsx_cart") == ExpansionCatalog.SAVE_OWNER_UNIT,
		"nest/ the BS-X cartridge owns its own save")
	_check(ExpansionCatalog.save_owner_of("nintendo_64dd") == ExpansionCatalog.SAVE_OWNER_MEDIA,
		"nest/ while a 64DD disk saves onto itself")
	# A save path only exists for a machine that has content loaded -- the guard
	# at the top of _compose_sram_path says so -- and a launched BS-X stack has
	# the pack as its rom_path.
	nest_sfc.rom_path = "/roms/satellaview/PACK.bs"
	var save_a := nest_sfc._memcards._compose_sram_path("snes9x")
	var slot_a := nest_sfc._memcards._sram_slot()
	_check(save_a.contains("bsx_cart"),
		"nest/ so the save is filed under the cartridge, not the pack")
	_check(not save_a.contains("PACK"),
		"nest/ and carries nothing of the pack's name")

	# Swap the pack. The town must not move with it.
	await _unbolt(nest_bsx.get_node("MediaBay") as XRToolsSnapZone, nest_pack)
	var other := await _cart("satellaview", "/roms/satellaview/OTHER.bs")
	nest_bsx.restore_media(other)
	await _wait(5)
	_check(nest_sfc._memcards._compose_sram_path("snes9x") == save_a,
		"nest/ a different pack keeps the same save")
	_check(nest_sfc._memcards._sram_slot() == slot_a,
		"nest/ and is not treated as a different save source")
	await _unbolt(nest_bsx.get_node("MediaBay") as XRToolsSnapZone, other)
	_check(nest_sfc._memcards._compose_sram_path("snes9x") == save_a,
		"nest/ and an empty cart still has the town on it")
	nest_bsx.restore_media(nest_pack)
	await _wait(5)


	# ── the front-panel lamps ───────────────────────────────────────────────
	# The real unit wears POWER and ACCESS, and nothing else. Both report the
	# MACHINE: POWER follows the console, ACCESS is $2194 bit 2 as the core
	# reports it. The broadcast client deliberately drives neither.
	var lamp := await _unit("satellaview")
	_check(lamp.get_node_or_null("LedPower") != null, "led/ the unit wears a POWER lamp")
	_check(lamp.get_node_or_null("LedAccess") != null, "led/ and an ACCESS lamp")

	# Named on the case, and far enough apart to be read. At the spacing the two
	# lamps started at, POWER and ACCESS overlapped into one word.
	var pl := lamp.get_node_or_null("LabelPower") as Label3D
	var al := lamp.get_node_or_null("LabelAccess") as Label3D
	_check(pl != null and pl.text == "POWER", "led/ POWER is named under its lamp")
	_check(al != null and al.text == "ACCESS", "led/ and ACCESS under its own")
	if pl != null and al != null:
		var gap: float = absf(al.position.x - pl.position.x)
		_check(gap > 0.03, "led/ the two names are far enough apart not to run together")
		_check(pl.position.y < (lamp.get_node("LedPower") as Node3D).position.y,
			"led/ and they sit UNDER the lamps they name")

	var power_mat: StandardMaterial3D = lamp.get("_led_power_mat")
	var access_mat: StandardMaterial3D = lamp.get("_led_access_mat")
	lamp.call("_update_lamps")
	_check(power_mat.emission_energy_multiplier == 0.0,
		"led/ POWER is dark with no console under it")
	_check(access_mat.emission_energy_multiplier == 0.0, "led/ and so is ACCESS")

	var lamp_sfc := await _console("super_nes")
	await _bolt(lamp_sfc, lamp)
	lamp_sfc.is_powered_on = true
	lamp.call("_update_lamps")
	_check(power_mat.emission_energy_multiplier > 0.0,
		"led/ POWER follows the console it is under")
	lamp_sfc.is_powered_on = false
	lamp.call("_update_lamps")
	_check(power_mat.emission_energy_multiplier == 0.0, "led/ and goes out with it")

	# ACCESS answers the core and nothing else.
	lamp.call("_on_core_led", 0, true)
	_check(access_mat.emission_energy_multiplier > 0.0,
		"led/ ACCESS lights when the core reports the register")
	lamp.call("_on_core_led", 0, false)
	_check(access_mat.emission_energy_multiplier == 0.0, "led/ and clears when it drops")
	lamp.call("_on_core_led", 3, true)
	_check(access_mat.emission_energy_multiplier == 0.0,
		"led/ an index that is not ACCESS is ignored")

	# The client's state must not reach a lamp: that was invented signalling the
	# hardware never had, and removing it is the point of this group.
	lamp.call("_on_client_state", "error")
	_check(access_mat.emission_energy_multiplier == 0.0,
		"led/ and the broadcast client drives neither lamp")
	await _clear()

	# Empty both zones before the objects go: a snap zone that is still holding one
	# walks it on the body_exited a queue_free fires, and reads a freed instance.
	await _unbolt(nest_bsx.get_node("MediaBay") as XRToolsSnapZone, nest_pack)
	await _clear()

	# Unbolted, the same cartridge still fits: a BS-X cart boots its menu in a bare
	# Super Famicom, and a silent refusal is the worst way to say otherwise.
	var lone := await _console("super_nes")
	var lone_pack := await _cart("satellaview", "/roms/satellaview/BS-X.bs")
	_check(lone._cartridge_slot.snap_filter.call(lone_pack),
		"media/ and fits a Super Famicom with no base station under it")
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
