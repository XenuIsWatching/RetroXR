## WebFileServer — lightweight HTTP file manager.
## Serves the retroxr user data directory (roms + cores) over a local HTTP port.
## Supports directory listing, multi-file and whole-folder upload (drag-and-drop or
## a folder picker — e.g. a ScummVM game folder), and deletion.
class_name WebFileServer
extends Node

const DEFAULT_PORT := 8080

var _tcp := TCPServer.new()
## Each entry: { peer: StreamPeerTCP, buf: PackedByteArray }
## While streaming an upload: also has "us" → upload stream state dict
var _connections: Array = []
var _running := false
var _thread: Thread = null
## Shared progress state read by /api/progress.
var _upload_progress: Dictionary = {}

## 4-digit PIN required to log in. Set by the owner before start(); an empty PIN
## disables authentication (open access) as a safety fallback.
var pin: String = ""
## Live sessions, token -> the Unix time the session stops being accepted.
##
## An EXPIRY rather than a bare true. The Set-Cookie below has always said
## Max-Age=86400, but that is a request to the browser and nothing more: a
## client that keeps sending the cookie is a client the server kept trusting,
## for as long as the app stayed running. The dictionary also only ever grew,
## so every login since launch stayed valid at once.
var _sessions: Dictionary = {}

## How long a login lasts. Must match the Max-Age on the cookie, or the two
## halves of the same promise disagree.
const SESSION_SECONDS := 86400


## Root of the served media filesystem (roms, books, videos, dvds).
static func server_root() -> String:
	return DataPaths.media_root()


## Named roots exposed at the top level of the web UI. "media" is the ROM/book/
## video/dvd tree; "libretro" is the cores + system dir (a separate filesystem on
## Android — internal storage — so it can't be reached by walking into "media").
static func _roots() -> Dictionary:
	return {
		"media": server_root(),
		"libretro": CoreDownloadManager.default_core_root(),
	}


## Best-guess LAN IP address (filters out loopback and IPv6).
static func local_ip() -> String:
	for addr: String in IP.get_local_addresses():
		if ":" in addr:
			continue  # skip IPv6
		if addr.begins_with("192.168.") or addr.begins_with("10.") or addr.begins_with("172."):
			return addr
	return "127.0.0.1"


func start(port: int = DEFAULT_PORT) -> bool:
	if _running:
		return true
	for base: String in _roots().values():
		DirAccess.make_dir_recursive_absolute(base)
	var err := _tcp.listen(port)
	if err != OK:
		push_error("[WebFileServer] listen(%d) failed: %s" % [port, error_string(err)])
		return false
	_running = true
	_thread = Thread.new()
	_thread.start(_thread_loop)
	print("[WebFileServer] Listening on http://%s:%d  root=%s" % [local_ip(), port, server_root()])
	return true


## Joining the thread is teardown, not politeness: _thread_loop reads this node's
## members every iteration, so a thread left running past the node's lifetime
## dereferences a freed script instance — a null _tcp here, a SIGSEGV on Android.
## The spawn menu that owns the server rides inside the scene, so every scene
## change frees it.
func _exit_tree() -> void:
	stop()


func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		stop()


func stop() -> void:
	if not _running and _thread == null:
		return
	_running = false
	if _thread:
		_thread.wait_to_finish()
		_thread = null
	for c: Dictionary in _connections:
		(c["peer"] as StreamPeerTCP).disconnect_from_host()
	_connections.clear()
	_sessions.clear()
	_tcp.stop()
	print("[WebFileServer] Stopped")


func _thread_loop() -> void:
	while _running:
		# Accept new connections.
		while _tcp.is_connection_available():
			var peer := _tcp.take_connection()
			_connections.append({"peer": peer, "buf": PackedByteArray()})

		# Service connections.
		var to_remove: Array = []
		for c: Dictionary in _connections:
			if c.has("us"):
				# Streaming upload — feed incoming bytes directly to the state machine.
				var up_peer := c["peer"] as StreamPeerTCP
				up_peer.poll()
				var up_st := up_peer.get_status()
				if up_st == StreamPeerTCP.STATUS_NONE or up_st == StreamPeerTCP.STATUS_ERROR:
					# Dropped mid-part: bin the stage. Leaving it would strand a
					# half-written .part beside the file it was replacing.
					_discard_part(c["us"] as Dictionary)
					to_remove.append(c)
					continue
				var new_bytes := PackedByteArray()
				var up_avail := up_peer.get_available_bytes()
				if up_avail > 0:
					var result := up_peer.get_data(up_avail)
					if result[0] == OK:
						new_bytes = result[1]
				if _feed_upload_stream(c, new_bytes):
					to_remove.append(c)
				continue

			# Receiving phase — buffer until full (non-upload) request arrives.
			var peer := c["peer"] as StreamPeerTCP
			peer.poll()
			var st := peer.get_status()
			if st == StreamPeerTCP.STATUS_NONE or st == StreamPeerTCP.STATUS_ERROR:
				to_remove.append(c)
				continue
			var avail := peer.get_available_bytes()
			if avail > 0:
				var result := peer.get_data(avail)
				if result[0] == OK:
					var new_buf: PackedByteArray = c["buf"]
					new_buf.append_array(result[1])
					c["buf"] = new_buf
			if _try_handle(c):
				if not c.has("us"):
					to_remove.append(c)

		for c: Dictionary in to_remove:
			(c["peer"] as StreamPeerTCP).disconnect_from_host()
			_connections.erase(c)

		OS.delay_msec(1)


