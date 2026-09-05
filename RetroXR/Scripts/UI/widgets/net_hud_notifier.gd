## NetHudNotifier -- turns netplay events into sentences a host can read at a
## glance, without opening the menu.
##
## Split from the panel it drives, deliberately. What is worth testing here is
## the MAPPING -- which event becomes which words, under which key, and whether
## it says anything at all -- and that has to be checkable without a headset, a
## camera or a viewport. It takes a MenuToasts and talks to it through the same
## API the menu uses, so a test hands it a bare stack and reads the result.
##
## Three rules do most of the work:
##
##  - HOST ONLY. Every event here is a host's business. A client already sees its
##    own downloads and its own join; repeating the room's whole traffic to
##    everyone in it would be noise four ways over.
##  - KEYED, never appended. One row per peer, one per transfer, patched in
##    place. A joiner pulling twelve files leaves twelve rows that update, not a
##    scrolling history -- and MenuToasts._enforce_cap() already collapses past
##    four into "+N more".
##  - NAMES, not ids. A toast that says "peer 1341581476 joined" is a log line,
##    not a notification.
class_name NetHudNotifier
extends Node

const KEY_PEER := "hud:peer:%d"
const KEY_UPLOAD := "hud:up:%d:%s"
const KEY_JOIN := "hud:join:%d"
const KEY_WANTS := "hud:wants:%d"
const KEY_DESYNC := "hud:desync:%d"
const KEY_BLOCKED := "hud:blocked"
const KEY_SESSION := "hud:session"

var _nm: Node = null
var _stack: MenuToasts = null
## md5 -> filename, for transfers currently in flight. Filled from serve_started
## and dropped when the transfer ends, so it is bounded by what is actually
## moving rather than by everything that ever moved.
var _names: Dictionary = {}


## `nm` is the NetworkManager (injected so a test can pass a stand-in).
func setup(nm: Node, stack: MenuToasts) -> void:
	_nm = nm
	_stack = stack
	if _nm == null:
		return
	_nm.peer_registered.connect(_on_peer_registered)
	_nm.peer_left.connect(_on_peer_left)
	_nm.serve_started.connect(_on_serve_started)
	_nm.serve_progress.connect(_on_serve_progress)
	_nm.serve_done.connect(_on_serve_done)
	_nm.serve_refused.connect(_on_serve_refused)
	_nm.netplay_state_progress.connect(_on_join_progress)
	_nm.netplay_join_requested.connect(_on_join_requested)
	_nm.netplay_desync.connect(_on_desync)
	_nm.netplay_blocked.connect(_on_blocked)
	_nm.netplay_session_stopped.connect(_on_session_stopped)


func _ready() -> void:
	set_process(false)   # purely signal-driven


func _speaking() -> bool:
	return is_instance_valid(_stack) \
		and _nm != null and _nm.has_method("is_host") and _nm.is_host()


## The display name for a peer, or a fallback. A leave races the roster removal,
## so the id is often already gone by the time this is asked.
func _who(peer_id: int) -> String:
	if _nm != null and "peers" in _nm:
		var info: Dictionary = (_nm.peers as Dictionary).get(peer_id, {})
		var name := str(info.get("name", ""))
		if not name.is_empty():
			return name
	return "a player"


func _what(md5: String) -> String:
	return str(_names.get(md5, "a file"))


func _on_peer_registered(peer_id: int, info: Dictionary) -> void:
	if not _speaking():
		return
	var name := str(info.get("name", ""))
	if name.is_empty():
		name = _who(peer_id)
	_stack.finish(KEY_PEER % peer_id, String.chr(MenuIcons.CHECK),
		"%s joined" % name, MenuToasts.DWELL_OK)


func _on_peer_left(peer_id: int) -> void:
	if not _speaking():
		return
	# Named before the roster forgets them where possible; _who falls back.
	_stack.finish(KEY_PEER % peer_id, String.chr(MenuIcons.CLOSE),
		"%s left" % _who(peer_id), MenuToasts.DWELL_OK)


