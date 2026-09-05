## AV suite — what reaches a television's inputs, and what it shows.
##
## Covers the two halves that used to be worked out in several places at once:
## ROUTING (which cords reach which socket, across every lead a device is on) and
## DISPLAY (which input the set is showing, and what it paints when there is
## nothing). Every bug this suite pins down shipped at least once.
##
##   godot --headless --path RetroXR res://Tests/av_tests.tscn
##   godot --headless --path RetroXR res://Tests/av_tests.tscn -- --only=display
##
## Exits non-zero if anything fails. Headless on purpose: these are decisions, not
## appearances — what a picture LOOKS like needs a windowed run and a photograph.
extends Node3D

const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")
const VCR_SCENE := preload("res://Scenes/Objects/appliances/vcr_player.tscn")
const CABLE_SCENE := preload("res://Scenes/Objects/cables/composite_cable.tscn")
const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const VGA_CABLE := preload("res://Scenes/Objects/cables/vga_cable.tscn")
const TRS_CABLE := preload("res://Scenes/Objects/cables/trs_cable.tscn")
const SPEAKERS := preload("res://Scenes/Objects/appliances/speaker_pair.tscn")
const RF_SWITCH := preload("res://Scenes/Objects/appliances/rf_switch.tscn")
const WINDOW_SHADER := preload("res://Shaders/screen_window.gdshader")
const TV_OPTIONS_UI := preload("res://Scenes/UI/tv_options_2d.tscn")

## A machine or deck reduced to the contract a television actually reads.
## Real hardware is used wherever routing is the thing under test; this stands in
## when the test is about what the SET does with what it is handed.
class StubSource extends Node3D:
	var texture: Texture2D = null
	var stage: Dictionary = {}
	## Per-TV stages, keyed by the asking set — a dual-screen machine answers each
	## of its two televisions differently.
	var stage_by_tv: Dictionary = {}
	var rf_channel: int = -1
	var volumes: Array[float] = []
	## Whether this source is putting a picture on the asking set. A real source
	## answers per set; the default is yes, so every other case reads as before.
	var video_to_tv := true

	func sends_video_to(_tv: Node) -> bool:
		return video_to_tv

	func get_video_texture() -> Texture2D:
		return texture

	func get_video_stage(tv: Node) -> Dictionary:
		return stage_by_tv.get(tv, stage)

	func set_audio_volume(v: float) -> void:
		volumes.append(v)

	func get_rf_channel() -> int:
		return rf_channel


## The set's own TV input, reduced to the one thing the glass reads off it.
## A TVTuner subclass rather than a StubSource because RetroTV holds its tuner by
## type — and because none of libVLC, a channel list or a real HDHomeRun is part
## of the question, which is what route a broadcast takes onto the glass.
class StubTuner extends TVTuner:
	var texture: Texture2D = null

	func _ready() -> void:
		pass

	func set_active(on: bool) -> void:
		_active = on

	func picture_texture() -> Texture2D:
		return texture

	func status_banner() -> String:
		return ""


var _case := ""
## Set by a case that cannot run here (no core, no shell in this build). Anything
## else that ends without asserting is an abort, not a pass.
var _skipped := ""
var _failed_cases := {}
var _checks := 0
var _spawned: Array[Node] = []


func _ready() -> void:
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[av] TIMEOUT during '%s'" % _case)
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.split("=")[1]

	var cases: Array = [
		["routing/one lead carries picture and both channels", _r_one_lead],
		["routing/two leads, neither clobbers the other", _r_two_leads],
		["routing/crossed audio pair swaps the speakers", _r_crossed],
		["routing/picture into an audio socket is not a picture", _r_video_into_audio],
		["routing/pulling the picture cord leaves the sound", _r_pull_picture],
		["routing/picture and sound on different inputs: picture wins", _r_video_wins],
		["routing/a machine on VGA is filed on the VGA input", _r_vga],
		["display/a monitor lands on its own socket, not the tuner", _d_monitor_default],
		["display/removed TV models migrate to retained primitives", _d_legacy_tv_models],
		["wiring/VGA alone reaches the monitor", _w_vga_only],
		["wiring/composite alone reaches the television", _w_composite_only],
		["wiring/VGA and composite together reach BOTH", _w_both_video],
		["wiring/sound to the speakers does not take the picture away", _w_trs_speakers],
		["wiring/sound to a second set leaves the first showing", _w_audio_elsewhere],
		["wiring/pulling one video lead leaves the other", _w_pull_one_video],
		["wiring/pulling the sound lead leaves the picture", _w_pull_sound],
		["wiring/the sound lead first, then the picture", _w_sound_first],
		["wiring/both displays may actually paint the machine", _w_both_can_paint],
		["wiring/the sound goes where its lead goes", _w_sound_routing],
		["wiring/two machines on one set keep their own inputs", _w_two_machines],
		["wiring/unplugging a machine takes it off both displays", _w_unplug_all],
		["wiring/an NES feeds composite and RF at the same time", _w_nes_rf],
		["display/the selected input is shown", _d_selected],
		["display/another input is blue, not the last picture", _d_away],
		["display/coming back shows it again", _d_back],
		["display/a source that stops is blue, not frozen", _d_stopped],
		["display/a set switched off is dark", _d_off],
		["display/a set that is on lights the room, and again after a power cycle", _d_ambilight],
		["display/an empty input is blue", _d_empty],
		["display/a host on the input that sends no picture is blue", _d_no_video_cord],
		["display/the aerial input on the wrong channel is snow", _d_rf_untuned],
		["display/the aerial input on the right channel shows the machine", _d_rf_tuned],
		["display/the afterglow does not carry over from the last machine", _d_no_ghost],
		["display/a source's own stage shader is used", _d_stage],
		["display/glass controls follow sliders, source, power and save", _d_glass_wear],
		["display/two sets get their own window of one picture", _d_stage_per_tv],
		["display/the picture shape follows the button on the TV input", _d_tv_aspect],
		["guard/a host that is not shown is refused", _g_refused],
		["guard/the shown host may paint", _g_allowed],
		["guard/only the owner may take the picture down", _g_release],
		["audio/only the selected input is heard", _a_selected_only],
		["audio/a machine with nowhere to show is not heard", _a_no_display],
	]

	print("[av] running %d cases%s" % [cases.size(), "" if only.is_empty() else " matching '%s'" % only])
	for c: Array in cases:
		var name: String = c[0]
		if not only.is_empty() and not name.contains(only):
			continue
		_case = name
		_skipped = ""
		var before := _checks
		await (c[1] as Callable).call()
		await _teardown()
		# A case that asserted NOTHING did not pass — it aborted. GDScript kills the
		# coroutine on a bad property or a null call and the runner never hears, so
		# an empty case used to be reported green. That is how a test survives the
		# very change it was written to catch.
		if _checks == before and _skipped.is_empty():
			_failed_cases[name] = true
			print("[av] FAIL  %s
[av]         made no assertions — it aborted part way"
				% name)
		elif not _skipped.is_empty():
			print("[av] SKIP  %s (%s)" % [name, _skipped])
		elif not _failed_cases.has(name):
			print("[av] PASS  %s" % name)

	print("[av] %d checks, %d case(s) failed" % [_checks, _failed_cases.size()])
	print("[av] RESULT=%s" % ("FAIL" if _failed_cases.size() > 0 else "PASS"))
	get_tree().quit(1 if _failed_cases.size() > 0 else 0)


