## RA — the RetroAchievements session, as an autoload.
##
## An autoload for the same reason SaveSync is one: the cabinet that runs the game
## and the menu that offers the sign-in are unrelated nodes with no shared parent,
## and both need this. It owns the config, the HTTP bridge and the badge cache,
## and re-emits the extension's signals so nothing else has to know the singleton
## exists.
##
## The achievement runtime itself lives in the GDExtension — evaluating a set of
## conditions against console RAM every frame is not something GDScript can do.
## This script is the sign-in, the settings and the notification routing.
extends Node

signal login_changed(logged_in: bool, display_name: String, error: String)
## Fired for the cabinet that owns the session, so it can raise a toast.
signal achievement_unlocked(id: int, title: String, description: String, points: int, badge: Texture2D)
signal game_loaded(ok: bool, title: String, num_achievements: int, num_unlocked: int, error: String)
signal connection_changed(connected: bool)

const BADGE_CACHE_DIR := "user://ra_badges"

var config: RaConfig = null

var _bridge: RaHttpBridge = null
## The RetroSystem currently holding the session, or null. Weak by intent — it is
## only ever compared and cleared, never used to keep the cabinet alive.
var _session_owner: Node = null
var _busy_signing_in := false
## handle -> the callback waiting on that browse lookup. Keyed because several
## rows can ask at once and the answers come back in whatever order they finish.
var _lookups: Dictionary = {}
var _badge_cache: Dictionary = {}


func _ready() -> void:
	config = RaConfig.new()
	config.load_config()

	var ra: Object = _ra()
	if ra == null:
		# No extension (headless editor, or a build where it failed to load).
		# Everything below degrades to "achievements are unavailable".
		return

	_bridge = RaHttpBridge.new()
	_bridge.name = "RaHttpBridge"
	add_child(_bridge)

	ra.connect("ra_login_result", _on_login_result)
	ra.connect("ra_game_loaded", _on_game_loaded)
	ra.connect("ra_achievement_triggered", _on_achievement_triggered)
	ra.connect("ra_connection_changed", _on_connection_changed)
	ra.connect("ra_server_error", _on_server_error)

	DirAccess.make_dir_recursive_absolute(BADGE_CACHE_DIR)

	if config.enabled:
		ra.SetEnabled(true)
		_bridge.apply_user_agent()
		# A stored token signs in silently. This is the ordinary startup path —
		# the password was traded for this token at the last sign-in and never
		# written to disk.
		if config.is_configured():
			ra.LoginWithToken(config.username, config.token)


static func _ra() -> Object:
	return Engine.get_singleton("RetroAchievements") if \
		Engine.has_singleton("RetroAchievements") else null


func is_available() -> bool:
	return _ra() != null


func is_logged_in() -> bool:
	var ra: Object = _ra()
	return ra != null and ra.IsLoggedIn()


func user_info() -> Dictionary:
	var ra: Object = _ra()
	return ra.GetUserInfo() if ra != null else {}


func game_info() -> Dictionary:
	var ra: Object = _ra()
	return ra.GetGameInfo() if ra != null else {}


## Deliberately a bare Array, unlike the other list-returning functions here.
##
## The rows come straight out of the GDExtension, which hands back an untyped
## Array — declaring Array[Dictionary] would mean an .assign() copy on every
## call, and would turn a row of an unexpected shape into a runtime error inside
## whichever panel is drawing rather than a row that renders oddly.
func achievements() -> Array:
	var ra: Object = _ra()
	return ra.GetAchievements() if ra != null else []


func rich_presence() -> String:
	var ra: Object = _ra()
	return ra.GetRichPresence() if ra != null else ""


## A game's achievements WITHOUT running it, delivered to
## `callback(ok, info: Dictionary)` on the main thread.
##
## `info` carries game_id, title, badge_url, achievements (id, title,
## description, points, type, rarity, badge_url, badge_locked_url, unlocked) and
## error. game_id 0 with ok true means RetroAchievements does not know this ROM —
## which is an answer, not a failure.
##
## Nothing here starts a session: the console's own hash rules are applied
## locally and only the lookup calls go out, so this can be asked while another
## game is running without disturbing it.
func lookup_achievements(systemid: String, rom_path: String, callback: Callable) -> void:
	var ra: Object = _ra()
	var console_id := RaConsoles.for_systemid(systemid)
	if ra == null or console_id <= 0 or not is_logged_in():
		callback.call(false, {"error": "Sign in to RetroAchievements to see achievements."})
		return
	if not ra.has_method("LookupAchievements"):
		# An older extension binary against newer scripts — say so rather than
		# failing with "method not found" three frames later.
		callback.call(false, {"error": "This build cannot look achievements up yet."})
		return

	var handle: int = ra.LookupAchievements(console_id, rom_path)
	if handle <= 0:
		callback.call(false, {"error": "Could not read this ROM to identify it."})
		return
	_lookups[handle] = callback
	if not ra.is_connected("ra_lookup_result", _on_lookup_result):
		ra.connect("ra_lookup_result", _on_lookup_result)


func _on_lookup_result(handle: int, ok: bool, game_id: int, title: String,
					   badge_url: String, achievements_in: Array, error: String) -> void:
	if not _lookups.has(handle):
		return
	var callback: Callable = _lookups[handle]
	_lookups.erase(handle)
	if callback.is_valid():
		callback.call(ok, {
			"game_id": game_id,
			"title": title,
			"badge_url": badge_url,
			"achievements": achievements_in,
			"error": error,
		})


