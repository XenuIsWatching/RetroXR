## TV — pickable television with a screen surface and a composite video input port.
class_name RetroTV
extends XRToolsPickable




const CRT_SHADER := preload("res://Shaders/crt_effect.gdshader")
const VCR_SHADER := preload("res://Shaders/vcr_effect.gdshader")
# Dual-screen handhelds mirror one channel of their composite framebuffer onto
# the TV through this shader; the CRT stage chains inside it like the VCR's.
const WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")
# Analog snow, shown by the built-in tuner for every failure. Named here too
# because _route_osd and _update_crt both have to recognise it on the screen.
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
## _load_shell() is then a strict no-op — the arcade and den TVs must render
## bit-identically to before this system existed.
@export var tv_model: String = ""

## Cabinet variants. A shell supplies geometry plus Marker3D seats; every
## functional node stays on this TV. See Scripts/Objects/tv/tv_shell.gd.
const _SHELL_SCENES := {
	"crt_90s":     "res://Scenes/Objects/tv_models/crt_90s.tscn",
	"crt_monitor": "res://Scenes/Objects/tv_models/crt_monitor.tscn",
	"crt_plain":   "res://Scenes/Objects/tv_models/crt_plain.tscn",
}

var _shell: RetroTVShell = null

# Whether the worn shell named speaker seats. False means the markers still hold
# the stock body's positions and _ready recomputes them for the fitted tube.
var _speakers_seated: bool = false

@onready var _screen_mesh: MeshInstance3D = $ScreenMesh
## Composite 1's video socket. Kept as a named handle because that one socket is
## named from outside this script — a console's captive lead restores into it
## (system.gd::_snap_cable_to_tv), netplay names it, and the save file names it.
@onready var _composite_port: XRToolsSnapZone = $CompositePort
## Every A/V input socket, [input][VIDEO, L, R]. Filled by _collect_av_ports from
## the scene's fixed names, and seated as whole GROUPS rather than left where
## tv.tscn put them — see _seat_av_row.
var _av_ports: Array = []
## Off unless the fitted shell carries a VgaPortSeat — see _seat_vga_port.
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

# CRT wrap state: the ShaderMaterial we install over the source material, and
# the source material we replaced (restored when the filter turns off).
var _crt_material: ShaderMaterial = null

# Stereo wrapper for full-frame side-by-side sources (Virtual Boy): a
# screen_window material (left-eye window + eye_shift, CRT chained inside) that
# stays installed regardless of the CRT toggle, so the per-eye split never
# depends on the tube filter.
var _stereo_material: ShaderMaterial = null

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

# Tunable CRT display-stage uniforms (crt_filter.gdshaderinc). Adjustable from
# the TV options panel; applied to whichever material carries the CRT stage (our
# wrapper or the chained VCR shader). Defaults mirror the shader's own defaults.
#
# crt_mask_pitch_mm and crt_persistence are NOT shader uniforms — they're the
# authoring values behind ones that are (see _apply_derived_crt_params and
# _update_phosphor).
var _crt_params := {
	"crt_curvature": 0.0,          # geometry now — see Tools/gen_curved_screen.gd
	"crt_corner_radius": 0.04,
	"crt_mask_mode": 1,
	"crt_mask_strength": 0.55,
	"crt_mask_pitch_mm": 2.0,
	"crt_scanline_strength": 0.6,
	"crt_beam_min": 0.18,
	"crt_beam_max": 0.35,
	"crt_gamma": 1.09,
	"crt_halation": 0.08,
	"crt_glow_radius": 6.0,
	"crt_notch": 0.0,
	"crt_persistence": 0.3,
	"crt_grain": 0.1,
	"crt_smear": 0.0,
	"crt_wiggle": 0.0,
	"crt_vignette": 0.18,
	"crt_brightness": 1.0,
	"crt_glass_reflection": 0.35,
	"crt_glass_roughness": 0.12,
	"crt_glass_wear": 0.35,
}

# Phosphor persistence ping-pong (Shaders/phosphor_decay.gdshader). A viewport
# can't sample itself, so one renders while the other is read as "last frame".
@onready var _phosphor_a: SubViewport = $PhosphorA
@onready var _phosphor_b: SubViewport = $PhosphorB
var _phosphor_write_a: bool = true
## Frames for which the accumulator must ignore its own history, counted down one
## per buffer because it ping-pongs between two and BOTH hold the old picture.
##
## Nothing used to reset it, so the decayed image of whatever was on the glass
## before survived an input change, a machine being switched off and a reset —
## reset a console on Composite 2 and the last thing Composite 1 was showing came
## back for a moment before the BIOS did.
var _phosphor_fresh: int = 0
# The raw picture texture we wrapped, kept because _crt_material's source_tex is
# replaced by the accumulator once persistence is running.
var _crt_source_tex: Texture2D = null
# Signature of the inputs to _apply_derived_crt_params, so the per-frame refresh
# only touches the material when one of them actually moved.
var _crt_derived_key: String = ""

# Tube face size in metres, read off the mesh in _ready. The phosphor pitch is a
# physical property of the glass, so the triad count is derived from this times
# scale_factor rather than being a fixed number of triads per UV.
var _screen_size_m := Vector2(0.35, 0.25)

# TV-owned screen states: blue "no signal" (ON with no live input) and black
# phosphors behind reflective glass (OFF).
var _blue_texture: Texture2D = null
var _dark_texture: Texture2D = null
var _dark_material: ShaderMaterial = null

# CRT power-on animation (thin horizontal line expanding to full height).
var _poweron_tween: Tween = null

# Bumped each time an OSD message is shown or hidden so a stale auto-hide timer
# from a previous message can't clear a newer one.
var _osd_token: int = 0
# Same, for the independent volume-bars OSD at the bottom of the screen.
var _vol_osd_token: int = 0

# The captive lead seated in each input's video socket, so a disconnect knows
# which host to tell. One entry per composite input, indexed by it.
var _snapped_plugs: Array = []

# What is feeding each composite input, indexed by it. A host is any node
# implementing the TV contract (on_tv_connected/on_tv_disconnected/
# set_audio_volume/set_screen_enabled) — a RetroSystem or a VCRPlayer — so the
# entries are typed loosely.
#
# Four of them because the set has four sockets and a player can leave a console on
# one while watching another: everything that used to be "the connected system" is
# now "the system on the input SOURCE has selected" (_selected_system) or "every
# system, told whether it is the one showing" (_apply_screen_enable).
var _connected_systems: Array = []
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
# Snow for an untuned aerial channel; see _rf_static.
var _rf_static_material: ShaderMaterial = null

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


## The resize helper is built HERE and not in _ready, because _ready applies the
## authored size on its way past and would find a null.
func _init() -> void:
	_resize = TvResize.new()
	_resize.name = "TvResize"
	add_child(_resize)
	_resize.setup(self)


func _ready() -> void:
	super._ready()
	# Before _load_shell, which re-seats every one of them.
	_collect_av_ports()
	# Before anything reads the screen mesh or the buttons — _screen_size_m below
	# is derived from ScreenMesh, and a shell may have moved and rescaled it.
	_load_shell()
	# After the shell, so each legend is printed round wherever its group ended up,
	# and so a cabinet that carries fewer than four has already said so.
	_disable_absent_inputs()
	_print_av_legends()
	# The set defaults to Composite 1 and a cabinet need not have it, so land on one
	# it does before anything reads current_source. _seat_vga_port has already run
	# inside _load_shell, which is what decides whether Composite 1 counts here.
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
		var video := _video_port(i)
		if video == null:
			continue
		video.has_picked_up.connect(_on_plug_snapped.bind(i))
		video.has_dropped.connect(_on_plug_released.bind(i))
	# The VGA socket announces the same way, on its own input. Connected whether or
	# not this shell uses it — a disabled zone never fires, so there is nothing to
	# gate.
	_vga_port.has_picked_up.connect(_on_plug_snapped.bind(Source.VGA))
	_vga_port.has_dropped.connect(_on_plug_released.bind(Source.VGA))
	_mute_btn.button_pressed.connect(_on_mute_toggle)
	_audio_mode_btn.button_pressed.connect(_on_audio_mode_toggle)
	_vol_down_btn.button_pressed.connect(_on_volume_down)
	_vol_up_btn.button_pressed.connect(_on_volume_up)
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
	_update_mute_button_color()
	_update_audio_mode_button()
	# Hidden until a stereo source is connected (see _update_stereo_button).
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
	if _shell != null and not _speakers_seated:
		_place_default_speakers()

	# A texture rather than a material: the no-signal screen is SAMPLED like every
	# other picture, so it goes through the tube stage instead of being a flat
	# rectangle of blue over a curved glass.
	var blue_img := Image.create(2, 2, false, Image.FORMAT_RGB8)
	blue_img.fill(BLUE_SCREEN_COLOR)
	_blue_texture = ImageTexture.create_from_image(blue_img)
	var dark_img := Image.create(2, 2, false, Image.FORMAT_RGB8)
	dark_img.fill(Color.BLACK)
	_dark_texture = ImageTexture.create_from_image(dark_img)
	_dark_material = ShaderMaterial.new()
	_dark_material.shader = CRT_SHADER
	_dark_material.set_shader_parameter("source_tex", _dark_texture)
	_dark_material.set_shader_parameter("crt_enabled", crt_enabled)
	_apply_crt_params(_dark_material)


