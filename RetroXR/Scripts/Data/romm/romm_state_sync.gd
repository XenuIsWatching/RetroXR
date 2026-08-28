## RommStateSync — backs save states up to RomM, and pulls them down again.
##
## Autoloaded as `StateSync`. Modelled on RommSaveSync's threading (one worker,
## a separate list thread, `_abort` polled through `_aborting()`, abort before
## join in `_exit_tree`) and deliberately much simpler than it in every other way.
##
## **A battery save needs a three-way merge; a state does not.** The core edits
## a .srm continuously behind the player's back, on any device that runs the
## game, which is why RommSaveSync compares local, last-synced and server
## hashes. A state changes only at a deliberate press, on one device, at a
## moment the app is watching. So the protocol here is: upload what the server
## does not have, PUT what the player overwrote, list what the server has that
## we do not, and let them pull those down. No merge, no fork, no conflict.
##
## The one genuine conflict — two devices overwriting the same state while
## offline — is last-writer-wins, deliberately. Detecting it would need a
## version the API does not carry, and what is lost is one state the player
## themselves replaced twice, not a save file of accumulated progress.
## `server_updated_at` is recorded so a future version COULD notice.
##
## Record file: <core_root>/states/romm_states.json, keyed by the state's path
## relative to the states root, holding {server_id, uploaded_at, bytes, error}.
class_name RommStateSync
extends Node


## `key` is the ledger key (see key_for). `detail` is a sentence to show.
signal upload_started(key: String)
signal upload_finished(key: String, ok: bool, detail: String)
## A listing came back: state_id -> server record, for one game.
signal listed(rom_id: int, ok: bool, states: Array, detail: String)

var config: RommConfig = null

## Ledger key -> record.
var _state: Dictionary = {}
var _thread: Thread = null
var _queue: Array[Dictionary] = []
var _busy := false
var _current_key := ""
var _list_thread: Thread = null
var _list_busy := false
## Polled by the workers between HTTP chunks. Whoever joins one raises it first:
## a 50 MB upload left running answers to nothing else, and the join would
## otherwise wait out the whole response timeout on the main thread.
var _abort := false


func _ready() -> void:
	config = RommConfig.new()
	config.load_config()
	load_state()


## Re-read the config after the OPTIONS panel changes it. Unlike its counterpart
## on RommSaveSync, this one has a caller from the day it lands.
func setup(cfg: RommConfig) -> void:
	config = cfg
	load_state()


func is_available() -> bool:
	return config != null and config.is_configured()


## Is backing up switched on at all? The global switch governs states outright —
## there is no per-state opt-in, because a state is a deliberate act and the
## player has already said they want it kept.
func backup_enabled() -> bool:
	return config != null and config.is_configured() and config.backup_enabled


func _exit_tree() -> void:
	_queue.clear()
	_abort = true
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null
	if _list_thread != null and _list_thread.is_started():
		_list_thread.wait_to_finish()
		_list_thread = null
	_abort = false


func _aborting() -> bool:
	return _abort


# ── The ledger ────────────────────────────────────────────────────────────────

## Relative to the states root, so the key survives the app moving — the same
## rule RommSaveSync.key_for follows for saves.
static func key_for(state_path: String) -> String:
	return state_path.trim_prefix(StatePaths.states_root()).trim_prefix("/")


func record_for(state_path: String) -> Dictionary:
	return (_state.get(key_for(state_path), {}) as Dictionary).duplicate()


## What the tab shows against a row: "on" | "busy" | "failed" | "off".
func status_for(state_path: String) -> String:
	if not backup_enabled():
		return "off"
	var k := key_for(state_path)
	if _current_key == k:
		return "busy"
	for j: Dictionary in _queue:
		if str(j["key"]) == k:
			return "busy"
	var rec: Dictionary = _state.get(k, {})
	if int(rec.get("server_id", 0)) > 0:
		return "on"
	return "failed" if not str(rec.get("error", "")).is_empty() else "off"


## Every row's status at once, keyed by state_id, so the tab makes one pass
## rather than one call per row.
func statuses_for(core_name: String, rom_path: String, rows: Array) -> Dictionary:
	var out: Dictionary = {}
	for r: Variant in rows:
		var d := r as Dictionary
		out[str(d.get("state_id", ""))] = status_for(str(d.get("path", "")))
	return out


## The one sentence to put above the list when backup is failing, or "".
## One strip rather than twelve identical row glyphs to read one at a time.
func failure_notice(core_name: String, rom_path: String, rows: Array) -> String:
	if not backup_enabled() or rows.is_empty():
		return ""
	var failed := 0
	var detail := ""
	for r: Variant in rows:
		var rec: Dictionary = _state.get(key_for(str((r as Dictionary).get("path", ""))), {})
		var err := str(rec.get("error", ""))
		if not err.is_empty():
			failed += 1
			detail = err
	if failed == 0:
		return ""
	if failed == rows.size():
		return "None of these are backed up — %s" % detail
	return "%d of these could not be backed up — %s" % [failed, detail]


