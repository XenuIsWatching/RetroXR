@tool
## A panel-mount RCA socket — the female half of the connector on cable.tscn's plug.
##
## The mesh is baked by Tools/gen/gen_rca_jack.gd with surface 0 the coloured
## insulator and surface 1 the chrome shell, so a jack is recoloured by tinting
## surface 0 and nothing else. That is the same split gen_rca_plug.gd uses, and the
## same one system.gd's _decorate_channel_plug relies on at the plug end.
##
## @tool so a colour set in the inspector shows without pressing play, which is the
## whole point of having it exported.
class_name RcaJack
extends MeshInstance3D


## The RCA colour code, for the audio pair this composite jack will eventually sit
## beside. Named rather than left as raw Colors so a red jack is `AUDIO_RED` in the
## scene that wants one.
const COMPOSITE_YELLOW := Color(0.95, 0.74, 0.02)
const AUDIO_WHITE := Color(0.87, 0.87, 0.84)
const AUDIO_RED := Color(0.72, 0.08, 0.08)

## The jacket every wire in the room wears. The colour code above belongs to
## CONNECTORS; a lead is black whatever it carries, on the spawnable composite
## leads and on the pigtail fixed to a handheld alike. Kept beside them so the two
## cannot drift apart — cable.tscn writes the same value as a literal, since a
## .tscn cannot reference a constant.
const WIRE_BLACK := Color(0.05, 0.05, 0.06)

## Colour of the plastic insulator. The metal is not tintable on purpose: plated
## shells are the same on every jack, and letting a scene recolour one would only
## produce jacks that do not exist.
@export var jack_color: Color = COMPOSITE_YELLOW:
	set(value):
		jack_color = value
		_apply_color()


func _ready() -> void:
	# The exported value may have been assigned before `mesh` was, in which case the
	# setter had nothing to write to.
	_apply_color()


func _apply_color() -> void:
	# The bake wears Shaders/connector.gdshader, whose plastic takes its colour
	# from this instance parameter: one shared material for every jack in the
	# room, and no copy of it per colour.
	set_instance_shader_parameter(&"tint", jack_color)
