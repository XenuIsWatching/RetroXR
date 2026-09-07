## The Nintendo 64's AV MULTI OUT. Everything about how one hole carries three signals
## lives in MultiAvPort; the only thing that is the N64's own is which leads it accepts.
##
## The shell is the 12-pin one Nintendo put on the SNES, the N64, the GameCube and the
## Wii, so a lead off any of them physically fits this socket. Three of those four share
## a pinout and one does not: the SNS-008 stereo AV cable shipped with the Super
## Nintendo, the N64 AND the GameCube and works on all three, while a Wii lead moved the
## signals and gives nothing here — which is why N64-to-Wii adapters are sold. So the
## group is the pinout, not the machine.
##
## A Super Nintendo or GameCube model added later belongs on THIS port and THIS lead.
## Do not mint a third group for them: that would refuse a cable the hardware accepts,
## which is the mistake in the opposite direction from the one this group prevents.
class_name N64AvPort
extends MultiAvPort


func plug_group() -> String:
	return "n64_av_plug"