# ── Checks ────────────────────────────────────────────────────────────────────

## Say why a case cannot run, rather than returning quietly.
func _skip(why: String) -> void:
	_skipped = why


func _check(cond: bool, what: String) -> void:
	_checks += 1
	if cond:
		return
	_failed_cases[_case] = true
	print("[av] FAIL  %s\n[av]         %s" % [_case, what])


func _check_eq(got: Variant, want: Variant, what: String) -> void:
	_check(got == want, "%s: got %s, want %s" % [what, got, want])


# ── Building a room ───────────────────────────────────────────────────────────

func _tv() -> RetroTV:
	var tv := TV_SCENE.instantiate() as RetroTV
	tv.freeze = true
	tv.position = Vector3(_spawned.size() * 3.0, 1, 0)
	add_child(tv)
	tv.add_to_group("spawned")
	_spawned.append(tv)
	return tv


func _deck() -> VCRPlayer:
	var deck := VCR_SCENE.instantiate() as VCRPlayer
	deck.freeze = true
	deck.position = Vector3(_spawned.size() * 3.0, 1, 1.2)
	add_child(deck)
	deck.add_to_group("spawned")
	_spawned.append(deck)
	return deck


## The three sockets of one composite input, in cord order (VIDEO, L, R).
func _input_ports(tv: RetroTV, input: int) -> Array[RcaPort]:
	var suffix := "" if input == 0 else str(input + 1)
	var out: Array[RcaPort] = []
	for base in ["CompositePort", "AudioLIn", "AudioRIn"]:
		out.append(tv.get_node_or_null(base + suffix) as RcaPort)
	return out


func _out_ports(deck: Node3D) -> Array[RcaPort]:
	var out: Array[RcaPort] = []
	for n in ["VideoOut", "AudioLOut", "AudioROut"]:
		out.append(deck.get_node_or_null(n) as RcaPort)
	return out


## Spawn a lead and seat the cords named in `pairs` — [[cord, from, to], …].
func _lead(pairs: Array) -> Node3D:
	var cable := CABLE_SCENE.instantiate() as Node3D
	cable.position = Vector3(_spawned.size() * 3.0, 1, 0.6)
	add_child(cable)
	_spawned.append(cable)
	await _wait(20)
	for p: Array in pairs:
		var cord: int = p[0]
		(p[1] as RcaPort).pick_up_object(cable.get_node("PlugA%d" % cord) as RcaPlug)
		(p[2] as RcaPort).pick_up_object(cable.get_node("PlugB%d" % cord) as RcaPlug)
		await _wait(6)
	await _wait(25)
	return cable


## Put a stub on one of a set's inputs without cabling it up: these cases are
## about what the SET does, and _connected_systems is what it reads.
func _seat_stub(tv: RetroTV, input: int, source: StubSource) -> void:
	add_child(source)
	_spawned.append(source)
	tv._panel._connected_systems[input] = source
	tv.set_source(input)
	await _wait(4)


## Take a plug out and leave it out.
##
## Dropping one is not enough, and shutting its own socket is not either: it is
## released standing in front of a whole back panel of sockets whose grab zones
## reach 60 mm, and whichever one is nearest takes it — the log reads "pulled
## VIDEO on TV" followed immediately by "seated VIDEO on TV". So every socket in
## the room is shut for the move, and the plug is frozen where it is put, because
## a live one falls back down past the panel and is caught on the way.
func _unplug(plug: RcaPlug) -> void:
	var shut: Array[RcaPort] = []
	for node in get_tree().get_nodes_in_group(RcaPort.GROUP):
		var port := node as RcaPort
		if port != null and port.enabled:
			port.enabled = false
			shut.append(port)
	var seated := plug.seated_port()
	if seated != null:
		seated.drop_object()
	await _wait(4)
	plug.freeze = true
	plug.global_position += Vector3(0.0, 3.0, 0.0)
	PhysicsServer3D.body_set_state(plug.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, plug.global_transform)
	await _wait(15)
	for port in shut:
		if is_instance_valid(port):
			port.enabled = true
	await _wait(15)


func _which_input(tv: RetroTV, dev: Node3D) -> int:
	for i in (tv._panel._connected_systems as Array).size():
		if tv._panel._connected_systems[i] == dev:
			return i
	return -1


func _glass(tv: RetroTV) -> Material:
	return tv.get_screen_mesh().get_surface_override_material(0)


## The texture the glass is sampling, however it is being shown.
##
## Through the set's own record when the CRT material is up: phosphor persistence
## legitimately swaps source_tex for its ping-pong buffer, so reading the uniform
## back would report a ViewportTexture rather than the picture behind it.
func _shown(tv: RetroTV) -> Texture2D:
	var mat := _glass(tv)
	if mat == tv._display._crt_material:
		return tv._display._crt_source_tex
	if mat is ShaderMaterial:
		return (mat as ShaderMaterial).get_shader_parameter("source_tex") as Texture2D
	if mat is StandardMaterial3D:
		var std := mat as StandardMaterial3D
		return std.emission_texture if std.emission_texture != null else std.albedo_texture
	return null


func _a_texture(colour: Color = Color.WHITE) -> Texture2D:
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	img.fill(colour)
	return ImageTexture.create_from_image(img)


func _teardown() -> void:
	for n in _spawned:
		if is_instance_valid(n):
			n.queue_free()
	_spawned.clear()
	await _wait(3)


func _wait(frames: int) -> void:
	for i in range(frames):
		await get_tree().process_frame


# ── Routing ───────────────────────────────────────────────────────────────────

