## RetroSystemModelHandheld — shared base for handheld consoles (Game Boy family).
##
## A handheld is a RetroSystem whose model provides a BUILT-IN screen: the core
## renders to the on-device LCD when no TV is connected, and the video-out
## cable moves the picture to a TV (Super Game Boy style).
##
## The visible shell — body, screen, bezel, cosmetic d-pad/buttons, cartridge
## slot mouth, and the on-device volume slider + power switch — is authored in
## the per-device scene under Scenes/Objects/system_models/ (e.g. game_boy.tscn).
## This script no longer BUILDS geometry: it caches the authored nodes, reads the
## body/screen dimensions back from them, wires the control signals to the owning
## RetroSystem, keeps the live LCD picture filtered, and repositions the shared
## cabinet nodes (collision, cartridge slot, cable port) to fit the device.
##
## Subclasses set only NON-geometry data in _init (cartridge dimensions, the DMG
## LCD shader) — the shape and layout live in the scene.
class_name RetroSystemModelHandheld
extends RetroSystemModel

# Device local frame: lying flat, screen on the +Y (top) face, top edge of the
# screen toward -Z, cartridge slot on the back edge (-Z), video-out on the left.

## Body size in metres (x = width, y = thickness, z = length). Read back from the
## authored HandheldBody mesh at _ready; the scene is the source of truth.
var body_size := Vector3(0.09, 0.032, 0.148)
## Screen quad size (x = width, z = height on the device face). Read back from the
## authored HandheldScreen mesh at _ready.
var screen_size := Vector2(0.047, 0.043)
## Cartridge size (width, length-into-slot, thickness) — should match the
## system's MediaDimensions.CART_SIZES entry. Drives the slot-mouth visual
## and how deep the cart seats. Default = Game Boy cart. Set per-device in _init.
var cart_size := Vector3(0.057, 0.065, 0.008)

var _screen: MeshInstance3D = null
var _power_switch: VRSlider = null
var _volume_slider: VRSlider = null
var _host: Node3D = null

# Per-device LCD display filter (e.g. the DMG dot-matrix look). A subclass may
# replace _lcd_shader; the base wraps the built-in screen's material with it — the
# same watch-and-rewrap the TV uses for its CRT, since the C++ video handler
# re-asserts its own StandardMaterial3D (emission = picture) each frame.
#
# The DEFAULT is screen_pixel_aa: no device look, purely to get the core frame
# sampled properly. A handheld's screen sits near 1:1 with the headset's pixels
# (a 54 mm GBA panel at arm's length is ~0.94x — see Scripts/XR/xr_init.gd), and at
# non-integer ratios neither hardware filter works: linear is uniformly soft, and
# nearest drops source rows and crawls as the head moves. pixel_aa.gdshaderinc
# explains the fix; gameboy_lcd samples the same way, so a device look does not
# cost sharpness.
const PIXEL_AA_SHADER: Shader = preload("res://Shaders/screen_pixel_aa.gdshader")

var _lcd_shader: Shader = PIXEL_AA_SHADER
var _lcd_material: ShaderMaterial = null
## What the panel shows with nothing running — the authored, unlit LCD.
var _screen_off_material: Material = null

## The detailed shell, when this scene bakes one as a child named "Shell". Null on
## a plain model, whose geometry is authored directly in the scene — the two are
## separate models, not two modes of one.
var _glb: Node3D = null

## Screen-cast light: the built-in LCD tints a SpotLight3D aimed OUT of the glass,
## so a powered handheld throws a glow on whatever it's pointed at — the
## personal-scale sibling of the TV's ambilight. This started as an OmniLight,
## which sat INSIDE the shell and lit the whole device from within instead of
## casting anywhere.
## Off when the screen shows no picture; ScreenCastLight transfers only a tiny
## GPU-blurred result and derives output from this panel's physical area.
## Clearance from the glass — the cone must start outside it (see the TV's
## ambilight, which sits just proud of its screen).
const SCREEN_LIGHT_OFFSET := 0.006
var _screen_light: ScreenCastLight = null


func is_handheld() -> bool:
	return true




## Name of a shell's screen-lens mesh. The convention is "screen_mesh"; some
## shells suffix it ("screen_mesh_0"). Override to match.
func _glb_screen_name() -> String:
	return "screen_mesh"


