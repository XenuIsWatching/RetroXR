## RetroExpansion — a console expansion as a physical unit you can pick up.
##
## The 64DD, the Famicom Disk System, the Mega-CD, the 32X. Each is its own box
## with its own media bay and its own connector, and each does nothing at all
## until a console is actually bolted to it. Spawn one, spawn the console, stand
## the two together, put a cartridge in one and a disk in the other, press power.
##
## It knows nothing about cores. What it knows is which console it fits, which
## way up it goes, and what its own bay is holding — RetroSystem asks it those
## three things at power-on and ExpansionCatalog turns the answers into a launch.
##
## Geometry
## --------
## Where the connector goes follows entirely from ExpansionCatalog's `mount`:
##   MOUNT_BELOW  the console stands on this unit, so the unit wears the SOCKET
##                on its roof and its media bay moves to the FRONT face, which is
##                where it has to be with a console sitting on top of it.
##   MOUNT_ABOVE  this unit stands on the console, so it wears the FOOT on its
##                underside and its bay sits on TOP, where nothing covers it.
## Both cases are the same two ExpansionPort calls with the arguments swapped.
class_name RetroExpansion
extends XRToolsPickable

const MEDIA_GROUP := "cartridge"
const SNAP_ZONE_SCENE := preload("res://addons/godot-xr-tools/objects/snap_zone.tscn")

## How far into the front face a disk or disc rides on a slot-loading bay. Same
## figure the consoles use (RetroSystem.SLOT_INSET) — a 64DD disk stands as proud
## of its drive as a PS2 disc does of its slot.
const SLOT_INSET := 0.10


## Which expansion this is — a key in ExpansionCatalog.ROWS. Set by the spawner
## before the unit enters the tree, the same way RetroSystem.systemid is.
@export var expansion_id: String = ""

## Emitted when a console is bolted on or taken off, with the console (or null).
## The room's persistence and any future cable art listen to these rather than
## polling the socket.
signal host_changed(host: RetroSystem)


## The console currently joined to this unit, whichever side the socket is on.
var _host: RetroSystem = null
## The socket, on a MOUNT_BELOW unit. Null on one that stands on a console — its
## opposite number lives on the console instead.
var _socket: XRToolsSnapZone = null
## The foot, on a MOUNT_ABOVE unit.
var _foot: XRToolsGrabPointSnap = null
## This unit's own media bay, and what is in it.
var _bay: XRToolsSnapZone = null
var _slot: MediaSlot = null
var _tray: MediaTray = null
## The drawer mechanism on a tray unit that has no lid -- the mouth in the front
## face and the shelf that runs out of it. Null on a lidded unit and on every
## other kind of bay.
var _disc_bay: ProceduralDiscBay = null
var _eject: VRButton = null
var _media: Node3D = null

var _body: MeshInstance3D = null
var _label: Label3D = null
var _shape: CollisionShape3D = null
var _pointer_shape: CollisionShape3D = null

## True only while a saved room is being reloaded into this unit — the restore
## seats media through the same calls a hand does, and anything that makes a
## noise on those events has to be able to tell the two apart.
var _restoring: bool = false


func _ready() -> void:
	super._ready()
	add_to_group(ExpansionPort.GROUP_EXPANSION)
	if not ExpansionCatalog.has(expansion_id):
		push_warning("RetroExpansion: unknown expansion_id '%s'" % expansion_id)
		return
	_build_body()
	_build_connector()
	_build_media_bay()
	_update_label()


# ── the box ───────────────────────────────────────────────────────────────────


func size() -> Vector3:
	return ExpansionCatalog.size_of(expansion_id)


