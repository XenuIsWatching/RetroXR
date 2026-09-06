## SramPaths — the single source of truth for where battery saves live.
##
## Layout (append-only; nothing here ever deletes a file):
##   <root>/save/<core_name>/<game_stem>/<save_id>.srm   cartridge saves
##   <root>/save/memcards/<family>/<card_id>.<ext>       memory cards
##
## A cartridge holds its own save, so its path is keyed by game. A memory card
## is the opposite: ONE image that every game on that console writes into, which
## is the whole point of a card and what lets a game read saves another game
## left behind. Splitting a card per game would defeat it.
##
## Card paths deliberately carry no core name — a card is hardware, and its raw
## image is the same for every core that emulates the console, so a card survives
## switching cores the way a real one survives switching consoles.
##
## They are keyed by card FAMILY rather than systemid, because a family is what a
## card physically is: the GameCube's is shared with the Wii, which takes the same
## card when it plays a GameCube disc. See CardFormat.
##
## Used by RetroSystem (composing the path handed to Libretro.SetSramPath at
## power-on) and by the cartridge options panel (listing recoverable saves).
class_name SramPaths
extends RefCounted


static func game_stem(rom_path: String) -> String:
	return rom_path.get_file().get_basename()


## save/<core> root for a given core, under the libretro root directory.
static func core_save_dir(core_name: String) -> String:
	return CoreDownloadManager.default_core_root().path_join("save").path_join(core_name)


static func cart_save_dir(core_name: String, rom_path: String) -> String:
	return core_save_dir(core_name).path_join(game_stem(rom_path))


static func cart_save_path(core_name: String, rom_path: String, save_id: String) -> String:
	return cart_save_dir(core_name, rom_path).path_join(save_id + ".srm")


## save/<core>/<expansion_id>/<expansion_id>.srm — the battery inside an
## EXPANSION UNIT rather than in whatever medium is loaded with it.
##
## The BS-X cartridge is the case: its 32 KB holds the player's name and town,
## and that belongs to the CART. Keyed off the medium instead, every memory pack
## looked like a different BS-X and the shell asked for a new name each time one
## was swapped in. Deliberately independent of rom_path for the same reason --
## the pack IS the rom_path here.
static func unit_save_path(core_name: String, expansion_id: String) -> String:
	return core_save_dir(core_name).path_join(expansion_id) \
		.path_join(expansion_id + ".srm")


## save/memcards/<family> — every card belonging to one console family.
static func cards_dir(family: String) -> String:
	return CoreDownloadManager.default_core_root().path_join("save") \
		.path_join("memcards").path_join(family)


## The one image this card is. No core, no game — see the header.
static func card_save_path(family: String, card_id: String) -> String:
	var fmt := CardFormats.for_family(family)
	if fmt == null:
		return ""
	return cards_dir(family).path_join("%s.%s" % [card_id, fmt.extension()])


## A card's NAME IS ITS FILENAME, so the folder reads as a shelf of cards and can
## be managed from outside RetroXR — these are ordinary card images that any tool
## for that console opens. That makes the name the identity: renaming a card moves
## its file, and `card_id` is just the sanitised name.
##
## Strips what Windows forbids in a filename, plus the trailing dots and spaces
## it silently drops, and caps the length so a pasted essay can't produce a path
## no one can delete. Never returns "" — an all-punctuation name would otherwise
## produce a bare ".mcr".
static func sanitize_card_name(text: String) -> String:
	var out := ""
	for c in text.strip_edges():
		if c in "<>:\"/\\|?*" or c.unicode_at(0) < 32:
			continue
		out += c
	while out.ends_with(".") or out.ends_with(" "):
		out = out.substr(0, out.length() - 1)
	out = out.substr(0, 48).strip_edges()
	return out if not out.is_empty() else "MEMORY CARD"


## `base`, or `base 2`, `base 3`… until no console already has a card by that
## name. Two cards sharing a filename would share their saves.
##
## Unique across EVERY family, not just its own. Two folders genuinely cannot
## collide, but a card is matched by card_id alone across the whole room — that
## is how CardSaveOps.holder_of finds the console holding one — so two cards of
## different families sharing a name would have the "power the console off first"
## guard protecting the wrong machine.
static func unique_card_id(base: String) -> String:
	var name := sanitize_card_name(base)
	if find_card(name).is_empty():
		return name
	var n := 2
	while not find_card("%s %d" % [name, n]).is_empty():
		n += 1
	return "%s %d" % [name, n]


## Rename a card's image to match its new name. Returns the new card_id, or ""
## when the name is already taken — refused rather than merged, because two
## cards pointing at one file would silently share saves.
##
## A card with no image yet (never seated) has nothing to move; the new id is
## still returned so the object can adopt it.
##
## The extension is carried over from the file being moved rather than looked up,
## so this needs no family and cannot rename a card into another family's format.
static func rename_card(old_id: String, new_label: String, family := "") -> String:
	var new_id := sanitize_card_name(new_label)
	if new_id == old_id:
		return old_id
	if not find_card(new_id).is_empty():
		return ""
	var old_path := find_card(old_id, family)
	if old_path.is_empty():
		return new_id
	var new_path := old_path.get_base_dir().path_join(
		"%s.%s" % [new_id, old_path.get_extension()])
	var err := DirAccess.rename_absolute(old_path, new_path)
	if err != OK:
		push_error("[SramPaths] cannot rename card %s -> %s (%d)" % [old_path, new_path, err])
		return ""
	return new_id


