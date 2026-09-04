## RetroCartridge — pickable cartridge carrying a ROM file path.
## Must be in the "cartridge" group to snap into a RetroSystem's CartridgeSlot.
##
## Battery saves: each physical cartridge owns a persistent save identity
## (save_id). Its .srm lives at save/<core>/<game_stem>/<save_id>.srm — like a
## real cartridge, two copies of the same game hold independent saves. Files
## are NEVER deleted; the cartridge options panel can bind any existing .srm
## for this game back onto this cartridge (save recovery).
class_name RetroCartridge
extends XRToolsPickable


const OPTIONS_PANEL_SCENE := preload("res://Scenes/UI/cartridge_options_panel.tscn")
## A Satellaview memory pack spawns as a cartridge but is a medium, not a game,
## so it gets its own panel rather than one offering saves it cannot have.
const PACK_PANEL_SCENE := preload("res://Scenes/UI/bsx_pack_panel.tscn")

## The full path to the ROM file this cartridge represents
@export_global_file var rom_path: String = ""

## Display label (game name, shown on the cartridge face and in spawn menu)
@export var game_label: String = "":
	set(v):
		game_label = v
		_update_label()

## Persistent battery-save identity. Generated once at first _ready; restored
## from saves/snapshots so the cartridge keeps its .srm across sessions.
@export var save_id: String = ""

## The systemid this game belongs to (e.g. "nes"). Set by the spawn menu and
## back-filled when the cartridge is inserted into a console — used to resolve
## the core name for the save-recovery list.
@export var systemid: String = ""

var _options_panel: Node3D = null
var _pack_panel: BsxPackPanel = null

## Real per-system cartridge models. A system with no entry — or with its asset
## stripped from the build — silently keeps the procedural box.
const _CART_MODELS := {
	"nes": "res://imported-assets/carts/nes/nes_cart.glb",
	"atari_2600": "res://imported-assets/carts/atari_2600/atari_2600_cart.glb",
}

## Name of the model's swappable label face, which _apply_label_art covers with
## the scraped art. Kept as a constant so a model that names it something else
## can be special-cased without touching the lookup.
const _LABEL_MESH := "media_label"

## The model's own label face, when a real cart model is in use.
var _model_label: MeshInstance3D = null
# True while a handheld slot owns the shapes — see set_seated_grab_stub.
var _stub_seated := false


## The cabinet this cart is lying in, but only when its bay is a push tray. Null
## everywhere else, which is what keeps every other console's carts on plain
## click-to-take.
func push_tray_host() -> Node:
	if _grab_driver == null or not is_instance_valid(_grab_driver.primary):
		return null
	var zone := _grab_driver.primary.by as XRToolsSnapZone
	if zone == null:
		return null
	var host := zone.get_parent()
	if host != null and host.has_method("has_push_tray_bay") and host.has_push_tray_bay():
		return host
	return null


## True while a pushed-home tray is holding this cart down. Asked by every grab
## route BEFORE the socket lets go, because can_pick_up() cannot answer it: while a
## snap zone holds an object, that method answers "already held" whatever the
## object thinks, so a clamp expressed there would only be read once the zone had
## already released the cart.
func is_clamped() -> bool:
	var host := push_tray_host()
	return host != null and host.is_tray_down()


## The clamp again, for a route that reaches the cart directly rather than through
## the socket holding it.
func can_pick_up(by: Node3D) -> bool:
	if is_clamped():
		return false
	return super(by)


## Whether a click on this cart means something other than "pick me up" — true only
## while it is lying in a push tray. A cart on the floor, on a shelf, or in any
## ordinary bay answers false and is taken by a plain click, as everything else in
## the room is.
func desktop_click_available() -> bool:
	return push_tray_host() != null


## Desktop: a click on a cart lying in a push tray pushes it home, and a click on a
## pushed-home one lifts it back out. Pulling it out is the DRAG — see DesktopPickup.
func desktop_click_action() -> void:
	var host := push_tray_host()
	if host != null:
		host.toggle_cart_tray()


func _ready() -> void:
	if save_id.is_empty():
		save_id = "%08x%08x" % [randi(), randi()]
	_update_label()
	_apply_system_size()
	_apply_cart_model()
	_apply_label_art()
	picked_up.connect(_on_picked_up)
	dropped.connect(_on_dropped)


