## PerfHud — the performance overlay behind OPTIONS > Debug.
##
## Four sections, each switched on independently: FRAME (how the headset is
## doing), MEMORY, SCENE (what the room costs) and EMULATION (what each running
## core is doing). A section that is off is not sampled at all.
##
## Drawn the way HeldHint draws its popups — a SubViewport of ordinary Controls
## on a Sprite3D — rather than as Label3Ds, which is what this replaced: a
## Label3D rebuilds its text mesh on every assignment, carries no panel behind
## it, and cannot lay two columns out so the digits stay still.
##
## In a headset it goes in the world, mounted either head-locked or on the left
## wrist — both plain parenting, so neither costs a per-frame follow. On a
## monitor there is a 2D corner to put it in, so it is drawn straight onto a
## CanvasLayer at the top left and the whole render-target path is skipped.
##
## Sampling is tiered, because this room is CPU-bound on Quest:
##   _process   push one float into a ring. No monitor reads, no allocations.
##   FAST_S     read the monitors, format the labels, redraw the viewport once.
##   SLOW_S     re-enumerate nodes (systems, ropes, spawned), the eye buffer and
##              the device clocks.
class_name PerfHud
extends Node3D

# ── Cadence ───────────────────────────────────────────────────────────────────
## Between label refreshes. Fast enough that the trace moves, slow enough that
## formatting a dozen strings is nothing.
const FAST_S := 0.25
## Between node censuses — anything that walks the tree or a group.
const SLOW_S := 2.0
## Frame samples kept for the trace: two seconds at 72 Hz.
##
## Deliberately reported as worst + missed count rather than as a "1% low":
## one percent of this window is a single frame, so a percentile here would be
## the worst frame under a name that implies it was averaged over many.
const RING := 144

## What counts as a missed frame, as a multiple of the refresh period.
##
## A frame that is keeping up lands ON the budget by definition — 13.9 ms at
## 72 Hz, every frame, however little work went into it — so being at or a hair
## over budget is the healthy state and not a fault. Judged against the budget
## itself, a Quest 3 holding a locked 72/72 with its GPU downclocked to 456 MHz
## of an available 690 painted every graded row of this section amber or red.
##
## A frame that genuinely misses has to wait out the NEXT vsync, so it arrives a
## whole period late rather than a fraction of one. Past one and a half periods
## is therefore a real miss, and everything under it is jitter around the lock.
const MISS_FACTOR := 1.5

# ── Device clocks ─────────────────────────────────────────────────────────────
## Where the SoC's governor has settled, read straight out of sysfs.
##
## Not the same question as "are we hitting the rate", and the more useful one
## once the answer to that is yes: a Quest 3 holding a locked 72/72 was found
## sitting at 456 MHz of an available 690, which is a governor that has clocked
## DOWN because the app is not asking for much. An app in trouble pins its
## ceiling instead. Read the busy figure beside it and not on its own — DVFS
## steers on busy and moves the CLOCK to hold it, so a flat 55% at half the
## ceiling and a flat 55% at the ceiling are opposite readings.
##
## Both trees are readable from the app's own UID and SELinux domain, verified on
## a Quest 3 through `run-as`, so neither figure needs a plugin or a native call.
## They exist nowhere else, which is why the rows are only built where a read of
## them actually succeeds.
##
## Deliberately NOT Meta's `CPU4/GPU=2/2` from the VrApi log line. That is their
## own 0-4 tier and it is not what the kgsl table is indexed by — 456 MHz is
## their level 2 and this table's sixth entry — so printing a rank from here
## under their name would be a different number wearing their label.
const GPU_CLOCK_PATH := "/sys/class/kgsl/kgsl-3d0/gpuclk"
const GPU_TABLE_PATH := "/sys/class/kgsl/kgsl-3d0/gpu_available_frequencies"
const GPU_BUSY_PATH := "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage"
const CPU_DIR := "/sys/devices/system/cpu"

# ── Panel metrics ─────────────────────────────────────────────────────────────
# Two sets. The VR one is read through a lens at arm's length and has to be
# generous; on a monitor those same sizes are drawn at 1:1 pixels and a panel
# with every section on covers half the window. Chosen per platform at _ready.
const PANEL_W := 430
const PAD := 14
const VALUE_W := 176
const CAPTION_PT := 17
const VALUE_PT := 18
const HEADER_PT := 15
const SPARK_H := 34

const DESKTOP_PANEL_W := 296
const DESKTOP_PAD := 10
const DESKTOP_VALUE_W := 122
const DESKTOP_CAPTION_PT := 12
const DESKTOP_VALUE_PT := 13
const DESKTOP_HEADER_PT := 11
const DESKTOP_SPARK_H := 24

var _panel_w := PANEL_W
var _pad := PAD
var _value_w := VALUE_W
var _caption_pt := CAPTION_PT
var _value_pt := VALUE_PT
var _header_pt := HEADER_PT
var _spark_h := SPARK_H

