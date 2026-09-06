## BookOptionsPanel — floating 3D panel that displays settings for a PDFBook.
##
## Parented to a PDFBook node but uses top_level=true so it inherits no transform.
## Each frame it repositions itself above the owning book and faces the camera.
## Opened/closed via show_for()/hide_panel(); also has an in-UI ✕ close button.
## Mirrors VCROptionsPanel.
class_name BookOptionsPanel
extends FloatingObjectPanel3D

## Height above the book's origin at which the panel floats.
const FLOAT_HEIGHT := 0.35

var _book: PDFBook = null

@onready var _viewport_node: XRToolsViewport2DIn3D = $BookOptionsViewport


# ── Public API ─────────────────────────────────────────────────────────────────

## Show the panel for the given book, looking toward the given camera.
func show_for(book: PDFBook, camera: Node3D) -> void:
	_book = book
	_camera = camera
	if _book:
		global_position = _book.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	visible = true
	_ensure_ui_connected()
	_populate()


# ── Internal helpers ───────────────────────────────────────────────────────────

func _get_ui() -> BookOptions2D:
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		return null
	return vp.get_child(0) as BookOptions2D


func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_ensure_ui_connected")
		return
	ui.half_page_toggled.connect(_on_half_page_toggled)
	ui.size_changed.connect(_on_size_changed)
	ui.size_committed.connect(_on_size_committed)
	ui.close_requested.connect(hide_panel)
	_ui_connected = true


func _populate() -> void:
	if not _book:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_populate")
		return
	ui.populate(_book.half_page_mode, _book.size_scale)


func _on_half_page_toggled(enabled: bool) -> void:
	if _book and is_instance_valid(_book):
		_book.half_page_mode = enabled
		NetworkManager.report_event(NetEvents.Event.EV_BOOK_HALF,
			{"book": _book, "on": enabled})


## Live while the slider is dragged — resizes the local book every tick.
func _on_size_changed(factor: float) -> void:
	if _book and is_instance_valid(_book):
		_book.size_scale = factor


## Drag finished — replicate the final size to the other players.
func _on_size_committed(factor: float) -> void:
	if _book and is_instance_valid(_book):
		_book.size_scale = factor
		NetworkManager.report_event(NetEvents.Event.EV_BOOK_SIZE,
			{"book": _book, "scale": factor})


# ── Placement, for FloatingObjectPanel3D ─────────────────────────────────────

func _target_node() -> Node3D:
	return _book


func _float_height() -> float:
	return FLOAT_HEIGHT