## Called once the shell is in place — EITHER shell. Subclasses cache their
## control meshes here for animate_controls() and mount their sliders/buttons on
## them. A stand-in scene authors its controls under the same names the detailed
## shell uses, so the same pass wires both and neither needs a special case.
func _on_shell_ready() -> void:
	pass

## Handheld shells are conventionally modelled upright (screen on +Z); RetroXR's
## frame is lying flat with the screen on +Y, so the default lays it back. Override
## if a particular shell is authored differently.
func _glb_rotation_degrees() -> Vector3:
	return Vector3(-90, 0, 0)


func _ready() -> void:
	_cache_shell_nodes()
	# A plain model IS its shell — geometry authored alongside these functional
	# nodes — so there is nothing to adopt. A detailed scene instances its GLB as
	# a child named "Shell" and adopts that.
	if has_baked_shell():
		_adopt_baked_shell()
	else:
		_on_shell_ready()          # this model's own controls, already in place
	# An authored "CartSeat" marker (see configure_cartridge_slot) may carry a
	# visible "SeatPreview" box so the seated-cart pose can be dialled in inside
	# the Godot 3D editor. It's an editor aid only — hide it at runtime.
	_hide_seat_previews()
	_setup_screen_light()


func _setup_screen_light() -> void:
	_screen_light = _make_screen_light(_screen)


## Create + configure a screen-cast spot just off `screen`'s glass, aimed out along
## the screen's own normal. Parented to the screen so it tracks a GLB-repositioned
## (or lid-mounted) screen automatically. Reusable for devices with more than one
## screen (see RetroSystemModelDualScreen).
func _make_screen_light(screen: MeshInstance3D) -> ScreenCastLight:
	ScreenCastLight.mark_screen(screen)
	if screen == null:
		return null
	var light := ScreenCastLight.new()
	light.name = "ScreenCastLight"
	# A QuadMesh screen faces its local +Z, but a SpotLight3D emits along its local
	# -Z — so flip it, or the cone points back through the device.
	light.rotation_degrees = Vector3(180.0, 0.0, 0.0)
	light.position = Vector3(0.0, 0.0, SCREEN_LIGHT_OFFSET)
	screen.add_child(light)
	light.configure_screen(_physical_screen_size(screen))
	return light


## Authored panel dimensions in metres. QuadMesh sizes are physical in these
## model scenes; screen_size remains the fallback for a custom screen mesh.
func _physical_screen_size(screen: MeshInstance3D) -> Vector2:
	var s := screen_size
	if screen.mesh is QuadMesh:
		s = (screen.mesh as QuadMesh).size
	return Vector2(s.x * absf(screen.scale.x), s.y * absf(screen.scale.y))


## Cache the authored shell nodes and read the device dimensions back from their
## meshes, so runtime placement (collision/slot/cable) tracks the scene geometry.
func _cache_shell_nodes() -> void:
	_screen = get_node_or_null("HandheldScreen") as MeshInstance3D
	# The dark panel, kept so the model can put it back when nothing is running.
	# The C++ video handler used to hold this and restore it on teardown, which is
	# why a machine that never tore down cleanly left its last frame frozen there.
	if _screen != null:
		_screen_off_material = _screen.get_surface_override_material(0)
	_volume_slider = get_node_or_null("VolumeSlider") as VRSlider
	_power_switch = get_node_or_null("PowerSwitch") as VRSlider
	# Authored rather than built here, so it joins the group by hand — see
	# RetroSystemModel.POWER_SWITCH_GROUP for what reads it.
	if _power_switch != null:
		_power_switch.add_to_group(POWER_SWITCH_GROUP)
	# find_child, not get_node: the stand-in shell is a "Primitive" subtree now.
	var body := find_child("HandheldBody", true, false) as MeshInstance3D
	if body and body.mesh is BoxMesh:
		body_size = (body.mesh as BoxMesh).size
	if _screen and _screen.mesh is QuadMesh:
		screen_size = (_screen.mesh as QuadMesh).size