func _build_body() -> void:
	var s := size()
	_body = $Body as MeshInstance3D
	var mesh := BoxMesh.new()
	mesh.size = s
	_body.mesh = mesh
	var mat := StandardMaterial3D.new()
	# A shade darker than the console box so a stack reads as two machines from
	# across the room rather than one tall one.
	mat.albedo_color = Color(0.38, 0.38, 0.40)
	mat.roughness = 0.7
	_body.set_surface_override_material(0, mat)

	_shape = $CollisionShape3D as CollisionShape3D
	var box := BoxShape3D.new()
	box.size = s
	_shape.shape = box

	_pointer_shape = $PointerArea/CollisionShape3D as CollisionShape3D
	var ptr := BoxShape3D.new()
	# Deliberately larger than the case, as every other laser target here is, so
	# a low base under a console can still be hit with a beam from across the room.
	ptr.size = s + Vector3(0.02, 0.02, 0.02)
	_pointer_shape.shape = ptr

	_label = $NameLabel as Label3D
	# Above the slit on a front-loading unit and below the join on a top-mounting
	# one, so the name never lands on the mouth the media goes into (it did: the
	# 64DD's plate sat across its own slit) and never on the console it stands on.
	var front_loading := ExpansionCatalog.mount_of(expansion_id) == ExpansionCatalog.MOUNT_BELOW
	var label_y := (s.y * 0.5 - 0.014) if front_loading else (-s.y * 0.5 + 0.010)
	_label.position = Vector3(0.0, label_y, s.z * 0.5 + 0.001)


## The unit's name, plus the console's while one is attached — so a Mega-CD with
## a Mega Drive on it says what the assembled machine is, not just what the base
## is. The console prints the same sentence on its own plate; two machines that
## have become one should agree about what they are.
func _update_label() -> void:
	if _label == null:
		return
	_label.text = ExpansionCatalog.label_of(expansion_id)


# ── the connector ─────────────────────────────────────────────────────────────


func _build_connector() -> void:
	var s := size()
	var span := Vector2(s.x, s.z)
	if ExpansionCatalog.mount_of(expansion_id) == ExpansionCatalog.MOUNT_CARTRIDGE:
		# We ARE the cartridge -- the console's own slot takes us, and joining the
		# group that slot accepts is most of it.
		add_to_group(MEDIA_GROUP)
		# But not all of it. A snap zone seats an object by its grab point, and
		# with none the object's ORIGIN lands on the zone -- which for a cartridge
		# slot is where a cartridge's MIDDLE sits, well inside the console. A
		# cartridge is meant to be mostly swallowed; a whole machine is not, and
		# the Jaguar CD sank into the Jaguar far enough to bury its own OPEN
		# button.
		#
		# What actually goes into the slot is this unit's connector, so that is
		# what the grab point marks: a tongue hanging below the unit whose tip
		# reaches exactly where a cartridge's centre would be. The unit then sits
		# with its underside at the cartridge's top edge -- on the console, not in
		# it -- and the figure comes from the host's own cartridge size, so it is
		# right for whatever model the slot belongs to.
		var tongue := MediaDimensions.cart_size(
			ExpansionCatalog.host_of(expansion_id)).y * 0.5
		var point := XRToolsGrabPointSnap.new()
		point.name = "CartridgeConnector"
		point.require_group = ExpansionPort.GROUP_CART_SLOT
		add_child(point)
		point.position = Vector3(0.0, -(s.y * 0.5 + tongue), 0.0)
		# By hand, for the same reason the foot is: XRToolsPickable collects its
		# grab points in _ready, which has already run by the time we get here.
		_grab_points.push_back(point)
		return

	if ExpansionCatalog.mount_of(expansion_id) == ExpansionCatalog.MOUNT_BELOW:
		# The console stands on us: we hold the socket, and only the console this
		# unit was made for is allowed into it.
		_socket = ExpansionPort.build_socket(self, s.y * 0.5, span,
			ExpansionPort.GROUP_SYSTEM, _accepts_host)
		_socket.has_picked_up.connect(_on_host_seated)
		_socket.has_dropped.connect(_on_host_lifted)
	else:
		# We stand on the console: we wear the foot, and the console's own socket
		# is what takes us. Registered by hand because XRToolsPickable collects
		# grab points in its _ready, which has already run by the time we get here.
		_foot = ExpansionPort.build_foot(self, -s.y * 0.5, span)
		_grab_points.push_back(_foot)


## Socket gate: is this the console this unit bolts to? A Mega-CD takes a Mega
## Drive and refuses everything else, silently, the way every snap zone here does.
func _accepts_host(obj: Node3D) -> bool:
	var sys := obj as RetroSystem
	if sys == null:
		return false
	return sys.systemid == ExpansionCatalog.host_of(expansion_id)


