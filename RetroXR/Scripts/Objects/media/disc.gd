## RetroDisc — pickable CD/DVD carrying a ROM (disc image) path, for disc-based
## consoles (PlayStation, GameCube, Dreamcast...). Extends RetroCartridge so it
## inherits the whole cartridge contract — CartridgeSlot snap-in ("cartridge"
## group), save_id battery-save identity, persistence file resolution, and the
## cartridge options panel — with a disc-shaped body instead of a box.
##
## The body is one baked lathe (Tools/gen/gen_disc.gd) shaded by Shaders/disc.gdshader,
## which draws both faces, the per-system underside colour and the diffraction
## rainbow from a single surface. Scraped "support" art (the round disc-label scan)
## goes straight into a shader uniform: it is authored full-bleed to the rim with
## its own transparent centre hole, so it needs no fitting and no quad of its own.
## Without art the disc shows the game title as flat text, like a written-on CD-R.
class_name RetroDisc
extends RetroCartridge

## One mesh per diameter rather than one scaled mesh: the 15 mm hole and the 1.2 mm
## thickness are identical at every size, so scaling would shrink them along with
## the disc. Keyed by diameter and matched to the NEAREST — a diameter with no
## mesh warns rather than silently getting a platter of the wrong size.
const MESH_120 := preload("res://Scenes/Objects/media/disc_120mm.res")
const MESH_80 := preload("res://Scenes/Objects/media/disc_80mm.res")
const MESH_64 := preload("res://Scenes/Objects/media/disc_64mm.res")

const PLATTERS: Dictionary = {
	0.12: MESH_120,
	0.08: MESH_80,
	0.064: MESH_64,
}


## Whether the host should visually spin this disc while it plays (system.gd's
## _update_disc_spin rotates the whole node about its local Y — correct for a
## round CD/mini-disc, since the visible geometry IS the spinning platter, but
## wrong for a disc enclosed in an opaque caddy, where the real platter isn't
## visible from outside anyway). True for every disc except an override says
## otherwise (see RetroUMD).
func can_visually_spin() -> bool:
	return true


## The baked platter closest to this diameter. A miss beyond a couple of
## millimetres means a system was added to DISC_DIAMETERS without a mesh to go
## with it, which would otherwise show up as a disc quietly rendered at the wrong
## size — so it warns instead.
func _platter_for(d: float) -> ArrayMesh:
	var best: ArrayMesh = MESH_120
	var best_err := INF
	for dia: float in PLATTERS:
		var err: float = absf(dia - d)
		if err < best_err:
			best_err = err
			best = PLATTERS[dia]
	if best_err > 0.002:
		push_warning("RetroDisc: no platter mesh for %.3f m (%s); using nearest"
			% [d, systemid])
	return best


## Fit the disc to this system: the right platter mesh, and the finish uniforms
## that make a PS1 disc black, a PS2 CD blue and a Wii disc a silver DVD.
##
## The ShaderMaterial is resource_local_to_scene, so the override fetched here is
## this disc's own copy — .tscn sub_resources are otherwise shared across every
## instance in the room.
func _apply_system_size() -> void:
	var d := MediaDimensions.disc_diameter(systemid)

	var body := get_node_or_null("DiscMesh") as MeshInstance3D
	if body != null:
		body.mesh = _platter_for(d)
		var mat := body.get_surface_override_material(0) as ShaderMaterial
		if mat != null:
			var finish := MediaDimensions.disc_finish(systemid, rom_path)
			mat.set_shader_parameter("data_color", finish["data"])
			mat.set_shader_parameter("poly_color", finish["poly"])
			mat.set_shader_parameter("poly_alpha", finish["alpha"])
			mat.set_shader_parameter("track_pitch", finish["pitch"])
			# A DVD's finer pitch spreads the orders apart until the fourth is
			# unreachable — see irid_orders in the shader. Three is lossless
			# (verified byte-identical at grazing); two is not.
			mat.set_shader_parameter("irid_orders",
				3 if float(finish["pitch"]) < 1.0 else 4)
			# save_id is already a random hex per disc, so it is a free seed.
			# Without it every disc of a system is pixel-identical, and a stack
			# of them reads as cloned.
			mat.set_shader_parameter("disc_seed",
				float(hash(save_id) % 1000) / 1000.0)
			var zones := MediaDimensions.disc_zones(systemid, finish["pitch"])
			mat.set_shader_parameter("r_metal_start", zones.x)
			mat.set_shader_parameter("r_data_start", zones.y)
			mat.set_shader_parameter("r_data_end", zones.z)

	# Duplicates before mutating: the tscn's shapes are shared across instances.
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is CylinderShape3D:
		var shape := col.shape.duplicate() as CylinderShape3D
		shape.radius = d / 2.0 + 0.005
		col.shape = shape

	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl:
		lbl.width = d * 1600.0

	var pointer_col := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pointer_col and pointer_col.shape is CylinderShape3D:
		var pshape := pointer_col.shape.duplicate() as CylinderShape3D
		pshape.radius = d / 2.0 + 0.02
		pointer_col.shape = pshape


