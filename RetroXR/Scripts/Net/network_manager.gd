## NetworkManager — LAN multiplayer session core (autoload).
##
## Star topology over ENet: the host is the server (peer 1) and relays
## everything. Clients register with a handshake, follow the host's scene, and
## exchange avatar poses at 20 Hz. Object sync (M2), file transfer (M3) and
## netplay (M4) hang off this node as fixed-path children so RPC node paths
## match on every peer.
##
## Testability: all networking goes through `self.multiplayer` (never the tree
## global) and the world root is injectable, so probes can instantiate two
## copies of this script under sibling branches with per-branch
## SceneMultiplayer APIs (get_tree().set_multiplayer(api, branch_path)).
extends Node

const DEFAULT_PORT := 42777
const MAX_PLAYERS := 8
## Where the GL/Vulkan video probe's config is accepted from on device, beside
## user://. Spelled out rather than derived, the same way rom_library.gd spells
## out each of its roots.
const GLPROBE_EXTERNAL_CFG := "/sdcard/Android/data/com.xenu.retroxr/files/glprobe.cfg"
const MARIOPROBE_EXTERNAL_CFG := "/sdcard/Android/data/com.xenu.retroxr/files/marioprobe.cfg"
const RBCOST_EXTERNAL_CFG := "/sdcard/Android/data/com.xenu.retroxr/files/rbcost.cfg"
## 2: systems are replicated by model_id rather than by a (systemid, variant)
## pair. 3 added netplay. 4 made linked sessions carry a specification per
## machine. 5 added per-machine aux/keyboard blocks and machine-addressed disc
## operations. 6 adds articulated child-control batches (plain/spring hinges,
## levers, knobs and sliders). 7 adds deterministic reset plus explicit TV
## source/channel/aspect state. 8 adds per-port accel/gyro/pointer frames. 9
## carries the external link-bus snapshot needed by linked late join. 10 makes
## each machine's ROM/empty-media/no-content boot mode explicit. 11 chunks and
## verifies late-join savestates instead of putting them in one RPC. These
## wire layouts are intentionally refused across versions:
## accepting an old peer would look connected while feeding different cores.
const PROTOCOL_VERSION := 12
const POSE_INTERVAL := 1.0 / 20.0

# ENet channels
const CH_CONTROL := 0   # reliable: handshake, spawns, events, netplay control
const CH_POSE := 1      # unreliable_ordered: avatar poses, object transforms
const CH_NPINPUT := 2   # unreliable: netplay per-frame inputs (self-redundant)
const CH_FILE := 3      # reliable: file/state chunks

const AVATAR_SCENE := preload("res://Scenes/Net/remote_avatar.tscn")
const POSE_BROADCASTER := preload("res://Scripts/Net/netplay/pose_broadcaster.gd")
const OBJECT_SYNC := preload("res://Scripts/Net/netplay/object_sync.gd")
const NETPLAY := preload("res://Scripts/Net/netplay/netplay_session.gd")
const FILE_TRANSFER := preload("res://Scripts/Net/netplay/file_transfer.gd")

## Avatar palette — color_idx assigned by the host at registration.
const PLAYER_COLORS: Array[Color] = [
	Color(0.90, 0.25, 0.25), Color(0.25, 0.55, 0.95), Color(0.30, 0.85, 0.35),
	Color(0.95, 0.80, 0.20), Color(0.80, 0.35, 0.90), Color(0.25, 0.85, 0.85),
	Color(0.95, 0.55, 0.20), Color(0.90, 0.90, 0.95),
]

signal session_started(is_host: bool)
signal session_ended(reason: String)
signal peer_registered(id: int, info: Dictionary)
signal peer_left(id: int)
signal status_changed(text: String)
## The room code a joiner has to be told, or empty when not hosting online.
signal room_code_changed(code: String)

## A machine that cannot hold a session, and what to press instead.
##
## Powering on an unvetted core used to fall through to a local boot with no
## trace: no signal, no error, remote players left on the host-only placeholder
## and nothing anywhere saying why. `remedy` is the NetplayReadiness dict, empty
## when no vetted core covers the system.
signal netplay_blocked(reason: String, machine: Object, remedy: Dictionary)

## Late-join state movement: "capturing", "transferring", "verifying", "loading".
##
## The stream already tracked every byte and reported none of them, so a joiner
## sat on a frozen menu for up to 15 s. Emitted on both ends.
signal netplay_state_progress(peer_id: int, phase: String, received: int, total: int)

## Forwarded from the session, which had these three and no listeners at all.
signal netplay_join_requested(peer_id: int, port: int)
signal netplay_desync(peer_id: int, frame: int)
signal netplay_session_stopped(reason: String)

## Forwarded from the file transfer: what THIS peer is handing out, and to whom.
## Fires on the sender, so in practice on the host.
signal serve_started(peer_id: int, md5: String, kind: String, size: int, name: String)
signal serve_progress(peer_id: int, md5: String, sent: int, total: int)
signal serve_done(peer_id: int, md5: String)
signal serve_refused(peer_id: int, md5: String, reason: String)

## Peer roster: peer_id -> {name: String, is_vr: bool, color_idx: int}
var peers: Dictionary = {}

## Local display name (set from the NET menu / --net-name).
var player_name: String = "Player"

## Injectable world root (defaults to get_tree().current_scene). Probes set this.
var world_root: Node = null

## Injectable pose source returning PackedFloat32Array(21):
## head pos+quat, left pos+quat, right pos+quat. Defaults to a PoseBroadcaster
## attached to the player rig; probes inject a lambda.
var pose_source: Callable = Callable()