## Metres per viewport pixel, per mount. The wrist copy is read at ~35 cm and the
## head-locked one at 75 cm, so the wrist wants to be physically smaller to take
## the same share of the view.
const M_PER_PX_HEAD := 0.00050
const M_PER_PX_WRIST := 0.00030

## Head mount: up and to the left, out of the way of anything held in front of
## you. Above HeldHint's render_priority (3) so a grab hint cannot cover it.
const HEAD_OFFSET := Vector3(-0.28, 0.16, -0.75)
const HEAD_YAW_DEG := 14.0
const RENDER_PRIORITY := 4

## Wrist mount: over the back of the left forearm, tilted up toward the face, so
## it reads when the hand is turned over the way you would check a watch.
const WRIST_OFFSET := Vector3(0.0, 0.045, 0.075)
const WRIST_PITCH_DEG := -55.0

# ── Status colours ────────────────────────────────────────────────────────────
# Local rather than in MenuStyle: that file's own docstring says it is a place
# for repetition, not a licence to restyle, and nothing else uses these.
const OK := Color(0.55, 0.88, 0.55)
const WARN := Color(0.95, 0.78, 0.35)
const OVER := Color(0.96, 0.47, 0.38)
const DIM := Color(0.62, 0.62, 0.76)
## Indexed by QualityManager.Foveation, which the eye row names rather than
## printing the raw ordinal.
const FOVEATION_NAMES := ["Off", "Low", "Medium", "High"]

## How many emulator rows are drawn before the rest collapse into one line. Six
## running systems must not push MEMORY and SCENE off the panel, and the rows
## are sorted worst-first so the one misbehaving is always among those shown.
const EMU_ROWS_MAX := 4

## Which sections show, and where the panel sits. Static and deliberately NOT
## persisted, for the reason the collision-shape overlay beside it in OPTIONS is
## not: this is a look at how the app is running, not a setting, and a debug
## overlay that came back by itself after a restart would read as a bug.
static var show_frame := false
static var show_memory := false
static var show_scene := false
static var show_emulation := false
static var wrist_mount := true


## True when there is no headset. Decided once, at _ready — the XR session is up
## by then (xr_init runs at startup) and it cannot change mid-run.
@onready var _desktop: bool = not MenuStyle.is_vr_mode()
## Desktop only: the layer the panel is drawn on, over the game view.
var _canvas: CanvasLayer = null
## Inset from the top-left corner of the window, in pixels.
const DESKTOP_MARGIN := 16

var _viewport: SubViewport = null
var _panel: PanelContainer = null
var _rows: VBoxContainer = null
var _sprite: Sprite3D = null
var _spark: PerfSparkline = null
## Section key -> its VBoxContainer.
var _sections: Dictionary = {}
## Row key -> the Label holding its value.
var _val: Dictionary = {}
## Box the emulator rows are rebuilt into when the running set changes. A box and
## not a two-column grid like the other sections: a machine's line is one
## sentence — name, rate, fill — not a caption with a figure against it, and in
## the value column it just overflows.
var _emu_box: VBoxContainer = null

## The viewport the room is drawn into — the one whose render time is worth
## measuring. Not this node's own SubViewport, which only draws the panel.
var _vp_rid: RID = RID()

var _camera: XRCamera3D = null
var _left_hand: XRController3D = null
var _wrist_wanted := false

# Frame trace.
var _ring := PackedFloat32Array()
var _ring_i := 0
var _fast_accum := 0.0
var _slow_accum := 0.0
var _budget_ms := 13.9

# Cached censuses (slow tick).
var _ropes: Array[Node] = []
var _systems: Array[Node] = []
var _spawned_count := 0
var _eye_text := ""
## Set when the eye row is reporting foveation that was asked for but is not
## attached, which is the one state in that row worth a colour.
var _eye_warn := false
var _peak_static := 0

# Device clocks, sampled on the slow tick. The ceilings never move, so they are
# found once and kept; only the current figures are re-read.
var _cpu_clock_text := ""
var _gpu_clock_text := ""
var _cpu_max_khz := 0
var _gpu_max_hz := 0
var _cpu_cur_paths: PackedStringArray = PackedStringArray()
var _clocks_scanned := false

## Per-system sampling state, keyed by ObjectID — never by the node itself. A
## cabinet can be freed between two ticks, and holding a reference across that is
## how this project has crashed before.
var _emu: Dictionary = {}
## Set once the first Libretro node is seen: false against an extension built
## before the stat getters landed, so a stale .so degrades to measured fps only
## instead of erroring every quarter second.
var _emu_stats_ok := true
var _emu_stats_checked := false
## Signature of the running set, so the rows are only rebuilt when it changes.
var _emu_sig := ""


