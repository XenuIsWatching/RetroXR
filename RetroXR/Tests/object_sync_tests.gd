extends Node

## Network/object-sync regression suite. Two complete NetworkManagers share this
## process but use separate SceneMultiplayer roots and real loopback ENet.
## No ROM, core, headset, display or user files are required.
##
##   "$godot" --headless --path RetroXR res://Tests/object_sync_tests.tscn
##   "$godot" --headless --path RetroXR res://Tests/object_sync_tests.tscn -- --only=hinges

const NM_SCRIPT := preload("res://Scripts/Net/network_manager.gd")
const POSE_BROADCASTER := preload("res://Scripts/Net/netplay/pose_broadcaster.gd")
const MEMORY_CARD := preload("res://Scenes/Objects/media/memory_card.tscn")
const WIIMOTE := preload("res://Scenes/Objects/controllers/wii/wiimote.tscn")
const RETRO_SYSTEM := preload("res://Scenes/Objects/system.tscn")
const RETRO_CONTROLLER := preload("res://Scenes/Objects/controllers/retro_controller.tscn")
const TV := preload("res://Scenes/Objects/tv.tscn")
const AVATAR := preload("res://Scenes/Net/remote_avatar.tscn")
const PORT := 42917
const GROUPS := ["registry", "snapshot", "spawn", "motion", "authority",
	"controllers", "hinges", "events", "relay", "avatars", "lifecycle"]

var _fail := 0
var _ran := 0
var _only := ""


class StubNM extends Node:
	var world: Node = null
	var active := false
	var disk_calls: Array = []
	var handoff_calls: Array = []
	func is_host() -> bool: return true
	func is_client() -> bool: return false
	func is_active() -> bool: return active
	func _resolve_world_root() -> Node: return world
	func netplay_schedule_disk(system: Object, op: int, md5: String, index: int) -> void:
		disk_calls.append([system, op, md5, index])
	func netplay_handoff_port(system: Object, port: int, owner: int) -> void:
		handoff_calls.append([system, port, owner])


class MockPowerHost extends Node3D:
	var is_powered_on := false
	var toggles := 0
	func toggle_power() -> void:
		toggles += 1
		is_powered_on = not is_powered_on


class MockRoomLight extends LightSwitch:
	func _ready() -> void: pass
	func set_lights_on(on: bool) -> void: lights_on = on


class MockPullLight extends BeadPullCord:
	func _ready() -> void: pass
	func set_lit_remote(on: bool) -> void: lit = on


class MockBlinds extends WindowBlinds:
	func _ready() -> void: pass
	func set_drop_remote(value: float) -> void: drop = value


class MockTimeOfDay extends TimeOfDay:
	func _ready() -> void: pass
	func net_set_time(value: float) -> void: time = value


class MockHingeBody extends RigidBody3D:
	var target_node: Node3D
	var hinge: VRHinge
	func _init() -> void:
		target_node = Node3D.new()
		target_node.name = "Panel"
		add_child(target_node)
		hinge = VRHinge.new()
		hinge.name = "Hinge"
		hinge.target = target_node
		hinge.min_deg = -20.0
		hinge.max_deg = 120.0
		target_node.add_child(hinge)


class MockControlsBody extends RigidBody3D:
	var spring: VRSpringLatchedHinge
	var push_spring: VRSpringLatchedHinge
	var lever: VRLever
	var knob: VRKnob
	var slider: VRSlider
	var return_slider: VRSpringReturnSlider
	var button: VRButton
	var knob_effect := 0.0
	var slider_effect := 0.0
	var return_slider_effect := 0.0
	var lever_effect := 0.0
	func _init() -> void:
		var spring_pivot := Node3D.new()
		spring_pivot.name = "SpringPanel"
		add_child(spring_pivot)
		spring = VRSpringLatchedHinge.new()
		spring.name = "SpringHinge"
		spring.target = spring_pivot
		spring.min_deg = 0.0
		spring.max_deg = 100.0
		spring.spring_speed_deg = 0.0
		spring_pivot.add_child(spring)

		var push_pivot := Node3D.new()
		push_pivot.name = "PushSpringPanel"
		add_child(push_pivot)
		push_spring = VRSpringLatchedHinge.new()
		push_spring.name = "PushSpringHinge"
		push_spring.target = push_pivot
		push_spring.min_deg = 0.0
		push_spring.max_deg = 85.0
		push_spring.spring_speed_deg = 0.0
		push_spring.push_push = true
		push_pivot.add_child(push_spring)

		var lever_pivot := Node3D.new()
		lever_pivot.name = "LeverPanel"
		add_child(lever_pivot)
		lever = VRLever.new()
		lever.name = "Lever"
		lever.target = lever_pivot
		lever.min_deg = 0.0
		lever.max_deg = 90.0
		lever.value_at_min = 0.0
		lever.value_at_max = 1.0
		lever_pivot.add_child(lever)

		knob = VRKnob.new()
		knob.name = "Knob"
		var knob_pivot := Node3D.new()
		knob_pivot.name = VRKnob.PIVOT_NAME
		knob.add_child(knob_pivot)
		knob.target = knob_pivot
		add_child(knob)
		knob.value_changed.connect(func(v: float) -> void: knob_effect = v)

		slider = VRSlider.new()
		slider.name = "Slider"
		add_child(slider)
		slider.value_changed.connect(func(v: float) -> void: slider_effect = v)

		return_slider = VRSpringReturnSlider.new()
		return_slider.name = "ReturnSlider"
		return_slider.return_speed = 0.0
		add_child(return_slider)
		return_slider.value_changed.connect(func(v: float) -> void: return_slider_effect = v)

		button = VRButton.new()
		button.name = "Button"
		var button_mesh := MeshInstance3D.new()
		button_mesh.name = "ButtonMesh"
		button_mesh.mesh = BoxMesh.new()
		button.add_child(button_mesh)
		add_child(button)
		lever.value_changed.connect(func(v: float) -> void: lever_effect = v)


class MockSlot extends Node:
	var drops := 0
	func drop_object() -> void: drops += 1


class MockEventObject extends Node3D:
	var sync: NetObjectSync = null
	var tray_open := false
	var pages: Array = []
	var applying_seen := false
	var restored: Dictionary = {}
	var cable_calls: Array = []
	var plug_calls: Array = []
	var transport: Array[String] = []
	var power_toggles := 0
	var resets := 0
	var remote_power := false
	var tv_power_toggles := 0
	var volume := 0.5
	var muted := false
	var crt := false
	var stereo_mode := 0
	var audio_mode := 0
	var widescreen := false
	var source := 0
	var rf_channel := 3
	var channel_index := -1
	var scale_factor := 1.0
	var video_out := true
	var floating := false
	var size_scale := 1.0
	var half_page_mode := false
	var room_lights := true
	var pull_lit := true
	var blinds_drop := 1.0
	var day_time := 0.75

	func _init() -> void:
		for slot_name: String in ["CartridgeSlot", "TapeSlot", "ControllerPort1",
				"MemoryCardSlot", "MemoryCardSlot2", "DiscSlot", "MediaSlot"]:
			var slot := MockSlot.new()
			slot.name = slot_name
			add_child(slot)

	func net_set_tray_open(open: bool) -> void:
		tray_open = open
		applying_seen = sync != null and sync.is_applying()
	func set_page(state: int, leaf: int) -> void:
		pages.append([state, leaf])
		applying_seen = sync != null and sync.is_applying()
	func restore_cartridge(obj: Node) -> void: restored["cart"] = obj
	func restore_tape(obj: Node) -> void: restored["tape"] = obj

	# The removal half of the same contract. object_sync asks the owner to give
	# the media up rather than reaching for its child by name, so the mock has to
	# answer these the way a real machine or deck does.
	func net_release_cartridge() -> void: _drop("CartridgeSlot")
	func net_release_tape() -> void: _drop("TapeSlot")
	func net_release_disc() -> void: _drop("DiscSlot")
	func net_release_controller_port(port: int) -> void:
		_drop("ControllerPort%d" % (port + 1))
	func _drop(slot_name: String) -> void:
		var slot := get_node_or_null(slot_name) as MockSlot
		if slot != null:
			slot.drop_object()
	func restore_memory_card(obj: Node, slot := 0) -> void:
		restored["card"] = obj
		restored["card_slot"] = slot
	func restore_disc(obj: Node) -> void: restored["disc"] = obj
	func restore_media(obj: Node) -> void: restored["media"] = obj
	## An audio deck unseats through its own loader now, rather than the event
	## reaching into get_node("MediaSlot").drop_object(). That reach only ever
	## worked for a SLOT deck: a tray deck's media is not held by the snap zone at
	## all, so the old call unseated nothing. A front loader ejects, which is what
	## this models.
	func remove_media() -> void:
		(get_node("MediaSlot") as MockSlot).drop_object()
	func restore_cable_connection(tv: Node, channel := -1, input := -1) -> void:
		cable_calls.append([tv, channel, input])
	func release_input(input: int) -> void: cable_calls.append(["release", input])
	func net_seat_plug(end: int, cord: int, dev: Node, port: String) -> void:
		plug_calls.append(["seat", end, cord, dev, port])
	func net_release_plug(end: int, cord: int) -> void:
		plug_calls.append(["release", end, cord])
	func restore_port_connection(sys: Node, port: int) -> void:
		plug_calls.append(["controller", sys, port])
	func toggle_power() -> void: power_toggles += 1
	func reset() -> void: resets += 1
	func net_set_remote_power(on: bool) -> void: remote_power = on
	func remote_power_toggle() -> void: tv_power_toggles += 1
	func remote_volume_up() -> void: volume = minf(1.0, volume + 0.1)
	func remote_volume_down() -> void: volume = maxf(0.0, volume - 0.1)
	func remote_mute_toggle() -> void: muted = not muted
	func set_crt_enabled(on: bool) -> void: crt = on
	func set_stereo_mode(mode: int) -> void: stereo_mode = mode
	func set_audio_mode(mode: int) -> void: audio_mode = mode
	func set_widescreen(on: bool) -> void: widescreen = on
	func set_source(which: int) -> void: source = which
	func net_set_channel_state(which: int, rf: int, index: int) -> void:
		source = which
		rf_channel = rf
		channel_index = index
	func set_tv_scale(value: float) -> void: scale_factor = value
	func set_video_out_enabled(on: bool) -> void: video_out = on
	func set_ignore_gravity(on: bool) -> void: floating = on
	func set_lights_on(on: bool) -> void: room_lights = on
	func set_lit_remote(on: bool) -> void: pull_lit = on
	func set_drop_remote(value: float) -> void: blinds_drop = value
	func net_set_time(value: float) -> void: day_time = value
	func remote_play() -> void: transport.append("play")
	func remote_pause() -> void: transport.append("pause")
	func remote_stop() -> void: transport.append("stop")
	func remote_ff() -> void: transport.append("ff")
	func remote_rewind() -> void: transport.append("rew")
	func remote_next() -> void: transport.append("next")
	func remote_prev() -> void: transport.append("prev")
	func dvd_menu_up() -> void: transport.append("menu_up")
	func dvd_menu_down() -> void: transport.append("menu_down")
	func dvd_menu_left() -> void: transport.append("menu_left")
	func dvd_menu_right() -> void: transport.append("menu_right")
	func dvd_ok() -> void: transport.append("ok")
	func dvd_root_menu() -> void: transport.append("root")
	func dvd_next_chapter() -> void: transport.append("next_ch")
	func dvd_prev_chapter() -> void: transport.append("prev_ch")
	func dvd_cycle_audio() -> void: transport.append("audio")
	func dvd_cycle_subtitle() -> void: transport.append("subtitle")


