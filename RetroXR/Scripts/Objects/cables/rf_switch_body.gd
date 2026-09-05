## The RXR-003's grey box: the part a player actually picks up.
##
## A pickable and nothing else. Every routing decision belongs to the RfSwitch root
## above it, which is a CompositeCable and already knows how to answer them — this
## exists because a lead has no body to grab and the switch does.
class_name RfSwitchBody
extends XRToolsPickable

const HINT_HEIGHT := 0.07

## The lines printed down the middle of the case, top to bottom. Flush left with
## each other — see _align_print_block.
const PRINT_BLOCK: Array[StringName] = [&"LabelBrand", &"LabelModel", &"LabelMade"]

## Label3D builds its mesh a frame after the text is set, so the first look at
## get_aabb() can come back empty. Give it a few frames before giving up.
const ALIGN_TRIES := 8

var _hint: HeldHint = null
var _align_tries := 0


func _ready() -> void:
	super._ready()
	_hint = HeldHint.attach(self, true, HINT_HEIGHT)
	grabbed.connect(_on_grabbed_signal)
	dropped.connect(_on_dropped_signal)
	call_deferred("_align_print_block")


## Set the three printed lines flush left.
##
## A Label3D centres its text block on its own ORIGIN, so three lines of different
## lengths sharing an x have three different left edges — "RF SWITCH" stood a
## millimetre proud of the other two and "MADE IN JAPAN" a tenth of one.
##
## Measured off the built mesh and applied here rather than baked into rf_switch.tscn
## as three hand-tuned x values, because the widths come from a SystemFont: the face
## is whatever the machine has, and a hard-coded offset that is flush on this one is
## crooked on the next. Anchored on the leftmost edge, so the block keeps the left
## margin the widest line already had.
func _align_print_block() -> void:
	var labels: Array[Label3D] = []
	var left := INF
	for n in PRINT_BLOCK:
		var l := get_node_or_null(NodePath(n)) as Label3D
		if l == null:
			continue
		var ab: AABB = l.get_aabb()
		if ab.size.x <= 0.0:
			# Not shaped yet. Try again next frame rather than aligning to nothing.
			_align_tries += 1
			if _align_tries < ALIGN_TRIES:
				call_deferred("_align_print_block")
			return
		labels.append(l)
		left = minf(left, l.position.x + ab.position.x)
	for l in labels:
		l.position.x = left - l.get_aabb().position.x


func _on_grabbed_signal(_pickable: Node3D, by: Node3D) -> void:
	if _hint:
		_hint.on_grabbed(by)


func _on_dropped_signal(_pickable: Node3D) -> void:
	if _hint:
		_hint.on_dropped()


## Bin the whole switch, not just the box.
##
## StorageBox._delete_with_dependents calls this on any pickable that has it and
## queue_frees it otherwise, and freeing the box alone would leave the root, both
## ropes and both plugs alive with a freed anchor node — the ropes read their
## anchors' global transforms every frame. Binning a PLUG already takes the whole
## switch with it, because plug.cable points at the root and StorageBox._free_lead
## follows it; this is the same rule for the other handle.
func drop_and_free() -> void:
	var root := get_parent()
	if is_instance_valid(root) and root.has_method("drop_and_free"):
		root.call("drop_and_free")
	else:
		Vanish.free_node(self)