## Returns true when the request is fully received and handled.
func _try_handle(c: Dictionary) -> bool:
	var buf := c["buf"] as PackedByteArray
	var sep := _find_bytes(buf, "\r\n\r\n".to_utf8_buffer())
	if sep == -1:
		return false  # headers incomplete

	var header_text := buf.slice(0, sep).get_string_from_utf8()
	var lines := header_text.split("\r\n")
	if lines.is_empty():
		return true

	var req_parts := lines[0].split(" ")
	if req_parts.size() < 2:
		return true
	var method: String = req_parts[0]
	var raw_path: String = req_parts[1]

	var hdrs: Dictionary = {}
	for i in range(1, lines.size()):
		var colon := lines[i].find(":")
		if colon != -1:
			hdrs[lines[i].substr(0, colon).strip_edges().to_lower()] = \
				lines[i].substr(colon + 1).strip_edges()

	var q_pos := raw_path.find("?")
	var path := raw_path.substr(0, q_pos if q_pos != -1 else raw_path.length())
	var query := _parse_query(raw_path.substr(q_pos + 1) if q_pos != -1 else "")

	# Intercept uploads — start streaming immediately without waiting for full body.
	if method == "POST" and path == "/api/upload":
		if not _is_authed(hdrs):
			_send_text(c["peer"] as StreamPeerTCP, 401, "application/json",
					   '{"error":"unauthorized"}')
			return true
		var upload_body_start := sep + 4
		_start_upload_stream(c, query.get("path", ""), hdrs, buf.slice(upload_body_start))
		return true

	var body_start := sep + 4
	var content_length := int(hdrs.get("content-length", "0"))
	if buf.size() < body_start + content_length:
		return false  # body incomplete

	var body := buf.slice(body_start, body_start + content_length)
	_dispatch(c, method, path, query, hdrs, body)
	return true


func _dispatch(c: Dictionary, method: String, path: String,
			   query: Dictionary, headers: Dictionary, body: PackedByteArray) -> void:
	var peer := c["peer"] as StreamPeerTCP
	var authed := _is_authed(headers)
	if method == "OPTIONS":
		_send_text(peer, 200, "text/plain", "")
	elif method == "POST" and path == "/api/login":
		_handle_login(peer, body)
	elif method == "GET" and path == "/":
		# Serve the file manager when authed, otherwise the PIN login page.
		_send_text(peer, 200, "text/html", _HTML if authed else _LOGIN_HTML)
	elif not authed:
		_send_text(peer, 401, "application/json", '{"error":"unauthorized"}')
	elif method == "GET" and path == "/api/list":
		_handle_list(peer, query.get("path", ""))
	elif method == "GET" and path == "/api/progress":
		_send_text(peer, 200, "application/json", JSON.stringify(_upload_progress))
	elif method == "GET" and path == "/api/download":
		_handle_download(peer, query.get("path", ""))
	elif method == "DELETE" and path == "/api/delete":
		_handle_delete(peer, query.get("path", ""))
	else:
		_send_text(peer, 404, "text/plain", "Not Found")


# ── Authentication ────────────────────────────────────────────────────────────

## True if the request carries a valid session cookie. An empty PIN means auth is
## disabled (open access) — every request is treated as authorised.
func _is_authed(headers: Dictionary) -> bool:
	if pin.is_empty():
		return true
	var token := _cookie(headers.get("cookie", ""), "rvrsession")
	if token.is_empty() or not _sessions.has(token):
		return false
	if Time.get_unix_time_from_system() >= float(_sessions[token]):
		_sessions.erase(token)
		return false
	return true


## Validates the submitted PIN and, on success, issues a session cookie.
func _handle_login(peer: StreamPeerTCP, body: PackedByteArray) -> void:
	var who := _peer_address(peer)
	if _locked_out(who):
		# 429, not 401: the PIN may well be right, and a client that is being
		# rate-limited should be told that rather than shown "bad pin" forever.
		_send_text(peer, 429, "application/json", '{"error":"too many attempts"}')
		return
	var submitted := _extract_pin(body.get_string_from_utf8())
	if pin.is_empty() or submitted != pin:
		_note_failure(who)
		_send_text(peer, 401, "application/json", '{"error":"bad pin"}')
		return
	_failures.erase(who)
	var token := _gen_token()
	_prune_sessions()
	_sessions[token] = Time.get_unix_time_from_system() + SESSION_SECONDS
	var body_bytes := '{"ok":true}'.to_utf8_buffer()
	var hdr := "HTTP/1.1 200 OK\r\nContent-Type: application/json; charset=utf-8\r\nSet-Cookie: rvrsession=%s; Path=/; Max-Age=86400; SameSite=Strict\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" \
			   % [token, body_bytes.size()]
	peer.put_data(hdr.to_utf8_buffer())
	peer.put_data(body_bytes)