class Pair:
	var host_root: Node
	var client_root: Node
	var host_nm: Node
	var client_nm: Node
	var host_os: NetObjectSync
	var client_os: NetObjectSync
	var client_id := -1


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[object-sync] TIMEOUT")
		get_tree().quit(1))
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			_only = arg.trim_prefix("--only=")

	if _want("registry"):
		await _test_registry_lifecycle()
	var pair: Pair = null
	if _needs_network():
		pair = await _make_pair()
		if pair == null:
			print("[object-sync] %d checks, %d failure(s)" % [_ran, _fail])
			return get_tree().quit(1)
	if _want("snapshot"):
		await _test_snapshot(pair)
	if _want("spawn"):
		await _test_spawn(pair)
	if _want("motion"):
		await _test_motion(pair)
	if _want("authority"):
		await _test_authority(pair)
	if _want("controllers"):
		await _test_controller_end_to_end(pair)
	if _want("hinges"):
		await _test_hinges(pair)
	if _want("events"):
		await _test_events(pair)
	if _want("relay"):
		await _test_relay(pair)
	if _want("avatars"):
		await _test_avatars(pair)
	if _want("lifecycle"):
		await _test_network_lifecycle(pair)
	if pair != null:
		_free_pair(pair)
		await _frames(5)
	print("[object-sync] %d checks, %s" % [_ran,
		"PASS" if _fail == 0 else "%d FAILURE(S)" % _fail])
	get_tree().quit(0 if _fail == 0 else 1)


func _needs_network() -> bool:
	return _only.is_empty() or _only != "registry"


func _test_registry_lifecycle() -> void:
	var root := Node.new()
	add_child(root)
	var nm := StubNM.new()
	nm.world = root
	root.add_child(nm)
	var sync := NetObjectSync.new()
	nm.add_child(sync)
	var card := _card("REBIND", Vector3.ZERO)
	root.add_child(card)
	card.add_to_group("spawned")
	_ok(sync._register_host(card), "registry/a serializable object registers")
	var id := sync.id_of(card)
	_ok(id > 0 and sync.node_for_id(id) == card, "registry/the id resolves to that object")
	sync._apply_event(NetObjectSync.EV_DISK_OP, {
		"sys": {"$id": id}, "op": 1, "md5": "DISC", "index": 2,
	})
	_eq(nm.disk_calls, [[card, 1, "DISC", 2]],
		"registry/a disc button request reaches the deterministic scheduler")
	var fixed_control := MockEventObject.new()
	fixed_control.name = "FixedRoomControl"
	root.add_child(fixed_control)
	var fixed_wire := sync._encode_args({"switch": fixed_control})
	_ok((fixed_wire.get("switch", {}) as Dictionary).has("$path"),
		"registry/a fixed room control is encoded by scene path")
	_eq(sync._decode_args(fixed_wire).get("switch"), fixed_control,
		"registry/a fixed room control path resolves back to its effect target")
	sync._remote_held[id] = 7
	_eq(sync.holder_peer(card), 7,
		"registry/the authoritative remote holder is available to initial port ownership")
	sync._update_port_owner(NetObjectSync.EV_PORT_PLUG,
		{"sys": card, "ctrl": fixed_control, "port": 2}, 7)
	sync._update_port_owner(NetObjectSync.EV_PORT_UNPLUG, {"sys": card, "port": 2}, 7)
	_eq(nm.handoff_calls, [[card, 2, 7], [card, 2, 0]],
		"registry/plug and unplug events assign and release the netplay port")
	sync.end_session()
	_eq(sync._registry.size(), 0, "registry/end_session clears the lookup")
	sync.on_world_ready()
	_ok(sync.node_for_id(id) == card,
		"registry/re-hosting rebinds objects that already carry an id")

	# Snapshot replacement queues the old object for deletion and binds the new
	# one immediately. The old tree_exiting callback must not erase its successor.
	var replacement := _card("REPLACEMENT", Vector3.ONE)
	root.add_child(replacement)
	sync._bind(replacement, id)
	card.queue_free()
	await get_tree().process_frame
	_ok(sync.node_for_id(id) == replacement,
		"registry/an old tree exit cannot unregister its replacement")
	root.queue_free()
	await get_tree().process_frame


func _make_pair() -> Pair:
	var p := Pair.new()
	p.host_root = _branch("Host")
	p.client_root = _branch("Client")
	p.host_nm = p.host_root.get_node("NetworkManager")
	p.client_nm = p.client_root.get_node("NetworkManager")
	p.host_os = p.host_nm._object_sync
	p.client_os = p.client_nm._object_sync
	_add_fixed_room_controls(p.host_root, false, false, 0.25, 0.9)
	_add_fixed_room_controls(p.client_root, true, true, 1.0, 0.1)

	# Existing world content exercises the initial snapshot. The Wiimote's
	# articulated battery cover is the hinge case that a root transform misses.
	var card := _card("SNAPSHOT", Vector3(0.4, 1.2, -0.3))
	p.host_root.add_child(card)
	card.add_to_group("spawned")
	var remote := WIIMOTE.instantiate() as Node3D
	remote.name = "SnapshotWiimote"
	p.host_root.add_child(remote)
	remote.add_to_group("spawned")
	var hinge := remote.get_node("CoverPivot/BatteryCover") as VRHinge
	hinge.set_rotation_deg_no_signal(73.0)
	var tv := TV.instantiate() as RetroTV
	tv.name = "SnapshotTV"
	tv.stereo_mode = 1
	p.host_root.add_child(tv)
	# Through the public restore path, and after the set is in the tree: volume
	# and mute belong to TvAudio, which does not exist until _ready has run.
	tv.restore_control_state({
		"volume": 0.4, "muted": true, "enabled": false, "widescreen": true,
		"source": RetroTV.Source.RF, "rf_channel": 4, "audio_mode": 2,
	})
	tv.add_to_group("spawned")

	# This must be removed by the host snapshot, without touching the host or a
	# similarly-grouped object outside the client's world root.
	var stray := _card("CLIENT_STRAY", Vector3(9, 9, 9))
	p.client_root.add_child(stray)
	stray.add_to_group("spawned")
	var outside := _card("OUTSIDE", Vector3(-9, -9, -9))
	add_child(outside)
	outside.add_to_group("spawned")
	p.client_root.set_meta("test_stray", stray)
	p.host_root.set_meta("test_outside", outside)

	p.host_nm.host_game(PORT)
	p.client_nm.join_game("::1", PORT)
	if not await _until(func() -> bool:
		return p.host_nm.peers.size() == 2 and p.client_nm.peers.size() == 2 \
			and p.client_os._registry.size() >= 2, 900):
		_ok(false, "harness/host and client connect and apply the snapshot")
		_free_pair(p)
		return null
	p.client_id = _other_id(p.host_nm, 1)
	_ok(true, "harness/host and client connect and apply the snapshot")
	return p