# ── e-Reader cards ────────────────────────────────────────────────────────────
#
# A dotcode card is spawned as a cartridge, but it is one to two strip FILES
# rather than one ROM. It carries the first strip in rom_path and finds the rest
# from the library, so nothing extra has to be saved for a card to come back
# whole after a restore.


## The card this is, or {} when it is an ordinary cartridge.
##
## CardSwipeSlit and RetroSystem both read this; the strip a swipe selects is an
## index into its `strips`.
func get_card_data() -> Dictionary:
	if systemid != EReaderCards.SYSTEMID:
		return {}
	return EReaderCards.card_for_path(rom_path)


## The body size for this card — portrait TCG or landscape e-Reader.
func get_card_size() -> Vector3:
	return MediaDimensions.cart_size(systemid, rom_path)


## Swap the procedural box for this system's real cartridge model when one ships.
##
## The GLB's body runs +Y from its connector with the label on +Z — the same
## frame the framework uses — so centring its AABB lands it correctly (connector
## -Y, grip +Y, label +Z) and everything downstream (snap pose, seated grab stub,
## insert animation) keeps working unchanged.
func _apply_cart_model() -> void:
	if _model_label != null or has_node("CartModel"):
		return
	var path: String = _CART_MODELS.get(systemid, "")
	if path.is_empty() or not ResourceLoader.exists(path):
		return
	var scene := load(path) as PackedScene
	if scene == null:
		return
	var glb := scene.instantiate() as Node3D
	glb.name = "CartModel"
	add_child(glb)
	var ab := _cart_model_aabb(glb)
	if ab.size.y <= 0.0001:
		return
	# Scale the (oversized) model to the system's real card dimensions, PER AXIS.
	# One uniform factor off width and height leaves depth to whatever proportions
	# the asset happens to have — the NES cart drew 12.2 mm against a real 17 — and
	# depth is the axis a bay's clearances are built on.
	var s := MediaDimensions.cart_size(systemid, rom_path)
	var k := Vector3(
		s.x / maxf(ab.size.x, 0.0001),
		s.y / maxf(ab.size.y, 0.0001),
		s.z / maxf(ab.size.z, 0.0001))
	glb.scale = k
	glb.position = -(ab.position + ab.size * 0.5) * k
	# Moulded plastic exported with a high metallicFactor reads as a dark mirror
	# rather than a grey shell — the NES cart ships metallic 0.76.
	ModelMaterialFix.demetal(glb)
	_model_label = glb.find_child(_LABEL_MESH, true, false) as MeshInstance3D
	# The procedural stand-ins are replaced by the real shell.
	for nm in ["CartridgeMesh", "LabelMesh", "GameLabel"]:
		var n := get_node_or_null(nm) as Node3D
		if n != null:
			n.visible = false


## Bounds of a cart model, in the GLB root's own space.
##
## Must compose the FULL chain to the root, not the mesh's own `transform`: a GLB
## exported straight from Sketchfab nests its meshes several levels deep
## (Sketchfab_model / *.fbx / RootNode / part / mesh), so reading one level gave a
## fraction of the real size and scaled the cart to two metres across.
func _cart_model_aabb(root: Node3D) -> AABB:
	var to_root := root.global_transform.affine_inverse()
	var acc := AABB()
	var first := true
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var ab: AABB = (to_root * mi.global_transform) * mi.get_aabb()
		acc = ab if first else acc.merge(ab)
		first = false
	return acc


## Bounds of the flat face of a model's label mesh, in cartridge space.
##
## A label mesh is not always the flat quad the art wants to cover — a printed
## label that wraps over the shell's top edge gives an AABB straddling the whole
## depth, with its centre buried in the plastic. Keeping only the polygons facing
## along the label normal leaves the flat front the sticker actually lives on.
## Either sign counts: some models have the quad's winding inverted, and the
## polygon lies in the label plane either way.
func _label_face_bounds(mi: MeshInstance3D) -> AABB:
	var xf := global_transform.affine_inverse() * mi.global_transform
	var full: AABB = xf * mi.get_aabb()
	var mesh := mi.mesh
	if mesh == null:
		return full
	var acc := AABB()
	var first := true
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays.size() <= Mesh.ARRAY_NORMAL:
			continue
		if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_NORMAL] == null:
			continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		if norms.size() != verts.size():
			continue
		for i in verts.size():
			if absf((xf.basis * norms[i]).normalized().z) < 0.95:
				continue
			var p := xf * verts[i]
			if first:
				acc = AABB(p, Vector3.ZERO)
				first = false
			else:
				acc = acc.expand(p)
	if first or acc.size.x < 0.0001 or acc.size.y < 0.0001:
		return full
	return acc


