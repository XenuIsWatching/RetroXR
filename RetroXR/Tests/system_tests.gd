## RetroSystem self-tests — the pure-logic half of the machine controller, run
## headless with no core, no ROM, no headset and no device.
##
##     "$godot" --headless --path RetroXR res://Tests/system_tests.tscn
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## Every case below is a rule that a console, a core or a peripheral depends on
## and that nothing else checks: which libretro port a peripheral drives, which
## device id a core is told, which pad profile a plugged pad selects, which
## seated object names the save, and whether pulling the media stops the run.
## The light-gun cases are the regression record for a bug that shipped — the ray
## gun announced a device id fceumm does not know, and fceumm turns an unknown id
## into a gamepad, so plugging the gun in is what unplugged the Zapper.
##
## RetroSystem is a scene node with a `Libretro` child and a hardware model, so
## these build it with `.new()` and never add it to the tree: `_ready()` would
## look for children that a bare instance does not have. That is also the limit
## of what can be tested here — anything that touches `_libretro`, `_model`, the
## snap zones or the A/V graph needs a real scene and lives in `Tools/` probes or
## in `Tests/av_tests.tscn`. `_sync_core_tray()` is on the far side of that line;
## what is testable is the two questions it asks first, and those are below.
##
## Known gaps, asserted nowhere on purpose — add the case with the fix, not
## before it, or the suite goes red on behaviour nobody has agreed to yet:
##   - the light-gun name list does not know "Stunner" (the Saturn Virtua Gun's
##     US name), so a core naming its gun only that would not resolve;
##   - `attach_expanded_controller` (a multitap sub-port) announces the raw
##     device type, skipping `_core_device_id`, so a gun on a multitap is a
##     gamepad to fceumm until the next core start re-announces it.
extends Node


## A systemid no console has, so seeding a default core for it cannot shadow one
## the player chose. Never a real platform: core_defaults.json is the player's
## own file and the only one _resolve_core() will read.
const _RESOLVE_SYS := "__resolve_selftest"


## A stand-in for a cartridge or a memory card: the system only ever reads named
## properties off the seated object, so a Node3D carrying them is enough.
class FakeSeated extends Node3D:
	var save_id: String = ""
	var card_id: String = ""
	var game_label: String = ""
	var systemid: String = ""
	var device_type: int = 1


## Port lists exactly as fceumm declares them (read back from the running core).
## Its Zapper is a MOUSE subclass, so nothing here has a light gun's base type —
## which is the whole reason the resolver cannot go by base type alone.
const FCEUMM_PORTS: Array = [
	{"port": 0, "controllers": [
		{"name": "Auto", "id": 1}, {"name": "Gamepad", "id": 513},
		{"name": "Zapper", "id": 258}]},
	{"port": 1, "controllers": [
		{"name": "Auto", "id": 1}, {"name": "Gamepad", "id": 513},
		{"name": "Arkanoid", "id": 514}, {"name": "Zapper", "id": 258},
		{"name": "Power Pad A", "id": 259}, {"name": "Power Pad B", "id": 515}]},
	{"port": 2, "controllers": [
		{"name": "Auto", "id": 1}, {"name": "Gamepad", "id": 513}]},
]

## A core that subclasses the light gun properly, the way libretro.h intends.
## 263 = SUBCLASS(LIGHTGUN, 0), 519 = SUBCLASS(LIGHTGUN, 1).
const SNES_PORTS: Array = [
	{"port": 0, "controllers": [
		{"name": "SNES Joypad", "id": 1}, {"name": "SNES Mouse", "id": 2},
		{"name": "Super Scope", "id": 263}, {"name": "Justifier", "id": 519}]},
]

## A core declaring both shapes on one port. The base type is the stronger
## signal, so it must win however early the name match appears in the list.
const MIXED_PORTS: Array = [
	{"port": 0, "controllers": [
		{"name": "Zapper", "id": 258}, {"name": "Super Scope", "id": 263}]},
]

const DEVICE_NONE := 0
const DEVICE_JOYPAD := 1
const DEVICE_MOUSE := 2
const DEVICE_KEYBOARD := 3
const DEVICE_LIGHTGUN := 7

var _pass := 0
var _fail := 0


func _ready() -> void:
	# A test scene must never hang a headless run.
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))

	_test_reads_as_lightgun()
	_test_core_device_id()
	_test_light_gun_cards()
	_test_bsx_card()
	_test_pad_type_choice()
	await _test_analog_mode_switch()
	await _test_playstation_hardware()
	await _test_power_led()
	await _test_save_state_gates()
	await _test_sram_paths()
	_test_libretro_port_routing()
	_test_port_device_cache()
	_test_cabinet_lookup()
	_test_seated_content()
	_test_media_removal()
	_test_expanded_port_binding()
	_test_belongs_here()
	_test_core_resolution()
	_test_forced_options_merge()
	_test_net_link_group_merge()
	_test_memcard_presence()
	_test_bios_seed()
	_test_bios_boot_table()
	_test_neo_geo_cd_cores()
	_test_supergrafx_core()
	_test_bios_pinned_options()
	_test_bios_pins_reach_the_opt_file()
	_test_power_on_verdict()
	_test_state_paths()
	_test_state_thumbnail()
	_test_state_disk_round_trip()
	_test_audio_cabling_gate()

	await _settle()
	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


## Release the machines this suite built and let the AudioServer reclaim their
## voices BEFORE the main loop ends.
##
## Godot deletes the AudioServer after unregistering the extension classes, so a
## playback still held at that point is destroyed through a freed class record:
## the process dies with an access violation, no crash-handler backtrace, every
## case already printed PASS. It crashed 3 runs in 12 like that. A RetroSystem
## binds a spatial emitter as soon as its core starts, and several are still
## standing here — queue_free() alone is not enough because it only schedules the
## free, and quit() leaves at most the rest of the current iteration.
##
## The frame count matches time_of_day_tests._settle for the same measured
## reason: the reclaim is a chain (emitters freed, then the mixer notices it has
## no voices and frees its own player, then another AudioServer::update() hands
## the playback back), and a shorter wait only covers part of it.
func _settle() -> void:
	for child in get_children():
		child.queue_free()
	for _i in range(60):
		await get_tree().process_frame