## Wear a cabinet variant. Strict no-op when tv_model is empty — that is the
## acceptance test for this whole mechanism, since the arcade and den TVs must
## look and behave exactly as they did before.
##
## Only nodes the shell actually names a seat for are moved; everything else keeps
## its tv.tscn pose, so a shell describes differences rather than the whole layout.
func _load_shell() -> void:
	if tv_model.is_empty():
		return
	var path: String = _SHELL_SCENES.get(tv_model, "")
	if path.is_empty():
		push_warning("RetroTV: unknown tv_model '%s' — falling back to the stock body" % tv_model)
		return
	var packed := load(path) as PackedScene
	if packed == null:
		push_warning("RetroTV: failed to load shell scene: %s" % path)
		return
	_shell = packed.instantiate() as RetroTVShell
	if _shell == null:
		push_warning("RetroTV: shell scene root is not a RetroTVShell: %s" % path)
		return
	add_child(_shell)
	$TVBody.hide()

	_seat_node(_screen_mesh, _shell.screen_seat())
	_seat_av_row(_shell.port_seat())
	_seat_vga_port(_shell.vga_port_seat())
	_seat_node(_ambilight, _shell.ambilight_seat())

	# Both or neither: one seated speaker and one still on the stock tube's edge
	# would be a lopsided stereo image nobody authored. _ready falls back to the
	# computed pair when this stays false.
	var spk_l: Variant = _shell.speaker_l_seat()
	var spk_r: Variant = _shell.speaker_r_seat()
	_speakers_seated = spk_l is Transform3D and spk_r is Transform3D
	if _speakers_seated:
		_seat_node(_speaker_l, spk_l)
		_seat_node(_speaker_r, spk_r)

	# Bezel buttons march along the row marker's local +X from the first cap, and
	# wrap onto a second row below it. Same order the stock cabinet authors, so a
	# shelled set and the plain box read alike.
	var row: Variant = _shell.button_row_seat()
	var buttons: Array[Node3D] = _bezel_buttons()
	if not _shell.show_button_row:
		for btn in buttons:
			(btn as VRButton).set_active(false)
	elif row is Transform3D:
		var base: Transform3D = row
		var per_row: int = maxi(1, _shell.buttons_per_row)
		for i in buttons.size():
			var b: Node3D = buttons[i]
			# Keep each cap's authored basis (they are rotated to face outward);
			# only the origin walks the row.
			@warning_ignore("integer_division")
			b.transform = Transform3D(b.transform.basis, base * Vector3(
				float(i % per_row) * _shell.button_pitch,
				float(i / per_row) * -_shell.button_row_drop,
				0.0))

	_resize_body_collision(_shell.body_size)


## The bezel caps in the order they are laid out, reading left to right and then
## down. The everyday controls of the set fill the first row; the picture and
## sound MODES — the ones you set once and leave — go on the second.
##
## 3D comes LAST on purpose. It is the one cap that comes and goes (only a
## stereo source has anything for it to switch), and a hidden button still owns
## its slot — anywhere else in the order it leaves a hole in the middle of the
## row that reads as a missing control. At the end it simply is not there.
##
## Mute and the speaker switch used to sit outside this list, so a shell moved
## nine caps onto its marker and left those two wherever the stock cabinet had
## put them. One list now, and both paths read it.
func _bezel_buttons() -> Array[Node3D]:
	return [
		_tv_toggle_btn, _source_btn, _ch_down_btn, _ch_up_btn,
		_vol_down_btn, _vol_up_btn, _mute_btn,
		_audio_mode_btn, _crt_btn, _aspect_btn, _stereo_btn,
	]


func _seat_node(node: Node3D, seat: Variant) -> void:
	if node != null and seat is Transform3D:
		node.transform = seat


## Centre-to-centre along the A/V row. The pitch the primitive console, the NES, the
## PC tower and both decks already use, so a lead reaches a set's sockets exactly as
## it reaches a deck's.
const AV_ROW_PITCH := 0.018

## Centre-to-centre between one input group and the next. Wider than AV_ROW_PITCH by
## more than the printed legend is wide (57.6 mm at the authored text sizes), so the
## four plates stand clear of each other instead of overlapping — and wide enough
## that no socket sits closer to its neighbour in the next group than to the ones in
## its own, which is what makes the grouping readable at arm's length.
const AV_GROUP_PITCH := 0.06


## The A/V sockets, gathered from the scene's fixed names into [input][VIDEO, L, R].
##
## Composite 1 keeps the unsuffixed names it has always had — a console's captive
## lead, netplay and the save file all name "CompositePort" — and the rest count up
## from 2, so the numbering on the wire matches the numbering printed on the panel.
func _collect_av_ports() -> void:
	_av_ports = []
	_connected_systems = []
	_snapped_plugs = []
	for i in COMPOSITE_INPUTS:
		var suffix := "" if i == 0 else str(i + 1)
		var trio: Array[RcaPort] = []
		for base in ["CompositePort", "AudioLIn", "AudioRIn"]:
			var port := get_node_or_null(base + suffix) as RcaPort
			if port == null:
				push_warning("[RetroTV] missing A/V socket %s%s" % [base, suffix])
				continue
			trio.append(port)
		_av_ports.append(trio)
		_connected_systems.append(null)
		_snapped_plugs.append(null)
	# Two more slots so all three arrays stay indexable by Source over their WHOLE
	# range and not just the composite part of it — _input_for_device returns a
	# Source and everything downstream indexes with it.
	#
	# TV owns no sockets, so its entry is an empty trio; _video_port already guards
	# for that, and its connected-system slot stays null because a tuner is not a
	# connected system. RF owns exactly one, and it is a VIDEO socket, so it sits at
	# index 0 of its trio where _video_port looks.
	_av_ports.append([] as Array[RcaPort])
	_connected_systems.append(null)
	_snapped_plugs.append(null)
	var rf := _rf_port as RcaPort
	var rf_trio: Array[RcaPort] = []
	if rf != null:
		rf_trio.append(rf)
	else:
		push_warning("[RetroTV] missing aerial socket RfPort")
	_av_ports.append(rf_trio)
	_connected_systems.append(null)
	_snapped_plugs.append(null)
	# And the DE-15, which is an input in its own right rather than an alias for
	# Composite 1. As that alias it announced "COMPOSITE 1" on a cabinet with no
	# phono row at all, and a set carrying both would have had them share one slot,
	# so plugging either would evict the other. Its socket IS an RcaPort (VgaPort
	# extends it), so it needs no special case anywhere that walks these.
	var vga_trio: Array[RcaPort] = []
	var vga := _vga_port as RcaPort
	if vga != null:
		vga_trio.append(vga)
	_av_ports.append(vga_trio)
	_connected_systems.append(null)
	_snapped_plugs.append(null)


## How many composite inputs this cabinet actually carries sockets for. The stock
## body and both televisions take all four; a shell with a smaller back panel says so.
func _panel_inputs() -> int:
	if _shell == null:
		return COMPOSITE_INPUTS
	# Floored at ZERO, not at one: a cabinet is allowed to carry no phono sockets at
	# all, and the computer monitor is one. See TVShell.av_inputs.
	return clampi(_shell.av_inputs, 0, COMPOSITE_INPUTS)


## Whether this cabinet carries the aerial socket. The stock body does; a fitted
## shell says so itself.
func _has_aerial() -> bool:
	return _shell == null or _shell.has_aerial


## Turn off the inputs this cabinet has no room for: no socket, and nothing printed.
##
## `enabled` as well as `visible`, for the reason _seat_vga_port gives — hiding a
## snap zone stops it drawing and nothing else, so an invisible socket left enabled
## goes on catching plugs out of the air.
func _disable_absent_inputs() -> void:
	for i in range(_panel_inputs(), COMPOSITE_INPUTS):
		for port: RcaPort in _av_ports[i]:
			port.visible = false
			port.enabled = false
	if not _has_aerial():
		for port: RcaPort in _av_ports[Source.RF]:
			port.visible = false
			port.enabled = false


## The VIDEO socket of one input — the one that decides what is on the glass, and
## the one a captive lead goes into.
func _video_port(input: int) -> RcaPort:
	if input < 0 or input >= _av_ports.size() or (_av_ports[input] as Array).is_empty():
		return null
	return _av_ports[input][0]


## Print the back-panel legends: one per composite input group, plus the aerial
## socket's own.
##
## A set is a sink, so every A/V one reads AV IN; what tells them apart is the title
## above the jacks. The plate is the cabinet's call — a moulded CRT back is curved,
## and a flat rectangle across it either floats off the curve or cuts in.
func _print_av_legends() -> void:
	var plate: bool = _shell == null or _shell.av_legend_plate
	for i in _panel_inputs():
		var legend := AvLegend.attach(self, _av_ports[i])
		if legend == null:
			continue
		legend.name = "AvLegend%d" % (i + 1)
		legend.title = AV_INPUT_NAMES[i]
		legend.show_plate = plate
		# Every group but the first rules off the one to its left, so four inputs get
		# three lines and neither end of the bank carries a stray one.
		legend.divider_left = i > 0
		legend.rebuild()
	if _has_aerial():
		_print_rf_legend(plate)


## The aerial socket's legend — the same printing as a composite group so the one
## hole on the panel that is not phono is not also the one standing on bare cabinet.
##
## Wordless: CoaxPort reports Channel.VIDEO because the routing needs somewhere to
## send the picture, and printing VIDEO under an aerial hole would name the wrong
## connector. The row that word would have occupied still takes its space, so this
## plate comes out the same height as the four beside it.
##
## No divider, and that is the point of the gap it stands in: an aerial feed is not
## one of the composite inputs, and a rule would file it as a fifth.
func _print_rf_legend(plate: bool) -> void:
	var legend := AvLegend.attach(self, _av_ports[Source.RF])
	if legend == null:
		return
	legend.name = "AvLegendRf"
	legend.title = "Antenna"
	legend.heading_override = "RF IN"
	legend.show_words = false
	legend.show_plate = plate
	legend.rebuild()


