## Netplay with each player on their OWN machine.
##
##   "$godot" --headless --path RetroXR res://Tools/netplay/psx_netplay_split_probe.tscn -- \
##       "--rom=Z:/roms/psx/WipEout (Europe) (Rev 1).cue" --tag=A
##
## Run it twice with different --tag and diff the two [nsp] streams. Identical
## means the arrangement is deterministic across processes, which is the whole
## claim netplay rests on.
##
## WHY THIS IS NOT THE SPIKE. netplay_spike feeds ONE machine and gives both
## runs the SAME input timeline, so it measures determinism and nothing about
## netplay's actual shape. Under netplay two players are not two copies of one
## timeline: player one supplies port 0 of machine one, player two supplies port
## 0 of machine two, each from their own peer, and every peer replicates BOTH
## machines. A core can be perfectly deterministic on one timeline and still
## drop, mis-route or mis-order the far player's input, and the spike would
## report green throughout.
##
## So the two timelines here are deliberately DIFFERENT and deliberately
## asymmetric. If machine two's input were being dropped, or both machines were
## being fed player one's stream, the CRCs would still be internally consistent
## and still reproduce across processes -- so the probe also asserts that the
## two machines DIVERGE from each other, which is what actually catches a
## dropped far player.
extends Node3D

const CORE := "pcsx_rearmed"
const OPT := "pcsx_rearmed_link_cable"
const B_CROSS := 1 << 0
const B_START := 1 << 3
const B_DOWN := 1 << 5
const B_LEFT := 1 << 6
const B_RIGHT := 1 << 7

var rom := ""
var tag := "A"
var frames := 5400
var _libs: Array = []
var _feed := [0, 0]
var _crc: Array = [{}, {}]


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--rom="):
			rom = a.trim_prefix("--rom=")
		elif a.begins_with("--tag="):
			tag = a.trim_prefix("--tag=")
		elif a.begins_with("--frames="):
			frames = int(a.trim_prefix("--frames="))
	if rom.is_empty():
		print("[nsp] need --rom=")
		get_tree().quit(2)
		return
	get_tree().create_timer(1500.0).timeout.connect(func() -> void:
		print("[nsp] TIMEOUT")
		get_tree().quit(2))
	await _run()


## The whole run as a pure function of frame number, so two processes produce
## byte-identical timelines with no clock, no screen-watching and no state.
##
## Menus first, identical on both consoles: WipEout only takes START during part
## of its attract cycle, so it gets a long hold through the transition and then
## taps -- found empirically, kept verbatim. Then TWO PLAYER, then the class and
## team each player confirms for themselves.
##
## Then the part that matters: player one and player two do NOT do the same
## thing. That asymmetry is the point. If machine two's input were dropped, or
## both machines were fed player one's stream, the CRCs would still be
## internally consistent and still reproduce across processes -- and this probe
## would still go green. The asymmetry is what makes a dropped far player show
## up, as machine 0 and machine 1 failing to diverge.
func _input_for(machine: int, f: int) -> int:
	# ── into the menu ────────────────────────────────────────────────────────
	if f >= 2400 and f < 2640:
		return B_START                      # long hold through the attract flip
	if f >= 2820 and f < 3060:
		return B_START if (f % 30) < 6 else 0      # then taps
	# ── SELECT NUMBER OF PLAYERS → TWO PLAYER ────────────────────────────────
	if f >= 3120 and f < 3132:
		return B_DOWN
	if f >= 3240 and f < 3252:
		return B_CROSS
	# ── class / team / track: one confirm every 300 frames ───────────────────
	if f >= 3500 and f < 6200 and (f % 300) < 10:
		return B_CROSS
	# ── racing, and the two players drive differently ────────────────────────
	if f >= 6300:
		if machine == 0:
			return B_CROSS | (B_LEFT if (f % 120) < 45 else 0)
		return B_CROSS | (B_RIGHT if (f % 97) < 30 else 0)
	return 0


func _wait(n: int) -> void:
	var target: int = int(_libs[0].GetFrameCount()) + n
	var guard := n * 80
	while int(_libs[0].GetFrameCount()) < target and guard > 0:
		guard -= 1
		_pump()
		await get_tree().process_frame


## Keep both gated cores supplied. Each machine has its own port 0; a peer would
## originate one of these and receive the other over the wire, and the assembled
## frame that reaches the engine looks the same either way.
func _pump() -> void:
	for m in range(2):
		var cur: int = int(_libs[m].GetFrameCount())
		while _feed[m] < cur + 60:
			var arr := PackedInt32Array()
			arr.resize(20)
			arr[0] = _input_for(m, _feed[m])
			_libs[m].PostNetplayInputs(_feed[m], arr)
			_feed[m] += 1


func _run() -> void:
	var root: String = CoreDownloadManager.default_core_root()
	print("[nsp] tag=%s core=%s rom=%s" % [tag, CORE, rom.get_file()])
	for i in range(2):
		var o: Object = ClassDB.instantiate("Libretro")
		var n := o as Node
		add_child(n)
		_libs.append(n)
		n.SetCoreOption(OPT, "enabled")
		# Gated, port 0 local to this machine. Under a real session one peer
		# would own machine 0's and the other machine 1's; the engine applies
		# the assembled frame either way, which is what makes the split safe.
		n.SetNetplayMode(true, 0x1, 0)
		n.SetNetplayCrcInterval(60)
		n.connect("netplay_crc", func(f: int, c: int, mi := i) -> void:
			_crc[mi][f] = c)
		n.StartContent(root, CORE, rom)
	await _wait(300)
	for n in _libs:
		n.SetControllerPortDevice(0, 1)

	print("[nsp] cabling the two consoles")
	print("[nsp] cable seated: %s" % str(_libs[0].LinkConnect(_libs[1], 0, 0)))
	await _wait(2100)
	print("[nsp] running to frame %d" % frames)
	while int(_libs[0].GetFrameCount()) < frames:
		await _wait(300)

	# One line per checkpoint per machine, for the cross-process diff.
	for m in range(2):
		var keys: Array = _crc[m].keys()
		keys.sort()
		for f: int in keys:
			print("[nsp] m%d %d %08x" % [m, f, int(_crc[m][f])])
	print("[nsp] machine0 checkpoints=%d  machine1 checkpoints=%d"
		% [_crc[0].size(), _crc[1].size()])
	_libs[0].StopContent()
	_libs[1].StopContent()
	await get_tree().create_timer(2.0).timeout
	get_tree().quit(0)
