class_name PowerPort
extends XRToolsSnapZone

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
	super._ready()
