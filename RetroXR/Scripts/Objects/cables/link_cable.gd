## A link cable between two handhelds.
##
## Physically this is an ordinary lead and inherits all of it: the verlet rope,
## the plug clamping, seating persistence, and the multiplayer replication of
## which end sits where. What differs is only what a seated pair MEANS. A
## composite lead resolves into an A/V routing decision; this one resolves into
## two emulator cores being told they share a wire.
##
## So _resolve is the one thing overridden. It is the single place where "both
## ends are in sockets" turns into a consequence, and swapping that consequence
## is the whole of the difference.
##
## Two things a composite lead cares about and this one does not:
##
## Direction. A phono cord runs from an output to an input and carries nothing
## between two outputs. A link cable is symmetric, and which machine ends up
## driving the clock is decided by the guests over the wire, not by the room.
##
## The A/V graph. links() stays empty on purpose, so AvGraph walks straight past
## this lead. A television has no business hearing about it.
##
## The two ends are not interchangeable, and the shells say so. End A is always
## the one handed to LinkConnect first, so its machine takes bus index 0 and owns
## the clock; on the real cable that end is the purple connector and the
## secondary is grey. The colours are the hardware's, and here they happen to be
## accurate rather than decorative.
class_name LinkCable
extends CompositeCable

## A machine on this wire has been thrown back to its boot logo so that it can
## see the cable. Nothing in the room listens yet; it is emitted because this is
## the one thing this class does that a player did not ask for, and a room that
## wants to say so on screen should not have to scrape the log for it.
signal machine_restarted(machine: Node)

## The pair currently joined, as [{libretro, port}, {libretro, port}], so a pull
## can be undone against the same machines and the same sockets that were joined,
## even if by then one of them has been switched off or carried out of the room.
var _linked: Array[Dictionary] = []


## Every lead that currently shares a wire with this one, this one included, as
## of the last resolve. Kept so a lead being carried out of the room can tell the
## ones it leaves behind, at which point the walk that would have found them is
## already broken.
var _wire: Array[Node3D] = []

## Guards the wake below against ringing back and forth for ever: a lead woken by
## its neighbour would otherwise wake the neighbour straight back.
static var _waking := false


func _resolve() -> void:
	if not is_inside_tree():
		return

	var wire: Array[Node3D] = []
	var group := _machines_on_this_wire(wire)

	if _bus_head(wire) == self and netplay_took_bus(linked_machines(), held_machines()):
		# Keep the physical cache in step with the accepted intent. The actual bus
		# changes later at the agreed frame, but _watch must not resurrect a pull
		# or forget a join while it waits.
		_linked = group.duplicate() if group.size() >= 2 else []
		_restate_wait = RESTATE_COOLDOWN
	elif group.size() >= 2 and _bus_head(wire) == self:
		_join(group)
	else:
		# Either there is nothing to join, or another lead on this wire is the
		# one that joins it. Release whatever this lead is still holding either
		# way, so exactly one of them owns the bus.
		_disconnect()

	# Still reported and still announced: seating replication and anything
	# listening for a cable to move do not care what the cable carries.
	_report_seating_changes()
	topology_changed.emit()

	_wake(wire)


## Which lead on a wire performs the join.
##
## Every lead sharing a wire walks to the same machines, so without a rule they
## would all join them and all record having done so, and then whichever was
## pulled first would tear the bus down for the others. It has to be one.
##
## The head of the chain, meaning the lead that is not itself hanging off another
## lead's junction. That is a physical property of how the leads are plugged
## together rather than a fact about this program, so every lead on the wire
## picks the same one, and it puts the clock where the hardware puts it: on the
## machine at the head lead's purple end, which is the machine the walk visits
## first and therefore the one that takes bus index 0.
##
## A topology with no clear head, which needs both junctions in use, falls back
## to the lowest stable key. Arbitrary, but it has to be decided somehow, and it
## is at least the same answer from every lead AND from every peer.
func _bus_head(wire: Array[Node3D]) -> Node3D:
	var head: Node3D = null
	var head_key := ""
	for c in wire:
		var cable := c as LinkCable
		if cable == null or cable._hangs_off_a_junction():
			continue
		var key := stable_key(cable)
		if head == null or key < head_key:
			head = cable
			head_key = key
	if head != null:
		return head
	for c in wire:
		var key := stable_key(c)
		if head == null or key < head_key:
			head = c
			head_key = key
	return head


