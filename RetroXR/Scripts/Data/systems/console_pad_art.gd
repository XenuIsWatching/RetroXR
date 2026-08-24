## ConsolePadArt — line art and anchors for the consoles whose own pad the
## Controls tab can draw, keyed by systemid.
##
## A platform with a row here gets its real controller on its override page,
## with a dropdown on each control the hardware actually has. A platform without
## one falls back to the generic diagrams — the Quest controllers for the XR
## section, the Xbox-layout pad for the physical one — which is what every
## platform used before this table existed.
##
## Control keys are GamepadBindings target strings, so one row serves BOTH
## sections: the physical-pad map is keyed by target already, and the XR map's
## RetroPad bit is that target's index in GamepadBindings.TARGET_ORDER.
##
## Art must be redistributable and free of anyone's branding — see the
## ATTRIBUTIONS file beside the SVGs. Anchors are measured from a render rather
## than chosen (Tools/nes_pad_anchors.py), because the drawing is not ours.
class_name ConsolePadArt
extends RefCounted

## The generic pad's key in _ROWS. Not a systemid — no console uses it — so
## has() keeps answering false for every real platform while row() and texture()
## still serve it.
const RETROPAD := "__retropad"

## A Wii Remote turned on its side, held in two hands like an NES pad.
##
## A VARIANT, not a platform: one console can be held more than one way, and each
## way relabels the same RetroPad bits differently, so the page needs a picture
## per way rather than a picture per systemid. Keyed like RETROPAD is — off the
## systemid namespace, so has() keeps answering false and the platform grid does
## not grow a phantom tile.
const WII_SIDEWAYS := "wii#sideways"

## Every key in _ROWS that is NOT a platform. has() must answer false for all of
## them; row(), controls() and texture() serve them like any other.
const _VARIANTS: Array = [RETROPAD, WII_SIDEWAYS]

