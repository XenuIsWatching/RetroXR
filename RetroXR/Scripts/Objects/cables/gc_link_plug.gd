## The GameCube end of a GameCube-to-Game Boy Advance lead.
##
## The only asymmetric connector in the room: this end goes into a console's
## controller socket and the other into a handheld's EXT port, and neither will
## enter the other's. That is what plug_group() has been for since the link cable
## was built, and this is the cable it was waiting for.
##
## It is a CONTROLLER PLUG as far as the console is concerned, because that is
## what the socket takes and what the machine on the other end of the lead
## becomes: a Game Boy Advance on a GameCube port is a pad with a screen. Saying
## so in `device_type` is the whole of how the console finds out -- RetroSystem
## announces a seated plug's device type to the core, so plugging the lead in IS
## telling Dolphin there is a handheld on that port. Nothing else has to know.
class_name GcLinkPlug
extends RcaPlug

## What a Game Boy Advance on a GameCube lead is, as libretro counts devices.
## Matches RETRO_DEVICE_GBA_LINK in DolphinLibretro: (7 << 8) | RETRO_DEVICE_NONE.
const DEVICE_GBA_LINK := (7 << 8) | 0

## Read by RetroSystem when this plug seats, and announced to the core.
var device_type: int = DEVICE_GBA_LINK

## Which console's ports will take it. RetroSystem's port filter reads this off
## the plug: a GameCube lead is not a Wii lead and not a PlayStation lead, and
## the socket says so before anything electrical is decided.
var systemid: String = "gamecube"

## The console and port this end is sitting in, or null and -1. Set by the
## console itself, which is the only thing that knows: a controller socket is a
## plain snap zone rather than an RcaPort, so the usual walk to find the port a
## plug sits in has nothing to find.
var seated_system: Node3D = null
var seated_port_index: int = -1


func plug_group() -> String:
	return "gc_link_plug"


func plug_label() -> String:
	return "a GameCube controller plug"


func _ready() -> void:
	super._ready()
	# In BOTH groups: its own, so the cable's own bookkeeping can find it and so
	# nothing else mistakes it for a phono plug, and "controller_plug" because
	# that is the string a console's ports filter on. A connector that fits a
	# socket has to answer to the name the socket asks for.
	add_to_group("controller_plug")


## Called by RetroSystem when this plug snaps into one of its ports.
func on_plugged_in(system: RetroSystem, port_index: int) -> void:
	seated_system = system
	seated_port_index = port_index
	_tell_cable()


## Called by RetroSystem when it is pulled out.
func on_unplugged() -> void:
	seated_system = null
	seated_port_index = -1
	_tell_cable()


func _tell_cable() -> void:
	if is_instance_valid(cable) and cable.has_method("on_plug_seating_changed"):
		cable.on_plug_seating_changed()
