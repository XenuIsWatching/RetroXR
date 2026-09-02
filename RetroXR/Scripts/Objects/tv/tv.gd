## TV — pickable television with a screen surface and a composite video input port.
class_name RetroTV
extends XRToolsPickable




const CRT_SHADER := preload("res://Shaders/crt_effect.gdshader")
const VCR_SHADER := preload("res://Shaders/vcr_effect.gdshader")
# Dual-screen handhelds mirror one channel of their composite framebuffer onto
# the TV through this shader; the CRT stage chains inside it like the VCR's.
const WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")
# Analog snow, shown by the built-in tuner for every failure. Named here too
# because TvOsd.route and TvDisplay.update_crt both have to recognise it.
const STATIC_SHADER := preload("res://Shaders/tv_static.gdshader")
const GLASS_WEAR_TEXTURE := preload("res://Textures/TV/crt_glass_wear.png")

## Which input the set is showing. COMPOSITE_1..4 are the physical sockets on the
## back — a console, VCR or DVD deck on a composite lead — TV is the built-in tuner
## (see tv_tuner.gd) fed by channels.json, and RF is the aerial socket, which is how
## a console reaches a set through an RF switch (see rf_switch.gd).
##
## The composite inputs come FIRST and are contiguous, so a composite input's index
## is its own Source value and every per-input array is indexed by it directly. TV
## and RF are appended for the same reason: appending leaves that identity alone.
##
## RF is a real input rather than a flavour of TV even though a set has one aerial
## hole, because the tuner and an RF switch are two different things arriving at it
## and the viewer picks between them with SOURCE. The TV slot in the per-input arrays
## below is therefore always null — the tuner is not a "connected system" — and it is
## kept only so the arrays stay indexable by Source throughout.
##
## Named Source, not Input: `Input` is a native Godot singleton and an enum of
## that name shadows it, which fails to parse.
enum Source { COMPOSITE_1, COMPOSITE_2, COMPOSITE_3, COMPOSITE_4, TV, RF, VGA }

## How many composite inputs the set has. The back panel carries a socket trio per
## input (see tv.tscn) and tv_shell.gd lays them out for a fitted cabinet.
const COMPOSITE_INPUTS := 4

## Names as they appear in the OSD when SOURCE cycles. The OSD shouts, the way it
## does for POWER and MUTE; the back panel prints the same names in its own voice
## (AV_INPUT_NAMES).
const SOURCE_NAMES := ["COMPOSITE 1", "COMPOSITE 2", "COMPOSITE 3", "COMPOSITE 4",
	"TV", "RF", "VGA"]

## The channels an RF switch can put a console on, and what the set has to be tuned
## to for it to appear. Two of them because that is what the switch on the back of an
## NES offers; the set steps between them with the CH keys while RF is selected.
const RF_CHANNELS := [3, 4]

## The same four inputs as SILK-SCREENED beside their sockets — title case, because
## that is printing rather than shouting. Fed to AvLegend.title.
const AV_INPUT_NAMES := ["Composite 1", "Composite 2", "Composite 3", "Composite 4"]


## CRT display filter (curvature, scanlines, aperture mask). Applied to
## whatever source is showing — a system's game or the VCR's video.
@export var crt_enabled: bool = true

## Which cabinet to wear. Empty = the original box body authored in tv.tscn, and
## TvFit.load_shell() is then a strict no-op — the arcade and den TVs must render
## bit-identically to before this system existed.
@export var tv_model: String = ""

## Cabinet variants. A shell supplies geometry plus Marker3D seats; every
## functional node stays on this TV. See Scripts/Objects/tv/tv_shell.gd.
const _SHELL_SCENES := {
	"crt_plain":   "res://Scenes/Objects/tv_models/crt_plain.tscn",
}

## One-time aliases for scene records written while the removed imported shells
## existed. The old television becomes the stock set; the old VGA monitor becomes
## the retained primitive VGA monitor so its connector and source remain valid.
## Cabinets contributed by mods: shell_id -> {scene, label, owner}.
##
## Consulted BEFORE _SHELL_SCENES so a mod cabinet is reachable by the same
## "tv:<shell>" spawn token as a shipped one, and so tv_model round-trips through
## a save unchanged. A saved tv_model naming a mod that has gone falls through to
## the stock body, the way an unknown model_id falls through to a platform's
## default — nothing here needs to know the mod is missing.
static var _mod_shells: Dictionary = {}


## Returns "" on success.
static func register_mod_shell(shell_id: String, scene_path: String, label: String,
		owner_id: String) -> String:
	if _SHELL_SCENES.has(shell_id):
		return "'%s' is a shipped cabinet" % shell_id
	if _mod_shells.has(shell_id):
		return "'%s' is already registered by mod '%s'" % [shell_id,
			_mod_shells[shell_id].get("owner", "?")]
	if not ResourceLoader.exists(scene_path):
		return "scene does not exist: %s" % scene_path
	_mod_shells[shell_id] = {"scene": scene_path, "label": label, "owner": owner_id}
	return ""


static func _mod_shell_path(shell_id: String) -> String:
	return str((_mod_shells.get(shell_id, {}) as Dictionary).get("scene", ""))


## Every mod cabinet, as {id, label}, for the spawn menu.
static func mod_shells() -> Array:
	var out: Array = []
	for shell_id: String in _mod_shells:
		out.append({"id": shell_id, "label": str(_mod_shells[shell_id].get("label", shell_id))})
	return out


