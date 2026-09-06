## NetObjectSync — host-authoritative shared-world sync (multiplayer M2).
##
## Fixed-path child of NetworkManager ("ObjectSync") so RPC node paths match on
## every peer. The wire format for objects is ScenePersistence's serializer
## (dict entries + two-pass restore), keyed by host-allocated net_ids stored in
## each object's "net_id" meta.
##
## Model:
## - Host owns the world. Clients get a full snapshot on join, then incremental
##   spawn/despawn/event messages and 15 Hz transform batches.
## - Client replicas are frozen (kinematic). Grabbing one grants the client
##   authority (host arbitration); the owner streams the held pose at 20 Hz and
##   returns authority (with velocities) on release.
## - Discrete state changes (cartridge/tape insert, cable plug, ports, power,
##   TV controls, VCR transport) are replicated as events applied through the
##   existing restore_*/remote_* APIs; the originator suppresses re-apply.
##
## All group("spawned") queries are scoped to world_root descendants so two
## peers can share one process in probes.
class_name NetObjectSync
extends Node

signal peer_world_ready(peer_id: int)

const XFORM_INTERVAL := 1.0 / 15.0
const HELD_INTERVAL := 1.0 / 20.0
const HINGE_INTERVAL := 1.0 / 15.0
const MAX_HINGES_PER_BATCH := 64
const SNAP_DISTANCE := 1.0    # replica teleport threshold (metres)

var _nm: Node = null
var _persistence: ScenePersistence = ScenePersistence.new()
var _next_net_id := 1
var _registry: Dictionary = {}       # net_id -> Node3D
var _held_by_me: Dictionary = {}     # net_id -> true (this peer owns the grab)
var _remote_held: Dictionary = {}    # net_id -> peer_id (host bookkeeping)
var _xform_targets: Dictionary = {}  # net_id -> [Vector3, Quaternion] (client lerp)
var _applying := false               # applying remote state — suppress echo
var _xform_accum := 0.0
var _held_accum := 0.0
var _hinge_accum := 0.0
var _hinge_pending: Dictionary = {} # "net_id:path" -> articulated-control update
var _vcr_accum := 0.0                # host heartbeat for VCR drift sync (M5)
var _world_ready := false
var _pending_snapshot_peers: Dictionary = {}

const VCR_HEARTBEAT := 2.0


func _ready() -> void:
	_nm = get_parent()


func is_applying() -> bool:
	return _applying


## Run `body` with echo suppression forced on, then put back whatever was in
## force before rather than assuming it was off.
##
## Every hook in this file asks `_applying` before it broadcasts, so the flag is
## what stops a remote update being echoed straight back at the peer that sent
## it. It used to be raised and lowered by hand at each site, which cost one
## real bug per convention: a site that lowered it unconditionally cancelled the
## suppression of an outer apply it was nested inside, and a site that gained an
## early return left it raised for the rest of the session, silently ending all
## outbound sync. Saving and restoring makes both impossible.
func _suppressed(body: Callable) -> Variant:
	return _with_suppression(true, body)


## Run `body` with suppression forced OFF, then restore it.
##
## This is the host-authoritative half of the pair, and it is a deliberate hole
## in the suppression rather than an oversight. Some events are an INTENT — a
## client asking for the power to be toggled, a transport command — which the
## host carries out for real. The object's own hook has to see an unsuppressed
## flag so that it broadcasts the resulting STATE to every peer; suppressing it
## would apply the change on the host alone and no one else would ever see it.
func _unsuppressed(body: Callable) -> Variant:
	return _with_suppression(false, body)


func _with_suppression(suppressed: bool, body: Callable) -> Variant:
	var was := _applying
	_applying = suppressed
	var result: Variant = body.call()
	_applying = was
	return result


func id_of(node: Node) -> int:
	return node.get_meta("net_id", -1) if is_instance_valid(node) else -1


## Reverse lookup: the registered node for a net_id, or null.
func node_for_id(net_id: int) -> Node:
	var node: Node = _registry.get(net_id)
	return node if is_instance_valid(node) else null


## Every file-backed object in the room, as manifest rows for the CONTENT page.
##
## A view over what is already tracked rather than a second inventory: the kind
## and property come from _file_desc, the hash from the net_md5 meta the spawn
## path already stamped. `transferable` is read from TRANSFER_KINDS so the UI
## cannot disagree with the layer that enforces it.
##
## `have` is whether THIS peer can open the file, which is the question the page
## is actually asking -- a client with an empty path is missing it whatever the
## host has.
func content_manifest() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for net_id: int in _registry:
		var node: Node = _registry[net_id]
		if not is_instance_valid(node):
			continue
		var d := _file_desc(node)
		if d.is_empty():
			continue
		var kind := str(d["kind"])
		var path := str(node.get(str(d["prop"])))
		var md5 := str(node.get_meta("net_md5", ""))
		if md5.is_empty():
			md5 = NetFileTransfer.cached_hash_of(path)
		out.append({
			"net_id": net_id,
			"class": kind,
			"md5": md5,
			"size": NetFileTransfer.size_of(path) if not path.is_empty() else 0,
			"label": path.get_file() if not path.is_empty() else str(node.name),
			"have": not path.is_empty() and FileAccess.file_exists(path),
			"transferable": NetFileTransfer.TRANSFER_KINDS.has(kind),
		})
	return out


## Peer currently holding this replicated object: host=1, remote peer id, or 0.
## Used when a netplay session assigns its initial port owners.
func holder_peer(node: Object) -> int:
	if node == null or not is_instance_valid(node):
		return 0
	var net_id := id_of(node as Node)
	if net_id >= 0 and _remote_held.has(net_id):
		return int(_remote_held[net_id])
	return 1 if _is_hand_held(node as Node) else 0


# ── Session lifecycle (called by NetworkManager) ──────────────────────────────

## Called whenever the world is (re)ready: session start and after scene changes.
func on_world_ready() -> void:
	_applying = false
	_world_ready = true
	if _nm.is_host():
		_register_existing()
		for peer_id: Variant in _pending_snapshot_peers:
			_send_snapshot(int(peer_id))
		_pending_snapshot_peers.clear()
	elif _nm.is_client():
		_request_snapshot.rpc_id(1)


func reset_for_scene_change() -> void:
	# Scene teardown frees everything — suppress despawn/echo storms.
	#
	# The three lifecycle functions here assign the flag directly instead of
	# going through _suppressed(), and have to: this raise is NOT a scoped
	# window, it deliberately outlives the call and stays up until the next
	# on_world_ready() (or end_session()) lowers it. A save/restore wrapper
	# would put it back down on the way out, which is exactly the storm this is
	# here to stop.
	_applying = true
	_world_ready = false
	_pending_snapshot_peers.clear()
	_registry.clear()
	_held_by_me.clear()
	_remote_held.clear()
	_xform_targets.clear()
	_hinge_pending.clear()


func end_session() -> void:
	# Leave the world usable offline: unfreeze replicas that aren't snapped.
	for id: int in _registry:
		var node: Node = _registry[id]
		if is_instance_valid(node) and node is RigidBody3D and not _is_zone_snapped(node) \
				and not _is_hand_held(node):
			(node as RigidBody3D).freeze = false
	reset_for_scene_change()
	_applying = false


## Host cleanup when a peer disappears while holding something. Without this,
## the body remains frozen and every later grab is denied to a peer that no
## longer exists.
func on_peer_left(peer_id: int) -> void:
	if not _nm.is_host():
		return
	for net_id: int in _remote_held.keys():
		if int(_remote_held[net_id]) != peer_id:
			continue
		_remote_held.erase(net_id)
		var node: Node = _registry.get(net_id)
		if not is_instance_valid(node):
			continue
		_maybe_release_port(node)
		if node is RigidBody3D and not _is_zone_snapped(node):
			var body := node as RigidBody3D
			body.freeze = false
			body.sleeping = false


## Called by _place_spawned while in a session.
func local_spawn(obj: Node3D) -> void:
	if _applying:
		return
	if _nm.is_host():
		if _register_host(obj):
			_broadcast_spawn(obj)
	elif _nm.is_client():
		# Serialize the intent, discard the local copy, let the host mint it.
		# Placeholder id 0 so instantiate_objects doesn't skip the entry; the
		# host assigns the real net_id on registration.
		var entry := _persistence._serialize_node(obj, 0, {})
		obj.queue_free()
		if not entry.is_empty():
			_request_spawn.rpc_id(1, entry)


# ── Registration ──────────────────────────────────────────────────────────────

func _register_existing() -> void:
	var root: Node = _nm.world_root_node()
	if root == null:
		return
	for node: Node in get_tree().get_nodes_in_group("spawned"):
		if root.is_ancestor_of(node):
			_register_host(node)


