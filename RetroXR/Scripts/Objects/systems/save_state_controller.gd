## SaveStateController — taking a save state and putting one back.
##
## A child of the RetroSystem it serves, created unconditionally because every
## machine can be asked, in the same shape as HandheldInput and WiiLink.
##
## Lifted out of system.gd whole. It was the cleanest seam in that file: no
## NetworkManager anywhere in it, no reach into the shell model, and one async
## boundary it already owned through StatePaths.Job.
##
## The two signals stay on RetroSystem and are emitted through the host, because
## CartridgeOptionsPanel connects them BY NAME on the system node
## (`sys.connect("state_captured", ...)`) and Tools/state_probe does the same.
## Moving them would have been a rename disguised as a refactor.
##
## The contract worth keeping in mind while editing: capture_state and
## load_state each answer EXACTLY once, always. A missing answer leaves the
## panel button greyed for ever; a doubled one fires the tab twice. Every early
## return here emits before it returns, and system_tests pins all seven paths.
class_name SaveStateController
extends Node

## The machine this belongs to. Set by RetroSystem in setup(), never by _ready:
## the node is added before the host can hand itself over.
var _host: RetroSystem = null


func setup(host: RetroSystem) -> void:
	_host = host

# ---------------------------------------------------------------------------
# Save states
#
# The core serializes on the emulation thread and answers by signal; the disk
# writes and the thumbnail encode go to a worker. Nothing here may cost the
# render thread more than a memcpy — a 50 MB Dolphin state written on the main
# thread is three seconds of dropped frames on a Quest.
# ---------------------------------------------------------------------------


## Backstop only. Every ordinary failure now answers by itself: a capture in
## flight when the machine stops is answered by the emulation thread as it
## unwinds, and a request made before the core is up waits in the queue. What is
## left is a core that never unwinds at all and gets abandoned, which nothing
## downstream will ever hear from.
const STATE_ANSWER_TIMEOUT := 20.0

## Cores that answered "I cannot serialize". Static because it is a property of
## the core, not of this cabinet, and asking is the only way to find out — there
## is no capability query in the libretro API.
static var _cores_without_states: Dictionary = {}

var _capture_id := ""            ## non-empty while a capture is in flight
var _capture_core := ""
var _capture_rom := ""
var _capture_shot: Image = null
var _capture_task := -1
var _capture_gen := 0
var _load_id := ""
var _load_gen := 0


## Whether this machine can take a state right now, and why not if it cannot:
## {ok, reason}, where reason is empty when ok and otherwise a sentence to put
## on a disabled button.
##
## Named for the gate rather than the question because it does not answer with a
## bool — `if can_capture_state():` was true whatever the gate said, since a
## non-empty Dictionary is truthy. Every caller wants the reason as well.
func capture_gate() -> Dictionary:
	if _host.rom_path.is_empty():
		return {"ok": false, "reason": "no game is inserted"}
	if not _host.is_powered_on:
		return {"ok": false, "reason": "the machine is off"}
	if not _capture_id.is_empty():
		return {"ok": false, "reason": "a save state is already being written"}
	if _cores_without_states.has(_host.resolve_core_name()):
		return {"ok": false, "reason": "this core cannot save states"}
	return {"ok": true, "reason": ""}


## Take a state. `into_id` empty mints a new one; a real id overwrites that state
## in place, keeping its position in the list and its link to the copy on the
## server — which is the whole of what the tab's overwrite button does.
##
## Answers exactly once through state_captured, always.
func capture_state(into_id := "") -> void:
	var gate := capture_gate()
	if not bool(gate["ok"]):
		_host.state_captured.emit(into_id, false, str(gate["reason"]))
		return

	_capture_id = into_id if not into_id.is_empty() else StatePaths.mint_id()
	_capture_core = _host.resolve_core_name()
	_capture_rom = _host.rom_path
	# The frame the player was looking at when they pressed, not the one that
	# happens to be up when the core finishes serializing. This is the CPU buffer
	# the texture was uploaded from, so it is a memcpy and not a GPU readback —
	# and it MUST be duplicated, because the core writes the next frame into
	# those same pixels.
	var live: Image = _host.get_libretro_node().GetVideoImage()
	_capture_shot = live.duplicate() as Image if live != null and not live.is_empty() else null

	_capture_gen += 1
	var gen := _capture_gen
	_host.get_libretro_node().savestate_ready.connect(_on_savestate_ready, CONNECT_ONE_SHOT)
	get_tree().create_timer(STATE_ANSWER_TIMEOUT).timeout.connect(
		func() -> void:
			if _capture_gen == gen and not _capture_id.is_empty():
				if _host.get_libretro_node().savestate_ready.is_connected(_on_savestate_ready):
					_host.get_libretro_node().savestate_ready.disconnect(_on_savestate_ready)
				_finish_capture(false, "the machine stopped before the state was written"))
	_host.get_libretro_node().RequestSaveState()