func _ok(cond: bool, test_name: String, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s" % test_name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [test_name, "  — " + detail if not detail.is_empty() else ""])


func _eq(got: Variant, want: Variant, test_name: String) -> void:
	_ok(got == want, test_name, "got %s, want %s" % [str(got), str(want)])


## A bare instance: never added to the tree, so `_ready()` never runs and no
## child node is required. Caller frees it.
func _system(sysid: String = "nes") -> RetroSystem:
	var sys := RetroSystem.new()
	sys.systemid = sysid
	return sys


# ---------------------------------------------------------------------------
# Which device names read as a light gun.
# ---------------------------------------------------------------------------

func _test_reads_as_lightgun() -> void:
	for gun: String in ["Zapper", "Super Scope", "Konami Justifier", "GunCon",
			"Light Phaser", "Menacer", "Lightgun"]:
		_ok(RetroSystem._reads_as_lightgun(gun), "gun name/'%s' is a gun" % gun)
	# The rest of a NES port list, plus the devices most likely to be mistaken
	# for one because they also report a screen position.
	for other: String in ["Auto", "Gamepad", "Arkanoid", "Power Pad A",
			"SNES Mouse", "Keyboard", "Multitap", "Oeka Kids Tablet",
			"Pointer", "Touchscreen"]:
		_ok(not RetroSystem._reads_as_lightgun(other), "gun name/'%s' is not a gun" % other)


# ---------------------------------------------------------------------------
# The generic device type a peripheral carries -> the id the running core knows.
# ---------------------------------------------------------------------------

func _test_core_device_id() -> void:
	var sys := _system()
	sys._controller_info = FCEUMM_PORTS

	# The bug this suite exists for: 7 is not a device fceumm knows, and its
	# switch turns an unknown id into a gamepad. Port 2 (index 1) is where a NES
	# Zapper goes.
	_eq(sys._core_device_id(DEVICE_LIGHTGUN, 1), 258, "device/fceumm gun -> Zapper")
	_eq(sys._core_device_id(DEVICE_LIGHTGUN, 0), 258, "device/fceumm gun on port 1 -> Zapper")

	# A port that declares no gun keeps the generic id rather than borrowing the
	# gun another port declares.
	_eq(sys._core_device_id(DEVICE_LIGHTGUN, 2),
		DEVICE_LIGHTGUN, "device/no gun on this port passes through")
	# A port the core never declared at all.
	_eq(sys._core_device_id(DEVICE_LIGHTGUN, 9),
		DEVICE_LIGHTGUN, "device/unknown port passes through")

	# Only a light gun is translated. A pad, a mouse, a keyboard and an unplug
	# all have to reach the core exactly as sent.
	for dev: int in [DEVICE_NONE, DEVICE_JOYPAD, DEVICE_MOUSE, DEVICE_KEYBOARD]:
		_eq(sys._core_device_id(dev, 1), dev, "device/type %d untranslated" % dev)

	# Nothing is known about the core until it starts, and a peripheral can be
	# plugged into a machine that is off. The generic id is the honest answer;
	# _reannounce_port_devices() corrects it once the core declares its list.
	sys._controller_info = []
	_eq(sys._core_device_id(DEVICE_LIGHTGUN, 1),
		DEVICE_LIGHTGUN, "device/machine off passes through")

	# A core that subclasses the light gun properly is taken at its word.
	sys._controller_info = SNES_PORTS
	_eq(sys._core_device_id(DEVICE_LIGHTGUN, 0), 263, "device/subclassed gun wins")

	# Base type beats the name, however early the name matches.
	sys._controller_info = MIXED_PORTS
	_eq(sys._core_device_id(DEVICE_LIGHTGUN, 0), 263, "device/base type beats name")

	sys.free()


# ---------------------------------------------------------------------------
# Which cards offer the light gun.
# ---------------------------------------------------------------------------

## The gun is offered per platform, so the table is a claim about hardware and
## rots silently: nothing in the room fails when a console that never sold one
## starts offering it, or when one that did stops. Both directions are asserted
## for that reason -- a test that only checks the platforms in the list would
## still pass if the row were appended to every card.
func _test_light_gun_cards() -> void:
	var with_gun: Array = ["nes", "super_nes", "master_system", "mega_drive",
		"sega_saturn", "dreamcast", "playstation", "playstation2",
		"atari_2600", "atari_7800", "atari_8bit", "commodore_c64", "zx_spectrum",
		"cpc", "3do", "cdi"]
	# sega_cd moved across deliberately: light-gun games were sold for it, but
	# its card spawns the Mega-CD UNIT and a gun goes into the Mega Drive
	# standing on it. mega_drive is in the list above and still offers the row,
	# so the hardware is still reachable -- from the machine it plugs into.
	var without_gun: Array = ["nintendo_64", "gamecube", "wii", "virtual_boy",
		"game_boy", "game_boy_advance", "neogeo", "atari_5200", "colecovision",
		"intellivision", "vectrex", "pc_engine", "sg1000", "nds", "dos",
		"sega_cd"]

	for sysid: String in with_gun:
		_ok(not _gun_row(sysid).is_empty(), "gun/%s offers one" % sysid)
	for sysid: String in without_gun:
		_ok(_gun_row(sysid).is_empty(), "gun/%s does not" % sysid)

	# Once per card: it is appended by items_for, so a copy left in _PERIPHERALS
	# would list it twice on that one platform and nowhere else.
	var seen := 0
	for item: Dictionary in SpawnCatalog.items_for("nes"):
		if String(item.get("spawn", "")) == "light_gun":
			seen += 1
	_eq(seen, 1, "gun/listed once")

	# The row has to carry a token SpawnMenuController already handles, or the
	# button is drawn and does nothing.
	var row := _gun_row("super_nes")
	_eq(String(row.get("kind", "")), "peripheral", "gun/is a peripheral")
	_eq(SpawnCatalog.spawn_token("super_nes", row), "light_gun", "gun/token")
	_ok((load("res://Scenes/Objects/peripherals/light_gun.tscn") as PackedScene) .can_instantiate(),
		"gun/the token's scene loads a LightGun")


## Where the BS-X cartridge is offered from, and when.
##
## It used to sit on the Super Famicom's card, because it has no tile of its own
## and the host card was the only fallback. That put a Satellaview part among the
## SNES pads and leads, where a player who has never heard of the base station
## meets it first and where the two halves of one machine are on different cards.
##
## The second half is the firmware. What this cartridge runs is BS-X.bin in
## snes9x's system directory, which is not ours and not in the pack, so without
## it the row spawns a box that goes into a slot and does nothing. The check is
## written against the real filesystem rather than a fixture: it asserts that the
## row's presence AGREES with firmware_present either way, so it passes on a
## machine with the file and on one without, and fails if the gate is dropped.
func _test_bsx_card() -> void:
	_eq(ExpansionCatalog.card_systemid("bsx_cart"),
		"satellaview", "bsx/filed on the Satellaview card")
	_ok(ExpansionCatalog.ids_carded_on("satellaview").has("bsx_cart"), "bsx/and listed there")
	_ok(not ExpansionCatalog.ids_carded_on("super_nes").has("bsx_cart"),
		"bsx/not on the Super Famicom's")
	# The Jaguar CD used to be the case this rule did NOT move: its discs were
	# filed as the Jaguar's own media, so it had no tile and the console's card
	# was the only place it could be reached from. virtualjaguar names jaguar_cd
	# in secondary_systemids now, so the CD half is a system, and the unit is
	# spawned from its own card like every other expansion.
	_eq(ExpansionCatalog.card_systemid("jaguar_cd"),
		"jaguar_cd", "bsx/the Jaguar CD is filed on its own card")
	_ok(not ExpansionCatalog.ids_carded_on("atari_jaguar").has("jaguar_cd"),
		"bsx/the Jaguar CD no longer sits on the console's")
	_ok(not _spawn_row("jaguar_cd", "expansion:jaguar_cd").is_empty(),
		"bsx/and is offered from its own spawn menu")

	_ok(_spawn_row("super_nes", "expansion:bsx_cart").is_empty(),
		"bsx/never on the SNES spawn list")
	var installed := ExpansionCatalog.firmware_present("bsx_cart")
	var offered := not _spawn_row("satellaview", "expansion:bsx_cart").is_empty()
	_eq(offered, installed, "bsx/offered exactly when BS-X.bin is installed")
	# The base station is the card either way -- gating the cartridge must never
	# take the tile's own hardware down with it.
	_ok(not _spawn_row("satellaview", "expansion:satellaview").is_empty(),
		"bsx/the base station is offered regardless")


## A card's row carrying `token`, or {} when it offers none.
func _spawn_row(sysid: String, token: String) -> Dictionary:
	for item: Dictionary in SpawnCatalog.items_for(sysid):
		if String(item.get("spawn", "")) == token:
			return item
	return {}


## The gun's row on a platform's card, or {} if that card offers none.
func _gun_row(sysid: String) -> Dictionary:
	for item: Dictionary in SpawnCatalog.items_for(sysid):
		if String(item.get("spawn", "")) == "light_gun":
			return item
	return {}


# ---------------------------------------------------------------------------
# Which pad profile a plugged pad selects (PCSX-ReARMed's padNtype).
# ---------------------------------------------------------------------------

## Three faults reported from the room, each of which a render had already been
## used to "confirm" was fine.
##
## The lid one is the interesting one: OPEN on a spring-latched lid is a LATCH
## RELEASE, so RetroSystem deliberately ignores it while it believes the tray is
## up. Close the lid by hand without telling it and that belief never changes,
## the next press is correctly ignored, and the button reads as dead.
func _test_playstation_hardware() -> void:
	var labels: Array = []
	for it in SpawnCatalog.items_for("playstation"):
		labels.append(String((it as Dictionary).get("label", "")))
	# A platform that models its own console AND its own pads has no use for the
	# generic box or the generic pad; they are clutter on its card.
	_ok(not labels.has("Primitive System"), "psx/no Primitive System offered")
	_ok(not labels.has("Primitive Controller"), "psx/no Primitive Controller offered")
	_ok(labels.has("PlayStation"), "psx/the console is still offered")
	_ok(labels.has("Controller") and labels.has("DualShock"), "psx/both pads are offered")

	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	var card_scene := load("res://Scenes/Objects/media/memory_card.tscn") as PackedScene
	if sys_scene == null or card_scene == null:
		return
	var psx: Node3D = sys_scene.instantiate()
	psx.systemid = "playstation"
	add_child(psx)
	var card: Node3D = card_scene.instantiate()
	add_child(card)
	for i in range(20):
		await get_tree().process_frame

	var model: Node3D = psx.find_child("Shell", true, false)
	model = model.get_parent() if model != null else null
	var eject := psx.find_child("EjectButton", true, false) as VRButton
	if model == null or eject == null:
		psx.queue_free()
		return

	# Two ways to seat a card wrong, and each has its own axis. A controller plug
	# carries a SnapGrabPoint with its own 180 about X, so the ports roll to
	# compose with it; a memory card has no grab point, so the same roll simply
	# turns it OVER. Correcting that with a yaw then seated every card BACKWARDS,
	# because the card's front tab is its +Z end and the connector is its -Z one.
	# Measured against the shell rather than the cabinet: the front face is the
	# model's +Z (MemCard1 at z +86 mm, JackSerial on the back panel at -86).
	var slot := psx.find_child("MemoryCardSlot", true, false) as XRToolsSnapZone
	if slot != null:
		slot.enabled = true
		slot.pick_up_object(card)
	for i in range(18):
		await get_tree().process_frame
	var rel := model.global_transform.affine_inverse() * card.global_transform
	_ok(rel.basis.y.y > 0.9, "psx/the memory card seats label-up", "up = %.3v" % rel.basis.y)
	_ok(rel.basis.z.z > 0.9,
		"psx/and connector-first, tab out the front", "front = %.3v" % rel.basis.z)
	eject.button_pressed.emit()
	for i in range(22):
		await get_tree().process_frame
	_ok(float(model.call("get_lid_angle_deg")) > 40.0,
		"psx/OPEN raises the lid", "%.1f deg" % model.call("get_lid_angle_deg"))
	var hinge := psx.find_child("LidHinge", true, false)
	if hinge != null and hinge.has_method("latch_closed"):
		hinge.latch_closed()
	for i in range(22):
		await get_tree().process_frame
	_ok(float(model.call("get_lid_angle_deg")) < 5.0,
		"psx/a hand can shut it", "%.1f deg" % model.call("get_lid_angle_deg"))
	_ok(not bool(psx.get("_tray_open")), "psx/and the machine learns it is shut")
	eject.button_pressed.emit()
	for i in range(22):
		await get_tree().process_frame
	_ok(float(model.call("get_lid_angle_deg")) > 40.0,
		"psx/OPEN works a second time", "%.1f deg" % model.call("get_lid_angle_deg"))

	card.queue_free()
	psx.queue_free()
	for n in get_children():
		if String(n.name).contains("Cable"):
			n.queue_free()
	for i in range(4):
		await get_tree().process_frame


## The DualShock's ANALOG switch, which is one flag driving four things: the
## lamp, the lens emission, the axes the core is told about, and the pad type.
## Any one of them out of step is the pad saying two different things at once, and
## none of them is visible from the others -- the lamp can be lit over dead
## sticks, or the core left on "dualshock" while the pad reports centred.
##
## Plugged into a real machine on purpose: the lamp is deliberately dark on an
## unplugged pad, so a bench test with no console cannot tell "off because
## digital" from "off because nobody is driving it".
func _test_analog_mode_switch() -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	var pad_scene := load("res://Scenes/Objects/controllers/playstation/ps1_dualshock.tscn") as PackedScene
	if sys_scene == null or pad_scene == null:
		return
	var psx: Node3D = sys_scene.instantiate()
	psx.systemid = "playstation"
	add_child(psx)
	var pad: Node3D = pad_scene.instantiate()
	add_child(pad)
	for i in range(20):
		await get_tree().process_frame

	# The plug hangs off the CABLE, which RetroController parents to the current
	# scene rather than to the pad, so it is not under `pad` to be found.
	var plug: Node3D = null
	for n in find_children("*", "Node3D", true, false):
		if n is ControllerPlug:
			plug = n as Node3D
			break
	var port := psx.find_child("ControllerPort1", true, false) as XRToolsSnapZone
	if port != null and plug != null:
		port.enabled = true
		port.pick_up_object(plug)
	for i in range(24):
		await get_tree().process_frame

	var glow := pad.find_child("AnalogLampGlow", true, false) as OmniLight3D
	var btn := pad.get_node_or_null("AnalogButton") as VRButton
	_ok(pad.get("_connected_system") != null, "analog/plugged in")
	_ok(bool(pad.get("_analog_mode")), "analog/starts in analogue mode")
	_ok(glow != null and glow.visible, "analog/lamp lit")
	_eq(String(pad.get("pad_type_pref")), "dualshock", "analog/pad type")

	if btn != null:
		btn.button_pressed.emit()
	for i in range(6):
		await get_tree().process_frame
	_ok(not bool(pad.get("_analog_mode")), "analog/a poke leaves analogue mode")
	_ok(glow != null and not glow.visible, "analog/lamp goes out")
	var em := 0.0
	for m in (pad.get("_led_mats") as Array):
		em = maxf(em, (m as StandardMaterial3D).emission_energy_multiplier)
	_ok(is_zero_approx(em), "analog/emission goes out")
	_eq(String(pad.get("pad_type_pref")), "standard", "analog/pad type follows")
	pad.call("_send_joypad", 0, 32767, 0, 32767, 0)
	_ok((pad.get("_cur_lstick") as Vector2).is_zero_approx(),
		"analog/digital reports centred sticks")

	if btn != null:
		btn.button_pressed.emit()
	for i in range(6):
		await get_tree().process_frame
	_ok(bool(pad.get("_analog_mode")), "analog/a second poke returns")
	_ok(glow != null and glow.visible, "analog/lamp returns")
	pad.call("_send_joypad", 0, 32767, 0, 32767, 0)
	_ok(not (pad.get("_cur_lstick") as Vector2).is_zero_approx(), "analog/sticks report again")

	pad.queue_free()
	psx.queue_free()
	for n in get_children():
		if String(n.name).contains("Cable"):
			n.queue_free()
	for i in range(4):
		await get_tree().process_frame


func _test_pad_type_choice() -> void:
	var full: Array = ["standard", "analog", "dualshock"]
	_eq(RetroSystem._decide_pad_type(full, "dualshock", "standard"),
		"dualshock", "pad/dualshock takes dualshock")
	# A core offering no DualShock still deserves the analog pad rather than the
	# digital one — the sticks are physically there.
	_eq(RetroSystem._decide_pad_type(["standard", "analog"], "dualshock", "standard"),
		"analog", "pad/dualshock falls back to analog")
	_eq(RetroSystem._decide_pad_type(["standard"], "dualshock", "standard"),
		"", "pad/no fallback available")
	# Already right: setting an option costs a core round trip and a rewritten
	# .opt file, so the no-op has to stay a no-op.
	_eq(RetroSystem._decide_pad_type(full, "dualshock", "dualshock"),
		"", "pad/already selected")
	_eq(RetroSystem._decide_pad_type([], "dualshock", "standard"),
		"", "pad/no options known")
	# A preference this core has never heard of is left alone, not guessed at.
	_eq(RetroSystem._decide_pad_type(full, "wavebird", "standard"),
		"", "pad/unknown preference")
	_eq(RetroSystem._decide_pad_type(full, "analog", "standard"),
		"analog", "pad/plain analog pad")

	# And what the SCENES actually ask for. Everything above is the pure decision,
	# which was fully covered while no pad in the repo declared "dualshock" at all
	# -- the branch was reachable only from a test. These are the two that make it
	# reachable from a player, and a scene quietly losing the property would leave
	# every case above green.
	for entry in [["ps1_dualshock", "dualshock"], ["ps1_controller", "standard"]]:
		var path := "res://Scenes/Objects/controllers/playstation/%s.tscn" % entry[0]
		var pad: Node = load(path).instantiate()
		_eq(String(pad.get("pad_type_pref")),
			String(entry[1]), "pad/%s asks for %s" % [entry[0], entry[1]])
		pad.free()


# ---------------------------------------------------------------------------
# Which libretro port a peripheral drives, and whether it claims one at all.
# ---------------------------------------------------------------------------

func _test_libretro_port_routing() -> void:
	var pc := _system("dos")
	# A computer's cores poll the mouse on port 0 wherever the cabinet put it,
	# which is what lets a mouse and a keyboard share the machine.
	_eq(pc._libretro_port_for(DEVICE_MOUSE, 1),
		0, "routing/computer mouse pinned to port 0")
	_eq(pc._libretro_port_for(DEVICE_JOYPAD, 1),
		1, "routing/computer pad keeps its socket")
	_eq(pc._libretro_port_for(DEVICE_KEYBOARD, 1),
		1, "routing/computer keyboard keeps its socket")
	# ...but the GAME PORT does drive port 0: a DOS or Amiga core reads its one
	# joystick there, and a pad announced on port 2 is a pad the game never sees.
	# Narrow on purpose — pinning every joypad socket would break the machines
	# that really do have two.
	#
	# Instantiated and added rather than built with _system(): which socket is the
	# game port is the MODEL's to say, and a bare RetroSystem has no model. Adding
	# it runs _ready, which loads one — no frame needed.
	var tower := preload("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	tower.systemid = "dos"
	add_child(tower)
	_eq(tower._libretro_port_for(DEVICE_JOYPAD, 2),
		0, "routing/computer game port drives port 0")
	_eq(tower._libretro_port_for(DEVICE_JOYPAD, 1),
		1, "routing/its other sockets are untouched")
	tower.queue_free()
	# ...but does not occupy it: its keys are global to port 0 regardless, and
	# claiming a numbered port would take the slot the mouse needs.
	_ok(not pc._claims_port_device(DEVICE_KEYBOARD), "routing/computer keyboard claims no port")
	_ok(pc._claims_port_device(DEVICE_MOUSE), "routing/computer mouse claims a port")
	pc.free()

	var console := _system("nes")
	_eq(console._libretro_port_for(DEVICE_MOUSE, 1),
		1, "routing/console mouse keeps its socket")
	_ok(console._claims_port_device(DEVICE_KEYBOARD), "routing/console keyboard claims a port")
	_ok(console._claims_port_device(DEVICE_LIGHTGUN), "routing/console gun claims a port")
	console.free()


# ---------------------------------------------------------------------------
# The cached selection the options panel reads back.
# ---------------------------------------------------------------------------

func _test_port_device_cache() -> void:
	var sys := _system()
	# Deep-copied: the fixtures are consts shared with the other cases, and the
	# cache is written in place.
	sys._controller_info = FCEUMM_PORTS.duplicate(true)

	sys.set_controller_port_device(1, 258)
	_eq(sys._controller_info[1]["current_id"], 258, "cache/port 2 shows the Zapper")
	_ok(not sys._controller_info[0].has("current_id"), "cache/port 1 untouched")

	# A port the core did not declare must not invent an entry or disturb one.
	sys.set_controller_port_device(9, 513)
	_eq(sys._controller_info.size(), 3, "cache/unknown port adds nothing")
	_eq(sys._controller_info[1]["current_id"], 258, "cache/unknown port leaves port 2 alone")

	sys.free()


# ---------------------------------------------------------------------------
# Which cabinet socket holds a peripheral. The socket is not the libretro port:
# a saved room that recorded the port put two peripherals in one socket.
# ---------------------------------------------------------------------------

func _test_cabinet_lookup() -> void:
	var sys := _system()
	var pad := FakeSeated.new()
	var stray := FakeSeated.new()
	sys._port_controllers = [null, pad, null, null]

	_eq(sys.cabinet_port_of(pad), 1, "cabinet/finds the socket")
	_eq(sys.cabinet_port_of(stray), -1, "cabinet/absent peripheral")
	_eq(sys.port_holder(1), pad, "cabinet/holder of an occupied socket")
	_eq(sys.port_holder(0), null, "cabinet/holder of an empty socket")
	_eq(sys.port_holder(9), null, "cabinet/holder past the end")
	_eq(sys.port_holder(-1), null, "cabinet/holder below zero")

	pad.free()
	stray.free()
	sys.free()


# ---------------------------------------------------------------------------
# What the seated media says about the run: its label, its system and its save.
# ---------------------------------------------------------------------------

func _test_seated_content() -> void:
	var sys := _system()
	sys.rom_path = "C:/roms/nes/Duck Hunt (World).nes"

	# Nothing seated: the file on disk is all there is to go on.
	_eq(sys._content_label(), "Duck Hunt (World)", "content/label falls back to the file")
	_eq(sys._resolve_systemid(), "nes", "content/system falls back to the machine")
	_eq(sys._memcards._sram_slot(), "", "content/no cart means no save slot")
	_eq(sys._memcards._compose_sram_path("fceumm"), "", "content/no cart means no save path")

	var cart := FakeSeated.new()
	cart.game_label = "Duck Hunt"
	cart.save_id = "dh-001"
	cart.systemid = "fds"
	sys._snapped_cartridge = cart

	_eq(sys._content_label(), "Duck Hunt", "content/cart names the game")
	# A Famicom Disk System disc in a NES: the disc decides, because that is what
	# picks the core and the save location.
	_eq(sys._resolve_systemid(), "fds", "content/cart names the system")
	_eq(sys._memcards._sram_slot(), "dh-001", "content/cart names the save slot")
	_ok(not sys._memcards._compose_sram_path("fceumm").is_empty(), "content/cart has a save path")

	# A blank label is not a label — the file name is better than an empty plate.
	cart.game_label = ""
	_eq(sys._content_label(), "Duck Hunt (World)", "content/blank cart label falls back")
	cart.systemid = ""
	_eq(sys._resolve_systemid(), "nes", "content/blank cart system falls back")

	# No core resolved and no ROM are both "nothing to persist", not a path built
	# out of empty strings.
	_eq(sys._memcards._compose_sram_path(""), "", "content/no core means no save path")
	sys.rom_path = ""
	_eq(sys._memcards._compose_sram_path("fceumm"), "", "content/no rom means no save path")

	cart.free()
	sys.free()


# ---------------------------------------------------------------------------
# Taking the media out. A console does not stop when a disc leaves the drive —
# that is what lets Monster Rancher read an arbitrary CD, and what keeps a
# multi-disc game alive between discs — and a floppy machine is the same. Only a
# cartridge deck stops, where pulling the cart takes the program away.
# ---------------------------------------------------------------------------

func _test_media_removal() -> void:
	var tray := _system("playstation")
	tray._disc_loader = MediaDimensions.LOADER_TRAY
	_ok(tray._media_survives_removal(), "media/a tray console keeps running")
	tray.free()

	var slot := _system("wii")
	slot._disc_loader = MediaDimensions.LOADER_SLOT
	_ok(slot._media_survives_removal(), "media/a slot console keeps running")
	slot.free()

	# A Neo Geo CD loads under a lift-up lid, the same motion as the PlayStation
	# above. Without a DISC_DIAMETERS row it was not a disc system at all and its
	# discs were moulded as cartridges.
	_ok(MediaDimensions.is_disc_system("neo_geo_cd"), "media/the Neo Geo CD is a disc system")
	_eq(MediaDimensions.disc_loader("neo_geo_cd"), MediaDimensions.LOADER_TRAY,
		"media/and loads under a lid")

	# No disc loader at all, but the media is a floppy — the drive is a slot in
	# the tower's bezel and the machine runs on regardless.
	var floppy := _system("dos")
	_eq(floppy._disc_loader,
		MediaDimensions.LOADER_NONE, "media/a floppy machine has no disc loader")
	_ok(floppy._media_survives_removal(), "media/a floppy machine keeps running")
	floppy.free()

	# The cartridge IS the program. Pulling it stops the machine, as it always has.
	var cart := _system("nes")
	_ok(not cart._media_survives_removal(), "media/a cartridge deck stops")
	cart.free()

	# Whether a swap can reach the core is answered by the core's .info file
	# before the core is even loaded. The live disk_control_ready signal lands
	# some frames into the run, and a disc pulled before it did used to take the
	# no-disk-control path and power the machine off.
	var psx := _system("playstation")
	psx.core_name = "pcsx_rearmed"
	_ok(psx._supports_disk_control(), "disk control/declared by a PS1 core")
	psx.free()

	var amiga := _system("commodore_amiga")
	amiga.core_name = "puae"
	_ok(amiga._supports_disk_control(), "disk control/declared by a floppy core")
	amiga.free()

	var nes := _system("nes")
	nes.core_name = "fceumm"
	_ok(not nes._supports_disk_control(), "disk control/not declared by a cartridge core")
	# The running core is still the better witness: a core that reports the
	# interface at runtime is believed whatever its .info file says.
	nes._has_disk_control = true
	_ok(nes._supports_disk_control(), "disk control/the live answer wins")
	nes.free()

	var unknown := _system("playstation")
	unknown.core_name = "not_a_real_core"
	_ok(not unknown._supports_disk_control(), "disk control/an unknown core claims nothing")
	unknown.free()

	_test_lid_ops()


# ---------------------------------------------------------------------------
# The lid is the drive's sensor: the core's tray follows the LID, not the disc.
# Open it, swap freely, shut it — the core sees one tray cycle and one disc, so
# the swap trick works and a multi-disc game is never told anything else.
# ---------------------------------------------------------------------------

func _test_lid_ops() -> void:
	const NONE := RetroSystem.DISK_OP_NONE
	const EJECT := RetroSystem.DISK_OP_EJECT
	const CLOSE := RetroSystem.DISK_OP_CLOSE

	# Lid up over a drive the core thinks is shut: that is the moment the core
	# learns the disc is unavailable.
	_eq(RetroSystem._tray_op_for(true, false, true), EJECT, "lid/opening ejects")
	_eq(RetroSystem._tray_op_for(true, false, false), EJECT, "lid/opening an empty drive ejects")
	# Already open as far as the core is concerned — saying it twice would be a
	# second tray cycle the game can see.
	_eq(RetroSystem._tray_op_for(true, true, true), NONE, "lid/opening again says nothing")

	# Shutting hands over whatever is in the well, including the disc that was
	# already mounted: a real drive re-reads what it finds.
	_eq(RetroSystem._tray_op_for(false, true, true),
		CLOSE, "lid/shutting over a disc hands it over")
	_eq(RetroSystem._tray_op_for(false, false, true),
		CLOSE, "lid/shutting over the same disc still re-reads")
	# Nothing in the well: the core keeps waiting with its tray open rather than
	# being told to close on an empty drive.
	_eq(RetroSystem._tray_op_for(false, true, false),
		NONE, "lid/shutting over an empty well says nothing")
	_eq(RetroSystem._tray_op_for(false, false, false),
		NONE, "lid/shutting an empty drive the core thinks is shut")


# ---------------------------------------------------------------------------
# An EXPANDED port — one a multitap fans out to — is a port to the core like any
# other. It used to be bound by an abridged copy of the cabinet path, and the
# abridgement dropped the device translation, so a gun on a multitap reached
# fceumm as a gamepad. Only the expanded half is reachable here: the cabinet half
# seats a plug into a snap zone and adds a physics exception.
# ---------------------------------------------------------------------------

func _test_expanded_port_binding() -> void:
	var sys := _system()
	sys._controller_info = FCEUMM_PORTS.duplicate(true)
	var gun := FakeSeated.new()
	gun.device_type = DEVICE_LIGHTGUN

	sys.attach_expanded_controller(1, gun)
	_eq(sys._controller_info[1].get("current_id", -1),
		258, "expanded/a gun is announced as the core's gun")
	_eq(sys.port_holder(1), gun, "expanded/the port remembers the peripheral")
	# No cabinet socket, so nothing is recorded as a plug — that array belongs to
	# the sockets, and a stray entry would be released as if a cord were pulled.
	_ok(sys._port_plugs[1] == null, "expanded/no cabinet plug recorded")

	sys.detach_expanded_controller(1, gun)
	_eq(sys._controller_info[1]["current_id"], 0, "expanded/unplugging clears the port")
	_eq(sys.port_holder(1), null, "expanded/unplugging frees the holder")

	# A port below zero is not a port; binding one used to be caught by the
	# caller, and _bind_port is now the only thing that can catch it.
	sys.attach_expanded_controller(-1, gun)
	_ok(sys.port_holder(0) == null, "expanded/a negative port binds nothing")

	gun.free()
	sys.free()


# ---------------------------------------------------------------------------
# What a system's slot and ports will accept. One rule, two tables — an object
# that names no system is universal, which is what keeps RetroXR's stand-in
# props and unlabelled legacy media working everywhere.
# ---------------------------------------------------------------------------

func _test_belongs_here() -> void:
	var nes := _system("nes")
	var cart := FakeSeated.new()

	cart.systemid = "nes"
	_ok(nes._accepts_media(cart), "belongs/its own media fits")
	cart.systemid = "snes"
	_ok(not nes._accepts_media(cart), "belongs/another system's media does not")
	cart.systemid = ""
	_ok(nes._accepts_media(cart), "belongs/unlabelled media fits anywhere")
	# An object with no systemid property at all — a prop that predates the rule.
	var plain := Node3D.new()
	_ok(nes._accepts_media(plain), "belongs/an object naming no system fits")

	cart.systemid = "snes"
	_ok(not nes._accepts_plug(cart), "belongs/the port gate reads the same way")
	cart.systemid = ""
	_ok(nes._accepts_plug(cart), "belongs/an unlabelled plug fits")
	nes.free()

	# The media table is the console's, and it is not symmetric: a Wii takes a
	# GameCube disc, a GameCube does not take a Wii one.
	var wii := _system("wii")
	cart.systemid = "gamecube"
	_ok(wii._accepts_media(cart), "belongs/a Wii takes a GameCube disc")
	# ...and the front of the machine agrees with the tray. This case used to
	# read the other way, pinning an empty port table, and the cost of that
	# showed up the day a GameCube-to-Game Boy Advance lead was carried over to
	# the one console in the room that could use it and was silently refused.
	_ok(wii._accepts_plug(cart), "belongs/and a GameCube plug in its front sockets")
	wii.free()

	var cube := _system("gamecube")
	cart.systemid = "wii"
	_ok(not cube._accepts_media(cart), "belongs/a GameCube refuses a Wii disc")
	cube.free()

	var gba := _system("game_boy_advance")
	cart.systemid = "game_boy"
	_ok(gba._accepts_media(cart), "belongs/a GBA takes a Game Boy cart")
	gba.free()

	plain.free()
	cart.free()


# ---------------------------------------------------------------------------
# Which core and which directory this machine runs from. Every path asks these
# two — the options panel, netplay, the SRAM paths, achievements and the power
# button — so a machine that answered them itself would run a different core
# from the one the panel was editing.
# ---------------------------------------------------------------------------

func _test_core_resolution() -> void:
	var sys := _system("nes")

	sys.core_name = "some_core"
	_eq(sys._resolve_core(), "some_core", "resolve/a named core wins")

	# The fallback reads core_defaults.json, and NOTHING seeds that file --
	# OPTIONS > Cores writes it when a player picks a default, and until someone
	# does there is no file and every system resolves to "". So asserting that a
	# real system has a non-empty default passes on a machine that has been used
	# and fails on every fresh one, which is what CI reported.
	#
	# Write a default of its own instead, under a systemid no console uses, and
	# put the file back byte for byte. CoreDefaults.default_path() is derived from
	# the core root and cannot be pointed at a scratch dir, so the player's real
	# file is the only one there is to write.
	var path := CoreDefaults.default_path()
	var had := FileAccess.file_exists(path)
	var before := FileAccess.get_file_as_bytes(path) if had else PackedByteArray()
	var seeded := CoreDefaults.new()
	seeded.setup(path)
	seeded.set_default_core(_RESOLVE_SYS, "selftest_core")
	seeded.save()

	sys.core_name = ""
	sys.systemid = _RESOLVE_SYS
	_eq(sys._resolve_core(),
		"selftest_core", "resolve/a system with a default falls back to it")
	sys.systemid = ""
	_eq(sys._resolve_core(), "", "resolve/nothing to go on")

	if had:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(before)
		f.close()
	else:
		DirAccess.remove_absolute(path)
	_eq(FileAccess.file_exists(path),
		had, "resolve/the player's own defaults are put back")
	if had:
		_ok(FileAccess.get_file_as_bytes(path) == before, "resolve/byte for byte")

	sys.core_directory = "C:/somewhere/libretro"
	_eq(sys._resolve_dir(), "C:/somewhere/libretro", "resolve/a named directory wins")
	sys.core_directory = ""
	_eq(sys._resolve_dir(),
		CoreDownloadManager.default_core_root(), "resolve/the directory falls back to the core root")

	sys.free()


# ---------------------------------------------------------------------------
# The forced-options merge. A shell pins the options its screen needs before
# every launch, into the same <core>.opt file the running core loads and the
# options panel edits — so the merge has to leave the player's own keys alone,
# and it must not rewrite the file when nothing moved (a rewrite reorders it).
# ---------------------------------------------------------------------------

func _test_forced_options_merge() -> void:
	var root := "user://__system_selftest"
	var core := "selftest_core"
	var path := CoreOptionsStore.opt_path(root, core)

	_ok(not CoreOptionsStore.merge_values(root, core, {}), "forced/nothing forced writes nothing")
	_ok(not FileAccess.file_exists(path), "forced/and creates no file")

	# The player's own settings, as a run would have left them.
	CoreOptionsStore.save_values(root, core, {"user_key": "mine", "vb_3dmode": "anaglyph"})

	_ok(CoreOptionsStore.merge_values(root, core, {"vb_3dmode": "sidebyside"}),
		"forced/a new pin is written")
	var after := CoreOptionsStore.load_values(root, core)
	_eq(after.get("vb_3dmode", ""), "sidebyside", "forced/the pin took")
	_eq(after.get("user_key", ""), "mine", "forced/the player's own key survives")

	# Already pinned: no write at all, so the file keeps its bytes and its order.
	var before_time := FileAccess.get_modified_time(path)
	_ok(not CoreOptionsStore.merge_values(root, core, {"vb_3dmode": "sidebyside"}),
		"forced/an unchanged pin rewrites nothing")
	_eq(FileAccess.get_modified_time(path), before_time, "forced/the file was left alone")

	# Values arrive from a model as ints and bools as often as strings.
	_ok(CoreOptionsStore.merge_values(root, core, {"citra_factor_3d": 0}),
		"forced/a non-string value is written")
	_eq(CoreOptionsStore.load_values(root, core).get("citra_factor_3d", ""),
		"0", "forced/and reads back as its text")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CoreOptionsStore.opt_dir(root)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root))
	_ok(not FileAccess.file_exists(path), "forced/cleaned up")


