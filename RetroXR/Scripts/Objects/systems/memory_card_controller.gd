## MemoryCardController — the cards a console takes, and where their saves live.
##
## A child of the RetroSystem it serves, in the same shape as SaveStateController
## and WiiLink: a plain Node the system creates, owns and hands itself to.
##
## Three jobs that only look separable. Which cards a machine takes and whether
## one is seated; where the image backing each slot lives on disk; and watching
## those images for changes so RomM can be told what a game wrote. They share
## _snapped_memcards and _card_save_hashes and cannot be split without one
## reaching into the other, so they move together.
##
## ── Two save rules, and they are opposites ───────────────────────────────────
## A card machine saves to the CARD, keyed on the card's own id and family and
## NOT on the game -- that is what lets one card carry saves for several titles
## and follow the player between machines. A cartridge machine saves against the
## core and the ROM as well, so two copies of one game on two carts keep separate
## saves. _compose_sram_path is where those part company, and system_tests pins
## both.
##
## ── Single slot and multi slot part company too ──────────────────────────────
## Single-slot hardware backs its card through SAVE_RAM and _sram_path_for_run
## returns the path for SetSramPath. Dolphin exposes no SAVE_RAM at all -- it
## owns its card files -- so every seated card is mounted through the core's own
## per-slot option and the same function returns "", which is already how it says
## "nothing goes through SAVE_RAM".
class_name MemoryCardController
extends Node

## The machine this belongs to. Set by RetroSystem in setup(), never in _ready:
## the node is added before the host can hand itself over.
var _host: RetroSystem = null


func setup(host: RetroSystem) -> void:
	_host = host

# --- Memory card slot (CD-era consoles) ---

## The MemoryCard seated in each slot, or null. Indexed by slot, in the order
## MEMCARD_SLOT_NODES names them.
var _snapped_memcards: Array[Node3D] = [null, null]

## Per slot: save filename -> md5 of that save, as of the last time this console
## looked at the card in it. Snapshotted at mount so the first flush can tell
## what this game wrote from what was already on the card.
##
## Per SLOT and not one shared table, because the key is a save's own filename
## and two cards can each hold a save of the same name. Sharing one would make
## seating a second card look like every save on the first had just changed, and
## hand them all to whichever game happened to be running.
var _card_save_hashes: Array[Dictionary] = [{}, {}]

# Netplay SRAM override (set by NetplaySession before net_start_core):
# path "" on clients (no local persistence of someone else's game) and the
# host's real bytes injected on every peer so all cores boot identically.
var _net_sram_override := false
var _net_sram_path := ""
var _net_sram_data := PackedByteArray()


## The card in a slot, or null. Defaults to slot A, which is every caller that
## predates the second slot and every one-slot console.
func get_snapped_memcard(slot := 0) -> Node3D:
	if slot < 0 or slot >= _snapped_memcards.size():
		return null
	return _snapped_memcards[slot]


## How many card slots this console shows. Public so menu code can walk them
## without knowing which console it is looking at.
func get_memcard_slot_count() -> int:
	return _card_slot_count()


func _on_memcard_inserted(card: Node3D, slot: int) -> void:
	_snapped_memcards[slot] = card
	_host.add_collision_exception_with(card)
	if _host.is_powered_on:
		# Hot-swap: the C++ side flushes the old card and loads this one —
		# except mid-netplay, where SRAM is part of the deterministic state.
		if NetworkManager.netplay_running() and NetworkManager.netplay_system() == self:
			push_warning("[RetroSystem] memory card ignored during netplay")
		else:
			_remount_cards()
			_set_card_presence(slot, true)
	NetworkManager.report_event(NetObjectSync.EV_MEMCARD_INSERT,
		{"sys": self, "card": card, "slot": slot})


func _on_memcard_removed(slot: int) -> void:
	if _snapped_memcards[slot]:
		_host.remove_collision_exception_with(_snapped_memcards[slot])
		_snapped_memcards[slot] = null
	_card_save_hashes[slot] = {}
	if _host.is_powered_on:
		if NetworkManager.netplay_running() and NetworkManager.netplay_system() == self:
			push_warning("[RetroSystem] memory card removal ignored during netplay")
		else:
			# No card, no saving. The C++ side blanks SAVE_RAM to match, so
			# nothing is written into the card the core keeps for itself.
			_remount_cards()
			# And the console is told the slot is EMPTY, which blanking SAVE_RAM
			# cannot say on its own: a 128 KB buffer of zeroes is a card, merely
			# an unformatted one, so the game offered to format it instead of
			# reporting no card at all.
			_set_card_presence(slot, false)
	NetworkManager.report_event(NetObjectSync.EV_MEMCARD_REMOVE,
		{"sys": self, "slot": slot})


