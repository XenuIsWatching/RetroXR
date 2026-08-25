## RetroSystemModel — base class for system-specific console visual models.
##
## Subclasses load the appropriate GLB for their hardware and override the
## virtual methods below.  All overrides are optional stubs today; they will
## grow as physical animations, power lights, and port visuals are added.
class_name RetroSystemModel
extends Node3D

## Cache for has_baked_shell(). Lazy rather than resolved in _ready(): subclasses
## ask this DURING their own _ready(), and not all of them chain to a base one.
var _baked_shell: Node3D = null
var _baked_shell_checked: bool = false


# ── The machine's own picture ─────────────────────────────────────────────────
#
# A model owns the panels it authored, so a model paints them — nobody else. The
# C++ video handler used to install a material on whichever mesh it was handed,
# and every model here then read the texture back out of that material to wrap it
# in an LCD or stereo shader of its own. The picture is asked for now.


## The core's picture, from the machine this model belongs to. Null when nothing
## is running. A different object after a resolution change, so it is read per
## frame rather than cached.
func host_picture() -> Texture2D:
	var host := get_parent()
	if host == null or not host.has_method("get_video_texture"):
		return null
	return host.get_video_texture()


## True while a video-out cable has taken the picture to a television, which for
## a handheld means its own panel goes dark (Super Game Boy).
func host_picture_on_tv() -> bool:
	var host := get_parent()
	return host != null and host.has_method("picture_on_tv") and host.picture_on_tv()


## The material a panel shows a raw core picture in — emissive so it reads as lit
## from within, point-sampled so a 160-pixel-wide frame is not pre-softened before
## the headset resamples it. Moved here from VideoHandler::Init, which installed
## exactly this on whatever mesh it was given.
var _picture_material: StandardMaterial3D = null


func picture_material(tex: Texture2D) -> StandardMaterial3D:
	if _picture_material == null:
		_picture_material = StandardMaterial3D.new()
		_picture_material.albedo_color = Color(0, 0, 0, 1)
		_picture_material.emission_enabled = true
		_picture_material.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	_picture_material.emission_texture = tex
	return _picture_material


## True when this model wears a detailed shell — a GLB instanced into the scene as
## a child named "Shell".
##
## This replaced an authored `primitive_shell` bool, which said the same thing and
## could disagree with the scene. It did: atari_lynx, neo_geo_pocket, pokemon_mini,
## supervision and wonderswan are plain authored models that never set it, so they
## were treated as detailed shells — their own printed legends were hidden and they
## got no nameplate, despite having no moulding to carry either. Asking the scene
## cannot drift.
func has_baked_shell() -> bool:
	if not _baked_shell_checked:
		_baked_shell_checked = true
		_baked_shell = get_node_or_null("Shell") as Node3D
	return _baked_shell != null


## True when this model supplies the console's body itself, so the cabinet should
## drop its procedural box — and, with it, the procedural disc tray or slot that
## box would otherwise grow.
##
## RetroSystem used to derive this from the model's REGISTRY ID: anything not
## called "placeholder" was assumed to bring geometry. That is the same trap
## has_baked_shell was written to escape, and it sprang the same way. A row can
## exist for reasons that have nothing to do with geometry — the Wii's exists to
## carry the core options its remote cannot work without — and such a model wears
## the procedural box like any other. Under the id rule it lost the box and the
## disc slot both, and spawned as a set of buttons and ports floating in mid-air.
##
## Asking the model cannot drift: a model that draws nothing says so.
func brings_own_body() -> bool:
	return true


## Called when the system is powered on (e.g. light up power LED, play boot animation).
func on_power_on() -> void:
	if _power_slider != null:
		_power_slider.set_value_no_signal(1.0)


## Called when the system is powered off (e.g. extinguish power LED).
func on_power_off() -> void:
	if _power_slider != null:
		_power_slider.set_value_no_signal(0.0)


