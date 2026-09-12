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

# --- The controls -------------------------------------------------------------
#
# ControlAnimator, the same engine every pad and handheld face in the project
# runs on. A VMU has four buttons and a d-pad, and the d-pad rocks as one piece
# because on the real unit it is a disc with a cross moulded into it.
#
# The buttons map onto the RetroPad the way vemulator reads them: A and B are A
# and B, and MODE and SLEEP take START and SELECT — the VMU has no other pair to
# put them on.

## How far a cap sinks. The caps stand ~2 mm proud of a 16 mm body, and a cap
## driven flush reads as a hole rather than a press.
const PRESS_DEPTH := 0.0011

## Per-frame lerp weight toward the pressed pose.
const ANIM_WEIGHT := 0.4

## [node name, RetroPad bit]. Every one of these sits on the +Z face.
const _CONTROLS: Array = [
	["ButtonA", ControllerBindings.JOYPAD_A],
	["ButtonB", ControllerBindings.JOYPAD_B],
	["ModeButton", ControllerBindings.JOYPAD_START],
	["SleepButton", ControllerBindings.JOYPAD_SELECT],
]

var _anim: ControlAnimator = null
## The button mask last pushed in, which is what the controls animate from.
var _btn := 0
## Frames since anything needed driving. A released control lerps back to rest
## over a few frames, so the drive cannot stop the moment the mask clears — and a
## card doing nothing should not tick forever either, with eight of them in a
## room.
var _idle_frames := 0

## How long to keep driving after the last input, in frames. ANIM_WEIGHT 0.4
## settles well inside this.
const IDLE_FRAMES_TO_STOP := 24

# --- Standalone ---------------------------------------------------------------
#
# A VMU is a handheld in its own right: its own CPU, its own screen, its own
# buttons and two coin cells. Out of a controller it can run a downloaded
# minigame on the `vemulator` core, which is a whole machine in a 282 KB core.
#
# Deliberately NOT a RetroSystem. HandheldInput and the rest of that machinery
# hang off one, and a VMU is a card first — it has to keep being a card while it
# is seated. What it grows instead is a Libretro node of its own.

const STANDALONE_CORE := "vemulator"

## Where a game lifted off a card is written for the core to boot from.
const PLAY_DIR := "user://vmu_play"

var _lib: Node = null
var _running := false
## What the running game is called, for the panel's "playing" row. Empty when
## nothing runs.
var _game_title := ""
## The hand's buttons reaching the core — see VmuInput.
var _input: VmuInput = null


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
	_bind_controls()
	_input = VmuInput.attach(self)
	set_process(false)


# --- The controls -------------------------------------------------------------

func _bind_controls() -> void:
	_anim = ControlAnimator.new()
	# The pad's UP is its -Z arm in the pivot's frame, and a positive pitch about
	# X LIFTS what lies on -Z — so the sign flips for UP to depress it. Same
	# reason handheld_model's stand-in pass sets it.
	_anim.dpad_pitch_sign = -1.0
	_anim.dpad_tilt_deg = 6.0
	for spec: Array in _CONTROLS:
		var m := get_node_or_null(NodePath(str(spec[0]))) as MeshInstance3D
		if m == null:
			continue
		# `dir` is in the mesh PARENT's frame — the card's — where into the face
		# is -Z. The caps carry their own rotation to stand a cylinder up, and
		# that has no bearing on which way they travel.
		_anim.buttons.append({
			"node": m, "rest": m.transform, "bit": int(spec[1]),
			"depth": PRESS_DEPTH, "dir": Vector3(0, 0, -1),
		})
	# The animated node is the PIVOT, which is identity; the turn that puts the
	# face normal on +Y lives on the MOUNT above it, because the animator rotates
	# in the animated node's parent space. See the scene's own note.
	var pivot := get_node_or_null("DpadMount/DpadPivot") as Node3D
	if pivot != null:
		_anim.dpad = {"node": pivot, "rest": pivot.transform, "pivot": Vector3.ZERO}


## Push the button state this card's controls should show, and — while it is
## running standalone — what its core should read.
##
## One entry point for both, so a press can never animate without reaching the
## core or vice versa.
func set_input(btn: int) -> void:
	_btn = btn
	if _running and _lib != null:
		_lib.SetJoypadState(0, btn, 0, 0, 0, 0)
	# Wake the per-frame drive. The controls have to move whether or not this card
	# has a screen to fill — the animation gate and the picture gate are separate
	# questions, and conflating them left every button frozen while the animator
	# sat there correctly configured and never ticked.
	if btn != 0:
		_idle_frames = 0
		set_process(true)


## The mask currently held down. Read by the probes.
func input_mask() -> int:
	return _btn


