## DropdownPanel — a VRDropdown's option list as its own quad, floating a few
## centimetres in front of the panel that opened it.
##
## A 2D list inside a Viewport2Din3D has nowhere to go: expanding it grows its
## row, and overlaying it fights the sibling draw order. Its own quad has
## neither problem, and it matches the cartridge/core/tv options panels.
##
## Parented to the host Viewport2Din3D, so all placement is in that panel's
## local space and the popout follows the menu when it is grabbed or moved.
class_name DropdownPanel
extends Node3D

signal option_chosen(id: Variant)

const VIEWPORT_2D_IN_3D := preload("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn")
const OPTIONS_2D := preload("res://Scenes/UI/dropdown_options_2d.tscn")

## Metres in front of the host panel. Far enough to clear it without landing in
## a different focal plane from the menu behind it.
const Z_OFFSET := 0.035
const MAX_PANEL_PX_H := 620.0
const MIN_PANEL_PX_W := 320.0

var _viewport: XRToolsViewport2DIn3D = null
var _ui: DropdownOptions2D = null
var _host: XRToolsViewport2DIn3D = null
## Metres per host viewport pixel, so the popout matches the menu's scale.
var _m_per_px := 0.0005
## The popout's own curve, and the host's, which drives it.
var _curve: CurvedPanel = null
var _host_curve: CurvedPanel = null
## Last placement, in flat host-panel coordinates, so a curve step can re-place
## the card without recomputing the layout.
var _flat_at := Vector3.ZERO


func _ready() -> void:
	visible = false


## host        : the Viewport2Din3D the dropdown lives in
## toggle_rect : the toggle's rect in host viewport pixels
## options     : [[label, id, (Texture2D)], ...]
func show_for(host: XRToolsViewport2DIn3D, toggle_rect: Rect2, options: Array,
			  current_id: Variant, font: Font = null, columns: int = 1) -> void:
	_host = host
	if host.screen_size.x > 0.0 and host.viewport_size.x > 0.0:
		_m_per_px = host.screen_size.x / host.viewport_size.x

	var ui := _ensure_ui()
	if ui == null:
		return
	# Set here rather than in _ensure_ui: prewarm() builds the viewport before
	# any host is known, so doing it there would leave the layer at its default.
	_viewport.collision_layer = host.collision_layer
	var want := DropdownOptions2D.wanted_size(options.size(), columns)
	var px_w := maxf(maxf(toggle_rect.size.x, MIN_PANEL_PX_W), want.x)
	var px_h := minf(want.y, MAX_PANEL_PX_H)

	# Through with_flat_geometry: writing screen_size runs the addon's setter,
	# which assigns mesh.size — a property the arc's ArrayMesh does not have. Done
	# directly it throws on every open and, worse, aborts the setter before it
	# reaches the body's own screen_size, which is what maps a hit to a pixel.
	var resize := func() -> void:
		_viewport.viewport_size = Vector2(px_w, px_h)
		_viewport.screen_size = Vector2(px_w * _m_per_px, px_h * _m_per_px)
	if _curve != null:
		_curve.with_flat_geometry(resize)
	else:
		resize.call()

	ui.set_options(options, current_id, font, 22, columns)

	_flat_at = _local_for(host, toggle_rect, px_w, px_h)
	_host_curve = host.get_node_or_null("CurvedPanel") as CurvedPanel
	if _host_curve != null and not _host_curve.curve_changed.is_connected(_follow_host):
		_host_curve.curve_changed.connect(_follow_host)
	visible = true
	_follow_host()


