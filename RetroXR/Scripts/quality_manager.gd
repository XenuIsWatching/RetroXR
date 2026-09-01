## QualityManager — Autoload singleton that adapts visual quality per platform
## and owns the user-facing graphics settings from the menu's GRAPHICS tab
## (render scale, MSAA, shadows, ambient occlusion), persisted to
## user://graphics_prefs.json.
##
## Each room authors its own Environment for its own look — the arcade's neon
## haze is not the den's warm lamplight — so the settings here are layered onto
## whatever Environment the current scene brought, never swapped for one.
extends Node

const PREFS_PATH := "user://graphics_prefs.json"
const VRS_PROBE_EXTERNAL_CFG := "/sdcard/Android/data/com.xenu.retroxr/files/vrsprobe.cfg"


## Shadow tiers offered in the GRAPHICS tab. OFF is the original look: no light
## in the room casts a shadow at all.
enum ShadowQuality { OFF, LOW, MEDIUM, HIGH }

## Screen-space ambient occlusion tiers. Forward+ only — see supports_post_effects().
enum AOQuality { OFF, LOW, HIGH }

## Post-process edge smoothing, which catches what MSAA cannot: MSAA only samples
## geometry edges, so the procedural carpet, wood and neon shaders alias straight
## through it. TAA would cover the same ground but is not offered — it is inert on
## the mobile backend (measured: 0.004 mean pixel change against 0.493 for SMAA)
## and its history buffer smears under head motion.
enum PostAA { OFF, FXAA, SMAA }

## The one control most people will ever touch. CUSTOM is not selectable — it is
## what the preset becomes once an individual row is moved away from it.
enum Preset { LOW, MEDIUM, HIGH, CUSTOM }

## What the app tells the runtime about how hard this stretch of it works the
## chip, mirroring OpenXRInterface.PerfSettingsLevel. It is a declaration of
## complexity, not a clock in MHz — the runtime answers it with clocks, and
## answers the thermal budget first. SUSTAINED_HIGH means "high or dynamic
## complexity, held inside a thermally sustainable range"; BOOST asks to step
## OUTSIDE that range, which is granted for short stretches and paid for in heat
## and in the throttling that follows.
enum PerfLevel { POWER_SAVINGS, SUSTAINED_LOW, SUSTAINED_HIGH, BOOST }

## Fixed foveated rendering: the eye buffer's edges are shaded at a fraction of
## the centre's rate, which is nearly free detail to give up on a lens that
## over-samples the periphery anyway. Where it works it pays for the eye-buffer
## scale outright (12.92 ms / 71 fps against 17.04 / 56 at x1.229, Quest 3).
##
## The Quest runtime's XR_FB density-map path is deliberately not used here: on
## this Godot 4.7 / Quest 3 Vulkan stack both it and the subsampled-image variant
## cause Adreno GPU hangs. Instead we attach Godot's generated, ordinary VRS
## texture. Each eye gets an explicit (0, 0) NDC focus, i.e. its optical centre.
enum Foveation { OFF, LOW, MEDIUM, HIGH }

const FOVEATION_TIERS := {
	Foveation.LOW: {"min_radius": 45.0, "strength": 0.5},
	Foveation.MEDIUM: {"min_radius": 30.0, "strength": 1.0},
	Foveation.HIGH: {"min_radius": 20.0, "strength": 2.0},
}

## Render scale and the eye buffer are deliberately absent: both are a taste call
## about how much resolution to buy, not a quality tier, so a preset never moves
## either one.
const PRESETS := {
	Preset.LOW: {
		"msaa": Viewport.MSAA_4X, "post_aa": PostAA.OFF,
		"shadows": ShadowQuality.OFF, "ao": AOQuality.OFF,
	},
	Preset.MEDIUM: {
		"msaa": Viewport.MSAA_4X, "post_aa": PostAA.SMAA,
		"shadows": ShadowQuality.MEDIUM, "ao": AOQuality.LOW,
	},
	Preset.HIGH: {
		"msaa": Viewport.MSAA_4X, "post_aa": PostAA.SMAA,
		"shadows": ShadowQuality.HIGH, "ao": AOQuality.HIGH,
	},
}

## Positional shadow atlas edge, soft-shadow filter and depth precision per tier.
## The directional atlas gets twice the edge — it covers the whole room in one
## map where the positional atlas is subdivided between lights.
const SHADOW_TIERS := {
	ShadowQuality.OFF: {
		# Nothing casts at this tier, so an atlas would be VRAM reserved to go
		# unread — hand the smallest one back instead of leaving a tier's worth
		# allocated after switching down.
		"atlas": 256,
		"filter": RenderingServer.SHADOW_QUALITY_HARD,
		"bits16": true,
	},
	ShadowQuality.LOW: {
		"atlas": 1024,
		"filter": RenderingServer.SHADOW_QUALITY_HARD,
		"bits16": true,
	},
	ShadowQuality.MEDIUM: {
		"atlas": 2048,
		"filter": RenderingServer.SHADOW_QUALITY_SOFT_LOW,
		"bits16": true,
	},
	ShadowQuality.HIGH: {
		"atlas": 4096,
		"filter": RenderingServer.SHADOW_QUALITY_SOFT_HIGH,
		"bits16": false,
	},
}

## Half-resolution AO is the whole difference between the two tiers in cost.
const AO_TIERS := {
	AOQuality.LOW:  {"quality": RenderingServer.ENV_SSAO_QUALITY_LOW,  "half_size": true},
	AOQuality.HIGH: {"quality": RenderingServer.ENV_SSAO_QUALITY_HIGH, "half_size": false},
}

## Below 1.0 the 3D pass renders small and is upscaled into the full-size (eye)
## buffer; above 1.0 it supersamples.
const RENDER_SCALE_MIN := 0.5
const RENDER_SCALE_MAX := 1.5

