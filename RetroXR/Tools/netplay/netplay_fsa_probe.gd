## Four Swords Adventures over NETPLAY: a GameCube and N handhelds, one session,
## two real processes.
##
##   host:   "$godot" --path RetroXR res://Tools/netplay/netplay_fsa_probe.tscn -- --net-host  --fsa-gbas=4
##   client: "$godot" --path RetroXR res://Tools/netplay/netplay_fsa_probe.tscn -- --net-join=127.0.0.1 --fsa-gbas=4
##
## Windowed, not headless: Dolphin wants a real render context.
##
## THE POINT. Every earlier link result was one process. This one puts the whole
## bus — console plus every handheld — into a lockstep session and asks whether
## the two peers stay bit-identical. Only inputs cross the wire; each peer
## replicates all N+1 machines and regenerates the serial conversation itself,
## which is the same model Dolphin's own netplay uses.
##
## It turns NetplayCores.debug_allow_unverified ON. Neither Dolphin nor mGBA has
## been through netplay_spike, so the allowlist refuses them and there is no
## other way to find out whether they are deterministic in practice. That is the
## measurement, not a claim: watch the CRC stream. A desync here is a RESULT.
extends Node

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

const DEVICE_GBA_LINK := (7 << 8) | 0
const GBA_JOY_PORT := 1
const END_AT := 3600

var root_dir := _home + "/retroxr/libretro"
var gc_core := "dolphin"
var gba_core := "mgba"
var gc_rom := _home + "/retroxr/roms/gamecube/Legend of Zelda, The - Four Swords Adventures (USA).rvz"
var gbas := 4
## "gc"  console + N handhelds, each on its own controller port (Four Swords)
## "gb"  N handhelds chained on their serial ports, our own link ROMs
## "gba" N handhelds chained on their serial ports, a real GBA cartridge
var mode := "gc"
var chain_core := "gambatte"
var chain_rom := ""


var _is_host := false
var _machines: Array = []
var _started := false
var _done := false
var _desyncs: Array = []
var _ticks := 0