# ---------------------------------------------------------------------------
# Save states: the pure half — ids, paths, the thumbnail, and the disk round
# trip. Capture needs a live core and lives in Tools/state/state_probe.tscn; what is
# here is everything that decides WHERE a state goes and WHAT it looks like.
# ---------------------------------------------------------------------------

func _test_state_paths() -> void:
	# The id is the row's identity and outlives every overwrite, so it has to be
	# unique per capture and recognisable on sight.
	var seen := {}
	for i in range(200):
		seen[StatePaths.mint_id()] = true
	_eq(seen.size(), 200, "state/200 ids are 200 ids")
	var one := StatePaths.mint_id()
	_ok(StatePaths.is_state_id(one), "state/an id reads as one", one)
	_ok(not StatePaths.is_state_id("autosave"), "state/a stray file does not")
	_ok(not StatePaths.is_state_id("1787000000000"), "state/nor does a bare timestamp")
	_ok(not StatePaths.is_state_id("../../etc/passwd"), "state/nor does a path traversal")

	# The three files are siblings sharing a basename: that is what lets delete
	# find them without an index, and what lets an overwrite keep its picture.
	var sp := StatePaths.state_path("fceumm", "C:/roms/nes/Game (USA).nes", one)
	var shot := StatePaths.shot_path("fceumm", "C:/roms/nes/Game (USA).nes", one)
	var meta := StatePaths.meta_path("fceumm", "C:/roms/nes/Game (USA).nes", one)
	_eq([sp.get_basename(), shot.get_basename(), meta.get_basename()],
		[sp.get_basename(), sp.get_basename(), sp.get_basename()],
		"state/paths differ only by extension")
	_eq(sp.get_extension(), "state", "state/the state is a .state")
	_ok(sp.contains("fceumm"), "state/keyed by core", sp)
	_ok(sp.contains("Game (USA)"), "state/and by game", sp)
	# Two cores running the same game keep separate folders — a state is only
	# ever meaningful to the core that wrote it.
	_ok(StatePaths.game_dir("nestopia", "C:/roms/nes/Game (USA).nes") != StatePaths.game_dir("fceumm", "C:/roms/nes/Game (USA).nes"),
		"state/another core is another folder")
	# ...but the same game reached by a different path is the same folder, which
	# is what lets a ROM be moved without losing its states.
	_eq(StatePaths.game_dir("fceumm", "D:/elsewhere/Game (USA).nes"),
		StatePaths.game_dir("fceumm", "C:/roms/nes/Game (USA).nes"),
		"state/the same game moved is the same folder")