static func drop_mod_shells(owner_id: String) -> void:
	for shell_id: String in _mod_shells.keys():
		if _mod_shells[shell_id].get("owner", "") == owner_id:
			_mod_shells.erase(shell_id)


var _shell: RetroTVShell = null

# What is on the glass: the CRT stage, the phosphor trail, the stereo window, the
# aspect fit and the paint guard — see tv_display.gd.
var _display: TvDisplay = null

# Seating this set's nodes onto a shell — see tv_fit.gd.
var _fit: TvFit = null

@onready var _screen_mesh: MeshInstance3D = $ScreenMesh
@onready var _tube_collar: MeshInstance3D = $TubeCollar
## Composite 1's video socket. Kept as a named handle because that one socket is
## named from outside this script — a console's captive lead restores into it
## (system.gd::_snap_cable_to_tv), netplay names it, and the save file names it.
@onready var _composite_port: XRToolsSnapZone = $CompositePort
## Off unless the fitted shell carries a VgaPortSeat — see TvPanel.seat_vga_port.
@onready var _vga_port: XRToolsSnapZone = $VgaPort
## The aerial socket, Source.RF's one hole. Always fitted: every television has one,
## and unlike the VGA socket there is no cabinet in the project that would not.
@onready var _rf_port: XRToolsSnapZone = $RfPort
@onready var _ambilight: ScreenCastLight = $Ambilight
@onready var _mute_btn: VRButton = $MuteButton
@onready var _audio_mode_btn: VRButton = $AudioModeButton
@onready var _vol_down_btn: VRButton = $VolumeDownButton
@onready var _vol_up_btn: VRButton = $VolumeUpButton
@onready var _tv_toggle_btn: VRButton = $TVToggleButton
@onready var _crt_btn: VRButton = $CRTButton
@onready var _source_btn: VRButton = $SourceButton
@onready var _ch_down_btn: VRButton = $ChannelDownButton
@onready var _ch_up_btn: VRButton = $ChannelUpButton
@onready var _stereo_btn: VRButton = $StereoButton
@onready var _aspect_btn: VRButton = $AspectButton
@onready var _speaker_l: Marker3D = get_node_or_null("SpeakerL")
@onready var _speaker_r: Marker3D = get_node_or_null("SpeakerR")
@onready var _osd_label: Label3D = $ScreenMesh/OSDLabel
@onready var _vol_osd_label: Label3D = $ScreenMesh/VolumeOSDLabel
@onready var _osd_viewport: SubViewport = $OSDViewport
@onready var _osd_text_2d: Label = $OSDViewport/OSDText
@onready var _vol_osd_text_2d: Label = $OSDViewport/VolOSDText
@onready var _options_panel: TVOptionsPanel = $TVOptionsPanel


# Stereo wrapper for full-frame side-by-side sources (Virtual Boy): a
# screen_window material (left-eye window + eye_shift, CRT chained inside) that
# stays installed regardless of the CRT toggle, so the per-eye split never
# depends on the tube filter.

# Stereo presentation for stereo sources (the 3D bezel button, visible only
# while one is connected): 0 = per-eye stereo, 1 = left eye, 2 = right eye.
var stereo_mode: int = 0

## Picture shape. A CRT is a 4:3 tube, so that is the resting state and the one
## every source used to get by default — the frame was simply stretched to the
## glass, which squashed anything widescreen. Pressing the button shows the
## picture at 16:9 instead, letterboxed into the same tube.
##
## Deliberately a toggle between two fixed shapes rather than a mode cycle
## following what the core reports: which of the two a game wants is a thing the
## player can see, and a set of this era had exactly this button.
var widescreen: bool = false

const ASPECT_4_3 := 4.0 / 3.0
const ASPECT_16_9 := 16.0 / 9.0
const STEREO_MODE_NAMES := ["3D: STEREO", "3D: LEFT EYE", "3D: RIGHT EYE"]

## The set's speaker switch, in the OSD's own voice (it shouts).
const AUDIO_MODE_NAMES := ["STEREO", "MONO LEFT", "MONO RIGHT"]
## 0 stereo, 1 the left channel from both speakers, 2 the right from both.
var audio_mode: int = 0

# Phosphor persistence ping-pong (Shaders/phosphor_decay.gdshader). A viewport
# can't sample itself, so one renders while the other is read as "last frame".
@onready var _phosphor_a: SubViewport = $PhosphorA
@onready var _phosphor_b: SubViewport = $PhosphorB

# Tube face size in metres, read off the mesh in _ready. The phosphor pitch is a
# physical property of the glass, so the triad count is derived from this times
# scale_factor rather than being a fixed number of triads per UV.
var _screen_size_m := Vector2(0.35, 0.25)



# The corner banner and the volume bar — see tv_osd.gd.
var _osd: TvOsd = null

# Volume, mute and the speaker switch — see tv_audio.gd.
var _audio: TvAudio = null

# The back panel: its sockets, their legends, and which host is on which input —
# see tv_panel.gd.
var _panel: TvPanel = null
var _volume: float = 1.0       # 0.0–1.0, default 100%
var _tv_enabled: bool = true

