## TvPanel — the set's back panel: its sockets, their legends, and which device is
## arriving on which input.
##
## A child of the RetroTV it serves, created unconditionally in _init, in the same
## shape as TvResize, TvFit, TvOsd and TvAudio.
##
## Three arrays, all indexed by RetroTV.Source over their WHOLE range rather than
## only the composite part of it, because _input_for_device returns a Source and
## everything downstream indexes with it:
##
##   _av_ports          the sockets themselves, [input][VIDEO, L, R]
##   _snapped_plugs     the captive lead seated in each input's video socket
##   _connected_systems the host feeding each input
##
## The socket NODES stay on RetroTV (_composite_port, _vga_port, _rf_port): they are
## @onready paths into the set's own scene, and _ready connects their signals.
##
## The seven names a cabled device calls — accept_plug_restore, release_input,
## audio_ports, socket_holding, input_holding, on_av_source_found/lost and
## on_av_topology_changed — stay on RetroTV and forward here. rca_port.gd dispatches
## the last of those with has_method(), so the set has to answer it itself.
class_name TvPanel
extends Node

## The set this is the back of.
var _tv: RetroTV = null

## Centre-to-centre along the A/V row. The pitch the primitive console, the NES, the
## PC tower and both decks already use, so a lead reaches a set's sockets exactly as
## it reaches a deck's.
const AV_ROW_PITCH := 0.018

## Centre-to-centre between one input group and the next. Wider than AV_ROW_PITCH by
## more than the printed legend is wide (57.6 mm at the authored text sizes), so the
## four plates stand clear of each other instead of overlapping — and wide enough
## that no socket sits closer to its neighbour in the next group than to the ones in
## its own, which is what makes the grouping readable at arm's length.
const AV_GROUP_PITCH := 0.06

## The A/V sockets, [input][VIDEO, L, R].
var _av_ports: Array = []

## The captive lead seated in each input's video socket, so a disconnect knows
## which host to tell.
var _snapped_plugs: Array = []

## The host feeding each input, or null. av_suite and the Tools/av probes read this
## directly to assert what the set thinks is cabled to it.
var _connected_systems: Array = []


func setup(tv: RetroTV) -> void:
	_tv = tv


## The A/V sockets, gathered from the scene's fixed names into [input][VIDEO, L, R].
##
## Composite 1 keeps the unsuffixed names it has always had — a console's captive
## lead, netplay and the save file all name "CompositePort" — and the rest count up
## from 2, so the numbering on the wire matches the numbering printed on the panel.
func collect() -> void:
	_av_ports = []
	_connected_systems = []
	_snapped_plugs = []
	for i in RetroTV.COMPOSITE_INPUTS:
		var suffix := "" if i == 0 else str(i + 1)
		var trio: Array[RcaPort] = []
		for base in ["CompositePort", "AudioLIn", "AudioRIn"]:
			var port := _tv.get_node_or_null(base + suffix) as RcaPort
			if port == null:
				push_warning("[RetroTV] missing A/V socket %s%s" % [base, suffix])
				continue
			trio.append(port)
		_av_ports.append(trio)
		_connected_systems.append(null)
		_snapped_plugs.append(null)
	# Two more slots so all three arrays stay indexable by Source over their WHOLE
	# range and not just the composite part of it — _input_for_device returns a
	# Source and everything downstream indexes with it.
	#
	# TV owns no sockets, so its entry is an empty trio; video_port already guards
	# for that, and its connected-system slot stays null because a tuner is not a
	# connected system. RF owns exactly one, and it is a VIDEO socket, so it sits at
	# index 0 of its trio where video_port looks.
	_av_ports.append([] as Array[RcaPort])
	_connected_systems.append(null)
	_snapped_plugs.append(null)
	var rf := _tv._rf_port as RcaPort
	var rf_trio: Array[RcaPort] = []
	if rf != null:
		rf_trio.append(rf)
	else:
		push_warning("[RetroTV] missing aerial socket RfPort")
	_av_ports.append(rf_trio)
	_connected_systems.append(null)
	_snapped_plugs.append(null)
	# And the DE-15, which is an input in its own right rather than an alias for
	# Composite 1. As that alias it announced "COMPOSITE 1" on a cabinet with no
	# phono row at all, and a set carrying both would have had them share one slot,
	# so plugging either would evict the other. Its socket IS an RcaPort (VgaPort
	# extends it), so it needs no special case anywhere that walks these.
	var vga_trio: Array[RcaPort] = []
	var vga := _tv._vga_port as RcaPort
	if vga != null:
		vga_trio.append(vga)
	_av_ports.append(vga_trio)
	_connected_systems.append(null)
	_snapped_plugs.append(null)


