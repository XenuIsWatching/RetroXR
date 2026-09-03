## ControllerPak — the N64's 32 KiB of removable save memory.
##
## A memory card in every way that matters, so it carries a memory card's
## identity: the image lives at save/memcards/controller_pak/<card_id>.mpk and
## the same shelf, panel, rename and delete serve it. What it is NOT is a console
## card — it plugs into a CONTROLLER, so nintendo_64 declares no card_family and
## RetroSystem's own slot machinery stays out of this entirely.
##
## The bytes are not the core's to keep. mupen64plus-next points all four paks at
## one slab inside its single SAVE_RAM blob and backs them with a read-only
## storage backend whose save is a no-op, so nothing the core does persists a pak.
## RetroSystem binds this pak's file over that port's slice instead.
class_name ControllerPak
extends N64Pak

const PLUG_SYSTEMID := "n64_controller_pak"

## The family this pak's image belongs to. Fixed — unlike a memory card, there is
## only one kind of Controller Pak — but named the same so CardFormats,
## SramPaths and MemoryCardPanel all take it without a special case.
const FAMILY := "controller_pak"

const OPTIONS_PANEL_SCENE := preload("res://Scenes/UI/memory_card_panel.tscn")

## Read by everything that treats this as a card. See FAMILY.
var family: String = FAMILY

## Persistent identity, and literally the file name this pak's notes live in
## (`<card_id>.mpk`).
@export var card_id: String = ""

## Display label on the pak's face, and its filename on disk — see card_id.
@export var card_label: String = "CONTROLLER PAK":
	set(v):
		card_label = v
		_update_label()

## True only for a pak this session invented — the id was not handed in. Only
## such a pak may have its image created; one restored from a saved room or
## spawned from the shelf is supposed to have an image already, and answering a
## pak whose notes have gone missing with a silent blank reads exactly like the
## notes were wiped.
var minted := false

var _options_panel: MemoryCardPanel = null


func _ready() -> void:
	systemid = PLUG_SYSTEMID
	super._ready()
	# Numbering and the in-use check both sweep this group, and a pak being held
	# by a controller is exactly as much "in use" as a card in a console.
	add_to_group("memory_card")

	if card_label == "CONTROLLER PAK":
		card_label = "CONTROLLER PAK %d" % get_tree().get_nodes_in_group("n64_pak").size()
	if card_id.is_empty():
		card_id = SramPaths.unique_card_id(card_label)
		card_label = card_id
		minted = true
	_update_label()


func pak_option_value() -> String:
	return "memory"


func pak_label() -> String:
	return "Controller Pak"


## Where this pak's notes live, or "" when the family is somehow unregistered.
func image_path() -> String:
	return SramPaths.card_save_path(FAMILY, card_id)


func _update_label() -> void:
	var lbl := get_node_or_null("CardLabel") as Label3D
	if lbl:
		lbl.text = card_label


## Open/close the pak's note list, the same panel a memory card uses.
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		_options_panel = OPTIONS_PANEL_SCENE.instantiate()
		add_child(_options_panel)
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)
