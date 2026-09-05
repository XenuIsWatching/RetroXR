## ToastPanel — the spawn menu's notification stack (download progress, ROM
## hashing, RomM sync) lifted onto its own quad in front of the menu, the way
## DropdownPanel lifts an option list.
##
## Inside the menu's own viewport the bars are painted into the page: they share
## its curve, its lighting and its depth, so a progress bar reads as part of
## whatever tab happens to be open. On their own quad they float clear of it.
##
## The toast Controls themselves are NOT rebuilt here — spawn_menu still creates,
## updates and removes them exactly as before. This only reparents the stack into
## its own SubViewport and keeps that viewport sized and placed. Everything that
## writes a toast is untouched.
##
## Parented to the host Viewport2Din3D, so it rides along when the menu is
## grabbed, resized or curved.
class_name ToastPanel
extends Node3D

const HOST_2D := preload("res://Scenes/UI/toast_host_2d.tscn")

## Metres in front of the host panel. Slightly further out than a DropdownPanel's
## 0.035 so a dropdown opened over the stack cannot bury it.
const Z_OFFSET := 0.040
## Gap between the stack's bottom and the panel's bottom edge, in host pixels.
## Matches the offset_bottom the stack used while it lived in the page.
const BOTTOM_INSET := 62.0
## Ceiling on the quad's width, as a fraction of the host in host pixels. The
## quad is sized to the widest bar; this only stops one very long message from
## running wider than the menu it floats over.
const MAX_WIDTH_FRACTION := 0.5
## Floor, so a two-word notice is still a bar rather than a chip.
const MIN_W := 300.0
## Metres per pixel relative to the page. In the page the bars had to share the
## menu's scale; on their own quad they do not, and at page scale an 18 pt line
## is ~9 mm tall — too small to read across the room, which is the one thing a
## notification has to do.
const SCALE := 1.7
## Above this width, in metres, the host is a menu you stand in front of and the
## blow-up above applies. Below it the host is something you hold — a memory
## card's panel is 28 cm — already close to your face, where 1.7x is a banner
## bigger than the thing it belongs to and fits about four words.
##
## Under the spawn menu's smallest size (0.55 m, half its shipped 1.1): shrinking
## that panel must not quietly shrink its notifications too.
const HELD_WIDTH := 0.45
## How much of a held host's width a bar may span. Higher than the menu's half,
## because half of 28 cm is not a sentence.
const HELD_WIDTH_FRACTION := 0.9
const MIN_H := 48.0

var _host: XRToolsViewport2DIn3D = null
var _viewport: XRToolsViewport2DIn3D = null
var _stack: Control = null
var _curve: CurvedPanel = null
var _host_curve: CurvedPanel = null


## Move `stack` out of the menu page and onto a quad of its own. Returns null
## when there is no 3D host, leaving the stack where it is.
static func adopt(host: XRToolsViewport2DIn3D, stack: Control) -> ToastPanel:
	if host == null or stack == null:
		return null
	var panel := ToastPanel.new()
	panel.name = "ToastPopout"
	panel._host = host
	host.add_child(panel)
	panel._build(stack)
	return panel


func _build(stack: Control) -> void:
	# Instanced from the addon scene, not .new(): the SubViewport, mesh and
	# collision body are scene children.
	_viewport = load("res://addons/godot-xr-tools/objects/viewport_2d_in_3d.tscn") \
		.instantiate() as XRToolsViewport2DIn3D
	_viewport.name = "ToastViewport"
	_viewport.update_mode = XRToolsViewport2DIn3D.UpdateMode.UPDATE_ALWAYS
	# SCISSOR, not TRANSPARENT. The stack is a few bars with gaps between them, so
	# an OPAQUE quad would paint a slab over the menu — but an alpha-BLENDED one
	# does not draw here at all: measured 14787 px with blending off against 57
	# with it on, same mesh, same texture, same position. Scissor keeps real holes
	# between the bars while still drawing in the opaque pass.
	_viewport.transparent = XRToolsViewport2DIn3D.TransparancyMode.SCISSOR
	# Unshaded, like the menu it sits in front of — a lit bar over an unshaded
	# page is a dim patch that follows the room's lighting, not the menu's.
	_viewport.unshaded = true
	# Nothing here is pointable — the bars are MOUSE_FILTER_IGNORE and there is
	# nothing to click. Leaving it on the pointer layer would put an invisible
	# wall across the bottom of the menu.
	_viewport.collision_layer = 0
	add_child(_viewport)

	_curve = CurvedPanel.new()
	_curve.name = "CurvedPanel"
	_curve.show_controls = false
	_curve.follow_prefs = false
	_curve.animate_seconds = 0.0
	_viewport.add_child(_curve)

	# Through the `scene` property, as DropdownPanel does. The addon can also
	# render a Control added straight to its SubViewport, and that worked here —
	# this is the blessed path rather than a fix for anything.
	_stack = stack
	_viewport.scene = HOST_2D
	var mount := _viewport.get_scene_instance() as ToastHost2D
	if mount == null:
		push_warning("ToastPanel: viewport scene did not instantiate")
		return
	# It was anchored to the bottom of the menu page; here it owns the whole
	# surface, and the surface is sized to it instead.
	mount.mount(stack)

	_host_curve = _host.get_node_or_null("CurvedPanel") as CurvedPanel
	if _host_curve != null and not _host_curve.curve_changed.is_connected(_place):
		_host_curve.curve_changed.connect(_place)

	visible = false
	refresh.call_deferred()


