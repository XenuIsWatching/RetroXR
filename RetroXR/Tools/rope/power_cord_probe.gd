extends Node3D

const CORD := preload("res://Scenes/Objects/cables/power_cord.tscn")
const C14 := preload("res://Scenes/Objects/cables/iec_c14_inlet.res")
const OUT := "res://probe_out"

var viewport: SubViewport
var camera: Camera3D

func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT)
	_build_stage()
	await _shoot("power_cord_full", Vector3(0,0.78,1.85), Vector3(0,0.40,0), 46.0)
	await _shoot("power_cord_nema", Vector3(-0.58,0.90,0.48), Vector3(-0.58,0.78,0), 30.0)
	await _shoot("power_cord_iec", Vector3(0.58,0.90,0.48), Vector3(0.58,0.78,0), 30.0)
	print("[power-cord-probe] done")
	get_tree().quit()

func _build_stage() -> void:
	viewport = SubViewport.new()
	viewport.size = Vector2i(1000,700)
	viewport.own_world_3d = false
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(viewport)
	camera = Camera3D.new()
	camera.near = 0.03
	viewport.add_child(camera)
	camera.current = true

	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.055,0.06,0.075)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.72,0.76,0.88)
	env.ambient_light_energy = 0.75
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	world.environment = env
	add_child(world)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-48,-28,0)
	key.light_color = Color(1.0,0.82,0.65)
	key.light_energy = 2.2
	key.shadow_enabled = true
	add_child(key)
	var fill := OmniLight3D.new()
	fill.position = Vector3(0,0.7,0.5)
	fill.light_color = Color(0.45,0.62,1.0)
	fill.light_energy = 2.0
	fill.omni_range = 3.0
	add_child(fill)

	var cord := CORD.instantiate()
	add_child(cord)
	var nema := cord.get_node("WallPlug") as RigidBody3D
	var iec := cord.get_node("AppliancePlug") as RigidBody3D
	nema.freeze = true; iec.freeze = true
	nema.position = Vector3(-0.58,0.78,0)
	nema.rotation_degrees = Vector3(0,0,-18)
	iec.position = Vector3(0.58,0.78,0)
	iec.rotation_degrees = Vector3(0,0,18)

	# Matching inlet beside the cable-end close-up, rotated to face the camera.
	var inlet := MeshInstance3D.new()
	inlet.mesh = C14
	inlet.position = Vector3(0.75,0.78,0)
	add_child(inlet)

	# A matte pedestal makes the black molding and cable silhouette readable.
	var slab := MeshInstance3D.new()
	var box := BoxMesh.new(); box.size = Vector3(1.65,0.08,0.62)
	slab.mesh = box; slab.position = Vector3(0,-0.46,-0.08)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.24,0.26,0.31); mat.roughness = 0.88
	slab.material_override = mat
	add_child(slab)

func _shoot(name: String, eye: Vector3, target: Vector3, fov: float) -> void:
	camera.position = eye; camera.fov = fov
	camera.look_at(target,Vector3.UP)
	for i in 45: await get_tree().process_frame
	var image := viewport.get_texture().get_image()
	image.save_png("%s/%s.png" % [OUT,name])
