## ra_tests — the pure-logic half of the RetroAchievements layer.
##
## This layer handles a credential and talks to a remote server, and had zero
## test references. What is asserted here is the half that needs neither: the
## console id mapping, the config file's round trip and its refusals, and the
## user-agent string. A live sign-in stays out of the suites for the same reason
## a real core does.
##
## It writes the player's REAL ra_config.json — the path is a static on RaConfig
## and cannot be pointed elsewhere — so the file is snapshotted up front and
## restored byte-for-byte at the end, including the case where there was no file
## to begin with.
##
##   "$godot" --headless --path RetroXR res://Tests/ra_tests.tscn
##   "$godot" --headless --path RetroXR res://Tests/ra_tests.tscn -- --only=config
extends Node

var _passed := 0
var _failed := 0
var _only := ""

## The player's own config, put back exactly as found. `_had_config` false means
## there was no file, and the right restore is to delete ours rather than leave
## an empty one where the app would read defaults.
var _saved_config := ""
var _had_config := false


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			_only = arg.substr("--only=".length())
	# Restore BEFORE quitting: this suite writes the player's real ra_config.json,
	# and a suite that dies on its watchdog would otherwise leave the test
	# credentials sitting in it.
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		push_error("[ra] TIMEOUT")
		_restore()
		get_tree().quit(1))

	_snapshot()
	_group_consoles()
	_group_config()
	_group_agent()
	_restore()

	print("[ra] %d checks, %d failed" % [_passed + _failed, _failed])
	print("[ra] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


# ── Harness ───────────────────────────────────────────────────────────────────

func _ok(cond: bool, what: String, detail := "") -> void:
	if not (_only.is_empty() or what.begins_with(_only)):
		return
	if cond:
		_passed += 1
		print("[ra] ok   %s" % what)
	else:
		_failed += 1
		print("[ra] FAIL %s%s" % [what, "" if detail.is_empty() else "  -- " + detail])


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what, "got %s, want %s" % [got, want])


func _snapshot() -> void:
	var path := RaConfig.config_path()
	_had_config = FileAccess.file_exists(path)
	if _had_config:
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			_saved_config = f.get_as_text()


func _restore() -> void:
	var path := RaConfig.config_path()
	if not _had_config:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(path)
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(_saved_config)
		f.close()


func _write_raw(text: String) -> void:
	var path := RaConfig.config_path()
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()


func _read_raw() -> String:
	var f := FileAccess.open(RaConfig.config_path(), FileAccess.READ)
	return f.get_as_text() if f != null else ""


# ── consoles/ — the systemid to RC_CONSOLE_* mapping ──────────────────────────

func _group_consoles() -> void:
	_eq(RaConsoles.for_systemid("nes"), 7, "consoles/a mapped system resolves")
	_eq(RaConsoles.for_systemid("super_nes"), 3, "consoles/and so does another")
	_eq(RaConsoles.for_systemid(""), 0, "consoles/an empty systemid is not a console")
	_eq(RaConsoles.for_systemid("no_such_machine"), 0,
		"consoles/an unknown systemid is not a console")

	_ok(RaConsoles.is_supported("nes"), "consoles/a mapped system is supported")
	_ok(not RaConsoles.is_supported("no_such_machine"),
		"consoles/an unknown system is not supported")
	_ok(not RaConsoles.is_supported(""), "consoles/nor is an empty one")

	# is_supported is defined as "for_systemid > 0", so the two must never
	# disagree — a row mapped to 0 would read as present and be unusable.
	var disagreed: Array = []
	for sid: String in RaConsoles.CONSOLE_MAP:
		if RaConsoles.is_supported(sid) != (RaConsoles.for_systemid(sid) > 0):
			disagreed.append(sid)
	_eq(disagreed, [], "consoles/every mapped system agrees with is_supported")

	# No row may map to 0: that is the value meaning "not a console", so a row
	# carrying it is indistinguishable from an absent one and is a typo.
	var zeroed: Array = []
	for sid: String in RaConsoles.CONSOLE_MAP:
		if int(RaConsoles.CONSOLE_MAP[sid]) <= 0:
			zeroed.append(sid)
	_eq(zeroed, [], "consoles/no row maps to the not-a-console value")

	# UNSUPPORTED is a documentation list that nothing reads. This is what makes
	# its claim true: an id named there must really be absent from the map, or
	# the comment and the behaviour have drifted apart with nothing to say so.
	var contradicted: Array = []
	for sid: String in RaConsoles.UNSUPPORTED:
		if RaConsoles.is_supported(sid):
			contradicted.append(sid)
	_eq(contradicted, [],
		"consoles/every system listed unsupported really is unmapped")


