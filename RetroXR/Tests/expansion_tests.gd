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
##   sgb/     the Super Game Boy adapters: the pairing they hand bsnes, the two
##            cartridges that make them different machines, and the BIOS gate
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

	# A slot bay swallows its media and makes it neither grabbable nor pointable
	# while it is in there, so the button is the only way a disk comes back out.
	var eject := dd.get_node_or_null("EjectButton") as VRButton
	_check(eject != null, "media/ a slot unit has an eject button")
	_check(disk.enabled == false, "media/ a seated disk cannot be grabbed")
	if eject != null:
		eject.button_pressed.emit()
		await _wait(2)
	_check(disk.enabled == true, "media/ pressing eject hands the disk back")
	# And takes it back rather than leaving it parked for a hand that is not
	# coming, which is what the rest of this group goes on to read.
	if eject != null:
		eject.button_pressed.emit()
		await _wait(2)
	_check(dd.get_media_path() == "/roms/n64dd/disk.ndd", "media/ and pressed again draws it in")

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
	# The lamps are a panel of their own, hung on the unit -- the expansion builds
	# a box out of the catalog and knows nothing about what is printed on it.
	var panel := lamp.get_node_or_null("SatellaviewPanel") as SatellaviewPanel
	_check(panel != null, "led/ the unit wears a front panel")
	_check(panel.get_node_or_null("LedPower") != null, "led/ the unit wears a POWER lamp")
	_check(panel.get_node_or_null("LedAccess") != null, "led/ and an ACCESS lamp")

	# Named on the case, and far enough apart to be read. At the spacing the two
	# lamps started at, POWER and ACCESS overlapped into one word.
	var pl := panel.get_node_or_null("LabelPower") as Label3D
	var al := panel.get_node_or_null("LabelAccess") as Label3D
	_check(pl != null and pl.text == "POWER", "led/ POWER is named under its lamp")
	_check(al != null and al.text == "ACCESS", "led/ and ACCESS under its own")
	if pl != null and al != null:
		var gap: float = absf(al.position.x - pl.position.x)
		_check(gap > 0.03, "led/ the two names are far enough apart not to run together")
		_check(pl.position.y < (panel.get_node("LedPower") as Node3D).position.y,
			"led/ and they sit UNDER the lamps they name")

	var power_mat: StandardMaterial3D = panel.get("_led_power_mat")
	var access_mat: StandardMaterial3D = panel.get("_led_access_mat")
	panel.call("_update_lamps")
	_check(power_mat.emission_energy_multiplier == 0.0,
		"led/ POWER is dark with no console under it")
	_check(access_mat.emission_energy_multiplier == 0.0, "led/ and so is ACCESS")

	var lamp_sfc := await _console("super_nes")
	await _bolt(lamp_sfc, lamp)
	lamp_sfc.is_powered_on = true
	panel.call("_update_lamps")
	_check(power_mat.emission_energy_multiplier > 0.0,
		"led/ POWER follows the console it is under")
	lamp_sfc.is_powered_on = false
	panel.call("_update_lamps")
	_check(power_mat.emission_energy_multiplier == 0.0, "led/ and goes out with it")

	# ACCESS answers the core and nothing else.
	panel.call("_on_core_led", 0, true)
	_check(access_mat.emission_energy_multiplier > 0.0,
		"led/ ACCESS lights when the core reports the register")
	panel.call("_on_core_led", 0, false)
	_check(access_mat.emission_energy_multiplier == 0.0, "led/ and clears when it drops")
	panel.call("_on_core_led", 3, true)
	_check(access_mat.emission_energy_multiplier == 0.0,
		"led/ an index that is not ACCESS is ignored")

	# The client's state must not reach a lamp: that was invented signalling the
	# hardware never had, and removing it is the point of this group. Asserted by
	# ABSENCE -- this used to call the handler and check the lamp afterwards, but
	# calling a method that is gone aborts the group instead of failing a check,
	# so this and the two media checks below it had stopped running at all.
	_check(not panel.has_method("_on_client_state"),
		"led/ and the broadcast client drives neither lamp")
	_check(access_mat.emission_energy_multiplier == 0.0,
		"led/ and ACCESS is dark with nothing but the core to light it")

	# Empty both zones before the objects go: a snap zone that is still holding one
	# walks it on the body_exited a queue_free fires, and reads a freed instance.
	# Which is why the clear comes after: it frees the unit this reaches through.
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


# ── sgb ───────────────────────────────────────────────────────────────────────