## Host-side: assign a net_id if the object is a syncable type. Returns true
## if registered (cables and other side-effect nodes serialize empty -> skip).
func _register_host(node: Node) -> bool:
	if node.has_meta("net_id"):
		var existing_id := int(node.get_meta("net_id", -1))
		if existing_id < 0:
			return false
		# end_session() clears the registry but deliberately leaves the room and
		# its metadata intact. Re-hosting must bind those existing IDs again.
		if _registry.get(existing_id) != node:
			_bind(node, existing_id)
		_next_net_id = maxi(_next_net_id, existing_id + 1)
		return true
	if _persistence._serialize_node(node, 0, {}).is_empty():
		return false
	var id := _next_net_id
	_next_net_id += 1
	_bind(node, id)
	return true


func _register_client(node: Node, id: int) -> void:
	_bind(node, id)
	_freeze_replica(node)


func _bind(node: Node, id: int) -> void:
	node.set_meta("net_id", id)
	_registry[id] = node
	if node.has_signal("grabbed") and not node.is_connected("grabbed", _on_grabbed):
		node.connect("grabbed", _on_grabbed)
	if node.has_signal("dropped") and not node.is_connected("dropped", _on_dropped):
		node.connect("dropped", _on_dropped)
	var exiting := _on_node_exiting.bind(id, node)
	if not node.tree_exiting.is_connected(exiting):
		node.tree_exiting.connect(exiting)
	_bind_articulated_controls(node)


func _bind_articulated_controls(owner: Node) -> void:
	var hinges: Array[Node] = owner.find_children("*", "VRHinge", true, false)
	if owner is VRHinge:
		hinges.push_front(owner)
	for candidate: Node in hinges:
		var hinge := candidate as VRHinge
		if hinge == null:
			continue
		var path := NodePath(str(owner.get_path_to(hinge)))
		var handler := _on_hinge_changed.bind(owner, path, hinge)
		if not hinge.rotation_changed.is_connected(handler):
			hinge.rotation_changed.connect(handler)
		if hinge is VRLever:
			var lever := hinge as VRLever
			var value_handler := _on_control_changed.bind(owner, path, "lever", lever)
			if not lever.value_changed.is_connected(value_handler):
				lever.value_changed.connect(value_handler)
	for candidate: Node in owner.find_children("*", "VRKnob", true, false):
		var knob := candidate as VRKnob
		if knob == null:
			continue
		var path := NodePath(str(owner.get_path_to(knob)))
		var handler := _on_control_changed.bind(owner, path, "knob", knob)
		if not knob.value_changed.is_connected(handler):
			knob.value_changed.connect(handler)
	for candidate: Node in owner.find_children("*", "VRSlider", true, false):
		var slider := candidate as VRSlider
		if slider == null:
			continue
		var path := NodePath(str(owner.get_path_to(slider)))
		var handler := _on_control_changed.bind(owner, path, "slider", slider)
		if not slider.value_changed.is_connected(handler):
			slider.value_changed.connect(handler)


func _freeze_replica(node: Node) -> void:
	if node is RigidBody3D:
		var body := node as RigidBody3D
		body.freeze = true


func _serialize_registry_entry(node: Node) -> Dictionary:
	var node_to_id := {}
	for id: int in _registry:
		node_to_id[_registry[id]] = id
	var entry := _persistence._serialize_node(node, id_of(node), node_to_id)
	if not entry.is_empty():
		_augment_file_fields(node, entry)
	return entry


func _broadcast_spawn(node: Node) -> void:
	var entry := _serialize_registry_entry(node)
	if not entry.is_empty():
		_spawn_object.rpc(entry)


# ── Snapshot ──────────────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_snapshot() -> void:
	if not _nm.is_host():
		return
	# The sender must be a peer we ACCEPTED, not merely one holding a
	# socket: is_host() only says we are the one who decides.
	if not _nm.is_accepted_peer(multiplayer.get_remote_sender_id()):
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if not _world_ready or _applying or _nm.world_root_node() == null:
		_pending_snapshot_peers[peer_id] = true
		return
	_send_snapshot(peer_id)


func _send_snapshot(peer_id: int) -> void:
	_register_existing()
	var root: Node = _nm.world_root_node()
	if root == null:
		return
	var entries: Array = []
	var node_to_id := {}
	for id: int in _registry:
		node_to_id[_registry[id]] = id
	for id: int in _registry:
		var entry := _persistence._serialize_node(_registry[id], id, node_to_id)
		if not entry.is_empty():
			_augment_file_fields(_registry[id], entry)
			entries.append(entry)
	_world_snapshot.rpc_id(peer_id, entries, _capture_room_state(root))


@rpc("authority", "call_remote", "reliable", 0)
func _world_snapshot(entries: Array, room_state: Array) -> void:
	var root: Node = _nm.world_root_node()
	if root == null:
		return
	var count: int = _suppressed(_world_snapshot_body.bind(root, entries, room_state))
	print("[NetObjectSync] snapshot applied: %d objects" % count)
	_snapshot_applied.rpc_id(1)


func _world_snapshot_body(root: Node, entries: Array, room_state: Array) -> int:
	_clear_world(root)
	var spawned := _persistence.instantiate_objects(root, entries)
	for id: Variant in spawned:
		_register_client(spawned[id], int(id))
	for entry: Variant in entries:
		var node: Node = spawned.get(int((entry as Dictionary).get("id", -1)))
		if node != null:
			_resolve_file_fields(node, entry)
	_apply_room_state(root, room_state)
	return spawned.size()


## Scene-placed controls are not in the spawned-object registry, but a late
## joiner still needs the room the host is actually standing in rather than the
## scene defaults. Paths are relative to world_root so separate processes agree.
func _capture_room_state(root: Node) -> Array:
	var out: Array = []
	for node: Node in root.find_children("*", "LightSwitch", true, false):
		out.append({"path": str(root.get_path_to(node)), "kind": "lights",
			"value": bool((node as LightSwitch).lights_on)})
	for node: Node in root.find_children("*", "BeadPullCord", true, false):
		var cord := node as BeadPullCord
		if cord.light != null or not cord.glow.is_empty():
			out.append({"path": str(root.get_path_to(cord)), "kind": "pull_light",
				"value": cord.lit})
	for node: Node in root.find_children("*", "WindowBlinds", true, false):
		out.append({"path": str(root.get_path_to(node)), "kind": "blinds",
			"value": float((node as WindowBlinds).drop)})
	for node: Node in root.find_children("*", "TimeOfDay", true, false):
		out.append({"path": str(root.get_path_to(node)), "kind": "time",
			"value": float((node as TimeOfDay).time)})
	return out


func _apply_room_state(root: Node, records: Array) -> void:
	for raw: Variant in records:
		if not raw is Dictionary:
			continue
		var rec := raw as Dictionary
		var path := str(rec.get("path", ""))
		if path.is_empty() or path.is_absolute_path() or path.length() > 256:
			continue
		var node := root.get_node_or_null(NodePath(path))
		if node == null or (node != root and not root.is_ancestor_of(node)):
			continue
		match str(rec.get("kind", "")):
			"lights":
				if node.has_method("set_lights_on"):
					node.set_lights_on(bool(rec.get("value", true)))
			"pull_light":
				if node.has_method("set_lit_remote"):
					node.set_lit_remote(bool(rec.get("value", true)))
			"blinds":
				var drop := float(rec.get("value", NAN))
				if node.has_method("set_drop_remote") and is_finite(drop):
					node.set_drop_remote(drop)
			"time":
				var value := float(rec.get("value", NAN))
				if node.has_method("net_set_time") and is_finite(value):
					node.net_set_time(value)


@rpc("any_peer", "call_remote", "reliable", 0)
func _snapshot_applied() -> void:
	if _nm.is_host():
		peer_world_ready.emit(multiplayer.get_remote_sender_id())


## Scoped clear: only spawned objects under our world root (probe-safe).
func _clear_world(root: Node) -> void:
	var mine: Array = []
	for node: Node in get_tree().get_nodes_in_group("spawned"):
		if root.is_ancestor_of(node):
			mine.append(node)
	for node: Node in mine:
		for plug_name: String in ["CablePlug", "ControllerPlug"]:
			var plug := node.get_node_or_null(plug_name)
			if plug and plug.has_method("drop"):
				plug.call("drop")
	# Instant, not shrunk: this is a world teardown, not a player deleting one
	# object. See Vanish.instant.
	Vanish.instant = true
	for node: Node in mine:
		if node is RetroSystem and (node as RetroSystem).is_powered_on:
			(node as RetroSystem).toggle_power()
		if node.has_method("drop_and_free"):
			node.call("drop_and_free")
		else:
			node.queue_free()
	Vanish.instant = false


# ── Spawn / despawn ───────────────────────────────────────────────────────────

@rpc("any_peer", "call_remote", "reliable", 0)
func _request_spawn(entry: Dictionary) -> void:
	if not _nm.is_host():
		return
	# The sender must be a peer we ACCEPTED, not merely one holding a
	# socket: is_host() only says we are the one who decides.
	if not _nm.is_accepted_peer(multiplayer.get_remote_sender_id()):
		return
	var root: Node = _nm.world_root_node()
	if root == null:
		return
	entry = _local_paths_only(entry)
	var spawned: Dictionary = _suppressed(
		_persistence.instantiate_objects.bind(root, [entry]))
	for id: Variant in spawned:
		var node: Node = spawned[id]
		if _register_host(node):
			_broadcast_spawn(node)
		else:
			node.queue_free()