func _update_label() -> void:
	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl:
		lbl.text = game_label


## Resize the generic cartridge to this system's real-world dimensions
## (MediaDimensions.CART_SIZES). All mesh/shape resources are DUPLICATED before
## mutation — tscn sub_resources are shared across instances, so editing them
## in place would resize every cartridge in the room.
func _apply_system_size() -> void:
	if not MediaDimensions.has_cart_size(systemid):
		return
	var s := MediaDimensions.cart_size(systemid, rom_path)

	var body := get_node_or_null("CartridgeMesh") as MeshInstance3D
	if body and body.mesh is BoxMesh:
		var m := body.mesh.duplicate() as BoxMesh
		m.size = s
		body.mesh = m

	# The cart, exactly. This box is the RigidBody's own, so it is what the cart
	# RESTS on as well as what a hand grabs, and padding it puts the shell in the
	# air: a 7 mm Game Boy Advance cart inside a 40 mm box laid its label 16.5 mm
	# above the table it was supposedly lying on. Memory cards (memory_card.tscn,
	# 6 mm) have always matched their mesh here and are no harder to pick up,
	# because a hand's reach is XRToolsFunctionPickup's 125 mm grab sphere — the
	# old 25 mm of padding was ~10% of a reach that already dwarfed the card.
	# Aim padding, which a ray really does need, lives on PointerArea below.
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		var shape := col.shape.duplicate() as BoxShape3D
		shape.size = s
		col.shape = shape

	var label_mesh := get_node_or_null("LabelMesh") as MeshInstance3D
	if label_mesh and label_mesh.mesh is BoxMesh:
		var lm := label_mesh.mesh.duplicate() as BoxMesh
		if systemid == EReaderCards.SYSTEMID:
			# A dotcode card IS its printed face. There is no recessed sticker on
			# one, so a card given a cartridge's label region wears its own body
			# as a wide border no real card has.
			lm.size = Vector3(s.x, s.y, 0.0004)
			label_mesh.mesh = lm
			label_mesh.position = Vector3(0, 0, s.z / 2.0 + 0.0002)
			# And the body under it is card stock, not a moulded shell: any sliver
			# left by art of a different aspect should read as the card's margin.
			var card_body := get_node_or_null("CartridgeMesh") as MeshInstance3D
			if card_body != null:
				var bm := StandardMaterial3D.new()
				bm.albedo_color = Color(0.92, 0.90, 0.86)
				bm.roughness = 0.85
				card_body.set_surface_override_material(0, bm)
		else:
			lm.size = Vector3(s.x * 0.8, s.y * 0.62, 0.002)
			label_mesh.mesh = lm
			label_mesh.position = Vector3(0, s.y * 0.125, s.z / 2.0 + 0.001)

	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl:
		lbl.position = Vector3(0, s.y * 0.125, s.z / 2.0 + 0.0045)
		lbl.width = s.x * 2000.0

	# The AIM target keeps the padding, computed from the card rather than from the
	# grab box it used to be derived off. A ray has to be put on a 33 mm card edge-on
	# from across the room, and this StaticBody is 21:XRPointer with mask 0, so a
	# volume larger than the shell costs nothing physical. (It is pulled back to the
	# card itself the moment a machine is holding one — see _tighten_pointer_box.)
	var pointer_col := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pointer_col and pointer_col.shape is BoxShape3D:
		var pshape := pointer_col.shape.duplicate() as BoxShape3D
		pshape.size = Vector3(
			maxf(s.x, 0.05) + 0.04,
			maxf(s.y, 0.05) + 0.04,
			maxf(s.z + 0.025, 0.04))
		pointer_col.shape = pshape

	_apply_floppy_shell()