## The Super Game Boy: the second object in the room a player puts a cartridge
## into and then puts into a console, and the first whose own program is a BIOS
## rather than something spawned out of the library.
func _group_sgb() -> void:
	var sgb := await _unit("super_game_boy")
	var sfc := await _console("super_nes")

	_check(sgb.is_in_group("cartridge"), "sgb/ the adapter is itself a cartridge")
	var slot := sfc._cartridge_slot as XRToolsSnapZone
	_check(slot != null and slot.snap_filter.call(sgb),
		"sgb/ and the Super Famicom's slot takes it")
	_check(sgb.get_node_or_null("MediaBay") != null,
		"sgb/ while having a slot of its own")

	var gb := await _cart("game_boy", "/roms/game_boy/game.gb")
	_check(sgb._accepts_media(gb), "sgb/ that slot takes a Game Boy cartridge")
	_check(not sgb._accepts_media(await _cart("super_nes", "/roms/snes/x.sfc")),
		"sgb/ and refuses a Super Famicom one")

	sfc.restore_cartridge(sgb)
	sgb.restore_media(gb)
	await _wait(5)

	# snes9x defines RETRO_GAME_TYPE_SUPER_GAME_BOY and then never advertises it,
	# so a machine pinned to the console's own default would refuse to start.
	var boot := sfc.expansion_boot()
	_check(str(boot.get("core", "")) == "bsnes",
		"sgb/ the stack pins bsnes, not the console's own default")

	# Order is the CORE's, and it is the reverse of the BS-X pairing above: bsnes
	# declares sgb_roms[] as { "Game Boy ROM", "Super Game Boy ROM" } and assigns
	# gameBoy.location = info[0]. Handing those over the other way round would
	# give a core a .sfc where it expects a .gb and look like a broken dump.
	var sub: Dictionary = boot.get("subsystem", {})
	_check(str(sub.get("ident", "")) == "sgb", "sgb/ and declares the sgb pairing")
	var pair := sfc._expansion_roms(sub)
	_check(pair.size() == 2 and pair[0] == "/roms/game_boy/game.gb",
		"sgb/ whose FIRST half is the handheld's cartridge")
	_check(pair.size() == 2 and pair[1].get_file() == "SGB1.sfc",
		"sgb/ and whose second is the adapter's own, taken from the BIOS folder")

	# A Game Boy cartridge's save is ordinary SRAM. `writable` binds a path to the
	# SNES memory-pack region specifically, which is the BS-X pack's flash and
	# nothing else's.
	_check(not sub.has("writable"),
		"sgb/ with neither half marked writable, unlike a memory pack")

	# The adapter is spawned from a menu, never from the library, so rom_path is
	# empty for the whole of its life -- without the firmware fallback the pair is
	# one short and degrades to a plain load, silently.
	_check(sgb.rom_path.is_empty(),
		"sgb/ the unit carries no rom_path of its own")
	await _unbolt(sgb.get_node("MediaBay") as XRToolsSnapZone, gb)
	_check(sfc._expansion_roms(sub).size() == 1,
		"sgb/ an empty bay leaves the pair incomplete, so the plain load runs")
	# Indexed defensively. Breaking rom_from_firmware empties this list, and an
	# unguarded [0] aborted the whole group on the exact regression the case is
	# here to catch -- so the later checks, including the BIOS gate, never ran.
	var alone := sfc._expansion_roms(sfc.expansion_boot())
	_check(alone.size() == 1 and alone[0].get_file() == "SGB1.sfc",
		"sgb/ and an empty adapter still boots its own cartridge")
	await _clear()

	# The 1998 revision is a different machine, and the ONLY thing that makes it
	# one is which dump it is handed. A fallback to the first firmware that
	# happens to be on disk would hand a player with both dumps the wrong one.
	var one := ExpansionCatalog.firmware_rom_path("super_game_boy")
	var two := ExpansionCatalog.firmware_rom_path("super_game_boy_2")
	_check(one.get_file() == "SGB1.sfc" and two.get_file() == "SGB2.sfc",
		"sgb/ the two adapters run two different cartridges")
	_check(one != two, "sgb/ which is the whole of the difference between them")
	_check(ExpansionCatalog.firmware_rom_path("bsx_cart").is_empty(),
		"sgb/ and a unit spawned from the library keeps its own ROM")

	var boot2 := ExpansionCatalog.boot_for("super_nes", ["super_game_boy_2"])
	_check(str(boot2.get("core", "")) == "bsnes"
			and str((boot2.get("subsystem", {}) as Dictionary).get("ident", "")) == "sgb",
		"sgb/ the 2 has a recipe of its own, which is what gates it separately")

	# The gate the whole feature hangs on. Filed under game_boy rather than
	# super_nes: it runs Game Boy cartridges, and that is the card a player is on
	# when they want one.
	for id: String in ["super_game_boy", "super_game_boy_2"]:
		var listed := false
		for item: Dictionary in SpawnCatalog.items_for("game_boy"):
			if str(item.get("spawn", "")) == "expansion:%s" % id:
				listed = true
		_check(listed == ExpansionCatalog.firmware_present(id),
			"sgb/ the Game Boy card offers %s exactly when its BIOS is installed" % id)
		_check(not _spawn_card_has("super_nes", id),
			"sgb/ and the Super Famicom card does not also offer it")

	# The claim the comment above _units_carded_here makes. Asked of
	# ids_carded_on, which files a unit WITHOUT consulting its firmware -- the
	# menu itself cannot answer this, because a BS-X cartridge with no BS-X.bin
	# installed is absent from every card and that says nothing about which one it
	# belongs to. Getting those two confused is what this case is guarding.
	var on_gb: Array[String] = ExpansionCatalog.ids_carded_on("game_boy")
	var on_sv: Array[String] = ExpansionCatalog.ids_carded_on("satellaview")
	_check(on_gb == ["super_game_boy", "super_game_boy_2"],
		"sgb/ and the two of them are the whole of what a console card carries now")
	_check(on_sv == ["bsx_cart"],
		"sgb/ while the BS-X cartridge is filed on the Satellaview card, not here")

	await _sgb_gate_positive()