var _active := false
var _accepted := false           # handshake complete (host: immediately)
var _signals_wired := false
var _object_sync: NetObjectSync = null
var _netplay: NetplaySession = null
var _file_transfer: NetFileTransfer = null
var _rendezvous: RendezvousClient = null
var _punch: Punchthrough = null
var _room_code := ""
var _room_secret := ""
var _heartbeat: Timer = null
var _pose_accum := 0.0
var _latest_poses: Dictionary = {}     # peer_id -> PackedFloat32Array(21)
var _avatars_container: Node3D = null
var _avatars: Dictionary = {}          # peer_id -> RemoteAvatar
var _broadcaster: Node = null


func _ready() -> void:
	# Fixed-path RPC child — must exist on every peer before any session RPC.
	_object_sync = OBJECT_SYNC.new()
	_object_sync.name = "ObjectSync"
	add_child(_object_sync)
	_object_sync.peer_world_ready.connect(_on_peer_world_ready)
	# Fixed-path netplay session (M4) — one active game at a time.
	_netplay = NETPLAY.new()
	_netplay.name = "Netplay"
	add_child(_netplay)
	_netplay.join_requested.connect(func(peer_id: int, port: int) -> void:
		netplay_join_requested.emit(peer_id, port))
	_netplay.desync_detected.connect(func(peer_id: int, frame: int) -> void:
		netplay_desync.emit(peer_id, frame))
	_netplay.session_stopped.connect(func(reason: String) -> void:
		netplay_session_stopped.emit(reason))
	_netplay.join_state_progress.connect(
		func(peer_id: int, phase: String, received: int, total: int) -> void:
			netplay_state_progress.emit(peer_id, phase, received, total))
	# Fixed-path file delivery (M3) — books/videos by content hash.
	_file_transfer = FILE_TRANSFER.new()
	_file_transfer.name = "FileTransfer"
	add_child(_file_transfer)
	_file_transfer.serve_started.connect(
		func(peer_id: int, md5: String, kind: String, size: int, name: String) -> void:
			serve_started.emit(peer_id, md5, kind, size, name))
	_file_transfer.serve_progress.connect(
		func(peer_id: int, md5: String, sent: int, total: int) -> void:
			serve_progress.emit(peer_id, md5, sent, total))
	_file_transfer.serve_done.connect(func(peer_id: int, md5: String) -> void:
		serve_done.emit(peer_id, md5))
	_file_transfer.serve_refused.connect(
		func(peer_id: int, md5: String, reason: String) -> void:
			serve_refused.emit(peer_id, md5, reason))
	# React to host-driven scene switches (rebuild avatars in the new scene).
	if has_node("/root/SceneManager"):
		SceneManager.scene_changed.connect(_on_scene_changed)
		SceneManager.scene_content_ready.connect(_on_scene_content_ready)
	call_deferred("_parse_cmdline")


## Swap the room out for a probe scene, once the room is actually up.
##
## `_parse_cmdline` runs from a `call_deferred` in `_ready`, which is early
## enough that MainScene is still assembling itself — and tearing a half-built
## XR scene down took the render thread with it (SIGSEGV on VkThread, preceded
## by a bare "data.tree is null" from a node being freed mid-setup). Letting the
## room finish first costs a second and makes the teardown an ordinary one.
func _swap_in_probe(path: String) -> void:
	for _i in range(120):
		await get_tree().process_frame
	get_tree().change_scene_to_file(path)


