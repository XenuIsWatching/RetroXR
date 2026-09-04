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

## Which expansion this is — a key in ExpansionCatalog.ROWS. Set by the spawner
## before the unit enters the tree, the same way RetroSystem.systemid is.
@export var expansion_id: String = ""

## The ROM this unit carries in itself, for a cartridge-shaped unit that contains
## one. Empty on every unit that is only an enclosure.
##
## The BS-X cartridge is the case that needs it: the shell lives on the cartridge,
## and a pack in its bay is the CONTENT that shell loads. So the machine boots the
## pack when there is one and this ROM when the bay is empty, which is what the
## hardware does -- an empty BS-X cart still boots the town.
@export var rom_path: String = ""

## Emitted when a console is bolted on or taken off, with the console (or null).
## The room's persistence and any future cable art listen to these rather than
## polling the socket.
signal host_changed(host: RetroSystem)

## A card completed a pass through this unit's groove. `strip` indexes the card's
## own strips, or -1 when the edge presented carries no dotcode.
signal card_swiped(card: Node3D, edge: String, strip: int)
## A pass was started and not finished.
signal card_swipe_aborted(card: Node3D)


## The console currently joined to this unit, whichever side the socket is on.
var _host: RetroSystem = null
## The socket, on a MOUNT_BELOW unit. Null on one that stands on a console — its
## opposite number lives on the console instead.
var _socket: XRToolsSnapZone = null
## The foot, on a MOUNT_ABOVE unit.
var _foot: XRToolsGrabPointSnap = null
## The connector tongue, on a unit that mounts AS a cartridge. Its length is set
## against whichever console is asking -- see _aim_connector.
var _connector: XRToolsGrabPointSnap = null
## This unit's own media bays, and what is in each. Almost always one; a Sufami
## Turbo has two. Indexed rather than given a second named field, so every
## accessor is `slot := 0` and the ~10 existing callers keep working untouched --
## the same shape RetroSystem uses for its two memory-card sockets.
var _bays: Array[XRToolsSnapZone] = []
var _slot: MediaSlot = null
var _slit: CardSwipeSlit = null
var _tray: MediaTray = null
## The drawer mechanism on a tray unit that has no lid -- the mouth in the front
## face and the shelf that runs out of it. Null on a lidded unit and on every
## other kind of bay.
var _disc_bay: ProceduralDiscBay = null
var _media: Array[Node3D] = []

var _body: MeshInstance3D = null
var _label: Label3D = null

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
	_build_panel()


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

	var shape := $CollisionShape3D as CollisionShape3D
	var box := BoxShape3D.new()
	box.size = s
	shape.shape = box

	var pointer_shape := $PointerArea/CollisionShape3D as CollisionShape3D
	var ptr := BoxShape3D.new()
	# Deliberately larger than the case, as every other laser target here is, so
	# a low base under a console can still be hit with a beam from across the room.
	ptr.size = s + Vector3(0.02, 0.02, 0.02)
	pointer_shape.shape = ptr

	_label = $NameLabel as Label3D
	# Above the slit on a front-loading unit and below the join on a top-mounting
	# one, so the name never lands on the mouth the media goes into (it did: the
	# 64DD's plate sat across its own slit) and never on the console it stands on.
	var mount := ExpansionCatalog.mount_of(expansion_id)
	var front_loading := mount == ExpansionCatalog.MOUNT_BELOW
	var label_y := (s.y * 0.5 - 0.014) if front_loading else (-s.y * 0.5 + 0.010)
	# A unit that stands in the room is read from +Z, but a unit that IS a
	# cartridge is swallowed by a console and read from the other side: the
	# console's slot seats it facing away, so a name on +Z is the face nobody can
	# see, printed backwards through the shell.
	var cartridge := mount == ExpansionCatalog.MOUNT_CARTRIDGE
	var label_z := (-s.z * 0.5 - 0.001) if cartridge else (s.z * 0.5 + 0.001)
	_label.position = Vector3(0.0, label_y, label_z)
	_label.rotation = Vector3(0.0, PI, 0.0) if cartridge else Vector3.ZERO


## The front face some units wear -- the Satellaview's POWER and ACCESS lamps are
## the only one so far. The scene is named by the catalog row rather than by an
## id test here, the same way every other per-unit fact in this file is, and the
## panel finds this unit's console through host_changed on its own.
func _build_panel() -> void:
	var scene_path := ExpansionCatalog.panel_of(expansion_id)
	if scene_path.is_empty():
		return
	var packed := load(scene_path) as PackedScene
	if packed == null:
		push_warning("RetroExpansion: '%s' names a panel that will not load: %s"
			% [expansion_id, scene_path])
		return
	add_child(packed.instantiate())