const _ROWS: Dictionary = {
	# The generic pad, for scopes that are not one console: the desktop key map on
	# the global Controls page binds RetroPad buttons, not a NES's. Keyed by a
	# systemid no console uses, so has() still answers false for every platform.
	#
	# Art and anchors are GamepadDiagram's, re-keyed from the Xbox PHYSICAL names
	# it uses to the RetroPad targets everything else here speaks. The face four
	# swap on the way: RetroPad B is the BOTTOM button and A is the right one,
	# which is the positional convention GamepadBindings.DEFAULT_BUTTON_MAP is
	# built on. Getting that backwards would put the picture and the core's idea
	# of "A" on opposite buttons.
	RETROPAD: {
		"label": "Controller",
		"art": "res://Textures/Controllers/gamepad_line.svg",
		"layout": "columns",
		"anchors": {
			"l2": Vector2(0.3000, 0.1139),
			"r2": Vector2(0.7000, 0.1139),
			"l": Vector2(0.3000, 0.1778),
			"r": Vector2(0.7000, 0.1778),
			"l3": Vector2(0.2680, 0.3639),
			"r3": Vector2(0.6050, 0.5667),
			"up": Vector2(0.3980, 0.5028),
			"down": Vector2(0.3980, 0.6306),
			"left": Vector2(0.3520, 0.5667),
			"right": Vector2(0.4440, 0.5667),
			"x": Vector2(0.7220, 0.2944),
			"a": Vector2(0.7780, 0.3722),
			"b": Vector2(0.7220, 0.4500),
			"y": Vector2(0.6660, 0.3722),
			"select": Vector2(0.4410, 0.3722),
			"start": Vector2(0.5590, 0.3722),
		},
		# GamepadDiagram's own column orders, which were chosen by counting
		# segment intersections over a sweep of panel sizes. Do not reorder
		# without re-running that count — see the note on its LEFT_ORDER.
		"left": ["l2", "l", "l3", "select", "up", "left", "right", "down"],
		"right": ["r2", "r", "x", "a", "y", "b", "start", "r3"],
	},
	"nes": {
		"label": "NES Controller",
		"art": "res://Textures/Controllers/nes_pad_colour.svg",
		# Colour art, so the diagram must NOT tint it — ART_TINT exists to recolour
		# the white-on-alpha line drawings, and over this it would wash the red
		# buttons and the grey shell into one blue.
		"tint": false,
		# Normalized to the SVG viewBox, so the diagram lays out at any size.
		# MEASURED from a Godot render by Tools/nes_pad_anchors.py, not chosen:
		# the buttons are somebody else's drawing, so the dots have to be found
		# in it. Re-run that tool if the art is ever replaced.
		"anchors": {
			"left": Vector2(0.0867, 0.5892),
			"up": Vector2(0.1611, 0.4086),
			"right": Vector2(0.2354, 0.5892),
			"down": Vector2(0.1611, 0.7698),
			"select": Vector2(0.3915, 0.7122),
			"start": Vector2(0.5287, 0.7122),
			"b": Vector2(0.7019, 0.7070),
			"a": Vector2(0.8307, 0.7069),
		},
		# Rows along the top and bottom rather than columns down the sides: this
		# pad is 2.4:1, and a column beside it would put every lead nearly
		# horizontal across the whole picture. Split by anchor height, ordered by
		# anchor x. `down` is on the bottom row despite sharing the cross's x
		# with `up`, because from the top its lead would run through the cross.
		"top": ["left", "up", "right"],
		"bottom": ["down", "select", "start", "b", "a"],
	},
	"wii": {
		"label": "Wii Remote",
		"art": "res://Textures/Controllers/wii_remote.svg",
		# Colour art like the NES pad's, so the diagram must not tint it: ART_TINT
		# exists to recolour the white-on-alpha line drawings, and over a white
		# shell it would take the whole remote to one flat blue.
		"tint": false,
		# Columns, not rows: this remote is 1:4 portrait, and labels along its top
		# and bottom would leave every lead running the full height of the picture.
		"layout": "columns",
		# The keys are RETROPAD targets, not the names printed on the shell, because
		# that is what _control_glyph and the binding rows speak. The remote's own
		# mapping is in Scripts/Objects/peripherals/wiimote.gd DESKTOP_BUTTON_MAP
		# and this follows it exactly:
		#     a -> A     x -> 1     y -> 2
		#     start -> plus         select -> minus        r3 -> home
		# Getting one of those backwards would put the picture and the core's idea
		# of the button on different caps.
		#
		# Positions come from the art's own path data rather than from measuring a
		# render — see Tools/gen_wii_remote_art.py, which composes the drawing and
		# prints this block. The NES has to be measured because that drawing is
		# somebody else's with unknown geometry; this one we assemble, so the
		# centres are known exactly.
		"anchors": {
			"up": Vector2(0.5077, 0.1232),
			"left": Vector2(0.3659, 0.1679),
			"right": Vector2(0.6500, 0.1679),
			"down": Vector2(0.5077, 0.2125),
			"a": Vector2(0.5081, 0.3161),
			# B is the TRIGGER, on the back of the remote, so a front view cannot
			# show it. The dot sits on the shell where the trigger is behind rather
			# than being left off: a control the page will not draw is a control the
			# player cannot rebind.
			"b": Vector2(0.5081, 0.3922),
			"select": Vector2(0.2430, 0.4801),
			"r3": Vector2(0.5085, 0.4801),
			"start": Vector2(0.7740, 0.4801),
			"x": Vector2(0.5107, 0.7350),
			"y": Vector2(0.5107, 0.8205),
		},
		# Each column ordered by anchor height, so no lead crosses another. select
		# and start sit at the same height as r3 and are split left and right of it
		# for the same reason — the three share a row on the hardware.
		"left": ["up", "left", "a", "select", "x"],
		"right": ["right", "down", "b", "r3", "start", "y"],
		# The chips beside each row. Without these the page falls back to the shared
		# RETROPAD glyphs, and a Wii Remote ends up labelled with a PlayStation R3
		# for Home and a PlayStation Start for plus — which is what shipped, and is
		# worse than no picture: it names a button this hardware does not have.
		#
		# Keyed by the same RETROPAD targets as the anchors, so the left-hand column
		# reads "the control" and the picture agrees with it. Kenney's Wii set, the
		# same family the marks printed on the shell come from.
		"glyphs": {
			"up": "wii_dpad_up_outline",
			"down": "wii_dpad_down_outline",
			"left": "wii_dpad_left_outline",
			"right": "wii_dpad_right_outline",
			"a": "wii_button_a_outline",
			"b": "wii_button_b_outline",
			"select": "wii_button_minus_outline",
			"start": "wii_button_plus_outline",
			"r3": "wii_button_home_outline",
			"x": "wii_button_1_outline",
			"y": "wii_button_2_outline",
		},
		# No external-pad remapping page for this one. A Wii Remote is not a gamepad
		# with the buttons moved around: it is pointed at the screen and swung, and
		# the IR pointer, the accelerometer and the MotionPlus gyro have no sticks
		# or buttons on a pad to be mapped onto. Offering the usual grid would imply
		# an ordinary pad can play these games as they were meant to be played.
		"gamepad_note": "The Wii Remote is not a gamepad. Aiming is an infrared "
			+ "pointer at the sensor bar, and motion comes from the "
			+ "accelerometer and the MotionPlus gyro inside the remote — none of "
			+ "which a standard controller has anything to map onto. Its buttons "
			+ "still follow the XR bindings above, and in VR you press them on "
			+ "the remote itself.",
		# Shown under the diagram. This remote is the one console pad held in ONE
		# hand, and one VR hand does not carry enough inputs to reach seven buttons
		# and a d-pad — so the buttons are pokeable, and a player who does not
		# think of that simply cannot press 1, 2 or minus. The remote says the same
		# thing in VR through a HeldHint when you pick it up; this is the half a
		# desktop player, or someone reading the page before ever holding one, gets.
		"note": "In VR you can press the remote's own buttons directly: hold it "
			+ "in one hand and poke them with the other.",
	},
	# The same remote, turned on its side and held in two hands like an NES pad.
	#
	# The RetroPad bits do not move — Dolphin's descWiimoteSideways keeps every
	# one of them and changes what it MEANS, doing the remap internally — so this
	# is a picture and a set of labels, not a second binding map. Whatever a
	# player binds above works here too.
	#
	# What DOES move is which physical button each bit points at, so the anchors
	# are re-keyed rather than merely rotated:
	#
	#     upright    b -> B(trigger)   a -> A     x -> 1     y -> 2
	#     sideways   b -> 1            a -> 2     x -> A     y -> B(trigger)
	#
	# and the cross turns with the shell, so "up" takes the old "right" position
	# and round. Both the art and this block come out of
	# Tools/gen_wii_remote_sideways.py, which rotates the upright drawing and
	# prints these numbers — the re-keying is the half no one can check by eye.
	WII_SIDEWAYS: {
		"label": "Wii Remote (sideways)",
		"art": "res://Textures/Controllers/wii_remote_sideways.svg",
		"tint": false,
		# Rows, not columns: rotating the shell makes the art 4:1 landscape, and
		# columns down either side of a wide, short picture would leave every lead
		# crossing the middle of it.
		"layout": "rows",
		"anchors": {
			"b": Vector2(0.7350, 0.4893),
			"a": Vector2(0.8205, 0.4893),
			"x": Vector2(0.3161, 0.4919),
			"y": Vector2(0.3922, 0.4919),
			"up": Vector2(0.1679, 0.3500),
			"down": Vector2(0.1679, 0.6341),
			"left": Vector2(0.1232, 0.4923),
			"right": Vector2(0.2125, 0.4923),
			"select": Vector2(0.4801, 0.7570),
			"r3": Vector2(0.4801, 0.4915),
			"start": Vector2(0.4801, 0.2260),
		},
		# Ordered by the anchor's x so no lead crosses another — with one tie to
		# break. minus and home sit at the SAME x (they were a horizontal row on
		# the upright shell and are a vertical stack here), so ordering by x alone
		# does not decide them, and the wrong order really does cross: the lower
		# anchor has less height to cover, so it slants harder and overtakes the
		# higher one on the way to a further slot. The one nearer the row takes
		# the nearer slot.
		"top": ["left", "up", "x", "start", "b"],
		"bottom": ["down", "right", "y", "select", "r3", "a"],
		# The four face buttons say what they say when the remote is sideways,
		# which is the whole reason this picture exists. The d-pad and the three
		# below it are unchanged: Dolphin rotates the cross internally, so the
		# player still presses "up" for up.
		"glyphs": {
			"up": "wii_dpad_up_outline",
			"down": "wii_dpad_down_outline",
			"left": "wii_dpad_left_outline",
			"right": "wii_dpad_right_outline",
			"b": "wii_button_1_outline",
			"a": "wii_button_2_outline",
			"x": "wii_button_a_outline",
			"y": "wii_button_b_outline",
			"select": "wii_button_minus_outline",
			"start": "wii_button_plus_outline",
			"r3": "wii_button_home_outline",
		},
		"note": "Hold the remote in both hands, like a plain pad. Grab it with "
			+ "your second hand and it turns sideways by itself; let go and it "
			+ "turns back. The buttons keep whatever you bound above — the "
			+ "console is the one relabelling them, not the room.",
	},
}


