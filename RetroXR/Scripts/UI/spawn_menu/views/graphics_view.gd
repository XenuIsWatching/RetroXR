## SpawnMenuGraphicsView — the menu's GRAPHICS tab.
##
## Two halves: the desktop window mode / resolution rows, which drive the real OS
## window through DisplayServer, and the quality rows, which are a thin face over
## QualityManager. Nothing here reports back to the menu — every control writes
## straight to the autoload — so this view has no signals.
##
## It IS its own scroll container: the menu's _show_view wants a Control and a
## ScrollContainer, and for this tab they were always the same node.
class_name SpawnMenuGraphicsView
extends ScrollContainer

var _preset_opt:  VRDropdown = null
var _msaa_opt:    VRDropdown = null
var _post_aa_opt: VRDropdown = null
var _shadow_opt:  VRDropdown = null
var _ao_opt:      VRDropdown = null
var _glow_tog:    VRToggle = null
var _screen_lights_tog: VRToggle = null
var _syncing_screen_lights: bool = false
## A VRToggle's knob follows its own `toggled` signal, so _sync_rows has to move
## it loudly and the handler has to ignore the echo. set_pressed_no_signal would
## leave the switch and its state disagreeing.
var _syncing_glow: bool = false


## `vr_mode` is passed in rather than queried, so the caller decides once and
## every row agrees with the rest of the menu.
static func create(vr_mode: bool) -> SpawnMenuGraphicsView:
	var v := SpawnMenuGraphicsView.new()
	v._build(vr_mode)
	return v


# ── Desktop window mode / resolution ──────────────────────────────────────────

static func current_window_mode() -> String:
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN \
			or DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		return "fullscreen"
	return "borderless" if DisplayServer.window_get_flag(DisplayServer.WINDOW_FLAG_BORDERLESS) else "windowed"


static func current_resolution_key() -> String:
	var sz := DisplayServer.window_get_size()
	return "%dx%d" % [sz.x, sz.y]


static func apply_window_mode(mode: String) -> void:
	match mode:
		"fullscreen":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
		"borderless":
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, true)
		_:
			DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
			DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_BORDERLESS, false)


static func apply_resolution(key: String) -> void:
	var parts := key.split("x")
	if parts.size() != 2:
		return
	var win_size := Vector2i(int(parts[0]), int(parts[1]))
	# Only meaningful in windowed/borderless; leave fullscreen alone.
	if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_FULLSCREEN \
			or DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN:
		return
	DisplayServer.window_set_size(win_size)
	# Re-centre on the current screen so a bigger window doesn't spill off-screen.
	var screen := DisplayServer.window_get_current_screen()
	var origin := DisplayServer.screen_get_position(screen)
	var usable := DisplayServer.screen_get_size(screen)
	@warning_ignore("integer_division")
	var centred := origin + (usable - win_size) / 2
	DisplayServer.window_set_position(centred)


## Sizes the display can actually take, rather than a fixed list that capped out
## below the monitor. Godot exposes the native size but no mode enumeration, so
## the standard sizes are filtered against it and the native one always ends the
## list — on a 4K panel that is where 3840x2160 comes from. The current window
## size is folded in too, so the dropdown never opens on a blank value.
static func resolution_options() -> Array:
	var native := DisplayServer.screen_get_size(DisplayServer.window_get_current_screen())
	var sizes: Array[Vector2i] = []
	for candidate in [Vector2i(1280, 720), Vector2i(1600, 900), Vector2i(1920, 1080),
			Vector2i(1920, 1200), Vector2i(2560, 1440), Vector2i(2560, 1600),
			Vector2i(3440, 1440), Vector2i(3840, 2160)]:
		if candidate.x <= native.x and candidate.y <= native.y:
			sizes.append(candidate)
	for extra in [DisplayServer.window_get_size(), native]:
		if extra.x > 0 and extra.y > 0 and not sizes.has(extra):
			sizes.append(extra)
	sizes.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.x * a.y < b.x * b.y)

	var options: Array = []
	for candidate_size: Vector2i in sizes:
		var label := "%d×%d" % [candidate_size.x, candidate_size.y]
		if candidate_size == native:
			label += "  (native)"
		options.append([label, "%dx%d" % [candidate_size.x, candidate_size.y]])
	return options


