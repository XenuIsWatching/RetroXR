## N64Controller — the Nintendo 64 pad (NUS-005).
##
## Every control animates: A, B, the four C buttons, Start, Z, both shoulders,
## the D-pad and the analog stick. That is only possible because of WHICH asset
## this is — the shell arrives with each control already a separate named mesh,
## so nothing has to be cut out of a welded surface the way the PlayStation
## pad's did, and no primitive stand-ins are needed on top of it.
##
## The mapping is mupen64plus-next's, read out of the core's own
## `retro_input_descriptor` table rather than from memory:
##
##     N64 A       -> RetroPad B          N64 L  -> RetroPad L
##     N64 B       -> RetroPad Y          N64 R  -> RetroPad R
##     N64 Start   -> RetroPad START      N64 Z  -> RetroPad L2
##     N64 C-Up    -> RetroPad X          C-Down -> RetroPad A
##     N64 C-Left  -> RetroPad L    <-- shared with the L shoulder
##     N64 C-Right -> RetroPad R    <-- shared with the R shoulder
##     control stick -> analog 0, C cluster -> analog 1
##
## Those two collisions are real and are the core's default scheme (its
## "Independent C-button Controls" option is what separates them, and RetroXR
## does not set it). They are why the C buttons animate from the ANALOG stick
## rather than from bits: driving C-Left off bit L would depress it every time
## the player squeezed the left grip, which is the shoulder. RetroXR's default
## XR binding sends the C cluster on the right thumbstick anyway, so the stick is
## both the correct source and the one the player is actually using.
class_name N64Controller
extends AnimatedController

## Press depths, in metres.
##
## Every one of these is set against how far its cap actually stands proud of
## the shell, measured BY RAYCAST through the cap's centre -- not from the cap
## mesh's own height, and not from nearby shell vertices. The shell is 2102
## triangles, so its vertices near a button sit on panels centimetres away in
## surface terms and sampling them gives answers between 4 and 29 mm for the
## same button. The ray gives:
##
##     A 2.98   B 2.75   C 4.02-4.29   Start 1.81   D-pad 3.06   stick 11.72
##
## B is the binding constraint on the face pair, not A.
##
## Taking the cap mesh's own height instead answers about a third of this, which
## reads on screen as nothing happening at all. These leave roughly 0.8-1.8 mm
## of cap still standing at full press, which is what stops a button vanishing
## into its own aperture -- and n64_button_probe.tscn re-measures by ray and
## fails if any of them ever stops being true.
const PRESS_FACE: float = 0.0018
## The C buttons have the most clearance of any control here (4 mm), but they
## are also the smallest caps; more travel than this makes the cluster look like
## it is swallowing itself.
const PRESS_C: float = 0.0022
## Start is a small flush button with only 1.8 mm proud of the shell.
const PRESS_START: float = 0.0009
## The shoulders hinge more than they sink, but a short straight push along
## their own face reads correctly at the size they are seen from. They travel
## into the pad's REAR face, so the cap-sink limit above does not apply.
const PRESS_SHOULDER: float = 0.0025
## Z is a lever pulled with the middle finger and has the longest throw here.
const PRESS_Z: float = 0.0030

## Controls that travel straight into the button face (the engine's default -Y).
const FACE: Dictionary = {
	"Btn_A": ControllerBindings.JOYPAD_B,
	"Btn_B": ControllerBindings.JOYPAD_Y,
}

## The C cluster. Each entry is [RetroPad bit or JOYPAD_NONE, stick direction].
##
## C-Up and C-Down keep their bits (X and A) because those are theirs alone.
## C-Left and C-Right get none, because in this core's default scheme their bits
## ARE the shoulders' bits — see the class comment. All four also answer to the
## right stick, which is the channel the core calls "C Buttons X/Y".
##
## Stick Y is positive DOWN, matching the analog convention the rest of
## ControlAnimator uses.
const C_BUTTONS: Dictionary = {
	"Btn_C_Up":    [ControllerBindings.JOYPAD_X, Vector2(0, -1)],
	"Btn_C_Down":  [ControllerBindings.JOYPAD_A, Vector2(0, 1)],
	"Btn_C_Left":  [ControllerBindings.JOYPAD_NONE, Vector2(-1, 0)],
	"Btn_C_Right": [ControllerBindings.JOYPAD_NONE, Vector2(1, 0)],
}

