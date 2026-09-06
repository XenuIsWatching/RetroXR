## Wall switch gang — a VRButton over one toggle bat.
##
## Two of these sit on the bedroom's two-gang plate: the left one kills the room's
## ceiling lights, the right one the string-light strands.
##
## The ceiling gang toggles `visible`, never `light_energy`. QualityManager.
## _adjust_lights() owns the energy of every node in the "ceiling_light" group
## (0.8 desktop, 0.6 Quest) and rewrites it whenever the quality tier changes, so a
## switch that wrote an energy back would be silently undone. The string gang has no
## such owner and StringLights.set_lit() does write energies — see the note there.
##
## One class for both, deliberately: object_sync captures room state by walking
## `find_children("*", "LightSwitch")` and keys each record by NODE PATH, and
## applies an EV_ROOM_LIGHTS event through `set_lights_on` on the switch the event
## names. A second gang of the same class is therefore replicated to a late joiner
## and to every peer with no netplay change at all. A separate class would have
## needed both.
class_name LightSwitch
extends Node3D


## What this gang drives.
enum Target {
	CEILING,        ## the "ceiling_light" fixtures and their "light_glow" shades
	STRING,         ## every StringLights strand in the "string_light" group
}

@export var target: Target = Target.CEILING

## Starting state. The room is authored lit, so this is true.
@export var lights_on: bool = true

## Group the string gang drives. Its members answer set_lit(), the same call the
## ceiling gang makes on a GlowMesh.
const STRING_GROUP := &"string_light"

## Half the bat's throw, in radians about the button's local X. 0.42 rad is 24 deg
## either side of the plate normal, which is about what a real toggle gives and is
## enough to read across a room; the 17 deg this started at did not.
##
## The SIGN is not free. The bat is authored running along +Z, out of the wall (see
## gen_light_switch.gd), and Rx(+t) takes +Z toward -Y — so a POSITIVE rotation
## swings the tip DOWN. Lights on is therefore -LEVER_TILT, and the probe asserts the
## tip is higher when on rather than trusting this comment.
const LEVER_TILT := 0.42

## Dead band about the bat's pivot, in metres of the button's local Y. A fingertip
## inside it is on neither half and works the switch in neither direction, so the
## two halves cannot fight over a tip resting on the pivot.
const POKE_DEAD_BAND := 0.0015

var _button: VRButton = null
var _lever: Node3D = null


func _ready() -> void:
	_button = find_child("Button", true, false) as VRButton
	if _button == null:
		return
	_button.button_pressed.connect(_on_pressed)
	_button.press_gate = _poke_allowed
	_lever = _button.get_node_or_null("ButtonMesh") as Node3D
	_apply()


## Which half of the bat a poke has to land on, and it is the half the bat is
## currently STICKING OUT of: a lever thrown up is pushed down by a finger on its
## top, and one thrown down is flicked back up from underneath. Without the gate a
## fingertip approaching straight through the plate works the switch either way,
## which reads as a doorbell rather than a toggle.
##
## Local Y of the Button node is the plate's own up (the plate is only ever turned
## about the room's Y to face its wall), so no basis work is needed here.
func _poke_allowed(tip: Vector3) -> bool:
	if _button == null:
		return true
	var y: float = _button.to_local(tip).y
	return y >= POKE_DEAD_BAND if lights_on else y <= -POKE_DEAD_BAND


func _on_pressed() -> void:
	set_lights_on(not lights_on)
	NetworkManager.report_event(NetEvents.Event.EV_ROOM_LIGHTS,
		{"switch": self, "on": lights_on})


func set_lights_on(on: bool) -> void:
	lights_on = on
	_apply()


func _apply() -> void:
	match target:
		Target.CEILING:
			for node in get_tree().get_nodes_in_group("ceiling_light"):
				var light := node as Light3D
				if light != null:
					light.visible = lights_on
			# Darken the fixture's own glass along with its light, or the switch
			# leaves a glowing shade hanging over an unlit room.
			for node in get_tree().get_nodes_in_group("light_glow"):
				var glow := node as GlowMesh
				if glow != null:
					glow.set_lit(lights_on)
		Target.STRING:
			for node in get_tree().get_nodes_in_group(STRING_GROUP):
				var strand := node as StringLights
				if strand != null:
					strand.set_lit(lights_on)
	if _lever != null:
		_lever.rotation.x = -LEVER_TILT if lights_on else LEVER_TILT
