## LoadingOverlay — one loading screen, shared by everything that can make the
## room unusable while it works.
##
## LoadingRig covers the gap where no room is in the tree. It cannot cover what
## happens either side of that gap, because it owns a WorldEnvironment and a
## camera and so has to leave before the incoming scene enters. But the expensive
## part happens AFTER it leaves: the slot restore spawns objects into a room the
## player is already looking at, which is the pop-in this exists to hide. At cold
## boot there is no rig at all, and on a netplay join the world arrives from the
## host later still.
##
## So the screen is not owned by one caller. Several things can be "still
## loading" at once — the boot model warm and the boot slot restore overlap by
## design — and each registers as an OWNER. The panel goes up on the first
## begin() and comes down after the last end(), which means no caller has to know
## what else is running.
##
## Progress is a weighted mean across live owners, then clamped monotonic for the
## life of one show: a new owner joining mid-show drops the raw mean, and a bar
## that goes backwards reads as a bug. The STATUS TEXT carries the truth instead,
## showing whichever owner is furthest behind — the one actually gating.
extends Node


signal overlay_shown()
signal overlay_hidden()

const PANEL_SCENE := preload("res://Scenes/UI/loading_panel.tscn")

## Grace period on the last end() before the panel is taken down. Two owners
## handing off — the boot warm finishing a frame before the restore registers —
## must not flash the room between them.
const HOLD_S := 0.25

## A joiner whose host dies after accepting it would otherwise sit under the
## curtain for ever. Long enough not to fire on a slow but working transfer.
const JOIN_TIMEOUT_S := 30.0

## owner -> {weight, progress, text, detail, order}
var _owners: Dictionary = {}
var _order: int = 0
var _panel: LoadingPanel = null
## Monotonic floor for the current show, reset when the panel comes down.
var _shown_progress: float = 0.0
var _hide_token: int = 0
var _suspended: bool = false
var _join_token: int = 0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_connect_scene_manager.call_deferred()
	_connect_netplay.call_deferred()


func _process(_delta: float) -> void:
	if _owners.is_empty():
		return
	_poll_model_warmer()
	if _panel == null or not _panel.is_inside_tree():
		return
	if not _suspended and not _panel_attached():
		_attach()


# ── Owner bookkeeping ─────────────────────────────────────────────────────────

## Register `owner` as something being waited on. Calling it twice for the same
## owner refreshes the title rather than double-counting, which is what makes a
## coalesced room transition safe.
func begin(owner: StringName, title: String = "", weight: float = 1.0) -> void:
	_hide_token += 1
	if _owners.has(owner):
		if not title.is_empty():
			_owners[owner]["title"] = title
			_apply()
		return
	_order += 1
	_owners[owner] = {
		"weight": maxf(weight, 0.01),
		"progress": 0.0,
		"text": "",
		"title": title,
		"detail": PackedStringArray(),
		"order": _order,
	}
	_show()
	_apply()


func set_phase(owner: StringName, text: String, progress: float) -> void:
	if not _owners.has(owner):
		return
	_owners[owner]["text"] = text
	_owners[owner]["progress"] = clampf(progress, 0.0, 1.0)
	_apply()


func set_detail(owner: StringName, rows: PackedStringArray) -> void:
	if not _owners.has(owner):
		return
	_owners[owner]["detail"] = rows
	_apply()


## Unregister. Unknown owners are ignored on purpose: the same boundary
## (notify_scene_content_ready) ends the boot restore and a room transition, and
## only one of them is ever registered.
func end(owner: StringName) -> void:
	if not _owners.erase(owner):
		return
	if _owners.is_empty():
		_begin_hide()
	else:
		_apply()


## Pin the panel on an error. It stays up, showing why, until this owner is
## explicitly ended — a failure the player never sees is the thing being fixed.
func fail(owner: StringName, message: String) -> void:
	if not _owners.has(owner):
		begin(owner)
	_owners[owner]["failed"] = true
	if _panel != null:
		_panel.show_load_error(message)


func is_active() -> bool:
	return not _owners.is_empty()


func owners() -> Array:
	return _owners.keys()


## Weighted mean of every live owner, before the monotonic clamp. Exposed for the
## tests, which need to see the raw number.
func aggregate_progress() -> float:
	if _owners.is_empty():
		return 0.0
	var total := 0.0
	var sum := 0.0
	for key: Variant in _owners:
		var row: Dictionary = _owners[key]
		total += float(row["weight"])
		sum += float(row["weight"]) * float(row["progress"])
	return sum / total if total > 0.0 else 0.0


# ── Panel lifetime ────────────────────────────────────────────────────────────

func _show() -> void:
	if _panel != null:
		return
	_shown_progress = 0.0
	_panel = PANEL_SCENE.instantiate()
	add_child(_panel)
	_panel.reset()
	if not _suspended:
		_attach()
	overlay_shown.emit()


func _begin_hide() -> void:
	_hide_token += 1
	var token := _hide_token
	await get_tree().create_timer(HOLD_S).timeout
	if token != _hide_token or not _owners.is_empty():
		return
	_teardown()


func _teardown() -> void:
	if _panel == null:
		return
	# detach() runs from the panel's own _exit_tree, reclaiming the curtain from
	# whichever camera it was welded to.
	var panel := _panel
	_panel = null
	_shown_progress = 0.0
	panel.queue_free()
	overlay_hidden.emit()


func _panel_attached() -> bool:
	return _panel != null and _panel.get_parent() != self


