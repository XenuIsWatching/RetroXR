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
## The save-management half of CardFormat is NOT implemented. Listing, extracting
## and deleting individual programmes needs BS-X's own on-pack directory format,
## which has not been measured. The base class returns empty values for those
## rather than erroring, so a pack shows as a pack with no itemised contents —
## honest, and better than guessing at a layout and corrupting a player's medium.
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