## Adopt the detailed shell this scene already instances as a child named "Shell":
## measure the real geometry (collision / cart slot / cable placement track it) and
## fix its materials.
##
## This used to be _upgrade_to_glb(), which ALSO carried a ~55-line path that
## runtime-loaded a GLB, reparented it, recentred it and re-derived the screen quad
## from the shell's own screen mesh. That path was dead: every detailed scene bakes
## its Shell, so the function always took its early return. It was also the only
## caller of _glb_path(), which was the only reason seven model scripts named an
## asset path at all — so deleting it is what lets a model be removed by deleting
## its scene and its files, with no script left pointing at something missing.
func _adopt_baked_shell() -> void:
	_glb = _baked_shell
	var bb := _glb_local_aabb(_glb)
	if bb.size.length() > 0.0:
		body_size = bb.size
	_fix_shell_materials()
	_on_shell_ready()


func _adopt_knob(slider: VRSlider, glb_node_name: String) -> void:
	if slider == null:
		return
	var cap: MeshInstance3D = null
	if _glb != null:
		cap = _glb.find_child(glb_node_name, true, false) as MeshInstance3D
	if cap != null:
		slider.set_knob_mesh(cap)   # hides the placeholder itself
		return
	var k := slider.get_node_or_null("KnobMesh") as MeshInstance3D
	if k != null:
		k.visible = false


## Hide the GLB's bundled AV lead / plug (RetroXR spawns its own video-out cable).
func _hide_glb_clutter(root: Node3D) -> void:
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null:
			var nm := String(mi.name).to_lower()
			# "kabel" is not a typo: some imported shells were authored with German
			# node names ("AVKabel", "PowerKabel1/2"), and a future one may be too.
			if nm.contains("rca") or nm.contains("cable") or nm.contains("kabel") or nm.contains("plug"):
				mi.visible = false
		for c in n.get_children():
			stack.append(c)


## Combined AABB of the GLB's visible meshes, in this model node's local space.
func _glb_local_aabb(inst: Node3D) -> AABB:
	var acc := AABB(); var first := true
	var stack: Array[Node] = [inst]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		var mi := n as MeshInstance3D
		if mi != null and mi.visible:
			var ab: AABB = (global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			acc = ab if first else acc.merge(ab)
			first = false
		for ch in n.get_children():
			stack.append(ch)
	return acc


## Show the machine's picture on its own panel, through this device's LCD filter.
##
## Nothing else paints this mesh. It used to be handed to the C++ video handler,
## which installed an emissive material on it, which this then read back and
## wrapped — and a video-out cable moved the handler's target to the television,
## which is how the panel went dark. The panel is ours; the picture is asked for.
func _process(_delta: float) -> void:
	_update_screen()
	_update_screen_light()


func _update_screen() -> void:
	if _screen == null:
		return
	# The picture MOVES to a television rather than being mirrored, so a connected
	# set darkens the panel exactly as it always did.
	var tex := null if host_picture_on_tv() else host_picture()
	if tex == null:
		if _screen.get_surface_override_material(0) != _screen_off_material:
			_screen.set_surface_override_material(0, _screen_off_material)
		return
	if _lcd_shader == null:
		_screen.set_surface_override_material(0, picture_material(tex))
		return
	if _lcd_material == null:
		_lcd_material = ShaderMaterial.new()
		_lcd_material.shader = _lcd_shader
	if _lcd_material.get_shader_parameter("source_tex") != tex:
		_lcd_material.set_shader_parameter("source_tex", tex)
	if _screen.get_surface_override_material(0) != _lcd_material:
		_screen.set_surface_override_material(0, _lcd_material)


func _update_screen_light() -> void:
	_drive_screen_light(_screen, _screen_light)


## Drive one screen-cast light without reading its full-resolution picture back
## to the CPU. Dual-screen callers pass the panel's framebuffer region.
func _drive_screen_light(screen: MeshInstance3D, light: ScreenCastLight,
		region: Rect2 = Rect2(0.0, 0.0, 1.0, 1.0)) -> void:
	if light == null or screen == null:
		return
	var tex := _screen_emission_texture(screen.get_surface_override_material(0))
	if tex == null:
		light.turn_off()
		return
	light.show_picture(tex, region)


## The live picture texture out of whichever material the core installed (it uses
## an emissive StandardMaterial3D; our own wrapper carries source_tex).
func _screen_emission_texture(mat: Material) -> Texture2D:
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).emission_texture
	if mat is ShaderMaterial:
		return (mat as ShaderMaterial).get_shader_parameter("source_tex") as Texture2D
	return null