func _on_host_seated(obj: Node3D) -> void:
	var sys := obj as RetroSystem
	if sys == null:
		return
	_bind_host(sys)


func _on_host_lifted() -> void:
	_unbind_host()


## Called from either side of the join: by our own socket when we took a console,
## and by the console's socket when IT took us.
func _bind_host(sys: RetroSystem) -> void:
	if _host == sys:
		return
	_unbind_host()
	_host = sys
	# The seated machine is frozen and rides us through the scene graph; without
	# this the two boxes fight at the face they are pressed together at.
	add_collision_exception_with(sys)
	sys.attach_expansion(self)
	_update_label()
	host_changed.emit(sys)


func _unbind_host() -> void:
	if _host == null:
		return
	var was := _host
	_host = null
	if is_instance_valid(was):
		remove_collision_exception_with(was)
		was.detach_expansion(self)
	_update_label()
	host_changed.emit(null)


## The console this unit is joined to, or null.
func get_host() -> RetroSystem:
	return _host if is_instance_valid(_host) else null


## Bolt to `sys` from the console's side. Only meaningful on a MOUNT_ABOVE unit;
## a MOUNT_BELOW unit is bound by its own socket instead.
func bind_to_host(sys: RetroSystem) -> void:
	_bind_host(sys)


func unbind_from_host() -> void:
	_unbind_host()


# ── the media bay ─────────────────────────────────────────────────────────────