# Selected input and the built-in tuner behind Source.TV. The tuner is created on
# first use rather than in _ready: most sets in a scene never leave the composite
# inputs, and an idle one should cost nothing (no VlcPlayer, no discovery traffic).
var current_source: int = Source.COMPOSITE_1
var _tuner: TVTuner = null

## Which channel the set is tuned to while Source.RF is showing — 3 or 4, stepped by
## the CH keys. A console fed through an RF switch only appears when this matches the
## channel its own switch is set to; anything else is static, as it would be.
var rf_channel: int = RF_CHANNELS[0]
# Snow for an untuned aerial channel; see TvDisplay.rf_static.

# Mute: silences the connected device's audio without changing _volume. A sticky
# "MUTE" OSD stays up until mute is toggled off or a volume key is pressed.
var _muted: bool = false

# Uniform display scale of the whole TV (1.0 = default set size). Adjusted from
# the TV options panel and persisted per-scene. Applied to the RigidBody root so
# the screen, bezel, buttons and cable port all scale together.
const MIN_SCALE := 0.2
const MAX_SCALE := 5.0
var scale_factor: float = 1.0
# Everything that follows from changing it — see tv_resize.gd.
var _resize: TvResize = null

# The "no signal" blue — shared by the screen texture and the ambilight tint.
const BLUE_SCREEN_COLOR := Color(0.0, 0.05, 0.65)
const STATIC_LIGHT_COLOR := Color(0.42, 0.44, 0.46)


## The helpers are built HERE and not in _ready, because _ready applies the
## authored size and wears the shell on its way past, and would find a null.
func _init() -> void:
	_resize = TvResize.new()
	_resize.name = "TvResize"
	add_child(_resize)
	_resize.setup(self)
	_fit = TvFit.new()
	_fit.name = "TvFit"
	add_child(_fit)
	_fit.setup(self)
	_osd = TvOsd.new()
	_osd.name = "TvOsd"
	add_child(_osd)
	_osd.setup(self)
	_audio = TvAudio.new()
	_audio.name = "TvAudio"
	add_child(_audio)
	_audio.setup(self)
	_panel = TvPanel.new()
	_panel.name = "TvPanel"
	add_child(_panel)
	_panel.setup(self)
	_display = TvDisplay.new()
	_display.name = "TvDisplay"
	add_child(_display)
	_display.setup(self)


func _ready() -> void:
	# Off its own cast lights' layer; see ScreenCastLight.SCREEN_LAYER.
	ScreenCastLight.mark_screen(_screen_mesh)
	super._ready()
	# Before the shell is worn, which re-seats every one of them.
	_panel.collect()
	# Before anything reads the screen mesh or the buttons — _screen_size_m below
	# is derived from ScreenMesh, and a shell may have moved and rescaled it.
	_fit.load_shell()
	# After the shell, so each legend is printed round wherever its group ended up,
	# and so a cabinet that carries fewer than four has already said so.
	_panel.disable_absent_inputs()
	_panel.print_legends()
	# The set defaults to Composite 1 and a cabinet need not have it, so land on one
	# it does before anything reads current_source. _seat_vga_port has already run
	# inside load_shell, which is what decides whether Composite 1 counts here.
	if not _source_available(current_source):
		current_source = _first_available_source()
	# TV = power: it runs the power-on animation and flashes POWER on the OSD.
	TransportGlyphs.label_buttons(self, {
		"MuteButton": "mute", "AudioModeButton": "audio_stereo",
		"VolumeDownButton": "vol_down", "VolumeUpButton": "vol_up",
		"TVToggleButton": "power", "CRTButton": "crt", "StereoButton": "stereo",
		"SourceButton": "source",
		"ChannelDownButton": "ch_down", "ChannelUpButton": "ch_up",
	}, TransportGlyphs.TV_SIZE)
	for i in COMPOSITE_INPUTS:
		var video := _panel.video_port(i)
		if video == null:
			continue
		video.has_picked_up.connect(_panel.on_plug_snapped.bind(i))
		video.has_dropped.connect(_panel.on_plug_released.bind(i))
	# The VGA socket announces the same way, on its own input. Connected whether or
	# not this shell uses it — a disabled zone never fires, so there is nothing to
	# gate.
	_vga_port.has_picked_up.connect(_panel.on_plug_snapped.bind(Source.VGA))
	_vga_port.has_dropped.connect(_panel.on_plug_released.bind(Source.VGA))
	_mute_btn.button_pressed.connect(_audio.on_mute_toggle)
	_audio_mode_btn.button_pressed.connect(_audio.on_mode_toggle)
	_vol_down_btn.button_pressed.connect(_audio.on_volume_down)
	_vol_up_btn.button_pressed.connect(_audio.on_volume_up)
	_tv_toggle_btn.button_pressed.connect(_on_tv_toggle)
	_crt_btn.button_pressed.connect(_on_crt_toggle)
	_stereo_btn.button_pressed.connect(_on_stereo_toggle)
	_aspect_btn.button_pressed.connect(toggle_aspect)
	_source_btn.button_pressed.connect(cycle_source)
	_ch_down_btn.button_pressed.connect(_on_channel_down)
	_ch_up_btn.button_pressed.connect(_on_channel_up)
	_vol_down_btn.set_color(Color(0.1, 0.3, 0.9))   # blue
	_vol_up_btn.set_color(Color(0.0, 0.9, 0.9))     # cyan
	_tv_toggle_btn.set_color(Color(0.0, 1.0, 0.0) if _tv_enabled
		else Color(1.0, 0.1, 0.1))
	_audio.update_mute_button()
	_audio.update_mode_button()
	# Hidden until a stereo source is connected (see TvDisplay.update_stereo_button).
	# VRButton._ready adds the pointable layer — strip it while hidden so the
	# invisible button can't eat pokes or laser clicks (deferred: our _ready
	# runs before the child button's).
	_stereo_btn.set_process(false)
	_stereo_btn.set_deferred("collision_layer", 0)
	_update_crt_button_color()
	_update_stereo_button_color()
	# The aspect cap prints its own state and tv.tscn authors it blank, so without
	# this the picture-shape key on the bezel is an unlabelled button until the
	# first press.
	_update_aspect_button()

	# Keep the chosen display size across pickups: xr-tools' grab driver is a
	# RemoteTransform3D that copies scale (forcing us back to 1x while held), so
	# disable its scale copy on grab and reassert our scale on drop.
	grabbed.connect(_on_tv_grabbed)
	dropped.connect(_on_tv_dropped)
	_resize.apply()
	_float_lock = FloatLock.attach(self, ignore_gravity)

	# Blue is the ON-with-no-signal look. The authored dark material only covers
	# the instant before the first process tick; OFF gets its own black texture in
	# the same glass shader as every live source, so reflections do not disappear
	# when the phosphors go dark.
	if _screen_mesh.mesh != null:
		var aabb := _screen_mesh.mesh.get_aabb()
		# get_aabb() is the MESH's own extent and ignores the node scale, which a
		# shell uses to size its tube (ScreenSeat carries the scale). Without this
		# a 90s cabinet reports the stock 0.35 x 0.25 screen and every consumer of
		# _screen_size_m — aspect fitting, OSD sizing — is wrong by that factor.
		var screen_scale := _screen_mesh.scale
		if aabb.size.x > 0.0 and aabb.size.y > 0.0:
			_screen_size_m = Vector2(aabb.size.x * screen_scale.x, aabb.size.y * screen_scale.y)
	if _ambilight:
		_ambilight.configure_screen(_screen_size_m * scale_factor, scale_factor)

	# Now the fitted tube's size is known. A shell that moved it without saying
	# where its speakers went gets them computed; everything else keeps the
	# markers exactly as authored.
	_fit.place_default_speakers()

	# The blue no-signal screen and the powered-off black.
	_display.build_states()






