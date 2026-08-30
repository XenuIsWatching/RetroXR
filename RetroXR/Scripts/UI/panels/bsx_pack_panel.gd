## BsxPackPanel — what is written on the Satellaview pack you are pointing at.
##
## A `.bs` pack in the room is an ordinary RetroCartridge, so TAB on one used to
## open CartridgeOptionsPanel and offer Saves, States and Achievements. A pack is
## a medium, not a game: it has none of those, and it does have several programmes
## written across eight blocks of flash. Cartridge.toggle_options_ui sends packs
## here instead.
##
## Mirrors MemoryCardPanel, which is the same shape of thing — a small removable
## medium with a list of what is on it. The 2D half is BsxPackContents2D, the same
## Control the spawn menu embeds, so the list has one implementation.
##
## The image is re-read every time the panel opens. A pack seated in a running
## BS-X is being written to as the player downloads, so anything cached from last
## time would be a picture of the pack as it was.
class_name BsxPackPanel
extends FloatingObjectPanel3D

## Height above the pack's origin at which the panel floats. A pack is small and
## usually on a table or in a bay, so this sits nearer than a console's panel.
const FLOAT_HEIGHT := 0.28

var _pack: Node3D = null

@onready var _viewport_node: XRToolsViewport2DIn3D = $BsxPackViewport


func show_for(pack: Node3D, camera: Node3D) -> void:
	_pack = pack
	_camera = camera
	if _pack:
		global_position = _pack.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	visible = true
	_ensure_ui_connected()
	_populate()


func _target_node() -> Node3D:
	return _pack


func _float_height() -> float:
	return FLOAT_HEIGHT


func _get_ui() -> BsxPackContents2D:
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		return null
	return vp.get_child(0) as BsxPackContents2D


func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var ui := _get_ui()
	if not ui:
		# The viewport builds its scene a frame late; ask again rather than
		# binding to nothing and looking connected.
		call_deferred("_ensure_ui_connected")
		return
	ui.close_requested.connect(hide_panel)
	_ui_connected = true


func _populate() -> void:
	var ui := _get_ui()
	if ui == null:
		call_deferred("_populate")
		return
	var path := _pack_path()
	if path.is_empty():
		ui.populate("Memory Pack", [], BsxPack.BLOCK_COUNT, BsxPack.BLOCK_COUNT)
		return
	var data := FileAccess.get_file_as_bytes(path)
	ui.populate(path.get_file().get_basename(),
		BsxPack.programmes_of(data),
		BsxPack.free_blocks(data),
		BsxPack.BLOCK_COUNT)


## The pack's own file. `rom_path` is what a RetroCartridge calls the medium it
## stands for; anything else pointed at here has none and shows an empty pack.
func _pack_path() -> String:
	if _pack == null or not is_instance_valid(_pack):
		return ""
	var p: Variant = _pack.get("rom_path")
	return str(p) if p != null else ""
