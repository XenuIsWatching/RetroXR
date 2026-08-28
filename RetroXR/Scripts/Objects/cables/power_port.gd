class_name PowerPort
extends XRToolsSnapZone

## Every mains socket in the tree, so a loose plug can be asked which one is
## holding it. A power plug cannot answer that itself the way an RcaPlug does:
## RcaPlug.seated_port() walks RcaPort.GROUP, and this is a plain snap zone
## rather than an RcaPort, so it finds nothing and a saved room forgot what was
## plugged in where.
const GROUP := "power_port"

@export_enum(
	"nema_5_15_plug",
	"iec_c13_plug",
	"nema_1_15_plug",
	"nema_1_15_polarized_plug",
	"iec_c7_plug",
	"iec_c7_polarized_plug",
) var accepted_plug := "nema_5_15_plug"


func _ready() -> void:
	snap_require = accepted_plug
	add_to_group(GROUP)
	super._ready()


## The plug sitting in this socket, or null when it is empty.
func seated_plug() -> PowerPlug:
	return picked_up_object as PowerPlug


## The object a save file names this socket against, which is not the socket's
## own parent.
##
## A slot records a reference either as the id of another saved object or, for
## something that was already standing in the room, as a node path (see
## ScenePersistence._ref). Both need the node the socket can be FOUND under
## again: the wall outlet is furniture and comes back at the same path, while a
## console is spawned fresh every load and only its own root carries an id. The
## node in between, a socket's immediate parent inside a console's model, is
## neither, and naming that would write a path that means nothing next load.
##
## So: the nearest spawned ancestor if the socket belongs to something the save
## owns, else the nearest ancestor at all, which is the fixture case.
func get_device() -> Node3D:
	var at: Node = get_parent()
	var fixture: Node3D = null
	while at != null:
		if at.is_in_group("spawned"):
			return at as Node3D
		if fixture == null:
			fixture = at as Node3D
		at = at.get_parent()
	return fixture