## Tell the running console whether a card is in the slot.
##
## Presence and CONTENT are two different questions and only one of them can be
## answered while a game runs. What kind of card the slot holds is
## pcsx_rearmed_memcard1, and it gates the core's save buffer, so it is fixed at
## load; whether a card is in that slot is pcsx_rearmed_memcard1_inserted, which
## touches nothing but what the SIO reports and can move whenever a hand does.
##
## Down at the hardware this is the difference between a slot that answers "no
## device" and one that answers with an unformatted card -- which is what the
## room could only say before, and why pulling a card mid-game had the console
## offer to format it rather than say there was no card in it.
##
## Older cores never registered the key, and the extension skips a key a core
## does not have, so this is a no-op against a build from before the option
## shipped rather than an error.
## Only the PlayStation answers this. Its slot 2 is pinned to "none" and has no
## presence key of its own, so a second slot has nothing to say here — which is
## fine, because no console with two slots runs on pcsx_rearmed.
func _set_card_presence(slot: int, inserted: bool) -> void:
	if not _host.is_powered_on or _card_family() != "playstation":
		return
	if slot != 0 or not _host._resolve_core().begins_with("pcsx_rearmed"):
		return
	# Through _host.set_core_option rather than at the Libretro node, so the value the
	# options panel shows and the value the core is running on cannot drift, and
	# so a machine that is not running has it written to its .opt instead.
	_host.set_core_option("pcsx_rearmed_memcard1_inserted",
		"enabled" if inserted else "disabled")


## A seated card's image moved (it was renamed), so re-point the running core at
## the new path. Without this the core keeps writing to the old name and the next
## flush recreates it, making one card look like two.
##
## `slot` is which one moved; -1 re-points every seated card, which is what a
## caller holding only a card_id can ask for.
func refresh_memcard_path(slot := -1) -> void:
	if not _host.is_powered_on:
		return
	if slot >= 0 and get_snapped_memcard(slot) == null:
		return
	if NetworkManager.netplay_running() and NetworkManager.netplay_system() == self:
		return
	_remount_cards()


## Restore a memory card into a slot after loading from a save file.
func restore_memory_card(card: Node3D, slot := 0) -> void:
	if slot < 0 or slot >= _host._memcard_slots.size():
		return
	_host._memcard_slots[slot].pick_up_object(card)


# --- Battery saves (SRAM) ---

## The core just wrote SAVE_RAM to disk. Fires only on a real change (the
## dirty check lives in C++), so this is "the game saved", not a timer tick.
## `final` is the last flush for this file — shutdown, or a card/cart swap.
func _on_sram_flushed(path: String, _size: int, final: bool) -> void:
	if path.is_empty():
		return
	# A card never syncs as a FILE: SaveSync keys one record per file holding one
	# rom_id, and a card is one image many games write into, so they would fight
	# over it and a pull would overwrite the live card with another game's stale
	# copy. The saves INSIDE it sync individually.
	#
	# Taken BEFORE the per-file opt-in, which asks a question about cards that
	# nothing answers: each save carries its own, and no code sets a record
	# against a card's path. Gating on it left a card only ever backed up by
	# hand from the menu.
	if _uses_memory_cards():
		# Only single-slot hardware reaches here: SAVE_RAM is one buffer, so the
		# path it flushed is slot A's by construction.
		_sync_card_saves(CardFormats.for_path(path), 0, path)
		return
	if not SaveSync.is_enabled(path):
		return
	var sid := _host._resolve_systemid()
	var rom_id := SaveSync.rom_id_for(sid, _host.rom_path)
	if rom_id <= 0:
		return
	SaveSync.on_sram_flushed(path, rom_id, _host._resolve_core(), _sram_slot(),
		_host._content_label(), final)