# ── PIN throttling ────────────────────────────────────────────────────────────
#
# A 4-digit PIN is 10000 combinations, which a script walks in seconds over a
# LAN. The PIN is short on purpose — it is typed on a phone, from a headset —
# so the throttle is what makes it worth anything.

## How many wrong PINs one address may submit before it is refused.
const MAX_PIN_ATTEMPTS := 8
## How long a locked-out address stays locked out.
const PIN_LOCKOUT_SEC := 60.0

## address -> {"count": int, "until": float}
var _failures: Dictionary = {}


func _peer_address(peer: StreamPeerTCP) -> String:
	var host := peer.get_connected_host()
	return host if not host.is_empty() else "?"


func _locked_out(who: String) -> bool:
	var rec: Dictionary = _failures.get(who, {})
	var until := float(rec.get("until", 0.0))
	if until <= 0.0:
		return false            # counting attempts, not locked out
	if Time.get_ticks_msec() / 1000.0 < until:
		return true
	# The window has passed; forget the address entirely so a slow typist is not
	# punished for a mistake made a minute ago. Only ever cleared here, never on
	# the still-counting path — doing that reset the tally on every check and the
	# limit was never reached.
	_failures.erase(who)
	return false


func _note_failure(who: String) -> void:
	var rec: Dictionary = _failures.get(who, {"count": 0, "until": 0.0})
	rec["count"] = int(rec.get("count", 0)) + 1
	if int(rec["count"]) >= MAX_PIN_ATTEMPTS:
		rec["until"] = Time.get_ticks_msec() / 1000.0 + PIN_LOCKOUT_SEC
		rec["count"] = 0
	_failures[who] = rec

## Pulls the PIN out of a login body (form-encoded `pin=1234` or JSON `{"pin":"1234"}`).
func _extract_pin(body: String) -> String:
	body = body.strip_edges()
	if body.begins_with("{"):
		var json := JSON.new()
		if json.parse(body) == OK and json.data is Dictionary:
			return str((json.data as Dictionary).get("pin", ""))
		return ""
	for pair in body.split("&"):
		var eq := pair.find("=")
		if eq != -1 and pair.substr(0, eq) == "pin":
			return pair.substr(eq + 1).uri_decode()
	return ""


## Reads a single cookie value out of a Cookie header ("a=1; b=2").
func _cookie(header: String, key: String) -> String:
	for part in header.split(";"):
		var kv := part.strip_edges()
		var eq := kv.find("=")
		if eq != -1 and kv.substr(0, eq) == key:
			return kv.substr(eq + 1)
	return ""


## Forget sessions that have run out.
##
## Called when one is issued rather than on a timer: logins are the only thing
## that grows this, so that is the moment the dictionary can get bigger, and it
## keeps the server free of periodic work while nobody is using it. Expiry
## itself is enforced at every request by _is_authed — this only stops the
## dictionary keeping dead tokens for the life of the process.
func _prune_sessions() -> void:
	var now := Time.get_unix_time_from_system()
	for token: String in _sessions.keys():
		if now >= float(_sessions[token]):
			_sessions.erase(token)


## A session token, from the crypto RNG.
##
## randi() is a seeded PRNG: its stream is reproducible, so a token could be
## predicted from others rather than having to be stolen, and mixing in a
## microsecond clock only narrows the search. Crypto has no such property, and
## 32 bytes is past guessing.
func _gen_token() -> String:
	return Crypto.new().generate_random_bytes(32).hex_encode()


# ── API handlers ──────────────────────────────────────────────────────────────

func _handle_list(peer: StreamPeerTCP, rel: String) -> void:
	# Virtual top level: list each named root as a folder.
	if rel.is_empty():
		var names: Array[String] = []
		for k: String in _roots().keys():
			names.append(k)
		names.sort()
		_send_text(peer, 200, "application/json", JSON.stringify({"dirs": names, "files": []}))
		return
	var abs_path := _resolve(rel)
	if abs_path.is_empty():
		_send_text(peer, 403, "application/json", '{"error":"forbidden"}')
		return
	var dir := DirAccess.open(abs_path)
	if not dir:
		_send_text(peer, 404, "application/json", '{"error":"not found"}')
		return

	var dirs: Array[String] = []
	var files: Array = []
	dir.list_dir_begin()
	var entry_name := dir.get_next()
	while entry_name != "":
		if not entry_name.begins_with("."):
			if dir.current_is_dir():
				dirs.append(entry_name)
			else:
				var fa := FileAccess.open(abs_path.path_join(entry_name), FileAccess.READ)
				var size := fa.get_length() if fa else 0
				files.append({"name": entry_name, "size": size})
		entry_name = dir.get_next()
	dir.list_dir_end()

	dirs.sort()
	files.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["name"] < b["name"])
	_send_text(peer, 200, "application/json", JSON.stringify({"dirs": dirs, "files": files}))


