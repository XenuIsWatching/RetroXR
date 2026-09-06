## CartridgeOptionsPanel — floating 3D panel for a cartridge's battery saves.
##
## Parented to a RetroCartridge but top_level so it inherits no transform;
## floats above the cartridge facing the camera. Mirrors BookOptionsPanel.
## Selecting a save re-binds the cartridge's save_id ("recovery"); a new
## blank id means a fresh save. A save can also be deleted — armed on the first
## press and done on the second, and never while the console holding the game is
## on, which is the rule a memory card's saves follow too.
class_name CartridgeOptionsPanel
extends FloatingObjectPanel3D

const FLOAT_HEIGHT := 0.25

## What these saves belong to: a RetroCartridge in the room, or a
## CartridgeSaveTarget standing in for a ROM that has no cartridge — see
## adopt_external_ui. Read through _sysid()/_rom()/_label()/_save_id() so both
## kinds answer the same way.
var _cart: Object = null
## Set when another panel hosts a COPY of the UI (the core options Cartridge tab).
## This panel then drives that copy as well as its own quad — it does not stop
## owning the quad, and the two are never on screen at the same moment.
var _external_ui: CartridgeOptions2D = null
## Saves the server holds for this cartridge's ROM, fetched when the panel opens.
var _server_saves: Array = []
## And the save states it holds. Fetched on its own thread, so the States tab
## never waits behind the saves list or behind an upload.
var _server_states: Array = []
## save_ids whose last sync forked a conflict, so the row can say so until the
## user acts on it.
var _conflicted: Dictionary = {}
## The save whose delete is armed and waiting for a second press, or "".
var _armed_id := ""
## rom_path -> what a browse lookup returned for it, and the rom currently being
## asked about. See _lookup_achievements.
var _looked_up: Dictionary = {}
var _looking_up := ""
## How long a delete stays armed — the memory card's window, and the ROM rows'.
const ARM_SECONDS := 3.0

## get_node_or_null, not $: this class is also used bare (CartridgeOptionsPanel.new())
## to drive somebody else's UI, with no quad of its own to find.
@onready var _viewport_node: XRToolsViewport2DIn3D = \
	get_node_or_null("CartOptionsViewport") as XRToolsViewport2DIn3D


## Repopulate targets: this panel's own quad when it is up, and the embedded copy
## in the core options Cartridge tab whenever that exists. Without the second the
## embedded list never refreshes, because this node is never `visible`.
func _showing() -> bool:
	return visible or is_instance_valid(_external_ui)


func show_for(cart: RetroCartridge, camera: Node3D) -> void:
	_cart = cart
	_camera = camera
	if cart:
		global_position = cart.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	visible = true
	_ensure_ui_connected()
	_populate()
	_refresh_server_list()


## Drive a UI that lives somewhere else — the core options panel's Cartridge tab
## hosts an embedded CartridgeOptions2D, and all the save management, RomM sync
## and achievement lookup below should serve it rather than being written twice.
##
## The host owns the Control's lifetime; this node keeps only the reference and
## its own quad stays hidden.
##
## `cart` is a RetroCartridge, or a CartridgeSaveTarget when the host is showing a
## ROM from the library that has no cartridge in the room. The second kind reads
## everything and binds nothing — see _bindable().
func adopt_external_ui(ui: CartridgeOptions2D, cart: Object) -> void:
	_external_ui = ui
	_cart = cart
	_ensure_ui_connected()
	_populate()
	_refresh_server_list()


# ── The target, whichever kind it is ──────────────────────────────────────────

## A save belongs to the object you put in the machine, so only a real cartridge
## can be bound to one. A ROM standing in for itself can be read, synced and
## downloaded to, but never made "current".
func _bindable() -> bool:
	return _cart is RetroCartridge


func _sysid() -> String:
	return str(_cart.get("systemid")) if _cart != null else ""


func _rom() -> String:
	return str(_cart.get("rom_path")) if _cart != null else ""


func _label() -> String:
	return str(_cart.get("game_label")) if _cart != null else ""


func _save_id() -> String:
	return str(_cart.get("save_id")) if _cart != null else ""


func _bind_save(save_id: String) -> void:
	if _cart != null:
		_cart.set("save_id", save_id)


## The Control inside this panel's own quad, or null before it is built.
func _own_ui() -> CartridgeOptions2D:
	if _viewport_node == null:
		return null
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		return null
	return vp.get_child(0) as CartridgeOptions2D