## A 3.5-inch disk instead of a moulded cartridge, for the machines that loaded
## from one (MediaDimensions.FLOPPY_SYSTEMS). The body is already the right slab
## by the time this runs — what is left is what tells a disk from a cart at a
## glance: black shell, sprung metal shutter on the leading edge, paper label.
##
## Called from the tail of _apply_system_size rather than once from _ready,
## because that runs again on every drop and after a handheld stub is released,
## and it would otherwise put the cartridge's chunky 2 mm sticker back on.
## Everything here is therefore idempotent.
##
## Fresh materials, never the scene's: cartridge.tscn's Mat_cart and Mat_label are
## shared sub_resources, so tinting one would repaint every cartridge in the room.
func _apply_floppy_shell() -> void:
	if not MediaDimensions.uses_floppy(systemid):
		return
	var s := MediaDimensions.cart_size(systemid, rom_path)

	# The shell and its shutter are built once; the Shutter node's absence is what
	# says this cartridge has not been through here yet.
	#
	# The shutter: 37 x 24 mm of stamped steel over the head window, a hair thicker
	# than the shell so it stands proud on both faces the way the real slider does.
	#
	# On +Y, the OPPOSITE end from a cartridge's connector, even though it is the
	# end that goes into the drive first. That is where a real disk has it, and the
	# three things a floppy shows cannot be satisfied any other way: hold one with
	# the label toward you and the title upright and the shutter is at the TOP, in
	# your fingers, pointing at the drive. Putting it at -Y instead forces the seat
	# basis to invert X to stay a rotation, which seats the disk with its title
	# mirrored. See FloppySeat in pc_tower.tscn.
	#
	# Metallic 0.45, not 1.0. No room in RetroXR has a reflection probe, so a fully
	# metallic material has nothing to mirror and renders as a dark hole; at 0.45
	# the diffuse term carries it and the specular still reads as bare metal.
	if get_node_or_null("Shutter") == null:
		var body := get_node_or_null("CartridgeMesh") as MeshInstance3D
		if body != null:
			var shell := StandardMaterial3D.new()
			shell.albedo_color = Color(0.12, 0.12, 0.14)
			shell.roughness = 0.55
			body.set_surface_override_material(0, shell)
		var shutter := MeshInstance3D.new()
		shutter.name = "Shutter"
		var sm := BoxMesh.new()
		sm.size = Vector3(0.037, 0.024, s.z + 0.0008)
		shutter.mesh = sm
		var smat := StandardMaterial3D.new()
		smat.albedo_color = Color(0.72, 0.73, 0.75)
		smat.metallic = 0.45
		smat.roughness = 0.28
		shutter.set_surface_override_material(0, smat)
		shutter.position = Vector3(0.0, s.y * 0.5 - 0.012, 0.0)
		add_child(shutter)

	# A paper sticker, not the cartridge's moulded-in label: the real 70 x 46 mm
	# one, 0.6 mm thick against a 3.3 mm disk. The generic label is 2 mm proud,
	# which on a slab this thin stands up like a second cartridge.
	#
	# Pushed against the trailing edge (-Y, away from the shutter), 4 mm short of
	# it, which is where the sticker goes and is what makes the disk read as one:
	# a seated disk shows only the half standing out of the drive, so a label
	# centred on the body would be the whole of what there is to see and the black
	# shell would never appear at all.
	#
	# Left alone once _apply_label_art has been there — it swaps the box for a
	# QuadMesh carrying the scraped art, and that is not ours to resize.
	var label_mesh := get_node_or_null("LabelMesh") as MeshInstance3D
	if label_mesh != null and label_mesh.mesh is BoxMesh:
		var lm := label_mesh.mesh.duplicate() as BoxMesh
		lm.size = Vector3(0.070, 0.046, 0.0006)
		label_mesh.mesh = lm
		label_mesh.position = Vector3(0.0, -s.y * 0.5 + 0.004 + lm.size.y * 0.5,
			s.z * 0.5 + 0.0003)
		var lmat := StandardMaterial3D.new()
		lmat.resource_local_to_scene = true
		lmat.albedo_color = Color(0.88, 0.86, 0.78)
		lmat.roughness = 0.85
		label_mesh.set_surface_override_material(0, lmat)
		var lbl := get_node_or_null("GameLabel") as Label3D
		if lbl != null:
			lbl.position = Vector3(label_mesh.position.x, label_mesh.position.y,
				label_mesh.position.z + 0.0007)
			lbl.width = lm.size.x * 2000.0


## Whoever has it decides how big a target it should be.
##
## Loose, it wants generous padding. Seated in a console's bay it does not: the
## pointer box is the grab box plus 40 mm, and the grab box is already the cart
## plus 25 mm through its thickness, which together leave it standing 1.9 mm above
## an NES deck across 149 x 161 mm — most of the top face. Every aim at the
## console then reached the cartridge first. Handhelds already had this treatment
## (see set_seated_grab_stub); a console bay never did.
func _on_picked_up(_p: Variant) -> void:
	if _stub_seated:
		return          # a handheld slot has already sized this for its mouth
	if _snap_zone_holder() != null:
		_tighten_pointer_box()