## Every card that exists on disk, newest first. Entries:
##   card_id, path, label, mtime, saves (int), free (int)
##
## A card only appears once it has been seated in a powered console — that is
## when its image is written — so a freshly spawned card that has never been
## used is deliberately absent.
static func list_cards(family: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var fmt := CardFormats.for_family(family)
	var dir := cards_dir(family)
	if fmt == null or not DirAccess.dir_exists_absolute(dir):
		return out
	for fname: String in DirAccess.get_files_at(dir):
		if fname.get_extension().to_lower() != fmt.extension():
			continue
		var path := dir.path_join(fname)
		var card_id := fname.get_basename()
		var saves := 0
		var free := 0
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			var data := f.get_buffer(f.get_length())
			f.close()
			# Without icons: this is a shelf listing, and decoding every save's
			# animation frames to count them is the expensive half by far.
			saves = fmt.list_saves(data, false).size()
			free = fmt.free_blocks(data)
		out.append({
			"card_id": card_id,
			"path": path,
			"label": card_id,
			"mtime": FileAccess.get_modified_time(path),
			"saves": saves,
			"free": free,
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["mtime"]) > int(b["mtime"]))
	return out


## The existing image for a card id, or "" when it has never been seated in a
## powered console.
##
## With a family this is one exact lookup. Without one it sweeps every family's
## folder, which is what a caller holding only a card_id has to do — and is safe
## precisely because unique_card_id keeps ids unique across families.
static func find_card(card_id: String, family := "") -> String:
	if card_id.is_empty():
		return ""
	if not family.is_empty():
		var exact := card_save_path(family, card_id)
		return exact if not exact.is_empty() and FileAccess.file_exists(exact) else ""
	var root := CoreDownloadManager.default_core_root().path_join("save") \
		.path_join("memcards")
	if not DirAccess.dir_exists_absolute(root):
		return ""
	for fam: String in DirAccess.get_directories_at(root):
		var fmt := CardFormats.for_family(fam)
		if fmt == null:
			continue
		var p := root.path_join(fam).path_join("%s.%s" % [card_id, fmt.extension()])
		if FileAccess.file_exists(p):
			return p
	return ""


## The card's path, creating a formatted blank first if it has none yet. A card
## has to arrive formatted because RetroXR never boots a console's own BIOS, so
## the player has no way to format one. Never touches an image that exists.
static func ensure_card(family: String, card_id: String) -> String:
	var path := card_save_path(family, card_id)
	if path.is_empty() or FileAccess.file_exists(path):
		return path
	var fmt := CardFormats.for_family(family)
	if fmt == null:
		return ""
	DirAccess.make_dir_recursive_absolute(cards_dir(family))
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		# "" and not the path: a caller that is handed a path treats the card as
		# present and formatted, and this one does not exist. Both callers
		# already read "" as "no card", which is what this is.
		push_error("[SramPaths] cannot create memory card %s" % path)
		return ""
	f.store_buffer(fmt.blank_image())
	f.close()
	return path


## Resolve the default core for a cartridge's systemid ("" when unknown).
static func core_for_systemid(systemid: String) -> String:
	if systemid.is_empty():
		return ""
	var defaults := CoreDefaults.new()
	defaults.setup(CoreDefaults.default_path())
	return defaults.get_default_core(systemid)


## Erase one .srm. Nothing keeps a copy, so both menus that offer this ask twice
## first, and neither offers it while the console holding the game is on — the
## core would write the file straight back on its next flush.
static func delete_save(core_name: String, rom_path: String, save_id: String) -> bool:
	if core_name.is_empty() or save_id.is_empty():
		return false
	var path := cart_save_path(core_name, rom_path, save_id)
	if not FileAccess.file_exists(path):
		return false
	return DirAccess.remove_absolute(path) == OK


## Every existing .srm for this game (save recovery list). Entries:
## {save_id, path, mtime, size}, newest first.
static func list_saves(core_name: String, rom_path: String) -> Array:
	var out: Array = []
	var dir := cart_save_dir(core_name, rom_path)
	if core_name.is_empty() or not DirAccess.dir_exists_absolute(dir):
		return out
	for fname: String in DirAccess.get_files_at(dir):
		if fname.get_extension().to_lower() != "srm":
			continue
		var path := dir.path_join(fname)
		out.append({
			"save_id": fname.get_basename(),
			"path": path,
			"mtime": FileAccess.get_modified_time(path),
			"size": NetFileTransfer.size_of(path),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["mtime"]) > int(b["mtime"]))
	return out