## Where the bay goes follows the mount: a unit with a console standing on it
## loads through the FRONT (a slit, like a 64DD or a front-loading Mega-CD), and
## one that stands on a console loads from the TOP, where nothing covers it.
func _build_media_bay() -> void:
	var media := ExpansionCatalog.media_of(expansion_id)
	if media.is_empty():
		return
	var s := size()
	# A slit in the front is for media that SLIDES IN: a 64DD disk, an FDS disk.
	# Which way the unit stacks does not decide that -- a Satellaview sits under
	# a Super NES and takes a memory pack pushed into the top of it, and a
	# Mega-CD sits under a Mega Drive and opens a lid. Deciding by mount buried
	# the Satellaview's pack 92 mm inside the box, out of sight and out of reach,
	# because it rode the slot travel meant for something a third of its length.
	var front_loading := ExpansionCatalog.loader_of(expansion_id) == MediaDimensions.LOADER_SLOT

	_bay = SNAP_ZONE_SCENE.instantiate() as XRToolsSnapZone
	_bay.name = "MediaBay"
	_bay.snap_require = MEDIA_GROUP
	_bay.snap_filter = _accepts_media
	_bay.grab_distance = 0.07
	add_child(_bay)

	if front_loading:
		# At the mouth of the slit, a third of the way up the front face.
		_bay.position = Vector3(0.0, -s.y * 0.2, s.z * 0.5)
		_build_slit(s)
		# The ride in and out, the grab hand-off and the collision exception, all
		# from the same component the slot-loading consoles use. Its `host` is
		# typed PhysicsBody3D rather than RetroSystem precisely so a second kind
		# of machine can own one.
		_slot = MediaSlot.new()
		_slot.host = self
		_slot.slot = _bay
		# How far it rides in. SLOT_INSET is a disc figure and a 64DD disk is
		# shorter than that, so taken flat it would vanish inside the drive;
		# measured from the media itself, roughly two thirds swallowed, the head
		# stays out in the room where a hand can reach it -- which is what a
		# loaded 64DD looks like.
		var media_size := MediaDimensions.cart_size(media)
		if ExpansionCatalog.loader_of(expansion_id) == MediaDimensions.LOADER_SLOT:
			# A flat disk goes in the way you hold it: LABEL UP, shutter first.
			# The media is modelled with its label on +Z and its shutter at +Y,
			# so a quarter turn back about X lays the label upward and points the
			# shutter into the machine. Set on the SLOT rather than the bay: the
			# slot rides its media along its own -Z, and turning the bay would
			# have turned that axis too, sending the disk down through the floor
			# of the drive instead of into it.
			_slot.media_local_basis = Basis.from_euler(Vector3(-PI * 0.5, 0.0, 0.0))
			# insert_depth places the disk's CENTRE, not its trailing edge, so
			# the disc figure would bury a 64DD disk completely: at 0.66 of its
			# length the whole thing sits inside the drive. A fifth of the
			# length leaves about a third of the disk out in the room, which is
			# what a loaded 64DD looks like and what a hand needs to pull it
			# back out.
			_slot.insert_depth = media_size.y * 0.2
		else:
			_slot.insert_depth = SLOT_INSET
		add_child(_slot)
		_slot.inserted.connect(_on_media_in)
		_slot.removed.connect(_on_media_out)
	elif ExpansionCatalog.loader_of(expansion_id) == MediaDimensions.LOADER_TRAY:
		# A CD unit. Every one of these loads from the top on the real hardware,
		# and the disc consoles already have the pair that models it: a MediaTray
		# for the lid and the seating, and a button that opens it. Reusing them
		# means a Mega-CD behaves like every other disc machine in the room
		# rather than like a slot that swallows a disc whole.
		_tray = MediaTray.new()
		_tray.host = self
		_tray.slot = _bay
		if ExpansionCatalog.lid_of(expansion_id):
			# A LID. The disc lies in a well in the roof and the lid swings up off
			# it, the way a PlayStation or a GameCube opens.
			_bay.position = Vector3(0.0, s.y * 0.5, 0.0)
			_build_well(s)
			_tray.lid_pivot = _build_lid(s)
			add_child(_tray)
		else:
			# A DRAWER, and the same one a PlayStation 2 runs: a mouth in the front
			# face and a shelf that carries the disc out through it. Pressing OPEN
			# used to change nothing anybody could see -- MediaTray only animates a
			# lid pivot, and a tray unit with no lid had none, so the button
			# toggled a state with no mechanism attached to it.
			#
			# ProceduralDiscBay is the console's own mechanism, handed this unit's
			# box instead of the placeholder console's so the mouth lands on THIS
			# machine's front face. disc_lid_pivot is what makes the snap zone ride
			# the shelf, so a disc laid on the tray travels in with it -- and it has
			# to be set before the tray enters the tree, because MediaTray measures
			# the zone against the pivot in its _ready.
			# Below the middle of the face, not above it. The unit wears its
			# nameplate high on the front (_build_body puts it at s.y * 0.5 -
			# 14 mm on a MOUNT_BELOW unit), and a deck placed like a console's
			# ran the mouth -- and the disc riding out of it -- straight across
			# the lettering.
			_disc_bay = ProceduralDiscBay.build_tray(self, _bay, media, true,
				Callable(), s, _deck_y(s))
			_tray.disc_lid_pivot = _disc_bay.slide_pivot
			# Where the disc actually LIES on that shelf, and it is not the
			# shelf pivot's own origin. build_tray puts the snap zone 2.5 mm up
			# from the pivot, which is what clears the 3 mm well cylinder drawn
			# around it; seated at the pivot instead, the disc sat INSIDE that
			# well with the well's opaque top face over it, so it snapped to the
			# right place and then vanished into the tray.
			#
			# Read off the two nodes rather than written as a number, and it is
			# the same line RetroSystem uses for its own tray -- the offset is a
			# property of how ProceduralDiscBay lays the shelf out, so asking it
			# cannot drift the way a copied constant would.
			var rel := _disc_bay.slide_pivot.global_transform.affine_inverse() 				* _bay.global_transform
			_tray.media_local_basis = rel.basis
			_tray.seat_offset = rel.origin
			add_child(_tray)
			_tray.opened.connect(func() -> void: _disc_bay.slide(true))
			_tray.closed.connect(func() -> void: _disc_bay.slide(false))
		_tray.loaded.connect(_on_media_in)
		_tray.unloaded.connect(_on_media_out)
		_build_eject_button(s)
	else:
		# A well in the roof. The cart stands proud of it, which is what a 32X
		# cartridge does and what makes it obvious the unit is loaded.
		_bay.position = Vector3(0.0, s.y * 0.5, 0.0)
		_build_well(s)
		_bay.has_picked_up.connect(_on_media_in)
		_bay.has_dropped.connect(_on_media_out)


