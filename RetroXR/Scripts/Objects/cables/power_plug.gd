class_name PowerPlug
extends RcaPlug

@export_enum(
	"nema_5_15_plug",
	"iec_c13_plug",
	"nema_1_15_plug",
	"nema_1_15_polarized_plug",
	"iec_c7_plug",
	"iec_c7_polarized_plug",
) var connector_group := "nema_5_15_plug"
@export var connector_label := "a grounded power plug"


## The other sockets a connector physically enters, on top of its own.
##
## A NEMA 5-15R is a 1-15R with a ground hole added under it: the two blade slots
## sit in the same places, at the same widths, so both two-prong plugs drop
## straight into a modern outlet and simply leave the ground hole empty. That is
## how the lamp, the clock radio and every wall wart in the room are really
## powered, and it is why 1-15P is still on the shelf today. A room where the
## two-prong cords only went into two-prong outlets would have the player hunting
## for a socket that no house has fitted since the sixties.
##
## Stated one way round on purpose, which is the whole reason for a table here
## rather than one shared group. A 5-15P's ground pin has nowhere to go in a
## two-slot outlet, so a grounded plug still has to find a grounded socket, and a
## C7 is not a mains blade at all. Keyed by connector_group, listing the groups a
## plug JOINS in addition to its own.
const ALSO_FITS := {
	"nema_1_15_plug": ["nema_5_15_plug"],
	"nema_1_15_polarized_plug": ["nema_5_15_plug"],
}


func plug_group() -> String:
	return connector_group


func plug_label() -> String:
	return connector_label


func _ready() -> void:
	super._ready()
	# RcaPlug._ready has just put this plug in plug_group(). A snap zone filters
	# on ONE group name (XRToolsSnapZone.snap_require), so "it also fits a 5-15R"
	# is said by joining that outlet's group too, rather than by teaching every
	# port a list of what it tolerates. The seating gate, the held preview, the
	# aim highlight and the missed-socket report all ask the same is_in_group, so
	# saying it once here is enough for all four.
	var also: Array = ALSO_FITS.get(connector_group, [])
	for group in also:
		add_to_group(String(group))