## How many composite inputs this cabinet actually carries sockets for. The stock
## body and both televisions take all four; a shell with a smaller back panel says so.
func panel_inputs() -> int:
	if _tv._shell == null:
		return RetroTV.COMPOSITE_INPUTS
	# Floored at ZERO, not at one: a cabinet is allowed to carry no phono sockets at
	# all, and the computer monitor is one. See TVShell.av_inputs.
	return clampi(_tv._shell.av_inputs, 0, RetroTV.COMPOSITE_INPUTS)


## Whether this cabinet carries the aerial socket. The stock body does; a fitted
## shell says so itself.
func has_aerial() -> bool:
	return _tv._shell == null or _tv._shell.has_aerial


## Turn off the inputs this cabinet has no room for: no socket, and nothing printed.
##
## `enabled` as well as `visible`, for the reason seat_vga_port gives — hiding a
## snap zone stops it drawing and nothing else, so an invisible socket left enabled
## goes on catching plugs out of the air.
func disable_absent_inputs() -> void:
	for i in range(panel_inputs(), RetroTV.COMPOSITE_INPUTS):
		for port: RcaPort in _av_ports[i]:
			port.visible = false
			port.enabled = false
	if not has_aerial():
		for port: RcaPort in _av_ports[RetroTV.Source.RF]:
			port.visible = false
			port.enabled = false


## The VIDEO socket of one input — the one that decides what is on the glass, and
## the one a captive lead goes into.
func video_port(input: int) -> RcaPort:
	if input < 0 or input >= _av_ports.size() or (_av_ports[input] as Array).is_empty():
		return null
	return _av_ports[input][0]


## Print the back-panel legends: one per composite input group, plus the aerial
## socket's own.
##
## A set is a sink, so every A/V one reads AV IN; what tells them apart is the title
## above the jacks. The plate is the cabinet's call — a moulded CRT back is curved,
## and a flat rectangle across it either floats off the curve or cuts in.
func print_legends() -> void:
	var plate: bool = _tv._shell == null or _tv._shell.av_legend_plate
	for i in panel_inputs():
		var legend := AvLegend.attach(_tv, _av_ports[i])
		if legend == null:
			continue
		legend.name = "AvLegend%d" % (i + 1)
		legend.title = RetroTV.AV_INPUT_NAMES[i]
		legend.show_plate = plate
		# Every group but the first rules off the one to its left, so four inputs get
		# three lines and neither end of the bank carries a stray one.
		legend.divider_left = i > 0
		legend.rebuild()
	if has_aerial():
		_print_rf_legend(plate)


## The aerial socket's legend — the same printing as a composite group so the one
## hole on the panel that is not phono is not also the one standing on bare cabinet.
##
## Wordless: CoaxPort reports Channel.VIDEO because the routing needs somewhere to
## send the picture, and printing VIDEO under an aerial hole would name the wrong
## connector. The row that word would have occupied still takes its space, so this
## plate comes out the same height as the four beside it.
##
## No divider, and that is the point of the gap it stands in: an aerial feed is not
## one of the composite inputs, and a rule would file it as a fifth.
func _print_rf_legend(plate: bool) -> void:
	var legend := AvLegend.attach(_tv, _av_ports[RetroTV.Source.RF])
	if legend == null:
		return
	legend.name = "AvLegendRf"
	legend.title = "Antenna"
	legend.heading_override = "RF IN"
	legend.show_words = false
	legend.show_plate = plate
	legend.rebuild()