func _on_serve_started(peer_id: int, md5: String, _kind: String, size: int,
		name: String) -> void:
	if not _speaking():
		return
	if not name.is_empty():
		_names[md5] = name
	_stack.notify(KEY_UPLOAD % [peer_id, md5], String.chr(MenuIcons.UPLOAD),
		"Sending %s to %s" % [_what(md5), _who(peer_id)], 0.0, 0.0)
	if size <= 0:
		_stack.finish(KEY_UPLOAD % [peer_id, md5], String.chr(MenuIcons.CHECK),
			"Sent to %s" % _who(peer_id), MenuToasts.DWELL_OK)


func _on_serve_progress(peer_id: int, md5: String, sent: int, total: int) -> void:
	if not _speaking() or total <= 0:
		return
	_stack.notify(KEY_UPLOAD % [peer_id, md5], String.chr(MenuIcons.UPLOAD),
		"Sending %s to %s  %s / %s" % [_what(md5), _who(peer_id),
			MenuStyle.human_bytes(sent), MenuStyle.human_bytes(total)],
		float(sent) / float(total), 0.0)


func _on_serve_done(peer_id: int, md5: String) -> void:
	if not _speaking():
		return
	_stack.finish(KEY_UPLOAD % [peer_id, md5], String.chr(MenuIcons.CHECK),
		"Sent %s to %s" % [_what(md5), _who(peer_id)], MenuToasts.DWELL_OK)
	_names.erase(md5)


func _on_serve_refused(peer_id: int, md5: String, reason: String) -> void:
	if not _speaking():
		return
	_stack.finish(KEY_UPLOAD % [peer_id, md5], String.chr(MenuIcons.ERROR),
		"Could not send %s to %s -- %s" % [_what(md5), _who(peer_id), reason],
		MenuToasts.DWELL_FAIL)
	_names.erase(md5)


## The late-join stream. "capturing" is the one that matters most to a host:
## every player in the room is stalled at that moment, and until now nothing
## said why.
func _on_join_progress(peer_id: int, phase: String, received: int, total: int) -> void:
	if not _speaking():
		return
	var key := KEY_JOIN % peer_id
	var who := _who(peer_id)
	match phase:
		"capturing":
			# A stall, not a transfer -- every player in the room is frozen at
			# this moment, which a download arrow would misdescribe.
			_stack.notify(key, String.chr(MenuIcons.PAUSED),
				"Pausing the game so %s can join" % who, -1.0, 0.0)
		"transferring":
			var frac := float(received) / float(total) if total > 0 else -1.0
			_stack.notify(key, String.chr(MenuIcons.UPLOAD),
				"Sending the game to %s" % who, frac, 0.0)
		"done":
			_stack.finish(key, String.chr(MenuIcons.CHECK),
				"%s is in the game" % who, MenuToasts.DWELL_OK)
		_:
			pass


func _on_join_requested(peer_id: int, _port: int) -> void:
	if not _speaking():
		return
	_stack.notify(KEY_WANTS % peer_id, String.chr(MenuIcons.RETRY),
		"%s wants to play -- press RESET on the machine to let them in" % _who(peer_id),
		-1.0, MenuToasts.DWELL_INFO)


func _on_desync(peer_id: int, _frame: int) -> void:
	if not _speaking():
		return
	_stack.finish(KEY_DESYNC % peer_id, String.chr(MenuIcons.ERROR),
		"%s drifted out of step and is now watching" % _who(peer_id),
		MenuToasts.DWELL_FAIL)


func _on_blocked(reason: String, _machine: Object, _remedy: Dictionary) -> void:
	if not _speaking():
		return
	_stack.finish(KEY_BLOCKED, String.chr(MenuIcons.ERROR),
		"%s -- see NET > Readiness" % reason, MenuToasts.DWELL_FAIL)


func _on_session_stopped(reason: String) -> void:
	if not _speaking():
		return
	_stack.finish(KEY_SESSION, String.chr(MenuIcons.CLOSE), reason,
		MenuToasts.DWELL_INFO)