## The power state the display half of _process last ran for (-1 = never). The
## half runs every frame while the set is on and once more after it goes off, so
## the off frame still paints the dark glass, unlights it and douses the ambilight.
var _display_ran_powered: int = -1


func _process(_delta: float) -> void:
	var powered := 1 if _tv_enabled else 0
	var run_display := _tv_enabled or _display_ran_powered != powered
	if run_display:
		_display_ran_powered = powered
		_display.update_screen_source()
		_display.update_crt()
		_display.refresh_crt_derived()
		_display.update_phosphor()
		_osd.route()
	# Ungated: the 3D key follows the SOURCE, which can stop being stereo while
	# the set is off.
	_display.update_stereo_button()
	_resize.revalidate_park()

	# The tuner's sound comes out of this cabinet's own speakers, aimed the way
	# the tube points — a set heard from behind is muted by its own box.
	if _tuner != null and _tuner.is_active():
		_tuner.emit_through(self)

	# Grab-driver churn (second-hand grab, hand swap, desktop re-hold) recreates
	# the RemoteTransform3D with scale copying re-enabled, which stomps the TV
	# back to 1x — e.g. rotating a held TV with the other hand. Keep our chosen
	# size authoritative for the whole hold.
	if is_picked_up():
		_lock_grab_scale()
		if not scale.is_equal_approx(Vector3.ONE * scale_factor):
			scale = Vector3.ONE * scale_factor

	# An off set only has an ambilight to douse, and only while one is showing.
	if run_display or (_ambilight != null and _ambilight.visible):
		_display.tick_ambilight()




func set_crt_enabled(on: bool) -> void:
	crt_enabled = on
	_update_crt_button_color()
	NetworkManager.report_event(NetObjectSync.EV_TV_CRT, {"tv": self, "on": on})


func _on_crt_toggle() -> void:
	set_crt_enabled(not crt_enabled)


func _update_crt_button_color() -> void:
	if _crt_btn:
		_crt_btn.set_color(Color(1.0, 0.6, 0.1) if crt_enabled else Color(0.35, 0.35, 0.35))


## Cycle the stereo presentation: STEREO → LEFT → RIGHT → … (3D bezel button).
## TvDisplay.update_crt pushes the mode onto whichever shader is showing the source.
func set_stereo_mode(mode: int) -> void:
	stereo_mode = clampi(mode, 0, 2)
	_update_stereo_button_color()
	show_osd_timed(STEREO_MODE_NAMES[stereo_mode], 2.0)
	NetworkManager.report_event(NetObjectSync.EV_TV_STEREO,
		{"tv": self, "mode": stereo_mode})


func _on_stereo_toggle() -> void:
	set_stereo_mode((stereo_mode + 1) % 3)


# ── Picture shape (4:3 / 16:9) ────────────────────────────────────────────────

## The bezel button and the remote's, and what a save restores through.
func toggle_aspect() -> void:
	set_widescreen(not widescreen)