func _on_dropped(_p: Variant) -> void:
	if not _stub_seated:
		_apply_system_size()


func _snap_zone_holder() -> XRToolsSnapZone:
	if not is_picked_up():
		return null
	return get_picked_up_by() as XRToolsSnapZone


## Pointer target down to the cart itself, so nothing of it stands proud of the
## machine holding it. The GRAB box is untouched: it is on 17:XRHand_SnapZone,
## which no pointer ray queries, and hands want the padding.
func _tighten_pointer_box() -> void:
	if not MediaDimensions.has_cart_size(systemid):
		return
	var pcol := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pcol == null or not (pcol.shape is BoxShape3D):
		return
	var s := MediaDimensions.cart_size(systemid, rom_path)
	var shape := pcol.shape.duplicate() as BoxShape3D
	shape.size = s + Vector3(0.004, 0.004, 0.004)
	pcol.shape = shape
	pcol.position = Vector3.ZERO


## While seated in a handheld's recessed slot only the grip end pokes out of
## the body — limit grabbing (VR hands, desktop reticle, laser) to that stub.
## The normal grab padding (a ≥5 cm box around a 3.3 cm card) otherwise pokes
## through the thin shell and swallows clicks meant for the device itself.
## `depth` is the exposed length along the cart's +Y (grip) end.
func set_seated_grab_stub(depth: float) -> void:
	if not MediaDimensions.has_cart_size(systemid):
		return
	_stub_seated = true
	var s := MediaDimensions.cart_size(systemid, rom_path)
	var stub_center := Vector3(0, s.y / 2.0 - depth / 2.0, 0)
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col and col.shape is BoxShape3D:
		var shape := col.shape.duplicate() as BoxShape3D
		shape.size = Vector3(s.x, depth, s.z + 0.004)
		col.shape = shape
		col.position = stub_center
	var pcol := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pcol and pcol.shape is BoxShape3D:
		var pshape := pcol.shape.duplicate() as BoxShape3D
		# Keep the pointer target to the exposed stub. It used to pad +1 cm on
		# every axis, and that +1 cm of DEPTH pushed the grab volume ~6 mm past
		# the slot mouth toward the screen — so pointing at the console just above
		# a seated cart grabbed the cart. Match the grab box's depth (no bleed) and
		# only pad x/y a hair so the small stub is still targetable.
		pshape.size = Vector3(s.x + 0.004, depth + 0.002, s.z + 0.004)
		pcol.shape = pshape
		pcol.position = stub_center


## Restore the normal (padded) grab shapes after leaving a handheld slot.
func reset_grab_shapes() -> void:
	_stub_seated = false
	if not MediaDimensions.has_cart_size(systemid):
		return
	var col := get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col:
		col.position = Vector3.ZERO
	var pcol := get_node_or_null("PointerArea/CollisionShape3D") as CollisionShape3D
	if pcol:
		pcol.position = Vector3.ZERO
	_apply_system_size()


## A shell's moulded label face is blank, so with no art to put on it the title
## is all the cart has to say which game it is. The Label3D is authored against
## the procedural box, and the shell replaced that, so it has to be moved onto
## the shell's own label face — where the art would have gone.
func _title_on_model_face() -> void:
	if _model_label == null:
		return
	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl == null:
		return
	var ab := _label_face_bounds(_model_label)
	if ab.size.x <= 0.0001 or ab.size.y <= 0.0001:
		return
	var c := ab.get_center()
	lbl.position = Vector3(c.x, c.y, ab.position.z + ab.size.z + 0.0006)
	# Same 80%-of-the-face wrap width the procedural cart uses.
	lbl.width = ab.size.x * 2000.0
	lbl.visible = true


