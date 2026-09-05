## One RCA socket on a device: a snap zone that wears an RcaJack and knows what
## signal it carries and which way that signal flows.
##
## Every port accepts every plug — group "composite_plug", no colour filter —
## because that is what the real connector does. Putting the yellow cord into
## both L sockets carries the left channel down a yellow wire and works; putting
## it into the L socket at one end and the R at the other swaps the channels.
## Nothing here enforces a "correct" cable; the routing falls out of which ports a
## cord's two ends happen to sit in. See CompositeCable.
class_name RcaPort
extends XRToolsSnapZone


## What this socket carries. The order matches RcaJack's colour code and is used
## as an index into per-channel arrays, so do not reorder it.
##
## AUDIO_STEREO is APPENDED for that reason. It is what a 3.5 mm TRS socket carries —
## both channels down one connector — which no phono socket can express, since a
## phono lead needs a cord per channel. Nothing indexes an array with it: the two
## places that turn a channel into a speaker number (`int(channel) - 1`) are only
## ever reached from an AUDIO_L or AUDIO_R port, so appending leaves them alone.
enum Channel { VIDEO, AUDIO_L, AUDIO_R, AUDIO_STEREO }

## Which way the signal flows through this socket. A deck's sockets are OUT, a
## television's are IN. A cord between two OUTs (or two INs) carries nothing,
## which is also true of the real thing.
enum Direction { OUT, IN }

@export var channel: Channel = Channel.VIDEO:
	set(value):
		channel = value
		_tint_jack()

@export var direction: Direction = Direction.IN

## Draw this port's own jack, or leave it to the model underneath.
##
## The NES moulds its own AV jacks into the shell (JackYellow / JackRed), so its
## ports sit ON those and turn this off — two jacks in the same place z-fight, and
## the moulded pair is the one that matches the console.
@export var show_jack: bool = true:
	set(value):
		show_jack = value
		var jack := get_node_or_null("RcaJack") as Node3D
		if jack != null:
			jack.visible = show_jack

## Short label for the OSD and for debugging — "VIDEO", "L", "R".
const CHANNEL_NAMES := ["VIDEO", "L", "R", "STEREO"]

## Every socket in the room, so a plug can find the one holding it and a cable can
## re-resolve without knowing what devices exist.
const GROUP := "rca_port"


## The plug group this socket accepts — the other half of RcaPlug.plug_group().
## VgaPort overrides both together, which is what keeps a DE-15 hood out of a
## phono jack and a phono plug out of a DE-15 shell.
func plug_group() -> String:
	return "composite_plug"


func _ready() -> void:
	super._ready()
	add_to_group(GROUP)
	snap_require = plug_group()
	_tint_jack()
	var jack := get_node_or_null("RcaJack") as Node3D
	if jack != null:
		jack.visible = show_jack
	# The SOCKET announces seating, not the plug. A snap zone's has_picked_up /
	# has_dropped fire whenever the zone's own state changes, while the pickable's
	# `dropped` needs the releasing zone to be the one actually holding the grab —
	# so a plug taken straight out of one socket into another leaves the first
	# socket empty without the plug ever reporting a thing.
	has_picked_up.connect(_on_seated)
	has_dropped.connect(_on_unseated)


func _on_seated(what: Node3D) -> void:
	_last_plug = what as RcaPlug
	_log_seating("seated", _last_plug)
	_announce(_last_plug)


func _on_unseated() -> void:
	var plug := _last_plug
	_last_plug = null
	_log_seating("pulled", plug)
	_announce(plug)


## Every A/V connection in the room passes through here, so this is the one place
## that can say what is actually wired to what.
##
## Worth the noise because the symptom it explains is silent and misleading: sound
## and picture travel by different cords, so a console with its audio pair in and
## its video cord out plays perfectly through a set showing nothing but blue. From
## the outside that looks like a broken console, and there was no way to tell it
## from a wrong input, an unseated plug, or a socket that belongs to nobody.
func _log_seating(verb: String, plug: RcaPlug) -> void:
	var dev := get_device()
	print("[RcaPort] %s %s on %s%s" % [
		verb,
		channel_name(),
		_device_label(dev),
		"" if is_instance_valid(plug) else "  (plug already gone)",
	])
	# A socket whose walk up the tree found no owner accepts plugs and routes
	# nothing — the failure is invisible at the socket and only shows up as a
	# device that never notices it was connected.
	if dev == null:
		push_warning("[RcaPort] %s socket belongs to no device — nothing will be routed"
			% channel_name())


static func _device_label(dev: Node) -> String:
	if dev == null:
		return "<no device>"
	var name_prop: Variant = dev.get("display_name")
	if name_prop is String and not (name_prop as String).is_empty():
		return "%s (%s)" % [name_prop, dev.name]
	return str(dev.name)


## Tell the lead that what it carries may have changed.
func _announce(plug: RcaPlug) -> void:
	if is_instance_valid(plug) and plug.cable != null \
			and is_instance_valid(plug.cable):
		plug.cable.on_plug_seating_changed()


# The plug this socket last held, so an unseat — which reports nothing — still
# knows which lead to tell.
var _last_plug: RcaPlug = null


func _tint_jack() -> void:
	var jack := get_node_or_null("RcaJack") as RcaJack
	if jack == null:
		return
	match channel:
		Channel.VIDEO: jack.jack_color = RcaJack.COMPOSITE_YELLOW
		Channel.AUDIO_L: jack.jack_color = RcaJack.AUDIO_WHITE
		Channel.AUDIO_R: jack.jack_color = RcaJack.AUDIO_RED


func channel_name() -> String:
	return CHANNEL_NAMES[channel]


## What this socket carries on a given CORD of the lead seated in it.
##
## A phono socket is one signal down one wire, so the cord is nothing to it and this
## is just `channel`. The exception is a MULTI-WAY connector — the Wii's AV Multi Out
## is one shell carrying picture and both audio channels — where a single socket is
## the source for three cords at once and each has to answer differently. See
## WiiAvPort.
##
## A reader of a CompositeCable link whose device could be on either side of a
## multi-way connector must come through here rather than through `channel` directly:
## the link already carries its cord, and a socket that reported one channel for all
## three made a Multi Out lead put the picture down all of them. system.gd does.
##
## dvd_player.gd and vcr_player.gd still read `channel`, which is currently the same
## answer — a deck wears a phono row and its sink is a set with phono sockets, so
## neither side of one of their links can ever be multi-way. Give either of them a
## multi-way socket and both need this.
func channel_for(_cord: int) -> Channel:
	return channel


func channel_name_for(cord: int) -> String:
	return CHANNEL_NAMES[channel_for(cord)]


## The plug currently seated here, or null.
func seated_plug() -> Node3D:
	return picked_up_object if is_instance_valid(picked_up_object) else null


## The device this socket belongs to — the deck or the television that owns it.
##
## Walked rather than exported, so a port can be dropped anywhere in a device's
## scene (on a shell, inside a back-panel node) without also having to be wired up.
func get_device() -> Node3D:
	var n: Node = get_parent()
	while n != null:
		if n.has_method("on_av_topology_changed"):
			return n as Node3D
		n = n.get_parent()
	return null
