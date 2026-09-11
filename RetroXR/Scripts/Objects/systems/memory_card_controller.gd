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
## Single-slot hardware backs its card through SAVE_RAM and sram_path_for_run
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
func on_memcard_inserted(card: Node3D, slot: int) -> void:
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
	NetworkManager.report_event(NetEvents.Event.EV_MEMCARD_INSERT,
		{"sys": self, "card": card, "slot": slot})


func on_memcard_removed(slot: int) -> void:
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
	NetworkManager.report_event(NetEvents.Event.EV_MEMCARD_REMOVE,
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
## Only the PlayStation answers this; both of its slots have a presence key.
func _set_card_presence(slot: int, inserted: bool) -> void:
	if not _host.is_powered_on or card_family() != "playstation":
		return
	if slot < 0 or slot > 1 or not _host.resolve_core_name().begins_with("pcsx_rearmed"):
		return
	# Through _host.set_core_option rather than at the Libretro node, so the value the
	# options panel shows and the value the core is running on cannot drift, and
	# so a machine that is not running has it written to its .opt instead.
	_host.set_core_option("pcsx_rearmed_memcard%d_inserted" % (slot + 1),
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
	if slot < 0 or slot >= _host.memcard_slots().size():
		return
	_host.memcard_slots()[slot].pick_up_object(card)


# --- Battery saves (SRAM) ---

## The core just wrote SAVE_RAM to disk. Fires only on a real change (the
## dirty check lives in C++), so this is "the game saved", not a timer tick.
## `final` is the last flush for this file — shutdown, or a card/cart swap.
func on_sram_flushed(path: String, _size: int, final: bool) -> void:
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
		# Two slots can flush, so the slot is read back from the path rather than
		# assumed: the per-slot hash table is what tells this game's writes from
		# saves that were already on that card, and crediting them to the wrong
		# slot hands one card's saves to the other.
		var slot := _slot_of_card_path(path)
		if slot < 0:
			return
		_sync_card_saves(CardFormats.for_path(path), slot, path)
		return
	if not SaveSync.is_enabled(path):
		return
	var sid := _host.resolve_systemid()
	var rom_id := SaveSync.rom_id_for(sid, _host.rom_path)
	if rom_id <= 0:
		return
	SaveSync.on_sram_flushed(path, rom_id, _host.resolve_core_name(), _sram_slot(),
		_host.content_label(), final)


## Which slot a flushed card image came out of, or -1 when no seated card claims
## it — a card pulled between the write and the signal, which is a real race
## rather than a fault.
func _slot_of_card_path(path: String) -> int:
	var want := path.simplify_path()
	for slot in card_slot_count():
		var card := get_snapped_memcard(slot)
		if card == null or not "card_id" in card:
			continue
		var seated := SramPaths.card_save_path(card_family(),
			str(card.get("card_id")))
		if seated.simplify_path() == want:
			return slot
	return -1


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
	var rom_id := SaveSync.rom_id_for(_host.resolve_systemid(), _host.rom_path)
	if rom_id <= 0:
		return
	var core := _host.resolve_core_name()
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

## Where each slot's card was copied for a core that opens files of its own, and
## when that copy last changed. Empty for every other core, which needs neither.
var _scratch_paths: Array[String] = ["", ""]
var _scratch_mtimes: Array[int] = [0, 0]


func start_card_polling() -> void:
	if not _core_owns_card_files(_host.resolve_core_name()):
		return   # a published card raises sram_flushed and needs none of this
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
func stop_card_polling_soon() -> void:
	if _card_poll_timer == null:
		return
	_card_poll_until = Time.get_unix_time_from_system() + CARD_POLL_AFTER_OFF_SEC


func _poll_cards() -> void:
	if not _host.is_powered_on and _card_poll_until > 0.0 \
			and Time.get_unix_time_from_system() > _card_poll_until:
		_card_poll_timer.stop()
		_card_poll_until = 0.0
		return
	for slot in card_slot_count():
		var card := get_snapped_memcard(slot)
		if card == null:
			continue
		var path := SramPaths.find_card(str(card.get("card_id")), card_family())
		if path.is_empty():
			continue
		# A core that owns its card files wrote to its own copy, not to this one.
		_drain_scratch(slot, path)
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
	# Stable across a pack swap, for the same reason the path below is: the
	# battery is in the CART, so changing what is in its bay is not a change of
	# save source.
	var slot_battery := _expansion_holding_battery()
	if slot_battery != null:
		return "unit:%s" % slot_battery.expansion_id
	if _host.get_snapped_cartridge() and "save_id" in _host.get_snapped_cartridge():
		return str(_host.get_snapped_cartridge().get("save_id"))
	return ""


## True when this console saves to a removable card. Keyed on the console's own
## _host.systemid rather than _host.resolve_systemid(), which reads the seated disc: a
## PlayStation has a card slot whatever is in the drive, and the slot has to be
## configured before any media is loaded.
##
## A bespoke shell can still overrule the descriptor through its model.
func _uses_memory_cards() -> bool:
	return card_slot_count() > 0


## How many card slots this console shows. The shell has the last word when it
## has an opinion at all — see SystemModel.card_slot_count, where -1 means it has
## none and 0 means it is asserting there are no slots.
func card_slot_count() -> int:
	# Reachable from the options panel, which can ask before a model is loaded.
	if _host.get_model() == null:
		return 0
	var from_model: int = _host.get_model().card_slot_count()
	if from_model >= 0:
		return mini(from_model, RetroSystem.MEMCARD_SLOT_NODES.size())
	var info := SystemInfo.for_system(_host.systemid)
	if info == null:
		return 0
	return mini(info.card_slots, RetroSystem.MEMCARD_SLOT_NODES.size())


## Which family of card this console takes, or "" when it takes none.
func card_family() -> String:
	var info := SystemInfo.for_system(_host.systemid)
	return info.card_family if info != null else ""


## Where this run's save image lives, or "" when nothing backs it. Pure — see
## sram_path_for_run() for the variant that creates a card before returning.
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
			return SramPaths.card_save_path(card_family(),
				str(card.get("card_id")))
		return ""
	# A unit with its own battery answers before anything in its bay, and before
	# the console's slot: the BS-X cartridge IS what sits in that slot, and the
	# pack loaded with it is the rom_path, so both of the routes below would key
	# the cart's own 32 KB to whichever medium happened to be in it. Then every
	# new pack read as a different BS-X and the shell asked for a name again.
	var battery := _expansion_holding_battery()
	if battery != null:
		return SramPaths.unit_save_path(resolved_core, battery.expansion_id)
	if _host.get_snapped_cartridge() and "save_id" in _host.get_snapped_cartridge():
		return SramPaths.cart_save_path(resolved_core, _host.rom_path,
			str(_host.get_snapped_cartridge().get("save_id")))
	# Nothing in the console's own slot, but the machine may still be running
	# something: a 64DD disk or a Mega-CD disc sits in the EXPANSION's bay, and
	# that stack is what _apply_expansion_launch booted from. Read the medium from
	# there rather than returning "", which gave those machines no save file at
	# all -- a battery-backed disk that silently never saved.
	var seated := _expansion_media()
	if seated != null and "save_id" in seated:
		return SramPaths.cart_save_path(resolved_core, _host.rom_path,
			str(seated.get("save_id")))
	return ""


## An attached unit that owns its own save, or null. Independent of whether a
## medium is loaded: an empty BS-X cartridge still has the town on it.
func _expansion_holding_battery() -> RetroExpansion:
	if _host == null or not _host.has_method("get_expansions"):
		return null
	for unit: RetroExpansion in _host.get_expansions():
		if unit == null or not is_instance_valid(unit):
			continue
		if ExpansionCatalog.save_owner_of(unit.expansion_id) \
				== ExpansionCatalog.SAVE_OWNER_UNIT:
			return unit
	return null


## The medium in an attached expansion's own bay, or null. First one wins: a
## console carries at most one loaded stack, and a unit with no bay of its own
## (the Satellaview, whose cartridge goes into the console slot) reports none.
func _expansion_media() -> Node3D:
	if _host == null or not _host.has_method("get_expansions"):
		return null
	for unit: RetroExpansion in _host.get_expansions():
		if unit == null or not is_instance_valid(unit):
			continue
		# Every bay of the unit, not just its first. A Sufami Turbo holds two
		# cartridges, and the save this composes is keyed off whichever one is
		# found -- so a pair whose first slot is empty must not report nothing.
		# Which of a LINKED pair should own the save is a separate question, and
		# an open one: see the note on the sufami_turbo BOOT row.
		for s in unit.get_bay_count():
			var m: Node3D = unit.get_media(s)
			if m != null:
				return m
	return null


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
	var family := card_family()
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
## and both PlayStation 2 cores expose no SAVE_RAM at all — they own their card
## files — so every seated card is mounted here, through the core's own per-slot
## option or by being copied into the directory the core reads, and this returns
## "", which is already how this function says "nothing goes through SAVE_RAM".
func sram_path_for_run(resolved_core: String) -> String:
	var cards := _uses_memory_cards()
	_host.get_libretro_node().SetRemovableStorage(cards)
	if not cards:
		return _compose_sram_path(resolved_core)
	var paths: Array[String] = []
	for slot in card_slot_count():
		paths.append(_card_path_for_run(resolved_core, slot))
	if _core_owns_card_files(resolved_core):
		_mount_core_cards(resolved_core, paths)
		return ""
	_mount_second_card(resolved_core, paths)
	return paths[0] if not paths.is_empty() else ""


## True when the core keeps its own card files and takes paths, rather than
## publishing each card as a memory region the frontend reads and writes. It
## decides how a card is mounted, whether the flush signal fires at all, and so
## whether the file poller below is needed.
##
## THREE cores, not one. Dolphin takes a verbatim absolute path per slot, so it
## needs no staging and is named here directly. Both PlayStation 2 cores instead
## open files under names of their own choosing, so `MemcardMounts` describes
## where — and that table is the authority on which those are, rather than a
## second list kept in step by hand.
##
## Answering only "dolphin" here is not a small miss: it silently takes the PS2
## down the published-card path, where nothing stages a card into the directory
## the core reads AND nothing starts the poller that carries writes back. The
## core then invents a card of its own, the player saves into it, and the save
## exists — in a file RetroXR never looks at.
func _core_owns_card_files(resolved_core: String) -> bool:
	return resolved_core.begins_with("dolphin") or MemcardMounts.has(resolved_core)


## Hand a second card to a core that publishes one. pcsx_rearmed puts slot 2
## under a memory id of its own — SAVE_RAM is slot 1 alone — so the second slot
## needs its own file and its own id, unlike the first.
func _mount_second_card(resolved_core: String, paths: Array[String]) -> void:
	if not resolved_core.begins_with("pcsx_rearmed") or paths.size() < 2:
		return
	_host.get_libretro_node().SetSramBPath(paths[1], Libretro.SRAM_B_PCSX_MEMCARD2)


## Hand a multi-slot core its card files.
##
## Two shapes of core end up here. Dolphin's option takes a verbatim absolute
## path, or "none" for a slot with no card in it — which must be a genuinely
## absent card and not a blank one, so a game says "no memory card" rather than
## offering to format something. The PlayStation 2 cores instead open files of
## their own, in a directory of their own, so their cards are mirrored into it.
func _mount_core_cards(resolved_core: String, paths: Array[String]) -> void:
	var row := MemcardMounts.for_core(resolved_core)
	if not row.is_empty():
		_mirror_cards_in(resolved_core, row, paths)
		return
	if not resolved_core.begins_with("dolphin"):
		return
	const KEYS := ["dolphin_memcard_a_path", "dolphin_memcard_b_path"]
	for slot in KEYS.size():
		var path := paths[slot] if slot < paths.size() else ""
		_host.set_core_option(KEYS[slot], path if not path.is_empty() else "none")


## Copy every seated card into the directory the core will look in, and point it
## at them.
##
## The ORDER is load-bearing rather than tidy. pcee2 builds the list of cards it
## will offer by scanning this directory as it registers its options, which is
## before the core has run any code that would create the directory — so RetroXR
## creates it, and fills it, and only then does the core load. A mirror that
## landed later would leave the slot options unregistered, and RetroXR's own
## option layer drops a key the core never declared without failing, so the card
## would simply and silently not be selected.
func _mirror_cards_in(resolved_core: String, row: Dictionary,
		paths: Array[String]) -> void:
	var dir := MemcardMounts.mount_dir(resolved_core)
	if dir.is_empty():
		return
	if DirAccess.make_dir_recursive_absolute(dir) != OK \
			and not DirAccess.dir_exists_absolute(dir):
		push_warning("[RetroSystem] cannot create the memory card directory %s" % dir)
		return

	for key: String in row.get("forced", {}):
		_host.set_core_option(key, str(row["forced"][key]))

	# A core that cannot re-open a card while it runs must not have the file
	# under it rewritten either: it holds the whole card in memory from the
	# moment it opened it, and would flush that back over anything written here.
	var live := bool(row.get("live_swap", false))
	var running := _host.is_powered_on and not live

	var file_keys: Array = row.get("file_keys", [])
	var enable_keys: Array = row.get("enable_keys", [])
	for slot in card_slot_count():
		var src := paths[slot] if slot < paths.size() else ""
		var card := get_snapped_memcard(slot)
		var card_id := str(card.get("card_id")) if card != null else ""
		var leaf := MemcardMounts.scratch_name(row, slot, card_id)
		if leaf.is_empty():
			_scratch_paths[slot] = ""
			if slot < enable_keys.size():
				_host.set_core_option(str(enable_keys[slot]), "disabled")
			continue
		var dst := dir.path_join(leaf)

		if src.is_empty():
			# Nothing seated. Where the core can be told a slot is empty, tell
			# it; where it cannot, take the file away so at least the LAST card
			# is not still presented as this one. A core with fixed names will
			# then invent an unformatted card of its own, which is the one part
			# of this nothing here can prevent.
			_scratch_paths[slot] = ""
			if slot < enable_keys.size():
				_host.set_core_option(str(enable_keys[slot]), "disabled")
			elif FileAccess.file_exists(dst):
				DirAccess.remove_absolute(dst)
			continue

		_scratch_paths[slot] = dst
		if slot < enable_keys.size():
			_host.set_core_option(str(enable_keys[slot]), "enabled")
		if slot < file_keys.size():
			_host.set_core_option(str(file_keys[slot]), leaf)
		if running:
			continue
		if not _copy_card(src, dst):
			push_warning("[RetroSystem] could not stage memory card %s for %s"
				% [card_id, resolved_core])
			continue
		_scratch_mtimes[slot] = FileAccess.get_modified_time(dst)


static func _copy_card(from: String, to: String) -> bool:
	var data := FileAccess.get_file_as_bytes(from)
	if data.is_empty():
		return false
	var f := FileAccess.open(to, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return true


## Take back what the core wrote to a mirrored card, if anything.
##
## The same torn-read guard the poll below applies for Dolphin, and for the same
## reason: these cores rewrite a card in place with no atomic rename, so a tick
## can land mid-write. An image whose superblock does not parse is a half-written
## file, not a changed card.
func _drain_scratch(slot: int, card_path: String) -> void:
	if slot >= _scratch_paths.size():
		return
	var scratch := _scratch_paths[slot]
	if scratch.is_empty() or not FileAccess.file_exists(scratch):
		return
	var mtime := FileAccess.get_modified_time(scratch)
	if mtime == _scratch_mtimes[slot]:
		return
	var data := FileAccess.get_file_as_bytes(scratch)
	var fmt := CardFormats.for_path(card_path)
	if fmt == null or not fmt.is_card_image(data):
		return
	var f := FileAccess.open(card_path, FileAccess.WRITE)
	if f == null:
		return
	f.store_buffer(data)
	f.close()
	_scratch_mtimes[slot] = mtime


## Re-resolve every card slot and re-point the running core at the result. The
## one path a card being seated, pulled or renamed goes through, so the two
## families cannot drift apart over what a swap means.
func _remount_cards() -> void:
	var core := _host.resolve_core_name()
	var path := sram_path_for_run(core)
	if not _core_owns_card_files(core):
		_host.get_libretro_node().SetSramPath(path)


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
	var path := _compose_sram_path(_host.resolve_core_name())
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
	_host.get_libretro_node().SetSramPath(_net_sram_path)
	if not _net_sram_data.is_empty():
		_host.get_libretro_node().SetSramData(_net_sram_data)
	_net_sram_override = false
	_net_sram_data = PackedByteArray()
	return true


## Netplay stop: forget any injected SRAM, so a later local start composes its
## own path instead of inheriting the session's.
func clear_netplay_sram() -> void:
	_net_sram_override = false
	_net_sram_path = ""
	_net_sram_data = PackedByteArray()