func _test_state_thumbnail() -> void:
	# The core hands over RGBA8 with every pixel at alpha 0 — it draws opaque and
	# never writes the channel. A thumbnail that keeps it saves a fully
	# transparent rectangle, which is what this shipped as the first time.
	var frame := Image.create(256, 224, false, Image.FORMAT_RGBA8)
	frame.fill(Color(0.2, 0.6, 0.9, 0.0))
	var thumb := StatePaths.thumbnail(frame)
	_eq(thumb.get_format(), Image.FORMAT_RGB8, "thumb/alpha is dropped")
	_eq(thumb.get_pixel(thumb.get_width() / 2, thumb.get_height() / 2).a,
		1.0, "thumb/the picture survives it")
	# Downscale keeps the aspect: a 4:3 frame must not come back square.
	_eq(thumb.get_width(), StatePaths.THUMB_MAX_W, "thumb/scaled to the box")
	_eq(thumb.get_height(), 168, "thumb/aspect kept")
	_ok(frame.get_width() == 256 and frame.get_format() == Image.FORMAT_RGBA8,
		"thumb/the source is left alone")

	# Never upscaled. Blowing a Game Boy frame up to fill the box only makes it
	# blurry, and the row centres it instead.
	var gb := Image.create(160, 144, false, Image.FORMAT_RGBA8)
	gb.fill(Color(1, 1, 1, 0))
	var small := StatePaths.thumbnail(gb)
	_eq(small.get_size(), Vector2i(160, 144), "thumb/a small frame is left at its size")


