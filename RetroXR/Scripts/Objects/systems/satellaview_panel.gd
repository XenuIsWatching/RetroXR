## SatellaviewPanel — the two lamps on the front of a Satellaview, and only those.
##
## The real unit wears POWER and ACCESS. Both report the MACHINE: POWER follows
## the console the unit is bolted under, and ACCESS is the hardware's own -- the
## BS-X switches it through $2194 bit 2 while the tuner is moving data, and the
## core reports that edge over libretro's LED interface, so it lights because the
## emulated machine said so.
##
## It sits on its own node rather than inside RetroExpansion because it is the one
## thing on that unit true of a single expansion and no other. The expansion builds
## a box, a connector and a bay out of the catalog; this builds a face, and the
## catalog names it -- `ExpansionCatalog.panel_of`, beside the row for the machine
## that wears it, rather than an id test in the expansion. It finds its console
## through the unit's `host_changed` signal, so the expansion carries no lamp
## wiring at all.
##
## Emissive meshes, not lights: a tiny near-surface omni dies on the Quest mobile
## backend (see the note on lamp glows elsewhere in this project).
class_name SatellaviewPanel
extends Node3D

## snes9x reports index 0 as the Satellaview's ACCESS lamp. Other indices belong
## to other machines and are ignored rather than lighting this one.
const CORE_LED_ACCESS := 0

## Where the lamp names sit: under the domes, on the empty left of the face. The
## two are spaced to fit their own names -- at the 17 mm they started at, POWER
## and ACCESS ran into each other and read as one word.
const LED_LABEL_Y := 0.0155

## The unit this face belongs to, and the console under it.
var _unit: RetroExpansion = null
var _host: RetroSystem = null

var _led_power_mat: StandardMaterial3D = null
var _led_access_mat: StandardMaterial3D = null
## True while the core says the tuner is moving data.
var _access_on := false
## Last POWER state painted, so the lamp is only repainted when it changes.
var _lamp_powered := false


## The unit is this panel's parent -- ExpansionCatalog names the scene and
## RetroExpansion adds it -- so the lamps ride the box wherever it is carried.
func _ready() -> void:
	_unit = get_parent() as RetroExpansion
	if _unit == null:
		# Opened on its own rather than hung on a unit: nothing to measure a
		# face against, and no console to report.
		set_process(false)
		return
	# One measurement for all four fixtures. size() is a catalog lookup, and the
	# face they sit on is the same face for every one of them.
	var face_z := _unit.size().z * 0.5
	_led_power_mat = _make_led(-0.126, 0.024, face_z, "LedPower")
	_led_access_mat = _make_led(-0.080, 0.024, face_z, "LedAccess")
	# Named on the case, as they are on the real unit -- raised lettering there,
	# a plate here. A lamp nobody can read is decoration.
	_make_led_label(-0.126, face_z, "POWER", "LabelPower")
	_make_led_label(-0.080, face_z, "ACCESS", "LabelAccess")
	_unit.host_changed.connect(_on_host_changed)
	# A console can already be bolted on: a restore binds the host through the
	# same calls a hand does, and it need not wait for this node to exist.
	_on_host_changed(_unit.get_host())


func _on_host_changed(sys: RetroSystem) -> void:
	if _host == sys:
		return
	_unwatch_access_lamp(_host)
	_host = sys
	_watch_access_lamp(sys)
	# Nothing to poll with no machine under us -- the same thing RetroSystem
	# does with its own idle process.
	set_process(sys != null)
	_update_lamps()


## Follow the console's core so the ACCESS lamp is driven by the emulated machine.
func _watch_access_lamp(sys: RetroSystem) -> void:
	if _led_access_mat == null or sys == null or not sys.has_method("get_libretro_node"):
		return
	var node: Libretro = sys.get_libretro_node()
	if node == null or not node.has_signal("led_state"):
		return
	if not node.led_state.is_connected(_on_core_led):
		node.led_state.connect(_on_core_led)


func _unwatch_access_lamp(sys: RetroSystem) -> void:
	# The machine is going; the lamp cannot still be reporting traffic.
	_access_on = false
	if sys == null or not is_instance_valid(sys) or not sys.has_method("get_libretro_node"):
		return
	var node: Libretro = sys.get_libretro_node()
	if node == null or not node.has_signal("led_state"):
		return
	if node.led_state.is_connected(_on_core_led):
		node.led_state.disconnect(_on_core_led)


func _on_core_led(led: int, on: bool) -> void:
	if led != CORE_LED_ACCESS or _access_on == on:
		return
	_access_on = on
	_update_lamps()


## The name under a lamp. Small, unlit and slightly proud of the case, so it
## reads as printing on the shell rather than as another light.
func _make_led_label(x: float, face_z: float, text: String, tag: String) -> void:
	var lbl := Label3D.new()
	lbl.name = tag
	lbl.text = text
	lbl.pixel_size = 0.00016
	lbl.font_size = 28
	lbl.outline_size = 0
	lbl.modulate = Color(0.82, 0.82, 0.86)
	lbl.no_depth_test = false
	lbl.position = Vector3(x, LED_LABEL_Y, face_z + 0.0012)
	add_child(lbl)


## A small domed LED on the front face (+Z). Emissive so it glows without a light.
func _make_led(x: float, y: float, face_z: float, tag: String) -> StandardMaterial3D:
	var led := MeshInstance3D.new()
	led.name = tag
	var sph := SphereMesh.new()
	sph.radius = 0.004
	sph.height = 0.008
	sph.radial_segments = 12
	sph.rings = 6
	led.mesh = sph
	led.position = Vector3(x, y, face_z + 0.001)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.05, 0.05)
	mat.roughness = 0.35
	mat.emission_enabled = true
	mat.emission = Color(0, 0, 0)
	mat.emission_energy_multiplier = 0.0
	led.set_surface_override_material(0, mat)
	# A 4 mm dome earns nothing from a grab outline, and PickableHighlight builds
	# one overlay mesh per MeshInstance3D it finds -- on a unit whose only other
	# mesh is the body, the two lamps would be two thirds of that work.
	led.add_to_group("outline_exclude")
	add_child(led)
	return mat


## The console has no power signal, so the lamp watches. One bool compare a
## frame, and only on the unit that has lamps at all.
func _process(_delta: float) -> void:
	if _is_powered() != _lamp_powered:
		_update_lamps()


func _is_powered() -> bool:
	return is_instance_valid(_host) and _host.is_powered_on


## Paint both lamps from the machine's own state.
##
## Colours are a choice: the labels are documented on the real front panel but I
## have no photometric reference for them, so POWER is the green every other
## powered thing in this room uses and ACCESS is the amber of an activity light.
func _update_lamps() -> void:
	_lamp_powered = _is_powered()
	_set_led(_led_power_mat, Color(0.10, 1.0, 0.20), 2.5 if _lamp_powered else 0.0)
	_set_led(_led_access_mat, Color(1.0, 0.72, 0.12), 3.0 if _access_on else 0.0)


func _set_led(mat: StandardMaterial3D, color: Color, energy: float) -> void:
	if mat == null:
		return
	mat.emission = color
	mat.emission_energy_multiplier = energy
	# A lit LED's body reads as its own colour; a dark one as near-black plastic.
	mat.albedo_color = color.darkened(0.6) if energy > 0.01 else Color(0.05, 0.05, 0.05)
