## PS1CardFormat — the PlayStation's card, as a CardFormat.
##
## Forwards to PS1Card, which holds the measured .mcr layout and is deliberately
## left alone. Nothing but the forwards belongs here.
class_name PS1CardFormat
extends CardFormat


func id() -> String:
	return "playstation"


func label() -> String:
	return "PlayStation"


func extension() -> String:
	return "mcr"


func save_extension() -> String:
	return "mcs"


func unit_noun() -> String:
	return "block"


## Fixed at 15 — every PlayStation card is one 128 KB image of 16 blocks, of
## which block 0 is the directory. The argument is ignored rather than parsed.
func total_blocks(_data: PackedByteArray) -> int:
	return PS1Card.BLOCK_COUNT - 1


func blocks_for_size(byte_size: int) -> int:
	@warning_ignore("integer_division")
	var blocks: int = (byte_size - PS1Card.FRAME_SIZE) / PS1Card.BLOCK_SIZE
	return maxi(1, blocks)


## The rate the PlayStation itself cycled icon frames at.
func icon_fps() -> float:
	return 6.0


func blank_image() -> PackedByteArray:
	return PS1Card.blank_image()


func is_card_image(data: PackedByteArray) -> bool:
	return PS1Card.is_card_image(data)


func list_saves(data: PackedByteArray, with_icons := true) -> Array[Dictionary]:
	return PS1Card.list_saves(data, with_icons)


func block_of(data: PackedByteArray, name: String) -> int:
	return PS1Card.block_of(data, name)


func extract_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	return PS1Card.extract_save(data, first_block)


func is_save_file(bytes: PackedByteArray) -> bool:
	return PS1Card.is_mcs(bytes)


func insert_save(data: PackedByteArray, save: PackedByteArray) -> PackedByteArray:
	return PS1Card.insert_save(data, save)


func delete_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	return PS1Card.delete_save(data, first_block)


func free_blocks(data: PackedByteArray) -> int:
	return PS1Card.free_blocks(data)