func _add_fixed_room_controls(root: Node, lights: bool, lamp: bool,
		blinds: float, time: float) -> void:
	var light := MockRoomLight.new()
	light.name = "RoomLight"
	light.lights_on = lights
	root.add_child(light)
	# A second gang of the SAME class, deliberately holding the opposite state: the
	# bedroom's plate has one, and the capture keys its records by node path rather
	# than by class. A capture that keyed by class would pass every other case here
	# and quietly give a late joiner one switch's state for both.
	var strand := MockRoomLight.new()
	strand.name = "StringLight"
	strand.target = LightSwitch.Target.STRING
	strand.lights_on = not lights
	root.add_child(strand)
	var pull := MockPullLight.new()
	pull.name = "PullLight"
	pull.lit = lamp
	pull.glow = NodePath("MissingGlow") # marks this as a lamp cord, not the blind cord
	root.add_child(pull)
	var shade := MockBlinds.new()
	shade.name = "Blinds"
	shade.drop = blinds
	root.add_child(shade)
	var clock := MockTimeOfDay.new()
	clock.name = "TimeOfDay"
	clock.time = time
	root.add_child(clock)


func _test_snapshot(p: Pair) -> void:
	var host_card := _find_card(p.host_os, "SNAPSHOT")
	var host_remote := _find_named(p.host_os, "SnapshotWiimote")
	var host_tv := _find_named(p.host_os, "SnapshotTV") as RetroTV
	_ok(host_card != null and host_remote != null and host_tv != null,
		"snapshot/the host registers every serializable object in its world")
	var card_id := p.host_os.id_of(host_card)
	var remote_id := p.host_os.id_of(host_remote)
	var tv_id := p.host_os.id_of(host_tv)
	var client_card := p.client_os.node_for_id(card_id)
	var client_remote := p.client_os.node_for_id(remote_id)
	var client_tv := p.client_os.node_for_id(tv_id) as RetroTV
	_ok(client_card is MemoryCard and client_remote is Wiimote and client_tv != null,
		"snapshot/the client reconstructs the same object types")
	_vec((client_card as Node3D).global_position, host_card.global_position,
		"snapshot/root position survives")
	_ok((client_card as RigidBody3D).freeze,
		"snapshot/client rigid bodies start frozen under host authority")
	var client_hinge := client_remote.get_node("CoverPivot/BatteryCover") as VRHinge
	_num(client_hinge.get_rotation_deg(), 73.0,
		"snapshot/an articulated hinge angle survives the snapshot", 0.05)
	var tv_state := client_tv.get_control_state()
	_ok(not bool(tv_state["enabled"]) and is_equal_approx(float(tv_state["volume"]), 0.4)
		and bool(tv_state["muted"]) and bool(tv_state["widescreen"])
		and int(tv_state["source"]) == RetroTV.Source.RF
		and int(tv_state["rf_channel"]) == 4 and int(tv_state["audio_mode"]) == 2
		and client_tv.stereo_mode == 1,
		"snapshot/a TV's power, volume, mute, ratio, source, channel and modes survive")
	_ok((p.client_root.get_node("StringLight") as MockRoomLight).lights_on
		and not (p.client_root.get_node("RoomLight") as MockRoomLight).lights_on,
		"snapshot/two switch gangs of one class arrive with their own states")
	_ok(not (p.client_root.get_node("RoomLight") as MockRoomLight).lights_on
		and not (p.client_root.get_node("PullLight") as MockPullLight).lit
		and is_equal_approx((p.client_root.get_node("Blinds") as MockBlinds).drop, 0.25)
		and is_equal_approx((p.client_root.get_node("TimeOfDay") as MockTimeOfDay).time, 0.9),
		"snapshot/fixed room lights, blinds and time survive a late join")
	var stray: Node = p.client_root.get_meta("test_stray")
	await get_tree().process_frame
	_ok(not is_instance_valid(stray), "snapshot/client-only spawned clutter is cleared")
	var outside: Node = p.host_root.get_meta("test_outside")
	_ok(is_instance_valid(outside), "snapshot/clearing is scoped to the receiving world")
	_ok(not p.host_os._registry.values().has(outside),
		"snapshot/registration is scoped to the host world")

	# Replacing an already-populated snapshot used to let the old nodes' delayed
	# tree_exiting callbacks erase the replacements from the registry.
	var first_client_card := client_card
	p.host_os._send_snapshot(p.client_id)
	_ok(await _until(func() -> bool:
		return p.client_os.node_for_id(card_id) != first_client_card, 300),
		"snapshot/a repeated snapshot replaces the old replica")
	await _frames(2)
	_ok(is_instance_valid(p.client_os.node_for_id(card_id)),
		"snapshot/the replacement remains registered after old nodes exit")


func _test_spawn(p: Pair) -> void:
	var host_card := _card("HOST_SPAWN", Vector3(1.5, 1.0, 0.25))
	p.host_root.add_child(host_card)
	host_card.add_to_group("spawned")
	p.host_nm.on_local_spawn(host_card)
	var host_id := p.host_os.id_of(host_card)
	_ok(host_id > 0, "spawn/the host assigns a real id")
	_ok(await _until(func() -> bool:
		return p.client_os.node_for_id(host_id) is MemoryCard),
		"spawn/a host object appears on the client")
	_vec((p.client_os.node_for_id(host_id) as Node3D).global_position,
		host_card.global_position, "spawn/with its authored pose")

	var provisional := _card("CLIENT_SPAWN", Vector3(-1.25, 0.8, 0.5))
	p.client_root.add_child(provisional)
	provisional.add_to_group("spawned")
	var before := p.host_os._registry.size()
	p.client_nm.on_local_spawn(provisional)
	_ok(await _until(func() -> bool:
		return p.host_os._registry.size() == before + 1 \
			and p.client_os._registry.size() == p.host_os._registry.size(), 600),
		"spawn/a client request is minted by the host and echoed back")
	await get_tree().process_frame
	_ok(not is_instance_valid(provisional),
		"spawn/the client's provisional copy is discarded")


func _test_motion(p: Pair) -> void:
	var host_card := await _ensure_host_card(p, "HOST_SPAWN",
		Vector3(1.5, 1.0, 0.25)) as RigidBody3D
	var id := p.host_os.id_of(host_card)
	var client_card := p.client_os.node_for_id(id) as RigidBody3D
	# Held still for the assertion, because the replica is always one
	# XFORM_INTERVAL behind the host and this compares it against the host's
	# LIVE pose. The card drifts at 0.4-0.6 m/s left to itself, and at 15 Hz
	# that is 27-38 mm of travel per send -- against a 10 mm tolerance. The
	# case then passed only when a poll happened to land just after a packet,
	# which is why it failed about half the time in the full suite and never
	# on its own, where the card is younger and slower.
	#
	# gravity_scale, not freeze: MemoryCard is an XRToolsPickable, which
	# snapshots freeze into restore_freeze on pick-up, and the grab cases
	# further down this same suite would inherit whatever was left set.
	#
	# can_sleep matters as much as gravity here: _host_send_xforms skips a
	# sleeping body on purpose, so a card that is merely held still stops
	# being sent at all and the replica is stranded wherever it last heard
	# about -- 3.4 m away, the whole length of the move. Still AND awake.
	var gravity_was := host_card.gravity_scale
	var can_sleep_was := host_card.can_sleep
	host_card.gravity_scale = 0.0
	host_card.can_sleep = false
	host_card.linear_velocity = Vector3.ZERO
	host_card.angular_velocity = Vector3.ZERO
	host_card.sleeping = false
	host_card.global_position = Vector3(4.0, 1.5, -2.0)
	host_card.rotation = Vector3(0.2, -0.5, 0.1)
	p.host_os._host_send_xforms()
	_ok(await _until(func() -> bool:
		return client_card.global_position.distance_to(host_card.global_position) < 0.01),
		"motion/a distant host body snaps to the authoritative pose",
		"%.3f m apart" % client_card.global_position.distance_to(host_card.global_position))
	# Its own wait rather than a bare read: position can cross the line one
	# frame before rotation does, and asserting immediately caught that.
	_ok(await _until(func() -> bool:
		return client_card.quaternion.angle_to(host_card.quaternion) < 0.02),
		"motion/rotation follows with the position",
		"%.3f rad apart" % client_card.quaternion.angle_to(host_card.quaternion))

	# A locally-held replica must ignore stale host transform packets.
	p.client_os._held_by_me[id] = true
	var held_at := Vector3(-2.0, 1.0, 0.0)
	client_card.global_position = held_at
	host_card.global_position = Vector3(6.0, 1.0, 0.0)
	p.host_os._host_send_xforms()
	await _frames(10)
	_vec(client_card.global_position, held_at,
		"motion/host interpolation does not fight a local grab")
	p.client_os._held_by_me.erase(id)
	host_card.gravity_scale = gravity_was
	host_card.can_sleep = can_sleep_was