## Seat all TWELVE input sockets off the shell's PortSeat, not just the video one.
##
## PortSeat names one point — Composite 1's VIDEO socket — and everything else steps
## off it: the audio pair by av_socket_step, the next input group by av_group_step,
## both in the seat's own frame. A shell that named only the video socket used to
## leave the rest at tv.tscn's own coordinates while the body they were mounted in
## was hidden, which put live sockets in mid-air beside the cabinet.
##
## The two steps are the SHELL's because the room to lay them out is the cabinet's:
## the stock box and the 90s set measure flat across the whole 240 mm row, while the
## computer monitor runs out at 180 and stands its groups on end instead.
func _seat_av_row(seat: Variant) -> void:
	if not seat is Transform3D:
		return
	var base: Transform3D = seat
	var socket_step := Vector3(-AV_ROW_PITCH, 0.0, 0.0)
	var group_step := Vector3(-AV_GROUP_PITCH, 0.0, 0.0)
	if _shell != null:
		socket_step = _shell.av_socket_step
		group_step = _shell.av_group_step
	for i in COMPOSITE_INPUTS:
		for j in (_av_ports[i] as Array).size():
			var offset: Vector3 = group_step * float(i) + socket_step * float(j)
			_seat_node(_av_ports[i][j], Transform3D(base.basis, base * offset))
	# The aerial socket takes the next group slot along, so it travels with the row
	# onto a fitted cabinet instead of being left at tv.tscn's own coordinates —
	# which, with the stock body hidden, is a live socket floating beside the set.
	# One group clear of Composite 4 whether or not this cabinet fits four, since a
	# shell with fewer still has the room the others use.
	#
	# Plus ONE socket step, which lands it on that slot's CENTRE rather than on the
	# slot's first socket. A composite group centres its printing on the middle of
	# its trio, so a lone socket sitting where a trio's VIDEO jack goes puts its plate
	# 18 mm right of where the pattern wants it — close enough to overlap Composite
	# 4's and z-fight with it, the two being coplanar and the same colour.
	if _rf_port != null:
		_seat_node(_rf_port, Transform3D(base.basis,
			base * (group_step * float(COMPOSITE_INPUTS) + socket_step)))


## Turn the VGA input on, but only for a shell that asked for it.
##
## Opt-IN rather than opt-out: the socket is authored off in tv.tscn and a shell
## claims it by carrying a VgaPortSeat marker. Only the computer monitor does — a
## DE-15 on a wood-cabinet 70s set would be an anachronism, and the stock body has
## nowhere sensible to put one.
##
## `enabled` as well as `visible`, and that is not belt and braces: hiding a snap
## zone stops it drawing and nothing else, so an invisible socket left enabled goes
## on catching plugs.
func _seat_vga_port(seat: Variant) -> void:
	if _vga_port == null:
		return
	var on: bool = seat is Transform3D
	if on:
		_vga_port.transform = seat
	_vga_port.visible = on
	_vga_port.enabled = on


## Resize the pickup collider and the pointer box to the cabinet.
##
## BoxShape3D_body and BoxShape3D_pointer are plain sub_resources in tv.tscn, i.e.
## SHARED between every TV in the scene — writing a size straight onto them would
## resize the den's TV too. Duplicate first. (Same trap the resource_local_to_scene
## note on Mat_phosphor_a already documents for the phosphor materials.)
func _resize_body_collision(size: Vector3) -> void:
	var body_col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if body_col and body_col.shape is BoxShape3D:
		var s := (body_col.shape as BoxShape3D).duplicate() as BoxShape3D
		s.size = size
		body_col.shape = s
	var ptr_col := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if ptr_col and ptr_col.shape is BoxShape3D:
		var p := (ptr_col.shape as BoxShape3D).duplicate() as BoxShape3D
		# The stock pointer box is 20 mm proud of the body on each axis.
		p.size = size + Vector3(0.02, 0.02, 0.02)
		ptr_col.shape = p


func _process(_delta: float) -> void:
	_update_screen_source()
	_update_crt()
	_refresh_crt_derived()
	_update_phosphor()
	_update_stereo_button()
	_route_osd()
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

	if not _ambilight or not _ambilight.visible:
		return

	# Static states do not run the tiny projector viewport. A live full-resolution
	# picture stays on the GPU; only its already-blurred 12x8 result is transferred.
	var override := _screen_mesh.get_surface_override_material(0)
	if not _tv_enabled or override == _dark_material:
		_ambilight.turn_off()
		return
	if _crt_source_tex == _blue_texture:
		_ambilight.show_solid(BLUE_SCREEN_COLOR)
		return
	if override is ShaderMaterial and (override as ShaderMaterial).shader == STATIC_SHADER:
		_ambilight.show_solid(STATIC_LIGHT_COLOR)
		return
	var tex := _screen_texture()
	if not tex:
		_ambilight.turn_off()
		return
	_ambilight.show_picture(tex, _screen_light_rect(override))


## Region of a composite framebuffer that is actually visible on the tube. A
## shared 3D light cannot differ per eye, so stereo uses the selected eye when
## forced and the left-eye region in the ordinary per-eye mode.
func _screen_light_rect(mat: Material) -> Rect2:
	if not (mat is ShaderMaterial) or (mat as ShaderMaterial).shader != WINDOW_SHADER:
		return Rect2(0.0, 0.0, 1.0, 1.0)
	var shader_mat := mat as ShaderMaterial
	var packed: Variant = shader_mat.get_shader_parameter("source_rect")
	if not (packed is Vector4):
		return Rect2(0.0, 0.0, 1.0, 1.0)
	var value := packed as Vector4
	var rect := Rect2(value.x, value.y, value.z, value.w)
	if stereo_mode == 2:
		var shift: Variant = shader_mat.get_shader_parameter("eye_shift")
		if shift is float:
			rect.position.x += float(shift)
	return rect


# ── Screen source (blue / dark states) ─────────────────────────────────────────

## Own the "no signal" presentation like a retro TV: ON with no live input →
## blue screen; OFF → black phosphors behind the same reflective glass. Live
## sources (the C++ video handler, the VCR) install their own materials over ours and this
## backs off automatically; when they blank/restore a textureless material we
## take over again next frame.
func _update_screen_source() -> void:
	# On the TV input the tuner owns the glass outright: it always has something
	# to show (a picture, or static carrying the reason there isn't one), so the
	# blue screen below must not get a look in. Nothing else is driving the mesh
	# either -- the connected host was muted with set_screen_enabled(false) when
	# the input changed.
	#
	# A broadcast is SAMPLED like every other picture. The tuner used to hand the
	# set a finished StandardMaterial3D, which is the one route onto the glass that
	# skips _show_sampled — so the 4:3/16:9 fit, the tube stage, the OSD and the
	# phosphor all stopped at the TV input while working on composite, and the
	# aspect button appeared dead. Static is still a material of the tuner's own:
	# snow fills the whole tube whatever shape the picture would have been.
	if _tv_enabled and current_source == Source.TV and _tuner != null:
		var tex := _tuner.picture_texture()
		if tex != null:
			_show_sampled(_crt_screen_material(), tex)
			return
		var snow := _tuner.static_material()
		if _screen_mesh.get_surface_override_material(0) != snow:
			_drop_sampled()
			_paint(snow)
		return

	# The aerial input paints its own no-signal. A set tuned to a channel nothing is
	# broadcasting on shows SNOW, not a blue screen — and here "nothing" is the
	# ordinary state of whichever of the two channels the switch is not using, so the
	# blue no-signal screen would read as a fault every time you stepped past it.
	# When the channel does match, the host owns the glass and this falls through.
	if _tv_enabled and current_source == Source.RF and not _rf_tuned():
		var snow := _rf_static()
		if _screen_mesh.get_surface_override_material(0) != snow:
			_drop_sampled()
			_paint(snow)
		return

	# The selected input's picture, sampled into a material this set owns.
	if _tv_enabled and _pull_from_selected():
		return

	# Nothing to show. Every material on the glass is the set's own now, so this no
	# longer has to work out whether it is allowed to paint over what is up there:
	# it is. What stood here read the installed material back to guess whether some
	# host was still live, counted any ShaderMaterial as a picture, and kept a list
	# of which blank states were safe to reclaim while the set was off.
	if not _tv_enabled:
		if _screen_mesh.get_surface_override_material(0) != _dark_material:
			_drop_sampled()
			_paint(_dark_material)
		return
	# The blue screen is a picture like any other, so it takes the same route and
	# comes out curved, scanlined and fitted to the tube.
	_show_sampled(_crt_screen_material(), _blue_texture)


## Retro CRT turn-on: the picture starts as a thin horizontal line and expands
## to full height. Scaling the screen mesh squashes everything (picture, OSD).
func _play_power_on_anim() -> void:
	if _poweron_tween:
		_poweron_tween.kill()
	_screen_mesh.scale = Vector3(1.0, 0.02, 1.0)
	# Snap to the thin line instantly — don't let physics interpolation smooth
	# the collapse (the expansion itself is tweened below).
	_screen_mesh.reset_physics_interpolation()
	_poweron_tween = create_tween()
	_poweron_tween.tween_interval(0.07)
	_poweron_tween.tween_property(_screen_mesh, "scale", Vector3.ONE, 0.3) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _stop_power_on_anim() -> void:
	if _poweron_tween:
		_poweron_tween.kill()
		_poweron_tween = null
	_screen_mesh.scale = Vector3.ONE


# ── CRT filter ─────────────────────────────────────────────────────────────────

## Keep the tube stage and the stereo mode in step with the buttons.
##
## Was 118 lines of watching the override each frame to see whether a host had
## installed a new material, reading the texture back out of it, wrapping it in
## ours, and unwrapping it again when the toggle went off - all because the
## material on the glass belonged to somebody else. It belongs to the set, so this
## only writes uniforms. The tube is a stage inside every display shader
## (crt_filter.gdshaderinc), switched by crt_enabled, whether that shader is the
## set's own or one a source asked for.
func _update_crt() -> void:
	var mat := _screen_mesh.get_surface_override_material(0) as ShaderMaterial
	if mat == null:
		return
	# Writing a uniform a shader does not declare is harmless, so this does not
	# have to know which of the display shaders is currently showing.
	var cur: Variant = mat.get_shader_parameter("crt_enabled")
	if (cur == true) != crt_enabled:
		mat.set_shader_parameter("crt_enabled", crt_enabled)
		if crt_enabled:
			_apply_crt_params(mat)
	if mat.shader == WINDOW_SHADER:
		var cur_mode: Variant = mat.get_shader_parameter("stereo_mode")
		if cur_mode != stereo_mode:
			mat.set_shader_parameter("stereo_mode", stereo_mode)


