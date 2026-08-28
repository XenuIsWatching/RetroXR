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
## in `Tests/av_suite.tscn`. `_sync_core_tray()` is on the far side of that line;
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
	_test_bios_pinned_options()
	_test_bios_pins_reach_the_opt_file()
	_test_power_on_verdict()
	_test_state_paths()
	_test_state_thumbnail()
	_test_state_disk_round_trip()

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


func _ok(test_name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s" % test_name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [test_name, "  — " + detail if not detail.is_empty() else ""])


func _eq(test_name: String, got: Variant, want: Variant) -> void:
	_ok(test_name, got == want, "got %s, want %s" % [str(got), str(want)])


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
		_ok("gun name/'%s' is a gun" % gun, RetroSystem._reads_as_lightgun(gun))
	# The rest of a NES port list, plus the devices most likely to be mistaken
	# for one because they also report a screen position.
	for other: String in ["Auto", "Gamepad", "Arkanoid", "Power Pad A",
			"SNES Mouse", "Keyboard", "Multitap", "Oeka Kids Tablet",
			"Pointer", "Touchscreen"]:
		_ok("gun name/'%s' is not a gun" % other, not RetroSystem._reads_as_lightgun(other))


# ---------------------------------------------------------------------------
# The generic device type a peripheral carries -> the id the running core knows.
# ---------------------------------------------------------------------------

func _test_core_device_id() -> void:
	var sys := _system()
	sys._controller_info = FCEUMM_PORTS

	# The bug this suite exists for: 7 is not a device fceumm knows, and its
	# switch turns an unknown id into a gamepad. Port 2 (index 1) is where a NES
	# Zapper goes.
	_eq("device/fceumm gun -> Zapper", sys._core_device_id(DEVICE_LIGHTGUN, 1), 258)
	_eq("device/fceumm gun on port 1 -> Zapper", sys._core_device_id(DEVICE_LIGHTGUN, 0), 258)

	# A port that declares no gun keeps the generic id rather than borrowing the
	# gun another port declares.
	_eq("device/no gun on this port passes through",
		sys._core_device_id(DEVICE_LIGHTGUN, 2), DEVICE_LIGHTGUN)
	# A port the core never declared at all.
	_eq("device/unknown port passes through",
		sys._core_device_id(DEVICE_LIGHTGUN, 9), DEVICE_LIGHTGUN)

	# Only a light gun is translated. A pad, a mouse, a keyboard and an unplug
	# all have to reach the core exactly as sent.
	for dev: int in [DEVICE_NONE, DEVICE_JOYPAD, DEVICE_MOUSE, DEVICE_KEYBOARD]:
		_eq("device/type %d untranslated" % dev, sys._core_device_id(dev, 1), dev)

	# Nothing is known about the core until it starts, and a peripheral can be
	# plugged into a machine that is off. The generic id is the honest answer;
	# _reannounce_port_devices() corrects it once the core declares its list.
	sys._controller_info = []
	_eq("device/machine off passes through",
		sys._core_device_id(DEVICE_LIGHTGUN, 1), DEVICE_LIGHTGUN)

	# A core that subclasses the light gun properly is taken at its word.
	sys._controller_info = SNES_PORTS
	_eq("device/subclassed gun wins", sys._core_device_id(DEVICE_LIGHTGUN, 0), 263)

	# Base type beats the name, however early the name matches.
	sys._controller_info = MIXED_PORTS
	_eq("device/base type beats name", sys._core_device_id(DEVICE_LIGHTGUN, 0), 263)

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
		_ok("gun/%s offers one" % sysid, not _gun_row(sysid).is_empty())
	for sysid: String in without_gun:
		_ok("gun/%s does not" % sysid, _gun_row(sysid).is_empty())

	# Once per card: it is appended by items_for, so a copy left in _PERIPHERALS
	# would list it twice on that one platform and nowhere else.
	var seen := 0
	for item: Dictionary in SpawnCatalog.items_for("nes"):
		if String(item.get("spawn", "")) == "light_gun":
			seen += 1
	_eq("gun/listed once", seen, 1)

	# The row has to carry a token SpawnMenuController already handles, or the
	# button is drawn and does nothing.
	var row := _gun_row("super_nes")
	_eq("gun/is a peripheral", String(row.get("kind", "")), "peripheral")
	_eq("gun/token", SpawnCatalog.spawn_token("super_nes", row), "light_gun")
	_ok("gun/the token's scene loads a LightGun",
		(load("res://Scenes/Objects/peripherals/light_gun.tscn") as PackedScene)
			.can_instantiate())


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
	for it in SpawnCatalog.items_for("playstation", "PlayStation"):
		labels.append(String((it as Dictionary).get("label", "")))
	# A platform that models its own console AND its own pads has no use for the
	# generic box or the generic pad; they are clutter on its card.
	_ok("psx/no Primitive System offered", not labels.has("Primitive System"))
	_ok("psx/no Primitive Controller offered", not labels.has("Primitive Controller"))
	_ok("psx/the console is still offered", labels.has("PlayStation"))
	_ok("psx/both pads are offered",
		labels.has("Controller") and labels.has("DualShock"))

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
	_ok("psx/the memory card seats label-up", rel.basis.y.y > 0.9,
		"up = %.3v" % rel.basis.y)
	_ok("psx/and connector-first, tab out the front", rel.basis.z.z > 0.9,
		"front = %.3v" % rel.basis.z)
	eject.button_pressed.emit()
	for i in range(22):
		await get_tree().process_frame
	_ok("psx/OPEN raises the lid", float(model.call("get_lid_angle_deg")) > 40.0,
		"%.1f deg" % model.call("get_lid_angle_deg"))
	var hinge := psx.find_child("LidHinge", true, false)
	if hinge != null and hinge.has_method("latch_closed"):
		hinge.latch_closed()
	for i in range(22):
		await get_tree().process_frame
	_ok("psx/a hand can shut it", float(model.call("get_lid_angle_deg")) < 5.0,
		"%.1f deg" % model.call("get_lid_angle_deg"))
	_ok("psx/and the machine learns it is shut", not bool(psx.get("_tray_open")))
	eject.button_pressed.emit()
	for i in range(22):
		await get_tree().process_frame
	_ok("psx/OPEN works a second time", float(model.call("get_lid_angle_deg")) > 40.0,
		"%.1f deg" % model.call("get_lid_angle_deg"))

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
	_ok("analog/plugged in", pad.get("_connected_system") != null)
	_ok("analog/starts in analogue mode", bool(pad.get("_analog_mode")))
	_ok("analog/lamp lit", glow != null and glow.visible)
	_eq("analog/pad type", String(pad.get("pad_type_pref")), "dualshock")

	if btn != null:
		btn.button_pressed.emit()
	for i in range(6):
		await get_tree().process_frame
	_ok("analog/a poke leaves analogue mode", not bool(pad.get("_analog_mode")))
	_ok("analog/lamp goes out", glow != null and not glow.visible)
	var em := 0.0
	for m in (pad.get("_led_mats") as Array):
		em = maxf(em, (m as StandardMaterial3D).emission_energy_multiplier)
	_ok("analog/emission goes out", is_zero_approx(em))
	_eq("analog/pad type follows", String(pad.get("pad_type_pref")), "standard")
	pad.call("_send_joypad", 0, 32767, 0, 32767, 0)
	_ok("analog/digital reports centred sticks",
		(pad.get("_cur_lstick") as Vector2).is_zero_approx())

	if btn != null:
		btn.button_pressed.emit()
	for i in range(6):
		await get_tree().process_frame
	_ok("analog/a second poke returns", bool(pad.get("_analog_mode")))
	_ok("analog/lamp returns", glow != null and glow.visible)
	pad.call("_send_joypad", 0, 32767, 0, 32767, 0)
	_ok("analog/sticks report again",
		not (pad.get("_cur_lstick") as Vector2).is_zero_approx())

	pad.queue_free()
	psx.queue_free()
	for n in get_children():
		if String(n.name).contains("Cable"):
			n.queue_free()
	for i in range(4):
		await get_tree().process_frame


func _test_pad_type_choice() -> void:
	var full: Array = ["standard", "analog", "dualshock"]
	_eq("pad/dualshock takes dualshock",
		RetroSystem._decide_pad_type(full, "dualshock", "standard"), "dualshock")
	# A core offering no DualShock still deserves the analog pad rather than the
	# digital one — the sticks are physically there.
	_eq("pad/dualshock falls back to analog",
		RetroSystem._decide_pad_type(["standard", "analog"], "dualshock", "standard"), "analog")
	_eq("pad/no fallback available",
		RetroSystem._decide_pad_type(["standard"], "dualshock", "standard"), "")
	# Already right: setting an option costs a core round trip and a rewritten
	# .opt file, so the no-op has to stay a no-op.
	_eq("pad/already selected",
		RetroSystem._decide_pad_type(full, "dualshock", "dualshock"), "")
	_eq("pad/no options known",
		RetroSystem._decide_pad_type([], "dualshock", "standard"), "")
	# A preference this core has never heard of is left alone, not guessed at.
	_eq("pad/unknown preference",
		RetroSystem._decide_pad_type(full, "wavebird", "standard"), "")
	_eq("pad/plain analog pad",
		RetroSystem._decide_pad_type(full, "analog", "standard"), "analog")

	# And what the SCENES actually ask for. Everything above is the pure decision,
	# which was fully covered while no pad in the repo declared "dualshock" at all
	# -- the branch was reachable only from a test. These are the two that make it
	# reachable from a player, and a scene quietly losing the property would leave
	# every case above green.
	for entry in [["ps1_dualshock", "dualshock"], ["ps1_controller", "standard"]]:
		var path := "res://Scenes/Objects/controllers/playstation/%s.tscn" % entry[0]
		var pad: Node = load(path).instantiate()
		_eq("pad/%s asks for %s" % [entry[0], entry[1]],
			String(pad.get("pad_type_pref")), String(entry[1]))
		pad.free()


# ---------------------------------------------------------------------------
# Which libretro port a peripheral drives, and whether it claims one at all.
# ---------------------------------------------------------------------------

func _test_libretro_port_routing() -> void:
	var pc := _system("dos")
	# A computer's cores poll the mouse on port 0 wherever the cabinet put it,
	# which is what lets a mouse and a keyboard share the machine.
	_eq("routing/computer mouse pinned to port 0",
		pc._libretro_port_for(DEVICE_MOUSE, 1), 0)
	_eq("routing/computer pad keeps its socket",
		pc._libretro_port_for(DEVICE_JOYPAD, 1), 1)
	_eq("routing/computer keyboard keeps its socket",
		pc._libretro_port_for(DEVICE_KEYBOARD, 1), 1)
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
	_eq("routing/computer game port drives port 0",
		tower._libretro_port_for(DEVICE_JOYPAD, 2), 0)
	_eq("routing/its other sockets are untouched",
		tower._libretro_port_for(DEVICE_JOYPAD, 1), 1)
	tower.queue_free()
	# ...but does not occupy it: its keys are global to port 0 regardless, and
	# claiming a numbered port would take the slot the mouse needs.
	_ok("routing/computer keyboard claims no port",
		not pc._claims_port_device(DEVICE_KEYBOARD))
	_ok("routing/computer mouse claims a port", pc._claims_port_device(DEVICE_MOUSE))
	pc.free()

	var console := _system("nes")
	_eq("routing/console mouse keeps its socket",
		console._libretro_port_for(DEVICE_MOUSE, 1), 1)
	_ok("routing/console keyboard claims a port",
		console._claims_port_device(DEVICE_KEYBOARD))
	_ok("routing/console gun claims a port", console._claims_port_device(DEVICE_LIGHTGUN))
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
	_eq("cache/port 2 shows the Zapper", sys._controller_info[1]["current_id"], 258)
	_ok("cache/port 1 untouched", not sys._controller_info[0].has("current_id"))

	# A port the core did not declare must not invent an entry or disturb one.
	sys.set_controller_port_device(9, 513)
	_eq("cache/unknown port adds nothing", sys._controller_info.size(), 3)
	_eq("cache/unknown port leaves port 2 alone", sys._controller_info[1]["current_id"], 258)

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

	_eq("cabinet/finds the socket", sys.cabinet_port_of(pad), 1)
	_eq("cabinet/absent peripheral", sys.cabinet_port_of(stray), -1)
	_eq("cabinet/holder of an occupied socket", sys.port_holder(1), pad)
	_eq("cabinet/holder of an empty socket", sys.port_holder(0), null)
	_eq("cabinet/holder past the end", sys.port_holder(9), null)
	_eq("cabinet/holder below zero", sys.port_holder(-1), null)

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
	_eq("content/label falls back to the file", sys._content_label(), "Duck Hunt (World)")
	_eq("content/system falls back to the machine", sys._resolve_systemid(), "nes")
	_eq("content/no cart means no save slot", sys._memcards._sram_slot(), "")
	_eq("content/no cart means no save path", sys._memcards._compose_sram_path("fceumm"), "")

	var cart := FakeSeated.new()
	cart.game_label = "Duck Hunt"
	cart.save_id = "dh-001"
	cart.systemid = "fds"
	sys._snapped_cartridge = cart

	_eq("content/cart names the game", sys._content_label(), "Duck Hunt")
	# A Famicom Disk System disc in a NES: the disc decides, because that is what
	# picks the core and the save location.
	_eq("content/cart names the system", sys._resolve_systemid(), "fds")
	_eq("content/cart names the save slot", sys._memcards._sram_slot(), "dh-001")
	_ok("content/cart has a save path", not sys._memcards._compose_sram_path("fceumm").is_empty())

	# A blank label is not a label — the file name is better than an empty plate.
	cart.game_label = ""
	_eq("content/blank cart label falls back", sys._content_label(), "Duck Hunt (World)")
	cart.systemid = ""
	_eq("content/blank cart system falls back", sys._resolve_systemid(), "nes")

	# No core resolved and no ROM are both "nothing to persist", not a path built
	# out of empty strings.
	_eq("content/no core means no save path", sys._memcards._compose_sram_path(""), "")
	sys.rom_path = ""
	_eq("content/no rom means no save path", sys._memcards._compose_sram_path("fceumm"), "")

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
	_ok("media/a tray console keeps running", tray._media_survives_removal())
	tray.free()

	var slot := _system("wii")
	slot._disc_loader = MediaDimensions.LOADER_SLOT
	_ok("media/a slot console keeps running", slot._media_survives_removal())
	slot.free()

	# No disc loader at all, but the media is a floppy — the drive is a slot in
	# the tower's bezel and the machine runs on regardless.
	var floppy := _system("dos")
	_eq("media/a floppy machine has no disc loader",
		floppy._disc_loader, MediaDimensions.LOADER_NONE)
	_ok("media/a floppy machine keeps running", floppy._media_survives_removal())
	floppy.free()

	# The cartridge IS the program. Pulling it stops the machine, as it always has.
	var cart := _system("nes")
	_ok("media/a cartridge deck stops", not cart._media_survives_removal())
	cart.free()

	# Whether a swap can reach the core is answered by the core's .info file
	# before the core is even loaded. The live disk_control_ready signal lands
	# some frames into the run, and a disc pulled before it did used to take the
	# no-disk-control path and power the machine off.
	var psx := _system("playstation")
	psx.core_name = "pcsx_rearmed"
	_ok("disk control/declared by a PS1 core", psx._supports_disk_control())
	psx.free()

	var amiga := _system("commodore_amiga")
	amiga.core_name = "puae"
	_ok("disk control/declared by a floppy core", amiga._supports_disk_control())
	amiga.free()

	var nes := _system("nes")
	nes.core_name = "fceumm"
	_ok("disk control/not declared by a cartridge core", not nes._supports_disk_control())
	# The running core is still the better witness: a core that reports the
	# interface at runtime is believed whatever its .info file says.
	nes._has_disk_control = true
	_ok("disk control/the live answer wins", nes._supports_disk_control())
	nes.free()

	var unknown := _system("playstation")
	unknown.core_name = "not_a_real_core"
	_ok("disk control/an unknown core claims nothing",
		not unknown._supports_disk_control())
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
	_eq("lid/opening ejects", RetroSystem._tray_op_for(true, false, true), EJECT)
	_eq("lid/opening an empty drive ejects", RetroSystem._tray_op_for(true, false, false), EJECT)
	# Already open as far as the core is concerned — saying it twice would be a
	# second tray cycle the game can see.
	_eq("lid/opening again says nothing", RetroSystem._tray_op_for(true, true, true), NONE)

	# Shutting hands over whatever is in the well, including the disc that was
	# already mounted: a real drive re-reads what it finds.
	_eq("lid/shutting over a disc hands it over",
		RetroSystem._tray_op_for(false, true, true), CLOSE)
	_eq("lid/shutting over the same disc still re-reads",
		RetroSystem._tray_op_for(false, false, true), CLOSE)
	# Nothing in the well: the core keeps waiting with its tray open rather than
	# being told to close on an empty drive.
	_eq("lid/shutting over an empty well says nothing",
		RetroSystem._tray_op_for(false, true, false), NONE)
	_eq("lid/shutting an empty drive the core thinks is shut",
		RetroSystem._tray_op_for(false, false, false), NONE)


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
	_eq("expanded/a gun is announced as the core's gun",
		sys._controller_info[1].get("current_id", -1), 258)
	_eq("expanded/the port remembers the peripheral", sys.port_holder(1), gun)
	# No cabinet socket, so nothing is recorded as a plug — that array belongs to
	# the sockets, and a stray entry would be released as if a cord were pulled.
	_ok("expanded/no cabinet plug recorded", sys._port_plugs[1] == null)

	sys.detach_expanded_controller(1, gun)
	_eq("expanded/unplugging clears the port", sys._controller_info[1]["current_id"], 0)
	_eq("expanded/unplugging frees the holder", sys.port_holder(1), null)

	# A port below zero is not a port; binding one used to be caught by the
	# caller, and _bind_port is now the only thing that can catch it.
	sys.attach_expanded_controller(-1, gun)
	_ok("expanded/a negative port binds nothing", sys.port_holder(0) == null)

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
	_ok("belongs/its own media fits", nes._accepts_media(cart))
	cart.systemid = "snes"
	_ok("belongs/another system's media does not", not nes._accepts_media(cart))
	cart.systemid = ""
	_ok("belongs/unlabelled media fits anywhere", nes._accepts_media(cart))
	# An object with no systemid property at all — a prop that predates the rule.
	var plain := Node3D.new()
	_ok("belongs/an object naming no system fits", nes._accepts_media(plain))

	cart.systemid = "snes"
	_ok("belongs/the port gate reads the same way", not nes._accepts_plug(cart))
	cart.systemid = ""
	_ok("belongs/an unlabelled plug fits", nes._accepts_plug(cart))
	nes.free()

	# The media table is the console's, and it is not symmetric: a Wii takes a
	# GameCube disc, a GameCube does not take a Wii one.
	var wii := _system("wii")
	cart.systemid = "gamecube"
	_ok("belongs/a Wii takes a GameCube disc", wii._accepts_media(cart))
	# ...and the front of the machine agrees with the tray. This case used to
	# read the other way, pinning an empty port table, and the cost of that
	# showed up the day a GameCube-to-Game Boy Advance lead was carried over to
	# the one console in the room that could use it and was silently refused.
	_ok("belongs/and a GameCube plug in its front sockets", wii._accepts_plug(cart))
	wii.free()

	var cube := _system("gamecube")
	cart.systemid = "wii"
	_ok("belongs/a GameCube refuses a Wii disc", not cube._accepts_media(cart))
	cube.free()

	var gba := _system("game_boy_advance")
	cart.systemid = "game_boy"
	_ok("belongs/a GBA takes a Game Boy cart", gba._accepts_media(cart))
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
	_eq("resolve/a named core wins", sys._resolve_core(), "some_core")

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
	_eq("resolve/a system with a default falls back to it",
		sys._resolve_core(), "selftest_core")
	sys.systemid = ""
	_eq("resolve/nothing to go on", sys._resolve_core(), "")

	if had:
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_buffer(before)
		f.close()
	else:
		DirAccess.remove_absolute(path)
	_eq("resolve/the player's own defaults are put back",
		FileAccess.file_exists(path), had)
	if had:
		_ok("resolve/byte for byte", FileAccess.get_file_as_bytes(path) == before)

	sys.core_directory = "C:/somewhere/libretro"
	_eq("resolve/a named directory wins", sys._resolve_dir(), "C:/somewhere/libretro")
	sys.core_directory = ""
	_eq("resolve/the directory falls back to the core root",
		sys._resolve_dir(), CoreDownloadManager.default_core_root())

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

	_ok("forced/nothing forced writes nothing",
		not CoreOptionsStore.merge_values(root, core, {}))
	_ok("forced/and creates no file", not FileAccess.file_exists(path))

	# The player's own settings, as a run would have left them.
	CoreOptionsStore.save_values(root, core, {"user_key": "mine", "vb_3dmode": "anaglyph"})

	_ok("forced/a new pin is written",
		CoreOptionsStore.merge_values(root, core, {"vb_3dmode": "sidebyside"}))
	var after := CoreOptionsStore.load_values(root, core)
	_eq("forced/the pin took", after.get("vb_3dmode", ""), "sidebyside")
	_eq("forced/the player's own key survives", after.get("user_key", ""), "mine")

	# Already pinned: no write at all, so the file keeps its bytes and its order.
	var before_time := FileAccess.get_modified_time(path)
	_ok("forced/an unchanged pin rewrites nothing",
		not CoreOptionsStore.merge_values(root, core, {"vb_3dmode": "sidebyside"}))
	_eq("forced/the file was left alone", FileAccess.get_modified_time(path), before_time)

	# Values arrive from a model as ints and bools as often as strings.
	_ok("forced/a non-string value is written",
		CoreOptionsStore.merge_values(root, core, {"citra_factor_3d": 0}))
	_eq("forced/and reads back as its text",
		CoreOptionsStore.load_values(root, core).get("citra_factor_3d", ""), "0")

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CoreOptionsStore.opt_dir(root)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root))
	_ok("forced/cleaned up", not FileAccess.file_exists(path))


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
	_eq("state/200 ids are 200 ids", seen.size(), 200)
	var one := StatePaths.mint_id()
	_ok("state/an id reads as one", StatePaths.is_state_id(one), one)
	_ok("state/a stray file does not", not StatePaths.is_state_id("autosave"))
	_ok("state/nor does a bare timestamp", not StatePaths.is_state_id("1787000000000"))
	_ok("state/nor does a path traversal", not StatePaths.is_state_id("../../etc/passwd"))

	# The three files are siblings sharing a basename: that is what lets delete
	# find them without an index, and what lets an overwrite keep its picture.
	var sp := StatePaths.state_path("fceumm", "C:/roms/nes/Game (USA).nes", one)
	var shot := StatePaths.shot_path("fceumm", "C:/roms/nes/Game (USA).nes", one)
	var meta := StatePaths.meta_path("fceumm", "C:/roms/nes/Game (USA).nes", one)
	_eq("state/paths differ only by extension",
		[sp.get_basename(), shot.get_basename(), meta.get_basename()],
		[sp.get_basename(), sp.get_basename(), sp.get_basename()])
	_eq("state/the state is a .state", sp.get_extension(), "state")
	_ok("state/keyed by core", sp.contains("fceumm"), sp)
	_ok("state/and by game", sp.contains("Game (USA)"), sp)
	# Two cores running the same game keep separate folders — a state is only
	# ever meaningful to the core that wrote it.
	_ok("state/another core is another folder",
		StatePaths.game_dir("nestopia", "C:/roms/nes/Game (USA).nes")
			!= StatePaths.game_dir("fceumm", "C:/roms/nes/Game (USA).nes"))
	# ...but the same game reached by a different path is the same folder, which
	# is what lets a ROM be moved without losing its states.
	_eq("state/the same game moved is the same folder",
		StatePaths.game_dir("fceumm", "D:/elsewhere/Game (USA).nes"),
		StatePaths.game_dir("fceumm", "C:/roms/nes/Game (USA).nes"))


