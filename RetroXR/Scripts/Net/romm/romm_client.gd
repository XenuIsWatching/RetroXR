## RommClient — small one-shot calls against a RomM server (romm.app).
##
## Only endpoints with tiny responses live here; they use HTTPRequest nodes with
## use_threads = true, which is fine because the bodies are a few KB. The two
## heavy paths — catalog sync and ROM downloads — deliberately do NOT go through
## this class: they run on their own Thread with a blocking HTTPClient so a 3 MB
## JSON parse or a 4 GB transfer never lands on the main thread. See RommCatalog
## and RommDownloader.
##
## Must be in the scene tree (it creates HTTPRequest children).
class_name RommClient
extends Node


## Emitted when any request comes back 401/403 — the token was revoked or the
## password changed. Terminal: callers must not retry.
signal auth_failed(detail: String)

## Emitted when reachability changes, so the UI can toast once per transition
## instead of once per failed request.
signal reachability_changed(reachable: bool)

const REQUEST_TIMEOUT := 20.0

## Everything RetroXR asks the server to do, as RomM scope strings. A token we
## mint ourselves requests exactly this; a token minted elsewhere (pairing, the
## RomM UI, the DB) carries whatever it was given, which is why scopes have to
## be read back rather than assumed.
const WANTED_SCOPES := [
	"me.read",
	"roms.read", "roms.user.read", "roms.user.write",
	"platforms.read", "collections.read",
	"firmware.read",
	"assets.read", "assets.write",
]

## The one scope that decides whether saves and states can go up at all.
const SCOPE_UPLOAD := "assets.write"

## Emitted whenever the server's answer for the current credentials is read
## back. `scopes` is empty when the server would not say (see fetch_scopes).
signal scopes_refreshed(scopes: PackedStringArray)

var config: RommConfig = null

## null = unknown (nothing attempted yet).
var _reachable: Variant = null
## Server version string from the last heartbeat, e.g. "5.0.0".
var server_version: String = ""


func setup(cfg: RommConfig) -> void:
	config = cfg


# ---------------------------------------------------------------------------
# Public endpoints (no auth — verified: nginx serves these without a gate)
# ---------------------------------------------------------------------------

## GET /api/heartbeat — version + feature flags. Public.
## callback(ok: bool, data: Dictionary)
func heartbeat(callback: Callable) -> void:
	_get_json("/api/heartbeat", false, func(ok: bool, data: Variant, _code: int) -> void:
		var dict: Dictionary = data if data is Dictionary else {}
		if ok:
			var sys: Dictionary = dict.get("SYSTEM", {}) if dict.get("SYSTEM") is Dictionary else {}
			server_version = str(sys.get("VERSION", ""))
		callback.call(ok, dict)
	)


## GET /api/stats — {PLATFORMS, ROMS, SAVES, STATES, SCREENSHOTS,
## TOTAL_FILESIZE_BYTES}. Public, ~100 bytes: the cheap "did anything change?"
## poll that lets repeat menu opens skip /api/roms entirely.
## callback(ok: bool, stats: Dictionary)
func stats(callback: Callable) -> void:
	_get_json("/api/stats", false, func(ok: bool, data: Variant, _code: int) -> void:
		callback.call(ok, data if data is Dictionary else {})
	)


# ---------------------------------------------------------------------------
# Authenticated endpoints
# ---------------------------------------------------------------------------

## GET /api/platforms — bare array of PlatformSchema. Not paginated.
## callback(ok: bool, platforms: Array)
func platforms(callback: Callable) -> void:
	_get_json("/api/platforms", true, func(ok: bool, data: Variant, _code: int) -> void:
		callback.call(ok, data if data is Array else [])
	)


## GET /api/roms/{id} — DetailedRomSchema. Only for user-driven detail views;
## the list response already carries every metadata and artwork field, so never
## call this per row.
## callback(ok: bool, rom: Dictionary)
func rom_detail(rom_id: int, callback: Callable) -> void:
	_get_json("/api/roms/%d" % rom_id, true, func(ok: bool, data: Variant, _code: int) -> void:
		callback.call(ok, data if data is Dictionary else {})
	)


## GET /api/roms/by-hash — match a local file against the server library.
## callback(ok: bool, rom: Dictionary)
func rom_by_hash(md5: String, sha1: String, callback: Callable) -> void:
	var query := ""
	if not md5.is_empty():
		query = "?md5_hash=" + md5.to_lower().uri_encode()
	elif not sha1.is_empty():
		query = "?sha1_hash=" + sha1.to_lower().uri_encode()
	else:
		callback.call(false, {})
		return
	_get_json("/api/roms/by-hash" + query, true, func(ok: bool, data: Variant, _code: int) -> void:
		callback.call(ok, data if data is Dictionary else {})
	)


## GET /api/roms/identifiers — every visible rom id. Used to reconcile
## deletions, which `updated_after` cannot express.
## callback(ok: bool, ids: Array)
func rom_identifiers(callback: Callable) -> void:
	_get_json("/api/roms/identifiers", true, func(ok: bool, data: Variant, _code: int) -> void:
		callback.call(ok, data if data is Array else [])
	)