# --- power SLIDE switches ----------------------------------------------------
#
# Several consoles power on with a slide, not a push: the Genesis rocker travels
# left to ON, the N64's slides up. Driving those from the cabinet's generic
# VRButton made them sink into the case like a button, which is the wrong motion
# and hides the ON/OFF legend the shell prints either side of the cap.
#
# build_power_slider() replaces the button with a VRSlider mounted ON the shell's
# real cap, so the thing you grab is the thing that moves, and the two detents
# map to off/on. Subclasses that override on_power_on/on_power_off must call
# super() so an externally-driven power change (a save restore, a multiplayer
# event, the cartridge being pulled) still moves the switch.
var _power_slider: VRSlider = null

## Every power switch joins this, whether the base class built it (the console
## rockers below) or the model's scene authored it (HandheldModel). It is what
## tells ScenePersistence that a slider's position is a machine's STATE rather
## than a pose: a restored machine is always off, so a saved ON position brought
## a handheld back with its switch up and nothing running behind it.
const POWER_SWITCH_GROUP := "power_switch"


## Mount a two-detent power slider on `cap` and hide the generic push button.
## `axis` is the travel direction toward ON, in this model's local space;
## `throw` is the total travel in metres.
func build_power_slider(power_btn: VRButton, cap: MeshInstance3D,
		axis: Vector3, throw: float) -> VRSlider:
	if cap == null:
		return null
	if power_btn != null:
		power_btn.set_active(false)
	var slider := VRSlider.new()
	slider.name = "PowerSwitch"
	slider.axis_local = axis.normalized()
	slider.travel = throw
	slider.steps = 2
	slider.collision_layer = 1 | (1 << 20)
	var ab: AABB = cap.global_transform * cap.get_aabb()
	slider.engage_radius = clampf(maxf(ab.size.x, maxf(ab.size.y, ab.size.z)) * 0.9, 0.02, 0.05)
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = ab.size + Vector3(0.006, 0.006, 0.006)
	col.shape = box
	slider.add_child(col)
	add_child(slider)                     # _ready() runs here, before adopting
	slider.global_position = ab.get_center()
	slider.set_knob_mesh(cap)
	slider.value_changed.connect(_on_power_slider_changed)
	slider.add_to_group(POWER_SWITCH_GROUP)
	_power_slider = slider
	return slider


func _on_power_slider_changed(v: float) -> void:
	var host := get_parent()
	if host == null or not host.has_method("toggle_power"):
		return
	# The replicated position is visual state; EV_SYS_POWER is the one semantic
	# action. Letting both paths toggle would turn a remote machine twice.
	if NetworkManager.is_event_applying():
		return
	if (v > 0.5) != bool(host.get("is_powered_on")):
		host.toggle_power()


## Play the cartridge/disc tray open animation (if supported).
func play_open() -> void:
	pass


## Play the cartridge/disc tray close animation (if supported).
func play_close() -> void:
	pass


## True when this model's lid is a spring-loaded VRSpringLatchedHinge: the OPEN
## button only ever OPENS it (pressing it again while open does nothing — as on
## the real hardware, where the button is a latch release), and the lid is shut
## by hand, which reports back through RetroSystem.request_tray_state().
func has_spring_latched_lid() -> bool:
	return false


## Which controller socket is this machine's GAME PORT — the one a joystick went
## into, as opposed to the keyboard and mouse sockets beside it — or -1 for
## hardware that has no such distinction.
##
## Only computers need it. A console's pads drive the port they are plugged into;
## a DOS or Amiga core reads its one joystick on port 0 whatever socket the cabinet
## put it in, and RetroSystem._libretro_port_for uses this to pin exactly that one
## socket without touching the others (a C64 really does have two joystick ports).
func game_port_index() -> int:
	return -1


## Returns the number of controller ports active on this hardware.
## The base system scene has 4 snap zones; ports beyond this count are hidden.
func get_controller_port_count() -> int:
	return 2