func _parse_cmdline() -> void:
	# On-device QA hook: a user://spike.cfg boots straight into the netplay
	# determinism spike (used to vet cores over adb on Quest, where there are
	# no command-line args). The spike deletes the cfg so the next launch is
	# normal even if the run crashes mid-way. NB: ResourceLoader.exists, not
	# FileAccess — .tscn paths are remapped inside exported pcks.
	if FileAccess.file_exists("user://spike.cfg") \
			and ResourceLoader.exists("res://Tools/netplay/netplay_spike.tscn"):
		print("[NetworkManager] spike.cfg found — launching netplay spike")
		_swap_in_probe("res://Tools/netplay/netplay_spike.tscn")
		return
	# Same hook for the hardware-render video probe (GLES2/GLES3 black-screen
	# hunt). The probe deletes the cfg itself, like the spike.
	# Accepted from the EXTERNAL files dir as well as user://. A release build is
	# not debuggable, so `adb run-as` cannot reach user:// at all — and a release
	# build is the only one that runs properly on the Quest. Taking the cfg from
	# /sdcard, which adb can write unaided, is what makes this probe usable on the
	# build that actually ships.
	if (FileAccess.file_exists("user://glprobe.cfg") \
			or FileAccess.file_exists(GLPROBE_EXTERNAL_CFG)) \
			and ResourceLoader.exists("res://Tools/cores/gl_video_probe.tscn"):
		print("[NetworkManager] glprobe.cfg found — launching GL video probe")
		get_tree().change_scene_to_file("res://Tools/cores/gl_video_probe.tscn")
		return
	# Same hook for the rollback cost probe. Whether rollback is affordable is a
	# property of the machine, so the answer only counts when taken here rather
	# than on a desktop. Read from /sdcard too, like the GL probe: a release
	# build is the only one that runs properly on a Quest and `run-as` cannot
	# reach its user:// at all.
	if (FileAccess.file_exists("user://rbcost.cfg") \
			or FileAccess.file_exists(RBCOST_EXTERNAL_CFG)) \
			and ResourceLoader.exists("res://Tools/netplay/rollback_cost_probe.tscn"):
		print("[NetworkManager] rbcost.cfg found — launching rollback cost probe")
		_swap_in_probe("res://Tools/netplay/rollback_cost_probe.tscn")
		return
	# Same hook for the GBA link probe, which is how the multiplayer grain is
	# vetted on the machine that actually struggles with it: four cabled cores is
	# a Quest problem before it is a desktop one. Read from /sdcard too, like the
	# GL and rollback probes, and the probe deletes the cfg itself.
	if (FileAccess.file_exists("user://marioprobe.cfg") \
			or FileAccess.file_exists(MARIOPROBE_EXTERNAL_CFG)) \
			and ResourceLoader.exists("res://Tools/link/mario_link_probe.tscn"):
		print("[NetworkManager] marioprobe.cfg found — launching GBA link probe")
		_swap_in_probe("res://Tools/link/mario_link_probe.tscn")
		return
	# Same hook for menu timings. Deleted on sight, so a crash mid-run cannot
	# wedge the app into the probe.
	if FileAccess.file_exists("user://perfprobe.cfg") \
			and ResourceLoader.exists("res://Tools/perf/menu_perf_probe.tscn"):
		print("[NetworkManager] perfprobe.cfg found — launching menu perf probe")
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://perfprobe.cfg"))
		get_tree().change_scene_to_file("res://Tools/perf/menu_perf_probe.tscn")
		return
	var args := OS.get_cmdline_user_args()
	var do_host := false
	var do_host_online := false
	var join_ip := ""
	var join_code := ""
	for arg: String in args:
		if arg == "--net-host":
			do_host = true
		elif arg == "--net-host-online":
			do_host_online = true
		elif arg.begins_with("--net-join="):
			join_ip = arg.trim_prefix("--net-join=")
		elif arg.begins_with("--net-code="):
			join_code = arg.trim_prefix("--net-code=")
		elif arg.begins_with("--net-name="):
			player_name = arg.trim_prefix("--net-name=")
	# The online pair are awaited rather than called: they take as long as a
	# registry round trip and a punch, which is not something to do inside the
	# first frame of a scene.
	if do_host_online:
		host_online.call_deferred()
	elif not join_code.is_empty():
		join_by_code.call_deferred(join_code)
	elif do_host:
		host_game()
	elif not join_ip.is_empty():
		join_game(join_ip)


# ── Public API ────────────────────────────────────────────────────────────────

func is_active() -> bool:
	return _active


func is_host() -> bool:
	if not _active or multiplayer == null or multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return false
	return multiplayer.is_server()


func is_client() -> bool:
	if not _active or multiplayer == null or multiplayer.multiplayer_peer == null:
		return false
	if multiplayer.multiplayer_peer.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		return false
	return not multiplayer.is_server()


func host_game(port := DEFAULT_PORT) -> Error:
	if _active:
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		status_changed.emit("Failed to host (port %d): %s" % [port, error_string(err)])
		return err
	_wire_signals()
	multiplayer.multiplayer_peer = peer
	_active = true
	_accepted = true
	peers = {1: _local_info(0)}
	print("[NetworkManager] ENet host listening on UDP %d (protocol %d)" % [
		port, PROTOCOL_VERSION])
	_setup_world()
	status_changed.emit("Hosting on port %d — %s" % [port, ", ".join(local_ips())])
	session_started.emit(true)
	return OK


## local_port is the punched socket when joining by code. It has to be the port
## the handshake went out of, because that is the one the far NAT has a mapping
## for; anything else arrives at a closed door. Zero lets ENet pick, which is
## right for LAN and wrong for a punch.
func join_game(ip: String, port := DEFAULT_PORT, local_port := 0) -> Error:
	if _active:
		return ERR_ALREADY_IN_USE
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port, 0, 0, 0, local_port)
	if err != OK:
		status_changed.emit("Failed to connect: %s" % error_string(err))
		return err
	_wire_signals()
	multiplayer.multiplayer_peer = peer
	_active = true
	_accepted = false
	peers = {}
	print("[NetworkManager] ENet connecting to %s:%d (protocol %d)" % [
		ip, port, PROTOCOL_VERSION])
	status_changed.emit("Connecting to %s…" % ip)
	return OK


# ── Playing online, by room code ──────────────────────────────────────────────
# Everything here ends in host_game/join_game above. The ENet handshake, the
# roster and the version check are untouched: this only arranges for the two
# peers to be able to see each other first.


## Host where anyone can reach us. Returns OK once the room code exists and the
## ENet server is listening on the punched port; read the code from
## room_code_changed or room_code().
##
## Every failure leaves nothing running, so the caller can fall back to LAN
## hosting without cleaning up after this.
func host_online(room_name := "") -> Error:
	if _active:
		return ERR_ALREADY_IN_USE

	var rv := _make_rendezvous()
	status_changed.emit("Finding a way through…")

	var ep: Dictionary = await _call_registry(rv.punch_endpoint)
	if ep.is_empty():
		_teardown_online()
		status_changed.emit("Could not reach the RetroXR server. Try hosting on LAN.")
		return ERR_CANT_CONNECT

	var punched: Dictionary = await _make_punch().host(
		ep["punch_host"], ep["punch_port"])
	if punched["result"] != Punchthrough.Result.OK:
		_teardown_online()
		status_changed.emit(_punch_failure(punched["result"]))
		return ERR_CANT_CONNECT

	var room: Dictionary = await _call_registry(func(cb: Callable) -> void:
		rv.create_room(punched["oid"],
			room_name if not room_name.is_empty() else player_name,
			PROTOCOL_VERSION, cb))
	if room.is_empty():
		_teardown_online()
		status_changed.emit("Could not reach the RetroXR server. Try hosting on LAN.")
		return ERR_CANT_CONNECT

	# Only now is the port real. Hosting first would mean holding a socket open
	# that nobody could be told about.
	var err := host_game(punched["local_port"])
	if err != OK:
		rv.close_room(room["code"], room["secret"])
		_teardown_online()
		return err

	_room_code = room["code"]
	_room_secret = room["secret"]
	_start_heartbeat(int(room.get("ttl", 90)))
	room_code_changed.emit(_room_code)
	status_changed.emit("Hosting online — room code %s" % _room_code)
	return OK