## Count only, without dragging down a page of items. `limit=0` is a 422 on
## RomM (minimum is 1), so ask for one row and read `total`.
##
## `with_rom_id_index=false` matters more here than anywhere: the server's index
## covers the whole result set, not the page, so without it a limit=1 count of
## PlayStation returns 349 KB for one row and takes ~94 s — parsed on the main
## thread, since this goes through HTTPRequest.
## callback(ok: bool, total: int)
func rom_count(platform_id: int, callback: Callable) -> void:
	var path := "/api/roms?limit=1&with_char_index=false&with_rom_id_index=false" \
		+ "&with_filter_values=false&with_files=false"
	if platform_id > 0:
		path += "&platform_ids=%d" % platform_id
	_get_json(path, true, func(ok: bool, data: Variant, _code: int) -> void:
		var dict: Dictionary = data if data is Dictionary else {}
		callback.call(ok, int(dict.get("total", 0)))
	)


# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------

## POST /api/client-tokens/exchange — trade an 8-digit pairing code shown on
## the RomM web UI for a long-lived client token. Unauthenticated: the code IS
## the credential, which is the whole point — typing 8 digits on a headset beats
## typing a 68-character token.
## callback(ok: bool, token: String, error: String)
func pair_with_code(code: String, callback: Callable) -> void:
	var body := JSON.stringify({"code": code.strip_edges()})
	_post_json("/api/client-tokens/exchange", false, body,
		func(ok: bool, data: Variant, code_num: int) -> void:
			var dict: Dictionary = data if data is Dictionary else {}
			if not ok:
				callback.call(false, "", _describe_http(code_num, "Pairing failed"))
				return
			var raw := str(dict.get("raw_token", ""))
			if raw.is_empty():
				callback.call(false, "", "Server returned no token")
				return
			callback.call(true, raw, "")
	)


## POST /api/client-tokens using the configured username/password, so a user who
## signed in with a password can convert to a scoped, revocable token and stop
## storing the password on the device.
## callback(ok: bool, token: String, error: String)
func mint_token_from_basic(callback: Callable) -> void:
	if config == null or config.username.is_empty():
		callback.call(false, "", "No username configured")
		return
	var body := JSON.stringify({
		"name": "RetroXR (%s)" % OS.get_name(),
		"scopes": WANTED_SCOPES,
	})
	var header := "Authorization: Basic " + Marshalls.utf8_to_base64(config.username + ":" + config.password)
	_request_json("/api/client-tokens", HTTPClient.METHOD_POST, body,
		PackedStringArray([header, "Content-Type: application/json"]),
		func(ok: bool, data: Variant, code_num: int) -> void:
			var dict: Dictionary = data if data is Dictionary else {}
			if not ok:
				callback.call(false, "", _describe_http(code_num, "Could not create token"))
				return
			callback.call(true, str(dict.get("raw_token", "")), "")
	)


## GET /api/users/me — read the scopes the server currently grants these
## credentials, and cache them on the config.
##
## Scopes are editable server-side (today only in RomM's DB), so a token that
## could not upload yesterday may be able to today with no change on this
## device. Nothing here can be inferred from the token itself; the server is the
## only authority, and this is the call that asks it.
##
## A 403 here is NOT a bad token — it is a token without `me.read`, which is a
## perfectly good read-only token. So this call is deliberately quiet: it does
## not emit auth_failed, and it reports scopes as UNKNOWN (empty) rather than as
## "no permissions", because refusing to upload on the strength of a question
## the server declined to answer would break users who work fine today.
## callback(ok: bool, scopes: PackedStringArray)
func fetch_scopes(callback: Callable = Callable()) -> void:
	var headers := config.auth_headers() if config != null else PackedStringArray()
	if headers.is_empty():
		_store_scopes(PackedStringArray())
		if callback.is_valid():
			callback.call(false, PackedStringArray())
		return
	_request_json("/api/users/me", HTTPClient.METHOD_GET, "", headers,
		func(ok: bool, data: Variant, _code: int) -> void:
			var dict: Dictionary = data if data is Dictionary else {}
			var found := PackedStringArray()
			if ok and dict.get("oauth_scopes") is Array:
				for sc: Variant in dict["oauth_scopes"]:
					found.append(str(sc))
			_store_scopes(found)
			if callback.is_valid():
				callback.call(ok, found)
	, true)


func _store_scopes(scopes: PackedStringArray) -> void:
	if config != null:
		config.set_scopes(scopes)
		config.save_config()
	scopes_refreshed.emit(scopes)


