## One plug on a composite lead — the grabbable end of a single cord.
##
## A cord is a WIRE, and this is one of its two ends. It carries no channel of its
## own: what a cord conducts is decided entirely by the two ports its ends sit in,
## which is why the colour here is cosmetic and any plug fits any socket. The
## routing is worked out in CompositeCable._resolve.
##
## Distinct from CablePlug, which is the single captive plug on a console's
## permanently attached lead and knows the host that owns it. This one is owned by
## a cable, not by a device.
class_name RcaPlug
extends XRToolsPickable


## Which cord of the lead this end belongs to. The plug at the same index on the
## other end is the far end of the same wire.
var cord: int = 0

## The lead this plug belongs to.
var cable: Node3D = null

## Where the cord meets this plug, in plug-local space, for the rope's fray anchor.
## The plug's origin is its SEATING reference and sits at the collar, 40 mm forward
## of where the cord actually enters; anchoring there runs the tail out through the
## barrel. Derived from the mesh, as CablePlug does, so reshaping the connector
## cannot silently desync it.
var cable_anchor: Vector3 = Vector3.ZERO


## The snap group this end answers to, and the ONLY thing deciding which sockets
## will take it. RcaPort declares the matching side, so the two cannot drift.
##
## Overridable because a lead is not always an RCA lead: VgaPlug answers to
## "vga_plug", which is what stops a DE-15 hood being pushed into a phono jack.
## Within a family there is still no further filter — any RCA plug fits any RCA
## socket, by design, see RcaPort.
func plug_group() -> String:
	return "composite_plug"


## What to call this connector when telling a player where it goes.
##
## Overridden alongside plug_group, because the two say the same thing to
## different audiences: one names the group a socket filters on, the other names
## the thing a person is holding. A lead whose two ends fit different sockets is
## unusable without this -- the GameCube lead was reached for by the wrong end
## twice in one evening, and nothing in the room was in a position to say so.
func plug_label() -> String:
	return "a phono plug"


func _ready() -> void:
	super._ready()
	add_to_group(plug_group())
	_derive_cable_anchor()
	picked_up.connect(func(_p: Variant) -> void: PlugAim.aim(self))
	dropped.connect(report_missed_socket)