## Seat all TWELVE input sockets off the shell's PortSeat, not just the video one.
##
## PortSeat names one point — Composite 1's VIDEO socket — and everything else steps
## off it: the audio pair by av_socket_step, the next input group by av_group_step,
## both in the seat's own frame. A shell that named only the video socket used to
## leave the rest at tv.tscn's own coordinates while the body they were mounted in
## was hidden, which put live sockets in mid-air beside the cabinet.
##
## The two steps are the SHELL's because the room to lay them out is the cabinet's:
## the stock box and the 90s set measure flat across the whole 240 mm row, while the
## computer monitor runs out at 180 and stands its groups on end instead.
func seat_av_row(at: Variant) -> void:
	if not at is Transform3D:
		return
	var base: Transform3D = at
	var socket_step := Vector3(-AV_ROW_PITCH, 0.0, 0.0)
	var group_step := Vector3(-AV_GROUP_PITCH, 0.0, 0.0)
	if _tv._shell != null:
		socket_step = _tv._shell.av_socket_step
		group_step = _tv._shell.av_group_step
	for i in RetroTV.COMPOSITE_INPUTS:
		for j in (_av_ports[i] as Array).size():
			var offset: Vector3 = group_step * float(i) + socket_step * float(j)
			TvFit.seat(_av_ports[i][j], Transform3D(base.basis, base * offset))
	# The aerial socket takes the next group slot along, so it travels with the row
	# onto a fitted cabinet instead of being left at tv.tscn's own coordinates —
	# which, with the stock body hidden, is a live socket floating beside the set.
	# One group clear of Composite 4 whether or not this cabinet fits four, since a
	# shell with fewer still has the room the others use.
	#
	# Plus ONE socket step, which lands it on that slot's CENTRE rather than on the
	# slot's first socket. A composite group centres its printing on the middle of
	# its trio, so a lone socket sitting where a trio's VIDEO jack goes puts its plate
	# 18 mm right of where the pattern wants it — close enough to overlap Composite
	# 4's and z-fight with it, the two being coplanar and the same colour.
	if _tv._rf_port != null:
		TvFit.seat(_tv._rf_port, Transform3D(base.basis,
			base * (group_step * float(RetroTV.COMPOSITE_INPUTS) + socket_step)))


## Turn the VGA input on, but only for a shell that asked for it.
##
## Opt-IN rather than opt-out: the socket is authored off in tv.tscn and a shell
## claims it by carrying a VgaPortSeat marker. Only the computer monitor does — a
## DE-15 on a wood-cabinet 70s set would be an anachronism, and the stock body has
## nowhere sensible to put one.
##
## `enabled` as well as `visible`, and that is not belt and braces: hiding a snap
## zone stops it drawing and nothing else, so an invisible socket left enabled goes
## on catching plugs.
func seat_vga_port(at: Variant) -> void:
	if _tv._vga_port == null:
		return
	var on: bool = at is Transform3D
	if on:
		_tv._vga_port.transform = at
	_tv._vga_port.visible = on
	_tv._vga_port.enabled = on


## Snaps a captive cable plug into one of this TV's video sockets (used by save/load
## and netplay to restore connections). Defaults to Composite 1, which is where a
## caller that has no opinion — and every save written before there were four — means.
func accept_plug_restore(plug: CablePlug, input: int) -> void:
	var port := video_port(input)
	if port == null:
		port = _tv._composite_port as RcaPort
	print("[RetroTV] accept_plug_restore: plug=%s port=%s" % [plug, port])
	port.pick_up_object(plug)
	print("[RetroTV] accept_plug_restore: done, port.picked_up=%s" % port.picked_up_object)


## Drop whatever captive lead is in one input's video socket. Used by netplay when
## another player unplugs one; the input defaults to Composite 1 for an event from a
## peer that predates there being four.
func release_input(input: int) -> void:
	var port := video_port(input)
	if port != null:
		port.drop_object()


## The L and R sockets of one composite input, in that order — the pair a captive
## lead's audio cords go into beside its picture cord. Empty for an input this
## cabinet has no sockets for, and for the tuner, which has no audio of its own.
func audio_ports(input: int) -> Array:
	if input < 0 or input >= _av_ports.size():
		return []
	var trio: Array = _av_ports[input]
	return trio.slice(1) if trio.size() > 1 else []


