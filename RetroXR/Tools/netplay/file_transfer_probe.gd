## Headless two-branch probe for NetFileTransfer (M3).
##
## Real NetworkManager pair over loopback ENet:
##   A. 2 MB random "book" transfers host→client, md5-verified, progress monotonic
##   B. kind "rom" is refused by the host (verify-only policy)
##   C. resolve_by_md5 finds the transferred file in the net cache (no re-fetch)
##   D. hash cache: second hash_of call is a cache hit (no rehash)
##
## Run: godot --headless --path RetroXR res://Tools/netplay/file_transfer_probe.tscn
extends Node

const NM_SCRIPT := preload("res://Scripts/Net/network_manager.gd")
const PORT := 42913
const SRC_PATH := "user://net_probe_src.bin"
const SRC_SIZE := 2 * 1024 * 1024

var _fail := false


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
	# Source file: deterministic pseudo-random 2 MB.
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var data := PackedByteArray()
	data.resize(SRC_SIZE)
	for i in range(0, SRC_SIZE, 4):
		data.encode_u32(i, rng.randi())
	var f := FileAccess.open(SRC_PATH, FileAccess.WRITE)
	f.store_buffer(data)
	f.close()
	var src_abs := ProjectSettings.globalize_path(SRC_PATH)
	var md5: String = RomHasher.compute_checksums(src_abs)["md5"]
	print("[probe] source ready md5=%s" % md5)

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

	var host_ft: NetFileTransfer = host_nm._file_transfer
	var client_ft: NetFileTransfer = client_nm._file_transfer
	host_ft.serve_register(md5, SRC_PATH)

	# ── A: transfer a "book" ──────────────────────────────────────────────────
	var progress: Array = []
	var done_path := [""]
	var failed := [""]
	client_ft.transfer_progress.connect(func(_m: String, got: int, _t: int) -> void:
		progress.append(got))
	client_ft.transfer_done.connect(func(_m: String, p: String) -> void:
		done_path[0] = p)
	client_ft.transfer_failed.connect(func(_m: String, r: String) -> void:
		failed[0] = r)
	client_ft.request_file(md5, "book", SRC_SIZE, "bin")
	for _i in range(1200):
		await get_tree().process_frame
		if not done_path[0].is_empty() or not failed[0].is_empty():
			break
	print("[probe] A: done=%s failed=%s progress_events=%d" % [done_path[0], failed[0], progress.size()])
	_fail_if(done_path[0].is_empty(), "book transfer did not complete (%s)" % failed[0])
	if not done_path[0].is_empty():
		var got_md5: String = RomHasher.compute_checksums(
			ProjectSettings.globalize_path(done_path[0]))["md5"]
		_fail_if(got_md5 != md5, "received file md5 mismatch")
		var mono := true
		for i in range(1, progress.size()):
			if progress[i] < progress[i - 1]:
				mono = false
		_fail_if(not mono, "progress not monotonic")
		_fail_if(progress.size() < 5, "too few progress events (%d)" % progress.size())

	# ── B: kind "rom" refused ─────────────────────────────────────────────────
	failed[0] = ""
	client_ft.request_file("00000000000000000000000000000000", "rom", 100, "nes")
	for _i in range(120):
		await get_tree().process_frame
		if not failed[0].is_empty():
			break
	print("[probe] B: rom request -> '%s'" % failed[0])
	_fail_if(not failed[0].contains("not transferable"), "rom request was not refused client-side")

	# ── C: resolve_by_md5 hits the cache copy ─────────────────────────────────
	var resolved := NetFileTransfer.resolve_by_md5(md5, "book", SRC_SIZE, "")
	print("[probe] C: resolved=%s" % resolved)
	_fail_if(resolved.is_empty(), "resolve_by_md5 missed the cached copy")

	# ── D: hash cache hit ─────────────────────────────────────────────────────
	var t0 := Time.get_ticks_usec()
	var h1 := NetFileTransfer.hash_of(SRC_PATH)
	var t1 := Time.get_ticks_usec()
	var h2 := NetFileTransfer.hash_of(SRC_PATH)
	var t2 := Time.get_ticks_usec()
	print("[probe] D: first=%dus second=%dus" % [t1 - t0, t2 - t1])
	_fail_if(h1 != md5 or h2 != md5, "hash_of returned wrong md5")
	_fail_if(t2 - t1 > (t1 - t0) and t2 - t1 > 2000, "second hash_of not a cache hit")

	# Cleanup probe artifacts.
	client_nm.leave_session()
	host_nm.leave_session()
	DirAccess.remove_absolute(SRC_PATH)
	if not done_path[0].is_empty():
		DirAccess.remove_absolute(done_path[0])

	print("[probe] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)