## Every UI this panel is driving right now: its own quad's while that is up, and
## the embedded copy whenever a host has one.
##
## Both, not one of them. This used to answer with the embedded copy whenever it
## existed — so once a console's Cartridge tab had borrowed this panel, opening
## the cartridge's OWN panel populated the hidden copy instead: the quad floating
## in front of you was the freshly built, never-populated one, with an empty saves
## list (not even "New blank save") and a ✕ that had never been connected to
## anything. Feeding both also keeps the tab in step while the panel is up.
func _uis() -> Array[CartridgeOptions2D]:
	var out: Array[CartridgeOptions2D] = []
	if visible:
		var own := _own_ui()
		if own != null:
			out.append(own)
	if is_instance_valid(_external_ui) and not out.has(_external_ui):
		out.append(_external_ui)
	return out


## True while a UI this panel should be driving has not been built yet, so the
## caller knows to try again next frame rather than silently doing nothing.
func _ui_pending() -> bool:
	return visible and _own_ui() == null


func _ensure_ui_connected() -> void:
	if _ui_pending():
		call_deferred("_ensure_ui_connected")
	# Per UI rather than behind one flag: this panel drives two different Controls
	# over its life and whichever it meets second needs connecting too.
	for ui: CartridgeOptions2D in _uis():
		if not ui.save_selected.is_connected(_on_save_selected):
			ui.save_selected.connect(_on_save_selected)
			ui.sync_toggled.connect(_on_sync_toggled)
			ui.save_delete_requested.connect(_on_delete_requested)
			ui.server_save_requested.connect(_on_server_save_requested)
			ui.new_synced_save_requested.connect(_on_new_synced_save)
			ui.state_capture_requested.connect(_on_state_capture_requested)
			ui.state_overwrite_requested.connect(_on_state_overwrite_requested)
			ui.state_load_requested.connect(_on_state_load_requested)
			ui.state_delete_requested.connect(_on_state_delete_requested)
			ui.server_state_requested.connect(_on_server_state_requested)
		# The embedded copy has no ✕ of its own; its host closes it.
		if ui != _external_ui and not ui.close_requested.is_connected(hide_panel):
			ui.close_requested.connect(hide_panel)
	# One-shot: these are global signals, and the guard is what stops a second
	# adopt_external_ui() stacking another connection on every one.
	if not SaveSync.sync_finished.is_connected(_on_sync_finished):
		SaveSync.sync_finished.connect(_on_sync_finished)
		SaveSync.rom_id_resolved.connect(_on_rom_id_resolved)
		StateSync.upload_started.connect(_on_state_backup_changed.bind(true, ""))
		StateSync.upload_finished.connect(_on_state_backup_finished)
		StateSync.listed.connect(_on_states_listed)
		SaveSync.conflict_forked.connect(_on_conflict_forked)
		RA.game_loaded.connect(_on_ra_changed)
		RA.achievement_unlocked.connect(_on_ra_unlocked)


func _populate() -> void:
	if not _cart:
		return
	if _ui_pending():
		call_deferred("_populate")
		return
	var uis := _uis()
	if uis.is_empty():
		return
	var core := SramPaths.core_for_systemid(_sysid())
	var saves: Array = SramPaths.list_saves(core, _rom()) if not core.is_empty() else []

	var states: Dictionary = {}
	for s: Variant in saves:
		var sid := str((s as Dictionary).get("save_id", ""))
		var path := SramPaths.cart_save_path(core, _rom(), sid)
		if _conflicted.has(sid):
			states[sid] = "conflict"
		elif SaveSync.current_key() == RommSaveSync.key_for(path):
			states[sid] = "busy"
		elif SaveSync.is_enabled(path):
			states[sid] = "on"
		else:
			states[sid] = "off"

	# Which saves the server actually holds — not which are opted in. A save whose
	# game RomM does not know stays opted in and never uploads, and the bin on its
	# row must not promise a copy that is not there.
	var backed: Dictionary = {}
	for s: Variant in saves:
		var sid := str((s as Dictionary).get("save_id", ""))
		if SaveSync.key_backed_up(
				RommSaveSync.key_for(SramPaths.cart_save_path(core, _rom(), sid))):
			backed[sid] = true

	for ui: CartridgeOptions2D in uis:
		ui.selectable = _bindable()
		ui.backed_up = backed
		ui.armed_id = _armed_id
		ui.delete_blocked = _in_use_reason()
		ui.populate(_label(), _rom(), saves, _save_id(),
			not core.is_empty(), states, _server_only(saves), _romm_ready())
		_populate_states(ui)
		_populate_achievements(ui)