## Which socket ANYWHERE on this set is holding `plug` — audio as well as video.
## port_holding answers the narrower question of which INPUT a lead is feeding, and
## an audio cord is never the answer to that one.
func socket_holding(plug: Node3D) -> XRToolsSnapZone:
	for group: Array in _av_ports:
		for port: RcaPort in group:
			if port.picked_up_object == plug:
				return port
	if _tv._vga_port != null and _tv._vga_port.picked_up_object == plug:
		return _tv._vga_port
	return null


## Which video socket is holding `plug`, or null. Lets a host that seated a captive
## lead find its way back to the right socket without knowing the numbering.
func port_holding(plug: Node3D) -> XRToolsSnapZone:
	for i in RetroTV.COMPOSITE_INPUTS:
		var port := video_port(i)
		if port != null and port.picked_up_object == plug:
			return port
	if _tv._vga_port != null and _tv._vga_port.picked_up_object == plug:
		return _tv._vga_port
	return null


## Which INPUT is holding `plug`, for a host writing itself to a save file. The DE-15
## answers Source.VGA, its own input; anything else it cannot find falls back to
## Composite 1, which is where a restore with no opinion puts a lead anyway.
func input_holding(plug: Node3D) -> int:
	for i in RetroTV.COMPOSITE_INPUTS:
		var port := video_port(i)
		if port != null and port.picked_up_object == plug:
			return i
	if _tv._vga_port != null and _tv._vga_port.picked_up_object == plug:
		return RetroTV.Source.VGA
	return RetroTV.Source.COMPOSITE_1


## Called when a cable plug snaps into one of the video sockets. `input` is bound
## per socket at connect time, so the handler knows which one without asking.
func on_plug_snapped(plug: Node3D, input: int) -> void:
	# Hand the incoming host a clean screen so the C++ video handler doesn't
	# capture our CRT wrapper as the "original" material to restore later.
	_tv._drop_sampled()
	if plug is CablePlug:
		var plugged := plug as CablePlug
		_snapped_plugs[input] = plugged
		# Prevent the frozen kinematic plug from physically pushing the TV
		_tv.add_collision_exception_with(plugged)
		var system := plugged.get_system()
		if system:
			_connected_systems[input] = system
			# Multi-output systems need to know WHICH cable landed; other
			# hosts (VCR/DVD) keep the plain single-arg contract.
			if system is RetroSystem:
				(system as RetroSystem).on_tv_connected(_tv, plugged)
			elif system.has_method("on_tv_connected"):
				# Guarded: only a host with a captive lead implements this. The decks
				# dropped it when they moved to sockets and a spawned cable, and an
				# unguarded call errors on any plug that names one as its system.
				system.on_tv_connected(_tv)
			# A console plugged in while the set is showing something else must stay
			# off the glass until SOURCE selects it, or it repaints the screen from
			# under whatever is playing. Stated through the same pass SOURCE uses,
			# so the answer is given in BOTH directions: a host told only when it is
			# unselected has to guess when that stops being true, and one that
			# remembers the "no" — every host must, since it can arrive while the
			# machine is off — would never hear it lifted.
			# …and it must be silent too until SOURCE picks it, for the same reason.
			_tv._audio.apply_volume()
			NetworkManager.report_event(NetObjectSync.EV_TV_PLUG,
				{"owner": system, "tv": _tv, "ch": plugged.channel, "in": input})


## Called by a deck that has worked out it is feeding this set through a composite
## lead. Takes the place of on_plug_snapped's host lookup, which only works for a
## captive lead whose plug carries a back-reference to its owner; a composite
## cable's plugs belong to no device, so the deck tells the set instead.
func source_found(source: Node3D) -> void:
	var input := _input_for_device(source)
	if input < 0:
		return                  # nothing of ours is actually joined to it
	# Hand the incoming host a clean screen, exactly as the plug path does, so the
	# video handler doesn't capture our CRT wrapper as the material to restore.
	_tv._drop_sampled()
	_connected_systems[input] = source
	source.set_audio_volume(_tv._audio.volume_for(input))
	_tv._audio.apply_channel_mode()
	# Same rule as the captive-lead path, and stated the same way: a deck cabled up
	# to an input nobody is watching waits its turn rather than painting over the one
	# they are, and hears so when its turn comes.