# --- Seating ------------------------------------------------------------------

## Told by VmuPort which slot took this card, and on which pad.
func seated_in(pad: Node, slot: int) -> void:
	# A card in a controller is a memory card, not a handheld: its own buttons are
	# inside the pad and unreachable. Pushing it into a slot ends a standalone
	# game, which is what putting one in a Dreamcast does.
	power_off()
	_pad = pad
	_slot = slot
	# Slot 2 has no window in the shell and no screen in the core, so it never
	# needs driving. Neither does a loose, unpowered card.
	set_process(_slot == 0)
	if _slot != 0:
		_show_off()


func unseated() -> void:
	_pad = null
	_slot = -1
	if not _running:
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


# --- Standalone ---------------------------------------------------------------

## Power the card up as its own machine, running one minigame.
##
## `vms_path` is a .vms, .dci or .bin — the file a Dreamcast game downloaded into
## the card, or one out of a library. `title` is what to call it while it runs;
## the file name stands in when none is given. Returns false when the core is
## not installed, the file is missing or the card is seated, which is the
## difference between "nothing happened" and "it silently played nothing".
func power_on(vms_path: String, title := "") -> bool:
	if _running:
		return true
	if vms_path.is_empty() or not FileAccess.file_exists(vms_path):
		push_warning("[VmuCard] no such minigame: %s" % vms_path)
		return false
	var image := _flash_image_for(FileAccess.get_file_as_bytes(vms_path), vms_path)
	if image.is_empty():
		push_warning("[VmuCard] %s is not a VMU game, save or card" % vms_path.get_file())
		return false
	return _boot(image, title if not title.is_empty() else vms_path.get_file().get_basename())


## The 128 KiB flash image the core is handed, whatever the file was.
##
## A card image is taken as it is. A .dci or a .vms is put at block 0 of a
## blank card — where a game must sit, since with no BIOS the core runs the
## flash from its first byte.
func _flash_image_for(bytes: PackedByteArray, path: String) -> PackedByteArray:
	if VMUCard.is_card_image(bytes):
		return bytes
	var dci := bytes
	if not VMUCard.is_dci(dci):
		var stem := path.get_file().get_basename().to_upper()
		dci = VMUCard.dci_from_vms(bytes, stem if not stem.is_empty() else "GAME")
	if dci.is_empty():
		return PackedByteArray()
	return VMUCard.insert_save(VMUCard.blank_image(), dci)


## Boot the core on a flash image written to this card's scratch file.
##
## ALWAYS a .bin, never the .vms or .dci the game arrived as, and the reason
## is a crash in the core rather than a preference. vemulator's flash object
## opens a file handle only for a .bin with enable_flash_write on, and its
## destructor closes that handle unconditionally — but the member is never
## initialised, so on a .vms or .dci the handle is garbage and reset() dies in
## rfclose the moment the game is unloaded. Read at source (flash.cpp,
## flash.h, main.cpp) after the stop button took the process down with it. A
## .bin with writing on gives it a real handle to close, and the writes land
## in this scratch copy, never in the card. (The .dci path is also simply
## broken: a real one runs zero frames.)
func _boot(image: PackedByteArray, title: String) -> bool:
	var why := standalone_blocker()
	if not why.is_empty():
		push_warning("[VmuCard] cannot run %s: %s" % [title, why])
		return false
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(PLAY_DIR))
	var scratch := play_scratch_path()
	var f := FileAccess.open(scratch, FileAccess.WRITE)
	if f == null:
		push_warning("[VmuCard] could not write %s" % scratch)
		return false
	f.store_buffer(image)
	f.close()
	var root := CoreDownloadManager.default_core_root()
	CoreOptionsStore.merge_values(root, STANDALONE_CORE, {"enable_flash_write": "enabled"})

	# Made once and KEPT. Freeing a Libretro node whose emulation thread is still
	# unwinding is how a clean run ends in an access violation on the way out —
	# the same hazard as a GDExtension audio playback that outlives its
	# extension. Powering off stops the content and leaves the node in place for
	# the next game.
	if _lib == null:
		var lib: Object = ClassDB.instantiate("Libretro")
		_lib = lib as Node
		if _lib == null:
			push_warning("[VmuCard] could not instantiate a Libretro node")
			return false
		_lib.name = "VmuLibretro"
		add_child(_lib)
	_lib.StartContent(root, STANDALONE_CORE, ProjectSettings.globalize_path(scratch))
	_running = true
	_game_title = title
	# Its own screen now, not a window into a Dreamcast's frame.
	_last_tex = null
	_last_frame = Vector2i.ZERO
	set_process(true)
	if _hint != null:
		_hint.add_row(&"vmu_ab", HeldHint.PLATFORM_VR,
			["quest_button_a_outline", "quest_button_b_outline"], "A and B — stick is the d-pad")
		_hint.add_row(&"vmu_mode", HeldHint.PLATFORM_VR,
			["quest_stick_{s}_press"], "MODE")
	print("[VmuCard] %s running %s" % [card_label, title])
	return true