func _test_authority(p: Pair) -> void:
	var host_card := await _ensure_host_card(p, "HOST_SPAWN",
		Vector3(1.5, 1.0, 0.25)) as RigidBody3D
	var id := p.host_os.id_of(host_card)
	var client_card := p.client_os.node_for_id(id) as RigidBody3D
	var hand := Node3D.new()
	p.client_root.add_child(hand)
	p.client_os._on_grabbed(client_card, hand)
	_ok(await _until(func() -> bool:
		return int(p.host_os._remote_held.get(id, -1)) == p.client_id),
		"authority/a client grab is granted by the host")
	client_card.global_position = Vector3(2.5, 1.1, -0.75)
	p.client_os._client_send_held()
	_ok(await _until(func() -> bool:
		return host_card.global_position.distance_to(client_card.global_position) < 0.001),
		"authority/only the granted client can move the host body")

	# Host reclaim must explicitly revoke the optimistic client hold; otherwise
	# that client ignores host transforms forever even though its poses are denied.
	var host_hand := Node3D.new()
	p.host_root.add_child(host_hand)
	p.host_os._on_grabbed(host_card, host_hand)
	_ok(await _until(func() -> bool: return not p.client_os._held_by_me.has(id)),
		"authority/a host grab revokes the former client's local hold")
	_ok(not p.host_os._remote_held.has(id),
		"authority/the host clears remote ownership when reclaiming")

	# Grant it again and verify the final release pose and velocities.
	p.client_os._on_grabbed(client_card, hand)
	await _until(func() -> bool: return p.host_os._remote_held.has(id))
	var release_pos := Vector3(-1.0, 1.3, 0.4)
	client_card.global_position = release_pos
	client_card.linear_velocity = Vector3(1.0, 2.0, 3.0)
	client_card.angular_velocity = Vector3(-1.0, 0.5, 2.0)
	p.client_os._on_dropped(client_card)
	_ok(await _until(func() -> bool: return not p.host_os._remote_held.has(id)),
		"authority/release returns ownership to the host")
	_vec(host_card.global_position, release_pos,
		"authority/the final release pose reaches the host")
	_vec(host_card.linear_velocity, Vector3(1.0, 2.0, 3.0),
		"authority/linear release velocity survives")
	_vec(host_card.angular_velocity, Vector3(-1.0, 0.5, 2.0),
		"authority/angular release velocity survives")
	_ok(client_card.freeze, "authority/the released client replica is frozen again")
	hand.queue_free()
	host_hand.queue_free()


func _test_controller_end_to_end(p: Pair) -> void:
	# This is deliberately a real system scene, real universal controller, real
	# captive lead and real XR input tracker. The only absent piece is a core/ROM:
	# PeekJoypadState reads the C++ frontend buffer that a core would poll.
	var host_system := RETRO_SYSTEM.instantiate() as RetroSystem
	host_system.name = "ControllerE2ESystem"
	host_system.systemid = "netplay_test"
	host_system.position = Vector3(-2.0, 0.8, 1.0)
	p.host_root.add_child(host_system)
	host_system.add_to_group("spawned")
	p.host_nm.on_local_spawn(host_system)
	var system_id := p.host_os.id_of(host_system)
	_ok(system_id > 0, "controllers/a real console receives a network id")
	_ok(await _until(func() -> bool:
		return p.client_os.node_for_id(system_id) is RetroSystem, 600),
		"controllers/the real console scene spawns on the client")
	var client_system := p.client_os.node_for_id(system_id) as RetroSystem

	var host_pad := RETRO_CONTROLLER.instantiate() as RetroController
	host_pad.name = "ControllerE2EPad"
	host_pad.position = Vector3(-1.6, 1.0, 1.0)
	p.host_root.add_child(host_pad)
	host_pad.add_to_group("spawned")
	_ok(await _until(func() -> bool: return is_instance_valid(host_pad._cable_plug), 300),
		"controllers/the real pad creates its captive cable and plug")
	p.host_nm.on_local_spawn(host_pad)
	var pad_id := p.host_os.id_of(host_pad)
	_ok(pad_id > 0, "controllers/the real pad receives a network id")
	_ok(await _until(func() -> bool:
		return p.client_os.node_for_id(pad_id) is RetroPadController, 600),
		"controllers/the exact controller scene spawns on the client")
	var client_pad := p.client_os.node_for_id(pad_id) as RetroController
	_ok(await _until(func() -> bool: return is_instance_valid(client_pad._cable_plug), 300),
		"controllers/the client replica creates its own physical cable")
	_eq(client_pad.scene_file_path, host_pad.scene_file_path,
		"controllers/controller model identity survives serialization")

	# Seat the host's actual connector, then send the same semantic event the
	# production snap handler reports. The client must seat its own connector in
	# its own console rather than retaining a cross-peer Node reference.
	host_pad.restore_port_connection(host_system, 0)
	_ok(await _until(func() -> bool: return host_system.port_holder(0) == host_pad),
		"controllers/the host's real plug seats in the real console port")
	p.host_os.report_event(NetObjectSync.EV_PORT_PLUG,
		{"sys": host_system, "ctrl": host_pad, "port": 0})
	_ok(await _until(func() -> bool:
		return client_system.port_holder(0) == client_pad \
			and client_pad._connected_system == client_system \
			and client_pad._port_index == 0, 600),
		"controllers/the physical port connection is rebuilt on the client")

	# Feed a real XRController3D from a tracker, exactly as OpenXR does. Keep the
	# maps deterministic instead of inheriting the player's user:// overrides.
	var origin := XROrigin3D.new()
	add_child(origin)
	var xr_ctrl := XRController3D.new()
	xr_ctrl.name = "ControllerE2EHand"
	xr_ctrl.tracker = &"left_hand"
	xr_ctrl.pose = &"default"
	origin.add_child(xr_ctrl)
	var tracker := XRControllerTracker.new()
	tracker.name = &"left_hand"
	XRServer.add_tracker(tracker)
	tracker.set_pose(&"default", Transform3D.IDENTITY, Vector3.ZERO, Vector3.ZERO,
		XRPose.XR_TRACKING_CONFIDENCE_HIGH)
	tracker.set_input(&"ax_button", 1.0)
	tracker.set_input(&"primary", Vector2(0.75, -0.5))
	host_pad._button_map = ControllerBindings.DEFAULT_BUTTON_MAP.duplicate()
	host_pad._stick_map = ControllerBindings.DEFAULT_STICK_MAP.duplicate()
	host_pad._holding_ctrl = xr_ctrl
	_ok(await _until(func() -> bool: return xr_ctrl.get_is_active(), 120),
		"controllers/the fake OpenXR hand is active")
	_num(xr_ctrl.get_float(&"ax_button"), 1.0,
		"controllers/the tracked face button reaches XRController3D")
	_ok(xr_ctrl.get_vector2(&"primary").distance_to(Vector2(0.75, -0.5)) < 0.001,
		"controllers/the tracked stick reaches XRController3D")
	host_pad._process(1.0 / 60.0)
	var input_state: PackedInt32Array = host_system.get_libretro_node().PeekJoypadState(0)
	_ok((host_pad as AnimatedController)._cur_btn != 0,
		"controllers/the real pad assembles a non-neutral joypad frame")
	_ok(input_state.size() == 5 \
			and (input_state[0] & (1 << ControllerBindings.JOYPAD_X)) != 0 \
			and (input_state[0] & (1 << ControllerBindings.JOYPAD_DOWN)) != 0 \
			and (input_state[0] & (1 << ControllerBindings.JOYPAD_RIGHT)) != 0 \
			and absi(input_state[1] - int(0.75 * 32767.0)) <= 1 \
			and absi(input_state[2] - int(0.5 * 32767.0)) <= 1,
		"controllers/XR button and stick input reaches the C++ libretro port buffer — got %s" \
			% str(input_state))
	tracker.set_input(&"ax_button", 0.0)
	tracker.set_input(&"primary", Vector2.ZERO)
	host_pad._holding_ctrl = null
	_ok(await _until(func() -> bool:
		return host_system.get_libretro_node().PeekJoypadState(0) == \
			PackedInt32Array([0, 0, 0, 0, 0]), 300),
		"controllers/releasing the hand sends a neutral state to the same port")

	# Emit the real pickable signals. NetObjectSync's production signal binding
	# must grant the client authority, stream the pose, then return authority.
	var hand := Node3D.new()
	p.client_root.add_child(hand)
	client_pad.grabbed.emit(client_pad, hand)
	_ok(await _until(func() -> bool:
		return int(p.host_os._remote_held.get(pad_id, -1)) == p.client_id),
		"controllers/a real controller grab transfers authority to the client")
	_eq(int(p.host_nm.default_owners(host_system).get(0, 0)), p.client_id,
		"controllers/a new game initially assigns the port to its physical holder")
	client_pad.global_position = Vector3(1.25, 1.4, -0.8)
	p.client_os._client_send_held()
	_ok(await _until(func() -> bool:
		return host_pad.global_position.distance_to(client_pad.global_position) < 0.001),
		"controllers/the held controller pose reaches the host")
	client_pad.dropped.emit(client_pad)
	_ok(await _until(func() -> bool: return not p.host_os._remote_held.has(pad_id)),
		"controllers/dropping the real pad returns authority to the host")

	# Pulling the host plug and reporting the semantic event clears both actual
	# snap zones and both controller-side connection records.
	host_system.net_release_controller_port(0)
	p.host_os.report_event(NetObjectSync.EV_PORT_UNPLUG,
		{"sys": host_system, "port": 0})
	_ok(await _until(func() -> bool:
		return host_system.port_holder(0) == null and client_system.port_holder(0) == null \
			and host_pad._connected_system == null and client_pad._connected_system == null, 600),
		"controllers/unplug clears the physical port on both peers")

	# A controller owns a separately-parented captive cable. Despawning the pad
	# must remove both replicas and both cables, not leave invisible sync clutter.
	var host_cable: Node = host_pad._cable_instance
	var client_cable: Node = client_pad._cable_instance
	host_pad.queue_free()
	_ok(await _until(func() -> bool:
		return p.host_os.node_for_id(pad_id) == null \
			and p.client_os.node_for_id(pad_id) == null, 600),
		"controllers/despawning the pad removes both controller replicas")
	# Polled, not a fixed wait: a deleted object shrinks away before it is freed
	# (Vanish), so the cables outlive the registry entry by the length of that
	# animation. What matters is that they go, not that they go this frame.
	_ok(await _until(func() -> bool:
		return not is_instance_valid(host_cable) and not is_instance_valid(client_cable), 600),
		"controllers/despawning a pad also removes both captive cables")

	hand.queue_free()
	origin.queue_free()
	XRServer.remove_tracker(tracker)