## Join whoever is holding this code.
func join_by_code(raw_code: String) -> Error:
	if _active:
		return ERR_ALREADY_IN_USE

	var code := RoomCode.normalize(raw_code)
	if not RoomCode.is_valid(code):
		status_changed.emit("That is not a room code.")
		return ERR_INVALID_PARAMETER

	var rv := _make_rendezvous()
	status_changed.emit("Looking up %s…" % code)

	var room: Dictionary = await _call_registry(func(cb: Callable) -> void:
		rv.lookup(code, cb))
	if room.is_empty():
		_teardown_online()
		status_changed.emit("No game with code %s. Check it and try again." % code)
		return ERR_DOES_NOT_EXIST

	# Before ENet, not after. The registry record carries the version precisely
	# so a mismatch can be named here; left to the handshake it arrives as a
	# refusal from a peer the player never sees.
	var theirs := int(room.get("protocol_version", -1))
	if theirs != PROTOCOL_VERSION:
		_teardown_online()
		status_changed.emit(
			"That game is running a different version of RetroXR (theirs %d, yours %d)."
			% [theirs, PROTOCOL_VERSION])
		return ERR_INVALID_DATA

	status_changed.emit("Connecting to %s…" % code)
	var punched: Dictionary = await _make_punch().join(
		room["punch_host"], room["oid"], room["punch_port"])
	if punched["result"] != Punchthrough.Result.OK:
		_teardown_online()
		status_changed.emit(_punch_failure(punched["result"]))
		return ERR_CANT_CONNECT

	var err := join_game(punched["host_addr"], punched["host_port"],
		punched["local_port"])
	if err != OK:
		_teardown_online()
	return err


## The room code currently being hosted, or empty.
func room_code() -> String:
	return _room_code


# ── Online plumbing ───────────────────────────────────────────────────────────

## Turns one of the callback-style registry calls into something awaitable.
## Returns {} for every failure: the caller decides what to say, because the
## same empty answer means different things to a host and to a joiner.
func _call_registry(call: Callable) -> Dictionary:
	var done := [false, {}]
	call.call(func(res: int, data: Variant) -> void:
		done[0] = true
		if res == RendezvousClient.Result.OK and data is Dictionary:
			done[1] = data
	)
	while not done[0]:
		await get_tree().process_frame
	return done[1]


func _make_rendezvous() -> RendezvousClient:
	if _rendezvous == null:
		_rendezvous = RendezvousClient.new()
		_rendezvous.name = "Rendezvous"
		add_child(_rendezvous)
	return _rendezvous


func _make_punch() -> Punchthrough:
	if _punch == null:
		_punch = Punchthrough.new()
		_punch.name = "Punchthrough"
		add_child(_punch)
		_punch.peer_punched.connect(_on_peer_punched)
	return _punch


## A joiner has punched its way to us. Nothing to connect - the ENet server is
## already listening - but the far NAT only holds its mapping while traffic
## keeps arriving, so we answer for as long as the handshake lasts.
func _on_peer_punched(address: String, port: int) -> void:
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer == null or _punch == null:
		return
	_punch.blast_over_enet(peer, address, port)


## Keep the room alive. A missed beat is not fatal to the session, only to new
## players finding it, so this warns rather than tearing anything down: a
## registry that dies mid-game must not end the game.
func _start_heartbeat(ttl: int) -> void:
	_stop_heartbeat()
	_heartbeat = Timer.new()
	_heartbeat.wait_time = maxf(5.0, float(ttl) / 3.0)
	_heartbeat.timeout.connect(_beat)
	add_child(_heartbeat)
	_heartbeat.start()


func _beat() -> void:
	if _rendezvous == null or _room_code.is_empty():
		return
	_rendezvous.heartbeat(_room_code, _room_secret,
		func(res: int, _ttl: int) -> void:
			if res != RendezvousClient.Result.OK:
				push_warning("[NetworkManager] room %s missed a heartbeat" % _room_code)
	)


func _stop_heartbeat() -> void:
	if _heartbeat != null:
		_heartbeat.stop()
		_heartbeat.queue_free()
		_heartbeat = null


## Drop the room and everything holding it open. Safe to call when none of it
## was ever created.
func _teardown_online() -> void:
	_stop_heartbeat()
	if _rendezvous != null and not _room_code.is_empty():
		_rendezvous.close_room(_room_code, _room_secret)
	if not _room_code.is_empty():
		_room_code = ""
		_room_secret = ""
		room_code_changed.emit("")
	if _punch != null:
		_punch.queue_free()
		_punch = null


