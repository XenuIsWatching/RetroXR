## CardFormat — one console family's memory card, as an object.
##
## Everything about cards used to key on systemid, which held only while the
## PlayStation was the one console with them. It is the wrong key: a card family
## is a folder under save/memcards/, a file extension, a byte layout and a
## vocabulary, and the GameCube's is shared by TWO systemids — a Wii playing a
## GameCube disc writes to a GameCube card.
##
## The format half of this forwards to an all-static class (PS1Card, GCCard).
## Those stay static and untouched: they are measured, they are the thing most
## worth being able to test without a scene, and GDScript has no virtual statics
## to dispatch through anyway. This is the adapter that gives them one.
##
## Subclasses override everything. The stubs here return empty values rather than
## pushing an error, so a half-built format shows an empty card instead of
## spraying the log from _process.
class_name CardFormat
extends RefCounted


# --- Identity -----------------------------------------------------------------

## The folder under save/memcards/, and the value a MemoryCard carries as its
## `family`. Also the RomM platform saves from this family are filed under.
func id() -> String:
	return ""


## Console family name for menus and refusal messages ("PlayStation").
func label() -> String:
	return ""


## Card image extension, no dot ("mcr").
func extension() -> String:
	return ""


## Extension of ONE save lifted off a card ("mcs"). Uploaded to RomM under it,
## and what the card listing filters the server's saves by.
func save_extension() -> String:
	return ""


# --- Vocabulary ---------------------------------------------------------------

## What one unit of card space is called, singular ("block").
func unit_noun() -> String:
	return "block"


## How many units this card holds in total. Read from the IMAGE, because a
## GameCube card's size is a property of the card and not of the family — a 59
## and a 251 are both ordinary. Falls back to the family's usual size when the
## image is missing or unreadable, which is what a card that has never been
## seated has to show.
func total_blocks(_data: PackedByteArray) -> int:
	return 0


## How many units a save of this byte size occupies, given the file is one save
## as extract_save() produces it.
func blocks_for_size(_byte_size: int) -> int:
	return 1


## Frames per second to animate a save's icon at, when the format does not carry
## a per-frame duration of its own.
func icon_fps() -> float:
	return 6.0


# --- Format -------------------------------------------------------------------

## A freshly formatted, empty card. RetroXR never boots a console's own BIOS, so
## the player has no way to format one and a new card must arrive usable.
func blank_image() -> PackedByteArray:
	return PackedByteArray()


func is_card_image(_data: PackedByteArray) -> bool:
	return false


## Every save on the card, one entry each:
##   name    String   the save's own filename on the card
##   serial  String   the game's product code, for matching it to a library entry
##   title   String   the save's own title
##   blocks  int      how many units it occupies
##   block   int      an opaque handle to this save, which every other call
##                     here takes. The PlayStation numbers saves by their first
##                     block and the GameCube by directory entry; nothing outside
##                     a format may read anything into the number.
##   icons   Array    Image, one per animation frame
##
## `with_icons` off skips decoding the images, which is the expensive part by
## far. Only the save list draws them.
func list_saves(_data: PackedByteArray, _with_icons := true) -> Array[Dictionary]:
	return []


## The first block of the save with this filename, or -1.
func block_of(_data: PackedByteArray, _name: String) -> int:
	return -1


## One save lifted out of a card as a standalone file, in the format every tool
## for this console reads.
func extract_save(_data: PackedByteArray, _first_block: int) -> PackedByteArray:
	return PackedByteArray()


## Does this look like a save of THIS family, rather than some other console's?
## Worth asking of anything that came off a server: a save is just bytes with a
## name, and splicing a foreign one into a card corrupts the card.
func is_save_file(_bytes: PackedByteArray) -> bool:
	return false


## Splice a save into a card, returning a NEW image. Empty when it will not fit,
## is malformed, or a save of that name is already there.
func insert_save(_data: PackedByteArray, _save: PackedByteArray) -> PackedByteArray:
	return PackedByteArray()


## Free the space one save occupies, returning a NEW image.
func delete_save(_data: PackedByteArray, _first_block: int) -> PackedByteArray:
	return PackedByteArray()


func free_blocks(_data: PackedByteArray) -> int:
	return 0