## The unit's own name, from the catalog. It does not name the console bolted to
## it -- a stack is read from the console's plate, which carries both halves.
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
		# what the grab point marks: a tongue hanging below the unit, long enough
		# that the unit's underside comes to rest ON the console's roof with only
		# the connector inside it.
		#
		# How long that tongue is cannot be decided here. It is the distance from
		# the console's cartridge slot up to its top face, which is a different
		# figure on every shell -- so the point is placed when a slot actually
		# asks for it, in _get_grab_point, against the machine asking. Derived
		# from the CARTRIDGE's height instead, the 32X and the Jaguar CD floated
		# well above their consoles.
		_connector = XRToolsGrabPointSnap.new()
		_connector.name = "CartridgeConnector"
		_connector.require_group = ExpansionPort.GROUP_CART_SLOT
		add_child(_connector)
		_aim_connector(null)
		# By hand, for the same reason the foot is: XRToolsPickable collects its
		# grab points in _ready, which has already run by the time we get here.
		_grab_points.push_back(_connector)
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


## Aim the connector at `zone`'s machine before handing it over.
##
## snap_pose_for asks for the grab point every time it ranks or previews a zone,
## and the answer decides where this unit lands, so setting it here makes the
## ghost and the seat agree by construction -- they are the same query.
##
## A null zone (or one that belongs to no console) leaves the tongue at zero, so
## the unit seats on the slot itself. That is where a preview sits for the few
## frames before a console's model has meshes to measure, and it is never cached.
func _get_grab_point(grabber: Node3D, current: XRToolsGrabPoint) -> XRToolsGrabPoint:
	var point := super(grabber, current)
	if point != null and point == _connector:
		_aim_connector(grabber as XRToolsSnapZone)
	return point


func _aim_connector(zone: XRToolsSnapZone) -> void:
	if _connector == null:
		return
	var lift := 0.0
	if zone != null:
		var n: Node = zone.get_parent()
		while n != null:
			if n is RetroSystem:
				lift = (n as RetroSystem).roof_above_cartridge_slot()
				break
			n = n.get_parent()
	_connector.position = Vector3(0.0, -(size().y * 0.5 + lift), 0.0)


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
	# Some units have no mouth. The Satellaview is a tuner and a modem that clips
	# under the console; the cartridge goes into the SUPER FAMICOM's slot, on top,
	# and this unit builds nothing for it. Without this the bay landed on the
	# unit's roof -- which is the face the console is standing on -- and the
	# cartridge vanished into the join between the two machines.
	if ExpansionCatalog.media_in_host(expansion_id):
		return
	var s := size()
	# A slit in the front is for media that SLIDES IN: a 64DD disk, an FDS disk.
	# Which way the unit stacks does not decide that -- a Satellaview sits under
	# a Super NES and takes a memory pack pushed into the top of it, and a
	# Mega-CD sits under a Mega Drive and opens a lid. Deciding by mount buried
	# the Satellaview's pack 92 mm inside the box, out of sight and out of reach,
	# because it rode the slot travel meant for something a third of its length.
	var loader := ExpansionCatalog.loader_of(expansion_id)
	# A swiped medium is never held, so this unit gets a groove and NO bay. The
	# snap zones below are built before the loader is branched on, and one of them
	# would capture the card part-way through the swipe.
	if loader == MediaDimensions.LOADER_SWIPE:
		_build_swipe_slit(size(), media)
		return
	var front_loading := loader == MediaDimensions.LOADER_SLOT

	var count := ExpansionCatalog.bays_of(expansion_id)
	_media.resize(count)

	for i in count:
		var bay := SNAP_ZONE_SCENE.instantiate() as XRToolsSnapZone
		# "MediaBay", then "MediaBay2" -- the numbering RetroSystem's memory-card
		# sockets already use, so the first bay's node name is unchanged and every
		# scene, test and save file that names it keeps resolving.
		bay.name = "MediaBay" if i == 0 else "MediaBay%d" % (i + 1)
		bay.snap_require = MEDIA_GROUP
		bay.snap_filter = _accepts_media
		# 70 mm of capture radius is right for a unit with one mouth and far too
		# much for a unit whose mouths are 65 mm apart: two spheres that size
		# overlap almost completely, and every reach lights up both previews.
		bay.grab_distance = 0.07 if count == 1 else 0.03
		add_child(bay)
		_bays.append(bay)

	if front_loading:
		_build_slot_bay(s, media)
	elif loader == MediaDimensions.LOADER_TRAY:
		_build_tray_bay(s, media, loader)
	else:
		_build_well_bay(s, media, loader)


