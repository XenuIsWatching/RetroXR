## PDFBook — A VR-holdable book that displays PDF pages.
##
## Spawn via spawn menu (manual button) or instantiate and call load_pdf().
class_name PDFBook
extends XRToolsPickable

## Path to the PDF file to display.
@export_global_file("*.pdf") var pdf_path: String = "":
	set(value):
		pdf_path = value
		if not _loading and is_inside_tree() and not pdf_path.is_empty():
			load_pdf(pdf_path)

## Render DPI — higher = sharper but more memory. 150 is good for Quest.
@export_range(72, 300) var render_dpi: int = 150

## Half-page mode for scanned two-page spreads: each source page is split down
## the middle into two book pages (left half first, then right half).
@export var half_page_mode: bool = false:
	set(value):
		if half_page_mode == value:
			return
		half_page_mode = value
		if not _loading and is_inside_tree() and not pdf_path.is_empty():
			load_pdf(pdf_path)

## Fixed book height in meters (width is derived from PDF aspect ratio).
@export var book_height: float = 0.25

## Uniform size multiplier (aspect ratio always preserved). Driven live by the
## settings-panel slider; also restored from saves and synced in multiplayer.
@export_range(0.5, 2.5) var size_scale: float = 1.0:
	set(value):
		size_scale = clampf(value, 0.5, 2.5)
		if not _loading and is_inside_tree() and _page_count > 0:
			_apply_dimensions()

## Paper stock. Coating fills the fibre and flattens the surface, so a gloss
## finish is not just shinier — it is smoother, more even, and more opaque.
## Magazines and most game manuals are coated, so GLOSS is the default.
enum PaperFinish { MATTE, SATIN, GLOSS }

@export var paper_finish: PaperFinish = PaperFinish.GLOSS:
	set(value):
		paper_finish = value
		if is_inside_tree() and _page_count > 0:
			_apply_paper_finish()

## Number of pages to pre-render ahead/behind the current spread.
@export var prefetch_pages: int = 6

# ── Internal state ────────────────────────────────────────────────────────────

enum BookState { CLOSED, OPEN, LAST_PAGE }
enum _Format { PDF, CBZ }

var _state: BookState = BookState.CLOSED
var _format: _Format = _Format.PDF
var _page_count: int = 0
var _leaf_count: int = 0

## Current spread index. When open, the left page shows leaf[current_leaf].back,
## and the right page shows leaf[current_leaf+1].front.
## 0 = cover just opened (left = page 1, right = page 2).
var _current_leaf: int = 0

var _renderer: RefCounted = null  # PDFRenderer instance (PDF only)
var _cbz_entries: Array[String] = []  # sorted image filenames inside the CBZ (CBZ only)
var _cbz_path: String = ""            # stored for per-task ZIPReader opens (CBZ only)
var _page_width: float = 0.0
var _page_height: float = 0.0
var _book_width: float = 0.0  # single page width in meters (scaled)
var _base_width: float = 0.0   # unscaled dimensions (size_scale = 1.0)
var _base_height: float = 0.0
var _export_height: float = 0.25   # pristine book_height (CBZ sizing base)
var _pending_page: Dictionary = {}  # {state, leaf} to apply once loaded

# Texture cache (page_index -> ImageTexture)
var _texture_cache: Dictionary = {}

# PNG disk cache directory
var _cache_dir: String = ""

# Page mesh nodes (set up in _ready or after scene load)
@onready var _cover_mesh: MeshInstance3D = $Cover
@onready var _back_cover_mesh: MeshInstance3D = $BackCover
@onready var _left_stack: MeshInstance3D = $LeftStack
@onready var _left_stack_top: MeshInstance3D = $LeftStack/LeftStackTop
@onready var _right_stack: MeshInstance3D = $RightStack
@onready var _right_stack_top: MeshInstance3D = $RightStack/RightStackTop
@onready var _spine_node: Node3D = $Spine
@onready var _spine_mesh: MeshInstance3D = $Spine/SpineMesh
@onready var _active_leaf_container: Node3D = $ActiveLeafContainer
@onready var _options_panel: BookOptionsPanel = $BookOptionsPanel

# The currently active turning leaf
var _active_leaf: MeshInstance3D = null
var _is_turning: bool = false
var _turn_direction: int = 0  # 1 = forward, -1 = backward

# ── Hand-driven page fold ─────────────────────────────────────────────────────

## Fraction of a page, measured in from the fore edge, that can be gripped. The
## inner strip is deliberately left alone: the grab zones sit on the pointer
## layer, which outranks a pickable, so a full-page zone would leave the laser
## no way to pick the book up at all.
const GRAB_BAND := 0.65
const CURL_MIN := 0.003
const CURL_MAX := 0.045
## How much looser the crease is at the spine end than at the fore edge. Kept
## gentle: a strong taper lands the flipped half of the page at visibly
## different heights along its length.
const CURL_TAPER := 0.5
## Crease radius a completed turn closes down to. The flipped page ends up
## 2 x this above the stack it lands on, so it has to be small enough to read as
## flush — CURL_MIN would leave it floating 6 mm proud.
const CURL_CLOSED := 0.0004
## How close to the gutter the fold line may get before the binding stops it.
const FOLD_GUTTER_MARGIN := 0.004
## Fold progress past which letting go completes the turn instead of undoing it.
const TURN_COMMIT := 0.5
const LEAF_SETTLE_TIME := 0.28
## A replayed remote turn covers the whole page, so it runs slower than the
## settle that finishes a drag already most of the way over.
const REMOTE_TURN_TIME := 0.45
## Gap between a spread page and the block it lies on. Was 0.8 mm to keep the
## two off each other in the depth buffer, which is most of a nine-leaf stack —
## the page floated clear of its own block and had that much further to dive.
## Depth is written properly now, so one leaf's worth is plenty.
const LEAF_Z_GAP := 0.00015
## Clearance between the turning leaf and whichever page is under it. Both the
## page it uncovers and the page it lands on sit exactly at _page_plane_z(), so
## without this the leaf is coplanar with them and z-fights — the two pages
## interleave in patches and the one underneath appears to be pulled through.
const LEAF_LIFT := 0.0006

var _grab_right: PageGrab = null
var _grab_left: PageGrab = null
var _grab_dir: int = 0                     # 0 = no page in hand
var _grab_anchor: Vector2 = Vector2.ZERO   # gripped point, leaf-local metres
var _fold_origin: Vector2 = Vector2.ZERO
var _fold_normal: Vector2 = Vector2.RIGHT
var _curl_radius: float = CURL_MIN
var _curl_taper: float = CURL_TAPER
var _leaf_tween: Tween = null
var _sfx: PageSfx = null
var _grab_ctrl: XRController3D = null
## Set while replaying a turn somebody else made: the spread to land on when
## the animation finishes, instead of stepping locally and echoing it back.
var _animate_target: Dictionary = {}
var _loading: bool = false  # re-entry guard for load_pdf ↔ setter

# VR page turning
var _controllers: Array = []
var _turn_cooldown: float = 0.0
const TURN_COOLDOWN_TIME := 0.5
const GRIP_THRESHOLD := 0.3
const SPINE_WIDTH := 0.0035         # width of the spine binding strip
const SPINE_HEIGHT_MARGIN := 0.004  # how much taller spine is than pages
const LEAF_THICKNESS := 0.0001      # meters of depth per leaf (~0.1mm, realistic paper)
const COVER_THICKNESS := 0.004      # combined depth contribution of front + back covers
const COVER_GAP := 0.001            # gap between page stack face and cover quad
const STACK_BASE_DEPTH := 0.005     # BoxMesh baseline depth used as scale divisor
const ZFIGHT_MARGIN := 0.0005       # tiny margin to prevent Z-fighting on coplanar faces
const HINT_LABEL_OFFSET := 0.02     # distance outside the book edge for hint labels
const MIN_COLLISION_DEPTH := 0.04   # minimum collision shape Z — keeps thin books stable on surfaces

# ── Paper rendering ───────────────────────────────────────────────────────────

const PAPER_SHADER := preload("res://Shaders/paper.gdshader")
const EDGE_SHADER := preload("res://Shaders/page_edge.gdshader")
const SPINE_SHADER := preload("res://Shaders/spine.gdshader")

## Grid resolution of the resting spread pages and of the leaf being turned.
## The resting pages only carry the smooth rest bow; the turning leaf has to
## resolve a crease of radius ~1 cm, so it gets a much finer grid. Quest runs
## roughly half the density (the arcade scene is already over frame budget).
const SPREAD_SUBDIV_DESKTOP := Vector2i(12, 8)
const SPREAD_SUBDIV_QUEST := Vector2i(8, 6)
const LEAF_SUBDIV_DESKTOP := Vector2i(32, 22)
const LEAF_SUBDIV_QUEST := Vector2i(20, 14)

## Vertex displacement does not update a mesh's culling bounds, so every paper
## surface gets an explicit custom_aabb sized to the worst-case curl envelope —
## without it a folded page vanishes as soon as the book's origin leaves the
## frustum (the same trap verlet_rope.gd hit with surface_update_vertex_region).
const PAPER_AABB_MARGIN := 0.02
const PAPER_AABB_DEPTH := 0.16

## How deep the gutter valley runs, as a fraction of the stack on that side.
## A thick book has a deep valley and a thin magazine barely any, so this cannot
## be a constant — at a fixed 4 mm a 110-page magazine's pages dove clean
## through its own back cover.
const GUTTER_DIVE_RATIO := 0.6
const GUTTER_DIVE_MAX := 0.008