# ── Uploading ─────────────────────────────────────────────────────────────────

## Back one state up. Creates it on the server, or PUTs over the copy this state
## already has there — which is what makes an overwritten row replace its server
## copy rather than uploading the same name twice, behaviour the API does not
## specify.
func enqueue(core_name: String, rom_path: String, state_id: String, rom_id: int) -> void:
	if not backup_enabled() or rom_id <= 0 or state_id.is_empty():
		return
	var path := StatePaths.state_path(core_name, rom_path, state_id)
	if not FileAccess.file_exists(path):
		return
	var k := key_for(path)
	if _current_key == k:
		return
	for j: Dictionary in _queue:
		if str(j["key"]) == k:
			return
	_queue.append({
		"key": k, "state_id": state_id, "path": path,
		"shot": StatePaths.shot_path(core_name, rom_path, state_id),
		"rom_id": rom_id, "core": core_name,
		"base_url": config.base_url, "headers": config.auth_headers(),
		"server_id": int((_state.get(k, {}) as Dictionary).get("server_id", 0)),
	})
	_pump()


func _pump() -> void:
	if _busy or _queue.is_empty():
		return
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null
	var job: Dictionary = _queue.pop_front()
	_busy = true
	_current_key = str(job["key"])
	upload_started.emit(_current_key)
	_thread = Thread.new()
	_thread.start(_worker.bind(job))


## Worker thread. Reads the files here rather than on the main thread: a state
## is tens of megabytes and the whole point of this feature is that nothing
## about it costs a frame.
func _worker(job: Dictionary) -> void:
	var headers := PackedStringArray(job["headers"])
	var http := RommHttp.new()
	if http.open(str(job["base_url"]), _aborting) != RommHttp.Result.OK:
		call_deferred("_finish", job, false, 0, "Cannot reach RomM")
		return

	var bytes := FileAccess.get_file_as_bytes(str(job["path"]))
	if bytes.is_empty():
		http.close()
		call_deferred("_finish", job, false, 0, "The save state could not be read")
		return
	var shot := PackedByteArray()
	if FileAccess.file_exists(str(job["shot"])):
		shot = FileAccess.get_file_as_bytes(str(job["shot"]))

	var filename := str(job["state_id"]) + ".state"
	var server_id := int(job["server_id"])
	var out: Dictionary
	if server_id > 0:
		out = RommStates.update(http, headers, server_id, filename, bytes, shot, _aborting)
		# The copy was deleted on the server between our two writes. Falling back
		# to a create is right: the player asked for this state to be backed up,
		# and a 404 on the old id does not withdraw that.
		if not bool(out["ok"]) and str(out["error"]) == RommHttp.ERR_GONE:
			server_id = 0
	if server_id <= 0:
		out = RommStates.create(http, headers, int(job["rom_id"]), str(job["core"]),
			filename, bytes, shot, _aborting)
	http.close()

	var rec: Dictionary = out["state"] if out.has("state") else {}
	call_deferred("_finish", job, bool(out["ok"]),
		int(rec.get("id", server_id)), str(out["error"]))


func _finish(job: Dictionary, ok: bool, server_id: int, detail: String) -> void:
	_busy = false
	_current_key = ""
	var k := str(job["key"])
	var rec: Dictionary = _state.get(k, {})
	if ok:
		rec["server_id"] = server_id
		rec["uploaded_at"] = int(Time.get_unix_time_from_system())
		rec["bytes"] = NetFileTransfer.size_of(str(job["path"]))
		rec.erase("error")
	else:
		# Sticky and visible: a failure the tab can report beats one that leaves
		# a row looking backed up.
		rec["error"] = detail
		push_warning("[StateSync] %s: %s" % [k, detail])
	_state[k] = rec
	save_state()
	upload_finished.emit(k, ok, detail)
	_pump()


# ── Listing and restoring ─────────────────────────────────────────────────────

## Ask the server what states it holds for this game. Answers through `listed`.
##
## Its own thread, so opening the tab never waits behind an upload — the same
## split RommSaveSync makes for the same reason.
func list_for_rom(rom_id: int) -> void:
	if not is_available() or rom_id <= 0 or _list_busy:
		return
	if _list_thread != null and _list_thread.is_started():
		_list_thread.wait_to_finish()
		_list_thread = null
	_list_busy = true
	_list_thread = Thread.new()
	_list_thread.start(_list_worker.bind(rom_id, config.base_url, config.auth_headers()))


func _list_worker(rom_id: int, base_url: String, headers: PackedStringArray) -> void:
	var http := RommHttp.new()
	if http.open(base_url, _aborting) != RommHttp.Result.OK:
		call_deferred("_list_done", rom_id, false, [], "Cannot reach RomM")
		return
	var out := RommStates.list_for_rom(http, headers, rom_id, _aborting)
	http.close()
	call_deferred("_list_done", rom_id, bool(out["ok"]), out["states"], str(out["error"]))