## Which way each off-face control travels, in the pad's own frame.
##
## NOT the -Y the face buttons use, and not guessed either: each of these is the
## negated area-weighted normal of that control's own outward surface, measured
## off the mesh. The shoulders sit on the rear edge and are angled outward, so
## they travel forward (+Z) and inward; Z hangs under the centre prong facing
## down and back, so it travels up and forward. Pressing any of them along -Y
## would slide them along the outside of the shell instead of into it.
const SHOULDER_L_DIR := Vector3(0.402, -0.032, 0.915)
const SHOULDER_R_DIR := Vector3(-0.402, -0.032, 0.915)
const Z_DIR := Vector3(0.0, 0.829, 0.559)

const SHOULDERS: Dictionary = {
	"Btn_L": [ControllerBindings.JOYPAD_L, SHOULDER_L_DIR],
	"Btn_R": [ControllerBindings.JOYPAD_R, SHOULDER_R_DIR],
}

## The D-pad rocks about the shell surface, which sits below the cross's own
## centre. The model ships no pivot empty, and _find_pivot's AABB fallback would
## rock it about its own middle — the same correction the NES and PS1 pads need.
const DPAD_PIVOT_DROP: float = 0.0022

## The N64 stick is a tall shaft on a gimbal, not a low thumb cap: it pivots
## near the shell line, well below the cap the player sees.
const STICK_PIVOT_DROP: float = 0.0125


func _cache_meshes() -> void:
	_buttons.clear()
	for stem: String in FACE:
		_add(stem, {"bit": int(FACE[stem]), "depth": PRESS_FACE})
	for stem: String in C_BUTTONS:
		var row: Array = C_BUTTONS[stem]
		var e := {"depth": PRESS_C, "stick_dir": row[1] as Vector2}
		# Omitted rather than passed as JOYPAD_NONE: ControlAnimator reads a
		# missing "bit" as "no bit of its own", and a negative shift is not a
		# thing GDScript defines.
		if int(row[0]) >= 0:
			e["bit"] = int(row[0])
		_add(stem, e)
	for stem: String in SHOULDERS:
		var row: Array = SHOULDERS[stem]
		_add(stem, {"bit": int(row[0]), "depth": PRESS_SHOULDER, "dir": row[1] as Vector3})
	_add("Btn_Start", {"bit": ControllerBindings.JOYPAD_START, "depth": PRESS_START})
	_add("Btn_Z", {"bit": ControllerBindings.JOYPAD_L2, "depth": PRESS_Z, "dir": Z_DIR})

	_dpad = _rocker("DPad", DPAD_PIVOT_DROP)
	_stick_l = _rocker("Stick", STICK_PIVOT_DROP)


## The shell lies face-up — +Y out of the face — with the D-pad on -X, which puts
## its UP arm on -Z, so the engine's default pitch would lift UP instead of
## pressing it. Same as the NES and PS1 pads.
func _dpad_pitch_sign() -> float:
	return -1.0


func _add(stem: String, entry: Dictionary) -> void:
	var m := _find_mesh(stem)
	if m == null:
		push_warning("N64Controller: control mesh not found: " + stem)
		return
	entry["node"] = m
	entry["rest"] = m.transform
	_buttons.append(entry)


func _rocker(stem: String, drop: float) -> Dictionary:
	var m := _find_mesh(stem)
	if m == null:
		push_warning("N64Controller: control mesh not found: " + stem)
		return {}
	var pivot: Vector3 = _find_pivot(m, stem + "Pivot")
	pivot.y -= drop
	return {"node": m, "rest": m.transform, "pivot": pivot}