## Media that SLIDES IN through a slit in the front face: a 64DD disk, an FDS
## disk. MediaSlot runs the ride in and out.
func _build_slot_bay(s: Vector3, media: String) -> void:
	# At the mouth of the slit, a third of the way up the front face.
	_bays[0].position = Vector3(0.0, -s.y * 0.2, s.z * 0.5)
	ExpansionShell.build_slit(_body, s, media)
	# The ride in and out, the grab hand-off and the collision exception, all
	# from the same component the slot-loading consoles use. Its `host` is
	# typed PhysicsBody3D rather than RetroSystem precisely so a second kind
	# of machine can own one.
	_slot = MediaSlot.new()
	_slot.host = self
	_slot.slot = _bays[0]
	# How far it rides in. The consoles' slot inset is a disc figure and a
	# 64DD disk is shorter, so taken flat it would vanish inside the drive;
	# measured from the media itself, roughly two thirds swallowed, the head
	# stays out in the room where a hand can reach it -- which is what a
	# loaded 64DD looks like.
	var media_size := MediaDimensions.cart_size(media)
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
	add_child(_slot)
	_slot.inserted.connect(_on_media_in)
	_slot.removed.connect(_on_media_out)
	# A slot bay swallows its media and MediaSlot makes it neither grabbable nor
	# pointable while it is in there, so without this button a 64DD disk went in
	# and could not come back out.
	_build_eject_button(s, media)


## Media that is SWIPED rather than loaded: a groove across the roof, and no bay.
##
## The card stays in the hand for the whole pass, so there is nothing to seat and
## nothing to eject. CardSwipeSlit constrains the pose and reports a completed
## pass; this unit only forwards it.
func _build_swipe_slit(s: Vector3, media: String) -> void:
	var card := MediaDimensions.cart_size(media)
	var centre := ExpansionShell.build_through_slot(_body, s, card)

	_slit = CardSwipeSlit.new()
	_slit.name = "SwipeSlit"
	_slit.card_group = MEDIA_GROUP
	_slit.card_filter = _accepts_media
	# The same mask a snap zone carries, and for the same reason: media rests on
	# layer 3 and XRToolsPickable moves it to DEFAULT_LAYER while a hand has it,
	# so a groove watching only one of the two never sees a card being carried
	# through it -- which is the only way a card ever arrives.
	_slit.collision_mask = 0b0000_0000_0000_0001_0000_0000_0000_0100
	# The groove runs the width of the case, and a pass has to clear both ends.
	_slit.travel = s.x
	add_child(_slit)
	_slit.position = centre

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	# Deep enough in Y to catch a card whose edge is in the groove, tight in Z so
	# a card held flat above the case does not arm it.
	box.size = Vector3(s.x, card.y * 0.5, card.z + 0.006)
	shape.shape = box
	_slit.add_child(shape)

	_slit.swiped.connect(_on_card_swiped)
	_slit.aborted.connect(_on_card_swipe_aborted)


func _on_card_swiped(card: Node3D, edge: String, strip: int) -> void:
	card_swiped.emit(card, edge, strip)


func _on_card_swipe_aborted(card: Node3D) -> void:
	card_swipe_aborted.emit(card)


## A CD unit -- a lid in the roof, or a drawer out of the front.
##
## Every one of these loads from the top on the real hardware, and the disc
## consoles already have the pair that models it: a MediaTray for the lid and
## the seating, and a button that opens it. Reusing them means a Mega-CD
## behaves like every other disc machine in the room rather than like a slot
## that swallows a disc whole.
func _build_tray_bay(s: Vector3, media: String, loader: int) -> void:
	_tray = MediaTray.new()
	_tray.host = self
	_tray.slot = _bays[0]
	if ExpansionCatalog.lid_of(expansion_id):
		# A LID. The disc lies in a well in the roof and the lid swings up off
		# it, the way a PlayStation or a GameCube opens.
		_bays[0].position = Vector3(0.0, s.y * 0.5, 0.0)
		ExpansionShell.build_well(_body, s, media, loader)
		_tray.lid_pivot = ExpansionShell.build_lid(self, s)
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
		_disc_bay = ProceduralDiscBay.build_tray(self, _bays[0], media, true,
			Callable(), s, ExpansionShell.deck_y(s))
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
		var pivot_inv := _disc_bay.slide_pivot.global_transform.affine_inverse()
		var rel := pivot_inv * _bays[0].global_transform
		_tray.media_local_basis = rel.basis
		_tray.seat_offset = rel.origin
		add_child(_tray)
		_tray.opened.connect(func() -> void: _disc_bay.slide(true))
		_tray.closed.connect(func() -> void: _disc_bay.slide(false))
	_tray.loaded.connect(_on_media_in)
	_tray.unloaded.connect(_on_media_out)
	_build_eject_button(s, media)