## What to say when a punch fails. Naming the likely cause matters more here
## than anywhere else in this file: roughly one attempt in five cannot be
## punched at all, and a player given a blank failure will simply retry it.
func _punch_failure(result: int) -> String:
	match result:
		Punchthrough.Result.NO_SUCH_HOST:
			return "That game is no longer running."
		Punchthrough.Result.UNREACHABLE:
			return "Could not reach the RetroXR server. Try hosting on LAN."
		Punchthrough.Result.PROTOCOL_ERROR:
			# Split from UNREACHABLE deliberately. The two are one keystroke
			# apart in the code and a world apart when something is wrong: this
			# one means the punch server answered the socket and then ignored
			# the conversation, which happened on 2026-08-25 and sent the person
			# debugging it into the registry, the one part that was healthy.
			return ("The RetroXR punch server is not responding. Hosting on LAN "
				+ "still works.")
		_:
			return ("Could not reach the other player directly. This usually means "
				+ "one of you is on a mobile hotspot or a restricted network. "
				+ "Try a different Wi-Fi, or use LAN mode.")


func leave_session(reason := "left session") -> void:
	if not _active:
		return
	if _netplay != null:
		_netplay.stop("session ended")
	_file_transfer.end_session()
	_object_sync.end_session()
	_active = false
	_accepted = false
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer.close()
		multiplayer.multiplayer_peer = null
	peers.clear()
	_latest_poses.clear()
	_teardown_online()
	_teardown_world()
	status_changed.emit("Not connected")
	session_ended.emit(reason)


# ── Object-sync facade (hooks in world objects call these) ────────────────────

## Forward a state-transition event to the shared world (no-op offline).
func report_event(kind: int, args: Dictionary) -> void:
	if _active and _object_sync != null:
		_object_sync.report_event(kind, args)


## True while remote state is being applied locally (hooks must not re-report).
func is_event_applying() -> bool:
	return _object_sync != null and _object_sync.is_applying()


## Called by the spawn flow when a new object was placed while in a session.
func on_local_spawn(obj: Node3D) -> void:
	if _active and _object_sync != null:
		_object_sync.local_spawn(obj)


## A host deck's transport changed — broadcast it so peers can follow (M5).
##
## One entry point for the VCR, the DVD player and the CD/cassette player: they
## all publish the same net_get_state Dictionary, so they do not need a report
## function each.
func report_media_state(deck: Node) -> void:
	if _active and _object_sync != null:
		_object_sync.send_media_state(deck)


# ── Netplay facade (M4) ───────────────────────────────────────────────────────

## True if the core is determinism-verified for lockstep netplay.
func netplay_capable(core_name: String) -> bool:
	return NetplayCores.is_capable(core_name)


## True while a netplay game is running.
func netplay_running() -> bool:
	return _netplay != null and _netplay.is_running()


## global port -> peer_id for the running session, or {}.
##
## This is the map the input scheduler samples from, so it cannot drift from
## what is actually being played. A port is machine * PORTS_PER_MACHINE + port,
## which is what lets a linked pair's two machines share one numbering; decode
## it with netplay_port_of() / netplay_machine_of(). A peer holding no port at
## all is a spectator.
func netplay_owners() -> Dictionary:
	if _netplay == null or not _netplay.is_running():
		return {}
	return _netplay.owners()


## Which machine in the group a global port belongs to.
func netplay_machine_of(global_port: int) -> int:
	return global_port / NetplayWire.PORTS_PER_MACHINE


## The port number on that machine, 0-based.
func netplay_port_of(global_port: int) -> int:
	return global_port % NetplayWire.PORTS_PER_MACHINE


## The system currently under netplay, or null.
func netplay_system() -> Object:
	return _netplay.system() if _netplay != null else null


## The shared-room sync layer, or null before a session exists. Exposed so the
## netplay UI stops reaching for this facade's own private member by name.
func object_sync() -> NetObjectSync:
	return _object_sync


## The lockstep session, or null before one exists.
func netplay_session() -> NetplaySession:
	return _netplay


## True when a running netplay session covers `machine` — i.e. a cable seated on
## it has to be scheduled onto an agreed frame rather than joined on the spot.
func netplay_covers(machine: Object) -> bool:
	return _netplay != null and _netplay.covers(machine)


## Host: schedule a link-cable change for the running session. `entries` are
## [{machine, port}, ...], head first. op 1 joins them as one bus, op 0 drops
## the single named port.
func netplay_schedule_link(op: int, entries: Array) -> void:
	if _netplay != null and is_host():
		_netplay.schedule_link_for(op, entries)


## Host: begin netplay for `system`. `owners` maps port -> peer_id (defaults to
## a sensible assignment across connected peers). rollback: -1 auto (core
## capability), 0 force lockstep, 1 force rollback. Returns false if not host,
## core not verified, or already running.
func netplay_start_host(system: Object, core: String, rom_md5: String,
		owners: Dictionary = {}, delay := 3, rollback := -1) -> bool:
	if _netplay == null or not is_host():
		return false
	if owners.is_empty():
		owners = default_owners(system)
	return _netplay.start_host(system, core, rom_md5, owners, delay, rollback)