## Multiplier on the OpenXR runtime's recommended eye-buffer size — the headset's
## counterpart to render scale, and on Quest the only resolution knob there is
## (see supports_render_scale).
##
## x1.0 is NOT "native": OpenXR's recommendedImageRect is a performance
## recommendation, not the display size. Meta ships Quest 3 with recommended
## 1680x1760 per eye against a 2064x2208 panel — about 80% linear, on purpose.
## Unity's default eye texture is the same recommended size; Quest titles that
## look sharper have raised it themselves.
##
## Nor is the shortfall a flat 1.23x upscale of the finished image: the compositor
## warps a rectilinear eye buffer through the lens distortion, which over-samples
## the periphery and under-samples the CENTRE, so the runtime sizes the
## recommendation to land ~1:1 in the middle. The missing detail is therefore
## concentrated exactly where you look, which is why raising this is worth real
## frame time — and why foveation is its natural partner (spend the pixels in the
## centre, drop the ones wasted at the edges).
##
## The frame time is real. Measured on a Quest 3 (arcade scene, 72 Hz = 13.9 ms):
##
##   1680x1760 (x1.0)      13.55 ms  68 fps
##   2065x2163 (x1.229)    17.04 ms  56 fps
##
## Fixed foveation pays for it outright: 12.92 ms / 71 fps at x1.229 in the same
## room. The generated VRS texture below is intended to recover that saving
## without enabling the runtime-owned XR_FB profile that lost the Vulkan device.
const EYE_BUFFER_SCALE_MIN := 0.7
const EYE_BUFFER_SCALE_MAX := 2.0
## Where a saved rate does not say otherwise. The headset takes the rate a heavy
## room can hold: at 120 Hz the 8.3 ms budget goes over on both CPU and GPU, and a
## missed frame is reprojected and repeated, so the higher rate buys stale frames
## rather than smoothness. A PCVR runtime drives a display whose rate it already
## knows, so it takes the highest one offered.
const DISPLAY_RATE_HEADSET := 72.0
## The Quest 3 panel edge over the runtime's recommendation, 2064/1680, and the
## default. It is NOT the ceiling, and the old claim here that past the panel the
## extra pixels are "resolved away by the compositor" was wrong — supersampling
## above panel resolution still suppresses the aliasing that minified content
## (a core's picture across the room) shows. RetroGameDevVR ships 1.75-2.0.
##
## STALE, and left here with its provenance because it is worth knowing why.
## Measured 2026-08-26 19:51 in the bedroom, MSAA 4x, foveation HIGH, static
## head, no core running:
##
##   scale  per eye      72 Hz   120 Hz    120 Hz, foveation OFF
##   1.00   1680x1760     72      120       120
##   1.25   2100x2200     72      120       105
##   1.50   2520x2640     72      105        78
##   1.75   2940x3080     72       85        58
##   2.00   3360x3520     72       68        43
##
## The room it describes no longer exists. `Polish bedroom exterior` landed at
## 22:12 the SAME EVENING, two hours and twenty-one minutes later, and put a
## street outside the window: four houses, a tree row and nine shrubs. Measured
## 2026-09-01 on a Quest 3 at x1.75, that street is 7.9 ms — the houses 1.15,
## the trees 2.44, and the shrubs 4.27, because alpha-tested foliage is paid for
## in overdraw on a tiler rather than in triangles.
##
## So the ladder was never re-measured against the room that shipped. What holds
## 72 Hz today, with the shell and the props both on the baked volume and the
## redundant lights retired:
##
##   scale  per eye      72 Hz
##   1.00   1680x1760     72   (8.5 ms)
##   1.25   2100x2200     72   (11.6 ms)
##   1.40   2352x2464     64   (13.4 ms)
##   1.75   2940x3080     42   (19.4 ms)
##
## x1.75 is out of reach and it is the ROOM, not one subsystem: with the shell
## baked, the props baked, the lights retired and the ENTIRE street hidden, it
## still measures 14.5 ms / 56 fps against a budget of about 12.3. What is left
## at that point is the shell and the machines being rasterised at 18.1 Mpixel a
## frame, and the only thing that reduces that is foveation.
##
## And the other half of the old ladder does not reproduce either: "foveation
## HIGH" bought its top rungs, and foveation now returns nothing on any of the
## five paths tried — see apply_foveation(). Both halves of this table are
## waiting on that.
const EYE_BUFFER_PANEL := 1.229

## Frames between tiny GPU-blurred regional samples for TV/handheld glow.
## Six is 12 Hz at the Quest baseline of 72 Hz: responsive after the blur, while
## avoiding a separate canvas draw for every active screen on every eye frame.
var screen_light_interval: int = 6

## Viewport.MSAA_* level applied to the root (XR) viewport.
var msaa_3d: int = Viewport.MSAA_2X
var post_aa: PostAA = PostAA.OFF
var preset: Preset = Preset.CUSTOM
var shadow_quality: ShadowQuality = ShadowQuality.OFF
var ao_quality: AOQuality = AOQuality.OFF
var render_scale: float = 1.0
var eye_buffer_scale: float = EYE_BUFFER_PANEL
## Requested XR display refresh rate. 0 means the platform default above.
var display_rate: float = 0.0
var cpu_level: PerfLevel = PerfLevel.SUSTAINED_HIGH
var gpu_level: PerfLevel = PerfLevel.SUSTAINED_HIGH
var foveation_level: Foveation = Foveation.HIGH
## Keep the XRVRS object alive: it owns the RID returned by make_vrs_texture().
var _vrs_generator: Object
var _vrs_refresh_serial: int = 0
## Whether the requested generated texture and its viewport attachment are live.
var _foveation_live: bool = false
## QA overrides for the VRS knobs, set by `vrsprobe.cfg` and normally unset.
## The tier table is what ships; these exist because a foveation level that is
## attached and measurably doing NOTHING cannot be told apart from one that is
## working without turning the knobs by hand on the device.
var _vrs_radius_override: float = -1.0
var _vrs_strength_override: float = -1.0
## "texture" (Godot's generated map) or "xr" (the runtime's own density map).
var _vrs_mode_override: String = ""
## Engine glow. The rooms author it; this is the switch that can take it away,
## because it is the only full-frame post-process the mobile backend still runs
## and it is what reads the eye buffer back.
var glow_enabled: bool = true
## Desktop window state. Empty resolution means "leave the window where it is".
var window_mode: String = ""
var resolution: String = ""

