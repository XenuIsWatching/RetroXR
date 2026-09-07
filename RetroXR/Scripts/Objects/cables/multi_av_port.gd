## A Nintendo Multi AV socket — ONE hole carrying the picture and both audio channels.
##
## Every other socket in the room is one signal down one wire, which is why RcaPort can
## get away with a single `channel`. This connector is the exception the whole
## `channel_for(cord)` rule exists for: the lead seated here is a three-cord lead, and
## which signal a cord carries depends on which cord it is rather than on which socket
## it is in.
##
## The mapping is the CORD INDEX, and it is the same one every multi-out lead draws its
## far end in: cord 0 yellow to VIDEO, cord 1 white to L, cord 2 red to R. So a player
## who runs the lead's yellow plug into the set's yellow socket gets a picture, and one
## who crosses them gets exactly what crossing them does on the real hardware — which is
## the whole reason CompositeCable resolves routing from sockets instead of believing
## the colours.
##
## An RcaPort otherwise, and deliberately: GROUP membership so a plug can find the
## socket holding it, get_device() so the link resolves to the console, and the OUT/IN
## direction that decides which way a cord carries. CompositeCable._resolve reads
## RcaPort, and this is one.
##
## The jack visual is a child named for its own machine (WiiAvJack, N64AvJack), so
## RcaPort's own _tint_jack and show_jack — both of which look for a child named
## RcaJack — find nothing and no-op. That is wanted: this socket has no colour code.
##
## Subclassed rather than used directly, because `plug_group` is the one thing that
## differs and it is the thing that matters. Nintendo used the same 12-pin shell on the
## SNES, N64, GameCube and Wii, but the pinouts are not the same and a Wii lead does not
## work on an N64 — which is why N64-to-Wii adapters are a product. Two subclasses
## naming two groups is how the room refuses a lead that would not have worked.
class_name MultiAvPort
extends RcaPort


## Cord index to signal. Indexed directly, so the order is the contract — see the note
## above and each lead's cord_colors, which has to match it.
const CORD_CHANNELS := [
	RcaPort.Channel.VIDEO,
	RcaPort.Channel.AUDIO_L,
	RcaPort.Channel.AUDIO_R,
]


## Out of range falls back to VIDEO rather than erroring: a lead with more cords than
## this connector has signals is a scene mistake, and one that silently carries the
## picture is easier to see than one that crashes the room.
func channel_for(cord: int) -> Channel:
	if cord < 0 or cord >= CORD_CHANNELS.size():
		return Channel.VIDEO
	return CORD_CHANNELS[cord]


## A console's output, always. Pinned here rather than left to the scene for the reason
## VgaPort pins its own: every machine with this socket is a source, so an IN authored
## by mistake would be a silent dead lead.
func _ready() -> void:
	super._ready()
	direction = RcaPort.Direction.OUT
	channel = RcaPort.Channel.VIDEO