## Heartbeat + one authenticated call, so the user learns in one tap whether the
## URL is right AND whether the credentials work — they fail very differently.
## callback(ok: bool, summary: String)
func test_connection(callback: Callable) -> void:
	if config == null or config.base_url.is_empty():
		callback.call(false, "No server URL set")
		return
	heartbeat(func(hb_ok: bool, hb: Dictionary) -> void:
		if not hb_ok:
			callback.call(false, "Cannot reach %s" % config.base_url)
			return
		var sys: Dictionary = hb.get("SYSTEM", {}) if hb.get("SYSTEM") is Dictionary else {}
		var version := str(sys.get("VERSION", "?"))
		# Count from /api/platforms rather than an unfiltered /api/roms: with no
		# platform_ids, RomM's default grouping collapses the result to a
		# fraction of the library (141 of 1411 on the test server), which would
		# report a wildly wrong number here. Summing rom_count also proves auth
		# works and gives us the platform list we need anyway.
		platforms(func(ok: bool, plats: Array) -> void:
			if not ok:
				callback.call(false, "RomM %s reached, but sign-in failed" % version)
				return
			var total := 0
			for p: Dictionary in plats:
				total += int(p.get("rom_count", 0))
			var summary := "RomM %s · %s games across %d platform%s" % [
				version, _thousands(total), plats.size(),
				"" if plats.size() == 1 else "s"]
			# Scopes last, so a server that will not answer /api/users/me still
			# gets the full connection result rather than a failed test.
			fetch_scopes(func(_sc_ok: bool, _scopes: PackedStringArray) -> void:
				if config != null and config.knows_scopes() and not config.can_upload():
					summary += " · uploads not permitted by this token"
				callback.call(true, summary)
			)
		)
	)


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _get_json(path: String, authed: bool, callback: Callable) -> void:
	var headers := config.auth_headers() if (authed and config != null) else PackedStringArray()
	if authed and headers.is_empty():
		# Not signed in at all. Surface this the same way a rejected token does —
		# to a caller, "no credentials" and "bad credentials" are the same
		# problem, and silently returning false is indistinguishable from the
		# server being down.
		auth_failed.emit("No RomM credentials configured")
		callback.call(false, null, 0)
		return
	_request_json(path, HTTPClient.METHOD_GET, "", headers, callback)


func _post_json(path: String, authed: bool, body: String, callback: Callable) -> void:
	var headers := PackedStringArray(["Content-Type: application/json"])
	if authed and config != null:
		var h := config.auth_header()
		if h.is_empty():
			auth_failed.emit("No RomM credentials configured")
			callback.call(false, null, 0)
			return
		headers.append(h)
	_request_json(path, HTTPClient.METHOD_POST, body, headers, callback)


## `quiet_auth` suppresses the auth_failed emit on 401/403. Only for calls where
## a refusal is an expected answer about PERMISSIONS rather than evidence of a
## bad credential — fetch_scopes is the whole reason it exists.
## callback(ok: bool, parsed: Variant, response_code: int)
func _request_json(path: String, method: int, body: String,
				   headers: PackedStringArray, callback: Callable,
				   quiet_auth: bool = false) -> void:
	if config == null or config.base_url.is_empty():
		callback.call(false, null, 0)
		return

	var http := HTTPRequest.new()
	http.use_threads = true
	http.timeout = REQUEST_TIMEOUT
	add_child(http)

	http.request_completed.connect(
		func(result: int, response_code: int, _rh: PackedStringArray, raw: PackedByteArray) -> void:
			http.queue_free()

			if result != HTTPRequest.RESULT_SUCCESS:
				_set_reachable(false)
				push_warning("[RommClient] %s failed (result %d)" % [path, result])
				callback.call(false, null, 0)
				return

			_set_reachable(true)

			# 401/403 are terminal — a revoked token looks identical to a network
			# error at the transport layer and completely different to the user.
			if response_code == 401 or response_code == 403:
				if not quiet_auth:
					auth_failed.emit("HTTP %d on %s" % [response_code, path])
				callback.call(false, null, response_code)
				return

			if response_code < 200 or response_code >= 300:
				push_warning("[RommClient] %s -> HTTP %d" % [path, response_code])
				callback.call(false, null, response_code)
				return

			var json := JSON.new()
			if json.parse(raw.get_string_from_utf8()) != OK:
				push_warning("[RommClient] %s: bad JSON (%s)" % [path, json.get_error_message()])
				callback.call(false, null, response_code)
				return

			callback.call(true, json.data, response_code)
	)

	var err := http.request(config.base_url + path, headers, method, body)
	if err != OK:
		http.queue_free()
		push_warning("[RommClient] could not start request %s (err %d)" % [path, err])
		_set_reachable(false)
		callback.call(false, null, 0)


## Only emit on a transition, so a dead server doesn't produce a toast stream.
func _set_reachable(now: bool) -> void:
	if _reachable != null and bool(_reachable) == now:
		return
	_reachable = now
	reachability_changed.emit(now)


## Unknown counts as reachable. Nothing has asked the server yet at that point,
## and painting a whole cached catalogue as dead on the strength of no evidence
## is worse than painting it live and correcting on the first failed request.
func is_reachable() -> bool:
	return _reachable == null or bool(_reachable)


static func _describe_http(code: int, fallback: String) -> String:
	match code:
		0:   return "Could not reach the server"
		400: return "Invalid or expired code"
		401, 403: return "Not authorised"
		404: return "Not found on this server"
		422: return "Server rejected the request"
	if code >= 500:
		return "Server error (%d)" % code
	return fallback


static func _thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	var count := 0
	for i in range(s.length() - 1, -1, -1):
		out = s[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return out