func set_widescreen(on: bool) -> void:
	widescreen = on
	_display.apply_aspect()
	_update_aspect_button()
	show_osd_timed("16:9" if widescreen else "4:3", 1.5)
	NetworkManager.report_event(NetObjectSync.EV_TV_ASPECT,
		{"tv": self, "on": widescreen})




func _update_aspect_button() -> void:
	if _aspect_btn == null:
		return
	var lbl := _aspect_btn.get_node_or_null("ButtonLabel") as Label3D
	if lbl:
		lbl.text = "16:9" if widescreen else "4:3"


func _update_stereo_button_color() -> void:
	if _stereo_btn:
		# Magenta = per-eye stereo; dimmer purple flavors for single-eye modes.
		match stereo_mode:
			0: _stereo_btn.set_color(Color(1.0, 0.2, 1.0))
			1: _stereo_btn.set_color(Color(0.55, 0.35, 0.75))
			2: _stereo_btn.set_color(Color(0.35, 0.35, 0.75))
	_update_stereo_button_glyph()




## Both eyes gets the 3D symbol; a single eye gets an eye leaning to the side it
## is showing, so the cap says which one without a word on it.
func _update_stereo_button_glyph() -> void:
	match stereo_mode:
		0: TransportGlyphs.set_glyph(self, "StereoButton", "stereo", TransportGlyphs.TV_SIZE)
		1: TransportGlyphs.set_glyph(self, "StereoButton", "eye", TransportGlyphs.TV_SIZE, -1.0)
		2: TransportGlyphs.set_glyph(self, "StereoButton", "eye", TransportGlyphs.TV_SIZE, 1.0)




## World positions of the set's left and right speakers, in that order. See
## tv_fit.gd; speaker_pair.gd and the spatial emitters call this by name.
func get_speaker_positions() -> PackedVector3Array:
	return _fit.speaker_positions()


## Which way the picture faces. Sound leaves a set the same way it does, so
## anything giving these speakers a directivity aims them along this. Normalised,
## unlike the offsets above, because it is a direction rather than a distance.
func get_screen_normal() -> Vector3:
	return global_transform.basis.z.normalized()


## The set's own up, to go with get_screen_normal when a pose is wanted.
func get_screen_up() -> Vector3:
	return global_transform.basis.y.normalized()


# ── On-screen display ──────────────────────────────────────────────────────────
# The three names below stay on the set because the DVD and VCR call them on
# whatever they are cabled to without checking what it is, and speaker_pair.gd
# implements the same three to absorb that. See tv_osd.gd.

## Show a persistent OSD message (stays until replaced or hidden).
func show_osd(text: String) -> void:
	_osd.show_text(text)


## Show an OSD message that auto-hides after `seconds` (unless superseded).
func show_osd_timed(text: String, seconds: float) -> void:
	_osd.show_text_timed(text, seconds)


## Clear the OSD.
func hide_osd() -> void:
	_osd.clear()


# ── Back panel ─────────────────────────────────────────────────────────────────
# The seven names below stay on the set because a cabled device calls them on
# whatever it is joined to. rca_port.gd reaches on_av_topology_changed through
# has_method(), so the set has to answer it itself. See tv_panel.gd.

## Snaps a captive cable plug into one of this TV's video sockets (used by save/load
## and netplay to restore connections). Defaults to Composite 1, which is where a
## caller that has no opinion — and every save written before there were four — means.
func accept_plug_restore(plug: CablePlug, input: int = Source.COMPOSITE_1) -> void:
	_panel.accept_plug_restore(plug, input)


## Drop whatever captive lead is in one input's video socket.
func release_input(input: int = Source.COMPOSITE_1) -> void:
	_panel.release_input(input)


## The L and R sockets of one composite input, in that order.
func audio_ports(input: int) -> Array:
	return _panel.audio_ports(input)


## Which socket ANYWHERE on this set is holding `plug` — audio as well as video.
func socket_holding(plug: Node3D) -> XRToolsSnapZone:
	return _panel.socket_holding(plug)


## Which video socket is holding `plug`, or null.
func port_holding(plug: Node3D) -> XRToolsSnapZone:
	return _panel.port_holding(plug)


## Which INPUT is holding `plug`, for a host writing itself to a save file.
func input_holding(plug: Node3D) -> int:
	return _panel.input_holding(plug)


## Called by a deck that has worked out it is feeding this set through a composite
## lead.
func on_av_source_found(source: Node3D) -> void:
	_panel.source_found(source)


## Called by that deck when the last cord between the two is pulled.
func on_av_source_lost(source: Node3D) -> void:
	_panel.source_lost(source)


## Nothing to do here: a set is a sink, and every routing decision is the source's.
## It exists so RcaPort.get_device() recognises a television as a device at all —
## that is the whole of the interface.
func on_av_topology_changed(_links: Array) -> void:
	pass


# Remote-control entry points (TVRemote): identical to pressing the bezel
# buttons, so the volume label / power button color stay in sync.

func remote_power_toggle() -> void:
	_on_tv_toggle()


func remote_volume_up() -> void:
	_audio.on_volume_up()


func remote_volume_down() -> void:
	_audio.on_volume_down()


func remote_mute_toggle() -> void:
	_audio.on_mute_toggle()


