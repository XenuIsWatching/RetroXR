## N64Pak — what goes into the expansion port on the back of an N64 controller.
##
## Three of them: a Rumble Pak, a Controller Pak and a Transfer Pak. They share
## almost nothing physically and everything structurally, so what lives here is
## the structure — being seatable in a controller's port, and answering for which
## core option that port should take.
##
## Shaped after MotionPlus rather than ExpansionCatalog. That table's `host` is a
## CONSOLE systemid and RetroExpansion._accepts_host hard-requires a RetroSystem,
## so an expansion in this room cannot belong to a controller. The Wii Remote's
## ExpansionPort already solved that, and this is the same object on the other
## console: a pickable in the "controller_plug" group, narrowed to one socket by
## a systemid sentinel.
class_name N64Pak
extends XRToolsPickable

## Height of the drop hint above the pak, in metres. These are small objects and
## the default 18 cm floats clear of them.
const HINT_HEIGHT := 0.08

## Read by any socket this is offered to, and what the controller's expansion
## port narrows on. Subclasses set it in their own _ready before calling up.
var systemid: String = ""

var _hint: HeldHint = null


func _ready() -> void:
	super._ready()
	add_to_group("spawned")
	# The port requires this group, the same one every cable plug joins. Being in
	# it is what makes a cable-less pak seatable at all; the systemid is what then
	# narrows the socket to this one thing.
	add_to_group("controller_plug")
	add_to_group("n64_pak")
	_hint = HeldHint.attach(self, true, HINT_HEIGHT)


## The value this pak asks its port's core option to take. The core's own
## vocabulary, because it is the core that is being told: "rumble", "memory",
## "transfer". A core that does not offer the value leaves the port alone.
func pak_option_value() -> String:
	return ""


## What to call this in a menu or a refusal.
func pak_label() -> String:
	return "Pak"
