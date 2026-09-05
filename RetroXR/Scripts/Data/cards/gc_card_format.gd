## GCCardFormat — the GameCube's card, as a CardFormat.
##
## Forwards to GCCard, which holds the measured raw layout. Shared by the
## GameCube and the Wii: a Wii playing a GameCube disc writes to the same card.
class_name GCCardFormat
extends CardFormat


func id() -> String:
	return "gamecube"


func label() -> String:
	return "GameCube"


func extension() -> String:
	return "raw"


func save_extension() -> String:
	return "gci"


func unit_noun() -> String:
	return "block"


## Read from the image, unlike the PlayStation's fixed fifteen: a GameCube card's
## size is a property of the card. A 59 and a 251 are both ordinary, and the
## blank we format is a 251.
func total_blocks(data: PackedByteArray) -> int:
	return GCCard.total_blocks(data)


func blocks_for_size(byte_size: int) -> int:
	@warning_ignore("integer_division")
	var blocks: int = (byte_size - GCCard.DENTRY_SIZE) / GCCard.BLOCK_SIZE
	return maxi(1, blocks)


## GameCube icons carry a per-frame duration in units of four VBlanks, so a fixed
## rate is only the fallback for a save whose frames all ask for the same one.
## Four VBlanks at 60 Hz is 15 Hz.
func icon_fps() -> float:
	return 15.0


func blank_image() -> PackedByteArray:
	return GCCard.blank_image()


func is_card_image(data: PackedByteArray) -> bool:
	return GCCard.is_card_image(data)


func list_saves(data: PackedByteArray, with_icons := true) -> Array[Dictionary]:
	return GCCard.list_saves(data, with_icons)


func block_of(data: PackedByteArray, name: String) -> int:
	return GCCard.block_of(data, name)


func extract_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	return GCCard.extract_save(data, first_block)


func is_save_file(bytes: PackedByteArray) -> bool:
	return GCCard.is_gci(bytes)


func insert_save(data: PackedByteArray, save: PackedByteArray) -> PackedByteArray:
	return GCCard.insert_save(data, save)


func delete_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	return GCCard.delete_save(data, first_block)


func free_blocks(data: PackedByteArray) -> int:
	return GCCard.free_blocks(data)
