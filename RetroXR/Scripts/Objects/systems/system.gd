## RetroSystem — pickable retro console that loads a libretro core and renders to a connected TV.
class_name RetroSystem
extends XRToolsPickable


## True when this hardware has a bespoke model — an authored scene or a model
## script — rather than the procedural placeholder every other system shows.
## The spawn menu uses it to decide whether a system's hardware row is the real
## thing (named after it) or already the stand-in.
static func has_bespoke_model(sysid: String) -> bool:
	return SystemModelRegistry.has_any_model(sysid)


## True when this hardware has an authored stand-in model scene, i.e. spawning it
## with variant "primitive" gives plain geometry shaped like the device rather
## than the generic console box.
static func has_primitive_model(sysid: String) -> bool:
	return SystemModelRegistry.has_plain_alternative(sysid)


## The libretro core filename (without extension), e.g. "fceumm".
## If empty at power_on(), looked up from CoreDefaults using systemid.
@export var core_name: String = ""

## Root directory passed to the C++ core loader (NOT the cores/ subdir — C++ appends that).
## If empty at power_on(), defaults to CoreDownloadManager.default_core_root().
@export_dir var core_directory: String = ""

## Human-readable label shown in UI
@export var system_label: String = ""

## libretro systemid (e.g. "nes", "super_nes"). Used for dynamic core lookup.
@export var systemid: String = ""

## Which model in SystemModelRegistry this system wears. Empty means "this
## platform's default". Saves written before models had ids are translated on the
## way in by ScenePersistence, so nothing here needs to know about variants.
@export var model_id: String = ""

## Spatial audio settings for the AudioStreamPlayer3D created at runtime.
@export_group("Spatial Audio")
@export var audio_unit_size: float = 3.0        ## Reference distance (m) for full volume
@export var audio_max_distance: float = 15.0    ## Distance (m) at which sound is fully silent
@export var audio_panning_strength: float = 1.0 ## Left/right stereo separation (1.0 = default)
@export_group("")


# Runtime state
var rom_path: String = ""
var connected_tv: RetroTV = null
var is_powered_on: bool = false

## Which physical gamepad drives this machine, for HANDHELDS only. Everything
## with a controller port takes a PadReceiver plugged into it instead; a handheld
## has none (port_count is 0 below), so the same choice is made from its own
## Controllers panel and remembered here. GUID rather than device index, because
## the index is a connection order that changes every session. Empty = none.
var pad_guid: String = ""
var pad_ordinal: int = 0
## Exact mounted path registered with RomM's process-wide cache guard.
var _protected_cache_path: String = ""

## Video-out cables shown/usable. Handhelds default OFF (they have their own
## screen — the cables are clutter until wanted); consoles default ON (a TV is
## their only display). Toggled from the options panel's System tab.
var video_out_enabled: bool = true
# Saved value restored by persistence (set before _ready; -1 = no override).
var _video_out_from_save: int = -1
# Clamshell (DS/3DS) lid open angle restored by persistence (deg, 0 shut … 180
# flat; set before _ready; -1 = keep the model default).
var _lid_angle_from_save: float = -1.0
# Set before _ready by the deserializer, and only there — a menu-spawned
# console never sets this, so it defaults false. Read once, by
# _build_expansion_hardware, to decide whether a default-occupant accessory
# (the N64's Jumper Pak) should seed itself: a restored console's own
# "expansions" list (restore_expansion, driven by the save) is always the
# whole truth about what is bolted on, whether that is the default occupant,
# a real upgrade, or nothing at all, and seeding on top of that would double it.
var _restoring_from_save: bool = false


## Hand a console the state a save carries about it, before it enters the tree.
##
## The three fields above are one decision — "this console is being restored, not
## spawned" — and they are all read once from _ready. They must therefore be set
## BEFORE the caller adds the node to the tree, which is the invariant this
## method exists to keep in one place: ScenePersistence and TestSceneBuilder both
## used to set them by hand, so a fourth latch would have had to be remembered at
## two more call sites.
##
## `video_out` is -1 to keep the platform default, 0 or 1 to force it.
## `lid_angle` is degrees for a clamshell, or -1 to keep the model default.
func begin_restore(video_out: int = -1, lid_angle: float = -1.0) -> void:
	_video_out_from_save = video_out
	_lid_angle_from_save = lid_angle
	_restoring_from_save = true


## Force the video-out cables on or off, before the console enters the tree.
##
## Deliberately NOT begin_restore: a console built into a scene rather than
## loaded from a save is not being restored, and marking it so would stop its
## bays seeding their default occupants. Handhelds are the ones that need this —
## they default video-out off, and a generated scene wants them wired to a set.
func force_video_out(enabled: bool) -> void:
	_video_out_from_save = 1 if enabled else 0


## Ignore gravity: the system freezes exactly where it's dropped and floats
## there. Toggled from the options panel's System tab; default off.
var ignore_gravity: bool = false

# Cached core options (populated when options_ready fires)
var _options_definitions: Dictionary = {}
var _options_values: Dictionary = {}
# Why the options list is empty, when it is empty for a reason worth showing
# (a core that publishes nothing until content is loaded, or none installed).
var _options_unavailable: String = ""

# Cached controller port info (populated alongside options_ready).
# Array of Dictionaries: [{port, controllers: [{name, id}], current_id}]
var _controller_info: Array = []

var _port_devices_settled := false
# The card that floats over this machine's picture — achievement unlocks, and
# the notice raised when a game cannot run. Made on demand rather than at
# power-on: most sessions raise neither, and it costs a SubViewport.
var _screen_toast_card: AchievementToast = null
# The card that floats over the hardware itself, for what the machine is waiting
# on rather than showing. Same on-demand cost as _screen_toast_card.
var _machine_toast_card: AchievementToast = null
## Upper bound on half the gap between the emitters when no TV is connected, in
## metres. A connected set reports its own speaker positions instead. The gap
## actually used is a fifth of the hardware's own width, so this only binds for
## something console-sized; see SystemAudio._refresh_hardware_geometry.
@export var audio_speaker_separation: float = 0.09

## How directional the speaker the sound comes out of is, 0 (omnidirectional)
## to 1.
##
## Applied wherever there is a facing worth tracking: a handheld radiates from
## its face, and a connected set radiates the way its picture points. Measured
## difference between facing the listener and facing away:
##
##     0.0  0.00 dB      0.3  -3.7 dB      0.6  -8.6 dB      1.0  -17.5 dB
##
## 1.0 is far more than a small speaker behind a plastic grille manages; the
## default is set where a real handheld sits, a few dB down when turned away
## rather than gone.
@export var audio_directivity: float = 0.45

# Top of the body in local space, for panels that float above the hardware.
# Cached and model-keyed for the same reason as the audio geometry above.
var _body_top_model_id: int = 0
var _body_top_local: float = 0.0

# Active system model — always set (falls back to RetroSystemModelDefault)
var _model: RetroSystemModel = null

# Held-input component (handhelds only — the device itself is the controller)
var _handheld_input: HandheldInput = null
## Wireless-pad pairing, on the consoles that have it (the Wii). Null elsewhere,
## and every call site is guarded on that — see _setup_wireless_pads.
var _wii_link: WiiLink = null

## Last A/V routing reported to the log, so re-resolving the same wiring is quiet
## and only real changes are announced. See _apply_av_feed.
var _last_av_routing: String = ""
## Each cord as "OUT->IN", with (!) where its two ends sit on different channels.
## Built by on_av_topology_changed, printed by _apply_av_feed.
var _av_cord_summary: String = "none"

# Cable scene to instantiate
const CABLE_SCENE := preload("res://Scenes/Objects/cables/cable.tscn")
# The generic expansion-unit scene — see _seed_default_occupant.
const EXPANSION_SCENE := preload("res://Scenes/Objects/expansion.tscn")
# The lid over an expansion bay — see _seed_expansion_cover.
const EXPANSION_COVER_SCENE := preload("res://Scenes/Objects/expansion_cover.tscn")
# Window material for TVs on multi-output hardware (dual-screen handhelds).
const SCREEN_WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")

## One video-out channel: what the model says it is, the lead built for it, and
## the set it currently reaches.
##
## One object rather than the eleven arrays this replaced — all grown in a single
## loop, all indexed by the same number, and all read apart. Three call sites had
## started defensively bounds-checking three DIFFERENT arrays against the same
## length, which is the shape of a bug waiting for the twelfth array.
##
## The node references stay untyped, as the arrays were: a channel can outlive
## what it points at, and a typed field throws on assignment from a freed object
## the way a cast does. Read them through _live().
class VideoChannel:
	## From the model: what this output is called, which part of the core's
	## framebuffer it shows, whether it takes touch, and its stereo eye offset.
	var label: String = ""
	var rect: Rect2 = Rect2(0, 0, 1, 1)
	var touch: bool = false
	var eye_shift: float = 0.0
	var wires: PackedColorArray = PackedColorArray()
	## The lead: where it leaves the machine, the cable, its picture plug, its
	## audio pair ([left, right], empty on a channel the model gives one wire),
	## the rope and how far it reaches.
	var attach = null
	var cable = null
	var plug = null
	var audio_plugs: Array = []
	var rope = null
	var max_reach: float = 0.0
	## The set this channel is plugged into, and its touch surface on that set.
	var tv = null
	var touch_surface = null
	## A set to reconnect to once the cables exist, and which of its inputs for
	## (save/load restore, which runs before the lead is built).
	var pending_tv = null
	var pending_input: int = 0

	static func from_model(d: Dictionary) -> VideoChannel:
		var c := VideoChannel.new()
		c.label = str(d.get("label", ""))
		c.rect = d.get("rect", Rect2(0, 0, 1, 1))
		c.touch = bool(d.get("touch", false))
		c.eye_shift = float(d.get("eye_shift", 0.0))
		c.wires = d.get("wires", PackedColorArray())
		return c


# Video-out channels from the model (single unlabelled entry on classic
# hardware; TOP/BOTTOM on dual-screen handhelds). One cable per channel.
# connected_tv stays the channel-0 TV for external readers (persistence,
# netplay OSD).
var _channels: Array[VideoChannel] = []

# A/V sockets, for hardware that wears them instead of a captive lead (the NES).
# _av_speaker is which of the set's speakers the one mono cord reaches — 0 left,
# 1 right, -1 nowhere — and the picture, the sound and the set's controls each
# follow a different one of these, because a lead can carry any of them alone.
var _av_ports: Array = []
# The sink carrying this console's SOUND. Node3D, not RetroTV: a pair of powered
# speakers is a sink with no screen, and the picture can be going somewhere else
# entirely.
var _av_tv: Node3D = null
var _av_video_tv: RetroTV = null
## Every sink this machine currently reaches — each has been told it is here, and
## each decides for itself which of its inputs that means.
var _av_sinks: Array[Node3D] = []
# True once an AUDIO_R socket exists — stereo hardware. Mono hardware has one
# audio socket, and its single cord drives BOTH voices to the same speaker.
var _av_stereo: bool = false
var _av_speaker_l: int = -1
var _av_speaker_r: int = -1
var _snapped_cartridge: Node3D = null

# --- Disc loader (tray/slot) state ---
const DISC_SPIN_MAX := 25.0    # rad/s (~240 RPM) — seated disc at full speed
const DISC_SPIN_UP := 18.0     # rad/s² ramp-up (power on / tray closed)
const DISC_SPIN_DOWN := 10.0   # rad/s² ramp-down (power off / tray opened)
## How far the hinged lid springs up. Positive: the lid rig VRSpringLatchedHinge
## builds carries a 180° yaw, so +rotation lifts the lid's FRONT edge.
## How far the hinged-lid console's disc well is sunk into its pod. Deep enough
## that a 2.5 mm disc sits with its face below the rim.
## Front-sliding tray: how far the shelf travels out of the box, and how long it
## takes. 190 mm puts a 12 cm disc's REAR edge 15 mm clear of the front face —
## less and the disc is still half inside the case with the tray "open".
const SLOT_INSET := 0.10       # slot-load: how far inside the console a disc rides

# How this system loads discs (MediaDimensions.LOADER_*), cached at model load.
var _disc_loader := MediaDimensions.LOADER_NONE
var _tray_open := false        # LOADER_TRAY: lid state (starts closed)
var _disc_spin := 0.0          # current disc angular speed (rad/s)
# LOADER_SLOT front-loading bay (insert ride / eject / grab hand-off / collision),
# owned by the shared MediaSlot; created in _load_system_model for slot consoles.
# Null for cartridge / tray / no-disc systems. See media_slot.gd.
var _slot: MediaSlot = null
# LOADER_TRAY lid bay (well seating / lid gating / disc spin / grab hand-off /
# collision), owned by the shared MediaTray; created in _load_system_model for tray
# consoles. Null for cartridge / slot / no-disc systems. See media_tray.gd.
var _tray: MediaTray = null
# Procedural disc well + spring lid (default-model tray consoles only). The hinge
# owns the lid's angle — MediaTray is NOT given a lid_pivot to tween, or the two
# would fight over it — and reports a hand-close back through request_tray_state.
# Front-sliding tray shelf (LOADER_TRAY + MediaDimensions.has_front_tray), null on
# a hinged-lid console. The seated disc rides it out; MediaTray still gates.
var _front_tray := false
## The mechanism the model drew on the placeholder box — the spring lid or the
## sliding shelf. Null on a bespoke shell, which brings its own.
var _disc_bay: ProceduralDiscBay = null
## Cached answer for roof_above_cartridge_slot(); NAN until the model is
## measurable. The shell does not change after it loads, and the query runs on
## every preview frame, so it is worked out once.
var _roof_over_slot: float = NAN

# --- Disk control (multi-disc games: FF7 "insert disc 2") ---
# Mirrors the core's libretro disk-control state (disk_control_ready signal).
# When the running core owns the interface, pulling the disc hot-ejects
# (game keeps running) and inserting the next disc swaps it in live.
var _has_disk_control := false
var _disc_index := 0
var _disc_ejected := false


@onready var _system_body: MeshInstance3D = $SystemBody
@onready var _cartridge_slot: XRToolsSnapZone = $CartridgeSlot
## The cart lying in a push-tray bay, which the machine cannot read until the tray
## is pushed home. Distinct from _snapped_cartridge, which means "the machine has
## this cart" — on such a bay the two are apart for as long as the tray is up.
var _tray_cartridge: Node3D = null
## The card snap zones, in slot order. Named here rather than looked up through a
## method because NetObjectSync resolves a slot by node name — its test double is
## a bare node with named children and no methods of its own.
##
## Slot A keeps the original node name so a PlayStation, and every saved room and
## replicated event that already refers to it, is untouched.
const MEMCARD_SLOT_NODES := ["MemoryCardSlot", "MemoryCardSlot2"]

@onready var _memcard_slots: Array[XRToolsSnapZone] = [
	$MemoryCardSlot, $MemoryCardSlot2,
]
@onready var _cable_attach_point: Node3D = $CableAttachPoint
@onready var _libretro: Libretro = $Libretro
@onready var _power_button: VRButton = $PowerButton
@onready var _reset_button: VRButton = $ResetButton
@onready var _eject_button: VRButton = $EjectButton
@onready var _sync_button: VRButton = $SyncButton
@onready var _options_panel: CoreOptionsPanel = $CoreOptionsPanel
@onready var _system_name_label: Label3D = $SystemNameLabel
@onready var _port_zones: Array = [
	$ControllerPort1,
	$ControllerPort2,
	$ControllerPort3,
	$ControllerPort4,
]

## Cached RetroController currently plugged into each cabinet port (same index
## as the libretro port the core sees). Populated by the snap/release handlers
## so rumble signals can be routed back to the physical holder without a
## node tree scan on every core callback.
var _port_controllers: Array = [null, null, null, null]

## The ControllerPlug seated in each cabinet port. Kept alongside the controller
## because the two are not interchangeable on the way out: has_dropped names
## nothing, and the release path needs the PLUG (its device_type, its collision
## exception, its on_unplugged) rather than the controller behind it.
var _port_plugs: Array = [null, null, null, null]


## Real-world cross-compatibility: media of these systemids also fits.
## (The GBA plays original Game Boy carts — and mgba runs them.)
##
## The Wii row is not just cosmetic: with a GameCube disc in the tray the core's
## IsWii() goes false, and that changes how the whole cabinet is wired — see
## _wii_mode().
const _MEDIA_COMPAT: Dictionary = {
	"game_boy_advance": ["game_boy"],
	"wii":              ["gamecube"],
}

## The same idea for connectors: controllers of these systemids ALSO fit this
## system's ports.
##
## The Wii row is the same fact as the Wii row above, seen from the front of the
## machine: a console that plays GameCube discs has the four GameCube controller
## sockets to play them with, under the flap. Without it a GameCube pad, or a
## GameCube-to-Game Boy Advance lead, is refused by the only machine in the room
## that can use one, and the refusal is silent because a snap zone that declines
## an object simply does nothing.
##
## Real hardware is looser still, and each of these is one line if wanted:
##   "playstation2": ["playstation"]   PS2 takes PS1 pads (identical connector)
##   "mega_drive":   ["atari_2600"]    the DE-9 is shared, and vice versa
## Physical fit only — a plug that cannot enter the socket does not belong here
## however well its buttons would map.
const _CONTROLLER_COMPAT: Dictionary = {
	"wii": ["gamecube"],
}

# RETRO_DEVICE_* types relevant to port routing (libretro.h).
const RETRO_DEVICE_NONE := 0
const RETRO_DEVICE_JOYPAD := 1
const RETRO_DEVICE_MOUSE := 2
const RETRO_DEVICE_KEYBOARD := 3
const RETRO_DEVICE_LIGHTGUN := 7
## A device id is a base type in the low byte and a core-specific subclass above it.
const RETRO_DEVICE_MASK := 0xFF

## Words a core uses for a light gun in its own device list, for the cores that
## give one a base type other than RETRO_DEVICE_LIGHTGUN.
const _LIGHTGUN_WORDS: Array = [
	"zapper", "lightgun", "light gun", "gun", "scope", "justifier", "phaser", "menacer",
]


## The two controllers are built HERE and not in _ready, because a RetroSystem
## is not always a scene: system_tests builds bare RetroSystem.new() instances
## that never enter the tree, and every forwarder below would find a null.
func _init() -> void:
	_save_state = SaveStateController.new()
	_save_state.name = "SaveStateController"
	add_child(_save_state)
	_save_state.setup(self)
	_memcards = MemoryCardController.new()
	_memcards.name = "MemoryCardController"
	add_child(_memcards)
	_memcards.setup(self)
	_audio = SystemAudio.new()
	_audio.name = "SystemAudio"
	add_child(_audio)
	_audio.setup(self)
	_expansion_launch = ExpansionLaunch.new()
	_expansion_launch.name = "ExpansionLaunch"
	add_child(_expansion_launch)
	_expansion_launch.setup(self)


func _ready() -> void:
	super._ready()
	add_to_group("retro_system")
	# Unconditional, unlike HandheldInput and WiiLink: every machine can be asked
	# for a state, and capture_gate answers for the ones that cannot give
	# one. Built here so the forwarders below never see a null.
	_cartridge_slot.has_picked_up.connect(_on_cartridge_inserted)
	_cartridge_slot.has_dropped.connect(_on_cartridge_removed)
	# Only this system's own media fits its slot (a GB cart won't go into a
	# SNES, a PS1 disc only fits a PlayStation). Unlabelled legacy media keeps
	# working everywhere; save/netplay restores bypass the filter.
	_cartridge_slot.snap_filter = _accepts_media
	# Ignore-gravity: re-freeze wherever the player lets go.
	dropped.connect(_on_system_dropped)
	if ignore_gravity:   # restored from a save — float at the saved pose
		_freeze_in_place.call_deferred()
	for i in _memcard_slots.size():
		_memcard_slots[i].snap_filter = _accepts_card
		_memcard_slots[i].has_picked_up.connect(_memcards.on_memcard_inserted.bind(i))
		# has_dropped carries no argument, so the slot has to be closed over.
		_memcard_slots[i].has_dropped.connect(
			func() -> void: _memcards.on_memcard_removed(i))
	_power_button.button_pressed.connect(toggle_power)
	_reset_button.button_pressed.connect(reset)
	_eject_button.button_pressed.connect(_on_eject_pressed)
	_libretro.options_ready.connect(_on_options_ready)
	_libretro.rumble_state_changed.connect(_on_rumble_state_changed)
	_libretro.disk_control_ready.connect(_on_disk_control_ready)
	_libretro.sram_flushed.connect(_memcards.on_sram_flushed)
	_libretro.content_load_failed.connect(_on_content_load_failed)
	# Wire controller port snap signals
	for i in range(4):
		var idx := i
		_port_zones[i].has_picked_up.connect(func(obj: Node3D) -> void: _on_port_snapped(idx, obj))
		# has_dropped carries NO argument — it says the zone is empty, not what
		# left, and it fires after the zone has already forgotten. Taking one here
		# made every unplug abort with "expected 1 argument, called with 0", so a
		# controller pulled out of a port never released it: the libretro device
		# stayed set and the slot stayed occupied. _port_plugs is what remembers.
		_port_zones[i].has_dropped.connect(func() -> void: _on_port_released(idx))
		# A SNES pad does not fit a PlayStation. Same gate the cartridge slot
		# uses for media, applied to the connector.
		_port_zones[i].snap_filter = _accepts_plug
	# Load system-specific model (falls back to default placeholder model)
	_load_system_model()
	# Hardware with real sockets (the NES) gets those instead of a captive lead —
	# nothing plays until a lead is run to the set, as it did on the real thing.
	if _model.uses_av_ports():
		_build_av_ports()
	else:
		_spawn_cables()
	_update_name_label()
	# Lay the name flat on the model's front face once meshes + text are built.
	_place_name_label.call_deferred()
	# Deferred for the same reason the label is: the socket sits on the model's
	# top face and the foot under its bottom one, and neither is known until the
	# meshes exist.
	_build_expansion_hardware.call_deferred()
	# A machine spawns switched off, and its leads are clamped only once they
	# exist. Both ticks are armed by the things that make them worth running:
	# power_on/net_start_core and _apply_video_out.
	set_process(false)
	set_physics_process(false)


## The power button always reflects run state: green START when off, red STOP
## while running. Owned here (not per-model) so bespoke models that override
## on_power_on/off for their own visuals — the Virtual Boy's eyepiece shader —
## can't lose the label toggle. Harmless no-op for handhelds (button hidden).
func _update_power_button_visual() -> void:
	if _power_button == null:
		return
	# Only the generic placeholder cap gets the green/red START/STOP tint; a
	# modelled button (set_button_mesh) keeps its own material.
	if _power_button.state_tint:
		_power_button.set_color(Color(1.0, 0.0, 0.0) if is_powered_on else Color(0.0, 1.0, 0.0))
	var lbl := _power_button.get_node_or_null("ButtonLabel") as Label3D
	if lbl:
		lbl.text = "STOP" if is_powered_on else "START"


## What this machine calls itself — the scene's own label, else the systemname
## its cores agree on, else the bare systemid.
##
## The shared database rather than a fresh one: this used to reparse all 314
## .info files to answer a single lookup, and the answer cannot change at runtime.
func _display_name() -> String:
	var name_text := system_label
	if name_text.is_empty() and not systemid.is_empty():
		name_text = CoreInfoDatabase.shared().get_systemname_for_id(systemid)
	if name_text.is_empty():
		name_text = systemid
	# What the player has actually built -- "Mega Drive + Mega-CD + 32X" -- so
	# the nameplate says which machine this is while anything is bolted to it.
	var ids := expansion_ids()
	if not ids.is_empty():
		name_text = ExpansionCatalog.stack_label(name_text, ids)
	return name_text


func _update_name_label() -> void:
	_system_name_label.text = _display_name().to_upper()