## True when this platform has a pad of its own to draw. The generic pad is not
## a platform, so it never answers true here.
static func has(systemid: String) -> bool:
	return not systemid.is_empty() and not _VARIANTS.has(systemid) and _ROWS.has(systemid)


## The art keys to draw for one scope, in the order they should be stacked.
##
## A platform is usually one picture and answers with just itself. The Wii is
## held two ways that relabel the same bits — upright in one hand, sideways in
## two — and neither picture is right for the other, so it answers with both.
static func variants_for(systemid: String) -> Array:
	if systemid == "wii":
		return ["wii", WII_SIDEWAYS]
	return [systemid] if has(systemid) else []


## The row for a platform, or an empty Dictionary.
static func row(systemid: String) -> Dictionary:
	return _ROWS.get(systemid, {}) as Dictionary


## Every control this platform's pad carries, in row order.
static func controls(systemid: String) -> Array:
	var r := row(systemid)
	if r.is_empty():
		return []
	# Layout-aware, because a "columns" row has no top/bottom. It used to read
	# them unconditionally and a missing key is not an error in GDScript — it is
	# null, and `null as Array` is [], so a columns pad reported NO controls at all
	# rather than failing. ConsolePadDiagram._order() has always split the same two
	# ways; this is the half of the pair that did not.
	if String(r.get("layout", "rows")) == "columns":
		return (r["left"] as Array) + (r["right"] as Array)
	return (r["top"] as Array) + (r["bottom"] as Array)


## The RetroPad bit a control drives. Control keys are GamepadBindings targets,
## whose order IS the bit order — see the comment on TARGET_ORDER.
static func bit_of(control: String) -> int:
	return GamepadBindings.TARGET_ORDER.find(control)


## True when the diagram should recolour this art to follow the panel theme.
## Line art is white-on-alpha and wants it; a colour illustration does not.
static func tints(systemid: String) -> bool:
	var r := row(systemid)
	return bool(r.get("tint", true)) if not r.is_empty() else true


## The art for a platform, or null.
static func texture(systemid: String) -> Texture2D:
	var r := row(systemid)
	if r.is_empty():
		return null
	return load(String(r["art"])) as Texture2D
