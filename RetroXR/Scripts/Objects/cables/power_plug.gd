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

func plug_group() -> String:
	return connector_group

func plug_label() -> String:
	return connector_label