## Called by that deck when the last cord between the two is pulled.
func source_lost(source: Node3D) -> void:
	var found := false
	for i in _connected_systems.size():
		if _connected_systems[i] == source:
			_connected_systems[i] = null
			found = true
	if not found:
		return                  # already replaced by something else
	_tv._drop_sampled()


## Which input a device's signal is arriving on, or -1 if none of ours reaches it.
##
## Worked out from the cable rather than passed in, because the caller does not know
## it: a deck announces itself through on_av_source_found having resolved only that
## this television is its sink, and CompositeCable._resolve tells the SOURCE end
## first — so the set is told before its own on_av_topology_changed runs, and reading
## the answer off a stored link list would be both a frame late and one ordering
## assumption deep.
##
## VIDEO wins over audio when a device reaches more than one input, because the
## picture is what the input is named for. But audio alone still counts: a deck with
## its sound in Composite 2 and its video cord out is on Composite 2, and used to be
## heard there — which is the whole reason the L/R sockets are separate.
func _input_for_device(dev: Node3D) -> int:
	if dev == null or not is_instance_valid(dev):
		return -1
	# A captive lead names its own host and carries no CompositeCable at all, so it
	# is not in the graph. Over every input the set has sockets for, which includes
	# the aerial one: a console reached through an RF switch is found here exactly
	# as one on a composite lead is.
	for i in _av_ports.size():
		var captive: CablePlug = _snapped_plugs[i]
		if captive != null and is_instance_valid(captive) and captive.get_system() == dev:
			return i

	# Everything else comes off the graph, which walks every cable the device is
	# on rather than every socket this set owns — the same answer from one walker
	# instead of a second copy of it here.
	var audio_match := -1
	for link: Dictionary in AvGraph.links_for(dev):
		if (link["out"] as RcaPort).get_device() != dev:
			continue
		var in_port := link["in"] as RcaPort
		for i in _av_ports.size():
			if not (_av_ports[i] as Array).has(in_port):
				continue
			if in_port.channel == RcaPort.Channel.VIDEO:
				return i
			if audio_match < 0:
				audio_match = i
	return audio_match


## Called when a cable plug leaves one of the video sockets.
func on_plug_released(input: int) -> void:
	# Unwrap before the host tears down so it restores over its own material,
	# not our CRT wrapper.
	_tv._drop_sampled()
	var plugged: CablePlug = _snapped_plugs[input]
	if plugged:
		_tv.remove_collision_exception_with(plugged)
		var system := plugged.get_system()
		if system:
			if system is RetroSystem:
				(system as RetroSystem).on_tv_disconnected(plugged)
			elif system.has_method("on_tv_disconnected"):
				system.on_tv_disconnected()
		_connected_systems[input] = null
		_snapped_plugs[input] = null
		NetworkManager.report_event(NetObjectSync.EV_TV_UNPLUG, {"tv": _tv, "in": input})


## Read off the host duck-typed, and a host that has no opinion counts as a match:
## the channel switch belongs to the CONSOLE (an NES wears one on its back panel),
## so a deck or a machine without one fed through an RF switch should simply appear
## rather than being invisibly wrong on both channels.
func rf_tuned() -> bool:
	var host: Node3D = _connected_systems[RetroTV.Source.RF] \
		if _connected_systems.size() > RetroTV.Source.RF else null
	if host == null or not is_instance_valid(host):
		return false
	if not host.has_method("get_rf_channel"):
		return true
	var ch := int(host.call("get_rf_channel"))
	# -1 is "this machine has no channel switch". A match, not a mismatch: otherwise
	# a deck fed through an RF switch would be invisible on BOTH channels.
	return ch < 0 or ch == _tv.rf_channel


## The host feeding the selected input, if there is one and it is still alive.
func selected_system() -> Node3D:
	var input := _tv._selected_input()
	if input < 0:
		return null
	var system: Node3D = _connected_systems[input]
	return system if system != null and is_instance_valid(system) else null
