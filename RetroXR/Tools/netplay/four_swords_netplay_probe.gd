## Four Swords Adventures over netplay — a GameCube, four handhelds, N players.
##
##   "$godot" --headless --path RetroXR res://Tools/netplay/four_swords_netplay_probe.tscn -- \
##       --peers=4
##
## A probe, not a test: it wants Dolphin, mGBA, a commercial GameCube ROM and a
## GBA BIOS, so it cannot live in Tests/. It exits non-zero when the peers stop
## agreeing.
##
## WHAT IT IS FOR. Every other check in this area is a rehearsal for this one.
## A Four Swords group is FIVE machines across TWO cores — one Dolphin and four
## mGBAs — joined by four separate cables into one netplay session, and a link
## cable never crosses the network: LinkCoordinator is a process-wide singleton,
## so every peer replicates all five machines and it is determinism, not a wire,
## that keeps the four buses agreeing. Nothing smaller exercises the strategy
## intersection, a group this size, or per-machine ownership on handhelds.
##
## THE HANDHELDS HOLD NO CARTRIDGE. That is the real pairing: the console uses
## each GBA as a screen and pad and uploads its own program over the wire, which
## is why the bus probe measured 82407 messages with an empty handheld against
## 6247 with a commercial cartridge in it.
##
## WHAT A PASS MEANS. That N independent peers, each running all five machines,
## stay in step frame-for-frame and agree on RAM. It does NOT mean the game is
## playable — nothing here presses a button or looks at a screen. It is the
## determinism claim the allowlist wants evidence for, at the size that matters.
##
## COST. N peers x 5 cores. At four players that is four Dolphins and sixteen
## mGBAs in one process, which is not going to run near real time on one box;
## lockstep simply runs slow, so a low fps here is a fact about the box and not
## a failure. --peers=2 is the cheap shape for a smoke run.
extends Node

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

const NM_SCRIPT := preload("res://Scripts/Net/network_manager.gd")

## Matches GcLinkPlug.DEVICE_GBA_LINK and DolphinLibretro's RETRO_DEVICE_GBA_LINK.
const DEVICE_GBA_LINK := (7 << 8) | 0
## Matches GcGbaCable.GBA_JOY_PORT: which of the handheld's two conversations
## this cable is. Not the same number as the console's socket index.
const GBA_JOY_PORT := 1

const PORT := 42911
const BOOT_TICKS := 3600      ## Dolphin is slow to have a machine at all, x peers
const RUN_TICKS := 3000
const SAMPLE_EVERY := 600
## How far apart two peers' copies of one machine may drift before the session is
## not in step. Lockstep bounds this by the input delay, so it is small by
## construction; a real divergence runs away rather than hovering.
const MAX_SKEW := 30

var root_dir := _home + "/retroxr/libretro"
var gc_core := "dolphin"
var gba_core := "mgba"
var gc_rom := _home + "/retroxr/roms/gamecube/Legend of Zelda, The - Four Swords Adventures (USA).rvz"
var peers := 2
var gbas := 4
## Empty by default: the console uploads its own program over the wire.
var gba_rom := ""
## Optional per-peer core roots; see --peer-roots.
var peer_roots := ""

var _branches: Array = []       # NetworkManager per peer
var _machines: Array = []       # Array[Array] — per peer, [gc, gba0..gbaN]
var _ticks := 0
var _started := false
var _done := false
var _fail := ""
var _t0 := 0


