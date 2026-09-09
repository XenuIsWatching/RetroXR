## MemoryCardBrowser — the spawn menu's memory-card shelf for one console family.
##
## Two pages, one visible at a time:
##   list   : one row per card that exists on disk. Tap it to bring that card
##            into the room; tap its right-hand button to read what is saved on
##            it without spawning anything. "New Memory Card" at the bottom.
##   saves  : that card's save list, the same view the card's own panel shows,
##            read straight off the card image.
##
## A card only exists on disk once it has been seated in a powered console, so a
## freshly spawned card that has never been used is deliberately not listed —
## there is nothing to distinguish it from the blank the bottom row makes.
class_name MemoryCardBrowser
extends VBoxContainer

## Carries a spawn token for SpawnMenuController: "<family>_memory_card" for a
## new blank one, "memcard:<family>:<card_id>" to bring an existing card back.
signal spawn_requested(token: String)
## The player backed out of the card list.
signal closed
## Something worth saying out loud — forwarded to the menu's toast.
signal notice(text: String, seconds: float)
## Where the shelf now is, and what going back from here means.
##
## The shelf lives inside a page that already has a Back button and a title, so
## it draws neither: it says where it is and lets the one header do the walking.
signal page_changed(title: String, on_back: Callable)

## Which family's shelf this is. Set by the host before open(); the card format
## follows from it.
var family := "playstation"

## How long a delete stays armed. Matches the ROM rows' confirm window.
const ARM_SECONDS := 3.0

## card_id of the row currently showing its rename field, or "".
var _editing_id := ""
## Save slot whose delete has been armed and is waiting for a second press.
var _armed_slot := ""


## How many card images are on disk.
##
## A directory listing, not list_cards: that opens and parses every image to
## count its saves and free blocks, and the callers here only want how many
## there are — a number the console page asks for every time it is drawn.
static func card_count(a_family: String) -> int:
	var fmt := CardFormats.for_family(a_family)
	var dir := SramPaths.cards_dir(a_family)
	if fmt == null or not DirAccess.dir_exists_absolute(dir):
		return 0
	var n := 0
	for f: String in DirAccess.get_files_at(dir):
		if f.get_extension().to_lower() == fmt.extension():
			n += 1
	return n


## Any card images on disk? With none there is nothing to choose between, and
## the caller should just spawn a blank one.
static func has_cards(a_family: String) -> bool:
	return card_count(a_family) > 0


## The format this shelf's cards are in.
func _fmt() -> CardFormat:
	return CardFormats.for_family(family)


## Show the card list (rebuilt each time — cards are written as you play).
func open() -> void:
	_build_list()


func _clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()


## Say where the shelf is now. The host's header renders it and owns Back.
func _page(title_text: String, on_back: Callable) -> void:
	page_changed.emit(title_text, on_back)


func _build_list() -> void:
	_clear()
	_page("%s Memory Cards" % _fmt().label(), func() -> void: closed.emit())

	# Where the cards actually are. They are ordinary card images that any tool
	# for that console opens, so saying where they live is the difference between
	# a closed box and a folder you can back up, copy or edit outside RetroXR.
	add_child(MenuStyle.hint(SramPaths.cards_dir(family)))

	for card: Dictionary in SramPaths.list_cards(family):
		add_child(_card_row(card))

	add_child(MenuStyle.spacer(6))
	var new_btn := MenuStyle.row_button("  +  New Memory Card", 26, 0, 80, false)
	new_btn.pressed.connect(
		func() -> void: spawn_requested.emit("%s_memory_card" % family))
	add_child(new_btn)
	add_child(MenuStyle.spacer(10))


