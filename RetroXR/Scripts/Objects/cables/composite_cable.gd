## A 1.8 m composite A/V lead: three cords moulded into one ribbon, each ending in
## its own plug at both ends, all six free.
##
## ── What decides the signal ──────────────────────────────────────────────────
## A cord is a plain WIRE. It has a colour, and the colour means nothing: what a
## cord carries is whatever is on the socket its far end sits in. So
##
##   * video reaches the set only when a cord joins the deck's VIDEO socket to the
##     television's VIDEO socket — any cord, the yellow one by convention,
##   * the yellow cord run between the two L sockets carries the left channel and
##     works perfectly,
##   * and a cord from the deck's L to the set's R puts the left channel out of the
##     right-hand speaker, which is exactly what happens if you do it for real.
##
## None of that is special-cased. _resolve reads the two ports each cord lands in
## and reports the pairs; every device decides for itself what to do with them.
##
## ── The rope ────────────────────────────────────────────────────────────────
## One VerletRope with ribbon_count 3, frayed into three groups at BOTH ends, so
## the trunk is a single simulated chain that breaks out into three short tails
## per end. The trunk's terminal particles are left unanchored on purpose — the
## plugs carry the breakout, the way an unsupported junction behaves on the real
## lead. See the ribbon note at the top of verlet-rope/src/VerletRope.hpp.
class_name CompositeCable
extends Node3D


## Whether a running lockstep game has taken this lead's join/pull decision.
##
## Shared by all three link leads, because the rule is about the SESSION rather
## than about the lead's shape: seating or pulling a link plug changes
## deterministic state on both cores, and applying it the instant a hand moves
## lands it on a different emulated frame on every peer. Both peers are then
## wrong in the same way, so the CRC checker cannot even call it a desync.
## LinkCoordinator says as much itself — the one thing it cannot enforce is that
## Connect and Disconnect happen on the same emulated frame everywhere, and that
## it is the caller's job.
##
## `join` is the bus the lead would make now, `held` the one it is still holding
## (a pull has nothing to walk to). Every machine involved must be in the
## session: a lead half in one is a bus the session cannot schedule, and joining
## it locally anyway is the fork this exists to avoid. True means the caller
## must do nothing else — the host has scheduled it and every peer, this one
## included, applies it on the agreed frame.
var _netplay_held: Array = []
## Test seam for the deterministic topology policy. Runtime always uses the
## NetworkManager autoload.
var netplay_manager_override: Object = null


func netplay_took_bus(join: Array, held: Array) -> bool:
	var manager: Object = netplay_manager_override if netplay_manager_override != null \
		else NetworkManager
	if not manager.netplay_running():
		_netplay_held.clear()
		return false
	var is_join := join.size() >= 2
	var entries: Array = join if is_join else held
	# A scheduled join has not updated the cable's ordinary `_linked` cache yet.
	# If the player pulls it again inside LINK_LEAD, retain the intended bus here
	# so the inverse operation can cancel it at the next agreed boundary.
	if entries.is_empty() and not is_join:
		entries = _netplay_held
	if entries.is_empty():
		return false
	var covered := 0
	for entry: Dictionary in entries:
		if manager.netplay_covers(entry.get("machine")):
			covered += 1
	if covered == 0:
		return false
	if covered != entries.size():
		# Never fall through to an immediate local join when only one endpoint is
		# deterministic.  That forks this peer from the rest of the session.
		if manager.is_host():
			push_warning("[Netplay] cable touches a machine outside the session; topology change refused")
		return true
	if is_join and _same_netplay_bus(_netplay_held, entries):
		return true
	if manager.is_host():
		manager.netplay_schedule_link(1 if is_join else 0, entries)
	if is_join:
		_netplay_held = entries.duplicate(true)
	else:
		_netplay_held.clear()
	return true