# ── config/ — the credential file ─────────────────────────────────────────────

func _group_config() -> void:
	var cfg := RaConfig.new()
	cfg.enabled = true
	cfg.username = "player_one"
	cfg.token = "TOKEN123"
	cfg.auth_mode = RaConfig.AUTH_TOKEN
	cfg.show_notifications = false
	cfg.rich_presence = false
	_ok(cfg.save_config(), "config/a configuration saves")

	var back := RaConfig.new()
	back.load_config()
	_eq(back.username, "player_one", "config/the username round-trips")
	_eq(back.token, "TOKEN123", "config/the token round-trips")
	_eq(back.enabled, true, "config/the enabled flag round-trips")
	_eq(back.auth_mode, RaConfig.AUTH_TOKEN, "config/the auth mode round-trips")
	_eq(back.show_notifications, false, "config/notifications round-trip")
	_eq(back.rich_presence, false, "config/rich presence round-trips")

	# The policy this class states in its own header: a leaked token can be
	# revoked from the control panel, a leaked password cannot, so the password
	# is never written. Asserted against the FILE, not the object.
	var raw := _read_raw()
	_ok(not raw.contains("password\""),
		"config/no password key is written", raw.left(120))

	# An unrecognised auth mode must land on a real one rather than being carried
	# around as a third state nothing handles.
	_write_raw('{"enabled":true,"auth_mode":"telepathy","username":"u","token":"t"}')
	var odd := RaConfig.new()
	odd.load_config()
	_eq(odd.auth_mode, RaConfig.AUTH_PASSWORD,
		"config/an unknown auth mode falls back to password")

	# is_configured gates the sign-in attempt: all three of enabled, a username
	# and a token are required, and each one alone must not open the gate.
	var gate := RaConfig.new()
	gate.enabled = false
	gate.username = "u"
	gate.token = "t"
	_ok(not gate.is_configured(), "config/disabled is not configured")
	gate.enabled = true
	gate.username = ""
	_ok(not gate.is_configured(), "config/no username is not configured")
	gate.username = "u"
	gate.token = ""
	_ok(not gate.is_configured(), "config/no token is not configured")
	gate.token = "t"
	_ok(gate.is_configured(), "config/enabled with a username and token is configured")

	# A damaged file must leave the defaults standing rather than half-applying.
	_write_raw("{ this is not json")
	var broken := RaConfig.new()
	broken.username = "untouched"
	broken.load_config()
	_eq(broken.username, "untouched",
		"config/a corrupt file leaves the object alone")

	# A file that is valid JSON but not an object is the other shape of garbage.
	_write_raw('["not", "an", "object"]')
	var listy := RaConfig.new()
	listy.username = "kept"
	listy.load_config()
	_eq(listy.username, "", "config/a non-object file reads as empty defaults")

	# No file at all is the first-launch case and must not throw.
	var path := RaConfig.config_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	var fresh := RaConfig.new()
	fresh.username = "default"
	fresh.load_config()
	_eq(fresh.username, "default", "config/a missing file leaves the defaults")


# ── agent/ — what the server is told we are ───────────────────────────────────

func _group_agent() -> void:
	var agent := RaHttpBridge.build_user_agent()
	_ok(agent.begins_with("RetroXR/"), "agent/names this app first", agent)
	_ok(agent.contains("(") and agent.ends_with(")"),
		"agent/carries a parenthesised platform clause", agent)
	# rcheevos appends its own clause, and a newline here would split the header.
	_ok(not agent.contains("\n") and not agent.contains("\r"),
		"agent/is a single header line", agent)