func _test_state_thumbnail() -> void:
	# The core hands over RGBA8 with every pixel at alpha 0 — it draws opaque and
	# never writes the channel. A thumbnail that keeps it saves a fully
	# transparent rectangle, which is what this shipped as the first time.
	var frame := Image.create(256, 224, false, Image.FORMAT_RGBA8)
	frame.fill(Color(0.2, 0.6, 0.9, 0.0))
	var thumb := StatePaths.thumbnail(frame)
	_eq("thumb/alpha is dropped", thumb.get_format(), Image.FORMAT_RGB8)
	_eq("thumb/the picture survives it",
		thumb.get_pixel(thumb.get_width() / 2, thumb.get_height() / 2).a, 1.0)
	# Downscale keeps the aspect: a 4:3 frame must not come back square.
	_eq("thumb/scaled to the box", thumb.get_width(), StatePaths.THUMB_MAX_W)
	_eq("thumb/aspect kept", thumb.get_height(), 168)
	_ok("thumb/the source is left alone", frame.get_width() == 256
		and frame.get_format() == Image.FORMAT_RGBA8)

	# Never upscaled. Blowing a Game Boy frame up to fill the box only makes it
	# blurry, and the row centres it instead.
	var gb := Image.create(160, 144, false, Image.FORMAT_RGBA8)
	gb.fill(Color(1, 1, 1, 0))
	var small := StatePaths.thumbnail(gb)
	_eq("thumb/a small frame is left at its size", small.get_size(), Vector2i(160, 144))