func _on_savestate_ready(data: PackedByteArray, frame: int) -> void:
	if _capture_id.is_empty():
		return
	if frame < 0:
		_finish_capture(false, "the machine is not running")
		return
	if data.is_empty():
		# The only way to learn this, so remember it: the tab greys the button
		# out for every machine running this core from here on.
		_cores_without_states[_capture_core] = true
		_finish_capture(false, "this core cannot save states")
		return

	var job := StatePaths.Job.new()
	job.state_path = StatePaths.state_path(_capture_core, _capture_rom, _capture_id)
	job.shot_path = StatePaths.shot_path(_capture_core, _capture_rom, _capture_id)
	job.meta_path = StatePaths.meta_path(_capture_core, _capture_rom, _capture_id)
	job.data = data
	job.shot = _capture_shot
	job.frame = frame
	job.core = _capture_core
	job.rom = _capture_rom
	job.created_at = int(Time.get_unix_time_from_system())
	_capture_shot = null
	_capture_task = WorkerThreadPool.add_task(_write_state_task.bind(job, _capture_gen))


## Worker thread. Everything expensive about a capture happens here.
func _write_state_task(job: StatePaths.Job, gen: int) -> void:
	var err := StatePaths.write_job(job)
	call_deferred("_on_state_written", err, gen)


func _on_state_written(err: String, gen: int) -> void:
	if _capture_task != -1:
		WorkerThreadPool.wait_for_task_completion(_capture_task)
		_capture_task = -1
	if gen != _capture_gen:
		return
	_finish_capture(err.is_empty(), err)


func _finish_capture(ok: bool, reason: String) -> void:
	var id := _capture_id
	_capture_id = ""
	_capture_shot = null
	_capture_gen += 1
	if ok:
		print("[RetroSystem] save state %s written" % id)
	else:
		push_warning("[RetroSystem] save state failed: %s" % reason)
	_host.state_captured.emit(id, ok, reason)


## Restore a state. A machine that is off is switched on first and the request
## rides the emulation thread's startup queue, so one press does what was meant.
##
## Answers exactly once through state_loaded, always.
func load_state(state_id: String) -> void:
	if not _load_id.is_empty():
		_host.state_loaded.emit(state_id, false, "a save state is already loading")
		return
	var core := _host.resolve_core_name()
	if core.is_empty() or _host.rom_path.is_empty():
		_host.state_loaded.emit(state_id, false, "no game is inserted")
		return
	if not FileAccess.file_exists(StatePaths.state_path(core, _host.rom_path, state_id)):
		_host.state_loaded.emit(state_id, false, "that save state is missing")
		return
	_load_id = state_id
	_load_gen += 1
	# Reading it is the slow half on a big state, so it is not done here.
	WorkerThreadPool.add_task(_read_state_task.bind(core, _host.rom_path, state_id, _load_gen))


func _read_state_task(core: String, rom: String, state_id: String, gen: int) -> void:
	var data := PackedByteArray()
	var f := FileAccess.open(StatePaths.state_path(core, rom, state_id), FileAccess.READ)
	if f != null:
		data = f.get_buffer(f.get_length())
		f.close()
	var meta := StatePaths.read_meta(core, rom, state_id)
	call_deferred("_issue_load", data, int(meta.get("frame", 0)), gen)


func _issue_load(data: PackedByteArray, frame: int, gen: int) -> void:
	if gen != _load_gen or _load_id.is_empty():
		return
	if data.is_empty():
		_finish_load(false, "that save state could not be read")
		return
	_host.get_libretro_node().savestate_loaded.connect(_on_savestate_loaded, CONNECT_ONE_SHOT)
	get_tree().create_timer(STATE_ANSWER_TIMEOUT).timeout.connect(
		func() -> void:
			if _load_gen == gen and not _load_id.is_empty():
				if _host.get_libretro_node().savestate_loaded.is_connected(_on_savestate_loaded):
					_host.get_libretro_node().savestate_loaded.disconnect(_on_savestate_loaded)
				_finish_load(false, "the machine never answered"))
	if not _host.is_powered_on:
		_host.power_on()
	# Issued whether or not the core is up yet: the emulation thread drains this
	# queue at the top of its loop, which by construction is after the core has
	# loaded. A start that fails answers false through the same signal.
	_host.get_libretro_node().RequestLoadState(data, frame)


func _on_savestate_loaded(ok: bool) -> void:
	if _load_id.is_empty():
		return
	_finish_load(ok, "" if ok else "the core refused that save state")


func _finish_load(ok: bool, reason: String) -> void:
	var id := _load_id
	_load_id = ""
	_load_gen += 1
	_host.state_loaded.emit(id, ok, reason)
