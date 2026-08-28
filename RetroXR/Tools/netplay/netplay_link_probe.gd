## Netplay over a link cable — the real cores, the real bus, both legs.
##
##   "$godot" --headless --path RetroXR res://Tools/netplay/netplay_link_probe.tscn -- \
##       --link-core=gambatte
##
## A probe, not a test: two real Game Boys and the real LinkCoordinator. ROMs
## come from Tools/gen_gblink_rom.py (ours, so they ship freely) and are
## generated into Tools/gblink/ — run that script first if the folder is empty.
##
## WHAT IT IS FOR. A link cable never crosses the network: the coordinator is a
## process-wide singleton joining two cores in the SAME process, so under
## netplay every peer replicates BOTH machines and it is determinism, not a
## wire, that keeps the two buses agreeing. A session that held only one machine
## therefore left the far end of the cable ungated and, on a client, not running
## at all — and the coordinator waits for a peer that is behind rather than
## guessing, with deliberately no timeout.
##
## So the two legs pull in opposite directions and BOTH have to hold:
##
##   both  — every machine on the wire is fed the gate. The pair advances and
##           actually trades bytes. This is what the session does now.
##   one   — only the near machine is fed, exactly as a client looked before the
##           session learned about groups. The near core must WEDGE: it is not
##           allowed to run ahead of a peer that has not spoken. A green here
##           would mean the bus stopped waiting, which is worse than the hang.
##
## The second leg is the reproduction, and it is the one worth re-running after
## any change to the coordinator's grant rules.
extends Node

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

const ROM_DIR := "res://Tools/gblink/"
const FEED_AHEAD := 8
const RUN_FRAMES := 240
## How many frames of no progress at all count as wedged. The near core is fed
## continuously, so on a healthy bus it never sits still this long.
const WEDGE_TICKS := 90

var root_dir := _home + "/retroxr/libretro"
var core := "gambatte"

var _libs: Array = []
var _feed := [0, 0]
var _fail := 0
var _leg := ""
var _ticks := 0
var _last_progress := 0
var _peak := [0, 0]


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		arg = arg.strip_edges()
		if arg.begins_with("--link-core="):
			core = arg.trim_prefix("--link-core=")
		elif arg.begins_with("--link-root="):
			root_dir = arg.trim_prefix("--link-root=")
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[nplink] TIMEOUT in leg '%s'" % _leg)
		get_tree().quit(1))
	for name in ["link_master.gb", "link_slave.gb"]:
		if not FileAccess.file_exists(ROM_DIR + name):
			print("[nplink] FAIL missing %s — run Tools/gen_gblink_rom.py" % name)
			get_tree().quit(1)
			return
	_start_leg("both")


func _start_leg(leg: String) -> void:
	_leg = leg
	_ticks = 0
	_last_progress = 0
	_feed = [0, 0]
	_peak = [0, 0]
	for lib: Node in _libs:
		lib.StopContent()
		lib.queue_free()
	_libs = []
	await get_tree().create_timer(1.5).timeout

	var roms := [ROM_DIR + "link_master.gb", ROM_DIR + "link_slave.gb"]
	for i in range(2):
		var obj: Object = ClassDB.instantiate("Libretro")
		var lib: Node = obj as Node
		add_child(lib)
		# Both machines are gated, always. The leg decides who gets FED, which
		# is the difference the session used to get wrong — not who is gated.
		lib.SetNetplayMode(true, 0x1, 0)
		lib.StartContent(root_dir, core, ProjectSettings.globalize_path(roms[i]))
		_libs.append(lib)
	# Wait for both cores to be up before cabling them: a bus joined before the
	# cores have attached their serial hardware is a wire with no ends on it.
	for _i in range(600):
		await get_tree().process_frame
		var up := true
		for lib: Node in _libs:
			if (lib.GetCoreIdentity() as Dictionary).is_empty():
				up = false
		if up:
			break
	_libs[0].LinkConnectGroup([_libs[1]], PackedInt32Array([0, 0]))
	print("[nplink] leg '%s': two %s Game Boys, cabled" % [leg, core])


func _process(_d: float) -> void:
	if _libs.size() < 2 or _leg.is_empty():
		return
	_ticks += 1
	var flat := PackedInt32Array()
	flat.resize(20 + 7 + 8)
	# Feed the gate. In the "one" leg the far machine is never fed, which is
	# precisely what a client looked like when the session held one machine.
	var feed_count := 2 if _leg == "both" else 1
	for i in range(feed_count):
		while _feed[i] < int(_libs[i].GetFrameCount()) + FEED_AHEAD:
			_libs[i].PostNetplayInputs(_feed[i], flat)
			_feed[i] += 1
	var advanced := false
	for i in range(2):
		var f := int(_libs[i].GetFrameCount())
		if f > _peak[i]:
			_peak[i] = f
			advanced = true
	if advanced:
		_last_progress = _ticks

	if _leg == "both":
		if _peak[0] >= RUN_FRAMES and _peak[1] >= RUN_FRAMES:
			_finish_both()
	else:
		# Wedged is the PASS here, so give it a real chance to run away first.
		if _ticks - _last_progress > WEDGE_TICKS:
			_finish_one(true)
		elif _peak[0] > RUN_FRAMES * 2:
			_finish_one(false)


func _finish_both() -> void:
	var traffic0: int = int(_libs[0].LinkTraffic(0))
	var traffic1: int = int(_libs[1].LinkTraffic(0))
	var peers: int = int(_libs[0].LinkPeerCount(0))
	print("[nplink] both: frames %d/%d, peers %d, traffic %d/%d"
		% [_peak[0], _peak[1], peers, traffic0, traffic1])
	if peers < 2:
		_bad("both: the two machines are not on one bus")
	if traffic0 <= 0 or traffic1 <= 0:
		_bad("both: the cable carried nothing in either direction")
	if absi(_peak[0] - _peak[1]) > 60:
		_bad("both: the pair drifted apart (%d vs %d)" % [_peak[0], _peak[1]])
	_leg = ""
	await _start_leg("one")


func _finish_one(wedged: bool) -> void:
	print("[nplink] one: near machine reached frame %d and %s (far machine never fed)"
		% [_peak[0], "stopped" if wedged else "KEPT RUNNING"])
	if not wedged:
		_bad("one: a gated core ran on past a bus partner that never published — "
			+ "the coordinator is no longer waiting, and a cabled netplay pair "
			+ "will desync instead of stalling")
	_leg = ""
	for lib: Node in _libs:
		lib.StopContent()
	await get_tree().create_timer(1.5).timeout
	print("[nplink] RESULT=%s" % ("FAIL" if _fail > 0 else "PASS"))
	get_tree().quit(1 if _fail > 0 else 0)


func _bad(why: String) -> void:
	_fail += 1
	print("[nplink] FAIL %s" % why)
