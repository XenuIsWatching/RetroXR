## A link lead between two Game Boys, seated the way a hand seats it.
##
##     "$godot" --headless --path RetroXR res://Tools/gb_link_room_probe.tscn
##
## gb_link_probe drives the bus directly: it calls LinkConnect and proves two
## gambatte cores can exchange a byte. This drives the path a PLAYER uses, which
## is to pick a lead up and push a plug into a socket, and which runs through a
## snap zone, a plug group, a chain walk and LinkConnectGroup before it reaches
## any of that. It is where an integration fault lives -- a socket that takes the
## plug and tells nobody, a lead that joins the machines and never unjoins them.
##
## The two ROMs are ours (Tools/gen_gblink_rom.py) and swap a known byte for
## ever, painting the screen white while the byte coming back is the right one.
## So both halves are checked at once: that the room joined the machines, and
## that a real serial byte crossed the lead it joined them with.
extends Node3D

const SYS_SCENE := "res://Scenes/Objects/system.tscn"
const CABLE_SCENE := "res://Scenes/Objects/cables/gb_link_cable.tscn"
const CORE := "gambatte"
const LINK_KEY := "gambatte_gb_link_mode"
const BOOT_KEY := "gambatte_gb_bootloader"

var _pass := 0
var _fail := 0
var _opt_path := ""
var _opt_backup := ""
var _had_opt := false
var _restored := false
var _systems: Array[RetroSystem] = []
var _cables: Array[Node3D] = []


func _ready() -> void:
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("[gb-room] TIMEOUT")
		_restore()
		get_tree().quit(1))
	await _run()


func _run() -> void:
	var roms := {
		"master": ProjectSettings.globalize_path("res://Tools/gblink/link_master.gb"),
		"slave": ProjectSettings.globalize_path("res://Tools/gblink/link_slave.gb"),
	}
	for role in roms:
		if not FileAccess.file_exists(roms[role]):
			print("[gb-room] SKIP  run Tools/gen_gblink_rom.py first")
			get_tree().quit(0)
			return

	var root := CoreDownloadManager.default_core_root()
	if not FileAccess.file_exists(root.path_join("cores").path_join(CORE + "_libretro.dll")) \
			and not FileAccess.file_exists(root.path_join("cores").path_join(CORE + "_libretro.so")):
		print("[gb-room] SKIP  the %s core is not installed" % CORE)
		get_tree().quit(0)
		return
	if not _write_options(root):
		print("[gb-room] SKIP  could not write the core options file")
		get_tree().quit(0)
		return

	# Two Game Boys, switched on, exactly as the room builds them.
	var order := ["master", "slave"]
	for i in range(2):
		var sys := (load(SYS_SCENE) as PackedScene).instantiate() as RetroSystem
		sys.systemid = "game_boy"
		sys.core_name = CORE
		sys.name = "GB%d" % i
		add_child(sys)
		_systems.append(sys)
	await get_tree().process_frame
	for i in range(2):
		_systems[i].rom_path = roms[order[i]]
		_systems[i].power_on()
	for i in range(2):
		_ok("machine %d powered on" % i, _systems[i].is_powered_on)
	await _settle(120)

	var ports: Array[LinkPort] = []
	for sys in _systems:
		ports.append(sys.find_child("LinkPort", true, false) as LinkPort)
	_ok("the Game Boy model carries a link socket", ports.count(null) == 0)
	if ports.count(null) > 0:
		return _finish()

	var lead := (load(CABLE_SCENE) as PackedScene).instantiate() as LinkCable
	lead.name = "Lead0"
	add_child(lead)
	_cables.append(lead)
	await get_tree().process_frame

	_eq("nobody is cabled to start with", _peers(0), 0)
	var alone := _shade(0)
	print("[gb-room] uncabled master reads %s" % alone)

	(ports[0] as XRToolsSnapZone).pick_up_object(lead.get_node("PlugA0"))
	await _settle(6)
	_eq("one end in a socket is still nobody", _peers(0), 0)

	(ports[1] as XRToolsSnapZone).pick_up_object(lead.get_node("PlugB0"))
	await _settle(6)
	_eq("both ends in leaves machine 0 on a bus of two", _peers(0), 2)
	_eq("and machine 1 with it", _peers(1), 2)

	# A Game Boy is NOT thrown back to its boot logo when a lead arrives, unlike a
	# Game Boy Advance. Nothing is sampled at boot to be stale, and the moment a
	# cable turns up is the moment a player has walked their save into the Cable
	# Club -- restarting there would cost them the walk and repair nothing.
	await _settle(60)

	# And the bytes actually cross the lead the room just seated.
	await _settle(180)
	var linked := _shade(0)
	print("[gb-room] cabled master reads %s, slave %s" % [linked, _shade(1)])
	_ok("a real serial byte crosses the seated lead", linked != alone and linked != "",
		"still reading %s" % linked)
	_eq("and the other end agrees", _shade(1), linked)

	# Yanking the lead IS detach: the diegetic action and the emulated one are the
	# same action, which is the nicest property this feature has.
	await _pull(lead.get_node("PlugB0") as RcaPlug)
	_eq("pulling one end drops machine 0", _peers(0), 0)
	_eq("and machine 1 with it", _peers(1), 0)
	await _settle(120)
	_eq("and the master falls back to an open line", _shade(0), alone)

	(ports[1] as XRToolsSnapZone).pick_up_object(lead.get_node("PlugB0"))
	await _settle(180)
	_eq("pushing it back in joins them again", _peers(0), 2)
	_eq("and the bytes come back with it", _shade(0), linked)

	_finish()