func _r_one_lead() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_4)
	var outs := _out_ports(deck)
	await _lead([[0, outs[0], ins[0]], [1, outs[1], ins[1]], [2, outs[2], ins[2]]])
	_check(deck.connected_tv == tv, "the deck should know which set it feeds")
	_check(deck._feed_video, "the picture should have a path")
	_check_eq(deck._feed_left, 0, "left channel lands on the left speaker")
	_check_eq(deck._feed_right, 1, "right channel lands on the right speaker")
	_check_eq(_which_input(tv, deck), RetroTV.Source.COMPOSITE_4, "the set files the deck")


func _r_two_leads() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_4)
	var outs := _out_ports(deck)
	# Picture on one lead, the pair on another. Each cable reports only its own
	# cords, so the deck has to read every lead it is on rather than the last
	# report it was handed.
	var picture := await _lead([[0, outs[0], ins[0]]])
	var sound := await _lead([[1, outs[1], ins[1]], [2, outs[2], ins[2]]])
	_check(deck._feed_video, "the picture survives the sound lead resolving after it")
	_check_eq(deck._feed_left, 0, "left channel")
	_check_eq(deck._feed_right, 1, "right channel")

	# And neither report order loses the other half.
	deck.on_av_topology_changed(sound.links())
	await _wait(3)
	_check(deck._feed_video, "a report from the sound lead must not drop the picture")
	deck.on_av_topology_changed(picture.links())
	await _wait(3)
	_check(deck._feed_left == 0 and deck._feed_right == 1,
		"a report from the picture lead must not drop the sound")


func _r_crossed() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_1)
	var outs := _out_ports(deck)
	# The pair swapped at the set's end: what a player does by accident, and the
	# whole reason the two channels are tracked separately.
	await _lead([[0, outs[0], ins[0]], [1, outs[1], ins[2]], [2, outs[2], ins[1]]])
	_check(deck._feed_video, "the picture is unaffected")
	_check_eq(deck._feed_left, 1, "the left channel comes out of the RIGHT speaker")
	_check_eq(deck._feed_right, 0, "the right channel comes out of the LEFT speaker")


func _r_video_into_audio() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_2)
	var outs := _out_ports(deck)
	# The yellow plug in a white socket. Sound still arrives, so the deck reads as
	# connected — which is exactly how "I can hear it but not see it" happens.
	await _lead([[0, outs[0], ins[1]], [2, outs[2], ins[2]]])
	_check(deck.connected_tv == tv, "the deck is still connected")
	_check(not deck._feed_video, "a picture into an audio socket is not a picture")
	_check_eq(_which_input(tv, deck), RetroTV.Source.COMPOSITE_2,
		"the set still files it on that input, on the strength of the sound")


func _r_pull_picture() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_1)
	var outs := _out_ports(deck)
	var lead := await _lead([[0, outs[0], ins[0]], [1, outs[1], ins[1]], [2, outs[2], ins[2]]])
	_check(deck._feed_video, "the picture starts connected")
	await _unplug(lead.get_node("PlugB0") as RcaPlug)
	_check(not deck._feed_video, "pulling the picture cord takes the picture away")
	_check(deck._feed_left == 0 and deck._feed_right == 1, "the sound is untouched")


func _r_video_wins() -> void:
	var tv := _tv()
	var deck := _deck()
	await _wait(30)
	var two := _input_ports(tv, RetroTV.Source.COMPOSITE_2)
	var three := _input_ports(tv, RetroTV.Source.COMPOSITE_3)
	var outs := _out_ports(deck)
	# Picture into one input, sound into another: the input is named for the
	# picture, so that is the one the deck belongs to.
	await _lead([[0, outs[0], two[0]]])
	await _lead([[1, outs[1], three[1]], [2, outs[2], three[2]]])
	_check_eq(_which_input(tv, deck), RetroTV.Source.COMPOSITE_2, "the picture decides")


## A computer monitor and a tower: one DE-15 at each end and no phono row anywhere.
##
## The DE-15 used to answer for Composite 1, which meant a cabinet with no phono
## sockets at all announced "COMPOSITE 1", and a cabinet carrying both would have
## had them share one slot — plug in either and it evicts the other.
func _r_vga() -> void:
	var tv := TV_SCENE.instantiate() as RetroTV
	tv.tv_model = "crt_plain"
	tv.freeze = true
	add_child(tv)
	tv.add_to_group("spawned")
	_spawned.append(tv)
	var sys := SYSTEM_SCENE.instantiate() as Node3D
	sys.model_id = "pc_tower"
	sys.systemid = "dos"
	sys.position = Vector3(2.0, 1, 0)
	sys.freeze = true
	add_child(sys)
	sys.add_to_group("spawned")
	_spawned.append(sys)
	await _wait(60)

	var tower_vga := sys.find_child("VgaPort", true, false) as XRToolsSnapZone
	var mon_vga := tv.get_node_or_null("VgaPort") as XRToolsSnapZone
	_check(tower_vga != null, "the tower wears a DE-15")
	_check(mon_vga != null and mon_vga.enabled, "the monitor's DE-15 is fitted and live")
	if tower_vga == null or mon_vga == null:
		return

	var lead := VGA_CABLE.instantiate() as Node3D
	lead.position = Vector3(1.0, 1, -0.5)
	add_child(lead)
	_spawned.append(lead)
	await _wait(20)
	tower_vga.pick_up_object(lead.get_node("PlugA0"))
	mon_vga.pick_up_object(lead.get_node("PlugB0"))
	await _wait(40)
	_check_eq(_which_input(tv, sys), RetroTV.Source.VGA, "the tower is filed on VGA")
	_check(sys.connected_tv == tv, "and the tower knows which monitor it feeds")


func _d_monitor_default() -> void:
	var tv := TV_SCENE.instantiate() as RetroTV
	tv.tv_model = "crt_plain"
	tv.freeze = true
	add_child(tv)
	tv.add_to_group("spawned")
	_spawned.append(tv)
	await _wait(40)
	# The tuner is available on every set, so picking the first available input in
	# enum order would sit a monitor on a channel list rather than on its one socket.
	_check_eq(tv.current_source, RetroTV.Source.VGA, "a monitor starts on its DE-15")
	_check(not tv._source_available(RetroTV.Source.COMPOSITE_1),
		"and does not offer a phono input it has no socket for")
	_check(tv.get_node_or_null("TubeCollar") != null,
		"the retained primitive monitor keeps the physical tube collar")