## Lay the system name flat on the front face of the model, sized to fit, facing
## one fixed direction (no billboard) — consoles use their +Z face (upright,
## toward the player), handhelds their +Y top face (readable from above). Runs
## deferred so the model meshes + the label's own text mesh have been built.
func _place_name_label() -> void:
	# The nameplate is a printed legend like any other: a detailed shell has the
	# real thing moulded or printed on it, so ours only ever sat on top of it — and
	# so does a primitive that authors its own (see prints_own_name).
	if _model != null and (_model.has_baked_shell() or _model.prints_own_name()):
		_system_name_label.visible = false
		return
	var body := _body_aabb()
	if body.size.x <= 0.0 or body.size.y <= 0.0 or body.size.z <= 0.0:
		return
	var lbl := _system_name_label
	lbl.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	lbl.scale = Vector3.ONE
	lbl.rotation = Vector3.ZERO
	var la := lbl.get_aabb()
	if la.size.x <= 0.0 or la.size.y <= 0.0:
		return
	var cx := body.position.x + body.size.x * 0.5
	const EPS := 0.003
	# Placement config, overridable per-model via name_label_placement():
	#   upright  — true = upright on the vertical +Z front face (consoles, and
	#              clamshells whose front is the START-button face); false = flat
	#              on the +Y top face (simple flat handhelds like the Game Boy).
	#   v_center — vertical centre as a fraction of the face height.
	#   h_frac   — label height as a fraction of the face height.
	var cfg := {}
	if _model != null and _model.has_method("name_label_placement"):
		cfg = _model.name_label_placement()
	var upright: bool = cfg.get("upright", not (_model != null and _model.is_handheld()))
	if upright:
		# Vertical front (+Z) face, upright toward the player. Default sits low
		# as a nameplate strip so it clears the controller ports that occupy the
		# centre of a default console's front face; thin faces (a clamshell base)
		# override to centre + fill.
		var v_center: float = cfg.get("v_center", 0.18)
		var h_frac: float = cfg.get("h_frac", 0.26)
		var s: float = min(body.size.x * 0.85 / la.size.x, body.size.y * h_frac / la.size.y)
		lbl.scale = Vector3(s, s, s)
		var cy := body.position.y + body.size.y * v_center
		var front_z := body.position.z + body.size.z
		lbl.position = Vector3(cx, cy, front_z + EPS)
	else:
		# Top (+Y) face, lying flat; sit on the front (+Z) strip below the screen.
		lbl.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
		var s: float = min(body.size.x * 0.8 / la.size.x, body.size.z * 0.28 / la.size.y)
		lbl.scale = Vector3(s, s, s)
		var top_y := body.position.y + body.size.y
		var front_z := body.position.z + body.size.z
		lbl.position = Vector3(cx, top_y + EPS, front_z - la.size.y * s * 0.6)


## World-space Y of the top of the hardware body.
##
## Floating panels sit above this rather than at a fixed height off the origin.
## The bodies differ by an order of magnitude — a PC tower is 0.42 m tall and a
## flat console around 0.07 — so no single constant clears both, and one tuned
## for a console lands inside the tower.
##
## Cached in local space and keyed on the model instance, the same way
## SystemAudio._centre_local is: _body_aabb walks every mesh in the model and a
## floating panel wants this every frame.
func body_top_y() -> float:
	var inst_id := _model.get_instance_id() if _model != null else 0
	if inst_id != _body_top_model_id:
		_body_top_model_id = inst_id
		var aabb := _body_aabb()
		_body_top_local = aabb.end.y if aabb.size.y > 0.0 else 0.0
	# Through the transform, not added to it: the system may be scaled, and the
	# cached figure is in local space.
	return (global_transform * Vector3(0.0, _body_top_local, 0.0)).y


## AABB of the console/handheld body meshes in this system's local space
## (default box or the bespoke model's meshes). Excludes buttons/ports/cables/
## label, which are siblings of the body root. A model may narrow the measured
## body via name_label_body() — e.g. a clamshell returns just its base so the
## name lands on the base's front, not over the raised lid.
## The bounding box of the machine's body, excluding parts a model excludes from
## it (a clamshell's raised lid). Read by SystemAudio to place its emitter.
func body_aabb() -> AABB:
	return _body_aabb()


func _body_aabb() -> AABB:
	var meshes: Array[MeshInstance3D] = []
	var src: Node = null
	if _model != null and _model.has_method("name_label_body"):
		src = _model.name_label_body()
	if src != null:
		_collect_meshes(src, meshes)
	else:
		if _system_body.visible:
			meshes.append(_system_body)
		if _model != null:
			_collect_meshes(_model, meshes)
	var inv := global_transform.affine_inverse()
	var out := AABB()
	var have := false
	for mi in meshes:
		if not mi.visible or mi.mesh == null:
			continue
		var a := (inv * mi.global_transform) * mi.get_aabb()
		if not have:
			out = a
			have = true
		else:
			out = out.merge(a)
	return out if have else AABB()