func _ready() -> void:
	_ring.resize(RING)
	if _desktop:
		_panel_w = DESKTOP_PANEL_W
		_pad = DESKTOP_PAD
		_value_w = DESKTOP_VALUE_W
		_caption_pt = DESKTOP_CAPTION_PT
		_value_pt = DESKTOP_VALUE_PT
		_header_pt = DESKTOP_HEADER_PT
		_spark_h = DESKTOP_SPARK_H
	set_process(false)
	visible = false


## Leaving timestamp queries running on a viewport nobody is reading is a cost
## for nothing, so the measurement dies with the node.
func _exit_tree() -> void:
	_measure_render_time(false)


func _measure_render_time(enable: bool) -> void:
	var vp := get_viewport()
	if vp == null:
		return
	_vp_rid = vp.get_viewport_rid() if enable else RID()
	RenderingServer.viewport_set_measure_render_time(vp.get_viewport_rid(), enable)


# ── Setup ─────────────────────────────────────────────────────────────────────

## Called by SpawnMenuController once the rig has been found.
func setup(camera: XRCamera3D, left_hand: XRController3D) -> void:
	_camera = camera
	_left_hand = left_hand
	apply_settings()


## Re-read the switches above and rebuild. One entry point rather than a signal
## per switch: five booleans and a mount through the menu's four-hop relay would
## be five signals to say "something on this page changed".
func apply_settings() -> void:
	var want: Array[String] = []
	if show_frame:
		want.append("frame")
	if show_memory:
		want.append("memory")
	if show_scene:
		want.append("scene")
	if show_emulation:
		want.append("emu")

	_wrist_wanted = wrist_mount

	if want.is_empty():
		_measure_render_time(false)
		_set_shown(false)
		set_process(false)
		return

	_ensure_nodes()
	_build_sections(want)
	_measure_render_time(want.has("frame"))
	_mount()
	_set_shown(true)
	set_process(true)
	# Sample immediately so the panel never shows a frame of placeholder dashes.
	_fast_accum = FAST_S
	_slow_accum = SLOW_S


func _ensure_nodes() -> void:
	if _panel != null:
		return

	# Desktop draws the panel straight onto a CanvasLayer in the corner of the
	# window. A headset needs it in the world because there is no 2D corner to
	# put it in, but on a monitor that indirection buys nothing and costs a
	# render target, a texture and a resample.
	if _desktop:
		_canvas = CanvasLayer.new()
		_canvas.name = "HudCanvas"
		_canvas.layer = 100
		add_child(_canvas)
	else:
		_viewport = SubViewport.new()
		_viewport.name = "HudViewport"
		_viewport.transparent_bg = true
		_viewport.disable_3d = true
		# UPDATE_ONCE, requested per sample tick. Never UPDATE_ALWAYS: that hangs
		# a headless run, and the content only changes when a tick refreshes it.
		_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		add_child(_viewport)

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = MenuStyle.COLOR_BG
	style.border_color = MenuStyle.COLOR_NAV_ACTIVE
	style.set_border_width_all(2)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(_pad)
	_panel.add_theme_stylebox_override("panel", style)
	if _desktop:
		_canvas.add_child(_panel)
	else:
		_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
		_viewport.add_child(_panel)

	_rows = MenuStyle.vbox(8)
	_panel.add_child(_rows)

	if _desktop:
		return

	_sprite = Sprite3D.new()
	_sprite.name = "HudSprite"
	_sprite.no_depth_test = true
	_sprite.render_priority = RENDER_PRIORITY
	_sprite.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_sprite.texture = _viewport.get_texture()
	add_child(_sprite)


# ── Panel construction ────────────────────────────────────────────────────────

func _build_sections(want: Array[String]) -> void:
	# remove_child BEFORE queue_free: freeing is deferred, so an outgoing section
	# is still in the tree — and still in the panel's minimum size — when the
	# panel is measured below. Left as a bare queue_free, every switch measured
	# the old sections plus the new ones and the panel grew without bound.
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()
	_sections.clear()
	_val.clear()
	_spark = null
	_emu_box = null
	_emu_sig = ""

	var first := true
	for key in want:
		if not first:
			_rows.add_child(HSeparator.new())
		first = false
		match key:
			"frame": _build_frame()
			"memory": _build_memory()
			"scene": _build_scene()
			"emu": _build_emu()

	_relayout()


func _section(key: String, title: String) -> VBoxContainer:
	var box := MenuStyle.vbox(4)
	box.add_child(MenuStyle.label(title, _header_pt, MenuStyle.COLOR_TITLE))
	_rows.add_child(box)
	_sections[key] = box
	return box


func _grid(parent: Container) -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 2)
	parent.add_child(g)
	return g


## A caption on the left and a right-aligned value on the right. The value column
## has a fixed width so a number changing width does not shift the row.
func _row(grid: GridContainer, key: String, caption: String) -> void:
	var cap := MenuStyle.label(caption, _caption_pt, MenuStyle.COLOR_LICENSE)
	cap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(cap)

	var val := MenuStyle.label("--", _value_pt, DIM)
	val.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	val.custom_minimum_size = Vector2(_value_w, 0)
	grid.add_child(val)
	_val[key] = val