## Back up whichever saves on the seated card changed, each under the game that
## wrote it.
##
## Attribution is the whole trick. A PS1 save names its game only by product code
## (BASCUS-94163…), and nothing local maps that to a RomM id — gamelist.json has
## no serial field. It does not need to: only the running game can have written
## the block that just changed, so the diff against the snapshot taken when the
## card was mounted says which saves are ours to claim.
##
## Without that snapshot the first flush would look like every save on the card
## was new and hand another game's saves to this one.
## `slot` is the CARD slot this image came out of. The `slot` inside a save entry
## is a different thing — RomM's name for one save — which is why the two are
## kept apart by name below.
func _sync_card_saves(fmt: CardFormat, slot: int, path: String) -> void:
	if fmt == null or path.is_empty() or not SaveSync.is_available():
		return
	var rom_id := SaveSync.rom_id_for(_host._resolve_systemid(), _host.rom_path)
	if rom_id <= 0:
		return
	var core := _host._resolve_core()
	var data := FileAccess.get_file_as_bytes(path)
	for s: Dictionary in _changed_card_saves(fmt, slot, data):
		var save_slot := str(s["slot"])
		# Opt-in per SAVE, not per card: a card is shared between games, and
		# sending one game's progress to a server should not decide it for every
		# other game that later writes to the same card.
		var key := RommSaveSync.card_save_key(path, save_slot)
		# Record the owner either way. This is the only moment it is knowable,
		# and it is what lets the menu upload a save the moment it is opted in
		# rather than waiting for this game to be played again.
		SaveSync.note_card_save_owner(key, rom_id)
		if not SaveSync.is_key_enabled(key):
			continue
		var title := str(s["title"])
		SaveSync.push_card_save(key, rom_id, core, save_slot,
			title if not title.is_empty() else save_slot, s["bytes"],
			fmt.save_extension())


## Which saves on the card in this slot differ from its snapshot, as
## {slot, title, bytes}, updating the snapshot as it goes.
##
## Split out from the upload so the attribution rule can be tested without a
## server: everything this returns is claimed by whatever game is running.
func _changed_card_saves(fmt: CardFormat, slot: int,
		data: PackedByteArray) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if fmt == null or slot < 0 or slot >= _card_save_hashes.size():
		return out
	var seen: Dictionary = _card_save_hashes[slot]
	for s: Dictionary in fmt.list_saves(data, false):
		var save_slot := str(s["name"])
		var bytes := fmt.extract_save(data, int(s["block"]))
		if bytes.is_empty():
			continue
		var digest := RommSaveSync.md5_of(bytes)
		if str(seen.get(save_slot, "")) == digest:
			continue
		seen[save_slot] = digest
		out.append({"slot": save_slot, "title": str(s["title"]), "bytes": bytes})
	return out


# --- Cards the core owns (Dolphin) --------------------------------------------
#
# A PlayStation card reaches RomM through sram_flushed, which the C++ raises
# after IT writes the file. Dolphin exposes no SAVE_RAM at all -- it owns its
# card files and writes them from a thread of its own, on a 15 s dirty timer plus
# a final write when the device is destroyed -- so that signal never fires for a
# GameCube and nothing here would ever hear that a card had changed.
#
# So watch the files. mtime is only the cheap hint; the real gate is the content
# diff in _changed_card_saves, which hashes each save individually. That matters
# because Dolphin's exit flush rewrites the whole card whether it is dirty or
# not, so mtime alone cannot tell "the game saved" from "the card was rewritten
# byte-identically on the way out". The hash can, and says nothing changed.

## How often to look at a seated card while the machine is on. Dolphin's own
## flush is every 15 s when dirty, so this is comfortably inside it.
const CARD_POLL_SEC := 5.0

## How long to keep looking after power-off. StopContent is deliberately
## non-blocking -- the join, retro_unload_game and the core's own final card
## write all happen on the emulation thread afterwards -- so the file is NOT
## final when the machine reports itself off. Nothing in GDScript can observe
## when it becomes final, so this waits out the teardown instead.
const CARD_POLL_AFTER_OFF_SEC := 12.0

var _card_poll_timer: Timer = null
var _card_mtimes: Array[int] = [0, 0]
var _card_poll_until := 0.0


func _start_card_polling() -> void:
	if _card_slot_count() <= 1:
		return   # single-slot hardware has sram_flushed and needs none of this
	if _card_poll_timer == null:
		_card_poll_timer = Timer.new()
		_card_poll_timer.wait_time = CARD_POLL_SEC
		_card_poll_timer.timeout.connect(_poll_cards)
		add_child(_card_poll_timer)
	_card_mtimes = [0, 0]
	_card_poll_until = 0.0
	_card_poll_timer.start()


## Keep polling for a while after the machine goes off, then stop. The last write
## lands during teardown, after this function's caller has already returned.
func _stop_card_polling_soon() -> void:
	if _card_poll_timer == null:
		return
	_card_poll_until = Time.get_unix_time_from_system() + CARD_POLL_AFTER_OFF_SEC