func _d_legacy_tv_models() -> void:
	var old_tv := TV_SCENE.instantiate() as RetroTV
	old_tv.tv_model = "crt_90s"
	old_tv.freeze = true
	add_child(old_tv)
	_spawned.append(old_tv)
	var old_monitor := TV_SCENE.instantiate() as RetroTV
	old_monitor.tv_model = "crt_monitor"
	old_monitor.freeze = true
	old_monitor.position = Vector3(3.0, 1.0, 0.0)
	add_child(old_monitor)
	_spawned.append(old_monitor)
	await _wait(40)
	_check_eq(old_tv.tv_model, "", "the removed television migrates to the stock body")
	_check(old_tv.shell() == null and old_tv.get_node("TVBody").visible,
		"the migrated television retains stock primitive geometry")
	_check_eq(old_monitor.tv_model, "crt_plain",
		"the removed VGA monitor migrates to the primitive monitor")
	_check(old_monitor.shell() != null and old_monitor.vga_port().enabled,
		"the migrated monitor retains its VGA connector")


# ── Wiring: a machine with more than one output ───────────────────────────────
#
# The PC tower wears three: a DE-15, a phono row, and a 3.5 mm line out. Every case
# here is a combination a player can make in ten seconds, and the ones marked were
# all broken at once — the machine resolved ONE picture sink (first cord in cable
# order) and told ONE sink about itself (the SOUND one, if any lead carried sound).
# Being told is what lets a set show a machine, so plugging in a speaker lead took
# the picture off the monitor.


func _monitor() -> RetroTV:
	var tv := TV_SCENE.instantiate() as RetroTV
	tv.tv_model = "crt_plain"      # a DE-15 and no phono row at all
	tv.freeze = true
	tv.position = Vector3(0, 1, 0)
	add_child(tv)
	tv.add_to_group("spawned")
	_spawned.append(tv)
	return tv


func _tower() -> Node3D:
	var sys := SYSTEM_SCENE.instantiate() as Node3D
	sys.systemid = "dos"
	sys.model_id = "pc_tower"
	sys.freeze = true
	sys.position = Vector3(3.0, 1, 0)
	add_child(sys)
	sys.add_to_group("spawned")
	_spawned.append(sys)
	return sys


func _speakers() -> Node3D:
	var sp := SPEAKERS.instantiate() as Node3D
	sp.position = Vector3(6.0, 1, 0)
	add_child(sp)
	sp.add_to_group("spawned")
	_spawned.append(sp)
	return sp


## Seat a one-cord lead (VGA or TRS) between two named sockets.
func _single_lead(scene: PackedScene, from: Node3D, from_port: String,
		to: Node3D, to_port: String) -> Node3D:
	var lead := scene.instantiate() as Node3D
	lead.position = Vector3(_spawned.size() * 2.0, 1, -1.0)
	add_child(lead)
	_spawned.append(lead)
	await _wait(20)
	var a := from.find_child(from_port, true, false) as XRToolsSnapZone
	var b := to.find_child(to_port, true, false) as XRToolsSnapZone
	_check(a != null and b != null, "sockets %s / %s exist" % [from_port, to_port])
	if a != null and b != null:
		a.pick_up_object(lead.get_node("PlugA0"))
		b.pick_up_object(lead.get_node("PlugB0"))
	await _wait(35)
	return lead


func _w_vga_only() -> void:
	var mon := _monitor()
	var tower := _tower()
	await _wait(60)
	await _single_lead(VGA_CABLE, tower, "VgaPort", mon, "VgaPort")
	_check_eq(_which_input(mon, tower), RetroTV.Source.VGA, "the monitor has the tower")


func _w_composite_only() -> void:
	var tv := _tv()
	var tower := _tower()
	await _wait(60)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_1)
	await _lead([[0, _out_ports(tower)[0], ins[0]]])
	_check_eq(_which_input(tv, tower), RetroTV.Source.COMPOSITE_1, "the set has the tower")


func _w_both_video() -> void:
	var mon := _monitor()
	var tv := _tv()
	var tower := _tower()
	await _wait(60)
	await _single_lead(VGA_CABLE, tower, "VgaPort", mon, "VgaPort")
	await _lead([[0, _out_ports(tower)[0], _input_ports(tv, RetroTV.Source.COMPOSITE_1)[0]]])
	# BOTH, not whichever cord the walk happened to reach first. A machine cabled to
	# two displays feeds two displays; that is what the wiring says.
	_check_eq(_which_input(mon, tower), RetroTV.Source.VGA, "the monitor still has it")
	_check_eq(_which_input(tv, tower), RetroTV.Source.COMPOSITE_1, "and so does the set")


func _w_trs_speakers() -> void:
	var mon := _monitor()
	var tower := _tower()
	var speakers := _speakers()
	await _wait(60)
	await _single_lead(VGA_CABLE, tower, "VgaPort", mon, "VgaPort")
	_check_eq(_which_input(mon, tower), RetroTV.Source.VGA, "picture first")
	# The 3.5 mm lead to a pair of speakers: sound leaves the machine somewhere with
	# no screen at all, and the monitor must not hear about it.
	await _single_lead(TRS_CABLE, tower, "LineOut", speakers, "LineIn")
	_check_eq(_which_input(mon, tower), RetroTV.Source.VGA,
		"the monitor keeps the picture when the sound goes to the speakers")


func _w_audio_elsewhere() -> void:
	var mon := _monitor()
	var tv := _tv()
	var tower := _tower()
	await _wait(60)
	await _single_lead(VGA_CABLE, tower, "VgaPort", mon, "VgaPort")
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_1)
	var outs := _out_ports(tower)
	await _lead([[1, outs[1], ins[1]], [2, outs[2], ins[2]]])
	_check_eq(_which_input(mon, tower), RetroTV.Source.VGA,
		"the monitor keeps the picture when the sound goes to another set")
	_check_eq(_which_input(tv, tower), RetroTV.Source.COMPOSITE_1,
		"and the set carrying the sound knows about it too")


func _w_pull_one_video() -> void:
	var mon := _monitor()
	var tv := _tv()
	var tower := _tower()
	await _wait(60)
	var vga := await _single_lead(VGA_CABLE, tower, "VgaPort", mon, "VgaPort")
	await _lead([[0, _out_ports(tower)[0], _input_ports(tv, RetroTV.Source.COMPOSITE_1)[0]]])
	await _unplug(vga.get_node("PlugB0") as RcaPlug)
	_check_eq(_which_input(tv, tower), RetroTV.Source.COMPOSITE_1,
		"the set keeps the picture when the OTHER lead is pulled")
	_check_eq(_which_input(mon, tower), -1, "and the monitor lets it go")