func get_controller_port_count() -> int:
	return 0


func get_builtin_screen() -> MeshInstance3D:
	return _screen


## How much of the seated cartridge pokes out of the back for grabbing.
func _cart_protrude() -> float:
	return clampf(cart_size.y * 0.28, 0.008, 0.02)


## Seated cart: only the protruding stub is grabbable — the cart's padded
## grab box otherwise pokes through the thin shell and steals desktop clicks
## / VR grabs aimed at the device.
func play_cartridge_insert(cartridge: Node3D, _slot: Node3D) -> void:
	if cartridge.has_method("set_seated_grab_stub"):
		cartridge.set_seated_grab_stub(_cart_protrude() + 0.004)


func play_cartridge_eject(cartridge: Node3D, _slot: Node3D) -> void:
	if cartridge.has_method("reset_grab_shapes"):
		cartridge.reset_grab_shapes()


## Seat the cartridge INSIDE the body, through the slot mouth on the back
## face: lying flat (label up), most of its length inside, _cart_protrude()
## sticking out for grabbing.
func configure_cartridge_slot(slot: Node3D) -> void:
	# Cartridge local frame: x = width, y = length (insert axis), z = thickness
	# with the label on +Z. This pose lays it flat with the length running into
	# the body (-Z) and the LABEL FACING DOWN toward the device's back shell —
	# like real handheld carts (the label is hidden while inserted).
	slot.rotation_degrees = Vector3(90, 180, 0)
	slot.position = Vector3(0, 0,
		-body_size.z / 2.0 + cart_size.y / 2.0 - _cart_protrude())
	# The console-scale 7 cm grab sphere (also the desktop click target for the
	# seated cart) envelopes most of a handheld — clicking anywhere near the
	# device grabbed the cart. Shrink it to just around the slot/stub.
	slot.grab_distance = 0.03
	var visual := slot.get_node_or_null("SlotVisual") as MeshInstance3D
	if visual:
		visual.visible = false
	# The snap ghost is a generic console-cartridge box — reshape it to this
	# system's cart so the blue "goes here" shadow matches what fits.
	var ghost := slot.get_node_or_null("SnapHighlight/HighlightMesh") as MeshInstance3D
	if ghost:
		var ghost_mesh := BoxMesh.new()
		ghost_mesh.size = cart_size
		ghost.mesh = ghost_mesh
	# The zone's grab sphere belongs on the slot MOUTH, not on the seat.
	#
	# function_pickup takes a seated object by grabbing its ZONE (see the snap-zone
	# branch of _pick_up_object), so this sphere is what a hand has to reach to pull
	# a cartridge back out. Left at the zone's origin it sits at the SEAT — most of
	# a card-length inside the shell — and only the sliver of it past the back face
	# can be reached. That sliver is 15-23 mm on the short-card handhelds and 7 mm
	# on the Atari Lynx, whose 86 mm card is the longest here and whose protrusion
	# is clamped: the difference between fiddly and impossible.
	#
	# Sliding it out to the mouth makes the reach uniform, and it is the truer place
	# for it either way — a cartridge goes in at the mouth and comes out at the
	# mouth, and nobody reaches into the middle of a shell for one. `grab_distance`
	# is deliberately untouched: that is the range at which this zone claims a
	# released cart and ranks against its neighbours (see find_preview_zone), and it
	# is measured from the zone's origin whatever the shape does.
	#
	# Local +Y is the insert axis, so the mouth is half a card out along it, less
	# the part that stays proud. snap_zone.tscn's sphere is resource_local_to_scene,
	# so writing this touches only our own zone.
	var grab_col := slot.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if grab_col != null:
		grab_col.position = Vector3(0, cart_size.y * 0.5 - _cart_protrude(), 0)
	# An authored "CartSeat" marker in the device .tscn wins over the computed pose
	# above, so the exact seated-cart transform can be placed visually in the Godot
	# 3D editor (drag/rotate CartSeat; its SeatPreview box shows the cart footprint).
	# Devices without the marker keep the generic pose — nothing else changes.
	# (The mouth offset above is LOCAL to the zone, so it rides an authored seat.)
	var seat := _seat_marker("CartSeat")
	if seat != null:
		slot.global_transform = seat.global_transform


