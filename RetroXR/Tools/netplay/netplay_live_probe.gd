## Live two-process netplay probe (M4b) — real core, real network, real gate.
##
## Run TWO instances of this scene on one machine (loopback ENet):
##   host:   godot --path RetroXR --rendering-driver opengl3 res://Tools/netplay/netplay_live_probe.tscn -- --net-host
##   client: godot --path RetroXR --rendering-driver opengl3 res://Tools/netplay/netplay_live_probe.tscn -- --net-join=127.0.0.1
##
## Each process boots the REAL NetworkManager autoload (which parses --net-host /
## --net-join), wraps a REAL Libretro node in a minimal duck-typed "system", and
## runs fceumm under the lockstep session with deterministic scripted inputs on
## its owned port. The host compares every peer's periodic RAM CRC — reaching
## END_AT frames with zero desyncs prints [live] RESULT=PASS.
##
## Optional args: --spike-core= --spike-rom= --spike-root= (fceumm/SMB defaults).
extends Node3D

const END_AT := 1800

## Defaults assume the standard data root; override both with --spike-root=
## and --spike-rom= (see _parse_args below).
static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

var root_dir := _home + "/retroxr/libretro"
var core := "fceumm"
var rom := _home + "/retroxr/roms/nes/probe.nes"

var _sys: LiveSys = null
var _is_host := false
var _started := false
var _done := false


## Minimal duck-typed system: the net_start_core/net_stop_core seam wrapping a
## real Libretro node rendering to a quad.
class LiveSys extends Node3D:
	var lib: Node = null
	var root_dir := ""
	var core := ""
	var rom := ""
	var _mesh: MeshInstance3D = null

	func _ready() -> void:
		_mesh = MeshInstance3D.new()
		_mesh.mesh = QuadMesh.new()
		add_child(_mesh)
		var obj: Object = ClassDB.instantiate("Libretro")
		lib = obj as Node
		add_child(lib)

	func get_libretro_node() -> Node:
		return lib

	func net_start_core(net_core: String, port_mask: int, start_frame: int, options: Dictionary) -> Node:
		if not net_core.is_empty():
			core = net_core          # the host names the core; every peer runs THAT one
		for k: Variant in options:
			lib.SetCoreOption(str(k), str(options[k]))
		lib.SetNetplayMode(true, port_mask, start_frame)
		lib.StartContent(root_dir, core, rom)
		print("[live] core started (mask=%d start=%d)" % [port_mask, start_frame])
		return lib

	func net_stop_core() -> void:
		lib.SetNetplayMode(false, 1, 0)
		lib.StopContent()


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--net-host":
			_is_host = true
		elif arg.begins_with("--spike-core="):
			core = arg.trim_prefix("--spike-core=")
		elif arg.begins_with("--spike-rom="):
			rom = arg.trim_prefix("--spike-rom=")
		elif arg.begins_with("--spike-root="):
			root_dir = arg.trim_prefix("--spike-root=")
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("[live] TIMEOUT")
		print("[live] RESULT=FAIL")
		get_tree().quit(1))

	_sys = LiveSys.new()
	_sys.root_dir = root_dir
	_sys.core = core
	_sys.rom = rom
	add_child(_sys)
	NetworkManager._netplay.system_override = _sys
	NetworkManager._netplay.desync_detected.connect(func(pid: int, f: int) -> void:
		print("[live] DESYNC peer %d @frame %d" % [pid, f])
		_finish(false))
	NetworkManager._netplay.session_stopped.connect(func(reason: String) -> void:
		if not _done and not _is_host:
			# Host ended the game — treat a normal end as success on the client.
			print("[live] session stopped: %s" % reason)
			print("[live] RESULT=%s" % ("PASS" if reason == "finished" else "FAIL"))
			await _settle()
			get_tree().quit(0 if reason == "finished" else 1))
	if _is_host:
		NetworkManager.peer_registered.connect(_on_peer_registered)


func _on_peer_registered(id: int, _info: Dictionary) -> void:
	if _started:
		return
	_started = true
	# Host owns port 0, the first client owns port 1.
	var owners := {0: 1, 1: id}
	await get_tree().create_timer(0.5).timeout   # let the client settle
	var ok: bool = NetworkManager.netplay_start_host(_sys, core, "LIVE", owners, 3)
	print("[live] start_host -> %s owners=%s" % [ok, str(owners)])
	if not ok:
		_finish(false)


## Deterministic scripted play (same recipe as netplay_spike): START to get
## in-game, then run right with periodic jumps. Each peer contributes its own
## port's input — both timelines flow through the shared assembled frames.
func _input_for_frame(f: int) -> int:
	var btn := 0
	if (f >= 180 and f < 195) or (f >= 300 and f < 320):
		btn |= 1 << 3          # START
	if f >= 400:
		btn |= 1 << 7          # RIGHT
		if (f % 90) < 25:
			btn |= 1 << 8      # A
		if (f % 51) < 10:
			btn |= 1 << 0      # B
	return btn


func _process(_delta: float) -> void:
	if _done:
		return
	var np: NetplaySession = NetworkManager._netplay
	if not np.is_running():
		return
	# Feed the scripted input for our owned port(s). Rollback: drive the live
	# SetJoypadState path (the wrapper samples it each emu frame); lockstep:
	# fill the scheduled route as before.
	var f: int = np._sched_frame
	for port: int in np._local_ports:
		if np._rollback:
			_sys.lib.SetJoypadState(port, _input_for_frame(int(_sys.lib.GetFrameCount()) + 1), 0, 0, 0, 0)
		else:
			np._pending_local_route[port] = [_input_for_frame(f), 0, 0, 0, 0]
	var emu: int = _sys.lib.GetFrameCount()
	if emu > 0 and emu % 600 == 0:
		pass  # progress visible via [Netplay]/[live] lines
	if _is_host and emu >= END_AT:
		_finish(true)


## Frames, not wall time, between the core stopping and quitting.
##
## A GDExtension AudioStreamPlayback still held by the AudioServer at quit is
## destroyed AFTER its class record has been unregistered, which segfaults the
## exit with everything already printed and no crash dump. The server only hands
## a stopped playback back in AudioServer::update() on the main thread, so what
## it needs is main-loop iterations before quit() — quitting straight out of the
## session_stopped handler is the worst possible moment for it, and it made this
## probe exit 139 on a run that had otherwise passed cleanly.
func _settle() -> void:
	for _i in range(60):
		await get_tree().process_frame


func _finish(ok: bool) -> void:
	if _done:
		return
	_done = true
	var emu: int = _sys.lib.GetFrameCount() if _sys and _sys.lib else -1
	if _sys and _sys.lib and _sys.lib.has_method("GetNetplayRollbackCount"):
		print("[live] rollbacks performed: %d" % _sys.lib.GetNetplayRollbackCount())
	print("[live] finished at frame %d" % emu)
	print("[live] RESULT=%s" % ("PASS" if ok else "FAIL"))
	if _is_host:
		NetworkManager.netplay_stop("finished")
	await get_tree().create_timer(1.0).timeout
	get_tree().quit(0 if ok else 1)