## Rest shape of a sheet, shared with the block it lies on so the two cannot
## disagree (paper_rest.gdshaderinc). Set explicitly rather than left to the
## shader defaults, because page_edge.gdshader has to be handed the same values.
const REST_BOW := 0.0025
const REST_DROOP := 0.0015
const REST_EDGE_CURL := 0.002
const REST_GUTTER_FALLOFF := 12.0

# Async page rendering
var _render_mutex := Mutex.new()
var _pending_renders: Dictionary = {}  # page_index -> true

# Loading placeholder texture
var _loading_texture: ImageTexture = null

# 1-pixel-wide colour strip taken from the cover's inner edge, wrapped around
# the binding by spine.gdshader. Built once per loaded book.
var _spine_strip: ImageTexture = null

# Hint labels for page turning
var _next_label: Label3D = null
var _prev_label: Label3D = null

# Multiplayer download status (shown while NetObjectSync fetches the file)
var _net_status_label: Label3D = null


## Show or clear a floating status line above the book ("" hides it). Called by
## NetObjectSync while the backing PDF is being transferred from the host.
func net_set_download_status(text: String) -> void:
	if text.is_empty():
		if _net_status_label:
			_net_status_label.visible = false
		return
	if _net_status_label == null:
		_net_status_label = Label3D.new()
		_net_status_label.font_size = 40
		_net_status_label.pixel_size = 0.001
		_net_status_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
		_net_status_label.no_depth_test = true
		_net_status_label.modulate = Color(1.0, 0.9, 0.4)
		_net_status_label.outline_modulate = Color(0, 0, 0, 0.8)
		_net_status_label.outline_size = 6
		_net_status_label.position = Vector3(0, book_height * 0.8 + 0.05, 0)
		add_child(_net_status_label)
	_net_status_label.text = text
	_net_status_label.visible = true


## The trigger drags a page (see page_grab.gd), so it can't double as the
## push-out modifier. Catching a book back off the laser still works. Queried by
## function_pickup._handoff_eligible.
func wants_ray_handoff() -> bool:
	return false


func _ready() -> void:
	super._ready()
	_export_height = book_height   # pristine value: the CBZ sizing base
	# The spread pages bend; PickableHighlight's inverted-hull copy would not,
	# so a bowed or folded page would poke through its own flat outline shell.
	# They sit inside the stack silhouette anyway, so the book still outlines
	# completely from the stacks, covers and spine.
	_left_stack_top.add_to_group("outline_exclude")
	_right_stack_top.add_to_group("outline_exclude")
	_create_loading_texture()
	_create_hint_labels()
	_build_page_grabs()
	_sfx = PageSfx.new()
	_sfx.name = "PageSfx"
	add_child(_sfx)
	await get_tree().process_frame
	for node: Node in get_tree().root.find_children("*", "XRController3D", true, false):
		_controllers.append(node as XRController3D)
	if not pdf_path.is_empty():
		load_pdf(pdf_path)


## Toggle the floating book settings panel (mirrors VCRPlayer.toggle_options_ui).
## Called by SpawnMenuController when the menu button is pressed while pointing
## at this book.
func toggle_options_ui(camera: Node3D) -> void:
	if _options_panel.visible:
		_options_panel.hide_panel()
	else:
		_options_panel.show_for(self, camera)


## Open a PDF or CBZ file and configure the book.
func load_pdf(path: String) -> void:
	_cleanup()
	_loading = true
	pdf_path = path
	_loading = false

	var ext := path.get_extension().to_lower()
	if ext == "cbz":
		_load_cbz(path)
	else:
		_load_pdf_internal(path)


func _load_pdf_internal(path: String) -> void:
	_format = _Format.PDF
	_renderer = ClassDB.instantiate("PDFRenderer")
	if not _renderer:
		push_error("[PDFBook] PDFRenderer class not available. Is the GDExtension loaded?")
		return

	if not _renderer.open(path):
		push_error("[PDFBook] Failed to open PDF: %s" % path)
		_renderer = null
		return

	_page_count = _renderer.get_page_count()
	if _page_count == 0:
		push_warning("[PDFBook] PDF has 0 pages: %s" % path)
		_renderer.close()
		_renderer = null
		return

	var size: Vector2 = _renderer.get_page_size(0)
	_page_width = size.x
	_page_height = size.y

	# Half-page mode: each source page yields two book pages of half the width.
	if half_page_mode:
		_page_count *= 2
		_page_width /= 2.0

	_leaf_count = ceili(_page_count / 2.0)

	# Size from the ASPECT RATIO only, never from the declared page box.
	#
	# A scraped manual's page box is almost never a physical size — it is
	# usually the scan's pixel dimensions taken as 72 dpi. Across the manuals on
	# hand that gave a Game Boy Advance booklet at 508 x 381 mm and a Nintendo
	# Power at 88 x 118 mm, off in both directions, so a plausibility window
	# does not save it: 88 x 118 looks like a perfectly reasonable book. The
	# scan's aspect ratio does survive, so use that and normalise the height,
	# exactly as the CBZ path has always done. size_scale is the knob for
	# anything that wants to be bigger or smaller.
	var aspect := _page_width / maxf(_page_height, 1.0)
	_base_height = _export_height
	_base_width = _export_height * aspect

	_cache_dir = "user://pdf_cache/" + pdf_path.md5_text() + ("_half/" if half_page_mode else "/")
	DirAccess.make_dir_recursive_absolute(_cache_dir)

	_current_leaf = 0
	_state = BookState.CLOSED
	_apply_dimensions()
	_consume_pending_page()

	print("[PDFBook] Loaded PDF: %s (%d pages, %d leaves, %.2f x %.2f m)" % [
		pdf_path, _page_count, _leaf_count, _book_width, book_height])


func _load_cbz(path: String) -> void:
	_format = _Format.CBZ
	_cbz_path = path

	var reader := ZIPReader.new()
	var err := reader.open(path)
	if err != OK:
		push_error("[PDFBook] Failed to open CBZ: %s (err %d)" % [path, err])
		return

	# Filter entries to supported image types, sort naturally
	var IMAGE_EXTS := ["jpg", "jpeg", "png", "webp"]
	var entries: Array[String] = []
	for entry: String in reader.get_files():
		if entry.get_extension().to_lower() in IMAGE_EXTS:
			entries.append(entry)
	entries.sort_custom(func(a: String, b: String) -> bool:
		return a.naturalnocasecmp_to(b) < 0
	)
	reader.close()

	if entries.is_empty():
		push_warning("[PDFBook] CBZ has no image entries: %s" % path)
		return

	_cbz_entries = entries
	_page_count = entries.size()

	# Decode the first image to get page dimensions
	var first_img := _decode_cbz_page(0)
	if first_img:
		_page_width = first_img.get_width()
		_page_height = first_img.get_height()
	else:
		_page_width = 1.0
		_page_height = 1.0

	# Half-page mode: each source image yields two book pages of half the width.
	if half_page_mode:
		_page_count *= 2
		_page_width /= 2.0

	_leaf_count = ceili(_page_count / 2.0)

	if _page_height > 0:
		_base_width = _export_height * (_page_width / _page_height)
	else:
		_base_width = _export_height * 0.65
	_base_height = _export_height

	_cache_dir = "user://pdf_cache/" + path.md5_text() + ("_half/" if half_page_mode else "/")
	DirAccess.make_dir_recursive_absolute(_cache_dir)

	_current_leaf = 0
	_state = BookState.CLOSED
	_apply_dimensions()
	_consume_pending_page()

	print("[PDFBook] Loaded CBZ: %s (%d pages, %d leaves, %.2f x %.2f m)" % [
		path, _page_count, _leaf_count, _book_width, book_height])


## Decode a CBZ page image by index. Opens and closes its own ZIPReader (thread-safe).
func _decode_cbz_page(page_index: int) -> Image:
	if page_index < 0 or page_index >= _cbz_entries.size():
		return null
	var reader := ZIPReader.new()
	if reader.open(_cbz_path) != OK:
		return null
	var data := reader.read_file(_cbz_entries[page_index])
	reader.close()
	if data.is_empty():
		return null
	var img := Image.new()
	var ext := _cbz_entries[page_index].get_extension().to_lower()
	var decode_err: Error
	if ext == "png":
		decode_err = img.load_png_from_buffer(data)
	elif ext == "webp":
		decode_err = img.load_webp_from_buffer(data)
	else:  # jpg / jpeg
		decode_err = img.load_jpg_from_buffer(data)
	if decode_err != OK:
		return null
	return img


## Recompute the scaled dimensions and rebuild every size-dependent piece
## (meshes, collision, spine, labels) while keeping the current page/state.
func _apply_dimensions() -> void:
	if _page_count == 0:
		return
	# Resizing rebuilds every mesh, so a page in someone's hand has to go first.
	_abort_grab()
	_book_width = _base_width * size_scale
	book_height = _base_height * size_scale
	_configure_meshes()
	_rebuild_highlight_overlays()
	_despawn_active_leaf()
	_set_state(_state)
	if _net_status_label:
		_net_status_label.position = Vector3(0, book_height * 0.8 + 0.05, 0)


# ── Page state (persistence + multiplayer sync) ──────────────────────────────