## Starts a streaming multipart upload. Called as soon as HTTP headers arrive,
## before the body has been fully received.
func _start_upload_stream(c: Dictionary, rel: String, headers: Dictionary,
						   body_so_far: PackedByteArray) -> void:
	var peer := c["peer"] as StreamPeerTCP
	var abs_path := _resolve(rel)
	if abs_path.is_empty():
		_send_text(peer, 403, "application/json", '{"error":"forbidden"}')
		return
	var ct: String = headers.get("content-type", "")
	var b_idx := ct.find("boundary=")
	if b_idx == -1:
		_send_text(peer, 400, "application/json", '{"error":"no boundary"}')
		return
	var boundary := ct.substr(b_idx + 9).strip_edges()
	if boundary.begins_with('"'):
		boundary = boundary.trim_prefix('"').trim_suffix('"')
	c["us"] = {
		"phase":     "part_preamble",
		"dest_dir":  abs_path,
		"delim":     ("--" + boundary).to_utf8_buffer(),
		"data_term": ("\r\n--" + boundary).to_utf8_buffer(),
		"buf":       body_so_far.duplicate(),
		"f":         null,
		"filename":  "",
		"written":   0,
		"total":     int(headers.get("content-length", "0")),
		"saved":     0,
	}


## Append to the staged part, reporting a write that did not land.
##
## store_buffer returns nothing, so a full disk is only visible through
## get_error() -- without this the server answered 200 OK over a file that was
## silently short. A failure abandons the stage rather than promoting it.
func _write_part(us: Dictionary, chunk: PackedByteArray) -> bool:
	var f := us["f"] as FileAccess
	f.store_buffer(chunk)
	if f.get_error() != OK:
		push_error("[WebFileServer] Write failed for %s (%d) -- discarding"
			% [us.get("filename", ""), f.get_error()])
		_discard_part(us)
		return false
	us["written"] = (us["written"] as int) + chunk.size()
	_upload_progress["written"] = us["written"]
	return true


## Close and delete the staging file, leaving whatever was already at dest alone.
func _discard_part(us: Dictionary) -> void:
	if us.get("f") != null:
		(us["f"] as FileAccess).close()
		us["f"] = null
	var part := str(us.get("part", ""))
	if not part.is_empty() and FileAccess.file_exists(part):
		DirAccess.remove_absolute(part)
	us["part"] = ""


## Move the finished stage over the real destination.
func _promote_part(us: Dictionary) -> bool:
	(us["f"] as FileAccess).close()
	us["f"] = null
	var part := str(us.get("part", ""))
	var dest := str(us.get("dest", ""))
	if FileAccess.file_exists(dest) and DirAccess.remove_absolute(dest) != OK:
		push_error("[WebFileServer] Cannot replace %s" % dest)
		DirAccess.remove_absolute(part)
		return false
	if DirAccess.rename_absolute(part, dest) != OK:
		push_error("[WebFileServer] Cannot promote %s" % part)
		DirAccess.remove_absolute(part)
		return false
	return true


