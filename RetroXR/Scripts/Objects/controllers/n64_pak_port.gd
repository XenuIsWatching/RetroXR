## N64PakPort — an expansion port that takes a Controller, Rumble or Transfer
## Pak, and tells the machine on the other end what is in it.
##
## Lifted out of RetroController so a PAD RECEIVER can have one too. A player on
## a real gamepad holds no virtual controller, so before this there was nowhere
## to put a pak at all: the paks existed and the one socket that took them was on
## a pad that player was not using. A receiver is not a RetroController and
## cannot inherit from one, so the port sits in a RefCounted both hold — the same
## arrangement ControlAnimator has for the same reason.
##
## The host supplies two things and keeps the rest:
##
##   owner      the node the machine knows as its port controller, passed back to
##              reapply_pak() so the system can find it in _port_controllers
##   on_change  called after every seat and removal, for whatever else the host
##              has to do about it (a controller stops its rumble here)
##
## RetroSystem reaches all of this by duck typing — it asks a port controller for
## `pak_option_value` and `get_pak` and does not care what class answers — so a
## host that forwards those two methods needs no change on the system side.
class_name N64PakPort
extends RefCounted

## Objects in this group, and nothing else, seat here. snap_require alone would
## also take a cable plug, because every ControllerPlug is in the "controller_plug"
## group the zone requires.
const PAK_GROUP := &"n64_pak"

var _owner: Node = null
var _zone: XRToolsSnapZone = null
var _pak: N64Pak = null
var _on_change: Callable = Callable()


## Bind to the host's "ExpansionPort" node, if its scene authors one.
##
## Gated on the node existing so a host whose scene has no port carries none of
## this, and a scene that grows one needs no script of its own.
func attach(owner: Node, on_change: Callable = Callable()) -> bool:
	_owner = owner
	_on_change = on_change
	_zone = owner.get_node_or_null("ExpansionPort") as XRToolsSnapZone
	if _zone == null:
		return false
	_zone.snap_filter = _accepts
	_zone.has_picked_up.connect(_on_seated)
	_zone.has_dropped.connect(_on_removed)
	return true


func has_port() -> bool:
	return _zone != null


func _accepts(obj: Node3D) -> bool:
	return obj != null and obj.is_in_group(PAK_GROUP)


func _on_seated(obj: Node3D) -> void:
	_pak = obj as N64Pak
	if _pak != null:
		if _owner is CollisionObject3D:
			(_owner as CollisionObject3D).add_collision_exception_with(_pak)
		# A Transfer Pak's cartridge can change without the pak moving, and this
		# port has to re-announce when it does — so the host follows the pak's
		# own signal, the way a Wii Remote follows a chained Nunchuk's.
		if _pak is TransferPak and not _pak.cart_changed.is_connected(_on_cart_changed):
			_pak.cart_changed.connect(_on_cart_changed)
	announce()


func _on_cart_changed(_cart: Node3D) -> void:
	announce()


## has_dropped carries no argument, so this hears that the port emptied, not what
## left. Which is enough — the port holds one thing and _pak is it.
func _on_removed() -> void:
	if is_instance_valid(_pak):
		if _owner is CollisionObject3D:
			(_owner as CollisionObject3D).remove_collision_exception_with(_pak)
		if _pak is TransferPak and _pak.cart_changed.is_connected(_on_cart_changed):
			_pak.cart_changed.disconnect(_on_cart_changed)
	_pak = null
	announce()


## Tell the machine what is in the port now.
##
## A pak that is not plugged into anything is just an object on a shelf, so this
## is a no-op until the host is on a port.
func announce(system: Node = null) -> void:
	var sys: Node = system
	if sys == null and _owner != null and _owner.has_method("get_connected_system"):
		sys = _owner.call("get_connected_system")
	if is_instance_valid(sys) and sys.has_method("reapply_pak"):
		sys.reapply_pak(_owner)
	if _on_change.is_valid():
		_on_change.call()


## The pak fitted here, or null.
func get_pak() -> N64Pak:
	return _pak


## Put a pak back into the port after a load.
##
## Synchronous, unlike the Wii Remote's equivalent: a pak is one body with no
## cord to spawn on a deferred call, so there is nothing to wait for and no retry
## to bound. A null is a host that was saved with an empty port.
func restore_pak(pak: N64Pak) -> void:
	if _zone == null or not is_instance_valid(pak):
		return
	_zone.pick_up_object(pak)


## The core option value this port should take.
##
## "" means this host has no expansion port AT ALL, which is not the same as an
## empty one: mupen64plus-next fits a Controller Pak to port 1 by default, and
## answering "none" for a device that cannot take a pak would quietly pull out a
## pak the player has been saving to.
func pak_option_value() -> String:
	if _zone == null:
		return ""
	if not is_instance_valid(_pak):
		return "none"
	return _pak.pak_option_value()
