## N64CardFormat — the Controller Pak, as a CardFormat.
##
## Forwards to N64Card, which holds the measured 32 KiB layout. Nothing but the
## forwards belongs here.
##
## Filed as its own family rather than under a console: a Controller Pak plugs
## into a CONTROLLER, so nintendo_64 deliberately declares no card_family — that
## field drives the console's own slots and would divert the cartridge save.
class_name N64CardFormat
extends CardFormat


func id() -> String:
	return "controller_pak"


## The CONSOLE family, like every other format's label — "PlayStation",
## "GameCube", "Nintendo 64". What the object itself is called is device_noun().
func label() -> String:
	return "Nintendo 64"


func extension() -> String:
	return "mpk"


func save_extension() -> String:
	return "note"


## The N64 counted its pak in pages, and every game says so on screen.
func unit_noun() -> String:
	return "page"


func device_noun() -> String:
	return "Controller Pak"


## Fixed at 123 — pages 0 to 4 are the ID block, the index table, its backup and
## the note table. Every Controller Pak is the same size, so the argument is
## ignored rather than parsed.
func total_blocks(_data: PackedByteArray) -> int:
	return N64Card.usable_pages()


func blocks_for_size(byte_size: int) -> int:
	@warning_ignore("integer_division")
	var pages: int = (byte_size - N64Card.NOTE_SIZE) / N64Card.PAGE_SIZE
	return maxi(1, pages)


## A note carries no icon, so nothing animates. The contract still wants a rate
## above zero.
func icon_fps() -> float:
	return 6.0


func blank_image() -> PackedByteArray:
	return N64Card.blank_image()


func is_card_image(data: PackedByteArray) -> bool:
	return N64Card.is_card_image(data)


func list_saves(data: PackedByteArray, with_icons := true) -> Array[Dictionary]:
	return N64Card.list_saves(data, with_icons)


func block_of(data: PackedByteArray, name: String) -> int:
	return N64Card.block_of(data, name)


func extract_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	return N64Card.extract_save(data, first_block)


func is_save_file(bytes: PackedByteArray) -> bool:
	return N64Card.is_note(bytes)


func insert_save(data: PackedByteArray, save: PackedByteArray) -> PackedByteArray:
	return N64Card.insert_save(data, save)


func delete_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	return N64Card.delete_save(data, first_block)


func free_blocks(data: PackedByteArray) -> int:
	return N64Card.free_blocks(data)