func _test_state_disk_round_trip() -> void:
	# A scratch core name, so this writes beside the player's real states without
	# ever being able to collide with one.
	var core := "__state_selftest"
	var rom := "selftest.nes"
	var dir := StatePaths.game_dir(core, rom)
	if DirAccess.dir_exists_absolute(dir):
		for f: String in DirAccess.get_files_at(dir):
			DirAccess.remove_absolute(dir.path_join(f))

	_eq("disk/nothing is listed to start", StatePaths.list_states(core, rom).size(), 0)

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
	_eq("disk/the write reports no error", StatePaths.write_job(job), "")

	var rows := StatePaths.list_states(core, rom)
	_eq("disk/one state is listed", rows.size(), 1)
	if rows.size() == 1:
		_eq("disk/under its own id", rows[0]["state_id"], id)
		_ok("disk/with its picture", not str(rows[0]["shot"]).is_empty())
		_eq("disk/and its size", int(rows[0]["bytes"]), job.data.size())
	var meta := StatePaths.read_meta(core, rom, id)
	_eq("disk/the sidecar carries the frame", int(meta.get("frame", -1)), 4242)
	_eq("disk/and the birthday", int(meta.get("created_at", -1)), 1000)

	# Overwrite: the same id, new contents, and the birthday is NOT restamped —
	# that is what makes a row behave like a slot rather than a new entry.
	job.data = "a longer core image".to_utf8_buffer()
	job.frame = 9999
	job.created_at = 2000
	_eq("disk/the overwrite reports no error", StatePaths.write_job(job), "")
	_eq("disk/still one state", StatePaths.list_states(core, rom).size(), 1)
	var meta2 := StatePaths.read_meta(core, rom, id)
	_eq("disk/the frame moved on", int(meta2.get("frame", -1)), 9999)
	_eq("disk/the birthday did not", int(meta2.get("created_at", -1)), 1000)
	_ok("disk/updated_at is stamped", int(meta2.get("updated_at", 0)) > 0)

	# Nothing half-written is ever offered: the promote is a rename, so a .part
	# left behind by a crash is invisible to the list.
	var stray := FileAccess.open(job.state_path + ".part", FileAccess.WRITE)
	stray.store_string("half")
	stray.close()
	_eq("disk/a .part is not a state", StatePaths.list_states(core, rom).size(), 1)
	DirAccess.remove_absolute(job.state_path + ".part")

	_eq("disk/total_bytes counts the picture too", StatePaths.total_bytes(core, rom),
		job.data.size() + NetFileTransfer.size_of(job.shot_path))

	_ok("disk/delete succeeds", StatePaths.delete_state(core, rom, id))
	_eq("disk/and the list is empty", StatePaths.list_states(core, rom).size(), 0)
	_ok("disk/the picture went with it", not FileAccess.file_exists(job.shot_path))
	_ok("disk/and the sidecar", not FileAccess.file_exists(job.meta_path))
	_ok("disk/deleting it twice is not a success", not StatePaths.delete_state(core, rom, id))
	_ok("disk/nor is deleting something that is not an id",
		not StatePaths.delete_state(core, rom, "../../boot"))
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

	_ok("seed/nothing to seed writes nothing", not CoreOptionsStore.seed_values(root, core, {}))
	_ok("seed/and creates no file", not FileAccess.file_exists(path))

	_ok("seed/a fresh key is written",
		CoreOptionsStore.seed_values(root, core, {"splash": "enabled"}))
	_eq("seed/the default took",
		CoreOptionsStore.load_values(root, core).get("splash", ""), "enabled")

	# The whole point of a default: the player turns it off and it STAYS off.
	# merge_values would put it back on at the next power-on.
	CoreOptionsStore.set_value(root, core, "splash", "disabled")
	_ok("seed/seeding twice writes nothing",
		not CoreOptionsStore.seed_values(root, core, {"splash": "enabled"}))
	_eq("seed/the player's choice survives",
		CoreOptionsStore.load_values(root, core).get("splash", ""), "disabled")

	# A core serialises its WHOLE option set on shutdown, so after one run every
	# key it declares is already in the file. Presence must not be mistaken for
	# "already seeded" or a BIOS installed later would never take effect.
	CoreOptionsStore.save_values(root, core, {"splash": "disabled", "later": "off"})
	_ok("seed/a key the core already wrote is still seedable",
		CoreOptionsStore.seed_values(root, core, {"later": "on"}))
	var after := CoreOptionsStore.load_values(root, core)
	_eq("seed/and takes", after.get("later", ""), "on")
	_eq("seed/without disturbing its neighbours", after.get("splash", ""), "disabled")

	# The record is per (core, key). genesis_plus_gx_bios really is shared by
	# five machines under one core, so the key alone cannot be the identity.
	_ok("seed/another core's same key is untouched",
		CoreOptionsStore.seed_values(root, "other_core", {"later": "on"}))

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		CoreOptionsStore.opt_path(root, "other_core")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CoreOptionsStore.opt_dir(root)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CoreOptionsStore.seeded_path(root)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root))
	_ok("seed/cleaned up", not FileAccess.file_exists(path))


