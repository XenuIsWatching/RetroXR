## NesController — the Nintendo Entertainment System pad.
##
## The first of the imported console models, so unlike RetroPadController and
## VbController it binds its controls with AnimatedController's fuzzy mesh-name
## search instead of by node path — the meshes live inside nes_controller.glb and
## the scene has no authored nodes to point at.
##
## The NES pad is the smallest joypad we animate: a rocking D-pad, B and A, and
## SELECT/START. No shoulders, no triggers, no sticks, so most of the engine sits
## idle and _stick_l / _stick_r / _dpad2 stay empty.
class_name NesController
extends AnimatedController

# Mesh-name stem -> RETRO_JOYPAD bit. _find_mesh normalises and prefix-matches,
# so these hit the glTF's "BtnA_Controller_0" / "DPad_Controller_0" without the
# exporter's suffix having to appear here.
const NES_FACE: Dictionary = {
	"BtnB": ControllerBindings.JOYPAD_B,
	"BtnA": ControllerBindings.JOYPAD_A,
}
const NES_SMALL: Dictionary = {
	"BtnSelect": ControllerBindings.JOYPAD_SELECT,
	"BtnStart":  ControllerBindings.JOYPAD_START,
}

## The D-pad rocks about the shell surface rather than its own centre, which sits
## a little above it. The model ships no pivot empty for _find_pivot to find, and
## that helper's AABB fallback would rock it about its own middle, so drop the
## pivot explicitly the way the authored pads do.
const DPAD_PIVOT_DROP: float = 0.003


func _cache_meshes() -> void:
	_buttons.clear()
	for stem: String in NES_FACE:
		_add_button(stem, int(NES_FACE[stem]), FACE_PRESS)
	for stem: String in NES_SMALL:
		_add_button(stem, int(NES_SMALL[stem]), SMALL_PRESS)
	_dpad = _rocker("DPad", DPAD_PIVOT_DROP)


## The shell lies face-up — +Y out of the face, B left of A along +X — which puts
## the D-pad's UP arm on -Z, so the engine's default pitch would lift UP instead
## of pressing it.
func _dpad_pitch_sign() -> float:
	return -1.0


## Every control is moulded into the top face, so all of them travel along the
## engine's default PRESS_DIR and none needs a "dir" of its own.
func _add_button(stem: String, bit: int, depth: float) -> void:
	var m := _find_mesh(stem)
	if m == null:
		push_warning("NesController: control mesh not found: " + stem)
		return
	_buttons.append({"node": m, "rest": m.transform, "bit": bit, "depth": depth})


func _rocker(stem: String, drop_dist: float) -> Dictionary:
	var m := _find_mesh(stem)
	if m == null:
		push_warning("NesController: control mesh not found: " + stem)
		return {}
	return {"node": m, "rest": m.transform, "pivot": m.position - Vector3(0.0, drop_dist, 0.0)}


# --- button sounds --------------------------------------------------------------
#
# Recorded off a real NES-001 pad. Three banks, not eight: A and B are the same
# moulding and sound identical, as do SELECT and START, as do the four arms of the
# rocker — so each bank pools every take of its group and gets far more variation
# than a per-button split would have allowed.
#
# Driven off the edges of AnimatedController's merged _cur_btn rather than off any
# widget: these buttons are read as INPUT STATE, not pressed as VRButtons the way
# the console's POWER and RESET are.

const SFX_DIR := "res://Audio/nes/"

## Which sample bank each joypad bit belongs to.
const BANK_OF: Dictionary = {
	ControllerBindings.JOYPAD_A: "face",
	ControllerBindings.JOYPAD_B: "face",
	ControllerBindings.JOYPAD_START: "menu",
	ControllerBindings.JOYPAD_SELECT: "menu",
	ControllerBindings.JOYPAD_UP: "dpad",
	ControllerBindings.JOYPAD_DOWN: "dpad",
	ControllerBindings.JOYPAD_LEFT: "dpad",
	ControllerBindings.JOYPAD_RIGHT: "dpad",
}

var _prev_btn: int = 0
var _sfx_voices: Array[PcmOneShot] = []
var _sfx_next: int = 0
var _sfx_banks: Dictionary = {}     # "face_press" -> Array[PackedVector2Array]
var _sfx_last: Dictionary = {}


func _ready() -> void:
	super._ready()
	for bank in ["face", "menu", "dpad"]:
		for role in ["press", "release"]:
			var key := "%s_%s" % [bank, role]
			var v := _load_variants("nes_pad_" + key)
			if not v.is_empty():
				_sfx_banks[key] = v
	# The cable end, which lives on the controller rather than the console: these
	# are recordings of THIS plug in THIS port, so they belong with the pad.
	for key in ["plug_in", "plug_unplug"]:
		var pv := _load_variants("nes_" + key)
		if not pv.is_empty():
			_sfx_banks[key] = pv
	# THREE voices. A pad can have a direction and a face button change in the same
	# frame, and PcmOneShot restarts rather than layers, so fewer would cut a click
	# short every time someone runs and jumps.
	for i in 3:
		var v := PcmOneShot.new()
		v.name = "PadSfx%d" % i
		# Held in the hand, so closer and quieter than the console's panel switches.
		v.unit_size = 0.4
		v.max_distance = 2.5
		v.volume = 0.45
		add_child(v)
		_sfx_voices.append(v)