func _w_pull_sound() -> void:
	var mon := _monitor()
	var tower := _tower()
	var speakers := _speakers()
	await _wait(60)
	await _single_lead(VGA_CABLE, tower, "VgaPort", mon, "VgaPort")
	var trs := await _single_lead(TRS_CABLE, tower, "LineOut", speakers, "LineIn")
	await _unplug(trs.get_node("PlugB0") as RcaPlug)
	_check_eq(_which_input(mon, tower), RetroTV.Source.VGA,
		"pulling the sound lead leaves the picture alone")


## The same wiring in the other order. Order-dependence is the signature of the bug
## this group exists for: the machine kept ONE sink, so which lead moved last
## decided who knew about it.
func _w_sound_first() -> void:
	var mon := _monitor()
	var tower := _tower()
	var speakers := _speakers()
	await _wait(60)
	await _single_lead(TRS_CABLE, tower, "LineOut", speakers, "LineIn")
	await _single_lead(VGA_CABLE, tower, "VgaPort", mon, "VgaPort")
	_check_eq(_which_input(mon, tower), RetroTV.Source.VGA,
		"the picture arrives even though the sound was plugged in first")


## Filed is not quite shown: each set has to select that input and be willing to
## paint it. Both of them, at once, off one machine.
func _w_both_can_paint() -> void:
	var mon := _monitor()
	var tv := _tv()
	var tower := _tower()
	await _wait(60)
	await _single_lead(VGA_CABLE, tower, "VgaPort", mon, "VgaPort")
	await _lead([[0, _out_ports(tower)[0], _input_ports(tv, RetroTV.Source.COMPOSITE_2)[0]]])
	mon.set_source(RetroTV.Source.VGA)
	tv.set_source(RetroTV.Source.COMPOSITE_2)
	await _wait(6)
	_check(mon.can_paint(tower), "the monitor would show it")
	_check(tv.can_paint(tower), "and the set would show it at the same time")


## Where the sound ends up, which is the other half of every case above.
func _w_sound_routing() -> void:
	var mon := _monitor()
	var tower := _tower()
	var speakers := _speakers()
	await _wait(60)
	await _single_lead(VGA_CABLE, tower, "VgaPort", mon, "VgaPort")
	_check(tower._av_tv == null, "a picture-only hookup carries no sound")
	await _single_lead(TRS_CABLE, tower, "LineOut", speakers, "LineIn")
	_check_eq(tower._av_tv, speakers, "the 3.5 mm lead puts the sound in the speakers")
	_check(tower._av_speaker_l >= 0 and tower._av_speaker_r >= 0,
		"and both channels land somewhere (l=%d r=%d)"
		% [tower._av_speaker_l, tower._av_speaker_r])


## Two machines into one set, on different inputs. Nothing here is specific to a
## tower: it is the same resolution every console in the room goes through.
func _w_two_machines() -> void:
	var tv := _tv()
	var a := _tower()
	var b := _tower()
	b.position = Vector3(4.5, 1, 0)
	await _wait(70)
	await _lead([[0, _out_ports(a)[0], _input_ports(tv, RetroTV.Source.COMPOSITE_1)[0]]])
	await _lead([[0, _out_ports(b)[0], _input_ports(tv, RetroTV.Source.COMPOSITE_3)[0]]])
	_check_eq(_which_input(tv, a), RetroTV.Source.COMPOSITE_1, "the first keeps its input")
	_check_eq(_which_input(tv, b), RetroTV.Source.COMPOSITE_3, "the second has its own")
	tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(5)
	_check(tv.can_paint(a) and not tv.can_paint(b), "only the selected one may paint")
	tv.set_source(RetroTV.Source.COMPOSITE_3)
	await _wait(5)
	_check(tv.can_paint(b) and not tv.can_paint(a), "and it swaps over on SOURCE")


## Pulling a machine out entirely: every display that had it lets go, not just the
## one that happened to be resolved.
func _w_unplug_all() -> void:
	var mon := _monitor()
	var tv := _tv()
	var tower := _tower()
	await _wait(60)
	var vga := await _single_lead(VGA_CABLE, tower, "VgaPort", mon, "VgaPort")
	var comp := await _lead([[0, _out_ports(tower)[0],
		_input_ports(tv, RetroTV.Source.COMPOSITE_1)[0]]])
	_check(_which_input(mon, tower) >= 0 and _which_input(tv, tower) >= 0, "both have it")
	await _unplug(vga.get_node("PlugB0") as RcaPlug)
	await _unplug(comp.get_node("PlugB0") as RcaPlug)
	_check_eq(_which_input(mon, tower), -1, "the monitor let go")
	_check_eq(_which_input(tv, tower), -1, "and so did the set")


## The NES wears both: a phono pair on its flank and an RF OUT with a CH3/CH4
## switch on its back. The RF switch is itself a lead — its links() reports console
## RF OUT to the set's aerial socket, with the grey box in the middle counting for
## nothing — so both paths resolve through exactly the same code.
func _w_nes_rf() -> void:
	var tv_comp := _tv()
	var tv_rf := _tv()
	tv_rf.position = Vector3(3.0, 1, 0)
	var nes := SYSTEM_SCENE.instantiate() as Node3D
	nes.systemid = "nes"
	nes.model_id = "nes"          # the detailed shell: only it moulds an RF panel
	nes.freeze = true
	nes.position = Vector3(6.0, 1, 0)
	add_child(nes)
	nes.add_to_group("spawned")
	_spawned.append(nes)
	# The shell is a GLB and can be slow to land; the RF socket is built with it.
	await _wait(180)

	var rf_out := nes.find_child("RfOut", true, false) as RcaPort
	if rf_out == null:
		_skip("this build's NES has no RF panel")
		return
	await _lead([[0, _out_ports(nes)[0],
		_input_ports(tv_comp, RetroTV.Source.COMPOSITE_1)[0]]])
	await _single_lead(RF_SWITCH, nes, "RfOut", tv_rf, "RfPort")

	_check_eq(_which_input(tv_comp, nes), RetroTV.Source.COMPOSITE_1,
		"the composite lead reaches one set")
	_check_eq(_which_input(tv_rf, nes), RetroTV.Source.RF,
		"and the RF lead reaches the other, at the same time")

	# On the aerial input the console's own switch decides whether there is a
	# picture at all: a set tuned to the other channel shows snow.
	tv_rf.set_source(RetroTV.Source.RF)
	await _wait(5)
	var ch: int = nes.get_rf_channel()
	if ch >= 0:
		tv_rf.rf_channel = ch
		await _wait(5)
		_check(tv_rf.can_paint(nes), "tuned to the console's channel, it may paint")
		tv_rf.rf_channel = 4 if ch != 4 else 3
		await _wait(5)
		_check(not tv_rf.can_paint(nes), "on the other channel it may not")


