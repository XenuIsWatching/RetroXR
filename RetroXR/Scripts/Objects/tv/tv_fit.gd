## TvFit — fitting a RetroTV's functional nodes onto a cabinet shell.
##
## A child of the RetroTV it serves, created unconditionally in _init, in the same
## shape as TvResize.
##
## Everything here runs once, from RetroTV._ready. The set is built and then this
## is done with it — the one exception is speaker_positions(), which reads back the
## markers seated here and is asked every time something places the set's sound.
##
## The shell itself stays on RetroTV as `_shell`: the back panel reads it for its
## input count and legend plate, and the display reads it for a screen shader.
class_name TvFit
extends Node

## The set this fits. Every node moved below is one of its children.
var _tv: RetroTV = null

## Cabinet ids that were renamed. Mapped before the lookup, so a saved room still
## finds its shell; "" is the stock body.
const _LEGACY_TV_MODELS := {
	"crt_90s": "",
	"crt_monitor": "crt_plain",
}

## Whether the shell named BOTH speaker seats. place_default_speakers() computes
## the pair when it did not.
var _speakers_seated: bool = false



## The shell body this set is wearing, or null for the stock cabinet.
##
## Owned here because this helper is the only thing that ever builds one — it
## used to be stored on RetroTV, which never read it, purely so the other
## helpers could see it. They ask the set, and the set asks here.
var _shell: RetroTVShell = null


func shell() -> RetroTVShell:
	return _shell

func setup(tv: RetroTV) -> void:
	_tv = tv


## Put a node on a marker's pose, if the shell named one. Static because the back
## panel seats its own sockets the same way.
static func seat(node: Node3D, at: Variant) -> void:
	if node != null and at is Transform3D:
		node.transform = at


## Wear a cabinet variant. Strict no-op when tv_model is empty — that is the
## acceptance test for this whole mechanism, since the arcade and den TVs must
## look and behave exactly as they did before.
##
## Only nodes the shell actually names a seat for are moved; everything else keeps
## its tv.tscn pose, so a shell describes differences rather than the whole layout.
func load_shell() -> void:
	if _LEGACY_TV_MODELS.has(_tv.tv_model):
		_tv.tv_model = _LEGACY_TV_MODELS[_tv.tv_model]
	if _tv.tv_model.is_empty():
		return
	var path: String = RetroTV._mod_shell_path(_tv.tv_model)
	if path.is_empty():
		path = RetroTV._SHELL_SCENES.get(_tv.tv_model, "")
	if path.is_empty():
		push_warning("RetroTV: unknown tv_model '%s' — falling back to the stock body" % _tv.tv_model)
		return
	var packed := load(path) as PackedScene
	if packed == null:
		push_warning("RetroTV: failed to load shell scene: %s" % path)
		return
	_shell = packed.instantiate() as RetroTVShell
	if _shell == null:
		push_warning("RetroTV: shell scene root is not a RetroTVShell: %s" % path)
		return
	_tv.add_child(_shell)
	_tv.get_node("TVBody").hide()

	var shell: RetroTVShell = _shell
	seat(_tv.screen_mesh(), shell.screen_seat())
	seat(_tv._tube_collar, shell.screen_seat())
	_tv.panel().seat_av_row(shell.port_seat())
	_tv.panel().seat_vga_port(shell.vga_port_seat())
	seat(_tv.ambilight(), shell.ambilight_seat())

	# Both or neither: one seated speaker and one still on the stock tube's edge
	# would be a lopsided stereo image nobody authored. place_default_speakers
	# falls back to the computed pair when this stays false.
	var spk_l: Variant = shell.speaker_l_seat()
	var spk_r: Variant = shell.speaker_r_seat()
	_speakers_seated = spk_l is Transform3D and spk_r is Transform3D
	if _speakers_seated:
		seat(_tv._speaker_l, spk_l)
		seat(_tv._speaker_r, spk_r)

	# Bezel buttons march along the row marker's local +X from the first cap, and
	# wrap onto a second row below it. Same order the stock cabinet authors, so a
	# shelled set and the plain box read alike.
	var row: Variant = shell.button_row_seat()
	var buttons: Array[Node3D] = _bezel_buttons()
	if not shell.show_button_row:
		for btn in buttons:
			(btn as VRButton).set_active(false)
	elif row is Transform3D:
		var base: Transform3D = row
		var per_row: int = maxi(1, shell.buttons_per_row)
		for i in buttons.size():
			var b: Node3D = buttons[i]
			# Keep each cap's authored basis (they are rotated to face outward);
			# only the origin walks the row.
			@warning_ignore("integer_division")
			b.transform = Transform3D(b.transform.basis, base * Vector3(
				float(i % per_row) * shell.button_pitch,
				float(i / per_row) * -shell.button_row_drop,
				0.0))

	_resize_body_collision(shell.body_size)


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
		_tv._tv_toggle_btn, _tv._source_btn, _tv._ch_down_btn, _tv._ch_up_btn,
		_tv._vol_down_btn, _tv._vol_up_btn, _tv.mute_btn(),
		_tv.audio_mode_btn(), _tv._crt_btn, _tv._aspect_btn, _tv.stereo_btn(),
	]


## Resize the pickup collider and the pointer box to the cabinet.
##
## BoxShape3D_body and BoxShape3D_pointer are plain sub_resources in tv.tscn, i.e.
## SHARED between every TV in the scene — writing a size straight onto them would
## resize the den's TV too. Duplicate first. (Same trap the resource_local_to_scene
## note on Mat_phosphor_a already documents for the phosphor materials.)
func _resize_body_collision(size: Vector3) -> void:
	var body_col := _tv.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if body_col and body_col.shape is BoxShape3D:
		var s := (body_col.shape as BoxShape3D).duplicate() as BoxShape3D
		s.size = size
		body_col.shape = s
	var ptr_col := _tv.get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if ptr_col and ptr_col.shape is BoxShape3D:
		var p := (ptr_col.shape as BoxShape3D).duplicate() as BoxShape3D
		# The stock pointer box is 20 mm proud of the body on each axis.
		p.size = size + Vector3(0.02, 0.02, 0.02)
		ptr_col.shape = p


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
func speaker_positions() -> PackedVector3Array:
	var out := PackedVector3Array()
	if _tv._speaker_l != null and _tv._speaker_r != null:
		out.push_back(_tv._speaker_l.global_position)
		out.push_back(_tv._speaker_r.global_position)
		return out
	# No markers (a scene predating them): the defaults, computed in place.
	var frame := _tv.global_transform.basis
	var face: Vector3 = _tv.screen_mesh().global_position + frame.z * 0.005
	var right: Vector3 = frame.x * (_tv.screen_size_m().x * 0.5 + 0.055)
	var down: Vector3 = -frame.y * (_tv.screen_size_m().y * 0.35)
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
func place_default_speakers() -> void:
	if _shell == null or _speakers_seated:
		return
	if _tv._speaker_l == null or _tv._speaker_r == null:
		return
	var half_w: float = _tv.screen_size_m().x * 0.5 + 0.055
	var drop_m: float = _tv.screen_size_m().y * 0.35
	var face: Vector3 = _tv.screen_mesh().position + Vector3(0.0, 0.0, 0.005)
	_tv._speaker_l.position = face + Vector3(-half_w, -drop_m, 0.0)
	_tv._speaker_r.position = face + Vector3(half_w, -drop_m, 0.0)