## Show the selected host by SAMPLING the picture it offers, in a material this
## set owns. False when there is nothing to sample — no host on this input, no
## picture yet — and the caller falls through to the set's own no-signal states.
##
## The set has always owned a material that samples a source texture: the CRT
## wrapper. What is new is where the texture comes from. Wrapping meant waiting for
## a host to paint, reading the texture back out of whatever it painted, and
## re-wrapping every time it changed its mind — which is why the old path needed
## _extract_texture, _crt_wrapped and an unwrap ordered against every handover.
func _pull_from_selected() -> bool:
	var host := _selected_system()
	var tex: Texture2D = null
	# Being ON this input is not the same as SENDING a picture to it. The set
	# files a machine on a video input as soon as any cord lands there, on
	# purpose, so its sound routes — and a phono plug fits any phono socket, so
	# an AUDIO cord in the yellow input is ordinary hardware rather than a fault.
	# Without this the set pulled the machine's picture anyway: red lead into the
	# yellow socket, no video cord anywhere, and the game appeared on the glass.
	# The two decks never had the bug because each already refuses its own
	# texture unless a picture cord reached the set (VCRPlayer._feed_video); a
	# console's accessor hands the core's frame to anyone who asks, so the guard
	# has to be here as well as there. Asked of the source, per set.
	if host != null and host.has_method("sends_video_to") and not host.sends_video_to(self):
		host = null
	if host != null and host.has_method("get_video_texture"):
		tex = host.get_video_texture()
	if tex == null:
		_drop_sampled()
		return false

	# A source may ask for a stage of its own — the VHS effect is one — and the set
	# runs it in a material the set owns. It does not need to know what the stage
	# means: the shader and its uniforms both come from the source, and the CRT
	# stage chains inside it exactly as it did when the deck owned the material.
	# Named, because the answer can depend on which set is asking: a dual-screen
	# machine cabled to two televisions shows each of them a different window of
	# the same frame.
	var stage: Dictionary = host.get_video_stage(self) \
		if host.has_method("get_video_stage") else {}
	var shader := stage.get("shader") as Shader
	var stereo := _source_is_sbs()
	var mat: ShaderMaterial
	if shader != null:
		mat = _stage_screen_material(shader)
		var params: Dictionary = stage.get("params", {})
		for key: String in params:
			mat.set_shader_parameter(key, params[key])
	elif stereo:
		mat = _stereo_screen_material()
	else:
		mat = _crt_screen_material()
	_show_sampled(mat, tex)
	return true


## Install one of the set's own materials and point it at a texture. The one place
## a picture reaches the glass, whether it came from a machine, a deck, or the
## set's own no-signal screen.
func _show_sampled(mat: ShaderMaterial, tex: Texture2D) -> void:
	if _screen_mesh.get_surface_override_material(0) != mat:
		_drop_sampled()
		_paint(mat)
	# Against _crt_source_tex rather than the material, because the phosphor
	# accumulator legitimately swaps source_tex for its ping-pong buffer — reading
	# it back would look like a source change every frame and undo the persistence.
	var on_crt := mat == _crt_material
	var current: Texture2D = _crt_source_tex if on_crt \
		else mat.get_shader_parameter("source_tex") as Texture2D
	if current == tex:
		return
	mat.set_shader_parameter("source_tex", tex)
	# A different picture: the afterglow of the last one is not this one's history.
	_phosphor_fresh = 2
	# The fit does not survive a new source, and the scanline count is derived
	# from the source's own resolution.
	_apply_aspect()
	_apply_crt_params(mat)
	if on_crt:
		_crt_source_tex = tex     # what the phosphor accumulator reads


## The set's own material for a sampled picture. crt_enabled is set at creation
## because the shader's own default is ON, so a set with the tube switched off
## would show one frame of it before _update_crt caught up.
func _crt_screen_material() -> ShaderMaterial:
	if _crt_material == null:
		_crt_material = ShaderMaterial.new()
		_crt_material.shader = CRT_SHADER
		_crt_material.set_shader_parameter("crt_enabled", crt_enabled)
	return _crt_material


## True for a material this set samples a source into, as against one a host
## painted for itself. The distinction is what tells "a picture is up" from "the
## set is holding a picture that has stopped arriving".
func _is_sampling_material(mat: Material) -> bool:
	return mat != null and (mat == _crt_material or mat == _stereo_material
		or _stage_materials.values().has(mat))


## Forget the picture the set was sampling, when the source stops offering one —
## a machine switched off, a picture cord pulled out.
##
## Only the set's record of it. The material keeps the dead texture and is simply
## painted over: a sampling material counts as showing nothing (see _effective in
## _update_screen_source), and clearing the uniform instead would also strip the
## CRT wrapper when what it happens to be wrapping is the set's own blue screen —
## which renders as a white panel, not a blue one.
func _drop_sampled() -> void:
	_crt_source_tex = null
	_crt_derived_key = ""
	_phosphor_fresh = 2


## One material per stage shader a source has asked for, kept because the uniforms
## on it (the VHS tuning, the CRT stage's own) are worth not rebuilding per frame.
## Keyed by shader, so two decks asking for the same stage share nothing but the
## shader itself — only one of them can be on the glass at a time.
var _stage_materials := {}


func _stage_screen_material(shader: Shader) -> ShaderMaterial:
	var mat: ShaderMaterial = _stage_materials.get(shader)
	if mat == null:
		mat = ShaderMaterial.new()
		mat.shader = shader
		mat.set_shader_parameter("crt_enabled", crt_enabled)
		_stage_materials[shader] = mat
	return mat


## The same for a full-frame side-by-side source (Virtual Boy): the windowing
## shader takes the left half and shifts +0.5 for the right eye, with the CRT
## stage chained inside it.
func _stereo_screen_material() -> ShaderMaterial:
	if _stereo_material == null:
		_stereo_material = ShaderMaterial.new()
		_stereo_material.shader = WINDOW_SHADER
		_stereo_material.set_shader_parameter("source_rect", Vector4(0.0, 0.0, 0.5, 1.0))
		_stereo_material.set_shader_parameter("eye_shift", 0.5)
		_stereo_material.set_shader_parameter("stereo_mode", stereo_mode)
		_stereo_material.set_shader_parameter("crt_enabled", crt_enabled)
	return _stereo_material


## Phosphor persistence: run the live frame through the decay accumulator and feed
## the CRT stage the result instead of the raw texture.
##
## Rides the crt_effect wrapper only. The chained VCR and dual-screen window
## shaders keep sampling their source directly — three more ping-pong pairs isn't
## worth it for a tape deck that has its own artefacts and for a handheld panel
## that isn't a tube in the first place.
func _update_phosphor() -> void:
	if _crt_material == null or _crt_source_tex == null:
		return
	if _screen_mesh.get_surface_override_material(0) != _crt_material:
		return

	var amount: float = float(_crt_params.get("crt_persistence", 0.0))
	if not crt_enabled or amount <= 0.001:
		# Hand the raw picture back so turning persistence off is a true bypass.
		if _crt_material.get_shader_parameter("source_tex") != _crt_source_tex:
			_crt_material.set_shader_parameter("source_tex", _crt_source_tex)
		return

	var sz := Vector2i(_crt_source_tex.get_size())
	if sz.x < 2 or sz.y < 2:
		return

	var write: SubViewport = _phosphor_a if _phosphor_write_a else _phosphor_b
	var read: SubViewport = _phosphor_b if _phosphor_write_a else _phosphor_a
	if write.size != sz:
		write.size = sz
		read.size = sz

	var rect := write.get_child(0) as ColorRect
	var pm := rect.material as ShaderMaterial
	pm.set_shader_parameter("src", _crt_source_tex)
	# A fresh source has no afterglow of its own yet, and the buffers still hold the
	# last one's. Blend against the source itself until both have been written.
	if _phosphor_fresh > 0:
		_phosphor_fresh -= 1
		pm.set_shader_parameter("prev", _crt_source_tex)
	else:
		pm.set_shader_parameter("prev", read.get_texture())
	# Red decays slowest, blue fastest, so the afterglow goes warm as it fades.
	pm.set_shader_parameter("decay", Vector3(amount, amount * 0.85, amount * 0.7))
	# UPDATE_ONCE re-armed every frame, never UPDATE_ALWAYS — an ALWAYS render
	# target hangs headless runs.
	write.render_target_update_mode = SubViewport.UPDATE_ONCE

	_crt_material.set_shader_parameter("source_tex", write.get_texture())
	_phosphor_write_a = not _phosphor_write_a


## True when the source ON SCREEN outputs a side-by-side stereo frame (Virtual Boy).
## The one showing, not merely one connected: a VB left plugged into an input nobody
## has selected must not put the other input's picture through a per-eye split.
func _source_is_sbs() -> bool:
	var system := _selected_system()
	return system != null \
		and system.has_method("is_stereo_output") \
		and system.is_stereo_output()


## True while what's showing is a stereo source: a full-frame SBS system (VB)
## or a dual-screen system's window channel with a per-eye shift (3DS top).
## True while something 3D is playing — what both the bezel's 3D key and the
## remote's hide themselves on.
func has_stereo_source() -> bool:
	return _stereo_source_active()


func _stereo_source_active() -> bool:
	if _source_is_sbs():
		return true
	var override := _screen_mesh.get_surface_override_material(0)
	if override is ShaderMaterial and override != _stereo_material \
			and (override as ShaderMaterial).shader == WINDOW_SHADER:
		var es: Variant = (override as ShaderMaterial).get_shader_parameter("eye_shift")
		return es != null and float(es) != 0.0
	return false