## Jump directly to a spread with no turn animation. Safe to call before the
## book has loaded — the target page is stashed and applied after load.
func set_page(state: int, leaf: int) -> void:
	if _page_count == 0:
		_pending_page = {"state": state, "leaf": leaf}
		return
	# A page change arriving from the host (or a restore) while somebody is
	# mid-drag must not delete the leaf out of their hand. Hold it and apply on
	# release — _pending_page already means exactly "apply this once we can".
	if _grab_dir != 0:
		_pending_page = {"state": state, "leaf": leaf}
		return
	if _animate_page_step(state, leaf):
		return
	_despawn_active_leaf()
	_current_leaf = clampi(leaf, 0, maxi(_leaf_count - 1, 0))
	_set_state(clampi(state, BookState.CLOSED, BookState.LAST_PAGE) as BookState)


## When another player turns a single page, play it as a real turn rather than
## teleporting the spread. Only remote events qualify — a scene restore or a
## size change jumps an arbitrary distance and should just snap.
##
## The fold itself is never streamed: it is 28 bytes at 20 Hz, but it would add
## a third continuous channel to a system that deliberately has two, and a
## client lerping toward a sampled copy of someone else's hand jitter looks
## worse than a clean local animation.
func _animate_page_step(state: int, leaf: int) -> bool:
	if not NetworkManager.is_active() or not NetworkManager.is_event_applying():
		return false
	if _active_leaf != null or not is_inside_tree():
		return false
	var target_state := clampi(state, BookState.CLOSED, BookState.LAST_PAGE)
	var target_leaf := clampi(leaf, 0, maxi(_leaf_count - 1, 0))
	var dir := _step_direction(target_state, target_leaf)
	if dir == 0:
		return false
	if not _spawn_leaf(dir):
		return false
	_grab_dir = dir
	_animate_target = {"state": target_state, "leaf": target_leaf}
	_fold_origin = Vector2(float(dir) * (_book_width * 0.5 + 0.01), 0.0)
	_fold_normal = Vector2(float(dir), 0.0)
	_curl_radius = CURL_MAX * 0.5
	_curl_taper = CURL_TAPER
	_push_fold(1.0)
	_settle_leaf(true, REMOTE_TURN_TIME)
	return true


## +1 / -1 if the requested spread is exactly one page either side of the
## current one, 0 for anything further.
func _step_direction(target_state: int, target_leaf: int) -> int:
	match _state:
		BookState.CLOSED:
			if target_state == BookState.OPEN and target_leaf == 0:
				return 1
			if target_state == BookState.LAST_PAGE and _leaf_count <= 1:
				return 1
		BookState.OPEN:
			if target_state == BookState.OPEN:
				if target_leaf == _current_leaf + 1:
					return 1
				if target_leaf == _current_leaf - 1:
					return -1
			elif target_state == BookState.LAST_PAGE and _current_leaf >= _leaf_count - 2:
				return 1
			elif target_state == BookState.CLOSED and _current_leaf == 0:
				return -1
		BookState.LAST_PAGE:
			if target_state == BookState.OPEN and target_leaf == _leaf_count - 2:
				return -1
	return 0


func net_get_page() -> Dictionary:
	return {"state": int(_state), "leaf": _current_leaf}


func _consume_pending_page() -> void:
	if _pending_page.is_empty():
		return
	var p := _pending_page
	_pending_page = {}
	set_page(int(p.get("state", 0)), int(p.get("leaf", 0)))


## Broadcast the page we landed on so other players' copies follow along.
func _report_page() -> void:
	if NetworkManager.is_active() and not NetworkManager.is_event_applying():
		NetworkManager.report_event(NetObjectSync.EV_BOOK_PAGE,
			{"book": self, "state": int(_state), "leaf": _current_leaf})


# ── Async page texture loading ────────────────────────────────────────────────

## Get a page texture if cached, otherwise return placeholder and start background render.
func _get_page_texture(page_index: int) -> ImageTexture:
	if page_index < 0 or page_index >= _page_count:
		return null

	if _texture_cache.has(page_index):
		return _texture_cache[page_index]

	# Check disk cache (fast — no PDF render needed)
	var cache_path := _cache_dir + "page_%03d.png" % page_index
	if FileAccess.file_exists(cache_path):
		var img := Image.load_from_file(cache_path)
		if img:
			var tex := ImageTexture.create_from_image(img)
			_texture_cache[page_index] = tex
			return tex

	# Queue background render
	_request_page_render(page_index)
	return _loading_texture


## Crop a source image to the half selected by a logical page index (half-page
## mode only; passthrough otherwise). Even logical pages = left half.
func _crop_to_half(img: Image, page_index: int) -> Image:
	if not half_page_mode or img == null:
		return img
	@warning_ignore("integer_division")
	var half_w := img.get_width() / 2
	if half_w <= 0:
		return img
	var x := 0 if page_index % 2 == 0 else half_w
	return img.get_region(Rect2i(x, 0, half_w, img.get_height()))


## Queue a page for background rendering if not already pending.
## page_index is a LOGICAL book page: in half-page mode two logical pages map
## to the two halves of one source page.
func _request_page_render(page_index: int) -> void:
	if _pending_renders.has(page_index):
		return
	_pending_renders[page_index] = true

	@warning_ignore("integer_division")
	var src_index := page_index / 2 if half_page_mode else page_index
	# Captured for the worker lambda so it never reaches back through `self`.
	var cache_dir := _cache_dir

	if _format == _Format.CBZ:
		WorkerThreadPool.add_task(func():
			var img := _decode_cbz_page(src_index)
			img = _crop_to_half(img, page_index)
			if img:
				img.save_png(cache_dir + "page_%03d.png" % page_index)
			call_deferred("_on_page_rendered", page_index, img)
		)
		return

	# PDF path
	if not _renderer or not _renderer.is_open():
		_pending_renders.erase(page_index)
		return
	var renderer_ref := _renderer
	var dpi := render_dpi
	WorkerThreadPool.add_task(func():
		_render_mutex.lock()
		var img: Image = null
		if renderer_ref and renderer_ref.is_open():
			img = renderer_ref.render_page(src_index, dpi)
		_render_mutex.unlock()
		img = _crop_to_half(img, page_index)
		if img:
			img.save_png(cache_dir + "page_%03d.png" % page_index)
		call_deferred("_on_page_rendered", page_index, img)
	)


## Called on main thread when a background page render completes.
func _on_page_rendered(page_index: int, img: Image) -> void:
	_pending_renders.erase(page_index)
	if not img:
		return
	var tex := ImageTexture.create_from_image(img)
	_texture_cache[page_index] = tex
	_refresh_visible_textures()


## Re-apply textures to currently visible meshes (after async render completes).
func _refresh_visible_textures() -> void:
	match _state:
		BookState.CLOSED:
			_update_cover_texture()
			_update_back_cover_texture()
		BookState.OPEN:
			_update_cover_texture()
			_update_back_cover_texture()
			_update_spread_textures()
		BookState.LAST_PAGE:
			_update_cover_texture()
			_update_back_cover_texture()


## Unload textures that are far from the current spread to save VRAM.
func _trim_texture_cache() -> void:
	var keep_min := maxi(0, (_current_leaf * 2) - prefetch_pages)
	var keep_max := mini(_page_count - 1, (_current_leaf * 2) + prefetch_pages + 2)
	# Always keep cover and back cover
	var to_remove: Array[int] = []
	for key: int in _texture_cache:
		if key == 0 or key == _page_count - 1:
			continue
		if key < keep_min or key > keep_max:
			to_remove.append(key)
	for key: int in to_remove:
		_texture_cache.erase(key)


# ── Mesh configuration ────────────────────────────────────────────────────────

## Configure mesh sizes and create unique materials for each mesh.
func _configure_meshes() -> void:
	var half_w := _book_width / 2.0
	var spine_half := SPINE_WIDTH / 2.0
	# Stack center X: pages start at the outer edge of the spine
	var stack_x := half_w + spine_half

	# Duplicate the collision shape too — the tscn sub-resource is SHARED across
	# all book instances, so without this every _update_collision_shape() call
	# resized every book's collision box (visible as "collision off to one side"
	# whenever multiple books of different sizes/states existed, e.g. after a
	# scene restore).
	var col_shape := $CollisionShape3D as CollisionShape3D
	if col_shape and col_shape.shape:
		col_shape.shape = col_shape.shape.duplicate()

	# Duplicate all shared meshes before resizing so instances don't affect each other
	if _cover_mesh.mesh:
		_cover_mesh.mesh = _cover_mesh.mesh.duplicate()
	if _back_cover_mesh.mesh:
		_back_cover_mesh.mesh = _back_cover_mesh.mesh.duplicate()
	if _left_stack_top.mesh:
		_left_stack_top.mesh = _left_stack_top.mesh.duplicate()
	if _right_stack_top.mesh:
		_right_stack_top.mesh = _right_stack_top.mesh.duplicate()
	if _left_stack.mesh:
		_left_stack.mesh = _left_stack.mesh.duplicate()
	if _right_stack.mesh:
		_right_stack.mesh = _right_stack.mesh.duplicate()

	_set_mesh_size(_cover_mesh, _book_width, book_height)
	_set_mesh_size(_back_cover_mesh, _book_width, book_height)
	_set_mesh_size(_left_stack_top, _book_width, book_height)
	_set_mesh_size(_right_stack_top, _book_width, book_height)

	# Stack box sizes and positions — offset outward so they don't overlap the spine
	if _left_stack.mesh is BoxMesh:
		(_left_stack.mesh as BoxMesh).size = Vector3(_book_width, book_height, STACK_BASE_DEPTH)
	if _right_stack.mesh is BoxMesh:
		(_right_stack.mesh as BoxMesh).size = Vector3(_book_width, book_height, STACK_BASE_DEPTH)
	_left_stack.position = Vector3(-stack_x, 0, 0)
	_right_stack.position = Vector3(stack_x, 0, 0)

	# Spine initial setup: full closed-book depth, centered at Z=0
	var total_thick := maxf(_leaf_count * LEAF_THICKNESS, LEAF_THICKNESS * 2)
	if _spine_mesh and _spine_mesh.mesh is BoxMesh:
		_spine_mesh.mesh = _spine_mesh.mesh.duplicate()
		(_spine_mesh.mesh as BoxMesh).size = Vector3(SPINE_WIDTH, book_height + SPINE_HEIGHT_MARGIN, total_thick)
	_ensure_spine_material()
	_set_spine_closed(total_thick)

	# Hint label positions — just outside the full book width
	_next_label.position = Vector3(stack_x + half_w + HINT_LABEL_OFFSET, 0, 0)
	_prev_label.position = Vector3(-(stack_x + half_w + HINT_LABEL_OFFSET), 0, 0)

	# Collision shape will be sized per-state in _update_collision_shape()

	# Per-instance materials: textures must not bleed between meshes, and each
	# page surface carries its own size / spine_sign / fold uniforms.
	_ensure_paper_material(_cover_mesh, true)
	_ensure_paper_material(_back_cover_mesh, true)
	_ensure_paper_material(_left_stack_top, false)
	_ensure_paper_material(_right_stack_top, false)
	_ensure_edge_material(_left_stack, _current_leaf + 1)
	_ensure_edge_material(_right_stack, _leaf_count - _current_leaf - 1)