## Assign participating ports to peers: port index i -> the i-th peer (host
## first). Only ports with a controller plugged in participate.
func default_owners(system: Object) -> Dictionary:
	var ids: Array = peers.keys()
	ids.sort()
	var owners := {}
	# Over the whole bus, not just the machine the power button was pressed on:
	# a cabled pair is one session over two machines, and a port is named by
	# machine * PORTS_PER_MACHINE + port so both machines' pads fit in one frame.
	var group: Array = [system]
	if system != null and system.has_method("net_link_group"):
		var bus: Array = system.net_link_group()
		if bus.size() > 1:
			group = bus
	var plugged: Array = []
	for m in range(group.size()):
		var machine: Object = group[m]
		var found := false
		if machine != null and machine.has_method("port_holders"):
			var pc: Array = machine.port_holders()
			for i in range(pc.size()):
				if pc[i] != null:
					plugged.append(m * NetplaySession.PORTS_PER_MACHINE + i)
					found = true
		if not found:
			# Every machine on the wire needs at least one port in the frame, or
			# its core is gated on inputs the assembler never asks anyone for.
			plugged.append(m * NetplaySession.PORTS_PER_MACHINE)
	for i in range(plugged.size()):
		var global_port := int(plugged[i])
		var machine: Object = group[NetplaySession.machine_of_port(global_port)]
		var local_port := NetplaySession.port_on_machine(global_port)
		var controller: Object = null
		if machine != null and machine.has_method("port_holders"):
			var pc: Array = machine.port_holders()
			if local_port < pc.size():
				controller = pc[local_port]
		var holder := _object_sync.holder_peer(controller) if _object_sync != null else 0
		owners[global_port] = holder if holder > 0 else ids[i % ids.size()]
	return owners


## Stop the active netplay game.
func netplay_stop(reason := "stopped") -> void:
	if _netplay != null:
		_netplay.stop(reason)


## Input seam: called from retro_controller. Returns true if netplay consumed
## the input (caller must not drive the core directly).
func netplay_route(system: Object, port: int, m: Dictionary) -> bool:
	return _netplay != null and _netplay.route(system, port, m)


## Host: a netplay-registered controller changed hands to `peer_id`. If it
## occupies a participating netplay port owned by someone else, hand that port
## (and thus who drives it) to the new holder. No-op off-session / non-host.
func netplay_handoff(controller: Object, peer_id: int) -> void:
	if _netplay != null:
		_netplay.handoff_controller(controller, peer_id)


func netplay_handoff_port(system: Object, port: int, peer_id: int) -> void:
	if _netplay != null:
		_netplay.handoff_port(system, port, peer_id)


## Host: frame-schedule a disc eject/swap for the running netplay game so
## every peer's core applies it on the same frame. op 0 = eject, op 1 =
## replace image `index` with the disc whose md5 matches (resolved locally
## on each peer — disc files are never transferred).
func netplay_schedule_disk(system: Object, op: int, md5: String, index: int) -> void:
	if _netplay != null:
		_netplay.schedule_disk_op(system, op, md5, index)


## Host: frame-schedule a front-panel reset for one machine in the active
## netplay group so every peer resets before the same emulated frame.
func netplay_schedule_reset(system: Object) -> void:
	if _netplay != null:
		_netplay.schedule_reset(system)


## Host: spectators waiting for a restart to let them into the running game.
func netplay_pending_joins() -> Array:
	if _netplay == null or not is_host():
		return []
	return _netplay.pending_join_peers()


## Host: start the game again so the people waiting to join are in it.
##
## A stop and a fresh cold start, not a reset. Ownership is decided once, at
## start, from whoever is holding each pad, so admitting somebody new means
## deciding it again -- and that is a new session by definition. Everyone loses
## the game in progress, which is why nothing calls this on its own: it is what
## RESET means while somebody is stood there waiting.
func netplay_rejoin_restart(system: Object) -> bool:
	if _netplay == null or not is_host() or system == null:
		return false
	# Read the claims BEFORE stopping. The stop clears them, along with every
	# other per-session record of who was watching.
	var waiting := _netplay.pending_join_peers()
	if waiting.is_empty():
		return false
	var core := str(system.resolve_core_name()) if system.has_method("resolve_core_name") else ""
	var rom_md5 := str(system.net_rom_md5()) if system.has_method("net_rom_md5") else ""
	print("[Netplay] restarting to admit %d waiting player(s)" % waiting.size())
	_netplay.stop("restarting to let %d more player(s) in" % waiting.size())
	# The pads have not moved, so default_owners reads the same hands it would
	# have read a moment ago -- including the ones that were being refused.
	return netplay_start_host(system, core, rom_md5)


## Aux input feeds for the running game. True means netplay consumed the input.
func netplay_set_aux_sensor(system: Object, port: int, sensor_index: int,
		x_mg: int, y_mg: int, z_mg: int, gyro := false) -> bool:
	return _netplay != null and _netplay.set_aux_sensor(system, port, sensor_index,
		x_mg, y_mg, z_mg, gyro)


func netplay_set_aux_pointer(system: Object, port: int, pointer_index: int,
		px: int, py: int, pressed: bool) -> bool:
	return _netplay != null and _netplay.set_aux_pointer(system, port, pointer_index,
		px, py, pressed)


func netplay_set_lightgun_button(system: Object, port: int, button: int,
		pressed: bool) -> bool:
	return _netplay != null and _netplay.set_lightgun_button(system, port, button, pressed)


func netplay_set_lightgun_aim(system: Object, port: int, px: int, py: int,
		offscreen: bool) -> bool:
	return _netplay != null and _netplay.set_lightgun_aim(system, port, px, py, offscreen)


## Queue a keyboard transition into the running netplay game's deterministic
## schedule. Returns true when netplay consumed it (caller must NOT feed the
## core directly).
func netplay_queue_key(system: Object, keycode: int, down: bool, character: int) -> bool:
	return _netplay != null and _netplay.queue_key_event(system, keycode, down, character)


