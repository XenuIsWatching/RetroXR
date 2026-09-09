## PS2IconView — one PlayStation 2 save's icon, rendered as the 3-D model it is.
##
## Every other family draws a save with a small bitmap and the row holds a
## TextureRect. A PS2 save carries a lit, textured, morph-animated mesh instead,
## so its row holds one of these: a SubViewport with its own little world, a
## camera framed to whatever the model turns out to occupy, and the animation the
## icon itself specifies.
##
## Geometry comes from PS2Icon as plain arrays; nothing here parses anything. The
## split is deliberate — the parser is testable headless, and this is not, since
## a SubViewport that updates every frame hangs a headless run outright.
class_name PS2IconView
extends SubViewportContainer

## Rebuilding the vertex array is the expensive part, so the morph runs at a rate
## the eye accepts rather than at the display's. The PS2's own icons are slow,
## looping things; nothing here needs sixty steps a second.
const MORPH_HZ := 12.0

## What a model with no animation of its own turns at, so a still icon is still
## legibly three-dimensional rather than looking like a flat sprite.
const IDLE_SPIN_DEG := 28.0

var _viewport: SubViewport
var _mesh_inst: MeshInstance3D
var _pivot: Node3D
var _model: Dictionary = {}
var _base: PackedVector3Array
var _time := 0.0
var _next_morph := 0.0
var _animated := false


func _init() -> void:
	stretch = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Build the little world. `px` is the square size of the render target; the
## container's own size is whatever the row gives it.
func show_model(model: Dictionary, px := 96) -> void:
	_model = model
	if _model.is_empty():
		return
	_build(px)
	_apply_pose(0.0)


func _build(px: int) -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(px, px)
	_viewport.own_world_3d = true
	_viewport.transparent_bg = true
	_viewport.msaa_3d = Viewport.MSAA_4X
	# A SubViewport set to update every frame has nothing to service it in a
	# headless run and hangs it. Anything that renders here has a display.
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED \
		if DisplayServer.get_name() == "headless" \
		else SubViewport.UPDATE_ALWAYS
	add_child(_viewport)

	var world := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CANVAS
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.47, 0.55)
	env.ambient_light_energy = 1.0
	world.environment = env
	_viewport.add_child(world)

	# icon.sys carries its own three-light rig and RetroXR does not read it: the
	# saves worth looking at are lit acceptably by a key and a fill, and reading
	# a per-save rig would make one icon dark for reasons the player cannot see.
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-35, -40, 0)
	key.light_energy = 1.6
	_viewport.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-10, 150, 0)
	fill.light_energy = 0.5
	_viewport.add_child(fill)

	_pivot = Node3D.new()
	_viewport.add_child(_pivot)

	_mesh_inst = MeshInstance3D.new()
	_pivot.add_child(_mesh_inst)

	var shapes: Array = _model.get("shapes", [])
	_base = shapes[0] if not shapes.is_empty() else PackedVector3Array()
	_animated = shapes.size() > 1 and not (_model.get("frames", []) as Array).is_empty()

	var cam := Camera3D.new()
	# Added to the tree BEFORE it is aimed: look_at on a node that is not in the
	# tree yet fails with a message and leaves the camera pointing wherever it
	# started, which looks like a badly framed model rather than an error.
	_viewport.add_child(cam)
	_frame_camera(cam)
	# make_current() does not work inside a SubViewport; the flag does.
	cam.current = true


## Point the camera at whatever this model actually occupies. Icons are authored
## in fixed point over a range no two of them agree on, so a fixed camera frames
## some of them and misses others entirely.
func _frame_camera(cam: Camera3D) -> void:
	var lo := Vector3.INF
	var hi := -Vector3.INF
	for v in _base:
		lo = lo.min(v)
		hi = hi.max(v)
	if lo == Vector3.INF:
		lo = Vector3.ZERO
		hi = Vector3.ONE
	var centre := (lo + hi) * 0.5
	var radius := maxf((hi - lo).length() * 0.5, 0.001)
	_pivot.position = -centre
	cam.position = Vector3(0, radius * 0.35, radius * 3.0)
	cam.look_at(Vector3(0, 0, 0), Vector3.UP)
	cam.fov = 40.0
	cam.near = radius * 0.01


func _process(delta: float) -> void:
	if _viewport == null:
		return
	_time += delta
	if not _animated:
		# Nothing to morph: turn it slowly instead, which costs one rotation.
		_pivot.rotation_degrees.y = fmod(_time * IDLE_SPIN_DEG, 360.0)
		return
	if _time < _next_morph:
		return
	_next_morph = _time + 1.0 / MORPH_HZ
	_apply_pose(_time)


## The model at time t: every animated shape mixed by the weight its own key
## list gives it. This is what the PS2 does — the shapes are morph targets over
## one topology, not separate models.
func _apply_pose(t: float) -> void:
	if _base.is_empty():
		return
	var shapes: Array = _model.get("shapes", [])
	var frames: Array = _model.get("frames", [])
	var verts := PackedVector3Array()

	if not _animated:
		verts = _base
	else:
		verts.resize(_base.size())
		var length := maxf(float(_model.get("frame_length", 0)), 1.0)
		var at := fmod(t * MORPH_HZ, length)
		var total := 0.0
		var weights: Array[float] = []
		weights.resize(shapes.size())
		for f: Dictionary in frames:
			var id := int(f.get("shape_id", 0))
			if id < 0 or id >= shapes.size():
				continue
			var w := _weight_at(f.get("keys", PackedVector2Array()), at)
			weights[id] = weights[id] + w
			total += w
		if total <= 0.0:
			verts = _base
		else:
			for i in verts.size():
				var acc := Vector3.ZERO
				for s in shapes.size():
					if weights[s] == 0.0:
						continue
					acc += (shapes[s] as PackedVector3Array)[i] * weights[s]
				verts[i] = acc / total

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var uvs: PackedVector2Array = _model.get("uvs", PackedVector2Array())
	if uvs.size() == verts.size():
		arrays[Mesh.ARRAY_TEX_UV] = uvs
	var colors: PackedColorArray = _model.get("colors", PackedColorArray())
	if colors.size() == verts.size():
		arrays[Mesh.ARRAY_COLOR] = colors
	var normals: PackedVector3Array = _model.get("normals", PackedVector3Array())
	if normals.size() == verts.size():
		arrays[Mesh.ARRAY_NORMAL] = normals

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_inst.mesh = mesh
	_mesh_inst.material_override = _material()


func _weight_at(keys: PackedVector2Array, at: float) -> float:
	if keys.is_empty():
		return 0.0
	if keys.size() == 1 or at <= keys[0].x:
		return keys[0].y
	for i in range(1, keys.size()):
		if at <= keys[i].x:
			var span := keys[i].x - keys[i - 1].x
			if span <= 0.0:
				return keys[i].y
			var f := (at - keys[i - 1].x) / span
			return lerpf(keys[i - 1].y, keys[i].y, f)
	return keys[keys.size() - 1].y


var _mat: StandardMaterial3D = null

func _material() -> StandardMaterial3D:
	if _mat != null:
		return _mat
	_mat = StandardMaterial3D.new()
	_mat.vertex_color_use_as_albedo = true
	# An icon is a closed-ish shell authored without a consistent winding, and a
	# back-face cull turns several of them into a handful of stray triangles.
	_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_mat.roughness = 0.55
	var img: Image = _model.get("texture")
	if img != null:
		_mat.albedo_texture = ImageTexture.create_from_image(img)
		_mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	return _mat
