## Vanish — shrink an object away, then free it.
##
## Deleting a world object used to be instantaneous: the frame a pickable was
## released into the storage box it simply stopped existing, which reads as a
## glitch rather than as a deletion. Everything the player can delete goes
## through here instead, so the object collapses to nothing over a third of a
## second and is freed at the end of that.
##
## The caller keeps its own teardown. This replaces the TERMINAL queue_free()
## and nothing else — a system is still powered off, foreign captive plugs are
## still released and owned cables are still freed, all before the shrink
## starts. Cables themselves are NOT routed through here: a VerletRope is a
## native particle sim rather than a mesh, and scaling its anchor does not read
## as the cord shrinking.
##
## Bulk teardown (SceneManager clearing a room, ObjectSync clearing the world)
## deliberately still frees on the spot — an animation there would leave the
## outgoing room's nodes racing the incoming one's.
class_name Vanish
extends Object

const DURATION := 0.3

## Earth gravity, so the drop reads as a real fall rather than a slide. Godot's
## own default 3D gravity, not a number picked to look right.
const FALL_GRAVITY := 9.8

## Marks a node already on its way out. Both the storage box's overlap poll and
## a snap zone can reach the same object, and the second call must be a no-op
## rather than a second tween fighting the first.
const META := "vanishing"

## Set while a whole room is being torn down. Bulk teardown reaches the same
## drop_and_free() every deleted object does, and there an animation would leave
## the outgoing room's nodes alive for a third of a second, racing the incoming
## room's — so while this is up, free_node() frees on the spot. Always restore it
## in the same function that raised it.
static var instant := false


## True once free_node() has taken this object. Callers that walk a set of
## objects can use it to skip one that is already going.
static func is_vanishing(node: Node) -> bool:
	return is_instance_valid(node) and node.has_meta(META)


## Shrink `node` to nothing and free it. Safe to call twice. Anything without a
## transform has no scale to shrink and is simply freed.
static func free_node(node: Node, duration: float = DURATION) -> void:
	if not is_instance_valid(node) or node.is_queued_for_deletion():
		return
	if node.has_meta(META):
		return
	var spatial := node as Node3D
	if spatial == null or instant:
		node.queue_free()
		return
	spatial.set_meta(META, true)

	# Nothing may touch it while it shrinks: it must not be grabbed again, and it
	# must not be re-detected by the box that is deleting it.
	_neutralise(spatial)

	# Created from the node, so the tween dies with it if something frees the
	# object out from under us anyway.
	var tween := spatial.create_tween()
	tween.set_parallel(true)
	tween.tween_property(spatial, "scale", Vector3.ONE * 0.001, duration) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)

	# And it falls while it goes, instead of hanging in the air.
	#
	# Integrated here rather than handed back to the physics server, which is not
	# a preference: a RigidBody's transform is written from the server every tick
	# and that transform carries no scale, so an unfrozen body would have the
	# shrink wiped out from under it each frame. The body stays frozen and the
	# drop is authored — real gravity, from a standing start, which over the
	# 0.3 s of the animation is about 0.44 m.
	#
	# It keeps no collision (see _neutralise), so it falls THROUGH the box's base
	# and the floor rather than landing on them. That is the point: something
	# being deleted should sink out of the world, not settle onto it.
	var start := spatial.global_position
	tween.tween_method(func(t: float) -> void:
		if not is_instance_valid(spatial):
			return
		spatial.global_position = start - Vector3(0.0, 0.5 * FALL_GRAVITY * t * t, 0.0),
		0.0, duration, duration)

	tween.finished.connect(func() -> void:
		if is_instance_valid(spatial):
			spatial.queue_free())


## Take the object out of the simulation without stopping its processing — a
## tween created from a node is governed by that node's process mode, so
## disabling it would stall the shrink half way.
static func _neutralise(node: Node3D) -> void:
	var body := node as RigidBody3D
	if body != null:
		body.freeze = true
	# Deferred: a release can land inside a physics callback, where changing a
	# body's layers is not allowed.
	for child in _self_and_descendants(node):
		var col := child as CollisionObject3D
		if col != null:
			col.set_deferred("collision_layer", 0)
			col.set_deferred("collision_mask", 0)
		var area := child as Area3D
		if area != null:
			area.set_deferred("monitoring", false)
			area.set_deferred("monitorable", false)


static func _self_and_descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = [node]
	out.append_array(node.find_children("*", "", true, false))
	return out