## Show the 3D button only while a stereo source is connected. Hidden buttons
## also stop processing and drop off the pointable layer so an invisible
## button can't eat pokes or laser clicks.
func _update_stereo_button() -> void:
	if _stereo_btn == null:
		return
	var active := _stereo_source_active()
	if _stereo_btn.visible != active:
		_stereo_btn.set_active(active)


## Push every tunable CRT uniform onto a material carrying the CRT display stage
## (our wrapper or the chained VCR shader).
func _apply_crt_params(mat: ShaderMaterial) -> void:
	for key: String in _crt_params:
		mat.set_shader_parameter(key, _crt_params[key])
	mat.set_shader_parameter("crt_glass_wear_tex", GLASS_WEAR_TEXTURE)
	_apply_derived_crt_params(mat)


func _is_tv_display_shader(shader: Shader) -> bool:
	return shader == CRT_SHADER or shader == VCR_SHADER or shader == WINDOW_SHADER \
		or shader == STATIC_SHADER


## Every cached or currently installed material that can carry the shared tube
## stage. Keeping this list in one place means a glass control changed while the
## set is off still reaches VHS/static/stereo when that source comes back.
func _known_display_materials() -> Array[ShaderMaterial]:
	var result: Array[ShaderMaterial] = []
	var candidates: Array[Variant] = [
		_crt_material, _stereo_material, _dark_material, _rf_static_material,
	]
	for candidate: Variant in _stage_materials.values():
		candidates.append(candidate)
	if _screen_mesh != null:
		candidates.append(_screen_mesh.get_surface_override_material(0))
	for candidate: Variant in candidates:
		if candidate is ShaderMaterial:
			var mat := candidate as ShaderMaterial
			if mat.shader != null and _is_tv_display_shader(mat.shader) and not result.has(mat):
				result.append(mat)
	return result


## Uniforms derived from the set and its current signal rather than authored by a
## slider. They keep the mask/raster fixed to the glass and vary the shared wear
## map between otherwise identical televisions.
func _apply_derived_crt_params(mat: ShaderMaterial) -> void:
	var wear_variant := int(get_instance_id() % 4)
	mat.set_shader_parameter("crt_glass_wear_flip", Vector2(
		float(wear_variant & 1), float((wear_variant >> 1) & 1)))
	# Phosphor pitch is a property of the glass, so the triad count follows the
	# screen's WORLD width: scaling the TV up adds triads instead of stretching
	# them, exactly as a physically bigger tube would.
	var pitch_m: float = maxf(float(_crt_params.get("crt_mask_pitch_mm", 2.0)), 0.05) * 0.001
	var triads: float = (_screen_size_m.x * scale_factor) / pitch_m
	mat.set_shader_parameter("crt_mask_triads", triads)
	# Slot/shadow phosphor cells run about 1.5x taller than they are wide.
	mat.set_shader_parameter("crt_mask_rows",
		triads * (_screen_size_m.y / _screen_size_m.x) / 1.5)

	# Active lines in the signal, taken from the source itself. A fixed count is
	# the point: the raster belongs to the signal, so walking backwards must not
	# change how many scanlines are on the tube.
	var lines := 240.0
	var tex := mat.get_shader_parameter("source_tex") as Texture2D
	if tex != null:
		var h: float = tex.get_size().y
		# A window shader shows one sub-rect of a composite framebuffer, so a DS
		# panel has half the lines the texture does.
		var rect: Variant = mat.get_shader_parameter("source_rect")
		if rect is Vector4:
			h *= maxf((rect as Vector4).w, 0.01)
		if h >= 16.0:
			lines = h
	mat.set_shader_parameter("crt_scanline_count", lines)


## The installed material carrying the CRT display stage, if any.
func _active_crt_material() -> ShaderMaterial:
	var override := _screen_mesh.get_surface_override_material(0)
	if override is ShaderMaterial:
		var sh := (override as ShaderMaterial).shader
		if sh != null and _is_tv_display_shader(sh):
			return override as ShaderMaterial
	return null


## Recompute the derived uniforms when what they depend on moves — the TV's
## display scale, the mask pitch, or the source's resolution. Cheap signature
## check so the steady state costs nothing.
func _refresh_crt_derived() -> void:
	var mat := _active_crt_material()
	if mat == null:
		return
	var tex := mat.get_shader_parameter("source_tex") as Texture2D
	var key := "%s|%.4f|%.4f|%s" % [
		mat.get_instance_id(), scale_factor,
		float(_crt_params.get("crt_mask_pitch_mm", 2.0)),
		"null" if tex == null else str(tex.get_size()),
	]
	if key == _crt_derived_key:
		return
	_crt_derived_key = key
	_apply_derived_crt_params(mat)


## Set one CRT display-stage uniform live (from the TV options panel) and apply
## it to whichever material currently shows the CRT stage.
func set_crt_param(pname: String, value: Variant) -> void:
	if not _crt_params.has(pname):
		return
	_crt_params[pname] = value
	for mat: ShaderMaterial in _known_display_materials():
		mat.set_shader_parameter(pname, value)
	# crt_mask_pitch_mm isn't a uniform — it feeds the derived triad count.
	_crt_derived_key = ""


## Current CRT tuning values, for the options panel to populate its controls.
func get_crt_params() -> Dictionary:
	return _crt_params.duplicate()


## Seed the CRT tuning from a save. Merges only keys we already know, so a save
## written by a build with a different set of uniforms can't inject stray shader
## parameters, and coerces through the current value's type — JSON gives every
## number back as a float, but crt_mask_mode is an int uniform.
func set_crt_params(values: Dictionary) -> void:
	for key: String in values:
		if not _crt_params.has(key):
			continue
		if typeof(_crt_params[key]) == TYPE_INT:
			_crt_params[key] = int(values[key])
		else:
			_crt_params[key] = float(values[key])
	_crt_derived_key = ""
	# Seeded before _ready (scene restore instantiates then sets): the values are
	# in place and get pushed when the filter first wraps a source.
	if _screen_mesh == null:
		return
	for mat: ShaderMaterial in _known_display_materials():
		_apply_crt_params(mat)


## Pull the picture texture out of a screen material, whichever shape it has:
## the C++ video handler uses emission, the VCR uses albedo or a video_tex
## uniform, and our own CRT wrapper uses source_tex.
## Replaces _extract_texture, which had to guess where the picture was: the C++
## handler used emission, a deck used albedo or its own video_tex uniform, the
## set's wrapper used source_tex. One convention now, because the set writes them.
func _screen_texture() -> Texture2D:
	var mat := _screen_mesh.get_surface_override_material(0)
	if mat is ShaderMaterial:
		return (mat as ShaderMaterial).get_shader_parameter("source_tex") as Texture2D
	if mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		return std.emission_texture if std.emission_texture != null else std.albedo_texture
	return null


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
## _update_crt pushes the mode onto whichever shader is showing the source.
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
	_apply_aspect()
	_update_aspect_button()
	show_osd_timed("16:9" if widescreen else "4:3", 1.5)
	NetworkManager.report_event(NetObjectSync.EV_TV_ASPECT,
		{"tv": self, "on": widescreen})


## How much of the glass the picture should cover, as a fraction per axis.
##
## The tube is whatever shape the shell gave it — not necessarily 4:3 — so the
## fit is computed against the real glass rather than assumed. Whichever axis is
## too generous gets shrunk about the centre and the rest becomes bar.
func _aspect_fit() -> Vector2:
	if _screen_size_m.x <= 0.0 or _screen_size_m.y <= 0.0:
		return Vector2.ONE
	var glass := _screen_size_m.x / _screen_size_m.y
	var want := ASPECT_16_9 if widescreen else ASPECT_4_3
	if is_equal_approx(glass, want):
		return Vector2.ONE
	if want > glass:
		return Vector2(1.0, glass / want)   # wider than the glass -> bars above/below
	return Vector2(want / glass, 1.0)       # taller -> bars either side


## Push the fit onto whichever material is currently showing the picture. Called
## on every material change as well as on the button, because the display path
## swaps materials underneath us (raw source, CRT wrapper, window shader).
func _apply_aspect() -> void:
	var fit := _aspect_fit()
	for mat in [_crt_material, _stereo_material]:
		if mat != null:
			(mat as ShaderMaterial).set_shader_parameter("fit_scale", fit)
	var override := _screen_mesh.get_surface_override_material(0) as ShaderMaterial
	if override != null and override.shader == CRT_SHADER:
		override.set_shader_parameter("fit_scale", fit)


## True when the picture needs shrinking to fit. The raw source material has no
## fit of its own, so this is what decides the CRT wrapper has to go on even
## with the tube effect switched off — otherwise turning CRT off would silently
## stretch the picture back out again.
func _aspect_needs_fit() -> bool:
	return not _aspect_fit().is_equal_approx(Vector2.ONE)


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


## Cycle the speaker switch: stereo -> the left channel from both speakers -> the
## right from both. Called by the front-panel key and by the remote.
func set_audio_mode(mode: int) -> void:
	audio_mode = clampi(mode, 0, 2)
	_apply_audio_channel_mode()
	_update_audio_mode_button()
	show_osd_timed(AUDIO_MODE_NAMES[audio_mode], 2.0)
	NetworkManager.report_event(NetObjectSync.EV_TV_AUDIO_MODE,
		{"tv": self, "mode": audio_mode})


func _on_audio_mode_toggle() -> void:
	set_audio_mode((audio_mode + 1) % 3)