## A duck-typed machine: what NetplaySession needs of a RetroSystem, and no
## room, no scene and no pickup behaviour.
class FsaMachine extends Node3D:
	var lib: Node = null
	var root_dir := ""
	var core := ""
	var rom := ""          ## empty means a cartridge-less handheld (multiboot)
	var label := ""
	var group: Array = []  ## every machine on this one's bus, itself first

	func _ready() -> void:
		var obj: Object = ClassDB.instantiate("Libretro")
		lib = obj as Node
		add_child(lib)

	func get_libretro_node() -> Node:
		return lib

	func resolve_core_name() -> String:
		return core

	## Per-machine launch spec. A GameCube boots a disc; a Four Swords handheld
		## has no cartridge at all and takes its program down the wire, which is
	## the `no_content` mode.
	func net_boot_spec(_requested: String) -> Dictionary:
		if rom.is_empty():
			return {"mode": "no_content", "core": core, "rom_md5": "", "extension": ""}
		return {"mode": "rom", "core": core, "rom_md5": _md5(), "extension": rom.get_extension()}

	func net_prepare_boot(spec: Dictionary) -> bool:
		if str(spec.get("mode", "rom")) == "no_content":
			return true
		return str(spec.get("rom_md5", "")) == _md5()

	func net_resolve_rom(md5: String) -> bool:
		return md5.is_empty() or md5 == _md5()

	func net_rom_md5() -> String:
		return _md5()

	func _md5() -> String:
		return "" if rom.is_empty() else FileAccess.get_md5(rom)

	func net_sram_file_bytes() -> PackedByteArray:
		return PackedByteArray()

	func net_set_sram(_path: String, _data: PackedByteArray) -> void:
		pass

	func net_link_group() -> Array:
		return group

	func net_link_buses() -> Array:
		return []

	## The session asks the ANCHOR to re-seat the room's cables once every core
	## is attached again. In the room that is the leads resolving; here it is the
	## console cabling each handheld to its own controller port, which is what
	## GcGbaCable does and what gives LinkCaptureGroup a bus to snapshot.
	## "gc": the console cables each handheld to its own controller port.
	## "chain": the handhelds share one wire, which is what a multi-player GBA
	## lead is - a bus, not a star.
	var cable_mode := "gc"

	func net_refresh_link_cables() -> void:
		if group.size() < 2 or group[0] != self:
			return
		if cable_mode != "gc":
			var others: Array = []
			var ports := PackedInt32Array([0])
			for i in range(1, group.size()):
				others.append((group[i] as FsaMachine).lib)
				ports.append(0)
			var okg: bool = lib.LinkConnectGroup(others, ports)
			print("[fsa] chained %d handhelds on one wire: %s" % [group.size(), okg])
			return
		for i in range(1, group.size()):
			var handheld: FsaMachine = group[i]
			if handheld == null or handheld.lib == null:
				continue
			lib.SetControllerPortDevice(i - 1, (7 << 8) | 0)
			var ok: bool = lib.LinkConnect(handheld.lib, i - 1, 1)
			print("[fsa] cabled console port %d <-> %s: %s" % [i - 1, handheld.label, ok])

	func net_start_core(net_core: String, port_mask: int, start_frame: int,
			options: Dictionary) -> Node:
		if not net_core.is_empty():
			core = net_core
		for k: Variant in options:
			lib.SetCoreOption(str(k), str(options[k]))
		lib.SetNetplayMode(true, port_mask, start_frame)
		lib.StartContent(root_dir, core, rom)
		print("[fsa] %s core started (mask=%d start=%d)" % [label, port_mask, start_frame])
		return lib

	func net_stop_core() -> void:
		lib.SetNetplayMode(false, 1, 0)
		lib.StopContent()


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--net-host":
			_is_host = true
		elif arg.begins_with("--fsa-gbas="):
			gbas = clampi(int(arg.trim_prefix("--fsa-gbas=")), 0, 4)
		elif arg.begins_with("--fsa-rom="):
			gc_rom = arg.trim_prefix("--fsa-rom=")
		elif arg.begins_with("--mode="):
			mode = arg.trim_prefix("--mode=")
		elif arg.begins_with("--chain-core="):
			chain_core = arg.trim_prefix("--chain-core=")
		elif arg.begins_with("--chain-rom="):
			chain_rom = arg.trim_prefix("--chain-rom=")
	# The whole reason this probe exists. See the note at the top.
	NetplayCores.debug_allow_unverified = not (mode == "gb" or mode == "gbc" or mode == "gba")

	get_tree().create_timer(400.0).timeout.connect(func() -> void:
		print("[fsa] TIMEOUT")
		_finish(false))

	_machines = []
	if mode == "gc":
		_machines.append(_spawn(gc_core, gc_rom, "gc"))
		for i in range(gbas):
			_machines.append(_spawn(gba_core, "", "gba%d" % i))
	else:
		# A chain of handhelds on their own serial ports. The GB link ROMs come
		# in a master/slave pair; a real cartridge is the same image in every
		# machine, the way four players each hold their own copy.
		var base := ProjectSettings.globalize_path("res://Tools/gblink/")
		for i in range(gbas):
			var r := chain_rom
			if mode == "gb" and r.is_empty():
				r = base + ("link_master.gb" if i == 0 else "link_slave.gb")
			elif mode == "gbc" and r.is_empty():
				# The same exchange at the Game Boy Color's 262144 Hz clock,
				# which is the one path a Game Boy cannot reach.
				r = base + ("link_master_fast.gbc" if i == 0 else "link_slave_fast.gbc")
			_machines.append(_spawn(chain_core, r, "h%d" % i))
	# One bus for the session's purposes: the console and every handheld on it.
	# The console is index 0 and anchors the session.
	for m: FsaMachine in _machines:
		m.group = _machines if _machines.size() > 1 else []
		m.cable_mode = "gc" if mode == "gc" else "chain"

	var np: NetplaySession = NetworkManager._netplay
	var ids := {}
	for i in range(_machines.size()):
		ids[i] = _machines[i]
	np.systems_override = ids
	np.desync_detected.connect(func(pid: int, f: int) -> void:
		_desyncs.append([pid, f])
		print("[fsa] DESYNC peer %d @frame %d (total %d)" % [pid, f, _desyncs.size()]))
	np.session_stopped.connect(func(reason: String) -> void:
		if not _done and not _is_host:
			print("[fsa] session stopped: %s" % reason)
			_finish(reason == "finished"))
	if _is_host:
		NetworkManager.peer_registered.connect(_on_peer)
	print("[fsa] %s, mode=%s, %d machine(s)" % [
		"HOST" if _is_host else "CLIENT", mode, _machines.size()])