func _test_hinges(p: Pair) -> void:
	# A busy room can move more controls than one reliable packet accepts. The
	# overflow must remain queued for the next 15 Hz flush; the old code cleared
	# all 65 records and then resized the outgoing array to 64, losing the last
	# released position forever.
	for i in range(NetObjectSync.MAX_HINGES_PER_BATCH + 1):
		p.host_os._hinge_pending["overflow:%d" % i] = {"value": i}
	p.host_os._flush_hinge_updates()
	_eq(p.host_os._hinge_pending.size(), 1,
		"hinges/overflow remains queued instead of being discarded")
	p.host_os._flush_hinge_updates()
	_ok(p.host_os._hinge_pending.is_empty(),
		"hinges/the next packet drains the overflow")

	var host_body := MockHingeBody.new()
	host_body.name = "HingeBody"
	p.host_root.add_child(host_body)
	var client_body := MockHingeBody.new()
	client_body.name = "HingeBody"
	p.client_root.add_child(client_body)
	p.host_os._bind(host_body, 9001)
	p.client_os._bind(client_body, 9001)

	host_body.hinge.set_rotation_deg_remote(48.0)
	p.host_os._flush_hinge_updates()
	_ok(await _until(func() -> bool:
		return absf(client_body.hinge.get_rotation_deg() - 48.0) < 0.05),
		"hinges/a host-driven child hinge reaches the client")
	client_body.hinge.set_rotation_deg_remote(91.0)
	p.client_os._flush_hinge_updates()
	_ok(await _until(func() -> bool:
		return absf(host_body.hinge.get_rotation_deg() - 91.0) < 0.05),
		"hinges/a client-driven child hinge reaches the host")
	_ok(p.host_os._hinge_pending.is_empty() and p.client_os._hinge_pending.is_empty(),
		"hinges/remote application does not echo forever")

	var before := host_body.hinge.get_rotation_deg()
	var bad := p.host_os._apply_hinge_updates([{
		"owner": {"$id": 9001}, "path": "../../NetworkManager", "degrees": 12.0,
	}])
	_eq(bad.size(), 0, "hinges/a path escaping its registered owner is rejected")
	_num(host_body.hinge.get_rotation_deg(), before,
		"hinges/a rejected path changes nothing", 0.001)

	# Other articulated controls have the same root-transform blind spot. A
	# lever is a VRHinge subclass, while knobs/sliders carry normalized values.
	var host_controls := MockControlsBody.new()
	var client_controls := MockControlsBody.new()
	host_controls.name = "Controls"
	client_controls.name = "Controls"
	p.host_root.add_child(host_controls)
	p.client_root.add_child(client_controls)
	p.host_os._bind(host_controls, 9003)
	p.client_os._bind(client_controls, 9003)
	host_controls.knob.set_value(0.2)
	host_controls.slider.set_value(0.8)
	host_controls.return_slider.set_value(0.7)
	host_controls.lever.set_value(0.35)
	p.host_os._flush_hinge_updates()
	_ok(await _until(func() -> bool:
		return absf(client_controls.knob.get_value() - 0.2) < 0.001 \
			and absf(client_controls.slider.value - 0.8) < 0.001 \
			and absf(client_controls.return_slider.value - 0.7) < 0.001 \
			and absf(client_controls.lever.get_value() - 0.35) < 0.001),
		"hinges/knobs, sliders, spring-return sliders and levers replicate")
	_ok(is_equal_approx(client_controls.knob_effect, 0.2)
		and is_equal_approx(client_controls.slider_effect, 0.8)
		and is_equal_approx(client_controls.return_slider_effect, 0.7)
		and is_equal_approx(client_controls.lever_effect, 0.35),
		"hinges/replicated controls drive their connected device effects")

	# Power switches are the exception: their physical position is replicated,
	# but EV_SYS_POWER owns the semantic toggle. Prove applying the position does
	# not toggle a console a second time before the power event arrives.
	var power_host := MockPowerHost.new()
	var console_model := RetroSystemModel.new()
	power_host.add_child(console_model)
	NetworkManager._object_sync._applying = true
	console_model._on_power_slider_changed(1.0)
	NetworkManager._object_sync._applying = false
	_eq(power_host.toggles, 0,
		"hinges/a replicated power-slider pose does not double-toggle its platform")
	console_model._on_power_slider_changed(1.0)
	_eq(power_host.toggles, 1,
		"hinges/a local power-slider move still performs its semantic action")
	power_host.free()
	client_controls.return_slider.return_speed = 1.0
	client_controls.return_slider._process(0.1)
	_ok(client_controls.return_slider.value < 0.7,
		"hinges/a replicated spring-return slider resumes returning home")
	client_controls.return_slider.return_speed = 0.0

	# Spring-loaded hinges need mechanism state as well as an angle. Otherwise
	# an open-looking remote lid remains latched and cannot be grabbed, or an
	# unlatched closed-looking lid springs open on the next frame.
	host_controls.spring.open()
	host_controls.spring.set_rotation_deg_remote(55.0)
	p.host_os._flush_hinge_updates()
	_ok(await _until(func() -> bool:
		return not client_controls.spring.is_latched_closed() \
			and absf(client_controls.spring.get_rotation_deg() - 55.0) < 0.05),
		"hinges/a spring hinge replicates its unlatched state and angle")
	client_controls.spring.spring_speed_deg = 100.0
	client_controls.spring._process(0.1)
	_ok(client_controls.spring.get_rotation_deg() > 55.0,
		"hinges/the replicated unlatched lid continues springing open")
	client_controls.spring.spring_speed_deg = 0.0
	host_controls.spring.latch_closed()
	p.host_os._flush_hinge_updates()
	_ok(await _until(func() -> bool:
		return client_controls.spring.is_latched_closed() \
			and absf(client_controls.spring.get_rotation_deg()) < 0.05),
		"hinges/a spring hinge replicates the closed latch")
	_ok(not client_controls.spring._can_engage(),
		"hinges/the replicated closed latch is mechanically locked")
	host_controls.push_spring.open()
	host_controls.push_spring.set_rotation_deg_remote(42.0)
	p.host_os._flush_hinge_updates()
	_ok(await _until(func() -> bool:
		return not client_controls.push_spring.is_latched_closed() \
			and absf(client_controls.push_spring.get_rotation_deg() - 42.0) < 0.05),
		"hinges/a push-push spring hinge replicates its released travel")
	host_controls.push_spring.latch_closed()
	p.host_os._flush_hinge_updates()
	_ok(await _until(func() -> bool:
		return client_controls.push_spring.is_latched_closed()),
		"hinges/a push-push spring hinge replicates its latch")
	_ok(client_controls.push_spring._can_engage(),
		"hinges/a replicated push-push latch remains mechanically releasable")

	var persistence := ScenePersistence.new()
	var records := persistence._serialize_articulated_controls(host_controls)
	client_controls.knob.set_value_no_signal(0.9)
	client_controls.slider.set_value_no_signal(0.1)
	client_controls.return_slider.set_value_no_signal(0.1)
	client_controls.lever.set_value_no_signal(0.9)
	client_controls.spring.set_state_remote(40.0, false)
	persistence._restore_articulated_controls(client_controls, records)
	_num(client_controls.knob.get_value(), host_controls.knob.get_value(),
		"hinges/a snapshot restores knob state")
	_num(client_controls.slider.value, host_controls.slider.value,
		"hinges/a snapshot restores slider state")
	_num(client_controls.return_slider.value, host_controls.return_slider.value,
		"hinges/a snapshot restores spring-return slider state")
	_num(client_controls.lever.get_value(), host_controls.lever.get_value(),
		"hinges/a snapshot restores lever state")
	_ok(client_controls.spring.is_latched_closed(),
		"hinges/a snapshot restores spring-latch state")
	_ok(client_controls.push_spring.is_latched_closed()
		and client_controls.push_spring._can_engage(),
		"hinges/a snapshot restores push-push latch mechanics")
	_ok(records.all(func(rec: Dictionary) -> bool:
		return str(rec.get("path", "")) != "Button"),
		"hinges/momentary buttons are excluded; their semantic events are synced")