## Cartridges slide in from behind the device.
func get_cartridge_insert_direction() -> Vector3:
	return Vector3(0, 0, -1)


## Video-out port on the rear edge (the Super Game Boy fantasy), clear of the
## centred cartridge slot mouth. On narrow bodies whose back edge is mostly
## slot (Game Boy, WonderSwan, Supervision, Pokémon Mini) the port moves to
## the right side edge instead.
##
## The exit axis moves WITH it. A lead leaves its attach point along that point's
## local -Z, so a side-mounted port left at identity put the cord out of the flank
## and then straight back along the body — see aim_cable_exit.
func configure_cable_attach(attach_point: Node3D) -> void:
	var back_x := maxf(body_size.x * 0.30, (cart_size.x + 0.005) / 2.0 + 0.010)
	if back_x <= body_size.x / 2.0 - 0.008:
		attach_point.position = Vector3(back_x, 0, -body_size.z / 2.0 - 0.002)
		aim_cable_exit(attach_point, Vector3(0, 0, -1))   # out of the back edge
	else:
		attach_point.position = Vector3(body_size.x / 2.0 + 0.002, 0, -body_size.z * 0.30)
		aim_cable_exit(attach_point, Vector3(1, 0, 0))    # out of the right flank
	# The scene's console-scale grey port barrel dwarfs a handheld shell —
	# hide it (the cable itself marks the port).
	var vis := attach_point.get_node_or_null("PortVisual") as MeshInstance3D
	if vis:
		vis.visible = false


## How far down the body the hands grip, as a fraction of its length from centre.
const GRIP_Z_FRACTION := 0.25


## Where a hand grips the device, in the system's local frame — the side edges,
## at mid-thickness, down toward the near edge where the hands actually sit (the
## far edge is the cartridge slot). RetroSystem hands this to GripAnchor so a
## held handheld sits in one hand or between two, rather than keeping whatever
## offset it was touched at.
func get_grip_anchor(is_left: bool) -> Transform3D:
	var x := body_size.x * 0.5
	return Transform3D(Basis(), Vector3(
		-x if is_left else x,
		0.0,
		body_size.z * GRIP_Z_FRACTION))


## Shrink the root collision box to the device and hide the console body.
## Called by RetroSystem after the model loads.
func configure_handheld_body(host: Node3D) -> void:
	var col := host.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		# The .tscn sub-resource is shared across instances — duplicate first.
		col.shape = col.shape.duplicate()
		(col.shape as BoxShape3D).size = body_size + Vector3(0.01, 0.01, 0.01)
		col.position = Vector3.ZERO
	var body := host.get_node_or_null("SystemBody") as MeshInstance3D
	if body:
		body.visible = false
	# The selection PointerArea keeps its console-sized box otherwise — a huge
	# invisible pointable slab that the desktop reticle / VR laser hits FIRST,
	# shadowing every on-device control (power switch, volume slider, START
	# button, touch screen). Shrink it to the body so controls, which all poke
	# out of the shell, win the raycast.
	var pcol := host.get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pcol and pcol.shape is BoxShape3D:
		pcol.shape = pcol.shape.duplicate()
		(pcol.shape as BoxShape3D).size = body_size
		pcol.position = Vector3.ZERO


## On-device controls: wire the authored volume slider + power switch to the
## owning RetroSystem. The knobs/travel/positions are authored in the scene;
## this only connects their signals.
func configure_handheld_controls(host: Node3D) -> void:
	_host = host
	if _volume_slider:
		_volume_slider.value_changed.connect(func(v: float) -> void:
			if _host and _host.has_method("set_audio_volume"):
				_host.set_audio_volume(v))
	if _power_switch is VRSpringReturnSlider:
		# A MOMENTARY switch reports an intent, not a position: it springs back on
		# release, so its value crosses the midpoint twice per push and means
		# nothing either time. Wire the completed hold instead.
		var momentary := _power_switch as VRSpringReturnSlider
		momentary.system_on = bool(_host.get("is_powered_on"))
		momentary.toggle_requested.connect(func() -> void:
			if _host != null and _host.has_method("toggle_power"):
				_host.toggle_power())
	elif _power_switch:
		_power_switch.value_changed.connect(_on_power_switch_changed)