## Path fields a spawn entry can carry into a node.
const PEER_PATH_FIELDS := ["pdf_path", "image_path", "rom_path", "video_path"]


## Blank any path in a PEER-SUPPLIED entry that does not sit inside this
## machine's own library.
##
## The host adopts these verbatim, and _serialize_registry_entry then hashes
## whatever path the spawned node holds and calls serve_register on it for any
## kind in TRANSFER_KINDS. Unchecked, that is an arbitrary-file-read: a peer
## names a file anywhere on the host, asks the host to spawn a book pointing at
## it, and then fetches it back down the file channel.
##
## Blanked rather than refused, because a peer naming a path this machine does
## not have is the ORDINARY case and already worked: the client's own resolution
## chain (_resolve_file_fields) finds the file by name or by hash instead. The
## host simply must not adopt the string. Its own spawns are not filtered --
## those come from its menus and its save files, where naming a path outside the
## library is legitimate.
func _local_paths_only(entry: Dictionary) -> Dictionary:
	var root := DataPaths.media_root()
	var out := entry.duplicate(true)
	for key: String in PEER_PATH_FIELDS:
		var raw := str(out.get(key, ""))
		if raw.is_empty():
			continue
		var p := raw.simplify_path()
		if p == root or p.begins_with(root + "/"):
			continue
		push_warning("[NetObjectSync] refused a peer path outside the library: %s" % raw)
		out[key] = ""
	return out


@rpc("authority", "call_remote", "reliable", 0)
func _spawn_object(entry: Dictionary) -> void:
	var root: Node = _nm.world_root_node()
	if root == null:
		return
	_suppressed(_spawn_object_body.bind(root, entry))


func _spawn_object_body(root: Node, entry: Dictionary) -> void:
	var spawned := _persistence.instantiate_objects(root, [entry])
	for id: Variant in spawned:
		_register_client(spawned[id], int(entry.get("id", -1)))
		_resolve_file_fields(spawned[id], entry)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_despawn(net_id: int) -> void:
	if not _nm.is_host():
		return
	# The sender must be a peer we ACCEPTED, not merely one holding a
	# socket: is_host() only says we are the one who decides.
	if not _nm.is_accepted_peer(multiplayer.get_remote_sender_id()):
		return
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node):
		# tree_exiting hook broadcasts _despawn to the remaining clients. It now
		# fires at the END of the shrink rather than on this frame — a despawn
		# a third of a second later, which is what every peer is watching too.
		_drop_and_free(node)


@rpc("authority", "call_remote", "reliable", 0)
func _despawn(net_id: int) -> void:
	var node: Node = _registry.get(net_id)
	_unregister(net_id)
	if is_instance_valid(node):
		# The shrink outlives this _applying window, so the real tree_exiting
		# arrives with the flag already down. It still does not echo back: the
		# id was unregistered above, and _on_node_exiting drops anything the
		# registry no longer maps to that node.
		_suppressed(_drop_and_free.bind(node))


func _on_node_exiting(net_id: int, exiting_node: Node) -> void:
	# A replacement snapshot can bind a new object to the same id before the old
	# queue_free reaches tree_exiting. The old callback must not erase the new one.
	if _registry.get(net_id) != exiting_node:
		return
	var was_applying := _applying
	_unregister(net_id)
	if was_applying or not _nm.is_active():
		return
	if _nm.is_host():
		_despawn.rpc(net_id)
	else:
		# A client freed a replica locally (e.g. trash can) — ask the host to
		# make it authoritative.
		_request_despawn.rpc_id(1, net_id)


func _unregister(net_id: int) -> void:
	_registry.erase(net_id)
	_held_by_me.erase(net_id)
	_remote_held.erase(net_id)
	_xform_targets.erase(net_id)
	_album_fetch.erase(net_id)


# ── Transform sync ────────────────────────────────────────────────────────────

func _process(delta: float) -> void:
	if not _nm.is_active():
		return
	_hinge_accum += delta
	if _hinge_accum >= HINGE_INTERVAL:
		_hinge_accum = 0.0
		_flush_hinge_updates()
	if _nm.is_host():
		_xform_accum += delta
		if _xform_accum >= XFORM_INTERVAL:
			_xform_accum = 0.0
			_host_send_xforms()
		_vcr_accum += delta
		if _vcr_accum >= VCR_HEARTBEAT:
			_vcr_accum = 0.0
			_host_media_heartbeat()
	else:
		_client_lerp_targets(delta)
		_held_accum += delta
		if _held_accum >= HELD_INTERVAL:
			_held_accum = 0.0
			_client_send_held()


# ── Articulated child-control sync ───────────────────────────────────────────

## Root rigid-body transforms do not include articulated children: handheld
## lids, console flaps, battery covers, knobs, sliders and levers can all move
## while their owner stays perfectly still. Coalesce each control to 15 Hz, but
## send the batch reliably so the final released value cannot be lost.
func _on_hinge_changed(degrees: float, owner: Node, hinge_path: NodePath,
		hinge: VRHinge) -> void:
	if _applying or not _nm.is_active() or not is_instance_valid(owner) \
			or bool(hinge.get_meta("net_restore_in_progress", false)):
		return
	var id := id_of(owner)
	if id < 0 or not is_finite(degrees):
		return
	var path := str(hinge_path)
	var rec := {
		"owner": {"$id": id}, "path": path, "kind": "hinge", "value": degrees,
	}
	if hinge is VRSpringLatchedHinge:
		rec["latched"] = (hinge as VRSpringLatchedHinge).is_latched_closed()
	_hinge_pending["%d:%s" % [id, path]] = rec


func _on_control_changed(value: float, owner: Node, control_path: NodePath,
		kind: String, control: Node) -> void:
	if _applying or not _nm.is_active() or not is_instance_valid(owner) \
			or bool(control.get_meta("net_restore_in_progress", false)):
		return
	var id := id_of(owner)
	if id < 0 or not is_finite(value):
		return
	var path := str(control_path)
	_hinge_pending["%d:%s" % [id, path]] = {
		"owner": {"$id": id}, "path": path, "kind": kind, "value": value,
	}


func _flush_hinge_updates() -> void:
	if _hinge_pending.is_empty():
		return
	var updates := _take_hinge_batch()
	if _nm.is_host():
		_hinge_apply.rpc(updates)
	else:
		_hinge_request.rpc_id(1, updates)


## Remove only the controls this packet can carry. Clearing the dictionary and
## resizing its values dropped every update after the first 64 permanently.
## Erasing the sent keys also moves controls which change again to the back of
## the insertion order, so a continuously moving first batch cannot starve the
## remainder.
func _take_hinge_batch() -> Array:
	var updates: Array = []
	for key: Variant in _hinge_pending.keys():
		updates.append(_hinge_pending[key])
		_hinge_pending.erase(key)
		if updates.size() == MAX_HINGES_PER_BATCH:
			break
	return updates


@rpc("any_peer", "call_remote", "reliable", 0)
func _hinge_request(updates: Array) -> void:
	if not _nm.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Accepted peer, not merely a connected one -- see
	# NetworkManager.is_accepted_peer.
	if not _nm.is_accepted_peer(sender):
		return
	var accepted := _apply_hinge_updates(updates)
	if accepted.is_empty():
		return
	for peer_id: int in _nm.peers:
		if peer_id != 1 and peer_id != sender:
			_hinge_apply.rpc_id(peer_id, accepted)


@rpc("authority", "call_remote", "reliable", 0)
func _hinge_apply(updates: Array) -> void:
	_apply_hinge_updates(updates)


func _apply_hinge_updates(updates: Array) -> Array:
	return _suppressed(_apply_hinge_updates_body.bind(updates)) as Array


func _apply_hinge_updates_body(updates: Array) -> Array:
	var accepted: Array = []
	for raw: Variant in updates.slice(0, MAX_HINGES_PER_BATCH):
		if not raw is Dictionary:
			continue
		var rec := raw as Dictionary
		var decoded := _decode_args({"owner": rec.get("owner")})
		var owner := decoded.get("owner") as Node
		var path := str(rec.get("path", ""))
		var kind := str(rec.get("kind", "hinge"))
		var value := float(rec.get("value", rec.get("degrees", NAN)))
		if owner == null or path.is_empty() or path.is_absolute_path() \
				or path.length() > 256 or not is_finite(value):
			continue
		var control := owner.get_node_or_null(NodePath(path))
		if control == null or (control != owner and not owner.is_ancestor_of(control)):
			continue
		match kind:
			"hinge":
				if not control is VRHinge:
					continue
				if control is VRSpringLatchedHinge:
					(control as VRSpringLatchedHinge).set_state_remote(value,
						bool(rec.get("latched", false)))
				else:
					(control as VRHinge).set_rotation_deg_remote(value)
			"lever":
				if not control is VRLever:
					continue
				(control as VRLever).set_value(value)
			"knob":
				if not control is VRKnob:
					continue
				(control as VRKnob).set_value(value)
			"slider":
				if not control is VRSlider:
					continue
				(control as VRSlider).set_value(value)
			_:
				continue
		accepted.append(rec)
	return accepted