func _collect_meshes(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		_collect_meshes(c, out)


func _load_system_model() -> void:
	# One lookup. `model_id` names a row in SystemModelRegistry; empty means "this
	# platform's default", which resolve() handles.
	var row := SystemModelRegistry.resolve(model_id, systemid)
	_model = SystemModelRegistry.instantiate(row)
	# Never leave _model null. Every configure_*/on_*/play_* call below assumes it
	# is valid once _ready() returns, and a null here does not fail at the point of
	# failure — it crashes some unrelated caller much later (e.g. a cartridge insert
	# during a save restore).
	if _model == null:
		push_warning("RetroSystem: model '%s' failed for systemid='%s' — using the placeholder"
			% [row.get("id", ""), systemid])
		row = SystemModelRegistry.placeholder_row()
		_model = SystemModelRegistry.instantiate(row)
	# Asked of the MODEL, not of its registry id: a row can exist for reasons that
	# have nothing to do with geometry (the Wii's carries core options), and such a
	# model still wears the procedural box. See RetroSystemModel.brings_own_body.
	add_child(_model)
	var is_bespoke := _model.brings_own_body()
	_model.hide_printed_labels()
	if is_bespoke:
		_system_body.hide()
	_model.configure_buttons(_power_button, _reset_button, _eject_button)
	_model.configure_controller_ports(_port_zones)
	# Video-out channels: one attach point + cable per channel. Channel 0 is
	# the scene's CableAttachPoint; extra channels get their own Node3D.
	var described: Array = _model.get_video_channels()
	if described.is_empty():
		described = [{}]        # classic hardware: one unlabelled full-frame output
	_channels.clear()
	for d: Dictionary in described:
		_channels.append(VideoChannel.from_model(d))
	# Channel 0 is the scene's own CableAttachPoint; extra channels get their own.
	_channels[0].attach = _cable_attach_point
	for i in _channels.size():
		if i > 0:
			var pt := Node3D.new()
			pt.name = "CableAttachPoint%d" % (i + 1)
			add_child(pt)
			_channels[i].attach = pt
		_model.configure_cable_attach_for(_channels[i].attach, i)
	# A machine with no display of its own ALWAYS has video out — a TV is the only
	# place its picture can go, so there is no toggle. One that carries its own
	# screen defaults OFF and remembers the saved choice.
	if supports_video_out_toggle():
		video_out_enabled = _video_out_from_save == 1
	else:
		video_out_enabled = true
	_model.configure_cartridge_slot(_cartridge_slot)
	# So a unit that mounts AS a cartridge can carry a grab point naming this
	# slot, and seat by its connector instead of by its centre. See
	# RetroExpansion._build_connector.
	_cartridge_slot.add_to_group(ExpansionPort.GROUP_CART_SLOT)
	_wire_push_tray()
	# The serial socket, for the consoles that have one. Placed by the model for
	# the same reason the A/V sockets are: it goes on the back panel, and only
	# the thing that draws the back panel knows where that is.
	_model.build_serial_port(self, systemid)
	_model.configure_collision(self)
	# Native controller ports: prefer the per-system SystemInfo descriptor (the
	# real console's built-in port count) over the model's default, clamped to
	# the cabinet's available snap zones. A multitap plugged into a port extends
	# players beyond this on its own. Handhelds are their own controller (the
	# HandheldInput below drives port 0), so they expose NO external port zones.
	var port_count := 0
	if not _model.is_handheld():
		port_count = _model.get_controller_port_count()
		var info := SystemInfo.for_system(systemid)
		if info and info.native_ports > 0:
			port_count = info.native_ports
		port_count = clampi(port_count, 1, _port_zones.size())
	for i in range(_port_zones.size()):
		var active := i < port_count
		_port_zones[i].visible = active
		_port_zones[i].enabled = active
	# Memory-card slots only on hardware that takes them; cartridge systems keep
	# their battery save on the cartridge itself. A PlayStation shows one, a
	# GameCube or Wii two.
	#
	# The model is configured LAST and only for the slots that exist, because a
	# shell may gate its slots behind a door — the Wii's are under the memory
	# flap — and that gate has to win over this blanket enable.
	var card_slots := card_slot_count()
	for i in _memcard_slots.size():
		var active := i < card_slots
		_memcard_slots[i].visible = active
		_memcard_slots[i].enabled = active
		var mouth := _system_body.get_node_or_null(
			"MemCardMouth" if i == 0 else "MemCardMouth%d" % (i + 1)) as MeshInstance3D
		if mouth != null:
			mouth.visible = active
		if active:
			_model.configure_memory_card_slot(_memcard_slots[i], i)
	# Disc loader: tray consoles (PS1/GameCube…) get an OPEN button gating a
	# closed-by-default tray; slot loaders (PS2) get an always-open slot with
	# an EJECT button. Cartridge systems hide the button entirely.
	_disc_loader = MediaDimensions.disc_loader(systemid)
	var has_loader := _disc_loader != MediaDimensions.LOADER_NONE
	# A shell that models its own release control (the PSP's sprung OPEN latch)
	# opts out — it drives request_tray_state directly.
	var want_eject := has_loader and _model.has_eject_button()
	_eject_button.set_active(want_eject)
	# Consoles with wireless pads grow a SYNC button and the component behind it.
	# Set up here rather than in _ready because `systemid` is an export the spawner
	# may still be filling in when _ready runs; by the time a model is resolved it
	# is definitely set.
	_setup_wireless_pads()
	# A front-sliding tray is a property of the PROCEDURAL box. A bespoke shell
	# brings its own mechanism — the PS2 Slim's hinged cover is a lid whatever the
	# platform row says the family does — so it keeps the lid wording and geometry.
	_front_tray = _disc_loader == MediaDimensions.LOADER_TRAY \
		and MediaDimensions.has_front_tray(systemid) and not is_bespoke
	if has_loader:
		var eject_label := _eject_button.get_node_or_null("ButtonLabel") as Label3D
		if eject_label:
			# A sliding tray EJECTS, like the drive it imitates; only a hinged lid
			# is something you OPEN.
			var is_lid: bool = _disc_loader == MediaDimensions.LOADER_TRAY and not _front_tray
			eject_label.text = "OPEN" if is_lid else "EJECT"
		# The cartridge recess would look wrong on disc hardware — the disc
		# tray/slit is the visual instead.
		var cart_recess := _system_body.get_node_or_null("CartSlotMouth") as MeshInstance3D
		if cart_recess:
			cart_recess.visible = false
		# The snap ghost is cartridge-shaped — reshape it into this system's
		# disc so the blue "goes here" shadow reads correctly.
		var ghost := _cartridge_slot.get_node_or_null("SnapHighlight/HighlightMesh") as MeshInstance3D
		if ghost:
			var ghost_mesh := CylinderMesh.new()
			ghost_mesh.top_radius = MediaDimensions.disc_diameter(systemid) / 2.0
			ghost_mesh.bottom_radius = ghost_mesh.top_radius
			ghost_mesh.height = 0.004
			ghost.mesh = ghost_mesh
		# Tray consoles on the placeholder box get a physical disc well + hinged
		# lid (bespoke GLB models own their tray geometry instead).
		# The model draws its own mechanism: the placeholder box builds a pod or a
		# sliding shelf to match itself, a bespoke shell already has one.
		if _disc_loader == MediaDimensions.LOADER_TRAY:
			_cartridge_slot.enabled = false   # tray starts closed
			_disc_bay = _model.build_disc_bay(self, _cartridge_slot, systemid,
				_front_tray, _on_lid_swung)
			# Lid tray: hand the well seating / lid gating / spin / grab / collision to the
			# shared MediaTray (bespoke models animate their own lid via play_open/close;
			# a procedural lid pivot, if any, is animated by MediaTray). The zone's raw
			# insert/remove signals are replaced by MediaTray's, which fire the same
			# _on_cartridge_inserted/_removed for the emulation-side work.
			_cartridge_slot.has_picked_up.disconnect(_on_cartridge_inserted)
			_cartridge_slot.has_dropped.disconnect(_on_cartridge_removed)
			_tray = MediaTray.new()
			_tray.host = self
			_tray.slot = _cartridge_slot
			# No lid_pivot: a bespoke model swings its own lid from play_open/close,
			# and the procedural one is driven by its own spring hinge.
			# A flip-open tray assembly (the PSP's UMD door) carries its disc with
			# it — unlike a spindle console, where the disc stays fixed and only
			# the lid mesh swings. _cartridge_slot's pose (already set above by
			# configure_cartridge_slot) is where the disc should visually rest
			# with the pivot at its baked rest orientation; re-express it as a
			# LOCAL offset from that pivot so MediaTray can reparent the disc
			# under it and have it swing rigidly with the door.
			# The procedural slide when we built one, else whatever moving part the
			# model nominates (the PC tower's authored shelf, the PSP's UMD door).
			var disc_pivot: Node3D = _disc_bay.slide_pivot if _disc_bay != null else null
			if disc_pivot == null and _model != null:
				disc_pivot = _model.get_disc_lid_pivot()
			if disc_pivot != null:
				_tray.disc_lid_pivot = disc_pivot
				var rel := disc_pivot.global_transform.affine_inverse() * _cartridge_slot.global_transform
				_tray.media_local_basis = rel.basis
				_tray.seat_offset = rel.origin
			add_child(_tray)
			_tray.loaded.connect(_on_cartridge_inserted)
			_tray.unloaded.connect(_on_cartridge_removed)
		# Slot loaders take the disc through a slit in the FRONT face: move the
		# snap zone to the slit mouth and add the slit visual there.
		if _disc_loader == MediaDimensions.LOADER_SLOT and not is_bespoke:
			_cartridge_slot.position = Vector3(0, 0.03, 0.125)
			_model.build_disc_slit(self, systemid)
		# Front-loading disc bay: hand the physical ride/eject/grab/collision to the
		# shared MediaSlot (bespoke models place their own slit but still slot-load).
		# The zone's raw insert/remove signals are replaced by MediaSlot's, which
		# fire the same _on_cartridge_inserted/_removed for the emulation-side work.
		if _disc_loader == MediaDimensions.LOADER_SLOT:
			_cartridge_slot.has_picked_up.disconnect(_on_cartridge_inserted)
			_cartridge_slot.has_dropped.disconnect(_on_cartridge_removed)
			_slot = MediaSlot.new()
			_slot.host = self
			_slot.slot = _cartridge_slot
			# A model whose case is too shallow for the cabinet's default says so;
			# 0 means "no opinion". See RetroSystemModel.slot_insert_depth.
			var slot_depth: float = _model.slot_insert_depth()
			_slot.insert_depth = slot_depth if slot_depth > 0.0 else SLOT_INSET
			add_child(_slot)
			_slot.inserted.connect(_on_cartridge_inserted)
			_slot.removed.connect(_on_cartridge_removed)
	# Handhelds: built-in screen, on-device controls, and the held-input
	# component that turns the device itself into the port-0 controller.
	# Dual-screen clamshells keep the cabinet START/STOP button (repositioned
	# by their configure_buttons) — the back-edge power knob doesn't fit them.
	if _model.is_handheld():
		var keep_power_btn := _model.has_start_stop_button()
		_power_button.set_active(keep_power_btn)
		_update_power_button_visual()
		_reset_button.set_active(false)
		if _model.has_method("configure_handheld_body"):
			_model.configure_handheld_body(self)
		_model.configure_handheld_controls(self)
		# Two-handed hold, like a game controller: HandheldInput already merges
		# buttons/sticks from both hands (retro_controller pipeline) — the
		# pickable just has to allow the second grab.
		second_hand_grab = SecondHandGrab.SECOND
		_handheld_input = HandheldInput.new()
		_handheld_input.name = "HandheldInput"
		add_child(_handheld_input)
		_handheld_input.setup(self)
		# Route port-0 rumble to the holding hands via the existing path.
		_port_controllers[0] = _handheld_input
	# Restore a saved lid pose — a clamshell's hinge (DS/3DS/GBA SP) or a console's
	# cartridge-bay flap (the NES). Last, and for every model rather than only the
	# handhelds, because a disc loader and configure_cartridge_slot both re-gate the
	# bay above and either would win over the restored pose.
	if _lid_angle_from_save >= 0.0:
		_model.set_lid_angle_deg(_lid_angle_from_save)
		_restore_tray_open()


## A handheld routes the trigger and thumbstick into the emulated pad, leaving
## the push-out gesture nothing to bind to. Consoles keep it. Catching either
## back off the laser works regardless. Queried by
## function_pickup._handoff_eligible.
func wants_ray_handoff() -> bool:
	return _handheld_input == null


## Where a hand grips this system, in local space, or null when it has no
## authored grip and should stay where it was grabbed. Only handhelds define
## one — a console keeps the precise grab. Read by GripAnchor via HandheldInput.
func grip_anchor(is_left: bool) -> Variant:
	if _model != null and _model.has_method("get_grip_anchor"):
		return _model.get_grip_anchor(is_left)
	return null


## Interior open angle of a clamshell handheld's lid (0 shut … 180 flat), or
## -1 for systems without a lid. Used by ScenePersistence.
func get_lid_angle_deg() -> float:
	return _model.get_lid_angle_deg() if _model != null else -1.0


## Pose a lid at a saved angle. Public because ScenePersistence has to re-apply it
## after seating a cartridge: an insert swings the bay open on its own.
func set_lid_angle_deg(open_deg: float) -> void:
	if _model != null:
		_model.set_lid_angle_deg(open_deg)
		_restore_tray_open()


## Carry a restored lid pose into the MACHINE, which is a separate thing from the
## shell the pose just moved.
##
## set_lid_angle_deg only moves the mesh and the model's own zone gate. A tray
## console's open state lives in two more places — RetroSystem._tray_open and
## MediaTray._open — and both start shut, so a room saved with the lid up came
## back with the lid drawn open over a machine that believed it was closed. The
## PlayStation's well then took a disc (the model had enabled the zone) and
## MediaTray immediately sealed it in: ungrabbable, and the core never heard the
## tray cycle, so the game never saw the disc that was visibly sitting in it.
##
## Idempotent, and a no-op on anything but a tray console — which is why the
## NES's flap, whose own set_lid_angle_deg already gates its bay, passes through
## here unchanged.
func _restore_tray_open() -> void:
	if _model == null or _disc_loader != MediaDimensions.LOADER_TRAY:
		return
	var open: bool = _model.is_lid_open()
	if open != _tray_open:
		_set_tray_open(open, true)


## Enable or disable libretro input polling for this system.
## Only the actively-controlled instance should have input enabled.
func set_input_enabled(on: bool) -> void:
	_libretro.SetInputEnabled(on)


## Spatial audio for this machine, lifted out into SystemAudio. Created in
## _init beside the other components, because every machine makes sound.
var _audio: SystemAudio = null


## Set the audio volume for the running libretro instance (0.0 = silent, 1.0 = 100%).
##
## Stays on RetroSystem rather than moving to the component with its body: every
## caller reaches it by DUCK TYPING — tv.gd, speaker_pair.gd and the handheld,
## PSP and Virtual Boy models all test has_method("set_audio_volume") on whatever
## is plugged in, and a VCR and a DVD player answer the same name.
func set_audio_volume(volume: float) -> void:
	_audio.set_volume(volume)


## Part of the TV contract: the set's mono switch. Reached by duck typing from
## tv.gd exactly as set_audio_volume is, so it stays here too.
func set_audio_channel_mode(mode: int) -> void:
	_audio.set_channel_mode(mode)


## The TV this system's sound should come out of: whichever channel is plugged
## in, channel 0 first (a dual-screen handheld can be wired up by its BOTTOM
## cable alone). Null when nothing is connected.
func _audio_tv() -> Node3D:
	# A ports console's sound goes wherever its audio cord went, which is not
	# necessarily where its picture went — or anywhere at all.
	if not _av_ports.is_empty():
		var live: bool = _av_speaker_l >= 0 or _av_speaker_r >= 0
		return _av_tv if live and is_instance_valid(_av_tv) else null
	for chan: VideoChannel in _channels:
		if is_instance_valid(chan.tv):
			return chan.tv as RetroTV
	return null


## Everything SystemAudio needs to know about the cabling, in one answer.
##
## The component is deliberately given this rather than _av_ports and
## _av_speaker_l/_r themselves. Which set the sound reaches, and which of that
## set's speakers each channel lands on, is decided in _apply_av_feed as cords
## are seated and pulled; a second reader of those three fields would be a
## second owner of the routing, and the gains cached against them would go stale
## in a way nothing here could see.
##
## "socketed" is the hardware-has-phono-sockets test, not a
## something-is-plugged-in test: it is what separates a console that is silent
## until a cord reaches a set from a handheld whose captive lead always carries
## its own speaker.
## Where this machine's sound goes: its speakers plus the set it reaches, if
## any. Read by SystemAudio, which this node owns and drives.
func audio_route() -> Dictionary:
	var route := _audio_speakers()
	route["tv"] = _audio_tv()
	return route


## The speaker half of audio_route, without resolving the sink. Separate on
## purpose: resolving the set is the expensive half, and two of SystemAudio's
## three callers do not need it.
func audio_speakers() -> Dictionary:
	return _audio_speakers()


## The speaker half of audio_route, without resolving the sink.
##
## Split out because the gain path wants it every frame and does not care which
## set the sound is going to — and because _apply_av_feed has to invalidate the
## gain cache one line BEFORE it assigns _av_tv, where _audio_tv() would still
## answer with the old sink.
func _audio_speakers() -> Dictionary:
	return {
		"socketed": not _av_ports.is_empty(),
		"left": _av_speaker_l,
		"right": _av_speaker_r,
	}


## The core's picture. The ONE way anything gets at it — the television that shows
## this machine reads it here rather than being painted into, and so does the
## model's own panel.
##
## Null before the first frame and while nothing is running, and a different object
## after a resolution change, so callers read it per frame instead of caching it.
func get_video_texture() -> Texture2D:
	return _libretro.GetVideoTexture() if _libretro != null else null


## The mesh the core paints, which is now only ever this machine's OWN screen: a
## handheld's built-in LCD, or the hidden proxy a dual-screen or stereo model
## samples. Null for a console, which has no panel of its own.
##
## A television is never named here any more. It reads get_video_texture() and
## paints its own glass, so the picture no longer depends on which set was
## connected first, and a machine feeding two sets is not a special case.
func _screen_target() -> MeshInstance3D:
	return _model.get_builtin_screen() if _model else null


## Is a VIDEO cord from this machine actually reaching `tv`?
##
## Asked by a set before it paints, because being wired to a machine is not the
## same as being sent its picture. A phono plug fits any phono socket, so an
## AUDIO cord in the yellow input is ordinary hardware — and the set still files
## the machine on that input, deliberately, so the sound routes. What it must not
## do is take that as a picture.
##
## Read off the video channels rather than recomputed, because that is the one
## record both routes keep: a captive lead sets it through on_tv_connected, a
## composite cable through _apply_av_feed, and a walk of the cable graph would
## see only the second — captive leads carry no CompositeCable and are not in it.
##
## Per set, not per machine. A tower with its picture on a monitor and its sound
## on a second television is wired to both, and only one of them has the picture.
func sends_video_to(tv: Node3D) -> bool:
	if tv == null or not is_instance_valid(tv):
		return false
	for chan: VideoChannel in _channels:
		if chan.tv == tv:
			return true
	return false


## True while a video-out cable has taken the picture to a television. The model
## asks, and darkens its own panel: a handheld's picture MOVES to the set rather
## than being mirrored (Super Game Boy), and that is the model's own glass to
## decide about.
func picture_on_tv() -> bool:
	return _channels.size() == 1 and is_instance_valid(connected_tv)


## Somewhere for the picture to go: this machine's own panel, or a television
## cabled to it. Powering on with neither is the "no display" fault.
func _has_display() -> bool:
	if _screen_target() != null:
		return true
	for chan: VideoChannel in _channels:
		if is_instance_valid(chan.tv):
			return true
	return false


## A machine wired to nothing is silent. Used to fall out of SetScreenMesh(null) —
## no mesh, no sound — which only worked while a picture reached a set by being
## painted onto it.
func _apply_audio_playing() -> void:
	if _libretro != null:
		_libretro.SetAudioPlaying(_has_display())


## True when the running core outputs a side-by-side stereo frame (Virtual Boy);
## a connected TV uses this to split the picture per-eye. Read by RetroTV.
func is_stereo_output() -> bool:
	return _model != null and _model.is_stereo_side_by_side()


# set_screen_enabled, _last_screen_enabled and _bound_screen_target are gone with
# the push. Which input a set is showing decided where the CORE rendered, so it had
# to be latched for a machine that was off, stated in both directions, and applied
# in an order that did not clobber the incoming picture. None of that is a question
# any more: the core renders to its own texture, and the set samples it or does not.


## Which channel this console's own RF switch puts it on, or -1 if it has none.
##
## Asked by a television showing its aerial input: an RF-fed console only appears
## when the set is tuned to the channel the console is modulating on. The switch is
## the MODEL's — an NES wears one, a Wii does not — so this only forwards.
func get_rf_channel() -> int:
	return _model.get_rf_channel() if _model != null else -1


## The model's channel switch moved. Tell whichever set is showing us on its aerial
## input, because that switch is half of what decides whether there is a picture and
## nothing else would prompt the set to re-read it.
func on_rf_channel_changed() -> void:
	for chan: VideoChannel in _channels:
		if is_instance_valid(chan.tv) \
				and chan.tv.has_method("on_rf_channel_changed"):
			chan.tv.call("on_rf_channel_changed")
	if is_instance_valid(_av_video_tv) \
			and _av_video_tv.has_method("on_rf_channel_changed"):
		_av_video_tv.on_rf_channel_changed()


## Called by the TV when one of this system's plugs connects. `plug` tells us
## which video-out channel landed (null = classic single-cable path).
func on_tv_connected(tv: RetroTV, plug: CablePlug = null) -> void:
	var ch := plug.channel if plug != null else 0
	if ch < 0 or ch >= _channels.size():
		ch = 0
	_channels[ch].tv = tv
	if ch == 0:
		connected_tv = tv
	_seat_audio_pair(ch, tv)
	_apply_audio_playing()
	if _channels.size() > 1:
		# The set samples our picture through get_video_stage; a touch channel
		# additionally turns the TV's glass into the touch screen.
		if _channels[ch].touch:
			_remove_touch_surface(ch)
			var surf := TVTouchSurface.new()
			surf.setup(self, _channels[ch].rect, tv.get_screen_mesh())
			tv.get_screen_mesh().add_child(surf)
			_channels[ch].touch_surface = surf
		return


## Called by the TV when a plug disconnects. Handhelds take the picture back
## onto their built-in LCD; consoles go dark.
func on_tv_disconnected(plug: CablePlug = null) -> void:
	var ch := plug.channel if plug != null else 0
	if ch < 0 or ch >= _channels.size():
		ch = 0
	var tv_obj = _channels[ch].tv
	var tv: RetroTV = tv_obj as RetroTV if (is_instance_valid(tv_obj)) else null
	_channels[ch].tv = null
	if ch == 0:
		connected_tv = null
	_release_audio_pair(ch, tv)
	_apply_audio_playing()
	if _channels.size() > 1:
		_remove_touch_surface(ch)
		return


## Put the lead's audio pair into the L and R sockets of the input the picture
## cord just went into, and take them out again when it leaves.
##
## The pair travels with the picture because on a CAPTIVE lead the sound already
## does: a machine with no A/V sockets of its own has one connection to a set, and
## on_tv_connected is the whole of it. Leaving the two connectors dangling in front
## of the television while the yellow one was seated would have said the opposite —
## that they route something, and that this lead was half plugged in.
##
## Hardware that wears real sockets (the NES, the Wii) never comes through here:
## it has no captive lead at all, and a spawned CompositeCable resolves every cord
## on its own. See CompositeCable._resolve.
func _seat_audio_pair(ch: int, tv: RetroTV) -> void:
	if tv == null or ch < 0 or ch >= _channels.size():
		return
	var pair: Array = _channels[ch].audio_plugs
	if pair.is_empty():
		return
	var plug := _live(_channels[ch].plug) as CablePlug
	if plug == null:
		return
	var sockets: Array = tv.audio_ports(tv.input_holding(plug))
	for c in mini(pair.size(), sockets.size()):
		var p := _live(pair[c]) as CablePlug
		var port := sockets[c] as RcaPort
		if p != null and port != null and port.enabled and port.seated_plug() == null:
			port.pick_up_object(p)


func _release_audio_pair(ch: int, tv: RetroTV) -> void:
	if tv == null or not is_instance_valid(tv) or ch < 0 or ch >= _channels.size():
		return
	for extra: Variant in _channels[ch].audio_plugs:
		var p := _live(extra) as CablePlug
		if p != null:
			_release_plug(tv.socket_holding(p), p)


## The TV connected to a given video-out channel, or null (persistence).
func get_channel_tv(ch: int) -> RetroTV:
	if ch < 0 or ch >= _channels.size():
		return null
	return _channels[ch].tv


## Which of that TV's four composite inputs channel `ch`'s lead is sitting in
## (persistence). Asked of the television rather than tracked here: the socket is
## its property, and a player can move the plug from one input to another without
## this system hearing anything about it.
func get_channel_tv_input(ch: int) -> int:
	if ch < 0 or ch >= _channels.size() or ch >= _channels.size():
		return 0
	var tv := _live(_channels[ch].tv) as RetroTV
	var plug := _live(_channels[ch].plug) as CablePlug
	if tv == null or plug == null:
		return 0
	return tv.input_holding(plug)


## How many video-out cables this system has (persistence).
func get_channel_count() -> int:
	return _channels.size()


func _remove_touch_surface(ch: int) -> void:
	var surf: TVTouchSurface = _channels[ch].touch_surface
	if is_instance_valid(surf):
		surf.queue_free()
	_channels[ch].touch_surface = null


## Which window of this machine's picture a given television should show, and the
## shader that cuts it out — dual-screen hardware only, where one composite frame
## carries the top panel above the bottom and each set is cabled to one of them.
##
## Replaces _update_tv_mirrors, which pushed a material onto every connected set
## every frame and had to be told when to stop. The set asks, so a set showing
## another input simply does not ask.
func get_video_stage(tv: Node) -> Dictionary:
	if _channels.size() <= 1:
		return {}
	var ch := -1
	for i in _channels.size():
		if _channels[i].tv == tv:
			ch = i
			break
	if ch < 0:
		return {}
	var r := _channels[ch].rect
	return {
		"shader": SCREEN_WINDOW_SHADER,
		"params": {
			"source_rect": Vector4(r.position.x, r.position.y, r.size.x, r.size.y),
			"eye_shift": _channels[ch].eye_shift,
		},
	}


## Read a slot that may be holding a freed instance.
##
## The Variant argument and return are the point: assigning a previously freed
## instance to ANY Object-typed variable — a local, or a function parameter —
## throws before is_instance_valid() gets a chance to guard it. Cables and TVs
## are freed out from under these arrays whenever a room is torn down or a slot
## restore rebuilds the set across frames.
static func _live(v: Variant) -> Object:
	return v if is_instance_valid(v) else null


## A freed system must not leave its touch surfaces on TVs. Its picture needs no
## cleaning up any more: a set that asks a freed machine for one stops getting it.
##
## It must also let its core go. Only ScenePersistence.clear_scene used to power
## machines off, so every other way one leaves — the trash can, a bare queue_free,
## a room torn down around it — skipped _stop_core() entirely: the achievements
## session was never released, so no other cabinet could claim it, and a controller
## rumbling at that moment kept rumbling. The C++ Libretro::_exit_tree still stops
## the emulation thread, which is why this was invisible; none of the GDScript-side
## release is its job. Safe here because a system is never reparented — a grab is
## driven, not a re-hang — so leaving the tree always means going away.
func _exit_tree() -> void:
	if is_powered_on:
		power_off()
	_release_cache_protection()
	for i in _channels.size():
		_remove_touch_surface(i)
	super._exit_tree()


# --- Cable management ---

## Build the two sockets a `uses_av_ports` console wears, and let the model seat
## them on its own moulded jacks.
##
## Video and ONE audio channel: this is mono hardware, and the second socket is the
## whole of its sound. Where that cord lands decides which single speaker plays —
## see on_av_topology_changed.
func _build_av_ports() -> void:
	# Named for the channel, matching the decks, so a save file reads the same on
	# either kind of hardware.
	const PORT_NAMES := {
		RcaPort.Channel.VIDEO: "VideoOut",
		RcaPort.Channel.AUDIO_L: "AudioLOut",
		RcaPort.Channel.AUDIO_R: "AudioROut",
	}
	var channels: Array = _model.av_port_channels()
	# Read off the CHANNEL LIST rather than off the sockets built, because those two
	# stopped being the same thing: a multi-way machine is as stereo as any other and
	# has one hole. Without this the Wii's left cord also fed the right speaker.
	for ch: int in channels:
		if ch == RcaPort.Channel.AUDIO_R:
			_av_stereo = true
	var built: Array = []
	if _model.av_ports_are_multi_way():
		# One socket for the lot — the Wii's AV Multi Out. Which cord carries which
		# signal is WiiAvPort.channel_for's business from here on.
		var multi: PackedScene = load("res://Scenes/Objects/system_models/wii/wii_av_port.tscn")
		if multi != null:
			var port := multi.instantiate() as RcaPort
			port.name = "AvMultiOut"
			add_child(port)
			built.append(port)
	else:
		var scene: PackedScene = load("res://Scenes/Objects/cables/rca_port.tscn")
		if scene == null:
			return
		for ch: int in channels:
			var port := scene.instantiate() as RcaPort
			port.name = str(PORT_NAMES.get(ch, "AvOut"))
			port.channel = ch as RcaPort.Channel
			port.direction = RcaPort.Direction.OUT
			add_child(port)
			built.append(port)
	_av_ports = built
	# After add_child: the model places these in world space off its own meshes.
	_model.configure_av_ports(built)
	_print_av_legend(built)
	# Hide the captive lead's own connector. CableAttachPoint carries a PortVisual —
	# the yellow RCA plug that reads as the lead permanently seated in the console —
	# and on a shell like the NES the model parks it right in the VIDEO jack. With
	# sockets there is no captive lead, so leaving it there blocks the very jack the
	# player has to plug into.
	for chan: VideoChannel in _channels:
		var visual := chan.attach.get_node_or_null("PortVisual") as Node3D
		if visual != null:
			visual.hide()


## Silkscreen the A/V row: the outlined box, the words under the jacks and the AV OUT
## heading. Console hardware is a source, so every one of these reads OUT.
##
## Stand-ins only, the same rule _place_name_label follows: a detailed shell carries
## its own printing in its texture, and ours would sit on top of it.
##
## Parented to the cabinet rather than to the model, which keeps it out of
## _body_aabb() — that walks the body and the model, and a plate merged into it would
## drag the nameplate off the front face.
func _print_av_legend(ports: Array) -> void:
	if _model == null or _model.has_baked_shell():
		return
	# A multi-way socket gets no phono legend. AvLegend draws a bracket over an audio
	# PAIR and a word under each jack, and a machine with one hole has neither — the
	# Wii prints "AV MULTI OUT" beside its socket instead, from its own model.
	if _model.av_ports_are_multi_way():
		return
	var legend := AvLegend.attach(self, ports)
	if legend != null:
		_model.configure_av_legend(legend)


## Called by a CompositeCable whenever a plug is seated or pulled anywhere on it.
##
## Mono, so there is one audio answer rather than two: the single cord either
## reaches one of the set's speakers or it reaches nothing. Both of this console's
## voices are then played AT that one speaker, which is what a mono feed into one
## input sounds like — two coincident sources sum, no downmix needed.
func on_av_topology_changed(_reported: Array) -> void:
	var feed := AvSource.resolve(self, _av_stereo)
	_av_cord_summary = feed.summary()
	_apply_av_feed(feed.video_sinks, feed.audio_sink, feed.left, feed.right)


func _apply_av_feed(video_devs: Array[RetroTV], audio_dev: Node3D, l: int, r: int) -> void:
	# The set every single-display consumer means: the wiimote's pointer, the RF
	# channel check, "has the picture moved to a television". The FIRST video sink,
	# and the only one that was ever resolved before.
	var video_dev: RetroTV = video_devs[0] if not video_devs.is_empty() else null
	# The conclusion, not the wiring — RcaPort logs each cord as it lands, this
	# says what they added up to. Picture and sound resolve independently below, so
	# "video=<none> audio=TV" is a real and easily-missed state: the console is
	# heard but never seen, which reads from the room as a dead console.
	#
	# Only on CHANGE. Seating one lead re-resolves the routing once per cord per
	# end, so a plain three-cord hookup would otherwise print this eighteen times
	# and bury the transition that matters.
	var names := PackedStringArray()
	for dev in video_devs:
		names.append(String(dev.name))
	var routing := "video=%s audio=%s  cords: %s" % [
		"<none>" if names.is_empty() else ", ".join(names),
		String(audio_dev.name) if audio_dev != null else "<none>",
		_av_cord_summary]
	if routing != _last_av_routing:
		_last_av_routing = routing
		print("[RetroSystem] A/V feed: %s" % routing)
		# A cord bridging two different channels conducts nothing either side can
		# use — video out into an audio in is the classic one, and it leaves a set
		# that plays sound perfectly while showing blue.
		if _av_cord_summary.contains("(!)"):
			push_warning("[RetroSystem] a cord has its ends on DIFFERENT channels "
				+ "(marked !) — it carries nothing. Check the colours match end to end.")
	_av_speaker_l = l
	_av_speaker_r = r
	# The cached pair is keyed on the gains last sent, not on the routing, so a
	# cord moving between sockets has to invalidate it or the new silence (or the
	# new sound) never reaches the mixer. Told rather than inferred: SystemAudio
	# reads the routing through _audio_speakers() and cannot see it change.
	#
	# Safe to call here, one line BEFORE _av_tv is assigned, because everything
	# route_changed touches is keyed on the speakers rather than on the set. It
	# must not grow a dependency on _audio_tv(), which is still the old sink at
	# this point; the position follows on the next frame's update_position().
	_audio.route_changed()
	_av_tv = audio_dev
	# The PICTURE follows the video cord alone: a lead with only its audio end in
	# leaves the set on its blue no-signal screen, as it would.
	var showing: RetroTV = video_dev
	if showing != _av_video_tv:
		if is_instance_valid(_av_video_tv):
			on_tv_disconnected(null)
		_av_video_tv = showing
		if showing != null:
			on_tv_connected(showing, null)
	# EVERY sink is told, picture and sound alike, because being told is what lets a
	# set work out which of its own inputs this machine is on — and a set that has
	# not been told shows its blue screen no matter what is cabled to it.
	#
	# One sink used to be told, and it was the AUDIO one when there was any: wire
	# the tower's sound to a speaker pair and its picture to a monitor, and the
	# thing that got the announcement was the speakers, which have no screen. The
	# monitor was never told about the machine plugged into it.
	var sinks: Array[Node3D] = []
	for dev in video_devs:
		sinks.append(dev)
	if audio_dev != null and not sinks.has(audio_dev):
		sinks.append(audio_dev)
	for old_sink in _av_sinks:
		if is_instance_valid(old_sink) and not sinks.has(old_sink):
			old_sink.on_av_source_lost(self)
	for sink in sinks:
		if not _av_sinks.has(sink):
			sink.on_av_source_found(self)
	_av_sinks = sinks


func _spawn_cables() -> void:
	for i in _channels.size():
		_channels[i].cable = CABLE_SCENE.instantiate()
	# Add cables to scene root so they're not affected by system's RigidBody transform weirdness
	call_deferred("_add_cables_to_scene")


func _add_cables_to_scene() -> void:
	# Deferred from _spawn_cables(), so a room change can land in between: during
	# a transition there is no current scene to hang the cables on, and this
	# system is on its way out with it.
	if not is_inside_tree() or get_tree().current_scene == null:
		return
	for i in _channels.size():
		var inst: Node3D = _channels[i].cable
		get_tree().current_scene.add_child(inst)
		# Track cable in the "spawned" group so clear_scene() includes it.
		inst.add_to_group("spawned")
		var plug := inst.get_node("CablePlug") as CablePlug
		var rope := inst.get_node("VerletRope") as VerletRope
		_channels[i].plug = plug
		_channels[i].rope = rope

		# Tell the plug who owns it and which channel it carries
		plug.set_system(self)
		plug.channel = i
		plug.channel_label = _channels[i].label
		_decorate_channel_plug(plug, i)

		# Exclude the plug from colliding with this system so it doesn't jitter on spawn
		plug.add_collision_exception_with(self)

		# Stand the plug off the rope's start anchor along the way the port faces,
		# so the lead lays itself out of the machine rather than across it.
		plug.global_position = _plug_park_pos(i, 0)

		# Per-channel wiring, when the model asks for something other than the
		# cable scene's own composite pigtail. A channel carrying one signal wants
		# one wire, in its own colour — the DS's bottom screen is a lone blue cord
		# beside the top's yellow/white/red three.
		var wires := _channels[i].wires
		if not wires.is_empty():
			rope.ribbon_count = wires.size()
			rope.ribbon_colors = wires

		# The audio pair, and whether this channel has one at all.
		var pair: Array = _adopt_audio_pair(inst, i, rope)

		# Wire rope anchors: start = system's attach point, end = plug
		rope.start_node = _channels[i].attach
		# Same correction at THIS end. The attach point sits at the console's jack,
		# and the plug seated in it is modelled from its collar too — so without
		# this the cord started inside the barrel and appeared to sprout from the
		# middle of the connector rather than the strain relief behind it.
		rope.start_anchor_offset = _port_cable_anchor(_channels[i].attach)
		if pair.is_empty():
			rope.end_node = plug
			# End the cord AT the RCA plug's cable boss. The plug's origin is its
			# SEATING reference, up at the collar, so a zero offset runs the tube out
			# through the barrel.
			rope.end_anchor_offset = plug.cable_anchor
		else:
			# One tail per cord, each ending at its own connector's boss. The trunk's
			# terminal particle is left unanchored on purpose — the plugs carry the
			# breakout, the way an unsupported junction behaves on the real lead.
			var groups := PackedInt32Array()
			for c in rope.ribbon_count:
				groups.append(c)
			rope.fray_end_groups = groups
			rope.end_node = null
			var ends: Array = [plug, pair[0], pair[1]]
			for c in ends.size():
				var p: CablePlug = ends[c]
				rope.set_fray_end_node(c, p)
				rope.set_fray_end_anchor_offset(c, p.cable_anchor)
		rope._init_points()
		_channels[i].max_reach = _rope_reach(rope)

		# Restore a pending TV connection requested before the cable was ready
		if _channels[i].pending_tv != null:
			print("[RetroSystem] _add_cables_to_scene: restoring pending TV connection (ch %d)" % i)
			_snap_cable_to_tv(_channels[i].pending_tv, i, int(_channels[i].pending_input))
			_channels[i].pending_tv = null
			_channels[i].pending_input = 0
	_apply_video_out()


## Take charge of one lead's audio pair, or retire it.
##
## The cable scene ships a composite pigtail — a picture cord with the audio pair
## beside it — because that is what all but one of this room's leads is. A channel
## whose model asks for a single wire has no pair to break out, so the two spare
## connectors are freed and the rope goes back to the plain unfrayed cord it was:
## the fray count comes off, and the trunk grows by the tail it is no longer
## spending, which keeps every channel's reach the 1.80 m the lead is.
##
## Returns [left, right], or [] on a one-wire channel.
func _adopt_audio_pair(inst: Node3D, channel: int, rope: VerletRope) -> Array:
	var pair: Array = []
	for nm in ["CablePlugL", "CablePlugR"]:
		var p := inst.get_node_or_null(nm) as CablePlug
		if p != null:
			pair.append(p)
	if rope.ribbon_count < 3 or pair.size() < 2:
		for p: CablePlug in pair:
			p.queue_free()
		rope.segment_count += rope.fray_segments_end
		rope.fray_segments_end = 0
		_channels[channel].audio_plugs = []
		return []
	for c in pair.size():
		var p: CablePlug = pair[c]
		# NO set_system: on this lead the sound travels with the picture, so these
		# two are the picture cord's companions rather than routes of their own (see
		# _seat_audio_pair). A plug that named a host would have the television take
		# it for a second video connection from this machine.
		p.channel = channel
		p.add_collision_exception_with(self)
		p.global_position = _plug_park_pos(channel, c + 1)
	_channels[channel].audio_plugs = pair
	return pair


## Sideways step per connector across the face the port is on, so three plugs on
## one lead do not spawn inside each other. Indexed picture, left, right.
const _PLUG_PARK_SPREAD := [0.0, -0.02, 0.02]


## Where connector `index` of channel `ch`'s lead stands when the lead is built or
## parked, in world space.
##
## Through the attach point's TRANSFORM, not its position: the model's spawn offset
## is read in that frame (see RetroSystemModel.get_cable_spawn_offset), so the cord
## trails out of the face its port is on whichever way the machine happens to be
## turned. Added in the world, it always pointed at world -Z — which is the back of
## a console standing square to the room and nothing at all on one that has been
## picked up, turned round, or built with its port on the flank.
func _plug_park_pos(ch: int, index: int) -> Vector3:
	var attach := _live(_channels[ch].attach) as Node3D
	if attach == null:
		return global_position
	var spread: float = _PLUG_PARK_SPREAD[mini(index, _PLUG_PARK_SPREAD.size() - 1)]
	return attach.global_transform * (_model.get_cable_spawn_offset(ch)
		+ Vector3(spread, 0, 0))


## How far one lead reaches from its attach point: the trunk, plus the tail a
## frayed end hangs off it. Read off the rope rather than tabled, so a scene that
## re-lengths the cord cannot leave the tether behind.
func _rope_reach(rope: VerletRope) -> float:
	var fray_seg: float = rope.fray_segment_length
	if fray_seg <= 0.0:
		fray_seg = rope.segment_length
	return rope.segment_count * rope.segment_length \
		+ float(rope.fray_segments_end) * fray_seg


## Where the cord meets the plug seated in the console's own jack, in the attach
## point's local space — the mirror of CablePlug.cable_anchor at the far end of
## the same lead, and derived the same way so reshaping the connector cannot
## desync either end.
##
## Zero when the model hides PortVisual: with no plug modelled at this end the
## cord should leave the jack itself, which is what the attach point already is.
func _port_cable_anchor(attach: Node3D) -> Vector3:
	var pv := attach.get_node_or_null("PortVisual") as MeshInstance3D
	if pv == null or pv.mesh == null or not pv.visible:
		return Vector3.ZERO
	var ab: AABB = pv.mesh.get_aabb()
	# Cable trails -Z (VerletRope.plug_exit_axis), so the boss is at min Z.
	return pv.transform * Vector3(ab.get_center().x, ab.get_center().y, ab.position.z)


## True when this system offers the Enable Video Out toggle: the machine has a
## display of its own, so running a lead to a television is a choice.
##
## Asked of the SCREEN rather than of is_handheld(), because the two are not the
## same question. The Virtual Boy is a tabletop console by every other measure —
## it takes a controller and it has no battery — but the picture is already in
## front of your eyes, and a lead permanently hanging off the back of it is the
## one thing on that machine nobody would want.
func supports_video_out_toggle() -> bool:
	if _model == null:
		return false
	return _model.is_handheld() or _model.get_builtin_screen() != null


## Toggle floating: on = freeze right where it is (or where it's next dropped);
## off = normal physics resumes (unless currently held or being restored).
func set_ignore_gravity(on: bool) -> void:
	if on == ignore_gravity:
		return
	ignore_gravity = on
	if on:
		_freeze_in_place()
	elif not is_picked_up():
		freeze = false
		sleeping = false
	NetworkManager.report_event(NetEvents.Event.EV_SYS_GRAVITY, {"sys": self, "on": on})


func _on_system_dropped(_pickable: Node3D) -> void:
	if ignore_gravity:
		# Deferred: let the release finish (velocities applied) before parking.
		_freeze_in_place.call_deferred()


func _freeze_in_place() -> void:
	if ignore_gravity and not is_picked_up():
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		freeze = true


## Show/hide+park the video-out cables per the video_out_enabled toggle.
## Disabling first unplugs any connected TV (so no picture lingers), then
## hides the whole cable and freezes it out of the simulation.
func set_video_out_enabled(on: bool) -> void:
	if not supports_video_out_toggle():
		on = true   # consoles are always on, whatever a save/peer says
	if on == video_out_enabled:
		return
	video_out_enabled = on
	_apply_video_out()
	NetworkManager.report_event(NetEvents.Event.EV_SYS_VIDEO_OUT, {"sys": self, "on": on})


func _apply_video_out() -> void:
	# The only thing _physics_process does is keep the video-out leads inside
	# their reach. With the leads hidden and frozen there is nothing to clamp, so
	# the tick goes off entirely rather than opening with a flag test 90 times a
	# second — and a handheld, which has no video out, never ticks at all.
	set_physics_process(video_out_enabled)
	for i in _channels.size():
		var inst := _live(_channels[i].cable) as Node3D
		var plug := _live(_channels[i].plug) as CablePlug
		if inst == null or plug == null:
			continue
		var tv := _live(_channels[i].tv) as RetroTV
		# The whole lead goes with the picture cord: the audio pair beside it is on
		# the same cable, and a set fed by a machine with its video out switched off
		# is not fed at all.
		var ends: Array = [plug]
		for extra: Variant in _channels[i].audio_plugs:
			var p := _live(extra) as CablePlug
			if p != null:
				ends.append(p)
		if not video_out_enabled and tv != null:
			# Ask the set which socket is holding each rather than assuming the first:
			# a television has four composite inputs and this lead may be in any of
			# them, and naming CompositePort left a lead in Composite 2 seated while
			# its video-out was switched off.
			for e: CablePlug in ends:
				_release_plug(tv.socket_holding(e), e)
		for c in ends.size():
			var p: CablePlug = ends[c]
			p.enabled = video_out_enabled
			if video_out_enabled:
				# A plug already socketed into a TV (e.g. restored from a save, where
				# _apply_video_out runs right after the snap) is held frozen at the port by
				# the snap zone. Unfreezing/parking it here drops it off the socket, and it
				# then drifts under gravity + rope tension. Only park a free-dangling plug.
				if not p.is_picked_up():
					p.freeze = false
					p.global_position = _plug_park_pos(i, c)
					p.linear_velocity = Vector3.ZERO
			else:
				p.freeze = true
		if video_out_enabled:
			inst.visible = true
			inst.process_mode = Node.PROCESS_MODE_INHERIT
		else:
			inst.visible = false
			inst.process_mode = Node.PROCESS_MODE_DISABLED


## How far a released connector is drawn out of its socket, in metres. Clear of the
## 60 mm grab distance every RcaPort uses, so it cannot be snapped straight back up.
const PULLED_CLEAR := 0.12


## Take a plug out of the socket holding it and stand it clear of the bank.
##
## Disarming the zone around the drop is not enough on its own once three cords go
## into a set at once. A composite input's sockets are 18 mm apart and each reaches
## 60 mm, so a plug released at the panel is standing inside its NEIGHBOURS' grab
## areas as well as its own — pull the lead and the set caught the red connector in
## the socket the white one had just left. So it is also drawn back along the
## socket's own axis, which is the way a hand takes it out.
##
## The transform goes through the physics server as well as the node: the body is
## live again the moment it is dropped, and a transform written only on the node is
## overwritten on the next tick, putting it back in the socket. Same recipe, and the
## same reasons, as CompositeCable.net_release_plug.
func _release_plug(port: XRToolsSnapZone, plug: CablePlug) -> void:
	if port == null or not is_instance_valid(port):
		return
	port.enabled = false
	port.drop_object()
	if is_instance_valid(plug):
		plug.global_position = port.global_position \
			+ port.global_transform.basis.z.normalized() * PULLED_CLEAR
		PhysicsServer3D.body_set_state(plug.get_rid(),
			PhysicsServer3D.BODY_STATE_TRANSFORM, plug.global_transform)
	_reopen_port(port)


## Let the deferred drop handler and the area's body_exited both run before the
## socket is live again. Deliberately not awaited by the caller: the release has
## already happened, and this only reopens the socket behind it.
func _reopen_port(port: XRToolsSnapZone) -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if is_instance_valid(port):
		port.enabled = true


## Mark a multi-output host's second lead so the player can tell the two apart: a
## blue connector on the BOTTOM channel against the composite trio of the top.
##
## No printed tag. The word TOP floated in the air off the end of a cable, which is
## not a thing a lead does, and it was redundant twice over by the time it read:
## the top lead is a yellow/white/red pigtail and the bottom one a single blue
## cord, which is the same distinction the hardware would make.
func _decorate_channel_plug(plug: CablePlug, channel: int) -> void:
	if channel <= 0:
		return
	plug.plug_color = Color(0.2, 0.6, 1.0)


func _process(_delta: float) -> void:
	# Tilt-sensor feed (handhelds): the device's physical orientation IS the
	# accelerometer for tilt carts (WarioWare Twisted, Kirby Tilt 'n' Tumble).
	# libretro frame: X = screen-right, Y = screen-top, Z = out of the screen;
	# at rest flat (screen up) = (0,0,1) g. Our shell: screen normal = +Y,
	# screen-top = -Z, screen-right = +X. During netplay the tilt rides the
	# deterministic frame schedule (aux block, supplied by the port-0 owner)
	# instead of feeding the core directly.
	if is_powered_on and _model != null and _model.is_handheld():
		var a := global_transform.basis.orthonormalized().transposed() * Vector3.UP
		if not NetworkManager.netplay_set_aux_sensor(self, 0, 0,
				int(a.x * 1000.0), int(-a.z * 1000.0), int(a.y * 1000.0)):
			_libretro.SetSensorAccel(0, a.x, -a.z, a.y)
	_update_disc_spin(_delta)
	_audio.ensure_bound()
	_ensure_port_devices_bound()
	# Every fourth frame, staggered across machines: the route is a dictionary
	# and two dynamic lookups per call, and a room holds eight of these. A
	# carried set's sound trails it by 55 ms at most, under what the ear places.
	if (Engine.get_process_frames() + get_instance_id()) % 4 == 0:
		_audio.update_position()
	# Nothing left to do until something switches on again. Tested here rather
	# than per frame from outside: a room holds a lot of these, most of them off.
	if not is_powered_on and _disc_spin <= 0.0:
		set_process(false)


## Spin the seated disc: ramp up while powered with the tray shut, ramp down
## when the tray opens or the power goes off. Purely visual — each peer derives
## the same state from power + tray, so no sync is needed.
func _update_disc_spin(delta: float) -> void:
	var disc := _snapped_cartridge as RetroDisc
	if disc == null or not is_instance_valid(disc):
		_disc_spin = 0.0
		return
	# "Shut and seated": a tray disc spins only with the lid closed (MediaTray.can_spin
	# already means shut-over-a-disc); a slot disc has no lid but must have finished its
	# insert ride so the spin doesn't fight MediaSlot's ride tween.
	var shut := true
	if _tray != null:
		shut = _tray.can_spin()
	elif _slot != null:
		shut = _slot.is_media_seated()
	var target := DISC_SPIN_MAX if (is_powered_on and shut) else 0.0
	var rate := DISC_SPIN_UP if target > _disc_spin else DISC_SPIN_DOWN
	_disc_spin = move_toward(_disc_spin, target, rate * delta)
	# A disc being grabbed out keeps its pose (it's no longer frozen in the bay).
	if _disc_spin > 0.0 and disc.freeze and disc.can_visually_spin():
		disc.rotate_object_local(Vector3.UP, _disc_spin * delta)
	# The shell's own mechanism turns with the motor, NOT with the platter: a disc
	# lifted out mid-spin stops being rotated here, and a turntable that stopped
	# dead with it would be reporting the hand rather than the motor. Models
	# without a modelled mechanism ignore this.
	if _disc_spin > 0.0 and _model != null:
		_model.spin_disc_mechanism(_disc_spin * delta)


## Touch-screen feed (dual-screen handhelds): uv is a point in the COMPOSITE
## core framebuffer (both screens), 0..1 — the model converts a poke on its
## bottom screen through its UV window. RETRO_DEVICE_POINTER is how melonDS/
## citra take touch input. During netplay the touch rides the deterministic
## frame schedule (aux block, supplied by the port-0 owner).
func feed_touch(uv: Vector2, pressed: bool) -> void:
	if _libretro == null or not is_powered_on:
		return
	var px := int(clampf(uv.x, 0.0, 1.0) * 65534.0) - 32767
	var py := int(clampf(uv.y, 0.0, 1.0) * 65534.0) - 32767
	if not NetworkManager.netplay_set_aux_pointer(self, 0, 0, px, py, pressed):
		_libretro.SetPointerState(0, px, py, pressed)


func _physics_process(_delta: float) -> void:
	if not video_out_enabled:
		return   # cables hidden and frozen — nothing to clamp
	for i in _channels.size():
		var max_len: float = _channels[i].max_reach
		if max_len <= 0.0:
			continue   # cable not built yet
		var plug := _live(_channels[i].plug) as CablePlug
		var attach := _live(_channels[i].attach) as Node3D
		if plug == null or attach == null:
			continue
		# Snapped to TV or actively held by the user — don't fight whoever owns the plug
		if _live(_channels[i].tv) == null:
			_clamp_plug(plug, attach.global_position, max_len)
		# Every connector on the lead is on the same cord and reaches the same
		# distance; the pair is guarded on its own hold rather than on the channel's
		# television, since either of them can be sitting in a socket while the
		# picture cord is not.
		for extra: Variant in _channels[i].audio_plugs:
			var p := _live(extra) as CablePlug
			if p != null:
				_clamp_plug(p, attach.global_position, max_len)


## Hold one plug within the cord's reach of where the cord leaves the machine,
## and kill the velocity that carried it past. A hard clamp rather than a spring,
## for the reason CompositeCable._physics_process gives: over-extension here runs
## to a metre and a spring stiff enough to haul a plug back at that distance
## launches it.
func _clamp_plug(plug: CablePlug, attach_pos: Vector3, max_len: float) -> void:
	if plug.is_picked_up():
		return          # a hand, a beam or a socket owns it
	var diff := plug.global_position - attach_pos
	var dist := diff.length()
	if dist <= max_len or dist < 0.0001:
		return
	var dir := diff / dist
	plug.global_position = attach_pos + dir * max_len
	var outward_vel := dir.dot(plug.linear_velocity)
	if outward_vel > 0.0:
		plug.linear_velocity -= dir * outward_vel


## Power on: start this system's libretro core
func power_on() -> void:
	if is_powered_on:
		return
	# A console with no TV connected still powers on and runs — the core renders to
	# its own texture regardless, and a set plugged in later simply starts sampling
	# it. Handhelds always have a panel, so they never take this branch.
	if not _has_display():
		# Name the actual state. "No display" covers two very different faults and
		# the loud one — audio cords in, video cord out — looks identical to a
		# console that is simply broken, because you can hear it running.
		if is_instance_valid(_av_tv):
			print("[RetroSystem] Powering on with SOUND but no PICTURE: audio reaches %s, "
				% _av_tv.name + "no video cord is linked. Check the yellow lead at BOTH ends.")
		else:
			print("[RetroSystem] Powering on with no display connected (connect a TV to see output)")
	# Through the same resolvers as every other path — the options panel, netplay,
	# the SRAM paths and achievements all ask these two, and the power button
	# answering them itself is how it would end up running a different core.
	# Resolved BEFORE the empty-slot check, which cannot be answered without
	# knowing the core: whether a machine shows its BIOS is a fact about the core
	# and the files in its system directory, not about the systemid.
	# Before the core is resolved and before the verdict is taken: an assembled
	# machine boots from the stack, not from the console's own slot, and both of
	# those read rom_path.
	var stack_spec := _expansion_launch.apply_expansion_launch()
	var resolved_core := _resolve_core()
	var resolved_dir := _resolve_dir()

	# Nothing in the slot, and this core will start anyway. Named because it is
	# asked four times across this function and the answer CHANGES half way
	# through: the verdict below may substitute blank media into rom_path, after
	# which rom_path.is_empty() is false for a machine that is still, as far as
	# the player is concerned, empty. See `still_empty` past that point.
	var slot_empty := rom_path.is_empty() \
		and BiosBoot.can_boot_empty(resolved_core, systemid)

	# Only when the slot is empty: empty_media_path CREATES the blank image, and
	# a machine with a game in it must not leave one behind.
	var blank := ""
	if slot_empty:
		blank = BiosBoot.empty_media_path(
			BiosBoot.empty_media_extension(resolved_core, systemid))

	var verdict := _power_on_verdict(resolved_core, systemid, rom_path,
		BiosBoot.missing_required(resolved_core), blank,
		slot_empty and BiosBoot.boots_with_no_content(resolved_core, systemid),
		resolved_core.is_empty()
			or not CoreDownloadManager.installed_core_lib(resolved_core).is_empty())
	if not bool(verdict["start"]):
		push_error("RetroSystem: Cannot power on - %s" % verdict["log"])
		# Over the hardware rather than the picture: every one of these is a
		# state of the console, and half the machines they fire on have no set
		# connected to show anything on.
		var refusal_toast := _machine_toast()
		if refusal_toast != null:
			refusal_toast.show_notice(_display_name(), str(verdict["title"]),
				str(verdict["description"]), Color(verdict["accent"]))
		return

	# May be empty media: a machine with nothing in it whose BIOS is installed is
	# handed a blank disc, which is what a console with a closed empty tray is.
	rom_path = str(verdict["rom"])

	# The same question as slot_empty, asked again on the OTHER side of that
	# substitution, which is why it cannot reuse it: a machine handed blank media
	# now has a non-empty rom_path while still being a console with nothing in
	# its tray. Both readers below want this one, not the one above.
	var still_empty := rom_path.is_empty() \
		and BiosBoot.can_boot_empty(resolved_core, systemid)

	print("[RetroSystem] Powering on: core=%s dir=%s rom=%s" % [resolved_core, resolved_dir, rom_path])

	# The core is handed rom_path verbatim: nothing downstream unpacks an archive
	# the core cannot read, so without this the machine sits powered on and black.
	if not _resolve_content(resolved_core):
		return

	# With the override on the BIOS options are the player's, so they are written
	# once as a default and then left alone -- a machine still boots to its BIOS
	# the first time, and a change made afterwards stands. With it off they are
	# pinned instead, by _apply_forced_core_options below, which rewrites them
	# every launch. Never both: seed_values records the key as seeded for ever,
	# and doing that behind a pin would silently disarm the override.
	if AppPrefs.bios_boot_override:
		CoreOptionsStore.seed_values(resolved_dir, resolved_core,
			BiosBoot.pinned_options(resolved_core, systemid, still_empty))
	_apply_forced_core_options(resolved_dir, resolved_core)
	AppPrefs.apply_hw_render_for(resolved_core)
	_libretro.SetSramPath(sram_path_for_run(resolved_core))
	# Before StartContent: identification happens as the core comes up, so the
	# claim has to be in place by then. Returns false when another cabinet already
	# holds the session, nobody is signed in, or the system has no RA console —
	# all of which just mean this machine runs without achievements.
	_claim_achievements_session()
	_protect_active_rom()
	# A machine starting with NOTHING in it needs the core handed a null game
	# info rather than an empty path, and most cores do not survive that -- six of
	# sixteen surveyed took the process down. It is switched on only for the
	# machines measured to want it, and off again straight after so the next
	# machine to start is not handed a setting it never asked for.
	var no_content := still_empty \
		and BiosBoot.boots_with_no_content(resolved_core, systemid)
	if no_content:
		ClassDB.class_call_static("Libretro", "SetNoContentPassesNull", true)
	# An assembled machine goes over as one piece if the core will take it that
	# way; only if it will not do we fall back to a single path and say what the
	# drive is about to lose.
	if not _expansion_launch.start_subsystem_content(resolved_dir, resolved_core, stack_spec):
		_expansion_launch.warn_missing_sidecar(stack_spec)
		_libretro.StartContent(resolved_dir, resolved_core, rom_path)
	if no_content:
		ClassDB.class_call_static("Libretro", "SetNoContentPassesNull", false)
	_after_core_started()


## Everything a machine does once its core is up, whichever way it was started.
##
## Written once because the netplay start used to be an abridged copy, and what
## the abridgement dropped was invisible until you looked for it: the power
## button kept saying START on a machine that was running, and the core was never
## asked whether it has disk control, so a netplay disc swap had nothing to go on.
func _after_core_started() -> void:
	# A machine with nowhere to send its picture is not heard either.
	_apply_audio_playing()
	# A fresh run re-asks which backend came up — that is decided per core start,
	# and this first attempt is expected to find neither.
	_port_devices_settled = false
	_audio.rebind()
	is_powered_on = true
	set_process(true)
	start_card_polling()
	_update_power_button_visual()
	_model.on_power_on()
	# Learn whether this core exposes the disk-control interface (multi-disc
	# swap). The emulation thread is only starting here, so this queues and is
	# answered once the core is up.
	_libretro.RequestDiskInfo()
	# And re-make whatever link cable this machine is on.
	#
	# Stopping a core takes its endpoints out of LinkCoordinator, and that cuts
	# the whole bus rather than idling one seat -- so after a machine is
	# switched off the lead still in its socket is joined to nothing, and the
	# console at the other end is left loose. Nothing puts it back by itself: a
	# cable re-resolves when a PLUG MOVES, and powering a machine on moves no
	# plug. Measured on a Quest, a GameCube and a Game Boy Advance on a link
	# lead: the first power-on joined (bus 0 [P1 on, P2 on]), switching the
	# handheld off left "nothing cabled, loose: m1:0 on", and every power-on
	# after that re-attached under fresh endpoint ids and stayed loose. Four
	# Swords never saw the handheld again until the lead was pulled and
	# re-seated by hand.
	net_refresh_link_cables()


## Should the power button do anything, and with what in the slot?
##
## Static and pure so the decision can be asserted without a core, a model or a
## scene — power_on() itself dereferences all three, which is why the rules used
## to be untestable. The two facts that need the disk are looked up by the
## caller and passed in: `missing` is BiosBoot.missing_required(), and `blank` is
## the path to an empty image when this machine can show its BIOS with an empty
## slot, "" otherwise. Returns
##   {start: bool, rom: String, log: String, title, description, accent}
## with the card fields filled in whenever `start` is false.
##
## Three refusals and one substitution, in the order they can be answered:
##   * no core resolved — used to be a bare push_error with nothing shown at all
##   * a required BIOS is missing — used to be a black screen and no explanation
##   * an empty slot the machine cannot boot from — the long-standing card
##   * an empty slot it CAN boot from — hand it a blank disc and start
static func _power_on_verdict(core_name: String, sysid: String, rom: String,
		missing: Array[Dictionary], blank: String, empty_ok := false,
		core_installed := true) -> Dictionary:
	var waiting := AchievementToast.ACCENT_WAITING
	var fault := AchievementToast.ACCENT_NOTICE

	if core_name.is_empty():
		return {
			"start": false, "rom": "",
			"log": "no core set and no default for systemid '%s'" % sysid,
			"title": "No core installed",
			"description": "Pick one in OPTIONS > Cores, then switch it on.",
			"accent": waiting,
		}

	# Named but not on disk, which is a different failure from having no core at
	# all and used to be indistinguishable from a broken one: the machine went
	# through every check, printed that it was powering on, and then sat black.
	#
	# An assembled machine is how a player meets this without ever having chosen a
	# core. A stack pins the core its COMBINATION needs, which is often not the
	# console's own -- a Super Famicom runs on snes9x until a Super Game Boy goes
	# into it, and then it needs bsnes, because snes9x cannot do that at any
	# price. So the core named here can be one the player has never been asked
	# about, and saying which one is missing is the whole of the help.
	#
	# Defaulted true so the check stays out of the pure verdict logic: this
	# function is a table of decisions and reads no disk, and its cases are tested
	# by calling it directly.
	if not core_installed:
		return {
			"start": false, "rom": rom,
			"log": "core '%s' is not installed" % core_name,
			"title": "Core not installed",
			"description": "This machine needs the %s core.\nGet it in OPTIONS > Cores."
				% core_name,
			"accent": fault,
		}

	# Asked even when a game IS inserted: a PS2 with no bios folder cannot run
	# anything, and the failure looks identical to a broken core.
	if not missing.is_empty():
		var first: Dictionary = missing[0]
		var path := str(first.get("path", ""))
		var more := "" if missing.size() == 1 else " (+%d more)" % (missing.size() - 1)
		return {
			"start": false, "rom": rom,
			"log": "core '%s' is missing required firmware: %s" % [core_name, path],
			"title": "BIOS required",
			# Two lines, and no absolute path. The card is 520x132 at 1400 px/m —
			# about a playing card held at arm's length — and a Windows system path
			# overflowed it top AND bottom, clipping the one line that says what to
			# do about it. The BIOS / Extras tab prints the folder itself ("Files go
			# in: …"), so repeating it here bought nothing and cost the instruction.
			"description": "%s%s is missing.\nAdd it in OPTIONS > Cores > BIOS / Extras."
				% [path, more],
			"accent": fault,
		}

	if not rom.is_empty():
		return {"start": true, "rom": rom, "log": "", "title": "", "description": "", "accent": waiting}

	# Nothing in the slot. A machine whose BIOS is installed and whose core will
	# take a blank disc starts anyway, silently, the way the hardware does.
	if not blank.is_empty():
		return {"start": true, "rom": blank, "log": "", "title": "", "description": "", "accent": waiting}

	# Or whose core will start with nothing handed to it at all, which is a
	# different mechanism and a rarer one: a Game Boy Advance with no cartridge
	# draws its BIOS screen and then listens on the link port, which is how it
	# ends up on the end of a GameCube lead or receiving a game from another
	# handheld. An empty file would not do -- there is no drive to look at.
	if empty_ok:
		return {"start": true, "rom": "", "log": "", "title": "", "description": "", "accent": waiting}

	# Orange rather than the red of a fault: nothing is broken, the machine is
	# just waiting for something the player can put in from where they stand.
	var medium := "disc" if MediaDimensions.is_disc_system(sysid) else "cartridge"
	return {
		"start": false, "rom": "",
		"log": "no cartridge inserted",
		"title": "No game inserted",
		"description": "Put a %s in, then switch it on." % medium,
		"accent": waiting,
	}


## Settle rom_path against what this core actually declares it can load.
##
## Unpacks (and deletes) an archive the core cannot read, and refuses the
## power-on outright for a format no amount of unpacking will fix. Returns false
## when the machine must stay off.
##
## A core that declares the archive extension is left alone — for fbneo, MAME and
## daphne the .zip is the romset, not a wrapper around one.
func _resolve_content(core: String) -> bool:
	var verdict := RomCompat.resolve(rom_path, core, systemid)
	if int(verdict["verdict"]) == RomCompat.Verdict.UNSUPPORTED:
		push_error("RetroSystem: %s" % verdict["message"])
		# On the card rather than the TV's OSD: half the machines this fires on
		# are handhelds with no set connected, and the card anchors to whatever
		# screen the machine actually has. A console with no TV at all gets the
		# log alone, which is all it could show anyway.
		var toast := _screen_toast()
		if toast != null:
			toast.show_notice(rom_path.get_file(),
				"Cannot run this game", str(verdict["message"]))
		return false

	var resolved := str(verdict["path"])
	if resolved != rom_path and not resolved.is_empty():
		rom_path = resolved
		# The cartridge outlives the run — an eject re-reads rom_path from it, and
		# so does a scene reload — so leaving it holding the .zip we just deleted
		# would fail the same way on the next insert.
		if is_instance_valid(_snapped_cartridge) \
				and "rom_path" in _snapped_cartridge:
			_snapped_cartridge.set("rom_path", resolved)
	return true


func _protect_active_rom() -> void:
	if rom_path == _protected_cache_path:
		return
	_release_cache_protection()
	if systemid.is_empty() or rom_path.is_empty():
		return
	RommCacheManifest.protect_file(systemid, rom_path)
	_protected_cache_path = rom_path


func _release_cache_protection() -> void:
	if _protected_cache_path.is_empty():
		return
	RommCacheManifest.unprotect_file(systemid, _protected_cache_path)
	_protected_cache_path = ""


## Power off: stop the running core
func power_off() -> void:
	if not is_powered_on:
		return
	print("[RetroSystem] Powering off")
	_stop_core()
	_restore_displaced_options()


## Hand back what this machine's workaround pins took from the shared file, so a
## 64DD run does not decide how every other Nintendo 64 renders.
func _restore_displaced_options() -> void:
	if _displaced_options.is_empty() or _displaced_core.is_empty():
		return
	if CoreOptionsStore.merge_values(_resolve_dir(), _displaced_core, _displaced_options):
		print("[RetroSystem] restored displaced core options: %s" % str(_displaced_options))
	_displaced_options.clear()
	_displaced_core = ""


## Everything a machine does when its core goes away, whichever way it was
## stopped. The netplay stop used to be an abridged copy of this, and what the
## abridgement dropped stayed behind: the achievements session was never
## released, so no other cabinet could claim it, and the disc state survived to
## describe a core that had gone.
func _stop_core() -> void:
	# Zero any active rumble on all plugged-in controllers so vibration
	# doesn't leak past core unload if the core was rumbling at shutdown.
	for ctrl in _port_controllers:
		if ctrl and is_instance_valid(ctrl) and ctrl.has_method("set_rumble"):
			ctrl.set_rumble(0.0, 0.0)
	RA.release_session(self)
	_libretro.StopContent()
	_release_cache_protection()
	_audio.on_core_stopped()
	is_powered_on = false
	# StopContent returned but the core has not finished: a card the core owns is
	# written during the teardown that follows. Keep watching for a while.
	stop_card_polling_soon()
	_has_disk_control = false
	_disc_index = 0
	_disc_ejected = false
	_options_panel.hide_panel()
	_update_power_button_visual()
	_model.on_power_off()
	# Both directions, because the machine still running is the one left wrong.
	#
	# StopContent has just cut the bus from under a lead that is still in its
	# socket, so the console at the other end holds a join to endpoints that no
	# longer exist. Re-resolving here puts it back to a lead seated in a
	# powered machine waiting for an unpowered one -- which is a state the
	# coordinator handles, and the state it was in before this machine was ever
	# switched on.
	net_refresh_link_cables()


## Toggle power (used by the power button)
func toggle_power() -> void:
	if NetworkManager.is_active() and not NetworkManager.is_event_applying():
		# A running lockstep game: power stops it on every peer.
		if NetworkManager.netplay_running() and NetworkManager.netplay_system() == self:
			NetworkManager.netplay_stop("powered off")
			return
		# Host powering on a determinism-verified core → start lockstep netplay:
		# every peer runs the core locally instead of the host-only placeholder.
		if NetworkManager.is_host() and not is_powered_on:
			if _netplay_eligible():
				if NetworkManager.netplay_start_host(self, _resolve_core(), net_rom_md5()):
					return   # cold start drives net_start_core on every peer
			else:
				# This used to fall straight through to a local boot: no signal,
				# no error, remote players stranded on the host-only placeholder
				# and nothing anywhere saying why. It still boots locally -- that
				# is the right fallback -- but it now says so.
				_report_netplay_blocked()
		if NetworkManager.is_client():
			# Non-netplay core: emulation runs on the host only — send the intent.
			NetworkManager.report_event(NetEvents.Event.EV_SYS_POWER, {"sys": self})
			return
	if is_powered_on:
		power_off()
	else:
		power_on()
	# Host in a session: tell clients the new state (placeholder screens).
	if NetworkManager.is_active() and NetworkManager.is_host() \
			and not NetworkManager.is_event_applying():
		NetworkManager.report_event(NetEvents.Event.EV_SYS_POWER_STATE,
			{"sys": self, "on": is_powered_on})


## True if this system can run lockstep netplay right now: a determinism-verified
## core is resolvable and its present boot (game, empty media, or BIOS-only) can
## be reproduced by every peer.
func _netplay_eligible() -> bool:
	var resolved_core := _resolve_core()
	return NetworkManager.netplay_capable(resolved_core) \
		and not net_boot_spec(resolved_core).is_empty()


## Say why this machine is booting local-only, and what would fix it.
##
## Two different failures reach here and they want different words: a core that
## has never been vetted (offer a substitute) and a boot this peer cannot
## reproduce at all -- a BIOS-less machine, an unhashable ROM -- which no core
## swap helps.
func _report_netplay_blocked() -> void:
	var resolved_core := _resolve_core()
	var why := NetplayCores.why_not_capable(resolved_core)
	if why.is_empty():
		NetworkManager.netplay_blocked.emit(
			"this machine's boot media cannot be shared with other players",
			self, {})
		return
	var remedy: Dictionary = {}
	var substitute := NetplayCores.suggest_substitute(resolved_core, systemid)
	if not substitute.is_empty():
		remedy = {"kind": "swap_core", "core": substitute, "machine": self,
			"strategy": NetplayCores.listed_strategy(substitute)}
	NetworkManager.netplay_blocked.emit(why, self, remedy)


## Which core this machine would actually load. Public because the core manager
## has to ask before letting one be uninstalled, and `core_name` alone is not the
## answer: a machine left on its default has it empty and resolves it here.
func resolve_core_name() -> String:
	return _resolve_core()


func _resolve_core() -> String:
	# A console with something bolted to it is a different machine, and the
	# combination names its own core: a Mega Drive on a Mega-CD is not the core
	# either box would pick alone. Ahead of core_name, because the machine the
	# player has physically built beats a default chosen for the bare console --
	# and behind nothing, since a bare console never reaches this at all.
	var spec := expansion_boot()
	if not spec.is_empty() and not str(spec.get("core", "")).is_empty():
		return str(spec["core"])
	return _bare_core_default()


## What this console alone would resolve to, ignoring anything bolted to it:
## the player's own per-instance pick if set, else the manager's per-systemid
## default (CoreDefaults, set from the CORES panel). This is also what a stack
## whose console slot is empty falls back to, since expansion_boot() names no
## core for that case.
func _bare_core_default() -> String:
	var c := core_name
	if c.is_empty() and not systemid.is_empty():
		var defaults := CoreDefaults.new()
		defaults.setup(CoreDefaults.default_path())
		c = defaults.get_default_core(systemid)
	return c


func _resolve_dir() -> String:
	var dir := core_directory
	if dir.is_empty():
		dir = CoreDownloadManager.default_core_root()
	return dir


## MD5 of the inserted ROM (for netplay peer verification). Empty if none.
## Cached (mtime-keyed) so only the first hash of a given file touches disk.
func net_rom_md5() -> String:
	if rom_path.is_empty():
		return ""
	return NetFileTransfer.hash_of(rom_path)


## Why net_prepare_boot last refused, in words a player can act on. Read by the
## session so the specific cause survives instead of being flattened into one
## generic string on its way to the menu.
var net_boot_failure: String = ""


## Reproducible launch description for netplay. A BIOS-only core still has a
## full deterministic machine state; it simply has no copyrighted content to
## hash or transfer. Empty media is regenerated locally from its extension.
func net_boot_spec(core: String) -> Dictionary:
	var empty_extension := BiosBoot.empty_media_extension(core, systemid)
	var generated_empty := ""
	if not empty_extension.is_empty():
		generated_empty = CoreDownloadManager.default_core_root().path_join("temp") \
			.path_join("no_disc." + empty_extension)
	var has_real_media := not rom_path.is_empty() and rom_path != generated_empty
	if has_real_media:
		var md5 := net_rom_md5()
		if md5.is_empty():
			return {}
		var game_boot := {"mode": "rom", "rom_md5": md5}
		# sha1 and size are carried so a peer who does NOT have this ROM can ask
		# their own RomM for it -- /api/roms/by-hash prefers md5 but falls back to
		# sha1. Both come from the same cached pass, so this costs nothing after
		# the first time. The label is metadata for the "you are missing this"
		# row; the file itself is never sent.
		var sums := NetFileTransfer.checksums_of(rom_path)
		if not sums.is_empty():
			game_boot["rom_sha1"] = str(sums.get("sha1", ""))
			game_boot["rom_size"] = int(sums.get("size", 0))
		game_boot["rom_label"] = rom_path.get_file().get_basename()
		game_boot["systemid"] = systemid
		var splash := BiosBoot.splash_options(core, systemid)
		if not splash.is_empty():
			game_boot["boot_options"] = splash
		FirmwareDigest.stamp(game_boot, core)
		return game_boot
	if not BiosBoot.can_boot_empty(core, systemid):
		return {}
	var empty_boot := {
		"boot_options": BiosBoot.empty_boot_options(core, systemid),
	}
	FirmwareDigest.stamp(empty_boot, core)
	if BiosBoot.boots_with_no_content(core, systemid):
		empty_boot["mode"] = "no_content"
	else:
		empty_boot["mode"] = "empty_media"
		empty_boot["extension"] = empty_extension
	return empty_boot


## Recreate a host machine's launch mode locally before net_start_core. ROMs
## are only resolved by hash; BIOS files are never sent and must already be
## installed on this peer.
func net_prepare_boot(spec: Dictionary) -> bool:
	var core := str(spec.get("core", ""))
	net_boot_failure = ""
	if spec.has("firmware") \
			and str(spec.get("firmware", "")) != FirmwareDigest.signature(core):
		# Name the files. The caller used to collapse every media failure into
		# "cannot reproduce one machine's boot media", which does not even say
		# the word firmware, let alone which file to go and fix.
		var diff := NetplayReadiness.firmware_diff(
			spec.get("firmware_rows", {}) as Dictionary, FirmwareDigest.rows(core))
		net_boot_failure = FirmwareDigest.failure_text(core, diff)
		push_warning("[RetroSystem] netplay: %s" % net_boot_failure)
		return false
	match str(spec.get("mode", "rom")):
		"rom":
			_net_no_content_override = false
			return net_resolve_rom(str(spec.get("rom_md5", "")),
				int(spec.get("rom_size", 0)))
		"no_content":
			if not BiosBoot.can_boot_empty(core, systemid) \
					or not BiosBoot.boots_with_no_content(core, systemid):
				return false
			rom_path = ""
			_net_no_content_override = true
			return true
		"empty_media":
			var extension := str(spec.get("extension", ""))
			if not BiosBoot.can_boot_empty(core, systemid) \
					or BiosBoot.boots_with_no_content(core, systemid) \
					or extension != BiosBoot.empty_media_extension(core, systemid):
				return false
			rom_path = BiosBoot.empty_media_path(extension)
			_net_no_content_override = false
			return not rom_path.is_empty()
	return false


## Netplay cold start (client): make sure we own a byte-identical copy of the
## host's ROM. Checks the current rom_path first, then searches the local rom
## library by hash. ROMs are VERIFY-ONLY — never transferred (copyright; see
## file_transfer.gd). Returns false when no matching copy exists locally.
func net_resolve_rom(md5: String, size := 0) -> bool:
	if md5.is_empty():
		return false
	# Refresh from the seated cartridge — object_sync may have remapped it.
	if _snapped_cartridge and _snapped_cartridge.has_method("get_rom_path"):
		var cart_path: String = _snapped_cartridge.get_rom_path()
		if not cart_path.is_empty():
			rom_path = cart_path
	if not rom_path.is_empty() and FileAccess.file_exists(rom_path) \
			and NetFileTransfer.hash_of(rom_path) == md5:
		return true
	# Search THIS system's folder, not the whole library, and only files of the
	# right length. resolve_by_md5 hashes every candidate it cannot rule out, so
	# an unbounded search means reading every ROM the player owns to find one --
	# minutes of disk on a large library, at the moment someone pressed Join.
	# systemid narrows it to one console, `size` to the handful that could match.
	var dirs: Array = [RomLibrary.rom_dir_for_system(systemid)] if not systemid.is_empty() \
		else [RomLibrary.default_roms_root()]
	var found := NetFileTransfer.resolve_by_md5(md5, "rom", size, rom_path, dirs)
	if found.is_empty():
		net_boot_failure = "you do not have the game this machine is running"
		push_warning("[RetroSystem] netplay: no local ROM matches md5 %s… — not transferable" % md5.left(8))
		return false
	rom_path = found
	if _snapped_cartridge and "rom_path" in _snapped_cartridge:
		_snapped_cartridge.set("rom_path", found)
	print("[RetroSystem] netplay: rom matched by hash → %s" % found)
	return true


# ── Netplay core seam (driven by NetplaySession on every peer) ────────────────

## Start the local core under the netplay gate. The gate (SetNetplayMode) is set
## BEFORE StartContent so the core holds at `start_frame` until inputs post.
## Returns the Libretro node (the session connects its signals). null on failure.
func net_start_core(core: String, port_mask: int, start_frame: int, options: Dictionary) -> Libretro:
	var requested_no_content := _net_no_content_override
	_net_no_content_override = false
	if not _has_display():
		push_error("RetroSystem: netplay start — no display (connect a TV)")
		return null
	# The host names the core, and every peer runs THAT one. _resolve_core() is
	# this machine's own preference, which is a per-player, per-platform answer:
	# taking it here is how two peers end up on different emulators with no way
	# to tell from the symptom. Falling back to it only covers a caller with
	# nothing to say (an offline-style start).
	var resolved_core := core if not core.is_empty() else _resolve_core()
	if resolved_core.is_empty():
		push_error("RetroSystem: netplay start — no core for systemid '%s'" % systemid)
		return null
	var no_content := requested_no_content and rom_path.is_empty() \
		and BiosBoot.boots_with_no_content(resolved_core, systemid)
	if rom_path.is_empty() and not no_content:
		push_error("RetroSystem: netplay start — boot media was not prepared")
		return null
	if is_powered_on:
		_libretro.StopContent()
		_release_cache_protection()
		is_powered_on = false
	# SetCoreOption is a live-core command and is intentionally ignored before
	# StartContent. Netplay options must therefore go through the same persisted
	# store the core reads during startup, or every "forced" option here is a
	# no-op and peers can boot with different saved settings.
	if not options.is_empty() \
			and not CoreOptionsStore.merge_values(_resolve_dir(), resolved_core, options):
		push_error("RetroSystem: netplay start — could not pin deterministic core options")
		return null
	# SRAM: netplay override (session-injected identical bytes) or the normal
	# local composition when the session didn't set one (offline-like start).
	if not _memcards.apply_netplay_sram():
		_libretro.SetSramPath(sram_path_for_run(resolved_core))
	_apply_forced_core_options(_resolve_dir(), resolved_core)
	AppPrefs.apply_hw_render_for(resolved_core)
	_libretro.SetNetplayMode(true, port_mask, start_frame)
	_protect_active_rom()
	if no_content:
		ClassDB.class_call_static("Libretro", "SetNoContentPassesNull", true)
	_libretro.StartContent(_resolve_dir(), resolved_core, rom_path)
	if no_content:
		ClassDB.class_call_static("Libretro", "SetNoContentPassesNull", false)
	_after_core_started()
	net_remote_powered = false
	if connected_tv:
		connected_tv.hide_osd()   # real local output now, not the placeholder
	return _libretro


## Every machine on this one's link bus, ITSELF FIRST, or just itself when
## nothing is cabled to it.
##
## Netplay asks this because a link cable never crosses the network: the bus is
## a process-wide singleton joining two cores in one process, so a cabled pair
## is one session over two machines that every peer replicates, not two players'
## machines talking to each other.
##
## Self first because index 0 anchors the session — it owns the frame clock and
## the savestate. Only the host walks this; every other peer is told the answer,
## so the order has to be stable within one process rather than across them.
func net_link_group() -> Array:
	if not is_inside_tree():
		return [self]
	# A console may have one independent link cable per controller socket (four
	# GameCube-to-GBA leads are the common case).  No single cable's bus contains
	# the other handhelds, so collect every bus that contains this machine.
	return merge_link_buses(self, net_link_buses())


## Every distinct physical cable bus containing this machine. This is also the
## list netplay re-resolves after restarting cores, because StopContent drops
## LinkCoordinator ownership while the plugs themselves never moved.
func net_link_buses() -> Array:
	var buses: Array = []
	for cable: Object in _link_cables():
		var bus: Array = cable.linked_machines()
		if _bus_has_self(bus):
			buses.append(bus)
	return buses


func net_refresh_link_cables() -> void:
	for cable: Object in _link_cables():
		if _bus_has_self(cable.linked_machines()) and cable.has_method("rejoin"):
			# Why a rejoin and not a resolve is LinkCable.rejoin()'s to explain.
			cable.call("rejoin")


## Flatten every cable bus reachable from `anchor`.  Kept pure so the rule can
## be tested without constructing sockets and cables: one console with several
## independent controller-port leads still needs every far machine in its
## replicated netplay group.
static func merge_link_buses(anchor: Object, buses: Array) -> Array:
	var machines: Array = [anchor]
	var changed := true
	while changed:
		changed = false
		for bus: Array in buses:
			var touches := false
			for entry: Dictionary in bus:
				if machines.has(entry.get("machine")):
					touches = true
					break
			if not touches:
				continue
			for entry: Dictionary in bus:
				var machine: Object = entry.get("machine")
				if machine != null and not machines.has(machine):
					machines.append(machine)
					changed = true
	return machines


## The bus this machine is on, as [{machine, port}], or [] when it is on none.
##
## Asked of every LEAD in the room rather than walked out of this machine's own
## sockets, because the three kinds of link cable do not attach the same way and
## two of them cannot be found from here at all. A handheld lead and a
## PlayStation null modem both sit in LinkPorts, but a GameCube-to-GBA lead puts
## its wide end in a CONTROLLER socket — there is no LinkPort on the console
## side to walk out of, and a search from this machine would silently decide a
## cabled GameCube was on no bus.
func net_link_bus() -> Array:
	for cable: Object in _link_cables():
		var bus: Array = cable.linked_machines()
		if _bus_has_self(bus):
			return bus
	return []


## Every distinct link cable in the room, in group order.
##
## Swept from the LEADS rather than from this machine's sockets, for the reason
## net_link_bus() gives above — and it is the pair of GROUPS that is easy to get
## wrong, which is why three methods asking the same question now ask it once. A
## sweep that forgot controller_plug would decide a cabled GameCube was on no
## bus at all, silently, while going on working for the two leads that do sit in
## a LinkPort.
##
## Empty off the tree. A machine can be stopped as its room is torn down, when
## get_tree() is already null — power-off reaches here, not only netplay.
func _link_cables() -> Array:
	var cables: Array = []
	if not is_inside_tree():
		return cables
	var seen := {}
	for plug in get_tree().get_nodes_in_group("link_plug") \
			+ get_tree().get_nodes_in_group("controller_plug"):
		var cable: Object = plug.get("cable")
		if cable == null or not is_instance_valid(cable) or seen.has(cable) \
				or not cable.has_method("linked_machines"):
			continue
		seen[cable] = true
		cables.append(cable)
	return cables


## True when a linked_machines() list includes this machine.
func _bus_has_self(bus: Array) -> bool:
	for entry: Dictionary in bus:
		if entry.get("machine") == self:
			return true
	return false


## Stop the local netplay core and clear the gate.
func net_stop_core() -> void:
	_libretro.SetNetplayMode(false, 1, 0)
	_net_no_content_override = false
	_memcards.clear_netplay_sram()
	if is_powered_on:
		_stop_core()
	else:
		# Nothing was running, but a session may still have pinned the ROM in the
		# cache on its way to a start that never happened.
		_release_cache_protection()


## True on clients while the host runs this system's emulation.
var net_remote_powered := false

## Client-side mirror of the host's power state (pre-netplay placeholder).
func net_set_remote_power(on: bool) -> void:
	net_remote_powered = on
	if connected_tv:
		if on:
			connected_tv.show_osd("LIVE ON HOST")
		else:
			connected_tv.hide_osd()


## Front-panel reset: the machine restarts, the core stays loaded. Does not
## change button state, labels, or fire power model hooks.
##
## retro_reset, not a stop/start of the core: a restart has to join the
## emulation thread, and a core that owns internal threads of its own (Dolphin)
## does not unwind on demand, so the join never returns and the app hangs with
## every thread parked. Nothing is torn down here, so the screen, the audio
## voices and the port bindings all survive and there is nothing to rebind.
func reset() -> void:
	if NetworkManager.is_active() and not NetworkManager.is_event_applying():
		if NetworkManager.netplay_running() and NetworkManager.netplay_covers(self):
			if NetworkManager.is_client():
				NetworkManager.report_event(NetEvents.Event.EV_SYS_RESET, {"sys": self})
			elif not NetworkManager.netplay_pending_joins().is_empty():
				# Somebody is stood there holding a pad this session cannot give
				# them. A scheduled retro_reset would not admit them: it keeps the
				# session, and with it the ownership decided when it started. So
				# RESET means something stronger while a claim is waiting -- start
				# the game again with everybody in it, which is the only way in
				# for a core that cannot hand over a savestate.
				NetworkManager.netplay_rejoin_restart(self)
			else:
				NetworkManager.netplay_schedule_reset(self)
			return
		# Before lockstep starts, clients hold only a visual replica; reset the
		# host's running core instead of returning because this copy is powered off.
		if NetworkManager.is_client():
			NetworkManager.report_event(NetEvents.Event.EV_SYS_RESET, {"sys": self})
			return
	if not is_powered_on:
		return
	_model.play_reset()
	# Re-assert the drive first. A machine coming back up should boot whatever is
	# physically in its bay, and the core's tray is a mirror that can be left
	# behind — a lid cycle the core did not hear about leaves it believing the
	# tray is open, and then every reset lands in the BIOS menu until the machine
	# is switched off and on again.
	_sync_core_tray()
	print("[RetroSystem] Resetting: rom=%s" % rom_path)
	_libretro.RequestReset()


## Visual half of a frame-scheduled netplay reset. The core half is armed on
## every peer by NetplaySession and executes at the agreed emulated frame.
func net_play_reset() -> void:
	if is_powered_on and _model != null:
		_model.play_reset()


## Everything pinned for a run: what the shell demands, plus what this system
## composes per run. One place, so the .opt seam and the options panel can never
## disagree about which keys the player is allowed to move.
## What this machine's memory cards pin, asked of the machine rather than of
## ForcedCoreOptions directly — the card state is the machine's to report, and
## system_tests checks it that way.
func _removable_media_options(core: String) -> Dictionary:
	return ForcedCoreOptions.removable_media(core, card_family(),
		get_snapped_memcard(0) != null)


func _all_forced_options(core: String) -> Dictionary:
	var out: Dictionary = _model.get_forced_core_options() if _model != null else {}
	out.merge(ForcedCoreOptions.all(core, systemid, rom_path, expansion_ids(),
		card_family(), get_snapped_memcard(0) != null, _expansion_launch.host_media_path()), true)
	return out


## The 64DD is a drive bolted under an N64, and parallel_n64 models it behind an
## option: with parallel-n64-64dd-hardware disabled there is no drive and a disk
## has nothing to load into. So this machine pins it on, the way the Virtual Boy
## pins its stereo split -- it is what makes the hardware that hardware, not a
## preference.
##
## Keyed on the systemid as well as the core, and deliberately not added to
## CoreOptionsStore.HARDWARE_PINNED: that table is per key, and the same core
## runs the plain nintendo_64, where the drive really is the player's choice.
# ── expansions ────────────────────────────────────────────────────────────────
#
# A console and the unit bolted to it are two separate physical objects that
# together behave as one machine. Which one wears the socket depends on which
# way the pair stacks -- a 64DD is a base the N64 stands on, a 32X sits on top
# of a Mega Drive -- and ExpansionCatalog is the only thing that knows. The
# console side is deliberately thin: it keeps the list, answers what the stack
# is, and hands the launch path one path to boot from.


## Everything currently bolted to this console. Order is the catalog's, not the
## order they were attached in, so a stack reads the same however it was built.
var _expansions: Array[RetroExpansion] = []


## Option values this machine displaced in the shared <core>.opt, and the core
## the file belongs to, so power_off can put them back.
##
## The forced-options file is per CORE, not per machine, so a pin set for a 64DD
## outlives the run and reaches every other console using that core: one
## cartridge-less boot would leave every plain Nintendo 64 on a renderer its
## owner never chose. Pins that describe the HARDWARE -- a drive that is
## physically bolted on -- are re-pinned every launch and are fine to leave; this
## is for the ones that describe a WORKAROUND.
var _displaced_options: Dictionary = {}
var _displaced_core := ""


## The socket on top and the foot underneath, built from the model's own box.
##
## Only what the catalog says this console has: a machine nothing mounts above
## must NOT grow a socket, because an empty one still lights a snap ghost and
## offers a join that does not exist.
## Where this machine's roof is relative to its own cartridge slot, in metres.
##
## Signed, and in practice NEGATIVE: the slot is placed a few millimetres proud
## of the shell so a cartridge stands out of it, which is measured as -5 mm on
## both the Mega Drive and the Jaguar. That is exactly why seating a unit by its
## origin half-sank it into the console instead of swallowing it whole, and it is
## why this is measured rather than assumed to be positive.
##
## A unit that mounts AS a cartridge -- a 32X, a Jaguar CD -- stands ON the
## console with only its connector inside, so it has to know where the top face
## is relative to the slot that connector goes into. Only the console can answer
## that: the slot is placed by the model and the roof is measured off the model's
## meshes, and the two differ by a different amount on every shell. Derived from
## the CARTRIDGE's height instead -- 35 mm on a Mega Drive -- both units hung in
## the air well above the consoles they were supposed to be sitting on.
##
## Cached once the model has meshes to measure. Answers 0.0 until then, which
## seats a unit ON the slot -- wrong, but only for the frames before a model
## finishes loading, and never cached.
func roof_above_cartridge_slot() -> float:
	if not is_nan(_roof_over_slot):
		return _roof_over_slot
	if _cartridge_slot == null:
		return 0.0
	var aabb := _body_aabb()
	if aabb.size.x <= 0.0:
		return 0.0
	_roof_over_slot = aabb.end.y - _cartridge_slot.position.y
	return _roof_over_slot


func _build_expansion_hardware() -> void:
	if systemid.is_empty():
		return
	var aabb := _body_aabb()
	if aabb.size.x <= 0.0:
		return          # no meshes yet; nothing to measure against
	var span := Vector2(aabb.size.x, aabb.size.z)

	if ExpansionCatalog.host_takes_top_unit(systemid) \
			and get_node_or_null("ExpansionSocket") == null:
		var socket := ExpansionPort.build_socket(self, aabb.end.y, span,
			ExpansionPort.GROUP_EXPANSION, _accepts_expansion)
		socket.has_picked_up.connect(_on_expansion_seated)
		socket.has_dropped.connect(_on_expansion_lifted)
		# Roof-top-centred is only right for a unit that genuinely stacks
		# externally — nothing ships yet. The N64's Expansion Pak/Jumper Pak
		# port is inside the body, so its model relocates the socket behind a
		# cover; every other model's override is a no-op and leaves it here.
		_model.configure_expansion_socket(socket)
		if not _restoring_from_save:
			# Pak first, then the cover over it — the order the factory used.
			_seed_default_occupant(socket)
			_seed_expansion_cover()

	if ExpansionCatalog.host_stands_on_unit(systemid) \
			and get_node_or_null("ExpansionFoot") == null:
		# Registered by hand: XRToolsPickable collects grab points in its own
		# _ready, which ran long before the model was measured.
		_grab_points.push_back(ExpansionPort.build_foot(self, aabb.position.y, span))


## Seats the console's default-occupant expansion (a Jumper Pak) the moment a
## FRESH socket is built for it -- never on a restore, which is why the caller
## already checked _restoring_from_save. A restored console's own
## "expansions" list (scene_persistence -> restore_expansion) is the whole
## truth about what is bolted on there, whether that is this same unit, a real
## Expansion Pak the player installed, or nothing; seeding on top of that would
## leave a second Jumper Pak with nowhere to go, since the socket holds one
## object and the save's own restore_expansion call would simply evict this one
## un-tracked.
func _seed_default_occupant(socket: XRToolsSnapZone) -> void:
	var default_id := ExpansionCatalog.default_occupant_for(systemid)
	if default_id.is_empty():
		return
	var unit := EXPANSION_SCENE.instantiate() as RetroExpansion
	unit.expansion_id = default_id
	get_tree().current_scene.add_child(unit)
	unit.add_to_group("spawned")
	unit.global_position = global_position
	socket.pick_up_object(unit)


## Puts the lid on a fresh console's expansion bay, for a model that has one.
## Same restore rule as the pak underneath it: never on a restore, where the
## save's own record — lid on the console, or lid left on a table across the
## room — is the whole truth. A player who lost theirs stays without one.
func _seed_expansion_cover() -> void:
	var zone := _model.expansion_cover_slot() if _model != null else null
	if zone == null or zone.has_snapped_object():
		return
	var cover := EXPANSION_COVER_SCENE.instantiate() as ExpansionCover
	get_tree().current_scene.add_child(cover)
	cover.add_to_group("spawned")
	cover.global_position = global_position
	zone.pick_up_object(cover)


## The lid seated on this console's expansion bay, or null when it is off —
## what a save records. Null on every console whose model has no such bay.
func get_expansion_cover() -> Node3D:
	var zone := _model.expansion_cover_slot() if _model != null else null
	if zone == null:
		return null
	return zone.picked_up_object as Node3D


## Put a saved lid back on. The counterpart of get_expansion_cover, called from
## the restore's second pass the way restore_memory_card is.
func restore_expansion_cover(cover: Node3D) -> void:
	var zone := _model.expansion_cover_slot() if _model != null else null
	if zone != null and cover != null:
		zone.pick_up_object(cover)


## Roof-socket gate: is this a unit that mounts on THIS console?
func _accepts_expansion(obj: Node3D) -> bool:
	var unit := obj as RetroExpansion
	if unit == null:
		return false
	return ExpansionCatalog.host_of(unit.expansion_id) == systemid \
		and ExpansionCatalog.mount_of(unit.expansion_id) == ExpansionCatalog.MOUNT_ABOVE


func _on_expansion_seated(obj: Node3D) -> void:
	var unit := obj as RetroExpansion
	if unit != null:
		unit.bind_to_host(self)


func _on_expansion_lifted() -> void:
	# The zone says it is empty, not what left it, so unbind whatever we hold
	# that a socket is no longer holding.
	for unit in _expansions.duplicate():
		if is_instance_valid(unit) and ExpansionCatalog.mount_of(unit.expansion_id) == ExpansionCatalog.MOUNT_ABOVE:
			unit.unbind_from_host()


## Called from the unit's side of the join, whichever side owns the socket.
func attach_expansion(unit: RetroExpansion) -> void:
	if unit == null or _expansions.has(unit):
		return
	_expansions.append(unit)
	if not unit.card_swiped.is_connected(_on_expansion_card_swiped):
		unit.card_swiped.connect(_on_expansion_card_swiped)
	_update_name_label()


func detach_expansion(unit: RetroExpansion) -> void:
	if unit == null or not _expansions.has(unit):
		return
	if unit.card_swiped.is_connected(_on_expansion_card_swiped):
		unit.card_swiped.disconnect(_on_expansion_card_swiped)
	_expansions.erase(unit)
	_update_name_label()


## A dotcode card was slid through an expansion's groove.
##
## The card reaches the core as removable media: eject, replace, insert, and the
## INSERT edge is what queues the dotcode. Always image 0 — the swipe has already
## decided which strip, so there is nothing for an index to choose between, and
## the frontend has no add_image_index bound. The core's per-strip image list is
## for a frontend driving this from a disk menu instead.
func _on_expansion_card_swiped(card: Node3D, edge: String, strip: int) -> void:
	if strip < 0:
		# Two different refusals, and one message for both left a player with no
		# way to tell them apart: a card presented on an uncoded edge needs
		# TURNING, a card presented face-down needs FLIPPING, and doing the second
		# when you needed the first reads nothing either way.
		var data: Dictionary = card.get_card_data() if card.has_method("get_card_data") else {}
		if EReaderCards.coded_edges(data).has(edge):
			print("[RetroSystem] card presented %s face-down: a dotcode is printed on one side only" % edge)
		else:
			print("[RetroSystem] card presented %s: no dotcode on that edge; this card is coded on %s"
				% [edge, ", ".join(EReaderCards.coded_edges(data))])
		return
	var path := _swiped_strip_path(card, strip)
	if path.is_empty():
		push_warning("[RetroSystem] swiped card supplied no path for strip %d" % strip)
		return
	# mGBA does not serialize the e-Reader's card queue, scan position or dot
	# buffer, so a rollback replaying across a swipe and a late join mid-card both
	# diverge. Landing the op on one agreed frame is not enough on its own.
	if NetworkManager.netplay_running() and NetworkManager.netplay_covers(self):
		print("[RetroSystem] card refused: e-Reader state is not transferable in a session")
		var toast := _machine_toast()
		if toast != null:
			toast.show_notice(_display_name(), "Card not scanned",
				"e-Reader cards cannot be scanned during netplay.",
				AchievementToast.ACCENT_NOTICE)
		return
	if not _supports_disk_control():
		push_warning("[RetroSystem] core takes no removable media; card ignored")
		return
	print("[RetroSystem] card swiped: %s strip %d -> %s" % [edge, strip, path.get_file()])
	_libretro.SetDiskEjectState(true)
	_libretro.ReplaceDiskImage(0, path)
	_libretro.SetDiskEjectState(false)
	_libretro.RequestDiskInfo()


## The file behind the strip a swipe selected, off the card itself.
func _swiped_strip_path(card: Node3D, strip: int) -> String:
	if card == null or not card.has_method("get_card_data"):
		return ""
	var data: Variant = card.call("get_card_data")
	if typeof(data) != TYPE_DICTIONARY:
		return ""
	var strips: Array = (data as Dictionary).get("strips", [])
	if strip < 0 or strip >= strips.size():
		return ""
	return str((strips[strip] as Dictionary).get("path", ""))


## A disk going into or out of an expansion's own bay. The machine's boot media
## can change without anything touching the console's cartridge slot.
func on_expansion_media_changed(_unit: RetroExpansion) -> void:
	_update_name_label()


## Bolt `unit` on from the console's side. Used by the save restore and by a
## MOUNT_ABOVE join, where it is the console that owns the socket.
func restore_expansion(unit: RetroExpansion) -> void:
	if unit == null:
		return
	# Whichever machine owns the socket is the one that has to do the taking: a
	# unit that stands on this console goes into OUR socket, a unit this console
	# stands on takes the console into ITS socket. Only the second half was here,
	# so bolting a 64DD or a Mega-CD bound the two logically and seated neither --
	# and an unfrozen console with nothing holding it simply fell through the join.
	var mount := ExpansionCatalog.mount_of(unit.expansion_id)

	if mount == ExpansionCatalog.MOUNT_CARTRIDGE:
		# It goes where a game would go, and fills the slot the way it does on
		# the hardware.
		if _cartridge_slot != null and _accepts_media(unit):
			_cartridge_slot.pick_up_object(unit)
			return
	elif mount == ExpansionCatalog.MOUNT_ABOVE:
		var socket := get_node_or_null("ExpansionSocket") as XRToolsSnapZone
		if socket != null and _accepts_expansion(unit):
			socket.pick_up_object(unit)
			return
	else:
		var base := unit.get_socket()
		if base != null:
			base.pick_up_object(self)
			return
	# No socket on either side -- a combination the catalog does not describe, or
	# a machine whose body was never measured. Bind it logically so the stack is
	# at least reported correctly, rather than silently doing nothing.
	push_warning("[RetroSystem] %s and %s have no socket between them; bound without a physical join"
		% [systemid, unit.expansion_id])
	unit.bind_to_host(self)


## The ids bolted to this console, in catalog order.
func expansion_ids() -> Array[String]:
	var ids: Array[String] = []
	for unit in _expansions:
		if is_instance_valid(unit) and not unit.expansion_id.is_empty():
			ids.append(unit.expansion_id)
	return ExpansionCatalog.sorted_ids(ids)


## The units themselves, for whoever needs the objects rather than the names.
func get_expansions() -> Array[RetroExpansion]:
	var out: Array[RetroExpansion] = []
	for unit in _expansions:
		if is_instance_valid(unit):
			out.append(unit)
	return out


# ── Expansion launch ──────────────────────────────────────────────────────────
# The launch half of the expansion subject lives in ExpansionLaunch now. The
# hardware half — sockets, cover, seating, card swipes — stays here, because it
# parents nodes to this console and reads its transform. Only expansion_boot is
# called from outside, so only it keeps a forward.

func expansion_boot() -> Dictionary:
	return _expansion_launch.expansion_boot()


## Public because ExpansionLaunch and expansion_tests both call it; it was
## private when its only caller was in this file.
func slot_b_save_path(core: String) -> String:
	if core.is_empty():
		return ""
	for unit in get_expansions():
		if unit.get_bay_count() < 2:
			continue
		var m := unit.get_media(1)
		if m == null or not ("save_id" in m):
			continue
		var save_id := str(m.get("save_id"))
		if save_id.is_empty():
			continue
		return SramPaths.cart_save_path(core, rom_path, save_id)
	return ""


## Merge every REQUIRED core option into <dir>/core_options/<core>.opt before
## StartContent — the C++ OptionsHandler reads that file when the core boots.
## (SetCoreOption needs a running core, so pre-start forcing goes through the
## file; user-set values for other keys are preserved.)
##
## Not gated on there being a shell model: the BIOS-boot pins come from the core
## and the systemid, and a machine with no model still boots one.
func _apply_forced_core_options(dir: String, core: String) -> void:
	var forced := _all_forced_options(core)
	if forced.is_empty():
		return
	# Through the store, which owns this file: set_core_option already writes it
	# that way, and two writers with their own idea of the format is how the same
	# file came out in a different order depending on which one touched it last.
	# Remember what the renderer pin displaces. It is the only forced option here
	# that is a workaround rather than a description of the hardware, so it is the
	# only one that has to be handed back.
	_displaced_options.clear()
	_displaced_core = core
	if forced.has("mupen64plus-rdp-plugin"):
		var saved := CoreOptionsStore.load_values(dir, core)
		if saved.has("mupen64plus-rdp-plugin"):
			_displaced_options["mupen64plus-rdp-plugin"] = saved["mupen64plus-rdp-plugin"]

	if CoreOptionsStore.merge_values(dir, core, forced):
		print("[RetroSystem] forced core options applied: %s -> %s"
			% [str(forced), CoreOptionsStore.opt_path(dir, core)])


# --- Core options ---

## The run never started. Until this signal existed a refused load raised
## nothing at all, so the machine reported is_powered_on = true and sat dark —
## indistinguishable from a broken core, a missing BIOS or a dead TV.
##
## Powers back off rather than leaving the button saying STOP on a machine with
## no core behind it, and says why on the hardware, where the player is.
func _on_content_load_failed(reason: String) -> void:
	push_error("RetroSystem: content load failed — %s" % reason)
	if is_powered_on:
		_stop_core()
	var toast := _machine_toast()
	if toast != null:
		toast.show_notice(_display_name(), "Could not start", reason,
			AchievementToast.ACCENT_NOTICE)


## Fired by the Libretro node (via options_ready signal) once the emulation core
## has registered its option set. Caches the data and refreshes the panel if it
## is already open so live changes (e.g. second options_ready after reset) appear.
func _on_options_ready(_categories: Dictionary, definitions: Dictionary, current_values: Dictionary) -> void:
	print("[RetroSystem] options_ready — %d definitions received" % definitions.size())
	_options_definitions = definitions
	_options_values = current_values
	_options_unavailable = ""
	# Controller info is set during retro_load_game, so it's ready by the time
	# options_ready fires. Fetch it here so the panel can show both tabs.
	_controller_info = _libretro.GetControllerInfo()
	print("[RetroSystem] controller info fetched — %d ports" % _controller_info.size())
	# A controller can be plugged before the core (and its options) exist. Now that
	# there is a core: tell it what is on each port, then apply each pad's
	# preferred type. Devices first — the pad-type option is per-port and means
	# nothing until the port has a device on it.
	_reannounce_port_devices()
	reapply_pad_types()
	if _options_panel.visible:
		_options_panel.refresh()


## Toggle the core options panel open or closed.
## Called by SpawnMenuController when the user points at this system and presses
## the left thumbstick (primary_click action).
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel.visible:
		print("[RetroSystem] closing options panel")
		_options_panel.hide_panel()
		return
	print("[RetroSystem] opening options panel")
	# Powered off there is no core to ask, so read what the system's DEFAULT core
	# declares. It writes to the same file the core loads at start, so a change
	# made now is what the next launch runs with.
	if not is_powered_on:
		_load_prelaunch_options()
	_options_panel.show_for(self, camera)


## Fill the option cache from the default core's own declarations without starting
## it. Some cores publish nothing until content is loaded; for those the cache
## stays empty and the panel explains why instead of showing an empty list.
func _load_prelaunch_options() -> void:
	var core := _resolve_core()
	var dir := _resolve_dir()
	var peeked := CoreOptionsStore.peek(dir, core)
	if peeked.is_empty():
		_options_definitions = {}
		_options_values = {}
		_options_unavailable = CoreOptionsStore.peek_failure_reason(dir, core)
		print("[RetroSystem] pre-launch options unavailable for '%s'" % core)
		return
	_options_unavailable = ""
	_options_definitions = peeked["definitions"]
	_options_values = CoreOptionsStore.effective_values(
		peeked, CoreOptionsStore.load_values(dir, core))
	print("[RetroSystem] pre-launch options for '%s' — %d definitions"
		% [core, _options_definitions.size()])


## Apply a single core option change. A running core is told directly; a powered
## off one is edited through its option file, which it reads at start.
func set_core_option(key: String, value: String) -> void:
	print("[RetroSystem] set_core_option '%s' = '%s'" % [key, value])
	_options_values[key] = value
	if is_powered_on:
		_libretro.SetCoreOption(key, value)
	else:
		CoreOptionsStore.set_value(_resolve_dir(), _resolve_core(), key, value)


## Options this system pins so the hardware works at all — the 3DS's
## side-by-side framebuffer, the Virtual Boy's stereo split, and which memory
## card slots the PlayStation has, which the physical cards decide rather than a
## menu. They are locked in the UI and skipped by a reset, which would otherwise
## break the screen (or silently detach a seated card) rather than restore it.
func forced_core_options() -> Dictionary:
	return _all_forced_options(_resolve_core())


## Put every non-forced option back to the value the core itself declares as its
## default.
func reset_core_options() -> void:
	if _options_definitions.is_empty():
		return
	var forced := forced_core_options()
	var changed := 0
	for key: String in _options_definitions:
		if forced.has(key):
			continue
		var defn: Object = _options_definitions[key]
		var default_val: String = defn.GetDefaultValue()
		if default_val.is_empty() or String(_options_values.get(key, "")) == default_val:
			continue
		set_core_option(key, default_val)
		changed += 1
	print("[RetroSystem] reset %d core options (%d forced kept)" % [changed, forced.size()])


## Switch the input device type on a given controller port.
## device_id corresponds to RETRO_DEVICE_* constants (1 = joypad, 5 = analog, etc.).
func set_controller_port_device(port: int, device_id: int) -> void:
	print("[RetroSystem] set_controller_port_device port=%d device=%d" % [port, device_id])
	# Update the cached current_id so reopening the panel shows the right selection
	for entry in _controller_info:
		if entry["port"] == port:
			entry["current_id"] = device_id
			break
	# Guard: a controller can be plugged in before the core is started (or in a
	# headless probe where the GDExtension isn't loaded). The device selection is
	# re-applied at core start, so skipping here is safe.
	if is_instance_valid(_libretro) and _libretro.has_method("SetControllerPortDevice"):
		_libretro.SetControllerPortDevice(port, device_id)


## Auto-select the running core's per-port "pad type" option to match the pad
## just plugged in: a DualShock (pad_type_pref "dualshock") switches the port to
## the analog/DualShock profile, the original digital pad selects "standard".
## Gated on the option actually existing (PCSX-ReARMed's pcsx_rearmed_padNtype),
## so it is a no-op on every core that has no such option.
func _apply_pad_type_option(lib_port: int, ctrl: Node) -> void:
	if not is_instance_valid(ctrl) or not ("pad_type_pref" in ctrl):
		return
	var key := _pad_type_option_key(lib_port)
	if key.is_empty():
		return
	var desired: String = ctrl.get("pad_type_pref")
	var allowed := _pad_type_values(key)
	var current := String(_options_values.get(key, ""))
	var target := _decide_pad_type(allowed, desired, current)
	if target.is_empty():
		return
	print("[RetroSystem] auto pad-type: port %d -> %s = '%s'" % [lib_port, key, target])
	set_core_option(key, target)


## Pure pad-type decision: given the option's allowed values, the pad's preferred
## value and the current value, return the value to set, or "" for no change.
## A DualShock on a core that offers only a plain analog pad falls back to it.
static func _decide_pad_type(allowed: Array, desired: String, current: String) -> String:
	if allowed.is_empty():
		return ""
	var pick := desired
	if not (pick in allowed):
		if desired == "dualshock" and "analog" in allowed:
			pick = "analog"
		else:
			return ""
	return "" if pick == current else pick


## Tell the core which device is on each occupied port, now that there is a core
## to tell. set_controller_port_device is a no-op while the machine is off, and
## everything that claims a port — a plug seating, a remote pairing, a save being
## restored — can happen long before that.
##
## A plain joypad survived the gap by luck: libretro already defaults its ports to
## JOYPAD, so a pad plugged in beforehand worked anyway. A Wii Remote does not.
## The core zeroes every port during its own startup, so the remote was paired as
## far as this room was concerned, showing its player light, and simply absent in
## the game — no buttons, no pointer.
func _reannounce_port_devices() -> void:
	for i in range(_port_controllers.size()):
		var ctrl: Node = _port_controllers[i]
		if not is_instance_valid(ctrl):
			continue
		var dev: int = ctrl.get("device_type") if "device_type" in ctrl else 1
		if not _claims_port_device(dev):
			continue
		# _port_plugs is what says WIRED: a cabinet socket records its plug, and a
		# wireless remote or a multitap sub-port has none. Only the wired ones take
		# the GameCube-on-Wii translation.
		var announce := dev
		if _wii_link != null and _port_plugs[i] != null:
			announce = _wii_link.cabinet_device_id(dev)
		var lib_port := _libretro_port_for(dev, i)
		set_controller_port_device(lib_port, core_device_id(announce, lib_port))


## Say what is on each port a SECOND time, once the core has actually run a frame.
##
## _reannounce_port_devices at options_ready is enough for anything announced
## while a core was already running: Wrapper queues that as an emulation-thread
## command and it lands between frames. A device announced while the machine was
## OFF does not take that path. It goes into Wrapper's pending map and is applied
## right after retro_load_game — which is canonical, and is also before the first
## retro_run.
##
## That is too early for a core which decides anything on its first pass. Dolphin
## turns its sensors on in InitSensors(), at the top of frame 0, and binds a Wii
## Remote's accelerometer and gyroscope INSIDE retro_set_controller_port_device
## only if that has already happened. So a remote paired before the console was
## switched on — which is the ordinary way round, you press SYNC and then you
## press POWER — got no motion at all for the whole session, and nothing rebound
## it short of pulling the Nunchuk out and putting it back.
##
## Measured with Tools/prestart_probe: "Applying pre-start port device: port=0
## device=769" prints before every "Sensor: accelerometer enabled" line, and both
## come from the emulation thread, so that order is real rather than two threads
## interleaving in the log.
##
## One completed frame is the whole condition — retro_run has returned, so
## whatever the core sets up on its first pass is up. Deliberately not a frame
## COUNT: see SystemAudio.ensure_bound, where elapsed frames stood in for a readiness
## question and the two only agreed for cores that come up fast.
func _ensure_port_devices_bound() -> void:
	if _port_devices_settled or not is_powered_on:
		return
	if not is_instance_valid(_libretro) or _libretro.GetFrameCount() <= 0:
		return
	_port_devices_settled = true
	_reannounce_port_devices()


## Re-apply every plugged pad's preferred pad type. Called when the option set
## first becomes known (options_ready), covering pads plugged before core start.
## Re-apply every port's pad-type option. Public because a pad can change its own
## mode while it stays plugged in: a DualShock toggled out of analogue mode is the
## same controller reporting a different pad_type_pref, and the core option has to
## follow it without the cable being pulled and pushed back.
func reapply_pad_types() -> void:
	for i in range(_port_controllers.size()):
		var ctrl: Node = _port_controllers[i]
		if not is_instance_valid(ctrl):
			continue
		var dev: int = ctrl.get("device_type") if "device_type" in ctrl else 1
		_apply_pad_type_option(_libretro_port_for(dev, i), ctrl)


## The core option key that controls the pad type on a given libretro port, or
## "" if the running core has none. PCSX-ReARMed exposes pcsx_rearmed_pad1type …
## pad8type (1-based); extend here to cover another core if needed.
func _pad_type_option_key(lib_port: int) -> String:
	var key := "pcsx_rearmed_pad%dtype" % (lib_port + 1)
	return key if _options_definitions.has(key) else ""


## The list of allowed values for a pad-type option key (empty if unknown).
func _pad_type_values(key: String) -> Array:
	var def: Object = _options_definitions.get(key)
	if def == null:
		return []
	var out: Array = []
	for v in def.GetValues():
		out.append(v.GetValue())
	return out


## True when this system is a home computer (ScummVM, DOS, Amiga…) whose core
## reads the mouse on port 0 and takes keyboard input globally.
func _is_computer() -> bool:
	var info := SystemInfo.for_system(systemid)
	return info != null and info.computer


## The libretro port a plugged peripheral should drive. On computer systems the
## mouse always drives port 0 — where ScummVM/DOS/Amiga cores poll it — no matter
## which cabinet slot it's in; every other device drives its own physical port.
##
## A joypad on a computer is pinned the same way, and for the same reason. Its
## socket is the tower's game port, which is cabinet slot 3 because slots 1 and 2
## are the keyboard and mouse — but a DOS or Amiga core reads its one joystick on
## port 0, and a pad announced on port 2 is a pad the game never sees.
func _libretro_port_for(device_type: int, physical_port: int) -> int:
	if device_type == RETRO_DEVICE_MOUSE and _is_computer():
		return 0
	# The GAME PORT only, not every joypad socket on a computer: a machine with two
	# joystick ports still drives port 1 from its second one.
	if device_type == RETRO_DEVICE_JOYPAD and _is_computer():
		if _model != null and _model.game_port_index() == physical_port:
			return 0
	return physical_port


## The id the RUNNING core understands for a peripheral, given the generic type
## the peripheral carries. Only the light gun needs translating, and it needs it
## badly: a core names its own device ids, and a gun is rarely plain
## RETRO_DEVICE_LIGHTGUN — fceumm's Zapper is 258, a MOUSE subclass. An id a core
## does not recognise does not leave the port alone either; fceumm's switch falls
## through to a gamepad, which un-plugs the gun the game had auto-detected.
##
## The core's own declared list is the source, so this needs no per-core table:
## prefer an entry whose base type IS a light gun, else one whose name reads as a
## gun, else announce what we were given.
##
## Public because the suites assert against it directly: an underscore promises
## the name may change freely, and a test that names it is a caller that cannot.
func core_device_id(device_type: int, lib_port: int) -> int:
	if device_type != RETRO_DEVICE_LIGHTGUN:
		return device_type
	var by_name := -1
	for entry: Dictionary in _controller_info:
		if int(entry.get("port", -1)) != lib_port:
			continue
		for dev: Dictionary in entry.get("controllers", []):
			var id := int(dev.get("id", 0))
			if (id & RETRO_DEVICE_MASK) == RETRO_DEVICE_LIGHTGUN:
				return id
			if by_name < 0 and reads_as_lightgun(String(dev.get("name", ""))):
				by_name = id
	return by_name if by_name >= 0 else device_type


## Whether a core's device NAME reads as a light gun, for the cores that
## describe one without using the light-gun base type.
##
## Public because the suites assert against it directly: an underscore promises
## the name may change freely, and a test that names it is a caller that cannot.
static func reads_as_lightgun(device_name: String) -> bool:
	var lower := device_name.to_lower()
	for word: String in _LIGHTGUN_WORDS:
		if lower.contains(word):
			return true
	return false


## Whether a plugged peripheral occupies a numbered libretro port device. A
## computer keyboard does not: its keys are global to port 0 regardless, so it
## leaves the port free for the mouse and avoids cores that mishandle a
## RETRO_DEVICE_KEYBOARD "controller" set on a numbered port.
func _claims_port_device(device_type: int) -> bool:
	return not (device_type == RETRO_DEVICE_KEYBOARD and _is_computer())


## Attach the wireless-pad component and reveal its button, on the consoles that
## have one. Everything the Wii does differently — pairing, the slot arithmetic
## it shares with wired pads, the GameCube-vs-Wii device ids — lives in WiiLink,
## the same way a handheld's input pipeline lives in HandheldInput. Every other
## console leaves `_wii_link` null and reads none of it.
func _setup_wireless_pads() -> void:
	var wants := WiiLink.handles(systemid)
	_sync_button.set_active(wants)
	if not wants or _wii_link != null:
		return
	# system.tscn parks this on the procedural box's top face. A model with its own
	# geometry has to say where it really lives, or it hangs in the air beside the
	# console. See RetroSystemModel.configure_sync_button.
	_model.configure_sync_button(_sync_button)
	_wii_link = WiiLink.new()
	_wii_link.name = "WiiLink"
	add_child(_wii_link)
	_wii_link.setup(self, _sync_button)


## The node holding a given libretro port, or null. A read-only window onto the
## port cache for components that need to see what is where — WiiLink searches it
## for a free remote slot — without every one of them reaching into the array.
func port_holder(port: int) -> Node:
	if port < 0 or port >= _port_controllers.size():
		return null
	var held: Node = _port_controllers[port]
	return held if is_instance_valid(held) else null


## True while a save is seating this machine's media, so hooks that make a NOISE
## on insertion can tell a restore from a player pushing a cartridge in.
func is_restoring_media() -> bool:
	return _restoring_media


## The cabinet socket a plug went into, or null when it cannot be told yet.
##
## Two ways to find it, because _port_plugs is not always filled in by the time a
## plug-in hook runs. The index is the FALLBACK rather than the primary: it is
## the libretro port, which equals the cabinet socket for a joypad but not for
## everything — a computer mouse is forced to port 0 whichever socket it is in —
## so the identity lookup is preferred whenever it is available.
##
## Callers want it to place a sound at the socket rather than at the plug, which
## on_plugged_in fires too early to do from the plug's own position.
func port_socket(plug: Node, port_index: int) -> Node3D:
	for i in _port_plugs.size():
		if _port_plugs[i] == plug and i < _port_zones.size():
			return _port_zones[i] as Node3D
	if port_index >= 0 and port_index < _port_zones.size():
		return _port_zones[port_index] as Node3D
	return null


## Every port's holder, port order, null where nothing is plugged in.
##
## The companion to port_holder for callers that have to walk all of them —
## netplay decides which ports a frame must carry. A copy, so a caller cannot
## reshape the cache by holding onto it.
func port_holders() -> Array:
	return _port_controllers.duplicate()


## The Wii pairing component, or null on every other console. Wii Remotes look it
## up here after a save restore, when they have a system but not yet a link.
func get_wii_link() -> WiiLink:
	return _wii_link


## The active hardware model (RetroSystemModel). Lets peripherals/held-input drive
## model-side visuals (e.g. a handheld animating its own buttons from input).
func get_model() -> RetroSystemModel:
	return _model


## The Libretro node, so plugged-in peripherals can call input methods on it.
func get_libretro_node() -> Libretro:
	return _libretro


# --- Controller port snap handlers ---

func _on_port_snapped(port_index: int, controller: Node3D) -> void:
	_model.play_port_plug_insert(controller, _port_zones[port_index])
	var device_type: int = controller.get("device_type") if "device_type" in controller else 1
	# The libretro port a peripheral drives isn't always its cabinet slot: on
	# computer systems the mouse is forced to port 0 (where those cores poll it),
	# so a mouse + keyboard can share the cabinet. See _libretro_port_for().
	_bind_port(_libretro_port_for(device_type, port_index), controller, port_index)


func _on_port_released(port_index: int) -> void:
	var plug: Node3D = _port_plugs[port_index]
	_port_plugs[port_index] = null
	if not is_instance_valid(plug):
		return
	var device_type: int = plug.get("device_type") if "device_type" in plug else 1
	# Clear the SAME libretro port the snap set (a computer mouse claimed port 0,
	# not its cabinet slot; a computer keyboard claimed none).
	_unbind_port(_libretro_port_for(device_type, port_index), plug, port_index)


## Attach a controller (by its cable plug) to an EXPANDED libretro port that has
## no cabinet snap zone — used by a multitap plugged into a native port to fan
## out to consecutive ports.
func attach_expanded_controller(port: int, plug: Node3D) -> void:
	_bind_port(port, plug, -1)


## Detach a controller from an expanded port (see attach_expanded_controller).
func detach_expanded_controller(port: int, plug: Node3D) -> void:
	_unbind_port(port, plug, -1)


## Bind a peripheral to a libretro port, from either direction: `cabinet_index`
## is the socket it seated into, or -1 for an EXPANDED port — one a multitap fans
## out to, which has no socket, no plug to remember and no Wii translation, but is
## a port to the core like any other.
##
## Written once because the expanded copy used to be an abridged one, and the
## abridgement is what dropped the device translation: a light gun on a multitap
## announced RETRO_DEVICE_LIGHTGUN, which fceumm turns into a gamepad.
func _bind_port(lib_port: int, plug: Node3D, cabinet_index: int) -> void:
	if lib_port < 0 or not is_instance_valid(plug):
		return
	var device_type: int = plug.get("device_type") if "device_type" in plug else 1
	var announce := device_type
	if cabinet_index >= 0:
		add_collision_exception_with(plug)
		# The plug itself is kept for the release path, which is handed nothing.
		_port_plugs[cabinet_index] = plug
		# On a Wii the slot may already hold a paired remote, and a wired pad may
		# need announcing as a GameCube pad rather than a plain joypad. Both are
		# Wii policy and both live in WiiLink; every other console skips them.
		if _wii_link != null:
			_wii_link.evict_remote_from(lib_port)
			announce = _wii_link.cabinet_device_id(device_type)
	announce = core_device_id(announce, lib_port)
	print("[RetroSystem] port %d bound: device_type=%d -> libretro port %d (announced %d)" %
		[cabinet_index, device_type, lib_port, announce])
	if _claims_port_device(device_type):
		set_controller_port_device(lib_port, announce)
	# The bound node is a ControllerPlug (cable end). Unwrap to the actual
	# RetroController so rumble can be routed to its set_rumble() method.
	var ctrl: Node3D = plug.get_controller() if plug.has_method("get_controller") else plug
	var slot := cabinet_index if cabinet_index >= 0 else lib_port
	if slot < _port_controllers.size():
		_port_controllers[slot] = ctrl
	if plug.has_method("on_plugged_in"):
		plug.on_plugged_in(self, lib_port)
	# Auto-select the core's per-port pad type (e.g. PCSX-ReARMed: DualShock vs
	# the original digital pad). No-ops unless the core exposes such an option.
	_apply_pad_type_option(lib_port, ctrl)
	NetworkManager.report_event(NetEvents.Event.EV_PORT_PLUG,
		{"sys": self, "ctrl": ctrl, "port": slot})


## Release a peripheral from a libretro port. See _bind_port for `cabinet_index`.
func _unbind_port(lib_port: int, plug: Node3D, cabinet_index: int) -> void:
	if lib_port < 0:
		return
	print("[RetroSystem] port %d released" % cabinet_index)
	# Stop any active rumble on the controller being unplugged.
	var ctrl: Node3D = plug.get_controller() \
		if is_instance_valid(plug) and plug.has_method("get_controller") else plug
	if is_instance_valid(ctrl) and ctrl.has_method("set_rumble"):
		ctrl.set_rumble(0.0, 0.0)
	var device_type: int = plug.get("device_type") \
		if is_instance_valid(plug) and "device_type" in plug else 1
	if cabinet_index >= 0 and is_instance_valid(plug):
		remove_collision_exception_with(plug)
	var slot := cabinet_index if cabinet_index >= 0 else lib_port
	if slot < _port_controllers.size():
		_port_controllers[slot] = null
	if _claims_port_device(device_type):
		set_controller_port_device(lib_port, RETRO_DEVICE_NONE)
	if is_instance_valid(plug) and plug.has_method("on_unplugged"):
		plug.on_unplugged()
	NetworkManager.report_event(NetEvents.Event.EV_PORT_UNPLUG, {"sys": self, "port": slot})


## Route a rumble request from the core to the RetroController currently
## plugged into the matching cabinet port.
func _on_rumble_state_changed(port: int, weak: float, strong: float) -> void:
	if port < 0 or port >= _port_controllers.size():
		return
	var ctrl = _port_controllers[port]
	if ctrl and is_instance_valid(ctrl) and ctrl.has_method("set_rumble"):
		ctrl.set_rumble(weak, strong)


# --- Cartridge slot callbacks ---

## Does this object belong to this system, per one of the compatibility tables?
##
## An object that names no system is universal and always fits — RetroXR's own
## props (generic pad, keyboard, mouse, multitap, light gun) stand in for hardware
## we have no model of, so locking them to one system would strand every console
## that has no dedicated pad yet, and unlabelled legacy media keeps working.
##
## Anything that is not media or a plug at all falls through to true and is still
## filtered by the zone's own snap_require.
func _belongs_here(obj: Node3D, compat: Dictionary) -> bool:
	if not "systemid" in obj:
		return true
	var mid := str(obj.get("systemid"))
	if mid.is_empty():
		return true
	return mid == systemid or mid in compat.get(systemid, [])


## Slot gate: does this piece of media (cartridge/disc) belong in this system?
func _accepts_media(obj: Node3D) -> bool:
	# A cartridge-shaped expansion goes in this slot and fills it, the way it does
	# on the hardware: a Mega Drive holds a 32X or a game, never both.
	var unit := obj as RetroExpansion
	if unit != null:
		return ExpansionCatalog.host_of(unit.expansion_id) == systemid \
			and ExpansionCatalog.mount_of(unit.expansion_id) == ExpansionCatalog.MOUNT_CARTRIDGE
	if _belongs_here(obj, _MEDIA_COMPAT):
		return true
	# An expansion with no bay of its own loads through THIS slot. A Satellaview
	# pack is a cartridge you push into the Super Famicom on top of it, so the
	# console has to take a systemid that is not its own -- see
	# ExpansionCatalog.host_slot_media for why it takes one whether or not the
	# base station is actually bolted on.
	if not ("systemid" in obj):
		return false
	return ExpansionCatalog.host_slot_media(systemid).has(str(obj.get("systemid")))


## Port gate: does this plug's controller belong to this system? Reads the
## systemid the ControllerPlug copied off its controller.
func _accepts_plug(obj: Node3D) -> bool:
	return _belongs_here(obj, _CONTROLLER_COMPAT)


## Card gate: is this the family of card this console takes? Every card is in
## one "memory_card" group — the group is load-bearing in scene persistence, the
## netplay object sync and the card's own numbering — so the family is what
## separates them, the same way a plug's systemid separates controllers.
func _accepts_card(obj: Node3D) -> bool:
	if obj == null or not ("family" in obj):
		return false
	return str(obj.get("family")) == card_family()


## Returns the currently snapped cartridge, or null (used by save/load).
func get_snapped_cartridge() -> Node3D:
	return _snapped_cartridge


## The media whose saves and achievements this machine's Game tab should show.
##
## The console's OWN slot first. With F-Zero X in the N64 and its Expansion Kit
## disk in the 64DD under it, the cartridge is the identity of the session --
## rom_path, the save file and the achievement set all key off it -- so it is the
## one to show, and the disk is a second piece of media for the same game.
##
## Otherwise whatever an attached unit is holding. A bare 64DD disk, a Mega-CD
## disc and a 32X cartridge are each the whole of the game on that machine, and
## the tab was hidden for all three: it asked only about the console's own slot,
## so a stack with its game one box further down looked like a console with
## nothing in it at all. Saves and achievements exist for those games exactly as
## they do for a cartridge, and there was no way to reach them.
##
## RetroDisc extends RetroCartridge, so one test covers a disc as well as a cart.
func game_media() -> RetroCartridge:
	if _snapped_cartridge is RetroCartridge:
		return _snapped_cartridge as RetroCartridge
	for unit in get_expansions():
		# Every bay, not the first: a Sufami Turbo with its second slot filled and
		# its first empty would otherwise report no game at all, and the machine
		# would offer neither saves nor achievements for something plainly in it.
		for s in unit.get_bay_count():
			var m := unit.get_media(s)
			if m is RetroCartridge:
				return m as RetroCartridge
	return null


## Restore a cable→TV connection after loading from a save file.
## Safe to call before the cables have finished spawning — the snap will be
## deferred until _add_cables_to_scene() runs if the plug isn't ready yet.
## `channel` picks the video-out cable (0 on classic single-cable systems);
## `tv_input` picks which of the set's four composite inputs to land in.
func restore_cable_connection(tv: RetroTV, channel: int = 0, tv_input: int = 0) -> void:
	if channel < 0 or channel >= _channels.size():
		channel = 0
	print("[RetroSystem] restore_cable_connection: ch=%d in=%d plug=%s tv=%s" %
		[channel, tv_input, _channels[channel].plug if channel < _channels.size() else null, tv])
	if channel < _channels.size() and _channels[channel].plug != null:
		_snap_cable_to_tv(tv, channel, tv_input)
	else:
		print("[RetroSystem] cable plug not ready yet, deferring restore")
		_channels[channel].pending_tv = tv
		_channels[channel].pending_input = tv_input


func _snap_cable_to_tv(tv: RetroTV, channel: int = 0, tv_input: int = 0) -> void:
	tv.accept_plug_restore(_channels[channel].plug, tv_input)


## Restore a cartridge→slot insertion after loading from a save file. Slot/tray
## loaders seat the disc immediately through MediaSlot/MediaTray (no ride, filter
## bypassed); plain cartridge systems snap it through the zone as before.
## True only while a save is being reloaded into this machine. Restoring seats
## media and plugs through the SAME snap-zone calls a hand does, so anything that
## makes a NOISE on those events has to be able to tell the two apart — otherwise
## loading a room plays a cartridge insert for every console at once.
var _restoring_media: bool = false


func restore_cartridge(cartridge: Node3D) -> void:
	_restoring_media = true
	if _slot != null:
		_slot.restore(cartridge)
	elif _tray != null:
		_tray.restore(cartridge)
	else:
		_cartridge_slot.pick_up_object(cartridge)
		# A saved cart is one the machine could READ, so the tray it came out of was
		# pushed home. Pushed again inside the restore flag, so it lands latched with
		# neither the slide nor the sound.
		if has_push_tray_bay():
			_model.push_tray_down()
	_restoring_media = false


## The counterpart to restore_cartridge, for a remote peer taking the cart out.
##
## Releases the snap zone rather than running the local eject ride: the media is
## already gone on the peer that moved it, and object_sync positions it here.
## Which child holds the cartridge stays this machine's business.
func net_release_cartridge() -> void:
	_cartridge_slot.drop_object()


## The same, for a memory card. `slot` is an index into MEMCARD_SLOT_NODES and
## is clamped by the caller, so a console with one well still answers an event
## from a peer that has two.
##
## Exists so the relay does not have to reach in by node name. It was the one
## eject that had no method, which meant object_sync walked this machine's
## children looking for a snap zone — the sort of thing that keeps working right
## up until a console arranges its slots differently.
func net_release_memory_card(slot: int) -> void:
	if slot < 0 or slot >= _memcard_slots.size():
		return
	_memcard_slots[slot].drop_object()


## Restore a controller plug into a port after loading from a save file.
func restore_controller_plug(port_index: int, plug: ControllerPlug) -> void:
	if port_index < 0 or port_index >= _port_zones.size():
		return
	# Never evict. XRToolsSnapZone.pick_up_object drops whatever a zone is already
	# holding, so two peripherals naming the same slot would restore as one plugged
	# in and one lying on the floor — and the loser is decided by file order. That
	# is exactly what a save written before cabinet_port_of() existed says, since a
	# computer mouse recorded libretro port 0 rather than its socket, so those files
	# have to land somewhere sensible rather than unplug the keyboard.
	_restoring_media = true
	if is_instance_valid(_port_zones[port_index].picked_up_object):
		for i in _port_zones.size():
			if _port_zones[i].enabled and not is_instance_valid(_port_zones[i].picked_up_object):
				_port_zones[i].pick_up_object(plug)
				_restoring_media = false
				return
		_restoring_media = false
		return
	_port_zones[port_index].pick_up_object(plug)
	_restoring_media = false


## Release a controller port from replicated state. A plain SnapZone drop leaves
## the plug centred in its grab volume, so it is immediately picked back up on
## the next physics tick. The local player's hand naturally carries a pulled
## plug away; a remote peer has no synced plug body, so park it by its controller
## before re-enabling the socket.
func net_release_controller_port(port_index: int) -> void:
	if port_index < 0 or port_index >= _port_zones.size():
		return
	var zone := _port_zones[port_index] as XRToolsSnapZone
	var plug := _port_plugs[port_index] as ControllerPlug
	var plug_enabled := plug.enabled if is_instance_valid(plug) else false
	var enabled: Array[bool] = []
	for candidate: XRToolsSnapZone in _port_zones:
		enabled.append(candidate.enabled)
		candidate.enabled = false
	if is_instance_valid(plug):
		plug.enabled = false
	zone.drop_object()
	if is_instance_valid(plug):
		for candidate: XRToolsSnapZone in _port_zones:
			candidate.forget_object(plug)
		var controller := plug.get_controller()
		var attach := controller.get_node_or_null("CableAttachPoint") as Node3D \
			if is_instance_valid(controller) else null
		if attach != null:
			plug.global_position = attach.global_position \
				+ attach.global_basis * Vector3(0, 0, -0.12)
		if plug is RigidBody3D:
			(plug as RigidBody3D).linear_velocity = Vector3.ZERO
			(plug as RigidBody3D).angular_velocity = Vector3.ZERO
	# DROPPED-mode zones receive the plug's dropped signal deferred. Keep every
	# neighbouring socket shut until that callback and a physics overlap refresh
	# have both passed, or the plug simply hops from port 1 into port 2.
	get_tree().create_timer(0.1).timeout.connect(func() -> void:
		for i in _port_zones.size():
			_port_zones[i].enabled = enabled[i]
		if is_instance_valid(plug):
			plug.enabled = plug_enabled, CONNECT_ONE_SHOT)


## Which cabinet socket holds this peripheral, or -1 if the system is not holding
## it at all.
##
## The peripheral's own _port_index is the LIBRETRO port, which is the same number
## only by coincidence: _libretro_port_for pins a mouse on a computer system to
## port 0 whichever socket it is in, because that is where those cores poll it. So
## a save that recorded _port_index put the mouse and the keyboard both in socket 1
## on restore, and one of them was left dangling. Ask the cabinet instead.
func cabinet_port_of(peripheral: Node) -> int:
	for i in _port_controllers.size():
		if is_instance_valid(_port_controllers[i]) and _port_controllers[i] == peripheral:
			return i
	return -1


## True when this cabinet's bay only connects on a push, so a cart lying in it knows
## a click means "push me home" rather than "take me out".
func has_push_tray_bay() -> bool:
	return _model != null and _model.has_push_tray()


## Is this cabinet's tray pushed home? False for every bay that has no tray.
func is_tray_down() -> bool:
	return has_push_tray_bay() and _model.is_tray_down()


## Push the cart home, or lift it back out. Both the desktop click and the VR hand
## end up here.
func toggle_cart_tray() -> void:
	if not has_push_tray_bay():
		return
	if _model.is_tray_down():
		_model.lift_tray()
	else:
		_model.push_tray_down()


## A bay whose cart only connects when it is pushed home (the NES ZIF cradle).
## The zone catching a cart means the cart is LYING in the tray, nothing more, so
## the emulation-side pair is fired by the tray instead — the same swap MediaSlot
## and MediaTray make for disc loaders.
func _wire_push_tray() -> void:
	if not _model.has_push_tray():
		return
	if _cartridge_slot.has_picked_up.is_connected(_on_cartridge_inserted):
		_cartridge_slot.has_picked_up.disconnect(_on_cartridge_inserted)
	if _cartridge_slot.has_dropped.is_connected(_on_cartridge_removed):
		_cartridge_slot.has_dropped.disconnect(_on_cartridge_removed)
	_cartridge_slot.has_picked_up.connect(_on_cart_laid_in_tray)
	_cartridge_slot.has_dropped.connect(_on_cart_taken_from_tray)
	_model.cart_tray_changed.connect(_on_cart_tray_changed)


## Cart is in the tray. It slides home visually here; the machine still cannot read
## it. A tray left down by a cart pulled out of it takes the next one straight away,
## because nothing more is going to be pushed.
func _on_cart_laid_in_tray(cartridge: Node3D) -> void:
	_tray_cartridge = cartridge
	_model.play_cartridge_insert(cartridge, _cartridge_slot)
	if _model.is_tray_down():
		_on_cartridge_inserted(cartridge)


## Cart has left the tray for good.
func _on_cart_taken_from_tray() -> void:
	_tray_cartridge = null
	if _snapped_cartridge != null:
		_on_cartridge_removed()
	else:
		_model.play_cartridge_eject(null, _cartridge_slot)


## The tray was pushed home, or sprung back up.
func _on_cart_tray_changed(down: bool) -> void:
	if down:
		if is_instance_valid(_tray_cartridge):
			_on_cartridge_inserted(_tray_cartridge)
	elif _snapped_cartridge != null:
		_on_cartridge_removed()


func _on_cartridge_inserted(cartridge: Node3D) -> void:
	# An expansion in the cartridge slot is a machine being bolted on, not media
	# being loaded: it has no ROM of its own, and what it runs goes into a slot
	# of its own further up the stack.
	var unit := cartridge as RetroExpansion
	if unit != null:
		add_collision_exception_with(unit)
		unit.bind_to_host(self)
		return

	_snapped_cartridge = cartridge
	# Prevent the frozen kinematic cartridge from physically pushing the system body.
	# Slot/tray loaders let their MediaSlot/MediaTray own the exception (held until
	# the disc is grabbed clear), so only plain cartridge decks add one here.
	if _slot == null and _tray == null:
		add_collision_exception_with(cartridge)
	if cartridge.has_method("get_rom_path"):
		rom_path = cartridge.get_rom_path()
	# Back-fill the cartridge's systemid (save-recovery list needs it to
	# resolve the core) — a cart inserted into an NES is an NES cart.
	if "systemid" in cartridge and str(cartridge.get("systemid")).is_empty():
		cartridge.set("systemid", systemid)
	# A push-tray bay already slid the cart home when it was laid in — this moment
	# is the tray latching, which moves nothing.
	if not _model.has_push_tray():
		_model.play_cartridge_insert(cartridge, _cartridge_slot)
	# (Slot/tray loaders already seated the disc and set its grabbability through
	# MediaSlot/MediaTray — the disc's enabled state follows the lid there.)
	# Hot swap: a powered disc console with its virtual tray open takes the new
	# disc without a reboot (multi-disc games — FF7 "insert disc 2").
	#
	# A lidded drive reports nothing here. Its lid is the sensor, so the swap
	# reaches the core when the lid shuts (_sync_core_tray) — a disc laid in an
	# open tray has not been read by anything yet.
	if _tray == null and is_powered_on and _supports_disk_control() and _disc_ejected \
			and not rom_path.is_empty() and not NetworkManager.is_event_applying():
		# _disc_index is the core's internal image-list SLOT (get_image_index),
		# not a disc number — without .m3u the list has one slot (0) and the
		# swap overwrites the file in it (replace_image_index).
		print("[RetroSystem] Hot swap: image slot %d -> %s" % [_disc_index, rom_path])
		_request_disk_op(1, rom_path)
		_protect_active_rom()
	NetworkManager.report_event(NetEvents.Event.EV_CART_INSERT,
		{"sys": self, "cart": cartridge})


func _on_cartridge_removed() -> void:
	# The slot says it is empty, not what left it. If what left was a bolted-on
	# expansion, that is the join coming apart.
	for held in get_expansions():
		if ExpansionCatalog.mount_of(held.expansion_id) == ExpansionCatalog.MOUNT_CARTRIDGE:
			remove_collision_exception_with(held)
			held.unbind_from_host()
			return

	if _snapped_cartridge:
		# On a push-tray bay this fires when the tray is LIFTED, with the cart still
		# lying in it — the eject belongs to the cart actually leaving, which
		# _on_cart_taken_from_tray plays.
		if not _model.has_push_tray():
			_model.play_cartridge_eject(_snapped_cartridge, _cartridge_slot)
		# Slot/tray loaders let MediaSlot/MediaTray manage (and hold) the collision
		# exception until the disc is grabbed clear — don't drop it here.
		if _slot == null and _tray == null:
			remove_collision_exception_with(_snapped_cartridge)
		_snapped_cartridge = null
	_disc_spin = 0.0
	# Taking the media out never interrupts the run. A console does not stop when
	# a disc leaves the drive — that is what lets Monster Rancher read whatever
	# CD you hand it, and what keeps a multi-disc game alive between discs — and a
	# floppy machine behaves the same way. Only a cartridge deck powers off, where
	# pulling the cart really does take the program away.
	if is_powered_on and _media_survives_removal():
		# A lidded drive tells the core nothing yet: the lid is the sensor, and
		# the core hears about it when the lid shuts. A slot drive has no lid, so
		# the disc leaving IS the event. rom_path stays mounted either way — that
		# image is still what the core is running.
		print("[RetroSystem] Media out: game keeps running (%s)" % rom_path)
		if _tray == null and _supports_disk_control() \
				and not NetworkManager.is_event_applying():
			_request_disk_op(DISK_OP_EJECT, "")
		NetworkManager.report_event(NetEvents.Event.EV_CART_REMOVE, {"sys": self})
		return
	if is_powered_on:
		power_off()
	rom_path = ""
	NetworkManager.report_event(NetEvents.Event.EV_CART_REMOVE, {"sys": self})


## Cached disk-control state from the emulation thread (async signal).
func _on_disk_control_ready(has_control: bool, count: int, current_index: int,
		ejected: bool) -> void:
	# Log state changes (not every echo) — the boot answer and each op's result.
	if has_control != _has_disk_control or current_index != _disc_index \
			or ejected != _disc_ejected:
		print("[RetroSystem] Disk control: has=%s images=%d index=%d ejected=%s" %
			[has_control, count, current_index, ejected])
	_has_disk_control = has_control
	_disc_index = current_index
	_disc_ejected = ejected


## Whether a disc change can reach the core without rebooting it.
##
## The live answer arrives on disk_control_ready, which is async: it lands some
## frames after the core comes up, and a disc pulled before it did took the "no
## disk control" path and powered the machine off. The core's own .info file
## answers the same question before the core is even loaded, so ask that too.
func _supports_disk_control() -> bool:
	if _has_disk_control:
		return true
	var info := CoreInfoDatabase.shared().get_by_core_name(_resolve_core())
	return str(info.get("disk_control", "false")) == "true"


## True when this machine's media can leave while the program keeps running: a
## disc drive of either kind, or a floppy machine. A cartridge deck cannot — the
## program itself lives on the cart.
func _media_survives_removal() -> bool:
	return _disc_loader != MediaDimensions.LOADER_NONE \
		or MediaDimensions.uses_floppy(systemid)


## Disc ops, as `_request_disk_op` takes them. NONE is not an op — it is the
## answer `_tray_op_for` gives when the core needs to hear nothing at all.
const DISK_OP_NONE := -1
const DISK_OP_EJECT := 0
const DISK_OP_CLOSE := 1


## Perform a disc op — op 0 = eject (open the core's tray), op 1 = replace the
## current image with `path` and close the tray. Offline: straight to the core.
## Netplay: frame-scheduled so every lockstep peer swaps on the same frame
## (host schedules; clients send intent via EV_DISK_OP).
func _request_disk_op(op: int, path: String) -> void:
	if NetworkManager.netplay_running() and NetworkManager.netplay_covers(self):
		var md5 := "" if path.is_empty() else NetFileTransfer.hash_of(path)
		if NetworkManager.is_host():
			NetworkManager.netplay_schedule_disk(self, op, md5, _disc_index)
		else:
			print("[RetroSystem] Disc op %d intent -> host (md5 %s…)" % [op, md5.left(8)])
			NetworkManager.report_event(NetEvents.Event.EV_DISK_OP,
				{"sys": self, "op": op, "md5": md5, "index": _disc_index})
		# The core-side state flips on the scheduled frame; the mirror updates
		# via disk_control_ready then.
		return
	if op == DISK_OP_EJECT:
		_libretro.SetDiskEjectState(true)
		_disc_ejected = true
	else:
		_libretro.ReplaceDiskImage(_disc_index, path)
		_libretro.SetDiskEjectState(false)
		_disc_ejected = false
	# Read the drive back rather than trusting what we just wrote. The mirror is
	# what the next decision is made from, and it drifts: the answer to a
	# RequestDiskInfo issued at power-on drains AFTER an early lid press and
	# reports the state from before it, quietly overwriting the truth.
	_libretro.RequestDiskInfo()


# --- Disc loader (tray lid / slot loading) ---

## OPEN (tray consoles): toggles the lid, gating insert/remove and the spin.
## EJECT (slot consoles): slides the seated disc out so it can be grabbed.
func _on_eject_pressed() -> void:
	match _disc_loader:
		MediaDimensions.LOADER_TRAY:
			# A spring-latched lid (PSone/PSX/Saturn/Dreamcast/PS2) is closed BY HAND —
			# the button is only a latch release, so pressing it while the lid is already
			# up does nothing. Pressing it used to snap the lid shut, which is not what
			# the real hardware does.
			if _has_spring_lid():
				if not _tray_open:
					_request_tray_state(true)
			else:
				_request_tray_state(not _tray_open)
		MediaDimensions.LOADER_SLOT:
			if _slot:
				# Pressed again with the disc still resting at the slot mouth, it
				# takes the disc back — a slot drive has no open tray to leave it on.
				_slot.toggle_eject()


## True when the model's lid is spring-loaded + hand-closed (see
## RetroSystemModel.has_spring_latched_lid).
func _has_spring_lid() -> bool:
	if _disc_bay != null and _disc_bay.lid_hinge != null:
		return true          # the procedural box's own lid
	return _model != null and _model.has_spring_latched_lid()


## A model's own hand-driven lid (e.g. the PSone's VRHinge) reporting the state
## the player physically put it in. Idempotent, so a drag can report freely.
func request_tray_state(open: bool) -> void:
	if _disc_loader == MediaDimensions.LOADER_TRAY and open != _tray_open:
		_request_tray_state(open)


## Local intent (OPEN button or pushing the lid shut): apply + replicate.
func _request_tray_state(open: bool) -> void:
	_set_tray_open(open)
	NetworkManager.report_event(NetEvents.Event.EV_TRAY,
		{"sys": self, "open": _tray_open})


## Apply a tray state: the snap zone only hover-accepts discs while open, and a
## seated disc can only be grabbed out while open (no reaching through the lid).
## The spin ramp follows via _update_disc_spin. Netplay applies remote toggles
## through net_set_tray_open below.
##
## `restoring` is a load re-entering a state the room was already in: the shell
## has just been posed by set_lid_angle_deg, so nothing animates and the model is
## not asked to play the swing again — but every gate is applied exactly as a
## press would, which is the whole reason a restore comes through here at all.
func _set_tray_open(open: bool, restoring: bool = false) -> void:
	_tray_open = open
	# MediaTray gates the well (accepts a disc only while open + empty), makes a
	# seated disc grabbable only while open, and swings the procedural lid pivot.
	if _tray:
		_tray.set_open(open, not restoring)
	# Latch the OPEN button down to show "tray open" — except on a spring lid, whose
	# button is a momentary latch release (holding it down would advertise a second
	# press that deliberately does nothing).
	_eject_button.set_latched_pressed(open and not _has_spring_lid())
	# The procedural spring lid: unlatch so it pops up, or snap it shut. A remote
	# peer's toggle arrives here too, so both ends stay in the same physical state.
	if _disc_bay != null:
		if _disc_bay.lid_hinge != null:
			if open:
				_disc_bay.lid_hinge.open()
			else:
				_disc_bay.lid_hinge.latch_closed()
		_disc_bay.slide(open)
	# Bespoke GLB tray models animate their own lid here. Skipped on a restore,
	# where set_lid_angle_deg has already put the shell exactly where the save
	# says it was — playing the swing would tween it there from wherever it is.
	if not restoring:
		if open:
			_model.play_open()
		else:
			_model.play_close()
	_sync_core_tray()


## The lid is the drive's sensor, so the core's tray follows the LID and not the
## disc. Opening tells the core the tray is open; shutting hands it whatever is
## in the well by then. In between the core hears nothing, which is what lets a
## disc be swapped — or an unrelated one shown to the drive and taken back out —
## without the program seeing anything but one tray cycle.
##
## A slot drive has no lid to read, so its insert and eject are the events; they
## stay where they are, in _on_cartridge_inserted/_removed.
func _sync_core_tray() -> void:
	if _tray == null or not is_powered_on or not _supports_disk_control():
		return
	# A remote peer's lid arrives through net_set_tray_open; the machine's owner
	# schedules the op for everyone, so applying one here would double it.
	if NetworkManager.is_event_applying():
		return
	var has_disc := _snapped_cartridge != null and not rom_path.is_empty()
	var op := _tray_op_for(_tray_open, _disc_ejected, has_disc)
	# Logged either way. When a machine will not boot what is plainly sitting in
	# its bay, this line is the difference between the room and the core — and
	# the one thing that cannot be read off the screen.
	print("[RetroSystem] Lid %s: disc=%s core_ejected=%s -> %s"
		% ["open" if _tray_open else "shut", has_disc, _disc_ejected,
			["nothing", "eject", "close on " + rom_path.get_file()][op + 1]])
	if op == DISK_OP_NONE:
		return
	_request_disk_op(op, rom_path if op == DISK_OP_CLOSE else "")
	if op == DISK_OP_CLOSE:
		_protect_active_rom()


## Pure lid-to-core decision: what the core needs to be told when the lid reaches
## `open`, given what it currently believes (`core_ejected`) and whether there is
## a disc in the well to hand it.
##
## Shutting the lid over a disc always hands it over, even the one already
## mounted — a real drive re-reads what it finds. Shutting it over an empty well
## says nothing, so the core keeps waiting with its tray open rather than being
## told to close on nothing.
static func _tray_op_for(open: bool, core_ejected: bool, has_disc: bool) -> int:
	if open:
		return DISK_OP_NONE if core_ejected else DISK_OP_EJECT
	return DISK_OP_CLOSE if has_disc else DISK_OP_NONE


## The lid moved under its own mechanism — mark the tray as wherever it now
## stands, as the PSP's UMD door does.
##
## BOTH directions, and that is the fix. This used to report only the latch
## clicking SHUT, because in play the only way a lid opens is the OPEN button,
## which reports for itself. A restore does not press that button:
## ScenePersistence reapplies the saved angle and latch straight onto the
## mechanism, so a room saved with the lid up came back with the lid standing
## open over a machine that still believed it was shut — and its bay refused
## every disc until the lid was pushed home and opened again.
##
## request_tray_state is idempotent, so the echo from an OPEN press or from
## latch_closed() stops here rather than bouncing back into the hinge. While a
## remote update or a restore is being APPLIED the state is set without being
## reported, which is the rule _sync_core_tray already follows — a hook that
## re-reports what it was just told starts a round trip.
func _on_lid_swung(_deg: float) -> void:
	if _disc_bay == null or _disc_bay.lid_hinge == null:
		return
	_lid_reports(not _disc_bay.lid_hinge.is_latched_closed(),
		_disc_bay.lid_hinge)


## A lid mechanism reporting its own state. Public because a bespoke model owns
## its hinge and reports through here rather than growing a second copy of the
## rule (see playstation_model._on_lid_swung).
func lid_reports_open(open: bool, mechanism: Node) -> void:
	_lid_reports(open, mechanism)


func _lid_reports(open: bool, mechanism: Node) -> void:
	if _disc_loader != MediaDimensions.LOADER_TRAY or open == _tray_open:
		return
	var applying: bool = NetworkManager.is_event_applying() \
		or (mechanism != null and mechanism.has_meta("net_restore_in_progress"))
	if applying:
		_set_tray_open(open, true)
	else:
		_request_tray_state(open)


## Netplay: another player toggled this console's tray.
func net_set_tray_open(open: bool) -> void:
	if _disc_loader == MediaDimensions.LOADER_TRAY and open != _tray_open:
		_set_tray_open(open)


# --- Achievements, toasts and content naming ---
#
# Sat inside the memory-card block by accident of position rather than of
# subject, and came back when that block moved out.

var _net_no_content_override := false


## Ask to track achievements for the game about to start. Silent on refusal —
## another cabinet holding the session, or a system RetroAchievements has no
## console for, is an ordinary outcome and not worth a message.
func _claim_achievements_session() -> void:
	if not RA.claim_session(self, _resolve_systemid(), _libretro):
		return
	if not RA.achievement_unlocked.is_connected(_on_achievement_unlocked):
		RA.achievement_unlocked.connect(_on_achievement_unlocked)


func _on_achievement_unlocked(_id: int, title: String, description: String,
							  points: int, badge: Texture2D) -> void:
	# The signal is global, so a cabinet that lost the session to another machine
	# must not raise a toast for its unlocks.
	if RA.session_owner() != self:
		return
	var toast := _screen_toast()
	if toast == null:
		return
	toast.show_unlock(title, description, points, badge)


## The notification card over this machine's picture, made on demand.
##
## Rebuilt when the picture has moved — plugging a video-out cable into a TV
## changes _screen_target(), and a cached card is parented to the old one.
## Null when the machine has no screen at all: a console with no TV connected.
func _screen_toast() -> AchievementToast:
	var anchor := _screen_target()
	if anchor == null:
		return null
	if is_instance_valid(_screen_toast_card) and _screen_toast_card.anchor() != anchor:
		_screen_toast_card.queue_free()
		_screen_toast_card = null
	if not is_instance_valid(_screen_toast_card):
		_screen_toast_card = AchievementToast.attach(anchor)
	return _screen_toast_card if is_instance_valid(_screen_toast_card) else null


## The notification card over the hardware itself, made on demand.
##
## For what the machine is waiting on rather than what it is showing. An empty
## slot is a state of the console, and the player who just pressed its power
## button is standing at it; a console cabled to a set across the room puts its
## picture where they are not, and a handheld's own panel is dark until a game
## runs. Never null: unlike the picture, the machine is always there.
func _machine_toast() -> AchievementToast:
	if not is_instance_valid(_machine_toast_card):
		_machine_toast_card = AchievementToast.attach_to_machine(self)
	return _machine_toast_card if is_instance_valid(_machine_toast_card) else null


## What is loaded, for a label or a save name — the cartridge's title, else the
## ROM's. Read by the memory-card controller when naming a backup.
func content_label() -> String:
	return _content_label()


func _content_label() -> String:
	if _snapped_cartridge and "game_label" in _snapped_cartridge:
		var lbl := str(_snapped_cartridge.get("game_label"))
		if not lbl.is_empty():
			return lbl
	return rom_path.get_file().get_basename()


## Which platform this machine is currently being: a cartridge's own systemid
## when one is seated, else the machine's. The controllers this node owns ask
## for it when naming a save.
func resolve_systemid() -> String:
	return _resolve_systemid()


func _resolve_systemid() -> String:
	if _snapped_cartridge and "systemid" in _snapped_cartridge:
		var sid := str(_snapped_cartridge.get("systemid"))
		if not sid.is_empty():
			return sid
	return systemid


# --- Memory cards ---
#
# The work lives in MemoryCardController, a child this node owns. What stays
# here is the surface other code already talks to by name: ScenePersistence and
# CardSaveOps ask this node for its seated cards, NetplaySession asks it for its
# SRAM, and the snap zones were wired to it in _ready.

## The memory-card bays, in slot order. A read-only window for the controller
## this node owns; the zones themselves stay this node's to wire.
func memcard_slots() -> Array[XRToolsSnapZone]:
	return _memcard_slots


var _memcards: MemoryCardController = null
## What a stacked expansion hands the core at boot - see ExpansionLaunch.
var _expansion_launch: ExpansionLaunch = null


## The MemoryCard seated in `slot`, or null.
func get_snapped_memcard(slot := 0) -> Node3D:
	return _memcards.get_snapped_memcard(slot)


## How many card slots this machine actually has.
func get_memcard_slot_count() -> int:
	return _memcards.get_memcard_slot_count()


## Re-resolve one slot (or all, with -1) and re-point a running core at it.
func refresh_memcard_path(slot := -1) -> void:
	_memcards.refresh_memcard_path(slot)


## Restore a card into its slot from a save. Called by ScenePersistence.
func restore_memory_card(card: Node3D, slot: int) -> void:
	_memcards.restore_memory_card(card, slot)


## Netplay: override the SRAM source for the next net_start_core. path "" turns
## local persistence off; data is injected so every peer boots identical.
func net_set_sram(path: String, data: PackedByteArray) -> void:
	_memcards.net_set_sram(path, data)


## Host: the current .srm bytes for the seated content, for the cold-start
## payload. Empty when no file exists yet.
func net_sram_file_bytes() -> PackedByteArray:
	return _memcards.net_sram_file_bytes()


## Which card family this machine takes, and how many slots — read by the
## power-on option path and by the snap filter.
func card_family() -> String:
	return _memcards.card_family()


func card_slot_count() -> int:
	return _memcards.card_slot_count()


## The path to hand the core for a run about to start. "" means nothing goes
## through SAVE_RAM, which is a real answer and not a failure.
func sram_path_for_run(resolved_core: String) -> String:
	return _memcards.sram_path_for_run(resolved_core)


func start_card_polling() -> void:
	_memcards.start_card_polling()


func stop_card_polling_soon() -> void:
	_memcards.stop_card_polling_soon()

# ---------------------------------------------------------------------------
# Save states
#
# The work lives in SaveStateController, a child this node owns. What stays here
# is the surface other code already talks to: CartridgeOptionsPanel connects
# these signals by name on the system node and calls the three methods below on
# it, so the seam is behind them rather than in front.
# ---------------------------------------------------------------------------

## ok is false with a sentence in `reason` the panel can show as-is.
signal state_captured(state_id: String, ok: bool, reason: String)
signal state_loaded(state_id: String, ok: bool, reason: String)

var _save_state: SaveStateController = null


## Can this machine take a state right now? {ok, reason} — reason is empty when
## ok, and a sentence to put on a disabled button when not.
func capture_gate() -> Dictionary:
	return _save_state.capture_gate()


## Take a state. `into_id` empty mints a new one; a real id overwrites that state
## in place. Answers exactly once through state_captured, always.
func capture_state(into_id := "") -> void:
	_save_state.capture_state(into_id)


## Restore a state. A machine that is off is switched on first, so one press does
## what was meant. Answers exactly once through state_loaded, always.
func load_state(state_id: String) -> void:
	_save_state.load_state(state_id)
