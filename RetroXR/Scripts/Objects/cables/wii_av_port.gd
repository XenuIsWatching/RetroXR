## The Wii's AV Multi Out. Everything about how one hole carries three signals lives in
## MultiAvPort; the only thing that is the Wii's own is which leads it accepts.
##
## The RVL-009 and nothing else. The shell is the same one the SNES, N64 and GameCube
## wear, so a lead off any of them physically fits — and on real hardware would give no
## picture, because the Wii moved the signals to different pins. The group is where that
## is enforced.
class_name WiiAvPort
extends MultiAvPort


func plug_group() -> String:
	return "wii_av_plug"
