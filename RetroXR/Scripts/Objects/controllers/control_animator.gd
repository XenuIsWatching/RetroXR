## ControlAnimator — drives separated button / D-pad / stick meshes from a joypad
## state. The engine only; what to bind is the caller's business.
##
## Lifted out of AnimatedController so the handheld MODELS can use it too. A pad
## and a handheld's built-in controls are the same problem — press a mesh along a
## direction while its bit is held, rock a pad about its pivot, tilt a stick — but
## a pad is a RetroController and a handheld's face is a RetroSystemModel, two
## unrelated trees. Neither can inherit the other, so the engine sits in a
## RefCounted both hold.
##
## Fill the arrays/dicts, then call animate() each frame:
##   buttons : {node, rest, depth, bit?, mask?, dir?, stick_dir?, stick?}
##   dpad    : {node, rest, pivot, bits?, axis?}   (dpad2 is a second rocker)
##   stick_l : {node, rest, pivot}                 (clicks on L3; stick_r on R3)
class_name ControlAnimator
extends RefCounted

## "Into the shell" in the mesh parent's space. Per-button "dir" overrides it —
## a control on the back edge travels into THAT face, and pressing it along the
## default just slides it down the outside of the shell.
var press_dir: Vector3 = Vector3(0, -1, 0)
var stick_click: float = 0.0016
var dpad_tilt_deg: float = 7.0
var stick_tilt_deg: float = 16.0
## Deflection past which a stick-driven button counts as pressed. Only used by
## entries carrying a "stick_dir" — see animate().
var stick_press: float = 0.5
## A positive pitch about the mesh parent's X axis lifts whatever lies on -Z, so
## a rig whose UP arm points -Z must set this to -1.0 for UP to depress it.
var dpad_pitch_sign: float = 1.0

var buttons: Array[Dictionary] = []
var dpad: Dictionary = {}
var dpad2: Dictionary = {}
var stick_l: Dictionary = {}
var stick_r: Dictionary = {}


func is_empty() -> bool:
	return buttons.is_empty() and dpad.is_empty() and dpad2.is_empty() \
		and stick_l.is_empty() and stick_r.is_empty()


## `weight` is the per-frame lerp weight (0..1) toward the pressed/rest pose.
func animate(btn: int, lstick: Vector2, rstick: Vector2, weight: float) -> void:
	for e: Dictionary in buttons:
		# Node3D rather than MeshInstance3D: a control is usually one mesh, but a
		# VMU's d-pad is a disc with a cross moulded into it and moves as one
		# piece, so what travels is an empty parent with three meshes under it.
		# Every existing caller passes a MeshInstance3D, which is a Node3D.
		var node: Node3D = e["node"]
		var rest: Transform3D = e["rest"]
		# "mask" lets one mesh answer to several buttons. Some pads mould their
		# face buttons as a single piece — the Genesis pad's A, B and C are one
		# mesh — so there is nothing to press individually. Defaults to this
		# entry's own bit.
		var bit: int = int(e.get("bit", -1))
		var mask: int = int(e.get("mask", (1 << bit) if bit >= 0 else 0))
		var pressed: float = 1.0 if (mask != 0 and (btn & mask) != 0) else 0.0
		# "stick_dir" presses a button from an ANALOG stick instead of, or as
		# well as, a bit. The N64's four C buttons are why: a core reads that
		# cluster as the right analog stick, and the two bits it also offers for
		# C-Left and C-Right are the SAME bits as the L and R shoulders — so
		# animating those two from their bits would depress a C button every
		# time the player squeezed a grip. The stick is the unambiguous source,
		# and it is what RetroXR's own default XR binding sends.
		var push: Vector2 = e.get("stick_dir", Vector2.ZERO)
		if push != Vector2.ZERO and pressed == 0.0:
			var src: Vector2 = lstick if e.get("stick", "right") == "left" else rstick
			if src.dot(push) > stick_press:
				pressed = 1.0
		var dir: Vector3 = e.get("dir", press_dir)
		var target := Transform3D(rest.basis,
			rest.origin + dir * (float(e["depth"]) * pressed))
		node.transform = node.transform.interpolate_with(target, weight)

	if not dpad.is_empty():
		_rock(dpad, btn, lstick, rstick, weight)
	if not dpad2.is_empty():
		_rock(dpad2, btn, lstick, rstick, weight)

	if not stick_l.is_empty():
		var click_l: float = 1.0 if (btn & (1 << ControllerBindings.JOYPAD_L3)) != 0 else 0.0
		apply_pivot(stick_l, _stick_basis(lstick), click_l, weight)
	if not stick_r.is_empty():
		var click_r: float = 1.0 if (btn & (1 << ControllerBindings.JOYPAD_R3)) != 0 else 0.0
		apply_pivot(stick_r, _stick_basis(rstick), click_r, weight)


## Rock one D-pad about its pivot from the four bits it answers to, plus the
## analog stick named by "axis" if it has one.
func _rock(entry: Dictionary, btn: int, lstick: Vector2, rstick: Vector2, weight: float) -> void:
	var bits: Array = entry.get("bits", [ControllerBindings.JOYPAD_UP, ControllerBindings.JOYPAD_DOWN,
		ControllerBindings.JOYPAD_LEFT, ControllerBindings.JOYPAD_RIGHT])
	var pitch: float = float((btn >> int(bits[0])) & 1) - float((btn >> int(bits[1])) & 1)
	var roll: float  = float((btn >> int(bits[2])) & 1) - float((btn >> int(bits[3])) & 1)
	var axis: String = entry.get("axis", "")
	if not axis.is_empty():
		# Analog Y is positive DOWN and X positive RIGHT — the opposite sense to
		# the up-minus-down / left-minus-right sums above.
		var stick: Vector2 = rstick if axis == "right" else lstick
		pitch = clampf(pitch - stick.y, -1.0, 1.0)
		roll = clampf(roll - stick.x, -1.0, 1.0)
	var r := Basis.from_euler(Vector3(deg_to_rad(pitch * dpad_tilt_deg * dpad_pitch_sign),
		0.0, deg_to_rad(roll * dpad_tilt_deg)))
	apply_pivot(entry, r, 0.0, weight)


func _stick_basis(stick: Vector2) -> Basis:
	return Basis.from_euler(Vector3(deg_to_rad(stick.y * stick_tilt_deg), 0.0,
		deg_to_rad(-stick.x * stick_tilt_deg)))


## Rotate a mesh about a pivot in its parent's space, plus an optional click push
## along press_dir, lerping from its current transform toward the target.
func apply_pivot(entry: Dictionary, r: Basis, click: float, weight: float) -> void:
	# Node3D, for the reason given in animate(): a rocker may be an empty parent
	# carrying several meshes that move together.
	var node: Node3D = entry["node"]
	var rest: Transform3D = entry["rest"]
	var pivot: Vector3 = entry["pivot"]
	var about := Transform3D(r, pivot - r * pivot + press_dir * (stick_click * click))
	node.transform = node.transform.interpolate_with(about * rest, weight)