func _poll_cards() -> void:
	if not _host.is_powered_on and _card_poll_until > 0.0 \
			and Time.get_unix_time_from_system() > _card_poll_until:
		_card_poll_timer.stop()
		_card_poll_until = 0.0
		return
	for slot in _card_slot_count():
		var card := get_snapped_memcard(slot)
		if card == null:
			continue
		var path := SramPaths.find_card(str(card.get("card_id")), _card_family())
		if path.is_empty():
			continue
		var mtime := FileAccess.get_modified_time(path)
		if mtime == _card_mtimes[slot]:
			continue
		var fmt := CardFormats.for_path(path)
		var data := FileAccess.get_file_as_bytes(path)
		# Dolphin writes the whole card in one call with no atomic rename, so a
		# poll can land mid-write. An image whose checksums do not add up is a
		# torn read, not a changed card: skip it and take the next tick rather
		# than uploading half a save to a server, which is not recoverable from
		# inside the app.
		if fmt == null or not fmt.is_card_image(data):
			continue
		_card_mtimes[slot] = mtime
		_sync_card_saves(fmt, slot, path)


## Remember what was already on a card the moment it is mounted, so the first
## flush can tell this game's writes from saves that were there before it.
func _snapshot_card_saves(slot: int, path: String) -> void:
	if slot < 0 or slot >= _card_save_hashes.size():
		return
	_card_save_hashes[slot] = {}
	# Everything it finds counts as "already there", so the snapshot and the diff
	# cannot disagree about how a save is hashed.
	_changed_card_saves(CardFormats.for_path(path), slot,
		FileAccess.get_file_as_bytes(path))


## The slot this save occupies on the server. A cartridge's own save_id, so a
## round trip is stable; memory cards are namespaced because their id is a card
## rather than a save, and one card holds a file per game.
func _sram_slot() -> String:
	if _uses_memory_cards():
		var card := get_snapped_memcard(0)
		if card and "card_id" in card:
			return "card:%s" % str(card.get("card_id"))
		return ""
	if _host._snapped_cartridge and "save_id" in _host._snapped_cartridge:
		return str(_host._snapped_cartridge.get("save_id"))
	return ""


## True when this console saves to a removable card. Keyed on the console's own
## _host.systemid rather than _host._resolve_systemid(), which reads the seated disc: a
## PlayStation has a card slot whatever is in the drive, and the slot has to be
## configured before any media is loaded.
##
## A bespoke shell can still overrule the descriptor through its model.
func _uses_memory_cards() -> bool:
	return _card_slot_count() > 0


## How many card slots this console shows. The shell has the last word when it
## has an opinion at all — see SystemModel.card_slot_count, where -1 means it has
## none and 0 means it is asserting there are no slots.
func _card_slot_count() -> int:
	# Reachable from the options panel, which can ask before a model is loaded.
	if _host._model == null:
		return 0
	var from_model: int = _host._model.card_slot_count()
	if from_model >= 0:
		return mini(from_model, RetroSystem.MEMCARD_SLOT_NODES.size())
	var info := SystemInfo.for_system(_host.systemid)
	if info == null:
		return 0
	return mini(info.card_slots, RetroSystem.MEMCARD_SLOT_NODES.size())


## Which family of card this console takes, or "" when it takes none.
func _card_family() -> String:
	var info := SystemInfo.for_system(_host.systemid)
	return info.card_family if info != null else ""


## Where this run's save image lives, or "" when nothing backs it. Pure — see
## _sram_path_for_run() for the variant that creates a card before returning.
##
## Card systems resolve to the SEATED CARD, not the game: one image shared by
## everything played with that card in, which is what lets a game read the saves
## other games left. No card seated means no path at all.
##
## Cartridge systems resolve to the cart's own save_id file — each physical cart
## holds its own save.
func _compose_sram_path(resolved_core: String, slot := 0) -> String:
	if resolved_core.is_empty() or _host.rom_path.is_empty():
		return ""
	if _uses_memory_cards():
		var card := get_snapped_memcard(slot)
		if card and "card_id" in card:
			return SramPaths.card_save_path(_card_family(),
				str(card.get("card_id")))
		return ""
	if _host._snapped_cartridge and "save_id" in _host._snapped_cartridge:
		return SramPaths.cart_save_path(resolved_core, _host.rom_path,
			str(_host._snapped_cartridge.get("save_id")))
	return ""