## How many removable card slots this SHELL has, or -1 for "no opinion, ask the
## system descriptor". Enables that many card snap zones.
##
## -1 rather than 0 is the whole point: a shell that has never thought about
## cards must not out-vote its console's descriptor, while a shell that returns 0
## is saying something stronger — this hardware has none, whatever the descriptor
## claims. Cartridge systems keep saves on the cartridge and mean the second one.
func card_slot_count() -> int:
	return -1


## True for handheld hardware (Game Boy family): the device has a built-in
## screen, is played while held, and its VR-controller input drives port 0.
func is_handheld() -> bool:
	return false


## The device's built-in display mesh (handhelds), or null. When no TV is
## connected the core renders here; plugging the video-out cable into a TV
## moves the picture there and unplugging brings it back.
func get_builtin_screen() -> MeshInstance3D:
	return null


## True if the core outputs a side-by-side stereo frame (left eye | right eye),
## i.e. the Virtual Boy. A connected TV then splits it per-eye like the eyepiece.
func is_stereo_side_by_side() -> bool:
	return false


## Video-out channels this hardware exposes. Single-output hardware (default)
## has one unlabelled channel showing the whole core frame, handled by the
## classic path (the C++ VideoHandler renders straight onto the connected TV).
## Multi-channel hardware (dual-screen handhelds) gets one cable PER channel;
## each connected TV then shows that channel's UV window of the composite
## framebuffer via the screen_window shader. Entry keys:
##   label     String  cable/port tag ("TOP"/"BOTTOM"); "" on single-channel
##   rect      Rect2   UV window into the composite framebuffer
##   touch     bool    taps on a TV showing this channel feed the touch screen
##   eye_shift float   right-eye UV-x shift for stereo SBS sources (0 = mono)
func get_video_channels() -> Array:
	return [{"label": "", "rect": Rect2(0, 0, 1, 1), "touch": false, "eye_shift": 0.0}]


## Handhelds normally hide the cabinet START/STOP button (they carry their own
## power switch). Dual-screen clamshells override this to keep the button —
## their hinge swallows the tiny back-edge knob, so a proper labelled button
## repositioned by configure_buttons() is the discoverable way to power them.
func has_start_stop_button() -> bool:
	return not is_handheld()


## Whether the cabinet's generic OPEN/EJECT button should appear on a system that
## has a disc loader. Override to false when the shell models its own release
## control and mounts a widget on it (the PSP's sprung OPEN latch), so the two
## don't both claim the same job — and the same mesh.
func has_eject_button() -> bool:
	return true


## Hide the generic grey port box and its number on every controller port.
##
## system.tscn ships those as stand-ins for the procedural default shell, which
## has no port geometry of its own. Any console whose GLB moulds real ports wants
## them gone — otherwise a grey cube and a floating "1" sit on top of the moulded
## socket. Call from configure_controller_ports.
static func hide_port_placeholders(port_zones: Array) -> void:
	for z: Node in port_zones:
		var recess := z.get_node_or_null("PortRecess") as MeshInstance3D
		if recess != null:
			recess.hide()
		var lbl := z.get_node_or_null("PortLabel") as Label3D
		if lbl != null:
			lbl.hide()


## Handhelds: create and wire the on-device controls (volume slider, power
## switch) against the owning RetroSystem. Called after the model loads.
func configure_handheld_controls(_host: Node3D) -> void:
	pass


## Interior open angle of a clamshell handheld's lid in degrees (0 = folded
## shut … 180 = flat open), or -1 for hardware without a lid. Read by
## ScenePersistence to save the lid pose; the -1 sentinel is the same
## "capability absent" convention as get_builtin_screen() → null.
func get_lid_angle_deg() -> float:
	return -1.0


## Restore a clamshell lid's interior open angle (0 shut … 180 flat). Hardware
## without a lid ignores it.
func set_lid_angle_deg(_open_deg: float) -> void:
	pass