## State-machine step for streaming uploads. Appends new_data to the upload buffer
## and writes file bytes to disk as they arrive, keeping only a tiny lookahead buffer.
## Returns true when the upload is complete (HTTP response already sent).
func _feed_upload_stream(c: Dictionary, new_data: PackedByteArray) -> bool:
	var us: Dictionary = c["us"]
	if new_data.size() > 0:
		var b: PackedByteArray = us["buf"]
		b.append_array(new_data)
		us["buf"] = b

	while true:
		var phase: String = us["phase"]

		if phase == "part_preamble":
			var delim: PackedByteArray = us["delim"]
			var buf: PackedByteArray   = us["buf"]
			var pos := _find_bytes(buf, delim)
			if pos == -1:
				break
			var after := pos + delim.size()
			if after + 1 >= buf.size():
				break  # need 2 more bytes to classify
			if buf[after] == 45 and buf[after + 1] == 45:
				# "--boundary--" with no parts.
				_send_text(c["peer"] as StreamPeerTCP, 200, "application/json",
						   '{"saved":%d}' % us["saved"])
				return true
			# Skip CRLF after delimiter.
			if buf[after] == 13 and buf[after + 1] == 10:
				after += 2
			us["buf"]   = buf.slice(after)
			us["phase"] = "part_headers"

		elif phase == "part_headers":
			var buf: PackedByteArray = us["buf"]
			var hdr_end := _find_bytes(buf, "\r\n\r\n".to_utf8_buffer())
			if hdr_end == -1:
				break
			var hdr_text := buf.slice(0, hdr_end).get_string_from_utf8()
			us["buf"] = buf.slice(hdr_end + 4)
			var filename := _extract_filename(hdr_text)
			# Folder uploads transmit a relative path (e.g. "MyGame/save/data.001");
			# preserve it instead of flattening so the directory tree is recreated.
			var sub := _safe_subpath(filename)
			if sub.is_empty():
				us["phase"] = "part_preamble"
				continue
			var dest_dir: String = us["dest_dir"]
			var dest: String = dest_dir.path_join(sub)
			# Defence in depth — _safe_subpath already strips "..", but never write
			# outside the destination root even if that ever changes.
			if not dest.simplify_path().begins_with(dest_dir + "/"):
				push_error("[WebFileServer] Rejected escaping upload path: %s" % filename)
				us["phase"] = "part_preamble"
				continue
			var parent := dest.get_base_dir()
			if parent != dest_dir:
				DirAccess.make_dir_recursive_absolute(parent)
			# Staged, never written straight to dest. An upload that stops early --
			# a closed tab, a dropped link, a full disk -- would otherwise leave a
			# truncated file standing where a good one was, and RomLibrary.scan_roms
			# would spawn it as a real cartridge. Promoted on the closing boundary,
			# deleted on any failure. Same rule the ROM downloader and the state
			# writer already follow.
			var part := dest + ".part"
			var f := FileAccess.open(part, FileAccess.WRITE)
			if not f:
				push_error("[WebFileServer] Cannot open %s for writing (%d)"
					% [part, FileAccess.get_open_error()])
				us["phase"] = "part_preamble"
				continue
			us["f"]        = f
			us["part"]     = part
			us["dest"]     = dest
			us["filename"] = sub
			us["written"]  = 0
			us["phase"]    = "data"
			_upload_progress = {"filename": us["filename"], "written": 0, "total": us["total"]}
			print("[WebFileServer] Streaming write: %s" % dest)

		elif phase == "data":
			var buf: PackedByteArray  = us["buf"]
			var term: PackedByteArray = us["data_term"]
			var term_pos := _find_bytes(buf, term)
			if term_pos != -1:
				var after_term := term_pos + term.size()
				if after_term + 1 >= buf.size():
					# Write up to the possible terminator and wait for 2 more bytes.
					if term_pos > 0 and not _write_part(us, buf.slice(0, term_pos)):
						_send_text(c["peer"] as StreamPeerTCP, 507, "application/json",
							'{"error":"write failed"}')
						return true
					us["buf"] = buf.slice(term_pos)
					break
				# Write data before the terminator, then close file.
				if term_pos > 0 and not _write_part(us, buf.slice(0, term_pos)):
					_send_text(c["peer"] as StreamPeerTCP, 507, "application/json",
						'{"error":"write failed"}')
					return true
				if not _promote_part(us):
					_send_text(c["peer"] as StreamPeerTCP, 500, "application/json",
						'{"error":"could not save"}')
					return true
				us["saved"] = (us["saved"] as int) + 1
				print("[WebFileServer] Saved: %s" % us["filename"])
				if buf[after_term] == 45 and buf[after_term + 1] == 45:
					# Final boundary "--" → done.
					_send_text(c["peer"] as StreamPeerTCP, 200, "application/json",
							   '{"saved":%d}' % us["saved"])
					return true
				# More parts → skip CRLF, read next part headers.
				if buf[after_term] == 13 and buf[after_term + 1] == 10:
					after_term += 2
				us["buf"]   = buf.slice(after_term)
				us["phase"] = "part_headers"
			else:
				# Terminator not found yet. Flush all bytes that can't be part of it.
				var safe := buf.size() - (term.size() - 1)
				if safe > 0:
					if not _write_part(us, buf.slice(0, safe)):
						_send_text(c["peer"] as StreamPeerTCP, 507, "application/json",
							'{"error":"write failed"}')
						return true
					us["buf"] = buf.slice(safe)
				break

		else:
			break

	return false


func _handle_download(peer: StreamPeerTCP, rel: String) -> void:
	var abs_path := _resolve(rel)
	if abs_path.is_empty() or _is_root_base(abs_path):
		_send_text(peer, 403, "application/json", '{"error":"forbidden"}')
		return
	var f := FileAccess.open(abs_path, FileAccess.READ)
	if not f:
		_send_text(peer, 404, "text/plain", "Not Found")
		return
	var data := f.get_buffer(f.get_length())
	f.close()
	var filename := abs_path.get_file()
	var hdr := "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"%s\"\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" \
			   % [filename, data.size()]
	peer.put_data(hdr.to_utf8_buffer())
	peer.put_data(data)


func _handle_delete(peer: StreamPeerTCP, rel: String) -> void:
	var abs_path := _resolve(rel)
	if abs_path.is_empty() or _is_root_base(abs_path):
		_send_text(peer, 403, "application/json", '{"error":"forbidden"}')
		return
	var err := DirAccess.remove_absolute(abs_path)
	if err == OK:
		_send_text(peer, 200, "application/json", '{"ok":true}')
	else:
		_send_text(peer, 500, "application/json",
				   '{"error":"delete failed","code":%d}' % err)


# ── Helpers ───────────────────────────────────────────────────────────────────