func _test_state_disk_round_trip() -> void:
	# A scratch core name, so this writes beside the player's real states without
	# ever being able to collide with one.
	var core := "__state_selftest"
	var rom := "selftest.nes"
	var dir := StatePaths.game_dir(core, rom)
	if DirAccess.dir_exists_absolute(dir):
		for f: String in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute(dir.path_join(f))

	_eq(StatePaths.list_states(core, rom).size(), 0, "disk/nothing is listed to start")

	var id := StatePaths.mint_id()
	var job := StatePaths.Job.new()
	job.state_path = StatePaths.state_path(core, rom, id)
	job.shot_path = StatePaths.shot_path(core, rom, id)
	job.meta_path = StatePaths.meta_path(core, rom, id)
	job.data = "the core".to_utf8_buffer()
	job.shot = Image.create(64, 48, false, Image.FORMAT_RGBA8)
	job.shot.fill(Color(1, 0, 0, 0))
	job.frame = 4242
	job.core = core
	job.rom = rom
	job.created_at = 1000
	_eq(StatePaths.write_job(job), "", "disk/the write reports no error")

	var rows := StatePaths.list_states(core, rom)
	_eq(rows.size(), 1, "disk/one state is listed")
	if rows.size() == 1:
		_eq(rows[0]["state_id"], id, "disk/under its own id")
		_ok(not str(rows[0]["shot"]).is_empty(), "disk/with its picture")
		_eq(int(rows[0]["bytes"]), job.data.size(), "disk/and its size")
	var meta := StatePaths.read_meta(core, rom, id)
	_eq(int(meta.get("frame", -1)), 4242, "disk/the sidecar carries the frame")
	_eq(int(meta.get("created_at", -1)), 1000, "disk/and the birthday")

	# Overwrite: the same id, new contents, and the birthday is NOT restamped —
	# that is what makes a row behave like a slot rather than a new entry.
	job.data = "a longer core image".to_utf8_buffer()
	job.frame = 9999
	job.created_at = 2000
	_eq(StatePaths.write_job(job), "", "disk/the overwrite reports no error")
	_eq(StatePaths.list_states(core, rom).size(), 1, "disk/still one state")
	var meta2 := StatePaths.read_meta(core, rom, id)
	_eq(int(meta2.get("frame", -1)), 9999, "disk/the frame moved on")
	_eq(int(meta2.get("created_at", -1)), 1000, "disk/the birthday did not")
	_ok(int(meta2.get("updated_at", 0)) > 0, "disk/updated_at is stamped")

	# Nothing half-written is ever offered: the promote is a rename, so a .part
	# left behind by a crash is invisible to the list.
	var stray := FileAccess.open(job.state_path + ".part", FileAccess.WRITE)
	stray.store_string("half")
	stray.close()
	_eq(StatePaths.list_states(core, rom).size(), 1, "disk/a .part is not a state")
	DirAccess.remove_absolute(job.state_path + ".part")

	_eq(StatePaths.total_bytes(core, rom), job.data.size() + NetFileTransfer.size_of(job.shot_path),
		"disk/total_bytes counts the picture too")

	_ok(StatePaths.delete_state(core, rom, id), "disk/delete succeeds")
	_eq(StatePaths.list_states(core, rom).size(), 0, "disk/and the list is empty")
	_ok(not FileAccess.file_exists(job.shot_path), "disk/the picture went with it")
	_ok(not FileAccess.file_exists(job.meta_path), "disk/and the sidecar")
	_ok(not StatePaths.delete_state(core, rom, id), "disk/deleting it twice is not a success")
	_ok(not StatePaths.delete_state(core, rom, "../../boot"),
		"disk/nor is deleting something that is not an id")
	DirAccess.remove_absolute(dir)


# ---------------------------------------------------------------------------
# BIOS boot: seeding a default, the table that decides what is offered, and the
# power button's own verdict. What a real core does with an empty disc needs a
# real core and a real BIOS and lives in Tools/cores/bios_boot_probe.tscn.
# ---------------------------------------------------------------------------

func _test_bios_seed() -> void:
	var root := "user://__biosboot_selftest"
	var core := "selftest_core"
	var path := CoreOptionsStore.opt_path(root, core)

	_ok(not CoreOptionsStore.seed_values(root, core, {}), "seed/nothing to seed writes nothing")
	_ok(not FileAccess.file_exists(path), "seed/and creates no file")

	_ok(CoreOptionsStore.seed_values(root, core, {"splash": "enabled"}),
		"seed/a fresh key is written")
	_eq(CoreOptionsStore.load_values(root, core).get("splash", ""),
		"enabled", "seed/the default took")

	# The whole point of a default: the player turns it off and it STAYS off.
	# merge_values would put it back on at the next power-on.
	CoreOptionsStore.set_value(root, core, "splash", "disabled")
	_ok(not CoreOptionsStore.seed_values(root, core, {"splash": "enabled"}),
		"seed/seeding twice writes nothing")
	_eq(CoreOptionsStore.load_values(root, core).get("splash", ""),
		"disabled", "seed/the player's choice survives")

	# A core serialises its WHOLE option set on shutdown, so after one run every
	# key it declares is already in the file. Presence must not be mistaken for
	# "already seeded" or a BIOS installed later would never take effect.
	CoreOptionsStore.save_values(root, core, {"splash": "disabled", "later": "off"})
	_ok(CoreOptionsStore.seed_values(root, core, {"later": "on"}),
		"seed/a key the core already wrote is still seedable")
	var after := CoreOptionsStore.load_values(root, core)
	_eq(after.get("later", ""), "on", "seed/and takes")
	_eq(after.get("splash", ""), "disabled", "seed/without disturbing its neighbours")

	# The record is per (core, key). genesis_plus_gx_bios really is shared by
	# five machines under one core, so the key alone cannot be the identity.
	_ok(CoreOptionsStore.seed_values(root, "other_core", {"later": "on"}),
		"seed/another core's same key is untouched")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		CoreOptionsStore.opt_path(root, "other_core")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CoreOptionsStore.opt_dir(root)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CoreOptionsStore.seeded_path(root)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root))
	_ok(not FileAccess.file_exists(path), "seed/cleaned up")


func _test_neo_geo_cd_cores() -> void:
	var db := CoreInfoDatabase.shared()

	# neocd owns the id outright, so it needs nothing declared to be found.
	var owners: Array[String] = []
	for entry: Dictionary in db.get_by_systemid("neo_geo_cd"):
		owners.append(str(entry.get("corename", "")))
	_ok(owners.has("NeoCD"), "neogeocd/neocd serves it")

	# Geolith reads the CD too — its firmware list declares neocd.zip and
	# neocdz.zip as required — but a core is only offered under a platform it
	# NAMES, so without secondary_systemids it was reachable as an AES only.
	_ok(owners.has("Geolith"), "neogeocd/geolith serves it as well")
	_ok(CoreInfoDatabase.systemids_of(db.get_by_core_name("geolith")).has("neogeo"),
		"neogeocd/and still serves the cartridge Neo Geo")

	# A CHD is the point of the whole platform: the library stores these discs
	# converted, so an extension list without chd files none of them.
	var exts := CoreInfoDatabase.extensions_for_systemid("neo_geo_cd")
	_ok(exts.has("cue"), "neogeocd/reads cue")
	_ok(exts.has("chd"), "neogeocd/reads chd")
	# Geolith contributes only its declared subset, never its whole list.
	_ok(not exts.has("neo"), "neogeocd/does not inherit the cartridge .neo")