## Whether the lid this model just posed counts as OPEN — the machine's own
## question, not the mesh's. RetroSystem asks it after restoring a saved angle,
## because the pose alone tells nobody whether the bay should be accepting media.
##
## The default reads the reported angle, which is right for anything that keeps
## no separate open/shut state; a model that has one (the PlayStation lid)
## overrides this so its own half-way rule stays the only rule.
##
## Only asked of a LOADER_TRAY console, so a cartridge flap never reaches here.
func is_lid_open() -> bool:
	return get_lid_angle_deg() > 0.0


## Reposition one memory-card snap zone onto the model's physical card slot.
## `index` is the slot, 0-based, in the same order card_slot_count() counts them.
##
## Called only for slots this model actually has, and called LAST in the slot
## setup, so a shell whose slots sit behind a door can shut them again here.
func configure_memory_card_slot(_slot: Node3D, _index: int) -> void:
	pass


## Core options this hardware REQUIRES (key -> value), merged into the core's
## .opt file before every content start. Used when a model only works with a
## specific core configuration (e.g. Virtual Boy forces vb_3dmode =
## side-by-side so the stereo eyepiece shader gets both eyes).
func get_forced_core_options() -> Dictionary:
	return {}


## RETRO_JOYPAD bits this hardware has no physical control for, as a mask.
## Cleared from the port state before it reaches the core, whatever bound them:
## a core is free to hang a hotkey off a button the machine never had, and the
## player has no way to know they are pressing it.
func get_unsupported_button_mask() -> int:
	return 0


## Emitted by a model whose bay only connects when its tray is pushed down (the
## NES ZIF cradle). `down` true = the cart is home and the machine may read it;
## false = the tray is up and the cart is merely lying in it.
signal cart_tray_changed(down: bool)


## True when this model's bay defers the insert to a push, so RetroSystem knows the
## snap zone's own capture is not the moment the cart went in.
func has_push_tray() -> bool:
	return false


## For a push-tray bay: is the tray currently pushed home?
func is_tray_down() -> bool:
	return false


## Animate a controller plug into a port.  Called after XRTools has snapped and
## frozen the plug at the socket, on the same terms as play_cartridge_insert: the
## model tweens it from wherever the zone stood its ghost, then refreezes.
func play_port_plug_insert(_plug: Node3D, _zone: Node3D) -> void:
	pass


## Animate a cartridge into its slot.  Called after XRTools has snapped and
## frozen the cartridge at the slot position.  Subclasses unfreeze, tween from
## a system-specific start offset to the final position, then refreeze.
func play_cartridge_insert(_cartridge: Node3D, _slot: Node3D) -> void:
	pass


## Reposition the system's existing VRButton nodes to match the model's physical
## button locations and wire them to the GLB button meshes for depress animation.
## The existing signal connections to toggle_power/reset/eject are preserved — only
## the position and mesh reference are updated. eject_btn is the OPEN/eject button
## (disc consoles); models without a disc button ignore it.
func configure_buttons(_power_btn: VRButton, _reset_btn: VRButton, _eject_btn: VRButton) -> void:
	pass


## Reposition the SYNC button, on the consoles that pair wireless pads. Called from
## _setup_wireless_pads, after configure_buttons, and only when this hardware has
## one — which today means the Wii alone.
##
## Separate from configure_buttons because the cabinet builds this button on a
## different test (WiiLink.handles) and later in the sequence; a model that grows its
## own geometry must place it or it stays wherever system.tscn parked it, which on
## anything but the procedural box is mid-air.
func configure_sync_button(_sync_btn: VRButton) -> void:
	pass


## Reposition controller port snap zones to the model's physical port locations.
## port_zones is the system's Array of XRToolsSnapZone nodes (index 0 = port 1).
## Only move the zones the model has markers for; others keep their default positions.
func configure_controller_ports(_port_zones: Array) -> void:
	pass


## Reposition the cable attach point to the model's physical video-out port.
func configure_cable_attach(_attach_point: Node3D) -> void:
	pass