func _put(key: String, text: String, color: Color = DIM) -> void:
	# is_instance_valid, not a null check: a rebuilt section leaves freed labels
	# behind, and assigning one to a TYPED local throws rather than reading null.
	var entry: Variant = _val.get(key)
	if not is_instance_valid(entry):
		return
	var label: Label = entry
	if label.text != text:
		label.text = text
	label.add_theme_color_override("font_color", color)


func _build_frame() -> void:
	var box := _section("frame", "FRAME")
	_spark = PerfSparkline.new()
	_spark.custom_minimum_size = Vector2(0, _spark_h)
	_spark.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(_spark)
	var g := _grid(box)
	_row(g, "fps", "frame rate")
	_row(g, "ms", "frame time")
	_row(g, "worst", "worst / missed")
	_row(g, "load", "gpu load")
	_row(g, "render", "render cpu / gpu")
	_row(g, "cpu", "process / physics")
	if MenuStyle.is_vr_mode():
		_row(g, "eye", "eye buffer")
	# Built on a successful read rather than on a platform check, so a panel never
	# carries a row that can only ever say n/a — and so a kernel that lays these
	# out somewhere else simply drops the row instead of printing a wrong number.
	if not _sysfs_line(GPU_CLOCK_PATH).is_empty():
		_row(g, "gpuclk", "gpu clock")
	if not _sysfs_line(CPU_DIR + "/cpu0/cpufreq/scaling_cur_freq").is_empty():
		_row(g, "cpuclk", "cpu clock")


func _build_memory() -> void:
	var g := _grid(_section("memory", "MEMORY"))
	_row(g, "vram", "video used")
	_row(g, "vsplit", "tex / buffer")
	_row(g, "ram", "static / peak")
	_row(g, "pool", _pool_caption())


func _build_scene() -> void:
	var g := _grid(_section("scene", "SCENE"))
	_row(g, "draws", "draws / prims")
	_row(g, "nodes", "nodes / orphans")
	_row(g, "bodies", "bodies / pairs")
	_row(g, "objects", "spawned / ropes")


func _build_emu() -> void:
	var box := _section("emu", "EMULATION")
	_emu_box = MenuStyle.vbox(2)
	box.add_child(_emu_box)
	var g := _grid(box)
	_row(g, "emu_audio", "underruns (all)")


## Fit the panel — and in VR the render target behind it — to what was built.
## Done after every rebuild, because the emulator section changes height as
## machines are switched on and off.
func _relayout() -> void:
	var wanted := Vector2(_panel_w, maxf(_panel.get_combined_minimum_size().y, 40.0))
	if _desktop:
		_panel.size = wanted
		_panel.position = Vector2(DESKTOP_MARGIN, DESKTOP_MARGIN)
		return
	_viewport.size = Vector2i(_panel_w, int(ceil(wanted.y)))
	_sprite.pixel_size = M_PER_PX_WRIST if _is_wrist() else M_PER_PX_HEAD


# ── Mounting ──────────────────────────────────────────────────────────────────

## A Node3D's `visible` does not reach a CanvasLayer child, so the two paths hide
## differently.
func _set_shown(shown: bool) -> void:
	visible = shown
	if _canvas != null:
		_canvas.visible = shown


## Wrist only when there is a hand to put it on: desktop has no tracked
## controller, so it falls back to the head rather than vanishing.
func _is_wrist() -> bool:
	return _wrist_wanted and _left_hand != null and not _desktop


func _mount() -> void:
	if _desktop:
		return   # a CanvasLayer is not placed in the world
	var host: Node3D = _left_hand if _is_wrist() else _camera
	if host == null:
		return
	if get_parent() != host:
		if get_parent() != null:
			get_parent().remove_child(self)
		host.add_child(self)

	if _is_wrist():
		position = WRIST_OFFSET
		rotation_degrees = Vector3(WRIST_PITCH_DEG, 0.0, 0.0)
	else:
		position = HEAD_OFFSET
		rotation_degrees = Vector3(0.0, HEAD_YAW_DEG, 0.0)
	if _sprite != null:
		_sprite.pixel_size = M_PER_PX_WRIST if _is_wrist() else M_PER_PX_HEAD


# ── Sampling ──────────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	# The only per-frame work: one float into the ring.
	_ring[_ring_i] = delta * 1000.0
	_ring_i = (_ring_i + 1) % RING

	_slow_accum += delta
	if _slow_accum >= SLOW_S:
		_slow_accum = 0.0
		_sample_slow()

	_fast_accum += delta
	if _fast_accum < FAST_S:
		return
	_fast_accum = 0.0
	_sample_fast()


## Anything that walks the tree or a group.
func _sample_slow() -> void:
	if _sections.has("scene"):
		_spawned_count = get_tree().get_nodes_in_group("spawned").size()
		if ClassDB.class_exists("VerletRope"):
			_ropes = get_tree().root.find_children("*", "VerletRope", true, false)
	if _sections.has("emu"):
		_collect_systems()
	if _sections.has("frame"):
		_budget_ms = _refresh_budget_ms()
		_eye_text = _eye_buffer_text()
		_sample_clocks()