func _test_events(p: Pair) -> void:
	var host_obj := MockEventObject.new()
	var client_obj := MockEventObject.new()
	var host_aux := MockEventObject.new()
	var client_aux := MockEventObject.new()
	host_obj.sync = p.host_os
	client_obj.sync = p.client_os
	p.host_root.add_child(host_obj)
	p.client_root.add_child(client_obj)
	p.host_root.add_child(host_aux)
	p.client_root.add_child(client_aux)
	p.host_os._bind(host_obj, 9002)
	p.client_os._bind(client_obj, 9002)
	p.host_os._bind(host_aux, 9004)
	p.client_os._bind(client_aux, 9004)

	# Platform front-panel controls: client intent executes on the host, while
	# the host's resulting power state is what clients display.
	p.client_os.report_event(NetObjectSync.EV_SYS_POWER, {"sys": client_obj})
	_ok(await _until(func() -> bool: return host_obj.power_toggles == 1),
		"events/a client's platform power button executes on the host")
	p.host_os.report_event(NetObjectSync.EV_SYS_POWER_STATE,
		{"sys": host_obj, "on": true})
	_ok(await _until(func() -> bool: return client_obj.remote_power),
		"events/the platform's resulting power state reaches the client")
	p.client_os.report_event(NetObjectSync.EV_SYS_RESET, {"sys": client_obj})
	_ok(await _until(func() -> bool: return host_obj.resets == 1),
		"events/a client's platform reset button executes on the host")

	# Every TV bezel/remote effect is explicit. Button depression itself remains
	# local; power, sound, picture mode, source and tuning are shared state.
	p.host_os.report_event(NetObjectSync.EV_TV_POWER, {"tv": host_obj})
	_ok(await _until(func() -> bool: return client_obj.tv_power_toggles == 1),
		"events/TV power reaches the remote set")
	p.host_os.report_event(NetObjectSync.EV_TV_VOL_UP, {"tv": host_obj})
	_ok(await _until(func() -> bool: return client_obj.volume > 0.5),
		"events/TV volume-up changes the remote volume")
	p.host_os.report_event(NetObjectSync.EV_TV_VOL_DOWN, {"tv": host_obj})
	_ok(await _until(func() -> bool: return is_equal_approx(client_obj.volume, 0.5)),
		"events/TV volume-down changes the remote volume")
	p.host_os.report_event(NetObjectSync.EV_TV_MUTE, {"tv": host_obj})
	_ok(await _until(func() -> bool: return client_obj.muted),
		"events/TV mute changes the remote audio gate")
	p.host_os.report_event(NetObjectSync.EV_TV_CRT, {"tv": host_obj, "on": true})
	p.host_os.report_event(NetObjectSync.EV_TV_STEREO, {"tv": host_obj, "mode": 2})
	p.host_os.report_event(NetObjectSync.EV_TV_AUDIO_MODE, {"tv": host_obj, "mode": 1})
	p.host_os.report_event(NetObjectSync.EV_TV_ASPECT, {"tv": host_obj, "on": true})
	p.host_os.report_event(NetObjectSync.EV_TV_SOURCE, {"tv": host_obj, "source": 5})
	p.host_os.report_event(NetObjectSync.EV_TV_CHANNEL,
		{"tv": host_obj, "source": 1, "rf": 4, "index": 2})
	p.host_os.report_event(NetObjectSync.EV_TV_SIZE, {"tv": host_obj, "scale": 1.35})
	_ok(await _until(func() -> bool:
		return client_obj.crt and client_obj.stereo_mode == 2 \
			and client_obj.audio_mode == 1 and client_obj.widescreen \
			and client_obj.source == 1 and client_obj.rf_channel == 4 \
			and client_obj.channel_index == 2 \
			and is_equal_approx(client_obj.scale_factor, 1.35)),
		"events/TV CRT, stereo, audio, ratio, source, channel and size take effect")

	p.host_os.report_event(NetObjectSync.EV_SYS_VIDEO_OUT,
		{"sys": host_obj, "on": false})
	p.host_os.report_event(NetObjectSync.EV_SYS_GRAVITY,
		{"sys": host_obj, "on": true})
	_ok(await _until(func() -> bool:
		return not client_obj.video_out and client_obj.floating),
		"events/platform video-output and gravity toggles take effect")
	p.host_os.report_event(NetObjectSync.EV_ROOM_LIGHTS,
		{"switch": host_obj, "on": false})
	p.host_os.report_event(NetObjectSync.EV_PULL_LIGHT,
		{"cord": host_obj, "on": false})
	p.host_os.report_event(NetObjectSync.EV_BLINDS,
		{"blinds": host_obj, "drop": 0.25})
	p.host_os.report_event(NetObjectSync.EV_TIME_OF_DAY,
		{"clock": host_obj, "time": 0.9})
	_ok(await _until(func() -> bool:
		return not client_obj.room_lights and not client_obj.pull_lit \
			and is_equal_approx(client_obj.blinds_drop, 0.25) \
			and is_equal_approx(client_obj.day_time, 0.9)),
		"events/wall lights, pull lamps, blinds and time-of-day take effect")

	p.host_os.report_event(NetObjectSync.EV_TRAY, {"sys": host_obj, "open": true})
	_ok(await _until(func() -> bool: return client_obj.tray_open),
		"events/a host tray state reaches the client")
	_ok(client_obj.applying_seen,
		"events/remote state runs under echo suppression")
	p.client_os.report_event(NetObjectSync.EV_BOOK_PAGE,
		{"book": client_obj, "state": 2, "leaf": 7})
	_ok(await _until(func() -> bool: return host_obj.pages == [[2, 7]]),
		"events/a client event is applied authoritatively on the host")
	_ok(host_obj.applying_seen, "events/client intent is also echo-suppressed on apply")
	p.host_os.report_event(NetObjectSync.EV_BOOK_SIZE,
		{"book": host_obj, "scale": 1.6})
	p.host_os.report_event(NetObjectSync.EV_BOOK_HALF,
		{"book": host_obj, "on": true})
	_ok(await _until(func() -> bool:
		return is_equal_approx(client_obj.size_scale, 1.6) and client_obj.half_page_mode),
		"events/book size and half-page controls take effect")

	# Insert/eject and cable/port button effects use matching registered objects
	# on each peer, never the originating peer's Node pointer.
	p.host_os.report_event(NetObjectSync.EV_CART_INSERT,
		{"sys": host_obj, "cart": host_aux})
	p.host_os.report_event(NetObjectSync.EV_TAPE_INSERT,
		{"vcr": host_obj, "tape": host_aux})
	p.host_os.report_event(NetObjectSync.EV_MEMCARD_INSERT,
		{"sys": host_obj, "card": host_aux})
	p.host_os.report_event(NetObjectSync.EV_DVD_INSERT,
		{"dvd": host_obj, "disc": host_aux})
	p.host_os.report_event(NetObjectSync.EV_AUDIO_INSERT,
		{"player": host_obj, "media": host_aux})
	_ok(await _until(func() -> bool:
		return client_obj.restored.get("cart") == client_aux \
			and client_obj.restored.get("tape") == client_aux \
			and client_obj.restored.get("card") == client_aux \
			and client_obj.restored.get("disc") == client_aux \
			and client_obj.restored.get("media") == client_aux),
		"events/cartridge, tape, memory-card, DVD and audio insertion take effect")
	p.host_os.report_event(NetObjectSync.EV_CART_REMOVE, {"sys": host_obj})
	p.host_os.report_event(NetObjectSync.EV_TAPE_REMOVE, {"vcr": host_obj})
	p.host_os.report_event(NetObjectSync.EV_MEMCARD_REMOVE, {"sys": host_obj})
	p.host_os.report_event(NetObjectSync.EV_DVD_REMOVE, {"dvd": host_obj})
	p.host_os.report_event(NetObjectSync.EV_AUDIO_REMOVE, {"player": host_obj})
	_ok(await _until(func() -> bool:
		return (client_obj.get_node("CartridgeSlot") as MockSlot).drops == 1 \
			and (client_obj.get_node("TapeSlot") as MockSlot).drops == 1 \
			and (client_obj.get_node("MemoryCardSlot") as MockSlot).drops == 1 \
			and (client_obj.get_node("DiscSlot") as MockSlot).drops == 1 \
			and (client_obj.get_node("MediaSlot") as MockSlot).drops == 1),
		"events/all media eject/remove buttons take effect")

	# An event missing a node it cannot be applied without is refused at the
	# SENDER, where the caller still exists to be blamed. Before EV_NODE_KEYS it
	# went out, failed every peer's _valid() guard, and told nobody.
	var refused_before: int = p.host_os.events_refused
	p.host_os.report_event(NetObjectSync.EV_CART_REMOVE, {})
	p.host_os.report_event(NetObjectSync.EV_TAPE_REMOVE, {"vcr": null})
	# The far side would drop these anyway, so watching the client proves
	# nothing — what is asserted is that the SENDER refused them.
	_eq(p.host_os.events_refused - refused_before, 2,
		"events/an event missing a required node is refused at the sender")
	await _until(func() -> bool:
		return (client_obj.get_node("CartridgeSlot") as MockSlot).drops > 1, 30)
	_ok((client_obj.get_node("CartridgeSlot") as MockSlot).drops == 1,
		"events/and never reaches the far side")

	p.host_os.report_event(NetObjectSync.EV_TV_PLUG,
		{"owner": host_obj, "tv": host_aux})
	p.host_os.report_event(NetObjectSync.EV_TV_UNPLUG,
		{"tv": host_obj, "in": 3})
	p.host_os.report_event(NetObjectSync.EV_RCA_PLUG,
		{"cable": host_obj, "end": 1, "cord": 2, "dev": host_aux, "port": "VideoIn"})
	p.host_os.report_event(NetObjectSync.EV_RCA_UNPLUG,
		{"cable": host_obj, "end": 1, "cord": 2})
	p.host_os.report_event(NetObjectSync.EV_PORT_PLUG,
		{"sys": host_obj, "ctrl": host_aux, "port": 0})
	p.host_os.report_event(NetObjectSync.EV_PORT_UNPLUG,
		{"sys": host_obj, "port": 0})
	_ok(await _until(func() -> bool:
		return client_obj.cable_calls.size() == 2 and client_obj.plug_calls.size() == 2 \
			and client_aux.plug_calls.size() == 1 \
			and (client_obj.get_node("ControllerPort1") as MockSlot).drops == 1),
		"events/TV, RCA and controller cable changes take effect")

	for cmd: String in ["play", "pause", "stop", "ff", "rew"]:
		p.client_os.report_event(NetObjectSync.EV_VCR_CMD,
			{"vcr": client_obj, "cmd": cmd})
	for cmd: String in ["play", "pause", "stop", "menu_up", "menu_down", "menu_left",
			"menu_right", "ok", "root", "next_ch", "prev_ch", "ff", "rew", "audio",
			"subtitle"]:
		p.client_os.report_event(NetObjectSync.EV_DVD_CMD,
			{"dvd": client_aux, "cmd": cmd})
	for cmd: String in ["play", "pause", "stop", "ff", "rew", "next", "prev"]:
		p.client_os.report_event(NetObjectSync.EV_AUDIO_CMD,
			{"player": client_obj, "cmd": cmd})
	_ok(await _until(func() -> bool:
		return host_obj.transport.size() == 12 and host_aux.transport.size() == 15),
		"events/all VCR, DVD and audio transport buttons execute on the host")


