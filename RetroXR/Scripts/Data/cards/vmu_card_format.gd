## VMUCardFormat — the Dreamcast's Visual Memory Unit, as a CardFormat.
##
## Forwards to VMUCard, which holds the measured layout and is deliberately left
## alone. Nothing but the forwards belongs here.
##
## The family is "vmu" rather than "dreamcast" for two reasons. The card is a
## VMU — it plugs into a controller, not the console, and the console declares
## no card_family at all — and `card_tests` uses "dreamcast" as its known-absent
## family, which is a check worth keeping.
class_name VMUCardFormat
extends CardFormat


func id() -> String:
	return "vmu"


func label() -> String:
	return "Dreamcast"


## Not "Memory Card": this thing has a screen and a d-pad and its own name.
func device_noun() -> String:
	return "Visual Memory Unit"


func extension() -> String:
	return "vmu"


## A lifted save is a .dci, not a raw .vms, because only the .dci carries the
## directory entry — the type, the on-card name, the block count and the header
## offset. A .vms would have all four invented on the way back in.
func save_extension() -> String:
	return "dci"


func unit_noun() -> String:
	return "block"


## Fixed at 200. Every VMU is one 128 KB flash of 256 blocks, of which only
## 0-199 are the player's; the rest are the directory, FAT, root and a reserved
## run. The argument is ignored rather than parsed.
func total_blocks(_data: PackedByteArray) -> int:
	return VMUCard.USER_BLOCKS


func blocks_for_size(byte_size: int) -> int:
	@warning_ignore("integer_division")
	var blocks: int = (byte_size - VMUCard.DCI_HEADER) / VMUCard.BLOCK_SIZE
	return maxi(1, blocks)


## A VMS carries its own animation speed per save, but CardFormat has no channel
## to pass one, so this is the fallback rate the whole family animates at.
func icon_fps() -> float:
	return 6.0


func blank_image() -> PackedByteArray:
	return VMUCard.blank_image()


func is_card_image(data: PackedByteArray) -> bool:
	return VMUCard.is_card_image(data)


func list_saves(data: PackedByteArray, with_icons := true) -> Array[Dictionary]:
	return VMUCard.list_saves(data, with_icons)


func block_of(data: PackedByteArray, name: String) -> int:
	return VMUCard.block_of(data, name)


func extract_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	return VMUCard.extract_save(data, first_block)


func is_save_file(bytes: PackedByteArray) -> bool:
	return VMUCard.is_dci(bytes)


func insert_save(data: PackedByteArray, save: PackedByteArray) -> PackedByteArray:
	return VMUCard.insert_save(data, save)


func delete_save(data: PackedByteArray, first_block: int) -> PackedByteArray:
	return VMUCard.delete_save(data, first_block)


func free_blocks(data: PackedByteArray) -> int:
	return VMUCard.free_blocks(data)