func _set_mesh_size(mesh_node: MeshInstance3D, w: float, h: float) -> void:
	if not mesh_node:
		return
	# QuadMesh derives from PlaneMesh, so both carry the subdivision properties.
	var mesh := mesh_node.mesh as PlaneMesh
	if mesh == null:
		return
	mesh.size = Vector2(w, h)
	var subdiv := SPREAD_SUBDIV_DESKTOP if QualityManager.is_desktop() else SPREAD_SUBDIV_QUEST
	mesh.subdivide_width = subdiv.x
	mesh.subdivide_depth = subdiv.y
	_set_paper_aabb(mesh_node, w, h)


## Cover the worst-case curl envelope: a folded page reaches ~2 curl radii off
## the plane and can lay itself across the far half of the book.
func _set_paper_aabb(mesh_node: MeshInstance3D, w: float, h: float) -> void:
	var m := PAPER_AABB_MARGIN
	mesh_node.custom_aabb = AABB(
		Vector3(-w - m, -h * 0.5 - m, -PAPER_AABB_DEPTH * 0.5),
		Vector3(w * 2.0 + m * 2.0, h + m * 2.0, PAPER_AABB_DEPTH))


## Tiling paper-fibre texture, built once and shared by every book: RG hold the
## fibre gradient, B a slow roughness variation. Paper fibres are long and thin,
## so the field is blurred much wider across X than Y before differencing.
static var _grain_texture: ImageTexture = null

static func _paper_grain() -> ImageTexture:
	if _grain_texture != null:
		return _grain_texture
	const N := 128
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x9E3779B9
	var field := PackedFloat32Array()
	field.resize(N * N)
	for i in N * N:
		field[i] = rng.randf()

	# Separable box blur, wrapping so the texture tiles: 9 wide on X, 3 on Y.
	var pass_x := PackedFloat32Array()
	pass_x.resize(N * N)
	for y in N:
		for x in N:
			var acc := 0.0
			for k in range(-4, 5):
				acc += field[y * N + ((x + k + N) % N)]
			pass_x[y * N + x] = acc / 9.0
	var blur := PackedFloat32Array()
	blur.resize(N * N)
	for y in N:
		for x in N:
			var acc := 0.0
			for k in range(-1, 2):
				acc += pass_x[((y + k + N) % N) * N + x]
			blur[y * N + x] = acc / 3.0

	var img := Image.create(N, N, true, Image.FORMAT_RGB8)
	for y in N:
		for x in N:
			var dx := blur[y * N + ((x + 1) % N)] - blur[y * N + ((x - 1 + N) % N)]
			var dy := blur[((y + 1) % N) * N + x] - blur[((y - 1 + N) % N) * N + x]
			img.set_pixel(x, y, Color(
				clampf(0.5 + dx * 4.0, 0.0, 1.0),
				clampf(0.5 + dy * 4.0, 0.0, 1.0),
				blur[y * N + x]))
	img.generate_mipmaps()
	_grain_texture = ImageTexture.create_from_image(img)
	return _grain_texture


## Give a page surface its own ShaderMaterial running paper.gdshader, and push
## the size-dependent uniforms into it. Covers are stiffer and opaque: no bow,
## no gutter dive, no light bleeding through.
func _ensure_paper_material(mesh_node: MeshInstance3D, is_cover: bool) -> ShaderMaterial:
	if not mesh_node:
		return null
	var mat := mesh_node.get_surface_override_material(0) as ShaderMaterial
	if mat == null or mat.shader != PAPER_SHADER:
		mat = ShaderMaterial.new()
		mat.shader = PAPER_SHADER
		mesh_node.set_surface_override_material(0, mat)
	mat.set_shader_parameter("page_size", Vector2(_book_width, book_height))
	mat.set_shader_parameter("grain_texture", _paper_grain())
	if is_cover:
		mat.set_shader_parameter("gutter_dive", 0.0)
		mat.set_shader_parameter("bow_amount", 0.0)
		mat.set_shader_parameter("fore_droop", 0.0)
		mat.set_shader_parameter("edge_curl", 0.0)
		mat.set_shader_parameter("gutter_ao", 0.25)
		mat.set_shader_parameter("backlight_amount", 0.0)
	else:
		mat.set_shader_parameter("bow_amount", REST_BOW)
		mat.set_shader_parameter("fore_droop", REST_DROOP)
		mat.set_shader_parameter("edge_curl", REST_EDGE_CURL)
		mat.set_shader_parameter("gutter_falloff", REST_GUTTER_FALLOFF)
	_apply_finish_to(mat, is_cover)
	return mat


## Surface properties of the chosen stock. Coating fills the paper's fibre and
## evens out the surface, so gloss means smoother and more opaque as well as
## shinier — turning roughness down on its own just makes matte paper look wet.
## Covers are one step glossier than the pages inside them, as they are in print.
func _apply_finish_to(mat: ShaderMaterial, is_cover: bool) -> void:
	var rough := 0.82
	var spec := 0.18
	var fibre := 0.25
	var rough_var := 0.06
	var backlight := 0.22
	match paper_finish:
		PaperFinish.SATIN:
			rough = 0.52
			spec = 0.35
			fibre = 0.14
			rough_var = 0.04
			backlight = 0.16
		PaperFinish.GLOSS:
			# A tight lobe, not a bright one. Varnish is still a dielectric, so
			# pushing SPECULAR up instead of roughness down just spread the
			# highlight into a sheet of glare across the whole spread and made
			# the page unreadable.
			rough = 0.20
			spec = 0.28
			fibre = 0.05
			rough_var = 0.015
			backlight = 0.09
	if is_cover:
		rough = maxf(rough - 0.1, 0.12)
		spec = minf(spec + 0.1, 1.0)
		fibre *= 0.5
		backlight = 0.0
	mat.set_shader_parameter("roughness", rough)
	mat.set_shader_parameter("sheen", spec)
	mat.set_shader_parameter("fibre_strength", fibre)
	mat.set_shader_parameter("roughness_variation", rough_var)
	if not is_cover:
		mat.set_shader_parameter("backlight_amount", backlight)


## Re-push the stock onto every page surface after a live finish change.
func _apply_paper_finish() -> void:
	for pair: Array in [[_cover_mesh, true], [_back_cover_mesh, true],
			[_left_stack_top, false], [_right_stack_top, false]]:
		var mat := (pair[0] as MeshInstance3D).get_surface_override_material(0) as ShaderMaterial
		if mat:
			_apply_finish_to(mat, bool(pair[1]))
	if _active_leaf:
		var leaf_mat := _active_leaf.get_surface_override_material(0) as ShaderMaterial
		if leaf_mat:
			_apply_finish_to(leaf_mat, false)


## Fore-edge material for a page stack. leaf_count drives the stripe pitch, and
## the box is authored at STACK_BASE_DEPTH before the book scales it on Z.
func _ensure_edge_material(mesh_node: MeshInstance3D, leaves: int) -> void:
	if not mesh_node:
		return
	var mat := mesh_node.get_surface_override_material(0) as ShaderMaterial
	if mat == null or mat.shader != EDGE_SHADER:
		mat = ShaderMaterial.new()
		mat.shader = EDGE_SHADER
		mesh_node.set_surface_override_material(0, mat)
	mat.set_shader_parameter("stack_depth", STACK_BASE_DEPTH)
	mat.set_shader_parameter("leaf_count", float(maxi(leaves, 1)))
	# Flat by default; only an OPEN spread digs a gutter, and _update_gutter_depth
	# runs after this on that path. Without the reset a book closed after being
	# open kept the dive and its block sagged under a flat cover.
	mat.set_shader_parameter("gutter_dive", 0.0)
	mat.set_shader_parameter("gutter_ao", 0.0)
	mat.set_shader_parameter("fore_droop", 0.0)
	mat.set_shader_parameter("edge_curl", 0.0)


