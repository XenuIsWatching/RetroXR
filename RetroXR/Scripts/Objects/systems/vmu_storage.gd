## VmuStorage — binds the VMUs seated in a Dreamcast's controllers to the files
## flycast reads them from.
##
## Every other console here backs a card through SAVE_RAM and SetSramPath. That
## reaches nothing on a Dreamcast: flycast answers retro_get_memory_size with 0
## and keeps its own files, so this is the Dolphin situation rather than the
## PlayStation one — except that flycast takes no path option either, so there is
## nothing to point at a card. What it has instead is a fixed location:
##
##     <root>/system/<core>/dc/vmu_save_<Port><Slot>.bin      Port A-D, Slot 1-2
##
## So a card is STAGED into that location before content starts and drained back
## out afterwards. flycast holds the file open and flushes every block write
## immediately, which is what makes draining safe at any moment rather than a
## race — the file on disk is always current.
##
## **The binding is load-time only, and that is measured rather than assumed.**
## Toggling `reicast_device_port<N>_slot<S>` while the core runs does not
## re-create the maple device, so a card seated or pulled mid-game cannot reach
## it. See Tools/cores/vmu_slot_probe, which also records why the obvious probe
## for this proves nothing. A change made while the machine is on is recorded and
## takes effect at the next power-on.
class_name VmuStorage
extends Node

## The family whose images this stages. Cards live at
## save/memcards/vmu/<card_id>.vmu, with no core in the path, because a card is
## hardware and its raw image is the same whichever core reads it.
const FAMILY := "vmu"

## flycast's own option keys. The legacy `reicast_` prefix, not `flycast_`.
const SLOT_KEY := "reicast_device_port%d_slot%d"

## Per-content VMU files would re-key a card per game, which is exactly what a
## card is not: one image, many games. Pinned off.
const PER_CONTENT_KEY := "reicast_per_content_vmus"

## What an empty slot must say. "None" has to mean genuinely absent rather than a
## blank card, or a game offers to format something instead of reporting no
## memory card — the same distinction pcsx_rearmed's `_inserted` option draws.
const SLOT_EMPTY := "None"

var _host: RetroSystem = null
## Which card id was staged into which "<Port><Slot>" name this run, so a drain
## knows where to put the bytes back even if the card has since been pulled.
var _staged: Dictionary = {}


func setup(host: RetroSystem) -> void:
	_host = host


## Does this machine use VMUs at all? Keyed on the console's OWN systemid rather
## than whatever disc is in the drive: a Dreamcast's pads have slots whatever it
## is running.
func _uses_vmus() -> bool:
	return is_instance_valid(_host) and _host.systemid == VmuPort.HOST_SYSTEMID


## Where flycast keeps one slot's flash. `port` is 0-based, `slot` 0-based.
static func core_vmu_path(root: String, core: String, port: int, slot: int) -> String:
	return root.path_join("system/%s/dc/vmu_save_%s%d.bin"
		% [core, char("A".unicode_at(0) + port), slot + 1])


func _read(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b: PackedByteArray = f.get_buffer(f.get_length())
	f.close()
	return b


func _write(path: String, data: PackedByteArray) -> bool:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("[VmuStorage] cannot write %s" % path)
		return false
	f.store_buffer(data)
	f.close()
	return true


## Every (port, slot, card) this machine's controllers currently hold. A pad with
## no VMU slots contributes nothing, which is not the same as contributing empty
## slots — a Light Gun has one slot and a keyboard has none.
func _seated() -> Array:
	var out: Array = []
	if not _uses_vmus():
		return out
	var ports: Array = _host.get_port_controllers()
	for port in range(ports.size()):
		var ctrl: Node = ports[port]
		if not is_instance_valid(ctrl) or not ctrl.has_method("vmu_slot_count"):
			continue
		var slots: int = int(ctrl.call("vmu_slot_count"))
		for slot in range(slots):
			out.append({
				"port": port,
				"slot": slot,
				"card": ctrl.call("get_vmu", slot),
				"value": str(ctrl.call("vmu_slot_option_value", slot)),
			})
	return out


# --- Before the core starts ---------------------------------------------------

## Copy each seated card into the file flycast will read, and pin the per-slot
## device options to match. Called from the content-start path, before the core
## is told to run.
func stage_before_start(dir: String, core: String) -> void:
	_staged.clear()
	if not _uses_vmus() or not core.begins_with("flycast"):
		return

	var opts := {PER_CONTENT_KEY: "disabled"}
	for entry: Dictionary in _seated():
		var port: int = entry["port"]
		var slot: int = entry["slot"]
		opts[SLOT_KEY % [port + 1, slot + 1]] = str(entry["value"])

		var path := core_vmu_path(dir, core, port, slot)
		var card: Node = entry["card"]
		if not is_instance_valid(card):
			# Nothing seated. Leave whatever is there alone rather than deleting
			# it — the option says the slot is empty, and a file the core is not
			# reading is harmless. Deleting would throw away the last card's
			# saves for a player who simply pulled it out.
			continue

		var image := _card_image(card)
		if image.is_empty():
			continue
		if _write(path, image):
			_staged[_key(port, slot)] = str(card.get("card_id"))

	if not opts.is_empty() and CoreOptionsStore.merge_values(dir, core, opts):
		print("[VmuStorage] slots pinned before boot: %s" % str(opts))


## One card's image, creating it only for a card this session invented.
##
## A card restored from a saved room whose file has gone missing runs unbacked
## rather than being handed a blank: answering with a fresh empty card reads
## exactly like the saves were wiped.
func _card_image(card: Node) -> PackedByteArray:
	var card_id := str(card.get("card_id"))
	if card_id.is_empty():
		return PackedByteArray()
	var path := SramPaths.find_card(card_id, FAMILY)
	if path.is_empty():
		if not bool(card.get("minted")):
			push_warning("[VmuStorage] VMU '%s' has no image on disk - running without it rather than creating a blank" % card_id)
			return PackedByteArray()
		path = SramPaths.ensure_card(FAMILY, card_id)
	return _read(path)


static func _key(port: int, slot: int) -> String:
	return "%d:%d" % [port, slot]


# --- After it stops, and while it runs ----------------------------------------

## Copy what the core has written back into the cards it came from.
##
## Safe at any moment: flycast flushes each block write straight through, so the
## staged file is never half a save. A file that does not parse as a card is
## skipped rather than copied — a torn read must not overwrite a good image.
func drain(dir: String, core: String) -> void:
	if _staged.is_empty():
		return
	for key: String in _staged:
		var bits := key.split(":")
		if bits.size() != 2:
			continue
		var path := core_vmu_path(dir, core, int(bits[0]), int(bits[1]))
		var data := _read(path)
		if data.is_empty() or not VMUCard.is_card_image(data):
			continue
		var card_path := SramPaths.card_save_path(FAMILY, str(_staged[key]))
		if card_path.is_empty():
			continue
		if _read(card_path) != data:
			_write(card_path, data)


## Re-announce the slots on one controller. Called when a VMU is pushed into or
## pulled out of a slot, which the system cannot see for itself — the slot
## belongs to the controller, two objects away.
##
## It deliberately does NOT touch the running core: flycast will not re-create a
## maple device for a changed slot option, measured. The seating is recorded and
## the next content start applies it.
func reapply(ctrl: Node) -> void:
	if not _uses_vmus() or not is_instance_valid(ctrl):
		return
	if not is_instance_valid(_host) or not _host.is_powered_on:
		return
	print("[VmuStorage] VMU change noted; it takes effect when the machine is next powered on")
