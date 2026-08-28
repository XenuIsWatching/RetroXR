class_name PowerCord
extends Node3D

## Which end of the lead a plug is. The wall end is the one with the pins that go
## into the room; the appliance end is the one that goes into the machine. Saved
## as an integer beside each plug, so the two must not be renumbered.
enum End { WALL = 0, APPLIANCE = 1 }

@onready var rope: VerletRope = $VerletRope
@onready var wall_plug: RcaPlug = $WallPlug
@onready var appliance_plug: RcaPlug = $AppliancePlug

func _ready() -> void:
	wall_plug.cable = self
	appliance_plug.cable = self
	call_deferred("_build_rope")

func _build_rope() -> void:
	if not is_inside_tree():
		return
	rope.start_node = wall_plug
	rope.end_node = appliance_plug
	rope.start_anchor_offset = wall_plug.cable_anchor
	rope.end_anchor_offset = appliance_plug.cable_anchor
	rope._init_points()

func on_plug_seating_changed() -> void:
	pass


# ── Persistence ────────────────────────────────────────────────────────────────
#
# Deliberately the same record shape a CompositeCable writes: an "end" and a
# "cord", a pose, and the socket as a device reference plus the socket's node
# name. Same shape means the same slot validator, the same two-pass restore and
# the same reader, and it is why a mains lead is filed under the "composite_cable"
# entry type despite carrying no signal. The alternative was a second entry type
# whose every field happened to be identical.
#
# Until this existed a mains lead was not saved AT ALL. ScenePersistence only ever
# serialized a lead that `is CompositeCable`, which a PowerCord is not, so it fell
# through to the empty entry and vanished on reload, while the restore side had
# carried a branch for all three cord scenes since they were baked, waiting for a
# writer that was never wired up.


## One cord, two ends. The count is what a save uses to pick a lead back up when
## its "kind" is from a build that no longer ships it.
func cord_count() -> int:
	return 1


## The connector at one end, or null for an index that is not an end.
func plug_at(end: int) -> PowerPlug:
	match end:
		End.WALL:
			return wall_plug as PowerPlug
		End.APPLIANCE:
			return appliance_plug as PowerPlug
	return null


## Where both ends are right now, one record per plug.
func seating() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: int in [End.WALL, End.APPLIANCE]:
		var plug := plug_at(e)
		var socket := socket_holding(plug)
		out.append({
			"plug": plug,
			"end": int(e),
			"cord": 0,
			"device": socket.get_device() if socket != null else null,
			"port": String(socket.name) if socket != null else "",
		})
	return out


## The mains socket holding this plug, or null when it is loose.
##
## Asked of the SOCKETS rather than of the plug, exactly as RcaPlug.seated_port
## does and for the same reason: `picked_up_object` is the zone's own account of
## what it has, so a plug that was dropped, stolen by another zone or freed
## cannot leave a stale socket behind.
static func socket_holding(plug: Node3D) -> PowerPort:
	if plug == null or not plug.is_inside_tree():
		return null
	for node in plug.get_tree().get_nodes_in_group(PowerPort.GROUP):
		var port := node as PowerPort
		if port != null and port.picked_up_object == plug:
			return port
	return null


## Stand both connectors where they were left, seating neither.
##
## Called a whole pass before the seating, as CompositeCable's is, because a pose
## needs nothing from the rest of the room and the rope lays itself out around
## these two at the end of the frame the lead spawns in. Left until pass 2 the
## cord hangs in mid-air over wherever the lead was spawned for as many frames as
## the restore takes to reach it.
func restore_plug_poses(seats: Array) -> void:
	for seat: Dictionary in seats:
		var plug := plug_at(int(seat.get("end", 0)))
		if plug == null:
			continue
		var pos: Array = seat.get("position", [])
		var rot: Array = seat.get("rotation", [])
		if pos.size() == 3:
			plug.global_position = Vector3(pos[0], pos[1], pos[2])
		if rot.size() == 3:
			plug.global_rotation_degrees = Vector3(rot[0], rot[1], rot[2])


## Put both ends back: seat the one that names a socket, drop the other where it
## was saved.
##
## Deferred a frame, because the rope is built deferred from _ready and seating a
## plug before that happens has _init_points bake the particles around a plug that
## is about to move again.
func restore_seating(seats: Array) -> void:
	call_deferred("_apply_seating", seats)


func _apply_seating(seats: Array) -> void:
	restore_plug_poses(seats)
	for seat: Dictionary in seats:
		var plug := plug_at(int(seat.get("end", 0)))
		var device: Node3D = seat.get("device")
		var port_name := str(seat.get("port", ""))
		if plug == null or device == null or not is_instance_valid(device) \
				or port_name.is_empty():
			continue
		# A socket that cannot be found leaves the plug where it was saved. A loose
		# end on the floor beats one seated in the wrong machine.
		var port := CompositeCable.port_named(device, port_name)
		if port != null:
			port.pick_up_object(plug)