## Which way u runs on this page: the gutter is at book-local x = 0, so work out
## which of the mesh's own local X directions points at it. The covers flip 180
## degrees about Y between states, so this cannot be a constant per node.
func _page_spine_sign(mesh_node: MeshInstance3D) -> float:
	if not mesh_node or not is_inside_tree():
		return 1.0
	var xf := global_transform.affine_inverse() * mesh_node.global_transform
	if is_zero_approx(xf.origin.x):
		return 1.0
	var to_gutter: Vector3 = xf.basis.inverse() * Vector3(-signf(xf.origin.x), 0.0, 0.0)
	if is_zero_approx(to_gutter.x):
		return 1.0
	return -signf(to_gutter.x)


## Refresh spine_sign on every page surface. Called after any state change that
## moves or rotates a page.
func _update_page_frames() -> void:
	for mesh_node: MeshInstance3D in [_cover_mesh, _back_cover_mesh, _left_stack_top, _right_stack_top]:
		var mat := mesh_node.get_surface_override_material(0) as ShaderMaterial
		if mat:
			mat.set_shader_parameter("spine_sign", _page_spine_sign(mesh_node))


## Apply a texture to a MeshInstance3D's material albedo.
func _apply_texture(mesh_node: MeshInstance3D, tex: Texture2D) -> void:
	if not mesh_node or not tex:
		return
	var mat := mesh_node.get_active_material(0)
	if mat is StandardMaterial3D:
		(mat as StandardMaterial3D).albedo_color = Color.WHITE
		(mat as StandardMaterial3D).albedo_texture = tex
	elif mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("front_texture", tex)


## Apply a texture to the back face of a double-sided page shader.
func _apply_back_texture(mesh_node: MeshInstance3D, tex: Texture2D) -> void:
	if not mesh_node or not tex:
		return
	var mat := mesh_node.get_active_material(0)
	if mat is ShaderMaterial:
		(mat as ShaderMaterial).set_shader_parameter("back_texture", tex)


# ── State management ──────────────────────────────────────────────────────────

func _set_state(new_state: BookState) -> void:
	_state = new_state
	var half_w := _book_width / 2.0
	var stack_x := half_w + SPINE_WIDTH / 2.0
	var total_thick := maxf(_leaf_count * LEAF_THICKNESS, LEAF_THICKNESS * 2)

	match new_state:
		BookState.CLOSED:
			_cover_mesh.visible = true
			_cover_mesh.position = Vector3(stack_x, 0, total_thick / 2.0 + COVER_GAP)
			_cover_mesh.rotation_degrees = Vector3.ZERO
			_back_cover_mesh.visible = true
			_back_cover_mesh.position = Vector3(stack_x, 0, -(total_thick / 2.0 + COVER_GAP))
			_back_cover_mesh.rotation_degrees = Vector3(0, 180, 0)
			_right_stack.visible = true
			_right_stack.position = Vector3(stack_x, 0, 0)
			_right_stack.scale.z = total_thick / STACK_BASE_DEPTH
			_right_stack_top.visible = false
			_left_stack.visible = false
			_set_spine_closed(total_thick)
			_ensure_edge_material(_right_stack, _leaf_count)
			_update_cover_texture()
			_update_back_cover_texture()
			_prefetch_nearby_pages()
			_update_collision_shape()

		BookState.OPEN:
			_cover_mesh.visible = true
			_cover_mesh.rotation_degrees = Vector3(0, 180, 0)
			_back_cover_mesh.visible = true
			_back_cover_mesh.rotation_degrees = Vector3(0, 180, 0)
			_left_stack.visible = true
			_left_stack.position = Vector3(-stack_x, 0, 0)
			_left_stack_top.visible = true
			_right_stack.visible = true
			_right_stack.position = Vector3(stack_x, 0, 0)
			_right_stack_top.visible = true
			_update_cover_texture()
			_update_back_cover_texture()
			_update_spread_textures()
			_update_stack_thickness()
			_prefetch_nearby_pages()
			_update_collision_shape()

		BookState.LAST_PAGE:
			_back_cover_mesh.visible = true
			_back_cover_mesh.position = Vector3(-stack_x, 0, total_thick / 2.0 + COVER_GAP)
			_back_cover_mesh.rotation_degrees = Vector3.ZERO
			_cover_mesh.visible = true
			_cover_mesh.position = Vector3(-stack_x, 0, -(total_thick / 2.0 + COVER_GAP))
			_cover_mesh.rotation_degrees = Vector3(0, 180, 0)
			_left_stack.visible = true
			_left_stack.position = Vector3(-stack_x, 0, 0)
			_left_stack.scale.z = total_thick / STACK_BASE_DEPTH
			_left_stack_top.visible = false
			_right_stack.visible = false
			_set_spine_closed(total_thick)
			_ensure_edge_material(_left_stack, _leaf_count)
			_update_cover_texture()
			_update_back_cover_texture()
			_prefetch_nearby_pages()
			_update_collision_shape()

	_update_page_frames()
	_layout_page_grabs()


## Update the CollisionShape3D so the grab/highlight area matches the visible book.
func _update_collision_shape() -> void:
	var col_shape := $CollisionShape3D as CollisionShape3D
	if not col_shape or not col_shape.shape is BoxShape3D:
		return
	var half_w := _book_width / 2.0
	var total_thick := maxf(_leaf_count * LEAF_THICKNESS, LEAF_THICKNESS * 2)
	var depth := maxf(total_thick + COVER_THICKNESS + COVER_GAP * 2 + ZFIGHT_MARGIN, MIN_COLLISION_DEPTH)
	match _state:
		BookState.CLOSED:
			# Only the right stack + spine + cover is visible
			(col_shape.shape as BoxShape3D).size = Vector3(_book_width + SPINE_WIDTH, book_height, depth)
			col_shape.position = Vector3(half_w, 0, 0)
		BookState.OPEN:
			# Both page stacks visible, spanning the full open width
			(col_shape.shape as BoxShape3D).size = Vector3(_book_width * 2.0 + SPINE_WIDTH, book_height, depth)
			col_shape.position = Vector3.ZERO
		BookState.LAST_PAGE:
			# Only the left stack + spine + back cover is visible
			(col_shape.shape as BoxShape3D).size = Vector3(_book_width + SPINE_WIDTH, book_height, depth)
			col_shape.position = Vector3(-half_w, 0, 0)


## Closed book: the spine is the outward binding, flush with the two covers.
## The covers are zero-thickness quads sitting at +/-(total_thick/2 + COVER_GAP),
## so that — not COVER_THICKNESS, which double-counted them and left the spine
## standing proud of the cover as a visible lip — is the span to match.
func _set_spine_closed(total_thick: float) -> void:
	if _spine_mesh and _spine_mesh.mesh is BoxMesh:
		(_spine_mesh.mesh as BoxMesh).size.z = total_thick + COVER_GAP * 2.0 + ZFIGHT_MARGIN
	_spine_node.position.z = 0.0
	var mat := _spine_mesh.get_surface_override_material(0) as ShaderMaterial
	if mat:
		mat.set_shader_parameter("gutter_shade", 0.0)
		mat.set_shader_parameter("spine_depth", total_thick + COVER_GAP * 2.0)


## Sit a spread page on top of its stack, undoing the stack's Z scale.
##
## The page quad is a CHILD of the stack box, and the box is scaled on Z to
## match its leaf count — so the page inherited that scale. Harmless while the
## page was flat, but paper.gdshader displaces along Z, so a 1.65 mm gutter dive
## rendered as 0.9 mm on a half-scaled stack and the normals skewed with it.
func _seat_stack_top(stack: MeshInstance3D, top: MeshInstance3D, thick: float) -> void:
	if stack == null or top == null:
		return
	var sz := maxf(stack.scale.z, 1e-4)
	top.scale.z = 1.0 / sz
	top.position.z = (thick * 0.5 + LEAF_Z_GAP) / sz


## Z that both pages converge to at the binding.
##
## This has to be ONE depth shared by both sides. Diving each page by a fraction
## of its own stack looks right in isolation but the two halves of an open book
## are rarely the same thickness: at leaf 8 of 55 the right stack is 46 leaves
## and the left is 9, so the right page's binding edge finished BELOW the left
## page's and the turning page visibly slid underneath the one it was leaving.
func _valley_z() -> float:
	var shallow := minf(_page_plane_z(1), _page_plane_z(-1))
	var deepest := maxf(_page_plane_z(1), _page_plane_z(-1))
	var floor_z := -maxf(_side_thickness(1), _side_thickness(-1)) * 0.25
	var valley := maxf(floor_z, deepest - GUTTER_DIVE_MAX)
	# Never below the underside of the THINNER block. Halfway through a book the
	# two halves are wildly different thicknesses — nine leaves against forty-six
	# at leaf 8 — and a valley set from the thick side put the thin side's page
	# below its own block, so the page passed through it and the block's flat top
	# face showed beside the spine.
	var thinnest := minf(_side_thickness(1), _side_thickness(-1))
	valley = maxf(valley, -thinnest * 0.5)
	# The shallower page still has to dive a little, or its gutter edge would be
	# pushed up instead of down. The margin has to scale with the book: a
	# 4-leaf game manual is 0.4 mm thick all in, so a flat 0.5 mm ZFIGHT_MARGIN
	# drove the valley deeper than the entire book and dug a trough through its
	# own back cover.
	return minf(valley, shallow - minf(ZFIGHT_MARGIN, thinnest * 0.25))


## How far a page sitting at plane_z has to fall to reach the binding.
func _gutter_dive_for(plane_z: float) -> float:
	return maxf(plane_z - _valley_z(), 0.0)