## QualityManager persists the desktop window state; the DisplayServer calls stay
## here where they already live, so the stored values are pulled rather than
## pushed — an autoload's _ready runs long before this menu exists to hear a
## signal. Static because the menu restores the window before it builds any view.
static func restore_window_state() -> void:
	if MenuStyle.is_vr_mode():
		return
	if not QualityManager.window_mode.is_empty():
		apply_window_mode(QualityManager.window_mode)
	if not QualityManager.resolution.is_empty():
		apply_resolution(QualityManager.resolution)


# ── Build ─────────────────────────────────────────────────────────────────────

func _build(vr_mode: bool) -> void:
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var vbox := MenuStyle.vbox(14)
	add_child(vbox)

	vbox.add_child(MenuStyle.spacer(10))

	if not vr_mode:
		vbox.add_child(MenuStyle.header("DISPLAY"))

		# Window mode (desktop only). VRDropdown, not OptionButton — the menu is a
		# Viewport2Din3D and OptionButton double-fires there.
		var win_opt := VRDropdown.create("Window Mode",
			[["Windowed", "windowed"], ["Borderless", "borderless"], ["Fullscreen", "fullscreen"]],
			current_window_mode(), 3, Vector2(170, 52), 20)
		win_opt.item_selected.connect(func(id: Variant) -> void:
			apply_window_mode(str(id))
			QualityManager.set_window_state(str(id), ""))
		vbox.add_child(win_opt)

		# Resolution (applies while windowed/borderless; ignored in fullscreen).
		var res_opt := VRDropdown.create("Resolution", resolution_options(),
			current_resolution_key(), 2, Vector2(190, 52), 20)
		res_opt.item_selected.connect(func(id: Variant) -> void:
			apply_resolution(str(id))
			QualityManager.set_window_state("", str(id)))
		vbox.add_child(res_opt)

		vbox.add_child(HSeparator.new())

	vbox.add_child(MenuStyle.header("QUALITY"))

	# Custom is listed so the dropdown can display it, but picking it does nothing
	# — it is the state the rows below put the preset into, not a tier to select.
	_preset_opt = VRDropdown.create("Preset",
		[["Low", QualityManager.Preset.LOW],
		 ["Medium", QualityManager.Preset.MEDIUM],
		 ["High", QualityManager.Preset.HIGH],
		 ["Custom", QualityManager.Preset.CUSTOM]],
		int(QualityManager.preset), 4, Vector2(110, 52), 20)
	_preset_opt.item_selected.connect(func(id: Variant) -> void:
		if int(id) == QualityManager.Preset.CUSTOM:
			return
		QualityManager.apply_preset(int(id))
		_sync_rows()
	)
	vbox.add_child(_preset_opt)

	vbox.add_child(MenuStyle.hint("Sets everything below at once. Moving any single row "
		+ "afterwards turns this to Custom."))

	# Scaling the 3D pass corrupts the XR viewport on the mobile backend in both
	# directions, so the row is not offered there at all rather than shown with
	# values that would break the view.
	if QualityManager.supports_render_scale():
		var scale_opt := VRDropdown.create("Render Scale",
			[["50%", 0.5], ["70%", 0.7], ["85%", 0.85],
			 ["100%", 1.0], ["125%", 1.25], ["150%", 1.5]],
			QualityManager.render_scale, 6, Vector2(95, 52), 20)
		scale_opt.item_selected.connect(func(id: Variant) -> void:
			QualityManager.set_render_scale(float(id)))
		vbox.add_child(scale_opt)

		vbox.add_child(MenuStyle.hint("Resolution the 3D world is drawn at before it is scaled "
			+ "to the display. Below 100% FSR upscales it for cheaper frames; above 100% "
			+ "supersamples."))

	# The headset's counterpart to the row above, which the mobile backend cannot
	# take. Never both: render scale is Forward+, this is the headset.
	if QualityManager.supports_eye_buffer_scale():
		var eye_opt := VRDropdown.create("Eye Buffer",
			[["85%", 0.85], ["100%", 1.0],
			 ["123%", QualityManager.EYE_BUFFER_PANEL], ["140%", 1.4],
			 ["150%", 1.5], ["175%", 1.75], ["200%", 2.0]],
			QualityManager.eye_buffer_scale, 4, Vector2(95, 52), 20)
		eye_opt.item_selected.connect(func(id: Variant) -> void:
			QualityManager.set_eye_buffer_scale(float(id)))
		vbox.add_child(eye_opt)

		vbox.add_child(MenuStyle.hint("Resolution each eye is drawn at before the headset warps "
			+ "it through the lenses. 100% is the runtime's recommendation, which under-samples "
			+ "the centre of view; 123% matches the panel and is sharper where you look, for "
			+ "real frame time. Past that keeps paying off on things seen across the room, a "
			+ "game screen most of all, and is what Foveation buys you. The picture blinks as "
			+ "it resizes."))

	# Built from what the runtime enumerates, never a fixed list — a rate outside
	# it is refused, and 120 Hz appears only once the headset's own display setting
	# allows it. One rate on offer is no choice, so the row hides itself.
	if QualityManager.supports_display_rate():
		var rate_opts: Array = []
		for rate: float in QualityManager.available_display_rates():
			rate_opts.append(["%d Hz" % int(round(rate)), rate])
		var rate_opt := VRDropdown.create("Refresh Rate", rate_opts,
			QualityManager.effective_display_rate(), rate_opts.size(), Vector2(95, 52), 20)
		rate_opt.item_selected.connect(func(id: Variant) -> void:
			QualityManager.set_display_rate(float(id)))
		vbox.add_child(rate_opt)

		vbox.add_child(MenuStyle.hint("How many times a second the headset draws, in Hz. Higher "
			+ "is smoother only while the frame time keeps up; where it cannot, the headset "
			+ "repeats and reprojects frames instead. Watch the performance overlay's frame row "
			+ "after changing it."))

	# Foveation shades the edges of each eye at a fraction of the centre's rate.
	# Driven through the viewport's VRS rather than XR_FB foveation, which on this
	# stack is either inert or a flat brown screen — QualityManager's enum has the
	# measurements.
	if QualityManager.supports_foveation():
		var fov_opt := VRDropdown.create("Foveation",
			[["Off", QualityManager.Foveation.OFF],
			 ["Low", QualityManager.Foveation.LOW],
			 ["Medium", QualityManager.Foveation.MEDIUM],
			 ["High", QualityManager.Foveation.HIGH]],
			int(QualityManager.foveation_level), 4, Vector2(110, 52), 20)
		fov_opt.item_selected.connect(func(id: Variant) -> void:
			QualityManager.set_foveation_level(int(id)))
		vbox.add_child(fov_opt)

		vbox.add_child(MenuStyle.hint("Spends fewer pixels at the edges of each eye, where the "
			+ "lens throws detail away anyway, and hands the saving to the centre — worth about "
			+ "a third of the frame, which is what pays for a bigger Eye Buffer. While it is on, "
			+ "the hover outline around an object is hidden by anything in front of it instead "
			+ "of showing through."))

	# Requests to the runtime, not clock speeds — and nothing reads back, since
	# Godot binds the setters and no getter. The rows show what was asked for.
	if QualityManager.supports_perf_levels():
		var cpu_opt := VRDropdown.create("CPU Level", _perf_level_options(),
			int(QualityManager.cpu_level), 4, Vector2(150, 52), 20)
		cpu_opt.item_selected.connect(func(id: Variant) -> void:
			QualityManager.set_cpu_level(int(id)))
		vbox.add_child(cpu_opt)

		var gpu_opt := VRDropdown.create("GPU Level", _perf_level_options(),
			int(QualityManager.gpu_level), 4, Vector2(150, 52), 20)
		gpu_opt.item_selected.connect(func(id: Variant) -> void:
			QualityManager.set_gpu_level(int(id)))
		vbox.add_child(gpu_opt)

		vbox.add_child(MenuStyle.hint("What the headset is told to expect of this room, which it "
			+ "answers with clock speed inside its heat budget. Sustained High is the working "
			+ "default. Boost asks to run past that budget — it holds for a while, then the "
			+ "headset throttles and gets hot."))

	_msaa_opt = VRDropdown.create("Anti-Aliasing",
		[["Off", Viewport.MSAA_DISABLED], ["2×", Viewport.MSAA_2X],
		 ["4×", Viewport.MSAA_4X], ["8×", Viewport.MSAA_8X]],
		QualityManager.msaa_3d, 4, Vector2(110, 52), 20)
	_msaa_opt.item_selected.connect(func(id: Variant) -> void:
		QualityManager.set_msaa(int(id))
		_sync_rows())
	vbox.add_child(_msaa_opt)

	vbox.add_child(MenuStyle.hint("Multisampling on the 3D view. Smooths geometry edges only, "
		+ "and is nearly free on the headset's tiled GPU. The selected value is saved, but "
		+ "temporarily stands down while Foveation is on: on this Quest/Godot render path, "
		+ "combining the two eventually hangs the GPU. It returns automatically when "
		+ "Foveation is turned off."))

	# SMAA renders a stereo viewport black, so a headset session is offered only
	# what can actually run there rather than a row that breaks the view.
	var post_aa_opts: Array = [["Off", QualityManager.PostAA.OFF],
		["FXAA", QualityManager.PostAA.FXAA]]
	if QualityManager.supports_smaa():
		post_aa_opts.append(["SMAA", QualityManager.PostAA.SMAA])
	_post_aa_opt = VRDropdown.create("Edge Smoothing", post_aa_opts,
		int(QualityManager.effective_post_aa()), post_aa_opts.size(), Vector2(110, 52), 20)
	_post_aa_opt.item_selected.connect(func(id: Variant) -> void:
		QualityManager.set_post_aa(int(id))
		_sync_rows())
	vbox.add_child(_post_aa_opt)

	var post_aa_hint := "Catches what MSAA cannot — the carpet, wood and neon are drawn " \
		+ "by shaders, whose aliasing is inside the surface rather than on its edge. "
	post_aa_hint += "SMAA keeps detail; FXAA is cheaper but softens the whole picture." \
		if QualityManager.supports_smaa() else "FXAA softens the whole picture a little."
	vbox.add_child(MenuStyle.hint(post_aa_hint))

	_shadow_opt = VRDropdown.create("Shadows",
		[["Off", QualityManager.ShadowQuality.OFF],
		 ["Low", QualityManager.ShadowQuality.LOW],
		 ["Medium", QualityManager.ShadowQuality.MEDIUM],
		 ["High", QualityManager.ShadowQuality.HIGH]],
		int(QualityManager.shadow_quality), 4, Vector2(110, 52), 20)
	_shadow_opt.item_selected.connect(func(id: Variant) -> void:
		QualityManager.set_shadow_quality(int(id))
		_sync_rows())
	vbox.add_child(_shadow_opt)

	vbox.add_child(MenuStyle.hint("Off is the original look — lights still glow, nothing casts. "
		+ "Every room light, TV and handheld screen casts from Low up."))

	# Screen-space AO is a no-op on the mobile backend Quest renders with, so the
	# row is not offered there rather than sitting dead in the list.
	if QualityManager.supports_post_effects():
		_ao_opt = VRDropdown.create("Ambient Occlusion",
			[["Off", QualityManager.AOQuality.OFF],
			 ["Low", QualityManager.AOQuality.LOW],
			 ["High", QualityManager.AOQuality.HIGH]],
			int(QualityManager.ao_quality), 3, Vector2(110, 52), 20)
		_ao_opt.item_selected.connect(func(id: Variant) -> void:
			QualityManager.set_ao_quality(int(id))
			_sync_rows())
		vbox.add_child(_ao_opt)

		vbox.add_child(MenuStyle.hint("Contact shading where surfaces meet, so furniture and "
			+ "cabinets sit in the room instead of floating. Low draws it at half "
			+ "resolution."))

	# The rooms are authored with glow on, so this is a row that changes the look
	# rather than only the cost — but it is the single most expensive thing in a
	# frame here, so the choice belongs to the player.
	var glow_row := HBoxContainer.new()
	glow_row.add_theme_constant_override("separation", 10)
	glow_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(glow_row)

	var glow_lbl := Label.new()
	glow_lbl.text = "Glow"
	glow_lbl.add_theme_font_size_override("font_size", 22)
	glow_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	glow_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	glow_row.add_child(glow_lbl)

	_glow_tog = VRToggle.create(QualityManager.glow_enabled, func(on: bool) -> void:
		if _syncing_glow:
			return
		QualityManager.set_glow_enabled(on)
		_sync_rows())
	glow_row.add_child(_glow_tog)

	vbox.add_child(MenuStyle.hint("Bleeds light out of bright things — neon, lamps, a game "
		+ "screen in a dark room. It is the one full-frame pass this renderer still "
		+ "runs, and on a Quest it measured about a seventh of the frame, so turning "
		+ "it off is the biggest single saving in the list."))

	var sl_row := HBoxContainer.new()
	sl_row.add_theme_constant_override("separation", 10)
	sl_row.custom_minimum_size = Vector2(0, 68)
	vbox.add_child(sl_row)

	var sl_lbl := Label.new()
	sl_lbl.text = "Screen Light"
	sl_lbl.add_theme_font_size_override("font_size", 22)
	sl_lbl.add_theme_color_override("font_color", MenuStyle.COLOR_TITLE)
	sl_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl_row.add_child(sl_lbl)

	_screen_lights_tog = VRToggle.create(QualityManager.screen_lights_enabled, func(on: bool) -> void:
		if _syncing_screen_lights:
			return
		QualityManager.set_screen_lights_enabled(on)
		_sync_rows())
	sl_row.add_child(_screen_lights_tog)

	vbox.add_child(MenuStyle.hint("A lit screen throws its picture into the room - the glow on "
		+ "the console beside the set. Three lights per screen, shaded on everything "
		+ "they reach, so on a headset it starts off; the desktop keeps it."))

	vbox.add_child(HSeparator.new())