## The A/V SOCKETS this hardware wears, as RcaPort.Channel values in build order,
## or [] for hardware that keeps a captive lead.
##
## A console that lists sockets gets no cable of its own: RetroSystem builds these
## instead and the player runs a spawned lead to the set, which is what the
## hardware actually made you do. The list is what says whether it is stereo —
## [VIDEO, AUDIO_L, AUDIO_R] for most consoles, [VIDEO, AUDIO_L] for mono hardware
## like the NES, whose single audio cord then feeds both of the set's speakers.
##
## Handhelds are deliberately not in this world: their screen is their own, and the
## video-out lead is an extra rather than the only way to see anything.
func av_port_channels() -> Array:
	return []


func uses_av_ports() -> bool:
	return not av_port_channels().is_empty()


## True when every channel above leaves through ONE socket rather than one each.
##
## Orthogonal to av_port_channels on purpose: the Wii outputs the same three signals
## as any other stereo console — which is what decides whether its sound is stereo and
## which speaker each cord feeds — it just packages them in a single AV Multi Out
## shell. Folding that into the channel list would have made "what this machine puts
## out" and "how many holes it has" the same question, and they are not.
##
## The socket built is WiiAvPort, whose channel_for(cord) is what tells the three
## cords apart once they are all in it.
func av_ports_are_multi_way() -> bool:
	return false


## Which channel this machine's RF modulator puts it on, or -1 for "no such switch".
##
## Only hardware old enough to reach a set through an RF switch has one — the NES
## wears a CH3/CH4 slide on its rear panel — and a television on its aerial input
## only shows a console whose channel matches its own tuning. -1 means the machine
## has no opinion, and RetroTV treats that as a match rather than as a mismatch, so
## anything else fed through an RF switch simply appears.
func get_rf_channel() -> int:
	return -1


## Place the sockets built from av_port_channels, in that same order. Called once,
## with the ports already children of the system.
func configure_av_ports(_ports: Array) -> void:
	pass


## Adjust — or switch off — the printed legend round those sockets. Called once,
## straight after configure_av_ports, with the legend already laid out from the port
## positions; change any of its exports and call rebuild(). Default: leave it alone.
##
## Never called on a model wearing a detailed shell, which prints its own.
func configure_av_legend(_legend: AvLegend) -> void:
	pass


## Reposition the attach point for video-out channel `channel` (multi-output
## hardware). Channel 0 defaults to the classic single-port hook above; extra
## channels get a small sideways offset unless the model places them itself.
func configure_cable_attach_for(attach_point: Node3D, channel: int) -> void:
	if channel == 0:
		configure_cable_attach(attach_point)
	else:
		configure_cable_attach(attach_point)
		attach_point.position += Vector3(-0.04 * channel, 0, 0)


## Point an attach point's cord-exit axis along `normal`, the outward normal of the
## face its port sits on, given in this model's own frame.
##
## VerletRope leaves a fixed anchor stiffly along that node's local -Z
## (VerletRope::PlugExitDir), so this is the whole of what decides which way a
## captive lead leaves the machine. Left at identity the cord runs out of the
## model's BACK whatever face the port ended up on — which on a handheld whose port
## moved to the side edge means the lead emerges from the flank and immediately
## doubles back along the body. It also aims PortVisual into the jack, the plug mesh
## being authored connector-on-+Z.
##
## The NES and the Atari 2600 wrote this out by hand — rotate -90 degrees about Y
## for a flank jack, identity for a rear panel — and this is the same rule for any
## face. Written through the GLOBAL transform because an attach point is a child of
## the SYSTEM, not of the model: the two frames coincide today, and a model that
## ever carries a transform of its own would silently aim every cord wrongly.
func aim_cable_exit(attach_point: Node3D, normal: Vector3) -> void:
	var n: Vector3 = (global_transform.basis.orthonormalized() * normal)
	if n.length_squared() < 0.0001:
		return
	n = n.normalized()
	# Any perpendicular will do for the roll — nothing about a cord cares which way
	# up its port is — but it must not lie along the normal itself.
	var up := Vector3.UP if absf(n.dot(Vector3.UP)) < 0.99 else Vector3(0, 0, -1)
	var x := up.cross(n).normalized()
	attach_point.global_transform = Transform3D(
		Basis(x, (-n).cross(x), -n), attach_point.global_position)