## SuperGrafx is not an ExpansionCatalog accessory: it is the PC Engine's own
## enhanced hardware variant, reached the same way Game Gear/Sega CD/32X are —
## a core declares it as a secondary systemid, and the generic Cores > Manager
## scan (cores_view.gd, over the installed core library) and SystemInfo pick it
## up with no code of their own naming it. There was no gap to close here; this
## is the regression guard for the mechanism that already closed it.
func _test_supergrafx_core() -> void:
	var db := CoreInfoDatabase.shared()
	var entry: Dictionary = db.get_by_core_name("mednafen_supergrafx")
	_ok(not entry.is_empty(), "supergrafx/mednafen_supergrafx is a known core")
	_ok(CoreInfoDatabase.systemids_of(entry).has("supergrafx"),
		"supergrafx/and declares the supergrafx systemid")
	_ok(db.is_secondary_systemid("supergrafx"),
		"supergrafx/which is reached only through that declaration")
	_ok(not CoreInfoDatabase.systemids_of(db.get_by_core_name("mednafen_pce_fast")) .has("supergrafx"),
		"supergrafx/mednafen_pce_fast does not declare it — why the recommendation " + "is mednafen_supergrafx and not the lighter core")

	var info := SystemInfo.for_system("supergrafx")
	_ok(info != null, "supergrafx/has its own SystemInfo descriptor")
	_ok(info != null and info.display_name == "PC Engine SuperGrafx",
		"supergrafx/named distinctly from the plain PC Engine")
	_eq(db.get_systemname_for_id("supergrafx"),
		"PC Engine SuperGrafx", "supergrafx/and that name is what the core scan would show a player")


func _test_bios_boot_table() -> void:
	var db := CoreInfoDatabase.shared()
	for key: String in BiosBoot._ROWS:
		var parts := key.split("/", false)
		_eq(parts.size(), 2, "table/%s is keyed core-then-systemid" % key)
		if parts.size() != 2:
			continue
		_ok(not db.get_by_core_name(parts[0]).is_empty(), "table/%s names a real core" % key)
		_ok(ResourceLoader.exists("res://SystemInfo/%s.tres" % parts[1]),
			"table/%s names a real system" % key)
		var row: Dictionary = BiosBoot._ROWS[key]
		_ok(not (row.get("boot_rom", []) as Array).is_empty(), "table/%s declares a boot rom" % key)
		for opt_key: String in (row.get("splash", {}) as Dictionary):
			_ok(not opt_key.strip_edges().is_empty(), "table/%s option %s is named" % [key, opt_key])

	# Keyed on the PAIR. One core, five Sega machines, five different boot ROMs
	# — read by core alone this would offer a Game Gear the Mega Drive's.
	_eq(BiosBoot.entry("genesis_plus_gx", "mega_drive").get("boot_rom", []),
		["bios_MD.bin"], "table/a Mega Drive wants its own boot rom")
	_eq(BiosBoot.entry("genesis_plus_gx", "game_gear").get("boot_rom", []),
		["bios.gg"], "table/a Game Gear wants its own")

	# Measured, and the natural guess is the wrong way round: pcee2 says
	# pcsx2_fast_boot where LRPS2 says pcsx2_fastboot.
	_ok((BiosBoot.entry("pcee2", "playstation2").get("splash", {}) as Dictionary) .has("pcsx2_fast_boot"),
		"table/pcee2 uses fast_boot")
	_ok((BiosBoot.entry("pcsx2", "playstation2").get("splash", {}) as Dictionary) .has("pcsx2_fastboot"),
		"table/pcsx2 uses fastboot")

	# Only the PlayStation reaches a BIOS from an empty slot; measured over
	# sixteen cores, and the rest refuse a blank image or crash on one.
	_eq(BiosBoot.empty_media_extension("pcsx_rearmed", "playstation"),
		"cue", "table/a PlayStation takes a blank disc")
	_eq(BiosBoot.empty_boot_options("mgba", "game_boy_advance").get("mgba_skip_bios"),
		"OFF",
		"table/a cartridge-less GBA pins its real BIOS path")
	_eq(BiosBoot.empty_boot_options("pcsx_rearmed", "playstation").get("pcsx_rearmed_bios"),
		"auto",
		"table/an empty PlayStation pins automatic real BIOS selection")
	_eq(BiosBoot.boot_rom_paths("mgba", "game_boy_advance"),
		["gba_bios.bin"], "table/the GBA fingerprint names its boot ROM")
	_eq(BiosBoot.empty_media_extension("dolphin", "gamecube"),
		"", "table/a GameCube does not")
	_eq(BiosBoot.empty_media_extension("fceumm", "nes"),
		"", "table/nor does a machine with no row")

	_ok(BiosBoot.entry("selftest_core", "nes").is_empty(), "table/an unknown pair offers nothing")
	_ok(BiosBoot.splash_options("selftest_core", "nes").is_empty(), "table/and no splash")
	_ok(BiosBoot.missing_required("selftest_core").is_empty(),
		"table/a core with no .info requires nothing")
	# The pair is required: a core alone names no machine.
	_ok(BiosBoot.entry("pcsx_rearmed", "").is_empty(), "table/no systemid is not a match")


# ---------------------------------------------------------------------------
# The BIOS options are PINNED, and the switch that hands them back.
#
# Two halves of one row and they are reached differently: a loaded game plays
# its boot ROM through `splash`, an empty slot reaches the BIOS through
# `empty_options`, and which one applies is read from what is in the slot.
# ---------------------------------------------------------------------------

func _test_bios_pinned_options() -> void:
	# The empty-slot half. This is the case that used to reach netplay and
	# nothing else: net_boot_spec read it, the local power-on path never did, so
	# a saved mgba_skip_bios = ON skipped the BIOS with nothing to put it back.
	_eq(BiosBoot.pinned_options("mgba", "game_boy_advance", true).get("mgba_skip_bios", ""),
		"OFF",
		"pin/an empty slot pins the boot ROM on")
	_eq(BiosBoot.pinned_options("mgba", "game_boy_advance", true).get("mgba_use_bios", ""),
		"ON",
		"pin/and the BIOS itself in use")

	# The loaded-game half is gated on the boot ROM being installed, so on a box
	# with none it is empty — pinning a core to run a file that is not there
	# turns a machine that played games into a black screen.
	_ok(BiosBoot.pinned_options("selftest_core", "nes", true).is_empty() and BiosBoot.pinned_options("selftest_core", "nes", false).is_empty(),
		"pin/an unknown pair pins nothing either way")

	# Keys only, and both halves of every row for the core: the core manager
	# edits a core with no machine in front of it and has no systemid to ask
	# with.
	var mgba_keys := BiosBoot.pinned_keys_for_core("mgba")
	_ok(mgba_keys.has("mgba_skip_bios") and mgba_keys.has("mgba_use_bios"),
		"pin/a core's key set covers its empty-slot half")
	_ok(BiosBoot.pinned_keys_for_core("genesis_plus_gx").has("genesis_plus_gx_bios"),
		"pin/one core's five Sega machines fold into one key")
	_ok(BiosBoot.pinned_keys_for_core("selftest_core").is_empty(),
		"pin/a core with no row pins no keys")
	_ok(BiosBoot.pinned_keys_for_core("").is_empty(), "pin/and no core names none")
	# A key from ANOTHER core's row must not leak in — pcee2 and pcsx2 spell the
	# same switch differently, and one table read by core alone would offer each
	# the other's no-op.
	_ok(not BiosBoot.pinned_keys_for_core("pcsx2").has("pcsx2_fast_boot"),
		"pin/nor another core's spelling of the same switch")


## The system half, with a real firmware presence behind it.
##
## pcsx2 is the machine this can be run for: its boot ROM requirement is a
## DIRECTORY with no md5 (`pcsx2/bios`), so the test can create one and get a
## genuine PRESENT — every other row wants a dump whose hash cannot be faked,
## and without a present boot ROM every assertion below is a green that could
## not have gone red.
##
## It writes the player's real system dir, so it creates the directory only if
## it was not already there and removes exactly what it made.
func _test_bios_pins_reach_the_opt_file() -> void:
	var core := "pcsx2"
	var systemid := "playstation2"
	var key := "pcsx2_fastboot"
	var dest := FirmwareRequirements.destination(core, "pcsx2/bios")
	var made_dir := not DirAccess.dir_exists_absolute(dest)
	if made_dir and DirAccess.make_dir_recursive_absolute(dest) != OK:
		_ok(false, "pin/could create a boot ROM directory to test against")
		return
	FirmwareState.shared().invalidate(core, "pcsx2/bios")

	var was_override: bool = AppPrefs.bios_boot_override
	var root := "user://__biospin_selftest"
	var sys := _system(systemid)
	sys.rom_path = "/roms/ps2/game.iso"

	_ok(BiosBoot.boot_rom_present(core, systemid), "pin/the boot ROM reads as present")

	AppPrefs.bios_boot_override = false
	_eq(sys._all_forced_options(core).get(key, ""),
		"disabled", "pin/a loaded game pins its boot animation on")

	# The pin has to beat what is already saved. A core serialises its whole
	# option set on shutdown, so "already in the file" is the normal case and a
	# write-once default would never fix a machine that had skipped its BIOS.
	CoreOptionsStore.save_values(root, core, {key: "enabled"})
	sys._apply_forced_core_options(root, core)
	_eq(CoreOptionsStore.load_values(root, core).get(key, ""),
		"disabled", "pin/and overwrites a saved value that skipped it")

	AppPrefs.bios_boot_override = true
	_ok(not sys._all_forced_options(core).has(key), "pin/the override hands the key back")
	CoreOptionsStore.save_values(root, core, {key: "enabled"})
	sys._apply_forced_core_options(root, core)
	_eq(CoreOptionsStore.load_values(root, core).get(key, ""),
		"enabled", "pin/and the player's value then survives a launch")

	AppPrefs.bios_boot_override = was_override
	sys.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		CoreOptionsStore.opt_path(root, core)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CoreOptionsStore.opt_dir(root)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root))
	if made_dir:
		DirAccess.remove_absolute(dest)
		FirmwareState.shared().invalidate(core, "pcsx2/bios")
	_ok(made_dir == (not DirAccess.dir_exists_absolute(dest)), "pin/cleaned up")