func _sample_fast() -> void:
	if _sections.has("frame"):
		_update_frame()
	if _sections.has("memory"):
		_update_memory()
	if _sections.has("scene"):
		_update_scene()
	if _sections.has("emu"):
		_update_emu()
	# The desktop panel is an ordinary Control and redraws itself.
	if _viewport != null:
		_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


func _update_frame() -> void:
	var miss_ms := _budget_ms * MISS_FACTOR
	var worst := 0.0
	var missed := 0
	var filled := 0
	for ms in _ring:
		if ms <= 0.0:
			continue
		filled += 1
		worst = maxf(worst, ms)
		if ms > miss_ms:
			missed += 1

	var fps := Engine.get_frames_per_second()
	var target := 1000.0 / _budget_ms
	_put("fps", "%.0f / %.0f" % [fps, target], _grade(target - fps, 2.0, 6.0))

	var now_ms: float = _ring[(_ring_i - 1 + RING) % RING]
	_put("ms", "%.1f ms" % now_ms, _grade(now_ms, miss_ms, _budget_ms * 2.0))
	_put("worst", "%.1f ms · %d" % [worst, missed], _grade(float(missed), 1.0, 8.0))

	# GPU as a share of the budget, which is the framing VrApi's logcat line uses
	# and so is directly comparable to an on-device capture.
	#
	# GPU alone, with no CPU counterpart, because on a rate-locked app there is
	# no honest one to print. Wall-clock frame time sits on the refresh period
	# whatever the load, so quoting it against the budget is a fixed 100%; and
	# TIME_PROCESS in the row below carries the wait for the GPU inside it —
	# measured, a 144 Hz frame doing 2 ms of script work reports 8.2 ms, against
	# 3.0 ms for the same work with vsync off. The GPU timestamp is the only
	# figure here that falls when the room gets cheaper, so it is the only one
	# quoted as a share. What the CPU has to say is whether frames were missed,
	# and that is the row above.
	var gpu_ms := _render_gpu_ms()
	if gpu_ms > 0.0:
		var gpu_pct := gpu_ms / _budget_ms * 100.0
		_put("load", _pct(gpu_pct), _grade(gpu_pct, 85.0, 100.0))
		# Two decimals: a light scene renders in hundredths of a millisecond, and
		# at one decimal both halves read 0.0 and look like a broken measurement.
		_put("render", "%.2f / %.2f ms" % [_render_cpu_ms(), gpu_ms], DIM)
	else:
		# Timestamp queries are not available on every driver, and the GL path has
		# none at all. Say so rather than draw a confident 0%.
		_put("load", "n/a", DIM)
		_put("render", "n/a", DIM)

	# Ungraded. Only the physics half is a clean measure of work done — the
	# process half is the whole idle frame, wait included, for the reason above,
	# so there is no threshold on the pair that means anything.
	var proc_ms := float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0
	var phys_ms := float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
	_put("cpu", "%.1f / %.1f ms" % [proc_ms, phys_ms], DIM)

	if _val.has("eye"):
		_put("eye", _eye_text, WARN if _eye_warn else DIM)
	# Ungraded, like the two rows above it. A governor sitting at its ceiling is
	# not a fault — it means the headroom is spent, which is a thing to know and
	# not a thing to go red about. What judges this section is the rate and the
	# missed count.
	if _val.has("gpuclk"):
		_put("gpuclk", _gpu_clock_text, DIM)
	if _val.has("cpuclk"):
		_put("cpuclk", _cpu_clock_text, DIM)

	if _spark != null:
		_spark.set_trace(_ring, _ring_i, _budget_ms, miss_ms)
	if filled == 0:
		_put("ms", "--", DIM)


func _update_memory() -> void:
	var video := int(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	var tex := int(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED))
	var buf := int(Performance.get_monitor(Performance.RENDER_BUFFER_MEM_USED))
	var stat := int(Performance.get_monitor(Performance.MEMORY_STATIC))
	_peak_static = maxi(_peak_static, stat)

	# On a unified-memory device the video figure has a real ceiling to be a
	# share of; on a discrete GPU it has none that Godot can see, so it is left
	# as an absolute rather than quoted against the wrong total.
	var info := OS.get_memory_info()
	var physical := int(info.get("physical", -1))
	if _unified_memory() and physical > 0:
		_put("vram", "%s · %.1f%%" % [MenuStyle.human_bytes(video),
			float(video) / float(physical) * 100.0], DIM)
	else:
		_put("vram", MenuStyle.human_bytes(video), DIM)
	_put("vsplit", "%s / %s" % [MenuStyle.human_bytes(tex), MenuStyle.human_bytes(buf)], DIM)
	_put("ram", "%s / %s" % [MenuStyle.human_bytes(stat), MenuStyle.human_bytes(_peak_static)], DIM)

	# "free", not "available": Windows reports available as the COMMIT limit, which
	# came back as 62 GB against 31 GB of physical on this box — subtracting it
	# gives a negative "used". free is physical memory that is actually free.
	var free_bytes := int(info.get("free", -1))
	if physical > 0 and free_bytes >= 0:
		var used := physical - free_bytes
		_put("pool", "%s / %s" % [MenuStyle.human_bytes(used), MenuStyle.human_bytes(physical)],
			_grade(float(used) / float(physical), 0.80, 0.92))
	else:
		_put("pool", "unreported", DIM)