## One machine, backed by a REAL core, presenting the interface netplay drives.
##
## Not MockSys: the whole point is that these are Dolphin and mGBA. Only what
## NetplaySession actually calls is implemented, and every method here is the
## real thing rather than a recording.
class RealSys extends Node:
	## Same numbers as the outer script's, repeated because an inner class cannot
	## reach them without a class_name on the file.
	const DEVICE_GBA_LINK := (7 << 8) | 0
	const GBA_JOY_PORT := 1

	var lib: Node = null
	var core_name := ""
	var rom := ""                   ## "" means boot with no cartridge at all
	var root := ""
	var link_group: Array = []
	var buses: Array = []
	var is_console := false
	var gba_ports: Array = []       ## console only: which of its ports hold leads

	## The node exists from the start, like a real RetroSystem's $Libretro child.
	##
	## Not created inside net_start_core: the session reaches for it BEFORE that
	## to set the rollback flag and the CRC interval, both of which have to be in
	## place before the emulation thread spins up. Building it late leaves those
	## calls looking at a null and silently skipped -- which is exactly what this
	## probe did on its first run, and it showed up as a divergence reported at
	## the default 60-frame cadence instead of Dolphin's 900.
	func _ready() -> void:
		var obj: Object = ClassDB.instantiate("Libretro")
		lib = obj as Node
		add_child(lib)

	func get_libretro_node() -> Node:
		return lib

	func net_start_core(core: String, port_mask: int, start_frame: int,
			_options: Dictionary) -> Node:
		# The gate BEFORE the content, so the core holds at the start frame
		# rather than running ahead while the other peers are still loading.
		lib.SetNetplayMode(true, port_mask, start_frame)
		lib.StartContent(root, core, rom)
		return lib

	func net_stop_core() -> void:
		if lib != null and is_instance_valid(lib):
			lib.StopContent()

	func resolve_core_name() -> String:
		return core_name

	func net_rom_md5() -> String:
		# Content is verified by hash, never transferred. A cartridge-less
		# handheld has nothing to hash and says so through the boot mode.
		return NetFileTransfer.hash_of(rom) if not rom.is_empty() else ""

	func net_boot_spec(_core: String) -> Dictionary:
		if rom.is_empty():
			return {"mode": "no_content"}
		return {"mode": "rom", "rom_md5": net_rom_md5()}

	func net_prepare_boot(_spec: Dictionary) -> bool:
		return true

	func net_resolve_rom(_md5: String) -> bool:
		return not rom.is_empty()

	func net_sram_file_bytes() -> PackedByteArray:
		return PackedByteArray()

	func net_set_sram(_path: String, _data: PackedByteArray) -> void:
		pass

	func net_link_group() -> Array:
		return link_group

	func net_link_buses() -> Array:
		return buses

	func net_play_reset() -> void:
		pass

	## Seat every lead again, exactly as GcGbaCable does: the console's socket is
	## told it holds a link plug, then the two cores are joined. A core restart
	## drops its LinkCoordinator endpoints while the plugs stay physically in, so
	## this is what puts the bus back.
	func net_refresh_link_cables() -> void:
		if not is_console or lib == null:
			return
		for i in range(gba_ports.size()):
			var far: Object = gba_ports[i]
			if far == null or far.lib == null:
				continue
			lib.SetControllerPortDevice(i, DEVICE_GBA_LINK)
			lib.LinkConnect(far.lib, i, GBA_JOY_PORT)


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--peers="):
			peers = maxi(2, int(arg.trim_prefix("--peers=")))
		elif arg.begins_with("--gbas="):
			gbas = maxi(1, int(arg.trim_prefix("--gbas=")))
		elif arg.begins_with("--gc-rom="):
			gc_rom = arg.trim_prefix("--gc-rom=")
		elif arg.begins_with("--gba-rom="):
			# Put a cartridge in every handheld. NOT the pairing the game wants —
			# it is here to tell a cartridge-less boot's determinism apart from
			# the core's, which is a different question from whether the game
			# plays.
			gba_rom = arg.trim_prefix("--gba-rom=")
		elif arg.begins_with("--root="):
			root_dir = arg.trim_prefix("--root=")
		elif arg.begins_with("--peer-roots="):
			# One core root per peer, as "<dir>" — each peer gets <dir>/p<N>.
			#
			# Every peer here is a NetworkManager in ONE process, so they would
			# otherwise share a root and two Dolphins would write the same
			# save/dolphin tree and the same core_options file. Real peers are
			# separate processes on separate machines and never do that, so the
			# shared root is an artifact of the harness that makes divergence
			# look worse than it is.
			peer_roots = arg.trim_prefix("--peer-roots=")

	if not FileAccess.file_exists(gc_rom):
		_finish("no GameCube ROM at %s" % gc_rom)
		return

	# Dolphin is not on the allowlist yet, and this run is how it earns a place.
	NetplayCores.debug_allow_unverified = true

	print("[fsa] %d peers x (1 %s + %d %s)" % [peers, gc_core, gbas, gba_core])
	print("[fsa] %s, handhelds cartridge-less (multiboot)" % gc_rom.get_file())

	for p in range(peers):
		_build_peer(p)
	await get_tree().process_frame

	_branches[0].host_game(PORT)
	for p in range(1, peers):
		_branches[p].join_game("::1", PORT)
	_t0 = Time.get_ticks_msec()