func _test_relay(p: Pair) -> void:
	var third_root := _branch("Third")
	var third_nm: Node = third_root.get_node("NetworkManager")
	third_nm.join_game("::1", PORT)
	_ok(await _until(func() -> bool:
		return p.host_nm.peers.size() == 3 and third_nm.peers.size() == 3 \
			and third_nm._object_sync._registry.size() >= 2, 900),
		"relay/a second client joins and receives the world")
	var third_id := _peer_not_in(p.host_nm, [1, p.client_id])
	var third_os: NetObjectSync = third_nm._object_sync

	var host_obj := MockEventObject.new()
	var client_obj := MockEventObject.new()
	var third_obj := MockEventObject.new()
	host_obj.sync = p.host_os
	client_obj.sync = p.client_os
	third_obj.sync = third_os
	p.host_root.add_child(host_obj)
	p.client_root.add_child(client_obj)
	third_root.add_child(third_obj)
	p.host_os._bind(host_obj, 9010)
	p.client_os._bind(client_obj, 9010)
	third_os._bind(third_obj, 9010)
	p.client_os.report_event(NetObjectSync.EV_BOOK_PAGE,
		{"book": client_obj, "state": 3, "leaf": 11})
	_ok(await _until(func() -> bool:
		return host_obj.pages == [[3, 11]] and third_obj.pages == [[3, 11]]),
		"relay/a client event reaches the host and every other client")

	var host_hinge := MockHingeBody.new()
	var client_hinge := MockHingeBody.new()
	var third_hinge := MockHingeBody.new()
	p.host_root.add_child(host_hinge)
	p.client_root.add_child(client_hinge)
	third_root.add_child(third_hinge)
	p.host_os._bind(host_hinge, 9011)
	p.client_os._bind(client_hinge, 9011)
	third_os._bind(third_hinge, 9011)
	client_hinge.hinge.set_rotation_deg_remote(64.0)
	p.client_os._flush_hinge_updates()
	_ok(await _until(func() -> bool:
		return absf(host_hinge.hinge.get_rotation_deg() - 64.0) < 0.05 \
			and absf(third_hinge.hinge.get_rotation_deg() - 64.0) < 0.05),
		"relay/a client hinge reaches the host and every other client")

	# Contention is host-arbitrated: the second client is denied without taking
	# ownership away from the first one.
	var host_card := await _ensure_host_card(p, "CONTENDED", Vector3(0, 1, 2))
	var card_id := p.host_os.id_of(host_card)
	_ok(await _until(func() -> bool:
		return third_os.node_for_id(card_id) is MemoryCard),
		"relay/a newly spawned object reaches both clients")
	var first_card := p.client_os.node_for_id(card_id) as MemoryCard
	var third_card := third_os.node_for_id(card_id) as MemoryCard
	var first_hand := Node3D.new()
	var third_hand := Node3D.new()
	p.client_root.add_child(first_hand)
	third_root.add_child(third_hand)
	p.client_os._on_grabbed(first_card, first_hand)
	await _until(func() -> bool:
		return int(p.host_os._remote_held.get(card_id, -1)) == p.client_id)
	third_os._on_grabbed(third_card, third_hand)
	_ok(await _until(func() -> bool: return not third_os._held_by_me.has(card_id)),
		"relay/a competing client grab is denied")
	_eq(int(p.host_os._remote_held.get(card_id, -1)), p.client_id,
		"relay/the first holder keeps authority")
	p.client_os._on_dropped(first_card)
	await _until(func() -> bool: return not p.host_os._remote_held.has(card_id))

	third_nm.leave_session("relay test complete")
	_ok(await _until(func() -> bool: return not p.host_nm.peers.has(third_id)),
		"relay/the extra peer leaves cleanly")
	third_root.queue_free()
	await _frames(3)