## Apply the scraped "support" label art onto the label face. Missing art keeps
## the existing generic label + title text fallback. Fresh material every time —
## never mutate the shared Mat_label sub_resource.
func _apply_label_art() -> void:
	var tex := MediaDimensions.load_label_texture(systemid, rom_path)
	if tex == null:
		_title_on_model_face()
		return
	# Real cart model: cover the model's own label face with a quad of our own
	# rather than repainting theirs.
	#
	# Painting onto the author's quad means inheriting the author's UVs, and
	# imported models agree on no convention at all — normals point in or out, u
	# runs across the card on one and up the face on another. The label plane is
	# a flat quad in the cart's XY facing +Z on all of them, so building a fresh
	# quad over it from its measured bounds is right by construction and stays
	# right for models not imported yet.
	if _model_label != null:
		var ab := _label_face_bounds(_model_label)
		if ab.size.x > 0.0001 and ab.size.y > 0.0001:
			_model_label.visible = false
			var art := MeshInstance3D.new()
			art.name = "ModelLabelArt"
			add_child(art)
			# Fit-within, so art of any aspect is never stretched to the recess.
			var recess_fit := Vector2(ab.size.x, ab.size.y)
			var ar := float(tex.get_width()) / maxf(float(tex.get_height()), 1.0)
			if recess_fit.x / maxf(recess_fit.y, 0.0001) > ar:
				recess_fit.x = recess_fit.y * ar
			else:
				recess_fit.y = recess_fit.x / ar
			var quad := QuadMesh.new()
			quad.size = recess_fit
			art.mesh = quad
			var c := ab.get_center()
			art.position = Vector3(c.x, c.y, ab.position.z + ab.size.z + 0.0003)
			var lm := StandardMaterial3D.new()
			lm.albedo_color = Color.WHITE
			lm.albedo_texture = tex
			art.set_surface_override_material(0, lm)
		var glbl := get_node_or_null("GameLabel") as Label3D
		if glbl != null:
			glbl.visible = false
		return
	var label_mesh := get_node_or_null("LabelMesh") as MeshInstance3D
	if label_mesh == null or not (label_mesh.mesh is BoxMesh):
		return
	# Fit-within: shrink one axis of the label region to the texture's aspect so
	# the art is never stretched (region set by _apply_system_size or the scene).
	var region := (label_mesh.mesh as BoxMesh).size
	var aspect := float(tex.get_width()) / maxf(float(tex.get_height()), 1.0)
	var fitted := Vector2(region.x, region.y)
	if region.x / maxf(region.y, 0.0001) > aspect:
		fitted.x = region.y * aspect
	else:
		fitted.y = region.x / aspect
	# QuadMesh, not BoxMesh: a BoxMesh atlases the texture across its six faces
	# (the front face would show only a crop). The quad faces +Z like the label.
	var qm := QuadMesh.new()
	qm.size = fitted
	label_mesh.mesh = qm
	label_mesh.position.z += region.z / 2.0 + 0.0002   # sit on the old face plane

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.albedo_texture = tex
	label_mesh.set_surface_override_material(0, mat)

	var lbl := get_node_or_null("GameLabel") as Label3D
	if lbl:
		lbl.visible = false


## Returns the ROM path — called by RetroSystem when the cartridge snaps in
func get_rom_path() -> String:
	return rom_path


## Toggle the floating save-management panel (mirrors PDFBook/VCR panels).
## Called by SpawnMenuController when the menu button is pressed while
## pointing at this cartridge.
func toggle_options_ui(camera: Node3D) -> void:
	# A Satellaview memory pack arrives here as an ordinary cartridge — the spawn
	# path builds one for any satellaview file that is not the BS-X shell — but it
	# is a MEDIUM, not a game. Saves, states and achievements are all meaningless
	# for it; what it holds is programmes across eight blocks of flash. Send it to
	# the panel that can say so.
	if BsxPack.is_pack_path(rom_path):
		var pack_panel := ensure_pack_panel()
		if pack_panel.visible:
			pack_panel.hide_panel()
		else:
			pack_panel.show_for(self, camera)
		return
	var panel := ensure_options_panel()
	if panel.visible:
		panel.hide_panel()
	else:
		panel.show_for(self, camera)


## The pack-contents panel, created on first use and parented here so it dies
## with the pack. Separate from _options_panel: a cartridge is one or the other
## for its whole life, so the unused one is never built.
func ensure_pack_panel() -> BsxPackPanel:
	if _pack_panel == null:
		_pack_panel = PACK_PANEL_SCENE.instantiate()
		add_child(_pack_panel)
	return _pack_panel


## The cartridge's options panel, created on first use.
##
## Public because the core options panel borrows it: while a cartridge is in a
## machine, its Cartridge tab is driven by this same panel, so a save selected
## from the console and one selected from the cartridge in your hand are the
## same act on the same state rather than two copies that can disagree.
func ensure_options_panel() -> CartridgeOptionsPanel:
	if _options_panel == null:
		_options_panel = OPTIONS_PANEL_SCENE.instantiate()
		add_child(_options_panel)
	return _options_panel