## Push the per-side valley depth into the two spread page materials. Each side
## starts at a different height, so each dives by a different amount — to the
## same place.
func _update_gutter_depth() -> void:
	for dir: int in [1, -1]:
		var dive := _gutter_dive_for(_page_plane_z(dir))
		var top := _right_stack_top if dir > 0 else _left_stack_top
		var mat := top.get_surface_override_material(0) as ShaderMaterial
		if mat:
			mat.set_shader_parameter("gutter_dive", dive)
		# The block underneath curves into the binding too, or its flat top face
		# stands proud of the diving top page and shows as a pale strip beside
		# the spine with the page apparently passing through it.
		var stack := _right_stack if dir > 0 else _left_stack
		var edge := stack.get_surface_override_material(0) as ShaderMaterial
		if edge:
			edge.set_shader_parameter("page_size", Vector2(_book_width, book_height))
			edge.set_shader_parameter("spine_sign", _page_spine_sign(top))
			edge.set_shader_parameter("gutter_dive", dive)
			edge.set_shader_parameter("z_scale", stack.scale.z)
			edge.set_shader_parameter("gutter_ao", 0.8)
			# Same rest shape as the sheet on top, or the block pokes through it
			# — at the gutter if it ignores the dive, at the fore edge if it
			# ignores the droop.
			edge.set_shader_parameter("gutter_falloff", REST_GUTTER_FALLOFF)
			edge.set_shader_parameter("bow_amount", REST_BOW)
			edge.set_shader_parameter("fore_droop", REST_DROOP)
			edge.set_shader_parameter("edge_curl", REST_EDGE_CURL)


## The binding material. The cover's own inner edge is wrapped around the spine
## so the book's spine matches its artwork instead of a fixed colour.
func _ensure_spine_material() -> void:
	if not _spine_mesh:
		return
	var mat := _spine_mesh.get_surface_override_material(0) as ShaderMaterial
	if mat == null or mat.shader != SPINE_SHADER:
		mat = ShaderMaterial.new()
		mat.shader = SPINE_SHADER
		_spine_mesh.set_surface_override_material(0, mat)
	mat.set_shader_parameter("spine_height", book_height + SPINE_HEIGHT_MARGIN)
	mat.set_shader_parameter("spine_width", SPINE_WIDTH)


func _update_cover_texture() -> void:
	var tex := _get_page_texture(0)
	_apply_texture(_cover_mesh, tex)
	_update_spine_strip(tex)


## Wrap the cover around the binding. Sampling the cover texture directly in the
## spine shader smeared one column of pixels down the whole spine; averaging a
## band of the cover's inner edge into a 1-pixel-wide strip keeps the colour
## banding that makes the spine match the artwork without the streaking.
func _update_spine_strip(tex: Texture2D) -> void:
	if _spine_mesh == null or tex == null or tex == _loading_texture or _spine_strip != null:
		return
	var mat := _spine_mesh.get_surface_override_material(0) as ShaderMaterial
	if mat == null:
		return
	var src := tex.get_image()
	if src == null or src.get_width() == 0:
		return
	var rows := mini(src.get_height(), 256)
	@warning_ignore("integer_division")
	var band := maxi(1, src.get_width() / 32)
	var strip := Image.create(1, rows, false, Image.FORMAT_RGBA8)
	for y in rows:
		@warning_ignore("integer_division")
		var sy := y * src.get_height() / rows
		var acc := Color(0.0, 0.0, 0.0)
		for x in band:
			acc += src.get_pixel(x, sy)
		strip.set_pixel(0, y, acc / float(band))
	_spine_strip = ImageTexture.create_from_image(strip)
	mat.set_shader_parameter("cover_texture", _spine_strip)
	mat.set_shader_parameter("has_cover", true)


func _update_back_cover_texture() -> void:
	var tex := _get_page_texture(_page_count - 1)
	_apply_texture(_back_cover_mesh, tex)


func _update_spread_textures() -> void:
	# Left page = back of current leaf (odd page index)
	var left_page_idx := _current_leaf * 2 + 1
	var left_tex := _get_page_texture(left_page_idx)
	_apply_texture(_left_stack_top, left_tex)

	# Right page = front of next leaf (even page index)
	var right_page_idx := (_current_leaf + 1) * 2
	var right_tex := _get_page_texture(right_page_idx) if right_page_idx < _page_count else null
	_apply_texture(_right_stack_top, right_tex)

	_trim_texture_cache()


func _update_stack_thickness() -> void:
	var left_count := _current_leaf + 1
	var right_count := _leaf_count - _current_leaf - 1

	var left_thick := maxf(left_count * LEAF_THICKNESS, LEAF_THICKNESS)
	var right_thick := maxf(right_count * LEAF_THICKNESS, LEAF_THICKNESS)

	if _left_stack:
		_left_stack.scale.z = left_thick / STACK_BASE_DEPTH
		_ensure_edge_material(_left_stack, left_count)
		_seat_stack_top(_left_stack, _left_stack_top, left_thick)
	if _right_stack:
		_right_stack.scale.z = right_thick / STACK_BASE_DEPTH
		_ensure_edge_material(_right_stack, right_count)
		_seat_stack_top(_right_stack, _right_stack_top, right_thick)

	_update_gutter_depth()

	# Open book: the binding is the FLOOR of the gutter valley, not a wall
	# between the pages. Its top has to finish just below where the pages bottom
	# out — centred at Z=0 with the full book depth it stood proud of both
	# stacks as a bright slab down the middle of the spread.
	var max_thick := maxf(left_thick, right_thick)
	var valley_top := _valley_z() - ZFIGHT_MARGIN
	var spine_bottom := -(max_thick * 0.5 + COVER_GAP)
	var open_spine_depth := maxf(valley_top - spine_bottom, LEAF_THICKNESS * 4.0)
	if _spine_mesh and _spine_mesh.mesh is BoxMesh:
		(_spine_mesh.mesh as BoxMesh).size.z = open_spine_depth
	_spine_node.position.z = spine_bottom + open_spine_depth * 0.5
	var spine_mat := _spine_mesh.get_surface_override_material(0) as ShaderMaterial
	if spine_mat:
		spine_mat.set_shader_parameter("gutter_shade", 1.0)
		spine_mat.set_shader_parameter("spine_depth", open_spine_depth)

	# Position covers just behind their respective stacks
	var half_w := _book_width / 2.0
	var stack_x := half_w + SPINE_WIDTH / 2.0
	_cover_mesh.position = Vector3(-stack_x, 0, -(left_thick / 2.0 + COVER_GAP))
	_back_cover_mesh.position = Vector3(stack_x, 0, -(right_thick / 2.0 + COVER_GAP))


# ── Page turning ──────────────────────────────────────────────────────────────

func turn_page_forward() -> void:
	if _is_turning:
		return

	var before := [_state, _current_leaf]
	match _state:
		BookState.CLOSED:
			_current_leaf = 0
			if _leaf_count <= 1:
				_set_state(BookState.LAST_PAGE)
			else:
				_set_state(BookState.OPEN)
		BookState.OPEN:
			_current_leaf += 1
			if _current_leaf >= _leaf_count - 1:
				_set_state(BookState.LAST_PAGE)
			else:
				_update_spread_textures()
				_update_stack_thickness()
				_prefetch_nearby_pages()
		BookState.LAST_PAGE:
			pass
	if before != [_state, _current_leaf]:
		_report_page()


func turn_page_backward() -> void:
	if _is_turning:
		return

	var before := [_state, _current_leaf]
	match _state:
		BookState.LAST_PAGE:
			_current_leaf = _leaf_count - 2
			if _current_leaf < 0:
				_set_state(BookState.CLOSED)
			else:
				_set_state(BookState.OPEN)
		BookState.OPEN:
			_current_leaf -= 1
			if _current_leaf < 0:
				_set_state(BookState.CLOSED)
			else:
				_update_spread_textures()
				_update_stack_thickness()
				_prefetch_nearby_pages()
		BookState.CLOSED:
			pass
	if before != [_state, _current_leaf]:
		_report_page()


# ── Active leaf: hand-driven fold ─────────────────────────────────────────────
#
# A page turn is one continuous deformation, not a rotation. The leaf wraps
# around a fold line whose position comes straight from where the hand is:
# the fold line is the perpendicular bisector of (grip point -> hand), pushed
# toward the spine by half the crease circumference so paper length is
# conserved. See paper.gdshader for the wrap itself.
#
# The classic Hong/Card/Chen cone model looks better but has no closed-form
# inverse — you cannot solve its apex/angle from a touch point — and tracking
# the hand exactly is the whole point here.


## Build the two grab zones. Their geometry depends on the loaded page size, so
## they are sized in _layout_page_grabs() rather than authored in the scene.
func _build_page_grabs() -> void:
	_grab_right = _make_page_grab(1)
	_grab_left = _make_page_grab(-1)


func _make_page_grab(dir: int) -> PageGrab:
	var zone := PageGrab.new()
	zone.name = "PageGrabRight" if dir > 0 else "PageGrabLeft"
	zone.direction = dir
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	zone.add_child(shape)
	add_child(zone)
	zone.grab_begin.connect(_on_page_grab_begin)
	zone.grab_move.connect(_on_page_grab_move)
	zone.grab_end.connect(_on_page_grab_end)
	return zone


## Thickness of the page stack on one side of the book.
func _side_thickness(dir: int) -> float:
	if _state != BookState.OPEN:
		return maxf(_leaf_count * LEAF_THICKNESS, LEAF_THICKNESS * 2)
	var leaves := (_leaf_count - _current_leaf - 1) if dir > 0 else (_current_leaf + 1)
	return maxf(leaves * LEAF_THICKNESS, LEAF_THICKNESS)