func _test_avatars(p: Pair) -> void:
	# Recreate each other's avatars as VR players; the headless viewport itself is
	# desktop, but pose_source supplies the exact 21-float wire payload.
	p.host_nm.peers[p.client_id]["is_vr"] = true
	p.client_nm.peers[1]["is_vr"] = true
	p.host_nm._remove_avatar(p.client_id)
	p.client_nm._remove_avatar(1)
	p.host_nm._add_avatar(p.client_id, p.host_nm.peers[p.client_id])
	p.client_nm._add_avatar(1, p.client_nm.peers[1])
	var host_pose := _pose(Vector3(1, 2, 3), Vector3(1.1, 1.2, 1.3),
		Vector3(1.4, 1.5, 1.6))
	var client_pose := _pose(Vector3(-1, 2.5, 0.5), Vector3(-1.1, 1.0, 0.2),
		Vector3(-0.8, 1.1, 0.4))
	p.host_nm.pose_source = func() -> PackedFloat32Array: return host_pose
	p.client_nm.pose_source = func() -> PackedFloat32Array: return client_pose
	var host_view := p.host_nm._avatars[p.client_id] as RemoteAvatar
	var client_view := p.client_nm._avatars[1] as RemoteAvatar
	# 1200 ticks, not the default 300, because _until counts FRAMES and this waits
	# on a clock. Poses go out every POSE_INTERVAL (20 Hz) over an
	# unreliable_ordered channel, and the host's own view needs two hops -- the
	# client's report, then the host's next broadcast. Headless frames run about
	# 1-3 ms, so 300 of them is roughly half a second, i.e. ten sends, and a
	# couple of dropped packets on an unreliable channel used up the whole budget.
	# Measured: a successful wait takes 110-330 ms, so this is several times the
	# real settling time rather than a number picked to make red go away.
	_ok(await _until(func() -> bool:
		return host_view._buf.size() > 0 and client_view._buf.size() > 0, 1200),
		"avatars/head and hand pose packets travel in both directions")
	# Wait for the poses to be APPLIED, not for a fixed ten frames. A packet
	# landing in _buf is not the same event as the avatar consuming it, and
	# the guess was occasionally short -- the right hand read (0,0,0) because
	# the assertion ran a frame or two before the pose was drained.
	await _until(func() -> bool:
		var head_ok: bool = host_view.get_node("Head").position.is_equal_approx(
			Vector3(-1, 2.5, 0.5))
		var hand_ok: bool = client_view.get_node("RightHand").position.is_equal_approx(
			Vector3(1.4, 1.5, 1.6))
		return head_ok and hand_ok)
	_vec(host_view.get_node("Head").position, Vector3(-1, 2.5, 0.5),
		"avatars/the host sees the client's head")
	_vec(host_view.get_node("LeftHand").position, Vector3(-1.1, 1.0, 0.2),
		"avatars/the host sees the client's left hand")
	_vec(client_view.get_node("RightHand").position, Vector3(1.4, 1.5, 1.6),
		"avatars/the client sees the host's right hand")
	_ok(host_view.get_node("LeftHand").visible and host_view.get_node("RightHand").visible,
		"avatars/VR peers show both hands")
	var before := host_view._buf.size()
	host_view.push_pose(PackedFloat32Array([1.0, 2.0]))
	_eq(host_view._buf.size(), before, "avatars/a malformed pose is ignored")

	var desktop := AVATAR.instantiate() as RemoteAvatar
	add_child(desktop)
	desktop.setup("Desktop", Color.WHITE, false)
	_ok(not desktop.get_node("LeftHand").visible and not desktop.get_node("RightHand").visible,
		"avatars/desktop peers do not grow phantom hands")
	desktop.queue_free()


func _test_network_lifecycle(p: Pair) -> void:
	var host_card := await _ensure_host_card(p, "HOST_SPAWN",
		Vector3(1.5, 1.0, 0.25))
	var host_id := p.host_os.id_of(host_card)
	var client_card := p.client_os.node_for_id(host_id) as RigidBody3D
	host_card.queue_free()
	_ok(await _until(func() -> bool:
		return p.host_os.node_for_id(host_id) == null \
			and p.client_os.node_for_id(host_id) == null),
		"lifecycle/a host despawn removes every replica")

	var client_owned := await _ensure_client_card(p, "CLIENT_SPAWN",
		Vector3(-1.25, 0.8, 0.5))
	var client_id := p.client_os.id_of(client_owned)
	client_owned.queue_free()
	_ok(await _until(func() -> bool:
		return p.host_os.node_for_id(client_id) == null \
			and p.client_os.node_for_id(client_id) == null),
		"lifecycle/a client despawn is authorized and broadcast by the host")

	# A disconnected client keeps its room, but replicas must become physical
	# again instead of remaining frozen forever. The host also has to release any
	# object that client was holding, or nobody can ever pick it up again.
	var remaining := _find_card(p.client_os, "SNAPSHOT") as RigidBody3D
	var host_remaining := _find_card(p.host_os, "SNAPSHOT") as RigidBody3D
	var remaining_id := p.client_os.id_of(remaining)
	var hand := Node3D.new()
	p.client_root.add_child(hand)
	p.client_os._on_grabbed(remaining, hand)
	await _until(func() -> bool:
		return int(p.host_os._remote_held.get(remaining_id, -1)) == p.client_id)
	p.client_nm.leave_session("lifecycle test")
	await _frames(3)
	_ok(remaining == null or not remaining.freeze,
		"lifecycle/leaving unfreezes ordinary client replicas")
	_ok(not p.host_os._remote_held.has(remaining_id) and not host_remaining.freeze,
		"lifecycle/disconnect releases objects held by the departed peer")
	_ok(await _until(func() -> bool: return not p.host_nm._avatars.has(p.client_id)),
		"lifecycle/a departed player's avatar is removed")


func _branch(branch_name: String) -> Node:
	var root := Node.new()
	root.name = branch_name
	add_child(root)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, root.get_path())
	var nm := NM_SCRIPT.new()
	nm.name = "NetworkManager"
	nm.world_root = root
	nm.pose_source = func() -> PackedFloat32Array: return PackedFloat32Array()
	root.add_child(nm)
	return root


func _card(label: String, pos: Vector3) -> MemoryCard:
	var card := MEMORY_CARD.instantiate() as MemoryCard
	card.name = label
	card.card_id = label.to_lower()
	card.card_label = label
	card.position = pos
	return card


func _find_card(sync: NetObjectSync, label: String) -> MemoryCard:
	for node: Variant in sync._registry.values():
		if node is MemoryCard and (node as MemoryCard).card_label == label:
			return node
	return null


func _find_named(sync: NetObjectSync, node_name: String) -> Node3D:
	for node: Variant in sync._registry.values():
		if node is Node3D and str((node as Node3D).name) == node_name:
			return node
	return null


func _pose(head: Vector3, left: Vector3, right: Vector3) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(21)
	POSE_BROADCASTER._write_pose(out, 0, Transform3D(Basis.IDENTITY, head))
	POSE_BROADCASTER._write_pose(out, 7, Transform3D(Basis.IDENTITY, left))
	POSE_BROADCASTER._write_pose(out, 14, Transform3D(Basis.IDENTITY, right))
	return out


func _ensure_host_card(p: Pair, label: String, pos: Vector3) -> MemoryCard:
	var existing := _find_card(p.host_os, label)
	if existing != null:
		return existing
	var card := _card(label, pos)
	p.host_root.add_child(card)
	card.add_to_group("spawned")
	p.host_nm.on_local_spawn(card)
	var id := p.host_os.id_of(card)
	await _until(func() -> bool: return p.client_os.node_for_id(id) is MemoryCard)
	return card


func _ensure_client_card(p: Pair, label: String, pos: Vector3) -> MemoryCard:
	var existing := _find_card(p.client_os, label)
	if existing != null:
		return existing
	var provisional := _card(label, pos)
	p.client_root.add_child(provisional)
	provisional.add_to_group("spawned")
	var before := p.host_os._registry.size()
	p.client_nm.on_local_spawn(provisional)
	await _until(func() -> bool: return p.host_os._registry.size() == before + 1)
	return _find_card(p.client_os, label)


func _other_id(nm: Node, excluded: int) -> int:
	for id: int in nm.peers:
		if id != excluded:
			return id
	return -1


func _peer_not_in(nm: Node, excluded: Array) -> int:
	for id: int in nm.peers:
		if not excluded.has(id):
			return id
	return -1


func _free_pair(p: Pair) -> void:
	if is_instance_valid(p.client_nm) and p.client_nm.is_active():
		p.client_nm.leave_session("test over")
	if is_instance_valid(p.host_nm) and p.host_nm.is_active():
		p.host_nm.leave_session("test over")
	if is_instance_valid(p.client_root):
		p.client_root.queue_free()
	if is_instance_valid(p.host_root):
		var outside: Variant = p.host_root.get_meta("test_outside", null)
		if is_instance_valid(outside):
			outside.queue_free()
		p.host_root.queue_free()


func _frames(count: int) -> void:
	for _i in range(count):
		await get_tree().process_frame


func _until(condition: Callable, ticks := 300) -> bool:
	for _i in range(ticks):
		await get_tree().process_frame
		if condition.call():
			return true
	return false


func _want(group: String) -> bool:
	return _only.is_empty() or _only == group


## `detail` is printed only on failure, for the cases where knowing HOW far off
## it was is the difference between a real regression and a tolerance to widen.
func _ok(condition: bool, message: String, detail: String = "") -> void:
	_ran += 1
	if condition:
		print("[object-sync] ok   %s" % message)
	else:
		_fail += 1
		print("[object-sync] FAIL %s%s"
			% [message, "  — " + detail if not detail.is_empty() else ""])


func _eq(got: Variant, want: Variant, message: String) -> void:
	_ok(got == want, "%s — got %s, want %s" % [message, str(got), str(want)])


func _num(got: float, want: float, message: String, epsilon := 0.001) -> void:
	_ok(absf(got - want) <= epsilon,
		"%s — got %.4f, want %.4f" % [message, got, want])


func _vec(got: Vector3, want: Vector3, message: String, epsilon := 0.01) -> void:
	_ok(got.distance_to(want) <= epsilon,
		"%s — got %s, want %s" % [message, str(got), str(want)])