## Maps a URL path ("<root>/sub/dir") to an absolute path, confined to that named
## root. Returns "" for the virtual top level (no single root) or on a bad/escaping
## path. Callers that must reject the top level check `is_empty()`.
func _resolve(rel: String) -> String:
	if rel.is_empty():
		return ""  # virtual root has no single filesystem path
	var decoded := rel.uri_decode()
	var slash := decoded.find("/")
	var root_name := decoded.substr(0, slash) if slash != -1 else decoded
	var remainder := decoded.substr(slash + 1) if slash != -1 else ""
	var roots := _roots()
	if not roots.has(root_name):
		return ""
	var base: String = roots[root_name]
	if remainder.is_empty():
		return base
	var abs_path := (base + "/" + remainder).simplify_path()
	# The separator is load-bearing. A bare begins_with(base) also accepts a
	# SIBLING whose name merely starts with the root's — "…/retroxr/../retroxr_evil
	# /secret" simplifies to "…/retroxr_evil/secret", which passed the old check
	# and served a file from outside the root to any PIN-authed client on the LAN.
	# Comparing against base + "/" confines it, and the equality keeps the root
	# directory itself resolvable.
	if abs_path == base or abs_path.begins_with(base + "/"):
		return abs_path
	return ""


## True if `abs_path` is one of the named-root base directories (never deletable/downloadable).
func _is_root_base(abs_path: String) -> bool:
	for base: String in _roots().values():
		if abs_path == base:
			return true
	return false


func _parse_query(s: String) -> Dictionary:
	var d: Dictionary = {}
	for pair in s.split("&"):
		var eq := pair.find("=")
		if eq != -1:
			d[pair.substr(0, eq).uri_decode()] = pair.substr(eq + 1).uri_decode()
	return d



## Sanitises a multipart filename — which for a folder upload carries a relative
## path ("MyGame/save/data.001") — into a safe path relative to the destination
## dir. Backslashes become "/", and empty / "." / ".." segments are dropped so the
## result can never escape the destination or reference an absolute location.
## Returns "" when nothing usable remains.
func _safe_subpath(rel_name: String) -> String:
	var out: Array[String] = []
	for seg in rel_name.replace("\\", "/").split("/"):
		var s := seg.strip_edges()
		if s.is_empty() or s == "." or s == "..":
			continue
		out.append(s)
	return "/".join(out)


func _extract_filename(part_headers: String) -> String:
	var idx := part_headers.find("filename=")
	if idx == -1:
		return ""
	var rest := part_headers.substr(idx + 9)
	if rest.begins_with('"'):
		var quote_end := rest.find('"', 1)
		return rest.substr(1, quote_end - 1) if quote_end != -1 else ""
	var end := rest.find("\r")
	if end == -1:
		end = rest.find("\n")
	return rest.substr(0, end if end != -1 else rest.length())


func _find_bytes(haystack: PackedByteArray, needle: PackedByteArray, from: int = 0) -> int:
	var hs := haystack.size()
	var ns := needle.size()
	if ns == 0 or hs < ns:
		return -1
	for i in range(from, hs - ns + 1):
		var ok := true
		for j in range(ns):
			if haystack[i + j] != needle[j]:
				ok = false
				break
		if ok:
			return i
	return -1


func _send_text(peer: StreamPeerTCP, code: int, content_type: String, body: String) -> void:
	var body_bytes := body.to_utf8_buffer()
	var status_map := {
		200: "OK", 201: "Created", 400: "Bad Request", 401: "Unauthorized",
		403: "Forbidden", 404: "Not Found", 500: "Internal Server Error"
	}
	var status: String = status_map.get(code, "Unknown")
	var hdr := "HTTP/1.1 %d %s\r\nContent-Type: %s; charset=utf-8\r\nContent-Length: %d\r\nConnection: close\r\n\r\n" \
			   % [code, status, content_type, body_bytes.size()]
	peer.put_data(hdr.to_utf8_buffer())
	peer.put_data(body_bytes)


# ── Embedded HTML UI ──────────────────────────────────────────────────────────

const _LOGIN_HTML := """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>RetroXR Files — Sign in</title><style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:monospace;background:#111;color:#ccc;min-height:100vh;
     display:flex;align-items:center;justify-content:center;padding:16px}
.card{background:#181820;border:1px solid #222;border-radius:10px;padding:28px;width:280px;text-align:center}
h1{color:#8af;font-size:20px;margin-bottom:6px}
p{color:#666;font-size:13px;margin-bottom:18px}
input{width:100%;font-family:monospace;font-size:28px;text-align:center;letter-spacing:12px;
      background:#111;color:#8af;border:1px solid #333;border-radius:6px;padding:10px 0;margin-bottom:14px}
input:focus{outline:none;border-color:#8af}
button{width:100%;border:none;padding:11px;border-radius:6px;cursor:pointer;font-size:15px;
       background:#245;color:#8cf}
button:hover{background:#367}
#er{color:#f88;font-size:13px;min-height:18px;margin-top:10px}
</style></head><body>
<form class="card" id="f">
<h1>RetroXR Files</h1>
<p>Enter the 4-digit PIN shown in the headset options.</p>
<input id="pin" type="tel" inputmode="numeric" pattern="[0-9]*" maxlength="4" autocomplete="off" placeholder="••••" autofocus>
<button type="submit">Sign in</button>
<div id="er"></div>
</form>
<script>
var f=document.getElementById('f'),pin=document.getElementById('pin'),er=document.getElementById('er');
pin.addEventListener('input',function(){pin.value=pin.value.replace(/[^0-9]/g,'').slice(0,4);er.textContent='';});
f.addEventListener('submit',function(e){
  e.preventDefault();
  if(pin.value.length!=4){er.textContent='Enter 4 digits.';return;}
  fetch('/api/login',{method:'POST',headers:{'Content-Type':'application/json'},
    body:JSON.stringify({pin:pin.value})}).then(function(r){
    if(r.ok){location.reload();}
	else{er.textContent='Incorrect PIN.';pin.value='';pin.focus();}
  }).catch(function(){er.textContent='Connection error.';});
});
</script></body></html>"""