func _update_scene() -> void:
	var draws := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME)
	var prims := RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME)
	_put("draws", "%d / %s" % [draws, _thousands(prims)], DIM)

	var nodes := int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT))
	var orphans := int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT))
	_put("nodes", "%s / %d" % [_thousands(nodes), orphans], WARN if orphans > 0 else DIM)

	var bodies := int(Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS))
	var pairs := int(Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS))
	_put("bodies", "%d / %d" % [bodies, pairs], DIM)

	# Ropes are the known main-thread cost on Quest, and only an AWAKE one costs
	# anything — the solver skips a settled cable entirely.
	var awake := 0
	for rope in _ropes:
		if is_instance_valid(rope) and not rope.call("is_sleeping"):
			awake += 1
	_put("objects", "%d / %d awake" % [_spawned_count, awake],
		_grade(float(awake), 6.0, 12.0))


# ── Emulation ─────────────────────────────────────────────────────────────────

## The running machines, and the row set they imply. Slow tick only: this walks a
## group and asks each cabinet for its Libretro child.
func _collect_systems() -> void:
	_systems.clear()
	for node in get_tree().get_nodes_in_group("retro_system"):
		if not is_instance_valid(node):
			continue
		if not bool(node.get("is_powered_on")):
			continue
		if node.call("get_libretro_node") == null:
			continue
		_systems.append(node)

	# Drop sampling state for machines that have gone away, so a long session
	# does not accumulate an entry per cabinet ever switched on.
	var live: Dictionary = {}
	for node in _systems:
		live[node.get_instance_id()] = true
	for id: int in _emu.keys():
		if not live.has(id):
			_emu.erase(id)


func _update_emu() -> void:
	var rows: Array = []
	for node in _systems:
		if not is_instance_valid(node):
			continue
		var lib: Object = node.call("get_libretro_node")
		if lib == null:
			continue
		rows.append(_read_system(node, lib))

	# Worst first: a dropped frame is the loudest symptom, then falling short of
	# the rate the core asked for.
	rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return float(a["score"]) > float(b["score"]))

	_rebuild_emu_rows(rows)
	for i in range(mini(rows.size(), EMU_ROWS_MAX)):
		var r: Dictionary = rows[i]
		_put("emu_%d" % i, r["value"], r["color"])
	if rows.size() > EMU_ROWS_MAX:
		_put("emu_more", "%d more running" % (rows.size() - EMU_ROWS_MAX), DIM)

	# Underruns are one counter for the whole mixer, so they cannot be pinned on
	# any single core — hence a row of their own rather than a column above.
	var mx: Object = _meta_audio()
	if mx != null:
		var n := int(mx.call("get_underrun_count"))
		_put("emu_audio", str(n), OVER if n > 0 else OK)
	else:
		_put("emu_audio", "n/a", DIM)


## One machine's line. Emulated fps is derived from the core's own frame counter
## rather than from anything the core claims about its speed.
func _read_system(node: Node, lib: Object) -> Dictionary:
	if not _emu_stats_checked:
		_emu_stats_checked = true
		_emu_stats_ok = lib.has_method("GetDeclaredFps")

	var id := node.get_instance_id()
	var now_us := Time.get_ticks_usec()
	var frames := int(lib.call("GetFrameCount"))
	var dropped := int(lib.call("GetDroppedFrameCount")) if _emu_stats_ok else 0

	var state: Dictionary = _emu.get(id, {})
	var fps := float(state.get("fps", 0.0))
	var drop_rate := float(state.get("drop_rate", 0.0))
	if state.has("t"):
		var dt := float(now_us - int(state["t"])) / 1_000_000.0
		var df := frames - int(state["frames"])
		var dd := dropped - int(state["dropped"])
		# A negative delta means the counter restarted — a power cycle, or a
		# savestate load, which rewinds GetFrameCount. Drop the sample rather
		# than report a negative frame rate for a quarter of a second.
		if dt > 0.0 and df >= 0 and dd >= 0:
			fps = lerpf(fps, float(df) / dt, 0.5)
			drop_rate = lerpf(drop_rate, float(dd) / dt, 0.5)
		else:
			fps = 0.0
			drop_rate = 0.0
	_emu[id] = {"t": now_us, "frames": frames, "dropped": dropped,
		"fps": fps, "drop_rate": drop_rate}

	var declared := float(lib.call("GetDeclaredFps")) if _emu_stats_ok else 0.0
	var occupancy := int(lib.call("GetAudioBufferOccupancy")) if _emu_stats_ok else -1

	var text := "%s  %.1f" % [_short_name(node), fps]
	if declared > 0.0:
		text += " / %.1f" % declared
	if occupancy >= 0:
		text += "  %d%%" % occupancy
	if drop_rate >= 0.5:
		text += "  drop %.0f/s" % drop_rate

	var score := drop_rate * 10.0
	if declared > 0.0:
		score += maxf(declared - fps, 0.0)
	var color := OK
	if drop_rate >= 1.0 or (occupancy >= 0 and occupancy <= 10):
		color = OVER
	elif declared > 0.0 and fps < declared - 2.0:
		color = WARN
	return {"value": text, "color": color, "score": score}