func _build_slit(s: Vector3) -> void:
	var slit := MeshInstance3D.new()
	slit.name = "SlitMouth"
	var mesh := BoxMesh.new()
	# Cut to the media, not to the box: a slot loader's mouth is as wide and as
	# tall as the disk that goes through it, so the disk does not appear to pass
	# through a letterbox narrower than itself.
	if ExpansionCatalog.loader_of(expansion_id) == MediaDimensions.LOADER_SLOT:
		var m := MediaDimensions.cart_size(ExpansionCatalog.media_of(expansion_id))
		mesh.size = Vector3(m.x + 0.004, m.z + 0.003, 0.008)
	else:
		mesh.size = Vector3(s.x * 0.62, 0.012, 0.008)
	slit.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.03, 0.03, 0.04)
	slit.set_surface_override_material(0, mat)
	_body.add_child(slit)
	slit.position = Vector3(0.0, -s.y * 0.2, s.z * 0.5 - 0.002)


## The mouth in the roof that media drops into.
##
## Cut to the MEDIA, not to a fraction of the box -- the same rule the front slit
## already followed. A fixed 0.7 x 0.55 of the footprint gave the 32X a wide
## rectangular pit where a cartridge slot belongs: a cart stands upright in it, so
## the mouth it goes through is as wide as the cart and only as deep as the cart
## is THICK, which is a 104 x 19 mm letterbox rather than a 105 x 77 mm hole.
##
## A tray unit is sized from the disc instead, and by its loader rather than by
## its media systemid -- the Jaguar CD's media is "atari_jaguar", whose cart_size
## is a Jaguar CARTRIDGE, so asking the media what shape it is would cut a
## cartridge slot in a CD machine.
func _build_well(s: Vector3) -> void:
	var well := MeshInstance3D.new()
	well.name = "WellMouth"
	var media := ExpansionCatalog.media_of(expansion_id)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.03, 0.03, 0.04)

	if ExpansionCatalog.loader_of(expansion_id) == MediaDimensions.LOADER_TRAY:
		# Round, because a disc is. A box here read as a hatch rather than a well.
		var disc := CylinderMesh.new()
		var r: float = MediaDimensions.disc_diameter(media) * 0.5 + 0.003
		disc.top_radius = r
		disc.bottom_radius = r
		disc.height = 0.01
		well.mesh = disc
	else:
		var mesh := BoxMesh.new()
		var m := MediaDimensions.cart_size(media)
		mesh.size = Vector3(m.x + 0.004, 0.01, m.z + 0.004)
		well.mesh = mesh
	well.set_surface_override_material(0, mat)
	_body.add_child(well)
	# A millimetre BELOW the roof, not flush with it. At s.y * 0.5 - 0.005 the
	# well's top face landed in exactly the plane of the body's top face, and two
	# coplanar faces is the whole of the z-fighting seen on the 32X: neither
	# surface is in front, so the depth test picks per-pixel and the roof
	# shimmers. Sinking it clears the tie.
	well.position = Vector3(0.0, s.y * 0.5 - 0.006, 0.0)


## Bay gate: is this the media this unit takes? Media with no systemid of its own
## is let through — a blank cartridge is whatever machine it is put into, which
## is how RetroSystem treats one too.
func _accepts_media(obj: Node3D) -> bool:
	if obj == null or not ("systemid" in obj):
		return false
	var mid := str(obj.get("systemid"))
	return mid.is_empty() or mid == ExpansionCatalog.media_of(expansion_id)


func _on_media_in(media: Node3D) -> void:
	_media = media
	if _slot == null:
		add_collision_exception_with(media)
	# Back-fill, exactly as a console does: a disk put into a 64DD is a 64DD disk.
	if "systemid" in media and str(media.get("systemid")).is_empty():
		media.set("systemid", ExpansionCatalog.media_of(expansion_id))
	if _host != null and is_instance_valid(_host):
		_host.on_expansion_media_changed(self)


func _on_media_out() -> void:
	if _media != null and is_instance_valid(_media) and _slot == null:
		remove_collision_exception_with(_media)
	_media = null
	if _host != null and is_instance_valid(_host):
		_host.on_expansion_media_changed(self)


## What is in this unit's bay, or null.
func get_media() -> Node3D:
	return _media if is_instance_valid(_media) else null