## Offset from the video-out attach point where channel `channel`'s cable plug
## first stands, in the ATTACH POINT's own frame — so local -Z is the cord's exit
## axis (see aim_cable_exit) and the default simply trails the lead 100 mm straight
## out of the face its port is on. Local X runs along that face, which is what
## separates one channel's plug from the next.
##
## Read in the attach point's frame rather than in the world, so a machine standing
## at any angle — or simply picked up — lays its cord out of itself rather than
## toward world -Z.
func get_cable_spawn_offset(channel: int) -> Vector3:
	return Vector3(0.05 * channel, 0, -0.1)


## Adjust the root collision shape to fit this model. Custom non-handheld models
## whose geometry doesn't match the default console box (e.g. the tall Virtual
## Boy standing on its bipod) override this so the body rests on the ground
## instead of floating. Default: leave the scene's collision box unchanged.
## (Handhelds resize collision separately via configure_handheld_body.)
func configure_collision(_host: Node3D) -> void:
	pass


## How far past the slot mouth a slot-loaded disc rides, in metres, or 0 to take the
## cabinet's own default. Override on a machine whose case is too shallow for that
## default — a disc standing on edge in a 157 mm-deep Wii would otherwise finish 3 mm
## out through the back panel.
func slot_insert_depth() -> float:
	return 0.0


## Turn this shell's own disc mechanism with the platter, by `radians` about the
## spindle axis.
##
## RetroSystem already spins the DISC, and for a procedural bay that is the whole
## of it -- the box draws no mechanism, so there is nothing else to turn. A shell
## that models one is different: the PlayStation's clamp sits in the disc's
## centre hole and is visible THROUGH it, so a spinning platter around a fixed
## hub is a thing the player can see standing still.
##
## Handed an angle rather than a speed on purpose. The ramp lives in
## RetroSystem._update_disc_spin, which already knows about power, seating and
## spin-down, and a model second-guessing any of that would drift out of step
## with the disc it is supposed to be turning with.
func spin_disc_mechanism(_radians: float) -> void:
	pass


## Optional pivot node the seated disc should physically ride along with,
## instead of staying fixed to the console body (see MediaTray.disc_lid_pivot)
## — a flip-open tray assembly (the PSP's UMD door) where the disc's resting
## slot is part of the door itself, unlike a spindle console (PS1, GameCube...)
## where the disc rests on the BASE and only the lid mesh swings. Null
## (default): disc stays in its normal fixed seat.
func get_disc_lid_pivot() -> Node3D:
	return null


## Build this shell's disc mechanism on the host, and return it if it has one
## that moves. A bespoke shell brings its own geometry — its lid or shelf is part
## of the model — so the base builds nothing and answers null; the placeholder box
## draws one to match itself. `front` asks for a sliding shelf rather than a
## hinged lid, and `on_lid_swung` is told when a hand pushes a spring lid home.
func build_disc_bay(_host: Node3D, _slot: Node3D, _systemid: String, _front: bool,
		_on_lid_swung: Callable) -> ProceduralDiscBay:
	return null


## Draw the mouth a slot-loaded disc goes in through. Same split as
## build_disc_bay: a bespoke shell already has one.
## Put this machine's serial socket on it, if it has one.
##
## A hook rather than a fixed node on the cabinet because it is the SHELL that
## knows where the socket is: a model with a baked body has a moulded recess to
## sit it in, and the primitive box has only a back panel to lay it against. The
## cabinet cannot place something it cannot measure.
##
## Nothing here by default. A console with no serial port is the ordinary case,
## and a model that draws its own can override this without the cabinet caring.
func build_serial_port(_host: Node3D, _systemid: String) -> void:
	pass


func build_disc_slit(_host: Node3D, _systemid: String) -> void:
	pass