## The one shade a machine's whole screen is painted, or a marker when it is not
## flat. Our ROMs draw one blank tile everywhere, so flat is the normal case.
func _shade(index: int) -> String:
	var lib := _libretro(index)
	if lib == null:
		return "<no core>"
	var img := lib.GetVideoImage()
	if img == null or img.is_empty():
		return "<no picture>"
	var first := img.get_pixel(0, 0)
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			if not img.get_pixel(x, y).is_equal_approx(first):
				return "<not flat>"
	return "#" + first.to_html(false)


func _libretro(index: int) -> Libretro:
	if index >= _systems.size() or not is_instance_valid(_systems[index]):
		return null
	return _systems[index].find_child("Libretro", true, false) as Libretro


func _peers(index: int) -> int:
	var lib := _libretro(index)
	return lib.LinkPeerCount(0) if lib != null else -1


## Pull a plug out and get it clear, the way a hand carrying it away does.
##
## A dropped plug is a live rigid body a few millimetres from the socket it just
## left, and it falls straight back into it. So every socket is shut for the move
## and the plug is frozen where it is put; the A/V suite carries the same helper
## for the same reason.
func _pull(plug: RcaPlug) -> void:
	var shut: Array[RcaPort] = []
	for node in get_tree().get_nodes_in_group(RcaPort.GROUP):
		var port := node as RcaPort
		if port != null and port.enabled:
			port.enabled = false
			shut.append(port)
	var seated := plug.seated_port()
	if seated != null:
		seated.drop_object()
	await _settle(4)
	plug.freeze = true
	plug.global_position += Vector3(0.0, 3.0, 0.0)
	PhysicsServer3D.body_set_state(plug.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, plug.global_transform)
	await _settle(6)
	for port in shut:
		if is_instance_valid(port):
			port.enabled = true
	plug.freeze = false
	await _settle(6)


func _settle(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("[gb-room] PASS  %s" % name)
	else:
		_fail += 1
		print("[gb-room] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


func _finish() -> void:
	for cable in _cables:
		if is_instance_valid(cable):
			cable.queue_free()
	for sys in _systems:
		if is_instance_valid(sys):
			sys.power_off()
	await _settle(90)
	_restore()
	print("[gb-room] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


## Turn the cable on and the bootloader off, keeping a copy of whatever was
## there. The bootloader matters: our ROMs carry no Nintendo logo, so a real boot
## ROM would refuse to hand them control, and gambatte ships that option on.
func _write_options(root: String) -> bool:
	_opt_path = "%s/core_options/%s.opt" % [root, CORE]
	var existing := ""
	_had_opt = FileAccess.file_exists(_opt_path)
	if _had_opt:
		var reader := FileAccess.open(_opt_path, FileAccess.READ)
		if reader != null:
			existing = reader.get_as_text()
			reader.close()
	_opt_backup = existing

	var lines: PackedStringArray = []
	for line in existing.split("\n", false):
		if not line.begins_with(LINK_KEY) and not line.begins_with(BOOT_KEY):
			lines.append(line)
	lines.append('%s = "Link Cable"' % LINK_KEY)
	lines.append('%s = "disabled"' % BOOT_KEY)

	var writer := FileAccess.open(_opt_path, FileAccess.WRITE)
	if writer == null:
		return false
	writer.store_string("\n".join(lines) + "\n")
	writer.close()
	return true


func _restore() -> void:
	if _restored or _opt_path.is_empty():
		return
	_restored = true
	if not _had_opt:
		DirAccess.remove_absolute(_opt_path)
		return
	var writer := FileAccess.open(_opt_path, FileAccess.WRITE)
	if writer != null:
		writer.store_string(_opt_backup)
		writer.close()