func _test_bios_boot_table() -> void:
	var db := CoreInfoDatabase.shared()
	for key: String in BiosBoot._ROWS:
		var parts := key.split("/", false)
		_eq("table/%s is keyed core-then-systemid" % key, parts.size(), 2)
		if parts.size() != 2:
			continue
		_ok("table/%s names a real core" % key,
			not db.get_by_core_name(parts[0]).is_empty())
		_ok("table/%s names a real system" % key,
			ResourceLoader.exists("res://SystemInfo/%s.tres" % parts[1]))
		var row: Dictionary = BiosBoot._ROWS[key]
		_ok("table/%s declares a boot rom" % key,
			not (row.get("boot_rom", []) as Array).is_empty())
		for opt_key: String in (row.get("splash", {}) as Dictionary):
			_ok("table/%s option %s is named" % [key, opt_key],
				not opt_key.strip_edges().is_empty())

	# Keyed on the PAIR. One core, five Sega machines, five different boot ROMs
	# — read by core alone this would offer a Game Gear the Mega Drive's.
	_eq("table/a Mega Drive wants its own boot rom",
		BiosBoot.entry("genesis_plus_gx", "mega_drive").get("boot_rom", []), ["bios_MD.bin"])
	_eq("table/a Game Gear wants its own",
		BiosBoot.entry("genesis_plus_gx", "game_gear").get("boot_rom", []), ["bios.gg"])

	# Measured, and the natural guess is the wrong way round: pcee2 says
	# pcsx2_fast_boot where LRPS2 says pcsx2_fastboot.
	_ok("table/pcee2 uses fast_boot",
		(BiosBoot.entry("pcee2", "playstation2").get("splash", {}) as Dictionary)
			.has("pcsx2_fast_boot"))
	_ok("table/pcsx2 uses fastboot",
		(BiosBoot.entry("pcsx2", "playstation2").get("splash", {}) as Dictionary)
			.has("pcsx2_fastboot"))

	# Only the PlayStation reaches a BIOS from an empty slot; measured over
	# sixteen cores, and the rest refuse a blank image or crash on one.
	_eq("table/a PlayStation takes a blank disc",
		BiosBoot.empty_media_extension("pcsx_rearmed", "playstation"), "cue")
	_eq("table/a cartridge-less GBA pins its real BIOS path",
		BiosBoot.empty_boot_options("mgba", "game_boy_advance").get("mgba_skip_bios"),
		"OFF")
	_eq("table/an empty PlayStation pins automatic real BIOS selection",
		BiosBoot.empty_boot_options("pcsx_rearmed", "playstation").get("pcsx_rearmed_bios"),
		"auto")
	_eq("table/the GBA fingerprint names its boot ROM",
		BiosBoot.boot_rom_paths("mgba", "game_boy_advance"), ["gba_bios.bin"])
	_eq("table/a GameCube does not",
		BiosBoot.empty_media_extension("dolphin", "gamecube"), "")
	_eq("table/nor does a machine with no row",
		BiosBoot.empty_media_extension("fceumm", "nes"), "")

	_ok("table/an unknown pair offers nothing",
		BiosBoot.entry("selftest_core", "nes").is_empty())
	_ok("table/and no splash", BiosBoot.splash_options("selftest_core", "nes").is_empty())
	_ok("table/a core with no .info requires nothing",
		BiosBoot.missing_required("selftest_core").is_empty())
	# The pair is required: a core alone names no machine.
	_ok("table/no systemid is not a match", BiosBoot.entry("pcsx_rearmed", "").is_empty())


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
	_eq("pin/an empty slot pins the boot ROM on",
		BiosBoot.pinned_options("mgba", "game_boy_advance", true).get("mgba_skip_bios", ""),
		"OFF")
	_eq("pin/and the BIOS itself in use",
		BiosBoot.pinned_options("mgba", "game_boy_advance", true).get("mgba_use_bios", ""),
		"ON")

	# The loaded-game half is gated on the boot ROM being installed, so on a box
	# with none it is empty — pinning a core to run a file that is not there
	# turns a machine that played games into a black screen.
	_ok("pin/an unknown pair pins nothing either way",
		BiosBoot.pinned_options("selftest_core", "nes", true).is_empty()
			and BiosBoot.pinned_options("selftest_core", "nes", false).is_empty())

	# Keys only, and both halves of every row for the core: the core manager
	# edits a core with no machine in front of it and has no systemid to ask
	# with.
	var mgba_keys := BiosBoot.pinned_keys_for_core("mgba")
	_ok("pin/a core's key set covers its empty-slot half",
		mgba_keys.has("mgba_skip_bios") and mgba_keys.has("mgba_use_bios"))
	_ok("pin/one core's five Sega machines fold into one key",
		BiosBoot.pinned_keys_for_core("genesis_plus_gx").has("genesis_plus_gx_bios"))
	_ok("pin/a core with no row pins no keys",
		BiosBoot.pinned_keys_for_core("selftest_core").is_empty())
	_ok("pin/and no core names none", BiosBoot.pinned_keys_for_core("").is_empty())
	# A key from ANOTHER core's row must not leak in — pcee2 and pcsx2 spell the
	# same switch differently, and one table read by core alone would offer each
	# the other's no-op.
	_ok("pin/nor another core's spelling of the same switch",
		not BiosBoot.pinned_keys_for_core("pcsx2").has("pcsx2_fast_boot"))


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
		_ok("pin/could create a boot ROM directory to test against", false)
		return
	FirmwareState.shared().invalidate(core, "pcsx2/bios")

	var was_override: bool = AppPrefs.bios_boot_override
	var root := "user://__biospin_selftest"
	var sys := _system(systemid)
	sys.rom_path = "/roms/ps2/game.iso"

	_ok("pin/the boot ROM reads as present",
		BiosBoot.boot_rom_present(core, systemid))

	AppPrefs.bios_boot_override = false
	_eq("pin/a loaded game pins its boot animation on",
		sys._all_forced_options(core).get(key, ""), "disabled")

	# The pin has to beat what is already saved. A core serialises its whole
	# option set on shutdown, so "already in the file" is the normal case and a
	# write-once default would never fix a machine that had skipped its BIOS.
	CoreOptionsStore.save_values(root, core, {key: "enabled"})
	sys._apply_forced_core_options(root, core)
	_eq("pin/and overwrites a saved value that skipped it",
		CoreOptionsStore.load_values(root, core).get(key, ""), "disabled")

	AppPrefs.bios_boot_override = true
	_ok("pin/the override hands the key back",
		not sys._all_forced_options(core).has(key))
	CoreOptionsStore.save_values(root, core, {key: "enabled"})
	sys._apply_forced_core_options(root, core)
	_eq("pin/and the player's value then survives a launch",
		CoreOptionsStore.load_values(root, core).get(key, ""), "enabled")

	AppPrefs.bios_boot_override = was_override
	sys.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		CoreOptionsStore.opt_path(root, core)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(CoreOptionsStore.opt_dir(root)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(root))
	if made_dir:
		DirAccess.remove_absolute(dest)
		FirmwareState.shared().invalidate(core, "pcsx2/bios")
	_ok("pin/cleaned up", made_dir == (not DirAccess.dir_exists_absolute(dest)))