func _spawn(core: String, rom: String, label: String) -> FsaMachine:
	var m := FsaMachine.new()
	m.name = label
	m.root_dir = root_dir
	m.core = core
	m.rom = rom
	m.label = label
	add_child(m)
	return m


func _on_peer(id: int, _info: Dictionary) -> void:
	if _started:
		return
	_started = true
	await get_tree().create_timer(1.0).timeout
	# The console keeps port 0 and supplies nothing; each handheld's pad is its
	# own machine's port 0, which in global terms is machine * 4.
	var owners := {}
	if mode == "gc":
		owners[0] = 1
		if gbas == 0:
			owners = {0: 1, 1: id}      # control: two pads on the one console
		for i in range(gbas):
			owners[(i + 1) * NetplaySession.PORTS_PER_MACHINE] = 1 if i % 2 == 0 else id
	else:
		# One pad per handheld, alternating between the two peers, so both
		# sides are really supplying input rather than one watching.
		for i in range(_machines.size()):
			owners[i * NetplaySession.PORTS_PER_MACHINE] = 1 if i % 2 == 0 else id
	var start_core: String = gc_core if mode == "gc" else chain_core
	var ok: bool = NetworkManager.netplay_start_host(_machines[0], start_core, "", owners, 3, 0)
	print("[fsa] start_host -> %s owners=%s" % [ok, str(owners)])
	if not ok:
		_finish(false)


func _process(_d: float) -> void:
	if _done:
		return
	var np: NetplaySession = NetworkManager._netplay
	if not np.is_running():
		return
	var gc_frame: int = _machines[0].lib.GetFrameCount()
	if _ticks % 120 == 0:
		var fr: Array = []
		for m: FsaMachine in _machines:
			fr.append(int(m.lib.GetFrameCount()))
		# next_post is what this peer has FED its cores; complete_upto is what the
		# host has assembled. A client stuck with next_post flat is starving.
		print("[fsa] t%d frames %s next_post=%d complete=%d sched=%d desyncs=%d" % [
			_ticks, str(fr), np._next_post, np._complete_upto, np._sched_frame,
			_desyncs.size()])
	_ticks += 1
	if _is_host and gc_frame >= END_AT:
		_finish(_desyncs.is_empty())


func _finish(ok: bool) -> void:
	if _done:
		return
	_done = true
	var fr: Array = []
	for m: FsaMachine in _machines:
		fr.append(int(m.lib.GetFrameCount()) if m.lib else -1)
	print("[fsa] final frames %s" % str(fr))
	print("[fsa] desyncs: %d" % _desyncs.size())
	print("[fsa] RESULT=%s" % ("PASS" if ok and _desyncs.is_empty() else "FAIL"))
	if _is_host:
		NetworkManager.netplay_stop("finished")
	for _i in range(60):
		await get_tree().process_frame
	get_tree().quit(0 if ok and _desyncs.is_empty() else 1)