## The same four levels for both domains, in the order the OpenXR enum declares
## them.
func _perf_level_options() -> Array:
	return [["Power Save", QualityManager.PerfLevel.POWER_SAVINGS],
		["Low", QualityManager.PerfLevel.SUSTAINED_LOW],
		["High", QualityManager.PerfLevel.SUSTAINED_HIGH],
		["Boost", QualityManager.PerfLevel.BOOST]]


## Push QualityManager's current values back into the rows, so choosing a preset
## moves them and moving one of them shows Custom. select_id() does not re-emit,
## so this cannot loop back into the handlers that call it.
func _sync_rows() -> void:
	if _preset_opt:
		_preset_opt.select_id(int(QualityManager.preset))
	if _msaa_opt:
		_msaa_opt.select_id(QualityManager.msaa_3d)
	if _post_aa_opt:
		_post_aa_opt.select_id(int(QualityManager.effective_post_aa()))
	if _shadow_opt:
		_shadow_opt.select_id(int(QualityManager.shadow_quality))
	if _ao_opt:
		_ao_opt.select_id(int(QualityManager.ao_quality))
	if _glow_tog:
		_syncing_glow = true
		_glow_tog.button_pressed = QualityManager.glow_enabled
		_syncing_glow = false
	if _screen_lights_tog:
		_syncing_screen_lights = true
		_screen_lights_tog.button_pressed = QualityManager.screen_lights_enabled
		_syncing_screen_lights = false
