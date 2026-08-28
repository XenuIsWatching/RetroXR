## RetroTVShell — the visual cabinet for a RetroTV.
##
## A shell supplies geometry and anchors ONLY. Every functional node — the screen,
## the composite port, the ambilight, the bezel buttons, the colliders — stays on
## the RetroTV itself, because tv.gd reaches them by fixed `$Name` paths and the
## whole point of the variant system is that a new cabinet costs no script changes.
##
## A shell says where those nodes belong on THIS cabinet by carrying `Marker3D`
## children with known names. Anything it does not name is left exactly as authored
## in tv.tscn, so a shell only has to describe what actually differs. This is the
## same "authored marker wins over the computed default" idiom the console models
## use for CartSeat/DiscSeat/UMDSeat (see system_models/atari_2600_model.gd).
##
## Marker names, all optional:
##   ScreenSeat     — pose for ScreenMesh. Its SCALE sizes the tube; the OSD labels
##                    are children of ScreenMesh and ride that scale for free.
##   PortSeat       — pose for CompositePort, the VIDEO socket of Composite 1. The
##                    other eleven step off it by av_socket_step / av_group_step.
##   AmbilightSeat  — pose for the Ambilight SpotLight3D.
##   ButtonRow      — pose of the FIRST bezel button (volume-down). The rest step
##                    along the marker's local +X by `button_pitch`.
##   SpeakerLSeat   — pose for the SpeakerL marker, the point the left channel
##   SpeakerRSeat     radiates from, and the same for the right. Name BOTH or
##                    neither: a shell that names one gets the computed pair for
##                    its tube instead, since half an authored stereo image is
##                    worse than none. Left is the listener's left, i.e. -X on a
##                    set facing +Z.
class_name RetroTVShell
extends Node3D


## Outer dimensions of the cabinet, driving the pickup collider and the pointer
## box. Defaults to tv.tscn's original 0.5 x 0.4 x 0.3 body.
@export var body_size: Vector3 = Vector3(0.5, 0.4, 0.3)

## Spacing between bezel buttons along the ButtonRow marker's local +X.
@export var button_pitch: float = 0.07

## Caps per row before wrapping to the next one, and how far down the marker's
## local -Y that next row sits.
##
## The row used to run until it ran out, which was fine at six caps and stopped
## being fine at eleven — the last of them walked off the end of the cabinet.
## Wrapping keeps every control on the bezel whatever a shell's width.
@export var buttons_per_row: int = 7
@export var button_row_drop: float = 0.055

## Small cabinets (a computer monitor) have no room for the 25 mm button caps on
## a 70 mm pitch. Turn the row off and TVOptionsPanel — already pointer-driven —
## becomes the only control surface for this shell.
@export var show_button_row: bool = true

## Mesh nodes inside the shell GLB to hide. Chiefly the cabinet's own glass: the
## live picture has to land on RetroTV's ScreenMesh, and a modelled pane sitting
## in front of it would either z-fight or hide it outright.
@export var hide_meshes: PackedStringArray = []

## How the four A/V input groups sit on this cabinet's back, measured in the
## PortSeat's own frame. `av_socket_step` walks VIDEO → L → R inside one group,
## `av_group_step` walks Composite 1 → 2 → 3 → 4.
##
## The defaults are the flat row the stock box and the 90s cabinet both take: a
## raycast grid over both backs reads -10.0 mm — the exact standoff a port wants —
## at every one of the twelve sockets, the whole 240 mm of it. A cabinet whose back
## runs out sooner stands its groups on end instead, which is what the computer
## monitor does: its panel measures flat for 180 mm and the row needs 216.
@export var av_socket_step: Vector3 = Vector3(-0.018, 0.0, 0.0)
@export var av_group_step: Vector3 = Vector3(-0.06, 0.0, 0.0)