## What a lead is called, in a way every peer agrees on.
##
## The tie-break used to be the lowest instance id, and that is a desync waiting
## to happen. An instance id is a per-process allocation: two headsets running
## the same replicated room hand back different ones for the same lead, so they
## can pick different heads, and the head decides which machine takes bus index
## zero. Different player one on each peer, from identical inputs.
##
## A net_id where there is one, because the host mints those and every peer is
## told the same number. Cables do not get one today (they serialise empty and
## object_sync skips them), so in practice this is the node path, which is what
## object_sync ALREADY puts on the wire for a cable: EV_RCA_PLUG encodes an
## unregistered node as "$path" and the far peer looks it up by that path. So the
## path being the same everywhere is not a new assumption, it is the one this
## room already runs on.
static func stable_key(node: Node) -> String:
	var id := int(node.get_meta("net_id", -1))
	# Zero-padded so it sorts numerically rather than as text, and prefixed so a
	# registered lead never sorts into the middle of the unregistered ones.
	return "#%012d" % id if id >= 0 else str(node.get_path())


## Whether either of this lead's ends sits in another lead's junction rather than
## in a machine. A junction socket has no core behind it, which is exactly what
## tells the two kinds of socket apart.
func _hangs_off_a_junction() -> bool:
	for e in [End.A, End.B]:
		var port := _link_port_at(e)
		if port != null and port.get_machine() == null and port.get_cable() != null:
			return true
	return false


## Tell every other lead on this wire to look again.
##
## A lead resolves when ITS OWN plug moves, and that is not the same question as
## which machines are on the wire. Chain a third handheld onto a lead's junction
## and the FIRST lead's bus grew from two machines to three without anything of
## its own having moved.
##
## The union of the wire before and after, because unplugging from a junction
## takes this lead OFF the wire it needs to tell.
func _wake(wire: Array[Node3D]) -> void:
	var reach: Array[Node3D] = []
	for group: Array[Node3D] in [_wire, wire]:
		for c in group:
			if c != self and is_instance_valid(c) and not reach.has(c):
				reach.append(c)
	_wire = wire

	if _waking:
		return
	_waking = true
	for c in reach:
		var cable := c as LinkCable
		if cable != null:
			cable._resolve()
	_waking = false


## Every machine that ends up sharing this wire, as [{libretro, port}, ...].
##
## Not just this lead's two ends. A link cable carries an inline junction so a
## third and fourth player can chain in, and the junction has no core behind it:
## it conducts. So the set is found by walking cable to cable through junctions
## until nothing new turns up, which is what makes four handhelds on three leads
## one bus rather than three.
##
## The coordinator cannot do this walk itself, because a junction can never be an
## endpoint there. Working it out is the room's job precisely because the cables
## and their junctions are things in the room.
## The bus this lead makes, as [{machine, port}], head first, or [] when it
## joins nothing.
##
## Every cable that can put two cores on a wire answers this, whatever its
## shape: a handheld lead walking a chain of junctions, a GameCube-to-GBA lead
## joining two ends that are not even the same KIND of socket, a PlayStation
## null modem between peers. A machine asks all of them to find its own bus, so
## a lead that cannot say what it joins is a lead netplay cannot schedule.
func linked_machines() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var wire := machines_on_wire()
	if wire.size() < 2:
		return out
	for entry: Dictionary in wire:
		out.append({"machine": entry.get("machine"), "port": int(entry.get("port", 0))})
	return out


## Every machine port on this lead's wire, as [{libretro, port, machine}].
## Public because a machine needs to know its own bus before netplay can put
## the whole of it into one session; the walk itself is the same one _resolve
## does, and there must not be two of them.
func machines_on_wire() -> Array[Dictionary]:
	var cables: Array[Node3D] = []
	return _machines_on_this_wire(cables)