## Drive the gate BOTH ways, whichever way this machine happens to be set up.
##
## The path is derived from the core name and cannot be pointed elsewhere, so
## this works on the REAL bsnes BIOS folder -- the same bargain romm_tests makes
## with the roms root, and restored at both ends the same way.
##
## Two routes to the same four checks, because the count must not depend on
## whether the player owns a dump. With no dump installed a scratch file is
## written and removed; with one installed it is moved ASIDE and put back, which
## is the only way to see the shut direction on a machine that can already play.
## A rename within one directory, never a copy: a 256 KB read-write of somebody's
## BIOS to prove a menu row is the wrong trade.
func _sgb_gate_positive() -> void:
	var dest := ExpansionCatalog.firmware_rom_path("super_game_boy")
	if dest.is_empty():
		_check(false, "sgb/ the adapter names a firmware path at all")
		return
	var aside := dest + ".expansion_tests_backup"
	# A previous run that died mid-swap left the player with no BIOS and a file
	# they would never think to look for. Put it back before doing anything else.
	if FileAccess.file_exists(aside) and not FileAccess.file_exists(dest):
		DirAccess.rename_absolute(aside, dest)
		print("[exp] sgb/ restored an SGB1.sfc left aside by an earlier run")

	var real := FileAccess.file_exists(dest)
	if real:
		DirAccess.rename_absolute(dest, aside)
		_refresh_firmware()
		_check(not ExpansionCatalog.firmware_present("super_game_boy"),
			"sgb/ with the dump moved away the adapter is withdrawn")
		_check(not _spawn_card_has("game_boy", "super_game_boy"),
			"sgb/ and the Game Boy card loses its row")
		DirAccess.rename_absolute(aside, dest)
		_refresh_firmware()
		_check(FileAccess.file_exists(dest), "sgb/ and the player's dump is put back")
		_check(ExpansionCatalog.firmware_present("super_game_boy"),
			"sgb/ which brings the adapter back with it")
		return

	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		_check(false, "sgb/ can write to the BIOS folder to drive the gate")
		return
	f.store_string("retroxr expansion_tests scratch, safe to delete")
	f.close()
	_refresh_firmware()
	_check(ExpansionCatalog.firmware_present("super_game_boy"),
		"sgb/ a dump on disk makes the adapter available")
	_check(_spawn_card_has("game_boy", "super_game_boy"),
		"sgb/ and the Game Boy card grows a row for it")
	DirAccess.remove_absolute(dest)
	_refresh_firmware()
	_check(not FileAccess.file_exists(dest), "sgb/ and the scratch dump is cleaned up")
	_check(not ExpansionCatalog.firmware_present("super_game_boy"),
		"sgb/ which withdraws the adapter again")


## Drop the cached verdict. FirmwareState keys on size and mtime, so a file that
## appeared or vanished since the last look is simply not noticed.
func _refresh_firmware() -> void:
	FirmwareState.shared().evaluate("bsnes", FirmwareRequirements.for_core("bsnes"))


func _spawn_card_has(systemid: String, expansion_id: String) -> bool:
	for item: Dictionary in SpawnCatalog.items_for(systemid):
		if str(item.get("spawn", "")) == "expansion:%s" % expansion_id:
			return true
	return false


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
	if _want("sgb"):
		await _group_sgb()
