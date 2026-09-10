## VmuCard — a Dreamcast Visual Memory Unit, the object you can pick up.
##
## Two identities at once, the way a Controller Pak is both an N64Pak and a card:
##
##   * a CONTROLLER accessory. It seats in one of the two expansion slots on a
##     Dreamcast pad, so it joins "controller_plug" narrowed by a systemid
##     sentinel, exactly as N64Pak does. dreamcast.tres declares no card_family
##     and RetroSystem's own console-slot machinery stays out of this entirely.
##   * a MEMORY CARD. Its image lives at save/memcards/vmu/<card_id>.vmu and the
##     same shelf, panel, rename and delete serve it.
##
## Not a subclass of N64Pak, and not yet a shared base with it. The two have the
## seat in common and little else — a pak answers a per-port core option, a VMU
## answers a per-SLOT one and also carries a screen — so the common surface is
## not yet obvious enough to name. Extracting one once both exist is the cheap
## direction; guessing it now is not.
##
## Dimensions are the real unit's: 47 x 80 x 16 mm, 45 g, and an LCD of 48 x 32
## dots measuring 37 x 26 mm. Referenced rather than guessed — an earlier draft
## of this had it 8 mm thick.
class_name VmuCard
extends XRToolsPickable

## Read by the slot this is offered to. The sentinel that narrows a socket which
## would otherwise take any cable plug in the room.
const PLUG_SYSTEMID := "dreamcast_vmu"

## The card family: the folder under save/memcards/ and the byte format. Fixed —
## there is only one kind of VMU — but named `family` like every other card so
## CardFormats, SramPaths and MemoryCardPanel take it with no special case.
const FAMILY := "vmu"

const OPTIONS_PANEL_SCENE := preload("res://Scenes/UI/memory_card_panel.tscn")

## Height of the drop hint above the card, in metres. A VMU is a small object and
## the default 18 cm floats clear of it.
const HINT_HEIGHT := 0.10

## Read by everything that treats this as a card. See FAMILY.
var family: String = FAMILY

## Read by any slot this is offered to; see PLUG_SYSTEMID.
var systemid: String = PLUG_SYSTEMID

## Persistent identity, and literally the file name this card's saves live in
## (`<card_id>.vmu`).
@export var card_id: String = ""

## Display label on the card's back, and its filename on disk — see card_id.
@export var card_label: String = "VMU":
	set(v):
		card_label = v
		_update_label()

## True only for a card this session invented — the id was not handed in. Only
## such a card may have its image created; one restored from a saved room or
## spawned from the shelf is supposed to have an image already, and answering a
## card whose saves have gone missing with a silent blank reads exactly like the
## saves were wiped.
var minted := false

var _options_panel: MemoryCardPanel = null
var _hint: HeldHint = null


func _ready() -> void:
	super._ready()
	add_to_group("spawned")
	# The slot requires this group, the same one every cable plug joins. Being in
	# it is what makes a cable-less accessory seatable at all; the systemid is
	# what then narrows the socket to this one thing.
	add_to_group("controller_plug")
	add_to_group("vmu")
	# Numbering and the in-use check both sweep this group, and a VMU held by a
	# controller is exactly as much "in use" as a card in a console.
	add_to_group("memory_card")

	if card_label == "VMU":
		card_label = "VMU %d" % get_tree().get_nodes_in_group("vmu").size()
	if card_id.is_empty():
		card_id = SramPaths.unique_card_id(card_label)
		card_label = card_id
		minted = true
	_update_label()
	_hint = HeldHint.attach(self, true, HINT_HEIGHT)


## What flycast's per-slot device option should be set to while this is seated.
## The core's own vocabulary, because it is the core being told.
func slot_option_value() -> String:
	return "VMU"


## What to call this in a menu or a refusal.
func accessory_label() -> String:
	return "Visual Memory Unit"


## Where this card's saves live, or "" when the family is somehow unregistered.
func image_path() -> String:
	return SramPaths.card_save_path(FAMILY, card_id)


func _update_label() -> void:
	var lbl := get_node_or_null("CardLabel") as Label3D
	if lbl:
		lbl.text = card_label


## Open/close the save list, the same panel a memory card uses.
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		_options_panel = OPTIONS_PANEL_SCENE.instantiate()
		add_child(_options_panel)
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)