func _machines_on_this_wire(cables: Array[Node3D]) -> Array[Dictionary]:
	var machines: Array[Dictionary] = []
	cables.append(self)
	var seen := {self: true}
	var i := 0

	while i < cables.size():
		var cable: LinkCable = cables[i] as LinkCable
		i += 1
		if cable == null:
			continue

		# Where this lead's own two ends are sitting.
		for e in [End.A, End.B]:
			var port := cable._link_port_at(e)
			if port == null:
				continue
			var machine := port.get_machine()
			if machine != null:
				var node := port.get_libretro()
				if node != null:
					machines.append({"libretro": node, "port": port.link_port,
						"machine": machine})
				continue
			# Not a machine, so it is another lead's junction: follow it.
			_visit(port.get_cable(), cables, seen)

		# And whatever is plugged INTO this lead's junction.
		var junction := cable.junction_port()
		if junction != null:
			var plug := junction.seated_plug() as RcaPlug
			if plug != null:
				_visit(plug.cable, cables, seen)

	return machines


func _visit(cable: Node3D, cables: Array[Node3D], seen: Dictionary) -> void:
	if cable == null or not (cable is LinkCable) or seen.has(cable):
		return
	seen[cable] = true
	cables.append(cable)


## The junction socket moulded into this lead, or null on a lead that ships
## without one.
func junction_port() -> LinkPort:
	return get_node_or_null("Junction/LinkPort") as LinkPort


## What this lead is currently holding, in the same [{machine, port}] shape the
## walk produces — the machines a PULL has to name, since by then the walk finds
## nothing.
func held_machines() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for end: Dictionary in _linked:
		var machine: Object = end.get("machine")
		if machine == null:
			continue
		out.append({"machine": machine, "port": int(end.get("port", 0))})
	return out


func _join(group: Array[Dictionary]) -> void:
	if _same_group(group):
		return          # already joined to exactly this set

	_disconnect()

	var head: Libretro = group[0]["libretro"]
	var others: Array = []
	var ports := PackedInt32Array()
	ports.append(group[0]["port"])
	for k in range(1, group.size()):
		others.append(group[k]["libretro"])
		ports.append(group[k]["port"])

	if head.LinkConnectGroup(others, ports):
		_linked = group.duplicate()
	_log_ends("joined", _linked)


## Platforms that read their link once, on the way up.
##
## A Game Boy Advance samples SIOCNT's "all GBAs ready" bit while it boots and
## caches the answer, so a lead pushed in afterwards reaches a machine that has
## already decided it is alone.
##
## A Game Boy decides nothing. Its serial port is self-synchronising and a game
## looks at it when the player asks to link, which is when the cable turns up in
## real life: both Pokemon players are hours into a save by the time they walk
## into the Cable Club. Resetting one there would throw the session away to
## repair a fault it does not have.
const SAMPLES_LINK_AT_BOOT: Array = ["game_boy_advance"]