# ── Display ───────────────────────────────────────────────────────────────────

func _d_selected() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	_check_eq(_shown(tv), src.texture, "the set shows the input it is on")


func _d_away() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(6)
	_check(_shown(tv) != src.texture, "an input with nothing on it must not show the other one")
	_check_eq(_shown(tv), tv._display._blue_texture, "it shows the no-signal screen")


func _d_back() -> void:
	# The reported bug: play, change input, come back, and the picture is gone
	# until you restart the source.
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(6)
	tv.set_source(RetroTV.Source.COMPOSITE_3)
	await _wait(6)
	_check_eq(_shown(tv), src.texture, "coming back to the input shows it again")


func _d_stopped() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	src.texture = null                   # switched off / stopped / unplugged
	await _wait(6)
	_check_eq(_shown(tv), tv._display._blue_texture, "a source that stops leaves no frozen frame")


func _d_off() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	tv.remote_power_toggle()          # the set has no setter; this is the POWER key
	await _wait(6)
	_check(_shown(tv) != src.texture, "a set that is off shows nothing")
	_check_eq(_glass(tv), tv._display._dark_material, "it wears its own dark glass")
	_check(_glass(tv) is ShaderMaterial, "the dark glass keeps the reflective shader")
	_check_eq(_shown(tv), tv._display._dark_texture, "the phosphors behind it are black")


## The cast light hides itself while it has nothing to show (92294bee), and
## the display's tick used to return early on exactly that, so once a set had
## been off - which every set is at _ready - nothing could light it again.
func _d_ambilight() -> void:
	var tv := _tv()
	await _wait(30)
	var light := tv.ambilight()
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(6)
	_check(light.visible and light.light_energy > 0.0, "a set with a picture lights the room")
	tv.remote_power_toggle()
	await _wait(6)
	_check(not light.visible, "a set switched off throws no light")
	tv.remote_power_toggle()
	await _wait(6)
	_check(light.visible and light.light_energy > 0.0, "and lights the room again once it is back on")
	# The graphics switch, without saving the player's prefs from a test.
	var was := QualityManager.screen_lights_enabled
	QualityManager.screen_lights_enabled = false
	QualityManager.apply_screen_lights()
	await _wait(2)
	_check(not light.visible, "the Screen Light switch off douses it while the set stays on")
	QualityManager.screen_lights_enabled = true
	QualityManager.apply_screen_lights()
	await _wait(2)
	_check(light.visible and light.light_energy > 0.0, "and on lights the room again at once")
	QualityManager.screen_lights_enabled = was
	QualityManager.apply_screen_lights()


func _d_empty() -> void:
	var tv := _tv()
	await _wait(30)
	tv.set_source(RetroTV.Source.COMPOSITE_2)
	await _wait(6)
	_check_eq(_shown(tv), tv._display._blue_texture, "an input with nothing plugged in is blue")


## Being ON an input is not the same as SENDING a picture to it.
##
## A phono plug fits any phono socket, so a red cord in the yellow input is
## ordinary hardware — and the set still files the machine on that input, on
## purpose, so its sound routes (see routing/picture into an audio socket). What
## it must not do is take that as a picture, which it did: the game appeared on
## the glass with no video cord anywhere in the room.
##
## The source answers, because only it knows where its picture went. The two
## decks always did, through their own _feed_video; a console's accessor hands
## the core's frame to anyone who asks, so the set has to ask first.
func _d_no_video_cord() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	src.video_to_tv = false
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_1, src)
	await _wait(6)
	_check(_shown(tv) != src.texture, "a host sending no picture here must not be shown")
	_check_eq(_shown(tv), tv._display._blue_texture, "the set shows its no-signal screen")

	# And the moment a picture cord does land, the same host appears.
	src.video_to_tv = true
	tv.set_source(RetroTV.Source.COMPOSITE_2)
	await _wait(4)
	tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(6)
	_check_eq(_shown(tv), src.texture, "and is shown again once it is sending one")


func _d_rf_untuned() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	src.rf_channel = 4 if tv.rf_channel != 4 else 3     # deliberately not the set's
	await _seat_stub(tv, RetroTV.Source.RF, src)
	await _wait(6)
	_check(_shown(tv) != src.texture, "a machine modulating on the other channel is not shown")
	_check_eq(_glass(tv), tv._display._rf_static_material,
		"an aerial channel with nothing on it is SNOW, not the blue no-signal screen")


func _d_rf_tuned() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	src.rf_channel = tv.rf_channel                      # the one the set is tuned to
	await _seat_stub(tv, RetroTV.Source.RF, src)
	await _wait(6)
	_check_eq(_shown(tv), src.texture, "tuned to its channel, the machine appears")
	_check(tv.can_paint(src), "and it counts as the shown input")


## The tube's afterglow belongs to the picture that made it.
##
## The accumulator ping-pongs between two SubViewports and blends each frame with
## what it already holds, and nothing ever cleared it: switch input, or reset a
## machine, and the last picture bled back in — "I pressed reset on the PS1 and saw
## the Wii for a moment, then the BIOS". Measured in pixels by
## Tools/av/phosphor_ghost_probe.tscn (a quarter of the old picture on the first frame,
## gone over eight); asserted here as the thing that decides it, since a headless
## run has no renderer to accumulate anything.
func _d_no_ghost() -> void:
	var tv := _tv()
	await _wait(30)
	var first := StubSource.new()
	first.texture = _a_texture(Color(1, 0, 0, 1))
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_1, first)
	await _wait(8)
	_check(tv._display._phosphor_fresh == 0, "the accumulator settles while one source runs")

	var second := StubSource.new()
	second.texture = _a_texture(Color(0, 1, 0, 1))
	add_child(second)
	_spawned.append(second)
	tv._panel._connected_systems[RetroTV.Source.COMPOSITE_2] = second
	tv.set_source(RetroTV.Source.COMPOSITE_2)
	await _wait(1)
	_check(tv._display._phosphor_fresh > 0 or _prev_is(tv, second.texture),
		"a new source starts with no history behind it")

	# And the same when a machine restarts: its picture stops, then a new one
	# arrives, and what the buffers hold in between is the OLD one.
	await _wait(10)
	second.texture = null
	await _wait(6)
	_check(tv._display._phosphor_fresh > 0, "a source that stops arms the accumulator")
	second.texture = _a_texture(Color(0, 0, 1, 1))
	await _wait(1)
	_check(tv._display._phosphor_fresh > 0 or _prev_is(tv, second.texture),
		"and the picture that comes back does not blend with the old one")