## The routing itself belongs to whoever owns the samples, so it is handed to the
## connected deck rather than done here — the set has no emitter of its own.
func _apply_audio_channel_mode() -> void:
	# Every connected host, not just the one showing: the speaker switch is a
	# property of the SET, so an input switched to later has to already be routed
	# the way the switch says rather than reverting to stereo for one press.
	for system in _connected_systems:
		if system != null and is_instance_valid(system) \
				and system.has_method("set_audio_channel_mode"):
			system.set_audio_channel_mode(audio_mode)
	# The tuner is the one source the set does own an emitter for, so it takes the
	# same routing directly rather than being asked to do it.
	if _tuner:
		_tuner.set_channel_mode(audio_mode)


## Stereo gets the two-speaker symbol; a mono mode gets a single speaker leaning
## to the channel it is carrying, matching how the 3D key shows its eye.
func _update_audio_mode_button() -> void:
	match audio_mode:
		0:
			TransportGlyphs.set_glyph(self, "AudioModeButton", "audio_stereo",
				TransportGlyphs.TV_SIZE)
		1:
			TransportGlyphs.set_glyph(self, "AudioModeButton", "audio_mono",
				TransportGlyphs.TV_SIZE, -1.0)
		2:
			TransportGlyphs.set_glyph(self, "AudioModeButton", "audio_mono",
				TransportGlyphs.TV_SIZE, 1.0)
	if _audio_mode_btn:
		_audio_mode_btn.set_color(Color(0.35, 0.55, 0.9) if audio_mode == 0
			else Color(0.9, 0.65, 0.25))


## Both eyes gets the 3D symbol; a single eye gets an eye leaning to the side it
## is showing, so the cap says which one without a word on it.
func _update_stereo_button_glyph() -> void:
	match stereo_mode:
		0: TransportGlyphs.set_glyph(self, "StereoButton", "stereo", TransportGlyphs.TV_SIZE)
		1: TransportGlyphs.set_glyph(self, "StereoButton", "eye", TransportGlyphs.TV_SIZE, -1.0)
		2: TransportGlyphs.set_glyph(self, "StereoButton", "eye", TransportGlyphs.TV_SIZE, 1.0)


## Returns the screen MeshInstance3D so Libretro can render onto it
func get_screen_mesh() -> MeshInstance3D:
	return _screen_mesh


# ── Who may paint the glass ───────────────────────────────────────────────────
#
# One mesh, one material slot, and until now five things wrote it directly: the
# C++ video handler, both decks, this script, and a dual-screen console's mirror.
# Nothing owned it, so who was showing had to be inferred from whatever material
# happened to be installed — and every bug in this area came from that. A host
# painting an input nobody selected produced a picture on the wrong input; a host
# that stopped painting produced no picture at all. Both were SILENT.
#
# The rule is now stated: a host may put a picture on the glass only while the set
# is showing its input, and may always take its own picture off again. Breaking it
# is an error rather than a wrong picture.


## Who last painted the glass — the set itself, or the host on the shown input.
var _screen_owner: Object = null

## The last caller refused, so a host that keeps asking is reported once rather
## than once per frame.
var _refused: Object = null


## True when `who` is allowed to show a picture right now: the set itself, or the
## host on the selected input while the set is on. RF adds its own condition — a
## console on the aerial input only appears on the channel its switch is using.
func can_paint(who: Object) -> bool:
	if who == self:
		return true
	if not _tv_enabled or who == null:
		return false
	if current_source == Source.RF and not _rf_tuned():
		return false
	return who == _selected_system()


## Put a material on the glass. Refused, loudly, unless `who` may paint.
func paint_screen(who: Object, mat: Material) -> bool:
	if not can_paint(who):
		if _refused != who:
			_refused = who
			push_error("[RetroTV] %s tried to paint %s while it is showing %s"
				% [who, name, SOURCE_NAMES[current_source]])
		return false
	_refused = null
	_screen_owner = who
	_screen_mesh.set_surface_override_material(0, mat)
	return true


## Take `who`'s picture off the glass. Always allowed — a host may stop showing
## whenever it likes — but it only clears when the picture up there is actually
## theirs, so a deck being unplugged cannot blank the input somebody is watching.
func release_screen(who: Object) -> void:
	# Or while the set is showing their input: what is on the glass then is
	# theirs by definition, even when the set has wrapped it in its own CRT
	# material and taken nominal ownership doing so.
	if _screen_owner != who and not can_paint(who):
		return
	# _update_screen_source paints the right nothing (blue while on, dark while
	# off) on the next frame; clearing the override is what lets it.
	_drop_sampled()
	_paint(null)
	_screen_owner = null


## The set's own writes. Separate from paint_screen so the set does not have to
## police itself, and so every write still passes through one place.
func _paint(mat: Material) -> void:
	_screen_owner = self
	if mat is ShaderMaterial:
		var shader_mat := mat as ShaderMaterial
		if shader_mat.shader != null and _is_tv_display_shader(shader_mat.shader):
			_apply_crt_params(shader_mat)
	_screen_mesh.set_surface_override_material(0, mat)


## World positions of the set's left and right speakers, in that order.
##
## Read straight off the SpeakerL / SpeakerR markers, so where a set radiates
## from is authored in the scene and can be dragged in the editor like any other
## node. Being children of the root they ride scale_factor and any parent's
## transform for free.
##
## Left and right are the LISTENER's. The set faces +Z (the screen sits proud of
## the front face, the composite port is on the back at -Z), so someone watching
## it has its +X on their right, and SpeakerR is the one at +X.
##
## Emitting from the cabinet centre instead makes the sound appear to come from
## inside the box -- inaudible with amplitude panning, obvious with HRTF.
func get_speaker_positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	if _speaker_l != null and _speaker_r != null:
		out.push_back(_speaker_l.global_position)
		out.push_back(_speaker_r.global_position)
		return out
	# No markers (a scene predating them): the defaults, computed in place.
	var frame := global_transform.basis
	var face: Vector3 = _screen_mesh.global_position + frame.z * 0.005
	var right: Vector3 = frame.x * (_screen_size_m.x * 0.5 + 0.055)
	var down: Vector3 = -frame.y * (_screen_size_m.y * 0.35)
	out.push_back(face - right + down)
	out.push_back(face + right + down)
	return out


## Put the speaker markers where a set of this size wears them: flanking the tube
## 5.5 cm outboard of its edges, a little below its centre, and just proud of the
## glass -- which is where a CRT of this vintage puts them.
##
## Only for a shell that names no speaker seats. tv.tscn's own markers are already
## these numbers for the stock 0.35 x 0.25 tube, so this exists for a cabinet that
## moves and rescales the screen without saying where its speakers went; leaving
## the stock markers there would strand them on the old tube's edges.
##
## Local metres throughout, since the markers are children of the root: no basis
## juggling, and the scale that ScreenSeat gave the tube is already inside
## _screen_size_m.
func _place_default_speakers() -> void:
	if _speaker_l == null or _speaker_r == null:
		return
	var half_w: float = _screen_size_m.x * 0.5 + 0.055
	var drop_m: float = _screen_size_m.y * 0.35
	var face: Vector3 = _screen_mesh.position + Vector3(0.0, 0.0, 0.005)
	_speaker_l.position = face + Vector3(-half_w, -drop_m, 0.0)
	_speaker_r.position = face + Vector3(half_w, -drop_m, 0.0)


## Which way the picture faces. Sound leaves a set the same way it does, so
## anything giving these speakers a directivity aims them along this. Normalised,
## unlike the offsets above, because it is a direction rather than a distance.
func get_screen_normal() -> Vector3:
	return global_transform.basis.z.normalized()


## The set's own up, to go with get_screen_normal when a pose is wanted.
func get_screen_up() -> Vector3:
	return global_transform.basis.y.normalized()


# ── On-screen display (top-right corner) ────────────────────────────────────────
# The text lives in two places: a 2D Label rendered into OSDViewport (composited
# INSIDE the CRT/VHS shaders so the OSD curves and scanlines with the picture)
# and the legacy OSDLabel Label3D used as a fallback when no shader owns the
# screen. _route_osd() picks the right one every frame.

## Show a persistent OSD message (stays until replaced or hidden).
func show_osd(text: String) -> void:
	_osd_token += 1
	_set_osd_text(text)


## Show an OSD message that auto-hides after `seconds` (unless superseded).
func show_osd_timed(text: String, seconds: float) -> void:
	_osd_token += 1
	var tok := _osd_token
	_set_osd_text(text)
	get_tree().create_timer(seconds).timeout.connect(func():
		if tok == _osd_token:
			hide_osd()
	)


## Clear the OSD.
func hide_osd() -> void:
	_osd_token += 1
	_set_osd_text("")


# Long OSD messages (e.g. "AUDIO: English (Dolby Digital 5.1)" from the DVD/VHS
# track cycling) would otherwise overflow past the edge of the screen at the
# base font size. Short messages ("PLAY", "MUTE", "POWER"...) stay full-size;
# anything past OSD_FIT_CHARS scales down (never below the min) to fit.
const OSD_FIT_CHARS := 10
const OSD_BASE_FONT_SIZE_3D := 64
const OSD_MIN_FONT_SIZE_3D := 24
const OSD_BASE_FONT_SIZE_2D := 44
const OSD_MIN_FONT_SIZE_2D := 18


func _fit_osd_font_size(text: String, base_size: int, min_size: int) -> int:
	var length := text.length()
	if length <= OSD_FIT_CHARS:
		return base_size
	return maxi(min_size, int(base_size * OSD_FIT_CHARS / float(length)))


func _set_osd_text(text: String) -> void:
	_osd_label.text = text
	_osd_label.font_size = _fit_osd_font_size(text, OSD_BASE_FONT_SIZE_3D, OSD_MIN_FONT_SIZE_3D)
	_osd_text_2d.text = text
	_osd_text_2d.add_theme_font_size_override(
			"font_size", _fit_osd_font_size(text, OSD_BASE_FONT_SIZE_2D, OSD_MIN_FONT_SIZE_2D))
	_refresh_osd_texture(text)


