## What does rollback COST on this machine?
##
##   "$godot" --headless --path RetroXR res://Tools/netplay/rollback_cost_probe.tscn -- \
##       --core=snes9x "--rom=Z:/roms/snes/game.sfc" --frames=1800 --mode=rollback
##
## A probe, not a test: it wants a real core and a real ROM, and it reports
## numbers rather than passing or failing.
##
## Rollback pays a full `retro_serialize` EVERY frame whether or not a rewind
## ever happens, plus another one per replayed frame during a rewind. Whether
## that is affordable is a property of the machine, not of the core, so this has
## to be run where the answer matters — a desktop absorbs 50 MB/s of
## serialization and tells you nothing about a Quest.
##
## Run it twice, once per mode, and diff:
##   --mode=lockstep   the same timeline with the rollback engine off
##   --mode=rollback   confirmations lag, so the engine mispredicts and rewinds
##
## Two things it is careful about. The frame counter is driven by the emulation
## thread, so throughput is measured from the CORE's frame count over wall clock
## rather than from `_process` ticks, which are capped by the display. And the
## first RUNUP frames are discarded: a core's first frames include its own
## start-up and the ring filling, neither of which is steady-state cost.
##
## Node3D with a mesh in it, deliberately: on a Quest the QA hook swaps this
## scene in for the XR room, and a plain Node leaves the compositor with no 3D
## world — which arrives as a SIGSEGV on the render thread, not as an error.
extends Node3D

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

const RUNUP := 120           # frames discarded before the clock starts
const LAG := 3               # confirmations trail execution by this many frames
const MAX_AHEAD := 8

var root_dir := _home + "/retroxr/libretro"
var core := "snes9x"
var rom := ""
var frames := 1800
var mode := "rollback"

var _lib: Node = null
var _next_feed := 0
var _t0 := 0
var _f0 := -1
var _done := false


## Where NetworkManager's QA hook accepts this probe's config on device. A
## release build is the only one that runs properly on a Quest and `run-as`
## cannot reach its user://, so /sdcard is the path adb can actually write.
const EXTERNAL_CFG := "/sdcard/Android/data/com.xenu.retroxr/files/rbcost.cfg"


## One `--flag=value` per line, same spelling as the command line. Deleted on
## sight: a run that crashes must not wedge the app into probe mode.
func _cfg_args() -> PackedStringArray:
	var out: PackedStringArray = []
	for path in ["user://rbcost.cfg", EXTERNAL_CFG]:
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			out += f.get_as_text().split("\n", false)
			f.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return out


func _ready() -> void:
	for a_raw in OS.get_cmdline_user_args() + _cfg_args():
		var a := a_raw.strip_edges()
		if a.begins_with("--core="):
			core = a.trim_prefix("--core=")
		elif a.begins_with("--rom="):
			rom = a.trim_prefix("--rom=")
		elif a.begins_with("--root="):
			root_dir = a.trim_prefix("--root=")
		elif a.begins_with("--frames="):
			frames = int(a.trim_prefix("--frames="))
		elif a.begins_with("--mode="):
			mode = a.trim_prefix("--mode=")
	if rom.is_empty():
		print("[rb] need --rom=")
		get_tree().quit(2)
		return
	get_tree().create_timer(600.0).timeout.connect(func() -> void:
		print("[rb] TIMEOUT at frame %d" % (_lib.GetFrameCount() if _lib != null else -1))
		get_tree().quit(2))

	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	add_child(quad)
	var o: Object = ClassDB.instantiate("Libretro")
	_lib = o as Node
	add_child(_lib)
	if not _lib.has_method("GetNetplayRollbackStats"):
		print("[rb] the extension has no GetNetplayRollbackStats; rebuild it")
		get_tree().quit(2)
		return
	# Gate before starting: the core holds at frame 0 until inputs post.
	_lib.SetNetplayMode(true, 0x1, 0)
	# Port 0 is REMOTE (local_mask 0) so the engine has to predict it; the
	# lagged confirmations below are what force a rewind.
	_lib.SetNetplayRollback(mode == "rollback", 0, MAX_AHEAD)
	_lib.StartContent(root_dir, core, rom)
	print("[rb] %s / %s  mode=%s frames=%d  on %s %s" % [core, rom.get_file(),
		mode, frames, OS.get_name(), Engine.get_architecture_name()])