## Every `<prefix>_NN.wav` in SFX_DIR, counting up until one is missing.
## ResourceLoader.exists(), not FileAccess.file_exists() — the latter is false in
## an exported build, where res:// paths are remapped into the pck.
func _load_variants(prefix: String) -> Array:
	var out: Array = []
	var i := 1
	while true:
		var p := "%s%s_%02d.wav" % [SFX_DIR, prefix, i]
		if not ResourceLoader.exists(p):
			break
		var frames := PcmClip.load_frames(p)
		if not frames.is_empty():
			out.append(frames)
		i += 1
	return out


func _process(delta: float) -> void:
	super._process(delta)
	if not _got_input:
		# Not held, or not plugged in. The base class has already forced _cur_btn to
		# 0, so comparing against it would fire a release click for every button that
		# happened to be down — a dropped pad clicking its own buttons on the way to
		# the floor. Forget the state instead, so picking it back up is silent too.
		_prev_btn = 0
		return
	var down := _cur_btn & ~_prev_btn
	var up := _prev_btn & ~_cur_btn
	_prev_btn = _cur_btn
	if down != 0:
		_click(down, "press")
	if up != 0:
		_click(up, "release")


## One click per BANK per edge, not one per bit: rolling the rocker from UP to
## UP+RIGHT is a single movement of a single piece of plastic, and firing two
## samples for it comb-filters into something metallic.
func _click(bits: int, role: String) -> void:
	var fired: Dictionary = {}
	for bit: int in BANK_OF:
		if (bits & (1 << bit)) == 0:
			continue
		var key: String = "%s_%s" % [BANK_OF[bit], role]
		if fired.has(key):
			continue
		fired[key] = true
		_play_sfx(key)


# --- the plug going into a console's port -------------------------------------
#
# RetroController already receives these from ControllerPlug, so the sound needs no
# new plumbing. Both are guarded, because the same two calls are made by code:
#
#  * RetroSystem.restore_controller_plug seats a saved plug through the very snap
#    zone a hand uses, so loading a room would plug in every controller at once.
#  * Tearing a room down frees the port zones, and an emptied zone reports a drop —
#    which is a machine being deleted, not a cable being pulled.


func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	super.on_plugged_in(system, port_index)
	if system != null and not system.is_restoring_media():
		# From the PLUG. These voices hang off the controller, so left alone the
		# sound comes from wherever the pad is lying rather than from the socket
		# the cable just went into.
		_play_sfx("plug_in", _socket_pos(system, port_index))


func on_unplugged() -> void:
	# Read the system BEFORE super() clears it — that reference is the only way to
	# tell a pulled cable from a console being freed out from under one.
	var sys := _connected_system
	super.on_unplugged()
	if is_instance_valid(sys) and not sys.is_queued_for_deletion() and not is_queued_for_deletion():
		_play_sfx("plug_unplug", _plug_pos())


## The socket the plug is going into.
##
## Not the plug's own position: on_plugged_in fires from inside the snap, before
## the zone has moved the plug onto the socket, so the plug is still hanging
## where the hand let go of it — which is why the sound came from the pad.
func _socket_pos(system: RetroSystem, port_index: int) -> Vector3:
	if system == null:
		return _plug_pos()
	var socket := system.port_socket(_cable_plug, port_index)
	return socket.global_position if socket != null else _plug_pos()


## Where the cable end is right now, or the pad itself if it has none.
func _plug_pos() -> Vector3:
	if is_instance_valid(_cable_plug):
		return (_cable_plug as Node3D).global_position
	return global_position


## Pick a variant and play it on the next voice. Never repeats the variant it
## played last for that bank — a face button gets mashed, and a plain random pick
## doubles often enough to read as a glitch rather than as variation.
func _play_sfx(key: String, at: Variant = null) -> void:
	var bank: Array = _sfx_banks.get(key, [])
	if bank.is_empty() or _sfx_voices.is_empty():
		return
	var idx := randi() % bank.size()
	if bank.size() > 1 and idx == int(_sfx_last.get(key, -1)):
		idx = (idx + 1) % bank.size()
	_sfx_last[key] = idx
	var voice: PcmOneShot = _sfx_voices[_sfx_next]
	_sfx_next = (_sfx_next + 1) % _sfx_voices.size()
	if at == null:
		voice.play(bank[idx])
	else:
		voice.play_from(bank[idx], at as Vector3)