## The Achievements ribbon. rcheevos keeps one session for the whole app, so the
## list it holds belongs to whichever machine claimed it — this cartridge only
## gets to show it when it is the one in that machine. Every other case is an
## empty state with the reason, because "no achievements" and "not this cart" and
## "not signed in" are different problems and the player can only fix one of them.
func _populate_achievements(ui: CartridgeOptions2D) -> void:
	if not RA.is_available():
		ui.populate_achievements([], {}, "Achievements are unavailable in this build.")
		return
	if not RaConsoles.is_supported(_sysid()):
		var what := _sysid() if not _sysid().is_empty() else "this system"
		ui.populate_achievements([], {},
			"RetroAchievements has no achievement sets for %s." % what)
		return
	if not RA.is_logged_in():
		ui.populate_achievements([], {},
			"Sign in to RetroAchievements in OPTIONS to track achievements.")
		return
	if not _is_live_cartridge():
		# Not running, so rcheevos' session holds nothing for it — but the set and
		# this player's unlocks can still be fetched from the ROM alone. Live
		# progress (measured bars, what just triggered) is the part that needs the
		# game running; what is earned and what is left does not.
		_lookup_achievements(ui)
		return

	var entries := RA.achievements()
	if entries.is_empty():
		ui.populate_achievements([], {},
			"RetroAchievements has no achievement set for this game.")
		return
	ui.populate_achievements(entries, RA.game_info(), "")


## Ask the server what this ROM's achievements are, and which the player has.
##
## Cached per ROM for the life of the panel: the ribbon is repopulated on every
## sync result and every save edit, and three HTTP round trips per redraw would
## be both slow and rude. A repeat ask for the same ROM redraws from what came
## back the first time.
func _lookup_achievements(ui: CartridgeOptions2D) -> void:
	var rom := _rom()
	if _looked_up.has(rom):
		var got: Dictionary = _looked_up[rom]
		ui.populate_achievements(got["achievements"], got["summary"], str(got["state"]))
		return
	if _looking_up == rom:
		ui.populate_achievements([], {}, "Asking RetroAchievements…")
		return

	_looking_up = rom
	ui.populate_achievements([], {}, "Asking RetroAchievements…")
	RA.lookup_achievements(_sysid(), rom, func(ok: bool, info: Dictionary) -> void:
		if not is_instance_valid(self):
			return
		_looking_up = ""
		var entries: Array = info.get("achievements", [])
		var state := ""
		if not ok:
			state = str(info.get("error", "Could not reach RetroAchievements."))
		elif int(info.get("game_id", 0)) == 0:
			state = "RetroAchievements does not recognise this ROM."
		elif entries.is_empty():
			state = "RetroAchievements has no achievement set for this game."
		var unlocked := 0
		var points := 0
		var points_unlocked := 0
		for e: Dictionary in entries:
			points += int(e.get("points", 0))
			if bool(e.get("unlocked", false)):
				unlocked += 1
				points_unlocked += int(e.get("points", 0))
		_looked_up[rom] = {
			"achievements": entries,
			"summary": {
				"title": info.get("title", ""),
				"badge_url": info.get("badge_url", ""),
				"num_achievements": entries.size(),
				"num_unlocked": unlocked,
				"points_total": points,
				"points_unlocked": points_unlocked,
			},
			"state": state,
		}
		if _showing():
			_populate())


## True when the game in the machine holding the RA session is this one.
##
## By ROM as well as by object: a library page has no cartridge to be identical
## to, and the game it is asking about may be the one running right now — which is
## exactly when its achievements are worth showing.
func _is_live_cartridge() -> bool:
	var owner_system := RA.session_owner()
	if owner_system == null or not owner_system.has_method("get_snapped_cartridge"):
		return false
	var seated: Node = owner_system.get_snapped_cartridge()
	if seated == null:
		return false
	if seated == _cart:
		return true
	var rom := _rom()
	return not rom.is_empty() and str(seated.get("rom_path")) == rom


func _on_ra_changed(_ok: bool, _title: String, _n: int, _u: int, _err: String) -> void:
	if _showing():
		_populate()