func _test_power_on_verdict() -> void:
	var none: Array[Dictionary] = []

	var no_core := RetroSystem._power_on_verdict("", "nes", "/roms/a.nes", none, "")
	_ok(not no_core["start"], "verdict/no core refuses")
	_eq(no_core["title"], "No core installed", "verdict/and says so")

	var running := RetroSystem._power_on_verdict("fceumm", "nes", "/roms/a.nes", none, "")
	_ok(running["start"], "verdict/a game inserted starts")
	_eq(running["rom"], "/roms/a.nes", "verdict/with that game")

	var empty := RetroSystem._power_on_verdict("fceumm", "nes", "", none, "")
	_ok(not empty["start"], "verdict/an empty slot refuses when the machine cannot boot")
	_eq(empty["title"], "No game inserted", "verdict/with the long-standing card")
	_ok(str(empty["description"]).contains("cartridge"), "verdict/worded for a cartridge")
	_eq(empty["rom"], "", "verdict/and nothing in the slot")

	# The wording follows the machine, not the core. Untested before this.
	var disc := RetroSystem._power_on_verdict("pcsx_rearmed", "playstation", "", none, "")
	_ok(str(disc["description"]).contains("disc"), "verdict/worded for a disc")

	# The substitution: a blank image was resolved, so the machine starts on it.
	var bios := RetroSystem._power_on_verdict(
		"pcsx_rearmed", "playstation", "", none, "/tmp/no_disc.cue")
	_ok(bios["start"], "verdict/an empty slot with a blank disc starts")
	_eq(bios["rom"], "/tmp/no_disc.cue", "verdict/on the blank disc")

	# A required BIOS blocks the run whether or not a game is in — the core
	# cannot start either way, and a black screen explains neither.
	var missing: Array[Dictionary] = [{
		"path": "pcsx2/bios", "desc": "'pcsx2/bios' folder",
		"dest": "/root/system/pcee2/pcsx2/bios",
	}]
	var no_bios := RetroSystem._power_on_verdict(
		"pcee2", "playstation2", "/roms/g.iso", missing, "")
	_ok(not no_bios["start"], "verdict/a missing required bios refuses")
	_eq(no_bios["title"], "BIOS required", "verdict/and names the fault")
	_ok(str(no_bios["description"]).contains("pcsx2/bios"), "verdict/names the file")
	_ok(str(no_bios["description"]).contains("BIOS / Extras"), "verdict/and where to get it")
	# The card is 520x132 px at 1400 px/m. An absolute system path overflowed it
	# top and bottom and clipped the instruction clean off — caught by rendering
	# it, not by any assertion, so the length is pinned here now.
	_ok(str(no_bios["description"]).split("\n").size() == 2, "verdict/says it in two short lines")
	for line: String in str(no_bios["description"]).split("\n"):
		_ok(line.length() <= 52, "verdict/line fits the card: %s" % line)
	_ok(not str(no_bios["description"]).contains("more"),
		"verdict/one missing file is not counted up")

	var two: Array[Dictionary] = [missing[0], {
		"path": "pcsx2/resources", "desc": "'pcsx2/resources' folder",
		"dest": "/root/system/pcee2/pcsx2/resources",
	}]
	var counted := RetroSystem._power_on_verdict("pcee2", "playstation2", "/roms/g.iso", two, "")
	_ok(str(counted["description"]).contains("(+1 more)"), "verdict/two missing files are counted")

	# Order matters: a machine that is both empty AND missing its BIOS is told
	# about the BIOS, which is the one the player cannot fix from where they
	# stand by reaching for a cartridge.
	_eq(RetroSystem._power_on_verdict("pcee2", "playstation2", "", missing, "")["title"],
		"BIOS required",
		"verdict/a missing bios outranks an empty slot")


# ---------------------------------------------------------------------------
# Which machines belong to one replicated linked session.
# ---------------------------------------------------------------------------

func _test_net_link_group_merge() -> void:
	var console := Node.new()
	var gba1 := Node.new()
	var gba2 := Node.new()
	var gba3 := Node.new()
	var unrelated := Node.new()
	var buses: Array = [
		[{"machine": console}, {"machine": gba1}],
		[{"machine": console}, {"machine": gba2}],
		[{"machine": gba2}, {"machine": gba3}],
		[{"machine": unrelated}],
	]
	var group := RetroSystem.merge_link_buses(console, buses)
	_eq(group[0], console, "link-group/the anchor stays first")
	_eq(group.size(), 4, "link-group/every directly cabled machine is included")
	_ok(group.has(gba2), "link-group/a second controller-port cable is not lost")
	_ok(group.has(gba3), "link-group/transitively linked machines are included")
	_ok(not group.has(unrelated), "link-group/an unrelated cable is excluded")
	console.free()
	gba1.free()
	gba2.free()
	gba3.free()
	unrelated.free()


# ---------------------------------------------------------------------------
# What the console is told about its memory card slot.
#
# Two questions that look like one. What KIND of card the slot holds is
# pcsx_rearmed_memcard1, and it gates the core's save buffer, so it is fixed for
# the run. Whether a card is IN that slot is pcsx_rearmed_memcard1_inserted,
# which touches nothing but what the SIO answers and moves whenever a hand does.
#
# Before the second key existed the room could only blank SAVE_RAM, and 128 KB
# of zeroes is a card -- merely an unformatted one. A game whose card was pulled
# mid-play offered to format it instead of saying there was no card in the slot.
# ---------------------------------------------------------------------------

