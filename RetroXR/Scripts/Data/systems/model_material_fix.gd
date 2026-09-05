## ModelMaterialFix — repairs PBR values that survive the Unity -> glTF trip but
## are wrong for Godot's renderer.
##
## Two keep showing up, and both read as bugs in the room rather than as material
## choices:
##
##   - `emissiveFactor = [1,1,1]` with **no** emissive texture. Unity treats that
##     as "emission off, tint unused"; glTF/Godot take it literally and the whole
##     shell self-illuminates. The Arctic White Game Boy Advance glowed like a
##     lightbulb because of this one value.
##   - `metallicFactor = 1.0` on moulded plastic. The GameCube pad's shell and
##     buttons both ship this, which turns matte purple ABS into a mirror.
##
## Both helpers DUPLICATE the material before touching it. GLB materials are
## shared across every instance of the scene, so mutating in place would restyle
## every copy of the model in the room.
##
## Typed on BaseMaterial3D, not StandardMaterial3D: a GLB with packed
## occlusion/roughness/metalness imports as **ORMMaterial3D**, which is a sibling
## class, so a StandardMaterial3D check silently skips exactly the models most
## likely to need fixing.
class_name ModelMaterialFix
extends RefCounted


## Turn off self-illumination on materials that declare emission but ship no
## emissive texture to shape it. Returns the number of surfaces changed.
static func strip_emission(root: Node) -> int:
	return _walk(root, func(m: BaseMaterial3D) -> bool:
		if not m.emission_enabled or m.emission_texture != null:
			return false
		m.emission_enabled = false
		return true)


## Drop metallic to `value` on materials with no metallic map — plastic that was
## authored (or converted) as a pure metal. Returns surfaces changed.
static func demetal(root: Node, value: float = 0.0) -> int:
	return _walk(root, func(m: BaseMaterial3D) -> bool:
		if m.metallic_texture != null or is_equal_approx(m.metallic, value):
			return false
		m.metallic = value
		return true)


## Turn on alpha cutout for textured decal quads whose texture actually carries
## alpha. Converted models routinely leave these OPAQUE, so a logo authored as
## art-on-transparent renders as art on a solid black rectangle — the NES
## controller wore a black box around its Nintendo wordmark. Returns surfaces
## changed.
static func enable_decal_alpha(root: Node) -> int:
	return _walk(root, func(m: BaseMaterial3D) -> bool:
		if m.albedo_texture == null or m.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			return false
		var img := m.albedo_texture.get_image()
		if img == null or img.detect_alpha() == Image.ALPHA_NONE:
			return false
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		m.alpha_scissor_threshold = 0.5
		return true)


## Mirror a decal's UV. Some decal quads are authored facing INTO the shell and
## only show at all because culling is disabled, so what you see is the back of
## the art — the NES controller's wordmark read "obnetniN".
##
## `axis` must be named per model rather than inferred. These quads do not agree
## on which UV axis runs across the art: flipping `u` on the NES wordmark rotates
## it 180 degrees instead of mirroring it, because there `u` runs up the face.
## Pick the axis by looking at a render, not by reasoning about the normal — that
## is the same trap that made a UV-winding rule impossible for cart labels.
static func mirror_uv(root: Node, mesh_name: String, axis: String = "v") -> bool:
	var mi := root.find_child(mesh_name, true, false) as MeshInstance3D
	if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0:
		return false
	var src: Material = mi.get_active_material(0)
	if not (src is BaseMaterial3D):
		return false
	var dup := (src as BaseMaterial3D).duplicate() as BaseMaterial3D
	var s := dup.uv1_scale
	dup.uv1_scale = Vector3(-s.x, s.y, s.z) if axis == "u" else Vector3(s.x, -s.y, s.z)
	mi.set_surface_override_material(0, dup)
	return true


static func _walk(root: Node, fix: Callable) -> int:
	var n := 0
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mi := node as MeshInstance3D
		if mi.mesh == null:
			continue
		for i in range(mi.mesh.get_surface_count()):
			var src: Material = mi.get_active_material(i)
			if not (src is BaseMaterial3D):
				continue
			var dup := (src as BaseMaterial3D).duplicate() as BaseMaterial3D
			if fix.call(dup):
				mi.set_surface_override_material(i, dup)
				n += 1
	return n