## A well in the roof. The cart stands proud of it, which is what a 32X
## cartridge does and what makes it obvious the unit is loaded.
## Several wells are spread along X, evenly about the centre, so a two-bay unit
## reads as a pair of mouths side by side rather than one mouth off to a side.
## The offsets are computed rather than written down: the catalog owns both the
## box and the cartridge, and a hand-placed constant would go stale the moment
## either is tuned.
##
## The mesh takes the SAME offset as the zone. They are placed independently, and
## moving only the zone gives a unit that catches a cartridge where no hole is
## drawn -- see ExpansionShell.build_well.
func _build_well_bay(s: Vector3, media: String, loader: int) -> void:
	var n := _bays.size()
	var pitch := MediaDimensions.cart_size(media).x + 0.010
	for i in n:
		var x: float = (float(i) - float(n - 1) * 0.5) * pitch
		_bays[i].position = Vector3(x, s.y * 0.5, 0.0)
		ExpansionShell.build_well(_body, s, media, loader, x)
		# Bound, so each zone reports the slot it IS. Without the bind both bays
		# write the same entry and the second cartridge is invisible.
		_bays[i].has_picked_up.connect(_on_media_in.bind(i))
		_bays[i].has_dropped.connect(_on_media_out.bind(i))


## Bay gate: is this the media this unit takes? Media with no systemid of its own
## is let through — a blank cartridge is whatever machine it is put into, which
## is how RetroSystem treats one too.
func _accepts_media(obj: Node3D) -> bool:
	if obj == null or not ("systemid" in obj):
		return false
	var mid := str(obj.get("systemid"))
	return mid.is_empty() or mid == ExpansionCatalog.media_of(expansion_id)


func _on_media_in(media: Node3D, slot := 0) -> void:
	if slot >= _media.size():
		return
	_media[slot] = media
	if _slot == null:
		add_collision_exception_with(media)
	# Back-fill, exactly as a console does: a disk put into a 64DD is a 64DD disk.
	if "systemid" in media and str(media.get("systemid")).is_empty():
		media.set("systemid", ExpansionCatalog.media_of(expansion_id))
	_notify_host_media()


func _on_media_out(slot := 0) -> void:
	if slot >= _media.size():
		return
	var was: Node3D = _media[slot]
	if was != null and is_instance_valid(was) and _slot == null:
		remove_collision_exception_with(was)
	_media[slot] = null
	_notify_host_media()


## Tell the console its stack changed, if a console is bolted on.
func _notify_host_media() -> void:
	var h := get_host()
	if h != null:
		h.on_expansion_media_changed(self)


## How many cartridges this unit holds at once.
func get_bay_count() -> int:
	return _media.size()


## What is in one of this unit's bays, or null.
##
## Range-checked rather than indexed, because slot 1 is asked of every unit by
## code that does not know how many bays this one has -- and a single-bay unit
## answering "nothing in my second bay" is the correct answer, where a crash or a
## silent alias to bay 0 are both wrong. The alias is the more dangerous of the
## two: it reads as a cartridge that is not there.
func get_media(slot := 0) -> Node3D:
	if slot < 0 or slot >= _media.size():
		return null
	var m: Node3D = _media[slot]
	return m if is_instance_valid(m) else null


## The path of the disk/disc/cart in one of this unit's bays. Empty when the bay
## is empty or the media carries no ROM — which is the state a stack powers on in
## when the player has only put a game in the console.
func get_media_path(slot := 0) -> String:
	var m := get_media(slot)
	if m == null or not m.has_method("get_rom_path"):
		return ""
	return str(m.call("get_rom_path"))


## Seat media after a save restore, bypassing the insert ride and its noise.
func restore_media(media: Node3D, slot := 0) -> void:
	if _slot != null:
		_slot.restore(media)
	elif slot >= 0 and slot < _bays.size():
		_bays[slot].pick_up_object(media)


## The socket, for the console to release when it is pulled off from the far side.
func get_socket() -> XRToolsSnapZone:
	return _socket


## The EJECT/OPEN button, placed against this unit's own box and wired to
## whichever bay this unit built.
func _build_eject_button(s: Vector3, media: String) -> void:
	var drawer := _disc_bay != null
	var mount := ExpansionCatalog.mount_of(expansion_id)
	var pos := Vector3(
		ExpansionShell.eject_x(s, mount, drawer, media),
		ExpansionShell.eject_y(s, mount, drawer),
		s.z * 0.5 + 0.004)
	ExpansionShell.build_eject_button(self, pos, func() -> void:
		if _tray != null:
			_tray.toggle_open()
		elif _slot != null:
			_slot.toggle_eject(),
		"OPEN" if _tray != null else "EJECT")