## Flip the master switch. Disabling destroys the client and drops the session.
func set_enabled(enabled: bool) -> void:
	config.enabled = enabled
	config.save_config()

	var ra: Object = _ra()
	if ra == null:
		return
	ra.SetEnabled(enabled)
	if enabled:
		if _bridge != null:
			_bridge.apply_user_agent()
		if config.is_configured():
			ra.LoginWithToken(config.username, config.token)
	else:
		_session_owner = null
		login_changed.emit(false, "", "")


## Sign in with a password. The password is passed straight through to rcheevos
## and never stored — the token that comes back is what gets written.
func sign_in_with_password(username: String, password: String) -> void:
	var ra: Object = _ra()
	if ra == null or _busy_signing_in:
		return
	_busy_signing_in = true
	config.username = username.strip_edges()
	config.auth_mode = RaConfig.AUTH_PASSWORD
	config.save_config()
	if not config.enabled:
		set_enabled(true)
	ra.LoginWithPassword(config.username, password)


## Sign in with a connect token the player already has.
func sign_in_with_token(username: String, token: String) -> void:
	var ra: Object = _ra()
	if ra == null or _busy_signing_in:
		return
	_busy_signing_in = true
	config.username = username.strip_edges()
	config.token = token.strip_edges()
	config.auth_mode = RaConfig.AUTH_TOKEN
	config.save_config()
	if not config.enabled:
		set_enabled(true)
	ra.LoginWithToken(config.username, config.token)


func sign_out() -> void:
	var ra: Object = _ra()
	if ra != null:
		ra.Logout()
	config.token = ""
	config.save_config()
	_session_owner = null
	login_changed.emit(false, "", "")


## Ask to track the machine that is powering on. Returns false when another
## cabinet already holds the session, the system has no RetroAchievements
## console, or nobody is signed in — all of which mean "run without achievements".
func claim_session(claimant: Node, systemid: String, libretro: Object) -> bool:
	if libretro == null or not is_logged_in():
		return false
	var console_id := RaConsoles.for_systemid(systemid)
	if console_id <= 0:
		return false
	if not libretro.RaClaimSession(console_id):
		return false
	_session_owner = claimant
	return true


func release_session(claimant: Node) -> void:
	if _session_owner == claimant:
		_session_owner = null


func session_owner() -> Node:
	return _session_owner if is_instance_valid(_session_owner) else null


func _on_login_result(ok: bool, username: String, token: String, _score: int, error: String) -> void:
	_busy_signing_in = false

	if not ok:
		push_warning("[RA] sign-in failed: %s" % error)
		login_changed.emit(false, "", error)
		return

	# Persist the token so the next launch never needs the password again.
	config.username = username
	config.token = token
	config.save_config()

	var info := user_info()
	var display: String = str(info.get("display_name", username))
	print("[RA] signed in as %s" % display)
	login_changed.emit(true, display, "")


func _on_game_loaded(ok: bool, _game_id: int, title: String, _badge_url: String,
					 num_achievements: int, num_unlocked: int, error: String) -> void:
	if not ok:
		# Most often "no achievements for this ROM", which is ordinary, not a fault.
		print("[RA] no achievement set: %s" % error)
	else:
		print("[RA] %s — %d of %d unlocked" % [title, num_unlocked, num_achievements])
	game_loaded.emit(ok, title, num_achievements, num_unlocked, error)


func _on_achievement_triggered(id: int, title: String, description: String,
							   points: int, badge_url: String) -> void:
	if not config.show_notifications:
		return
	# Fetch the badge, then announce. The toast is worth the round trip — an
	# achievement popup without its badge is the one thing players notice.
	fetch_badge(badge_url, func(badge: Texture2D) -> void:
		achievement_unlocked.emit(id, title, description, points, badge)
	)


func _on_connection_changed(connected: bool) -> void:
	if connected:
		print("[RA] reconnected — queued unlocks delivered")
	else:
		push_warning("[RA] disconnected — unlocks are being queued")
	connection_changed.emit(connected)


func _on_server_error(api: String, message: String) -> void:
	push_warning("[RA] server error on %s: %s" % [api, message])


## Badges are small and immutable, so one disk copy per badge is all it takes.
## Public because the cartridge menu's Achievements ribbon fetches one per row;
## `done` is called with null when there is no badge to be had, so a caller can
## leave its slot empty rather than wait.
func fetch_badge(url: String, done: Callable) -> void:
	if url.is_empty():
		done.call(null)
		return

	if _badge_cache.has(url):
		done.call(_badge_cache[url])
		return

	var cached := BADGE_CACHE_DIR.path_join(url.get_file())
	if FileAccess.file_exists(cached):
		var image := Image.new()
		if image.load(cached) == OK:
			var texture := ImageTexture.create_from_image(image)
			_badge_cache[url] = texture
			done.call(texture)
			return

	var http := HTTPRequest.new()
	http.use_threads = true
	http.timeout = 15.0
	add_child(http)
	http.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			http.queue_free()
			if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
				done.call(null)
				return

			var image := Image.new()
			# Badges are PNG today; try both rather than trusting the extension.
			if image.load_png_from_buffer(body) != OK and image.load_jpg_from_buffer(body) != OK:
				done.call(null)
				return

			var bytes := FileAccess.open(cached, FileAccess.WRITE)
			if bytes:
				bytes.store_buffer(body)

			var texture := ImageTexture.create_from_image(image)
			_badge_cache[url] = texture
			done.call(texture)
	)
	if http.request(url) != OK:
		http.queue_free()
		done.call(null)