func _on_ra_unlocked(_id: int, _t: String, _d: String, _p: int, _b: Texture2D) -> void:
	if _showing():
		_populate()


## Server slots with no local .srm. The list is fetched on open, so this only
## filters what is already known — it never blocks the panel.
func _server_only(local: Array) -> Array:
	var have: Dictionary = {}
	for s: Variant in local:
		have[str((s as Dictionary).get("save_id", ""))] = true
	var out: Array = []
	for e: Dictionary in _server_saves:
		var slot := str(e.get("slot", ""))
		# Memory-card slots belong to a card, not to this cartridge.
		#
		# `state:` is belt-and-braces rather than a live hazard: save states go
		# to /api/states, a separate endpoint family with no slot field at all,
		# so none of them can reach this list today. It is here because the day
		# anything routes a state through the saves namespace, every state the
		# player has ever taken would appear in SAVES as a phantom battery save
		# offering to download over their real one.
		if slot.is_empty() or slot.begins_with("card:") \
				or slot.begins_with("state:") or have.has(slot):
			continue
		out.append(e)
	return out


func _romm_ready() -> bool:
	return SaveSync.is_available() and _rom_id() > 0


func _rom_id() -> int:
	if _cart == null:
		return 0
	return SaveSync.rom_id_for(_sysid(), _rom())


func _on_save_selected(save_id: String) -> void:
	# Only a cartridge can carry a save. The UI hides these rows' action when the
	# target cannot be bound, so this is the belt to that braces.
	if _cart == null or not is_instance_valid(_cart) or not _bindable():
		return
	if save_id.is_empty():
		# New blank save: mint a fresh identity — the first flush creates it.
		_bind_save("%08x%08x" % [randi(), randi()])
	else:
		_bind_save(save_id)
	print("[CartridgeOptions] %s bound to save %s" % [_label(), _save_id()])
	_populate()


## Start a fresh save already set to sync. Sync is recorded against the path
## before any file exists, so the very first flush uploads instead of the user
## having to come back and toggle it afterwards.
func _on_new_synced_save() -> void:
	if _cart == null or not is_instance_valid(_cart) or not _bindable():
		return
	var core := SramPaths.core_for_systemid(_sysid())
	var rid := _rom_id()
	if core.is_empty() or rid <= 0:
		return
	var new_id := "%08x%08x" % [randi(), randi()]
	_bind_save(new_id)
	SaveSync.set_enabled(SramPaths.cart_save_path(core, _rom(), new_id), true, rid)
	print("[CartridgeOptions] %s bound to new synced save %s" % [_label(), new_id])
	_populate()


## Why a save must not be deleted right now, or "".
##
## A running game owns its .srm: the core holds the save data and writes it back
## on its next flush, so a file deleted underneath simply reappears — and the one
## time it does not is when it takes the session's progress with it. Powering the
## console off is the honest fix, which is what a memory card's list says too.
func _in_use_reason() -> String:
	if _cart == null or not is_inside_tree():
		return ""
	var rom := _rom()
	for sys: Node in get_tree().get_nodes_in_group("retro_system"):
		if not sys.has_method("get_snapped_cartridge"):
			continue
		var seated: Node = sys.get_snapped_cartridge()
		if seated == null:
			continue
		if seated != _cart and str(seated.get("rom_path")) != rom:
			continue
		if bool(sys.get("is_powered_on")):
			return "in use — power the console off first"
	return ""


## Delete one save's file. Armed on the first press and done on the second: this
## cannot be undone, and the row says which of the two it is by the bin it shows.
func _on_delete_requested(save_id: String) -> void:
	if save_id.is_empty() or not _in_use_reason().is_empty():
		return
	if _armed_id != save_id:
		_armed_id = save_id
		_populate()
		if is_inside_tree():
			get_tree().create_timer(ARM_SECONDS).timeout.connect(func() -> void:
				if _armed_id == save_id and is_instance_valid(self):
					_armed_id = ""
					_populate())
		return
	_armed_id = ""
	var core := SramPaths.core_for_systemid(_sysid())
	if not SramPaths.delete_save(core, _rom(), save_id):
		push_warning("[CartridgeOptions] could not delete save '%s'" % save_id)
	# The cartridge was using the file that just went: leave it pointing there and
	# the next flush writes it back. A fresh identity is what "no save" means.
	elif _bindable() and _save_id() == save_id:
		_bind_save("%08x%08x" % [randi(), randi()])
	_populate()