## Re-measure and re-place. Call whenever a toast is added, removed or hidden;
## deferred internally is not enough because the caller may add several in one
## frame, so this is cheap and idempotent.
func refresh() -> void:
	if not is_instance_valid(_stack) or not is_instance_valid(_viewport):
		return
	if not is_instance_valid(_host):
		return

	var shown := 0
	for c: Node in _stack.get_children():
		if c is Control and (c as Control).visible:
			shown += 1
	if shown == 0:
		visible = false
		return

	var vp := _host.viewport_size
	var cap := vp.x * (MAX_WIDTH_FRACTION if not _held() else HELD_WIDTH_FRACTION)
	# A bar wider than the quad is a message with its end cut off, so the stack is
	# told what it has to fit in before it is measured.
	if _stack.has_method("set_wrap_width"):
		_stack.call("set_wrap_width", cap)
	# Sized to the content, both ways: the bars shrink to their text, so the
	# stack's minimum width is the widest bar's.
	var want := _stack.get_combined_minimum_size()
	# The ceiling wins over the floor. On the spawn menu the two never meet, but a
	# small panel — a memory card's, at 420 px — has a ceiling below MIN_W, and a
	# floor that beat it would hang a bar wider than the panel it belongs to.
	var px_w := clampf(want.x, minf(MIN_W, cap), cap)
	var px_h := maxf(MIN_H, want.y)

	if _viewport.viewport_size.x != px_w or _viewport.viewport_size.y != px_h:
		# Through with_flat_geometry: writing screen_size runs the addon's setter,
		# which assigns mesh.size — a property the arc's ArrayMesh does not have.
		var m_per_px := _m_per_px()
		var resize := func() -> void:
			_viewport.viewport_size = Vector2(px_w, px_h)
			_viewport.screen_size = Vector2(px_w * m_per_px, px_h * m_per_px)
		if _curve != null:
			_curve.with_flat_geometry(resize)
		else:
			resize.call()
		_rebind_albedo()

	visible = true
	_place()


## Re-point the quad's albedo at the SubViewport texture. The addon binds it once,
## during its first _update_render; resizing the viewport afterwards leaves the
## material holding a texture for the old size.
func _rebind_albedo() -> void:
	var screen := _viewport.get_node_or_null("Screen") as MeshInstance3D
	var sub := _viewport.get_node_or_null("Viewport") as SubViewport
	if screen == null or sub == null:
		return
	var mat := screen.get_surface_override_material(0) as StandardMaterial3D
	if mat != null:
		mat.albedo_texture = sub.get_texture()


## Metres per host viewport pixel — the page's own scale, used for placement.
func _base_m_per_px() -> float:
	if _host.screen_size.x > 0.0 and _host.viewport_size.x > 0.0:
		return _host.screen_size.x / _host.viewport_size.x
	return 0.0005


## Is the host a panel held in the hand rather than one stood in front of?
func _held() -> bool:
	return _host.screen_size.x < HELD_WIDTH


## Metres per pixel for the quad itself, blown up for legibility — except on a
## held panel, which is already an arm's length away.
func _m_per_px() -> float:
	return _base_m_per_px() * (1.0 if _held() else SCALE)


## Bottom-centre of the host, floating forward, riding the arc when it is curved.
func _place() -> void:
	if not visible or not is_instance_valid(_host) or not is_instance_valid(_viewport):
		return

	# Worked in metres, not host pixels: the quad is drawn at SCALE, so half its
	# height is not half its height in the page's pixel grid.
	var inset := BOTTOM_INSET * _base_m_per_px()
	var y := -_host.screen_size.y * 0.5 + inset + _viewport.screen_size.y * 0.5

	if is_instance_valid(_host_curve):
		# flat_x 0 — the stack is centred, so this only pushes it along the
		# surface normal and leaves the yaw at zero.
		transform = _host_curve.surface_pose(0.0, y, Z_OFFSET)
		if _curve != null:
			var r := _host_curve.axis_radius()
			if r <= 0.0:
				_curve.set_curved(false, false)
			else:
				# Concentric with the host: the stack floats Z_OFFSET nearer the
				# cylinder axis, so it needs the smaller radius.
				_curve.curve_radius = maxf(r - Z_OFFSET, 0.05)
				_curve.set_curved(true, false)
	else:
		position = Vector3(0.0, y, Z_OFFSET)