func _input_for_frame(f: int) -> int:
	# Has to keep CHANGING: the engine predicts "same as last frame", so a
	# constant timeline never mispredicts and never rewinds — it would measure
	# the per-frame serialize alone and quietly report rollback as free.
	var btn := 0
	if f >= 60:
		btn |= 1 << 7                       # RIGHT
		if (f % 17) < 6:
			btn |= 1 << 8                   # A
		if (f % 11) < 4:
			btn |= 1 << 0                   # B
		if (f % 53) < 9:
			btn |= 1 << 4                   # UP
	return btn


func _flat(f: int) -> PackedInt32Array:
	var arr := PackedInt32Array()
	arr.resize(20)
	arr[0] = _input_for_frame(f)
	return arr


func _process(_d: float) -> void:
	if _done or _lib == null:
		return
	var cur: int = _lib.GetFrameCount()
	if mode == "rollback":
		while _next_feed <= cur - LAG:
			_lib.PostNetplayInputs(_next_feed, _flat(_next_feed))
			_next_feed += 1
	else:
		while _next_feed < cur + 90:
			_lib.PostNetplayInputs(_next_feed, _flat(_next_feed))
			_next_feed += 1
	# Start the clock only once the core is past its own start-up.
	if _f0 < 0 and cur >= RUNUP:
		_f0 = cur
		_t0 = Time.get_ticks_usec()
	if _f0 >= 0 and cur >= frames:
		_report(cur)


func _rss_kb() -> int:
	# Godot reports its own heap, which misses the core's. On Android and Linux
	# the kernel will say what the process actually holds.
	var f := FileAccess.open("/proc/self/status", FileAccess.READ)
	if f == null:
		return -1
	while not f.eof_reached():
		var line := f.get_line()
		if line.begins_with("VmRSS:"):
			return int(line.split(":")[1].strip_edges().split(" ")[0])
	return -1


func _report(cur: int) -> void:
	_done = true
	var us := Time.get_ticks_usec() - _t0
	var ran := cur - _f0
	var s: Dictionary = _lib.GetNetplayRollbackStats()
	print("[rb] --- %s ---" % mode)
	print("[rb] %d frames in %.2f s = %.1f fps" % [ran, us / 1e6, ran / (us / 1e6)])
	print("[rb] serialize: %d states, mean %.0f us, %.1f%% of a 60Hz frame" % [
		int(s.get("serialize_count", 0)), float(s.get("serialize_us_mean", 0.0)),
		float(s.get("serialize_us_mean", 0.0)) / 16666.0 * 100.0])
	print("[rb] rewinds: %d, mean %.0f us, %d frames replayed, deepest %d" % [
		int(s.get("rollback_count", 0)), float(s.get("replay_us_mean", 0.0)),
		int(s.get("replay_frames", 0)), int(s.get("max_depth", 0))])
	print("[rb] ring: %d slots, %.1f MiB resident (limit %d, max_ahead %d)" % [
		int(s.get("state_slots", 0)), float(s.get("state_bytes", 0)) / 1048576.0,
		int(s.get("ring_limit", 0)), int(s.get("max_ahead", 0))])
	print("[rb] process RSS: %d KiB" % _rss_kb())
	# The number the ring should be sized from, said plainly.
	if int(s.get("rollback_count", 0)) > 0:
		print("[rb] VERDICT deepest rewind was %d frames against a ring of %d"
			% [int(s.get("max_depth", 0)), int(s.get("ring_limit", 0))])
	elif mode == "rollback":
		print("[rb] VERDICT no rewind happened — the timeline never mispredicted,"
			+ " so this run measured the per-frame serialize only")
	_lib.StopContent()
	await get_tree().create_timer(2.0).timeout
	get_tree().quit(0)