## Turn syncing on or off for one save. Turning it on reconciles immediately
## rather than waiting for the next flush, so a save made on another device
## arrives as soon as you ask for it.
func _on_sync_toggled(save_id: String, on: bool) -> void:
	if _cart == null or not is_instance_valid(_cart):
		return
	var core := SramPaths.core_for_systemid(_sysid())
	if core.is_empty():
		return
	var path := SramPaths.cart_save_path(core, _rom(), save_id)
	var rid := _rom_id()
	SaveSync.set_enabled(path, on, rid)
	if on and rid > 0:
		_conflicted.erase(save_id)
		SaveSync.enqueue(path, rid, core, save_id, _label())
	_populate()


## Pull a save that only exists on the server. It lands under its own slot id,
## which becomes a local save_id, and the cartridge binds to it — so the two
## sides agree on identity from the first sync onwards.
func _on_server_save_requested(slot: String) -> void:
	if _cart == null or not is_instance_valid(_cart):
		return
	var core := SramPaths.core_for_systemid(_sysid())
	var rid := _rom_id()
	if core.is_empty() or rid <= 0:
		return
	var path := SramPaths.cart_save_path(core, _rom(), slot)
	SaveSync.set_enabled(path, true, rid)
	SaveSync.enqueue(path, rid, core, slot, _label())
	# Harmless on a stand-in, which nothing reads back — the download is the point
	# there, and the cartridge you spawn later finds the file waiting.
	_bind_save(slot)
	_populate()


func _on_sync_finished(_key: String, _action: String, _ok: bool, _detail: String) -> void:
	if _showing():
		_refresh_server_list()
		_populate()


func _on_conflict_forked(_key: String, forked_save_id: String, _label: String) -> void:
	# Flag the fork, not the original: the fork is the copy the user has not
	# seen, and it is the one that needs explaining.
	_conflicted[forked_save_id] = true
	if _showing():
		_populate()


## Ask the server what it has for this ROM. Runs on SaveSync's worker, so the
## panel draws immediately with whatever it already knew.
func _refresh_server_list() -> void:
	var rid := _rom_id()
	# A ROM with no RomM id yet may still BE on the server — gamelist.json only
	# records one for a ROM that came from there. Ask by content hash, once, off
	# the main thread, and the answer is kept for good. This is the moment for
	# it: the panel is open, so the cost is paid where it is expected.
	if rid <= 0 and SaveSync.is_available() and not _rom().is_empty() \
			and SaveSync.resolved_rom_id(_sysid(), _rom()) < 0:
		SaveSync.resolve_rom_id(_sysid(), _rom())
	if rid > 0 and StateSync.is_available():
		StateSync.list_for_rom(rid)
	if rid <= 0 or not SaveSync.is_available():
		_server_saves = []
		_server_states = []
		return
	SaveSync.list_server_saves(rid, func(ok: bool, saves: Array) -> void:
		if not ok:
			return
		_server_saves = saves
		if _showing():
			_populate()
	)


# ── Save states ───────────────────────────────────────────────────────────────
#
# The list is read from disk; taking and restoring one needs a live machine, so
# every action first asks which console in the room is running this game. The
# panel is routinely open with no machine at all (the library shows it for a ROM
# nobody has spawned), and that case has to read as "nothing to take a state
# from", not as a broken button.

## The state waiting on a second press, and which action is waiting. ONE slot:
## arming either action disarms the other, so a row is never waiting on two
## confirmations at once.
var _states_armed_id := ""
var _states_armed_action := ""
## Set while a capture or a load is in flight, so the tab can say so and the
## second press of a doubled click cannot start a second one.
var _state_busy := ""


## The console in the room running this cartridge's game, or null. Same walk the
## in-use check makes — a save state belongs to a machine, not to a ROM.
func _live_machine() -> Node:
	if _cart == null or not is_inside_tree():
		return null
	var rom := _rom()
	for sys: Node in get_tree().get_nodes_in_group("retro_system"):
		if not sys.has_method("get_snapped_cartridge"):
			continue
		var seated: Node = sys.get_snapped_cartridge()
		if seated == null:
			continue
		if seated == _cart or str(seated.get("rom_path")) == rom:
			return sys
	return null