func _host_send_xforms() -> void:
	var buf := StreamPeerBuffer.new()
	var count := 0
	for id: int in _registry:
		var node: Node = _registry[id]
		if not is_instance_valid(node) or not node is RigidBody3D:
			continue
		if _is_zone_snapped(node):
			continue   # follows its carrier locally on every peer
		var body := node as RigidBody3D
		var include: bool = _remote_held.has(id) or _is_hand_held(node) or not body.sleeping
		if not include:
			continue
		buf.put_u32(id)
		var pos := body.global_position
		var quat := body.global_transform.basis.get_rotation_quaternion()
		buf.put_float(pos.x); buf.put_float(pos.y); buf.put_float(pos.z)
		buf.put_float(quat.x); buf.put_float(quat.y); buf.put_float(quat.z); buf.put_float(quat.w)
		count += 1
	if count > 0:
		_xform_batch.rpc(buf.data_array)


@rpc("authority", "call_remote", "unreliable_ordered", 1)
func _xform_batch(bytes: PackedByteArray) -> void:
	var buf := StreamPeerBuffer.new()
	buf.data_array = bytes
	while buf.get_position() + 32 <= buf.get_size():
		var id := buf.get_u32()
		var pos := Vector3(buf.get_float(), buf.get_float(), buf.get_float())
		var quat := Quaternion(buf.get_float(), buf.get_float(), buf.get_float(), buf.get_float())
		if _held_by_me.has(id):
			continue   # we're authoritative for this one right now
		if _registry.has(id):
			_xform_targets[id] = [pos, quat]


func _client_lerp_targets(delta: float) -> void:
	var w := clampf(delta * 12.0, 0.0, 1.0)
	for id: int in _xform_targets.keys():
		if _held_by_me.has(id):
			# We're the authority while holding — a stale host target must not
			# fight the local grab.
			_xform_targets.erase(id)
			continue
		var node: Node = _registry.get(id)
		if not is_instance_valid(node) or not node is Node3D:
			_xform_targets.erase(id)
			continue
		var n3d := node as Node3D
		var target: Array = _xform_targets[id]
		var tpos: Vector3 = target[0]
		var tquat: Quaternion = target[1]
		if n3d.global_position.distance_to(tpos) > SNAP_DISTANCE:
			n3d.global_position = tpos
			n3d.quaternion = tquat
			n3d.reset_physics_interpolation()
		else:
			n3d.global_position = n3d.global_position.lerp(tpos, w)
			n3d.quaternion = n3d.quaternion.slerp(tquat, w)


func _client_send_held() -> void:
	for id: int in _held_by_me:
		var node: Node = _registry.get(id)
		if not is_instance_valid(node) or not node is Node3D:
			continue
		var n3d := node as Node3D
		_held_pose.rpc_id(1, id, n3d.global_position,
			n3d.global_transform.basis.get_rotation_quaternion())


# ── Grab authority ────────────────────────────────────────────────────────────

func _on_grabbed(pickable: Node3D, by: Node3D) -> void:
	if _applying or not _nm.is_active() or by is XRToolsSnapZone:
		return
	var id := id_of(pickable)
	if id < 0:
		return
	if _nm.is_client() and not _held_by_me.has(id):
		_held_by_me[id] = true
		_xform_targets.erase(id)
		_request_grab.rpc_id(1, id)
	elif _nm.is_host():
		# Host grabbed it back — revoke any remote hold.
		var previous_owner := int(_remote_held.get(id, -1))
		if previous_owner > 0:
			_grab_denied.rpc_id(previous_owner, id)
		_remote_held.erase(id)
		_maybe_handoff_port(pickable, 1)


func _on_dropped(pickable: Node3D) -> void:
	if _applying or not _nm.is_active():
		return
	var id := id_of(pickable)
	if id < 0:
		return
	# Host dropped a controller it was holding (no client holds it) -> unown its
	# port. Client drops arrive via _release, which unowns there.
	if _nm.is_host() and not _remote_held.has(id):
		_maybe_release_port(pickable)
	if not _held_by_me.has(id):
		return
	_held_by_me.erase(id)
	var lin := Vector3.ZERO
	var ang := Vector3.ZERO
	if pickable is RigidBody3D:
		lin = (pickable as RigidBody3D).linear_velocity
		ang = (pickable as RigidBody3D).angular_velocity
	_release.rpc_id(1, id, pickable.global_position,
		pickable.global_transform.basis.get_rotation_quaternion(), lin, ang)
	_freeze_replica(pickable)


@rpc("any_peer", "call_remote", "reliable", 0)
func _request_grab(net_id: int) -> void:
	if not _nm.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Accepted peer, not merely a connected one -- see
	# NetworkManager.is_accepted_peer.
	if not _nm.is_accepted_peer(sender):
		return
	var node: Node = _registry.get(net_id)
	if not is_instance_valid(node):
		return
	if _remote_held.has(net_id) and int(_remote_held[net_id]) != sender:
		_grab_denied.rpc_id(sender, net_id)
		return
	if _is_hand_held(node):
		_grab_denied.rpc_id(sender, net_id)
		return
	_remote_held[net_id] = sender
	_freeze_replica(node)
	_maybe_handoff_port(node, sender)


@rpc("authority", "call_remote", "reliable", 0)
func _grab_denied(net_id: int) -> void:
	_held_by_me.erase(net_id)
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node):
		_suppressed(_drop_and_freeze.bind(node))


## Remove a networked object, letting it drop whatever it holds on the way out.
## Vanish.free_node is the fallback for anything without the pickable contract.
func _drop_and_free(node: Node) -> void:
	if node.has_method("drop_and_free"):
		node.call("drop_and_free")
	else:
		Vanish.free_node(node)


## Let go of a body the host refused us, and hand it back to the replica rules.
func _drop_and_freeze(node: Node) -> void:
	if node.has_method("drop"):
		node.call("drop")
	_freeze_replica(node)


@rpc("any_peer", "call_remote", "unreliable_ordered", 1)
func _held_pose(net_id: int, pos: Vector3, quat: Quaternion) -> void:
	if not _nm.is_host():
		return
	if int(_remote_held.get(net_id, -1)) != multiplayer.get_remote_sender_id():
		return
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node) and node is Node3D:
		(node as Node3D).global_position = pos
		(node as Node3D).quaternion = quat


## Host: a pickable's grab authority just moved to `peer_id`. If it's a controller
## plugged into a live netplay port, hand that port to the new holder (pass-me).
func _maybe_handoff_port(node: Node, peer_id: int) -> void:
	if _nm.is_host() and _is_port_peripheral(node):
		_nm.netplay_handoff(node, peer_id)


## Host: a controller was dropped and nobody else holds it — release its netplay
## port to unowned (owner 0), so it goes neutral and any player can grab it next.
func _maybe_release_port(node: Node) -> void:
	if _nm.is_host() and _is_port_peripheral(node):
		_nm.netplay_handoff(node, 0)


@rpc("any_peer", "call_remote", "reliable", 0)
func _release(net_id: int, pos: Vector3, quat: Quaternion, lin: Vector3, ang: Vector3) -> void:
	if not _nm.is_host():
		return
	if int(_remote_held.get(net_id, -1)) != multiplayer.get_remote_sender_id():
		return
	_remote_held.erase(net_id)
	var node: Node = _registry.get(net_id)
	# A client let go of a controller and nobody grabbed it -> unown its port.
	if is_instance_valid(node):
		_maybe_release_port(node)
	if is_instance_valid(node) and node is RigidBody3D:
		var body := node as RigidBody3D
		body.global_position = pos
		body.quaternion = quat
		body.freeze = false
		body.linear_velocity = lin
		body.angular_velocity = ang
		body.sleeping = false


# ── Replicated events ─────────────────────────────────────────────────────────