func _card_row(card: Dictionary) -> Control:
	var row := MenuStyle.hbox(8)

	# The row being renamed swaps its label for the field, so the name is edited
	# where it is read instead of in a dialog over the top of it.
	if str(card["card_id"]) == _editing_id:
		var edit := LineEdit.new()
		edit.text = str(card["label"])
		edit.custom_minimum_size = Vector2(0, 80)
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		edit.add_theme_font_size_override("font_size", 26)
		edit.text_submitted.connect(func(t: String) -> void: _commit_rename(card, t))
		edit.focus_exited.connect(func() -> void: _commit_rename(card, edit.text))
		row.add_child(edit)
		edit.call_deferred("grab_focus")
		edit.call_deferred("select_all")
		return row

	var saves := int(card["saves"])
	var free := int(card["free"])
	var spawn_btn := MenuStyle.row_button("")
	var fmt := _fmt()
	var unit := fmt.unit_noun() if free == 1 else fmt.unit_plural()
	spawn_btn.text = "  +  %s      %d save%s · %d %s free%s" \
		% [card["label"], saves, "" if saves == 1 else "s",
		   free, unit, _where(card, saves)]
	spawn_btn.pressed.connect(func() -> void:
		spawn_requested.emit("memcard:%s:%s" % [family, card["card_id"]]))
	row.add_child(spawn_btn)

	var view_btn := Button.new()
	view_btn.custom_minimum_size = Vector2(80, 80)
	view_btn.text = String.chr(MenuIcons.CARD_SAVES)
	view_btn.add_theme_font_override("font", MenuIcons.symbols())
	view_btn.add_theme_font_size_override("font_size", 34)
	view_btn.tooltip_text = "View the saves on this card"
	view_btn.pressed.connect(func() -> void: _build_saves(card))
	row.add_child(view_btn)

	var rename_btn := Button.new()
	rename_btn.custom_minimum_size = Vector2(80, 80)
	rename_btn.text = String.chr(MenuIcons.RENAME)
	rename_btn.add_theme_font_override("font", MenuIcons.symbols())
	rename_btn.add_theme_font_size_override("font_size", 34)
	rename_btn.tooltip_text = "Rename this card"
	rename_btn.pressed.connect(func() -> void:
		_editing_id = str(card["card_id"])
		_build_list())
	row.add_child(rename_btn)
	return row


## Where this card's saves live, in the same spirit as a ROM row saying whether
## it is here or on the server.
##
## A card is always on this device — the row would not exist otherwise — so what
## is worth saying is whether anything is ALSO on RomM, and stays quiet about it
## entirely when there is no server configured.
func _where(card: Dictionary, saves: int) -> String:
	if not SaveSync.is_available():
		return ""
	var path := str(card["path"])
	var backed := SaveSync.card_backup_count(path)
	if backed <= 0:
		return "   ·   on this device only"
	if backed >= saves:
		return "   ·   backed up to RomM"
	return "   ·   %d of %d on RomM" % [backed, saves]


## Rename the card, which moves its image — see SramPaths.rename_card.
func _commit_rename(card: Dictionary, text: String) -> void:
	# focus_exited fires again as the rebuilt list tears the field down, so the
	# first commit closes the edit and the second finds nothing to do.
	if _editing_id.is_empty():
		return
	_editing_id = ""
	var old_id := str(card["card_id"])
	var new_id := SramPaths.rename_card(old_id, text, family)
	if new_id.is_empty():
		push_warning("[MemoryCardBrowser] a card named '%s' already exists" % text)
	elif new_id != old_id:
		_adopt_rename_in_room(old_id, new_id)
	_build_list()


## The renamed card may also be sitting in the room, and its object keys off the
## filename — left alone it would point at an image that no longer exists, and
## the next save would write a second card under the old name.
func _adopt_rename_in_room(old_id: String, new_id: String) -> void:
	for n: Node in get_tree().get_nodes_in_group("memory_card"):
		var card := n as MemoryCard
		if card == null or card.card_id != old_id:
			continue
		card.card_id = new_id
		card.card_label = new_id
		CardSaveOps.refresh_holder(get_tree(), new_id)
		return


## The saves RomM holds, and which of them will fit on this card.
##
## Restoring writes into the card, so every refusal is stated on the row rather
## than discovered after the fact: a save already on the card, or one needing
## more blocks than are free, says so and cannot be pressed.
func _build_restore(card: Dictionary) -> void:
	_clear()
	_page("Restore to %s" % card["label"], func() -> void: _build_saves(card))

	var status := MenuStyle.label("Asking RomM…", 20, MenuStyle.COLOR_DESC)
	add_child(status)

	SaveSync.list_card_saves(family, _fmt().save_extension(),
			func(ok: bool, saves: Array) -> void:
		if not is_inside_tree():
			return
		status.queue_free()
		if not ok:
			add_child(MenuStyle.label("Could not reach RomM.", 20, Color(0.85, 0.5, 0.5)))
			return
		if saves.is_empty():
			add_child(MenuStyle.label("RomM holds no memory-card saves yet.",
				20, MenuStyle.COLOR_DESC))
			return

		var data := FileAccess.get_file_as_bytes(str(card["path"]))
		var free := _fmt().free_blocks(data)
		var present := CardSaveOps.present_slots(_fmt(), data)
		for s: Dictionary in saves:
			add_child(_restore_row(card, s, present, free)))