## Park the panel on the player's rig, so it survives the room being torn down —
## SceneManager carries that rig across a transition and re-seats it in the new
## room. Anything parented to the scene root would be freed with the old room.
func _attach() -> void:
	if _panel == null:
		return
	var player := _current_player()
	if player == null or not is_instance_valid(player.camera):
		return
	if _panel.get_parent() != null:
		_panel.get_parent().remove_child(_panel)
	player.origin.add_child(_panel)
	_panel.attach_to(player.camera, player.origin)


func _detach_panel() -> void:
	if _panel == null:
		return
	_panel.detach()
	if _panel.get_parent() != null and _panel.get_parent() != self:
		_panel.get_parent().remove_child(_panel)
		add_child(_panel)


func _current_player() -> PlayerRig:
	var scene := get_tree().current_scene
	if scene == null:
		return null
	return scene.get_node_or_null("PlayerRig") as PlayerRig


## Step aside while LoadingRig has the view. The owners are kept: the transition
## is a pause in the same wait, not the end of it.
func suspend() -> void:
	_suspended = true
	if _panel != null:
		_detach_panel()
		_panel.visible = false


func resume() -> void:
	_suspended = false
	if _panel != null:
		_panel.visible = true
		_attach()


# ── Rendering the aggregate ───────────────────────────────────────────────────

func _apply() -> void:
	if _panel == null:
		return
	_shown_progress = maxf(_shown_progress, aggregate_progress())
	_panel.set_progress(_shown_progress)

	# The owner furthest from done is the one holding everyone up, so it is the
	# one worth naming.
	var gating: Dictionary = {}
	var title := ""
	var rows := PackedStringArray()
	var ordered := _owners.keys()
	ordered.sort_custom(func(a: Variant, b: Variant) -> bool:
		return int(_owners[a]["order"]) < int(_owners[b]["order"]))
	for key: Variant in ordered:
		var row: Dictionary = _owners[key]
		if gating.is_empty() or float(row["progress"]) < float(gating["progress"]):
			gating = row
		if title.is_empty() and not str(row["title"]).is_empty():
			title = str(row["title"])
		rows.append_array(row["detail"] as PackedStringArray)
	if not title.is_empty():
		_panel.set_title(title)
	_panel.set_status(str(gating.get("text", "")))
	_panel.set_detail(rows)


# ── Sources ───────────────────────────────────────────────────────────────────

func _poll_model_warmer() -> void:
	if not _owners.has(&"boot_warm"):
		return
	var total: int = ModelWarmer.warm_total
	var done: int = ModelWarmer.warm_done
	var phase: String = ModelWarmer.warm_phase
	if total <= 0:
		return
	set_phase(&"boot_warm", "WARMING %s  %d / %d" % [phase.to_upper(), done, total],
		float(done) / float(total))


func _connect_scene_manager() -> void:
	var sm := get_node_or_null("/root/SceneManager")
	if sm == null:
		return
	# A transition hands the view to LoadingRig, which owns a WorldEnvironment and
	# must be the only screen up. Suspending on the signal keeps SceneManager from
	# having to know we exist at that end.
	sm.scene_changed.connect(func(_id: String) -> void: suspend())


func _connect_netplay() -> void:
	var nm := get_node_or_null("/root/NetworkManager")
	if nm == null:
		return
	nm.session_started.connect(_on_net_session_started)
	nm.session_ended.connect(func(_reason: String) -> void: end(&"netplay"))
	if nm.has_signal(&"netplay_state_progress"):
		nm.netplay_state_progress.connect(_on_net_state_progress)
	var sync: NetObjectSync = nm.object_sync()
	if sync != null and sync.has_signal(&"world_applied"):
		sync.world_applied.connect(func(_count: int) -> void: end(&"netplay"))


func _on_net_session_started(is_host: bool) -> void:
	if is_host:
		return
	begin(&"netplay", "JOINING ROOM", 1.0)
	set_phase(&"netplay", "WAITING FOR THE HOST", 0.02)
	_join_token += 1
	var token := _join_token
	await get_tree().create_timer(JOIN_TIMEOUT_S).timeout
	if token == _join_token and _owners.has(&"netplay"):
		fail(&"netplay", "HOST DID NOT RESPOND")


## The savestate transfer the netplay session runs alongside the world snapshot.
## It is shown as detail rows, never as the reason the curtain is up: a join into
## a room with no running game emits none of these, so the curtain's lifetime
## belongs to world_applied instead.
##
## The joiner tags its own progress with the HOST's id (1), not its own — see
## NetplaySession. A client's unique_id is never 1, so "peer_id == 1" is exactly
## "this is about my own join".
func _on_net_state_progress(peer_id: int, phase: String, received: int, total: int) -> void:
	# The netplay owner only exists on a joining client — _on_net_session_started
	# returns early for the host — so its presence is already the "am I the one
	# joining" test, and a further is_client() check would only make this
	# untestable without a live session.
	if not _owners.has(&"netplay") or peer_id != 1:
		return
	var row := ""
	match phase:
		"capturing":
			row = "HOST CAPTURING STATE"
		"transferring":
			row = "RECEIVING STATE  %.1f / %.1f MB" % [
				float(received) / 1048576.0, float(total) / 1048576.0]
		"verifying":
			row = "VERIFYING STATE"
		"loading":
			row = "LOADING STATE"
		_:
			row = phase.to_upper()
	set_detail(&"netplay", PackedStringArray([row]))
