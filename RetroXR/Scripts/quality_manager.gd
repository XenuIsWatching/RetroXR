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
## It works, but NOT down the road it looks like it should, and the wrong road
## is the one the property name points at. Measured on a Quest 3, Godot 4.7 +
## vendors 5.1, at the panel-native eye buffer:
##
##   XR_FB foveation (`foveation_level`)      what happens
##   ---------------------------------------  --------------------------------
##   level 3, rooms' glow ON                   nothing. Godot force-disables
##                                             subsampled images ("rendering
##                                             features are in use") and the
##                                             level is a silent no-op: same GPU
##                                             time, same image at every radius.
##   level 3, glow OFF                         the whole eye buffer paints one
##                                             flat brown — 21351c5, and it was
##                                             never about MSAA. Glow had been
##                                             hiding it by disabling the path.
##   subsampled images off, any level          nothing, at any radius.
##
## So that route is unusable: it is either inert or it is a brown screen. What
## works is Godot's own VRS, which reaches the same density map without the
## subsampled allocation — `vrs_mode = VRS_XR` with the interface's radial
## generator. Same room, same MSAA 4x, eye buffer x1.4, at 120 Hz:
##
##   VRS off   85 fps, 11.1 ms      VRS high   120 fps, 7.9 ms
##
## and peripheral detail falls to 0.80 of the centre's where every unfoveated
## capture measures 1.8-2.0, which is the check that separates the two paths.
## Glow survives it. The stencil outline does not — see stencil_safe().
enum Foveation { OFF, LOW, MEDIUM, HIGH }