## Run one of this card's own game entries, the loop the hardware is remembered
## for: a Dreamcast game put it there, and the card plays it on its own.
##
## The entry is lifted off as a .dci — the form that carries its directory
## entry — and put at block 0 of a fresh image for the core, one scratch per
## card, overwritten each time. The card's own image is never touched, and
## nothing comes back to it: whatever the game writes lands in the scratch.
## `block` is the entry's first block, as list_saves reports it.
func play_save(block: int, title := "") -> bool:
	var path := SramPaths.find_card(card_id, FAMILY)
	if path.is_empty():
		push_warning("[VmuCard] %s has no image to play from" % card_label)
		return false
	var dci := VMUCard.extract_save(FileAccess.get_file_as_bytes(path), block)
	if dci.is_empty():
		push_warning("[VmuCard] no game at block %d on %s" % [block, card_label])
		return false
	var image := VMUCard.insert_save(VMUCard.blank_image(), dci)
	if image.is_empty():
		push_warning("[VmuCard] the game at block %d would not go onto a blank card" % block)
		return false
	return _boot(image, title)


## Where the image the core boots from is written. A .bin, see _boot.
func play_scratch_path() -> String:
	return PLAY_DIR.path_join("%s.bin" % card_id)


## Why this card cannot run a minigame right now, or "" when it can.
func standalone_blocker() -> String:
	if _slot >= 0:
		return "seated in a controller — pull it out first"
	if CoreDownloadManager.installed_core_lib(STANDALONE_CORE).is_empty():
		return "the %s core is not installed" % STANDALONE_CORE
	return ""


## The running game's name, or "" when the card is not running one.
func playing_title() -> String:
	return _game_title if _running else ""


func power_off() -> void:
	if not _running:
		return
	_running = false
	# StopContent, and the node is KEPT rather than freed.
	#
	# Measured, both ways round. Freeing it here crashes the process with an
	# access violation before the caller's next print — StopContent is
	# non-blocking, so the emulation thread is still unwinding through a node
	# that has just been queued for deletion. Keeping it costs one idle node per
	# card and is reused by the next power_on.
	#
	# That is a DIFFERENT crash from the audio-teardown race, which fires on
	# QUIT rather than on free and is fixed with frames on the caller's side.
	if _lib != null and _lib.has_method("StopContent"):
		_lib.StopContent()
	_btn = 0
	_game_title = ""
	if _hint != null:
		_hint.remove_row(&"vmu_ab")
		_hint.remove_row(&"vmu_mode")
	set_process(_slot == 0)
	_show_off()


func is_running_standalone() -> bool:
	return _running


## Whichever picture belongs on this card's face, and the window into it.
##
## Two sources, and they crop differently. Standalone, the core IS a VMU and its
## frame is the whole 48 x 32 screen, so the window is everything. Seated, the
## picture is a Dreamcast's frame with the LCD burned into one corner, so the
## window is that corner — see VmuStorage.screen_rect.
func _picture() -> Dictionary:
	if _running and _lib != null:
		var own: Texture2D = _lib.GetVideoTexture()
		if own != null:
			return {"tex": own, "whole": true}
		return {}
	var sys := host_system()
	if sys == null or not sys.has_method("get_video_texture"):
		return {}
	var tex: Texture2D = sys.call("get_video_texture")
	return {"tex": tex, "whole": false} if tex != null else {}


func _process(_delta: float) -> void:
	if _anim != null and not _anim.is_empty():
		_anim.animate(_btn, Vector2.ZERO, Vector2.ZERO, ANIM_WEIGHT)

	# Stop ticking once there is nothing left to do: no screen to fill, nothing
	# held, and the controls given long enough to settle back.
	var wants_screen := _running or _slot == 0
	if not wants_screen and _btn == 0:
		_idle_frames += 1
		if _idle_frames > IDLE_FRAMES_TO_STOP:
			set_process(false)
	else:
		_idle_frames = 0

	if _lcd == null:
		return
	var pic := _picture()
	if pic.is_empty():
		_show_off()
		return
	var tex: Texture2D = pic["tex"]
	var whole: bool = pic["whole"]

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
		var r := Rect2(0, 0, 1, 1) if whole else VmuStorage.screen_rect(frame_i)
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
