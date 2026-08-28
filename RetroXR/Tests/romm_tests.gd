## RomM self-tests — the pure-logic half of the RomM stack, run headless with no
## server, no headset and no network.
##
## This project has no test framework and does not want one; what it has is
## probe scenes. This is a probe that asserts instead of printing, and it is the
## one probe worth keeping in the tree: every case below is a bug that actually
## shipped, so the file doubles as the regression record.
##
##     "$godot" --headless --path RetroXR res://Tests/romm_tests.tscn
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## What is NOT covered, and why: anything that needs a live RomM server
## (sync paging, the delta watermark, download resume) and anything welded to
## the menu's Control tree (_rebuild_romm_rows, which is the merge this most
## wants to test — it reads a dozen view members and cannot be called without a
## built view). Extracting that merge into a pure function is the next step.
extends Node

const TEST_SYSTEM := "__romm_selftest"

var _pass := 0
var _fail := 0
## The player's romm_sync.json as it was before this run touched it.
var _ledger_before := ""


func _ready() -> void:
	# A probe must never hang a headless run. The HTTP cases each cap their own
	# wait as well, because this timer is a SceneTree timer: it only fires while
	# the main loop is running, and a blocking call made ON the main thread would
	# stop the very clock meant to catch it.
	get_tree().create_timer(240.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))

	# Several cases stand up their own RommSaveSync and call save_state() on it,
	# which writes the PLAYER'S real romm_sync.json from that instance's empty
	# tables -- so a run left the ledger holding this file's __resolve_selftest
	# entries and nothing else.
	#
	# That ledger is where a hash-resolved rom id lives, and rom_id_for now falls
	# back to it, so losing it loses the attribution for every game the gamelist
	# cannot answer for. Measured: a run wiped two resolved GameCube ids.
	#
	# Snapshotted whole and put back at the end, the same way the arcade manifest
	# already is.
	_ledger_before = FileAccess.get_file_as_string(RommSaveSync.state_path()) 		if FileAccess.file_exists(RommSaveSync.state_path()) else ""

	_test_pair_url()
	_test_systemid_for()
	_test_partition()
	_test_collapse_by_systemid()
	_test_firmware_index()
	_test_stats_unchanged()
	_test_scopes()
	_test_verify_transfer()
	_test_error_vocabulary()
	_test_cache_paths()
	_test_scan_roms()
	_test_gamelist_removal()
	_test_media_and_cleanup()
	_test_cleanup_gate()
	_test_cleanup_core_dirs()
	_test_bios_folder_rule()
	_test_cleanup_folder_as_file()
	_test_gamelist_bad_paths()
	_test_core_uninstall()
	_test_backup_switch()
	_test_state_schema()
	await _test_state_upload_body()
	await _test_save_upload_still_works()
	await _test_state_overwrite_and_delete()
	_test_state_server_only()
	_test_state_restore()
	await _test_rom_id_resolve()
	_test_gamelist_one_entry_per_rom()
	_test_gamelist_dedupe()
	_test_ghost_rows()
	_test_index_rewrite()
	await _test_http_stalls()

	_restore_ledger()

	print("[test] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


## Put the player's sync ledger back byte for byte, including deleting one this
## run created where there was none.
func _restore_ledger() -> void:
	var path := RommSaveSync.state_path()
	if _ledger_before.is_empty():
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[romm_tests] cannot restore %s" % path)
		return
	f.store_string(_ledger_before)
	f.close()


func _ok(name: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("[test] PASS  %s" % name)
	else:
		_fail += 1
		print("[test] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


## Indexing an array that came out shorter than expected is a hard error, which
## aborts the rest of the case function — so one broken assumption takes its
## neighbours' results with it and the run reports fewer cases, not failures.
func _at(arr: Array, i: int) -> Dictionary:
	return arr[i] as Dictionary if i >= 0 and i < arr.size() else {}


# ---------------------------------------------------------------------------
# RommPairUrl — the QR payload parser.
# ---------------------------------------------------------------------------

func _test_pair_url() -> void:
	var scheme := RommPairUrl.parse("http://192.168.0.106:8080/pair?code=MXWT-SDZE")
	_eq("pair/scheme url", scheme["url"], "http://192.168.0.106:8080")
	_eq("pair/scheme code", scheme["code"], "MXWT-SDZE")

	# The QR frequently omits the scheme; both forms must land identically.
	var bare := RommPairUrl.parse("192.168.0.106:8080/pair?code=MXWT-SDZE")
	_eq("pair/schemeless url", bare["url"], "http://192.168.0.106:8080")
	_eq("pair/schemeless code", bare["code"], "MXWT-SDZE")

	# A bare code pairs against the configured server.
	var only := RommPairUrl.parse("MXWT-SDZE")
	_eq("pair/bare code url", only["url"], "")
	_eq("pair/bare code code", only["code"], "MXWT-SDZE")

	# Shaped like a URL but carrying no host: treating this as a bare code would
	# pair against whatever server happened to be configured and hide the
	# malformed QR behind an unrelated failure.
	var hostless := RommPairUrl.parse("/pair?code=MXWT-SDZE")
	_eq("pair/hostless rejected", hostless["code"], "")

	_eq("pair/not a romm qr", RommPairUrl.parse("https://example.com/hello")["code"], "")
	_eq("pair/empty", RommPairUrl.parse("")["code"], "")
	_eq("pair/whitespace only", RommPairUrl.parse("   ")["code"], "")

	# Percent-encoding must decode, and decoding must not smuggle in a code the
	# pattern would have rejected.
	_eq("pair/uri decoded", RommPairUrl.parse("http://h:8080/pair?code=AB%2DCD")["code"], "AB-CD")
	_eq("pair/decode cannot widen",
		RommPairUrl.parse("http://h:8080/pair?code=AB%2FCD")["code"], "")

	# Fragments and extra query params.
	_eq("pair/extra query", RommPairUrl.parse("http://h:8080/pair?x=1&code=ABCD")["code"], "ABCD")

	var over := "A".repeat(RommPairUrl.MAX_CODE_LEN + 1)
	_eq("pair/over-long code", RommPairUrl.parse("http://h:8080/pair?code=" + over)["code"], "")


# ---------------------------------------------------------------------------
# RommPlatforms — slug mapping.
# ---------------------------------------------------------------------------

func _test_systemid_for() -> void:
	_eq("slug/plain n64",
		RommPlatforms.systemid_for({"slug": "n64", "fs_slug": "n64"}), "nintendo_64")

	# The one that shipped wrong: 64DD is its own system, not N64.
	_eq("slug/64dd is not n64",
		RommPlatforms.systemid_for({"slug": "64dd", "fs_slug": "n64dd"}), "nintendo_64dd")

	# fs_slug beats slug — it is the folder the user named themselves.
	_eq("slug/fs_slug wins",
		RommPlatforms.systemid_for({"slug": "unknown-thing", "fs_slug": "snes"}), "super_nes")

	# An explicit override beats both, by either key.
	_eq("slug/override by slug",
		RommPlatforms.systemid_for({"slug": "weird", "fs_slug": "alsoweird"}, {"weird": "nes"}),
		"nes")

	_eq("slug/unmappable", RommPlatforms.systemid_for({"slug": "nonesuch", "fs_slug": "nope"}), "")

	# JSON nulls arrive from RomM for absent fields; str(null) must not map.
	_eq("slug/null fields", RommPlatforms.systemid_for({"slug": null, "fs_slug": null}), "")


func _test_partition() -> void:
	var part := RommPlatforms.partition([
		{"slug": "nes", "fs_slug": "nes", "rom_count": 12},
		{"slug": "nonesuch", "fs_slug": "nope", "rom_count": 5},
		{"slug": "snes", "fs_slug": "snes", "rom_count": 0},      # empty, dropped
		{"slug": "gb", "fs_slug": "gb", "rom_count": null},        # null, dropped
	])
	_eq("partition/mapped", part["mapped"].size(), 1)
	_eq("partition/unmapped", part["unmapped"].size(), 1)
	_eq("partition/systemid stamped", str((part["mapped"][0] as Dictionary)["systemid"]), "nes")


func _test_collapse_by_systemid() -> void:
	# snes/sfc/sgb all map to super_nes. Before the fix the dict build kept
	# whichever came last, so the winner depended on the server's array order.
	var a := {"slug": "snes", "systemid": "super_nes", "rom_count": 3512}
	var b := {"slug": "sgb", "systemid": "super_nes", "rom_count": 42}

	var forward := RommPlatforms.collapse_by_systemid([a, b])
	var reverse := RommPlatforms.collapse_by_systemid([b, a])

	_eq("collapse/one tile per systemid", (forward["platforms"] as Dictionary).size(), 1)
	_eq("collapse/biggest wins",
		str(((forward["platforms"] as Dictionary)["super_nes"] as Dictionary)["slug"]), "snes")
	_eq("collapse/order independent",
		str(((reverse["platforms"] as Dictionary)["super_nes"] as Dictionary)["slug"]), "snes")

	# The loser is reported, not dropped on the floor.
	_eq("collapse/loser reported", (forward["shadowed"] as Array).size(), 1)
	_eq("collapse/loser identity",
		str(((forward["shadowed"] as Array)[0] as Dictionary)["slug"]), "sgb")
	_eq("collapse/loser reported either order", (reverse["shadowed"] as Array).size(), 1)

	# Distinct systemids never contend.
	var many := RommPlatforms.collapse_by_systemid([
		{"slug": "nes", "systemid": "nes", "rom_count": 1},
		{"slug": "gb", "systemid": "game_boy", "rom_count": 1},
	])
	_eq("collapse/distinct kept", (many["platforms"] as Dictionary).size(), 2)
	_eq("collapse/no false shadow", (many["shadowed"] as Array).size(), 0)


# ---------------------------------------------------------------------------
# RommFirmware — the two indexes over the server's firmware list.
#
# The PS2 BIOS shipped invisible: both PS2 cores declare a FOLDER ("pcsx2/bios")
# rather than a filename, so the by-name join had nothing to match and 68 files
# sitting on the server were never offered. The platform index is the fix, and
# `file_path` — which the indexer used to discard — is the only key it has.
# ---------------------------------------------------------------------------

func _test_firmware_index() -> void:
	_eq("fw/slug from path", RommFirmware.platform_slug_from_path("bios/ps2"), "ps2")
	_eq("fw/slug trailing slash", RommFirmware.platform_slug_from_path("bios/ps2/"), "ps2")
	_eq("fw/slug backslashes", RommFirmware.platform_slug_from_path("bios\\ps2"), "ps2")
	_eq("fw/slug cased", RommFirmware.platform_slug_from_path("bios/PS2"), "ps2")
	# A bare name is not a folder. Reading one as a slug would file every loose
	# firmware under whatever platform its filename happened to resemble.
	_eq("fw/slug needs a folder", RommFirmware.platform_slug_from_path("ps2"), "")
	_eq("fw/slug empty", RommFirmware.platform_slug_from_path(""), "")

	var fw := RommFirmware.new()
	fw.config = RommConfig.new()
	# _index and _loaded are reached into directly: the only public route to them
	# is refresh(), which needs a server.
	fw._index([
		{"id": 7, "file_name": "ps2-0120a-20000902.bin", "file_path": "bios/ps2",
			"file_size_bytes": 4194304, "md5_hash": "8DB2FBBAC7413BF3E7154C1E0715E565"},
		{"id": 3, "file_name": "ps2-0100j-20000117.bin", "file_path": "bios/ps2",
			"file_size_bytes": 4194304, "md5_hash": "acf4730ceb38ac9d8c7d8e21f2614600"},
		{"id": 9, "file_name": "scph5500.bin", "file_path": "bios/psx",
			"file_size_bytes": 524288, "md5_hash": ""},
		# On the server's books but not on its disk — offering it would 404.
		{"id": 11, "file_name": "ps2-0101j-20000217.bin", "file_path": "bios/ps2",
			"file_size_bytes": 4194304, "missing_from_fs": true},
		# An unmappable folder must not become its own bucket keyed on "".
		{"id": 12, "file_name": "mystery.rom", "file_path": "bios/nonesuch",
			"file_size_bytes": 1024},
	])
	fw._loaded = true

	var ps2: Array = fw.find_for_system("playstation2")
	_eq("fw/platform index size", ps2.size(), 2)
	_eq("fw/name sorted", str(_at(ps2, 0).get("file_name", "")), "ps2-0100j-20000117.bin")
	_eq("fw/other platform", fw.find_for_system("playstation").size(), 1)
	_eq("fw/unmapped is not a bucket", fw.find_for_system("").size(), 0)
	_eq("fw/no such system", fw.find_for_system("gamecube").size(), 0)

	# The by-name index still works, and now carries the system with it.
	var hit := fw.find("scph5500.bin")
	_eq("fw/by name id", int(hit.get("id", 0)), 9)
	_eq("fw/by name stamps systemid", str(hit.get("systemid", "")), "playstation")
	# Declared nested and stored flat, cased differently — the shipped case.
	_eq("fw/by name is basename+caseless",
		int(fw.find("Machines/PS2-0120A-20000902.BIN").get("id", 0)), 7)

	# md5 is compared against FileAccess.get_md5, which is lowercase.
	_eq("fw/md5 lowercased", str(_at(ps2, 1).get("md5", "")),
		"8db2fbbac7413bf3e7154c1e0715e565")

	# A missing file is absent from BOTH indexes, not just the one it was
	# filtered out of.
	_eq("fw/missing from fs excluded by name",
		fw.find("ps2-0101j-20000217.bin").is_empty(), true)

	# Re-listing replaces; a server that lost a file must not keep serving it out
	# of a stale platform bucket.
	fw._index([
		{"id": 3, "file_name": "ps2-0100j-20000117.bin", "file_path": "bios/ps2",
			"file_size_bytes": 4194304},
	])
	_eq("fw/reindex replaces", fw.find_for_system("playstation2").size(), 1)
	_eq("fw/reindex clears other platforms", fw.find_for_system("playstation").size(), 0)

	fw.free()


# ---------------------------------------------------------------------------
# RommConfig — the "did the library move?" fingerprint.
# ---------------------------------------------------------------------------

func _test_stats_unchanged() -> void:
	var cfg := RommConfig.new()
	var stats := {"ROMS": 171148, "PLATFORMS": 54, "TOTAL_FILESIZE_BYTES": 13522092343348}

	# No baseline means "assume it moved" — never skip the first sync.
	cfg.last_stats = {}
	_ok("stats/no baseline is changed", not cfg.stats_unchanged(stats))

	cfg.last_stats = stats.duplicate()
	_ok("stats/identical is unchanged", cfg.stats_unchanged(stats))

	# An empty reading is not evidence of sameness.
	_ok("stats/empty reading is changed", not cfg.stats_unchanged({}))

	for key: String in ["ROMS", "PLATFORMS", "TOTAL_FILESIZE_BYTES"]:
		var moved := stats.duplicate()
		moved[key] = int(moved[key]) + 1
		_ok("stats/%s move is seen" % key, not cfg.stats_unchanged(moved))


# ---------------------------------------------------------------------------
# Scopes — what the server says these credentials may do.
#
# The shipped bug: scopes were never read back at all, and a token RetroXR
# minted itself asked for three read scopes, so save/state upload could not
# work however the server was configured. Reported as being stuck unable to
# upload saves after widening the scopes server-side.
#
# The asymmetry below is the whole design: UNKNOWN must permit, because a token
# without me.read cannot answer the question and uploads fine today.
# ---------------------------------------------------------------------------

func _test_scopes() -> void:
	var cfg := RommConfig.new()

	_ok("scopes/unknown at rest", not cfg.knows_scopes())
	_ok("scopes/unknown may upload", cfg.can_upload())

	cfg.set_scopes(PackedStringArray(["roms.read", "platforms.read"]))
	_ok("scopes/known once answered", cfg.knows_scopes())
	_ok("scopes/read-only cannot upload", not cfg.can_upload())
	_ok("scopes/has_scope reads the list", cfg.has_scope("roms.read") and not cfg.has_scope("assets.write"))
	_ok("scopes/answer is stamped", not cfg.scopes_checked_at.is_empty())

	cfg.set_scopes(PackedStringArray(["roms.read", "assets.write"]))
	_ok("scopes/write grant permits upload", cfg.can_upload())

	# Clearing goes back to unknown, not to "denied" — this is what a changed
	# token leaves behind, and it must not stop a working device uploading.
	cfg.set_scopes(PackedStringArray())
	_ok("scopes/cleared is unknown", not cfg.knows_scopes() and cfg.can_upload())
	_ok("scopes/cleared drops the stamp", cfg.scopes_checked_at.is_empty())

	# The mint list must actually cover what the app does, or the token it
	# creates repeats the shipped bug.
	_ok("scopes/mint asks for upload", RommClient.WANTED_SCOPES.has(RommClient.SCOPE_UPLOAD))
	_ok("scopes/mint asks for me.read", RommClient.WANTED_SCOPES.has("me.read"))

	# Round trip through the file, since this is persisted state now.
	var cfg2 := RommConfig.new()
	cfg2.set_scopes(PackedStringArray(["assets.write", "me.read"]))
	var json: Dictionary = JSON.parse_string(JSON.stringify({
		"scopes": cfg2.scopes, "scopes_checked_at": cfg2.scopes_checked_at,
	}))
	var cfg3 := RommConfig.new()
	cfg3.set_scopes(PackedStringArray(json["scopes"]))
	_ok("scopes/survive a JSON round trip", cfg3.can_upload() and cfg3.knows_scopes())


# ---------------------------------------------------------------------------
# RommDownloader.verify_transfer — is what landed on disk the whole body?
#
# The shipped bug: this compared the .part against the catalog's fs_size_bytes.
# For a "folder as file" ROM the server has no such file to send and streams a
# zip it builds around the members, which is larger than their sum by its own
# headers — so the check could never pass, and a download that genuinely
# finished was deleted and retried three times before going terminal. Reported
# as "downloads to 100%, then fails, for all the retries".
# ---------------------------------------------------------------------------

func _test_verify_transfer() -> void:
	var V: Callable = RommDownloader.verify_transfer

	# A plain, complete file: the response's own length is what it is judged on.
	_eq("verify/exact length ok", V.call(0, 200, 1000, 1000, 1000, false), "")
	# Truncated. HTTPClient cannot distinguish this from a clean finish, so this
	# check is the only thing that catches it.
	_ok("verify/short body caught",
		not V.call(0, 200, 1000, 940, 1000, false).is_empty())

	# THE BUG: a generated zip is bigger than the ROM the catalog describes, and
	# the server sent no length to check it against. It must still pass.
	_eq("verify/streamed zip larger than fs_size_bytes",
		V.call(0, 200, 0, 214223188, 214222438, true), "")
	# And a raw streamed file with no length still falls back to fs_size_bytes.
	_ok("verify/streamed raw file still checked",
		not V.call(0, 200, 0, 940, 1000, false).is_empty())
	_eq("verify/streamed raw file complete", V.call(0, 200, 0, 1000, 1000, false), "")

	# A served length always wins over fs_size_bytes — a zip whose body length IS
	# known must be judged on it, not on the members' sum.
	_eq("verify/served length beats fs_size_bytes",
		V.call(0, 200, 214223188, 214223188, 214222438, true), "")

	# Resume honoured: 206, and have + served is the whole file.
	_eq("verify/206 resume ok", V.call(400, 206, 600, 1000, 1000, false), "")
	_ok("verify/206 resume short caught",
		not V.call(400, 206, 600, 900, 1000, false).is_empty())

	# Resume IGNORED: 200 with a partial already on disk means the whole body was
	# appended onto it. have + served then equals the corrupt length, so nothing
	# downstream can catch it — this rule is the only guard.
	_ok("verify/range ignored caught", not V.call(400, 200, 1000, 1400, 1000, false).is_empty())
	_eq("verify/range ignored names itself",
		V.call(400, 200, 1000, 1400, 1000, false), "The server did not resume the download")
	# Not a resume, so a 200 is simply the normal case.
	_eq("verify/200 with no partial is fine", V.call(0, 200, 1000, 1000, 1000, false), "")

	# Nothing to check against at all: no served length, no catalog size. Passing
	# is the only option — failing here would block every unsized transfer.
	_eq("verify/no oracle passes", V.call(0, 200, 0, 1234, 0, false), "")

	# A mismatch that rounds to the same words must print exact bytes, or it
	# reports "204 MB of 204 MB" and reads as a broken message rather than a real
	# difference — which is exactly the scale a zip's headers add.
	var near: String = V.call(0, 200, 214222438, 214223188, 0, false)
	_ok("verify/near-miss reports exact bytes", near.contains("214223188")
		and near.contains("214222438"), near)
	# A difference big enough to render differently keeps the readable form.
	var far: String = V.call(0, 200, 3300000000, 1100000000, 0, false)
	_ok("verify/wide miss stays human", far.contains("GB"), far)


# ---------------------------------------------------------------------------
# RommCacheManifest — path handling. A key derived from a server-supplied name
# is the classic traversal hole.
# ---------------------------------------------------------------------------

func _test_cache_paths() -> void:
	var root := RomLibrary.default_roms_root()
	_eq("cache/relative strips the system dir",
		RommCacheManifest.relative_path("nes", root.path_join("nes").path_join("Game.nes")),
		"Game.nes")

	var key := RommCacheManifest.make_key("nes", "Game.nes")
	_ok("cache/key carries the system", key.contains("nes"), key)
	_ok("cache/key is stable", key == RommCacheManifest.make_key("nes", "Game.nes"))
	_ok("cache/key separates systems",
		RommCacheManifest.make_key("nes", "Game.nes")
			!= RommCacheManifest.make_key("snes", "Game.nes"))

	# A traversing name must not resolve outside the system's own folder.
	var escaped := RommCacheManifest.local_path("nes", "../../etc/passwd")
	_ok("cache/no traversal out of the system dir",
		escaped.is_empty() or escaped.begins_with(root.path_join("nes")), escaped)

	# The manifest keeps its entries and both indexes in process-wide statics, so
	# a background scan that wants to READ it must not go through load_manifest.
	# StorageCleanup.scan() runs on a worker thread; if its manifest read still
	# published into those dictionaries it would race protect_file (every
	# power-on) and evict_to_fit (every download), and the losing write empties
	# the cache index — which the player sees as every downloaded ROM vanishing.
	#
	# Asserted with a sentinel written straight into the shared dictionary and
	# never saved. In-memory only for two reasons: the player's real manifest is
	# the only file this class writes, and — more importantly — a sentinel that
	# existed on disk too would survive a reload, so the case could not go red.
	# Because it is unsaved, load_manifest() would wipe it, which is exactly the
	# signal. Point rom_ids_on_disk back at load_manifest and this fails.
	var live := RommCacheManifest.new()
	live.load_manifest()
	var sentinel := RommCacheManifest.make_key("__romm_selftest_sys", "Sentinel.nes")
	live._entries[sentinel] = {
		"rom_id": 424242, "systemid": "__romm_selftest_sys", "fs_name": "Sentinel.nes",
		"launch": "Sentinel.nes", "members": [], "size": 0, "md5": "",
		"downloaded_at": "", "last_used_at": 0.0,
	}
	_ok("cache/the sentinel is in the shared view", live._entries.has(sentinel))

	var off_disk := RommCacheManifest.rom_ids_on_disk("__romm_selftest_sys")
	_ok("cache/an on-disk read leaves the shared entries alone",
		live._entries.has(sentinel), "the read replaced the live manifest")
	_ok("cache/and reports only what is on disk",
		not off_disk.has(424242), str(off_disk))

	live._entries.erase(sentinel)
	_ok("cache/sentinel cleaned up without touching the file",
		not live._entries.has(sentinel))


# ---------------------------------------------------------------------------
# RomLibrary.scan_roms — the disk walk. Uses a scratch system folder under the
# real roms root, because the path is derived from the systemid and cannot be
# pointed elsewhere. Removed at both ends, so a crashed run leaves nothing.
# ---------------------------------------------------------------------------

func _test_scan_roms() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)

	for f: String in [
		"Game.z64",            # plain
		"UPPER.Z64",           # extension case must not matter
		".hidden.z64",         # dotfile, skipped
		"Disc.bin", "Disc.cue",  # .bin hidden by its .cue descriptor
		"Loose.bin",           # .bin with no .cue survives
		"notes.txt",           # filtered out when an extension list is given
	]:
		var h := FileAccess.open(dir_path.path_join(f), FileAccess.WRITE)
		if h:
			h.store_string("x")
			h.close()
	# A ROM one level down must NOT be found: the scan is flat for every system
	# except the folder_content ones.
	DirAccess.make_dir_recursive_absolute(dir_path.path_join("Sub"))
	var sh := FileAccess.open(dir_path.path_join("Sub").path_join("Nested.z64"), FileAccess.WRITE)
	if sh:
		sh.store_string("x")
		sh.close()

	var exts: Array[String] = ["z64", "cue", "bin"]
	var names: Array[String] = []
	for r: Dictionary in RomLibrary.scan_roms(TEST_SYSTEM, exts):
		names.append(str(r["path"]).get_file())

	_ok("scan/finds a plain rom", "Game.z64" in names, str(names))
	_ok("scan/extension case insensitive", "UPPER.Z64" in names, str(names))
	_ok("scan/skips dotfiles", not (".hidden.z64" in names), str(names))
	_ok("scan/cue hides its bin", not ("Disc.bin" in names), str(names))
	_ok("scan/keeps the cue", "Disc.cue" in names, str(names))
	_ok("scan/keeps an unpaired bin", "Loose.bin" in names, str(names))
	_ok("scan/is not recursive", not ("Nested.z64" in names), str(names))

	# Empty list means "no filter" — this is the call the menu actually makes,
	# and it is why gamelist.json once listed itself as a ROM.
	var unfiltered: Array[String] = []
	for r: Dictionary in RomLibrary.scan_roms(TEST_SYSTEM, [] as Array[String]):
		unfiltered.append(str(r["path"]).get_file())
	_ok("scan/empty filter keeps everything", "notes.txt" in unfiltered, str(unfiltered))

	_rm_rf(dir_path)
	_ok("scan/cleaned up", not DirAccess.dir_exists_absolute(dir_path))


# ---------------------------------------------------------------------------
# Deleting a game — what goes with it, and what must not.
#
# Deleting a ROM used to remove the bytes and nothing else: its library row, its
# box art, its manual and its cached cover all stayed forever, because
# GamelistManager had no removal API at all. These cover the removal rules and
# the one boundary that matters — saves are NEVER swept with a game, since a ROM
# can be downloaded again and a save cannot.
#
# Uses the same scratch system folder as the scan cases, removed at both ends.
# ---------------------------------------------------------------------------

func _test_gamelist_removal() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)
	_touch(dir_path.path_join("Kept.z64"))

	var gl := GamelistManager.new()
	gl.invalidate(TEST_SYSTEM)
	for entry: Array in [["Kept.z64", "keep"], ["Gone.z64", "drop"], ["Also.z64", "drop"]]:
		gl.add_or_merge_rom(TEST_SYSTEM,
			{"game_id": str(entry[1]), "name": str(entry[1])},
			{"path": "./" + str(entry[0]), "romname": str(entry[0])})

	# Absolute or relative, both must resolve to the same row.
	_ok("del/remove by absolute path",
		gl.remove_rom(TEST_SYSTEM, dir_path.path_join("Also.z64")))
	_ok("del/removed row is gone", not gl.known_rom_paths(TEST_SYSTEM).has("./Also.z64"))
	_ok("del/other rows untouched", gl.known_rom_paths(TEST_SYSTEM).has("./Kept.z64"))
	_ok("del/removing twice is not an error", not gl.remove_rom(TEST_SYSTEM, "Also.z64"))
	_ok("del/unknown rom refuses", not gl.remove_rom(TEST_SYSTEM, "Nonesuch.z64"))

	# The "drop" game held two ROMs and one is left, so the game must survive.
	var by_id := {}
	for g: Dictionary in gl.load_gamelist(TEST_SYSTEM).get("games", []):
		by_id[str(g.get("game_id", ""))] = g
	_ok("del/game survives while a rom remains", by_id.has("drop"))
	_eq("del/last rom standing", (by_id["drop"] as Dictionary).get("roms", []).size(), 1)

	# Removing the last one takes the game with it: an entry the library claims
	# and cannot produce is exactly the stale row this exists to stop.
	_ok("del/remove the last rom", gl.remove_rom(TEST_SYSTEM, "Gone.z64"))
	var ids := {}
	for g: Dictionary in gl.load_gamelist(TEST_SYSTEM).get("games", []):
		ids[str(g.get("game_id", ""))] = true
	_ok("del/empty game entry removed", not ids.has("drop"), str(ids.keys()))

	# prune_missing judges by the file, not by the row.
	gl.add_or_merge_rom(TEST_SYSTEM, {"game_id": "ghost", "name": "ghost"},
		{"path": "./Ghost.z64", "romname": "Ghost.z64"})
	var pruned := gl.prune_missing(TEST_SYSTEM)
	_ok("del/prune drops the missing", "./Ghost.z64" in pruned, str(pruned))
	_ok("del/prune keeps what is on disk",
		gl.known_rom_paths(TEST_SYSTEM).has("./Kept.z64"))

	# The preferred flag must not be left on a row that is gone — get_preferred_rom
	# falls back to roms[0], but set_preferred_rom reads the flags, so with none
	# set the answer depends on which reader asks.
	gl.invalidate(TEST_SYSTEM)
	for n: String in ["A.z64", "B.z64"]:
		_touch(dir_path.path_join(n))
		gl.add_or_merge_rom(TEST_SYSTEM, {"game_id": "pref", "name": "pref"},
			{"path": "./" + n, "romname": n})
	_ok("del/remove the preferred copy", gl.remove_rom(TEST_SYSTEM, "A.z64"))
	for g: Dictionary in gl.load_gamelist(TEST_SYSTEM).get("games", []):
		if str(g.get("game_id", "")) == "pref":
			_ok("del/preferred moves to a surviving rom",
				bool(GamelistManager.get_preferred_rom(g).get("preferred", false)))

	_rm_rf(dir_path)


func _test_media_and_cleanup() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)
	_touch(dir_path.path_join("Live.z64"))

	var media := RomMedia.media_root(TEST_SYSTEM)
	for rel: String in ["box/Live.png", "wheel/Live.jpg", "manual/Live.pdf",
						"box/Dead.png", "label/Dead.png", "romm/4242_s.webp"]:
		DirAccess.make_dir_recursive_absolute(media.path_join(rel).get_base_dir())
		_touch(media.path_join(rel))

	# Art is keyed on the ROM's basename and the extension is whatever the
	# scraper was handed, so a composed path would miss the .jpg every time.
	var live := RomMedia.scraped_for_rom(TEST_SYSTEM, "Live.z64")
	_eq("media/finds every extension for one rom", live.size(), 3)
	_ok("media/matches a rom-relative path",
		RomMedia.scraped_for_rom(TEST_SYSTEM, "./sub/Live.cue").size() == 3)
	_eq("media/unknown rom has none",
		RomMedia.scraped_for_rom(TEST_SYSTEM, "Nothing.z64").size(), 0)

	# The RomM cover is keyed on the server id instead, and the index has to say
	# so or the sweep cannot tell the two schemes apart.
	var index := RomMedia.index(TEST_SYSTEM)
	_eq("media/index keys scraped art by basename",
		str(index.get(media.path_join("box/Live.png"), "")), "Live")
	_eq("media/index keys romm art by id",
		str(index.get(media.path_join("romm/4242_s.webp"), "")), "romm:4242")
	_eq("media/romm art found by id", RomMedia.romm_art_for_id(TEST_SYSTEM, 4242).size(), 1)
	_eq("media/wrong id finds nothing", RomMedia.romm_art_for_id(TEST_SYSTEM, 1).size(), 0)

	# A sweep must spare art whose ROM is still here and take the rest.
	var found := StorageCleanup.scan()
	var orphans := {}
	for p: String in (found.get(StorageCleanup.MEDIA, {}) as Dictionary).get("paths", []):
		orphans[p] = true
	var sample := _sample(orphans)
	_ok("cleanup/keeps art for a rom on disk",
		not orphans.has(media.path_join("box/Live.png")), sample)
	_ok("cleanup/finds art with no rom",
		orphans.has(media.path_join("box/Dead.png")), sample)
	# A cover with no download IS found, but under COVERS — asserted just below.
	# What matters here is that it does not ALSO land in the artwork category.
	_ok("cleanup/a cover is not counted as scraped artwork",
		not orphans.has(media.path_join("romm/4242_s.webp")), sample)

	# A cached RomM cover is not an orphan, it is a cache — its own category, or
	# it dominates the total and a sweep looks like it reclaimed far more than it
	# did. 3,184 of them against 163 scraped files on a real disk.
	var covers := {}
	for p: String in (found.get(StorageCleanup.COVERS, {}) as Dictionary).get("paths", []):
		covers[p] = true
	_ok("cleanup/romm cover is its own category",
		covers.has(media.path_join("romm/4242_s.webp")), _sample(covers))
	_ok("cleanup/scraped art is not filed as a cover",
		not covers.has(media.path_join("box/Dead.png")), _sample(covers))

	# THE boundary: the two that cannot be got back by pressing a button are
	# reported but never pre-selected. Saves are progress; a BIOS folder is
	# firmware no server here hands out, and removing a core is routine.
	_ok("cleanup/saves are never swept by default",
		not (StorageCleanup.SAVES in StorageCleanup.DEFAULT_SELECTED))
	_ok("cleanup/bios folders are never swept by default",
		not (StorageCleanup.CORE_SYSTEM in StorageCleanup.DEFAULT_SELECTED))
	_ok("cleanup/media is sweepable", StorageCleanup.MEDIA in StorageCleanup.DEFAULT_SELECTED)

	# purge_rom_metadata takes one ROM's art and leaves its neighbours'.
	var freed := StorageCleanup.purge_rom_metadata(TEST_SYSTEM, "Live.z64", 0)
	_ok("cleanup/purge reports bytes", freed >= 0)
	_ok("cleanup/purge took the box art",
		not FileAccess.file_exists(media.path_join("box/Live.png")))
	_ok("cleanup/purge took the manual",
		not FileAccess.file_exists(media.path_join("manual/Live.pdf")))
	_ok("cleanup/purge left another rom's art alone",
		FileAccess.file_exists(media.path_join("box/Dead.png")))
	# It is metadata only — the ROM itself is the caller's to remove, and a purge
	# that took the file would delete the game twice over.
	_ok("cleanup/purge does not touch the rom",
		FileAccess.file_exists(dir_path.path_join("Live.z64")))

	_rm_rf(dir_path)
	_ok("cleanup/cleaned up", not DirAccess.dir_exists_absolute(dir_path))


