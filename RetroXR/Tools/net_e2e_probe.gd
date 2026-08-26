extends Node

## End-to-end probe: two OS processes, a real room code from the live
## rendezvous, a real ENet connection through it, and a real file transfer.
##
## Deliberately NOT a test in Tests/: it needs the network and an external
## service, so it can fail for reasons that have nothing to do with this code.
##
##   --e2e=host --e2e-out=<file>   claim a code, write it, wait for a joiner
##   --e2e=join --e2e-code=<code>  look the code up and connect
##   --e2e-lan [--e2e-port=N]      skip the rendezvous, host/join on loopback
##
## Both roles print [e2e] lines and exit non-zero on failure. Run the host in the
## background, wait for the code file, then run the joiner.
##
## WHY --e2e-lan EXISTS, and what the online path can and cannot prove here.
##
## Hosting online works: a real code is claimed and the room resolves. What
## cannot be tested from ONE MACHINE is the last hop. Both processes leave via
## the same public IP, so the peer punch is a NAT hairpin -- the router will not
## reflect a packet from one inside host back to another via the public mapping
## -- and the joiner reliably gets Result.UNPUNCHABLE:
##
##   status: Looking up RVVF56...
##   status: Connecting to RVVF56...
##   status: Could not reach the other player directly. [...] use LAN mode.
##
## That is the environment, not the code.
##
## Do not over-read it. Two DEVICES behind one router share a public IP too, so
## the same shape is plausible there -- but that is a hypothesis, not something
## anyone has observed: two processes on one host is a stronger constraint than
## two devices, and many consumer routers do implement NAT loopback. Nobody has
## measured the same-house case.
##
## It also does not stand in front of the real gate. A desktop on home wi-fi
## against a Quest on a phone hotspot is two DIFFERENT public IPs, which is
## precisely the case punchthrough exists for; that is the run still owed, and
## it needs two networks.
##
## So --e2e-lan is the mode that actually gates a change: two processes, real
## ENet, roster, chunked transfer, hash verify, everything either side of the
## punch hop.
##
## Re-check the punch server with:
##   curl https://net.retroxr.app/v1/punch                  (200 + endpoint)
##   printf 'register-host\n' | nc punch.retroxr.app 8890   (must reply set-oid)
## A silent socket that accepts and never answers is what a wedged noray looks
## like; it was down that way on 2026-08-25 and a port check would not show it.

var _role := ""
var _out := ""
var _code := ""
var _deadline_s := 90.0
var _lan := false
var _port := 42977

var _log: Array[String] = []


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--e2e-out="):
			_out = a.trim_prefix("--e2e-out=")
		elif a.begins_with("--e2e-code="):
			_code = a.trim_prefix("--e2e-code=")
		elif a == "--e2e-lan":
			_lan = true
		elif a.begins_with("--e2e-port="):
			_port = int(a.trim_prefix("--e2e-port="))
		elif a.begins_with("--e2e="):
			_role = a.trim_prefix("--e2e=")

	NetworkManager.status_changed.connect(func(t: String) -> void:
		_say("status: %s" % t))
	NetworkManager.peer_registered.connect(func(id: int, info: Dictionary) -> void:
		_say("peer joined: %d (%s)" % [id, info.get("name", "?")]))
	NetworkManager.peer_left.connect(func(id: int) -> void:
		_say("peer left: %d" % id))

	get_tree().create_timer(_deadline_s).timeout.connect(func() -> void:
		_fail("timed out after %.0f s" % _deadline_s))

	match _role:
		"host":
			await _run_host()
		"join":
			await _run_join()
		_:
			_fail("no --e2e= role given")


