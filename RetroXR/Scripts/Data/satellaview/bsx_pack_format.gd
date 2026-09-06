class_name BsxPackFormat
extends CardFormat

## BsxPackFormat — the Satellaview's 8M Memory Pack, as a CardFormat.
##
## Forwards to BsxPack, which holds the measured layout and is deliberately left
## alone, exactly as PS1CardFormat forwards to PS1Card.
##
## Two ways this family is unlike the console card families beside it, both
## deliberate:
##
## A pack is CONTENT, not only a save. snes9x is handed the `.bs` as the game and
## points FlashROM at it, so the same file is what the shell boots from and what a
## download is written onto. That is why packs live in <roms>/satellaview/ rather
## than under save/memcards/ — the core resolves its broadcast directory from the
## loaded ROM's own folder, so a pack anywhere else boots fine and receives
## nothing.
##
## The READING half of the save-management interface is now implemented; the
## writing half is still not, and the reason has changed rather than gone away.
##
## The on-pack layout has been measured: eight blocks of 1 Mbit, a programme's
## header at its first block's LoROM or HiROM offset, and OFF_BLOCK_ALLOC a
## bitmap of the blocks it holds. Read off a real pack carrying two programmes,
## 0x0F and 0xF0 — exact complements. So list_saves, total_blocks, free_blocks and
## block_of can all answer honestly, and BsxPack.programmes_of does the work.
##
## extract_save / insert_save / delete_save are still the base class's empty
## stubs. What is missing for those is not the directory but the ERASE semantics:
## flash is reclaimed in whole blocks and nothing here has watched the BS-X do it.
## A wrong guess does not fail loudly, it destroys a download that can only be got
## again off the live broadcast — so a pack lists what is on it and refuses to
## rearrange it, which is the honest half to ship.
##
## DELIBERATELY NOT REGISTERED in CardFormats. Membership of that registry means
## "this family's images live at save/memcards/<id>/", which SramPaths.cards_dir
## resolves for anything holding the family id. A pack filed there would load and
## boot perfectly and receive NOTHING, because snes9x reads its broadcast packets
## out of the loaded ROM's own directory. Instantiate this class directly; do not
## add it to CardFormats._build() to "finish" it.


func id() -> String:
	return "bsx"


func label() -> String:
	return "Satellaview"


func extension() -> String:
	return "bs"


func unit_noun() -> String:
	return "block"


func blank_image() -> PackedByteArray:
	return BsxPack.blank_image()


func is_card_image(data: PackedByteArray) -> bool:
	return BsxPack.is_pack_image(data)


## A pack is eight blocks whatever is on it — unlike a GameCube card, whose size
## is a property of the card, so this ignores the image rather than reading it.
func total_blocks(_data: PackedByteArray) -> int:
	return BsxPack.BLOCK_COUNT


func free_blocks(data: PackedByteArray) -> int:
	return BsxPack.free_blocks(data)


## Every programme on the pack, in CardFormat's shape.
##
## `block` is the block the header sits in, which is exactly what that field is
## for: an opaque handle nothing outside a format may read anything into.
## `serial` is empty because a broadcast carries no product code, and `icons` is
## empty because a pack stores no icon — `with_icons` therefore costs nothing here
## and is accepted only to honour the signature.
func list_saves(data: PackedByteArray, _with_icons := true) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for p: Dictionary in BsxPack.programmes_of(data):
		var title := str(p["title"])
		# A blank pack's placeholder header names no programme.
		if title.is_empty() or title == BsxPack.BLANK_TITLE:
			continue
		var blocks: Array = p["blocks"]
		out.append({
			"name": title,
			"serial": "",
			"title": title,
			"blocks": blocks.size(),
			"block": int(p["block"]),
			"icons": [],
		})
	return out


func block_of(data: PackedByteArray, name: String) -> int:
	for s: Dictionary in list_saves(data, false):
		if str(s["name"]) == name:
			return int(s["block"])
	return -1