## How many of the set's composite inputs this cabinet physically carries sockets
## for. Fewer than RetroTV.COMPOSITE_INPUTS turns the rest off — no sockets, no
## printing — and SOURCE steps straight past them, because an input you can select
## but cannot plug anything into is worse than one that isn't there.
##
## ONE by default, so the four-input bank belongs to the stock cabinet alone. That is
## a modelling decision rather than a measured limit for the 90s television, whose
## back does have the room; the computer monitor genuinely has not. A raycast grid
## says that monitor's back is flat in DEPTH for 180 mm, which is misleading — the
## moulding stays the same distance out while turning out of the plane — so the
## facet printing can actually sit on is the 123 x 46 mm panel around the power
## inlet, and four groups ran round the corner of the case.
##
## ZERO is allowed and means what it says: a cabinet with no phono sockets at all.
## The computer monitor is one — it takes its picture over VGA, and a row of phono
## jacks on the back of a VGA monitor is an anachronism. SOURCE then steps straight
## past every composite input, exactly as it does for the ones a smaller panel drops.
@export var av_inputs: int = 1

## Whether this cabinet carries the aerial socket, Source.RF.
##
## ON by default: every television has one, and it is what an RF switch plugs into.
## The computer monitor is the exception and turns it off — a coax tuner input on a
## VGA monitor is the same anachronism as the phono row.
@export var has_aerial: bool = true

## Whether the AV IN legend gets its printed backing plate. OFF by default because a
## moulded CRT back is curved — both cabinets here taper 16 mm and 46 mm across the
## plate's own footprint, so a flat rectangle floats off the curve or cuts into it,
## and the legend falls back to outlined words. The stock body, being a flat box,
## keeps its plate. A shell with a genuinely flat back panel turns this on.
@export var av_legend_plate: bool = false


func _ready() -> void:
	if hide_meshes.is_empty():
		return
	for node in find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if hide_meshes.has(mi.name):
			mi.visible = false


func screen_seat() -> Variant:      return _seat("ScreenSeat")
func port_seat() -> Variant:        return _seat("PortSeat")
## Absent on every shell but the computer monitor, and that absence is the switch:
## RetroTV leaves its VgaPort disabled and hidden unless a shell asks for one.
func vga_port_seat() -> Variant:    return _seat("VgaPortSeat")
func ambilight_seat() -> Variant:   return _seat("AmbilightSeat")
func button_row_seat() -> Variant:  return _seat("ButtonRow")
func speaker_l_seat() -> Variant:   return _seat("SpeakerLSeat")
func speaker_r_seat() -> Variant:   return _seat("SpeakerRSeat")


## Transform of a named marker relative to this shell's root, or null if absent.
##
## Walks the parent chain rather than reading `marker.transform` directly, so a
## marker may be nested under the imported GLB hierarchy (which is where it will
## naturally end up if it is parented to a cabinet part in the editor).
func _seat(marker_name: String) -> Variant:
	var marker := find_child(marker_name, true, false) as Node3D
	if marker == null:
		return null
	var xf: Transform3D = marker.transform
	var p: Node = marker.get_parent()
	while p != null and p != self:
		if p is Node3D:
			xf = (p as Node3D).transform * xf
		p = p.get_parent()
	return xf


# ── optional overrides ────────────────────────────────────────────────────────
#
# Both default to doing nothing, because the common case is a cabinet that only
# brings geometry. A shell overriding neither behaves exactly as a shipped one.


## The shader this cabinet's screen is painted with, or null for the stock CRT.
##
## NULL IS THE NORMAL ANSWER. A cabinet that just wants a different box gets the
## same picture every other set has, with no shader knowledge at all. Returning
## something is for a set that genuinely looks different — a monochrome portable,
## a projection set — and a shell wanting a built-in DELIBERATELY should ask for
## it by name (ModApi.shader("crt")) rather than loading the path, since the
## shader tree is free to move.
func screen_shader() -> Shader:
	return null


## The bezel buttons RetroTV built for this cabinet, handed over once they exist.
##
## RetroTV builds them, because their behaviour is the television's; this is
## where a shell adorns them — its own meshes, its own click. Note the stock sets
## have no button audio at all, so a cabinet adding some is not overriding
## anything: make a PcmOneShot, hang it off the button's signal, and keep the
## voice a child of this shell so it dies with the cabinet.
func on_buttons_built(_buttons: Array) -> void:
	pass