## True when either accumulation buffer is blending against `tex` itself — which is
## what "no history" looks like — rather than against the other buffer's contents.
func _prev_is(tv: RetroTV, tex: Texture2D) -> bool:
	for vp in [tv._phosphor_a, tv._phosphor_b]:
		var rect := (vp as SubViewport).get_child(0) as ColorRect
		if rect != null and rect.material is ShaderMaterial:
			if (rect.material as ShaderMaterial).get_shader_parameter("prev") == tex:
				return true
	return false


func _d_stage() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	# A source that wants its picture put through a shader of its own — what the
	# VHS effect is. The set runs it; the source never touches a material.
	src.stage = {"shader": WINDOW_SHADER,
		"params": {"source_rect": Vector4(0.0, 0.5, 1.0, 0.5), "eye_shift": 0.0}}
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	var mat := _glass(tv) as ShaderMaterial
	_check(mat != null and mat.shader == WINDOW_SHADER, "the set uses the source's shader")
	if mat != null:
		_check_eq(mat.get_shader_parameter("source_rect"), Vector4(0.0, 0.5, 1.0, 0.5),
			"and the source's own uniforms")
		_check_eq(mat.get_shader_parameter("source_tex"), src.texture, "fed with its picture")
		_check_eq(mat.get_shader_parameter("crt_glass_reflection"), 0.35,
			"and the shared glass tuning reaches a source-owned display stage")


func _d_glass_wear() -> void:
	var tv := _tv()
	await _wait(30)
	_check_eq(tv.get_crt_params().get("crt_glass_wear"), 0.35,
		"new sets start with subtle wear")
	_check_eq(tv.get_crt_params().get("crt_character"), 0.35,
		"new sets start with subtle CRT character")
	_check(tv._tube_collar.get_parent() == tv,
		"the physical collar is independent of the collapsing screen mesh")

	# Exercise the actual UI signal, not merely the television setter.
	var ui := TV_OPTIONS_UI.instantiate() as TVOptions2D
	add_child(ui)
	_spawned.append(ui)
	await _wait(2)
	ui.populate_crt(tv.get_crt_params())
	ui.crt_param_changed.connect(tv.set_crt_param)
	var wear_slider := ui._crt_sliders["crt_glass_wear"]["slider"] as HSlider
	_check_eq(wear_slider.max_value, 3.0,
		"the Glass wear slider offers a 3x overdrive range")
	wear_slider.value = 2.5
	_check_eq(tv.get_crt_params().get("crt_glass_wear"), 2.5,
		"Glass wear overdrive reaches the television")
	var character_slider := ui._crt_sliders["crt_character"]["slider"] as HSlider
	character_slider.value = 0.75
	_check_eq(tv.get_crt_params().get("crt_character"), 0.75,
		"the CRT character slider reaches the television")

	# A source-owned stage replaces the ordinary gameplay material. The set must
	# seed the replacement with the same wear texture, value and per-set flip.
	var src := StubSource.new()
	src.texture = _a_texture()
	src.stage = {"shader": WINDOW_SHADER,
		"params": {"source_rect": Vector4(0.0, 0.0, 1.0, 1.0), "eye_shift": 0.0}}
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	var active := _glass(tv) as ShaderMaterial
	_check(active != null, "the source switch leaves a display material")
	if active != null:
		_check_eq(active.get_shader_parameter("crt_glass_wear"), 2.5,
			"wear survives a source-stage switch")
		_check_eq(active.get_shader_parameter("crt_character"), 0.75,
			"CRT character survives a source-stage switch")
		_check_eq(active.get_shader_parameter("crt_glass_wear_tex"), RetroTV.GLASS_WEAR_TEXTURE,
			"the mipmapped mask reaches the source stage")
		_check(active.get_shader_parameter("crt_glass_wear_flip") is Vector2,
			"the source stage receives this set's mirrored orientation")
		var picture_before: Variant = active.get_shader_parameter("source_tex")
		tv.set_crt_param("crt_glass_wear", 3.0)
		_check_eq(active.get_shader_parameter("source_tex"), picture_before,
			"wear overdrive changes glass response without replacing the game image")
		tv.set_crt_param("crt_glass_wear", 2.5)

	# Power-off swaps in a separate dark material, where wear should be easiest to
	# see. It carries the same setting rather than resetting to the shader default.
	tv.remote_power_toggle()
	await _wait(6)
	var dark := _glass(tv) as ShaderMaterial
	_check_eq(dark, tv._display._dark_material, "power-off uses the dark glass")
	if dark != null:
		_check_eq(dark.get_shader_parameter("crt_glass_wear"), 2.5,
			"powered-off glass keeps the chosen wear")
		_check_eq(dark.get_shader_parameter("crt_powered"), false,
			"powered-off glass receives explicit unlit state")

	# ScenePersistence already stores the complete CRT dictionary. Assert the new
	# key is in that real record and can seed a television before it enters a tree.
	var persistence := ScenePersistence.new()
	var record: Dictionary = persistence._serialize_node(tv, 1, {})
	_check_eq((record.get("crt_params", {}) as Dictionary).get("crt_glass_wear"), 2.5,
		"the scene record persists Glass wear")
	_check_eq((record.get("crt_params", {}) as Dictionary).get("crt_character"), 0.75,
		"the scene record persists CRT character")
	var restored := TV_SCENE.instantiate() as RetroTV
	restored.set_crt_params(record.get("crt_params", {}))
	restored.freeze = true
	restored.position = Vector3(_spawned.size() * 3.0, 1, 0)
	add_child(restored)
	_spawned.append(restored)
	await _wait(4)
	_check_eq(restored.get_crt_params().get("crt_glass_wear"), 2.5,
		"a restored television keeps Glass wear overdrive")
	_check_eq(restored.get_crt_params().get("crt_character"), 0.75,
		"a restored television keeps CRT character")