var _desktop: bool


func _ready() -> void:
	_desktop = OS.get_name() != "Android"
	_read_vrs_overrides()
	# The old full-frame readback needed a 30-frame Quest throttle. The new path
	# transfers only an older, completed 12x8 pass, so both renderers use this cadence.
	screen_light_interval = 6
	# Quest starts where it always was; desktop takes the tier these settings exist
	# to provide. Applied before _load_prefs so a saved preset wins.
	apply_preset(Preset.LOW if not _desktop else Preset.MEDIUM, false)
	_load_prefs()
	# _load_prefs restores the saved foveation, which would undo a boot override.
	_read_vrs_overrides()
	_adjust_lights()
	apply_render_scale()
	apply_msaa()
	apply_post_aa()
	apply_forced_quality()
	apply_shadow_quality()
	apply_ao_quality()
	# apply_foveation() is deliberately NOT called here, and that is worth a note
	# because it looks like an omission. It is one - a saved foveation level does
	# nothing until the player opens the graphics menu and changes it, and every
	# launch logs "foveation 0" whatever the preference says. Calling it was
	# measured, and it makes the app SLOWER: foveation returns nothing on this
	# stack while attaching it costs 1-2.4 ms, so honouring the preference at
	# boot is a straight regression until that is fixed. See apply_foveation().
	# Lights and each room's WorldEnvironment arrive with every scene load, and
	# lights also with every spawned TV or handheld, so both are configured as
	# they enter the tree rather than swept for.
	get_tree().node_added.connect(_on_node_added)
	_log_state()
	_run_vrs_probe()


## Read the VRS overrides BEFORE anything applies foveation.
##
## The whole sweep so far set foveation part way into a session, which is what
## `vrsprobe.cfg` is for — and an XR runtime normally wants its foveation
## requested when the swapchain is CREATED. Applying it later can be quietly
## ignored, which would look exactly like the inert result measured: a level
## that reports live and changes no frame time. This reads the same file at the
## top of _ready so the boot path can be measured too, and leaves the file in
## place for _run_vrs_probe to consume as usual.
func _read_vrs_overrides() -> void:
	var path := "user://vrsprobe.cfg"
	if not FileAccess.file_exists(path):
		path = VRS_PROBE_EXTERNAL_CFG
		if not FileAccess.file_exists(path):
			return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var cfg: Dictionary = parsed
	if cfg.has("vrs_mode"):
		_vrs_mode_override = str(cfg["vrs_mode"])
	if cfg.has("vrs_radius"):
		_vrs_radius_override = float(cfg["vrs_radius"])
	if cfg.has("vrs_strength"):
		_vrs_strength_override = float(cfg["vrs_strength"])
	if cfg.has("boot_foveation"):
		foveation_level = clampi(int(cfg["boot_foveation"]),
			Foveation.OFF, Foveation.HIGH) as Foveation
	print("[VRSProbe] boot overrides: mode '%s', foveation %d"
		% [_vrs_mode_override, int(foveation_level)])


## On-device QA hook, in the shape of spike.cfg and glprobe.cfg: a
## `vrsprobe.cfg` applies a Foveation level and/or Eye Buffer scale part way
## into a session, so the mid-session path can be exercised over adb with
## nobody in the headset to work the graphics menu.
##
## `{"after": 400, "foveation": 3, "eye_buffer": 2.0}` — `after` in frames,
## the other two optional. Taken from the external files dir as well as
## user://, because a release build cannot be reached by `adb run-as`. The cfg
## is deleted as it is read, so a crashed run cannot wedge the next launch.
func _run_vrs_probe() -> void:
	var path := "user://vrsprobe.cfg"
	if not FileAccess.file_exists(path):
		path = VRS_PROBE_EXTERNAL_CFG
		if not FileAccess.file_exists(path):
			return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var cfg: Dictionary = parsed
	# Seconds rather than frames when asked for: under RenderDoc injection the
	# warm runs at a fraction of a frame a second, so a frame count fires long
	# after the capture it was meant to precede.
	if cfg.has("after_sec"):
		var secs := float(cfg["after_sec"])
		print("[VRSProbe] armed: %s, in %.1f s" % [JSON.stringify(cfg), secs])
		await get_tree().create_timer(secs).timeout
	else:
		var after: int = int(cfg.get("after", 400))
		print("[VRSProbe] armed: %s, in %d frames" % [JSON.stringify(cfg), after])
		for i in after:
			await get_tree().process_frame
	if cfg.has("eye_buffer"):
		print("[VRSProbe] eye_buffer -> %.2f" % float(cfg["eye_buffer"]))
		set_eye_buffer_scale(float(cfg["eye_buffer"]))
	if cfg.has("msaa"):
		var m := int(cfg["msaa"])
		print("[VRSProbe] msaa -> %d" % m)
		get_tree().root.msaa_3d = m as Viewport.MSAA
	if cfg.has("hide"):
		# Probe knob for the "what would you cut from the room" question: hide a
		# named subtree and measure what it was costing, rather than reasoning
		# about it from a draw list.
		for want in cfg["hide"]:
			var hit := 0
			for node in get_tree().root.find_children("*", "Node3D", true, false):
				if node.name == String(want):
					(node as Node3D).visible = false
					hit += 1
			print("[VRSProbe] hide '%s' -> %d node(s)" % [want, hit])
	if cfg.has("max_lights"):
		_probe_cap_lights(int(cfg["max_lights"]))
	if cfg.has("vrs_radius"):
		_vrs_radius_override = float(cfg["vrs_radius"])
	if cfg.has("vrs_strength"):
		_vrs_strength_override = float(cfg["vrs_strength"])
	if cfg.has("vrs_mode"):
		_vrs_mode_override = str(cfg["vrs_mode"])
	if cfg.has("foveation"):
		print("[VRSProbe] foveation -> %d" % int(cfg["foveation"]))
		set_foveation_level(int(cfg["foveation"]))
	print("[VRSProbe] applied, foveation_live=%s" % foveation_live())


