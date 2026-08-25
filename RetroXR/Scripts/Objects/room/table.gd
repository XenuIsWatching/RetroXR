## Table — a pickable wooden table that can be carried and set down anywhere.
##
## It was inline scenery in the arcade until it became a spawnable object, and the
## one thing that had to change on the way out is collision: the old node had a
## single box over the top slab, so a hand, a controller ray and anything dropped
## beside it all passed straight through the legs. Every leg carries its own shape
## here, which is what makes it a table you can put something UNDER.
##
## Pose is the whole of its state, so it needs no save/load arm beyond a branch in
## ScenePersistence — the class exists to give that branch something to match on.
class_name Table
extends XRToolsPickable


func _ready() -> void:
	super._ready()