## The category gate — the one rule in this feature that must never regress.
##
## Driven against a HAND-BUILT findings dict, never a real scan: calling
## remove() with SAVES on whatever scan() found would delete the developer's own
## orphaned saves the first time this suite ran. The gate is what is under test,
## not the scanner, so the input is synthetic on purpose.
func _test_cleanup_gate() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	var art := RomMedia.media_root(TEST_SYSTEM).path_join("box/Sweepable.png")
	var save_dir := dir_path.path_join("__fake_save")
	_touch(art)
	_touch(save_dir.path_join("game.srm"))

	var found := {
		StorageCleanup.MEDIA: {"label": "m", "count": 1, "bytes": 1, "paths": [art]},
		StorageCleanup.SAVES: {"label": "s", "count": 1, "bytes": 1, "paths": [save_dir]},
	}

	var res := StorageCleanup.remove(found, StorageCleanup.DEFAULT_SELECTED)
	_ok("gate/sweeps the safe category", not FileAccess.file_exists(art))
	_ok("gate/SAVES SURVIVES A DEFAULT SWEEP",
		FileAccess.file_exists(save_dir.path_join("game.srm")))
	_eq("gate/counts only what it removed", int(res["removed"]), 1)

	# Named explicitly, it goes — and a directory goes with its contents.
	StorageCleanup.remove(found, [StorageCleanup.SAVES])
	_ok("gate/saves removed when asked for by name",
		not DirAccess.dir_exists_absolute(save_dir))

	# A category present in the findings but absent from `kinds` is untouched,
	# which is what makes the checkboxes mean anything.
	_touch(art)
	StorageCleanup.remove(found, [StorageCleanup.SAVES])
	_ok("gate/unnamed category untouched", FileAccess.file_exists(art))

	_rm_rf(dir_path)


