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
	# The zone will not move a frozen body on its own; see ExpansionPort.seat.
	ExpansionPort.seat(_socket, sys)
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
	var front_loading := ExpansionCatalog.mount_of(expansion_id) == ExpansionCatalog.MOUNT_BELOW

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
	else:
		# A well in the roof. The cart or disc stands proud of it, which is what a
		# 32X cartridge does and what makes it obvious the unit is loaded.
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


func _build_well(s: Vector3) -> void:
	var well := MeshInstance3D.new()
	well.name = "WellMouth"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(s.x * 0.7, 0.01, s.z * 0.55)
	well.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.03, 0.03, 0.04)
	well.set_surface_override_material(0, mat)
	_body.add_child(well)
	well.position = Vector3(0.0, s.y * 0.5 - 0.005, 0.0)


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
