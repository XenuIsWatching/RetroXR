extends Node3D

## Does a table survive a bedroom save slot?
##
## The bedroom kept no slots until it was emptied, and a table is a brand new
## persisted type — so this walks the whole round trip a player makes: put one
## down, save, clear the room, load it back.
##
## It writes a scratch slot into the player's real user://scenes/bedroom and
## deletes it again at both ends; the slot dir is derived from the room id and
## cannot be pointed elsewhere.

const TABLE := preload("res://Scenes/Objects/furniture/table.tscn")
const POSE := Vector3(1.25, 0.0, -0.75)

var _fail := 0


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func(): get_tree().quit(1))

	var sp := ScenePersistence.new("bedroom")
	var slot: String = sp.create_new_slot(self, "__table_selftest")
	if slot.is_empty():
		print("[probe] FAIL could not create a bedroom slot")
		get_tree().quit(1)
		return
	print("[probe] ok   bedroom accepted a save slot (%s)" % slot)

	var table: Node3D = TABLE.instantiate()
	add_child(table)
	table.add_to_group("spawned")
	table.global_position = POSE
	table.freeze = true          # hold the pose; this is about the slot, not gravity
	await get_tree().physics_frame

	_expect(sp.save_slot(self, slot), "the slot saved with a table in the room")
	ScenePersistence.flush_pending_writes()
	await get_tree().process_frame

	sp.clear_scene(self)
	await get_tree().process_frame
	_expect(_find_table() == null, "clear_scene took the table away")

	await sp.load_slot_async(self, slot)
	await get_tree().process_frame

	var back := _find_table()
	_expect(back != null, "the table came back from the slot")
	if back != null:
		var d: float = back.global_position.distance_to(POSE)
		_expect(d < 0.05, "it came back where it was left (off by %.3f m)" % d)

	sp.delete_slot(slot)
	ScenePersistence.flush_pending_writes()

	print("[probe] %s" % ("PASS" if _fail == 0 else "%d FAILURE(S)" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


func _find_table() -> Node3D:
	for n in get_tree().get_nodes_in_group("spawned"):
		if n is Table:
			return n
	return null


func _expect(got: bool, label: String) -> void:
	if got:
		print("[probe] ok   %s" % label)
	else:
		_fail += 1
		print("[probe] FAIL %s" % label)
