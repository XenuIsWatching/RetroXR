## A red cord in the yellow socket: does a picture still come out?
##
## Phono plugs are physically identical, so the colours are a convention for
## people, not a signal. What decides is which SOCKET each end sits in: a cord
## from the machine's AUDIO out into the set's VIDEO in carries audio into a
## video input, and a real set shows no picture for it.
##
## Reported by hand, so this is a reproduction rather than a gate — it lives in
## Tools/ for the same reason three_plug_probe does, and prints FAIL by design
## until the defect it names is fixed.
##
##   godot --headless --path RetroXR res://Tools/av/rca_channel_probe.tscn
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const VCR_SCENE := preload("res://Scenes/Objects/appliances/vcr_player.tscn")
const CABLE_SCENE := preload("res://Scenes/Objects/cables/composite_cable.tscn")
const RF_SWITCH := preload("res://Scenes/Objects/appliances/rf_switch.tscn")

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace(String.chr(92), "/")

var core := "fceumm"
var rom := _home + "/retroxr/roms/nes/Super Mario Bros. (World).nes"
var _fail := false


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--rca-rom="):
			rom = arg.trim_prefix("--rca-rom=")
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[rca] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _check(ok: bool, msg: String) -> void:
	if not ok:
		_fail = true
	print("[rca] %s  %s" % ["PASS" if ok else "FAIL", msg])


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame


## The texture the glass is sampling. Read through the set's own record when the
## CRT material is up: phosphor persistence swaps source_tex for its ping-pong
## buffer, so the uniform would report that instead of the picture behind it.
func _shown(tv: RetroTV) -> Texture2D:
	var mat: Material = tv.get_screen_mesh().get_surface_override_material(0)
	if mat == tv._crt_material:
		return tv._crt_source_tex
	if mat is ShaderMaterial:
		return (mat as ShaderMaterial).get_shader_parameter("source_tex") as Texture2D
	return null


## Every OUT socket a device wears, minus the aerial one.
func _outs(dev: Node3D) -> Array:
	var out: Array = []
	for node in dev.find_children("*", "Node3D", true, false):
		var port := node as RcaPort
		if port != null and port.direction == RcaPort.Direction.OUT and port.name != "RfOut":
			out.append(port)
	return out


func _audio_out(dev: Node3D) -> RcaPort:
	for p: Variant in _outs(dev):
		var port := p as RcaPort
		if port.channel != RcaPort.Channel.VIDEO:
			return port
	return null


func _run() -> void:
	# ── A: a console, with a real core running ────────────────────────────────
	var tv := TV_SCENE.instantiate() as RetroTV
	tv.freeze = true
	add_child(tv)
	tv.add_to_group("spawned")
	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.systemid = "nes"
	sys.core_name = core
	sys.freeze = true
	sys.position = Vector3(2.0, 1, 0)
	add_child(sys)
	sys.add_to_group("spawned")
	await _wait(60)

	if not FileAccess.file_exists(rom):
		print("[rca] SKIP: rom not found (%s)" % rom)
		get_tree().quit(0)
		return
	sys.rom_path = rom
	sys.power_on()
	await _wait(150)
	print("[rca] console powered=%s texture=%s"
		% [sys.is_powered_on, sys.get_video_texture() != null])

	# ONE cord: the machine's AUDIO out into the set's VIDEO in. Nothing is
	# plugged into the set's audio sockets, and no video cord exists at all.
	var video_in := tv.get_node("CompositePort") as RcaPort
	var a_out := _audio_out(sys)
	print("[rca] wiring %s (channel %d) -> %s (channel %d)"
		% [a_out.name, int(a_out.channel), video_in.name, int(video_in.channel)])
	var cable := CABLE_SCENE.instantiate() as Node3D
	cable.position = Vector3(1.0, 1, 0.6)
	add_child(cable)
	await _wait(25)
	a_out.pick_up_object(cable.get_node("PlugA1") as RcaPlug)
	video_in.pick_up_object(cable.get_node("PlugB1") as RcaPlug)
	await _wait(45)

	tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(45)

	var filed := -1
	for i in (tv._panel._connected_systems as Array).size():
		if tv._panel._connected_systems[i] == sys:
			filed = i
	print("[rca] the set filed the console on input %d" % filed)
	print("[rca] the console says picture_on_tv=%s" % sys.picture_on_tv())
	var glass := _shown(tv)
	print("[rca] the glass is showing: %s (blue=%s, the core's own=%s)"
		% [glass, glass == tv._blue_texture, glass == sys.get_video_texture()])
	_check(glass != sys.get_video_texture(),
		"an AUDIO cord in the VIDEO socket does not put the core's picture on the set")
	_check(glass == tv._blue_texture,
		"and the set shows its no-signal screen instead (console)")

	sys.power_off()
	await get_tree().create_timer(1.0).timeout
	for n in [cable, sys, tv]:
		n.queue_free()
	await _wait(10)

	# ── B: the same miswiring on a deck ───────────────────────────────────────
	#
	# A WEAK control, and worth saying so: VCRPlayer.get_video_texture() refuses
	# on three counts (no libVLC, not playing, no video cord) and with no tape in
	# the machine the first two already answer. So this shows the deck does not
	# misbehave, not that _feed_video is what stops it. The case that does pin
	# that is av_suite's routing/picture into an audio socket is not a picture.
	var tv2 := TV_SCENE.instantiate() as RetroTV
	tv2.freeze = true
	tv2.position = Vector3(6.0, 1, 0)
	add_child(tv2)
	tv2.add_to_group("spawned")
	var deck := VCR_SCENE.instantiate() as VCRPlayer
	deck.freeze = true
	deck.position = Vector3(8.0, 1, 0)
	add_child(deck)
	deck.add_to_group("spawned")
	await _wait(60)

	var in2 := tv2.get_node("CompositePort") as RcaPort
	var out2 := deck.get_node("AudioROut") as RcaPort
	var cable2 := CABLE_SCENE.instantiate() as Node3D
	cable2.position = Vector3(7.0, 1, 0.6)
	add_child(cable2)
	await _wait(25)
	out2.pick_up_object(cable2.get_node("PlugA2") as RcaPlug)
	in2.pick_up_object(cable2.get_node("PlugB2") as RcaPlug)
	await _wait(45)
	tv2.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(30)
	print("[rca] the deck says _feed_video=%s" % deck._feed_video)
	var glass2 := _shown(tv2)
	print("[rca] the deck's set is showing: %s (blue=%s)"
		% [glass2, glass2 == tv2._blue_texture])
	_check(glass2 == tv2._blue_texture,
		"the same miswiring leaves the set blue (deck, the control)")

	for n in [cable2, deck, tv2]:
		n.queue_free()
	await _wait(10)

	# ── C: correct wiring still shows a picture ───────────────────────────────
	#
	# The point of the guard is to refuse a picture nobody sent. It has to be
	# checked in BOTH directions or "shows nothing, ever" would pass phase A —
	# and the two routes a console reaches a set by are different code: a
	# composite lead resolves through _apply_av_feed, an aerial lead through the
	# RF switch, and only the first one calls on_tv_connected directly.
	var tv3 := TV_SCENE.instantiate() as RetroTV
	tv3.freeze = true
	tv3.position = Vector3(12.0, 1, 0)
	add_child(tv3)
	tv3.add_to_group("spawned")
	var sys3 := SYSTEM_SCENE.instantiate() as RetroSystem
	sys3.systemid = "nes"
	sys3.model_id = "nes"
	sys3.core_name = core
	sys3.freeze = true
	sys3.position = Vector3(15.0, 1, 0)
	add_child(sys3)
	sys3.add_to_group("spawned")
	await _wait(180)
	sys3.rom_path = rom
	sys3.power_on()
	await _wait(150)

	var vid_out: RcaPort = null
	for pv: Variant in _outs(sys3):
		if (pv as RcaPort).channel == RcaPort.Channel.VIDEO:
			vid_out = pv as RcaPort
	var in3 := tv3.get_node("CompositePort") as RcaPort
	var cable3 := CABLE_SCENE.instantiate() as Node3D
	cable3.position = Vector3(13.0, 1, 0.6)
	add_child(cable3)
	await _wait(25)
	vid_out.pick_up_object(cable3.get_node("PlugA0") as RcaPlug)
	in3.pick_up_object(cable3.get_node("PlugB0") as RcaPlug)
	await _wait(45)
	tv3.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(30)
	print("[rca] composite: sends_video_to=%s" % sys3.sends_video_to(tv3))
	_check(_shown(tv3) == sys3.get_video_texture(),
		"a VIDEO cord in the VIDEO socket still shows the picture")

	# ── D: the same, over an aerial lead ──────────────────────────────────────
	var tv4 := TV_SCENE.instantiate() as RetroTV
	tv4.freeze = true
	tv4.position = Vector3(19.0, 1, 0)
	add_child(tv4)
	tv4.add_to_group("spawned")
	await _wait(30)
	var rf_out := sys3.find_child("RfOut", true, false) as RcaPort
	if rf_out == null:
		print("[rca] SKIP phase D: this build's NES has no RF panel")
	else:
		var lead := RF_SWITCH.instantiate() as Node3D
		lead.position = Vector3(17.0, 1, -1.0)
		add_child(lead)
		await _wait(20)
		var a := sys3.find_child("RfOut", true, false) as XRToolsSnapZone
		var b := tv4.find_child("RfPort", true, false) as XRToolsSnapZone
		if a != null and b != null:
			a.pick_up_object(lead.get_node("PlugA0"))
			b.pick_up_object(lead.get_node("PlugB0"))
		await _wait(45)
		tv4.set_source(RetroTV.Source.RF)
		var rfch: int = sys3.get_rf_channel()
		if rfch >= 0:
			tv4.rf_channel = rfch
		await _wait(30)
		print("[rca] aerial: sends_video_to=%s can_paint=%s"
			% [sys3.sends_video_to(tv4), tv4.can_paint(sys3)])
		_check(_shown(tv4) == sys3.get_video_texture(),
			"and an aerial lead on the right channel still shows it")

	sys3.power_off()
	await get_tree().create_timer(1.0).timeout

	print("[rca] RESULT=%s" % ("FAIL" if _fail else "PASS"))
	get_tree().quit(1 if _fail else 0)