func remote_source_cycle() -> void:
	cycle_source()


func remote_channel_up() -> void:
	if _tuner and current_source == Source.TV:
		_tuner.channel_up()
		_report_channel_state()


func remote_channel_down() -> void:
	if _tuner and current_source == Source.TV:
		_tuner.channel_down()
		_report_channel_state()


# Bezel channel keys. Unlike the remote's — which only appear once the tuner is
# the selected input, because the SOURCE key is right beside them — these are
# moulded into the cabinet and are always there. A physical CH key that does
# nothing on the wrong input would just read as broken, so pressing one selects
# the tuner first, exactly as a real set does.

func _on_channel_up() -> void:
	_select_tv_then(true)


func _on_channel_down() -> void:
	_select_tv_then(false)


func _select_tv_then(up: bool) -> void:
	if not _tv_enabled:
		return
	# On the aerial input the CH keys do what they would on a real set fed by an RF
	# switch: step between the two channels the switch can occupy, rather than
	# abandoning the input the viewer just chose to go and find the tuner.
	if current_source == Source.RF:
		var i := RF_CHANNELS.find(rf_channel)
		var n := RF_CHANNELS.size()
		rf_channel = RF_CHANNELS[((i if i >= 0 else 0) + (1 if up else n - 1)) % n]
		_audio.apply_volume()
		show_osd_timed(_source_banner(), 2.0)
		_report_channel_state()
		return
	if current_source != Source.TV:
		set_source(Source.TV)
		# set_source already tuned whatever channel was last on, so the press that
		# switched inputs is not also a channel step -- pressing CH+ from the
		# component input lands you on the tuner, not one past it.
		return
	if up:
		_ensure_tuner().channel_up()
	else:
		_ensure_tuner().channel_down()
	_report_channel_state()


## Options-panel channel selection uses the same replicated state as the bezel
## and remote buttons instead of mutating the tuner behind ObjectSync's back.
func set_channel_index(index: int) -> void:
	if current_source != Source.TV:
		set_source(Source.TV)
	_ensure_tuner().tune(index)
	_report_channel_state()


func _report_channel_state() -> void:
	NetworkManager.report_event(NetObjectSync.EV_TV_CHANNEL, {
		"tv": self,
		"source": current_source,
		"rf": rf_channel,
		"index": _tuner.current_index if _tuner != null else -1,
	})


## Apply one explicit channel state. Sending the result rather than only UP/DOWN
## makes the operation self-healing if a peer joined with a stale tuner index.
func net_set_channel_state(source: int, rf: int, index: int) -> void:
	set_source(source)
	rf_channel = rf if RF_CHANNELS.has(rf) else RF_CHANNELS[0]
	if current_source == Source.TV and index >= 0:
		_ensure_tuner().tune(index)
	_audio.apply_volume()
	show_osd_timed(_source_banner(), 2.0)


# ── Input selection (SOURCE) ──────────────────────────────────────────────────

## Step to the next input, wrapping. The SOURCE key on the bezel and the remote.
##
## Composite inputs this cabinet has no sockets for are stepped straight past: the
## cycle is a tour of what you can actually plug something into, and stopping on an
## input with no socket would read as the key being broken.
func cycle_source() -> void:
	var next := current_source
	# Step until something this cabinet actually has turns up. Bounded by the number
	# of inputs, so a set that somehow had none cannot spin here.
	for i in SOURCE_NAMES.size():
		next = (next + 1) % SOURCE_NAMES.size()
		if _source_available(next):
			break
	set_source(next)


## Whether this cabinet can show a given input at all.
##
## A composite input needs a socket on the back panel; the aerial input needs the
## coax hole. The tuner needs neither and is always there, which is what makes it
## the safe fallback in set_source.
func _source_available(source: int) -> bool:
	if source < COMPOSITE_INPUTS:
		return source < _panel.panel_inputs()
	if source == Source.RF:
		return _panel.has_aerial()
	if source == Source.VGA:
		return _vga_port != null and _vga_port.enabled
	return true


## The first input this cabinet has, for a set asked to show one it does not.
##
## The tuner is tried LAST despite sitting mid-enum: it is available on every set,
## so first-hit-in-enum-order would sit a computer monitor on a channel list rather
## than on the machine cabled to its only socket. Every set with a phono row still
## lands on Composite 1, which is what it always did.
func _first_available_source() -> int:
	for i in SOURCE_NAMES.size():
		if i != Source.TV and _source_available(i):
			return i
	return Source.TV


## Select an input. Idempotent, so panels can call it freely.
func set_source(source: int) -> void:
	source = clampi(source, 0, SOURCE_NAMES.size() - 1)
	# A cabinet without the socket cannot show that input. Fall back to the first it
	# DOES have rather than to Composite 1 — that used to be safe because every
	# cabinet carried at least one phono input, and the computer monitor carries
	# none, so the old fallback sent it to an input that is not there.
	if not _source_available(source):
		source = _first_available_source()
	if source == current_source:
		return
	current_source = source

	# Nothing to hand over, and nothing to clear first: the set reads the new
	# input's picture on the next frame, or paints its own no-signal. What stood
	# here blanked the glass BEFORE the incoming host could take it, because a host
	# installed its material once and anything painted afterwards was the last word
	# — "switch to the input the console is on and the picture disappears, until you
	# pull its plug and put it back in the same socket".

	# Sound still has to be told: only the picture is pulled. Without this the input
	# you just left goes on being heard.
	_audio.apply_volume()

	if current_source == Source.TV:
		_ensure_tuner()
		_tuner.set_active(_tv_enabled)
	elif _tuner:
		_tuner.set_active(false)

	show_osd_timed(_source_banner(), 2.0)
	NetworkManager.report_event(NetObjectSync.EV_TV_SOURCE,
		{"tv": self, "source": current_source})