## Called (via the NetworkManager facade) from state-transition hooks.
## Which node arguments each event kind cannot be applied without.
##
## Taken from _apply_event's own _valid() guards. Those guards run on the
## RECEIVING peer, where a missing key is silently indistinguishable from a node
## that legitimately went away — the event is dropped and nobody is told. Checked
## here as well, on the sending side, the same mistake fails in the caller's own
## stack while it still exists to be blamed.
##
## Non-node arguments (an "open" flag, a "cmd" string) are deliberately absent:
## they have defaults at the apply site and a missing one is not a bug.
const EV_NODE_KEYS := {
	NetEvents.Event.EV_CART_INSERT:     ["sys", "cart"],
	NetEvents.Event.EV_CART_REMOVE:     ["sys"],
	NetEvents.Event.EV_TAPE_INSERT:     ["vcr", "tape"],
	NetEvents.Event.EV_TAPE_REMOVE:     ["vcr"],
	NetEvents.Event.EV_TV_PLUG:         ["owner", "tv"],
	NetEvents.Event.EV_TV_UNPLUG:       ["tv"],
	NetEvents.Event.EV_RCA_PLUG:        ["cable", "dev"],
	NetEvents.Event.EV_RCA_UNPLUG:      ["cable"],
	NetEvents.Event.EV_PORT_PLUG:       ["sys", "ctrl"],
	NetEvents.Event.EV_PORT_UNPLUG:     ["sys"],
	NetEvents.Event.EV_SYS_POWER:       ["sys"],
	NetEvents.Event.EV_SYS_POWER_STATE: ["sys"],
	NetEvents.Event.EV_SYS_RESET:       ["sys"],
	NetEvents.Event.EV_TV_POWER:        ["tv"],
	NetEvents.Event.EV_TV_VOL_UP:       ["tv"],
	NetEvents.Event.EV_TV_VOL_DOWN:     ["tv"],
	NetEvents.Event.EV_TV_MUTE:         ["tv"],
	NetEvents.Event.EV_TV_CRT:          ["tv"],
	NetEvents.Event.EV_TV_STEREO:       ["tv"],
	NetEvents.Event.EV_TV_AUDIO_MODE:   ["tv"],
	NetEvents.Event.EV_TV_ASPECT:       ["tv"],
	NetEvents.Event.EV_TV_SOURCE:       ["tv"],
	NetEvents.Event.EV_TV_CHANNEL:      ["tv"],
	NetEvents.Event.EV_ROOM_LIGHTS:     ["switch"],
	NetEvents.Event.EV_PULL_LIGHT:      ["cord"],
	NetEvents.Event.EV_BLINDS:          ["blinds"],
	NetEvents.Event.EV_TIME_OF_DAY:     ["clock"],
	NetEvents.Event.EV_SYS_VIDEO_OUT:   ["sys"],
	NetEvents.Event.EV_SYS_GRAVITY:     ["sys"],
	NetEvents.Event.EV_TV_SIZE:         ["tv"],
	NetEvents.Event.EV_VCR_CMD:         ["vcr"],
	NetEvents.Event.EV_BOOK_PAGE:       ["book"],
	NetEvents.Event.EV_BOOK_SIZE:       ["book"],
	NetEvents.Event.EV_BOOK_HALF:       ["book"],
	NetEvents.Event.EV_MEMCARD_INSERT:  ["sys", "card"],
	NetEvents.Event.EV_MEMCARD_REMOVE:  ["sys"],
	NetEvents.Event.EV_TRAY:            ["sys"],
	NetEvents.Event.EV_DISK_OP:         ["sys"],
	NetEvents.Event.EV_DVD_INSERT:      ["dvd", "disc"],
	NetEvents.Event.EV_DVD_REMOVE:      ["dvd"],
	NetEvents.Event.EV_DVD_CMD:         ["dvd"],
	NetEvents.Event.EV_AUDIO_INSERT:    ["player", "media"],
	NetEvents.Event.EV_AUDIO_REMOVE:    ["player"],
	NetEvents.Event.EV_AUDIO_CMD:       ["player"],
}


func report_event(kind: NetEvents.Event, args: Dictionary) -> void:
	if _applying or not _nm.is_active():
		return
	if not _has_required_nodes(kind, args):
		return
	var wire := _encode_args(args)
	if _nm.is_host():
		_update_port_owner(kind, args, 1)
		_event_apply.rpc(kind, wire)
	else:
		_event_req.rpc_id(1, kind, wire)



## How many events this peer refused to send for want of a required node.
##
## The refusal is otherwise invisible: the receiving _valid() guard would have
## dropped the same event anyway, so nothing downstream changes and a test
## watching the far side cannot tell the two cases apart. Counted so it can be.
var events_refused: int = 0


## Complain here rather than dropping the event silently on every peer.
##
## Returns false for an event that cannot be applied, having already said which
## key was missing — an assert would take the whole session down over one
## mis-sent event, which is worse than the event not happening.
func _has_required_nodes(kind: NetEvents.Event, args: Dictionary) -> bool:
	if not EV_NODE_KEYS.has(kind):
		return true
	for key: String in EV_NODE_KEYS[kind]:
		if not is_instance_valid(args.get(key)):
			events_refused += 1
			push_error("NetObjectSync: event %d needs a valid '%s' node" % [kind, key])
			return false
	return true

@rpc("any_peer", "call_remote", "reliable", 0)
func _event_req(kind: NetEvents.Event, wire: Dictionary) -> void:
	if not _nm.is_host():
		return
	var sender := multiplayer.get_remote_sender_id()
	# Accepted peer, not merely a connected one -- see
	# NetworkManager.is_accepted_peer.
	if not _nm.is_accepted_peer(sender):
		return
	_apply_event(kind, wire)
	_update_port_owner(kind, _decode_args(wire), sender)
	# Relay to everyone except the originator (who already has the state).
	for id: int in _nm.peers:
		if id != 1 and id != sender:
			_event_apply.rpc_id(id, kind, wire)


@rpc("authority", "call_remote", "reliable", 0)
func _event_apply(kind: NetEvents.Event, wire: Dictionary) -> void:
	_apply_event(kind, wire)


func _update_port_owner(kind: NetEvents.Event, args: Dictionary, peer_id: int) -> void:
	if not _nm.is_host():
		return
	if kind == NetEvents.Event.EV_PORT_PLUG and _valid(args, ["sys", "ctrl"]):
		_nm.netplay_handoff_port(args["sys"], int(args.get("port", 0)), peer_id)
	elif kind == NetEvents.Event.EV_PORT_UNPLUG and _valid(args, ["sys"]):
		_nm.netplay_handoff_port(args["sys"], int(args.get("port", 0)), 0)


func _apply_event(kind: NetEvents.Event, wire: Dictionary) -> void:
	_suppressed(_dispatch_event.bind(kind, _decode_args(wire)))