## Hide all but the `keep` strongest Light3Ds in the tree. A probe knob only:
## the shell is lit by a baked volume now, so the room's real lights exist for
## the PROPS, and how much those lights cost is worth measuring before any of
## them is authored away.
func _probe_cap_lights(keep: int) -> void:
	var lights: Array[Light3D] = []
	for node in get_tree().root.find_children("*", "Light3D", true, false):
		var l := node as Light3D
		if l.is_visible_in_tree() and l.light_energy > 0.0:
			lights.append(l)
	lights.sort_custom(func(a: Light3D, b: Light3D) -> bool:
		return a.light_energy > b.light_energy)
	var hidden := 0
	for i in range(keep, lights.size()):
		lights[i].visible = false
		hidden += 1
	print("[VRSProbe] max_lights %d - kept %d, hid %d" % [keep, mini(keep, lights.size()), hidden])


## Report what the settings actually resolved to, so a wrong renderer string or a
## stale pref is visible in logcat instead of only in the headset — the same
## reason xr_init logs its eye buffer.
func _log_state() -> void:
	var root := get_tree().root
	print(("QualityManager: renderer '%s', scale %.2f (mode %d), msaa %d, post_aa %d, "
		+ "preset %d, shadows %d, ao %d, atlas %d") % [
		RenderingServer.get_current_rendering_method(), root.scaling_3d_scale,
		root.scaling_3d_mode, root.msaa_3d, root.screen_space_aa, preset,
		shadow_quality, ao_quality, root.positional_shadow_atlas_size])


## Screen-space effects (SSAO here, plus SSIL/SSR/volumetric fog if they are
## ever added) are Forward+ only. Android renders with the mobile backend, where
## setting them is silently a no-op — measured, not assumed.
func supports_post_effects() -> bool:
	return _is_forward_plus()


## SMAA's pass is not multiview-aware. On a stereo viewport it asks for a
## single-layer framebuffer against the two-layer eye buffer, `framebuffer_create`
## returns null, and every bind and draw on that list is dropped — the headset
## renders black at ~20 errors a frame ("Layers of our texture doesn't match view
## count for this framebuffer"). Measured over Link (Oculus runtime 1.206.0,
## Forward+): SMAA floods, FXAA and OFF are clean, and SMAA in the same build
## under `--xr-mode off` is clean too, so the trigger is the view count and not
## the runtime. Quest never showed it because the mobile backend ignores SMAA
## and the Android preset is LOW, which asks for none.
##
## Asked of the interface rather than `get_viewport().use_xr`: this is an autoload,
## so it runs before xr_init.gd sets that flag, while OpenXR is already initialised
## by then (the engine brings it up during startup).
func supports_smaa() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	return xr == null or not xr.is_initialized()


func _is_forward_plus() -> bool:
	return RenderingServer.get_current_rendering_method() == "forward_plus"


func is_desktop() -> bool:
	return _desktop


func _adjust_lights() -> void:
	# Ceiling lights — dimmer for arcade feel, extra dim on Quest
	var ceil_energy := 0.8 if _desktop else 0.6
	for light in get_tree().get_nodes_in_group("ceiling_light"):
		if light is Light3D:
			light.light_energy = ceil_energy

	# Neon sign lights — reduced on Quest
	var neon_energy := 1.5 if _desktop else 0.5
	for light in get_tree().get_nodes_in_group("neon_light"):
		if light is Light3D:
			light.light_energy = neon_energy


# ── Graphics settings ─────────────────────────────────────────────────────────

## Scaling the 3D pass at all breaks the mobile backend's XR viewport, in both
## directions and for both upscalers. Measured on a Quest 3: 0.5x logs
## `!draw_list.active` ~177 times a frame (510,724 in 40 s, against 0 at 1.0x),
## and 1.5x renders the scene into a corner of the eye buffer with stale frame
## data filling the rest. Neither shows up on a desktop SubViewport under the
## same backend, so only the headset catches it. The knob is therefore not
## offered there — 1.0 is the only safe value, and the way to spend resolution
## on that headset is the eye-buffer multiplier in xr_init.gd instead.
func supports_render_scale() -> bool:
	return _is_forward_plus()


func set_render_scale(scale: float) -> void:
	render_scale = clampf(scale, RENDER_SCALE_MIN, RENDER_SCALE_MAX) \
		if supports_render_scale() else 1.0
	apply_render_scale()
	save_prefs()


func apply_render_scale() -> void:
	var root := get_tree().root
	root.scaling_3d_scale = render_scale
	# FSR1 is a spatial upscaler, so it has none of the temporal ghosting that
	# rules FSR2 out for a head-tracked view. At 1.0 and above it would only cost
	# a pass for nothing, so bilinear takes over there.
	root.scaling_3d_mode = Viewport.SCALING_3D_MODE_FSR if render_scale < 1.0 \
		else Viewport.SCALING_3D_MODE_BILINEAR