## How each Foveation level is expressed to Godot's VRS generator. `min_radius`
## is how far out, in eye-buffer pixels, full rate is kept — the centre a reader
## actually looks through — and `strength` how hard the rate falls off past it.
## OFF is absent on purpose: it selects VRS_DISABLED rather than a weak tier.
const VRS_TIERS := {
	Foveation.LOW:    {"min_radius": 45.0, "strength": 0.5},
	Foveation.MEDIUM: {"min_radius": 30.0, "strength": 1.0},
	Foveation.HIGH:   {"min_radius": 20.0, "strength": 2.0},
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
## Fixed foveation would pay for it outright (12.92 ms / 71 fps at x1.229), but
## foveation_level >= 1 fills the whole eye buffer with one flat colour on this
## stack (Godot 4.7 + vendors 5.1 + 4x MSAA + multiview / Quest 3) — see 21351c5.
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
## Measured in the bedroom, MSAA 4x, foveation HIGH, static head, no core
## running — so this is a ceiling, not a promise about a busy arcade:
##
##   scale  per eye      72 Hz   120 Hz    120 Hz, foveation OFF
##   1.00   1680x1760     72      120       120
##   1.25   2100x2200     72      120       105
##   1.50   2520x2640     72      105        78
##   1.75   2940x3080     72       85        58
##   2.00   3360x3520     72       68        43
##
## Which is what the cap is doing at 2.0 rather than 1.4: at the shipping 72 Hz
## every step holds, and foveation is what pays for the top of the ladder.
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
var foveation_level: Foveation = Foveation.OFF
## Whether the VRS attachment `foveation_level` asks for is actually live.
##
## Tracked rather than read back, because nothing on this stack reports it.
## `Viewport.vrs_mode` is the obvious candidate and is a trap: it goes on
## answering VRS_XR after an eye-buffer resize has taken the attachment away,
## so it describes what was requested, never what is attached. The one event
## that destroys foveation is that resize, so that is what is recorded here.
var _foveation_live: bool = false
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
	# The old full-frame readback needed a 30-frame Quest throttle. The new path
	# transfers only an older, completed 12x8 pass, so both renderers use this cadence.
	screen_light_interval = 6
	# Quest starts where it always was; desktop takes the tier these settings exist
	# to provide. Applied before _load_prefs so a saved preset wins.
	apply_preset(Preset.LOW if not _desktop else Preset.MEDIUM, false)
	_load_prefs()
	_adjust_lights()
	apply_render_scale()
	apply_msaa()
	apply_post_aa()
	apply_forced_quality()
	apply_shadow_quality()
	apply_ao_quality()
	# Lights and each room's WorldEnvironment arrive with every scene load, and
	# lights also with every spawned TV or handheld, so both are configured as
	# they enter the tree rather than swept for.
	get_tree().node_added.connect(_on_node_added)
	_log_state()


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
	# On a live session the resize frees and rebuilds both swapchains, and the VRS
	# attachment does not survive it. Nothing brings it back short of a restart,
	# so record the loss rather than leaving the HUD to report a level that is no
	# longer being applied. At startup `use_xr` is still false and apply_foveation
	# runs after this, so a launch is unaffected.
	if get_tree().root.use_xr:
		_foveation_live = false


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


## Foveation is an FB extension, so the runtime is asked directly rather than the
## platform guessed at.
func supports_foveation() -> bool:
	var xr := XRServer.find_interface("OpenXR")
	if xr == null or not xr.is_initialized() or not xr.has_method("is_foveation_supported"):
		return false
	return bool(xr.call("is_foveation_supported"))


## Whether a stencil-based material may be drawn this session.
##
## False while foveation is on, and that is a crash guard rather than a taste
## call: with VRS active, drawing the outline_mask/outline stencil pair loses the
## Vulkan device inside two seconds on a Quest 3 (a fault in the opaque pass,
## two runs out of two, never once with VRS off). The highlight overlays ask this
## and take the stencil-free outline_hull instead; see that shader for the trade.
func stencil_safe() -> bool:
	return foveation_level == Foveation.OFF


## Saved now, applied at the next launch — NOT to the session you are in.
##
## Measured: VRS is latched when the XR swapchain is created, and re-assigning
## `vrs_mode` on a live session drops the attachment without building a new one.
## So a mid-session change cannot raise or lower foveation, it can only lose it.
## At 120 Hz on a x1.4 eye buffer, one call to this function while foveated took
## the room from ~85 fps to ~59 — a bigger fall than HIGH-to-MEDIUM could ever
## cost, because what actually happened is that foveation stopped.
##
## The same latch is why an Eye Buffer change turns foveation off until restart:
## that row resizes the swapchain, and the attachment does not survive it.
func set_foveation_level(level: int) -> void:
	foveation_level = clampi(level, Foveation.OFF, Foveation.HIGH) as Foveation
	# Only safe before the session exists. xr_init calls apply_foveation() itself
	# at startup, ahead of `use_xr = true`, which is the one moment it takes.
	if not get_tree().root.use_xr:
		apply_foveation()
	save_prefs()


## Safe to call before the swapchain exists, and NOT a way to change foveation on
## a live one. XR_FB_foveation did re-apply its profile on every swapchain
## creation, which is what the rest of this comment used to promise; the VRS path
## below carries no such guarantee, because its attachment is latched when the XR
## swapchain is created. A mid-session call can only lose foveation, never raise
## or restore it — see set_foveation_level.
func apply_foveation() -> void:
	if not supports_foveation():
		return
	var xr := XRServer.find_interface("OpenXR")
	# XR_FB_foveation stays OFF at every level. Measured on this stack, it has
	# exactly two outcomes and neither is foveation: with the rooms' glow on,
	# Godot force-disables subsampled images and the level becomes a silent
	# no-op; with glow off, subsampled images engage and the whole eye buffer
	# paints one flat brown. See the enum comment for the table.
	#
	# `xr/openxr/foveation_eye_tracked` is false in project.godot for the same
	# reason it is pinned here: the runtime logs that it skips
	# XR_META_foveation_eye_tracked outright, for want of an
	# `oculus.software.eye_tracking` manifest feature this app does not want.
	xr.set("foveation_level", 0)
	# Godot's own VRS instead, which reaches the same density map without the
	# subsampled allocation that breaks. The interface generates a radial rate
	# texture from these two, so the level is expressed as a strength and a
	# clean-centre radius rather than an FB profile.
	var tier: Dictionary = VRS_TIERS.get(foveation_level, {})
	if tier.is_empty():
		get_tree().root.vrs_mode = Viewport.VRS_DISABLED
		_foveation_live = false
		return
	xr.set("vrs_min_radius", tier["min_radius"])
	xr.set("vrs_strength", tier["strength"])
	get_tree().root.vrs_mode = Viewport.VRS_XR
	# Every caller reaches this before `use_xr` is true (xr_init) or refuses to
	# run once it is (set_foveation_level), so the attachment really is live here.
	_foveation_live = true


## Whether foveation is actually shading the eye buffer right now, as opposed to
## merely being the saved level. The two part company for a whole session the
## first time the Eye Buffer row is used, which is a ~20% GPU difference with
## nothing on screen to say so.
func foveation_live() -> bool:
	return foveation_level != Foveation.OFF and _foveation_live


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


func apply_msaa() -> void:
	get_tree().root.msaa_3d = msaa_3d as Viewport.MSAA


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