## Why a state cannot be taken right now, or "". Loading is deliberately NOT
## blocked by any of these: a machine that is off powers itself on to do it.
func _capture_blocked() -> String:
	if not _state_busy.is_empty():
		return _state_busy
	var sys := _live_machine()
	if sys == null:
		return "no machine is running this game"
	if not sys.has_method("capture_gate"):
		return "this machine cannot take save states"
	var gate: Dictionary = sys.capture_gate()
	return "" if bool(gate.get("ok", false)) else str(gate.get("reason", ""))


func _populate_states(ui: CartridgeOptions2D) -> void:
	var core := SramPaths.core_for_systemid(_sysid())
	if core.is_empty():
		ui.capture_blocked = "insert this cartridge into a console once first"
		ui.populate_states([], 0)
		return
	var rows := StatePaths.list_states(core, _rom())
	ui.capture_blocked = _capture_blocked()
	ui.states_armed_id = _states_armed_id
	ui.states_armed_action = _states_armed_action
	ui.populate_states(rows, StatePaths.total_bytes(core, _rom()),
		StateSync.statuses_for(core, _rom(), rows),
		StateSync.server_only(core, _rom(), _server_states),
		_backup_notice(core, rows),
		StateSync.backup_enabled() and _rom_id() > 0)


## Why there is no RomM column, when there isn't one.
##
## Silence here is what "I don't see the option to back it up" looks like: the
## rows just read "On this device" and nothing says whether that is a setting, a
## missing server, or this particular game. Each of these names the one thing
## the player could act on.
func _backup_notice(core: String, rows: Array) -> String:
	# A failure beats an explanation — it is the one the player can fix now.
	var failed := StateSync.failure_notice(core, _rom(), rows)
	if not failed.is_empty():
		return failed
	# No server configured at all is not a problem to report; RomM simply is not
	# part of how this player uses the app.
	if not SaveSync.is_available():
		return ""
	if StateSync.config != null and not StateSync.config.backup_enabled:
		return "Backing up is off — turn on \"Back up saves and states\" in OPTIONS ▸ RomM."
	if _rom_id() <= 0:
		# Not "RomM does not have this game" — it very often does. gamelist.json
		# only carries a RomM id for a ROM that was DOWNLOADED from RomM; a
		# hand-copied one carries a scraper id instead, which looks similar and
		# means something else. So the honest states are "still asking" and
		# "asked, and it is not there", and the two must not be conflated.
		if SaveSync.is_resolving():
			return "Checking whether RomM has this game…"
		if SaveSync.lookup_failed(_sysid(), _rom()):
			# Asked and got nothing back — a timeout or a dropped connection.
			# Never cached, so it is retried the next time this panel opens; say
			# that rather than leaving a "checking…" that will never finish, and
			# never say "RomM does not have it", which is a different claim.
			return "Could not reach RomM to check for this game — it will try again."
		if SaveSync.resolved_rom_id(_sysid(), _rom()) == 0:
			return "RomM does not have this ROM, so its save states stay on this device."
		# Never asked. The lookup is kicked off when the panel opens, so this is
		# the blink before it starts; nothing useful to say yet.
		return ""
	return ""


## Arm, then do. Both writing actions and the delete share one slot, so pressing
## one clears whatever the other was waiting for.
func _arm_state(state_id: String, action: String) -> bool:
	if _states_armed_id == state_id and _states_armed_action == action:
		_states_armed_id = ""
		_states_armed_action = ""
		return true
	_states_armed_id = state_id
	_states_armed_action = action
	_populate()
	if is_inside_tree():
		get_tree().create_timer(ARM_SECONDS).timeout.connect(func() -> void:
			if is_instance_valid(self) and _states_armed_id == state_id \
					and _states_armed_action == action:
				_states_armed_id = ""
				_states_armed_action = ""
				_populate())
	return false


func _on_state_capture_requested() -> void:
	if not _capture_blocked().is_empty():
		return
	_begin_capture("")


func _on_state_overwrite_requested(state_id: String) -> void:
	if not _capture_blocked().is_empty():
		return
	if not _arm_state(state_id, "overwrite"):
		return
	_begin_capture(state_id)


func _begin_capture(into_id: String) -> void:
	var sys := _live_machine()
	if sys == null:
		return
	_state_busy = "taking a save state…"
	_connect_machine(sys)
	sys.capture_state(into_id)
	_populate()