func _test_power_on_verdict() -> void:
	var none: Array[Dictionary] = []

	var no_core := RetroSystem._power_on_verdict("", "nes", "/roms/a.nes", none, "")
	_ok("verdict/no core refuses", not no_core["start"])
	_eq("verdict/and says so", no_core["title"], "No core installed")

	var running := RetroSystem._power_on_verdict("fceumm", "nes", "/roms/a.nes", none, "")
	_ok("verdict/a game inserted starts", running["start"])
	_eq("verdict/with that game", running["rom"], "/roms/a.nes")

	var empty := RetroSystem._power_on_verdict("fceumm", "nes", "", none, "")
	_ok("verdict/an empty slot refuses when the machine cannot boot", not empty["start"])
	_eq("verdict/with the long-standing card", empty["title"], "No game inserted")
	_ok("verdict/worded for a cartridge", str(empty["description"]).contains("cartridge"))
	_eq("verdict/and nothing in the slot", empty["rom"], "")

	# The wording follows the machine, not the core. Untested before this.
	var disc := RetroSystem._power_on_verdict("pcsx_rearmed", "playstation", "", none, "")
	_ok("verdict/worded for a disc", str(disc["description"]).contains("disc"))

	# The substitution: a blank image was resolved, so the machine starts on it.
	var bios := RetroSystem._power_on_verdict(
		"pcsx_rearmed", "playstation", "", none, "/tmp/no_disc.cue")
	_ok("verdict/an empty slot with a blank disc starts", bios["start"])
	_eq("verdict/on the blank disc", bios["rom"], "/tmp/no_disc.cue")

	# A required BIOS blocks the run whether or not a game is in — the core
	# cannot start either way, and a black screen explains neither.
	var missing: Array[Dictionary] = [{
		"path": "pcsx2/bios", "desc": "'pcsx2/bios' folder",
		"dest": "/root/system/pcee2/pcsx2/bios",
	}]
	var no_bios := RetroSystem._power_on_verdict(
		"pcee2", "playstation2", "/roms/g.iso", missing, "")
	_ok("verdict/a missing required bios refuses", not no_bios["start"])
	_eq("verdict/and names the fault", no_bios["title"], "BIOS required")
	_ok("verdict/names the file",
		str(no_bios["description"]).contains("pcsx2/bios"))
	_ok("verdict/and where to get it",
		str(no_bios["description"]).contains("BIOS / Extras"))
	# The card is 520x132 px at 1400 px/m. An absolute system path overflowed it
	# top and bottom and clipped the instruction clean off — caught by rendering
	# it, not by any assertion, so the length is pinned here now.
	_ok("verdict/says it in two short lines",
		str(no_bios["description"]).split("\n").size() == 2)
	for line: String in str(no_bios["description"]).split("\n"):
		_ok("verdict/line fits the card: %s" % line, line.length() <= 52)
	_ok("verdict/one missing file is not counted up",
		not str(no_bios["description"]).contains("more"))

	var two: Array[Dictionary] = [missing[0], {
		"path": "pcsx2/resources", "desc": "'pcsx2/resources' folder",
		"dest": "/root/system/pcee2/pcsx2/resources",
	}]
	var counted := RetroSystem._power_on_verdict("pcee2", "playstation2", "/roms/g.iso", two, "")
	_ok("verdict/two missing files are counted",
		str(counted["description"]).contains("(+1 more)"))

	# Order matters: a machine that is both empty AND missing its BIOS is told
	# about the BIOS, which is the one the player cannot fix from where they
	# stand by reaching for a cartridge.
	_eq("verdict/a missing bios outranks an empty slot",
		RetroSystem._power_on_verdict("pcee2", "playstation2", "", missing, "")["title"],
		"BIOS required")


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
	_eq("link-group/the anchor stays first", group[0], console)
	_eq("link-group/every directly cabled machine is included", group.size(), 4)
	_ok("link-group/a second controller-port cable is not lost", group.has(gba2))
	_ok("link-group/transitively linked machines are included", group.has(gba3))
	_ok("link-group/an unrelated cable is excluded", not group.has(unrelated))
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
	_eq("memcard/an empty slot is typed absent",
		empty.get("pcsx_rearmed_memcard1", ""), "none")
	_eq("memcard/and reported empty",
		empty.get("pcsx_rearmed_memcard1_inserted", ""), "disabled")
	_eq("memcard/the PlayStation's second slot is always absent",
		empty.get("pcsx_rearmed_memcard2", ""), "none")
	# A PlayStation shows ONE slot, whatever the cabinet has room for. The second
	# zone exists in the scene for the consoles that take two, and must stay shut
	# on this one.
	_eq("memcard/a PlayStation has one slot", psx._card_slot_count(), 1)
	_eq("memcard/of the PlayStation family", psx._card_family(), "playstation")

	# A card seated before the machine starts.
	var card := Node3D.new()
	psx._memcards._snapped_memcards[0] = card
	var seated := psx._removable_media_options("pcsx_rearmed")
	_eq("memcard/a seated card types the slot",
		seated.get("pcsx_rearmed_memcard1", ""), "libretro")
	_eq("memcard/and is reported present",
		seated.get("pcsx_rearmed_memcard1_inserted", ""), "enabled")

	# Only pcsx_rearmed has these keys, and only a machine that takes cards has a
	# slot. Pinning them anywhere else would write keys into another core's file.
	_ok("memcard/another core is told nothing",
		psx._removable_media_options("swanstation").is_empty())
	var nes := preload("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	nes.systemid = "nes"
	add_child(nes)
	_ok("memcard/a cartridge console is told nothing",
		nes._removable_media_options("pcsx_rearmed").is_empty())

	# The runtime half. It reaches for the live core, so on a machine that is not
	# running it must do nothing at all rather than fault -- which is also what
	# guards the case where the option arrives before a core exists to take it.
	psx._memcards._set_card_presence(0, false)
	_ok("memcard/presence on a machine that is off does nothing",
		not psx.is_powered_on)

	# A GameCube shows TWO slots, and takes a different family of card. The
	# family is what keeps the two apart: every card is in one "memory_card"
	# group, which scene persistence and the netplay sync both rely on, so
	# splitting the group was never an option.
	var gc := preload("res://Scenes/Objects/system.tscn").instantiate() as RetroSystem
	gc.systemid = "gamecube"
	add_child(gc)
	_eq("memcard/a GameCube has two slots", gc._card_slot_count(), 2)
	_eq("memcard/of the GameCube family", gc._card_family(), "gamecube")
	_ok("memcard/and is told no pcsx_rearmed keys",
		gc._removable_media_options("pcsx_rearmed").is_empty())

	# A Wii takes GameCube cards, which is the whole reason a family is not a
	# systemid: it plays GameCube discs and writes to the same card.
	#
	# Asked of the DESCRIPTOR rather than of a spawned Wii. Standing one up here
	# loads its shell and hangs its flap hinges, and tearing that down at the end
	# of the suite segfaults the engine on the way out -- which makes the exit
	# code, the thing this file exists to provide, meaningless.
	var wii_info := SystemInfo.for_system("wii")
	_eq("memcard/a Wii takes GameCube cards", wii_info.card_family, "gamecube")
	_eq("memcard/in two slots", wii_info.card_slots, 2)
	_eq("memcard/resolving to the GameCube format",
		CardFormats.for_system("wii").id(), "gamecube")

	# The gate that stops a card going into the wrong machine.
	var gc_card := preload("res://Scenes/Objects/media/gc_memory_card.tscn") 		.instantiate() as MemoryCard
	var ps_card := preload("res://Scenes/Objects/media/memory_card.tscn") 		.instantiate() as MemoryCard
	_eq("memcard/a GameCube card knows its family", gc_card.family, "gamecube")
	_eq("memcard/and a PlayStation card knows its own", ps_card.family, "playstation")
	_ok("memcard/a GameCube takes a GameCube card", gc._accepts_card(gc_card))
	_ok("memcard/but not a PlayStation card", not gc._accepts_card(ps_card))
	_ok("memcard/a PlayStation takes its own", psx._accepts_card(ps_card))
	_ok("memcard/but not a GameCube card", not psx._accepts_card(gc_card))

	# Paths are keyed by FAMILY, so a Wii and a GameCube reach the same card.
	_eq("memcard/a Wii and a GameCube share a card folder",
		SramPaths.cards_dir(wii_info.card_family),
		SramPaths.cards_dir(gc._card_family()))
	_ok("memcard/which is not the PlayStation's",
		SramPaths.cards_dir("gamecube") != SramPaths.cards_dir("playstation"))

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
		_ok("led/%s has an emissive lens" % systemid, mats != null and mats.size() > 0,
			"got %s" % ("null" if mats == null else str(mats.size())))
		if mats == null or mats.is_empty():
			sys.queue_free()
			continue

		var lens := mats[0] as StandardMaterial3D
		var glow := model.get("_power_light_glow") as OmniLight3D

		model.set_power_light(false)
		_ok("led/%s is dark when off" % systemid,
			is_equal_approx(lens.emission_energy_multiplier, 0.0),
			str(lens.emission_energy_multiplier))
		_ok("led/%s hides its glow when off" % systemid, glow == null or not glow.visible)

		model.set_power_light(true)
		# The energy is per console, not a shared constant: the NES's red lens
		# needs 3.0 where the PlayStation's green needs 1.0 for the same apparent
		# brightness. A helper that hard-coded one would light one of them wrong.
		_ok("led/%s lights at its own energy" % systemid,
			is_equal_approx(lens.emission_energy_multiplier, want_energy),
			"got %.2f want %.2f" % [lens.emission_energy_multiplier, want_energy])
		_ok("led/%s shows its glow when on" % systemid, glow != null and glow.visible)
		# Emission colour is the lens's own, and must survive being driven.
		_ok("led/%s keeps its emission colour" % systemid,
			lens.emission_enabled and lens.emission.get_luminance() > 0.0,
			str(lens.emission))

		model.set_power_light(false)
		_ok("led/%s goes dark again" % systemid,
			is_equal_approx(lens.emission_energy_multiplier, 0.0))
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
	_eq("state/no cartridge is the first refusal",
		str(sys.can_capture_state()["reason"]), "no game is inserted")

	sys.rom_path = "/nonexistent/__state_selftest.nes"
	_eq("state/then a machine that is off",
		str(sys.can_capture_state()["reason"]), "the machine is off")

	sys.is_powered_on = true
	_ok("state/a running machine with a game can capture",
		bool(sys.can_capture_state()["ok"]), str(sys.can_capture_state()))

	sys._save_state._capture_id = "__in_flight"
	_eq("state/one capture at a time",
		str(sys.can_capture_state()["reason"]), "a save state is already being written")
	sys._save_state._capture_id = ""

	# A core that answered "I cannot serialize" is remembered STATICALLY, because
	# it is a property of the core and not of this cabinet. Put it back after.
	var core: String = sys._resolve_core()
	SaveStateController._cores_without_states[core] = true
	_eq("state/a core that cannot serialize is remembered",
		str(sys.can_capture_state()["reason"]), "this core cannot save states")
	SaveStateController._cores_without_states.erase(core)

	# ── Answers exactly once ──
	var answers: Array = []
	sys.state_captured.connect(func(id: String, ok: bool, reason: String) -> void:
		answers.append([id, ok, reason]))
	sys.rom_path = ""
	sys.capture_state("wanted-id")
	_eq("state/a refused capture answers once", answers.size(), 1)
	if answers.size() == 1:
		_eq("state/and answers about the id that was asked for",
			str((answers[0] as Array)[0]), "wanted-id")
		_ok("state/and answers not-ok", not bool((answers[0] as Array)[1]))
		_eq("state/carrying the reason the gate gave",
			str((answers[0] as Array)[2]), "no game is inserted")

	# ── Load refusals, all synchronous ──
	var loads: Array = []
	sys.state_loaded.connect(func(id: String, ok: bool, reason: String) -> void:
		loads.append([id, ok, reason]))

	sys.load_state("whatever")
	_eq("state/loading with no cartridge answers once", loads.size(), 1)
	_eq("state/and says so", str((loads[0] as Array)[2]), "no game is inserted")

	loads.clear()
	sys.rom_path = "/nonexistent/__state_selftest.nes"
	sys.load_state("__no_such_state")
	_eq("state/a state that is not on disk answers once", loads.size(), 1)
	_eq("state/and says which way it failed",
		str((loads[0] as Array)[2]), "that save state is missing")

	# In-flight wins over everything else, so a second press cannot start a
	# second read over the top of the first.
	loads.clear()
	sys._save_state._load_id = "__already_loading"
	sys.load_state("second-press")
	_eq("state/one load at a time", loads.size(), 1)
	_eq("state/and the second press is the one refused",
		str((loads[0] as Array)[0]), "second-press")
	_eq("state/for the right reason",
		str((loads[0] as Array)[2]), "a save state is already loading")
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
	_eq("sram/no game means no save file",
		psx._memcards._compose_sram_path("pcsx_rearmed"), "")
	psx.rom_path = "/nonexistent/__sram_selftest.bin"
	_eq("sram/no core means no save file either",
		psx._memcards._compose_sram_path(""), "")

	# A machine that takes cards saves to the CARD, keyed on the card's own id
	# and family -- not on the game. That is what lets one card carry saves for
	# several games and follow the player between machines.
	psx._memcards._snapped_memcards[0] = null
	_eq("sram/a card machine with an empty slot has nowhere to write",
		psx._memcards._compose_sram_path("pcsx_rearmed"), "")

	var card := _StubCard.new()
	card.card_id = "__sram_selftest_card"
	card.family = "playstation"
	add_child(card)
	psx._memcards._snapped_memcards[0] = card
	_eq("sram/a seated card is where the save goes",
		psx._memcards._compose_sram_path("pcsx_rearmed"),
		SramPaths.card_save_path("playstation", "__sram_selftest_card"))
	# And it does not depend on the game: the same card under a different ROM
	# is the same file, which is the whole point of a memory card.
	psx.rom_path = "/nonexistent/__a_different_game.bin"
	_eq("sram/the same card backs a different game",
		psx._memcards._compose_sram_path("pcsx_rearmed"),
		SramPaths.card_save_path("playstation", "__sram_selftest_card"))

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
	_eq("sram/a cartridge machine with no cartridge has nowhere to write",
		nes._memcards._compose_sram_path("fceumm"), "")

	var cart := _StubCart.new()
	cart.save_id = "__sram_selftest_cart"
	add_child(cart)
	nes._snapped_cartridge = cart
	_eq("sram/a seated cartridge saves against core and rom",
		nes._memcards._compose_sram_path("fceumm"),
		SramPaths.cart_save_path("fceumm", "/nonexistent/__sram_selftest.nes",
			"__sram_selftest_cart"))
	# Unlike a card, this one DOES move with the game.
	_ok("sram/and a different rom is a different file",
		nes._memcards._compose_sram_path("fceumm")
			!= SramPaths.cart_save_path("fceumm", "/other.nes", "__sram_selftest_cart"))

	nes._snapped_cartridge = null
	cart.queue_free()
	nes.queue_free()
	await get_tree().process_frame


class _StubCart extends Node3D:
	var save_id := ""