## Which folder requirements may be offered BIOS files from the server.
##
## Both PS2 cores declare two directories, and only one of them is for BIOS.
## Keying the picker on the systemid alone offered the same 68 PS2 dumps for
## `pcsx2/resources` — a shaders/GameIndex/fonts folder — and pressing Get all
## there filed twenty of them in the wrong place on a real headset.
func _test_bios_folder_rule() -> void:
	var V: Callable = SpawnMenuCoresView._is_bios_folder

	_ok("biosdir/pcsx2 bios is one", V.call("pcsx2/bios"))
	_ok("biosdir/trailing slash still one", V.call("pcsx2/bios/"))
	_ok("biosdir/a bare bios folder is one", V.call("bios"))
	_ok("biosdir/case does not matter", V.call("PCSX2/BIOS"))

	# The three shapes in the info database that are NOT bios folders.
	_ok("biosdir/pcsx2 resources is not", not V.call("pcsx2/resources"))
	_ok("biosdir/mkxp RTP is not", not V.call("mkxp-z/RTP/Standard"))
	_ok("biosdir/mkxp RTP VXAce is not", not V.call("mkxp-z/RTP/RPGVXAce"))
	_ok("biosdir/empty is not", not V.call(""))

	# Every directory requirement the shipped .info files actually declare, so a
	# new core with a new folder shape shows up here rather than in a bug report.
	var dirs: Dictionary = {}
	var db := CoreInfoDatabase.shared()
	for core: String in ["pcsx2", "pcee2", "yaps2", "mkxp-z"]:
		for req: Dictionary in FirmwareRequirements.from_info(db.get_by_core_name(core)):
			if bool(req.get("is_dir", false)):
				dirs[str(req["path"])] = true
	_ok("biosdir/corpus still only these folders",
		dirs.has("pcsx2/bios") and dirs.has("pcsx2/resources"), str(dirs.keys()))
	var offered: Array = []
	for d: String in dirs:
		if V.call(d):
			offered.append(d)
	_eq("biosdir/exactly one folder shape takes server files", offered, ["pcsx2/bios"])