func _d_stage_per_tv() -> void:
	var tv_top := _tv()
	var tv_bottom := _tv()
	await _wait(30)
	# One machine, two sets, one composite frame: each set gets its own window of
	# it (the dual-screen handhelds).
	var src := StubSource.new()
	src.texture = _a_texture()
	src.stage_by_tv = {
		tv_top: {"shader": WINDOW_SHADER,
			"params": {"source_rect": Vector4(0.0, 0.0, 1.0, 0.5), "eye_shift": 0.0}},
		tv_bottom: {"shader": WINDOW_SHADER,
			"params": {"source_rect": Vector4(0.0, 0.5, 1.0, 0.5), "eye_shift": 0.0}},
	}
	add_child(src)
	_spawned.append(src)
	tv_top._panel._connected_systems[RetroTV.Source.COMPOSITE_1] = src
	tv_bottom._panel._connected_systems[RetroTV.Source.COMPOSITE_1] = src
	tv_top.set_source(RetroTV.Source.COMPOSITE_1)
	tv_bottom.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(6)
	var top_mat := _glass(tv_top) as ShaderMaterial
	var bottom_mat := _glass(tv_bottom) as ShaderMaterial
	_check(top_mat != null and bottom_mat != null, "both sets show the machine")
	if top_mat != null and bottom_mat != null:
		_check_eq(top_mat.get_shader_parameter("source_rect"), Vector4(0.0, 0.0, 1.0, 0.5),
			"the first set gets the top half")
		_check_eq(bottom_mat.get_shader_parameter("source_rect"), Vector4(0.0, 0.5, 1.0, 0.5),
			"the second set gets the bottom half")


## A broadcast is a picture like any other: it is sampled into one of the set's own
## materials, so the 4:3/16:9 button reshapes it exactly as it reshapes a console.
## The tuner used to hand the set a finished StandardMaterial3D instead — the only
## route onto the glass that skips _show_sampled — and the button did nothing at
## all on the TV input while working on every other one.
func _d_tv_aspect() -> void:
	var tv := _tv()
	await _wait(30)
	var tuner := StubTuner.new()
	tuner.name = "TVTuner"
	tuner.texture = _a_texture()
	tv.add_child(tuner)
	tv._tuner = tuner
	tv.set_source(RetroTV.Source.TV)
	await _wait(6)
	_check_eq(_shown(tv), tuner.texture, "the set shows the tuner's picture")

	tv.set_widescreen(false)
	await _wait(4)
	var narrow: Variant = _fit_on_glass(tv)
	tv.set_widescreen(true)
	await _wait(4)
	var wide: Variant = _fit_on_glass(tv)
	# Whichever shape the glass is, one of the two settings has to letterbox: the
	# tube cannot be both. Reading the fit off the material that is ACTUALLY on the
	# glass is the whole point — the set kept a fitted material up to date all along,
	# it just was not showing it.
	_check(narrow != null and wide != null,
		"a broadcast is sampled into a material that carries the fit")
	_check(narrow != wide, "the aspect button changes the picture's shape: %s vs %s"
		% [narrow, wide])


## The fit the picture on the glass is actually being drawn at, or null when what
## is up there has no fit to read.
func _fit_on_glass(tv: RetroTV) -> Variant:
	var mat := _glass(tv) as ShaderMaterial
	if mat == null:
		return null
	return mat.get_shader_parameter("fit_scale")


# ── The set's guard ───────────────────────────────────────────────────────────

func _g_refused() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(6)
	var before := _glass(tv)
	var rogue := StandardMaterial3D.new()
	rogue.albedo_color = Color(1, 0, 1, 1)
	_check(not tv.can_paint(src), "a host on another input may not paint")
	_check(not tv.paint_screen(src, rogue), "and is refused when it tries")
	_check_eq(_glass(tv), before, "the glass is left alone")


func _g_allowed() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	var mine := StandardMaterial3D.new()
	_check(tv.can_paint(src), "the shown host may paint")
	_check(tv.paint_screen(src, mine), "and its paint is accepted")
	_check_eq(_glass(tv), mine, "its material is on the glass")
	_check_eq(tv._display._screen_owner, src, "and the set records who put it there")


func _g_release() -> void:
	var tv := _tv()
	await _wait(30)
	var src := StubSource.new()
	src.texture = _a_texture()
	await _seat_stub(tv, RetroTV.Source.COMPOSITE_3, src)
	await _wait(4)
	var mine := StandardMaterial3D.new()
	tv.paint_screen(src, mine)
	var stranger := StubSource.new()
	add_child(stranger)
	_spawned.append(stranger)
	tv.release_screen(stranger)
	_check_eq(_glass(tv), mine, "a stranger cannot take somebody else's picture down")
	tv.release_screen(src)
	_check(_glass(tv) != mine, "the owner can")


# ── Audio ─────────────────────────────────────────────────────────────────────

func _a_selected_only() -> void:
	var tv := _tv()
	await _wait(30)
	var shown := StubSource.new()
	var hidden := StubSource.new()
	add_child(shown)
	add_child(hidden)
	_spawned.append(shown)
	_spawned.append(hidden)
	tv._panel._connected_systems[RetroTV.Source.COMPOSITE_1] = shown
	tv._panel._connected_systems[RetroTV.Source.COMPOSITE_2] = hidden
	tv.set_source(RetroTV.Source.COMPOSITE_1)
	await _wait(4)
	shown.volumes.clear()
	hidden.volumes.clear()
	tv.remote_volume_up()
	await _wait(4)
	_check(not shown.volumes.is_empty() and shown.volumes.back() > 0.0,
		"the input being watched is heard (got %s)" % str(shown.volumes))
	_check(not hidden.volumes.is_empty() and hidden.volumes.back() == 0.0,
		"the other input is silent (got %s)" % str(hidden.volumes))


func _a_no_display() -> void:
	# A machine wired to nothing makes no sound. This used to fall out of having
	# no screen mesh to paint, which stopped being a thing that could be asked.
	var sys := SYSTEM_SCENE.instantiate() as Node3D
	sys.freeze = true
	add_child(sys)
	sys.add_to_group("spawned")
	_spawned.append(sys)
	await _wait(40)
	_check(not sys._has_display(), "a console with no television has nowhere to show")
	var tv := _tv()
	await _wait(30)
	var ins := _input_ports(tv, RetroTV.Source.COMPOSITE_1)
	var outs := _out_ports(sys)
	if outs[0] == null:
		_skip("this cabinet wears a captive lead, not sockets")
		return
	await _lead([[0, outs[0], ins[0]], [1, outs[1], ins[1]], [2, outs[2], ins[2]]])
	_check(sys._has_display(), "cabling it to a set gives it one")