## Sit on the host's cylinder and bend to match it. Connected to the host's
## curve_changed, so this tracks the flat/curved animation frame by frame instead
## of snapping once it finishes.
func _follow_host() -> void:
	# The connection outlives the popout being dismissed, and rebuilding a mesh
	# nobody can see for every step of the host's tween is pure waste.
	if not visible:
		return
	if _host_curve == null or not is_instance_valid(_host_curve):
		position = _flat_at
		if _curve != null:
			_curve.set_curved(false, false)
		return

	transform = _host_curve.surface_pose(_flat_at.x, _flat_at.y, Z_OFFSET)
	if _curve == null:
		return

	# Concentric with the host, not merely bent by the same amount. The card
	# floats Z_OFFSET nearer the cylinder's axis than the screen does, so it needs
	# the smaller radius; give it the host's and its edges splay off the menu.
	var r := _host_curve.axis_radius()
	if r <= 0.0:
		_curve.set_curved(false, false)
	else:
		_curve.curve_radius = maxf(r - Z_OFFSET, 0.05)
		_curve.set_curved(true, false)


## Build the quad, its SubViewport, the arc mesh and the option scene now,
## while nothing is waiting on them. All of that otherwise happens inside the
## first show_for(), which is one frame's worth of scene instantiation on the
## first tap of any dropdown.
func prewarm() -> void:
	_ensure_ui()


func hide_panel() -> void:
	visible = false


## Place the popout just under the toggle, clamped so it cannot hang off the
## host panel, and flipped above the toggle when there is no room below.
func _local_for(host: XRToolsViewport2DIn3D, toggle_rect: Rect2,
				px_w: float, px_h: float) -> Vector3:
	var vp := host.viewport_size
	var gap := 6.0

	var x_px := toggle_rect.position.x + toggle_rect.size.x * 0.5
	var top_px := toggle_rect.position.y + toggle_rect.size.y + gap
	if top_px + px_h > vp.y:
		top_px = toggle_rect.position.y - gap - px_h
	top_px = clampf(top_px, 0.0, maxf(0.0, vp.y - px_h))
	x_px = clampf(x_px, px_w * 0.5, maxf(px_w * 0.5, vp.x - px_w * 0.5))

	var y_px := top_px + px_h * 0.5
	# Viewport pixels are +Y down from the top-left; the quad is centred, +Y up.
	return Vector3(
		(x_px / vp.x - 0.5) * host.screen_size.x,
		-(y_px / vp.y - 0.5) * host.screen_size.y,
		Z_OFFSET)


func _ensure_ui() -> DropdownOptions2D:
	if is_instance_valid(_ui):
		return _ui

	if _viewport == null:
		# Must be instanced from the addon scene: the SubViewport, mesh and
		# collision body are scene children, so .new() yields a bare Node3D.
		_viewport = VIEWPORT_2D_IN_3D.instantiate() as XRToolsViewport2DIn3D
		_viewport.name = "DropdownViewport"
		_viewport.update_mode = XRToolsViewport2DIn3D.UpdateMode.UPDATE_ALWAYS
		# Opaque and unshaded: the card fills its own quad, so alpha blending
		# only lets the list behind bleed through, and scene lighting would make
		# it read dimmer than the panel it sits on.
		_viewport.transparent = XRToolsViewport2DIn3D.TransparancyMode.OPAQUE
		# Unshaded, like the host: a lit card over an unshaded menu reads as a
		# darker cut-out floating on it rather than part of the same surface.
		_viewport.unshaded = true
		add_child(_viewport)

		# Its own arc, so the card bends with the menu instead of hanging off it
		# as a flat rectangle turned to the tangent. No toggle and no resize grip:
		# it follows the host's, and a second set of controls on a popout would be
		# both meaningless and in the way.
		_curve = CurvedPanel.new()
		_curve.name = "CurvedPanel"
		_curve.show_controls = false
		_curve.follow_prefs = false
		# Driven by the host's tween, one step at a time — a tween of its own would
		# race that one and lag behind it.
		_curve.animate_seconds = 0.0
		_viewport.add_child(_curve)

	# Must go through the `scene` property: that is what instantiates the UI
	# into the SubViewport and binds its texture to the quad's material.
	# Adding a Control to the SubViewport directly renders nothing.
	_viewport.scene = OPTIONS_2D
	_ui = _viewport.get_scene_instance() as DropdownOptions2D
	if _ui == null:
		return null
	_ui.option_chosen.connect(func(id: Variant) -> void:
		hide_panel()
		option_chosen.emit(id)
	)
	return _ui