func _on_state_load_requested(state_id: String) -> void:
	if not _state_busy.is_empty():
		return
	var sys := _live_machine()
	if sys == null:
		return
	# Loading disarms whatever was waiting: the press landed on the plate, not on
	# the button that was asking for a second one.
	_states_armed_id = ""
	_states_armed_action = ""
	_state_busy = "loading a save state…"
	_connect_machine(sys)
	sys.load_state(state_id)
	_populate()


func _on_state_delete_requested(state_id: String) -> void:
	if not _arm_state(state_id, "delete"):
		return
	var core := SramPaths.core_for_systemid(_sysid())
	# Forget the picture first: the path is reused if this id is ever minted
	# again, and a cache keyed on it would serve the dead one.
	for ui: CartridgeOptions2D in _uis():
		ui.forget_thumb(StatePaths.shot_path(core, _rom(), state_id))
	if StatePaths.delete_state(core, _rom(), state_id):
		# The ledger goes too, or a state minted later at the same path would
		# inherit this one's server id and PUT over a stranger's copy.
		StateSync.forget(StatePaths.state_path(core, _rom(), state_id))
		print("[CartridgeOptions] deleted save state %s" % state_id)
	_populate()


## One connection per machine, kept for the life of the panel. A machine answers
## exactly once per request, so these fire and the tab redraws.
func _connect_machine(sys: Node) -> void:
	if not sys.has_signal("state_captured"):
		return
	if not sys.is_connected("state_captured", _on_state_captured):
		sys.connect("state_captured", _on_state_captured)
		sys.connect("state_loaded", _on_state_loaded)


func _on_state_captured(state_id: String, ok: bool, reason: String) -> void:
	_state_busy = ""
	if not is_instance_valid(self):
		return
	# Every state uploads as it is made — that is what "Back up saves and states"
	# means. An overwrite PUTs over the copy this row already has on the server
	# rather than uploading its name twice.
	if ok:
		StateSync.enqueue(SramPaths.core_for_systemid(_sysid()), _rom(), state_id, _rom_id())
	# An overwrite writes a NEW picture to the SAME path, so the cache has to be
	# told or the row keeps showing the frame it replaced.
	var core := SramPaths.core_for_systemid(_sysid())
	for ui: CartridgeOptions2D in _uis():
		ui.forget_thumb(StatePaths.shot_path(core, _rom(), state_id))
	if not ok:
		push_warning("[CartridgeOptions] save state failed: %s" % reason)
	_populate()


func _on_state_loaded(_state_id: String, ok: bool, reason: String) -> void:
	_state_busy = ""
	if not is_instance_valid(self):
		return
	if not ok:
		push_warning("[CartridgeOptions] loading a save state failed: %s" % reason)
	_populate()


## The RomM half of the States tab: a status glyph moving, a listing landing, or
## a pull finishing. All of them mean the same thing here — redraw.
func _on_state_backup_changed(_key: String, _ok: bool, _detail: String) -> void:
	if _showing():
		_populate()


func _on_state_backup_finished(key: String, ok: bool, detail: String) -> void:
	if not ok:
		push_warning("[CartridgeOptions] RomM: %s (%s)" % [detail, key])
	if _showing():
		_populate()


## The hash lookup came back. A hit turns the whole RomM half of both tabs on
## for this game, so both lists want redrawing — and the server's states for it
## are only worth asking for now that there is an id to ask with.
func _on_rom_id_resolved(_systemid: String, rom_path: String, rom_id: int) -> void:
	if rom_path != _rom():
		return
	if rom_id > 0:
		_refresh_server_list()
	if _showing():
		_populate()


func _on_states_listed(rom_id: int, ok: bool, states: Array, _detail: String) -> void:
	if not ok or rom_id != _rom_id():
		return
	_server_states = states
	if _showing():
		_populate()


## Pull a state the server has and this device does not. It arrives in the
## normal local layout, after which it is an ordinary row.
func _on_server_state_requested(state_id: String) -> void:
	var core := SramPaths.core_for_systemid(_sysid())
	for e: Variant in StateSync.server_only(core, _rom(), _server_states):
		if str((e as Dictionary)["state_id"]) == state_id:
			StateSync.download(core, _rom(), e as Dictionary)
			return


# ── Placement, for FloatingObjectPanel3D ─────────────────────────────────────

func _target_node() -> Node3D:
	return _cart as Node3D


func _float_height() -> float:
	return FLOAT_HEIGHT