## Which directories under system/ may be offered for deletion.
##
## Both shapes below were live on a real disk and both were pre-ticked before the
## gate went in: `cheats/` is shared infrastructure holding dolphin-emu/*.cht,
## and `melonDS DS/` belongs to a core that IS installed but names its directory
## after its display name rather than its core_name. "Not installed" was the
## wrong test; "is a core this app knows about, and is not installed" is right,
## because it leaves anything unidentifiable alone.
func _test_cleanup_core_dirs() -> void:
	var system_root := CoreDownloadManager.default_core_root().path_join("system")
	var db := CoreInfoDatabase.shared()

	# The gate itself, asserted directly — the scan cannot be pointed at a
	# scratch libretro root, so planting directories under the real one to prove
	# it would risk the developer's own firmware.
	_ok("coredir/cheats is not a core name", db.get_by_core_name("cheats").is_empty())
	_ok("coredir/a display name is not a core name",
		db.get_by_core_name("melonDS DS").is_empty())
	_ok("coredir/the core behind that display name IS known",
		not db.get_by_core_name("melondsds").is_empty())
	_ok("coredir/a real core name is known", not db.get_by_core_name("snes9x").is_empty())

	# And the live scan: nothing it offers may be a directory the database
	# cannot name, whatever is actually on this machine.
	var offered := (StorageCleanup.scan().get(StorageCleanup.CORE_SYSTEM, {}) as Dictionary)
	var bad := {}
	for p: String in offered.get("paths", []):
		var leaf := str(p).trim_suffix("/").get_file()
		if db.get_by_core_name(leaf).is_empty():
			bad[p] = true
	_eq("coredir/offers no unidentifiable directory", bad.size(), 0)
	# Belt and braces: name the two that actually shipped wrong.
	for leaf: String in ["cheats", "melonDS DS"]:
		_ok("coredir/never offers %s" % leaf,
			not (system_root.path_join(leaf) in offered.get("paths", [])))


## A "folder as file" game — a directory named Game.cue holding the cue and its
## tracks, the layout ES-DE and RetroDECK use. The folder IS the ROM, so its art
## must not be swept.
func _test_cleanup_folder_as_file() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	# The common shape: the folder and its launch file share a name.
	_touch(dir_path.path_join("Disc Game.cue/Disc Game.cue"))
	_touch(dir_path.path_join("Disc Game.cue/Disc Game.bin"))
	# And the shape that actually tests the rule: a folder whose contents are
	# named nothing like it, so ONLY the folder's own name can vouch for the art.
	# Without it, the two cases above pass whether or not folders are recorded.
	_touch(dir_path.path_join("Compilation.m3u/track01.bin"))
	_touch(dir_path.path_join("Compilation.m3u/track02.bin"))

	var media := RomMedia.media_root(TEST_SYSTEM)
	_touch(media.path_join("box/Disc Game.png"))
	_touch(media.path_join("box/Compilation.png"))
	_touch(media.path_join("box/Vanished.png"))
	# Art keyed on a file INSIDE the folder must survive too — the walk records
	# the folder's own name and its contents.
	_touch(media.path_join("label/Disc Game.png"))

	var orphans := {}
	for p: String in (StorageCleanup.scan().get(StorageCleanup.MEDIA, {}) as Dictionary
			).get("paths", []):
		orphans[p] = true
	# The sweep sees the whole real library, so a failure would otherwise print
	# every orphan on the disk — hundreds of lines nobody reads.
	var sample := _sample(orphans)

	_ok("folder/keeps art for a folder-as-file game",
		not orphans.has(media.path_join("box/Disc Game.png")), sample)
	_ok("folder/keeps art when only the folder name matches",
		not orphans.has(media.path_join("box/Compilation.png")), sample)
	_ok("folder/keeps art keyed on a member",
		not orphans.has(media.path_join("label/Disc Game.png")), sample)
	_ok("folder/still finds a real orphan beside it",
		orphans.has(media.path_join("box/Vanished.png")), sample)

	_rm_rf(dir_path)


## A gamelist row whose path escapes the ROM root resolves to nothing. It must
## read as missing and be pruned, not silently kept forever because the check
## could not answer.
func _test_gamelist_bad_paths() -> void:
	var dir_path := RomLibrary.rom_dir_for_system(TEST_SYSTEM)
	_rm_rf(dir_path)
	DirAccess.make_dir_recursive_absolute(dir_path)
	_touch(dir_path.path_join("Real.z64"))

	var gl := GamelistManager.new()
	gl.invalidate(TEST_SYSTEM)
	for bad: String in ["./../../etc/passwd", "./", "C:/Windows/system.ini"]:
		gl.add_or_merge_rom(TEST_SYSTEM, {"game_id": bad, "name": bad},
			{"path": bad, "romname": bad})
	gl.add_or_merge_rom(TEST_SYSTEM, {"game_id": "ok", "name": "ok"},
		{"path": "./Real.z64", "romname": "Real.z64"})

	var pruned := gl.prune_missing(TEST_SYSTEM)
	_ok("badpath/traversal pruned", "./../../etc/passwd" in pruned, str(pruned))
	_ok("badpath/absolute pruned", "C:/Windows/system.ini" in pruned, str(pruned))
	_ok("badpath/real rom kept", gl.known_rom_paths(TEST_SYSTEM).has("./Real.z64"))

	_rm_rf(dir_path)


## Uninstalling a core. Runs against the real cores directory because the path is
## derived, not injectable — under a name nothing could ever ship as, and the
## cores manifest is byte-restored afterwards: rewriting it round-trips through
## JSON, and the user's real install is not this suite's to reformat.
func _test_core_uninstall() -> void:
	const FAKE := "__cleanup_selftest"
	var cores_dir := CoreDownloadManager.default_cores_dir()
	var manifest_path := CoreDownloadManager.default_manifest_dir().path_join(
		"cores_manifest.json")

	var backup := ""
	var had_manifest := FileAccess.file_exists(manifest_path)
	if had_manifest:
		backup = FileAccess.get_file_as_string(manifest_path)

	# The naming rules, driven with an explicit suffix list rather than this
	# platform's. Desktop has ONE suffix, so a test that leaned on the live list
	# could not tell "removes every variant" from "removes the only one" — it
	# passed with the loop cut down to a single name.
	var android := PackedStringArray(["_libretro_android", "_libretro"])
	var both := CoreDownloadManager.core_lib_filenames(FAKE, android, ".so")
	_eq("uninstall/android has two naming variants", both.size(), 2)
	_eq("uninstall/canonical variant first", both[0], FAKE + "_libretro_android.so")
	_eq("uninstall/round-trips the android name",
		CoreDownloadManager.core_name_from_lib_filename(
			FAKE + "_libretro_android.so", android, ".so"), FAKE)
	_eq("uninstall/round-trips the bare name",
		CoreDownloadManager.core_name_from_lib_filename(
			FAKE + "_libretro.so", android, ".so"), FAKE)
	_eq("uninstall/a non-core filename yields nothing",
		CoreDownloadManager.core_name_from_lib_filename("readme.txt", android, ".so"), "")

	var names := CoreDownloadManager.core_lib_filenames(FAKE)
	_ok("uninstall/has a filename for this platform", names.size() > 0)
	for n: String in names:
		_touch(cores_dir.path_join(n))
	# A stray file under a name uninstall must NOT touch, to prove the sweep is
	# scoped to this core rather than to anything sharing its prefix.
	var bystander := cores_dir.path_join(FAKE + "2" + names[0].trim_prefix(FAKE))
	_touch(bystander)

	var res := CoreDownloadManager.uninstall(FAKE)
	_ok("uninstall/reports ok", bool(res["ok"]), str(res))
	var left := 0
	for n: String in names:
		if FileAccess.file_exists(cores_dir.path_join(n)):
			left += 1
	_eq("uninstall/removes this platform's library", left, 0)
	_ok("uninstall/leaves a similarly named core alone", FileAccess.file_exists(bystander))
	DirAccess.remove_absolute(bystander)

	# Uninstalling what is not there must fail rather than report success — the
	# UI turns ok into "Removed X, N freed".
	var again := CoreDownloadManager.uninstall(FAKE)
	_ok("uninstall/absent core refuses", not bool(again["ok"]), str(again))
	_ok("uninstall/absent core says why", not str(again["error"]).is_empty())
	_ok("uninstall/empty name refuses", not bool(CoreDownloadManager.uninstall("")["ok"]))

	# Nothing in the scene, so nothing can be using it.
	_eq("uninstall/nothing is using a fake core",
		CoreDownloadManager.systems_using(FAKE).size(), 0)
	_eq("uninstall/an unnamed core is used by nothing",
		CoreDownloadManager.systems_using("").size(), 0)

	if had_manifest:
		var f := FileAccess.open(manifest_path, FileAccess.WRITE)
		if f:
			f.store_string(backup)
			f.close()
	elif FileAccess.file_exists(manifest_path):
		DirAccess.remove_absolute(manifest_path)
	_ok("uninstall/manifest restored",
		not had_manifest or FileAccess.get_file_as_string(manifest_path) == backup)


