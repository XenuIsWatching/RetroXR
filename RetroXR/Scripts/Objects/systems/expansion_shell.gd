## ExpansionShell — the procedural face of an expansion unit.
##
## An expansion has no scene of its own: its body is a measured box out of
## ExpansionCatalog and everything on that box is placed from the same
## dimensions. This file holds that placement work — the mouths cut into the
## case, the OPEN button, the lid, and the three measurements that decide where
## the button and the tray deck sit.
##
## Static, and a total function of its arguments: nothing here reads a unit's
## state. That is the whole reason it is a separate file — RetroExpansion was
## carrying two hundred lines that never touched `_host`, `_media`, `_bay` or
## anything on XRToolsPickable, so they were geometry sitting in a machine.
## ExpansionPort next door is the same shape and the same idea.
class_name ExpansionShell
extends RefCounted

## How thick the dark plate that marks a roof well is.
const WELL_THICKNESS := 0.01

## The dark of a mouth cut into a case, shared by the slit and the well.
const MOUTH_COLOUR := Color(0.03, 0.03, 0.04)


## The slit in the front face that media slides through.
##
## Cut to the media, not to the box: a slot loader's mouth is as wide and as
## tall as the disk that goes through it, so the disk does not appear to pass
## through a letterbox narrower than itself.
static func build_slit(body: Node3D, s: Vector3, media: String) -> void:
	var slit := MeshInstance3D.new()
	slit.name = "SlitMouth"
	var mesh := BoxMesh.new()
	var m := MediaDimensions.cart_size(media)
	mesh.size = Vector3(m.x + 0.004, m.z + 0.003, 0.008)
	slit.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = MOUTH_COLOUR
	slit.set_surface_override_material(0, mat)
	body.add_child(slit)
	slit.position = Vector3(0.0, -s.y * 0.2, s.z * 0.5 - 0.002)


## The groove across the roof that a swiped card is drawn through.
##
## Open at both ends, unlike build_slit's mouth: a card goes in one side and comes
## out the other, so the groove runs the full width of the case rather than being
## a pocket cut into one face. Cut to the card's THICKNESS, not its height — only
## the coded edge is down in the groove and the body of the card stands proud.
##
## Returns the groove's centre in `body` space, which is where the slit's Area3D
## and its travel axis are anchored.
static func build_through_slot(body: Node3D, s: Vector3, card: Vector3) -> Vector3:
	var groove := MeshInstance3D.new()
	groove.name = "SwipeGroove"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(s.x, 0.006, card.z + 0.003)
	groove.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = MOUTH_COLOUR
	groove.set_surface_override_material(0, mat)
	body.add_child(groove)
	var centre := Vector3(0.0, s.y * 0.5 - 0.003, 0.0)
	groove.position = centre
	return centre


## The mouth in the roof that media drops into.
##
## Cut to the MEDIA, not to a fraction of the box -- the same rule the front slit
## already followed. A fixed 0.7 x 0.55 of the footprint gave the 32X a wide
## rectangular pit where a cartridge slot belongs: a cart stands upright in it, so
## the mouth it goes through is as wide as the cart and only as deep as the cart
## is THICK, which is a 104 x 19 mm letterbox rather than a 105 x 77 mm hole.
##
## A tray unit is sized from the disc instead, and by its LOADER rather than by
## its media systemid -- the Jaguar CD's media is "atari_jaguar", whose cart_size
## is a Jaguar CARTRIDGE, so asking the media what shape it is would cut a
## cartridge slot in a CD machine.
## `x_offset` moves the mouth off centre, for a unit with more than one well. It
## defaults to the centre, so every single-bay caller is unchanged -- and it has
## to exist at all because the snap zone and this mesh are placed INDEPENDENTLY.
## Moving the zone alone gives a unit that catches a cartridge where there is no
## visible hole, and draws a hole where nothing can be put.
static func build_well(body: Node3D, s: Vector3, media: String, loader: int,
		x_offset := 0.0) -> void:
	var well := MeshInstance3D.new()
	well.name = "WellMouth" if is_zero_approx(x_offset) \
		else "WellMouth%s" % ("L" if x_offset < 0.0 else "R")
	var mat := StandardMaterial3D.new()
	mat.albedo_color = MOUTH_COLOUR

	if loader == MediaDimensions.LOADER_TRAY:
		# Round, because a disc is. A box here read as a hatch rather than a well.
		var disc := CylinderMesh.new()
		var r: float = MediaDimensions.disc_diameter(media) * 0.5 + 0.003
		disc.top_radius = r
		disc.bottom_radius = r
		disc.height = WELL_THICKNESS
		well.mesh = disc
	else:
		var mesh := BoxMesh.new()
		var m := MediaDimensions.cart_size(media)
		mesh.size = Vector3(m.x + 0.004, WELL_THICKNESS, m.z + 0.004)
		well.mesh = mesh
	well.set_surface_override_material(0, mat)
	body.add_child(well)
	# A fifth of a millimetre PROUD of the roof.
	#
	# Flush -- which is what s.y * 0.5 - 0.005 gave -- put the well's top face in
	# exactly the plane of the body's, and two coplanar faces have no depth
	# order, so the renderer picks per pixel and the roof shimmers. Sinking it
	# instead fixed the shimmer by hiding the well altogether: it is a solid dark
	# box, and a solid dark box a millimetre inside an opaque body cannot be seen
	# at all, which is a cartridge slot you cannot find. Standing it a hair proud
	# breaks the tie the other way and leaves it visible, the same trick the
	# connector plate uses.
	well.position = Vector3(x_offset, s.y * 0.5 + 0.0002 - WELL_THICKNESS * 0.5, 0.0)


