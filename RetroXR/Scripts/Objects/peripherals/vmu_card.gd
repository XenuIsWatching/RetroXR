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

const SCREEN_WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")

var _options_panel: MemoryCardPanel = null
var _hint: HeldHint = null

# --- The screen ---------------------------------------------------------------
#
# flycast burns the VMU's 48 x 32 LCD into a corner of the main framebuffer, so
# the card's face shows that corner cropped back out with screen_window — the
# same mechanism the 3DS bottom screen uses on a composite frame. The rect and
# the options that put it there live on VmuStorage.
#
# Only SLOT 1 lights up. That is the hardware (only the front slot has a window
# in the controller's shell) and the core agrees: its screen options are indexed
# per port and gate on the slot-1 device alone.

## Which slot this card is seated in, or -1 when it is loose. Set by VmuPort.
var _slot := -1
## The pad it is seated in, for reaching the machine on the other end.
var _pad: Node = null

var _lcd: MeshInstance3D = null
var _lcd_off_mat: Material = null
var _lcd_mat: ShaderMaterial = null
var _last_tex: Texture2D = null
var _last_frame := Vector2i.ZERO


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

	_lcd = get_node_or_null("Lcd") as MeshInstance3D
	if _lcd != null:
		# The authored dark panel is what a VMU shows with nothing driving it, and
		# is kept rather than rebuilt so an unseated card looks the same as it
		# does on a shelf.
		_lcd_off_mat = _lcd.get_surface_override_material(0)
	set_process(false)


# --- Seating ------------------------------------------------------------------

## Told by VmuPort which slot took this card, and on which pad.
func seated_in(pad: Node, slot: int) -> void:
	_pad = pad
	_slot = slot
	# Slot 2 has no window in the shell and no screen in the core, so it never
	# needs driving. Neither does a loose card.
	set_process(_slot == 0)
	if _slot != 0:
		_show_off()


func unseated() -> void:
	_pad = null
	_slot = -1
	set_process(false)
	_show_off()


## The machine this card is plugged into, through the pad holding it, or null.
func host_system() -> Node:
	if not is_instance_valid(_pad) or not _pad.has_method("get_connected_system"):
		return null
	var sys: Node = _pad.call("get_connected_system")
	return sys if is_instance_valid(sys) else null


# --- The screen ---------------------------------------------------------------

func _show_off() -> void:
	if _lcd != null and _lcd.get_surface_override_material(0) != _lcd_off_mat:
		_lcd.set_surface_override_material(0, _lcd_off_mat)
	_last_tex = null
	_last_frame = Vector2i.ZERO


func _process(_delta: float) -> void:
	if _lcd == null:
		return
	var sys := host_system()
	if sys == null or not sys.has_method("get_video_texture"):
		_show_off()
		return
	var tex: Texture2D = sys.call("get_video_texture")
	if tex == null:
		_show_off()
		return

	if _lcd_mat == null:
		_lcd_mat = ShaderMaterial.new()
		_lcd_mat.shader = SCREEN_WINDOW_SHADER

	# The texture is a NEW object whenever the core changes resolution, so it is
	# read every frame and only pushed when it differs. The rect has to be
	# recomputed with it: flycast places the panel relative to the output size,
	# so a rect worked out once goes wrong the moment the core resizes.
	if tex != _last_tex:
		_last_tex = tex
		_lcd_mat.set_shader_parameter("source_tex", tex)
	var frame := tex.get_size()
	var frame_i := Vector2i(int(frame.x), int(frame.y))
	if frame_i != _last_frame:
		_last_frame = frame_i
		var r := VmuStorage.screen_rect(frame_i)
		_lcd_mat.set_shader_parameter("source_rect",
			Vector4(r.position.x, r.position.y, r.size.x, r.size.y))

	if _lcd.get_surface_override_material(0) != _lcd_mat:
		_lcd.set_surface_override_material(0, _lcd_mat)


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