## Hand the scraped label scan — or, on a Wii with none, WiiDiscLabel's print
## template — to the shader, which composites it into the label face's albedo:
## opaque, so unlike a transparent quad it sorts correctly, writes depth and
## takes the pickable outline. The art's own alpha is the print mask, including
## its centre hole, so nothing here masks or resizes it.
func _apply_label_art() -> void:
	var tex := MediaDimensions.load_label_texture(systemid, rom_path)
	var lbl := get_node_or_null("GameLabel") as Label3D
	if tex != null:
		_set_label_tex(tex)
		if lbl:
			lbl.visible = false
		return
	if systemid != "wii":
		return
	_set_label_tex(WiiDiscLabel.TEXTURE)
	if lbl:
		WiiDiscLabel.fit_title(lbl, MediaDimensions.disc_diameter(systemid))


func _set_label_tex(tex: Texture2D) -> void:
	var body := get_node_or_null("DiscMesh") as MeshInstance3D
	if body == null:
		return
	var mat := body.get_surface_override_material(0) as ShaderMaterial
	if mat == null:
		return
	mat.set_shader_parameter("label_tex", tex)


## The world basis this disc had when the hand let go of it. A bay cannot read
## that off the disc when it accepts one: the snap zone has already re-posed the
## body to its own grab point by the time has_picked_up fires, so the hand's
## heading is gone one call earlier than the bay ever runs.
var _release_basis := Basis.IDENTITY


func let_go(by: Node3D, p_linear_velocity: Vector3, p_angular_velocity: Vector3) -> void:
	# A snap zone handing the disc on is not a hand letting go of it, and it lets
	# go from its OWN grab point: a bay drops the zone's grab before it seats, so
	# recording that release would overwrite the heading with the zone's every
	# time and the disc would always come up square.
	if not (by is XRToolsSnapZone):
		_release_basis = global_basis.orthonormalized()
	super(by, p_linear_velocity, p_angular_velocity)


## The heading the hand released it at, in the frame of `bay`.
func release_basis_in(bay: Node3D) -> Basis:
	return bay.global_basis.orthonormalized().inverse() * _release_basis


## The basis a bay should seat `media` at, given its authored seat basis `seat`
## and the basis the hand released it at, in the bay's own frame. A round platter
## is symmetric about its spin axis, so it is seated with the spin the hand was
## holding it at rather than snapped to one heading; anything else (a tape, a
## disc in an opaque caddy) seats exactly as authored.
static func seat_basis(seat: Basis, media: Node3D, bay: Node3D) -> Basis:
	var disc := media as RetroDisc
	if disc == null or not disc.can_visually_spin():
		return seat
	var m := (seat.inverse() * disc.release_basis_in(bay)).orthonormalized()
	return seat * Basis(Vector3.UP, atan2(-m.x.z, m.x.x))
