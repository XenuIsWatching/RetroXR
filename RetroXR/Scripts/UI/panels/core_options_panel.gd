## CoreOptionsPanel — floating 3D panel that displays libretro core options for a RetroSystem.
##
## Parented to a RetroSystem node but uses top_level=true so it inherits no transform.
## Each frame it repositions itself above the owning system and faces the camera.
## Opened/closed via show_for()/hide_panel(); also has an in-UI ✕ close button.
class_name CoreOptionsPanel
extends FloatingObjectPanel3D

## Gap between the top of the hardware and the BOTTOM edge of the panel.
##
## This replaced a fixed 0.42 m from the system's origin to the panel's centre.
## That figure was tuned against a flat console, where it clears the machine
## easily; the PC tower is 0.42 m tall, so the panel's centre landed exactly on
## its crown and the lower half of the page was drawn inside the case.
const CLEARANCE := 0.12

## Built on first open, not with the panel. A SubViewport and the whole control
## tree inside it is the most expensive part of a system, and a room pays it once
## per system while it is being built — main-thread time spent on a UI nobody has
## asked for yet, at the one moment the headset has nothing new to draw.
const UI_SCENE := preload("res://Scenes/UI/core_options_2d.tscn")

var _system: RetroSystem = null
## The slotted cartridge's panel while it is driving our Cartridge tab.
var _cart_panel: CartridgeOptionsPanel = null

@onready var _viewport_node: XRToolsViewport2DIn3D = $CoreOptionsViewport


## Centred over the machine, its bottom edge CLEARANCE above the hardware's top.
## Half the panel is added because global_position is its centre — placing the
## centre at the clearance height is what put the lower half inside the tower.
func _anchor() -> Vector3:
	var origin := _system.global_position
	var half_height := _viewport_node.screen_size.y * 0.5
	return Vector3(origin.x,
		_system.body_top_y() + CLEARANCE + half_height,
		origin.z)


# ── Public API ─────────────────────────────────────────────────────────────────

## Show the panel for the given system, looking toward the given camera.
func show_for(system: RetroSystem, camera: Node3D) -> void:
	_system = system
	_camera = camera
	# Pre-position before making visible to avoid a one-frame flash at the wrong spot
	if _system:
		global_position = _anchor()
	visible = true
	print("[CoreOptionsPanel] showing for system '%s'" % system.name)
	if _viewport_node.scene == null:
		_viewport_node.scene = UI_SCENE
	_ensure_ui_connected()
	_populate()


## Called by the system when fresh options data arrives and the panel is already open.
func refresh() -> void:
	print("[CoreOptionsPanel] refreshing options display")
	_populate()


# ── Internal helpers ───────────────────────────────────────────────────────────

## Wire signals from the 2D UI scene exactly once.
## The SubViewport may not have finished loading on the first call, so we defer
## and retry if the child scene isn't ready yet.
func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		# SubViewport hasn't instantiated its scene yet — retry next frame
		call_deferred("_ensure_ui_connected")
		return
	var ui := vp.get_child(0) as CoreOptions2D
	if not ui:
		push_warning("[CoreOptionsPanel] SubViewport child is not CoreOptions2D")
		return
	ui.option_changed.connect(_on_option_changed)
	ui.options_reset_requested.connect(_on_options_reset_requested)
	ui.port_device_changed.connect(_on_port_device_changed)
	ui.pad_device_changed.connect(_on_pad_device_changed)
	ui.video_out_toggled.connect(_on_video_out_toggled)
	ui.ignore_gravity_toggled.connect(_on_ignore_gravity_toggled)
	ui.close_requested.connect(hide_panel)
	_ui_connected = true
	print("[CoreOptionsPanel] 2D UI signals connected")


## Push the system's cached option data into the 2D UI.
## Defers if the SubViewport scene isn't ready yet.
func _populate() -> void:
	if not _system:
		return
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		call_deferred("_populate")
		return
	var ui := vp.get_child(0) as CoreOptions2D
	if not ui:
		return
	ui.populate(_system._options_definitions, _system._options_values, _system._controller_info,
		_system.forced_core_options(), _system._options_unavailable,
		_system._resolve_core())
	ui.populate_system(_system.video_out_enabled, _system.supports_video_out_toggle(),
		_system.ignore_gravity, _system.pad_guid, _system.pad_ordinal)
	_populate_cartridge_tab(ui)


## Hand the Cartridge tab to the slotted cartridge's own options panel, which
## owns the save recovery, RomM sync and achievement lookup. Nothing is
## reimplemented here — this only decides whether the tab exists and who drives it.
func _populate_cartridge_tab(ui: CoreOptions2D) -> void:
	# game_media, not get_snapped_cartridge: on an assembled machine the game is
	# often in the EXPANSION's bay and the console's own slot is empty, and this
	# tab was hidden for every one of those -- a 64DD disk, a Mega-CD disc, a 32X
	# cartridge -- so their saves and achievements could not be reached at all.
	var cart := _system.game_media()
	ui.set_cartridge_tab_visible(cart != null)
	if cart == null:
		_cart_panel = null
		return
	# Same panel the cartridge shows on its own, so a save selected here and one
	# selected there are the same act on the same state.
	if not cart.has_method("ensure_options_panel"):
		ui.set_cartridge_tab_visible(false)
		return
	_cart_panel = cart.ensure_options_panel()
	if _cart_panel == null:
		ui.set_cartridge_tab_visible(false)
		return
	_cart_panel.adopt_external_ui(ui.cartridge_ui(), cart)


## Relay the user's option change from the 2D UI back to the system.
func _on_option_changed(key: String, value: String) -> void:
	if _system and is_instance_valid(_system):
		print("[CoreOptionsPanel] option changed: '%s' = '%s'" % [key, value])
		_system.set_core_option(key, value)


## Reset every non-forced option, then redraw so the new values show.
func _on_options_reset_requested() -> void:
	if _system and is_instance_valid(_system):
		print("[CoreOptionsPanel] resetting core options to defaults")
		_system.reset_core_options()
		_populate()


## System-tab toggle: show/hide the console's video-out cables.
func _on_video_out_toggled(enabled: bool) -> void:
	if _system and is_instance_valid(_system):
		_system.set_video_out_enabled(enabled)


## System-tab toggle: float in place where dropped.
func _on_ignore_gravity_toggled(enabled: bool) -> void:
	if _system and is_instance_valid(_system):
		_system.set_ignore_gravity(enabled)


func _on_port_device_changed(port: int, device_id: int) -> void:
	if _system and is_instance_valid(_system):
		print("[CoreOptionsPanel] port %d device → %d" % [port, device_id])
		_system.set_controller_port_device(port, device_id)


func _on_pad_device_changed(guid: String, ordinal: int) -> void:
	if _system and is_instance_valid(_system):
		print("[CoreOptionsPanel] physical pad → '%s' #%d" % [guid, ordinal])
		_system.pad_guid = guid
		_system.pad_ordinal = ordinal


# ── Placement, for FloatingObjectPanel3D ─────────────────────────────────────

func _target_node() -> Node3D:
	return _system
