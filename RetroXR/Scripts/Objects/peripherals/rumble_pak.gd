## RumblePak — the N64's haptics, as a thing you have to go and fetch.
##
## It sends nothing to libretro itself. The core drives haptics through
## RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE, which this project already answers all
## the way through to XRToolsRumbleManager; all this has to do is be seated, so
## RetroSystem fits "rumble" to that port and the core starts writing to the pak
## bus at all.
##
## The N64's rumble is BINARY. Every stage between the game and the frontend
## collapses it — the pak register becomes a start/stop enum, which becomes 0x01
## or 0x00, which becomes 0xFFFF or 0 on both motors. There is no strength here
## to expose and no curve worth fitting to it.
class_name RumblePak
extends N64Pak

const PLUG_SYSTEMID := "n64_rumble_pak"


func _ready() -> void:
	systemid = PLUG_SYSTEMID
	super._ready()


func pak_option_value() -> String:
	return "rumble"


func pak_label() -> String:
	return "Rumble Pak"