## The image backing one card slot for a run that is about to start, formatting a
## brand-new card on the way. "" when nothing backs it.
func _card_path_for_run(resolved_core: String, slot: int) -> String:
	var path := _compose_sram_path(resolved_core, slot)
	var card := get_snapped_memcard(slot)
	if path.is_empty() or card == null:
		_card_save_hashes[slot] = {}
		return ""
	var card_id := str(card.get("card_id"))
	# Only a card this session invented may have its image created. One that came
	# from a saved room or the shelf is supposed to have an image already; if it
	# has gone — renamed away, or deleted outside the app — writing a blank would
	# look exactly like the saves were wiped, and the next flush would make that
	# permanent. Run with nothing backing it instead, which the core reports as
	# unformatted media, and leave the player somewhere to recover from.
	var family := _card_family()
	if SramPaths.find_card(card_id, family).is_empty() \
			and not bool(card.get("minted")):
		push_warning("[RetroSystem] memory card '%s' has no image on disk — "
			% card_id + "running without it rather than creating a blank")
		_card_save_hashes[slot] = {}
		return ""
	path = SramPaths.ensure_card(family, card_id)
	_snapshot_card_saves(slot, path)
	return path


## The path to hand the core for a run that is about to start. Also tells the
## core that empty means "nothing plugged in" rather than "don't save":
## pcsx_rearmed otherwise presents a fully formatted card of its own, which a
## game would write to and lose at power-off.
##
## Single-slot hardware backs its card through SAVE_RAM, so this returns slot A's
## path for the caller to hand to SetSramPath, exactly as it always did.
##
## Multi-slot hardware does not, and this is where the two part company. Dolphin
## exposes no SAVE_RAM at all — it owns its card files — so every seated card is
## mounted here through the core's own per-slot option and this returns "", which
## is already how this function says "nothing goes through SAVE_RAM".
func _sram_path_for_run(resolved_core: String) -> String:
	var cards := _uses_memory_cards()
	_host._libretro.SetRemovableStorage(cards)
	if not cards:
		return _compose_sram_path(resolved_core)
	var paths: Array[String] = []
	for slot in _card_slot_count():
		paths.append(_card_path_for_run(resolved_core, slot))
	if _card_slot_count() <= 1:
		return paths[0] if not paths.is_empty() else ""
	_mount_core_cards(resolved_core, paths)
	return ""


## Hand a multi-slot core its card files. Only Dolphin has any, and its option
## takes a verbatim absolute path, or "none" for a slot with no card in it —
## which must be a genuinely absent card and not a blank one, so a game says
## "no memory card" rather than offering to format something.
func _mount_core_cards(resolved_core: String, paths: Array[String]) -> void:
	if not resolved_core.begins_with("dolphin"):
		return
	const KEYS := ["dolphin_memcard_a_path", "dolphin_memcard_b_path"]
	for slot in KEYS.size():
		var path := paths[slot] if slot < paths.size() else ""
		_host.set_core_option(KEYS[slot], path if not path.is_empty() else "none")


## Re-resolve every card slot and re-point the running core at the result. The
## one path a card being seated, pulled or renamed goes through, so the two
## families cannot drift apart over what a swap means.
func _remount_cards() -> void:
	var path := _sram_path_for_run(_host._resolve_core())
	if _card_slot_count() <= 1:
		_host._libretro.SetSramPath(path)


## Netplay: override the SRAM source for the next net_start_core (see
## NetplaySession). path "" disables local persistence; data (may be empty)
## is injected so every peer boots with identical SRAM.
func net_set_sram(path: String, data: PackedByteArray) -> void:
	_net_sram_override = true
	_net_sram_path = path
	_net_sram_data = data


## Host: the current .srm file bytes for the seated content (shipped to peers
## in the netplay cold-start payload). Empty when no file exists yet.
func net_sram_file_bytes() -> PackedByteArray:
	var path := _compose_sram_path(_host._resolve_core())
	if path.is_empty() or not FileAccess.file_exists(path):
		return PackedByteArray()
	var f := FileAccess.open(path, FileAccess.READ)
	return f.get_buffer(f.get_length()) if f else PackedByteArray()


## Netplay start: if the session injected SRAM, hand it to the core and say so.
## Returns false when there is no override, meaning the caller should compose
## the local path as usual.
##
## The override is one-shot by design: every peer boots from identical bytes,
## and the next ordinary start must go back to this machine's own save rather
## than replay whatever the session handed over.
func apply_netplay_sram() -> bool:
	if not _net_sram_override:
		return false
	_host._libretro.SetSramPath(_net_sram_path)
	if not _net_sram_data.is_empty():
		_host._libretro.SetSramData(_net_sram_data)
	_net_sram_override = false
	_net_sram_data = PackedByteArray()
	return true


## Netplay stop: forget any injected SRAM, so a later local start composes its
## own path instead of inheriting the session's.
func clear_netplay_sram() -> void:
	_net_sram_override = false
	_net_sram_path = ""
	_net_sram_data = PackedByteArray()