## Volume-bars OSD (bottom of screen, like an old set): VOL |||||||---
## Independent of the corner OSD; auto-hides after 2 s.
func show_volume_osd() -> void:
	_vol_osd_token += 1
	var tok := _vol_osd_token
	var filled := roundi(_volume * VOL_OSD_SEGMENTS)
	var text := "VOL " + "|".repeat(filled) + "-".repeat(VOL_OSD_SEGMENTS - filled)
	_set_vol_osd_text(text)
	get_tree().create_timer(2.0).timeout.connect(func():
		if tok == _vol_osd_token:
			_vol_osd_token += 1
			_set_vol_osd_text("")
	)


# One segment per volume step, so the bar has exactly the granularity the keys do.
const VOL_OSD_SEGMENTS := 10
# The margin the bar keeps at each end, as a fraction of the picture width. The
# CRT stage samples the OSD through crt_warp, which pulls the outer few percent
# of the texture off past the curved glass.
const VOL_OSD_SIDE_MARGIN := 0.055
# A ceiling only. The bar is a fixed cell count, so on a normal 4:3 picture the
# solved size lands well under this; the clamp is there so a freak narrow
# viewport can't ask for a 300 px font.
const VOL_OSD_MAX_FONT_SIZE := 128


## Solve the font size that makes `text` span `avail` units wide, measuring the
## real font rather than assuming a cell width (the mono family resolves
## differently per platform — Consolas on Windows, Droid Sans Mono on Quest).
## `unit` is the world size of one font pixel (1.0 for a 2D label). Returns 0
## when there is nothing to measure, meaning "leave the size as it is".
func _fit_font_size_to_width(font: Font, text: String, avail: float, unit: float) -> int:
	if font == null or text.is_empty() or avail <= 0.0 or unit <= 0.0:
		return 0
	const PROBE := 64
	var probe_w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, PROBE).x
	if probe_w <= 0.0:
		return 0
	return clampi(int(PROBE * (avail / unit) / probe_w), 8, VOL_OSD_MAX_FONT_SIZE)


# The bar is as wide as the picture, the way a real set draws it. Both copies
# size themselves from the space they actually have — the viewport's width for
# the composited one, the screen quad's own extent for the Label3D fallback —
# so a shell with a different tube gets a bar that still spans it.
func _set_vol_osd_text(text: String) -> void:
	_vol_osd_label.text = text
	var size_3d := _fit_font_size_to_width(_vol_osd_label.font,
			text, _vol_osd_label_width(), _vol_osd_label.pixel_size)
	if size_3d > 0:
		_vol_osd_label.font_size = size_3d
	_vol_osd_text_2d.text = text
	var size_2d := _fit_font_size_to_width(_vol_osd_text_2d.get_theme_font("font"),
			text, _vol_osd_text_2d_width(), 1.0)
	if size_2d > 0:
		_vol_osd_text_2d.add_theme_font_size_override("font_size", size_2d)
	_refresh_osd_texture(text)


## The composited copy fills its own rect, which the tscn insets from the
## viewport edge. Before the first layout pass that rect is still empty, so fall
## back to the inset the constant describes.
func _vol_osd_text_2d_width() -> float:
	var w := _vol_osd_text_2d.size.x
	if w > 0.0:
		return w
	return _osd_viewport.size.x * (1.0 - 2.0 * VOL_OSD_SIDE_MARGIN)


## The Label3D runs rightward from its own origin, so its room is whatever lies
## between that origin and the far margin of the screen quad it hangs on.
func _vol_osd_label_width() -> float:
	if _screen_mesh.mesh == null:
		return 0.0
	var quad_w := _screen_mesh.mesh.get_aabb().size.x
	return quad_w * (0.5 - VOL_OSD_SIDE_MARGIN) - _vol_osd_label.position.x


func _refresh_osd_texture(text: String) -> void:
	# One-shot re-render of the OSD texture (skipped headless — no GPU).
	if text != "" and DisplayServer.get_name() != "headless":
		_osd_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_route_osd()


## Route the OSD to the screen shader when one is active (our CRT wrapper or
## the VCR's VHS material), else to the fallback Label3Ds. Both the corner OSD
## and the volume bars share the same OSD viewport texture.
func _route_osd() -> void:
	var main_active := _osd_label.text != ""
	var vol_active := _vol_osd_label.text != ""
	var mat := _screen_mesh.get_surface_override_material(0)
	var sm: ShaderMaterial = null
	if mat is ShaderMaterial:
		var candidate := mat as ShaderMaterial
		if candidate == _crt_material or candidate.shader == VCR_SHADER \
				or candidate.shader == WINDOW_SHADER \
				or candidate.shader == STATIC_SHADER:
			sm = candidate
	if sm != null:
		sm.set_shader_parameter("osd_tex", _osd_viewport.get_texture())
		sm.set_shader_parameter("osd_enabled", main_active or vol_active)
		_osd_label.visible = false
		_vol_osd_label.visible = false
	else:
		_osd_label.visible = main_active
		_vol_osd_label.visible = vol_active


## Snaps a captive cable plug into one of this TV's video sockets (used by save/load
## and netplay to restore connections). Defaults to Composite 1, which is where a
## caller that has no opinion — and every save written before there were four — means.
func accept_plug_restore(plug: CablePlug, input: int = Source.COMPOSITE_1) -> void:
	var port := _video_port(input)
	if port == null:
		port = _composite_port as RcaPort
	print("[RetroTV] accept_plug_restore: plug=%s port=%s" % [plug, port])
	port.pick_up_object(plug)
	print("[RetroTV] accept_plug_restore: done, port.picked_up=%s" % port.picked_up_object)


## Drop whatever captive lead is in one input's video socket. Used by netplay when
## another player unplugs one; the input defaults to Composite 1 for an event from a
## peer that predates there being four.
func release_input(input: int = Source.COMPOSITE_1) -> void:
	var port := _video_port(input)
	if port != null:
		port.drop_object()


## The L and R sockets of one composite input, in that order — the pair a captive
## lead's audio cords go into beside its picture cord. Empty for an input this
## cabinet has no sockets for, and for the tuner, which has no audio of its own.
func audio_ports(input: int) -> Array:
	if input < 0 or input >= _av_ports.size():
		return []
	var trio: Array = _av_ports[input]
	return trio.slice(1) if trio.size() > 1 else []


## Which socket ANYWHERE on this set is holding `plug` — audio as well as video.
## port_holding answers the narrower question of which INPUT a lead is feeding, and
## an audio cord is never the answer to that one.
func socket_holding(plug: Node3D) -> XRToolsSnapZone:
	for group: Array in _av_ports:
		for port: RcaPort in group:
			if port.picked_up_object == plug:
				return port
	if _vga_port != null and _vga_port.picked_up_object == plug:
		return _vga_port
	return null


## Which video socket is holding `plug`, or null. Lets a host that seated a captive
## lead find its way back to the right socket without knowing the numbering.
func port_holding(plug: Node3D) -> XRToolsSnapZone:
	for i in COMPOSITE_INPUTS:
		var port := _video_port(i)
		if port != null and port.picked_up_object == plug:
			return port
	if _vga_port != null and _vga_port.picked_up_object == plug:
		return _vga_port
	return null


## Which INPUT is holding `plug`, for a host writing itself to a save file. The DE-15
## answers Source.VGA, its own input; anything else it cannot find falls back to
## Composite 1, which is where a restore with no opinion puts a lead anyway.
func input_holding(plug: Node3D) -> int:
	for i in COMPOSITE_INPUTS:
		var port := _video_port(i)
		if port != null and port.picked_up_object == plug:
			return i
	if _vga_port != null and _vga_port.picked_up_object == plug:
		return Source.VGA
	return Source.COMPOSITE_1


## Called when a cable plug snaps into one of the video sockets. `input` is bound
## per socket at connect time, so the handler knows which one without asking.
func _on_plug_snapped(plug: Node3D, input: int) -> void:
	# Hand the incoming host a clean screen so the C++ video handler doesn't
	# capture our CRT wrapper as the "original" material to restore later.
	_drop_sampled()
	if plug is CablePlug:
		var plugged := plug as CablePlug
		_snapped_plugs[input] = plugged
		# Prevent the frozen kinematic plug from physically pushing the TV
		add_collision_exception_with(plugged)
		var system := plugged.get_system()
		if system:
			_connected_systems[input] = system
			# Multi-output systems need to know WHICH cable landed; other
			# hosts (VCR/DVD) keep the plain single-arg contract.
			if system is RetroSystem:
				(system as RetroSystem).on_tv_connected(self, plugged)
			elif system.has_method("on_tv_connected"):
				# Guarded: only a host with a captive lead implements this. The decks
				# dropped it when they moved to sockets and a spawned cable, and an
				# unguarded call errors on any plug that names one as its system.
				system.on_tv_connected(self)
			# A console plugged in while the set is showing something else must stay
			# off the glass until SOURCE selects it, or it repaints the screen from
			# under whatever is playing. Stated through the same pass SOURCE uses,
			# so the answer is given in BOTH directions: a host told only when it is
			# unselected has to guess when that stops being true, and one that
			# remembers the "no" — every host must, since it can arrive while the
			# machine is off — would never hear it lifted.
			# …and it must be silent too until SOURCE picks it, for the same reason.
			_apply_audio_volume()
			NetworkManager.report_event(NetObjectSync.EV_TV_PLUG,
				{"owner": system, "tv": self, "ch": plugged.channel, "in": input})