func _build_peer(index: int) -> void:
	var my_root := root_dir
	if not peer_roots.is_empty():
		my_root = "%s/p%d" % [peer_roots, index]
	var root := Node.new()
	root.name = "P%d" % index
	add_child(root)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, root.get_path())
	var nm: Node = NM_SCRIPT.new()
	nm.name = "NetworkManager"
	nm.world_root = root
	nm.pose_source = func() -> PackedFloat32Array: return PackedFloat32Array()
	root.add_child(nm)
	_branches.append(nm)

	var console := RealSys.new()
	console.name = "GC"
	console.core_name = gc_core
	console.rom = gc_rom
	console.root = my_root
	console.is_console = true
	nm.add_child(console)

	var group: Array = [console]
	var buses: Array = []
	for i in range(gbas):
		var hh := RealSys.new()
		hh.name = "GBA%d" % i
		hh.core_name = gba_core
		hh.rom = gba_rom            # empty = multiboot, the console uploads it
		hh.root = my_root
		nm.add_child(hh)
		group.append(hh)
		console.gba_ports.append(hh)
		# FOUR separate wires, not one bus of five — that is how the hardware
		# does it, one lead per controller socket.
		buses.append([{"machine": console, "port": i},
			{"machine": hh, "port": GBA_JOY_PORT}])

	for m: RealSys in group:
		m.link_group = group
		m.buses = buses
	_machines.append(group)

	var np: Object = nm._netplay
	np.system_override = console
	var by_id := {}
	for i in range(group.size()):
		by_id[i] = group[i]
	np.systems_override = by_id


func _process(_d: float) -> void:
	if _done:
		return
	_ticks += 1

	if not _started:
		if _ticks > BOOT_TICKS:
			_finish("peers never connected (%d of %d)" % [
				_branches[0].peers.size(), peers])
			return
		if _branches[0].peers.size() < peers:
			return
		# Everyone is in the room. Start the game over the whole bus; owners are
		# assigned from whoever holds each pad, which here is nobody, so they
		# fall to one port per peer in id order — a player each, which is the
		# shape being tested.
		_started = true
		var ok: bool = _branches[0].netplay_start_host(
			_machines[0][0], gc_core, _machines[0][0].net_rom_md5())
		print("[fsa] start_host -> %s" % ok)
		if not ok:
			_finish("the host refused to start the session")
		return

	if _ticks % SAMPLE_EVERY == 0:
		_sample()

	if _ticks > BOOT_TICKS + RUN_TICKS:
		_report()


func _sample() -> void:
	var np: Object = _branches[0]._netplay
	if not np.is_running():
		return
	var line := "[fsa] tick %d: " % _ticks
	for m in range(_machines[0].size()):
		var frames: Array = []
		for p in range(peers):
			var lib: Object = _machines[p][m].lib
			frames.append(int(lib.GetFrameCount()) if lib != null else -1)
		var lo: int = frames.min()
		var hi: int = frames.max()
		if lo >= 0 and hi - lo > MAX_SKEW:
			_fail = "machine %d drifted %d frames apart across peers %s" % [
				m, hi - lo, str(frames)]
		line += "m%d %d(+%d) " % [m, lo, hi - lo]
	print(line)


func _report() -> void:
	var np: Object = _branches[0]._netplay
	var secs := float(Time.get_ticks_msec() - _t0) / 1000.0
	print("[fsa] ---- strategy: %s" % NetplaySession.strategy_str(np._strategy))
	for m in range(_machines[0].size()):
		var frames: Array = []
		for p in range(peers):
			var lib: Object = _machines[p][m].lib
			frames.append(int(lib.GetFrameCount()) if lib != null else -1)
		var traffic: int = 0
		var lib0: Object = _machines[0][m].lib
		if lib0 != null and lib0.has_method("LinkTraffic"):
			for port in range(4):
				traffic = maxi(traffic, int(lib0.LinkTraffic(port)))
		print("[fsa] ---- m%d frames %s, link traffic %d" % [m, str(frames), traffic])
	var anchor: Object = _machines[0][0].lib
	var fps := float(anchor.GetFrameCount()) / maxf(secs, 0.001) if anchor != null else 0.0
	print("[fsa] ---- %.1f s, console %.1f fps (N peers x %d cores on one box)"
		% [secs, fps, _machines[0].size()])
	if np.is_running() and _fail.is_empty():
		_finish("")
	else:
		_finish(_fail if not _fail.is_empty() else "the session stopped early")


func _finish(err: String) -> void:
	if _done:
		return
	_done = true
	NetplayCores.debug_allow_unverified = false
	if err.is_empty():
		print("[fsa] RESULT=PASS")
	else:
		print("[fsa] FAIL %s" % err)
		print("[fsa] RESULT=FAIL")
	get_tree().quit(0 if err.is_empty() else 1)