func _restore_row(card: Dictionary, s: Dictionary, present: Dictionary, free: int) -> Control:
	var row := MenuStyle.hbox(8)
	var slot := str(s["slot"])
	var blocks := CardSaveOps.blocks_of(_fmt(), s)
	var reason := CardSaveOps.restore_blocker(_fmt(), s, present, free)

	var btn := MenuStyle.row_button("", 24)
	var rom_name := str(s.get("rom_name", ""))
	btn.text = "    %s      %d block%s%s" % [
		rom_name if not rom_name.is_empty() else slot,
		blocks, "" if blocks == 1 else "s",
		"" if reason.is_empty() else "   ·   " + reason]
	btn.disabled = not reason.is_empty()
	btn.pressed.connect(func() -> void: _restore(card, s))
	row.add_child(btn)
	return row


## Pull one save down and splice it into the card — see CardSaveOps.restore_save.
func _restore(card: Dictionary, s: Dictionary) -> void:
	_clear()
	_page(str(card["label"]), func() -> void: _build_saves(card))
	var status := MenuStyle.label("Downloading…", 20, MenuStyle.COLOR_DESC)
	add_child(status)

	CardSaveOps.restore_save(get_tree(), _fmt(), str(card["path"]), str(card["card_id"]), s,
		func(problem: String) -> void:
			if not is_inside_tree():
				return
			if not problem.is_empty():
				status.text = problem
				return
			notice.emit("Restored %s — kept backed up to RomM"
				% str(s.get("rom_name", s["slot"])), 3.5)
			_build_saves(card))


func _build_saves(card: Dictionary) -> void:
	_clear()
	_page(str(card["label"]), _build_list)

	var data := FileAccess.get_file_as_bytes(str(card["path"]))
	var saves := _fmt().list_saves(data)
	var free := _fmt().free_blocks(data)

	if SaveSync.is_available():
		# No glyph: the icon font carries symbols only, so a button holding both a
		# codepoint and words can use one font or the other, never both.
		var restore := MenuStyle.row_button("Restore a save from RomM", 22, 0, 68, false)
		restore.pressed.connect(func() -> void: _build_restore(card))
		add_child(restore)

	# The card's own panel, minus its rename field and ✕: this page has its own
	# back button, and the card being read may not even be in the room. Here it
	# also manages its saves, which the card's 3D panel does not.
	var ui := MemoryCard2D.new()
	ui.show_name_field = false
	ui.show_save_actions = true
	ui.armed_slot = _armed_slot
	ui.actions_blocked = _in_use_reason(card)
	ui.custom_minimum_size = Vector2(0, 470)
	ui.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ui.save_move_requested.connect(func(s: Dictionary) -> void: _build_move(card, s))
	ui.save_delete_requested.connect(func(s: Dictionary) -> void: _delete_save(card, s))
	ui.save_sync_toggled.connect(func(s: Dictionary, on: bool) -> void:
		_toggle_save_sync(card, s, on))
	add_child(ui)
	await get_tree().process_frame
	# A second _build_saves during that frame already freed this one.
	if not is_instance_valid(ui):
		return

	ui.synced_slots = CardSaveOps.synced_slots(str(card["path"]), saves)
	ui.backed_up_slots = CardSaveOps.backed_up_slots(str(card["path"]), saves)
	ui.sync_available = SaveSync.is_available()
	ui.populate(str(card["label"]), saves, free, _fmt().total_blocks(data), _fmt())


## Opt one save in or out — see CardSaveOps.backup_save, which uploads at once
## on the way in.
func _toggle_save_sync(card: Dictionary, s: Dictionary, on: bool) -> void:
	if not on:
		CardSaveOps.stop_backup(str(card["path"]), str(s["name"]))
		notice.emit("Stopped backing up %s" % CardSaveOps.title_of(s), 2.5)
		_build_saves(card)
		return

	notice.emit("Uploading %s…" % CardSaveOps.title_of(s), 8.0)
	CardSaveOps.backup_save(_fmt(), str(card["path"]), s,
			func(ok: bool, message: String) -> void:
		if not is_inside_tree():
			return
		notice.emit(message, 5.0 if not ok else 2.5)
		_build_saves(card))


