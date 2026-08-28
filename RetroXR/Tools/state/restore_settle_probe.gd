extends Node

## Boots the real arcade room (which auto-loads the last saved slot) and measures
## how far every restored body travels from where it was put — the "the whole room
## rains into place" artifact. A clean restore moves almost nothing.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20 res://Tools/state/restore_settle_probe.tscn
##   ... -- --video      also writes res://probe_out/settle_seq/*.png

const SECONDS := 15.0
## A step bigger than this in one tick is a placement, not motion.
const TELEPORT := 0.05
const CAM_FROM := Vector3(1.45, 1.45, 1.55)
const CAM_LOOK := Vector3(-0.05, 0.85, -0.5)

var _video := false
var _sv: SubViewport
var _cam: Camera3D

# body -> {first: Vector3, prev: Vector3, path: float, drop: float}
var _track: Dictionary = {}


func _ready() -> void:
	_video = "--video" in OS.get_cmdline_user_args()
	get_tree().create_timer(600.0).timeout.connect(func() -> void: get_tree().quit(1))
	if _video:
		DirAccess.make_dir_recursive_absolute("res://probe_out/settle_seq")
		var lamp := OmniLight3D.new()
		lamp.light_energy = 8.0
		lamp.omni_range = 7.0
		add_child(lamp)
		lamp.global_position = Vector3(0.4, 2.0, 0.6)
		_sv = SubViewport.new()
		_sv.size = Vector2i(900, 600)
		_sv.own_world_3d = false
		_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
		add_child(_sv)
		_cam = Camera3D.new()
		_sv.add_child(_cam)
		_cam.fov = 55.0
		_cam.current = true
		_cam.global_position = CAM_FROM
		_cam.look_at(CAM_LOOK)

	var t0 := Time.get_ticks_msec()
	var frame := 0
	while Time.get_ticks_msec() - t0 < int(SECONDS * 1000.0):
		await get_tree().physics_frame
		_step()
		if _video:
			await RenderingServer.frame_post_draw
			_sv.get_texture().get_image().save_png("res://probe_out/settle_seq/f%04d.png" % frame)
			frame += 1

	print("[settle] --- drift since the restore put each body down ---")
	var total := 0.0
	var worst_drop := 0.0
	var movers := 0
	for k: Variant in _track:
		var t: Dictionary = _track[k]
		total += float(t["drift"])
		worst_drop = maxf(worst_drop, float(t["drop"]))
		if float(t["drift"]) > 0.02:
			movers += 1
			print("[settle]   %-28s drifted %.2f m, sank %.2f m, %d teleports"
				% [t["name"], t["drift"], t["drop"], t["jumps"]])
	print("[settle] TOTAL drift=%.2f m over %d bodies (%d drifted), worst sink=%.2f m"
		% [total, _track.size(), movers, worst_drop])
	print("[settle] done")
	get_tree().quit(0)


func _step() -> void:
	for n: Node in get_tree().get_nodes_in_group("spawned"):
		_walk(n)


func _walk(n: Node) -> void:
	if n is RigidBody3D:
		var body := n as RigidBody3D
		var p := body.global_position
		var id := body.get_instance_id()
		if not _track.has(id):
			_track[id] = {"name": str(body.name), "prev": p, "drift": 0.0, "drop": 0.0,
				"jumps": 0, "rest": p.y}
			return
		var t: Dictionary = _track[id]
		var step: float = (t["prev"] as Vector3).distance_to(p)
		# A restore MOVES things on purpose — pass 2 puts the speakers back where
		# they were saved, which is 6 m from where the pair spawned. That arrives as
		# one huge step; falling arrives as a stream of small ones. Only the small
		# ones are the artifact, and only they are counted. The sink is measured
		# from the last teleport for the same reason.
		if step > TELEPORT:
			t["jumps"] = int(t["jumps"]) + 1
			t["rest"] = p.y
		else:
			t["drift"] = float(t["drift"]) + step
			t["drop"] = maxf(float(t["drop"]), float(t["rest"]) - p.y)
		t["prev"] = p
	for c in n.get_children():
		_walk(c)