## True when this model draws the machine's name itself, so the cabinet should not
## also lay its own nameplate on the front face.
##
## Separate from has_baked_shell(): a primitive can have every reason to print its
## own. The cabinet's plate is the SYSTEM name sized to 85% of the body width, which
## on a machine whose front reads "Wii" in a small grey mark puts "NINTENDO WII"
## across the whole foot of it.
func prints_own_name() -> bool:
	return false


## Group for a PRINTED LEGEND — the "POWER" / "3D" / "TOP" / "BOTTOM" text a
## device has silk-screened on its case, plus the system nameplate.
##
## A detailed shell already carries that printing in its own texture, so drawing
## ours over the top double-prints it; on the stand-ins, which have no texture at
## all, the legends are the only thing saying what a control does. Tag a label
## with this group and it appears on stand-ins only.
const PRINTED_LABEL_GROUP := "printed_label"


## Hide the printed legends on a detailed shell. No-op on a stand-in, which is
## the one place they earn their keep.
func hide_printed_labels() -> void:
	if not has_baked_shell():
		return
	for n in get_tree().get_nodes_in_group(PRINTED_LABEL_GROUP):
		if n is Node3D and is_ancestor_of(n):
			(n as Node3D).visible = false


## An editor-authored seat marker ("CartSeat" / "DiscSeat" / "UMDSeat"), whose
## global transform poses the seated media.
func _seat_marker(seat_name: String) -> Node3D:
	return find_child(seat_name, true, false) as Node3D


## Lookups that resolve against a DETAILED shell — socket markers, control meshes
## — have nothing to say on a plain model and must be skipped rather than left to
## come back null.
func _has_no_baked_shell() -> bool:
	return not has_baked_shell()


## Hide every editor-only seat preview box in the tree. There can be more than
## one — the device scene's and the stand-in's — and leaving either visible puts
## a translucent block through the shell at runtime.
func _hide_seat_previews() -> void:
	for n in find_children("SeatPreview", "Node3D", true, false):
		(n as Node3D).visible = false


## Reposition the cartridge snap zone to the model's physical slot location.
## Also returns the insertion offset — the vector the cartridge travels from its
## pre-animation position to the snapped position (in world space).
## Default: 6 cm straight up (+Y), i.e. cartridge drops straight down into slot.
func configure_cartridge_slot(_slot: Node3D) -> void:
	pass


## The world-space direction a cartridge travels when being inserted.
## Returned as a unit vector; the animation moves FROM final_pos - dir*depth TO final_pos.
func get_cartridge_insert_direction() -> Vector3:
	return Vector3.UP


## Play the reset animation (e.g. depress the reset button, reboot LED flash).
## Called by RetroSystem.reset() independently of the power on/off hooks.
func play_reset() -> void:
	pass


## Animate a cartridge ejecting from its slot before it is dropped.
## NOTE: by the time has_dropped fires the cartridge is already released, so
## this is reserved for future use (e.g. intercepting the drop earlier).
func play_cartridge_eject(_cartridge: Node3D, _slot: Node3D) -> void:
	pass


# ── Power LED ─────────────────────────────────────────────────────────────────
#
# A lit lens plus a companion OmniLight3D, shared by the shells detailed enough
# to have a real one. The NES and the PlayStation had a line-for-line copy each,
# differing only in the emission colour and how hard the lens is driven.
#
# The light is a separate node rather than emission alone because an emissive
# surface lights nothing around it: without the omni the lens glows and the
# plastic beside it stays dark.

## Shared by every shell with a lit lens. DECAY and RANGE are the falloff of a
## few-millimetre source, and STANDOFF is how far in front of the lens the omni
## sits. LED_ENERGY and the colour are NOT here: each console's lens is a
## different brightness and hue, measured per shell.
const LED_DECAY := 2.0
const LED_RANGE := 0.45
const LED_STANDOFF := 0.006