## Z of the page surface on one side of the book, in book-local space.
func _page_plane_z(dir: int) -> float:
	var gap := LEAF_Z_GAP if _state == BookState.OPEN else COVER_GAP
	return _side_thickness(dir) * 0.5 + gap


func _layout_page_grabs() -> void:
	if _grab_right == null:
		return
	var spine_half := SPINE_WIDTH * 0.5
	var half_x := _book_width * GRAB_BAND * 0.5
	var reach := Vector3(half_x, book_height * 0.5, 0.035)
	for pair: Array in [[_grab_right, 1.0], [_grab_left, -1.0]]:
		var zone: PageGrab = pair[0]
		var dir: float = pair[1]
		# Centred on the outer band of the page, measured out from the gutter.
		zone.position = Vector3(
			dir * (spine_half + _book_width * (1.0 - GRAB_BAND * 0.5)),
			0.0,
			_page_plane_z(int(dir)))
		zone.reach = reach
		var shape := zone.get_child(0) as CollisionShape3D
		(shape.shape as BoxShape3D).size = reach * 2.0
	_grab_right.set_enabled(_page_count > 0 and _state != BookState.LAST_PAGE)
	_grab_left.set_enabled(_page_count > 0 and _state != BookState.CLOSED)


## Which pages the turning leaf carries, and what shows through underneath.
## Returns {} when there is nothing to turn that way.
func _leaf_plan(dir: int) -> Dictionary:
	if dir > 0:
		match _state:
			BookState.CLOSED:
				return {"front": 0, "back": 1, "hide": _cover_mesh,
					"under": _right_stack_top, "under_page": 2}
			BookState.OPEN:
				var front := (_current_leaf + 1) * 2
				return {"front": front, "back": front + 1, "hide": null,
					"under": _right_stack_top, "under_page": (_current_leaf + 2) * 2}
	else:
		match _state:
			BookState.LAST_PAGE:
				return {"front": _page_count - 1, "back": _page_count - 2, "hide": _back_cover_mesh,
					"under": _left_stack_top, "under_page": _page_count - 3}
			BookState.OPEN:
				var front := _current_leaf * 2 + 1
				return {"front": front, "back": front - 1, "hide": null,
					"under": _left_stack_top, "under_page": (_current_leaf - 1) * 2 + 1}
	return {}


func _spawn_leaf(dir: int) -> bool:
	var plan := _leaf_plan(dir)
	if plan.is_empty():
		return false
	_despawn_active_leaf()

	var leaf := MeshInstance3D.new()
	leaf.name = "ActiveLeaf"
	var quad := QuadMesh.new()
	quad.size = Vector2(_book_width, book_height)
	var subdiv := LEAF_SUBDIV_DESKTOP if QualityManager.is_desktop() else LEAF_SUBDIV_QUEST
	quad.subdivide_width = subdiv.x
	quad.subdivide_depth = subdiv.y
	leaf.mesh = quad
	_set_paper_aabb(leaf, _book_width, book_height)
	# The leaf deforms every frame; an inverted-hull outline copy would not.
	leaf.add_to_group("outline_exclude")

	var mat := ShaderMaterial.new()
	mat.shader = PAPER_SHADER
	mat.set_shader_parameter("page_size", Vector2(_book_width, book_height))
	mat.set_shader_parameter("spine_sign", float(dir))
	mat.set_shader_parameter("grain_texture", _paper_grain())
	_apply_finish_to(mat, false)
	mat.set_shader_parameter("gutter_dive", _gutter_dive_for(_page_plane_z(dir)))
	mat.set_shader_parameter("bow_amount", REST_BOW)
	mat.set_shader_parameter("fore_droop", REST_DROOP)
	mat.set_shader_parameter("edge_curl", REST_EDGE_CURL)
	mat.set_shader_parameter("gutter_falloff", REST_GUTTER_FALLOFF)
	mat.set_shader_parameter("curl_taper", CURL_TAPER)
	mat.set_shader_parameter("front_texture", _get_page_texture(int(plan["front"])))
	var back_idx := int(plan["back"])
	if back_idx >= 0 and back_idx < _page_count:
		mat.set_shader_parameter("back_texture", _get_page_texture(back_idx))
	leaf.set_surface_override_material(0, mat)

	var stack_x := _book_width / 2.0 + SPINE_WIDTH / 2.0
	leaf.position = Vector3(dir * stack_x, 0.0, _page_plane_z(dir) + LEAF_LIFT)
	_active_leaf_container.add_child(leaf)
	_active_leaf = leaf
	_is_turning = true
	_turn_direction = dir

	# Reveal what the turning page is uncovering.
	var hide_node := plan.get("hide") as MeshInstance3D
	if hide_node:
		hide_node.visible = false
	var under := plan.get("under") as MeshInstance3D
	var under_page := int(plan["under_page"])
	if under:
		if under_page >= 0 and under_page < _page_count:
			under.visible = true
			_apply_texture(under, _get_page_texture(under_page))
		else:
			# Nothing behind it — the stack's own cream top reads as blank paper.
			under.visible = false
	return true


func _despawn_active_leaf() -> void:
	if _leaf_tween and _leaf_tween.is_valid():
		_leaf_tween.kill()
	_leaf_tween = null
	if _active_leaf:
		_active_leaf.queue_free()
		_active_leaf = null
	_is_turning = false
	_turn_direction = 0
	_grab_dir = 0
	_animate_target = {}


## Push the current fold into the leaf's material.
func _push_fold(strength: float) -> void:
	if _active_leaf == null:
		return
	var mat := _active_leaf.get_surface_override_material(0) as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("fold_strength", strength)
	mat.set_shader_parameter("fold_origin", _fold_origin)
	mat.set_shader_parameter("fold_normal", _fold_normal)
	mat.set_shader_parameter("curl_radius", _curl_radius)
	mat.set_shader_parameter("curl_taper", _curl_taper)


## Solve the fold line so the gripped point of the page sits under the hand.
func _update_fold_from_hand(world_pos: Vector3) -> void:
	if _active_leaf == null or _grab_dir == 0:
		return
	var hand: Vector3 = _active_leaf.to_local(world_pos)
	var dir := float(_grab_dir)
	var gutter_x := -dir * _book_width * 0.5
	var away := Vector2(hand.x, hand.y) - _grab_anchor
	var span := away.length()
	if span < 1e-4:
		return
	# Fold normal points from the fold line back toward where the grip started.
	var normal := -away / span
	# Crease radius follows how high the hand lifted, capped at span/PI so the
	# grip stays in the flipped-flap region — the only part of the wrap that
	# inverts to an exact fold line.
	var radius := clampf(minf(maxf(hand.z, 0.0) * 0.5, span / PI), CURL_MIN, CURL_MAX)
	var dist := (span + PI * radius) * 0.5

	# The fold line may not cross the BOUND EDGE — the binding holds it, so a
	# fold that would flip any part of the spine edge is impossible. Testing the
	# whole edge, rather than just keeping the fold origin clear of the gutter,
	# is what confines a turn to the spine: a horizontal fold line sails past a
	# point test, and the page hinged over its own top edge.
	#
	# Two things fall out of this instead of needing rules. Dragging parallel to
	# the spine cannot fold the page at all. Neither can dragging outward, away
	# from the binding. Corner drags still work, because their fold line clears
	# the bound edge at both ends.
	var bound_a := Vector2(gutter_x, -book_height * 0.5)
	var bound_b := Vector2(gutter_x, book_height * 0.5)
	var reach := maxf((bound_a - _grab_anchor).dot(normal), (bound_b - _grab_anchor).dot(normal))
	var limit := maxf(-reach - FOLD_GUTTER_MARGIN, 0.0)
	if limit <= 1e-5:
		# No fold in this direction is possible without tearing the binding.
		_fold_origin = Vector2(dir * (_book_width * 0.5 + 0.01), 0.0)
		_fold_normal = Vector2(dir, 0.0)
		_push_fold(0.0)
		return
	dist = minf(dist, limit)

	_fold_normal = normal
	_curl_radius = radius
	_fold_origin = _grab_anchor - normal * dist
	_push_fold(1.0)


## How far through the turn the fold line has travelled, 0 (untouched) to 1
## (laid flat on the far side).
func _turn_progress() -> float:
	if _grab_dir == 0:
		return 0.0
	var dir := float(_grab_dir)
	var fore_x := dir * _book_width * 0.5
	return clampf(dir * (fore_x - _fold_origin.x) / maxf(_book_width, 1e-5), 0.0, 1.0)