const _HTML := """<!DOCTYPE html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>RetroXR Files</title><style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:monospace;background:#111;color:#ccc;padding:16px}
h1{color:#8af;margin-bottom:12px;font-size:20px}
#bc{margin-bottom:14px;font-size:14px}
#bc a{color:#8af;cursor:pointer;text-decoration:none}
#bc a:hover{text-decoration:underline}
.sep{color:#444;margin:0 4px}
#dz{border:2px dashed #444;border-radius:8px;padding:18px;margin-bottom:10px;
    color:#666;text-align:center;font-size:14px;transition:border-color .15s,color .15s}
#dz.over{border-color:#8af;color:#8af}
.pk{color:#8cf;cursor:pointer;text-decoration:underline}
.pk:hover{color:#adf}
#st{min-height:18px;font-size:13px;color:#8f8;margin-bottom:10px}
table{width:100%;border-collapse:collapse}
tr{border-bottom:1px solid #1c1c1c}
tr:hover{background:#161626}
td{padding:9px 6px;font-size:14px;vertical-align:middle}
.ic{width:24px}
.nm{word-break:break-all}
.dn{color:#8af;cursor:pointer}
.dn:hover{text-decoration:underline}
.sz{color:#555;text-align:right;width:80px;white-space:nowrap}
.ac{text-align:right;width:84px;white-space:nowrap}
button{border:none;padding:3px 8px;border-radius:3px;cursor:pointer;font-size:13px}
.dl{background:#050;color:#8f8}
.dl:hover{background:#070}
.rm{background:#500;color:#f88}
.rm:hover{background:#800}
</style></head><body>
<h1>RetroXR Files</h1>
<div id="bc"></div>
<div id="dz">Drop files or a folder here &nbsp;·&nbsp;
<label class="pk">choose files<input type="file" id="pf_files" multiple hidden></label> &nbsp;·&nbsp;
<label class="pk">choose folder<input type="file" id="pf_dir" webkitdirectory hidden></label></div>
<div id="st"></div>
<div id="pb" style="display:none;height:8px;background:#222;border-radius:4px;margin-bottom:10px;overflow:hidden"><div id="pf" style="height:100%;width:0%;background:#8af;border-radius:4px;transition:width .15s"></div></div>
<table><tbody id="tb"></tbody></table>
<script>
var cur='';
function fmt(b){
  if(b<1024)return b+' B';
  if(b<1048576)return (b/1024).toFixed(1)+' KB';
  if(b<1073741824)return (b/1048576).toFixed(1)+' MB';
  return (b/1073741824).toFixed(2)+' GB';
}
function esc(s){var d=document.createElement('div');d.textContent=s;return d.innerHTML;}
function parent_of(p){var i=p.lastIndexOf('/');return i>0?p.substring(0,i):'';}
function go(p,push){
  cur=p;
  if(push===false)history.replaceState({path:p},'',location.pathname);
  else history.pushState({path:p},'',location.pathname);
  var bc=document.getElementById('bc');
  var parts=p?p.split('/').filter(Boolean):[];
  var h='<a data-nav="">root</a>';
  var acc='';
  parts.forEach(function(s){acc+='/'+s;h+='<span class="sep">/</span><a data-nav="'+acc+'">'+esc(s)+'</a>';});
  bc.innerHTML=h;
  fetch('/api/list?path='+encodeURIComponent(p)).then(function(r){
    if(r.status==401){location.reload();return null;}
    return r.json();
  }).then(function(d){if(d)draw(d);});
}
// The Back button should step up the file-nav path visited, not leave the
// page — replay the path the browser stored instead of pushing a new entry.
window.addEventListener('popstate',function(e){go(e.state?e.state.path:'',false);});
function draw(d){
  var tb=document.getElementById('tb');
  var h='';
  if(cur){h+='<tr><td class="ic">📁</td><td class="nm dn" data-nav="'+esc(parent_of(cur))+'">..</td><td class="sz"></td><td class="ac"></td></tr>';}
  (d.dirs||[]).forEach(function(n){
	var cp=cur?cur+'/'+n:n;
	h+='<tr><td class="ic">📁</td><td class="nm dn" data-nav="'+esc(cp)+'">'+esc(n)+'</td><td class="sz">—</td><td class="ac"></td></tr>';
  });
  (d.files||[]).forEach(function(f){
	var fp=cur?cur+'/'+f.name:f.name;
	h+='<tr><td class="ic">📄</td><td class="nm">'+esc(f.name)+'</td><td class="sz">'+fmt(f.size)+'</td><td class="ac"><button class="dl" data-dl="'+esc(fp)+'">↓</button> <button class="rm" data-del="'+esc(fp)+'">✕</button></td></tr>';
  });
  if(!h)h='<tr><td colspan="4" style="color:#333;padding:20px;text-align:center">Empty</td></tr>';
  tb.innerHTML=h;
}
document.addEventListener('click',function(e){
  if(e.target.hasAttribute('data-nav'))go(e.target.getAttribute('data-nav'));
  if(e.target.hasAttribute('data-dl')){
	window.location='/api/download?path='+encodeURIComponent(e.target.getAttribute('data-dl'));
  }
  if(e.target.hasAttribute('data-del')){
	var p=e.target.getAttribute('data-del');
	if(confirm('Delete '+p.split('/').pop()+'?'))
	  fetch('/api/delete?path='+encodeURIComponent(p),{method:'DELETE'}).then(function(){go(cur,false);});
  }
});
var dz=document.getElementById('dz');
var st=document.getElementById('st');
var pb=document.getElementById('pb');
var pf=document.getElementById('pf');
// Upload a list of {file,path} items sequentially, sending each item's relative
// path as the multipart filename so folder structure is recreated on the server.
function uploadItems(items){
  var i=0;
  function next(){
	if(i>=items.length){
	  st.textContent='Done \u2014 uploaded '+items.length+' file(s).';
	  pb.style.display='none';pf.style.width='0%';go(cur,false);return;
	}
	var it=items[i],nm=it.path||it.file.name;
	st.textContent='Uploading '+(i+1)+' of '+items.length+': '+nm;
	pb.style.display='block';pf.style.width='0%';
	var fd=new FormData();
	fd.append('file',it.file,it.path||it.file.name);
	var xhr=new XMLHttpRequest();
	xhr.upload.onprogress=function(ev){
	  if(ev.lengthComputable){
		var pct=Math.round(ev.loaded/ev.total*100);
		pf.style.width=pct+'%';
		st.textContent='Uploading '+(i+1)+' of '+items.length+': '+nm+' ('+pct+'%)';
	  }
	};
	xhr.onload=function(){pf.style.width='100%';i++;next();};
	xhr.onerror=function(){st.textContent='Error uploading '+nm;i++;next();};
	xhr.open('POST','/api/upload?path='+encodeURIComponent(cur));
	xhr.send(fd);
  }
  if(items.length)next();else st.textContent='Nothing to upload.';
}
// A <input type=file> selection (plain files, or a webkitdirectory folder whose
// files carry webkitRelativePath) \u2192 {file,path} items.
function itemsFromInput(inp){
  var out=[],fs=inp.files;
  for(var k=0;k<fs.length;k++)out.push({file:fs[k],path:fs[k].webkitRelativePath||fs[k].name});
  return out;
}
document.getElementById('pf_files').addEventListener('change',function(e){uploadItems(itemsFromInput(e.target));e.target.value='';});
document.getElementById('pf_dir').addEventListener('change',function(e){uploadItems(itemsFromInput(e.target));e.target.value='';});
// Recursively walk a dropped FileSystemEntry, collecting {file,path} into out.
function walkEntry(entry,prefix,out){
  return new Promise(function(resolve){
	if(entry.isFile){
	  entry.file(function(f){out.push({file:f,path:prefix+entry.name});resolve();},function(){resolve();});
	}else if(entry.isDirectory){
	  var reader=entry.createReader(),kids=[];
	  (function read(){
		reader.readEntries(function(ents){
		  if(!ents.length){
			Promise.all(kids.map(function(c){return walkEntry(c,prefix+entry.name+'/',out);})).then(resolve);
			return;
		  }
		  kids=kids.concat(Array.prototype.slice.call(ents));
		  read();
		},function(){resolve();});
	  })();
	}else{resolve();}
  });
}
dz.addEventListener('dragover',function(e){e.preventDefault();dz.classList.add('over');});
dz.addEventListener('dragleave',function(){dz.classList.remove('over');});
dz.addEventListener('drop',function(e){
  e.preventDefault();dz.classList.remove('over');
  var dt=e.dataTransfer,its=dt.items;
  // Prefer the entry API so a dropped folder keeps its structure. getAsEntry must
  // be called synchronously here \u2014 the item list is invalidated after this handler.
  if(its&&its.length&&its[0].webkitGetAsEntry){
	var entries=[];
	for(var k=0;k<its.length;k++){var en=its[k].webkitGetAsEntry();if(en)entries.push(en);}
	if(entries.length){
	  var out=[];
	  st.textContent='Reading folder\u2026';
	  Promise.all(entries.map(function(en){return walkEntry(en,'',out);})).then(function(){uploadItems(out);});
	  return;
	}
  }
  // Fallback: flat file list (older browsers / plain file drops).
  var files=dt.files,out=[];
  for(var k=0;k<files.length;k++)out.push({file:files[k],path:files[k].webkitRelativePath||files[k].name});
  uploadItems(out);
});
go('',false);
</script></body></html>"""