## Called by a deck that has worked out it is feeding this set through a composite
## lead. Takes the place of _on_plug_snapped's host lookup, which only works for a
## captive lead whose plug carries a back-reference to its owner; a composite
## cable's plugs belong to no device, so the deck tells the set instead.
func on_av_source_found(source: Node3D) -> void:
	var input := _input_for_device(source)
	if input < 0:
		return                  # nothing of ours is actually joined to it
	# Hand the incoming host a clean screen, exactly as the plug path does, so the
	# video handler doesn't capture our CRT wrapper as the material to restore.
	_drop_sampled()
	_connected_systems[input] = source
	source.set_audio_volume(_volume_for(input))
	_apply_audio_channel_mode()
	# Same rule as the captive-lead path, and stated the same way: a deck cabled up
	# to an input nobody is watching waits its turn rather than painting over the one
	# they are, and hears so when its turn comes.


## Called by that deck when the last cord between the two is pulled.
func on_av_source_lost(source: Node3D) -> void:
	var found := false
	for i in _connected_systems.size():
		if _connected_systems[i] == source:
			_connected_systems[i] = null
			found = true
	if not found:
		return                  # already replaced by something else
	_drop_sampled()


## Which input a device's signal is arriving on, or -1 if none of ours reaches it.
##
## Worked out from the cable rather than passed in, because the caller does not know
## it: a deck announces itself through on_av_source_found having resolved only that
## this television is its sink, and CompositeCable._resolve tells the SOURCE end
## first — so the set is told before its own on_av_topology_changed runs, and reading
## the answer off a stored link list would be both a frame late and one ordering
## assumption deep.
##
## VIDEO wins over audio when a device reaches more than one input, because the
## picture is what the input is named for. But audio alone still counts: a deck with
## its sound in Composite 2 and its video cord out is on Composite 2, and used to be
## heard there — which is the whole reason the L/R sockets are separate.
func _input_for_device(dev: Node3D) -> int:
	if dev == null or not is_instance_valid(dev):
		return -1
	# A captive lead names its own host and carries no CompositeCable at all, so it
	# is not in the graph. Over every input the set has sockets for, which includes
	# the aerial one: a console reached through an RF switch is found here exactly
	# as one on a composite lead is.
	for i in _av_ports.size():
		var captive: CablePlug = _snapped_plugs[i]
		if captive != null and is_instance_valid(captive) and captive.get_system() == dev:
			return i

	# Everything else comes off the graph, which walks every cable the device is
	# on rather than every socket this set owns — the same answer from one walker
	# instead of a second copy of it here.
	var audio_match := -1
	for link: Dictionary in AvGraph.links_for(dev):
		if (link["out"] as RcaPort).get_device() != dev:
			continue
		var in_port := link["in"] as RcaPort
		for i in _av_ports.size():
			if not (_av_ports[i] as Array).has(in_port):
				continue
			if in_port.channel == RcaPort.Channel.VIDEO:
				return i
			if audio_match < 0:
				audio_match = i
	return audio_match


## Nothing to do here: a set is a sink, and every routing decision is the source's.
## It exists so RcaPort.get_device() recognises a television as a device at all —
## that is the whole of the interface.
func on_av_topology_changed(_links: Array) -> void:
	pass


## Called when a cable plug leaves one of the video sockets.
func _on_plug_released(input: int) -> void:
	# Unwrap before the host tears down so it restores over its own material,
	# not our CRT wrapper.
	_drop_sampled()
	var plugged: CablePlug = _snapped_plugs[input]
	if plugged:
		remove_collision_exception_with(plugged)
		var system := plugged.get_system()
		if system:
			if system is RetroSystem:
				(system as RetroSystem).on_tv_disconnected(plugged)
			elif system.has_method("on_tv_disconnected"):
				system.on_tv_disconnected()
		_connected_systems[input] = null
		_snapped_plugs[input] = null
		NetworkManager.report_event(NetObjectSync.EV_TV_UNPLUG, {"tv": self, "in": input})


# Remote-control entry points (TVRemote): identical to pressing the bezel
# buttons, so the volume label / power button color stay in sync.

func remote_power_toggle() -> void:
	_on_tv_toggle()


func remote_volume_up() -> void:
	_on_volume_up()


func remote_volume_down() -> void:
	_on_volume_down()


func remote_mute_toggle() -> void:
	_on_mute_toggle()


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
		_apply_audio_volume()
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
	_apply_audio_volume()
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
		return source < _panel_inputs()
	if source == Source.RF:
		return _has_aerial()
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
	_apply_audio_volume()

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
		return "RF  CH %d%s" % [rf_channel, "" if _rf_tuned() else "  NO SIGNAL"]
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
		_tuner.set_volume(_volume_for(Source.TV))
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
	_update_mute_button_color()
	_update_audio_mode_button()
	_update_aspect_button()
	_apply_aspect()
	if _tuner != null:
		_tuner.set_active(_tv_enabled and current_source == Source.TV)
	_apply_audio_channel_mode()
	_apply_audio_volume()


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


## What the set's own amplifier is passing: silence while off or muted.
func _effective_volume() -> float:
	return 0.0 if (not _tv_enabled or _muted) else _volume


## …and what reaches one input, which is nothing at all unless that input is the
## one SOURCE has selected.
##
## The set has five sound sources and only ever plays one. Deselecting an input
## used to silence only its PICTURE (set_screen_enabled) and leave its sound
## running, so switching a console to the tuner played the channel over the top
## of the game you had just been playing.
func _volume_for(source: int) -> float:
	return _effective_volume() if current_source == source else 0.0


## Push the current volume to every connected device and to the built-in tuner, so
## one knob governs whichever input is showing and the other four are quiet.
func _apply_audio_volume() -> void:
	# Every slot, not just the composite ones: a console reached through an RF switch
	# is on Source.RF and has to be silenced with the rest when it is not showing.
	for i in _connected_systems.size():
		var system: Node3D = _connected_systems[i]
		if system != null and is_instance_valid(system):
			system.set_audio_volume(_volume_for(i))
	if _tuner:
		_tuner.set_volume(_volume_for(Source.TV))


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


## Snow for an aerial channel with nothing on it. Built on first use, like the tuner
## — a set that never leaves the composite inputs should not pay for it.
func _rf_static() -> ShaderMaterial:
	if _rf_static_material == null:
		_rf_static_material = ShaderMaterial.new()
		_rf_static_material.shader = STATIC_SHADER
	return _rf_static_material


## True when the set is tuned to the channel the connected RF switch is using.
##
## Read off the host duck-typed, and a host that has no opinion counts as a match:
## the channel switch belongs to the CONSOLE (an NES wears one on its back panel),
## so a deck or a machine without one fed through an RF switch should simply appear
## rather than being invisibly wrong on both channels.
func _rf_tuned() -> bool:
	var host: Node3D = _connected_systems[Source.RF] \
		if _connected_systems.size() > Source.RF else null
	if host == null or not is_instance_valid(host):
		return false
	if not host.has_method("get_rf_channel"):
		return true
	var ch := int(host.call("get_rf_channel"))
	# -1 is "this machine has no channel switch". A match, not a mismatch: otherwise
	# a deck fed through an RF switch would be invisible on BOTH channels.
	return ch < 0 or ch == rf_channel


## The connected console's channel switch moved. Repaint, because the same switch
## position decides whether there is a picture at all and this is the only thing
## that tells the set it changed.
func on_rf_channel_changed() -> void:
	if current_source != Source.RF:
		return
	_apply_audio_volume()
	show_osd_timed(_source_banner(), 2.0)


## The host feeding the selected input, if there is one and it is still alive.
func _selected_system() -> Node3D:
	var input := _selected_input()
	if input < 0:
		return null
	var system: Node3D = _connected_systems[input]
	return system if system != null and is_instance_valid(system) else null


## A volume key clears mute (like a real set) so the change is audible.
func _clear_mute_silently() -> void:
	if _muted:
		_muted = false
		hide_osd()


func _on_volume_down() -> void:
	_clear_mute_silently()
	_volume = maxf(0.0, _volume - 0.1)
	if _tv_enabled:
		show_volume_osd()
	if _tv_enabled:
		_apply_audio_volume()
	NetworkManager.report_event(NetObjectSync.EV_TV_VOL_DOWN, {"tv": self})


func _on_volume_up() -> void:
	_clear_mute_silently()
	_volume = minf(1.0, _volume + 0.1)
	if _tv_enabled:
		show_volume_osd()
	if _tv_enabled:
		_apply_audio_volume()
	NetworkManager.report_event(NetObjectSync.EV_TV_VOL_UP, {"tv": self})


## Toggle mute: silence (or restore) the connected device and show/clear a sticky
## "MUTE" OSD in the same corner "POWER" uses. No-op audibility change while off.
## Red while muted, matching the remote's own mute tint. Driven from here rather
## than the button so the remote's mute lands on the same cap.
func _update_mute_button_color() -> void:
	if _mute_btn:
		_mute_btn.set_color(Color(1.0, 0.35, 0.35) if _muted else Color(0.35, 0.35, 0.35))


func _on_mute_toggle() -> void:
	_muted = not _muted
	_update_mute_button_color()
	_update_audio_mode_button()
	_apply_audio_volume()
	if _muted:
		show_osd("MUTE")
	else:
		hide_osd()
	NetworkManager.report_event(NetObjectSync.EV_TV_MUTE, {"tv": self})


func _on_tv_toggle() -> void:
	_tv_enabled = not _tv_enabled
	_tv_toggle_btn.set_color(Color(0.0, 1.0, 0.0) if _tv_enabled else Color(1.0, 0.1, 0.1))
	if _tv_enabled:
		_play_power_on_anim()
		# Coming back on while muted keeps the sticky MUTE indicator, otherwise
		# show the usual POWER flash.
		if _muted:
			show_osd("MUTE")
		else:
			show_osd_timed("POWER", 3.0)
	else:
		_stop_power_on_anim()
		hide_osd()
		_vol_osd_token += 1
		_set_vol_osd_text("")
	# Powering back on must not un-mute a composite input while the set is showing
	# the tuner (or another input) -- it would start repainting the screen underneath.
	if _tuner:
		_tuner.set_active(_tv_enabled and current_source == Source.TV)
	_apply_audio_volume()
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