## Whether a lamp may hang a real light off its lens. Forward+ only.
##
## This light is a deliberately extreme thing: an energy of ~1e-5 sitting 3 to 6
## mm off the surface, whose brightness comes out of the inverse square at that
## range (peak * STANDOFF^2). Forward+ renders it as intended. The MOBILE backend
## — Android, so the Quest — does not, and not subtly: at the shipped values with
## specular 0 it paints everything the light reaches BLACK (the DualShock's lamp
## became a black bar, the PlayStation's green lens grew a dark core); nudging
## specular off zero clears the black but leaves a flat coloured disc that reads
## as a sticker rather than a light; and steepening the falloff detonates
## completely, the whole pad black with saturated patches. Three regimes, three
## different wrong answers, so this is not a value that wants tuning.
##
## The lens's own emissive material is untouched by any of it and renders
## identically on both backends. Mobile therefore keeps the glowing lens and
## gives up the wash it throws on the shell around it — which is exactly what
## these shells looked like before the lamps were added, and is a great deal
## better than a black hole where the lamp should be.
static func lamp_glow_supported() -> bool:
	return RenderingServer.get_current_rendering_method() == "forward_plus"

var _power_light_mesh: MeshInstance3D = null
var _power_light_mats: Array[StandardMaterial3D] = []
var _power_light_glow: OmniLight3D = null
var _power_light_energy := 1.0


## Make the lens emissive and hang a glow in front of it. Call once, after
## _power_light_mesh is resolved; set_power_light drives it afterwards.
##
## `emission` is the colour the lens itself radiates and `glow` what the omni
## casts — related but not equal, since the lens reads brighter than the light it
## throws. `lit_energy` is how hard the lens is driven when on: the NES's red
## takes 3.0 where the PlayStation's green takes 1.0 for the same apparent
## brightness, which is a luminance difference and not a tuning accident.
func prep_power_light(emission: Color, glow: Color, glow_energy: float,
		lit_energy: float) -> void:
	if _power_light_mesh == null:
		return
	_power_light_energy = lit_energy
	_power_light_mats.clear()
	for s in range(_power_light_mesh.mesh.get_surface_count()):
		var src := _power_light_mesh.get_active_material(s) as BaseMaterial3D
		var m := StandardMaterial3D.new()
		if src != null:
			m.albedo_color = src.albedo_color
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = 0.0
		_power_light_mesh.set_surface_override_material(s, m)
		_power_light_mats.append(m)
	_build_power_glow(glow, glow_energy)


func _build_power_glow(glow: Color, glow_energy: float) -> void:
	if _power_light_glow != null or _power_light_mesh == null:
		return
	if not lamp_glow_supported():
		return
	_power_light_glow = OmniLight3D.new()
	_power_light_glow.name = "PowerLightGlow"
	_power_light_glow.add_to_group("no_shadow")
	_power_light_glow.light_color = glow
	_power_light_glow.light_energy = glow_energy
	_power_light_glow.omni_range = LED_RANGE
	_power_light_glow.omni_attenuation = LED_DECAY
	# A point source millimetres from glossy ABS throws a specular highlight the
	# real lens cannot. Its reflection comes from the emissive mesh instead.
	_power_light_glow.light_specular = 0.0
	_power_light_glow.shadow_enabled = false
	_power_light_glow.distance_fade_enabled = true
	_power_light_glow.distance_fade_begin = 3.0
	_power_light_glow.distance_fade_length = 1.5
	_power_light_glow.visible = false
	add_child(_power_light_glow)
	# Measured off the lens rather than quoted from the asset: _ready recentres
	# the shell on its own footprint, so the GLB's coordinates are not this
	# node's.
	var to_model := global_transform.affine_inverse() * _power_light_mesh.global_transform
	var lens: Vector3 = to_model * _power_light_mesh.get_aabb().get_center()
	_power_light_glow.position = lens + Vector3(0.0, 0.0, LED_STANDOFF)


func set_power_light(on: bool) -> void:
	for m in _power_light_mats:
		m.emission_energy_multiplier = _power_light_energy if on else 0.0
	if _power_light_glow != null:
		# Hidden rather than dimmed to zero: an energy-0 light is still a light
		# the renderer culls and binds per object.
		_power_light_glow.visible = on
