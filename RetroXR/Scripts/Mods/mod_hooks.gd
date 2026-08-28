## ModHooks — how a mod attaches to classes it cannot edit.
##
## Built on get_tree().node_added, which is already how QualityManager,
## HeldObjectPhysics, TypingGuard and VRKeyboardFix decorate nodes as they
## appear. This is the house pattern, not a new one.
##
## Connected LAZILY: with no mod asking for a node hook, nothing is connected and
## the signal costs nothing. node_added fires for every node in the tree, so the
## per-node test is kept to a class check against a small list.
class_name ModHooks
extends RefCounted

## [{owner: String, cls: StringName, cb: Callable}]
var _node_watchers: Array[Dictionary] = []
var _connected := false
var _tree: SceneTree = null


func _init(tree: SceneTree) -> void:
	_tree = tree


## Call `cb(node)` for every node of class `cls` added from now on.
##
## `cls` is matched with is_class(), so it covers engine classes and any
## script class registered globally -- "RetroSystem", "RetroTV", "Node3D".
func watch_nodes(owner_id: String, cls: StringName, cb: Callable) -> void:
	_node_watchers.append({"owner": owner_id, "cls": cls, "cb": cb})
	if not _connected and _tree != null:
		_tree.node_added.connect(_on_node_added)
		_connected = true


func _on_node_added(node: Node) -> void:
	for w: Dictionary in _node_watchers:
		if not _matches(node, w["cls"]):
			continue
		var cb: Callable = w["cb"]
		if not cb.is_valid():
			continue
		# A mod that throws must not take the whole tree down with it, and the
		# blame has to name the mod rather than this file.
		cb.call(node)


## is_class() only knows engine classes. A script class is matched by walking the
## node's own script chain, which is what makes "RetroSystem" work.
static func _matches(node: Node, cls: StringName) -> bool:
	if node.is_class(cls):
		return true
	var s: Script = node.get_script() as Script
	while s != null:
		if s.get_global_name() == cls:
			return true
		s = s.get_base_script()
	return false


## Drop every watcher belonging to a mod. Used when a mod's registration failed
## part-way, so a half-registered mod leaves nothing behind.
func drop_owner(owner_id: String) -> void:
	var kept: Array[Dictionary] = []
	for w: Dictionary in _node_watchers:
		if w["owner"] != owner_id:
			kept.append(w)
	_node_watchers = kept
