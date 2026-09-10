## VMU standalone probe — the card as a machine in its own right, and its
## buttons moving.
##
## A VMU is a handheld: its own CPU, its own 48 x 32 screen, four buttons, a
## d-pad and two coin cells. Out of a controller it runs a downloaded minigame on
## the `vemulator` core. This drives that, presses each control in turn, and
## MEASURES what moved — a render alone cannot tell a button that depressed from
## one that was always down.
##
##     "$godot" --path RetroXR --resolution 320x240 --position 20,20 \
##         res://Tools/cores/vmu_standalone_probe.tscn -- \
##         --vms="C:/path/to/Something.vms" [--frames=240]
##
## Windowed rather than headless when a picture is wanted: the dummy renderer
## returns a correctly sized frame with nothing drawn into it. The measurements
## below work either way.
##
## Exits non-zero if the core refuses the game, if no frames run, or if a control
## does not move when its bit is held.
extends Node

const VMU_SCENE := preload("res://Scenes/Objects/controllers/dreamcast/vmu_card.tscn")

## Every control, the bit that works it, and the node that should move.
const CASES: Array = [
	["A", ControllerBindings.JOYPAD_A, "ButtonA"],
	["B", ControllerBindings.JOYPAD_B, "ButtonB"],
	["MODE", ControllerBindings.JOYPAD_START, "ModeButton"],
	["SLEEP", ControllerBindings.JOYPAD_SELECT, "SleepButton"],
]

const DPAD_CASES: Array = [
	["UP", ControllerBindings.JOYPAD_UP],
	["DOWN", ControllerBindings.JOYPAD_DOWN],
	["LEFT", ControllerBindings.JOYPAD_LEFT],
	["RIGHT", ControllerBindings.JOYPAD_RIGHT],
]

var vms := ""
var frames := 240
var shot := "res://probe_out/vmu_standalone.png"

var _card: VmuCard = null
var _fail := 0