## Spring the page the rest of the way over, or back where it came from.
func _settle_leaf(commit: bool, duration: float = LEAF_SETTLE_TIME) -> void:
	if _active_leaf == null or _grab_dir == 0:
		return
	var dir := float(_grab_dir)
	var to_origin: Vector2
	var to_radius: float
	var to_taper: float
	# The page has to come to rest on the stack it lands on, not float above the
	# one it left. Those two planes are different heights — the receiving stack
	# is usually the thinner one — and the wrap always lifts the flipped half by
	# two crease radii, so the leaf's own plane drops as the fold completes and
	# the crease closes almost flat.
	var to_z := _active_leaf.position.z
	if commit:
		# Fold line exactly on the book's gutter: the page lands mirrored onto
		# the opposite stack.
		to_origin = Vector2(-dir * (_book_width * 0.5 + SPINE_WIDTH * 0.5), 0.0)
		to_radius = CURL_CLOSED
		to_taper = 0.0
		to_z = _page_plane_z(-_grab_dir) - CURL_CLOSED * 2.0 + LEAF_LIFT
	else:
		# Fold line off the fore edge leaves every vertex on the flat side.
		to_origin = Vector2(dir * (_book_width * 0.5 + 0.01), 0.0)
		to_radius = _curl_radius
		to_taper = _curl_taper
	var from_origin := _fold_origin
	var from_normal := _fold_normal
	var to_normal := Vector2(dir, 0.0)
	var from_radius := _curl_radius
	var from_taper := _curl_taper
	var from_z := _active_leaf.position.z
	var leaf := _active_leaf

	if _sfx:
		# How much page is still to travel decides how fast the sweep sounds.
		var remaining := 1.0 - _turn_progress() if commit else _turn_progress()
		_sfx.play_riffle(1.15 - clampf(remaining, 0.0, 1.0) * 0.35)
	_pulse(_grab_ctrl, 0.35, 60)

	if _leaf_tween and _leaf_tween.is_valid():
		_leaf_tween.kill()
	_leaf_tween = create_tween()
	_leaf_tween.set_ease(Tween.EASE_OUT)
	_leaf_tween.set_trans(Tween.TRANS_CUBIC)
	_leaf_tween.tween_method(
		func(t: float) -> void:
			_fold_origin = from_origin.lerp(to_origin, t)
			_fold_normal = from_normal.slerp(to_normal, t)
			_curl_radius = lerpf(from_radius, to_radius, t)
			_curl_taper = lerpf(from_taper, to_taper, t)
			if is_instance_valid(leaf):
				leaf.position.z = lerpf(from_z, to_z, t)
			_push_fold(1.0),
		0.0, 1.0, duration)
	var settled_dir := _grab_dir
	_leaf_tween.tween_callback(func() -> void: _finish_turn(settled_dir, commit))


func _finish_turn(dir: int, commit: bool) -> void:
	var target := _animate_target
	_animate_target = {}
	_despawn_active_leaf()
	if _sfx:
		_sfx.play_settle()
	if not commit:
		_set_state(_state)
	elif not target.is_empty():
		# Replaying somebody else's turn: land exactly on the spread they
		# reported, and do not report it back.
		_current_leaf = clampi(int(target["leaf"]), 0, maxi(_leaf_count - 1, 0))
		_set_state(clampi(int(target["state"]), BookState.CLOSED, BookState.LAST_PAGE) as BookState)
	elif dir > 0:
		turn_page_forward()
	else:
		turn_page_backward()
	# A page change that arrived mid-drag was held back rather than yanking the
	# page out of the player's hand — apply it now.
	_consume_pending_page()


## Drop a live grab immediately (no spring), e.g. because the book is being
## resized or reloaded underneath it.
func _abort_grab() -> void:
	if _grab_dir == 0:
		return
	var was_state := _state
	_despawn_active_leaf()
	_set_state(was_state)


func _on_page_grab_begin(dir: int, world_pos: Vector3) -> void:
	if _grab_dir != 0 or _page_count == 0:
		return
	if not _spawn_leaf(dir):
		return
	_grab_dir = dir
	# The spot you gripped is the spot that follows your hand.
	var local: Vector3 = _active_leaf.to_local(world_pos)
	_grab_anchor = Vector2(
		clampf(local.x, -_book_width * 0.5, _book_width * 0.5),
		clampf(local.y, -book_height * 0.5, book_height * 0.5))
	_fold_origin = Vector2(float(dir) * (_book_width * 0.5 + 0.01), 0.0)
	_fold_normal = Vector2(float(dir), 0.0)
	_curl_radius = CURL_MIN
	_curl_taper = CURL_TAPER
	_push_fold(0.0)
	# The sheet lifting off the stack: brief and high, not the full sweep.
	if _sfx:
		_sfx.play_riffle(1.35)
	# Cached now: PageGrab has already let go of the controller by the time it
	# reports the release, so the settle pulse could not look it up again.
	var zone := _grab_right if dir > 0 else _grab_left
	_grab_ctrl = zone.held_by() if zone else null
	_pulse(_grab_ctrl, 0.25, 40)


## Short rumble on the hand holding the page. Uses the project's XRTools rumble
## manager rather than raw haptic pulses, matching retro_controller.gd.
func _pulse(ctrl: XRController3D, magnitude: float, ms: int) -> void:
	if ctrl == null or not is_instance_valid(ctrl):
		return
	var event := XRToolsRumbleEvent.new()
	event.magnitude = magnitude
	event.duration_ms = ms
	XRToolsRumbleManager.add(&"page_turn", event, [ctrl.tracker])


func _on_page_grab_move(world_pos: Vector3) -> void:
	_update_fold_from_hand(world_pos)


func _on_page_grab_end(_dir: int) -> void:
	if _grab_dir == 0 or _active_leaf == null:
		return
	_settle_leaf(_turn_progress() >= TURN_COMMIT)


func _process(delta: float) -> void:
	if _turn_cooldown > 0.0:
		_turn_cooldown -= delta
	_update_hints_and_detect_grip()


func _unhandled_input(event: InputEvent) -> void:
	# Desktop page turning: E = next page, Q = previous page.
	# Reuses RETRO_JOYPAD_R (E key) and RETRO_JOYPAD_L (Q key) actions.
	# Only fires when the book is held and not mid-turn.
	if not is_picked_up() or _page_count == 0 or _turn_cooldown > 0.0:
		return
	if event.is_action_pressed("RETRO_JOYPAD_R"):
		turn_page_forward()
		_turn_cooldown = TURN_COOLDOWN_TIME
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("RETRO_JOYPAD_L"):
		turn_page_backward()
		_turn_cooldown = TURN_COOLDOWN_TIME
		get_viewport().set_input_as_handled()


## Show the page hints, and run the one-handed quick-flip fallback.
##
## The hints follow the trigger-grab zones, since that is the primary way to
## turn a page. The grip flip stays as a fallback for turning pages with the
## book in one hand, and never fires while a page is actually being dragged.
func _update_hints_and_detect_grip() -> void:
	_next_label.visible = false
	_prev_label.visible = false

	if _page_count == 0 or _grab_dir != 0:
		return

	if _grab_right and _grab_right.is_hovering():
		_next_label.visible = true
	if _grab_left and _grab_left.is_hovering():
		_prev_label.visible = true

	if not is_picked_up():
		return

	var holding_ctrl: XRController3D = get_picked_up_by_controller()
	if not holding_ctrl:
		return

	for ctrl: XRController3D in _controllers:
		if not ctrl or not ctrl.get_is_active() or ctrl == holding_ctrl:
			continue
		# A hand already holding something is not poking anything.
		if not PokeTip.is_poking(ctrl):
			continue

		var ctrl_pos_local: Vector3 = to_local(PokeTip.tip_of(ctrl))
		if absf(ctrl_pos_local.y) > book_height * 0.6:
			continue
		if absf(ctrl_pos_local.z) > 0.08:
			continue
		if absf(ctrl_pos_local.x) > _book_width + 0.05:
			continue

		var is_right := ctrl_pos_local.x > 0.0
		if is_right and _state != BookState.LAST_PAGE:
			_next_label.visible = true
		elif not is_right and _state != BookState.CLOSED:
			_prev_label.visible = true

		if ctrl.get_float("grip") < GRIP_THRESHOLD:
			continue
		if _turn_cooldown > 0.0:
			continue

		if is_right:
			turn_page_forward()
		else:
			turn_page_backward()
		_turn_cooldown = TURN_COOLDOWN_TIME
		return


# ── Utilities ─────────────────────────────────────────────────────────────────

func _create_loading_texture() -> void:
	var img := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.9, 0.9, 0.85))
	_loading_texture = ImageTexture.create_from_image(img)


func _create_hint_labels() -> void:
	_next_label = Label3D.new()
	_next_label.text = "Next Page →"
	_next_label.font_size = 32
	_next_label.pixel_size = 0.001
	_next_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_next_label.no_depth_test = true
	_next_label.modulate = Color(1, 1, 1, 0.8)
	_next_label.outline_modulate = Color(0, 0, 0, 0.6)
	_next_label.outline_size = 4
	_next_label.visible = false
	add_child(_next_label)

	_prev_label = Label3D.new()
	_prev_label.text = "← Prev Page"
	_prev_label.font_size = 32
	_prev_label.pixel_size = 0.001
	_prev_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_prev_label.no_depth_test = true
	_prev_label.modulate = Color(1, 1, 1, 0.8)
	_prev_label.outline_modulate = Color(0, 0, 0, 0.6)
	_prev_label.outline_size = 4
	_prev_label.visible = false
	add_child(_prev_label)


## Pre-render pages near the current spread so they're ready before the user turns.
func _prefetch_nearby_pages() -> void:
	if _page_count == 0:
		return
	var center := _current_leaf * 2
	for i in range(maxi(0, center - prefetch_pages), mini(_page_count, center + prefetch_pages + 2)):
		_get_page_texture(i)  # triggers background render if not cached


func _rebuild_highlight_overlays() -> void:
	for child in get_children():
		if child.has_method("rebuild_overlays"):
			child.rebuild_overlays()
			break


func _cleanup() -> void:
	_render_mutex.lock()
	if _renderer and _renderer.is_open():
		_renderer.close()
	_renderer = null
	_render_mutex.unlock()
	_cbz_entries.clear()
	_cbz_path = ""
	_spine_strip = null
	_texture_cache.clear()
	_pending_renders.clear()
	_despawn_active_leaf()
	_page_count = 0
	_leaf_count = 0
	_current_leaf = 0
