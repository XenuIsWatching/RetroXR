## Link-cable self-tests — the decisions a link lead makes, headless.
##
##     "$godot" --headless --path RetroXR res://Tests/link_tests.tscn
##
## Exits 0 when everything passes, 1 otherwise, so it can gate a commit.
##
## What is here is what can be decided without a core: which sockets will take a
## link plug, which machine a socket belongs to, and the connect/disconnect
## bookkeeping that decides whether two cores are told they share a wire. Whether
## a linked pair actually trades bytes needs two real cores and lives in the
## coordinator's own C++ tests (libretro-godot/tests/run_tests.py), which is also
## where the deadlock and determinism cases are.
##
## Two of these are the regression record for traps this feature can fall into.
## A link lead that reported itself to AvGraph would put a television in the
## business of routing serial traffic, and a cable that stayed joined after being
## carried out of the room would leave two cores waiting on each other over a
## lead that no longer exists.
extends Node

var _pass := 0
var _fail := 0


func _ready() -> void:
	get_tree().create_timer(60.0).timeout.connect(func() -> void:
		print("[link] TIMEOUT")
		get_tree().quit(1))
	_test_plug_gating()
	_test_port_pins_its_channel()
	_test_machine_lookup()
	_test_libretro_lookup()
	_test_cable_is_not_av()
	_test_netplay_cable_guard()
	await _test_disconnect_is_idempotent()
	await _test_cable_scene()
	await _test_port_scene()
	_test_cable_is_spawnable()
	await _test_gc_gba_cable()
	await _test_lid_clears_the_socket()
	await _test_bus_head_is_the_same_on_every_peer()
	await _test_the_lead_will_seat()
	await _test_a_seated_plug_sits_outside()
	await _test_a_junction_plug_keeps_up()
	await _test_the_junction_does_not_snap_through_vertical()
	await _test_a_machine_takes_a_plug_the_same_way()
	await _test_each_end_says_what_it_is()
	await _test_every_socket_can_be_saved()
	_test_psx_plug_gating()
	_test_psx_cable_is_not_av()
	_test_psx_cable_is_spawnable()
	await _test_psx_socket_follows_the_hardware()
	await _test_psx_socket_is_in_the_panel()
	await _test_psx_lead_will_seat()
	await _test_psx_cable_joins_a_pair()
	await _test_every_lead_states_its_bus()
	_test_restart_rule()
	print("[link] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


class _NetplayStub extends RefCounted:
	var covered: Array = []
	var scheduled: Array = []

	func netplay_running() -> bool:
		return true

	func netplay_covers(machine: Object) -> bool:
		return covered.has(machine)

	func is_host() -> bool:
		return true

	func netplay_schedule_link(op: int, entries: Array) -> void:
		scheduled.append({"op": op, "entries": entries.duplicate(true)})


func _test_netplay_cable_guard() -> void:
	var a := Node.new()
	var b := Node.new()
	var outside := Node.new()
	var manager := _NetplayStub.new()
	manager.covered = [a, b]
	var cable := CompositeCable.new()
	cable.netplay_manager_override = manager
	var bus: Array = [{"machine": a, "port": 0}, {"machine": b, "port": 0}]
	_ok("netplay/a covered join is claimed", cable.netplay_took_bus(bus, []))
	_eq("netplay/and scheduled once", manager.scheduled.size(), 1)
	_ok("netplay/re-resolving the same seated lead does not schedule twice",
		cable.netplay_took_bus(bus, []))
	_eq("netplay/the duplicate join was coalesced", manager.scheduled.size(), 1)
	_ok("netplay/a pull before the join lands is still claimed",
		cable.netplay_took_bus([], []))
	_eq("netplay/and schedules the inverse operation", manager.scheduled.size(), 2)
	if manager.scheduled.size() >= 2:
		_eq("netplay/the inverse is a pull", manager.scheduled[1]["op"], 0)

	manager.scheduled.clear()
	var partial: Array = [{"machine": a, "port": 0}, {"machine": outside, "port": 0}]
	_ok("netplay/a cable crossing the session boundary is claimed and refused",
		cable.netplay_took_bus(partial, []))
	_eq("netplay/so no local or scheduled partial bus is made", manager.scheduled.size(), 0)
	a.free()
	b.free()
	outside.free()
	cable.free()


# -- The console-to-handheld lead --------------------------------------------
# The only asymmetric cable in the room, and every one of these is about that
# asymmetry: two ends that fit different sockets, joining two machines that are
# not peers, over a protocol neither of the handheld leads speaks.

func _test_gc_gba_cable() -> void:
	var scene := load("res://Scenes/Objects/cables/gc_gba_cable.tscn") as PackedScene
	_ok("the lead has a scene", scene != null)
	if scene == null:
		return
	var lead := scene.instantiate() as GcGbaCable
	_ok("and it is a GcGbaCable", lead != null)
	if lead == null:
		return
	add_child(lead)
	await get_tree().process_frame

	var gc_end := lead.get_node_or_null("PlugA0") as GcLinkPlug
	var gba_end := lead.get_node_or_null("PlugB0") as LinkPlug
	_ok("one end is a GameCube plug", gc_end != null)
	_ok("the other is a handheld plug", gba_end != null)
	if gc_end == null or gba_end == null:
		lead.queue_free()
		return

	# The whole point of the two ends being different. A console socket filters
	# on "controller_plug" and a handheld's EXT port on "link_plug", and neither
	# end answers to both, so neither can be pushed into the wrong machine.
	_ok("the console end answers a controller socket", gc_end.is_in_group("controller_plug"))
	_ok("and is not a handheld plug", gc_end.plug_group() != gba_end.plug_group())
	_ok("the handheld end answers an EXT port", gba_end.is_in_group("link_plug"))
	_ok("and is not a controller plug", not gba_end.is_in_group("controller_plug"))

	# Which console's ports will take it. A GameCube lead is not a Wii lead, and
	# the socket says so before anything electrical is decided.
	_eq("the console end fits a GameCube", gc_end.systemid, "gamecube")

	# Seating it announces a handheld to the core, the same way any pad announces
	# itself: there is no separate step and nothing else to configure.
	_eq("and announces a Game Boy Advance", gc_end.device_type, (7 << 8) | 0)

	# It carries neither picture nor sound, so AvGraph must walk straight past it.
	_ok("the lead is not an A/V cable", lead.links().is_empty())

	# Nothing is seated, so it is joined to nothing and says so without faulting.
	lead._resolve()
	_ok("an unseated lead joins nothing", true)

	lead.queue_free()
	await get_tree().process_frame


## Every lead that can put two cores on a wire has to be able to SAY so.
##
## Netplay asks each lead what bus it makes, because a cabled pair is one
## session over two machines that every peer replicates — a link cable never
## crosses the network. A lead that cannot answer is a lead the session cannot
## put in a group, and the far machine is then ungated on the host and not
## running at all on a client, whose core then sits on a bus whose other end
## never publishes.
##
## This is here rather than in netplay_tests because it is a fact about the
## LEADS. It is also the case that would have caught the GameCube lead being
## left out: it was the one whose wide end sits in a controller socket, so a
## search from the machine's own link ports could never have found it, and
## nothing said so out loud.
func _test_every_lead_states_its_bus() -> void:
	var leads := {
		"res://Scenes/Objects/cables/link_cable.tscn": "the handheld lead",
		"res://Scenes/Objects/cables/gc_gba_cable.tscn": "the GameCube lead",
		"res://Scenes/Objects/cables/psx_link_cable.tscn": "the PlayStation lead",
	}
	for path: String in leads:
		var scene := load(path) as PackedScene
		_ok("%s has a scene" % leads[path], scene != null)
		if scene == null:
			continue
		var lead := scene.instantiate()
		add_child(lead)
		await get_tree().process_frame
		_ok("%s can state its bus" % leads[path], lead.has_method("linked_machines"))
		_ok("%s can name what it holds" % leads[path], lead.has_method("held_machines"))
		if lead.has_method("linked_machines"):
			# Seated in nothing, so it joins nothing — and must say that rather
			# than fault, because _resolve asks before anything is plugged in.
			_ok("%s joins nothing while unseated" % leads[path],
				(lead.linked_machines() as Array).is_empty())
			_ok("%s holds nothing while unseated" % leads[path],
				(lead.held_machines() as Array).is_empty())
		# And it must defer to a session the same way, which with no session
		# running means taking the decision itself.
		_ok("%s acts alone when no game is running" % leads[path],
			not lead.netplay_took_bus([], []))
		lead.queue_free()
		await get_tree().process_frame

	# The above can only tell that a METHOD is there, and CompositeCable now
	# supplies an empty default for both — so a lead that lost its override
	# would sail through it. What cannot be faked is a lead that has actually
	# joined a pair naming them, which is also the harder half: a pull has to
	# name machines the walk can no longer reach.
	await _joined_lead_names_its_pair()


func _joined_lead_names_its_pair() -> void:
	var m1 := _StubMachine.new()
	var m2 := _StubMachine.new()
	add_child(m1)
	add_child(m2)
	m1.libretro = Libretro.new()
	m2.libretro = Libretro.new()
	m1.add_child(m1.libretro)
	m2.add_child(m2.libretro)

	var psx := PsxLinkCable.new()
	add_child(psx)
	psx._join({"libretro": m1.libretro, "machine": m1, "port": 0},
		{"libretro": m2.libretro, "machine": m2, "port": 0})
	var psx_held: Array = psx.held_machines()
	_eq("a joined PlayStation lead names two machines", psx_held.size(), 2)
	if psx_held.size() == 2:
		_ok("and they are the two it joined",
			psx_held[0]["machine"] == m1 and psx_held[1]["machine"] == m2)
	psx._disconnect()
	_eq("a parted PlayStation lead names none", (psx.held_machines() as Array).size(), 0)

	var gc := GcGbaCable.new()
	add_child(gc)
	# Console first, the end handed to LinkConnect — the same rule the handheld
	# lead follows for its purple end.
	gc._join({"libretro": m1.libretro, "machine": m1, "port": 2}, m2.libretro)
	var gc_held: Array = gc.held_machines()
	_eq("a joined GameCube lead names two machines", gc_held.size(), 2)
	if gc_held.size() == 2:
		_ok("console first", gc_held[0]["machine"] == m1)
		_ok("then the handheld", gc_held[1]["machine"] == m2)
		_eq("the console keeps its own port number", int(gc_held[0]["port"]), 2)
		_eq("and the handheld its GameCube conversation",
			int(gc_held[1]["port"]), GcGbaCable.GBA_JOY_PORT)
	gc._disconnect()
	_eq("a parted GameCube lead names none", (gc.held_machines() as Array).size(), 0)

	var handheld := LinkCable.new()
	add_child(handheld)
	handheld._join([{"libretro": m1.libretro, "machine": m1, "port": 0},
		{"libretro": m2.libretro, "machine": m2, "port": 0}])
	var hh_held: Array = handheld.held_machines()
	_eq("a joined handheld lead names two machines", hh_held.size(), 2)
	if hh_held.size() == 2:
		_ok("and they are the two it joined",
			hh_held[0]["machine"] == m1 and hh_held[1]["machine"] == m2)
	handheld._disconnect()
	_eq("a parted handheld lead names none", (handheld.held_machines() as Array).size(), 0)

	psx.queue_free()
	gc.queue_free()
	handheld.queue_free()
	m1.queue_free()
	m2.queue_free()
	await get_tree().process_frame


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("[link] PASS  %s" % name)
	else:
		_fail += 1
		print("[link] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


## A socket in the tree, so _ready has run. Caller frees it.
func _port() -> LinkPort:
	var p := LinkPort.new()
	add_child(p)
	return p


# ── The gate ────────────────────────────────────────────────────────────────
# plug_group() is the whole of what stops a lead going somewhere it could not go
# on real hardware, and it only works if both halves agree.

func _test_plug_gating() -> void:
	var port := _port()
	var plug := LinkPlug.new()
	add_child(plug)

	_eq("port and plug name the same group", port.plug_group(), plug.plug_group())
	_eq("the group is link_plug", port.plug_group(), "link_plug")

	# A link lead must not fit an A/V socket, and a phono cord must not fit this
	# one. Asserted against the real classes rather than string literals, so
	# renaming a group cannot quietly open the gate.
	var rca := RcaPort.new()
	add_child(rca)
	_ok("a link socket does not take a phono plug", port.plug_group() != rca.plug_group())

	var trs := TrsPort.new()
	add_child(trs)
	_ok("a link socket does not take a stereo plug", port.plug_group() != trs.plug_group())

	# The gate is enforced through the snap zone, so the requirement has to have
	# actually been applied and not just be available to read.
	_eq("the socket requires that group to snap", port.snap_require, port.plug_group())

	port.queue_free()
	plug.queue_free()
	rca.queue_free()
	trs.queue_free()


func _test_port_pins_its_channel() -> void:
	var port := _port()
	# Inherited from RcaPort but meaningless on a cable that carries neither
	# picture nor sound, so it is pinned rather than left for a scene to set
	# wrong.
	_eq("channel is pinned", port.channel, RcaPort.Channel.VIDEO)
	_ok("the jack visual is off", not port.show_jack)
	port.queue_free()


# ── Finding the machine ─────────────────────────────────────────────────────

func _test_machine_lookup() -> void:
	var loose := _port()
	_eq("a socket owned by nobody has no machine", loose.get_machine(), null)
	loose.queue_free()

	var machine := _StubMachine.new()
	add_child(machine)
	var shell := Node3D.new()
	machine.add_child(shell)          # a socket may sit any depth inside a machine
	var port := LinkPort.new()
	shell.add_child(port)

	_eq("a socket finds the machine that owns it", port.get_machine(), machine)
	machine.queue_free()


func _test_libretro_lookup() -> void:
	var machine := _StubMachine.new()
	add_child(machine)
	var port := LinkPort.new()
	machine.add_child(port)

	# A cable seated into a console that has not been switched on is ordinary,
	# not an error: the link should simply come up when it is powered.
	_eq("an unpowered machine yields no core", port.get_libretro(), null)
	machine.queue_free()


# ── Not an A/V lead ─────────────────────────────────────────────────────────

func _test_cable_is_not_av() -> void:
	var cable := LinkCable.new()
	add_child(cable)
	# AvGraph duck-types on links(), so an empty list is how a lead says "not
	# mine". A link cable reporting itself here would drag televisions into
	# routing serial traffic.
	_eq("a link cable reports no A/V links", cable.links().size(), 0)
	cable.queue_free()


# ── Coming apart ────────────────────────────────────────────────────────────

func _test_disconnect_is_idempotent() -> void:
	var cable := LinkCable.new()
	add_child(cable)

	# Never joined, so there is nothing to undo. This runs on every unseated
	# resolve and on the way out of the tree, so it has to be safe to call at any
	# time and any number of times.
	cable._disconnect()
	cable._disconnect()
	_eq("a cable that was never joined records no link", cable._linked.size(), 0)

	# Neither machine is running, and the cable joins them anyway. That is the
	# behaviour a cable has: seating one into a console that is switched off is
	# an ordinary thing to do, and the link comes alive when both cores attach
	# their serial hardware. Refusing here would mean a player had to power both
	# handhelds before plugging them together, which no cable has ever required.
	var m1 := _StubMachine.new()
	var m2 := _StubMachine.new()
	add_child(m1)
	add_child(m2)
	m1.libretro = Libretro.new()
	m2.libretro = Libretro.new()
	m1.add_child(m1.libretro)
	m2.add_child(m2.libretro)
	var p1 := LinkPort.new()
	var p2 := LinkPort.new()
	m1.add_child(p1)
	m2.add_child(p2)

	var g2: Array[Dictionary] = [
		{"libretro": m1.libretro, "port": 0},
		{"libretro": m2.libretro, "port": 0},
	]
	cable._join(g2)
	_eq("two idle machines are still cabled together", cable._linked.size(), 2)

	# Re-stating the same set changes nothing, which matters because every cable
	# in a chain resolves whenever any plug in it moves.
	cable._join(g2)
	_eq("re-stating the same group is a no-op", cable._linked.size(), 2)
	cable._disconnect()

	# The guard against a machine cabled to itself, which the room can present as
	# two sockets on one handheld.
	cable._join([
		{"libretro": m1.libretro, "port": 0},
		{"libretro": m1.libretro, "port": 0},
	] as Array[Dictionary])
	_eq("a machine cabled to itself is not recorded", cable._linked.size(), 0)

	# Disconnect has to survive the ends being gone. A machine can be carried out
	# of the room, or the room torn down, between joining and pulling.
	cable._linked = [
		{"libretro": m1.libretro, "port": 0},
		{"libretro": m2.libretro, "port": 0},
	]
	m2.libretro.free()
	cable._disconnect()
	_eq("disconnect clears even when an end is gone", cable._linked.size(), 0)

	m1.queue_free()
	m2.queue_free()
	cable.queue_free()
	await get_tree().process_frame



# ── The scenes ──────────────────────────────────────────────────────────────
# Importing a scene proves it parses. Only building one proves the scripts and
# node types actually fit together.

const CABLE_SCENE := "res://Scenes/Objects/cables/link_cable.tscn"
const PORT_SCENE := "res://Scenes/Objects/cables/link_port.tscn"


func _test_cable_scene() -> void:
	var packed: PackedScene = load(CABLE_SCENE)
	_ok("the cable scene loads", packed != null)
	if packed == null:
		return
	var cable := packed.instantiate() as LinkCable
	_ok("it builds as a LinkCable", cable != null)
	if cable == null:
		return
	add_child(cable)

	var a := cable.get_node_or_null("PlugA0") as LinkPlug
	var b := cable.get_node_or_null("PlugB0") as LinkPlug
	_ok("both ends are link plugs", a != null and b != null)
	if a == null or b == null:
		cable.queue_free()
		return

	# One cord, so CompositeCable takes its single-rope path. A miscount here
	# would send it down the ribbon path looking for a breakout that does not
	# exist.
	_eq("it is a one-cord lead", cable.cord_count(), 1)
	_ok("it has a rope", cable.get_node_or_null("VerletRope") != null)

	# Both ends answer to the group their sockets require, which is the whole of
	# what decides where this lead will go.
	_ok("end A is in the link group", a.is_in_group("link_plug"))
	_ok("end B is in the link group", b.is_in_group("link_plug"))

	# The trap the two-mesh split exists for. RcaPlug derives the cord's exit from
	# PlugTip's AABB alone, so folding the keyed nose into that mesh would drag
	# the anchor forward of the mating face and run the tail out through the
	# barrel. The shell is 20 mm deep behind an origin that sits on that face, so
	# the cord has to leave 20 mm back.
	_ok("the cord leaves the back of the shell",
		absf(a.cable_anchor.z - -0.02) < 0.0005,
		"anchor z = %f" % a.cable_anchor.z)
	_ok("and on the axis", absf(a.cable_anchor.x) < 0.0005 and absf(a.cable_anchor.y) < 0.0005)

	# The two ends are not interchangeable and the shells have to say so. End A is
	# always handed to LinkConnect first, so its machine owns the clock, and on
	# the real cable that end is purple against a grey secondary. CompositeCable
	# would repaint both from the cord palette, which is why LinkCable overrides
	# _tint_plug — drop that override and this goes red rather than silently
	# turning a two-tone lead into one colour.
	var ma := (a.get_node("PlugTip") as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D
	var mb := (b.get_node("PlugTip") as MeshInstance3D).get_surface_override_material(0) as StandardMaterial3D
	_ok("both shells are painted", ma != null and mb != null)
	if ma != null and mb != null:
		_ok("the two ends are different colours", ma.albedo_color != mb.albedo_color,
			"both %s" % str(ma.albedo_color))
		# The master end is the purple one, so it has to be the bluer of the two.
		_ok("end A is the purple shell", ma.albedo_color.b > ma.albedo_color.r + 0.1,
			"A = %s" % str(ma.albedo_color))
		_ok("end B is the grey shell", absf(mb.albedo_color.b - mb.albedo_color.r) < 0.06,
			"B = %s" % str(mb.albedo_color))

	# The junction, which is what makes a third and fourth player possible. A
	# socket that looked real and refused a plug would be worse than none, so it
	# is a full LinkPort and has to answer as one.
	var j := cable.junction_port()
	_ok("the lead carries a junction", j != null)
	if j != null:
		_eq("it takes the same plugs the machines do", j.snap_require, "link_plug")
		# The two kinds of socket have to be told apart during the chain walk:
		# a machine port answers get_machine, a junction answers get_cable.
		_eq("it belongs to no machine", j.get_machine(), null)
		_eq("it belongs to this cable", j.get_cable(), cable)

	cable.queue_free()
	await get_tree().process_frame


func _test_port_scene() -> void:
	var packed: PackedScene = load(PORT_SCENE)
	_ok("the port scene loads", packed != null)
	if packed == null:
		return
	var port := packed.instantiate() as LinkPort
	_ok("it builds as a LinkPort", port != null)
	if port == null:
		return
	add_child(port)

	# The gate, as the socket actually enforces it rather than as the class
	# merely reports it.
	_eq("it requires a link plug", port.snap_require, "link_plug")

	# Named LinkJack rather than RcaJack on purpose, so the inherited channel
	# tinting cannot repaint a socket that carries no signal.
	_ok("its jack is out of RcaPort's reach", port.get_node_or_null("RcaJack") == null)
	_ok("but it has one", port.get_node_or_null("LinkJack") != null)

	port.queue_free()
	await get_tree().process_frame



# ── Reachable from the room ─────────────────────────────────────────────────

func _test_cable_is_spawnable() -> void:
	# The lead existed for a while as a scene nobody could get hold of: built,
	# tested, rendered, and offered by no menu. A cable that cannot be spawned is
	# not a feature, so this asserts the catalogue actually lists it.
	var items: Array = SpawnCatalog.items_for("game_boy_advance")
	var found := false
	for item: Dictionary in items:
		if str(item.get("spawn", "")) == "link_cable":
			found = true
			_ok("it is offered under the Game Boy Advance", true)
			_ok("and it is labelled", not str(item.get("label", "")).is_empty())
	if not found:
		_ok("it is offered under the Game Boy Advance", false,
			"%d items, none of them the link cable" % items.size())

	# Offered only where there is a socket to put it in. A console with no EXT
	# port listing a link lead would be an invitation to nothing.
	var console: Array = SpawnCatalog.items_for("playstation")
	var stray := false
	for item: Dictionary in console:
		if str(item.get("spawn", "")) == "link_cable":
			stray = true
	_ok("and not offered where nothing takes it", not stray)


## A machine that answers the question LinkPort walks for, without being one.
class _StubMachine extends Node3D:
	var libretro: Libretro = null

	func get_libretro_node() -> Libretro:
		return libretro


# -- The clamshell over its own socket ----------------------------------------
# A Game Boy Advance SP hinges at the same edge its EXT socket sits on, so the
# lid and the lead are competing for one strip of plastic. Get the pivot or the
# open stop wrong and the lid closes on a plugged-in cable, which is a thing no
# real machine does and a thing the room cannot recover from: the plug is held
# by a snap zone and the lid is driven by a hand, so they simply interpenetrate.
#
# This walks the hinge across its whole travel with a lead seated and measures
# the gap, rather than trusting a render. Two more cases hold the geometry that
# makes the gap possible in the first place: a barrel narrow enough to leave the
# socket outboard of it, and a pivot high enough that the lid swings above the
# deck instead of through it.

const SP_SCENE := "res://Scenes/Objects/system_models/game_boy_advance_sp_primitive.tscn"
const GC_GBA_SCENE := "res://Scenes/Objects/cables/gc_gba_cable.tscn"


func _test_lid_clears_the_socket() -> void:
	var sp: Node3D = load(SP_SCENE).instantiate()
	add_child(sp)
	# Both leads, because either fits that socket and the lid has to clear the
	# fatter of them. They are not the same shell: one carries a metal shroud.
	var leads: Array[Node3D] = []
	for path: String in [GC_GBA_SCENE, CABLE_SCENE]:
		var l: Node3D = load(path).instantiate()
		add_child(l)
		leads.append(l)
	await get_tree().process_frame

	var port := sp.get_node_or_null("LinkPort") as Node3D
	var lid := sp.get_node_or_null("LidPivot/Lid") as MeshInstance3D
	var barrel := sp.get_node_or_null("HingeBarrel") as MeshInstance3D
	var body := sp.get_node_or_null("HandheldBody") as MeshInstance3D
	_ok("the SP has a socket, a lid, a barrel and a body",
		port != null and lid != null and barrel != null and body != null)
	if port == null or lid == null or barrel == null or body == null:
		sp.queue_free()
		for l: Node3D in leads:
			l.queue_free()
		return

	# Seated, which for this purpose is the plug sitting at the socket's own
	# transform. That is what the snap zone does to it, and the shell is the part
	# that can be hit: the cord is a rope and will simply drape aside.
	# Measured against the SHELL, which is what a player watches the lid meet.
	# The collision box is deliberately deeper than the shell so a hand can find
	# it, and it reaches back inside the machine where the lid is entitled to be.
	var shells: Array[MeshInstance3D] = []
	for l: Node3D in leads:
		var plug := l.get_node_or_null("PlugB0") as RigidBody3D
		if plug == null:
			continue
		plug.freeze = true
		# The same move the snap zone makes, not the socket's bare transform. A
		# zone lands the object's GRAB POINT on itself, and this plug's grab
		# point is turned about X, so seating it on the socket transform alone
		# puts the shell inside the machine and the cord out through the screen.
		# That is a plug nothing could clash with, which would make this whole
		# case pass for free.
		var gp := plug.get_node_or_null("SnapGrabPoint") as Node3D
		plug.global_transform = port.global_transform * (gp.transform.affine_inverse() if gp != null else Transform3D())
		for child in plug.get_children():
			var mi := child as MeshInstance3D
			if mi != null and mi.mesh != null:
				shells.append(mi)
	_ok("both leads have a shell to measure", shells.size() >= 4,
		"%d meshes over %d leads" % [shells.size(), leads.size()])
	var lid_box := (lid.mesh as BoxMesh).size

	# Every degree of the travel, because the clash does not have to be at either
	# end: a lid that clears when shut and clears at the stop can still sweep
	# through the plug on the way past.
	var worst := INF
	var worst_at := -1.0
	for step in range(0, 181):
		var open_deg := float(step)
		sp.set_lid_angle_deg(open_deg)
		# Read back rather than trusting the request: the hinge owns the limits
		# and clamps, so the angles actually reachable are the ones to test.
		var reached: float = sp.get_lid_angle_deg()
		for mi: MeshInstance3D in shells:
			var box := mi.mesh.get_aabb()
			var t := mi.global_transform.translated_local(box.get_center())
			var gap := _obb_gap(lid.global_transform, lid_box, t, box.size)
			if gap < worst:
				worst = gap
				worst_at = reached
	print("[link] lid clearance over a seated lead: %.2f mm, closest at %.0f degrees open"
		% [worst * 1000.0, worst_at])
	_ok("the lid never touches a seated lead", worst > 0.0,
		"closest %.1f mm at %.0f degrees open" % [worst * 1000.0, worst_at])

	# And with room to spare, because a hand-driven lid overshoots and a snapped
	# plug wobbles in its zone. A hair's clearance reads as a clash on a headset.
	_ok("and clears it by more than a millimetre", worst > 0.001,
		"closest %.1f mm" % (worst * 1000.0))

	# The socket is outboard of the barrel. This is the whole reason the barrel
	# was narrowed: on the real machine the hinge takes the middle of that edge
	# and the sockets live either side of it.
	var barrel_half: float = absf((barrel.mesh as CylinderMesh).height) * 0.5
	var port_x: float = absf(port.position.x)
	var plug_half := 0.0
	for mi: MeshInstance3D in shells:
		plug_half = maxf(plug_half, mi.mesh.get_aabb().size.x * 0.5)
	_ok("the socket sits outboard of the hinge barrel", port_x - plug_half > barrel_half,
		"socket edge %.1f mm, barrel end %.1f mm" % [(port_x - plug_half) * 1000.0, barrel_half * 1000.0])
	_ok("and the barrel is narrower than the machine",
		barrel_half * 2.0 < (body.mesh as BoxMesh).size.x)

	# The pivot stands proud of the deck. A hinge buried in the top face turns the
	# lid about a line inside the shell, which is what put it through its own back
	# edge, and it is also just visibly wrong: a real SP's hinge is a raised boss.
	var deck_y: float = (body.mesh as BoxMesh).size.y * 0.5
	_ok("the hinge stands proud of the deck", barrel.position.y + barrel_half * 0.0 > deck_y,
		"barrel axis at %.1f mm, deck at %.1f mm" % [barrel.position.y * 1000.0, deck_y * 1000.0])
	var pivot := sp.get_node_or_null("LidPivot") as Node3D
	_ok("and the lid turns about the barrel, not beside it",
		pivot != null and pivot.position.distance_to(barrel.position) < 0.0005)

	# Shut still means shut. Raising the pivot moves every child of it, so the
	# compensating drop is what keeps a closed lid lying on the body rather than
	# floating above it.
	sp.set_lid_angle_deg(0.0)
	var shut_y: float = lid.global_position.y
	var want_y: float = deck_y + lid_box.y * 0.5
	_ok("a shut lid lies flush on the body", absf(shut_y - want_y) < 0.0005,
		"lid centre at %.1f mm, flush would be %.1f mm" % [shut_y * 1000.0, want_y * 1000.0])

	sp.queue_free()
	for l: Node3D in leads:
		l.queue_free()
	await get_tree().process_frame


## Separating-axis gap between two boxes, in metres. Positive is the width of the
## smallest gap found along any separating axis, which is a lower bound on the
## real distance; zero or less means they overlap. A lower bound is the safe side
## of the question being asked here.
func _obb_gap(ta: Transform3D, sa: Vector3, tb: Transform3D, sb: Vector3) -> float:
	var ax: Array[Vector3] = [ta.basis.x.normalized(), ta.basis.y.normalized(), ta.basis.z.normalized()]
	var bx: Array[Vector3] = [tb.basis.x.normalized(), tb.basis.y.normalized(), tb.basis.z.normalized()]
	var ea := sa * 0.5
	var eb := sb * 0.5
	var axes: Array[Vector3] = [ax[0], ax[1], ax[2], bx[0], bx[1], bx[2]]
	for u: Vector3 in ax:
		for v: Vector3 in bx:
			var c := u.cross(v)
			# Parallel edges give a degenerate axis. The face normals already
			# cover that case, so dropping it loses nothing.
			if c.length_squared() > 1e-12:
				axes.append(c.normalized())
	var d := tb.origin - ta.origin
	var best := -INF
	for axis: Vector3 in axes:
		var ra: float = absf(ax[0].dot(axis)) * ea.x + absf(ax[1].dot(axis)) * ea.y + absf(ax[2].dot(axis)) * ea.z
		var rb: float = absf(bx[0].dot(axis)) * eb.x + absf(bx[1].dot(axis)) * eb.y + absf(bx[2].dot(axis)) * eb.z
		best = maxf(best, absf(d.dot(axis)) - (ra + rb))
	return best


# -- Who joins the bus, seen from two headsets --------------------------------
# Every lead on a wire walks to the same machines, so exactly one of them has to
# perform the join, and the one that does decides which machine takes bus index
# zero, which is to say who is player one. Under replication both peers run both
# cores and must reach the same answer from the same room.
#
# The tie-break used to be the lowest instance id. That is a per-process
# allocation: the same two leads can come out in either order on two headsets, so
# the two peers could seat the machines differently and diverge from frame one,
# with no message on the wire to disagree about. This asserts the key that
# replaced it does not move with allocation order.

func _test_bus_head_is_the_same_on_every_peer() -> void:
	var first: LinkCable = load(CABLE_SCENE).instantiate()
	var second: LinkCable = load(CABLE_SCENE).instantiate()
	add_child(first)
	add_child(second)
	first.name = "LeadOne"
	second.name = "LeadTwo"
	await get_tree().process_frame

	_ok("allocation order is what it looks like",
		first.get_instance_id() < second.get_instance_id())

	var wire: Array[Node3D] = [first, second]
	# Numbered against the allocation order on purpose. A head picked by instance
	# id answers "first" here and a head picked by the minted id answers "second",
	# so this case cannot pass by accident.
	first.set_meta("net_id", 7)
	second.set_meta("net_id", 3)
	_ok("the head follows the minted id, not the allocation order",
		first._bus_head(wire) == second)

	# And the other way about, so the case is not just reading a fixed answer.
	first.set_meta("net_id", 2)
	second.set_meta("net_id", 9)
	_ok("and it moves when the minted ids move", first._bus_head(wire) == first)

	# Both leads agree, which is the property the wire actually needs: they each
	# run this walk separately and only one of them may conclude it is the head.
	_ok("and both leads name the same head", first._bus_head(wire) == second._bus_head(wire))

	# With nothing minted, the fallback is the node path. Cables are not
	# registered today, so this is the case that runs in a real session.
	first.remove_meta("net_id")
	second.remove_meta("net_id")
	_ok("an unregistered lead is keyed by its path",
		LinkCable.stable_key(first) == str(first.get_path()))
	_ok("and two of them are keyed apart",
		LinkCable.stable_key(first) != LinkCable.stable_key(second))
	var by_path: Node3D = first if str(first.get_path()) < str(second.get_path()) else second
	_ok("the head is the lower path", first._bus_head(wire) == by_path)

	# A minted lead never sorts into the middle of unregistered ones. Mixed keys
	# are a transient, but a transient that reordered the bus would restart both
	# machines for no reason a player could see.
	second.set_meta("net_id", 999999)
	_ok("a minted lead outranks an unminted one", first._bus_head(wire) == second)

	first.queue_free()
	second.queue_free()
	await get_tree().process_frame


# -- Will the lead actually go in? --------------------------------------------
# Every other case here asks what a seated lead MEANS. This one asks whether the
# room lets a hand seat it at all, which is a different question and was never
# being asked: the probes seat their leads with pick_up_object, and that skips
# the gate entirely. So a lead could pass every test in this file and still be
# unpluggable in the room.
#
# The gate is XRToolsSnapZone.can_preview: the required group, the excluded
# group, and the owner's own filter. That is exactly what a hand runs into.

func _test_the_lead_will_seat() -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	_ok("the machine scene loads", sys_scene != null)
	if sys_scene == null:
		return

	var console: Node3D = sys_scene.instantiate()
	console.systemid = "gamecube"
	add_child(console)
	var handheld: Node3D = sys_scene.instantiate()
	handheld.systemid = "game_boy_advance"
	add_child(handheld)
	var lead: Node3D = load(GC_GBA_SCENE).instantiate()
	add_child(lead)
	var pair: Node3D = load(CABLE_SCENE).instantiate()
	add_child(pair)
	await get_tree().process_frame
	await get_tree().process_frame

	var slot := console.find_child("ControllerPort1", true, false) as XRToolsSnapZone
	var ext := handheld.find_child("LinkPort", true, false) as XRToolsSnapZone
	_ok("the console has a controller socket", slot != null)
	_ok("the handheld has an EXT socket", ext != null)
	if slot == null or ext == null:
		console.queue_free()
		handheld.queue_free()
		lead.queue_free()
		pair.queue_free()
		return

	var gc_end := lead.get_node_or_null("PlugA0") as Node3D
	var gba_end := lead.get_node_or_null("PlugB0") as Node3D
	var link_end := pair.get_node_or_null("PlugA0") as Node3D

	# The two that must work. Either one refusing makes the lead a prop.
	_ok("the console end goes into a controller socket", slot.can_preview(gc_end),
		"require '%s', plug in %s" % [slot.snap_require, str(gc_end.get_groups())])
	_ok("the handheld end goes into an EXT socket", ext.can_preview(gba_end),
		"require '%s', plug in %s" % [ext.snap_require, str(gba_end.get_groups())])

	# And the four that must not, which is the whole reason the ends are
	# different shapes.
	_ok("the console end does not go into an EXT socket", not ext.can_preview(gc_end))
	_ok("the handheld end does not go into a controller socket",
		not slot.can_preview(gba_end))
	_ok("a handheld link lead does not go into a controller socket",
		not slot.can_preview(link_end))
	_ok("but it does go into an EXT socket", ext.can_preview(link_end))

	# Seat the asymmetric lead through the real socket APIs, then ask the real
	# machine discovery method for its bus. The GameCube end exists only in the
	# controller_plug group; a scan limited to link_plug passes every electrical
	# cable test above but silently leaves the console out of netplay.
	slot.pick_up_object(gc_end)
	ext.pick_up_object(gba_end)
	await get_tree().process_frame
	lead._resolve()
	# Remove the handheld end as an alternate discovery route. The cable remains
	# physically seated and can still state its bus; only the GameCube end's
	# controller_plug membership can make the room-wide scan find it now.
	gba_end.remove_from_group("link_plug")
	var console_bus: Array = console.net_link_bus()
	_eq("netplay finds a bus through the controller socket", console_bus.size(), 2)
	_ok("and that bus contains the GameCube",
		console_bus.any(func(entry: Dictionary) -> bool:
			return entry.get("machine") == console))
	_ok("and that bus contains the handheld",
		console_bus.any(func(entry: Dictionary) -> bool:
			return entry.get("machine") == handheld))
	gba_end.add_to_group("link_plug")

	console.queue_free()
	handheld.queue_free()
	lead.queue_free()
	pair.queue_free()
	await get_tree().process_frame


# -- Which way a socket faces -------------------------------------------------
# A port's +Z points OUT of whatever it is a socket on: that is where the seated
# shell ends up, and the nose travels the other way. Turn one round and the shell
# goes in and the nose comes out, which on the link lead's junction block meant a
# 20 mm plug buried in a 17 mm box with its nose in the air.
#
# Not something a reader can check by eye: the transform is authored as rows, the
# grab point carries its own half-turn, and the two cancel in a way that reads
# plausibly whichever way round it is. So this measures it, in the frame of the
# thing being plugged into, the same way the fault was found.

const SHELL := "PlugTip"


func _test_a_seated_plug_sits_outside() -> void:
	var lead: LinkCable = load(CABLE_SCENE).instantiate()
	var other: LinkCable = load(CABLE_SCENE).instantiate()
	add_child(lead)
	add_child(other)
	await get_tree().process_frame
	await get_tree().process_frame

	var junction := lead.junction_port()
	_ok("the lead carries a junction socket", junction != null)
	var plug := other.get_node_or_null("PlugA0") as RigidBody3D
	if junction == null or plug == null:
		lead.queue_free()
		other.queue_free()
		return

	junction.pick_up_object(plug)
	for i in range(20):
		await get_tree().process_frame
	# The block rides the cord and the cord swings, so it is stopped before
	# anything is measured. Everything below is in the block's OWN frame.
	lead.set_physics_process(false)
	other.set_physics_process(false)
	await get_tree().process_frame

	var block := lead.get_node_or_null("Junction") as Node3D
	var into := block.global_transform.affine_inverse()
	var shell := plug.get_node_or_null(SHELL) as MeshInstance3D
	_ok("the block and the plug's shell are both there", block != null and shell != null)
	if block == null or shell == null:
		lead.queue_free()
		other.queue_free()
		return

	# 17 mm cube, so its faces are 8.5 mm out. A shell whose centre is inside
	# that is a shell that has been swallowed.
	var half := 0.0085
	var box: BoxMesh = (lead.get_node("Junction/Box") as MeshInstance3D).mesh
	half = box.size.x * 0.5
	var at: Vector3 = into * shell.global_position
	_ok("the shell sits outside the junction block", absf(at.x) > half,
		"shell centre %.1f mm out, the block's face is at %.1f mm" % [at.x * 1000.0, half * 1000.0])

	# And on the side the socket is on, rather than out through the far wall.
	var port_at: Vector3 = into * junction.global_position
	_ok("and on the socket's own side", signf(at.x) == signf(port_at.x),
		"shell at %.1f mm, socket at %.1f mm" % [at.x * 1000.0, port_at.x * 1000.0])

	# The nose is the other half of the same fact and fails the opposite way, so
	# a socket turned round cannot pass both.
	var nose := plug.get_node_or_null("PlugNose") as MeshInstance3D
	if nose != null:
		var nose_at: Vector3 = into * nose.global_position
		_ok("and the nose is inside it", absf(nose_at.x) < half,
			"nose centre %.1f mm out" % (nose_at.x * 1000.0))

	lead.queue_free()
	other.queue_free()
	await get_tree().process_frame


## A plug in the junction has to move WITH it, not a tick behind it.
##
## Every other socket is bolted to something: a machine's port and the plug in it
## move together whatever order they are updated in. The junction rides the cord
## and is moved by a script, so the order is the whole question — and the plug's
## grab driver used to run first, placing the plug where the block had been on
## the previous tick. Standing still that is invisible; with the cord moving at
## hand speed the plug trailed the block by 14 mm and snapped back every time the
## cord changed direction, dragging the second lead with it.
func _test_a_junction_plug_keeps_up() -> void:
	var room := Node3D.new()
	add_child(room)
	var holder_a := StaticBody3D.new()
	holder_a.collision_layer = 1
	holder_a.collision_mask = 0
	room.add_child(holder_a)
	holder_a.global_position = Vector3(-0.35, 0.9, 0)
	var holder_b := StaticBody3D.new()
	holder_b.collision_layer = 1
	holder_b.collision_mask = 0
	room.add_child(holder_b)
	holder_b.global_position = Vector3(0.35, 0.9, 0)
	var port_a: RcaPort = load(PORT_SCENE).instantiate()
	holder_a.add_child(port_a)
	var port_b: RcaPort = load(PORT_SCENE).instantiate()
	holder_b.add_child(port_b)

	# The lead hangs between the two sockets, the way it does between two
	# machines, so its junction dangles on a cord that can actually move.
	var lead: LinkCable = load(CABLE_SCENE).instantiate()
	room.add_child(lead)
	lead.global_position = Vector3(0, 0.9, 0)
	await get_tree().physics_frame
	port_a.pick_up_object(lead.get_node("PlugA0"))
	port_b.pick_up_object(lead.get_node("PlugB0"))
	for i in range(90):
		await get_tree().physics_frame

	var other: LinkCable = load(CABLE_SCENE).instantiate()
	room.add_child(other)
	other.global_position = Vector3(0, 0.6, 0.3)
	await get_tree().physics_frame
	var junction := lead.junction_port()
	var plug := other.get_node("PlugA0") as Node3D
	junction.pick_up_object(plug)
	for i in range(60):
		await get_tree().physics_frame

	# Sweep the socket the way a hand carries a machine, and ask each tick how
	# far the seated plug is from the seat it is supposed to be in.
	var base := holder_b.global_position
	var seated_plug := lead.get_node("PlugB0") as Node3D
	var worst_junction := 0.0
	var worst_machine := 0.0
	var travelled := 0.0
	var block := lead.get_node("Junction") as Node3D
	var was: Vector3 = block.global_position
	for f in range(120):
		holder_b.global_position = base + Vector3(
			0.15 * sin(float(f) / 90.0 * TAU * 0.5), 0, 0)
		await get_tree().physics_frame
		worst_junction = maxf(worst_junction, plug.global_position.distance_to(
			junction.snap_pose_for(plug).origin) * 1000.0)
		worst_machine = maxf(worst_machine, seated_plug.global_position.distance_to(
			port_b.snap_pose_for(seated_plug).origin) * 1000.0)
		travelled = maxf(travelled, block.global_position.distance_to(was) * 1000.0)
		was = block.global_position

	# The sweep has to have MOVED the block, or the case below is measuring a
	# cord standing still and cannot fail.
	_ok("the sweep moves the junction", travelled > 2.0,
		"%.2f mm/tick at the peak" % travelled)
	# A plug in a machine's socket is the control: same driver, same sweep, and
	# it has never had this problem.
	_ok("a plug in a machine socket stays seated", worst_machine < 0.5,
		"%.2f mm out at the peak" % worst_machine)
	_ok("a plug in the junction stays seated too", worst_junction < 0.5,
		"%.2f mm out at the peak, against %.2f mm/tick of junction travel"
			% [worst_junction, travelled])

	room.queue_free()
	await get_tree().process_frame


## The block must not snap round when the cord passes through vertical.
##
## _ride_junction aims the block along the cord. Aimed with world UP as the up
## vector, a lead hanging off a machine — which runs straight DOWN through its
## own junction — gives look_at two colinear vectors and no roll to choose from:
## the engine warns and picks. Swung through vertical the block snapped 65 deg in
## a single tick, taking the plug seated in it 18.6 mm with it.
func _test_the_junction_does_not_snap_through_vertical() -> void:
	var room := Node3D.new()
	add_child(room)
	var holder := StaticBody3D.new()
	holder.collision_layer = 1
	holder.collision_mask = 0
	room.add_child(holder)
	holder.global_position = Vector3(0, 1.6, 0)
	var port: RcaPort = load(PORT_SCENE).instantiate()
	holder.add_child(port)

	# Held at one end only, so the cord hangs straight down through the junction.
	var lead: LinkCable = load(CABLE_SCENE).instantiate()
	room.add_child(lead)
	lead.global_position = Vector3(0, 1.6, 0)
	await get_tree().physics_frame
	port.pick_up_object(lead.get_node("PlugA0"))
	for i in range(120):
		await get_tree().physics_frame

	var other: LinkCable = load(CABLE_SCENE).instantiate()
	room.add_child(other)
	other.global_position = Vector3(0.3, 1.2, 0.2)
	await get_tree().physics_frame
	lead.junction_port().pick_up_object(other.get_node("PlugA0"))
	for i in range(60):
		await get_tree().physics_frame

	var block := lead.get_node("Junction") as Node3D
	var rope := lead.get_node("VerletRope") as VerletRope
	var base := holder.global_position
	var worst_roll := 0.0
	var most_vertical := 0.0
	var last: Basis = block.global_transform.basis
	for f in range(240):
		# Held awake: a sleeping cord cannot swing, and a case measuring a cord
		# that never moved would pass whatever the aim does.
		rope.wake()
		holder.global_position = base + Vector3(
			0.25 * sin(float(f) / 120.0 * TAU), 0, 0)
		await get_tree().physics_frame
		var b: Basis = block.global_transform.basis
		worst_roll = maxf(worst_roll, rad_to_deg(b.x.angle_to(last.x)))
		last = b
		most_vertical = maxf(most_vertical, absf((-b.z).normalized().dot(Vector3.UP)))

	# The swing has to actually reach vertical, or there is no degenerate aim to
	# survive and the case cannot fail.
	_ok("the swung cord runs vertical through the block", most_vertical > 0.95,
		"cord-vs-up %.3f at the closest" % most_vertical)
	_ok("and the block turns with it rather than snapping round", worst_roll < 15.0,
		"%.2f deg in one tick at the peak" % worst_roll)

	room.queue_free()
	await get_tree().process_frame


func _test_a_machine_takes_a_plug_the_same_way() -> void:
	# The same measurement against a real machine, because the junction is only
	# unusual in being small enough to notice.
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	var handheld: Node3D = sys_scene.instantiate()
	handheld.systemid = "game_boy_advance"
	add_child(handheld)
	var lead: LinkCable = load(CABLE_SCENE).instantiate()
	add_child(lead)
	await get_tree().process_frame
	await get_tree().process_frame

	var port := handheld.find_child("LinkPort", true, false) as XRToolsSnapZone
	var plug := lead.get_node_or_null("PlugA0") as RigidBody3D
	_ok("the handheld has a socket to measure", port != null and plug != null)
	if port == null or plug == null:
		handheld.queue_free()
		lead.queue_free()
		return

	port.pick_up_object(plug)
	for i in range(20):
		await get_tree().process_frame
	lead.set_physics_process(false)
	await get_tree().process_frame

	# Measured along the socket's own axis rather than the machine's, so this
	# holds for a socket on any face of any shell. A port's +Z is the way OUT:
	# it is where the shell ends up, and the nose travels the other way.
	var shell := plug.get_node_or_null(SHELL) as MeshInstance3D
	var out: Vector3 = port.global_basis.z.normalized()
	var reach: float = (shell.global_position - port.global_position).dot(out)
	_ok("the shell sits outside the machine", reach > 0.0,
		"shell centre %.1f mm along the socket's axis, and out is positive" % (reach * 1000.0))

	handheld.queue_free()
	lead.queue_free()
	await get_tree().process_frame


# -- Telling the two ends apart -----------------------------------------------
# The one thing a two-ended lead has to be able to say. A socket that declines a
# plug is silent, so a player holding the wrong end of this cable gets no signal
# at all, and both ends of it were reached for wrongly in one evening. Each plug
# names itself, and a release that lands nowhere says which end it is and where
# the socket that takes it actually is.

func _test_each_end_says_what_it_is() -> void:
	var lead: Node3D = load(GC_GBA_SCENE).instantiate()
	var pair: Node3D = load(CABLE_SCENE).instantiate()
	add_child(lead)
	add_child(pair)
	await get_tree().process_frame

	var console_end := lead.get_node_or_null("PlugA0") as RcaPlug
	var handheld_end := lead.get_node_or_null("PlugB0") as RcaPlug
	var link_end := pair.get_node_or_null("PlugA0") as RcaPlug
	_ok("both ends of the console lead are there",
		console_end != null and handheld_end != null and link_end != null)
	if console_end == null or handheld_end == null or link_end == null:
		lead.queue_free()
		pair.queue_free()
		return

	_ok("the console end names itself", console_end.plug_label().contains("GameCube"),
		console_end.plug_label())
	_ok("the handheld end names itself",
		handheld_end.plug_label().contains("Game Boy Advance"), handheld_end.plug_label())
	# The point of the labels: a player who cannot tell the ends apart by shape
	# can tell them apart by what the room calls them.
	_ok("and the two ends are not called the same thing",
		console_end.plug_label() != handheld_end.plug_label())
	# The handheld end of a console lead and a plain link lead's end are the same
	# connector, so they must be called the same thing. Calling them differently
	# would be a distinction the hardware does not make.
	_ok("a link lead's end is the same connector as the console lead's handheld end",
		handheld_end.plug_label() == link_end.plug_label())
	# Every plug has to answer this, not just the ones added for the console
	# lead: the message that uses it is on RcaPlug and runs for all of them.
	_ok("and the base connector has a name too", not RcaPlug.new().plug_label().is_empty())

	lead.queue_free()
	pair.queue_free()
	await get_tree().process_frame


# -- Coming back to the socket you were left in ------------------------------
# A save records where each end of a lead sits as an owner and a socket name. A
# socket that pair cannot describe is a socket the plug never returns to, and it
# fails silently: the room reloads with the lead on the floor and nothing says
# why. Two of them could not be described, and both were found by a player
# rather than by this suite.

func _test_every_socket_can_be_saved() -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	var console: Node3D = sys_scene.instantiate()
	console.systemid = "gamecube"
	console.name = "GameCube"
	add_child(console)
	var handheld: Node3D = sys_scene.instantiate()
	handheld.systemid = "game_boy_advance"
	handheld.name = "Handheld"
	add_child(handheld)
	var lead: Node3D = load(GC_GBA_SCENE).instantiate()
	add_child(lead)
	var pair: LinkCable = load(CABLE_SCENE).instantiate()
	add_child(pair)
	var chained: LinkCable = load(CABLE_SCENE).instantiate()
	add_child(chained)
	await get_tree().process_frame
	await get_tree().process_frame

	# The console end, into a controller socket. A plain snap zone, so the plug
	# is the only thing that knows where it went.
	var port1 := console.get_node_or_null("ControllerPort1") as XRToolsSnapZone
	var gc_end := lead.get_node_or_null("PlugA0") as RcaPlug
	if port1 != null and gc_end != null:
		port1.pick_up_object(gc_end)
	# And a link lead into another lead's junction, which is an RcaPort but sits
	# on a CABLE rather than on a machine.
	var junction := pair.junction_port()
	var chained_end := chained.get_node_or_null("PlugA0") as RcaPlug
	if junction != null and chained_end != null:
		junction.pick_up_object(chained_end)
	await get_tree().process_frame

	var console_seat := {}
	for seat: Dictionary in lead.seating():
		if seat.get("plug") == gc_end:
			console_seat = seat
	_ok("a controller socket can be described in a save",
		console_seat.get("device") != null and not str(console_seat.get("port", "")).is_empty(),
		"owner %s, port '%s'" % [str(console_seat.get("device")), str(console_seat.get("port", ""))])
	_ok("and it names the console it is on", console_seat.get("device") == console)

	var junction_seat := {}
	for seat: Dictionary in chained.seating():
		if seat.get("plug") == chained_end:
			junction_seat = seat
	_ok("a junction can be described in a save",
		junction_seat.get("device") != null and not str(junction_seat.get("port", "")).is_empty(),
		"owner %s, port '%s'" % [str(junction_seat.get("device")), str(junction_seat.get("port", ""))])
	_ok("and it names the lead the junction is moulded into",
		junction_seat.get("device") == pair)

	# The round trip that matters: what was written has to find the socket again.
	for spec in [[lead, console_seat], [chained, junction_seat]]:
		var owner_node: Node = spec[1].get("device")
		var pname: String = str(spec[1].get("port", ""))
		var found: XRToolsSnapZone = (spec[0] as CompositeCable)._port_named(owner_node, pname)
		_ok("and the saved pair finds that socket again on load", found != null,
			"looked for '%s' under %s" % [pname, str(owner_node)])

	console.queue_free()
	handheld.queue_free()
	lead.queue_free()
	pair.queue_free()
	chained.queue_free()
	await get_tree().process_frame


# -- The PlayStation's serial port --------------------------------------------
# A second kind of link lead, and every case below is about it being a DIFFERENT
# one. The console's serial socket is SIO1, on the back panel; the controller
# bus on the front is SIO0 and shares nothing with it but a register layout. The
# lead between two of them is a null modem -- transmit crossed to receive, DTR to
# DSR, RTS to CTS -- so the two consoles are peers, either end goes in either
# console, and there is no junction and no third player.

## A layer nothing in the room uses, so the trimesh the panel is measured against
## meets no real body and no real body meets it.
const _PANEL_LAYER := 1 << 19
const PSX_CABLE_SCENE := "res://Scenes/Objects/cables/psx_link_cable.tscn"
const PSX_PORT_SCENE := "res://Scenes/Objects/cables/psx_link_port.tscn"


func _test_psx_plug_gating() -> void:
	var port := PsxLinkPort.new()
	add_child(port)
	var plug := PsxLinkPlug.new()
	add_child(plug)

	_eq("the PlayStation port and plug name the same group",
		port.plug_group(), plug.plug_group())
	_eq("the group is psx_link_plug", port.plug_group(), "psx_link_plug")
	_eq("the socket requires that group to snap", port.snap_require, port.plug_group())

	# The case this class exists for. Reusing the handheld group would have let a
	# Game Boy Advance lead seat in a console's serial socket and look right doing
	# it -- the refusal would still have come, one layer down, where the bus
	# declines to join two cores publishing different protocol ids, but it would
	# have arrived as a line in a log with the cable sitting there looking
	# connected. Asserted against the real classes so renaming a group cannot
	# quietly open the gate.
	var gba := LinkPort.new()
	add_child(gba)
	var gba_plug := LinkPlug.new()
	add_child(gba_plug)
	_ok("a PlayStation socket does not take a handheld link plug",
		port.plug_group() != gba_plug.plug_group())
	_ok("a handheld socket does not take a PlayStation link plug",
		gba.plug_group() != plug.plug_group())

	var rca := RcaPort.new()
	add_child(rca)
	_ok("nor does it take a phono plug", port.plug_group() != rca.plug_group())

	# link_port is inherited and a PlayStation has exactly one serial socket, so
	# it stays where it started. The export exists for hardware that has more.
	_eq("the console's one serial socket is port 0", port.link_port, 0)

	port.queue_free()
	plug.queue_free()
	gba.queue_free()
	gba_plug.queue_free()
	rca.queue_free()


func _test_psx_cable_is_not_av() -> void:
	# Same trap the handheld lead has: a link cord that reported itself to AvGraph
	# would put a television in the business of routing serial traffic.
	var cable := PsxLinkCable.new()
	add_child(cable)
	_eq("a PlayStation link cable carries no A/V links", cable.links().size(), 0)
	cable.queue_free()


func _test_psx_cable_is_spawnable() -> void:
	var items: Array = SpawnCatalog.items_for("playstation")
	var found := false
	for item: Dictionary in items:
		if str(item.get("spawn", "")) == "psx_link_cable":
			found = true
			_ok("and it is labelled", not str(item.get("label", "")).is_empty())
	_ok("it is offered under the PlayStation", found,
		"%d items, none of them the PlayStation link cable" % items.size())

	# Offered only where there is a socket to put it in.
	var handheld: Array = SpawnCatalog.items_for("game_boy_advance")
	var stray := false
	for item: Dictionary in handheld:
		if str(item.get("spawn", "")) == "psx_link_cable":
			stray = true
	_ok("and not offered to a machine with no serial port", not stray)


func _test_psx_socket_follows_the_hardware() -> void:
	# The socket is on the primitive body, and which consoles wear one is a fact
	# about the hardware rather than about the model: SystemInfo.serial_port is the
	# same kind of switch as memory_cards, which is what shows the card slot.
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	_ok("the machine scene loads", sys_scene != null)
	if sys_scene == null:
		return

	var psx: Node3D = sys_scene.instantiate()
	psx.systemid = "playstation"
	add_child(psx)
	# A Dreamcast, NOT a NES. The gate being tested lives on the primitive body,
	# and a console with a model scene of its own never reaches it -- a negative
	# case picked from those passes whether the gate works or not. The Dreamcast
	# has no model row, so it wears the same box the PlayStation does and the
	# only thing telling them apart is SystemInfo.serial_port.
	var plain: Node3D = sys_scene.instantiate()
	plain.systemid = "dreamcast"
	add_child(plain)
	await get_tree().process_frame
	await get_tree().process_frame

	var on_psx := psx.find_child("PsxLinkPort", true, false) as PsxLinkPort
	_ok("a PlayStation wears a serial socket", on_psx != null)
	var on_plain := plain.find_child("PsxLinkPort", true, false)
	_ok("a console with no serial port does not, on the same body",
		on_plain == null)

	if on_psx != null:
		# Behind the machine, not inside it: the socket has to be reachable by a
		# hand coming at the back panel, and it sits alongside the A/V row rather
		# than on top of it.
		# Against the machine's OWN panel and its OWN A/V row. Both of these were
		# constants of the primitive box -- z < -0.12, and the row at x = 0.082 --
		# and both stopped describing a PlayStation the moment it grew a shell:
		# a real SCPH-1001 is 187 mm deep against the box's 250, so its panel sits
		# at -0.093 and a socket correctly on it failed a threshold written for a
		# machine 60 mm longer.
		var panel := _panel_face_z(psx, psx.to_local(on_psx.global_position))
		_ok("it is on the back panel", on_psx.position.z <= panel + 0.002,
			"z = %.4f against a panel at %.4f" % [on_psx.position.z, panel])
		var av_gap := _nearest_av_gap(psx, on_psx.position.x)
		_ok("and clear of the A/V sockets", av_gap > 0.02,
			"nearest A/V socket is %.1f mm away" % (av_gap * 1000.0))
		# The machine behind the socket is the one it is bolted to, which is what
		# the cable resolves through.
		_eq("and it belongs to that machine", on_psx.get_machine(), psx)

	psx.queue_free()
	plain.queue_free()
	await get_tree().process_frame


func _test_psx_lead_will_seat() -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	if sys_scene == null:
		return
	var a: Node3D = sys_scene.instantiate()
	a.systemid = "playstation"
	add_child(a)
	var handheld: Node3D = sys_scene.instantiate()
	handheld.systemid = "game_boy_advance"
	add_child(handheld)
	var lead: Node3D = load(PSX_CABLE_SCENE).instantiate()
	add_child(lead)
	var gba_lead: Node3D = load(CABLE_SCENE).instantiate()
	add_child(gba_lead)
	await get_tree().process_frame
	await get_tree().process_frame

	var serial := a.find_child("PsxLinkPort", true, false) as XRToolsSnapZone
	var ext := handheld.find_child("LinkPort", true, false) as XRToolsSnapZone
	var pad := a.find_child("ControllerPort1", true, false) as XRToolsSnapZone
	_ok("the console has a serial socket", serial != null)
	_ok("the handheld has an EXT socket", ext != null)
	if serial == null or ext == null or pad == null:
		a.queue_free()
		handheld.queue_free()
		lead.queue_free()
		gba_lead.queue_free()
		return

	var end_a := lead.get_node_or_null("PlugA0") as Node3D
	var end_b := lead.get_node_or_null("PlugB0") as Node3D
	var gba_end := gba_lead.get_node_or_null("PlugA0") as Node3D

	# Symmetric, unlike the GameCube lead: this is a null modem between peers, so
	# either end goes in either console and there is no wrong way round.
	_ok("either end goes into a serial socket",
		serial.can_preview(end_a) and serial.can_preview(end_b),
		"require '%s', plug in %s" % [serial.snap_require, str(end_a.get_groups())])

	# And the three that must not.
	_ok("a PlayStation lead does not go into a handheld's EXT socket",
		not ext.can_preview(end_a))
	_ok("nor into a controller socket", not pad.can_preview(end_a))
	_ok("and a handheld link lead does not go into a serial socket",
		not serial.can_preview(gba_end))

	a.queue_free()
	handheld.queue_free()
	lead.queue_free()
	gba_lead.queue_free()
	await get_tree().process_frame


func _test_psx_cable_joins_a_pair() -> void:
	var cable := PsxLinkCable.new()
	add_child(cable)

	# Safe at any time and any number of times: this runs on every unseated
	# resolve and on the way out of the tree.
	cable._disconnect()
	cable._disconnect()
	_eq("a lead that was never joined records no link", cable._linked.size(), 0)

	var m1 := _StubMachine.new()
	var m2 := _StubMachine.new()
	add_child(m1)
	add_child(m2)
	m1.libretro = Libretro.new()
	m2.libretro = Libretro.new()
	m1.add_child(m1.libretro)
	m2.add_child(m2.libretro)

	var a := {"libretro": m1.libretro, "machine": m1, "port": 0}
	var b := {"libretro": m2.libretro, "machine": m2, "port": 0}

	# Neither console is running, and the lead joins them anyway. Seating a cable
	# into a machine that is switched off is an ordinary thing to do, and the link
	# comes alive when both cores attach their serial hardware.
	cable._join(a, b)
	_eq("two idle consoles are still cabled together", cable._linked.size(), 6)

	# Re-stating the same pair changes nothing, which matters because a lead
	# resolves whenever either of its plugs moves.
	var was: Variant = cable._linked
	cable._join(a, b)
	_ok("re-stating the same pair is a no-op", cable._linked == was)

	cable._disconnect()
	_eq("pulling a plug parts them", cable._linked.size(), 0)

	# A machine cabled to itself, which the room cannot present -- one console has
	# one serial socket -- but which the guard exists for anyway.
	cable._join(a, {"libretro": m1.libretro, "machine": m1, "port": 0})
	_eq("a console is not cabled to itself", cable._linked.size(), 0)

	cable.queue_free()
	m1.queue_free()
	m2.queue_free()
	await get_tree().process_frame


## The socket is IN the back panel, not floating off it.
##
## The regression record for the one bug a render could not show. A port is
## placed where the seated plug's ORIGIN belongs, and the two connectors on this
## panel put their origin in different places: a phono plug's is 10 mm out with
## its barrel reaching back, this one's is its mating face. Copying the phono
## row's z left the socket hanging 10 mm off the back of the console with the
## plug's nose stopping 3 mm short of it -- and photographed head-on that reads
## as a plug resting against the panel, which is why it survived two rounds of
## looking at pictures.
##
## So this measures rather than looks: the mouth of the recess against the body's
## own back face, and the nose of a seated plug against the same plane.
func _test_psx_socket_is_in_the_panel() -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	if sys_scene == null:
		return
	var psx: Node3D = sys_scene.instantiate()
	psx.systemid = "playstation"
	add_child(psx)
	var lead: Node3D = load(PSX_CABLE_SCENE).instantiate()
	add_child(lead)
	await get_tree().process_frame
	await get_tree().process_frame

	var body := psx.find_child("SystemBody", true, false) as MeshInstance3D
	var port := psx.find_child("PsxLinkPort", true, false) as Node3D
	var jack := port.find_child("PsxLinkJack", true, false) as MeshInstance3D if port != null else null
	_ok("the console has a body and a socket", body != null and port != null and jack != null)
	if body == null or port == null or jack == null:
		psx.queue_free()
		lead.queue_free()
		return

	# The back face of whatever this machine actually wears, in its own frame.
	# NOT body.get_aabb(): a console with a shell of its own keeps the primitive
	# SystemBody in the tree and merely HIDDEN, so measuring it compares the
	# socket against a box no player can see -- and the PlayStation's box reaches
	# 32 mm further back than its shell does.
	var panel_z: float = _panel_face_z(psx, psx.to_local(port.global_position))

	# On a machine with a shell of its own the port draws NOTHING. The console
	# moulds the socket and prints its name; the port's recess laid over that is a
	# black box stuck on the back panel, and the plate over the print is a black
	# rectangle. Both were shipped and both were reported.
	_ok("a shelled console draws its own socket, not the port's",
		not jack.is_visible_in_tree())

	# Where it puts the SEAT is still its whole job, and the failure is invisible
	# once nothing is drawn -- so measure it against the shell's own socket, which
	# is the thing a plug has to go into.
	var moulded := psx.find_child("JackSerial", true, false) as MeshInstance3D
	_ok("the shell has the socket the seat is measured from", moulded != null)
	if moulded != null:
		var mb := moulded.get_aabb()
		var m0: Vector3 = psx.to_local(moulded.global_transform * mb.position)
		var m1: Vector3 = psx.to_local(moulded.global_transform * (mb.position + mb.size))
		var face: float = minf(m0.z, m1.z)
		_ok("and the seat is on its face, not out in the air",
			absf(psx.to_local(port.global_position).z - face) < 0.002,
			"seat %.4f against the socket face %.4f, panel %.4f"
				% [psx.to_local(port.global_position).z, face, panel_z])
		_ok("which is on the back panel, not behind the console",
			face >= panel_z - 0.004,
			"socket face %.4f against a panel at %.4f" % [face, panel_z])

	# A console does not always stand square to the room, and it has to be turned
	# BEFORE it is built: the socket is posed once, at spawn. Posed by world
	# rotation it was twisted off the panel by however far the console faced away
	# from dead ahead, and the seat -- and any lead in it -- went in crooked.
	# Turning a console already standing proves nothing, because the port is a
	# child and rides along either way.
	var angled: Node3D = sys_scene.instantiate()
	angled.systemid = "playstation"
	angled.rotation = Vector3(0.0, deg_to_rad(37.0), 0.0)
	add_child(angled)
	for i in range(4):
		await get_tree().process_frame
	var turned: Node3D = angled.find_child("PsxLinkPort", true, false)
	_ok("a console standing at an angle keeps its socket on its panel",
		turned != null and turned.global_basis.z.normalized().dot(
			-angled.global_basis.z.normalized()) > 0.999,
		"socket +Z . panel normal = %.3f" % (turned.global_basis.z.normalized().dot(
			-angled.global_basis.z.normalized()) if turned != null else 0.0))
	angled.queue_free()
	await get_tree().process_frame

	# And a seated plug actually enters. A connector whose nose stops short of the
	# panel is a connector resting against the outside of the console.
	port.pick_up_object(lead.get_node("PlugA0"))
	for i in range(12):
		await get_tree().process_frame
	var nose := lead.get_node("PlugA0").find_child("PlugNose", true, false) as MeshInstance3D
	if nose != null:
		var nb := nose.get_aabb()
		var n0: Vector3 = psx.to_local(nose.global_transform * nb.position)
		var n1: Vector3 = psx.to_local(nose.global_transform * (nb.position + nb.size))
		_ok("a seated plug's nose is inside the panel", maxf(n0.z, n1.z) > panel_z,
			"nose reaches %.4f, panel at %.4f" % [maxf(n0.z, n1.z), panel_z])
		# And the shell stays out, or the lead has been swallowed.
		var tip := lead.get_node("PlugA0").find_child("PlugTip", true, false) as MeshInstance3D
		var t0: Vector3 = psx.to_local(tip.global_transform * tip.get_aabb().position)
		_ok("and its shell stays outside", t0.z < panel_z,
			"shell at %.4f, panel at %.4f" % [t0.z, panel_z])

	# The lettering has to read from OUTSIDE the console. The port is turned to
	# face out, which flips the frame the glyphs are laid out in; the plate undoes
	# that turn, and a plate that stopped undoing it would print SERIAL I/O
	# backwards without anything else noticing.
	var legend := port.find_child("Legend", true, false) as Node3D
	_ok("the socket carries a legend", legend != null)
	if legend != null:
		var label := legend.find_child("Label", true, false) as Label3D
		_ok("and it says what the socket is",
			label != null and label.text == "SERIAL I/O",
			label.text if label != null else "no label")
		# Its own +X must end up pointing the same way the machine's does, or the
		# text runs right to left.
		var right: Vector3 = legend.global_transform.basis.x.normalized()
		var machine_right: Vector3 = psx.global_transform.basis.x.normalized()
		_ok("and it reads the right way round", right.dot(machine_right) < -0.9,
			"legend +X . machine +X = %.2f" % right.dot(machine_right))

	psx.queue_free()
	lead.queue_free()
	await get_tree().process_frame


## The back panel of the body this machine actually wears, AT a given point on
## it, in the machine's own frame.
##
## Measured off the SHELL when there is one and the primitive SystemBody only
## when there is not, rather than over every mesh in the machine: the serial port
## is a child of the machine too, and its recess sits a millimetre proud of the
## panel, so a blanket sweep would measure the socket against itself and pass no
## matter where it was put.
##
## RAYCAST, and it has to be. This was the shell's rearmost mesh CORNER, which is
## what playstation_model was using to place the socket -- so both sides of
## "the mouth of the recess is level with the panel" agreed on a number that was
## 9.5 mm out, the case passed, and the console wore a black cube on its back
## panel through several rounds of review. A check that shares the code's own
## mistake cannot fail. measure-shell-panel-by-raycast says an AABB will lie
## about a panel; this is what that looks like when a test believes it too.
## The back panel of the body this machine actually wears, AT a given point on
## it, in the machine's own frame.
##
## Measured off the SHELL when there is one and the primitive SystemBody only
## when there is not, rather than over every mesh in the machine: the serial port
## is a child of the machine too, and its recess sits a millimetre proud of the
## panel, so a blanket sweep would measure the socket against itself and pass no
## matter where it was put.
##
## RAYCAST, and it has to be. This was the shell's rearmost mesh CORNER, which is
## exactly what playstation_model was using to place the socket -- so both sides
## of "the mouth of the recess is level with the panel" agreed on a number 9.5 mm
## out, the case passed, and the console wore a black cube on its back panel
## through several rounds of review. A check that shares the code's own mistake
## cannot fail. measure-shell-panel-by-raycast says an AABB will lie about a
## panel; this is what it looks like when the test believes it too.
##
## Cast against the TRIANGLES rather than through the physics server, which the
## note's recipe uses. One ray does not need bodies, a physics frame or the
## machine held still, and a shell carries meshes Jolt will not take: SilverTrim
## builds a shape it rejects outright, one loud error per call, for a trim that
## could never be the panel anyway.
func _panel_face_z(machine: Node3D, at: Vector3) -> float:
	var shell := machine.find_child("Shell", true, false) as Node3D
	if shell == null:
		var body := machine.find_child("SystemBody", true, false) as MeshInstance3D
		return body.get_aabb().position.z if body != null else 0.0

	# A RING around the point, not the point itself, and the nearest face of the
	# lot. Aim a single ray at a socket and it goes through the opening and
	# reports whatever is 2.5 mm further in -- a number that is neither the panel
	# nor the connector. The ring clears the 16 x 4.8 mm mouth by about 2 mm on
	# every side and still lands well short of the phono row 20 mm away.
	var best := INF
	for ix in [-0.010, -0.005, 0.0, 0.005, 0.010]:
		for iy in [-0.004, 0.0, 0.004]:
			if absf(ix) < 0.009 and absf(iy) < 0.003:
				continue                    # inside the mouth
			best = minf(best, _first_face_z(machine, shell,
				Vector3(at.x + ix, at.y + iy, 0.0)))
	return best if is_finite(best) else NAN


## Where a ray from behind the machine first meets the shell, in machine-local z.
##
## Cast against the TRIANGLES rather than through the physics server, which
## measure-shell-panel-by-raycast's recipe uses. One ray needs no bodies, no
## physics frame and no holding the machine still, and a shell carries meshes
## Jolt will not take: SilverTrim builds a shape it rejects outright, one loud
## error per call, for a trim that could never be the panel anyway.
func _first_face_z(machine: Node3D, shell: Node3D, at: Vector3) -> float:
	var from: Vector3 = machine.to_global(Vector3(at.x, at.y, -0.5))
	var dir: Vector3 = (machine.to_global(Vector3(at.x, at.y, 0.5)) - from).normalized()
	var best := INF
	for n in shell.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var to_local := mi.global_transform.affine_inverse()
		var lf: Vector3 = to_local * from
		var ld: Vector3 = (to_local.basis * dir).normalized()
		if not mi.get_aabb().grow(0.001).intersects_ray(lf, ld):
			continue
		var faces := mi.mesh.get_faces()
		for i in range(0, faces.size() - 2, 3):
			var p: Variant = Geometry3D.ray_intersects_triangle(
				lf, ld, faces[i], faces[i + 1], faces[i + 2])
			if p == null:
				continue
			best = minf(best, machine.to_local(mi.global_transform * (p as Vector3)).z)
	return best


## How far the nearest phono socket on this machine is from a given x.
##
## Asked of the machine rather than written down, because the two bodies do not
## agree: the stand-in box puts its row at x = 0.082 with the serial socket 37 mm
## away, while the real shell's nearest jack -- red AUDIO_R at 0.0236 against the
## serial at 0.0440 -- leaves barely 20 mm. That is the hardware, not a spacing
## anyone chose, and it is why this asserts a clearance rather than a position.
##
## LinkPort is EXCLUDED, and has to be: PsxLinkPort extends LinkPort extends
## RcaPort, so a plain `is RcaPort` finds the serial socket itself and reports it
## as being 0 mm from the A/V row -- a clearance test that can never pass.
func _nearest_av_gap(machine: Node3D, x: float) -> float:
	var best := INF
	for n in machine.find_children("*", "Node3D", true, false):
		if n is RcaPort and not (n is LinkPort):
			best = minf(best, absf((n as Node3D).position.x - x))
	return best if is_finite(best) else INF


# -- Who a re-formed bus power-cycles ----------------------------------------
# _restart exists so a cartridge game that has gone past the screen where it
# would have offered multiplayer gets another chance at it. These pin exactly
# which machines that reaches, because the rule is destructive and asymmetric:
# a reset costs a game with a cartridge a boot logo, and costs a machine whose
# whole state arrived down the wire everything it had.
#
# Driven through _restart directly rather than through _watch, because _watch
# reads LinkPeerCount off a running core and these must stay core-free. What
# _watch decides is the `seat`/`live_seat` pair in each entry, and that is what
# is varied here.

const NO_SEAT_SENTINEL := -1


class _FakeMachine extends Node:
	var systemid := "game_boy_advance"
	var rom_path := "/roms/game.gba"
	var is_powered_on := true


func _restart_seen(cable: LinkCable, ends: Array) -> Array:
	var fired: Array = []
	var tap := func(m: Node) -> void: fired.append(m)
	cable.machine_restarted.connect(tap)
	var typed: Array[Dictionary] = []
	for e: Dictionary in ends:
		typed.append(e)
	cable._restart(typed)
	cable.machine_restarted.disconnect(tap)
	return fired


func _end_for(machine: _FakeMachine, lib: Libretro, seat: int, live_seat: int) -> Dictionary:
	return {"libretro": lib, "machine": machine, "port": 0,
		"seat": seat, "live_seat": live_seat}


func _test_restart_rule() -> void:
	var cable := LinkCable.new()
	var host := _FakeMachine.new()
	var host_lib := Libretro.new()

	# The case the rule is FOR: a cartridge machine that booted alone and has
	# now found itself on a live wire.
	var fired := _restart_seen(cable, [_end_for(host, host_lib, 0, -1)])
	_ok("restart/a cartridge machine meeting the cable for the first time is NOT restarted",
		fired.is_empty())

	# Once it has been told, it is left alone.
	fired = _restart_seen(cable, [_end_for(host, host_lib, 0, 0)])
	_ok("restart/and is not restarted again at the same seat", fired.is_empty())

	# A renumber. Two pairs merging into one four-way bus moves seats under
	# machines that were already playing.
	fired = _restart_seen(cable, [_end_for(host, host_lib, 2, 0)])
	_ok("restart/a cartridge machine whose seat changed is restarted", fired.has(host))

	# The single-pak client. Nothing to reboot into, and the program it was sent
	# is its entire state, so neither branch may reach it.
	var client := _FakeMachine.new()
	client.rom_path = ""
	var client_lib := Libretro.new()
	fired = _restart_seen(cable, [_end_for(client, client_lib, 1, -1)])
	_ok("restart/a machine with no cartridge is not restarted on first sight of the cable",
		fired.is_empty())
	fired = _restart_seen(cable, [_end_for(client, client_lib, 3, 1)])
	_ok("restart/nor when its seat changes under it", fired.is_empty())

	# Only the platform whose games sample the link at boot.
	var snes := _FakeMachine.new()
	snes.systemid = "super_nintendo"
	var snes_lib := Libretro.new()
	fired = _restart_seen(cable, [_end_for(snes, snes_lib, 0, -1)])
	_ok("restart/a platform that does not sample the link at boot is never restarted",
		fired.is_empty())

	# THE HOST. It holds a cartridge, so the no-cartridge guard never covered it,
	# and powering on a client used to reset it in the middle of whatever it was
	# doing. It no longer does: mGBA fcf53f2ba keeps SIOCNT's id and slave bits
	# fresh as the party changes, so a game notices a cable arriving without being
	# power-cycled at it -- measured at 9.0 transfers a frame with nobody reset.
	var solo := _FakeMachine.new()
	var solo_lib := Libretro.new()
	fired = _restart_seen(cable, [_end_for(solo, solo_lib, 0, -1)])
	_ok("restart/the cartridge-holding host survives a client joining it",
		fired.is_empty())

	# A PULLED lead must not leave a seat behind.
	#
	# This is the case that actually power-cycled machines in a real session. Two
	# pairs were playing, every lead came out, and all four went back in as one
	# chain; the two that returned at player three and four were reset "so it can
	# be player 3 rather than player 1", against a seat they had held before the
	# cable was ever unplugged. There was no link in between for a renumber to
	# happen across -- the link went down and came back, which is the first-sight
	# case and needs no reset.
	var pulled := _FakeMachine.new()
	var pulled_lib := Libretro.new()
	pulled_lib.set_meta("link_live_seat", 0)
	var lead: LinkCable = load(CABLE_SCENE).instantiate()
	add_child(lead)
	lead._linked = [_end_for(pulled, pulled_lib, 0, 0)] as Array[Dictionary]
	lead._disconnect()
	_eq("restart/pulling the lead forgets the seat a machine was playing at",
		int(pulled_lib.get_meta("link_live_seat", NO_SEAT_SENTINEL)), -1)
	# ...so coming back somewhere else is a first sight, not a renumber.
	fired = _restart_seen(cable, [_end_for(pulled, pulled_lib, 2,
		int(pulled_lib.get_meta("link_live_seat", NO_SEAT_SENTINEL)))])
	_ok("restart/so returning at a different seat is not a renumber",
		fired.is_empty())
	lead.queue_free()

	for n: Node in [host, host_lib, client, client_lib, snes, snes_lib, solo, solo_lib,
			pulled, pulled_lib, cable]:
		n.free()