func _test_memcard_presence() -> void:
	# Instantiated and added rather than built with _system(): whether a machine
	# takes cards is asked of the MODEL first, and a bare RetroSystem has none, so
	# it answers no to everything. Adding it runs _ready, which loads one.
	var psx := preload("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	psx.systemid = "playstation"
	add_child(psx)

	# Nothing seated: the slot is typed absent AND reported empty. Both, because
	# they answer to different cores -- one built before the presence key shipped
	# reads only the first, and must still see an empty slot.
	var empty := psx._removable_media_options("pcsx_rearmed")
	_eq(empty.get("pcsx_rearmed_memcard1", ""),
		"none", "memcard/an empty slot is typed absent")
	_eq(empty.get("pcsx_rearmed_memcard1_inserted", ""),
		"disabled", "memcard/and reported empty")
	_eq(empty.get("pcsx_rearmed_memcard2", ""),
		"none", "memcard/the PlayStation's second slot is always absent")
	# A PlayStation shows ONE slot, whatever the cabinet has room for. The second
	# zone exists in the scene for the consoles that take two, and must stay shut
	# on this one.
	_eq(psx.card_slot_count(), 1, "memcard/a PlayStation has one slot")
	_eq(psx.card_family(), "playstation", "memcard/of the PlayStation family")

	# A card seated before the machine starts.
	var card := Node3D.new()
	psx._memcards._snapped_memcards[0] = card
	var seated := psx._removable_media_options("pcsx_rearmed")
	_eq(seated.get("pcsx_rearmed_memcard1", ""),
		"libretro", "memcard/a seated card types the slot")
	_eq(seated.get("pcsx_rearmed_memcard1_inserted", ""),
		"enabled", "memcard/and is reported present")

	# Only pcsx_rearmed has these keys, and only a machine that takes cards has a
	# slot. Pinning them anywhere else would write keys into another core's file.
	_ok(psx._removable_media_options("swanstation").is_empty(),
		"memcard/another core is told nothing")
	var nes := preload("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	nes.systemid = "nes"
	add_child(nes)
	_ok(nes._removable_media_options("pcsx_rearmed").is_empty(),
		"memcard/a cartridge console is told nothing")

	# The runtime half. It reaches for the live core, so on a machine that is not
	# running it must do nothing at all rather than fault -- which is also what
	# guards the case where the option arrives before a core exists to take it.
	psx._memcards._set_card_presence(0, false)
	_ok(not psx.is_powered_on, "memcard/presence on a machine that is off does nothing")

	# A GameCube shows TWO slots, and takes a different family of card. The
	# family is what keeps the two apart: every card is in one "memory_card"
	# group, which scene persistence and the netplay sync both rely on, so
	# splitting the group was never an option.
	var gc := preload("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	gc.systemid = "gamecube"
	add_child(gc)
	_eq(gc.card_slot_count(), 2, "memcard/a GameCube has two slots")
	_eq(gc.card_family(), "gamecube", "memcard/of the GameCube family")
	_ok(gc._removable_media_options("pcsx_rearmed").is_empty(),
		"memcard/and is told no pcsx_rearmed keys")

	# A Wii takes GameCube cards, which is the whole reason a family is not a
	# systemid: it plays GameCube discs and writes to the same card.
	#
	# Asked of the DESCRIPTOR rather than of a spawned Wii. Standing one up here
	# loads its shell and hangs its flap hinges, and tearing that down at the end
	# of the suite segfaults the engine on the way out -- which makes the exit
	# code, the thing this file exists to provide, meaningless.
	var wii_info := SystemInfo.for_system("wii")
	_eq(wii_info.card_family, "gamecube", "memcard/a Wii takes GameCube cards")
	_eq(wii_info.card_slots, 2, "memcard/in two slots")
	_eq(CardFormats.for_system("wii").id(),
		"gamecube", "memcard/resolving to the GameCube format")

	# The gate that stops a card going into the wrong machine.
	var gc_card := preload("res://Scenes/Objects/media/gc_memory_card.tscn") 		.instantiate() as MemoryCard
	var ps_card := preload("res://Scenes/Objects/media/memory_card.tscn") 		.instantiate() as MemoryCard
	_eq(gc_card.family, "gamecube", "memcard/a GameCube card knows its family")
	_eq(ps_card.family, "playstation", "memcard/and a PlayStation card knows its own")
	_ok(gc._accepts_card(gc_card), "memcard/a GameCube takes a GameCube card")
	_ok(not gc._accepts_card(ps_card), "memcard/but not a PlayStation card")
	_ok(psx._accepts_card(ps_card), "memcard/a PlayStation takes its own")
	_ok(not psx._accepts_card(gc_card), "memcard/but not a GameCube card")

	# Paths are keyed by FAMILY, so a Wii and a GameCube reach the same card.
	_eq(SramPaths.cards_dir(wii_info.card_family),
		SramPaths.cards_dir(gc.card_family()),
		"memcard/a Wii and a GameCube share a card folder")
	_ok(SramPaths.cards_dir("gamecube") != SramPaths.cards_dir("playstation"),
		"memcard/which is not the PlayStation's")

	gc_card.free()
	ps_card.free()
	card.free()
	nes.queue_free()
	gc.queue_free()
	psx.queue_free()


# ── Power LED ─────────────────────────────────────────────────────────────────
#
# The lit lens and its companion glow, shared by RetroSystemModel since the NES
# and the PlayStation each carried a line-for-line copy. Nothing tested either
# copy, so a lens that never lit, or one left burning after power-off, would
# have shipped -- and the two consoles drive theirs at different energies for a
# measured reason, which is exactly the kind of constant a shared helper can
# quietly flatten.

func _test_power_led() -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	if sys_scene == null:
		return
	for spec in [["playstation", 1.0], ["nes", 3.0]]:
		var systemid: String = spec[0]
		var want_energy: float = spec[1]
		var sys: Node3D = sys_scene.instantiate()
		sys.systemid = systemid
		add_child(sys)
		for i in range(20):
			await get_tree().process_frame

		var model: Node3D = sys.find_child("Shell", true, false)
		model = model.get_parent() if model != null else null
		if model == null or not model.has_method("set_power_light"):
			sys.queue_free()
			continue

		var mats: Array = model.get("_power_light_mats")
		_ok(mats != null and mats.size() > 0,
			"led/%s has an emissive lens" % systemid, "got %s" % ("null" if mats == null else str(mats.size())))
		if mats == null or mats.is_empty():
			sys.queue_free()
			continue

		var lens := mats[0] as StandardMaterial3D
		var glow := model.get("_power_light_glow") as OmniLight3D

		model.set_power_light(false)
		_ok(is_equal_approx(lens.emission_energy_multiplier, 0.0),
			"led/%s is dark when off" % systemid, str(lens.emission_energy_multiplier))
		_ok(glow == null or not glow.visible, "led/%s hides its glow when off" % systemid)

		model.set_power_light(true)
		# The energy is per console, not a shared constant: the NES's red lens
		# needs 3.0 where the PlayStation's green needs 1.0 for the same apparent
		# brightness. A helper that hard-coded one would light one of them wrong.
		_ok(is_equal_approx(lens.emission_energy_multiplier, want_energy),
			"led/%s lights at its own energy" % systemid, "got %.2f want %.2f" % [lens.emission_energy_multiplier, want_energy])
		_ok(glow != null and glow.visible, "led/%s shows its glow when on" % systemid)
		# Emission colour is the lens's own, and must survive being driven.
		_ok(lens.emission_enabled and lens.emission.get_luminance() > 0.0,
			"led/%s keeps its emission colour" % systemid, str(lens.emission))

		model.set_power_light(false)
		_ok(is_equal_approx(lens.emission_energy_multiplier, 0.0),
			"led/%s goes dark again" % systemid)
		sys.queue_free()
		await get_tree().process_frame


# ── Save-state gates ──────────────────────────────────────────────────────────
#
# Everything the save-state path decides BEFORE it needs a core, which is all of
# it bar the serialize itself. capture_state and load_state both promise in their
# docstrings to "answer exactly once, always" -- a panel button stays greyed for
# ever on a missing answer and double-fires on two, and neither had a test.
#
# Written against the code as it stands, deliberately, so it can be run before
# and after the block moves out of RetroSystem. A characterisation test written
# afterwards only proves the new code agrees with itself.

func _test_save_state_gates() -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	if sys_scene == null:
		return
	var sys: Node3D = sys_scene.instantiate()
	sys.systemid = "nes"
	# NAMED, not resolved. Every gate below asks _resolve_core(), which falls back
	# to the player's core_defaults.json -- so on a machine where nobody has
	# picked a default the core came back empty, load_state answered "no game is
	# inserted" about a machine holding one, and the case about a core that cannot
	# serialize skipped itself. None of these gates is about core resolution, and
	# the guard that used to hide that is gone with this line.
	sys.core_name = "__state_selftest_core"
	add_child(sys)
	for i in range(20):
		await get_tree().process_frame

	# ── Refusals, in the order the gate checks them ──
	sys.rom_path = ""
	sys.is_powered_on = false
	_eq(str(sys.capture_gate()["reason"]),
		"no game is inserted", "state/no cartridge is the first refusal")

	sys.rom_path = "/nonexistent/__state_selftest.nes"
	_eq(str(sys.capture_gate()["reason"]),
		"the machine is off", "state/then a machine that is off")

	sys.is_powered_on = true
	_ok(bool(sys.capture_gate()["ok"]),
		"state/a running machine with a game can capture", str(sys.capture_gate()))

	sys._save_state._capture_id = "__in_flight"
	_eq(str(sys.capture_gate()["reason"]),
		"a save state is already being written", "state/one capture at a time")
	sys._save_state._capture_id = ""

	# A core that answered "I cannot serialize" is remembered STATICALLY, because
	# it is a property of the core and not of this cabinet. Put it back after.
	var core: String = sys._resolve_core()
	SaveStateController._cores_without_states[core] = true
	_eq(str(sys.capture_gate()["reason"]),
		"this core cannot save states", "state/a core that cannot serialize is remembered")
	SaveStateController._cores_without_states.erase(core)

	# ── Answers exactly once ──
	var answers: Array = []
	sys.state_captured.connect(func(id: String, ok: bool, reason: String) -> void:
		answers.append([id, ok, reason]))
	sys.rom_path = ""
	sys.capture_state("wanted-id")
	_eq(answers.size(), 1, "state/a refused capture answers once")
	if answers.size() == 1:
		_eq(str((answers[0] as Array)[0]),
			"wanted-id", "state/and answers about the id that was asked for")
		_ok(not bool((answers[0] as Array)[1]), "state/and answers not-ok")
		_eq(str((answers[0] as Array)[2]),
			"no game is inserted", "state/carrying the reason the gate gave")

	# ── Load refusals, all synchronous ──
	var loads: Array = []
	sys.state_loaded.connect(func(id: String, ok: bool, reason: String) -> void:
		loads.append([id, ok, reason]))

	sys.load_state("whatever")
	_eq(loads.size(), 1, "state/loading with no cartridge answers once")
	_eq(str((loads[0] as Array)[2]), "no game is inserted", "state/and says so")

	loads.clear()
	sys.rom_path = "/nonexistent/__state_selftest.nes"
	sys.load_state("__no_such_state")
	_eq(loads.size(), 1, "state/a state that is not on disk answers once")
	_eq(str((loads[0] as Array)[2]),
		"that save state is missing", "state/and says which way it failed")

	# In-flight wins over everything else, so a second press cannot start a
	# second read over the top of the first.
	loads.clear()
	sys._save_state._load_id = "__already_loading"
	sys.load_state("second-press")
	_eq(loads.size(), 1, "state/one load at a time")
	_eq(str((loads[0] as Array)[0]),
		"second-press", "state/and the second press is the one refused")
	_eq(str((loads[0] as Array)[2]),
		"a save state is already loading", "state/for the right reason")
	sys._save_state._load_id = ""

	sys.queue_free()
	await get_tree().process_frame


# ── Where a save is written ───────────────────────────────────────────────────
#
# _compose_sram_path decides which file on disk backs a running machine, and
# every other path function is built on it. Getting it wrong does not crash --
# it writes the save somewhere else, or reads a different card's, and the player
# finds out later. Nothing covered it.
#
# Pure: no disk is touched here. _card_path_for_run and _mount_core_cards are
# deliberately NOT exercised -- the first calls SramPaths.ensure_card, which
# creates a card image, and the second reaches CoreOptionsStore, which writes
# the player's real core_options. Both want a scratch fixture of their own.

class _StubCard extends Node3D:
	var card_id := ""
	var family := ""
	var minted := false


func _test_sram_paths() -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	if sys_scene == null:
		return
	var psx: Node3D = sys_scene.instantiate()
	psx.systemid = "playstation"
	add_child(psx)
	for i in range(20):
		await get_tree().process_frame

	# Neither half of the pair is optional: a core with no game, or a game with
	# no core, has nowhere to put a save and must say so rather than guess.
	psx.rom_path = ""
	_eq(psx._memcards._compose_sram_path("pcsx_rearmed"),
		"", "sram/no game means no save file")
	psx.rom_path = "/nonexistent/__sram_selftest.bin"
	_eq(psx._memcards._compose_sram_path(""),
		"", "sram/no core means no save file either")

	# A machine that takes cards saves to the CARD, keyed on the card's own id
	# and family -- not on the game. That is what lets one card carry saves for
	# several games and follow the player between machines.
	psx._memcards._snapped_memcards[0] = null
	_eq(psx._memcards._compose_sram_path("pcsx_rearmed"),
		"", "sram/a card machine with an empty slot has nowhere to write")

	var card := _StubCard.new()
	card.card_id = "__sram_selftest_card"
	card.family = "playstation"
	add_child(card)
	psx._memcards._snapped_memcards[0] = card
	_eq(psx._memcards._compose_sram_path("pcsx_rearmed"),
		SramPaths.card_save_path("playstation", "__sram_selftest_card"),
		"sram/a seated card is where the save goes")
	# And it does not depend on the game: the same card under a different ROM
	# is the same file, which is the whole point of a memory card.
	psx.rom_path = "/nonexistent/__a_different_game.bin"
	_eq(psx._memcards._compose_sram_path("pcsx_rearmed"),
		SramPaths.card_save_path("playstation", "__sram_selftest_card"),
		"sram/the same card backs a different game")

	psx._memcards._snapped_memcards[0] = null
	card.queue_free()
	psx.queue_free()

	# A cartridge machine is the other rule: the save belongs to the CARTRIDGE,
	# keyed on the core and the ROM as well, so two copies of one game on two
	# carts keep separate saves.
	var nes: Node3D = sys_scene.instantiate()
	nes.systemid = "nes"
	add_child(nes)
	for i in range(20):
		await get_tree().process_frame
	nes.rom_path = "/nonexistent/__sram_selftest.nes"
	_eq(nes._memcards._compose_sram_path("fceumm"),
		"", "sram/a cartridge machine with no cartridge has nowhere to write")

	var cart := _StubCart.new()
	cart.save_id = "__sram_selftest_cart"
	add_child(cart)
	nes._snapped_cartridge = cart
	_eq(nes._memcards._compose_sram_path("fceumm"),
		SramPaths.cart_save_path("fceumm", "/nonexistent/__sram_selftest.nes",
			"__sram_selftest_cart"),
		"sram/a seated cartridge saves against core and rom")
	# Unlike a card, this one DOES move with the game.
	_ok(nes._memcards._compose_sram_path("fceumm") != SramPaths.cart_save_path("fceumm", "/other.nes", "__sram_selftest_cart"),
		"sram/and a different rom is a different file")

	nes._snapped_cartridge = null
	cart.queue_free()
	nes.queue_free()
	await get_tree().process_frame


## The cabling gate SystemAudio applies: whether a machine can be heard at all
## as it is currently wired.
##
## Pinned here because NOTHING else covers it. av_tests' audio/ cases drive a
## mock that answers set_audio_volume itself, so they measure tv.gd's routing
## decision and never reach a RetroSystem's own audio path — deleting this gate
## outright leaves all 22 suites green, which is how the gap was found. It was
## worth catching: the gate is the only thing stopping a socketed console with
## nothing plugged into it from playing at full volume out of its own shell.
##
## The rule: hardware with phono sockets is silent until an audio cord reaches a
## set, exactly as the real thing is. Hardware on a captive lead carries its own
## speaker — the handhelds, the Virtual Boy — and is always live.
func _test_audio_cabling_gate() -> void:
	var sys := preload("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	sys.systemid = "nes"
	add_child(sys)

	# A captive lead: no sockets at all, so there is nothing to be unplugged from.
	sys._av_ports = []
	sys._av_speaker_l = -1
	sys._av_speaker_r = -1
	_ok(sys._audio._is_live(), "audio/captive-lead hardware is always live")
	_ok(not bool(sys._audio_speakers().get("socketed", true)),
		"audio/and reports itself unsocketed")

	# Sockets, but no cord in any of them.
	sys._av_ports = [null, null]
	_ok(not sys._audio._is_live(), "audio/a socketed machine wired to nothing is silent")

	# Half connected is still audible — one cord carries one channel.
	sys._av_speaker_l = 0
	_ok(sys._audio._is_live(), "audio/one audio cord makes it live")
	sys._av_speaker_l = -1
	sys._av_speaker_r = 1
	_ok(sys._audio._is_live(), "audio/either channel alone makes it live")

	# The speaker map the component reads. Deliberately answered WITHOUT
	# resolving the sink: _apply_av_feed invalidates the gain cache one line
	# before it assigns _av_tv, where _audio_tv() would still name the old set.
	var spk: Dictionary = sys._audio_speakers()
	_eq(spk.get("left", 99), -1, "audio/the speaker map carries left")
	_eq(spk.get("right", 99), 1, "audio/the speaker map carries right")
	_ok(not spk.has("tv"), "audio/and does not resolve the sink")

	sys.queue_free()


class _StubCart extends Node3D:
	var save_id := ""