## Whether the eye-buffer knob means anything in this session. PCVR is left out
## on purpose: those runtimes size and supersample their own swapchains, and a
## desktop session already has the render-scale row for the same job.
##
## Asked of the interface rather than get_viewport().use_xr for the same reason
## supports_smaa() is — this autoload runs before xr_init.gd sets that flag,
## while OpenXR is already initialised by then.
func supports_eye_buffer_scale() -> bool:
	if _desktop:
		return false
	var xr := XRServer.find_interface("OpenXR")
	return xr != null and xr.is_initialized()


func set_eye_buffer_scale(scale: float) -> void:
	eye_buffer_scale = clampf(scale, EYE_BUFFER_SCALE_MIN, EYE_BUFFER_SCALE_MAX)
	apply_eye_buffer_scale()
	save_prefs()


## Resize the eye buffer, at startup or mid-session.
##
## Mid-session is supported by the engine: the property setter hands the value to
## the rendering thread, and OpenXRAPI::pre_render compares the recommended size
## against the live swapchain every frame, freeing and rebuilding both swapchains
## when they differ (openxr_api.cpp, Godot 4.7). That reallocation is why the menu
## offers steps rather than a dragged slider — one hitch per selection instead of
## one per frame of the drag.
##
## xr_init.gd calls this before `use_xr = true`, so a launch allocates once at the
## saved size rather than building the recommended swapchain and rebuilding it on
## the first frame.
func apply_eye_buffer_scale() -> void:
	if not supports_eye_buffer_scale():
		return
	var xr := XRServer.find_interface("OpenXR")
	xr.set("render_target_size_multiplier", eye_buffer_scale)
	if foveation_live():
		_schedule_vrs_refresh()


## The rates this runtime will accept, straight from xrEnumerateDisplayRefreshRatesFB.
## Never a fixed list: a Quest enumerates 120 Hz only once it has been enabled in
## the headset's own display settings, and a runtime without the extension returns
## nothing at all — asking for a rate outside the list is refused.
func available_display_rates() -> Array:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized():
		return []
	var rates: Array = xr.call("get_available_display_refresh_rates")
	return rates


func supports_display_rate() -> bool:
	return available_display_rates().size() > 1


## The rate that will actually be asked for: the saved one, or the platform
## default, snapped to the nearest the runtime offers so the menu row can tick it.
func effective_display_rate() -> float:
	var rates := available_display_rates()
	if rates.is_empty():
		return 0.0
	var target := display_rate
	if target <= 0.0:
		target = DISPLAY_RATE_HEADSET
		if _desktop:
			target = float(rates.max())
	var best: float = rates[0]
	for rate: float in rates:
		if absf(rate - target) < absf(best - target):
			best = rate
	return best


func set_display_rate(rate: float) -> void:
	display_rate = maxf(rate, 0.0)
	apply_display_rate()
	save_prefs()


## Ask the runtime for a refresh rate, at startup or mid-session.
##
## Mid-session is what the extension is for: the call is a bare
## xrRequestDisplayRefreshRateFB on the running session, which is legal at any
## point in it and tears nothing down. A refused rate only logs.
##
## There is no separate frame-rate target to keep in step — xr_init.gd disables
## vsync and the runtime paces frames through xrWaitFrame, so this IS the target.
## Engine.physics_ticks_per_second deliberately does NOT follow it: the rope
## solver is tuned and regression-tested at a fixed tick rate, and moving it under
## every cable in the room is far more than this setting is worth.
func apply_display_rate() -> void:
	var best := effective_display_rate()
	if best <= 0.0:
		return
	var xr := XRServer.find_interface("OpenXR")
	xr.call("set_display_refresh_rate", best)
	print("QualityManager: display refresh rate %s Hz (available: %s)" % [
		best, available_display_rates()])


## Whether the runtime takes performance-level requests. Asked with has_method
## rather than a version check, and headset-only: XR_EXT_performance_settings is
## a mobile-thermal extension, and Godot exposes no way to ask whether the runtime
## actually carries it — the engine silently drops the call where it does not.
func supports_perf_levels() -> bool:
	if _desktop:
		return false
	var xr := XRServer.find_interface("OpenXR")
	return xr != null and xr.is_initialized() and xr.has_method("set_cpu_level")


func set_cpu_level(level: int) -> void:
	cpu_level = clampi(level, PerfLevel.POWER_SAVINGS, PerfLevel.BOOST) as PerfLevel
	apply_perf_levels()
	save_prefs()


func set_gpu_level(level: int) -> void:
	gpu_level = clampi(level, PerfLevel.POWER_SAVINGS, PerfLevel.BOOST) as PerfLevel
	apply_perf_levels()
	save_prefs()


## Declare both domains at once — xrPerfSettingsSetPerformanceLevelEXT per domain,
## legal at any point in a session.
##
## Nothing can report back what the chip is actually running at: Godot binds the
## two setters and no getter, so the menu shows what was asked for, not what was
## granted. What the runtime does say is when the answer has changed — the
## cpu_level_changed / gpu_level_changed signals carry a thermal notification
## level (normal / warning / impaired) rather than a clock.
func apply_perf_levels() -> void:
	if not supports_perf_levels():
		return
	var xr := XRServer.find_interface("OpenXR")
	xr.call("set_cpu_level", int(cpu_level))
	xr.call("set_gpu_level", int(gpu_level))


## This requires Vulkan VRS and Godot's generator, but not the unstable runtime
## XR_FB foveation extension.
func supports_foveation() -> bool:
	if _desktop or not ClassDB.class_exists("XRVRS"):
		return false
	var xr := XRServer.find_interface("OpenXR")
	return xr != null and xr.is_initialized() \
		and RenderingServer.get_rendering_device() != null