## Round-trip time in ms to peer `id` as known locally, or -1 when unknown.
## The host knows every client's RTT; a client only knows its RTT to the host.
func ping_ms(id: int) -> int:
	if not _active or multiplayer == null:
		return -1
	var peer := multiplayer.multiplayer_peer as ENetMultiplayerPeer
	if peer == null:
		return -1
	var self_id := multiplayer.get_unique_id()
	if id == self_id:
		return 0
	var target := id if is_host() else 1
	if not is_host() and id != 1:
		return -1   # client can't see client<->client RTT
	var p: ENetPacketPeer = peer.get_peer(target)
	if p == null:
		return -1
	return int(p.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))


## Local LAN IPv4 addresses (for the host UI).
func local_ips() -> Array[String]:
	var out: Array[String] = []
	for ip: String in IP.get_local_addresses():
		if ip.begins_with("192.168.") or ip.begins_with("10.") \
				or (ip.begins_with("172.") and int(ip.split(".")[1]) >= 16 and int(ip.split(".")[1]) <= 31):
			out.append(ip)
	return out


# ── Connection lifecycle ──────────────────────────────────────────────────────

func _wire_signals() -> void:
	if _signals_wired:
		return
	_signals_wired = true
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(func():
		print("[NetworkManager] ENet connection failed")
		leave_session("connection failed"))
	multiplayer.server_disconnected.connect(func():
		print("[NetworkManager] ENet host disconnected")
		leave_session("host disconnected"))
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)


func _on_connected_to_server() -> void:
	print("[NetworkManager] ENet connected as peer %d; registering" % multiplayer.get_unique_id())
	# The mod list rides in the info dict, not the packs themselves. A peer with
	# a different set is told so and refused; it is never sent the mod. A mod is
	# a file the player chose to install, and this app is not a channel for
	# distributing one.
	_register.rpc_id(1, {
		"name": player_name,
		"is_vr": get_viewport().use_xr,
		"mods": Mods.fingerprint(),
	}, PROTOCOL_VERSION)


func _on_peer_disconnected(id: int) -> void:
	if not _active:
		return
	if is_host() and peers.has(id):
		peers.erase(id)
		_latest_poses.erase(id)
		_remove_avatar(id)
		_peer_left_msg.rpc(id)
		peer_left.emit(id)
		status_changed.emit("%d player(s) connected" % peers.size())
		if _object_sync != null:
			_object_sync.on_peer_left(id)
		# A departed peer that owned a netplay port would stall the assembler
		# forever — end the game for everyone.
		if _netplay != null and _netplay.is_active():
			_netplay.on_peer_left(id)


func _local_info(color_idx: int) -> Dictionary:
	return {"name": player_name, "is_vr": get_viewport().use_xr, "color_idx": color_idx}


func _next_color_idx() -> int:
	var used := {}
	for id: int in peers:
		used[int(peers[id].get("color_idx", 0))] = true
	for i in PLAYER_COLORS.size():
		if not used.has(i):
			return i
	return peers.size() % PLAYER_COLORS.size()


# ── Handshake RPCs ────────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable", CH_CONTROL)
func _register(info: Dictionary, version: int) -> void:
	if not is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	if version != PROTOCOL_VERSION:
		_reject.rpc_id(sender, "version mismatch (host %d, you %d)" % [PROTOCOL_VERSION, version])
		return
	if peers.size() >= MAX_PLAYERS:
		_reject.rpc_id(sender, "server full")
		return
	# Mods change what objects exist and what a console looks like, so a room
	# shared between mismatched peers is one where the two see different rooms —
	# and under netplay, one where a mod console desyncs the emulation. Refused
	# with the difference named, so the player knows what to install or remove.
	var their_mods: PackedStringArray = info.get("mods", PackedStringArray())
	var our_mods := Mods.fingerprint()
	if their_mods != our_mods:
		_reject.rpc_id(sender, "mods do not match: %s"
			% Mods.fingerprint_mismatch(our_mods, their_mods))
		return
	var entry := {
		"name": str(info.get("name", "Player")).left(24),
		"is_vr": bool(info.get("is_vr", false)),
		"color_idx": _next_color_idx(),
	}
	peers[sender] = entry
	print("[NetworkManager] accepted peer %d (%s); roster=%d" % [
		sender, entry["name"], peers.size()])
	var scene_id: String = SceneManager.current_scene_id if has_node("/root/SceneManager") else ""
	_accept.rpc_id(sender, peers.duplicate(true), scene_id)
	for id: int in peers:
		if id != 1 and id != sender:
			_peer_joined_msg.rpc_id(id, sender, entry)
	_add_avatar(sender, entry)
	peer_registered.emit(sender, entry)
	status_changed.emit("%d player(s) connected" % peers.size())


func _on_peer_world_ready(peer_id: int) -> void:
	print("[NetworkManager] peer %d applied the world snapshot" % peer_id)
	# Netplay references systems by ids minted in that snapshot. Starting the
	# late-join handshake before the client confirms it has instantiated them is
	# a race that intermittently resolves every machine as null.
	if _netplay != null and _netplay.is_running():
		_netplay.on_peer_joined(peer_id)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _accept(roster: Dictionary, scene_id: String) -> void:
	peers = roster
	_accepted = true
	print("[NetworkManager] registration accepted; roster=%d" % peers.size())
	if has_node("/root/SceneManager") and not scene_id.is_empty() \
			and scene_id != SceneManager.current_scene_id:
		_follow_host_scene(scene_id)
	else:
		_setup_world()
	status_changed.emit("Connected — %d player(s)" % peers.size())
	session_started.emit(false)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _reject(reason: String) -> void:
	leave_session("rejected: %s" % reason)


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _peer_joined_msg(id: int, info: Dictionary) -> void:
	peers[id] = info
	_add_avatar(id, info)
	peer_registered.emit(id, info)
	status_changed.emit("Connected — %d player(s)" % peers.size())


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _peer_left_msg(id: int) -> void:
	peers.erase(id)
	_remove_avatar(id)
	peer_left.emit(id)
	status_changed.emit("Connected — %d player(s)" % peers.size())