## Why this card must not be changed right now, or "".
func _in_use_reason(card: Dictionary) -> String:
	return CardSaveOps.in_use_reason(get_tree(), str(card["card_id"]))


## Delete one save. Armed on the first press and done on the second, the way a
## ROM row asks twice, because the blocks are freed and the card keeps no copy.
func _delete_save(card: Dictionary, s: Dictionary) -> void:
	var slot := str(s["name"])
	if _armed_slot != slot:
		# Same shape as deleting a ROM: arm, say so, and disarm after 3 s. The
		# glyph alone changing is easy to miss on a headset — and as there, the
		# confirm says whether this is the last copy or one of two.
		_armed_slot = slot
		notice.emit("Press again to delete %s%s" % [CardSaveOps.title_of(s),
			"" if CardSaveOps.delete_is_forever(str(card["path"]), slot)
				else " — RomM keeps its copy"], ARM_SECONDS)
		_build_saves(card)
		get_tree().create_timer(ARM_SECONDS).timeout.connect(func() -> void:
			if _armed_slot == slot and is_inside_tree():
				_armed_slot = ""
				_build_saves(card))
		return
	_armed_slot = ""
	if not CardSaveOps.delete_save(get_tree(), _fmt(), str(card["path"]),
			str(card["card_id"]), int(s["block"])):
		push_warning("[MemoryCardBrowser] could not delete '%s'" % slot)
	_build_saves(card)


## Move a save to another card: pick the destination.
func _build_move(card: Dictionary, s: Dictionary) -> void:
	_clear()
	var title := str(s["title"])
	_page("Move %s" % (title if not title.is_empty() else s["name"]),
		func() -> void: _build_saves(card))

	var blocks := int(s["blocks"])
	var any := false
	for dest: Dictionary in SramPaths.list_cards(family):
		if str(dest["card_id"]) == str(card["card_id"]):
			continue
		any = true
		var reason := _in_use_reason(dest)
		var data := FileAccess.get_file_as_bytes(str(dest["path"]))
		if reason.is_empty():
			if _fmt().block_of(data, str(s["name"])) != -1:
				reason = "already has this save"
		var free := _fmt().free_blocks(data)
		if reason.is_empty() and free < blocks:
			reason = "needs %d blocks, %d free" % [blocks, free]

		var btn := MenuStyle.row_button("", 24)
		btn.text = "   %s      %d block%s free%s" % [dest["label"],
			free, "" if free == 1 else "s",
			"" if reason.is_empty() else "   ·   " + reason]
		btn.disabled = not reason.is_empty()
		btn.pressed.connect(func() -> void: _do_move(card, dest, s))
		add_child(btn)

	if not any:
		add_child(MenuStyle.label("There is no other card to move it to.",
			20, MenuStyle.COLOR_DESC))


## Write the destination FIRST, and only remove the source once that has landed
## and verified. Ordered this way on purpose: the failure mode is then a save
## existing on both cards, which the player can see and fix, rather than a save
## that left one card and never arrived at the other.
func _do_move(src: Dictionary, dest: Dictionary, s: Dictionary) -> void:
	var src_data := FileAccess.get_file_as_bytes(str(src["path"]))
	var lifted := _fmt().extract_save(src_data, int(s["block"]))
	if lifted.is_empty():
		push_warning("[MemoryCardBrowser] could not read the save to move")
		_build_saves(src)
		return
	var merged := _fmt().insert_save(
		FileAccess.get_file_as_bytes(str(dest["path"])), lifted)
	if merged.is_empty() or not CardSaveOps.write_card(get_tree(), _fmt(), str(dest["path"]),
			str(dest["card_id"]), merged):
		push_warning("[MemoryCardBrowser] move aborted — nothing was changed")
		_build_saves(src)
		return
	if not CardSaveOps.delete_save(get_tree(), _fmt(), str(src["path"]),
			str(src["card_id"]), int(s["block"])):
		push_warning("[MemoryCardBrowser] '%s' was copied to '%s' but could not be "
			% [s["name"], dest["label"]] + "removed from '%s' — it is on both" % src["label"])
	_build_saves(src)
