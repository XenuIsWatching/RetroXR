## Headless two-branch probe for the VCR drift sync (M5) + book state sync.
##
## Real NetworkManager/ObjectSync pair over loopback ENet with MOCK VCRs (no
## libVLC/video): verifies that
##   A. a host transport change (send_vcr_state) reaches the client's VCR
##   B. the heartbeat re-broadcasts state while playing (within ~2.5s)
##   C. stop propagates and the heartbeat goes quiet
##   D. echo suppression: the client's apply doesn't re-report events
##   E. book events (EV_BOOK_PAGE/SIZE/HALF) replicate in both directions
##
## Run: godot --headless --path RetroXR res://Tools/av/vcr_sync_probe.tscn
extends Node

const NM_SCRIPT := preload("res://Scripts/Net/network_manager.gd")
const PORT := 42915

var _fail := false


class MockVCR extends Node3D:
	var is_playing := false
	var paused := false
	var pos := 0.0
	var applies: Array = []
	var on_apply: Callable = Callable()   # probe hook, sampled mid-apply
	func net_get_state() -> Dictionary:
		return {"playing": is_playing, "paused": paused, "pos": pos}
	func net_apply_state(playing: bool, p_paused: bool, p_pos: float) -> void:
		applies.append([playing, p_paused, p_pos])
		is_playing = playing
		paused = p_paused
		if playing:
			pos = p_pos
		if on_apply.is_valid():
			on_apply.call()


class MockBook extends Node3D:
	var size_scale := 1.0
	var half_page_mode := false
	var pages: Array = []
	func set_page(state: int, leaf: int) -> void:
		pages.append([state, leaf])


func _fail_if(cond: bool, msg: String) -> void:
	if cond:
		_fail = true
		print("[probe] FAIL: %s" % msg)


func _make_branch(bname: String) -> Node:
	var root := Node.new()
	root.name = bname
	add_child(root)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, root.get_path())
	var nm := NM_SCRIPT.new()
	nm.name = "NetworkManager"
	nm.world_root = root
	nm.pose_source = func() -> PackedFloat32Array: return PackedFloat32Array()
	root.add_child(nm)
	return nm


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[probe] TIMEOUT")
		get_tree().quit(1))
	_run()


func _run() -> void:
	var host_nm := _make_branch("H")
	var client_nm := _make_branch("C")
	host_nm.host_game(PORT)
	client_nm.join_game("127.0.0.1", PORT)
	var connected := false
	for _i in range(300):
		await get_tree().process_frame
		if host_nm.peers.size() == 2 and client_nm.peers.size() == 2:
			connected = true
			break
	if not connected:
		print("[probe] FAIL: handshake did not complete")
		return get_tree().quit(1)

	var h_os: NetObjectSync = host_nm._object_sync
	var c_os: NetObjectSync = client_nm._object_sync
	# Register a mock VCR under the same net_id on both branches.
	var h_vcr := MockVCR.new()
	var c_vcr := MockVCR.new()
	add_child(h_vcr)
	add_child(c_vcr)
	h_vcr.set_meta("net_id", 77)
	c_vcr.set_meta("net_id", 77)
	h_os._registry[77] = h_vcr
	c_os._registry[77] = c_vcr

	# ── A: transport change propagates ────────────────────────────────────────
	h_vcr.is_playing = true
	h_vcr.pos = 12.5
	h_os.send_vcr_state(h_vcr)
	for _i in range(120):
		await get_tree().process_frame
		if not c_vcr.applies.is_empty():
			break
	print("[probe] A: client applies=%d last=%s" % [c_vcr.applies.size(),
		str(c_vcr.applies.back()) if not c_vcr.applies.is_empty() else "none"])
	_fail_if(c_vcr.applies.is_empty(), "state did not reach client")
	if not c_vcr.applies.is_empty():
		var a: Array = c_vcr.applies.back()
		_fail_if(not bool(a[0]) or absf(float(a[2]) - 12.5) > 0.01, "wrong state applied")

	# ── B: heartbeat while playing ────────────────────────────────────────────
	var before: int = c_vcr.applies.size()
	h_vcr.pos = 20.0
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000 and c_vcr.applies.size() == before:
		await get_tree().process_frame
	print("[probe] B: heartbeat applies %d -> %d" % [before, c_vcr.applies.size()])
	_fail_if(c_vcr.applies.size() == before, "no heartbeat within 3s while playing")
	_fail_if(absf(c_vcr.pos - 20.0) > 0.01, "heartbeat position not applied (%f)" % c_vcr.pos)

	# ── C: stop propagates, heartbeat quiet ───────────────────────────────────
	h_vcr.is_playing = false
	h_os.send_vcr_state(h_vcr)
	for _i in range(120):
		await get_tree().process_frame
		if not c_vcr.is_playing:
			break
	_fail_if(c_vcr.is_playing, "stop did not propagate")
	var after_stop: int = c_vcr.applies.size()
	t0 = Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 2600:
		await get_tree().process_frame
	print("[probe] C: stopped, applies during quiet window: %d" % (c_vcr.applies.size() - after_stop))
	_fail_if(c_vcr.applies.size() != after_stop, "heartbeat still firing after stop")

	# ── D: echo suppression during apply ──────────────────────────────────────
	# _vcr_state applies under _applying=true — the guard the transport hooks
	# check (via is_event_applying) so a client's apply can't echo an intent.
	var mid_apply := [false]
	c_vcr.on_apply = func() -> void:
		mid_apply[0] = c_os.is_applying()
	h_vcr.is_playing = true
	h_os.send_vcr_state(h_vcr)
	var before_d: int = c_vcr.applies.size()
	for _i in range(120):
		await get_tree().process_frame
		if c_vcr.applies.size() > before_d:
			break
	print("[probe] D: is_applying mid-apply=%s, outside=%s" % [mid_apply[0], c_os.is_applying()])
	_fail_if(not mid_apply[0], "apply ran without the echo-suppression flag")
	_fail_if(c_os.is_applying(), "is_applying stuck true outside apply")

	# ── E: book state events, both directions ─────────────────────────────────
	var h_book := MockBook.new()
	var c_book := MockBook.new()
	add_child(h_book)
	add_child(c_book)
	h_book.set_meta("net_id", 88)
	c_book.set_meta("net_id", 88)
	h_os._registry[88] = h_book
	c_os._registry[88] = c_book
	# Client turns a page + resizes → host copy follows.
	c_os.report_event(NetObjectSync.EV_BOOK_PAGE, {"book": c_book, "state": 1, "leaf": 3})
	c_os.report_event(NetObjectSync.EV_BOOK_SIZE, {"book": c_book, "scale": 1.5})
	for _i in range(120):
		await get_tree().process_frame
		if not h_book.pages.is_empty() and h_book.size_scale != 1.0:
			break
	print("[probe] E: host book pages=%s scale=%.2f" % [str(h_book.pages), h_book.size_scale])
	_fail_if(h_book.pages != [[1, 3]], "client page turn did not reach host")
	_fail_if(absf(h_book.size_scale - 1.5) > 0.001, "client size change did not reach host")
	# Host toggles half-page → client copy follows.
	h_os.report_event(NetObjectSync.EV_BOOK_HALF, {"book": h_book, "on": true})
	for _i in range(120):
		await get_tree().process_frame
		if c_book.half_page_mode:
			break
	print("[probe] E: client half_page=%s" % c_book.half_page_mode)
	_fail_if(not c_book.half_page_mode, "host half-page toggle did not reach client")

	client_nm.leave_session()
	host_nm.leave_session()
	print("[probe] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)