## A readable slice of a set that may legitimately hold thousands of entries.
func _sample(found: Dictionary, limit: int = 6) -> String:
	var keys := found.keys()
	var head: Array = keys.slice(0, mini(limit, keys.size()))
	return "%d found, e.g. %s" % [keys.size(), str(head)]


func _touch(path: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string("x")
		f.close()


# ---------------------------------------------------------------------------
# RommHttp — what a stalled server does to the thread waiting on it.
#
# A RomM box that accepts the connection and then goes quiet froze the whole app:
# the body loop had no deadline, so the worker sat on the socket indefinitely and
# whoever joined that thread sat there with it. These drive a real socket that
# behaves exactly that way, on loopback, with no RomM anywhere.
# ---------------------------------------------------------------------------

const _HEAD := "HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n"
const _BODY := '{"ok":true}'


## A TCP server that accepts one connection and then does as it is told: a list
## of [delay_ms, bytes] steps, followed by silence with the socket HELD OPEN.
##
## Holding it open is the whole point. A server that closes instead ends the
## client's body loop by itself, and every case below would pass green without
## the code under test contributing anything.
class FakeServer extends RefCounted:

	var port := 0
	## Everything the client sent. Read it after stop() — the serve thread owns
	## it until then. Draining is not only for inspection: an upload body larger
	## than the socket buffer would block the CLIENT if nobody ever read it.
	var received := PackedByteArray()
	var _server := TCPServer.new()
	var _thread := Thread.new()
	var _stop := false

	func start(steps: Array) -> bool:
		for p in range(49500, 49560):
			if _server.listen(p, "127.0.0.1") == OK:
				port = p
				break
		if port == 0:
			return false
		_thread.start(_serve.bind(steps))
		return true

	func stop() -> void:
		_stop = true
		if _thread.is_started():
			_thread.wait_to_finish()
		_server.stop()

	func _serve(steps: Array) -> void:
		var peer: StreamPeerTCP = null
		var give_up := Time.get_ticks_msec() + 5000
		while peer == null and Time.get_ticks_msec() < give_up and not _stop:
			if _server.is_connection_available():
				peer = _server.take_connection()
			else:
				OS.delay_msec(5)
		if peer == null:
			return
		peer.poll()
		while peer.get_status() == StreamPeerTCP.STATUS_CONNECTING and not _stop:
			OS.delay_msec(5)
			peer.poll()

		# Let the request land before answering. A canned reply sent before the
		# client has finished writing is fine for HTTP, but this is also where
		# the body gets drained, and the client stalls if it never is.
		var quiet := Time.get_ticks_msec() + 250
		while Time.get_ticks_msec() < quiet and not _stop:
			peer.poll()
			var n := peer.get_available_bytes()
			if n > 0:
				received.append_array(peer.get_data(n)[1])
				quiet = Time.get_ticks_msec() + 60
			else:
				OS.delay_msec(5)

		for step: Array in steps:
			OS.delay_msec(int(step[0]))
			var chunk: PackedByteArray = step[1]
			if chunk.size() > 0:
				peer.put_data(chunk)

		while not _stop:
			peer.poll()
			var more := peer.get_available_bytes()
			if more > 0:
				received.append_array(peer.get_data(more)[1])
			OS.delay_msec(10)
		peer.disconnect_from_host()


## One exchange against a scripted server, run on ITS OWN thread.
##
## The blocking call cannot go on the main thread: a body loop with no deadline
## would pin _ready() itself, and a probe that hangs is worse than no probe —
## nothing left running would ever report the failure. Off-thread, `cap_sec`
## turns that same regression into a red line.
##
## Sentinel results, so a setup failure can never read as a pass:
##   -1 could not listen   -2 could not connect   -3 still blocked at the cap
func _probe(steps: Array, abort: Callable, timeout_sec: float,
			cap_sec: float = 10.0) -> Dictionary:
	var srv := FakeServer.new()
	if not srv.start(steps):
		return {"result": -1}

	var box := {"out": {"result": -2}}
	var url := "http://127.0.0.1:%d" % srv.port
	var t := Thread.new()
	t.start(func() -> void:
		var http := RommHttp.new()
		if http.open(url) == RommHttp.Result.OK:
			box["out"] = http.get_json("/x", PackedStringArray(), abort, timeout_sec)
		http.close())

	var deadline := Time.get_ticks_msec() + int(cap_sec * 1000.0)
	while t.is_alive() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame

	var stuck := t.is_alive()
	# Dropping the server closes the socket, which is what lets a stuck call
	# unwind far enough to be joined.
	srv.stop()
	t.wait_to_finish()
	return {"result": -3} if stuck else box["out"]


## Like _probe, but the caller supplies the request and gets the raw bytes the
## server received back with the result. Composing a multipart body is the part
## of an upload most likely to be wrong, and the only way to check it is to look
## at what actually went down the socket.
##
## Returns {out: Dictionary, request: String} — or {out: {result: -1|-2|-3}}.
func _probe_request(steps: Array, send: Callable, cap_sec: float = 10.0) -> Dictionary:
	var srv := FakeServer.new()
	if not srv.start(steps):
		return {"out": {"result": -1}, "request": ""}

	var box := {"out": {"result": -2}}
	var url := "http://127.0.0.1:%d" % srv.port
	var t := Thread.new()
	t.start(func() -> void:
		var http := RommHttp.new()
		if http.open(url) == RommHttp.Result.OK:
			box["out"] = send.call(http)
		http.close())

	var deadline := Time.get_ticks_msec() + int(cap_sec * 1000.0)
	while t.is_alive() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var stuck := t.is_alive()
	srv.stop()
	t.wait_to_finish()
	if stuck:
		return {"out": {"result": -3}, "request": ""}
	return {"out": box["out"], "request": _printable(srv.received),
		"raw": srv.received}


## A request rendered so its headers read and its LENGTH still means something.
##
## Not get_string_from_ascii(): a state is arbitrary binary and its first byte
## here is 0x00, which stops that decode dead — the capture came back 178 bytes
## long against a 925-byte body, so every length case failed on the harness
## rather than on the code. Every non-printable becomes ".", so one byte in is
## still one character out.
func _printable(bytes: PackedByteArray) -> String:
	var out := PackedByteArray()
	out.resize(bytes.size())
	for i in range(bytes.size()):
		var b := bytes[i]
		out[i] = b if (b >= 32 and b <= 126) or b == 13 or b == 10 else 46
	return out.get_string_from_ascii()


func _test_http_stalls() -> void:
	# Positive control. The header wait always had a deadline, so this one passing
	# says the fake server and the harness work; if it ever goes red, suspect them
	# before suspecting RommHttp.
	var silent: Dictionary = await _probe([], Callable(), 1.0)
	_eq("http/a server that never answers times out",
		int(silent["result"]), RommHttp.Result.TIMED_OUT)

	# The freeze itself: headers arrive, three bytes of an eleven-byte body
	# arrive, and then nothing ever does.
	var half: Array = [[0, (_HEAD + "abc").to_utf8_buffer()]]
	var stalled: Dictionary = await _probe(half, Callable(), 1.0)
	_eq("http/a body that stops mid-stream times out",
		int(stalled["result"]), RommHttp.Result.TIMED_OUT)

	# Same stall, but the caller changes its mind first. A generous timeout so
	# that reaching ABORTED proves the abort ended it and not the clock — this is
	# what lets a teardown join the worker instead of waiting out the server.
	var give_up := Time.get_ticks_msec() + 300
	var aborted: Dictionary = await _probe(half,
		func() -> bool: return Time.get_ticks_msec() > give_up, 30.0)
	_eq("http/a stalled body answers the abort",
		int(aborted["result"]), RommHttp.Result.ABORTED)

	# The deadline bounds SILENCE, not total transfer. Six chunks 200 ms apart run
	# 1.2 s against a 0.5 s budget and must all get through: a 4 GB ROM outruns
	# any single timeout, so a total-duration cap would abandon healthy downloads.
	var drip: Array = [[0, _HEAD.to_utf8_buffer()]]
	for i in range(6):
		drip.append([200, _BODY.substr(i * 2, 2).to_utf8_buffer()])
	var slow: Dictionary = await _probe(drip, Callable(), 0.5)
	_eq("http/a slow but moving body is not cut off",
		int(slow["result"]), RommHttp.Result.OK)


func _rm_rf(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		var child := path.path_join(n)
		if d.current_is_dir():
			_rm_rf(child)
		else:
			DirAccess.remove_absolute(child)
		n = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(path)


# ---------------------------------------------------------------------------
# The global backup switch. This changed SHIPPED behaviour — battery saves used
# to be opt-in per save, defaulting to off — so the exact fallback order is
# worth pinning: an explicit record always wins, and only a save nobody has
# said anything about follows the switch.
# ---------------------------------------------------------------------------

func _test_backup_switch() -> void:
	var cfg := RommConfig.new()
	var sync := RommSaveSync.new()
	sync.config = cfg
	var path := CoreDownloadManager.default_core_root().path_join("save") \
		.path_join("fceumm").path_join("Game").path_join("abc123.srm")

	cfg.backup_enabled = true
	_ok("backup/a save nobody has ruled on follows the switch", sync.is_enabled(path))
	cfg.backup_enabled = false
	_ok("backup/and follows it the other way", not sync.is_enabled(path))

	# An explicit answer outranks the switch in BOTH directions. The first is
	# what lets a player keep one save off a shared server; the second is what
	# stops turning the switch off silently un-syncing a save they turned on.
	sync.set_enabled(path, true)
	_ok("backup/an opted-in save ignores the switch being off", sync.is_enabled(path))
	cfg.backup_enabled = true
	sync.set_enabled(path, false)
	_ok("backup/an opted-out save ignores the switch being on", not sync.is_enabled(path))

	# A save INSIDE a memory card is keyed separately and has to follow the same
	# ladder — a card's saves were opt-in per slot too.
	var card := CoreDownloadManager.default_core_root().path_join("save") \
		.path_join("memcards").path_join("playstation").path_join("MEMORY CARD.mcr")
	var key := RommSaveSync.card_save_key(card, "BASLUS-00594")
	cfg.backup_enabled = true
	_ok("backup/a card save follows the switch too", sync.is_key_enabled(key))
	cfg.backup_enabled = false
	_ok("backup/and follows it off", not sync.is_key_enabled(key))

	# Nothing was persisted by this case beyond the two records it wrote; drop
	# them so a rerun starts where it did.
	sync._state.erase(RommSaveSync.key_for(path))
	sync.save_state()

	# The switch survives a round trip through the file, and an OLD config that
	# has never heard of it comes back ON — that is what makes the default
	# apply to everyone who upgrades rather than only to new installs.
	var fresh := RommConfig.new()
	_ok("backup/a config with no such key defaults on", fresh.backup_enabled)
	sync.free()


# ---------------------------------------------------------------------------
# RommStates — /api/states, which is NOT /api/saves with a different noun.
#
# Three differences bite, and all three are pinned below: there is no `slot` so
# identity is the filename; deleting is a POST with a list; and there is no
# `overwrite` parameter, so an overwrite has to PUT to a remembered id.
#
# The upload cases read the bytes the server actually received. Composing a
# multipart body is the part most likely to be silently wrong — a missing CRLF
# or a stale Content-Length produces a 200 from some servers and a corrupt file
# on disk, which no response-code check would ever catch.
# ---------------------------------------------------------------------------

const _STATE_ID := "1787000000000-0a1b2c"
## The line ending multipart is specified in, spelled out so the needles below
## read as what they are: every delimiter must be preceded by one.
const _CRLF := "\r\n"


func _test_state_schema() -> void:
	# `screenshot` is a REQUIRED field of StateSchema that may be null, so both
	# shapes arrive in practice and neither may throw.
	var with_shot := RommStates.from_schema({
		"id": 12, "rom_id": 7, "file_name": _STATE_ID + ".state",
		"file_size_bytes": 4456448, "emulator": "pcsx_rearmed",
		"updated_at": "2026-08-17T21:00:00", "created_at": "2026-08-17T20:00:00",
		"screenshot": {"download_path": "/assets/states/12.png",
			"file_name": "12.png", "file_size_bytes": 9000},
	})
	_eq("states/the id comes through", int(with_shot["id"]), 12)
	_eq("states/and the picture's path", str(with_shot["screenshot_path"]),
		"/assets/states/12.png")

	var without := RommStates.from_schema({
		"id": 13, "rom_id": 7, "file_name": "someone-elses.state", "screenshot": null})
	_eq("states/a null screenshot flattens to nothing", str(without["screenshot_path"]), "")

	# Identity is the filename, because RomM gives a state no slot to key on. A
	# name this app did not mint must NOT be adopted: claiming it would take an
	# id we might mint ourselves later, and the two would then collide.
	_eq("states/our own filename yields its id",
		RommStates.id_from_filename(_STATE_ID + ".state"), _STATE_ID)
	_eq("states/a foreign name yields nothing",
		RommStates.id_from_filename("someone-elses.state"), "")
	_eq("states/and so does an empty one", RommStates.id_from_filename(""), "")


func _test_state_upload_body() -> void:
	# Binary, NULs and all, with an ASCII sentinel buried in it: the length cases
	# below prove the body is the size it claims, and the sentinel proves those
	# bytes are the ones the caller handed over rather than a same-sized
	# re-encoding of them.
	var payload := PackedByteArray()
	for i in range(256):
		payload.append(i)
	payload.append_array("STATE-BYTES-HERE".to_utf8_buffer())
	for i in range(256):
		payload.append(255 - i)
	var shot := "PNG-not-really".to_utf8_buffer()

	var both: Dictionary = await _probe_request([[0, (_HEAD + _BODY).to_utf8_buffer()]],
		func(http: RommHttp) -> Dictionary:
			return RommStates.create(http, PackedStringArray(), 7, "pcsx_rearmed",
				_STATE_ID + ".state", payload, shot))
	var req: String = both["request"]
	_ok("upload/the call came back", bool((both["out"] as Dictionary).get("ok", false)),
		str((both["out"] as Dictionary).get("error", both["out"])))
	_ok("upload/POSTs to /api/states with the rom and emulator",
		req.begins_with("POST /api/states?rom_id=7&emulator=pcsx_rearmed "), req.left(60))
	_ok("upload/declares a multipart body",
		req.contains("Content-Type: multipart/form-data; boundary=----RetroXR"))
	# BOTH parts in ONE request — that is the whole reason the server stores the
	# picture against the state instead of beside it.
	_ok("upload/carries the state part",
		req.contains('name="stateFile"; filename="%s.state"' % _STATE_ID))
	_ok("upload/and the screenshot part",
		req.contains('name="screenshotFile"; filename="%s.png"' % _STATE_ID))
	_ok("upload/the screenshot is declared as a png", req.contains("Content-Type: image/png"))
	_ok("upload/the state's own bytes are in the body", req.contains("STATE-BYTES-HERE"))
	_ok("upload/and the picture's", req.contains("PNG-not-really"))

	# Every delimiter is preceded by CRLF — RFC 7578's rule, and the one an
	# implementation quietly gets wrong. Asserting it structurally rather than by
	# re-deriving the expected length: comparing the body against its own
	# Content-Length is self-consistent and stays green when a terminator is
	# dropped from BOTH, which is exactly what a mutation of this proved.
	var boundary := _boundary_of(req)
	_ok("upload/there is a boundary", not boundary.is_empty(), boundary)
	_ok("upload/the closing delimiter is preceded by CRLF",
		req.contains(_CRLF + "--%s--" % boundary))
	_ok("upload/and so is the second part's",
		req.contains(_CRLF + "--%s%sContent-Disposition: form-data; name=\"screenshotFile\""
			% [boundary, _CRLF]))
	# A stale Content-Length is a different fault: too short and the server reads
	# the rest as the next request, too long and it waits for bytes never sent.
	_eq("upload/Content-Length matches the body", _body_len(req), _declared_len(req))

	# No picture: one part, and the upload still goes. A thumbnail that failed to
	# encode must never hold a state back.
	var alone: Dictionary = await _probe_request([[0, (_HEAD + _BODY).to_utf8_buffer()]],
		func(http: RommHttp) -> Dictionary:
			return RommStates.create(http, PackedStringArray(), 7, "fceumm",
				_STATE_ID + ".state", payload))
	var req2: String = alone["request"]
	_ok("upload/a state with no picture still uploads",
		bool((alone["out"] as Dictionary).get("ok", false)))
	_ok("upload/and sends only the one part",
		req2.contains('name="stateFile"') and not req2.contains('name="screenshotFile"'))
	_eq("upload/its Content-Length matches too", _body_len(req2), _declared_len(req2))
	_ok("upload/and its one part is terminated",
		req2.contains(_CRLF + "--%s--" % _boundary_of(req2)))


## The battery-save upload still composes the way it always did. upload_multipart
## became a one-part wrapper over upload_parts when states needed two, and saves
## are the caller that was already shipping — a regression here would corrupt
## every .srm uploaded, silently, with a 200 back from the server.
func _test_save_upload_still_works() -> void:
	var sent: Dictionary = await _probe_request([[0, (_HEAD + _BODY).to_utf8_buffer()]],
		func(http: RommHttp) -> Dictionary:
			return RommSaves.create(http, PackedStringArray(), 7, "fceumm", "slot1",
				"game.srm", "battery".to_utf8_buffer()))
	var req: String = sent["request"]
	_ok("saves/still POSTs to /api/saves with its slot",
		req.begins_with("POST /api/saves?rom_id=7&emulator=fceumm&slot=slot1&overwrite=true "),
		req.left(70))
	_ok("saves/still names the part saveFile",
		req.contains('name="saveFile"; filename="game.srm"'))
	_ok("saves/still sends the bytes", req.contains("battery"))
	_ok("saves/and still terminates the body",
		req.contains(_CRLF + "--%s--" % _boundary_of(req)))
	_eq("saves/with a Content-Length that matches", _body_len(req), _declared_len(req))


func _test_state_overwrite_and_delete() -> void:
	var payload := "core".to_utf8_buffer()
	# There is no `overwrite` parameter on /api/states, unlike /api/saves — an
	# overwrite is a PUT to the id the ledger remembers, which is what stops the
	# same filename being uploaded twice.
	var put: Dictionary = await _probe_request([[0, (_HEAD + _BODY).to_utf8_buffer()]],
		func(http: RommHttp) -> Dictionary:
			return RommStates.update(http, PackedStringArray(), 42,
				_STATE_ID + ".state", payload))
	_ok("overwrite/PUTs to the state's own id",
		str(put["request"]).begins_with("PUT /api/states/42 "), str(put["request"]).left(40))
	_ok("overwrite/does not ask for overwrite=true",
		not str(put["request"]).contains("overwrite"))

	# Deleting is POST /api/states/delete with a list. DELETE /api/states/{id}
	# does not exist, and calling it would 404 forever while looking like a
	# server problem.
	var del: Dictionary = await _probe_request([[0, (_HEAD + _BODY).to_utf8_buffer()]],
		func(http: RommHttp) -> Dictionary:
			return RommStates.delete(http, PackedStringArray(), [42, 43]))
	var dreq: String = del["request"]
	_ok("delete/POSTs to /api/states/delete",
		dreq.begins_with("POST /api/states/delete "), dreq.left(40))
	_ok("delete/sends json", dreq.contains("Content-Type: application/json"))
	_ok("delete/with the ids in a list", dreq.contains('{"states":[42,43]}'), dreq.right(40))
	_ok("delete/nothing to delete makes no request at all",
		bool(RommStates.delete(null, PackedStringArray(), [])["ok"]))


func _test_state_server_only() -> void:
	var sync := RommStateSync.new()
	var core := "__state_selftest"
	var rom := "selftest.nes"
	var mine := StatePaths.state_path(core, rom, _STATE_ID)
	DirAccess.make_dir_recursive_absolute(mine.get_base_dir())
	var f := FileAccess.open(mine, FileAccess.WRITE)
	f.store_string("x")
	f.close()

	var server := [
		{"id": 1, "file_name": _STATE_ID + ".state", "size": 10, "updated_at": "a",
		 "screenshot_path": ""},
		{"id": 2, "file_name": "1787000000001-0a1b2d.state", "size": 20, "updated_at": "b",
		 "screenshot_path": "/assets/2.png"},
		{"id": 3, "file_name": "retroarch-slot1.state", "size": 30, "updated_at": "c",
		 "screenshot_path": ""},
	]
	var only := sync.server_only(core, rom, server)
	_eq("server-only/one row offered", only.size(), 1)
	if only.size() == 1:
		# Not the one we already have, and not the one another client wrote.
		_eq("server-only/and it is the one we lack", str(only[0]["state_id"]),
			"1787000000001-0a1b2d")
		_eq("server-only/carrying its server id", int(only[0]["server_id"]), 2)
		_eq("server-only/and its picture", str(only[0]["screenshot_path"]), "/assets/2.png")

	# The ledger key is relative to the states root, so it survives the app being
	# moved — the same rule saves follow.
	var key := RommStateSync.key_for(mine)
	_ok("server-only/the ledger key is relative", not key.begins_with("/")
		and not key.contains(":"), key)
	_ok("server-only/and names the game", key.contains(core) and key.contains(_STATE_ID), key)

	DirAccess.remove_absolute(mine)
	DirAccess.remove_absolute(mine.get_base_dir())
	sync.free()


## Pulling a state down, and the bookkeeping that keeps it from being pushed
## straight back up again.
func _test_state_restore() -> void:
	var sync := RommStateSync.new()
	var cfg := RommConfig.new()
	cfg.enabled = true
	cfg.base_url = "http://127.0.0.1:1"
	cfg.token = "x"
	cfg.backup_enabled = true
	sync.config = cfg
	var core := "__state_selftest"
	var rom := "selftest.nes"
	var path := StatePaths.state_path(core, rom, _STATE_ID)
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("pulled")
	f.close()

	# Fresh off the wire, before anything is recorded: the row must not claim to
	# be backed up.
	_eq("restore/an unrecorded state is not backed up", sync.status_for(path), "off")

	# What _download_worker reports when a pull lands. Recording the server id is
	# what stops the tab offering to upload a state it has just downloaded — and
	# what lets a later overwrite PUT over the right copy instead of creating a
	# second one.
	sync._download_done(path, true, 99, "")
	_eq("restore/a pulled state reads as backed up", sync.status_for(path), "on")
	_eq("restore/against the server's own id",
		int(sync.record_for(path).get("server_id", 0)), 99)
	# And it is no longer offered as server-only, because the file now exists.
	_eq("restore/and drops out of the server list",
		sync.server_only(core, rom, [{"id": 99, "file_name": _STATE_ID + ".state",
			"size": 6, "updated_at": "a", "screenshot_path": ""}]).size(), 0)

	# A failed pull records nothing: a row that says "on" with no file behind it
	# is worse than one that says nothing.
	var missing := StatePaths.state_path(core, rom, "1787000000009-0b2c3d")
	sync._download_done(missing, false, 0, "Connection lost")
	_eq("restore/a failed pull claims nothing", sync.status_for(missing), "off")

	# Deleting locally must drop the ledger entry, or a state minted later at the
	# same path would inherit this server id and PUT over a stranger's copy.
	sync.forget(path)
	_eq("restore/deleting forgets the server id", sync.status_for(path), "off")

	# With backup switched off the column goes away entirely rather than showing
	# a stale "on" for every row.
	sync._download_done(path, true, 99, "")
	cfg.backup_enabled = false
	_eq("restore/the switch hides the column", sync.status_for(path), "off")

	sync._state.clear()
	sync.save_state()
	DirAccess.remove_absolute(path)
	DirAccess.remove_absolute(path.get_base_dir())
	sync.free()


## One ROM, one game entry.
##
## The regression record for a bug found in a real library: add_or_merge_rom
## identified a game by game_id alone, so scraping a ROM that came from RomM
## found no match for the scraper's numeric id and appended a SECOND entry for
## the same file. Whichever entry a reader hit first then decided whether the
## ROM appeared to be on RomM at all — and with it whether save sync and
## save-state backup did anything.
func _test_gamelist_one_entry_per_rom() -> void:
	var sysid := TEST_SYSTEM
	var gl := GamelistManager.new()
	gl._gamelists[sysid] = {"games": []}
	var rom := "./Super Mario Bros. 2 (USA).nes"

	# Downloaded from RomM first, then scraped — the order your library is in.
	gl.add_or_merge_rom(sysid, {"game_id": "romm:93288", "name": "Super Mario Bros. 2",
		"desc": "", "developer": "Nintendo", "publisher": "", "genre": "Platform"},
		{"path": rom, "romname": rom.get_file()})
	gl.add_or_merge_rom(sysid, {"game_id": "1248", "name": "Super Mario Bros. 2",
		"desc": "Mario in a dream world.", "developer": "Nintendo",
		"publisher": "Nintendo", "genre": "Platform"},
		{"path": rom, "romname": rom.get_file()})

	var games: Array = gl._gamelists[sysid]["games"]
	_eq("gamelist/scraping a RomM rom does not add a second entry", games.size(), 1)
	if games.size() == 1:
		# The RomM link is load-bearing and the scraper id is not, so the scrape
		# must not take it away.
		_eq("gamelist/and keeps the RomM id", str(games[0].get("game_id", "")), "romm:93288")
		# ...while the description it brought is kept, rather than the entry
		# holding a RomM id and no metadata.
		_eq("gamelist/while adopting the scraped description",
			str(games[0].get("desc", "")), "Mario in a dream world.")
		_eq("gamelist/and lists the rom once", (games[0].get("roms", []) as Array).size(), 1)

	# The other order: scraped first, downloaded second. This is the one that
	# used to leave rom_id_for answering 0 for a ROM that IS on the server.
	var gl2 := GamelistManager.new()
	gl2._gamelists[sysid] = {"games": []}
	gl2.add_or_merge_rom(sysid, {"game_id": "1248", "name": "Super Mario Bros. 2",
		"desc": "Mario in a dream world.", "developer": "", "publisher": "", "genre": ""},
		{"path": rom, "romname": rom.get_file()})
	gl2.add_or_merge_rom(sysid, {"game_id": "romm:93288", "name": "Super Mario Bros. 2",
		"desc": "", "developer": "", "publisher": "", "genre": ""},
		{"path": rom, "romname": rom.get_file()})
	var games2: Array = gl2._gamelists[sysid]["games"]
	_eq("gamelist/downloading a scraped rom does not add one either", games2.size(), 1)
	if games2.size() == 1:
		_eq("gamelist/and upgrades it to the RomM id",
			str(games2[0].get("game_id", "")), "romm:93288")
		# The download must not wipe what the scrape wrote — the downloader
		# sends desc "" and would otherwise blank it.
		_eq("gamelist/without erasing the description",
			str(games2[0].get("desc", "")), "Mario in a dream world.")

	# Two different games still get two entries. The merge keys on the ROM, so a
	# rule that folded these together would be far worse than the bug.
	gl2.add_or_merge_rom(sysid, {"game_id": "1246", "name": "Super Mario Bros. 3",
		"desc": "", "developer": "", "publisher": "", "genre": ""},
		{"path": "./Super Mario Bros. 3 (USA).nes", "romname": "Super Mario Bros. 3 (USA).nes"})
	_eq("gamelist/a different rom is still its own entry",
		(gl2._gamelists[sysid]["games"] as Array).size(), 2)

	# A second regional copy of the SAME game joins its entry rather than
	# starting a new one — that is what the game_id match is still there for.
	gl2.add_or_merge_rom(sysid, {"game_id": "romm:93288", "name": "Super Mario Bros. 2",
		"desc": "", "developer": "", "publisher": "", "genre": ""},
		{"path": "./Super Mario Bros. 2 (Europe).nes", "romname": "smb2eu.nes"})
	var smb2: Dictionary = gl2._gamelists[sysid]["games"][0]
	_eq("gamelist/another region joins the same game",
		(smb2.get("roms", []) as Array).size(), 2)
	gl._gamelists.clear()
	gl2._gamelists.clear()


## Repairing a list that is already split, which every existing install has.
func _test_gamelist_dedupe() -> void:
	var sysid := TEST_SYSTEM
	var gl := GamelistManager.new()
	# Exactly the shape found in the real nes/gamelist.json: a romm entry and a
	# scraper entry for one file, plus one entry listing the same ROM twice
	# under two spellings.
	gl._gamelists[sysid] = {"games": [
		{"game_id": "romm:90988", "name": "1943 (USA)", "desc": "",
		 "roms": [{"path": "./1943.nes", "preferred": true}]},
		{"game_id": "1468", "name": "1943", "desc": "Shoot em up",
		 "roms": [{"path": "./1943.nes"}]},
		{"game_id": "1248", "name": "Super Mario Bros. 2", "desc": "Dream world",
		 "roms": [{"path": "./smb2.nes", "preferred": true}, {"path": "./SMB2.NES"}]},
	]}
	var folded := gl.dedupe(sysid)
	var games: Array = gl._gamelists[sysid]["games"]
	_eq("dedupe/the split pair became one", folded, 1)
	_eq("dedupe/leaving two games", games.size(), 2)
	_eq("dedupe/under the RomM id", str(games[0].get("game_id", "")), "romm:90988")
	_eq("dedupe/keeping the scraped description",
		str(games[0].get("desc", "")), "Shoot em up")
	_eq("dedupe/and one rom", (games[0].get("roms", []) as Array).size(), 1)
	if OS.get_name() in ["Windows", "macOS"]:
		# Same file, two spellings — one row.
		_eq("dedupe/a case-variant duplicate rom is dropped",
			(games[1].get("roms", []) as Array).size(), 1)
		_ok("dedupe/and the kept one is still preferred",
			bool((games[1].get("roms", [])[0] as Dictionary).get("preferred", false)))
	else:
		# Two genuinely different files on a case-sensitive filesystem.
		_eq("dedupe/case-distinct roms are left alone",
			(games[1].get("roms", []) as Array).size(), 2)

	# Idempotent: running it again changes nothing.
	_eq("dedupe/a clean list folds nothing", gl.dedupe(sysid), 0)
	gl._gamelists.clear()


## Matching a hand-copied ROM to the server's copy by content hash.
##
## This is the regression record for the bug that made state backup look absent:
## gamelist.json only carries a "romm:" id for a ROM DOWNLOADED from RomM, a
## hand-copied one carries a scraper id that looks similar and means something
## else, so rom_id_for answered 0 and everything keyed on it silently did nothing
## — while the server held the very same game.
func _test_rom_id_resolve() -> void:
	var sync := RommSaveSync.new()
	add_child(sync)
	var dir := CoreDownloadManager.default_core_root().path_join("temp")
	DirAccess.make_dir_recursive_absolute(dir)
	var rom := dir.path_join("__resolve_selftest.nes")
	var f := FileAccess.open(rom, FileAccess.WRITE)
	f.store_string("cartridge bytes")
	f.close()

	_eq("resolve/never asked reads as unknown", sync.resolved_rom_id("nes", rom), -1)

	# Which HTTP outcomes count as the server having ANSWERED. A 404 does — it
	# is how by-hash says "not in the library" — and everything that went wrong
	# on the way does not, or a server that was briefly down would permanently
	# mark half the shelf as unavailable.
	_ok("resolve/a 200 is an answer",
		RommSaveSync.is_hash_answer(RommHttp.Result.OK, 200))
	_ok("resolve/a 404 is an answer too",
		RommSaveSync.is_hash_answer(RommHttp.Result.HTTP_ERROR, 404))
	_ok("resolve/a timeout is not",
		not RommSaveSync.is_hash_answer(RommHttp.Result.TIMED_OUT, 0))
	_ok("resolve/nor a dropped connection",
		not RommSaveSync.is_hash_answer(RommHttp.Result.REQUEST_FAILED, 0))
	_ok("resolve/nor a server error",
		not RommSaveSync.is_hash_answer(RommHttp.Result.HTTP_ERROR, 500))
	_ok("resolve/nor being signed out",
		not RommSaveSync.is_hash_answer(RommHttp.Result.HTTP_ERROR, 401))

	# A real answer is recorded, and rom_id_for starts answering for it — that is
	# what lets the flush path use it without ever hashing anything itself.
	sync._id_done("nes", rom, 93288, true)
	_eq("resolve/a hit is remembered", sync.resolved_rom_id("nes", rom), 93288)
	_eq("resolve/and rom_id_for adopts it", sync.rom_id_for("nes", rom), 93288)

	# A 404 IS an answer — it is how by-hash says "not in the library" — and it
	# costs the server the same full search a hit does. Not caching it meant
	# every homebrew re-searched from scratch on every panel open, measured at
	# 78 s a time.
	var other := dir.path_join("__resolve_selftest2.nes")
	var f2 := FileAccess.open(other, FileAccess.WRITE)
	f2.store_string("homebrew")
	f2.close()
	sync._id_done("nes", other, 0, true)
	_eq("resolve/a miss is remembered too", sync.resolved_rom_id("nes", other), 0)

	# A lookup that died on the network must NOT be remembered: caching that as
	# "RomM does not have this game" would be permanent, and wrong the moment
	# the server came back.
	var third := dir.path_join("__resolve_selftest3.nes")
	var f3 := FileAccess.open(third, FileAccess.WRITE)
	f3.store_string("unreachable")
	f3.close()
	sync._id_done("nes", third, 0, false)
	_eq("resolve/an unanswered lookup is not remembered",
		sync.resolved_rom_id("nes", third), -1)

	# A file replaced under the same name is a different ROM. Answering for the
	# old one would attach this game's saves to another game on the server.
	await get_tree().create_timer(1.2).timeout
	var f4 := FileAccess.open(rom, FileAccess.WRITE)
	f4.store_string("a completely different dump, different length")
	f4.close()
	_eq("resolve/a replaced file invalidates its answer",
		sync.resolved_rom_id("nes", rom), -1)

	# The answer must never arrive synchronously. Half of them come off a worker
	# and half straight out of the cache, and a caller that connects the signal
	# after calling — which reads perfectly naturally — would miss only the fast
	# ones. That trap cost a probe run before it was closed.
	sync._id_done("nes", other, 0, true)
	var seen: Array = []
	sync.resolve_rom_id("nes", other)
	_ok("resolve/a cached answer does not fire before the caller can listen",
		seen.is_empty())
	sync.rom_id_resolved.connect(func(_s: String, p: String, i: int) -> void:
		seen.append([p, i]))
	var spins := 0
	while seen.is_empty() and spins < 60:
		await get_tree().process_frame
		spins += 1
	_ok("resolve/but it does arrive", not seen.is_empty())

	for p: String in [rom, other, third]:
		DirAccess.remove_absolute(p)
	sync.queue_free()


## The multipart boundary a request declared, or "".
func _boundary_of(req: String) -> String:
	var at := req.find("boundary=")
	if at < 0:
		return ""
	var rest := req.substr(at + 9)
	var end := rest.find("\r")
	return rest.left(end) if end > 0 else rest


## Bytes after the blank line that ends the headers.
func _body_len(req: String) -> int:
	var at := req.find("\r\n\r\n")
	return req.length() - at - 4 if at >= 0 else -1


## What the Content-Length header claimed.
func _declared_len(req: String) -> int:
	var at := req.find("Content-Length: ")
	if at < 0:
		return -2
	var rest := req.substr(at + 16)
	var end := rest.find("\r")
	return int(rest.left(end) if end > 0 else rest)


# ---------------------------------------------------------------------------
# RommHttp.describe_error — the one place a failed RomM request is put into
# words. It used to be four copies, and nothing asserted any of them, so a
# reworded branch could go out without a single test noticing.
# ---------------------------------------------------------------------------

func _test_error_vocabulary() -> void:
	var D: Callable = RommHttp.describe_error
	var HTTP: int = RommHttp.Result.HTTP_ERROR

	_eq("errors/a dead connection", D.call(RommHttp.Result.CONNECT_FAILED, 0),
		"Connection lost")
	_eq("errors/a refused request reads the same as a dead one",
		D.call(RommHttp.Result.REQUEST_FAILED, 0), "Connection lost")
	_eq("errors/a silent server", D.call(RommHttp.Result.TIMED_OUT, 0),
		"The server took too long to answer")
	_eq("errors/a full disk", D.call(RommHttp.Result.WRITE_FAILED, 0),
		"Not enough space, or the disk is unwritable")
	_eq("errors/the player cancelled", D.call(RommHttp.Result.ABORTED, 0), "Cancelled")

	# The transport result wins over the code: a cancelled transfer often carries
	# whatever status had already come back, and reporting that would be a lie.
	_eq("errors/a transport failure outranks any status code",
		D.call(RommHttp.Result.ABORTED, 500), "Cancelled")

	_eq("errors/an expired token", D.call(HTTP, 401), "Sign in to RomM again")
	_eq("errors/and a forbidden one says the same by default",
		D.call(HTTP, 403), "Sign in to RomM again")
	_eq("errors/a deleted item", D.call(HTTP, 404), "No longer on the server")
	_eq("errors/a server fault names the code", D.call(HTTP, 503),
		"Server error (503)")
	_eq("errors/anything else falls through with its code",
		D.call(HTTP, 418), "RomM refused the request (418)")

	# Both overrides. The upload wording is the reason this is a parameter and
	# not a fifth copy: a QR-paired token with no write access will never be able
	# to upload, so "sign in again" would send that player round a loop.
	var upload := "RomM will not accept uploads from this device — its sign-in has no write access"
	_eq("errors/an upload endpoint can say why a 403 is permanent",
		D.call(HTTP, 403, upload), upload)
	_eq("errors/and a download endpoint can name itself",
		D.call(HTTP, 400, "Sign in to RomM again", "Server refused the download (%d)"),
		"Server refused the download (400)")
	_eq("errors/an override does not leak into the other branches",
		D.call(HTTP, 404, upload), "No longer on the server")


# ---------------------------------------------------------------------------
# Ghost rows — a RomM record whose file the server has lost.
#
# The shipped bug: extracting archives on the server left RomM holding a row for
# each .7z it no longer had, beside a new row for the .ndd it produced. Half a
# 64DD platform was those. They 404 at the web server rather than at the API,
# and neither refresh could clear them — a delta merge only adds and overwrites,
# and a full sync re-fetched them because RomM still lists them.
# ---------------------------------------------------------------------------

func _test_ghost_rows() -> void:
	# --- what may enter the index --------------------------------------------
	_ok("ghost/a plain row is indexed",
		not RommCatalog.skips_item({"fs_name": "Game.z64", "id": 1}))
	_ok("ghost/a row the server lost is not",
		RommCatalog.skips_item({"fs_name": "Gone.7z", "id": 2, "missing_from_fs": true}))
	_ok("ghost/false is present, not missing",
		not RommCatalog.skips_item({"fs_name": "Game.z64", "missing_from_fs": false}))
	# RomM sends nulls for plenty of fields, and a null must not read as gone —
	# that would empty the index against any server that omits the flag.
	_ok("ghost/null is not missing",
		not RommCatalog.skips_item({"fs_name": "Game.z64", "missing_from_fs": null}))
	_ok("ghost/dot-directories still skipped",
		RommCatalog.skips_item({"fs_name": ".media", "id": 3}))

	# --- the query asks the server to leave them out --------------------------
	var cat := RommCatalog.new()
	var path := cat._page_path(143, 0, "", true, 1000)
	_ok("ghost/the page query excludes missing rows", path.contains("&missing=false"), path)

	# --- reading a page of the deletion sweep ---------------------------------
	var good := RommCatalog.missing_ids_in_page([
		{"id": 80159, "missing_from_fs": true},
		{"id": 80161, "missing_from_fs": true},
		{"id": 0, "missing_from_fs": true},     # no id to act on
	])
	_ok("ghost/a page of lost rows is trusted", bool(good["trusted"]))
	_eq("ghost/and yields their ids", Array(good["ids"] as PackedInt32Array), [80159, 80161])

	# The load-bearing one. A server too old for the `missing` filter ignores it
	# and answers with the whole platform; acting on that would delete every row
	# the player has. One unflagged row condemns the page.
	var stale := RommCatalog.missing_ids_in_page([
		{"id": 80159, "missing_from_fs": true},
		{"id": 80160, "missing_from_fs": false},
	])
	_ok("ghost/a page holding a present row is not trusted", not bool(stale["trusted"]))
	_eq("ghost/and yields nothing at all", (stale["ids"] as PackedInt32Array).size(), 0)

	# --- who survives the sweep ----------------------------------------------
	var lines := {80159: "a", 80160: "b", 80171: "c"}
	# 80171 is already downloaded. Its file is still a playable game whatever the
	# server has lost, and the browser hides cache-owned files that have no index
	# row — so removing it would take the player's own copy out of the list.
	var went := RommCatalog.drop_ghosts(lines, PackedInt32Array([80159, 80171]),
		PackedInt64Array([80171]))
	_eq("ghost/only the undownloaded ghost goes", went, 1)
	_ok("ghost/the ghost is gone", not lines.has(80159), str(lines.keys()))
	_ok("ghost/a downloaded ghost is kept", lines.has(80171), str(lines.keys()))
	_ok("ghost/an untouched row is untouched", lines.has(80160), str(lines.keys()))

	var none := {80159: "a"}
	_eq("ghost/an empty sweep removes nothing",
		RommCatalog.drop_ghosts(none, PackedInt32Array(), PackedInt64Array()), 0)
	_eq("ghost/and leaves the index alone", none.size(), 1)

	cat.free()


# ---------------------------------------------------------------------------
# Rewriting an index in place. The jsonl and its six sidecars are read by
# OFFSET, so one of them left a row out of step from the others does not fail —
# it shows the wrong game for every row after the join.
# ---------------------------------------------------------------------------

func _test_index_rewrite() -> void:
	var dir := RommCatalog.index_dir(TEST_SYSTEM)
	_rm_rf(dir)
	DirAccess.make_dir_recursive_absolute(dir)

	var cat := RommCatalog.new()
	var lines := {
		11: JSON.stringify({"id": 11, "name": "Alpha", "sort_name": "alpha",
			"fs_name": "Alpha.z64", "regions": ["USA"]}),
		22: JSON.stringify({"id": 22, "name": "Beta", "sort_name": "beta",
			"fs_name": "Beta.7z", "regions": ["Japan"]}),
		33: JSON.stringify({"id": 33, "name": "Gamma", "sort_name": "gamma",
			"fs_name": "Gamma.ndd", "regions": []}),
	}
	var written := RommCatalog._write_index(dir, RommCatalog._rows_from_lines(lines))
	_eq("rewrite/three rows written", str(written["error"]), "")
	_eq("rewrite/total counted", int(written["total"]), 3)
	RommCatalog._write_text(RommCatalog.meta_path(TEST_SYSTEM), JSON.stringify({
		"total": 3, "shown": 3, "updated_after": "2026-08-26T22:43:21+00:00",
		"group_by_meta_id": false, "platform_id": 143,
	}, "\t"))

	_eq("rewrite/removing an absent id changes nothing",
		cat.remove_rows(TEST_SYSTEM, [999]), 0)

	# The row dropped is the MIDDLE one, so a sidecar left unrewritten still has
	# the right length and the wrong contents.
	_eq("rewrite/one row removed", cat.remove_rows(TEST_SYSTEM, [22]), 1)

	_ok("rewrite/index still loads", cat.load_index(TEST_SYSTEM))
	_eq("rewrite/two rows left", cat.count(), 2)
	_eq("rewrite/ids in order", [cat.rom_id_at(0), cat.rom_id_at(1)], [11, 33])
	_eq("rewrite/names follow the ids", [cat.name_at(0), cat.name_at(1)], ["Alpha", "Gamma"])
	_eq("rewrite/fs sidecar follows too",
		[cat.fs_basename_at(0), cat.fs_basename_at(1)], ["alpha", "gamma"])
	_eq("rewrite/extensions follow", [cat.fs_ext_at(0), cat.fs_ext_at(1)], ["z64", "ndd"])
	_eq("rewrite/regions follow", Array(cat.regions_at(0)), ["USA"])
	# The offsets sidecar is the one that silently shows the wrong game.
	_eq("rewrite/row 1 seeks to its own line", str(cat.row(1).get("name", "")), "Gamma")
	_eq("rewrite/the removed row is unsearchable", Array(cat.search("Beta")), [])
	_eq("rewrite/a survivor is still searchable", Array(cat.search("Gamma")), [1])

	var meta := RommCatalog.read_meta(TEST_SYSTEM)
	_eq("rewrite/meta total follows", int(meta.get("total", -1)), 2)
	# The watermark belongs to the sync. A rewrite that reset it would make the
	# next delta re-fetch the whole platform.
	_eq("rewrite/meta watermark preserved",
		str(meta.get("updated_after", "")), "2026-08-26T22:43:21+00:00")
	_eq("rewrite/meta platform preserved", int(meta.get("platform_id", 0)), 143)

	cat.unload_index()
	cat.free()
	_rm_rf(dir)