## The arms marked host-authoritative run through _unsuppressed() rather than
## suppressed like the rest: see that method for why the hole has to be there.
##
## Where an arm still probes with has_method() it is because the receiver really
## is heterogeneous, and the probe is the dispatch: `sys` is a bare test double
## in several object_sync_tests cases, `book` and the file-backed objects span
## five unrelated classes plus whatever a mod ships, and for those the status
## line is an optional nicety that a plain node is right to not have. An arm
## whose receiver is known — the TV, and NetworkManager itself — calls straight
## through, because a missing method there is a bug that should be a loud crash
## rather than a room that silently stops responding to one control.
func _dispatch_event(kind: NetEvents.Event, a: Dictionary) -> void:
	# Every arm below used to repeat its own _valid(a, [...]) list, and those 44
	# lists were a second copy of EV_NODE_KEYS -- the same contract written twice,
	# agreeing only for as long as both were edited together. The table is the one
	# the SEND side already checks in _has_required_nodes, so it is now the only
	# place a new event declares which nodes it needs.
	if not _valid(a, EV_NODE_KEYS.get(kind, [])):
		return
	match kind:
		NetEvents.Event.EV_CART_INSERT:
			a["sys"].restore_cartridge(a["cart"])
		NetEvents.Event.EV_CART_REMOVE:
			a["sys"].net_release_cartridge()
		NetEvents.Event.EV_TAPE_INSERT:
			a["vcr"].restore_tape(a["tape"])
		NetEvents.Event.EV_TAPE_REMOVE:
			a["vcr"].net_release_tape()
		NetEvents.Event.EV_TV_PLUG:
			# A console carries the cable channel and the set's own input
			# ("in" is Composite 1-4, absent on events from before there
			# were four). Anything else is guarded rather than assumed the
			# way tv_panel guards on_tv_connected: the VCR and DVD player
			# used to satisfy this call with an empty override, which is a
			# method existing only to be called into and do nothing.
			if a["owner"] is RetroSystem:
				a["owner"].restore_cable_connection(a["tv"], int(a.get("ch", 0)),
					int(a.get("in", 0)))
			elif a["owner"].has_method("restore_cable_connection"):
				a["owner"].restore_cable_connection(a["tv"])
		NetEvents.Event.EV_TV_UNPLUG:
			a["tv"].release_input(int(a.get("in", 0)))
		NetEvents.Event.EV_RCA_PLUG:
			# The lead names the socket by device + node name, so a peer needs no
			# shared numbering of ports to put the same end in the same place.
			a["cable"].net_seat_plug(int(a.get("end", 0)), int(a.get("cord", 0)),
				a["dev"], str(a.get("port", "")))
		NetEvents.Event.EV_RCA_UNPLUG:
			a["cable"].net_release_plug(int(a.get("end", 0)), int(a.get("cord", 0)))
		NetEvents.Event.EV_PORT_PLUG:
			a["ctrl"].restore_port_connection(a["sys"], int(a.get("port", 0)))
		NetEvents.Event.EV_PORT_UNPLUG:
			var port := int(a.get("port", 0))
			a["sys"].net_release_controller_port(port)
		NetEvents.Event.EV_SYS_POWER:
			# Client intent — the host toggles for real. Un-suppressed so the
			# host's own hook broadcasts NetEvents.Event.EV_SYS_POWER_STATE afterwards.
			if _nm.is_host():
				_unsuppressed(a["sys"].toggle_power)
		NetEvents.Event.EV_SYS_POWER_STATE:
			if a["sys"].has_method("net_set_remote_power"):
				a["sys"].net_set_remote_power(bool(a.get("on", false)))
		NetEvents.Event.EV_SYS_RESET:
			# Like power intent, reset is host-authoritative. RetroSystem.reset()
			# frame-schedules the actual core reset when lockstep is active.
			if _nm.is_host() and a["sys"].has_method("reset"):
				_unsuppressed(a["sys"].reset)
		NetEvents.Event.EV_TV_POWER:
			a["tv"].remote_power_toggle()
		NetEvents.Event.EV_TV_VOL_UP:
			a["tv"].remote_volume_up()
		NetEvents.Event.EV_TV_VOL_DOWN:
			a["tv"].remote_volume_down()
		NetEvents.Event.EV_TV_MUTE:
			a["tv"].remote_mute_toggle()
		NetEvents.Event.EV_TV_CRT:
			a["tv"].set_crt_enabled(bool(a.get("on", true)))
		NetEvents.Event.EV_TV_STEREO:
			a["tv"].set_stereo_mode(int(a.get("mode", 0)))
		NetEvents.Event.EV_TV_AUDIO_MODE:
			a["tv"].set_audio_mode(int(a.get("mode", 0)))
		NetEvents.Event.EV_TV_ASPECT:
			a["tv"].set_widescreen(bool(a.get("on", false)))
		NetEvents.Event.EV_TV_SOURCE:
			a["tv"].set_source(int(a.get("source", 0)))
		NetEvents.Event.EV_TV_CHANNEL:
			a["tv"].net_set_channel_state(int(a.get("source", 0)),
				int(a.get("rf", 3)), int(a.get("index", -1)))
		NetEvents.Event.EV_ROOM_LIGHTS:
			if a["switch"].has_method("set_lights_on"):
				a["switch"].set_lights_on(bool(a.get("on", true)))
		NetEvents.Event.EV_PULL_LIGHT:
			if a["cord"].has_method("set_lit_remote"):
				a["cord"].set_lit_remote(bool(a.get("on", true)))
		NetEvents.Event.EV_BLINDS:
			if a["blinds"].has_method("set_drop_remote"):
				a["blinds"].set_drop_remote(float(a.get("drop", 1.0)))
		NetEvents.Event.EV_TIME_OF_DAY:
			if a["clock"].has_method("net_set_time"):
				a["clock"].net_set_time(float(a.get("time", 0.75)))
		NetEvents.Event.EV_SYS_VIDEO_OUT:
			a["sys"].set_video_out_enabled(bool(a.get("on", true)))
		NetEvents.Event.EV_SYS_GRAVITY:
			a["sys"].set_ignore_gravity(bool(a.get("on", false)))
		NetEvents.Event.EV_TV_SIZE:
			a["tv"].set_tv_scale(float(a.get("scale", 1.0)))
		NetEvents.Event.EV_VCR_CMD:
			# Transport is host-authoritative; the host executes the command and
			# its state broadcast (send_media_state) drives every peer's local
			# playback (M5 drift sync). Run un-suppressed so the transport hook's
			# _net_push_state() actually broadcasts.
			if _nm.is_host():
				_unsuppressed(_host_vcr_cmd.bind(a["vcr"], str(a.get("cmd", ""))))
		NetEvents.Event.EV_BOOK_PAGE:
			if a["book"].has_method("set_page"):
				a["book"].set_page(int(a.get("state", 0)), int(a.get("leaf", 0)))
		NetEvents.Event.EV_BOOK_SIZE:
			a["book"].set("size_scale", float(a.get("scale", 1.0)))
		NetEvents.Event.EV_BOOK_HALF:
			a["book"].set("half_page_mode", bool(a.get("on", false)))
		NetEvents.Event.EV_MEMCARD_INSERT:
			a["sys"].restore_memory_card(a["card"], _memcard_slot_of(a))
		NetEvents.Event.EV_MEMCARD_REMOVE:
			a["sys"].net_release_memory_card(_memcard_slot_of(a))
		NetEvents.Event.EV_TRAY:
			if a["sys"].has_method("net_set_tray_open"):
				a["sys"].net_set_tray_open(bool(a.get("open", false)))
		NetEvents.Event.EV_DISK_OP:
			# Client disc-swap intent — the host frame-schedules it for all
			# peers through the netplay session (system.gd _request_disk_op).
			if _nm.is_host():
				_nm.netplay_schedule_disk(a["sys"], int(a.get("op", 0)),
					str(a.get("md5", "")), int(a.get("index", 0)))
		NetEvents.Event.EV_DVD_INSERT:
			a["dvd"].restore_disc(a["disc"])
		NetEvents.Event.EV_DVD_REMOVE:
			a["dvd"].net_release_disc()
		NetEvents.Event.EV_DVD_CMD:
			# DVD transport/menu is host-authoritative: the host executes the
			# command and its state broadcast (send_media_state) drives every
			# peer's local playback. Run un-suppressed so the command hook's
			# _net_push_state() actually broadcasts.
			if _nm.is_host():
				_unsuppressed(_host_dvd_cmd.bind(a["dvd"], str(a.get("cmd", ""))))
		NetEvents.Event.EV_AUDIO_INSERT:
			a["player"].restore_media(a["media"])
		NetEvents.Event.EV_AUDIO_REMOVE:
			# Through the deck's own loader, not the snap zone. A seated item is
			# NOT held by the zone — MediaSlot/MediaTray both drop it and reparent
			# it as they take ownership — so the old get_node("MediaSlot").
			# drop_object() here unseated nothing at all on a tray deck.
			a["player"].remove_media()
		NetEvents.Event.EV_AUDIO_CMD:
			# Audio transport is host-authoritative: the host executes and its
			# state broadcast (send_media_state) drives every peer's local
			# playback. Run un-suppressed so the command hook's _net_push_state()
			# actually broadcasts.
			if _nm.is_host():
				_unsuppressed(_host_audio_cmd.bind(a["player"],
					str(a.get("cmd", "")), int(a.get("index", -1))))


## The three transport arms below are the host carrying out a client's command.
## None of them has a `_:` arm, deliberately: a host that predates a command
## no-ops on it rather than misfiring some other transport.
func _host_vcr_cmd(vcr: Node, cmd: String) -> void:
	match cmd:
		"play": vcr.remote_play()
		"pause": vcr.remote_pause()
		"stop": vcr.remote_stop()
		"ff": vcr.remote_ff()
		"rew": vcr.remote_rewind()


func _host_dvd_cmd(dvd: Node, cmd: String) -> void:
	match cmd:
		"play": dvd.remote_play()
		"pause": dvd.remote_pause()
		"stop": dvd.remote_stop()
		"menu_up": dvd.dvd_menu_up()
		"menu_down": dvd.dvd_menu_down()
		"menu_left": dvd.dvd_menu_left()
		"menu_right": dvd.dvd_menu_right()
		"ok": dvd.dvd_ok()
		"root": dvd.dvd_root_menu()
		"next_ch": dvd.dvd_next_chapter()
		"prev_ch": dvd.dvd_prev_chapter()
		"ff": dvd.remote_ff()
		"rew": dvd.remote_rewind()
		"audio": dvd.dvd_cycle_audio()
		"subtitle": dvd.dvd_cycle_subtitle()


## `index` is the band the needle lands on, and is carried the way
## NetEvents.Event.EV_TV_CHANNEL and NetEvents.Event.EV_DISK_OP carry theirs.
func _host_audio_cmd(ap: Node, cmd: String, index: int) -> void:
	match cmd:
		"play": ap.remote_play()
		"pause": ap.remote_pause()
		"stop": ap.remote_stop()
		"ff": ap.remote_ff()
		"rew": ap.remote_rewind()
		"next": ap.remote_next()
		"prev": ap.remote_prev()
		"track": ap.remote_goto_track(index)


## Which card slot a memcard event names, clamped to slots that exist. Defaults
## to slot A so an event from a peer that predates two-slot consoles still lands
## on the slot it meant.
func _memcard_slot_of(a: Dictionary) -> int:
	return clampi(int(a.get("slot", 0)), 0, RetroSystem.MEMCARD_SLOT_NODES.size() - 1)


func _valid(a: Dictionary, keys: Array) -> bool:
	for k: String in keys:
		if not is_instance_valid(a.get(k)):
			return false
	return true


## Encode node references as {"$id": net_id} (registered) or {"$path": path}
## (scene-placed, e.g. the room TV); primitives pass through.
func _encode_args(args: Dictionary) -> Dictionary:
	var out := {}
	for k: Variant in args:
		var v: Variant = args[k]
		if v is Node:
			var id := id_of(v)
			if id >= 0:
				out[k] = {"$id": id}
			else:
				out[k] = {"$path": str((v as Node).get_path())}
		else:
			out[k] = v
	return out


