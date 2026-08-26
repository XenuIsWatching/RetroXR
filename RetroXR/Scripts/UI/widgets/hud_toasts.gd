## HudToasts -- a toast stack that rides the player's view.
##
## The room already had two ways to tell somebody something and neither reaches a
## player who is just standing there playing: MenuToasts lives inside the spawn
## menu's viewport, so it inherits visible=false the moment the menu shuts, and
## AchievementToast is bolted to a machine, so it is behind you as often as not.
##
## This is the third: a small panel in the low periphery, present with the menu
## closed, carrying the same MenuToasts stack the menu uses. The stack is not
## reimplemented -- keyed rows, in-place patching, the "+N more" overflow and the
## dwell constants are all already right in MenuToasts, and a second copy would
## only be a second thing to keep in step.
##
## Borrowed wholesale from PerfHud: the SubViewport-on-a-Sprite3D construction,
## the desktop CanvasLayer fallback, and above all UPDATE_DISABLED with explicit
## repaints -- UPDATE_ALWAYS hangs a headless run, which is a thing this project
## has already been bitten by.
class_name HudToasts
extends Node3D

## Where the panel sits relative to the head: below the line of sight, near
## enough to read, far enough not to fight the machine's screen for focus.
## A starting point measured from PerfHud's head placement; the real value is
## whatever feels right in the headset.
const HEAD_OFFSET := Vector3(0.0, -0.20, -0.85)
const HEAD_PITCH_DEG := 10.0
## Bigger than PerfHud's 0.00050, and deliberately. PerfHud is a dense stats
## readout the player leans in to study; this has to be readable at a glance
## while playing, in the corner of the eye. At 0.00050 the first render came out
## legible on a 1:1 panel and completely unreadable in the world -- what matters
## is the angle it subtends, not the pixels it has.
const M_PER_PX := 0.00075
const RENDER_PRIORITY := 5
const VIEWPORT_SIZE := Vector2i(760, 420)

## Comfort. A panel welded to the camera reads as dirt on the lens: it never
## moves against the world, so the eye cannot tell it is a panel at all. Easing
## toward the target instead lets the head lead and the panel follow, and the
## deadzone means a still head leaves it perfectly still rather than creeping.
const FOLLOW_LAG := 6.0
const DEADZONE_M := 0.004
const DEADZONE_DEG := 0.35

## Repaint budget. The stack animates its own dwell timers, so it needs frames
## while anything is on it -- but only while.
const REPAINT_HZ := 20.0

var _camera: Node3D = null
var _viewport: SubViewport = null
var _sprite: Sprite3D = null
var _canvas: CanvasLayer = null
var _stack: MenuToasts = null
var _host: Control = null
var _desktop := false
var _muted := false
var _repaint_accum := 0.0


static func create(camera: Node3D) -> HudToasts:
	var hud := HudToasts.new()
	hud.name = "HudToasts"
	hud._camera = camera
	hud._desktop = not MenuStyle.is_vr_mode()
	return hud


## The stack itself. Callers drive this through the MenuToasts API they already
## know rather than through a forwarding layer that would only get out of date.
func stack() -> MenuToasts:
	return _stack


## Hide while the spawn menu is open. The menu is right in front of the player
## with its own toast stack, and two stacks saying the same thing is worse than
## one saying it once.
func set_muted(muted: bool) -> void:
	_muted = muted
	_apply_visibility()


func _ready() -> void:
	_build()
	top_level = true          # eased toward the head, not welded to it
	_snap_to_target()
	_apply_visibility()


func _build() -> void:
	_stack = MenuToasts.create()
	_stack.set_wrap_width(VIEWPORT_SIZE.x - 40)

	if _desktop:
		_canvas = CanvasLayer.new()
		_canvas.name = "HudCanvas"
		add_child(_canvas)
		var margin := MarginContainer.new()
		margin.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		margin.add_theme_constant_override("margin_bottom", 40)
		margin.add_theme_constant_override("margin_left", 40)
		margin.add_theme_constant_override("margin_right", 40)
		_canvas.add_child(margin)
		margin.add_child(_stack)
		return

	_viewport = SubViewport.new()
	_viewport.name = "HudToastViewport"
	_viewport.size = VIEWPORT_SIZE
	_viewport.transparent_bg = true
	_viewport.disable_3d = true
	# Never UPDATE_ALWAYS: it hangs a headless run and the content only changes
	# when a toast does. Repaints are requested in _process while visible.
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_viewport)

	_host = TOAST_HOST.instantiate()
	_viewport.add_child(_host)
	_host.mount(_stack)

	_sprite = Sprite3D.new()
	_sprite.name = "HudToastSprite"
	_sprite.no_depth_test = true
	_sprite.render_priority = RENDER_PRIORITY
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_sprite.pixel_size = M_PER_PX
	_sprite.texture = _viewport.get_texture()
	add_child(_sprite)


const TOAST_HOST := preload("res://Scenes/UI/toast_host_2d.tscn")


func _process(delta: float) -> void:
	_apply_visibility()
	if not visible or _desktop:
		return
	_follow(delta)
	_repaint_accum += delta
	if _repaint_accum >= 1.0 / REPAINT_HZ:
		_repaint_accum = 0.0
		if _viewport != null:
			_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## Nothing on the stack means nothing on screen -- an empty panel hanging in the
## player's view is exactly the clutter this is trying not to be.
func _apply_visibility() -> void:
	var wanted := not _muted and _has_content()
	if visible != wanted:
		visible = wanted
		if wanted:
			_snap_to_target()


func _has_content() -> bool:
	if _stack == null or not is_instance_valid(_stack):
		return false
	for c in _stack.get_children():
		if c is Control and (c as Control).visible:
			return true
	return false


func _target() -> Transform3D:
	if _camera == null or not is_instance_valid(_camera):
		return global_transform
	var t := (_camera as Node3D).global_transform
	t.origin = t * HEAD_OFFSET
	t.basis = t.basis.rotated(t.basis.x.normalized(), deg_to_rad(HEAD_PITCH_DEG))
	return t


func _snap_to_target() -> void:
	if not _desktop:
		global_transform = _target()


func _follow(delta: float) -> void:
	var want := _target()
	var here := global_transform
	var moved := here.origin.distance_to(want.origin)
	var turned := rad_to_deg(here.basis.get_rotation_quaternion().angle_to(
		want.basis.get_rotation_quaternion()))
	if moved < DEADZONE_M and turned < DEADZONE_DEG:
		return
	var t := clampf(FOLLOW_LAG * delta, 0.0, 1.0)
	global_transform = here.interpolate_with(want, t)