func _source_banner() -> String:
	if current_source == Source.TV and _tuner:
		var banner := _tuner.status_banner()
		if not banner.is_empty():
			return "TV  %s" % banner
	if current_source == Source.RF:
		# The channel is half the state on this input, so it belongs in the banner —
		# and NO SIGNAL is the difference between "nothing is plugged in" and "you
		# are on the wrong one of two channels", which the static alone cannot say.
		return "RF  CH %d%s" % [rf_channel, "" if _panel.rf_tuned() else "  NO SIGNAL"]
	return SOURCE_NAMES[current_source]


## The tuner is built on first use — a set that never leaves COMPONENT should not
## pay for a VlcPlayer instance or send discovery traffic.
func _ensure_tuner() -> TVTuner:
	if _tuner == null:
		_tuner = TVTuner.new()
		_tuner.name = "TVTuner"
		_tuner.status_changed.connect(_on_tuner_status)
		add_child(_tuner)
		_tuner.reload_channels()
		_tuner.set_volume(_audio.volume_for(Source.TV))
		_tuner.set_channel_mode(audio_mode)
	return _tuner


func _on_tuner_status(banner: String) -> void:
	if current_source != Source.TV:
		return
	if banner.is_empty():
		hide_osd()
	elif _tuner and not _tuner.error_text().is_empty():
		# A fault stays up: it is the only explanation for what is on the glass.
		show_osd(banner)
	else:
		show_osd_timed(banner, 3.0)


## The tuner, built if this is the first ask. Used by the options panel.
func get_tuner() -> TVTuner:
	return _ensure_tuner()


## Whether the tuner exists AND has a channel list — without building one.
## Callers that merely want to know (the remote, greying its channel keys) must
## use this: get_tuner() would spin up a VlcPlayer and start discovery just
## because somebody pointed a remote at the set.
func has_channels() -> bool:
	return _tuner != null and not _tuner.channels.is_empty()


func get_source() -> int:
	return current_source


## Complete user-facing control state for save files and netplay snapshots.
func get_control_state() -> Dictionary:
	return {
		"enabled": _tv_enabled,
		"volume": _volume,
		"muted": _muted,
		"widescreen": widescreen,
		"source": current_source,
		"rf_channel": rf_channel,
		"channel_index": _tuner.current_index if _tuner != null else -1,
		"audio_mode": audio_mode,
	}


## Restore after the TV is in the tree, so buttons, materials, audio routes and
## the optional tuner all receive the state rather than only its backing fields.
func restore_control_state(state: Dictionary) -> void:
	_volume = clampf(float(state.get("volume", _volume)), 0.0, 1.0)
	_muted = bool(state.get("muted", _muted))
	_tv_enabled = bool(state.get("enabled", _tv_enabled))
	widescreen = bool(state.get("widescreen", widescreen))
	audio_mode = clampi(int(state.get("audio_mode", audio_mode)), 0, 2)
	rf_channel = int(state.get("rf_channel", rf_channel))
	if not RF_CHANNELS.has(rf_channel):
		rf_channel = RF_CHANNELS[0]
	set_source(int(state.get("source", current_source)))
	var index := int(state.get("channel_index", -1))
	if current_source == Source.TV and index >= 0:
		_ensure_tuner().tune(index)
	_tv_toggle_btn.set_color(Color(0.0, 1.0, 0.0) if _tv_enabled
		else Color(1.0, 0.1, 0.1))
	_audio.update_mute_button()
	_audio.update_mode_button()
	_update_aspect_button()
	_display.apply_aspect()
	if _tuner != null:
		_tuner.set_active(_tv_enabled and current_source == Source.TV)
	_audio.apply_channel_mode()
	_audio.apply_volume()


# ── Options panel / display scale ────────────────────────────────────────────────

## Toggle the floating TV settings panel. Called by SpawnMenuController when the
## menu button is pressed while pointing at this TV (mirrors PDFBook/VCRPlayer).
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel == null:
		return
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)


## Current display scale (1.0 = default). Read by the TV options panel.
func get_scale_factor() -> float:
	return scale_factor




## Set the TV's uniform display scale, clamped to [MIN_SCALE, MAX_SCALE].
##
## The clamp is the whole of this set's contribution; what a size CHANGE then
## costs the room — pinning the base, carrying whatever was standing on top,
## parking a set jammed against a wall — lives in TvResize.
func set_tv_scale(factor: float) -> void:
	scale_factor = clampf(factor, MIN_SCALE, MAX_SCALE)
	_resize.apply()
	if _ambilight:
		_ambilight.configure_screen(_screen_size_m * scale_factor, scale_factor)