func _decode_args(wire: Dictionary) -> Dictionary:
	var out := {}
	for k: Variant in wire:
		var v: Variant = wire[k]
		if v is Dictionary and (v as Dictionary).has("$id"):
			out[k] = _registry.get(int(v["$id"]))
		elif v is Dictionary and (v as Dictionary).has("$path"):
			out[k] = get_node_or_null(NodePath(str(v["$path"])))
		else:
			out[k] = v
	return out


# ── VCR playback sync (M5) ────────────────────────────────────────────────────
# Drift-corrected, not lockstep: the host's transport is authoritative and every
# peer plays its own local copy of the video (delivered by NetFileTransfer).
# State goes out reliably on every transport change (vcr_player hooks) plus a
# heartbeat while playing; peers seek when they drift past the tolerance.

## Broadcast one deck's transport state (host only).
##
## The VCR, the DVD player and the CD/cassette player used to have a send
## function, an RPC and a net_apply_state arity each — three of everything for
## one idea — and the heartbeat below picked between them by sniffing which keys
## the returned Dictionary happened to carry. The payload IS the deck's own
## state dictionary, so one path carries all three and a deck that grows a field
## does not need a new RPC signature.
func send_media_state(deck: Node) -> void:
	if not _nm.is_host():
		return
	var id := id_of(deck)
	if id < 0 or not deck.has_method("net_get_state"):
		return
	_media_state.rpc(id, deck.net_get_state())


func _host_media_heartbeat() -> void:
	for id: int in _registry:
		var node: Node = _registry[id]
		if is_instance_valid(node) and node.has_method("net_get_state") \
				and bool(node.get("is_playing")):
			send_media_state(node)


@rpc("authority", "call_remote", "reliable", 0)
func _media_state(net_id: int, state: Dictionary) -> void:
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node) and node.has_method("net_apply_state"):
		_suppressed(node.call.bind("net_apply_state", state))


# ── File-backed objects (M3) ──────────────────────────────────────────────────
#
# Spawn entries for file-backed objects carry file_md5/file_size so clients can
# resolve content they don't have at the host's path. Policy per kind:
#  - book / video: transferable via NetFileTransfer (content-addressed).
#  - rom: HASH-VERIFY ONLY — never transferred (copyright: see file_transfer.gd).
#    The client searches its own rom library for a byte-identical file and remaps
#    the path; a missing ROM just means netplay won't start for that peer.

## md5 -> {net_id, prop} for transfers this client has in flight.
var _fetching: Dictionary = {}
var _ft_wired := false
## net_id -> album-fetch state {name, dir, single, total, remaining:{md5:track},
## final} while a client is downloading a multi-track album.
var _album_fetch: Dictionary = {}
const ALBUM_CACHE_DIR := "user://net_cache/albums"


## What file (if any) backs this object: {kind, prop}.
func _file_desc(node: Node) -> Dictionary:
	if node is PDFBook:
		return {"kind": "book", "prop": "pdf_path"}
	if node is RetroCartridge:
		return {"kind": "rom", "prop": "rom_path"}
	if node is VCRTape:
		return {"kind": "video", "prop": "video_path"}
	if node is DVDDisc:
		# Transferable, like the tapes: a disc image is user media. Only
		# single-file images (.iso/.img) carry a hash at all — a VIDEO_TS folder
		# has no single md5, so it neither transfers nor resolves on a peer.
		return {"kind": "dvd", "prop": "dvd_path"}
	if node is AudioDisc or node is AudioCassette or node is VinylRecord:
		# Music albums are folders (no single hash) + potentially copyrighted —
		# verify-BY-NAME, never transferred. Each peer plays its own album of the
		# same name; a peer without it simply won't hear playback.
		return {"kind": "music", "prop": "album_path"}
	return {}


## Host: attach file_md5/file_size to a spawn entry. Uses the persistent hash
## cache; a cache miss hashes on a worker thread and follows up with _file_info
## so big files (videos) never hitch the frame.
func _augment_file_fields(node: Node, entry: Dictionary) -> void:
	if not _nm.is_host():
		return
	var d := _file_desc(node)
	if d.is_empty():
		return
	# Music albums are folders of tracks — carry the album name (for the peer's
	# verify-by-name fast path) plus a per-track manifest (name/md5/size) so a peer
	# without the album can fetch it track-by-track. Hashing may be deferred to a
	# worker thread; the follow-up _album_manifest RPC re-enters resolution.
	if str(d["kind"]) == "music":
		var album := str(node.get(d["prop"]))
		if album.is_empty():
			return
		entry["album_name"] = album.get_file()
		var manifest := _music_manifest_of(album, false)   # cache-only, non-blocking
		if not manifest.is_empty():
			_register_album_serve(album, manifest)
			entry["tracks"] = manifest
			return
		var album_net_id := id_of(node)
		if album_net_id < 0 or node.has_meta("net_hashing"):
			return
		node.set_meta("net_hashing", true)
		WorkerThreadPool.add_task(func() -> void:
			var m := _music_manifest_of(album, true)   # blocking hash on the worker
			call_deferred("_on_music_hashed", album_net_id, album, m))
		return
	var path := str(node.get(d["prop"]))
	if path.is_empty() or not FileAccess.file_exists(path):
		return
	var md5 := str(node.get_meta("net_md5", ""))
	if md5.is_empty():
		md5 = NetFileTransfer.cached_hash_of(path)
	if not md5.is_empty():
		node.set_meta("net_md5", md5)
		entry["file_md5"] = md5
		entry["file_size"] = NetFileTransfer.size_of(path)
		if NetFileTransfer.TRANSFER_KINDS.has(str(d["kind"])):
			_nm.file_transfer().serve_register(md5, path)
		return
	# Not cached yet — hash in the background, then broadcast the follow-up.
	var net_id := id_of(node)
	if net_id < 0 or node.has_meta("net_hashing"):
		return
	node.set_meta("net_hashing", true)
	WorkerThreadPool.add_task(func() -> void:
		var h := NetFileTransfer.hash_of(path)
		call_deferred("_on_file_hashed", net_id, h, path))


func _on_file_hashed(net_id: int, md5: String, path: String) -> void:
	var node: Node = _registry.get(net_id)
	if not is_instance_valid(node) or md5.is_empty():
		return
	node.remove_meta("net_hashing")
	node.set_meta("net_md5", md5)
	var d := _file_desc(node)
	if NetFileTransfer.TRANSFER_KINDS.has(str(d.get("kind", ""))):
		_nm.file_transfer().serve_register(md5, path)
	if _nm.is_host() and _nm.is_active():
		_file_info.rpc(net_id, md5, NetFileTransfer.size_of(path))


@rpc("authority", "call_remote", "reliable", 0)
func _file_info(net_id: int, md5: String, size: int) -> void:
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node):
		_resolve_file_fields(node, {"file_md5": md5, "file_size": size})


## Client: make the object's backing file usable locally, or arrange for it.
func _resolve_file_fields(node: Node, entry: Dictionary) -> void:
	if not _nm.is_client():
		return
	var d := _file_desc(node)
	if d.is_empty():
		return
	var prop := str(d["prop"])
	var kind := str(d["kind"])
	var path := str(node.get(prop))
	if kind == "music":
		# 1) keep the host's path if it exists locally (same machine / shared lib).
		if not path.is_empty() and (FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path)):
			return
		# 2) verify-by-name: reuse our own album of the same name — no transfer.
		var album_name := str(entry.get("album_name", path.get_file()))
		var local_album := RomLibrary.find_music_album(album_name)
		if not local_album.is_empty():
			node.set(prop, local_album)
			return
		# 3) transfer it track-by-track using the manifest. If the manifest isn't
		# here yet (host still hashing), wait for the _album_manifest follow-up.
		var tracks: Array = entry.get("tracks", [])
		if tracks.is_empty():
			node.set(prop, "")
			return
		_start_album_fetch(node, album_name, tracks)
		return
	if not path.is_empty() and FileAccess.file_exists(path):
		return   # host's path happens to exist here (same machine / shared lib)
	var md5 := str(entry.get("file_md5", ""))
	var size := int(entry.get("file_size", 0))
	if md5.is_empty():
		# Host hasn't hashed it yet — _file_info will re-enter when it has.
		node.set(prop, "")
		return
	if kind == "rom":
		# Verify-only: find our own byte-identical copy, never transfer.
		#
		# DVDs used to share this branch on the grounds that a video disc is as
		# copyrighted as a game. They are now treated like the VCR tapes beside
		# them -- user media the room may hand over -- which is an owner's
		# decision about their own library, not a technical one. ROMs and
		# firmware remain the hard line and are not negotiable here.
		var dirs: Array = [RomLibrary.default_roms_root()]
		var local_copy := NetFileTransfer.resolve_by_md5(md5, kind, size, path, dirs)
		if not local_copy.is_empty():
			node.set(prop, local_copy)
			print("[NetObjectSync] %s matched by hash: %s" % [kind, local_copy])
		else:
			node.set(prop, "")
			print("[NetObjectSync] %s %s… not in local library (verify-only, not transferred)" % [kind, md5.left(8)])
		return
	var found := NetFileTransfer.resolve_by_md5(md5, kind, size, path)
	if not found.is_empty():
		node.set(prop, found)
		return
	# Fetch it. Track by md5 so transfer signals route back to this object.
	node.set(prop, "")
	_wire_transfer_signals()
	_fetching[md5] = {"net_id": id_of(node), "prop": prop}
	if node.has_method("net_set_download_status"):
		node.call("net_set_download_status", "DOWNLOADING…")
	_nm.file_transfer().request_file(md5, kind, size, path.get_extension())


