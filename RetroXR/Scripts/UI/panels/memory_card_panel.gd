## MemoryCardPanel — floating 3D panel listing what is saved on a memory card.
##
## Parented to a MemoryCard but uses top_level=true so it inherits no transform.
## Each frame it repositions above the owning card and faces the camera.
## Opened/closed via show_for()/hide_panel(); also has an in-UI ✕.
## Mirrors MouseOptionsPanel / TVOptionsPanel.
##
## The card image is re-read every time the panel opens: a card seated in a
## running console is being written to as the player saves, so anything cached
## from last time would be stale.
class_name MemoryCardPanel
extends FloatingObjectPanel3D

## Height above the card's origin at which the panel floats.
const FLOAT_HEIGHT := 0.32

## How long a delete stays armed. Matches the card shelf and the ROM rows.
const ARM_SECONDS := 3.0

var _card: MemoryCard = null
## Save slot whose delete has been armed and is waiting for a second press.
var _armed_slot := ""
## The bars that float in front of this panel — the spawn menu's stack, hosted
## here. Results are transient and belong over the page, not inside a list that
## is about to be redrawn under them.
var _toasts: MenuToasts = null

@onready var _viewport_node: XRToolsViewport2DIn3D = $MemoryCardViewport


# ── Public API ─────────────────────────────────────────────────────────────────

func show_for(card: MemoryCard, camera: Node3D) -> void:
	_card = card
	_camera = camera
	if _card:
		global_position = _card.global_position + Vector3(0, FLOAT_HEIGHT, 0)
	visible = true
	_ensure_ui_connected()
	_populate()


# ── Internal helpers ───────────────────────────────────────────────────────────

func _get_ui() -> MemoryCard2D:
	var vp := _viewport_node.get_node_or_null("Viewport") as SubViewport
	if not vp or vp.get_child_count() == 0:
		return null
	return vp.get_child(0) as MemoryCard2D


func _ensure_ui_connected() -> void:
	if _ui_connected:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_ensure_ui_connected")
		return
	ui.name_committed.connect(_on_renamed)
	ui.close_requested.connect(hide_panel)
	ui.save_delete_requested.connect(_on_delete_requested)
	ui.save_sync_toggled.connect(_on_sync_toggled)
	ui.restore_requested.connect(_on_restore_requested)
	ui.restore_picked.connect(_on_restore_picked)
	ui.restore_closed.connect(_populate)
	# The stack lifts itself onto its own quad in front of whichever Viewport2Din3D
	# hosts it — this panel's, here — so it needs to live in the 2D tree.
	_toasts = MenuToasts.create()
	ui.add_child(_toasts)
	_ui_connected = true


## Say what just happened, in front of the panel rather than inside it.
func _notice(text: String, seconds := MenuToasts.DWELL_OK) -> void:
	if is_instance_valid(_toasts):
		_toasts.notice(text, seconds)


## This card's image, or "" when it has none. A card only gets one the first
## time it is seated in a powered console.
func _path() -> String:
	if not (_card and is_instance_valid(_card)):
		return ""
	return SramPaths.find_card(_card.card_id, _card.family)


## The format this card is in. Never null for a card in the room — a MemoryCard
## always carries a family — but menu code checks anyway.
func _fmt() -> CardFormat:
	return CardFormats.for_family(_card.family) if _card else null


func _populate() -> void:
	if not _card:
		return
	var ui := _get_ui()
	if not ui:
		call_deferred("_populate")
		return

	# A card that has never been in a powered console has no image yet. That is
	# not an error — it is a blank card, and saying so beats an empty panel.
	var fmt := _fmt()
	if fmt == null:
		return
	var saves: Array[Dictionary] = []
	var blank := PackedByteArray()
	var total := fmt.total_blocks(blank)
	var free := total
	var path := _path()
	if not path.is_empty():
		var data := FileAccess.get_file_as_bytes(path)
		saves = fmt.list_saves(data)
		free = fmt.free_blocks(data)
		total = fmt.total_blocks(data)
	# A card with no image yet cannot be opted in — there is nothing to back up,
	# and the path it would be keyed by does not exist.
	#
	# "Missing" and "empty" are different things and must not read the same. A
	# new card has no image yet and will get one; a card that HAD one and lost it
	# has saves somewhere that this object can no longer find.
	ui.missing = path.is_empty() and not _card.minted
	# The same management the spawn menu's shelf offers, minus moving a save to
	# another card: that picks from a list of every card there is, which belongs
	# to the shelf. The card in your hand manages itself.
	ui.show_save_actions = true
	ui.show_move_action = false
	ui.show_restore_action = true
	ui.sync_available = SaveSync.is_available()
	ui.synced_slots = CardSaveOps.synced_slots(path, saves) if not path.is_empty() else {}
	ui.backed_up_slots = CardSaveOps.backed_up_slots(path, saves) if not path.is_empty() else {}
	ui.armed_slot = _armed_slot
	ui.actions_blocked = CardSaveOps.in_use_reason(get_tree(), _card.card_id)
	ui.populate(_card.card_label, saves, free, total, fmt)