## Whether a stencil-based material may be drawn this session.
##
## False while foveation is on, and that is a crash guard rather than a taste
## call: with VRS active, drawing the outline_mask/outline stencil pair loses the
## Vulkan device inside two seconds on a Quest 3 (a fault in the opaque pass,
## two runs out of two, never once with VRS off). The highlight overlays ask this
## and take the stencil-free outline_hull instead; see that shader for the trade.
func stencil_safe() -> bool:
	return foveation_level == Foveation.OFF


## Takes effect on the current root viewport without changing the XR swapchain.
func set_foveation_level(level: int) -> void:
	foveation_level = clampi(level, Foveation.OFF, Foveation.HIGH) as Foveation \
		if supports_foveation() else Foveation.OFF
	apply_foveation()
	save_prefs()


## Attach a conventional two-layer VRS texture. This intentionally keeps every
## XR_FB setting at zero/off: the generated image is a normal Godot texture and
## does not ask the Quest runtime to create or import a fragment-density map.
func apply_foveation() -> void:
	var xr := XRServer.find_interface("OpenXR")
	var root := get_tree().root
	if xr != null and xr.is_initialized():
		xr.set("foveation_with_subsampled_images", false)
		xr.set("foveation_dynamic", false)
		xr.set("foveation_level", int(Foveation.OFF))
	_vrs_refresh_serial += 1
	if foveation_level == Foveation.OFF or not supports_foveation():
		root.vrs_mode = Viewport.VRS_DISABLED
		RenderingServer.viewport_set_vrs_texture(root.get_viewport_rid(), RID())
		_vrs_generator = null
		_foveation_live = false
		apply_msaa()
		return
	# Fragment-density VRS and MSAA share the mobile render subpass. On Quest 3
	# this combination eventually hangs the Adreno Vulkan context even at Low
	# VRS; the same scene survived beyond that failure window single-sampled.
	# Keep the preference intact, but render single-sample while VRS is live.
	apply_msaa()
	_generate_centered_vrs()


func _generate_centered_vrs() -> void:
	var xr := XRServer.find_interface("OpenXR")
	var root := get_tree().root
	if xr == null or not xr.is_initialized():
		_foveation_live = false
		return
	var size: Vector2 = xr.get_render_target_size()
	if size.x <= 0.0 or size.y <= 0.0:
		_foveation_live = false
		return
	if _vrs_mode_override == "runtime":
		# The ORIGINAL path: the runtime owns the density map and Godot's own VRS
		# stays out of it entirely. Not VRS_XR, which asks the viewport to fetch
		# a texture from the interface - a different mechanism, and the one that
		# measured nothing. The eye-buffer ladder documented above was taken with
		# this on ("foveation HIGH"), including 72 Hz at 1.75x.
		root.vrs_mode = Viewport.VRS_DISABLED
		RenderingServer.viewport_set_vrs_texture(root.get_viewport_rid(), RID())
		xr.set("foveation_with_subsampled_images", false)
		xr.set("foveation_dynamic", false)
		xr.set("foveation_level", int(foveation_level))
		_vrs_generator = null
		_foveation_live = true
		print("QualityManager: runtime foveation level %d, eye %dx%d"
			% [int(foveation_level), int(size.x), int(size.y)])
		return
	if _vrs_mode_override == "xr":
		# VRS_XR fetches the density map from the XR INTERFACE, so the interface's
		# own foveation has to be on for there to be one. apply_foveation() forces
		# it to OFF a few lines above (the hang guard), which made an earlier
		# VRS_XR measurement identical to no foveation at all and read as "the
		# runtime path is inert too". It was measuring an unset texture.
		xr.set("foveation_level", int(foveation_level))
		xr.set("foveation_dynamic", false)
		xr.set("foveation_with_subsampled_images", false)
		RenderingServer.viewport_set_vrs_texture(root.get_viewport_rid(), RID())
		root.vrs_mode = Viewport.VRS_XR
		_vrs_generator = null
		_foveation_live = true
		print("QualityManager: VRS_XR runtime density map, xr foveation_level %d, eye %dx%d"
			% [int(foveation_level), int(size.x), int(size.y)])
		return
	var generator: Object = ClassDB.instantiate("XRVRS")
	var tier: Dictionary = FOVEATION_TIERS[foveation_level]
	var radius: float = _vrs_radius_override if _vrs_radius_override >= 0.0 		else tier["min_radius"]
	var strength: float = _vrs_strength_override if _vrs_strength_override >= 0.0 		else tier["strength"]
	generator.set("vrs_min_radius", radius)
	generator.set("vrs_strength", strength)
	# Two layers, one per eye. ZERO maps to the exact middle of each layer.
	var texture: RID = generator.call("make_vrs_texture", size,
		PackedVector2Array([Vector2.ZERO, Vector2.ZERO]))
	if not texture.is_valid():
		push_error("QualityManager: failed to generate centered XR VRS texture")
		_foveation_live = false
		return
	RenderingServer.viewport_set_vrs_texture(root.get_viewport_rid(), texture)
	root.vrs_mode = Viewport.VRS_TEXTURE
	_vrs_generator = generator
	_foveation_live = true
	print(("QualityManager: centered VRS level %d, radius %.1f, strength %.2f, "
		+ "eye texture %dx%d, focus (0,0), msaa %d, post_aa %d") % [
		int(foveation_level), radius, strength, int(size.x), int(size.y),
		root.msaa_3d, root.screen_space_aa])


## OpenXR rebuilds its swapchain asynchronously after an eye-buffer change. Wait
## until that has settled, then regenerate the VRS texture at the new dimensions.
func _schedule_vrs_refresh() -> void:
	_vrs_refresh_serial += 1
	var serial := _vrs_refresh_serial
	_refresh_vrs_after_resize(serial)