func _wire_transfer_signals() -> void:
	if _ft_wired:
		return
	_ft_wired = true
	var ft: NetFileTransfer = _nm.file_transfer()
	ft.transfer_progress.connect(_on_transfer_progress)
	ft.transfer_done.connect(_on_transfer_done)
	ft.transfer_failed.connect(_on_transfer_failed)


func _fetch_node(md5: String) -> Node:
	var info: Dictionary = _fetching.get(md5, {})
	if info.is_empty():
		return null
	var node: Node = _registry.get(int(info["net_id"]))
	return node if is_instance_valid(node) else null


func _on_transfer_progress(md5: String, received: int, total: int) -> void:
	# Album tracks report progress via a track counter in _album_track_ready, not
	# per-byte, so a single track's % doesn't clobber the "n/N" status.
	if _fetching.get(md5, {}).get("album", false):
		return
	var node := _fetch_node(md5)
	if node != null and node.has_method("net_set_download_status") and total > 0:
		node.call("net_set_download_status", "DOWNLOADING %d%%" % int(received * 100.0 / total))


func _on_transfer_done(md5: String, path: String) -> void:
	var info: Dictionary = _fetching.get(md5, {})
	_fetching.erase(md5)
	if info.get("album", false):
		_album_track_ready(int(info.get("net_id", -1)), md5, path)
		return
	var node: Node = _registry.get(int(info.get("net_id", -1)))
	if is_instance_valid(node):
		if node.has_method("net_set_download_status"):
			node.call("net_set_download_status", "")
		node.set(str(info["prop"]), path)


func _on_transfer_failed(md5: String, reason: String) -> void:
	var info: Dictionary = _fetching.get(md5, {})
	_fetching.erase(md5)
	if info.get("album", false):
		_album_fetch_failed(int(info.get("net_id", -1)), reason)
		return
	var node: Node = _registry.get(int(info.get("net_id", -1)))
	if is_instance_valid(node) and node.has_method("net_set_download_status"):
		node.call("net_set_download_status", "UNAVAILABLE")
	print("[NetObjectSync] transfer %s… failed: %s" % [md5.left(8), reason])


# ── Music album transfer (multi-track) ────────────────────────────────────────
# An album is a folder of tracks (or a single audio file). It transfers as a set
# of ordinary single-file transfers keyed by each track's MD5, driven by a
# manifest [{name, md5, size}] the host builds. The client fetches each missing
# track into the shared net cache, then reassembles the album folder locally.

## Build the album's track manifest. allow_hash=false uses only cached hashes and
## returns [] if any track isn't cached yet (caller then hashes off-thread);
## allow_hash=true hashes every track (blocking — run on a worker thread).
func _music_manifest_of(album: String, allow_hash: bool) -> Array:
	var out: Array = []
	for tp: String in RomLibrary.music_tracks(album):
		var md5 := NetFileTransfer.cached_hash_of(tp)
		if md5.is_empty():
			if not allow_hash:
				return []
			md5 = NetFileTransfer.hash_of(tp)
			if md5.is_empty():
				continue
		out.append({"name": tp.get_file(), "md5": md5, "size": NetFileTransfer.size_of(tp)})
	return out


## Host: offer each track for download by hash (main-thread only — _serve isn't
## guarded for worker threads).
func _register_album_serve(album: String, manifest: Array) -> void:
	var is_dir := DirAccess.dir_exists_absolute(album)
	for t: Variant in manifest:
		var track_name := str((t as Dictionary).get("name", ""))
		var tp := album.path_join(track_name) if is_dir else album
		_nm.file_transfer().serve_register(str((t as Dictionary).get("md5", "")), tp)


## Host: a background album hash finished — register the tracks and broadcast the
## manifest so peers who were waiting can start fetching.
func _on_music_hashed(net_id: int, album: String, manifest: Array) -> void:
	var node: Node = _registry.get(net_id)
	if not is_instance_valid(node) or manifest.is_empty():
		return
	node.remove_meta("net_hashing")
	_register_album_serve(album, manifest)
	if _nm.is_host() and _nm.is_active():
		_album_manifest.rpc(net_id, str(album).get_file(), manifest)


@rpc("authority", "call_remote", "reliable", 0)
func _album_manifest(net_id: int, album_name: String, tracks: Array) -> void:
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node):
		_resolve_file_fields(node, {"album_name": album_name, "tracks": tracks})


## Client: begin fetching every track of an album. Tracks already in the net cache
## are consumed immediately; the rest are requested over the wire.
func _start_album_fetch(node: Node, album_name: String, tracks: Array) -> void:
	var net_id := id_of(node)
	if net_id < 0 or tracks.is_empty():
		return
	if _album_fetch.has(net_id):
		return   # already downloading this album
	# A single-file album (the album path IS the track) stays a bare file; a
	# multi-track album reassembles into its own cache folder.
	var single: bool = tracks.size() == 1 and str((tracks[0] as Dictionary).get("name", "")) == album_name
	var dir := ""
	if not single:
		dir = ALBUM_CACHE_DIR.path_join(album_name)
		DirAccess.make_dir_recursive_absolute(dir)
	var remaining: Dictionary = {}
	for t: Variant in tracks:
		remaining[str((t as Dictionary)["md5"])] = t
	_album_fetch[net_id] = {"name": album_name, "dir": dir, "single": single,
		"total": tracks.size(), "remaining": remaining, "final": ""}
	_wire_transfer_signals()
	node.set("album_path", "")
	if node.has_method("net_set_download_status"):
		node.call("net_set_download_status", "DOWNLOADING 0/%d" % tracks.size())
	for t: Variant in tracks:
		var td := t as Dictionary
		var md5 := str(td["md5"])
		var cached := NetFileTransfer.resolve_by_md5(md5, "music", int(td.get("size", 0)), "")
		if not cached.is_empty():
			_album_track_ready(net_id, md5, cached)
		else:
			_fetching[md5] = {"net_id": net_id, "album": true}
			_nm.file_transfer().request_file(md5, "music", int(td.get("size", 0)),
				str(td["name"]).get_extension())


## Client: one album track arrived (or was already cached). Place it under the
## album folder; when the last one lands, point the object at the local album.
func _album_track_ready(net_id: int, md5: String, cache_path: String) -> void:
	var af: Dictionary = _album_fetch.get(net_id, {})
	if af.is_empty():
		return
	var t: Dictionary = af["remaining"].get(md5, {})
	if t.is_empty():
		return
	af["remaining"].erase(md5)
	if af["single"]:
		af["final"] = cache_path
	else:
		var dest := str(af["dir"]).path_join(str(t["name"]))
		if not FileAccess.file_exists(dest):
			DirAccess.copy_absolute(cache_path, dest)
		af["final"] = af["dir"]
	var node: Node = _registry.get(net_id)
	var done: int = int(af["total"]) - af["remaining"].size()
	if af["remaining"].is_empty():
		_album_fetch.erase(net_id)
		if is_instance_valid(node):
			if node.has_method("net_set_download_status"):
				node.call("net_set_download_status", "")
			node.set("album_path", str(af["final"]))
			print("[NetObjectSync] album '%s' assembled (%d tracks)" % [af["name"], af["total"]])
	elif is_instance_valid(node) and node.has_method("net_set_download_status"):
		node.call("net_set_download_status", "DOWNLOADING %d/%d" % [done, int(af["total"])])


## Client: a track transfer failed — abandon the album (peer just won't hear it).
func _album_fetch_failed(net_id: int, reason: String) -> void:
	var af: Dictionary = _album_fetch.get(net_id, {})
	if af.is_empty():
		return
	_album_fetch.erase(net_id)
	var node: Node = _registry.get(net_id)
	if is_instance_valid(node) and node.has_method("net_set_download_status"):
		node.call("net_set_download_status", "UNAVAILABLE")
	print("[NetObjectSync] album '%s' transfer failed: %s" % [af.get("name", "?"), reason])


# ── Helpers ───────────────────────────────────────────────────────────────────

func _is_zone_snapped(node: Node) -> bool:
	var driver: Variant = VrHold.grab_driver(node)
	if driver and driver.primary and driver.primary.by is XRToolsSnapZone:
		return true
	return false


func _is_hand_held(node: Node) -> bool:
	if not node.has_method("is_picked_up") or not node.call("is_picked_up"):
		return false
	return not _is_zone_snapped(node)


func _is_port_peripheral(node: Node) -> bool:
	# Receiver boxes forward a fixed local desktop device; carrying the box does
	# not mean the carrier took ownership of that keyboard/mouse/gamepad.
	return not node is InputReceiver \
		and "_connected_system" in node and "_port_index" in node