func _on_power_switch_changed(v: float) -> void:
	if _host == null or not _host.has_method("toggle_power"):
		return
	# ObjectSync also carries the authoritative power action. Applying the
	# replicated switch position must only move the cap; otherwise this callback
	# toggles the remote core once here and again when EV_SYS_POWER arrives.
	if NetworkManager.is_event_applying():
		return
	var want_on := v > 0.5
	if want_on != bool(_host.get("is_powered_on")):
		_host.toggle_power()


## Reflect externally-driven power changes (e.g. cart removal powers off, or a
## multiplayer event) back onto the switch position, and apply the volume
## slider's current position to the freshly-created audio player.
func on_power_on() -> void:
	if _power_switch is VRSpringReturnSlider:
		# Nothing to park — the cap lives at rest and springs back after each
		# push. It only needs to know which dwell applies from here on.
		(_power_switch as VRSpringReturnSlider).system_on = true
	elif _power_switch:
		_power_switch.set_value_no_signal(1.0)
	if _volume_slider and _host and _host.has_method("set_audio_volume"):
		_host.set_audio_volume(_volume_slider.value)


func on_power_off() -> void:
	if _power_switch is VRSpringReturnSlider:
		(_power_switch as VRSpringReturnSlider).system_on = false
	elif _power_switch:
		_power_switch.set_value_no_signal(0.0)
	# Unlit LCD look returns automatically when the core releases the material.


# --- stand-in control animation ----------------------------------------------
#
# The stand-in scenes share one control vocabulary — DpadBar1 + DpadBar2 for the
# pad, then FaceButton1..4, StartButton, SelectButton and the shoulder pairs — so
# one binding pass covers every one of them. The animation itself is
# ControlAnimator, the same engine the pads in Scenes/Objects/controllers/ run
# on: per-entry press direction and depth, rockers about a pivot, sticks that
# tilt and click.
#
# A detailed shell names its meshes whatever its bundle called them and its own
# model script binds those, so this pass finds nothing on the GLB path. Where a
# subclass claims one of these names for its shell — the 3DS and PSP both call
# their Start/Select caps exactly this — it says so in _own_animated_meshes() and
# keeps them.
#
# Devices with more than a pad and buttons still need their own animate_controls
# for the extras (the 3DS circle pad and C-stick, the PSP nub); those call super()
# for this pass and add their own on top.

## [mesh name, joypad bit, press direction]. Face buttons and the pill switches
## sit on the +Y face and sink; the shoulders sit on the back (-Z) edge and push
## in. Every stand-in authors its controls as direct children of the model, so
## these directions are already in the meshes' parent frame.
##
## Travel is NOT in this table: it is per device, and a single figure either sinks
## a short cap through the shell or leaves a tall one barely moving. See
## _standin_press_depth().
const _STANDIN_BUTTONS: Array = [
	["FaceButton1",  ControllerBindings.JOYPAD_A,      Vector3(0, -1, 0)],
	["FaceButton2",  ControllerBindings.JOYPAD_B,      Vector3(0, -1, 0)],
	["FaceButton3",  ControllerBindings.JOYPAD_X,      Vector3(0, -1, 0)],
	["FaceButton4",  ControllerBindings.JOYPAD_Y,      Vector3(0, -1, 0)],
	["StartButton",  ControllerBindings.JOYPAD_START,  Vector3(0, -1, 0)],
	["SelectButton", ControllerBindings.JOYPAD_SELECT, Vector3(0, -1, 0)],
	["ShoulderL",    ControllerBindings.JOYPAD_L,      Vector3(0, 0, 1)],
	["ShoulderR",    ControllerBindings.JOYPAD_R,      Vector3(0, 0, 1)],
	["ShoulderL2",   ControllerBindings.JOYPAD_L2,     Vector3(0, 0, 1)],
	["ShoulderR2",   ControllerBindings.JOYPAD_R2,     Vector3(0, 0, 1)],
]
## Fraction of a cap's proud height it sinks when pressed. Not all of it: a cap
## driven flush reads as a hole, and the shells these sit in are 1-2 mm thick.
const _STANDIN_PRESS_FRACTION := 0.55
const _STANDIN_PRESS_MIN := 0.0004
const _STANDIN_PRESS_MAX := 0.0025
const _STANDIN_ANIM_W := 0.35

var _standin: ControlAnimator = null


