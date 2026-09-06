## Web file server self-tests — the request-parsing and path-confinement half of
## WebFileServer, run headless with no socket, no browser and no client.
##
##     "$godot" --headless --path RetroXR res://Tests/web_server_tests.tscn
##     "$godot" --headless --path RetroXR res://Tests/web_server_tests.tscn -- --only=resolve
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## Why this exists: web_file_server.gd is 816 lines of hand-rolled HTTP — request
## line splitting, multipart upload streaming, a PIN cookie, and a path resolver
## that maps a URL onto the player's real disk — and it had no coverage of any
## kind. The resolver is the part that matters. It is reachable by anything on the
## LAN that has the PIN, and it decides which absolute path a request is allowed
## to read, overwrite or delete, so a mistake there is a security bug rather than
## a cosmetic one. Every `escape/` case below is a path that must NOT resolve.
##
## Nothing here starts the server. `start()` binds a TCP port and spawns a thread;
## a test that did it would be flaky under CI and would prove less than these do,
## because the interesting logic is all reachable directly.
##
## The resolver cases touch no disk at all: it is pure string work against the two
## named roots, and the roots are derived from the statics this asks for
## (server_root(), CoreDownloadManager.default_core_root()) rather than assumed,
## so they hold whatever the player's roots happen to be.
##
## The `upload/` group does write, because staging is the property under test and
## it cannot be observed anywhere but the filesystem. It confines itself to a
## __web_selftest folder under the media root and removes it at both ends.
extends Node

var _pass := 0
var _fail := 0
var _only := ""

var _srv: WebFileServer = null

## The "media" root, as the server itself computes it.
var _media := ""


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		_cleanup()
		get_tree().quit(1))

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			_only = arg.substr(7)

	_srv = WebFileServer.new()
	_media = WebFileServer.server_root()

	if _wants("resolve"):
		_test_resolve_inside_root()
		_test_resolve_rejects_unknown_root()
	if _wants("escape"):
		_test_escape_to_sibling()
		_test_escape_upward()
		_test_escape_encoded()
	if _wants("subpath"):
		_test_safe_subpath()
	if _wants("parse"):
		_test_parse_query()
		_test_cookie()
		_test_extract_pin()
		_test_auth_hardening()
		_test_extract_filename()
		_test_find_bytes()
	if _wants("upload"):
		_test_upload_completes()
		_test_upload_interrupted_keeps_the_original()

	_cleanup()
	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _wants(group: String) -> bool:
	return _only.is_empty() or _only == group


func _cleanup() -> void:
	if is_instance_valid(_srv):
		_srv.free()
		_srv = null