func _same_netplay_bus(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		var left: Dictionary = a[i]
		var right: Dictionary = b[i]
		if left.get("machine") != right.get("machine") \
				or int(left.get("port", 0)) != int(right.get("port", 0)):
			return false
	return true


## The bus this lead makes, as [{machine, port}], or [] for a lead that joins
## nothing. Overridden by every lead that can put two cores on a wire.
func linked_machines() -> Array[Dictionary]:
	return []


## The bus this lead is still HOLDING, in the same shape. A pull has to name the
## machines it was joined to, because by then the walk finds nothing.
func held_machines() -> Array[Dictionary]:
	return []


## Emitted whenever a plug is seated or pulled, after the devices have been told.
signal topology_changed

## Cord colours, in cord order — the PLUG BODIES are tinted from this, so a cord
## can be recognised at either end.
##
## Set per scene rather than fixed here: the full lead is yellow/white/red, while
## the mono lead a console like the NES uses is yellow and RED, video and the one
## audio channel that hardware has.
@export var cord_colors: PackedColorArray = PackedColorArray([
	RcaJack.COMPOSITE_YELLOW,
	RcaJack.AUDIO_WHITE,
	RcaJack.AUDIO_RED,
])

## The jacket every cord wears. Deliberately NOT cord_colors: a real composite
## lead is black sheath with colour-coded CONNECTORS, and the connector is what a
## player matches to a socket. Both used to be drawn from cord_colors, which made
## the lead itself a yellow/white/red tricolour no such cable has ever been.
@export var wire_color: Color = RcaJack.WIRE_BLACK

# How many cords this lead actually has, counted from the plugs the scene ships
# rather than declared, so a two-cord lead is a scene with four plugs and no code
# of its own.
var _cords: int = 0

## How far a remotely-unplugged end is drawn out of its socket, in metres. Clear of
## the 60 mm grab distance every RcaPort uses, so it cannot be snapped straight back
## up. See net_release_plug.
const PULLED_CLEAR := 0.12

## Ends of the lead, used only to name things.
enum End { A, B }

@onready var _rope: VerletRope = $VerletRope

# Plugs, [end][cord]. Populated in _ready from the scene's fixed node names. On a
# SHARED end every entry is the same node — see _count_cords.
var _plugs: Array = []

# Ends whose cords all leave through ONE connector: the Wii's AV Multi Out is a
# single shell carrying picture and both audio channels. Nothing about the ROUTING
# changes — three cords still land in three sockets at the far end, and the Multi Out
# answers each of them differently through RcaPort.channel_for — but everything that
# iterates plugs has to stop counting the same node three times.
var _shared := [false, false]

# Devices told about this cable last time round, so one that has just lost its
# last cord still gets a final update telling it so.
var _last_devices: Array[Node3D] = []

# Where each end sat at the last resolve, keyed "end:cord" — the baseline the
# netplay diff in _report_seating_changes works against.
var _last_seating := {}

# The rope is built a frame after _ready (see there). Until it is, its particles
# are a default cord around the origin and the tether must not read them.
var _rope_built := false


func _ready() -> void:
	add_to_group("spawned")
	_cords = _count_cords()
	_plugs = [[], []]
	for e in [End.A, End.B]:
		_shared[e] = _cords > 1 and get_node_or_null("Plug%s1" % "AB"[e]) == null
		for c in _cords:
			var plug := get_node("Plug%s%d" % ["AB"[e], 0 if _shared[e] else c]) as RcaPlug
			_plugs[e].append(plug)
			if _shared[e] and c > 0:
				continue        # same node: wiring it again would double-connect
			plug.cord = c
			plug.cable = self
			# A plug leaving or arriving anywhere changes what this lead carries.
			# grabbed(pickable, by) covers a socket taking it, dropped(pickable) a
			# socket or a hand letting it go.
			plug.grabbed.connect(_on_plug_moved.unbind(2))
			plug.dropped.connect(_on_plug_moved.unbind(1))
			# A shared connector belongs to no single cord, so it gets no cord colour.
			# The Multi Out shell is grey on the real lead and stays grey here.
			if not _shared[e]:
				_tint_plug(plug, _cord_color(c))
	# Deferred, NOT called straight through. VerletRope is top_level and its
	# particles are world-space, so _init_points bakes them around wherever the
	# plugs stand at the time. _ready runs inside add_child, and the spawn menu
	# positions what it spawned on the line AFTER that
	# (spawn_menu_controller.gd::_place_spawned) — so building here pins the cable
	# to the world origin while the plugs travel on to the menu, and the tether
	# below then hauls them back to the middle of the room. Every other cable
	# owner dodges this by calling _init_points itself once it has placed its
	# plug; a self-contained spawnable has to wait the frame out.
	call_deferred("_build_rope")
	# Ports fire on the frame the plug seats; resolve once the room is up so a
	# cable restored into sockets reports what it is already carrying.
	call_deferred("_resolve")


## How many cords the scene ships, counted as PlugA0, PlugA1, … until BOTH ends run
## out. A lead is then defined entirely by its scene: four plugs make a mono lead, six
## make the full one, and neither needs a script of its own.
##
## Counted from the LONGER end, not from both agreeing, because the two ends of a lead
## do not have to have the same number of connectors on them. The Wii's lead is one
## Multi Out shell against three phonos — three cords, four plugs — and requiring both
## sides would have counted it as one. An end that runs out early is SHARED: all its
## cords leave through its single PlugX0. See _shared.
func _count_cords() -> int:
	var n := 0
	while get_node_or_null("PlugA%d" % n) != null or get_node_or_null("PlugB%d" % n) != null:
		n += 1
	return n


## The distinct plugs on one end — three on an ordinary end, one on a shared one.
## Anything that walks connectors rather than cords wants this: seating them, dropping
## them, clamping them to the rope. Anything that walks CORDS still wants _plugs.
func _end_plugs(e: int) -> Array:
	return [_plugs[e][0]] if _shared[e] else _plugs[e]


## Colour for one cord, falling back to the palette's last entry if a scene ships
## more cords than colours.
func _cord_color(c: int) -> Color:
	if cord_colors.is_empty():
		return RcaJack.COMPOSITE_YELLOW
	return cord_colors[mini(c, cord_colors.size() - 1)]


## Colour a plug body to its cord, so the same wire can be recognised at both ends.
##
## Surface 0 of the baked plug is the plastic and surface 1 the metal — the split
## exists for exactly this (see Tools/gen/gen_rca_plug.gd). The baked material is shared
## by every plug in the room, so it is duplicated before a colour goes into it.
func _tint_plug(plug: RcaPlug, col: Color) -> void:
	var tip := plug.get_node_or_null("PlugTip") as MeshInstance3D
	if tip == null:
		return
	# The bake wears Shaders/connector.gdshader: the colour is an instance
	# parameter on one shared material, not a copy of it. Same rule as
	# RcaJack._apply_color and CablePlug._apply_plug_color.
	tip.set_instance_shader_parameter(&"tint", col)


## Wire the ribbon to its six plugs. Both ends fray into one group per cord, so
## every cord gets its own tail and its own anchor.
func _build_rope() -> void:
	if not is_inside_tree():
		return          # a netplay client's local copy is freed before we get here
	if _rope == null or _cords == 0:
		# A lead with no cord, or none of the rope a scene is supposed to ship,
		# has nothing to build. Only a bare `.new()` reaches this — every lead in
		# the room comes from a scene that carries both — but it is worth
		# surviving rather than writing through a null, because that is what a
		# unit test constructs and the failure is a stack trace rather than a
		# missing cable.
		return
	# One cord is one rope. The ribbon path below would build a trunk plus a single
	# fray tail meeting at a junction nothing holds — geometry a one-wire lead does
	# not have, and a VGA lead is exactly that. Both ends anchor straight to their
	# plugs instead, which is also what every captive lead in the project does.
	if _cords == 1:
		_rope.fray_segments_start = 0
		_rope.fray_segments_end = 0
		_rope.start_node = _plugs[End.A][0]
		_rope.end_node = _plugs[End.B][0]
		# End at the connector's cable boss rather than at the plug's origin, which
		# sits at the mating face well forward of where the cord actually enters.
		_rope.start_anchor_offset = (_plugs[End.A][0] as RcaPlug).cable_anchor
		_rope.end_anchor_offset = (_plugs[End.B][0] as RcaPlug).cable_anchor
		_rope._init_points()
		_rope_built = true
		return
	_rope.ribbon_count = _cords
	# Every cord in the same jacket — see wire_color.
	var jackets := PackedColorArray()
	for c in _cords:
		jackets.append(wire_color)
	_rope.ribbon_colors = jackets
	# Read in the START anchor's local space. The lead has no start anchor once
	# both ends fray, so this is world: the ribbon lies flat across X.
	_rope.ribbon_axis = Vector3(1, 0, 0)
	var groups := PackedInt32Array()
	for c in _cords:
		groups.append(c)
	# A SHARED end does not fray. Its three cords are inside one shell, so there is no
	# breakout to draw and the trunk anchors straight to the connector — which is
	# exactly what the one-cord path above does, and for the same reason. Only the end
	# with a connector per cord splits, and it splits by the same count any other lead
	# uses. An ordinary end frays into one tail per cord and the trunk ends at a
	# junction nothing holds.
	#
	# The zero fray count that leaves behind is REAL and _physics_process has to know
	# it: that clamp reads a fray count as a reach, and reading the wrong end's turned
	# the far end's reach to zero and dragged its plugs across the room.
	if _shared[End.A]:
		_rope.fray_segments_start = 0
		_rope.start_node = _plugs[End.A][0]
		_rope.start_anchor_offset = (_plugs[End.A][0] as RcaPlug).cable_anchor
	else:
		_rope.fray_start_groups = groups
		_rope.start_node = null
		for c in _cords:
			_rope.set_fray_start_node(c, _plugs[End.A][c])
			# End the tail at the connector's cable boss rather than at the plug's
			# origin, which sits 40 mm forward at the collar.
			_rope.set_fray_start_anchor_offset(c, _plugs[End.A][c].cable_anchor)
	if _shared[End.B]:
		_rope.fray_segments_end = 0
		_rope.end_node = _plugs[End.B][0]
		_rope.end_anchor_offset = (_plugs[End.B][0] as RcaPlug).cable_anchor
	else:
		_rope.fray_end_groups = groups
		_rope.end_node = null
		for c in _cords:
			_rope.set_fray_end_node(c, _plugs[End.B][c])
			_rope.set_fray_end_anchor_offset(c, _plugs[End.B][c].cable_anchor)
	_rope._init_points()
	_rope_built = true


## Keep every loose plug within its branch's reach of the breakout it hangs off.
##
## A pinned rope particle has inverse mass zero, so a plug drives the rope and the
## rope can never drive a plug. Without this, picking up one plug and walking away
## leaves the other five exactly where they were while the cable stretches without
## limit — the trunk cannot pull them because there is nothing to pull with. Every
## other cable owner in the project clamps its plug the same way (see
## system.gd::_physics_process); a lead with six free ends just needs six of them,
## measured against the breakout rather than against a host's attach point.
##
## A hard clamp rather than a force: over-extension here reaches a metre or more,
## and a spring stiff enough to drag a 50 g plug off the floor at that distance
## launches it. VerletRope.anchor_pull is the soft version and stays available.
##
## Plugs held by a hand, a laser or a socket are skipped — something else owns
## their transform, and fighting it either jitters the plug or pulls it out. The
## laser has to be in that list: a fray branch reaches 0.15 m, so clamping a
## beam-held plug to a junction lying on the floor pins it there, and the junction
## only follows at the speed the rope solver drags it — which reads as the plug
## hanging back under its own weight rather than coming to the beam.
func _physics_process(_delta: float) -> void:
	if not _rope_built or _rope == null or _plugs.is_empty():
		return
	# A one-cord lead has no breakouts to measure against — the two plugs ARE the
	# rope's ends. So each loose end is clamped to the whole rest length from the
	# other one, which is the same rule every host applies between its attach point
	# and its plug (see system.gd::_physics_process).
	if _cords == 1:
		_clamp_pair()
		return
	var pts: PackedVector3Array = _rope.get_points()
	if pts.size() <= _rope.segment_count:
		return
	var seg: float = _rope.fray_segment_length
	if seg <= 0.0:
		seg = _rope.segment_length
	# PER END. This read fray_segments_start alone, on the reasoning that both ends
	# fray by the same count — which stopped being true the moment a lead could have a
	# shared end, since that end frays by none. The Wii lead then took its ZERO from
	# the Multi Out and applied it to the phono end, and the clamp below — a hard
	# positional clamp, not a spring — glued all three phonos onto the trunk's end
	# particle and dragged them across the room with it.
	var reach := [
		float(_rope.fray_segments_start) * seg,
		float(_rope.fray_segments_end) * seg,
	]
	# The breakouts are the trunk's own end particles.
	var junction := [pts[0], pts[_rope.segment_count]]
	for e in [End.A, End.B]:
		# A shared end IS the rope's own anchor rather than a branch hanging off a
		# breakout, so the rope already follows it and there is nothing to clamp. Its
		# reach above is zero for exactly that reason, and running the clamp on it
		# would read that zero as "hold this plug on the junction".
		if _shared[e]:
			continue
		for plug: RcaPlug in _end_plugs(e):
			if plug.is_held():
				continue
			# The branch ends at the cord boss, not at the plug's origin, which
			# sits 40 mm forward at the collar.
			var boss: Vector3 = plug.global_transform * plug.cable_anchor
			var away: Vector3 = boss - junction[e]
			var d: float = away.length()
			var r: float = reach[e]
			if d <= r or d < 0.0001:
				continue
			_clamp_move(plug, away * ((r - d) / d))


## Keep the two ends of a one-cord lead within its rest length of each other.
##
## Only the LOOSE end moves: a plug held by a hand, a laser or a socket has
## something else owning its transform, and fighting that either jitters it or
## pulls it out. With both ends held there is nothing to do — the cord is simply
## stretched, which is what happens if two people walk apart with one between them.
func _clamp_pair() -> void:
	var a: RcaPlug = _plugs[End.A][0]
	var b: RcaPlug = _plugs[End.B][0]
	if not is_instance_valid(a) or not is_instance_valid(b):
		return
	# With BOTH ends held — one in a socket, one in a hand — there is nothing to
	# move: something else owns each transform, and the reach is the hand's problem
	# rather than the cable's. Otherwise the held end is the anchor; with neither
	# held, end A stands in as one, so a lead lying on the floor still cannot be
	# dragged apart by its own physics.
	if a.is_held() and b.is_held():
		return
	var fixed: RcaPlug = a
	var loose: RcaPlug = b
	if b.is_held():
		fixed = b
		loose = a
	var reach: float = float(_rope.segment_count) * _rope.segment_length
	# Measured boss to boss, not origin to origin: the cord leaves each hood some
	# 50 mm behind the mating face, and that is the span the rope actually has.
	var from: Vector3 = fixed.global_transform * fixed.cable_anchor
	var to: Vector3 = loose.global_transform * loose.cable_anchor
	var away: Vector3 = to - from
	var d: float = away.length()
	if d <= reach or d < 0.0001:
		return
	_clamp_move(loose, away * ((reach - d) / d))


## Move a clamped plug with a SWEPT motion, sliding along whatever it meets.
## The clamp used to write global_position directly, which bypasses collision
## entirely; the physics server happens to rescue steps smaller than the
## obstacle's half-thickness, so no tunnel was ever reproduced from this write
## alone at hand speeds — but that rescue is luck of scale, not a contract, and
## an uncollided write composes badly with everything else that repositions a
## plug (the rope's plug alignment carried one through a floor before its step
## was capped). Swept is strictly safer and costs one query.
func _clamp_move(plug: RcaPlug, motion: Vector3) -> void:
	var hit := plug.move_and_collide(motion)
	if hit != null:
		plug.move_and_collide(hit.get_remainder().slide(hit.get_normal()))


func _on_plug_moved() -> void:
	# A grab or a drop lands before the snap zone has taken or released the plug,
	# so read the ports next frame.
	call_deferred("_resolve")


## Called by an RcaPort when it takes or releases one of this lead's plugs. The
## socket is the authority on seating — see the note in RcaPort._ready — so this is
## the signal that actually keeps the routing honest; the plug's own grab signals
## are a belt-and-braces second path to the same resolve.
func on_plug_seating_changed() -> void:
	call_deferred("_resolve")


## Undo whatever _resolve() joined at the CORE level. A plain A/V lead has
## nothing to undo — its cords are re-read from scratch every _resolve() — so
## the base is a no-op and the three leads that put two cores on one emulated
## wire override it.
func _disconnect() -> void:
	pass


## Tear the join down and build it again from scratch.
##
## Public because a machine whose core has just been stopped and restarted needs
## exactly this and has no business knowing how a cable does it. RetroSystem
## used to reach in and call `_disconnect` then `_resolve` by name, guarded by
## has_method() on both — two private names spelled out in another class, where
## a rename turns the whole rejoin into a silent skip rather than an error.
##
## Why not a plain _resolve(): a link cable's cached endpoints still name the
## same Libretro nodes, so resolving alone is a no-op, while StopContent has
## already removed those nodes from LinkCoordinator. The disconnect is what
## makes the rejoin real.
##
## Lives on the base, not on LinkCable, because GcGbaCable and PsxLinkCable are
## link leads too and each defines its own _disconnect/_resolve pair. Given only
## to LinkCable, they would silently stop being rejoined.
func rejoin() -> void:
	_disconnect()
	_resolve()


## Work out what each cord joins, and tell every device involved.
##
## Reported as a list of {out_port, in_port} pairs — direction sorted here so a
## device never has to care which end of the lead it is on, and a cord between two
## outputs (or two inputs, or one loose end) is simply left out.
func _resolve() -> void:
	if not is_inside_tree():
		return
	var resolved: Array[Dictionary] = []
	var devices: Array[Node3D] = []
	for c in _cords:
		var pa: RcaPort = (_plugs[End.A][c] as RcaPlug).seated_port()
		var pb: RcaPort = (_plugs[End.B][c] as RcaPlug).seated_port()
		if pa == null or pb == null:
			continue
		var out_port: RcaPort = null
		var in_port: RcaPort = null
		if pa.direction == RcaPort.Direction.OUT and pb.direction == RcaPort.Direction.IN:
			out_port = pa
			in_port = pb
		elif pb.direction == RcaPort.Direction.OUT and pa.direction == RcaPort.Direction.IN:
			out_port = pb
			in_port = pa
		else:
			continue        # source to source, or sink to sink: carries nothing
		resolved.append({"out": out_port, "in": in_port, "cord": c})
		for port: RcaPort in [out_port, in_port]:
			var dev: Node3D = port.get_device()
			if dev != null and not devices.has(dev):
				devices.append(dev)

	# Devices that were carrying something and now are not have to hear about it
	# too, or a pulled cord leaves a picture on the screen.
	for dev in _last_devices:
		if is_instance_valid(dev) and not devices.has(dev):
			devices.append(dev)
	_last_devices = devices.duplicate()

	for dev in devices:
		if is_instance_valid(dev):
			dev.on_av_topology_changed(resolved)
	_report_seating_changes()
	topology_changed.emit()


## Tell the other players which ends moved.
##
## Diffed against the last seating rather than reported from the socket hook: the
## hook fires for every take and release, including the pair a single re-patch
## produces, while a diff sends one event per end that actually ended up somewhere
## new. It is also self-correcting — a peer applying an event re-enters here with
## report_event suppressed, so its own map lands on the same state either way.
func _report_seating_changes() -> void:
	var now := {}
	for seat: Dictionary in seating():
		var key: String = "%d:%d" % [seat["end"], seat["cord"]]
		var dev: Node3D = seat["device"]
		var where: String = "" if dev == null else "%s/%s" % [dev.get_path(), seat["port"]]
		now[key] = where
		if _last_seating.get(key, "") == where:
			continue
		if dev == null:
			NetworkManager.report_event(NetEvents.Event.EV_RCA_UNPLUG,
				{"cable": self, "end": seat["end"], "cord": seat["cord"]})
		else:
			NetworkManager.report_event(NetEvents.Event.EV_RCA_PLUG, {
				"cable": self, "end": seat["end"], "cord": seat["cord"],
				"dev": dev, "port": seat["port"],
			})
	_last_seating = now


# ── Seating: save/restore and netplay ────────────────────────────────────────
#
# One description of where the six ends are, used by both. A seat names the socket
# by its DEVICE and its node NAME ("AudioLIn") rather than by any index: the name
# is stable across scene edits, readable in a save file, and short enough to put on
# the wire.


## How many cords this lead has — 3 for the full composite lead, 2 for the mono
## one. Saved with the seating so a restore rebuilds the right lead: both are this
## same class, told apart only by the plugs their scenes ship.
func cord_count() -> int:
	return _cords


## Where every end is right now, one record per plug.
func seating() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e in [End.A, End.B]:
		# One record per CONNECTOR, not per cord. A shared end has a single plug in a
		# single socket, and three identical records would restore it three times and
		# put three netplay events on the wire for one hand movement.
		for c in (1 if _shared[e] else _cords):
			var plug: RcaPlug = _plugs[e][c]
			var where := _seat_of(plug)
			out.append({
				"plug": plug,
				"end": int(e),
				"cord": c,
				"device": where.get("owner"),
				"port": where.get("port", ""),
			})
	return out


## Where a plug is sitting, as an OWNER node and a socket name under it.
##
## Not "the device and its RcaPort", which is what this used to be and what left
## two kinds of socket unrestorable. A save records the pair, so a socket the
## pair cannot describe is a socket a plug never comes back to, silently: the
## lead reloads lying on the floor and nothing says why.
##
##   * A console's CONTROLLER socket is a plain snap zone, not an RcaPort, so
##     seated_port() finds nothing at all. The plug is the only thing that knows,
##     because RetroSystem tells it when it seats.
##   * A lead's JUNCTION is a real RcaPort, but it belongs to a CABLE, and
##     get_device() walks for a device. It answers get_cable() instead.
##
## Both come back as a node the save file can reference and a name to find under
## it, which is all the restore ever needed.
func _seat_of(plug: RcaPlug) -> Dictionary:
	var port := plug.seated_port()
	if port != null:
		var owner_node: Node3D = port.get_device()
		if owner_node == null and port.has_method("get_cable"):
			owner_node = port.get_cable()
		if owner_node != null:
			return {"owner": owner_node, "port": String(port.name)}
		return {}
	if "seated_system" in plug and is_instance_valid(plug.seated_system) and plug.seated_port_index >= 0:
		# Named by the convention RetroSystem's own scene uses for these zones
		# (ControllerPort1..4, one-based). The plug is handed an index rather
		# than the zone, so the name is rebuilt from it here; if that convention
		# ever moves, this is the line that has to move with it.
		return {"owner": plug.seated_system,
			"port": "ControllerPort%d" % (plug.seated_port_index + 1)}
	return {}


## The socket of that name on this device, wherever it sits underneath it.
##
## NOT get_node_or_null on its own, which only sees a DIRECT child. A socket
## authored into a system MODEL lives at <model>/Back/LineOut and the speaker
## pair's line-in at SpeakerR/LineIn, while RcaPort.get_device() walks UP to the
## RetroSystem and to the SpeakerPair — so the name saved beside the device did
## not resolve from it, and both ends of a 3.5 mm lead came back unseated. Every
## composite lead was fine only because system.gd::_build_av_ports parents its
## phono sockets to the system itself.
##
## The direct child is still tried first: it is the common case, and it keeps a
## model that happens to repeat a socket name from stealing the device's own.
## Typed as a SNAP ZONE rather than an RcaPort, because a console's controller
## socket is one of those and nothing more. Everything done with the result here
## is pick_up_object, which every zone answers.
## Static and public because PowerCord restores its two ends the same way and
## against the same trap: a mains socket is authored into a console's model at
## <model>/Back/PowerPort, so the direct child that a save's device/port pair
## implies is not there either.
static func port_named(device: Node, port_name: String) -> XRToolsSnapZone:
	if device == null or port_name.is_empty():
		return null
	var port := device.get_node_or_null(port_name) as XRToolsSnapZone
	if port != null:
		return port
	return device.find_child(port_name, true, false) as XRToolsSnapZone


## Put the six ends back: seat the ones that name a socket, and drop the rest where
## they were saved.
##
## Deferred a frame, because the lead builds its rope deferred (see _ready) and
## seating a plug before that happens would have _init_points bake the particles
## around plugs that are about to be moved again.
func restore_seating(seats: Array) -> void:
	call_deferred("_apply_seating", seats)


## Stand the connectors where they were left, without seating any of them.
##
## Split out of _apply_seating and called a whole pass earlier (ScenePersistence
## spawns objects in pass 1 and wires them in pass 2), because a pose needs nothing
## from the rest of the room. The rope is built at the end of the frame the lead
## spawns in, so left until pass 2 this leaves the cord laid out around six plugs
## still standing at the pose the lead was first spawned from — mid-air over the
## desk — for however many frames the restore takes to reach them.
func restore_plug_poses(seats: Array) -> void:
	for seat: Dictionary in seats:
		var e: int = int(seat.get("end", 0))
		var c: int = int(seat.get("cord", 0))
		if e < 0 or e > 1 or c < 0 or c >= _cords:
			continue
		var plug: RcaPlug = _plugs[e][c]
		var pos: Array = seat.get("position", [])
		var rot: Array = seat.get("rotation", [])
		if pos.size() == 3:
			plug.global_position = Vector3(pos[0], pos[1], pos[2])
		if rot.size() == 3:
			plug.global_rotation_degrees = Vector3(rot[0], rot[1], rot[2])


func _apply_seating(seats: Array) -> void:
	restore_plug_poses(seats)
	for seat: Dictionary in seats:
		var e: int = int(seat.get("end", 0))
		var c: int = int(seat.get("cord", 0))
		if e < 0 or e > 1 or c < 0 or c >= _cords:
			continue
		var plug: RcaPlug = _plugs[e][c]
		var dev: Node3D = seat.get("device")
		var port_name: String = str(seat.get("port", ""))
		if is_instance_valid(dev) and not port_name.is_empty():
			var port := port_named(dev, port_name)
			if port != null:
				port.pick_up_object(plug)
	# The sockets fire as they take each plug, but a lead restored with nothing
	# seated fires nothing at all — resolve once so the devices hear either way.
	call_deferred("_resolve")


## Seat one end, named the way the wire and the save file name it. Used by netplay
## when another player plugs something in.
func net_seat_plug(end: int, cord: int, device: Node3D, port_name: String) -> void:
	if end < 0 or end > 1 or cord < 0 or cord >= _cords or device == null:
		return
	var port := port_named(device, port_name)
	if port != null:
		port.pick_up_object(_plugs[end][cord])


## Pull one end out, wherever it happens to be.
##
## Dropping is not enough. The player who pulled it has it in their hand; on every
## other peer nothing is holding it, so it is released still standing in the
## socket's grab area and the socket snaps it straight back up — the other player
## would appear to unplug it and plug it in again in the same breath. So it is also
## drawn clear along the socket's own axis, which is the way a hand takes it out.
##
## The transform goes through the physics server as well as the node: the body is
## live again the moment it is dropped, and a transform written only on the node is
## overwritten on the next tick, putting it back in the socket.
func net_release_plug(end: int, cord: int) -> void:
	if end < 0 or end > 1 or cord < 0 or cord >= _cords:
		return
	var plug: RcaPlug = _plugs[end][cord]
	var port := plug.seated_port()
	if port == null:
		return
	# Shut the socket for the release. A snap zone in DROPPED mode listens for the
	# pickable's `dropped` on a DEFERRED connection and takes back anything still
	# listed in its grab area — which this plug is, and stays until a physics frame
	# has run it out. Moving it first does not help; the handler fires afterwards.
	port.enabled = false
	port.drop_object()
	plug.global_position = port.global_position \
		+ port.global_transform.basis.z.normalized() * PULLED_CLEAR
	PhysicsServer3D.body_set_state(plug.get_rid(),
		PhysicsServer3D.BODY_STATE_TRANSFORM, plug.global_transform)
	_reopen_port(port)


## Let the deferred drop handler and the area's body_exited both run before the
## socket is live again. Deliberately not awaited by the caller: the release has
## already happened, and this only reopens the socket behind it.
func _reopen_port(port: RcaPort) -> void:
	await get_tree().physics_frame
	await get_tree().physics_frame
	if is_instance_valid(port):
		port.enabled = true


## Drop every plug before the lead is freed.
##
## ScenePersistence.clear_scene looks for this by name, and its fallback pre-pass
## only knows the child names "CablePlug" and "ControllerPlug" — neither of which
## this lead has. Without it a socket is left holding a freed pickable and
## XRToolsPickable._exit_tree walks a dangling grab driver.
##
## Also used when a lead is binned while the devices it joined stay in the room, so
## the far end has to hear the unplug: the sockets do announce as they release, but
## they announce DEFERRED, and this node is deleted at the end of the frame — ahead
## of the next message flush — so that resolve never runs. Hence the direct call.
func drop_and_free() -> void:
	for e in [End.A, End.B]:
		for plug: RcaPlug in _end_plugs(e):
			var port := plug.seated_port()
			if port != null:
				port.drop_object()
	_resolve()
	queue_free()


## Every link this lead currently carries, for a device that wants to re-read them
## without waiting for a change (a deck coming out of standby, say).
func links() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for c in _cords:
		var pa: RcaPort = (_plugs[End.A][c] as RcaPlug).seated_port()
		var pb: RcaPort = (_plugs[End.B][c] as RcaPlug).seated_port()
		if pa == null or pb == null:
			continue
		if pa.direction == RcaPort.Direction.OUT and pb.direction == RcaPort.Direction.IN:
			out.append({"out": pa, "in": pb, "cord": c})
		elif pb.direction == RcaPort.Direction.OUT and pa.direction == RcaPort.Direction.IN:
			out.append({"out": pb, "in": pa, "cord": c})
	return out