## The path of the disk/disc/cart in this unit's bay. Empty when the bay is empty
## or the media carries no ROM — which is the state a stack powers on in when the
## player has only put a game in the console.
func get_media_path() -> String:
	var m := get_media()
	if m == null or not m.has_method("get_rom_path"):
		return ""
	return str(m.call("get_rom_path"))


## Seat media after a save restore, bypassing the insert ride and its noise.
func restore_media(media: Node3D) -> void:
	_restoring = true
	if _slot != null:
		_slot.restore(media)
	elif _bay != null:
		_bay.pick_up_object(media)
	_restoring = false


## True while a save is being reloaded into this unit.
func is_restoring() -> bool:
	return _restoring


## Seat a console after a save restore. Only a MOUNT_BELOW unit has a socket to
## seat one in; on a MOUNT_ABOVE unit the console does the seating instead.
func restore_host(sys: RetroSystem) -> void:
	if _socket != null and is_instance_valid(sys):
		_socket.pick_up_object(sys)


## The socket, for the console to release when it is pulled off from the far side.
func get_socket() -> XRToolsSnapZone:
	return _socket


## The OPEN button on a disc unit's front face.
##
## Built rather than authored because these units have no scene of their own --
## the body is a measured box and everything on it is placed from ExpansionCatalog
## dimensions. Same widget the consoles use, so it highlights, depresses and
## takes a trigger press identically.
## Where a drawer unit's tray deck sits on its front face -- below the middle,
## clear of the nameplate the unit carries high on that face.
func _deck_y(s: Vector3) -> float:
	return -s.y * 0.16


## The OPEN button's height: level with the tray deck on a drawer unit, so the
## two read as one row of controls rather than a button stranded above a mouth.
## A lidded unit has no deck, and keeps the height it always had.
func _eject_y(s: Vector3) -> float:
	return _deck_y(s) if _disc_bay != null else -s.y * 0.18


## And its distance out from the centre. On a drawer unit that is measured from
## the MOUTH rather than taken as a fraction of the box: the mouth is as wide as
## a disc plus its bezel however narrow the machine is, so a fixed fraction put
## the button through the tray on the smaller units (the CD-ROM2 is 60 mm
## narrower than the Mega-CD and the mouth is the same size on both).
func _eject_x(s: Vector3) -> float:
	if _disc_bay == null:
		return s.x * 0.30
	var mouth_half := (MediaDimensions.disc_diameter(
		ExpansionCatalog.media_of(expansion_id)) + 0.020) * 0.5
	# Clamped inside the case, so a machine too narrow to fit the button beside
	# its own tray puts it as far out as it can rather than off the edge.
	return minf(mouth_half + 0.018, s.x * 0.5 - 0.016)


func _build_eject_button(s: Vector3) -> void:
	_eject = VRButton.new()
	_eject.name = "EjectButton"
	_eject.position = Vector3(_eject_x(s), _eject_y(s), s.z * 0.5 + 0.004)
	# A button on the FRONT face travels into that face. The default axis is
	# (0,-1,0), which is right for the cabinet buttons on a console's roof and
	# wrong here: the cap sank downwards out of its own bezel instead of pressing
	# in.
	_eject.depress_axis = Vector3(0.0, 0.0, -1.0)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.026, 0.012, 0.010)
	shape.shape = box
	_eject.add_child(shape)

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
	_eject.add_child(mesh)

	var label := Label3D.new()
	label.text = "OPEN"
	label.font_size = 48
	label.pixel_size = 0.00016
	label.position = Vector3(0.0, -0.012, 0.006)
	label.modulate = Color(0.85, 0.85, 0.88)
	_eject.add_child(label)

	add_child(_eject)
	_eject.button_pressed.connect(func() -> void:
		if _tray != null:
			_tray.toggle_open())


## The hinged lid over a disc well, and the pivot MediaTray swings it on.
##
## A lid rather than a drawer: every one of these units loads from the top and
## opens upward, the way a PlayStation or a GameCube does, and MediaTray already
## animates a pivot for exactly that. Hinged at the BACK edge so it opens away
## from the player and never sweeps through the disc coming in.
func _build_lid(s: Vector3) -> Node3D:
	var pivot := Node3D.new()
	pivot.name = "LidPivot"
	add_child(pivot)
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