func _on_tv_grabbed(_pickable: Node3D, _by: Node3D) -> void:
	# Picking the set up ends the park. XRToolsPickable has already snapshotted
	# freeze into restore_freeze by the time `grabbed` fires and its release_mode is
	# ORIGINAL, so it would restore OUR freeze on release and leave the set hanging
	# wherever it was let go — correct the snapshot, not just the flag.
	if _resize.clear_park():
		restore_freeze = false
	# The grab driver is created during the grab; stop it copying scale so the
	# TV keeps its size while held (deferred so the driver exists first).
	call_deferred("_lock_grab_scale")


func _lock_grab_scale() -> void:
	if _grab_driver != null and "update_scale" in _grab_driver:
		_grab_driver.update_scale = false


func _on_tv_dropped(_pickable: Node3D) -> void:
	# Safety net: reassert our scale in case the release disturbed it.
	_resize.apply()


## True when the TV is switched on (used by the remote's POWER cell tint).
func is_powered_on() -> bool:
	return _tv_enabled


## True when audio is muted (used by the remote's MUTE cell tint).
func is_muted() -> bool:
	return _muted


## Cycle the speaker switch. Stays on the set because object_sync replays it by
## name on a peer and the remote's own key calls it. See tv_audio.gd.
func set_audio_mode(mode: int) -> void:
	_audio.set_mode(mode)




## Hand the glass to the selected input and take it off every other one.
##
## The same call covers SOURCE and POWER, which want the identical rule: exactly one
## host may paint, and only while the set is on. Without it a deselected console goes
## on writing its material onto the screen every frame and the two fight.
##
## Two passes, and the order is load-bearing. Releasing the mesh restores the material
## the releasing host found on it, so a host let go AFTER the selected one has taken
## the screen writes its own idea of "before" over the new picture. Index order is not
## selection order — going to Composite 1 from Composite 2 releases second — so a
## single pass silently depends on which way the viewer happened to be switching.
# _apply_screen_enable is gone with the push. Telling every host whether it was
# the one showing — in two passes, in an order that mattered, latched on the host's
# side so a machine that was off still heard it — was the whole cost of hosts
# painting. The set reads the selected input's picture, or paints its own blank.


## Which socket input is selected, or -1 while the tuner is showing.
##
## Tested against Source.TV rather than against COMPOSITE_INPUTS: RF is past the
## composite block but it is still an input with a host on it, and a bound of
## COMPOSITE_INPUTS would hide that host from _selected_system — which is what owns
## the volume keys and the power button.
func _selected_input() -> int:
	return -1 if current_source == Source.TV else current_source





## The connected console's channel switch moved. Repaint, because the same switch
## position decides whether there is a picture at all and this is the only thing
## that tells the set it changed.
func on_rf_channel_changed() -> void:
	if current_source != Source.RF:
		return
	_audio.apply_volume()
	show_osd_timed(_source_banner(), 2.0)






func _on_tv_toggle() -> void:
	_tv_enabled = not _tv_enabled
	_tv_toggle_btn.set_color(Color(0.0, 1.0, 0.0) if _tv_enabled else Color(1.0, 0.1, 0.1))
	if _tv_enabled:
		_display.play_power_on_anim()
		# Coming back on while muted keeps the sticky MUTE indicator, otherwise
		# show the usual POWER flash.
		if _muted:
			show_osd("MUTE")
		else:
			show_osd_timed("POWER", 3.0)
	else:
		_display.stop_power_on_anim()
		hide_osd()
		_osd.clear_volume()
	# Powering back on must not un-mute a composite input while the set is showing
	# the tuner (or another input) -- it would start repainting the screen underneath.
	if _tuner:
		_tuner.set_active(_tv_enabled and current_source == Source.TV)
	_audio.apply_volume()
	NetworkManager.report_event(NetObjectSync.EV_TV_POWER, {"tv": self})


## Ignore-gravity: the device floats where it is put instead of falling. Restored
## from a save through this flag, which FloatLock reads once at _ready.
var ignore_gravity: bool = false
var _float_lock: FloatLock = null


func get_ignore_gravity() -> bool:
	return _float_lock != null and _float_lock.enabled


func set_ignore_gravity(on: bool) -> void:
	ignore_gravity = on
	if _float_lock != null:
		_float_lock.set_enabled(on)


# ── The glass ──────────────────────────────────────────────────────────────────
# The names below stay on the set because they are its public face: the options
# panel and scene_persistence drive the CRT sliders, and the C++ video handler and
# both decks ask for the screen and the paint guard. See tv_display.gd.

## Returns the screen MeshInstance3D so Libretro can render onto it.
func get_screen_mesh() -> MeshInstance3D:
	return _display.get_screen_mesh()


## Whether `who` is allowed to put a material on the glass right now.
func can_paint(who: Object) -> bool:
	return _display.can_paint(who)


## Take the glass, if the guard allows it.
func paint_screen(who: Object, mat: Material) -> bool:
	return _display.paint_screen(who, mat)


## Give the glass back. Only the current owner may.
func release_screen(who: Object) -> void:
	_display.release_screen(who)


## One CRT authoring value.
func set_crt_param(pname: String, value: Variant) -> void:
	_display.set_crt_param(pname, value)


## Every CRT authoring value, for the options panel and the save file.
func get_crt_params() -> Dictionary:
	return _display.get_crt_params()


func set_crt_params(values: Dictionary) -> void:
	_display.set_crt_params(values)


## True when the showing source is handing over a side-by-side stereo frame.
func has_stereo_source() -> bool:
	return _display.has_stereo_source()