func _ready() -> void:
	for a in OS.get_cmdline_user_args():
		var s := str(a)
		if s.begins_with("--vms="):
			vms = s.substr("--vms=".length())
		elif s.begins_with("--frames="):
			frames = maxi(30, int(s.substr("--frames=".length())))
		elif s.begins_with("--shot="):
			shot = s.substr("--shot=".length())
	get_tree().create_timer(420.0).timeout.connect(func() -> void:
		print("[vmustand] TIMEOUT")
		get_tree().quit(1))
	await _run()
	print("[vmustand] ---- %s ----" % ("all checks passed" if _fail == 0 else "%d FAILED" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if not cond:
		_fail += 1
	print("[vmustand] %s  %s%s" % ["PASS" if cond else "FAIL", what,
		"" if detail.is_empty() else "  - " + detail])


## A short fingerprint of what is on the LCD right now, for telling two screens
## apart without caring what either says.
func _lcd_digest(lib: Node) -> String:
	if lib == null:
		return ""
	var tex: Texture2D = lib.GetVideoTexture()
	if tex == null:
		return ""
	var img := tex.get_image()
	if img == null:
		return ""
	var lit := 0
	var sum := 0
	for y in range(img.get_height()):
		for x in range(img.get_width()):
			if img.get_pixel(x, y).get_luminance() > 0.5:
				lit += 1
				sum += x * 7 + y * 13
	return "%d/%d" % [lit, sum]


## The LCD as a PNG, magnified without interpolation so its dots stay dots.
func _save_lcd(lib: Node, path: String) -> void:
	if lib == null:
		return
	var tex: Texture2D = lib.GetVideoTexture()
	if tex == null:
		return
	var img := tex.get_image()
	if img == null:
		return
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(path.get_base_dir()))
	var out := img.duplicate() as Image
	out.convert(Image.FORMAT_RGB8)
	out.resize(48 * 8, 32 * 8, Image.INTERPOLATE_NEAREST)
	out.save_png(path)
	print("[vmustand] wrote %s" % path)


func _hold(mask: int, ticks: int) -> void:
	for i in range(ticks):
		_card.set_input(mask)
		await get_tree().process_frame


func _run() -> void:
	_card = VMU_SCENE.instantiate() as VmuCard
	add_child(_card)
	# A RigidBody with no floor falls out of frame; this is a bench, not a room.
	_card.freeze = true
	await get_tree().process_frame
	await get_tree().process_frame

	# The transforms first, printed rather than trusted. The pivot has to put its
	# local +Y on the card's +Z or the animator rocks about the wrong axes, and a
	# basis read back is the only thing that says so — a render of a symmetric
	# disc looks the same either way.
	var mount := _card.get_node_or_null("DpadMount") as Node3D
	var pivot := _card.get_node_or_null("DpadMount/DpadPivot") as Node3D
	_ok(mount != null and pivot != null, "the d-pad mount and pivot exist")
	if mount == null or pivot == null:
		return
	var mb := mount.transform.basis
	print("[vmustand] mount basis  x=%s  y=%s  z=%s"
		% [str(mb.x.snappedf(0.001)), str(mb.y.snappedf(0.001)), str(mb.z.snappedf(0.001))])
	# The animator rotates in the animated node's PARENT space, so it is the
	# MOUNT that must present +Y as the face normal. Checking the pivot's own
	# basis proves nothing — it is identity, and was identity in the broken
	# version too.
	_ok(mb.y.dot(Vector3(0, 0, 1)) > 0.99,
		"the mount's +Y is the card's +Z, which is the frame the animator rocks in",
		"y=%s" % str(mb.y.snappedf(0.001)))
	_ok(pivot.transform.basis.is_equal_approx(Basis()),
		"and the pivot itself starts unrotated")

	# --- The controls move ----------------------------------------------------
	#
	# Rest pose first, then each bit held on its own. Comparing against the REST
	# transform rather than against "did it change" is what makes this able to
	# fail: a control that never moves and one that never returns both look like
	# movement to a difference test.
	var rest: Dictionary = {}
	for spec: Array in CASES:
		var n := _card.get_node_or_null(NodePath(str(spec[2]))) as Node3D
		if n != null:
			rest[str(spec[2])] = n.transform.origin
	var mount_inv := mb.inverse()

	for spec: Array in CASES:
		var name: String = spec[0]
		var node_name: String = spec[2]
		var n := _card.get_node_or_null(NodePath(node_name)) as Node3D
		if n == null:
			_ok(false, "%s exists" % name)
			continue
		await _hold(1 << int(spec[1]), 24)
		var moved: Vector3 = n.transform.origin - Vector3(rest[node_name])
		# It must go IN, along the card's -Z, and by something close to the
		# authored depth rather than merely not-zero.
		_ok(moved.z < -0.0005 and absf(moved.x) < 0.0001 and absf(moved.y) < 0.0001,
			"%s sinks into the face when its bit is held" % name,
			"moved %.4f mm in z" % (moved.z * 1000.0))
		await _hold(0, 24)
		var back: Vector3 = n.transform.origin - Vector3(rest[node_name])
		_ok(back.length() < 0.0002, "%s returns when released" % name,
			"%.4f mm off rest" % (back.length() * 1000.0))

	# The d-pad rocks, and each direction tips the RIGHT way: pressing UP has to
	# push the +Y edge of the disc into the face, not lift it out.
	for spec: Array in DPAD_CASES:
		var name: String = spec[0]
		await _hold(1 << int(spec[1]), 24)
		# Where the pressed edge went, measured in the CARD's frame. The pivot
		# turns inside the mount, so a direction has to go card -> mount -> rotate
		# -> card to be comparable; reading the pivot's basis raw would be in the
		# mount's frame, where the card's Z is not Z.
		var edge := {
			"UP": Vector3(0, 1, 0), "DOWN": Vector3(0, -1, 0),
			"LEFT": Vector3(-1, 0, 0), "RIGHT": Vector3(1, 0, 0),
		}[name] as Vector3
		var now: Vector3 = mb * (pivot.transform.basis * (mount_inv * edge))
		var tipped: float = now.z - edge.z
		_ok(tipped < -0.02, "the d-pad's %s edge dips when %s is held" % [name, name],
			"z moved %.4f" % tipped)
		await _hold(0, 20)

	# --- It runs a minigame ---------------------------------------------------
	if vms.is_empty():
		print("[vmustand] no --vms given; the standalone half is skipped")
		return
	_ok(_card.power_on(vms), "the card powers up on %s" % vms.get_file())
	if not _card.is_running_standalone():
		return

	for i in range(frames):
		# Nothing held: a minigame's title screen should come up on its own.
		_card.set_input(0)
		await get_tree().process_frame

	var lib := _card.get_node_or_null("VmuLibretro")
	var ran: int = int(lib.GetFrameCount()) if lib != null else 0
	_ok(ran > 0, "and runs frames of its own", "%d frames" % ran)
	var tex: Texture2D = lib.GetVideoTexture() if lib != null else null
	_ok(tex != null, "publishing its own picture")
	if tex != null:
		var sz := tex.get_size()
		print("[vmustand] core texture %s" % str(sz))
		# The whole point: this core IS a VMU, so its frame is the LCD itself
		# rather than a corner of somebody else's screen.
		_ok(int(sz.x) == 48 and int(sz.y) == 32,
			"which is the VMU's own 48 x 32 screen", str(sz))
		var img := tex.get_image()
		if img != null:
			var seen := {}
			for y in range(img.get_height()):
				for x in range(img.get_width()):
					seen[img.get_pixel(x, y).to_rgba32()] = true
			print("[vmustand] distinct colours on the LCD: %d" % seen.size())
			_ok(seen.size() >= 2, "with something actually drawn on it",
				"%d colours" % seen.size())
			DirAccess.make_dir_recursive_absolute(
				ProjectSettings.globalize_path(shot.get_base_dir()))
			var out := img.duplicate() as Image
			out.convert(Image.FORMAT_RGB8)
			out.resize(48 * 8, 32 * 8, Image.INTERPOLATE_NEAREST)
			out.save_png(shot)
			print("[vmustand] wrote %s" % shot)

	# Does input actually REACH the core, or does it only animate?
	#
	# Breakout's title screen says "Press A+B to start", so the game itself
	# supplies the oracle: hold those two and the screen has to change. Comparing
	# the LCD before and after is a check that cannot pass by accident — a core
	# that never saw the buttons keeps showing its title.
	var lib2 := _card.get_node_or_null("VmuLibretro")
	var before := _lcd_digest(lib2)
	await _hold((1 << ControllerBindings.JOYPAD_A) | (1 << ControllerBindings.JOYPAD_B), 90)
	await _hold(0, 60)
	var after := _lcd_digest(lib2)
	print("[vmustand] LCD before=%s after=%s" % [before, after])
	_save_lcd(lib2, shot.trim_suffix(".png") + "_after.png")
	_ok(not before.is_empty() and before != after,
		"holding A+B changes what the LCD shows, so the press reached the core")

	_card.power_off()
	_ok(not _card.is_running_standalone(), "and powers back down")
	# Sixty PROCESS FRAMES before quitting, and both halves of that matter.
	#
	# The extension's audio playback comes back through a chain rather than in
	# one step, so a probe that exits promptly after powering a core down dies
	# with an access violation and prints no crash-handler output at all — every
	# check green, then the process gone. A wall-clock timer does not fix it
	# (tried at 1.5 s, still died); the reclaim is counted in frames.
	for i in range(60):
		await get_tree().process_frame