## Power-cycle a machine that was already running when the cable arrived.
##
## A GBA reads whether anything is on the other end ONCE, while it boots, and
## never asks again: it samples the ready line about a third of a second in and
## caches the answer for the rest of the session. Cable two handhelds together
## after either of them has got past that moment and the link is live, both cores
## are on the bus, both read two peers, and the game still refuses multiplayer
## with a rejection noise -- because it decided before the cable existed.
##
## Measured, not guessed: the same two machines and the same ROM run 9 transfers
## a frame when both are switched on with the lead already in, and exactly zero
## when the lead goes in afterwards. A reset is what closes the gap.
##
## Real hardware behaves the same way, which is why the instruction on the box is
## to connect the cable BEFORE switching on, and why a player who forgets reaches
## for the power switch. The room does it for them, because the alternative is a
## cable that looks perfect and silently does nothing.
##
## Only machines that have NOT been on a live wire since their core started.
##
## A console that has already been linked knows the port is live, so pulling the
## lead and pushing it back in must not throw its game away. That is the ordinary
## thing a player does to a cable, and losing a single-player run to it would be
## worse than the fault this repairs.
##
## Marked as having seen a live port on the way out, which is what stops this
## repeating: after the restart the machine boots INTO a working link, so that is
## true by the time it matters. Without it the rule fed itself and the pair sat
## restarting each other for ever.
##
## No "is it still booting" exemption, because there is nothing to hang one on:
## the frame count carries across a core starting rather than beginning again, so
## a console switched on a moment ago is indistinguishable from one that has been
## running all afternoon. Restarting a machine that had not sampled its link yet
## costs it a second of boot logo and guarantees it comes up with the link live,
## which is the outcome wanted either way.
func _restart(members: Array[Dictionary]) -> void:
	for end: Dictionary in members:
		var lib: Libretro = end["libretro"]
		if not is_instance_valid(lib):
			continue
		var machine_node: Node = end["machine"]
		var systemid: String = ""
		var loaded_rom: String = ""
		if machine_node != null and is_instance_valid(machine_node):
			systemid = str(machine_node.get("systemid"))
			loaded_rom = str(machine_node.get("rom_path"))
		if not SAMPLES_LINK_AT_BOOT.has(systemid):
			continue
		# Never a machine with no cartridge in it.
		#
		# Everything below is about a GAME that has gone past the screen where it
		# would have offered multiplayer, and a power cycle is the only way the
		# room can get it back there. A machine with nothing in it is not playing
		# a game: it is sitting in the BIOS handshake, whose whole job is to poll
		# the link waiting to be sent a program, so it re-reads the cable by
		# design and needs no persuading.
		#
		# And the reset is not the cheap "second of boot logo" this rule assumes
		# it is. Single-cartridge play downloads a program into this machine's
		# RAM, and that program IS its entire state -- there is no cartridge
		# underneath to come back to, so there is no "wanted either way" about
		# it. Resetting drops the handheld to the no-cartridge screen and the
		# host has to send the whole program again.
		#
		# That is what made single-pak play so unreliable: seating the last lead,
		# or powering another machine on, re-forms the bus and renumbers the
		# seats, and the renumber reset clients that had already been sent their
		# copy.
		if loaded_rom.is_empty():
			continue
		var seat: int = int(end.get("seat", NO_SEAT))
		var had: int = int(end.get("live_seat", NO_SEAT))
		if had == seat:
			continue
		# Only a machine whose player number MOVED, never one meeting the cable
		# for the first time.
		#
		# Both used to reset, on the grounds that a GBA reads the cable once at
		# boot and caches the answer. That was true, and it was a driver fault
		# rather than a fact about the hardware: SIOCNT's id and slave bits are
		# decided by the cable, and the netlink driver only refreshed them when
		# the guest happened to WRITE SIOCNT, which a game sitting on a menu does
		# not do. A machine that booted with an empty socket therefore stayed
		# marked a slave for ever, and a slave never originates a transfer.
		# Fixed in mGBA fcf53f2ba, and measured after it: a lead seated around a
		# running pair now carries 9.0 transfers a frame with NOBODY reset, in
		# both orders a room can produce. So this branch is a power cycle that
		# buys nothing, and it cost whatever the player was doing.
		#
		# The renumber below is a different matter and was measured separately:
		# move a playing pair's seats and the traffic stops dead and never comes
		# back -- 5110 messages before, 5110 after, three watch steps later still
		# 5110, with both cores at 59.8 fps and the bus still reporting two peers.
		# The control rules out the bus: re-declaring the SAME group from the SAME
		# anchor, so that no seat moves, leaves the session running at 9.0. It is
		# the player number changing under a game that it cannot survive, which is
		# unsurprising -- no cable can do that to real hardware. Only a reset
		# recovers it, so this stays. Both cases are pinned in link_tests, and
		# mario_link_probe carries the two orders that measured them.
		if had == NO_SEAT:
			lib.set_meta(LIVE_SEAT, seat)
			continue
		lib.set_meta(LIVE_SEAT, seat)
		lib.RequestReset()
		var machine: Node = end["machine"]
		var why := "so it can be player %d rather than player %d" % [seat + 1, had + 1]
		print("[LinkCable] restarted %s %s" % [
			machine.name if machine != null and is_instance_valid(machine) else "a machine", why])
		machine_restarted.emit(machine)