func _run_host() -> void:
	NetworkManager.player_name = "HostProbe"
	var code := ""
	if _lan:
		_say("hosting on LAN port %d..." % _port)
		var lerr := NetworkManager.host_game(_port)
		if lerr != OK:
			_fail("host_game failed: %s" % error_string(lerr))
			return
		code = "LAN:%d" % _port
	else:
		_say("claiming a room code from the rendezvous...")
		var err := await NetworkManager.host_online("E2E Probe Room")
		if err != OK:
			_fail("host_online failed: %s" % error_string(err))
			return
		code = NetworkManager.room_code()
		if code.is_empty():
			_fail("hosting succeeded but no room code came back")
			return
	_say("room code: %s" % code)
	if not _out.is_empty():
		var f := FileAccess.open(_out, FileAccess.WRITE)
		if f == null:
			_fail("cannot write the code to %s" % _out)
			return
		f.store_string(code)
		f.close()

	# Serve a file the joiner can ask for, exercising the real transfer path.
	var served := _make_payload()
	var md5 := NetFileTransfer.hash_of(served)
	NetworkManager._file_transfer.serve_register(md5, served)
	_say("serving payload md5=%s size=%d" % [md5.left(8),
		NetFileTransfer.size_of(served)])
	if not _out.is_empty():
		var mf := FileAccess.open(_out + ".md5", FileAccess.WRITE)
		mf.store_string("%s %d" % [md5, NetFileTransfer.size_of(served)])
		mf.close()

	# What the host can see of its own serving. Until these signals existed the
	# host had no idea a peer was downloading from it at all.
	var seen := {"started": false, "progress": 0, "done": false, "last": 0, "total": 0}
	NetworkManager.serve_started.connect(
		func(peer: int, m: String, kind: String, size: int, fname: String) -> void:
			if m == md5:
				seen["started"] = true
				seen["total"] = size
				_say("serving to peer %d: %s '%s' (%s, %d bytes)" % [peer, m.left(8), fname, kind, size]))
	NetworkManager.serve_progress.connect(
		func(_peer: int, m: String, sent: int, total: int) -> void:
			if m == md5:
				seen["progress"] = int(seen["progress"]) + 1
				seen["last"] = sent
				_say("upload %d / %d" % [sent, total]))
	NetworkManager.serve_done.connect(func(_peer: int, m: String) -> void:
		if m == md5:
			seen["done"] = true
			_say("upload complete"))

	if not await _until(func() -> bool: return NetworkManager.peers.size() >= 2, 75.0):
		_fail("no one joined")
		return
	_say("joiner is connected; roster = %d" % NetworkManager.peers.size())

	# Hold while the joiner pulls the file, then leave.
	if not await _until(func() -> bool: return bool(seen["done"]), 30.0):
		_fail("the host never saw its own upload finish")
		return
	if not bool(seen["started"]):
		_fail("the host never saw the upload start")
		return
	if int(seen["progress"]) < 1:
		_fail("the host saw no upload progress")
		return
	_say("host observed: started -> %d progress -> done (%d / %d bytes)"
		% [int(seen["progress"]), int(seen["last"]), int(seen["total"])])
	await _wait(2.0)
	_say("host done")
	_pass()


func _run_join() -> void:
	NetworkManager.player_name = "JoinProbe"
	if _code.is_empty() and not _lan:
		_fail("no --e2e-code= given")
		return
	var err := OK
	if _lan:
		_say("joining 127.0.0.1:%d on LAN..." % _port)
		err = NetworkManager.join_game("127.0.0.1", _port)
	else:
		_say("joining by code %s..." % _code)
		err = await NetworkManager.join_by_code(_code)
	if err != OK:
		_fail("join failed: %s" % error_string(err))
		return
	if not await _until(func() -> bool: return NetworkManager.peers.size() >= 2, 40.0):
		_fail("connected but the roster never filled")
		return
	_say("connected; roster = %d" % NetworkManager.peers.size())

	# Ask for the host's file by hash -- the same path a book or video takes.
	var want := ""
	var want_size := 0
	var mf := FileAccess.open(_out + ".md5", FileAccess.READ) if not _out.is_empty() else null
	if mf != null:
		var parts := mf.get_as_text().strip_edges().split(" ")
		want = parts[0]
		want_size = int(parts[1]) if parts.size() > 1 else 0
		mf.close()
	if want.is_empty():
		_fail("no payload hash to request")
		return

	var got := {"done": false, "ok": false, "path": "", "progress": 0}
	NetworkManager._file_transfer.transfer_progress.connect(
		func(md5: String, received: int, total: int) -> void:
			if md5 == want:
				got["progress"] = received
				_say("transfer %d / %d" % [received, total]))
	NetworkManager._file_transfer.transfer_done.connect(
		func(md5: String, path: String) -> void:
			if md5 == want:
				got["done"] = true
				got["ok"] = true
				got["path"] = path)
	NetworkManager._file_transfer.transfer_failed.connect(
		func(md5: String, reason: String) -> void:
			if md5 == want:
				got["done"] = true
				_say("transfer failed: %s" % reason))

	_say("requesting %s (%d bytes)" % [want.left(8), want_size])
	NetworkManager._file_transfer.request_file(want, "book", want_size, "pdf")
	if not await _until(func() -> bool: return bool(got["done"]), 40.0):
		_fail("the transfer never finished")
		return
	if not bool(got["ok"]):
		_fail("the transfer failed")
		return

	# The received file must be byte-identical, which is what the hash is for.
	var have := NetFileTransfer.hash_of(str(got["path"]))
	_say("received %s -> md5 %s" % [str(got["path"]).get_file(), have.left(8)])
	if have != want:
		_fail("the received file does not match the host's hash")
		return
	_say("hash matches the host's")
	_pass()


## A payload big enough to take several chunks, so the windowing is exercised
## rather than a single-packet special case.
func _make_payload() -> String:
	var path := ProjectSettings.globalize_path("user://__e2e_payload.pdf")
	var f := FileAccess.open(path, FileAccess.WRITE)
	var block := "RetroXR end-to-end payload block. ".repeat(512)
	for i in range(12):
		f.store_string("%04d %s" % [i, block])
	f.close()
	return path


func _until(cond: Callable, seconds: float) -> bool:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		if cond.call():
			return true
		await get_tree().process_frame
	return false


func _wait(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


func _say(msg: String) -> void:
	_log.append(msg)
	print("[e2e] %s" % msg)


func _pass() -> void:
	print("[e2e] PASS (%s)" % _role)
	NetworkManager.leave_session("probe done")
	get_tree().quit(0)


func _fail(msg: String) -> void:
	print("[e2e] FAIL (%s): %s" % [_role, msg])
	get_tree().quit(1)