## Where a drawer unit's tray deck sits on its front face -- below the middle,
## clear of the nameplate the unit carries high on that face.
static func deck_y(s: Vector3) -> float:
	return -s.y * 0.16


## The OPEN button's height. `drawer` is true on a tray unit that runs a
## ProceduralDiscBay rather than a lid.
##
## Level with the tray deck on a drawer unit, so the two read as one row of
## controls rather than a button stranded above a mouth.
##
## HIGH on a unit that mounts as a cartridge. Two things are in the way down
## below: the console's own front panel, which this unit is standing directly on
## top of, and the unit's own nameplate, which sits in the bottom 20 mm of its
## face (_build_body puts it at -s.y * 0.5 + 10 mm on a top-mounting unit). At
## the old height the word OPEN ran into the lettering.
static func eject_y(s: Vector3, mount: int, drawer: bool) -> float:
	if drawer:
		return deck_y(s)
	if mount == ExpansionCatalog.MOUNT_CARTRIDGE:
		return s.y * 0.18
	return -s.y * 0.18


## And its distance out from the centre.
##
## CENTRED on a unit that mounts as a cartridge. It sits on the console's roof
## with its front face flush above the console's own, so a button off to one
## side lands directly over whatever the console keeps there -- on the machines
## these attach to, that is START, and the console's button covered the unit's.
## The middle of a small unit's face is the one place nothing below it competes
## for.
##
## On a drawer unit it is measured from the MOUTH rather than taken as a
## fraction of the box: the mouth is as wide as a disc plus its bezel however
## narrow the machine is, so a fixed fraction put the button through the tray on
## the smaller units (the CD-ROM2 is 60 mm narrower than the Mega-CD and the
## mouth is the same size on both).
static func eject_x(s: Vector3, mount: int, drawer: bool, media: String) -> float:
	if not drawer:
		if mount == ExpansionCatalog.MOUNT_CARTRIDGE:
			return 0.0
		return s.x * 0.30
	var mouth_half := (MediaDimensions.disc_diameter(media) + 0.020) * 0.5
	# Clamped inside the case, so a machine too narrow to fit the button beside
	# its own tray puts it as far out as it can rather than off the edge.
	return minf(mouth_half + 0.018, s.x * 0.5 - 0.016)


## The OPEN button on a disc unit's front face, at `pos`, calling `on_press`.
##
## Built rather than authored because these units have no scene of their own --
## the body is a measured box and everything on it is placed from ExpansionCatalog
## dimensions. Same widget the consoles use, so it highlights, depresses and
## takes a trigger press identically.
static func build_eject_button(parent: Node3D, pos: Vector3, on_press: Callable, text: String = "OPEN") -> void:
	var eject := VRButton.new()
	eject.name = "EjectButton"
	eject.position = pos
	# A button on the FRONT face travels into that face. The default axis is
	# (0,-1,0), which is right for the cabinet buttons on a console's roof and
	# wrong here: the cap sank downwards out of its own bezel instead of pressing
	# in.
	eject.depress_axis = Vector3(0.0, 0.0, -1.0)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.026, 0.012, 0.010)
	shape.shape = box
	eject.add_child(shape)

	# Named ButtonMesh and attached BEFORE the button enters the tree, so
	# VRButton's own `@onready var _mesh := $ButtonMesh` finds it.
	#
	# This used to add the cap after add_child and then call set_button_mesh on
	# it, which is why no OPEN button was visible on the Mega-CD or the Jaguar CD:
	# set_button_mesh HIDES the node called "ButtonMesh" before adopting the one
	# it is handed, because every other caller hands it a cap off an imported
	# shell and wants the scene's placeholder gone. Here the placeholder and the
	# cap were the same node, so it hid the mesh it was adopting. Building it the
	# ordinary way -- the way every authored button in system.tscn is built --
	# removes the call entirely and keeps state_tint, so the cap still lights on
	# hover like the console's own buttons.
	var mesh := MeshInstance3D.new()
	mesh.name = "ButtonMesh"
	var bm := BoxMesh.new()
	bm.size = Vector3(0.024, 0.010, 0.008)
	mesh.mesh = bm
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.16, 0.16, 0.18)
	mat.roughness = 0.5
	mesh.set_surface_override_material(0, mat)
	eject.add_child(mesh)

	var label := Label3D.new()
	label.text = text
	label.font_size = 48
	label.pixel_size = 0.00016
	label.position = Vector3(0.0, -0.012, 0.006)
	label.modulate = Color(0.85, 0.85, 0.88)
	eject.add_child(label)

	parent.add_child(eject)
	eject.button_pressed.connect(on_press)


## The hinged lid over a disc well, and the pivot MediaTray swings it on.
##
## A lid rather than a drawer: every one of these units loads from the top and
## opens upward, the way a PlayStation or a GameCube does, and MediaTray already
## animates a pivot for exactly that. Hinged at the BACK edge so it opens away
## from the player and never sweeps through the disc coming in.
static func build_lid(parent: Node3D, s: Vector3) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = "LidPivot"
	parent.add_child(pivot)
	pivot.position = Vector3(0.0, s.y * 0.5, -s.z * 0.5 + 0.004)

	var lid := MeshInstance3D.new()
	lid.name = "Lid"
	var mesh := BoxMesh.new()
	# Just inside the footprint, so the lid reads as a panel let into the roof
	# rather than a slab dropped on top of it.
	mesh.size = Vector3(s.x * 0.86, 0.008, s.z * 0.82)
	lid.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.30, 0.31, 0.34)
	mat.roughness = 0.45
	lid.set_surface_override_material(0, mat)
	pivot.add_child(lid)
	# Half its own depth forward of the hinge, so the panel covers the well.
	lid.position = Vector3(0.0, 0.004, mesh.size.z * 0.5)
	return pivot