func _log_ends(verb: String, ends: Array[Dictionary]) -> void:
	# Worth the noise for the same reason RcaPort logs every seating: the symptom
	# this explains is silent and misleading.
	#
	# A machine only takes part in a link if its CORE attached to the bus, and
	# that happens at load, behind a core option that says "(Restart)" and means
	# it. Switch a handheld on, then turn Link Cable on, and the room is entirely
	# right that the lead is seated and the machines are cabled -- while the game
	# reads "all GBAs ready" as false and refuses multiplayer with a rejection
	# noise. From the outside that is indistinguishable from a broken cable, a
	# socket that belongs to nobody, or a game that does not support linking.
	#
	# Peer COUNT is the number that tells them apart, because it comes back from
	# the core rather than from the room. Two machines cabled and only one peer
	# each means the other one's core is not on the bus.
	var parts: PackedStringArray = []
	for end: Dictionary in ends:
		# Checked BEFORE it is bound to a typed variable. Binding a freed object
		# to one faults on the assignment, before is_instance_valid ever gets to
		# answer, and the machines here really can be gone: this runs from the
		# disconnect path, which is where a lead reports on a room that has just
		# been torn down around it.
		if not is_instance_valid(end["libretro"]):
			continue
		var lib: Libretro = end["libretro"]
		# Typed, for the same reason the rope reads below are: Libretro is a
		# GDExtension and what its methods hand back is only known to the parser
		# where the extension is fully registered.
		var machine: Node = lib.get_parent()
		parts.append("%s (%d peers)" % [
			machine.name if machine != null else "?", lib.LinkPeerCount(end["port"])])
	print("[LinkCable] %s %s: %s" % [name, verb,
		", ".join(parts) if parts.size() > 0 else "nothing"])


func _same_group(group: Array[Dictionary]) -> bool:
	if _linked.size() != group.size():
		return false
	for k in group.size():
		if _linked[k]["libretro"] != group[k]["libretro"] or _linked[k]["port"] != group[k]["port"]:
			return false
	return true


## Deliberately empty. A link cable carries no picture and no sound, and AvGraph
## duck-types on this method, so an empty list is how a lead says "not mine".
func links() -> Array[Dictionary]:
	return []


## Left alone, deliberately.
##
## CompositeCable tints each plug with its CORD's colour so the wires of a
## multi-cord lead can be told apart at both ends. A link lead has one cord, and
## its two ends differ by ROLE rather than by wire: the purple shell is the
## master end, the grey one the secondary, exactly as on the real cable. Painting
## both from a one-entry cord palette would erase the only thing there is to see.
func _tint_plug(_plug: RcaPlug, _col: Color) -> void:
	pass


func _link_port_at(e: int) -> LinkPort:
	var plugs := _end_plugs(e)
	if plugs.is_empty():
		return null
	var plug := plugs[0] as RcaPlug
	if plug == null:
		return null
	return plug.seated_port() as LinkPort


## Where along the cord the junction sits, as a fraction of the lead.
##
## Nearer the master end, as on the real cable. Exact placement is cosmetic; what
## matters is that it rides the cord rather than floating beside it, because a
## socket that does not move with the lead it is moulded into reads as broken.
const JUNCTION_AT := 0.25

## The block's own up, carried between ticks so its roll stays continuous as the
## cord swings. See _ride_junction.
var _junction_up := Vector3.UP


## The seat a machine last had on a live bus, set on its Libretro node and reset
## to NONE when the machine is switched on again.
##
## A bare "has it been live" flag was not enough, and the case that proved it is
## the ordinary one: a player seats the lead the wrong way round, notices, and
## swaps the ends. Seat zero is player one, so swapping the ends swaps who is
## player one, and a game that has already decided it is player two does not
## become player one because a plug moved. It is the same fault the flag exists
## to repair, arriving by a different route, so it wants the same repair.
##
## Single-pak is where this bites hardest, because there the seat is not a
## preference: the machine WITH the cartridge has to be player one, or it will
## not offer to send the game at all. Measured on the two-machine probe with the
## seats reversed: zero bytes of program cross the wire and the host sends 24
## messages in half a minute, against tens of thousands the right way round.
const LIVE_SEAT := "link_live_seat"