func _ok(cond: bool, name: String, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s" % name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(got: Variant, want: Variant, name: String) -> void:
	_ok(got == want, name, "got %s, want %s" % [str(got), str(want)])


## Asserts a URL path resolves to nothing at all. The failure detail prints what
## it DID resolve to, because "" vs "somewhere outside the root" is the whole
## difference between a confined server and an open one.
func _denied(name: String, rel: String) -> void:
	var got: String = _srv._resolve(rel)
	_ok(got.is_empty(), "escape/" + name, "resolved to %s" % got)


# ── The resolver, inside its roots ────────────────────────────────────────────

func _test_resolve_inside_root() -> void:
	_eq(_srv._resolve(""), "", "resolve/the virtual top level has no single path")
	_eq(_srv._resolve("media"), _media, "resolve/a named root resolves to its base")
	_eq(_srv._resolve("media/roms/nes/game.nes"),
		_media + "/roms/nes/game.nes", "resolve/a file under it keeps the root prefix")
	_eq(_srv._resolve("media/roms/my%20game.nes"),
		_media + "/roms/my game.nes", "resolve/a percent-encoded space decodes")
	# Interior traversal that stays inside is legitimate and must still work --
	# a confinement check that rejects every ".." is too blunt and breaks the UI's
	# own "up one directory" link.
	_eq(_srv._resolve("media/roms/../roms/game.nes"),
		_media + "/roms/game.nes", "resolve/traversal that lands back inside is allowed")
	_ok(not _srv._resolve("libretro").is_empty(), "resolve/the second named root resolves too")


func _test_resolve_rejects_unknown_root() -> void:
	_eq(_srv._resolve("etc/passwd"), "", "resolve/an unknown root is refused")
	_eq(_srv._resolve("secret.txt"), "", "resolve/and so is a bare filename")
	# The root name is matched whole, so a name that merely starts with a real
	# one is not a root.
	_eq(_srv._resolve("mediaevil/x"), "", "resolve/a root name is not a prefix match")


# ── The resolver, under attack ────────────────────────────────────────────────

## The case that was live: a bare begins_with(base) also accepts a SIBLING
## directory whose name starts with the root's, so one ".." out and back into
## "<root>_evil" cleared the guard and served a file from outside the root.
func _test_escape_to_sibling() -> void:
	var sibling := _media.get_file() + "_evil"
	_denied("a sibling sharing the root's name prefix",
		"media/../%s/secret.txt" % sibling)
	_denied("the same escape from deeper in",
		"media/roms/../../%s/secret.txt" % sibling)
	_denied("and with the prefix continuing without a separator",
		"media/../%sX/secret.txt" % _media.get_file())


func _test_escape_upward() -> void:
	_denied("a plain walk out of the root", "media/../../secret.txt")
	_denied("a long walk toward the drive root",
		"media/../../../../../../../../Windows/win.ini")
	_denied("a walk out through a real subdirectory",
		"media/roms/../../../etc/passwd")


func _test_escape_encoded() -> void:
	# _resolve percent-decodes BEFORE splitting, so an encoded separator is
	# exactly as dangerous as a literal one and has to be judged after decoding.
	_denied("percent-encoded separators", "media%2F..%2F..%2Fsecret.txt")
	_denied("an encoded traversal after the root", "media/..%2F..%2Fsecret.txt")


# ── Upload filename sanitising ────────────────────────────────────────────────

## A folder upload carries a relative path in each part's filename, so this is
## the other place a client picks where bytes land.
func _test_safe_subpath() -> void:
	_eq(_srv._safe_subpath("game.nes"), "game.nes", "subpath/a plain name is kept")
	_eq(_srv._safe_subpath("MyGame/save/data.001"),
		"MyGame/save/data.001", "subpath/a folder path is kept")
	_eq(_srv._safe_subpath("MyGame\\save\\data.001"),
		"MyGame/save/data.001", "subpath/backslashes become separators")
	_eq(_srv._safe_subpath("../../etc/passwd"),
		"etc/passwd", "subpath/traversal segments are dropped")
	_eq(_srv._safe_subpath("MyGame/../../../x.nes"),
		"MyGame/x.nes", "subpath/a traversal in the middle is dropped too")
	_eq(_srv._safe_subpath("/etc/passwd"),
		"etc/passwd", "subpath/an absolute posix path loses its root")
	_eq(_srv._safe_subpath("./a/./b"), "a/b", "subpath/single dots are dropped")
	_eq(_srv._safe_subpath("a//b"), "a/b", "subpath/empty segments collapse")
	_eq(_srv._safe_subpath("../.."), "", "subpath/nothing usable gives nothing")
	_eq(_srv._safe_subpath(""), "", "subpath/an empty name gives nothing")


# ── Request parsing ───────────────────────────────────────────────────────────

func _test_parse_query() -> void:
	var q: Dictionary = _srv._parse_query("a=1&b=2")
	_eq(q.get("a", ""), "1", "parse/a query splits into pairs")
	_eq(q.get("b", ""), "2", "parse/and keeps the second")
	var enc: Dictionary = _srv._parse_query("path=roms%2Fmy%20game.nes")
	_eq(enc.get("path", ""), "roms/my game.nes", "parse/values are percent-decoded")
	_eq(_srv._parse_query("").size(), 0, "parse/an empty query is empty")
	# A bare flag has no "=", and the parser skips it rather than storing a null.
	_eq(_srv._parse_query("flag").size(), 0, "parse/a valueless key is skipped")


func _test_cookie() -> void:
	_eq(_srv._cookie("sid=abc123; other=1", "sid"),
		"abc123", "parse/a cookie value is found")
	_eq(_srv._cookie("other=1; sid=abc123", "sid"),
		"abc123", "parse/one later in the header is found too")
	_eq(_srv._cookie("other=1", "sid"),
		"", "parse/a missing cookie is empty")
	_eq(_srv._cookie("", "sid"), "", "parse/an empty header is empty")


## The session token must not be guessable, and the 4-digit PIN must not be
## walkable. 10000 combinations falls to a script in seconds over a LAN.
func _test_auth_hardening() -> void:
	var seen := {}
	for i in 200:
		var tok: String = _srv._gen_token()
		if i == 0:
			_eq(tok.length(), 64, "auth/a token is 32 bytes of hex")
		seen[tok] = true
	_eq(seen.size(), 200, "auth/every token is distinct")

	# randi() is seeded, so a fresh run reproduces its stream. Two independently
	# seeded sequences agreeing would mean the token is derived from one.
	seed(1)
	var first: String = _srv._gen_token()
	seed(1)
	_ok(_srv._gen_token() != first, "auth/tokens do not follow the seeded RNG")

	var who := "10.0.0.5"
	_srv._failures.clear()
	for i in WebFileServer.MAX_PIN_ATTEMPTS - 1:
		_srv._note_failure(who)
	_ok(not _srv._locked_out(who), "auth/a few wrong pins are tolerated")
	_srv._note_failure(who)
	_ok(_srv._locked_out(who), "auth/the attempt limit locks the address out")
	_ok(not _srv._locked_out("10.0.0.6"), "auth/another address is unaffected")
	_srv._failures.clear()


func _test_extract_pin() -> void:
	_eq(_srv._extract_pin("pin=1234"), "1234", "parse/a form pin is read")
	_eq(_srv._extract_pin("x=1&pin=4321&y=2"),
		"4321", "parse/a pin among other fields is read")
	_eq(_srv._extract_pin("x=1"), "", "parse/no pin field gives nothing")


func _test_extract_filename() -> void:
	_eq(_srv._extract_filename('Content-Disposition: form-data; name="f"; filename="game.nes"'),
		"game.nes",
		"parse/a multipart filename is read")
	_eq(_srv._extract_filename('filename="my game.nes"'),
		"my game.nes", "parse/a filename with spaces survives")
	_eq(_srv._extract_filename('Content-Disposition: form-data; name="f"'),
		"", "parse/no filename gives nothing")


func _test_find_bytes() -> void:
	var hay := "abcdefabc".to_utf8_buffer()
	_eq(_srv._find_bytes(hay, "def".to_utf8_buffer()),
		3, "parse/a needle is found at its offset")
	_eq(_srv._find_bytes(hay, "abc".to_utf8_buffer(), 1),
		6, "parse/searching from past it finds the later copy")
	_eq(_srv._find_bytes(hay, "zzz".to_utf8_buffer()),
		-1, "parse/an absent needle is -1")
	# The multipart reader calls this on every incoming chunk, so a needle longer
	# than what has arrived so far is the normal case, not an edge one.
	_eq(_srv._find_bytes("ab".to_utf8_buffer(), "abc".to_utf8_buffer()),
		-1, "parse/a needle longer than the haystack is -1")


# ── Upload staging ────────────────────────────────────────────────────────────
#
# The upload used to open the REAL destination and stream into it, so a dropped
# connection left a truncated file standing where a good one had been — and
# RomLibrary.scan_roms would spawn that as a real cartridge. These drive the
# state machine directly; no socket is involved, and the assertions are about
# what is on disk, not what was sent back.

const UP_DIR := "__web_selftest"
const BOUNDARY := "----RetroXRSelfTest"


func _up_root() -> String:
	return WebFileServer.server_root().path_join(UP_DIR)


## A multipart body carrying one named file, as a browser sends it.
func _multipart(filename: String, payload: String) -> PackedByteArray:
	var text := "--%s\r\nContent-Disposition: form-data; name=\"f\"; filename=\"%s\"\r\n\r\n" \
		% [BOUNDARY, filename]
	var out := text.to_utf8_buffer()
	out.append_array(payload.to_utf8_buffer())
	out.append_array(("\r\n--%s--\r\n" % BOUNDARY).to_utf8_buffer())
	return out


## A connection dict shaped the way _thread_loop builds one. The peer is never
## connected: _send_text writes into a dead socket and is ignored, which is fine
## because every assertion here is about the filesystem.
func _upload_conn() -> Dictionary:
	return {"peer": StreamPeerTCP.new(), "buf": PackedByteArray()}


func _begin_upload(c: Dictionary, filename: String, payload: String) -> PackedByteArray:
	var body := _multipart(filename, payload)
	_srv._start_upload_stream(c, "media/" + UP_DIR, {
		"content-type": "multipart/form-data; boundary=" + BOUNDARY,
		"content-length": str(body.size()),
	}, PackedByteArray())
	return body


func _cleanup_up_dir() -> void:
	var dir := DirAccess.open(_up_root())
	if dir != null:
		for f in dir.get_files():
			DirAccess.remove_absolute(_up_root().path_join(f))
	DirAccess.remove_absolute(_up_root())


func _test_upload_completes() -> void:
	DirAccess.make_dir_recursive_absolute(_up_root())
	var dest := _up_root().path_join("Game.nes")
	var c := _upload_conn()
	var body := _begin_upload(c, "Game.nes", "PAYLOAD-BYTES")
	var done: bool = _srv._feed_upload_stream(c, body)

	_ok(done, "upload/a whole body finishes the stream")
	_ok(FileAccess.file_exists(dest), "upload/the file lands at its destination")
	_eq(FileAccess.get_file_as_string(dest),
		"PAYLOAD-BYTES", "upload/with the bytes that were sent")
	_ok(not FileAccess.file_exists(dest + ".part"), "upload/and no staging file is left behind")
	_cleanup_up_dir()


## The case the fix exists for. Half a body arrives, then the peer drops.
func _test_upload_interrupted_keeps_the_original() -> void:
	DirAccess.make_dir_recursive_absolute(_up_root())
	var dest := _up_root().path_join("Game.nes")
	var keep := "THE-ORIGINAL-ROM"
	var f := FileAccess.open(dest, FileAccess.WRITE)
	f.store_string(keep)
	f.close()

	var c := _upload_conn()
	var body := _begin_upload(c, "Game.nes", "REPLACEMENT-PAYLOAD-THAT-NEVER-ARRIVES")
	# Enough to open the file and start writing, nowhere near the closing boundary.
	var partial := body.slice(0, body.size() - 24)
	var done: bool = _srv._feed_upload_stream(c, partial)
	_ok(not done, "upload/a partial body does not finish the stream")
	_ok((c["us"] as Dictionary).get("f") != null, "upload/it is writing to a staging file")

	# The peer drops: _thread_loop's disconnect branch calls exactly this.
	_srv._discard_part(c["us"] as Dictionary)

	_ok(FileAccess.file_exists(dest),
		"upload/the original file survives an interrupted upload", "dest is gone")
	_eq(FileAccess.get_file_as_string(dest),
		keep, "upload/and still holds its own bytes")
	_ok(not FileAccess.file_exists(dest + ".part"), "upload/the staging file is cleaned up")
	_cleanup_up_dir()