## Mesh names this model's own animate_controls already drives, so the shared
## pass leaves them alone rather than lerping the same node twice.
func _own_animated_meshes() -> PackedStringArray:
	return PackedStringArray()


func _bind_standin_controls() -> void:
	_standin = ControlAnimator.new()
	# A stand-in authors UP as the pad's -Z arm, and a positive pitch about X
	# LIFTS what lies on -Z — so the sign flips for UP to depress it. Same reason
	# RetroPadController overrides it.
	_standin.dpad_pitch_sign = -1.0
	var claimed := _own_animated_meshes()
	for spec: Array in _STANDIN_BUTTONS:
		var mesh_name: String = spec[0]
		if claimed.has(mesh_name):
			continue
		var m := find_child(mesh_name, true, false) as MeshInstance3D
		if m == null:
			continue
		var dir: Vector3 = spec[2]
		_standin.buttons.append({"node": m, "rest": m.transform, "bit": int(spec[1]),
			"depth": _standin_press_depth(mesh_name, m, dir), "dir": dir})
	# The pad is two bars crossed on one centre. The engine turns one entry, so the
	# second bar rides dpad2 — which reads the same four bits by default and so
	# moves with it as one piece.
	var bar1 := find_child("DpadBar1", true, false) as MeshInstance3D
	if bar1 != null:
		_standin.dpad = _standin_rocker(bar1)
	var bar2 := find_child("DpadBar2", true, false) as MeshInstance3D
	if bar2 != null:
		_standin.dpad2 = _standin_rocker(bar2)
	# Analog nubs, for the stand-ins that grow one.
	var sl := find_child("StickLeft", true, false) as MeshInstance3D
	if sl != null:
		_standin.stick_l = _standin_rocker(sl)
	var sr := find_child("StickRight", true, false) as MeshInstance3D
	if sr != null:
		_standin.stick_r = _standin_rocker(sr)


## How far a stand-in's cap travels when pressed, in metres.
##
## Measured off the scene rather than tabled: a cap sinks a fraction of the height
## it actually stands proud of the face it sits in, so a 4 mm Game Boy button and
## a 1.5 mm Pokemon mini one both read as a press instead of one of them punching
## through its shell. A device that wants a specific figure names it in
## _standin_press_travel().
func _standin_press_depth(mesh_name: String, m: MeshInstance3D, dir: Vector3) -> float:
	var named: Dictionary = _standin_press_travel()
	if named.has(mesh_name):
		return float(named[mesh_name])
	# Outward normal of the face this control sits in, and where that face is: the
	# body box is centred on the model origin, so its surface is half the body.
	var n := -dir
	var face: float = absf(body_size.dot(n)) * 0.5
	var ab: AABB = m.transform * m.get_aabb()
	var proud: float = maxf(ab.position.dot(n), ab.end.dot(n)) - face
	if proud <= 0.0:
		return _STANDIN_PRESS_MIN
	return clampf(proud * _STANDIN_PRESS_FRACTION, _STANDIN_PRESS_MIN, _STANDIN_PRESS_MAX)


## Per-device press travel in metres, by mesh name, for anything the measurement
## above gets wrong. Empty means every control is measured.
func _standin_press_travel() -> Dictionary:
	return {}


## A rocker turns about its own authored centre, not the model origin.
func _standin_rocker(m: MeshInstance3D) -> Dictionary:
	return {"node": m, "rest": m.transform, "pivot": m.transform.origin}


## btn = RETRO_JOYPAD bitmask; lstick/rstick are the analog values (-1..1) as sent
## to the core (y already screen-negated).
func animate_controls(btn: int, lstick: Vector2, rstick: Vector2) -> void:
	if _standin == null:
		_bind_standin_controls()
	_standin.animate(btn, lstick, rstick, _STANDIN_ANIM_W)


## Some converted shells ship emissiveFactor 1,1,1 with no emissive texture,
## which Godot takes literally — the Arctic White GBA glowed like a lightbulb.
## The live picture is drawn on our own quad, so nothing on the shell itself
## should be self-illuminated. Runs on the baked path too: several handhelds
## have their GLB saved into the .tscn and return before the load below.
func _fix_shell_materials() -> void:
	if _glb != null:
		ModelMaterialFix.strip_emission(_glb)