@rpc("authority", "call_remote", "reliable", CH_CONTROL)
func _scene_change(scene_id: String) -> void:
	if has_node("/root/SceneManager"):
		_follow_host_scene(scene_id)


func _follow_host_scene(scene_id: String) -> void:
	SceneManager.net_scene_override = true
	SceneManager.change_scene(scene_id)
	SceneManager.net_scene_override = false


# ── Pose sync ─────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _active or not _accepted:
		return
	_pose_accum += delta
	if _pose_accum < POSE_INTERVAL:
		return
	_pose_accum = 0.0

	var pose := _sample_local_pose()
	if is_host():
		if not pose.is_empty():
			_latest_poses[1] = pose
		if not _latest_poses.is_empty():
			_pose_broadcast.rpc(_latest_poses)
			_apply_poses(_latest_poses)
	else:
		if not pose.is_empty():
			_pose_report.rpc_id(1, pose)


func _sample_local_pose() -> PackedFloat32Array:
	if pose_source.is_valid():
		return pose_source.call()
	if is_instance_valid(_broadcaster):
		return _broadcaster.sample()
	return PackedFloat32Array()


@rpc("any_peer", "call_remote", "unreliable_ordered", CH_POSE)
func _pose_report(pose: PackedFloat32Array) -> void:
	if not is_host() or pose.size() != 21:
		return
	var sender := multiplayer.get_remote_sender_id()
	if peers.has(sender):
		_latest_poses[sender] = pose


@rpc("authority", "call_remote", "unreliable_ordered", CH_POSE)
func _pose_broadcast(poses: Dictionary) -> void:
	_apply_poses(poses)


func _apply_poses(poses: Dictionary) -> void:
	var self_id := multiplayer.get_unique_id()
	for id: Variant in poses:
		var pid := int(id)
		if pid == self_id:
			continue
		var avatar: Node = _avatars.get(pid)
		if is_instance_valid(avatar):
			avatar.push_pose(poses[id])


# ── World / avatars ───────────────────────────────────────────────────────────

func _resolve_world_root() -> Node:
	if world_root != null and is_instance_valid(world_root):
		return world_root
	return get_tree().current_scene


func _setup_world() -> void:
	# Probes inject world_root. The real scene tree waits until its slot restore is
	# complete, otherwise the host can answer a snapshot request with an empty or
	# half-restored room.
	if world_root == null and has_node("/root/SceneManager") \
			and not SceneManager.is_scene_content_ready(SceneManager.current_scene_id):
		return
	_teardown_world()
	var root := _resolve_world_root()
	if root == null:
		return
	_avatars_container = Node3D.new()
	_avatars_container.name = "NetAvatars"
	root.add_child(_avatars_container)
	var self_id := multiplayer.get_unique_id()
	for id: int in peers:
		if id != self_id:
			_add_avatar(id, peers[id])
	_attach_broadcaster()
	_object_sync.on_world_ready()


func _teardown_world() -> void:
	for id: int in _avatars.keys():
		_remove_avatar(id)
	_avatars.clear()
	if is_instance_valid(_avatars_container):
		_avatars_container.queue_free()
	_avatars_container = null
	if is_instance_valid(_broadcaster):
		_broadcaster.queue_free()
	_broadcaster = null


func _add_avatar(id: int, info: Dictionary) -> void:
	if not is_instance_valid(_avatars_container) or _avatars.has(id):
		return
	var avatar := AVATAR_SCENE.instantiate()
	avatar.name = "Avatar_%d" % id
	_avatars_container.add_child(avatar)
	avatar.setup(str(info.get("name", "?")),
		PLAYER_COLORS[int(info.get("color_idx", 0)) % PLAYER_COLORS.size()],
		bool(info.get("is_vr", false)))
	_avatars[id] = avatar


func _remove_avatar(id: int) -> void:
	var avatar: Node = _avatars.get(id)
	if is_instance_valid(avatar):
		avatar.queue_free()
	_avatars.erase(id)


## Attach a pose broadcaster next to the player rig's camera (skipped when no
## rig exists, e.g. in probes, which inject pose_source instead).
func _attach_broadcaster() -> void:
	if pose_source.is_valid():
		return
	var cams := get_tree().root.find_children("*", "XRCamera3D", true, false)
	if cams.is_empty():
		return
	var cam := cams[0] as XRCamera3D
	_broadcaster = POSE_BROADCASTER.new()
	_broadcaster.name = "NetPoseBroadcaster"
	cam.get_parent().add_child(_broadcaster)


func _on_scene_changed(scene_id: String) -> void:
	if not _active or not _accepted:
		return
	if _netplay != null and _netplay.is_active():
		_netplay.stop("room changed")
	_object_sync.reset_for_scene_change()
	_teardown_world()
	world_root = null
	# Host propagates the switch only after its old registry has been silenced.
	if is_host():
		_scene_change.rpc(scene_id)


func _on_scene_content_ready(scene_id: String) -> void:
	if not _active or not _accepted or scene_id != SceneManager.current_scene_id:
		return
	_setup_world()
