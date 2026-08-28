## Can the VR LASER pick this object up?
##
## Nothing to do with the interaction resolver. XRToolsFunctionPickup reads its
## sibling pointer's RayCast — mask 21 and 23 only — and resolves the collider
## with _resolve_pickable, which accepts the collider itself or its DIRECT parent
## and nothing further. An object with no body on 21 is invisible to the laser
## however grabbable it is on the desktop.
##
##   godot --headless --path RetroXR res://Tools/vr/laser_grab_probe.tscn
extends Node3D

const POINTER_MASK := 0b0000_0000_0101_0000_0000_0000_0000_0000
const DESKTOP_MASK := InteractionResolver.QUERY_MASK

const SUBJECTS := {
	"Sensor Bar": "res://Scenes/Objects/system_models/wii/sensor_bar.tscn",
	"Cartridge": "res://Scenes/Objects/media/cartridge.tscn",
	"Keyboard": "res://Scenes/Objects/peripherals/retro_keyboard.tscn",
	"Wiimote": "res://Scenes/Objects/controllers/wii/wiimote.tscn",
}

var _fail := 0


func _ready() -> void:
	get_tree().create_timer(150.0).timeout.connect(func() -> void:
		print("[lg] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self
	_run()


func _run() -> void:
	print("[lg] %-14s %-24s %-24s" % ["object", "VR laser (21,23)", "desktop ray (1,3,21,23)"])
	for label in SUBJECTS:
		await _check(String(label), String(SUBJECTS[label]))
	print("[lg] %s" % ("PASS" if _fail == 0 else "%d cannot be laser-grabbed" % _fail))
	get_tree().quit(0 if _fail == 0 else 1)


func _check(label: String, path: String) -> void:
	if not ResourceLoader.exists(path):
		print("[lg] %-14s (scene missing)" % label)
		return
	var obj := (load(path) as PackedScene).instantiate() as Node3D
	add_child(obj)
	obj.global_position = Vector3(0, 1, 0)
	await _wait(30)
	var rb := obj as RigidBody3D
	if rb != null:
		rb.freeze = true
	await _wait(5)

	var laser := _hit(obj, POINTER_MASK)
	var desktop := _hit(obj, DESKTOP_MASK)
	if not laser:
		_fail += 1
	print("[lg] %-14s %-24s %-24s"
		% [label, "YES" if laser else "no — invisible to it", "YES" if desktop else "no"])
	obj.queue_free()
	await _wait(5)


## Fire at the object from six faces; does anything resolve to a pickable the way
## _resolve_pickable does it — the collider, or its direct parent?
## `obj` itself must be what resolves — the sensor bar tows a cable whose plugs
## ARE on 21, so "some pickable answered" is not the question.
func _hit(obj: Node3D, mask: int) -> bool:
	var at: Vector3 = obj.global_position
	for dir in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT,
			Vector3.FORWARD, Vector3.BACK]:
		var q := PhysicsRayQueryParameters3D.create(at + dir * 0.6, at, mask)
		q.collide_with_areas = true
		var hit := get_world_3d().direct_space_state.intersect_ray(q)
		if hit.is_empty():
			continue
		var collider := hit.collider as Node3D
		var pickable := collider as XRToolsPickable
		if pickable == null and collider != null:
			pickable = collider.get_parent() as XRToolsPickable
		if pickable != null and pickable == obj:
			return true
	return false


func _wait(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame
