extends Node

# No room load, headset, or preference writes. Exercise the real tree lifecycle.
var _fail := 0
var _checks := 0


func _ready() -> void:
	get_tree().create_timer(15.0).timeout.connect(func() -> void: get_tree().quit(1))
	var room := Node3D.new()
	add_child(room)
	var lighting := PropLighting.new()
	room.add_child(lighting)
	var src := StandardMaterial3D.new()
	src.uv1_scale = Vector3(6, 6, 1)
	src.uv1_offset = Vector3(0.25, 0.5, 0)
	var first := _mesh(src)
	room.add_child(first)
	var volume := {"irr": null, "dir": null, "min": Vector3.ZERO, "size": Vector3.ONE}
	lighting._start(room, load(PropLighting.PROP_SHADER), volume)
	var replacement := first.get_surface_override_material(0) as ShaderMaterial
	_check(replacement != null, "existing opaque mesh converted")
	_check(replacement.get_shader_parameter("uv1_scale") == src.uv1_scale,
		"texture tiling preserved")
	_check(replacement.get_shader_parameter("uv1_offset") == src.uv1_offset,
		"texture offset preserved")

	var spawned := _mesh(src)
	room.add_child(spawned)
	await get_tree().process_frame
	_check(spawned.get_surface_override_material(0) == replacement,
		"late spawn converted and shares material")
	volume = volume.duplicate()
	volume["min"] = Vector3(2, 3, 4)
	lighting._on_volume_changed(volume)
	var restored := _mesh(src)
	room.add_child(restored)
	await get_tree().process_frame
	_check(restored.get_surface_override_material(0).get_shader_parameter("gi_min") == volume["min"],
		"new spawn uses latest lighting volume")

	var effect := ShaderMaterial.new()
	effect.shader = Shader.new()
	effect.shader.code = "shader_type spatial; void fragment() { ALBEDO = vec3(1.0); }"
	var custom := _mesh(src)
	room.add_child(custom)
	# Mimics parent/model _ready setup after node_added, before deferred conversion.
	custom.set_surface_override_material(0, effect)
	var led := _mesh(src)
	room.add_child(led)
	var led_mat := StandardMaterial3D.new()
	led.set_surface_override_material(0, led_mat)
	var override_mesh := _mesh(src)
	override_mesh.material_override = effect
	room.add_child(override_mesh)
	var exterior := _mesh(src)
	exterior.layers = 2
	room.add_child(exterior)
	var unrelated := _mesh(src)
	add_child(unrelated)
	var fading := src.duplicate() as StandardMaterial3D
	fading.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	var transparent := _mesh(fading)
	room.add_child(transparent)
	var crisp := src.duplicate() as StandardMaterial3D
	crisp.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	var pixel_art := _mesh(crisp)
	room.add_child(pixel_art)
	var removed_early := _mesh(src)
	room.add_child(removed_early)
	room.remove_child(removed_early)
	removed_early.free()
	await get_tree().process_frame
	_check(custom.get_surface_override_material(0) == effect, "authored shader override survives")
	led_mat.albedo_color = Color.RED
	_check(led.get_active_material(0) == led_mat, "runtime material owner retains control")
	_check(override_mesh.get_surface_override_material(0) == null,
		"whole-mesh override respected")
	_check(exterior.get_surface_override_material(0) == null, "exterior excluded")
	_check(unrelated.get_surface_override_material(0) == null, "other rooms excluded")
	_check(transparent.get_surface_override_material(0) == null, "transparent material preserved")
	_check(pixel_art.get_surface_override_material(0) == null, "nearest texture filtering preserved")

	room.remove_child(spawned)
	_check(spawned.get_surface_override_material(0) == null, "leaving room restores source material")
	room.add_child(spawned)
	await get_tree().process_frame
	_check(spawned.get_surface_override_material(0) == replacement, "reentering room converts again")
	var transient := _mesh(StandardMaterial3D.new())
	room.add_child(transient)
	await get_tree().process_frame
	var transient_mat: WeakRef = weakref(transient.get_surface_override_material(0))
	transient.free()
	_check(transient_mat.get_ref() == null, "despawn releases replacement material")
	lighting.free()
	_check(first.get_surface_override_material(0) == null, "removing lighting restores surviving props")
	_check(custom.get_active_material(0) == effect, "cleanup preserves script-owned material")
	room.free()
	unrelated.free()
	print("[test] %d checks, %d failures" % [_checks, _fail])
	get_tree().quit(1 if _fail else 0)


func _mesh(material: Material) -> MeshInstance3D:
	var out := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.material = material
	out.mesh = box
	return out


func _check(ok: bool, label: String) -> void:
	_checks += 1
	if not ok:
		_fail += 1
	print("[test] %s %s" % ["PASS" if ok else "FAIL", label])