## Rebuild the emulator rows only when the running set changes — every quarter
## second the values move, but the rows themselves rarely do.
func _rebuild_emu_rows(rows: Array) -> void:
	var shown := mini(rows.size(), EMU_ROWS_MAX)
	var sig := "%d:%d" % [shown, rows.size()]
	if sig == _emu_sig:
		return
	_emu_sig = sig

	# Drop the outgoing rows' keys as well as their nodes, or _val keeps handles
	# on freed labels for the rest of the session.
	for key: String in _val.keys():
		if key.begins_with("emu_") and key != "emu_audio":
			_val.erase(key)
	for child in _emu_box.get_children():
		_emu_box.remove_child(child)
		child.queue_free()
	for i in range(shown):
		_emu_line("emu_%d" % i)
	if rows.size() > shown:
		_emu_line("emu_more")
	if shown == 0:
		_emu_line("emu_none")
		_put("emu_none", "nothing running", DIM)
	_relayout.call_deferred()


## One machine's line: full width, left aligned, its own colour.
func _emu_line(key: String) -> void:
	var label := MenuStyle.label("--", _value_pt, DIM)
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.clip_text = true
	_emu_box.add_child(label)
	_val[key] = label


## What a row calls its machine. Two cabinets running the same system would
## otherwise be indistinguishable, so the ROM's own name breaks the tie.
func _short_name(node: Node) -> String:
	var label := str(node.call("_display_name"))
	var rom := str(node.get("rom_path"))
	if not rom.is_empty():
		label += " · " + rom.get_file().get_basename().left(14)
	return label.left(26)


func _meta_audio() -> Object:
	if not Engine.has_singleton("MetaXRAudio"):
		return null
	var mx: Object = Engine.get_singleton("MetaXRAudio")
	if mx == null or not bool(mx.call("is_available")):
		return null
	return mx


# ── Helpers ───────────────────────────────────────────────────────────────────

## One refresh period in ms — the budget every frame figure is measured against.
func _refresh_budget_ms() -> float:
	var xr := XRServer.find_interface("OpenXR")
	if xr != null and xr.is_initialized():
		var rate := float(xr.call("get_display_refresh_rate"))
		if rate > 1.0:
			return 1000.0 / rate
	var screen := DisplayServer.screen_get_refresh_rate()
	return 1000.0 / screen if screen > 1.0 else 1000.0 / 60.0


# ── Device clocks ─────────────────────────────────────────────────────────────

## One line out of sysfs, or "" if it cannot be read.
##
## get_line, never get_as_text: these files report a 4096-byte size they do not
## fill, and a length-based read hands back whatever else is in that buffer along
## with the value. This reads to the first newline and stops, so it does not care
## what the size was claimed to be.
func _sysfs_line(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return ""
	var line := file.get_line()
	file.close()
	return line.strip_edges()


## The ceilings, which do not move — found once, then kept for the session.
func _scan_clock_ceilings() -> void:
	_clocks_scanned = true
	for hz_text: String in _sysfs_line(GPU_TABLE_PATH).split(" ", false):
		if hz_text.is_valid_int():
			_gpu_max_hz = maxi(_gpu_max_hz, hz_text.to_int())

	var dir := DirAccess.open(CPU_DIR)
	if dir == null:
		return
	for entry: String in dir.get_directories():
		# "cpuidle" and "cpufreq" sit in here beside the cores themselves, and
		# only the numbered ones are cores.
		if not entry.begins_with("cpu") or not entry.substr(3).is_valid_int():
			continue
		var freq_dir := "%s/%s/cpufreq" % [CPU_DIR, entry]
		var ceiling := _sysfs_line(freq_dir + "/cpuinfo_max_freq")
		if not ceiling.is_valid_int():
			continue
		_cpu_max_khz = maxi(_cpu_max_khz, ceiling.to_int())
		_cpu_cur_paths.append(freq_dir + "/scaling_cur_freq")


func _sample_clocks() -> void:
	if not (_val.has("gpuclk") or _val.has("cpuclk")):
		return
	if not _clocks_scanned:
		_scan_clock_ceilings()
	_gpu_clock_text = _read_gpu_clock()
	_cpu_clock_text = _read_cpu_clock()


func _read_gpu_clock() -> String:
	var clock := _sysfs_line(GPU_CLOCK_PATH)
	if not clock.is_valid_int() or _gpu_max_hz <= 0:
		return "n/a"
	var text := "%d / %d MHz" % [clock.to_int() / 1_000_000, _gpu_max_hz / 1_000_000]
	var busy := _sysfs_line(GPU_BUSY_PATH).replace("%", "").strip_edges()
	if busy.is_valid_int():
		text += " · %d%%" % busy.to_int()
	return text


## The fastest core rather than an average across them: this app is single-thread
## bound, so what matters is the core the main thread is on, and a governor that
## has raised one core has raised the one doing the work.
##
## scaling_cur_freq, not cpuinfo_cur_freq — the second asks the hardware, which is
## slow and on many kernels root-only, while this one is what the governor last
## set and is a plain cached read.
func _read_cpu_clock() -> String:
	if _cpu_cur_paths.is_empty() or _cpu_max_khz <= 0:
		return "n/a"
	var cur_khz := 0
	for path: String in _cpu_cur_paths:
		var value := _sysfs_line(path)
		if value.is_valid_int():
			cur_khz = maxi(cur_khz, value.to_int())
	if cur_khz <= 0:
		return "n/a"
	return "%.2f / %.2f GHz" % [cur_khz / 1_000_000.0, _cpu_max_khz / 1_000_000.0]


## The eye buffer as the runtime actually sized it, and the foveation level.
##
## Sampled every slow tick rather than once at startup: meta/dynamic_resolution
## lets the runtime LOWER the eye buffer under GPU load, which xr_init.gd notes
## it cannot see because it only reads this once.
##
## The level comes from QualityManager, NOT from the interface's own
## `foveation_level` property. apply_foveation pins that property to 0 at every
## level and drives Godot's VRS instead, so reading it back reported "fov 0"
## whatever the row was set to — the readout could not distinguish foveation
## working from foveation gone, which is the distinction this row exists for.
func _eye_buffer_text() -> String:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		_eye_warn = false
		return "--"
	var size: Vector2 = xr.get_render_target_size()
	var level := int(QualityManager.foveation_level)
	var fov: String = FOVEATION_NAMES[level] if level < FOVEATION_NAMES.size() else "?"
	# Asked for but not attached: what an Eye Buffer change leaves behind for the
	# rest of the session. Worth about 20% of the GPU, and otherwise unobservable.
	_eye_warn = level != int(QualityManager.Foveation.OFF) \
		and not QualityManager.foveation_live()
	if _eye_warn:
		fov += " LOST"
	return "%d×%d  fov %s" % [int(size.x), int(size.y), fov]


## True where the GPU has no memory of its own and draws from system RAM — every
## mobile part, the Quest included. There, and only there, the physical total IS
## the video memory ceiling.
##
## Godot publishes video memory USED (here, RenderingDevice.get_memory_usage and
## the Performance monitors) but never a capacity, on any platform. A discrete
## card's total needs a Vulkan heap query the engine does not expose, so the row
## says what it can prove rather than quoting system RAM as if it were VRAM.
func _unified_memory() -> bool:
	return OS.has_feature("mobile") or OS.get_name() == "Android"


## What the pool row is called, since it means different things per platform.
func _pool_caption() -> String:
	return "shared pool" if _unified_memory() else "system ram"


## Measured render time for the viewport this HUD hangs in.
##
## Godot only measures these when asked (viewport_set_measure_render_time), and
## asking costs timestamp queries — so it is turned on with the FRAME section and
## off again with it. Both read 0 until a frame has been measured, and the GPU
## one stays 0 on a driver with no timestamp support.
func _render_gpu_ms() -> float:
	if _vp_rid == RID():
		return 0.0
	return RenderingServer.viewport_get_measured_render_time_gpu(_vp_rid)


func _render_cpu_ms() -> float:
	if _vp_rid == RID():
		return 0.0
	return RenderingServer.viewport_get_measured_render_time_cpu(_vp_rid)


## Green below `warn`, amber up to `over`, red past it.
func _grade(value: float, warn: float, over: float) -> Color:
	if value >= over:
		return OVER
	if value >= warn:
		return WARN
	return OK


## A share of the budget. Below 10 it keeps a decimal, so a nearly-free frame
## reads as 0.2% rather than as a flat 0% that looks like nothing was measured.
func _pct(value: float) -> String:
	return "%.1f%%" % value if value < 10.0 else "%.0f%%" % value


func _thousands(n: int) -> String:
	if n >= 1_000_000:
		return "%.1fM" % (float(n) / 1_000_000.0)
	if n >= 10_000:
		return "%.0fk" % (float(n) / 1000.0)
	return str(n)