## Say why a released plug did not land anywhere.
##
## A snap zone that declines an object does nothing at all: no sound, no message,
## no mark in the log. From the player's side a socket that will not take a lead
## is indistinguishable from a socket that is full, one that is switched off, one
## whose console has the wrong systemid, and one that was simply never quite in
## range. That silence has now cost two evenings, once on a GameCube lead that a
## Wii would not accept and once on the same lead again.
##
## So a release that seats nothing looks around and reports what it saw: every
## socket within reach, whether it would have taken this plug, and how far away
## it was. One line, only on a MISS.
##
## Called from BOTH release paths, which is the part that is easy to get wrong. A
## hand emits `dropped`; a ray grab never does, because it is a parallel hold
## mechanism that never calls let_go, so function_pickup calls this itself. Wired
## to one of them only, the diagnostic is silent for exactly the player who most
## needs it: the one on a desktop, holding the lead on the end of a beam.
func report_missed_socket(_p: Variant = null) -> void:
	if not is_inside_tree() or seated_port() != null:
		return
	# A snap zone can hold a plug without it being an RcaPort: a console's
	# controller sockets are plain zones. Landing in one of those is not a miss.
	for zone in XRToolsSnapZone.live_zones():
		if zone.picked_up_object == self:
			return

	# What this plug IS, and where the nearest thing that takes one is, wherever
	# that is in the room. This is the half that was missing and it is the half
	# that answers the question: a player holding the wrong end of a two-ended
	# lead learns nothing from being told the socket in front of them wants
	# something else. They want to know which end they are holding and where it
	# goes.
	var fits: XRToolsSnapZone = null
	var fits_at := INF
	for z in XRToolsSnapZone.live_zones():
		if not is_instance_valid(z) or not z.can_preview(self):
			continue
		var away: float = z.global_position.distance_to(global_position)
		if away < fits_at:
			fits_at = away
			fits = z
	var goes: String
	if fits == null:
		goes = "It is %s, and nothing in this room takes one." % plug_label()
	else:
		goes = "It is %s; the nearest socket that takes one is %s on %s, %s away." % [
			plug_label(), fits.name, _owner_name(fits),
			"%.0f mm" % (fits_at * 1000.0) if fits_at < 1.0 else "%.1f m" % fits_at]

	var reach := 0.25
	var found: Array = []
	for z in XRToolsSnapZone.live_zones():
		if not is_instance_valid(z):
			continue
		var d: float = z.global_position.distance_to(global_position)
		if d > reach:
			continue
		var why := "would take it"
		if not z.enabled:
			why = "switched off"
		elif is_instance_valid(z.picked_up_object):
			why = "already full, holding %s" % z.picked_up_object.name
		elif not z.snap_require.is_empty() and not is_in_group(z.snap_require):
			why = "wants a '%s', this plug is %s" % [z.snap_require, str(get_groups())]
		elif z.snap_filter.is_valid() and not z.snap_filter.call(self):
			why = "the machine refused this plug"
		found.append({"d": d, "text": "%s on %s, %.0f mm: %s" % [
			z.name, _owner_name(z), d * 1000.0, why]})
	# Nearest first, because the nearest is the one being aimed at.
	found.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x["d"] < y["d"])
	if found.is_empty():
		print("[Plug] %s landed in nothing. %s No socket at all was within %.0f mm." % [
			name, goes, reach * 1000.0])
		return
	# The nearest few, because past that it is a list of the furniture. Said out
	# loud rather than trimmed quietly: a cap nobody mentions reads as "that was
	# everything", which is the same silence this exists to break.
	var shown := mini(found.size(), 4)
	var lines: PackedStringArray = []
	for i in range(shown):
		lines.append(str((found[i] as Dictionary)["text"]))
	var rest := "" if found.size() == shown else " (and %d further off)" % (found.size() - shown)
	print("[Plug] %s landed in nothing. %s Sockets in reach: %s%s" % [
		name, goes, "; ".join(lines), rest])


## Whose socket that is, so two handhelds in one room do not both report
## "LinkPort". The machine if there is one, else whatever the socket hangs off.
func _owner_name(zone: Node) -> String:
	var at: Node = zone
	while at != null:
		if at.is_in_group("retro_system"):
			return "%s (%s)" % [at.name, str(at.get("systemid"))]
		at = at.get_parent()
	var parent := zone.get_parent()
	return parent.name if parent != null else "nothing"


func _derive_cable_anchor() -> void:
	var tip := get_node_or_null("PlugTip") as MeshInstance3D
	if tip == null or tip.mesh == null:
		return
	# One rule, stated in PlugExit rather than here as well: an authored CordExit
	# marker if the connector carries one, else the centre of its back face.
	cable_anchor = PlugExit.origin_of(self, tip)


## True while a hand, a laser or a socket owns this plug's pose.
##
## Deliberately not is_picked_up(): the ray grab is a parallel hold mechanism that
## never calls pick_up(), so it reports false for the whole hold — see
## XRToolsFunctionPickup._start_ray_grab_at. Every path that takes a plug freezes
## the body, hand, beam and snap zone alike, so the freeze is the ownership flag.
## Same test HeldObjectPhysics._escape reads, for the same reason.
func is_held() -> bool:
	return freeze


## The socket this plug is currently seated in, or null when it is loose.
##
## Asked of the SOCKETS rather than remembered here, and rather than walked up the
## parent chain: whether a snap zone reparents what it holds is xr-tools' business
## and not something to depend on, while `picked_up_object` is the zone's own
## account of what it has. A plug that is dropped, stolen by another zone or freed
## therefore cannot leave a stale port behind.
func seated_port() -> RcaPort:
	for node in get_tree().get_nodes_in_group(RcaPort.GROUP):
		var port := node as RcaPort
		if port != null and port.seated_plug() == self:
			return port
	return null