func _refresh_vrs_after_resize(serial: int) -> void:
	for frame in 12:
		await get_tree().process_frame
	if serial == _vrs_refresh_serial and foveation_level != Foveation.OFF:
		_generate_centered_vrs()


## Whether a generated texture is owned and its viewport VRS mode is set.
func foveation_live() -> bool:
	return foveation_level != Foveation.OFF and _foveation_live \
		and get_tree().root.vrs_mode == Viewport.VRS_TEXTURE


## Window mode and resolution were the only GRAPHICS rows that reset every launch,
## which read as a bug sitting next to rows that do persist. Headsets have no
## desktop window to restore, so this is desktop-only.
func set_window_state(mode: String, res: String) -> void:
	if not mode.is_empty():
		window_mode = mode
	if not res.is_empty():
		resolution = res
	save_prefs()


func set_msaa(mode: int) -> void:
	msaa_3d = clampi(mode, Viewport.MSAA_DISABLED, Viewport.MSAA_8X)
	apply_msaa()
	_mark_custom()
	save_prefs()


func effective_msaa() -> Viewport.MSAA:
	return (Viewport.MSAA_DISABLED if foveation_level != Foveation.OFF
		else msaa_3d) as Viewport.MSAA


func apply_msaa() -> void:
	get_tree().root.msaa_3d = effective_msaa()


func set_post_aa(mode: int) -> void:
	post_aa = clampi(mode, PostAA.OFF, PostAA.SMAA) as PostAA
	apply_post_aa()
	_mark_custom()
	save_prefs()


## What `post_aa` resolves to in this session. SMAA stands down to FXAA rather
## than to nothing where it cannot run: the carpet, wood and neon are shader
## aliasing, which MSAA does not touch at all.
##
## The stored preference is left alone, deliberately. A desktop install runs both
## flat and over PCVR out of the same user:// prefs file, so writing the fallback
## back would let one headset session strip SMAA from flat play as well.
func effective_post_aa() -> PostAA:
	if post_aa == PostAA.SMAA and not supports_smaa():
		return PostAA.FXAA
	return post_aa


func apply_post_aa() -> void:
	var root := get_tree().root
	match effective_post_aa():
		PostAA.FXAA:
			root.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
		PostAA.SMAA:
			root.screen_space_aa = Viewport.SCREEN_SPACE_AA_SMAA
		_:
			root.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED


## Settings with a strictly correct answer, so they are applied rather than asked
## about. Debanding is a dither pass costing almost nothing, and this room is
## mostly the dark gradients that band; anisotropic filtering sharpens floors at
## grazing angles, which is most of what a room-scale scene is looked at through.
func apply_forced_quality() -> void:
	var root := get_tree().root
	root.use_debanding = true
	root.anisotropic_filtering_level = Viewport.ANISOTROPY_8X


## Drive every tiered setting at once. `persist` is false only for the boot-time
## default, which must not write a prefs file before one has been read.
func apply_preset(level: Preset, persist: bool = true) -> void:
	preset = level
	var tier: Dictionary = PRESETS.get(level, {})
	if tier.is_empty():
		return
	msaa_3d = tier["msaa"]
	post_aa = tier["post_aa"]
	shadow_quality = tier["shadows"]
	# AO is Forward+ only; a preset must not switch on what the backend ignores.
	ao_quality = tier["ao"] if supports_post_effects() else AOQuality.OFF
	if is_inside_tree():
		apply_msaa()
		apply_post_aa()
		apply_shadow_quality()
		apply_ao_quality()
	if persist:
		save_prefs()


## Any individual row moving off the preset makes the preset Custom.
func _mark_custom() -> void:
	preset = Preset.CUSTOM


func shadows_enabled() -> bool:
	return shadow_quality != ShadowQuality.OFF


func set_shadow_quality(level: int) -> void:
	shadow_quality = clampi(level, ShadowQuality.OFF, ShadowQuality.HIGH) as ShadowQuality
	apply_shadow_quality()
	_mark_custom()
	save_prefs()


## Push the current tier at the renderer, then at every Light3D already in the
## tree. Lights added later are caught by _on_node_added.
func apply_shadow_quality() -> void:
	var tier: Dictionary = SHADOW_TIERS[shadow_quality]
	var atlas: int = tier["atlas"]
	var bits16: bool = tier["bits16"]

	var root := get_tree().root
	root.positional_shadow_atlas_size = atlas
	root.positional_shadow_atlas_16_bits = bits16
	RenderingServer.directional_shadow_atlas_set_size(atlas * 2, bits16)
	RenderingServer.directional_soft_shadow_filter_set_quality(tier["filter"])
	RenderingServer.positional_soft_shadow_filter_set_quality(tier["filter"])

	for node in root.find_children("*", "Light3D", true, false):
		configure_light(node as Light3D)


## Apply the current shadow tier to one light, so a spawned TV or handheld
## matches the room it was spawned into.
##
## Lights in the "no_shadow" group opt out and never cast. That is for a light
## sealed inside a fixture: the shade is opaque to the shadow map but translucent
## in reality, so shadows absorb the whole output. The bedroom's ceiling-fan globe
## is the case that found this — sat inside its closed glass dome it lit nothing
## at all, and the room was running on its two table lamps alone. Shades that are
## open top and bottom, like those same lamps' drums, still want shadows: the
## blocked middle is exactly what makes their double cone.
func configure_light(light: Light3D) -> void:
	if light == null:
		return
	if light.is_in_group("no_shadow"):
		light.shadow_enabled = false
		return
	light.shadow_enabled = shadows_enabled()
	if light is DirectionalLight3D and light.shadow_enabled:
		# One orthogonal split covers the whole room from a single map; four
		# splits spend most of their resolution near the camera, which is what
		# the higher tiers are paying for.
		var dir_light := light as DirectionalLight3D
		dir_light.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL \
			if shadow_quality == ShadowQuality.LOW \
			else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS


func set_ao_quality(level: int) -> void:
	ao_quality = clampi(level, AOQuality.OFF, AOQuality.HIGH) as AOQuality
	apply_ao_quality()
	_mark_custom()
	save_prefs()


## Layer the AO setting onto the current room's authored Environment. The room
## keeps its own sky, glow and ambient — only the SSAO block is ours.
func apply_ao_quality() -> void:
	if AO_TIERS.has(ao_quality):
		var tier: Dictionary = AO_TIERS[ao_quality]
		RenderingServer.environment_set_ssao_quality(tier["quality"], tier["half_size"],
			0.5, 2, 50.0, 300.0)
	for node in get_tree().root.find_children("*", "WorldEnvironment", true, false):
		configure_environment(node as WorldEnvironment)


func set_glow_enabled(on: bool) -> void:
	glow_enabled = on
	apply_ao_quality()
	_mark_custom()
	save_prefs()


func configure_environment(world_env: WorldEnvironment) -> void:
	if world_env == null or world_env.environment == null:
		return
	var env := world_env.environment
	# Every room authors glow on and matched, so this is a straight assignment
	# rather than a remembered per-room value. The one Environment that authors
	# it off, Resources/env_quest.tres, is referenced by no scene.
	env.glow_enabled = glow_enabled
	env.ssao_enabled = ao_quality != AOQuality.OFF and supports_post_effects()
	if not env.ssao_enabled:
		return
	# Rooms this small want a short radius — a metre-wide sample skirt reads as
	# dirt smeared up the walls rather than contact shading under the furniture.
	env.ssao_radius = 0.6
	env.ssao_intensity = 2.0


func _on_node_added(node: Node) -> void:
	if node is Light3D:
		configure_light(node as Light3D)
	elif node is WorldEnvironment:
		configure_environment(node as WorldEnvironment)


# ── Persistence ───────────────────────────────────────────────────────────────

func _load_prefs() -> void:
	if not FileAccess.file_exists(PREFS_PATH):
		return
	var file := FileAccess.open(PREFS_PATH, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var data: Dictionary = parsed
	msaa_3d = clampi(_prefs_int(data, "msaa_3d", msaa_3d),
		Viewport.MSAA_DISABLED, Viewport.MSAA_8X)
	post_aa = clampi(_prefs_int(data, "post_aa", post_aa), PostAA.OFF, PostAA.SMAA) as PostAA
	preset = clampi(_prefs_int(data, "preset", preset), Preset.LOW, Preset.CUSTOM) as Preset
	shadow_quality = clampi(_prefs_int(data, "shadow_quality", shadow_quality),
		ShadowQuality.OFF, ShadowQuality.HIGH) as ShadowQuality
	ao_quality = clampi(_prefs_int(data, "ao_quality", ao_quality),
		AOQuality.OFF, AOQuality.HIGH) as AOQuality
	# Forced to 1.0 where scaling is unsupported, so a value saved on desktop and
	# synced to a headset cannot bring the broken path back with it.
	window_mode = str(data.get("window_mode", window_mode))
	resolution = str(data.get("resolution", resolution))
	render_scale = clampf(_prefs_float(data, "render_scale", render_scale),
		RENDER_SCALE_MIN, RENDER_SCALE_MAX) if supports_render_scale() else 1.0
	# Kept whatever the platform, unlike render_scale above: where it is not
	# supported it is inert rather than harmful, and one desktop session writing
	# the file back must not strip the headset's setting out of it.
	eye_buffer_scale = clampf(_prefs_float(data, "eye_buffer_scale", eye_buffer_scale),
		EYE_BUFFER_SCALE_MIN, EYE_BUFFER_SCALE_MAX)
	# Kept as saved rather than validated here: which rates exist is the runtime's
	# to say, and effective_display_rate() snaps to the nearest it offers.
	display_rate = maxf(_prefs_float(data, "display_rate", display_rate), 0.0)
	cpu_level = clampi(_prefs_int(data, "cpu_level", cpu_level),
		PerfLevel.POWER_SAVINGS, PerfLevel.BOOST) as PerfLevel
	gpu_level = clampi(_prefs_int(data, "gpu_level", gpu_level),
		PerfLevel.POWER_SAVINGS, PerfLevel.BOOST) as PerfLevel
	foveation_level = clampi(_prefs_int(data, "foveation_level", foveation_level),
		Foveation.OFF, Foveation.HIGH) as Foveation
	var glow: Variant = data.get("glow_enabled")
	if typeof(glow) == TYPE_BOOL:
		glow_enabled = glow


func save_prefs() -> void:
	var file := FileAccess.open(PREFS_PATH, FileAccess.WRITE)
	if file == null:
		push_warning("QualityManager: cannot write %s" % PREFS_PATH)
		return
	file.store_string(JSON.stringify({
		"msaa_3d": msaa_3d,
		"post_aa": int(post_aa),
		"preset": int(preset),
		"window_mode": window_mode,
		"resolution": resolution,
		"shadow_quality": int(shadow_quality),
		"ao_quality": int(ao_quality),
		"render_scale": render_scale,
		"eye_buffer_scale": eye_buffer_scale,
		"display_rate": display_rate,
		"cpu_level": int(cpu_level),
		"gpu_level": int(gpu_level),
		"foveation_level": int(foveation_level),
		"glow_enabled": glow_enabled,
	}))
	file.close()


## JSON numbers arrive as floats and a null would make int() fail outright.
func _prefs_int(data: Dictionary, key: String, fallback: int) -> int:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return int(value)
	return fallback


func _prefs_float(data: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = data.get(key)
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		return float(value)
	return fallback