func _list_done(rom_id: int, ok: bool, states: Array, detail: String) -> void:
	_list_busy = false
	listed.emit(rom_id, ok, states, detail)


## Which of the server's states this device does not have on disk.
##
## Matched by file_name, because RomM gives a state no slot to key on. A name
## this app did not mint is skipped rather than guessed at: adopting one would
## claim an id we might later mint ourselves, and the two would collide.
func server_only(core_name: String, rom_path: String, server_states: Array) -> Array:
	var out: Array = []
	for s: Variant in server_states:
		var d := s as Dictionary
		var sid := RommStates.id_from_filename(str(d.get("file_name", "")))
		if sid.is_empty():
			continue
		if FileAccess.file_exists(StatePaths.state_path(core_name, rom_path, sid)):
			continue
		out.append({
			"state_id": sid,
			"server_id": int(d.get("id", 0)),
			"updated_at": str(d.get("updated_at", "")),
			"size": int(d.get("size", 0)),
			"screenshot_path": str(d.get("screenshot_path", "")),
		})
	return out


## Pull one server state down into the normal local layout, after which it is an
## ordinary row. Answers through `upload_finished` — the tab only needs to know
## that something changed and whether it worked.
func download(core_name: String, rom_path: String, entry: Dictionary) -> void:
	if not is_available() or _list_busy:
		return
	if _list_thread != null and _list_thread.is_started():
		_list_thread.wait_to_finish()
		_list_thread = null
	_list_busy = true
	_list_thread = Thread.new()
	_list_thread.start(_download_worker.bind(core_name, rom_path, entry.duplicate(),
		config.base_url, config.auth_headers()))


func _download_worker(core_name: String, rom_path: String, entry: Dictionary,
					  base_url: String, headers: PackedStringArray) -> void:
	var state_id := str(entry["state_id"])
	var local_path := StatePaths.state_path(core_name, rom_path, state_id)
	var http := RommHttp.new()
	if http.open(base_url, _aborting) != RommHttp.Result.OK:
		call_deferred("_download_done", local_path, false, 0, "Cannot reach RomM")
		return
	var got := RommStates.download(http, headers, int(entry["server_id"]), _aborting)
	var shot := PackedByteArray()
	if bool(got["ok"]):
		shot = RommStates.download_screenshot(http, headers,
			str(entry.get("screenshot_path", "")), _aborting)
	http.close()
	if not bool(got["ok"]):
		call_deferred("_download_done", local_path, false, 0, str(got["error"]))
		return

	# Written through the same atomic promote a capture uses, so a half-pulled
	# state is never offered. A state with no picture on the server gets none
	# here; the row shows a placeholder rather than an empty plate.
	var job := StatePaths.Job.new()
	job.state_path = local_path
	job.shot_path = StatePaths.shot_path(core_name, rom_path, state_id)
	job.meta_path = StatePaths.meta_path(core_name, rom_path, state_id)
	job.data = got["bytes"]
	job.frame = 0
	job.core = core_name
	job.rom = rom_path
	job.created_at = int(Time.get_unix_time_from_system())
	var err := StatePaths.write_job(job)
	if err.is_empty() and not shot.is_empty():
		var f := FileAccess.open(job.shot_path, FileAccess.WRITE)
		if f != null:
			f.store_buffer(shot)
			f.close()
	call_deferred("_download_done", job.state_path, err.is_empty(),
		int(entry["server_id"]), err)


func _download_done(local_path: String, ok: bool, server_id: int, detail: String) -> void:
	_list_busy = false
	var k := key_for(local_path)
	if ok and server_id > 0:
		# It came FROM the server, so it is already backed up. Recording that is
		# what stops the row offering to upload what it has just downloaded —
		# and what makes a later overwrite PUT over the right copy.
		_state[k] = {
			"server_id": server_id,
			"uploaded_at": int(Time.get_unix_time_from_system()),
			"bytes": NetFileTransfer.size_of(local_path),
		}
		save_state()
	upload_finished.emit(k, ok, detail)


# ── Persistence ───────────────────────────────────────────────────────────────

static func state_path() -> String:
	return StatePaths.states_root().path_join("romm_states.json")


func load_state() -> void:
	_state.clear()
	var f := FileAccess.open(state_path(), FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	f.close()
	if parsed is Dictionary and (parsed as Dictionary).get("states") is Dictionary:
		_state = (parsed as Dictionary)["states"]


func save_state() -> void:
	DirAccess.make_dir_recursive_absolute(state_path().get_base_dir())
	var f := FileAccess.open(state_path(), FileAccess.WRITE)
	if f == null:
		push_warning("[StateSync] Cannot write %s" % state_path())
		return
	f.store_string(JSON.stringify({"version": 1, "states": _state}, "\t"))
	f.close()


## Forget a state's ledger entry. Called when the state is deleted locally, so a
## later state minted with a recycled path cannot inherit its server id.
func forget(state_path_abs: String) -> void:
	if _state.erase(key_for(state_path_abs)):
		save_state()
