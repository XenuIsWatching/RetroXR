## PS2CardFormat — the PlayStation 2's card, as a CardFormat.
##
## Forwards to PS2Card, which holds the measured layout. Nothing but the
## forwards belongs here.
class_name PS2CardFormat
extends CardFormat


func id() -> String:
	return "playstation2"


func label() -> String:
	return "PlayStation 2"


func extension() -> String:
	return "ps2"


## The container every PS2 save tool reads. PCSX2 itself has no single-save
## import or export at all, so this comes from the wider ecosystem rather than
## from the emulator.
func save_extension() -> String:
	return "psu"


## The PS2 counts its card in kilobytes, and its own browser says so.
func unit_noun() -> String:
	return "KB"


## "KB" is already plural. Without this the usage line reads "7999 KBs".
func unit_plural() -> String:
	return "KB"


## Fixed at 7998. The card holds 8135 allocatable clusters, but both the console
## and PCSX2 report a truncated 7999, and one of those is the root directory,
## which a save can never have.
func total_blocks(data: PackedByteArray) -> int:
	return PS2Card.total_blocks(data)


## A .psu is headers of one entry each plus file data padded to a cluster, and a
## directory slot on the card is the same 512 bytes two-to-a-cluster, so the
## container's size tracks what it will occupy closely enough to size a restore.
func blocks_for_size(byte_size: int) -> int:
	@warning_ignore("integer_division")
	var clusters: int = (byte_size + PS2Card.CLUSTER_SIZE - 1) / PS2Card.CLUSTER_SIZE
	return maxi(1, clusters)


## Only a fallback: a PS2 icon is a 3-D model that carries its own animation
## speed, and the view that draws one reads that instead of this.
func icon_fps() -> float:
	return 6.0


func blank_image() -> PackedByteArray:
	return PS2Card.blank_image()


func is_card_image(data: PackedByteArray) -> bool:
	return PS2Card.is_card_image(data)


func list_saves(data: PackedByteArray, with_icons := true) -> Array[Dictionary]:
	return PS2Card.list_saves(data, with_icons)


func block_of(data: PackedByteArray, name: String) -> int:
	return PS2Card.block_of(data, name)


func extract_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	return PS2Card.extract_save(data, first_block)


func is_save_file(bytes: PackedByteArray) -> bool:
	return PS2Card.is_psu(bytes)


func insert_save(data: PackedByteArray, save: PackedByteArray) -> PackedByteArray:
	return PS2Card.insert_save(data, save)


func delete_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	return PS2Card.delete_save(data, first_block)


func free_blocks(data: PackedByteArray) -> int:
	return PS2Card.free_blocks(data)