## No seat: never been on a live bus, or has been switched off since.
const NO_SEAT := -1

## Physics frames to wait before saying the wire again.
##
## A core takes a moment to reach the bus after its machine is switched on, and
## in that moment the room is right that the machine is on while the bus is right
## that it is not there yet. Without a pause the two disagree every frame and the
## wire is re-stated on all of them. The delay costs nothing that matters: the
## machine has not sampled its link yet either, and the restart rule below is
## what covers it once it has.
const RESTATE_COOLDOWN := 20
var _restate_wait := 0


## Run this lead's tick BEFORE the snap zones place the plugs seated in it.
##
## Every other socket in the room is bolted to something: a machine's port and
## the plug in it move together, whatever order they are updated in. The junction
## is not — it rides this lead's cord, and _ride_junction moves it from
## _physics_process. The plug seated in it is placed by its own grab driver,
## which XRToolsGrabDriver._priority_for gives -70 (-80 for a hand), so at the
## default 0 the block moved AFTER the plug had already been put where the block
## was LAST tick, every tick.
##
## Standing still that is invisible. Measured with a socket swept at hand speed,
## the plug trailed the junction by a full tick — 14.25 mm at the peak, snapping
## back each time the cord changed direction, and dragging the whole second lead
## with it. Ahead of the drivers the same sweep measures 0.00 mm.
##
## Between the two driver priorities rather than below both: a plug in a HAND is
## what moves this cord in the first place, so it should be placed before the
## cord reads it.
const RIDE_PRIORITY := -75


func _ready() -> void:
	super._ready()
	process_physics_priority = RIDE_PRIORITY


func _physics_process(delta: float) -> void:
	super._physics_process(delta)
	_ride_junction()
	_watch()


## Keep the bus and the room agreeing about a wire nobody has touched.
##
## Two things happen to a seated lead without any plug moving, and neither is
## visible from the room:
##
## A machine being SWITCHED OFF takes the wires with it. The bus keys them on the
## core's instance, and switching off destroys that instance, so the lead is
## still in both sockets and joined to nothing. Powering back on does not undo it
## -- the new core attaches to a bus that no longer exists -- and the player's
## only way out is to unplug and replug, a repair for a fault they cannot see.
##
## And a machine ARRIVING on a wire that already had one running means the one
## already there booted alone and cached "nobody home", because a GBA asks once.
## Nothing moved, so nothing re-resolves, and the game refuses multiplayer with a
## rejection noise while every count in the room reads correctly.
func _watch() -> void:
	if _linked.is_empty():
		return

	var live: Array[Dictionary] = []
	for seat in range(_linked.size()):
		var end: Dictionary = _linked[seat]
		var lib: Libretro = end["libretro"]
		var machine: Node = end["machine"]
		if not is_instance_valid(lib) or machine == null or not is_instance_valid(machine):
			continue
		if not machine.is_powered_on:
			# A machine switched off starts its next session knowing nothing.
			lib.set_meta(LIVE_SEAT, NO_SEAT)
			continue
		var seen := end.duplicate()
		# The seat is this machine's position in the bus order, which is the
		# player number the hardware gives it: index zero is player one.
		seen["seat"] = seat
		# Read BEFORE the seat is recorded below. The machine that has just
		# gained a peer, or just been handed a different seat, is exactly the one
		# that may need restarting, and recording first would have it report that
		# it had been sitting there all along.
		seen["live_seat"] = int(lib.get_meta(LIVE_SEAT, NO_SEAT))
		if lib.LinkPeerCount(end["port"]) >= 2:
			lib.set_meta(LIVE_SEAT, seat)
		live.append(seen)

	# Every running machine on one wire must see every other running machine on
	# it. Anything else means the bus has forgotten a wire the room still has.
	if _restate_wait > 0:
		_restate_wait -= 1
	else:
		for end: Dictionary in live:
			if (end["libretro"] as Libretro).LinkPeerCount(end["port"]) != live.size():
				print("[LinkCable] %s: the bus lost this wire, saying it again" % name)
				_restate_wait = RESTATE_COOLDOWN
				_linked = []
				_resolve()
				return

	# Anyone on a live wire whose seat is not the seat they booted into has to
	# look again, which covers both a machine that has never been on a live wire
	# and one whose player number just changed under it. The seat was read above
	# BEFORE it was recorded, so a machine that has just gained its peer still
	# reports not having had one.
	#
	# Deliberately not "has the number of running machines gone up". That looked
	# equivalent and was not: it needed a record of who was here BEFORE, and there
	# is no before when the lead is first pushed in. Plugging one into two
	# consoles that were already running -- the most ordinary thing anyone does
	# with a cable -- restarted neither of them, and the link carried nothing.
	if live.size() >= 2:
		_restart(live)