## Delete one save, armed on the first press and done on the second, because
## the blocks are freed and the card keeps no copy.
##
## Whether that is the LAST copy is the thing worth saying, so the confirm names
## it either way — the same distinction a ROM row draws between deleting a
## download and deleting the only one there is.
func _on_delete_requested(s: Dictionary) -> void:
	var slot := str(s["name"])
	var forever := CardSaveOps.delete_is_forever(_path(), slot)
	if _armed_slot != slot:
		_armed_slot = slot
		_notice("Press again to %s %s%s" % ["delete" if forever else "remove",
			CardSaveOps.title_of(s),
			" permanently" if forever else " — RomM keeps its copy"], ARM_SECONDS)
		_populate()
		get_tree().create_timer(ARM_SECONDS).timeout.connect(func() -> void:
			if _armed_slot == slot and is_instance_valid(self):
				_armed_slot = ""
				_populate())
		return
	_armed_slot = ""
	var path := _path()
	if path.is_empty() or not CardSaveOps.delete_save(
			get_tree(), _fmt(), path, _card.card_id, int(s["block"])):
		_notice("Could not delete %s" % CardSaveOps.title_of(s), MenuToasts.DWELL_FAIL)
		_populate()
		return
	_notice("Deleted %s%s" % [CardSaveOps.title_of(s),
		"" if forever else " — RomM still has its copy"])
	_populate()


## Opt one save in or out of RomM backup. Opting in uploads it there and then —
## see CardSaveOps.backup_save.
func _on_sync_toggled(s: Dictionary, on: bool) -> void:
	var path := _path()
	if path.is_empty():
		return
	if not on:
		CardSaveOps.stop_backup(path, str(s["name"]))
		_notice("Stopped backing up %s" % CardSaveOps.title_of(s))
		_populate()
		return
	_notice("Uploading %s…" % CardSaveOps.title_of(s), 8.0)
	CardSaveOps.backup_save(_fmt(), path, s, func(ok: bool, message: String) -> void:
		if not (is_instance_valid(self) and visible):
			return
		_notice(message, MenuToasts.DWELL_OK if ok else MenuToasts.DWELL_FAIL)
		_populate())


## Show what RomM holds for this card, and which of it will fit.
func _on_restore_requested() -> void:
	var ui := _get_ui()
	if ui == null:
		return
	ui.show_restore([], "Asking RomM…")
	SaveSync.list_card_saves(_fmt().id(), _fmt().save_extension(),
			func(ok: bool, saves: Array) -> void:
		if not (is_instance_valid(self) and visible and is_instance_valid(ui)):
			return
		if not ok:
			ui.show_restore([], "Could not reach RomM.")
			return
		if saves.is_empty():
			ui.show_restore([], "RomM holds no memory-card saves yet.")
			return

		# A card with no image yet is empty with everything free, which is exactly
		# what the blank it has not been given yet would report.
		var fmt := _fmt()
		var path := _path()
		var data := FileAccess.get_file_as_bytes(path) if not path.is_empty() \
			else fmt.blank_image()
		var free := fmt.free_blocks(data)
		var present := CardSaveOps.present_slots(fmt, data)
		var rows: Array = []
		for s: Dictionary in saves:
			var row := s.duplicate()
			row["blocks"] = CardSaveOps.blocks_of(fmt, s)
			row["reason"] = CardSaveOps.restore_blocker(fmt, s, present, free)
			rows.append(row)
		ui.show_restore(rows, ""))


## Pull one save down onto this card.
##
## A card this session invented may still have no image; restoring is the one
## thing that can want it created early, so it is formatted here. A card that
## HAD an image and lost it is never given a blank — that would answer missing
## saves with something that looks exactly like them being wiped.
func _on_restore_picked(s: Dictionary) -> void:
	var path := _path()
	if path.is_empty():
		if not _card.minted:
			_notice("This card's image is missing — nothing was written",
				MenuToasts.DWELL_FAIL)
			return
		path = SramPaths.ensure_card(_card.family, _card.card_id)
	_notice("Downloading %s…" % str(s.get("rom_name", s.get("slot", ""))), 8.0)
	CardSaveOps.restore_save(get_tree(), _fmt(), path, _card.card_id, s,
		func(problem: String) -> void:
			if not (is_instance_valid(self) and visible):
				return
			if problem.is_empty():
				_notice("Restored %s — kept backed up to RomM"
					% str(s.get("rom_name", s["slot"])), MenuToasts.DWELL_INFO)
			else:
				_notice(problem, MenuToasts.DWELL_FAIL)
			_populate())


## A card's name IS its filename, so renaming moves the image on disk. Refused
## when another card already answers to that name — merging them would make two
## cards share one set of saves.
##
## A card seated in a powered console has its path held by the core, so the
## console is told to re-point at the moved file; otherwise the next flush would
## recreate the old name and the rename would appear to have duplicated the card.
func _on_renamed(text: String) -> void:
	if not (_card and is_instance_valid(_card)) or text.strip_edges().is_empty():
		return
	var new_id := SramPaths.rename_card(_card.card_id, text)
	if new_id.is_empty():
		_notice("A card named %s already exists" % text, MenuToasts.DWELL_FAIL)
		_populate()
		return
	_card.card_id = new_id
	_card.card_label = new_id
	_host_system_for(_card)
	_populate()


## Tell whichever console is holding this card that its image moved.
func _host_system_for(card: MemoryCard) -> void:
	for sys: Node in _card.get_tree().get_nodes_in_group("retro_system"):
		if sys.has_method("get_snapped_memcard") and sys.get_snapped_memcard() == card:
			if sys.has_method("refresh_memcard_path"):
				sys.refresh_memcard_path()
			return


# ── Placement, for FloatingObjectPanel3D ─────────────────────────────────────

func _target_node() -> Node3D:
	return _card


func _float_height() -> float:
	return FLOAT_HEIGHT