func _ride_junction() -> void:
	var junction := get_node_or_null("Junction") as Node3D
	if junction == null or _rope == null:
		return
	# Typed out rather than inferred, all three. VerletRope is a GDExtension, so
	# what its methods return is only known to the parser where the extension is
	# loaded and registered. It is on the desktop editor, which is why this read
	# fine here for months; it was not on the Quest, and inferring a variable
	# from a Variant is a hard parse ERROR rather than a warning, so the whole
	# script failed to load on device and took the cable with it.
	var n: int = _rope.point_count()
	if n < 3:
		return

	# One particle short of the end, so there is always a next one to take the
	# cord's direction from.
	var i: int = clampi(int(round(JUNCTION_AT * float(n - 1))), 0, n - 2)
	var here: Vector3 = _rope.point_position(i)
	var ahead: Vector3 = _rope.point_position(i + 1)
	var along := ahead - here
	if along.length_squared() < 1e-8:
		return

	junction.global_position = here
	# -Z runs along the cord, which leaves the socket facing out of the block's
	# side rather than back down the wire it is moulded into.
	#
	# The up vector is CARRIED from the last tick and squared against the cord,
	# rather than taken from world UP each time. A lead hanging off a machine
	# runs straight down through its own junction, and look_at has no roll to
	# give when the cord and the up vector lie on the same line: it warns about
	# colinear vectors and picks. Measured with the cord swung through vertical,
	# the block snapped 65 deg in a single tick and threw the plug seated in it
	# 18.6 mm with it. Carried forward, the roll is continuous through vertical
	# and there is no line to be colinear with.
	var dir := along.normalized()
	var up := _junction_up - dir * dir.dot(_junction_up)
	if up.length_squared() < 1e-6:
		# The carried up has drifted onto the cord itself. Any perpendicular
		# restarts it; the next tick carries on from wherever that lands.
		up = dir.cross(Vector3.RIGHT if absf(dir.x) < 0.9 else Vector3.FORWARD)
	_junction_up = up.normalized()
	junction.look_at(here + dir, _junction_up)


func _disconnect() -> void:
	# Cleared first, and the ends read straight out of the dictionary.
	#
	# Binding a freed object to a typed variable faults before is_instance_valid
	# ever gets to answer, so the guard has to come first, and a fault partway
	# through would otherwise leave the cable still believing it was joined. A
	# machine really can go away between joining and pulling: carried out of the
	# room, or the whole room torn down.
	var ends := _linked
	if ends.is_empty():
		return
	_linked = []
	for end: Dictionary in ends:
		if is_instance_valid(end["libretro"]):
			end["libretro"].LinkDisconnect(end["port"])
	# After the disconnects, so the count reported is the one that resulted.
	_log_ends("parted", ends)


func _exit_tree() -> void:
	# A cable carried out of the room, or a scene change, still counts as
	# pulling it. Leaving the cores joined would hold each other up over a lead
	# that no longer exists.
	_disconnect()

	# And the leads it was chained to have to rebuild whatever is left. Deferred,
	# because this one is still half in the tree and a wire walk performed now
	# would walk straight back into it.
	for c in _wire:
		if c != self and is_instance_valid(c):
			c.call_deferred("_resolve")
	_wire = []
