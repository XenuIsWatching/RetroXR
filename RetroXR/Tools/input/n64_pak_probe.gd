## Checks that the three N64 expansion paks seat correctly in the pad's
## expansion port -- and renders each one going in, so it can be watched.
##
## The port's snap zone is a hand-authored position in the .tscn, so it can drift
## from the shell it is meant to sit in without anything noticing: no headless
## suite covers it, and the pad's own render does not show it either, because an
## empty port looks the same whether or not a pak would land in it.
##
## So the oracle here is the SHELL's own geometry, read at run time: the bay
## mouth is the lowest face of the body inside the bay footprint, and a seated
## pak's mating face has to land on it.
##
##   godot --headless --path RetroXR res://Tools/input/n64_pak_probe.tscn
##   godot --path RetroXR --resolution 320x240 --position 20,20 \
##       res://Tools/input/n64_pak_probe.tscn -- --video
extends Node

const PAD := "res://Scenes/Objects/controllers/n64/n64_controller.tscn"
const PAKS: Dictionary = {
	"ControllerPak": "res://Scenes/Objects/controllers/n64/controller_pak.tscn",
	"RumblePak": "res://Scenes/Objects/controllers/n64/rumble_pak.tscn",
	"TransferPak": "res://Scenes/Objects/controllers/n64/transfer_pak.tscn",
}
const SHOT := Vector2i(900, 900)
const CART_SCENE := "res://Scenes/Objects/media/cartridge.tscn"
const RECEIVER := "res://Scenes/Objects/controllers/pad_receiver.tscn"

## Where to look for the bay, in the pad's own space. Wider than the bay so a
## shell whose bay moved a little is still found, narrow enough to exclude the
## outer grips, which hang lower than everything except the bay itself.
const BAY_X := 0.036
const BAY_Z := Vector2(-0.080, -0.038)
## Grid step for the ray sweep that maps the opening.
const SWEEP_STEP := 0.001
## A layer nothing in the pad uses, so the sweep meets only the shell.
const SHELL_PROBE_LAYER := 1 << 18
## Share of the port's open area an insert must cover to count as filling it.
## Much below this and a pak reads as a brick held near a hole rather than a
## part in a port -- a sixth of the opening looks exactly like that.
const MIN_PORT_FILL := 0.5
## How far a pak's prong must reach INSIDE the controller. A pak does not sit
## against this port, it goes into it -- and a prong that merely breaks the
## plane satisfies "enters the bay" while still reading as a lid on a hole.
const MIN_INSERTION := 0.030
## Clearance a prong must leave below the connector block hanging inside the
## well. The bay is deep, so "longer" has a hard limit at the other end, and a
## prong driven through the connector looks fine from outside -- the whole
## reason this is measured rather than eyeballed.
const CONNECTOR_CLEARANCE := 0.001

## Every pak puts its mating face 2 mm ahead of its origin -- see the frame table
## in each pak scene. The snap zone therefore stands 2 mm proud of the shell.
const PAK_FACE_OFFSET := 0.002
## How far a seated pak's face may sit off the shell it mates with. Half a
## millimetre: below that nobody sees a gap, above it the pak visibly floats.
const SEAT_TOLERANCE := 0.0005

var _pad: Node3D = null
var _port: Dictionary = {}
var _port_area := 0.0
var _ceiling := INF
var _fail := 0
var _pass := 0


func _ready() -> void:
	var video := false
	for a in OS.get_cmdline_user_args():
		if a == "--video":
			video = true
	await _run(video)
	print("[n64pak] %d passed, %d failed" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _ok(what: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		print("[n64pak] FAIL %s %s" % [what, detail])


func _run(video: bool) -> void:
	var packed: PackedScene = load(PAD)
	if packed == null:
		_fail += 1
		print("[n64pak] FAIL could not load " + PAD)
		return
	var pad: Node3D = packed.instantiate()
	# Freeze it. The pad is a RigidBody3D, so an unfrozen one FALLS while this
	# probe measures -- and it fell far enough between building the shell
	# collider and querying it that the two disagreed by a millimetre and the
	# port read as solid where it is open.
	if pad is RigidBody3D:
		(pad as RigidBody3D).freeze = true
	add_child(pad)
	await get_tree().process_frame

	_pad = pad
	var zone: Node3D = pad.get_node_or_null("ExpansionPort")
	_ok("port/exists", zone != null)
	if zone == null:
		return

	var mouth := _bay_mouth(pad)
	_ok("port/bay found", not is_nan(mouth), "no shell faces inside the bay footprint")
	if is_nan(mouth):
		return
	print("[n64pak] bay mouth y=%.5f   zone y=%.5f   (zone should sit %.4f below)"
		% [mouth, zone.position.y, PAK_FACE_OFFSET])
	_ok("port/zone stands 2mm proud of the bay mouth",
		absf((mouth - PAK_FACE_OFFSET) - zone.position.y) < SEAT_TOLERANCE,
		"mouth %.5f, zone %.5f, expected %.5f" % [mouth, zone.position.y, mouth - PAK_FACE_OFFSET])

	var space := await _shell_collider(pad)
	if space == null:
		return
	_sweep_port(space, mouth)
	_ceiling = _bay_ceiling(space, mouth)
	print("[n64pak] connector block sits %.1f mm above the mouth"
		% ((_ceiling - mouth) * 1000.0))
	_ok("port/opening found", _port_area > 1e-5,
		"swept the bay and found %.1f mm2 of open port" % (_port_area * 1e6))
	print("[n64pak] port opening: %.1f mm2 enclosed by the rim" % (_port_area * 1e6))

	for name: String in PAKS:
		_check_pak(pad, zone, name, mouth)

	await _check_receiver()

	if video:
		await _render(pad, zone)


## The pad receiver carries the same port, for the player on a real gamepad.
##
## Measured rather than eyeballed because its zone is turned a HALF TURN about Z
## -- a pak is authored to be pushed up into the underside of a controller, and
## here it is pushed down into a box on a table -- and because the boss it sits
## on has to be tall enough to swallow a 35 mm prong that a 20 mm case could not.
##
## RetroSystem reaches a pak by duck typing, so the two methods below are the
## whole contract on the system side; a receiver missing either is a pak that
## seats and does nothing.
func _check_receiver() -> void:
	var packed: PackedScene = load(RECEIVER)
	if packed == null:
		_ok("receiver/loads", false)
		return
	var rx: Node3D = packed.instantiate()
	if rx is RigidBody3D:
		(rx as RigidBody3D).freeze = true
	add_child(rx)
	await get_tree().process_frame

	_ok("receiver/answers get_pak", rx.has_method("get_pak"))
	_ok("receiver/answers pak_option_value", rx.has_method("pak_option_value"))
	# "" is "no port at all", which RetroSystem treats as "leave this port
	# alone". An empty port must say "none" instead, or a receiver would never
	# clear a pak the core had already fitted.
	_ok("receiver/an empty port reads none, not blank",
		str(rx.call("pak_option_value")) == "none",
		"read '%s'" % str(rx.call("pak_option_value")))

	var zone: Node3D = rx.get_node_or_null("ExpansionPort")
	_ok("receiver/has an expansion port", zone != null)
	if zone == null:
		rx.queue_free()
		return

	for name: String in PAKS:
		var pak: Node3D = (load(PAKS[name]) as PackedScene).instantiate()
		if pak is RigidBody3D:
			(pak as RigidBody3D).freeze = true
		rx.add_child(pak)
		pak.transform = zone.transform          # where the zone seats it
		var tongue: MeshInstance3D = pak.get_node_or_null("Tongue")
		if tongue == null:
			_ok("receiver/%s has a prong" % name, false)
			pak.queue_free()
			continue
		var xf: Transform3D = rx.global_transform.affine_inverse() * tongue.global_transform
		var tip: AABB = xf * tongue.get_aabb()
		# The prong must point DOWN into the case, not up into the air. This is
		# the case the half turn exists for, and the one an unrotated zone fails.
		_ok("receiver/%s prong points into the case" % name,
			tip.position.y < zone.position.y,
			"prong spans y %.4f..%.4f, port face is at %.4f"
			% [tip.position.y, tip.position.y + tip.size.y, zone.position.y])
		# ...and must stop inside it rather than come out through the underside
		# onto the table.
		_ok("receiver/%s prong stays inside the case" % name, tip.position.y > 0.0,
			"prong reaches y %.4f, the case bottom is 0" % tip.position.y)
		# The body stands proud on top, which is what a pak on a dongle looks
		# like: everything that is not the prong sits above the boss's face.
		var lowest := INF
		for n: Node in pak.find_children("*", "MeshInstance3D", true, false):
			var mi := n as MeshInstance3D
			if mi == tongue or mi.mesh == null or not mi.is_visible_in_tree():
				continue
			var b: AABB = (rx.global_transform.affine_inverse() * mi.global_transform) * mi.get_aabb()
			lowest = minf(lowest, b.position.y)
		_ok("receiver/%s body stands on the boss" % name,
			absf(lowest - (zone.position.y - PAK_FACE_OFFSET)) < SEAT_TOLERANCE,
			"body bottoms at %.4f, boss face is at %.4f"
			% [lowest, zone.position.y - PAK_FACE_OFFSET])
		pak.queue_free()
	rx.queue_free()
	await get_tree().process_frame


## A collider built from the shell mesh alone, on its own layer.
##
## Its own layer because the pad already carries two colliders that a ray from
## below meets FIRST -- its own body box and the pointer box, whose top stands
## above the whole controller -- so an unmasked sweep reports the port as solid
## everywhere and every check built on it passes for the wrong reason.
func _shell_collider(pad: Node3D) -> PhysicsDirectSpaceState3D:
	var shell: MeshInstance3D = null
	for n: Node in pad.find_children("*", "MeshInstance3D", true, false):
		if n.name == "Body":
			shell = n as MeshInstance3D
	_ok("port/shell found", shell != null and shell.mesh != null)
	if shell == null or shell.mesh == null:
		return null
	var body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	col.shape = shell.mesh.create_trimesh_shape()
	body.collision_layer = SHELL_PROBE_LAYER
	body.collision_mask = 0
	body.add_child(col)
	pad.add_child(body)
	body.global_transform = shell.global_transform
	await get_tree().physics_frame
	return pad.get_world_3d().direct_space_state


## A map of the port, swept once with rays and reused, rather than declared as
## constants -- so it keeps measuring whatever shell is actually in the scene.
##
## A cell counts as PORT only if a ray from below clears the rim plane AND the
## cell is enclosed by rim to its left and right. The enclosure test is the part
## that matters: without it every cell beyond the bay's boss also "clears the
## rim plane", for the trivial reason that there is no boss out there, and the
## port measured 2264 mm2 instead of its real 1130.
##
## Coordinates are PAD space; the rays are cast in GLOBAL space, which is not
## the same frame. Feeding pad-local numbers straight to intersect_ray samples a
## point centimetres from the one being asked about.
func _sweep_port(space: PhysicsDirectSpaceState3D, mouth: float) -> void:
	_port.clear()
	_port_area = 0.0
	var g: Transform3D = _pad.global_transform
	var nx := int((2.0 * BAY_X) / SWEEP_STEP) + 1
	var nz := int((BAY_Z.y - BAY_Z.x) / SWEEP_STEP) + 1
	for iz in nz:
		var z: float = BAY_Z.x + float(iz) * SWEEP_STEP
		var rim: Array[bool] = []
		for ix in nx:
			var x: float = -BAY_X + float(ix) * SWEEP_STEP
			var q := PhysicsRayQueryParameters3D.create(
				g * Vector3(x, mouth - 0.004, z), g * Vector3(x, mouth + 0.030, z))
			q.collision_mask = SHELL_PROBE_LAYER
			q.collide_with_areas = false
			var hit: Dictionary = space.intersect_ray(q)
			var is_rim := false
			if not hit.is_empty():
				var local: Vector3 = g.affine_inverse() * (hit["position"] as Vector3)
				is_rim = local.y <= mouth + 0.004
			rim.append(is_rim)
		var first := rim.find(true)
		var last := rim.rfind(true)
		if first < 0:
			continue
		for ix in range(first, last + 1):
			if not rim[ix]:
				_port[Vector2i(ix, iz)] = true
				_port_area += SWEEP_STEP * SWEEP_STEP


## The first thing a prong would meet inside the bay: the connector block that
## hangs in the well above the port. Measured, not written down, so it follows
## the shell.
func _bay_ceiling(space: PhysicsDirectSpaceState3D, mouth: float) -> float:
	var g: Transform3D = _pad.global_transform
	var lowest := INF
	for x in [-0.008, 0.0, 0.008]:
		for z in [-0.058, -0.055, -0.052]:
			var q := PhysicsRayQueryParameters3D.create(
				g * Vector3(x, mouth + 0.006, z), g * Vector3(x, mouth + 0.060, z))
			q.collision_mask = SHELL_PROBE_LAYER
			q.collide_with_areas = false
			var hit: Dictionary = space.intersect_ray(q)
			if not hit.is_empty():
				lowest = minf(lowest, (g.affine_inverse() * (hit["position"] as Vector3)).y)
	return lowest


## Is this pad-space point inside the port opening?
func _is_open(x: float, z: float) -> bool:
	var ix := int(round((x + BAY_X) / SWEEP_STEP))
	var iz := int(round((z - BAY_Z.x) / SWEEP_STEP))
	return _port.has(Vector2i(ix, iz))


## The bay mouth: the lowest point of the shell inside the bay's footprint.
##
## Read from the shell's mesh rather than written down, so this keeps measuring
## the asset that actually ships. If the shell is replaced again and the bay
## moves, this moves with it and the zone case below goes red -- which is the
## whole point, because that is the failure that would otherwise ship silently.
func _bay_mouth(pad: Node3D) -> float:
	var lowest := INF
	for n: Node in pad.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		if mi.mesh == null or mi.name != "Body":
			continue
		var xf: Transform3D = pad.global_transform.affine_inverse() * mi.global_transform
		for s in mi.mesh.get_surface_count():
			var verts: PackedVector3Array = mi.mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
			for v: Vector3 in verts:
				var p: Vector3 = xf * v
				if absf(p.x) <= BAY_X and p.z >= BAY_Z.x and p.z <= BAY_Z.y:
					lowest = minf(lowest, p.y)
	return NAN if is_inf(lowest) else lowest


func _check_pak(pad: Node3D, zone: Node3D, name: String, mouth: float) -> void:
	var packed: PackedScene = load(PAKS[name])
	if packed == null:
		_ok("%s/loads" % name, false)
		return
	var pak: Node3D = packed.instantiate()
	if pak is RigidBody3D:
		(pak as RigidBody3D).freeze = true
	pad.add_child(pak)
	# A snap zone puts the held object's ORIGIN on the zone. Seating one by hand
	# here is the same placement the zone makes, so what this measures is what a
	# player gets.
	pak.transform = Transform3D(Basis(), zone.position)

	var tongue: MeshInstance3D = pak.get_node_or_null("Tongue")
	_ok("%s/has an insert" % name, tongue != null)
	if tongue == null:
		pak.queue_free()
		return

	var tip: AABB = _local_aabb(pad, tongue)
	var top: float = tip.position.y + tip.size.y
	var reach: float = top - mouth
	_ok("%s/prong reaches inside the bay" % name, reach >= MIN_INSERTION,
		"prong reaches %.1f mm past the mouth, wanted at least %.1f mm"
		% [reach * 1000.0, MIN_INSERTION * 1000.0])
	# ...and stops short of what is in there. Both ends matter: too short reads
	# as a pak sitting on the hole, too long drives through the connector.
	if _ceiling < INF:
		_ok("%s/prong stops short of the connector" % name,
			top <= _ceiling - CONNECTOR_CLEARANCE,
			"prong tops out at %.1f mm, connector is at %.1f mm"
			% [top * 1000.0, _ceiling * 1000.0])

	# Every corner AND the middle of each edge must be over open port, not over
	# the rim. Corners alone would pass an insert that bulges across a tapered
	# end of the opening, which is the shape this port actually has.
	var blocked := 0
	for u in [0.0, 0.25, 0.5, 0.75, 1.0]:
		for v in [0.0, 0.25, 0.5, 0.75, 1.0]:
			var x: float = tip.position.x + tip.size.x * u
			var z: float = tip.position.z + tip.size.z * v
			if not _is_open(x, z):
				blocked += 1
	_ok("%s/insert clears the opening" % name, blocked == 0,
		"%d of 25 sampled points sit over the rim, not the hole" % blocked)

	# ...and it must FILL the port, not rattle around in it. This is the case
	# the reshape was for: the previous inserts were 28 x 8 mm in a 55 x 24 mm
	# opening and covered about a sixth of it.
	var fill: float = (tip.size.x * tip.size.z) / maxf(_port_area, 1e-9)
	_ok("%s/insert fills the port" % name, fill >= MIN_PORT_FILL,
		"insert covers %.0f%% of the opening, wanted at least %.0f%%"
		% [fill * 100.0, MIN_PORT_FILL * 100.0])

	# The body must stop AT the shell, not inside it: everything that is not the
	# insert has to sit at or below the bay mouth. A pak sunk into the shell and
	# a pak floating off it are both wrong, and only this catches the first.
	var highest := -INF
	for n: Node in pak.find_children("*", "MeshInstance3D", true, false):
		var mi := n as MeshInstance3D
		# is_visible_in_tree, not visible: every pak carries hand-pose scenes
		# whose ROOT is hidden while the meshes inside them are not, and those
		# poses sit up where the player's hand would be, 90 mm above the pak.
		if mi == tongue or mi.mesh == null or not mi.is_visible_in_tree():
			continue
		var b: AABB = _local_aabb(pad, mi)
		highest = maxf(highest, b.position.y + b.size.y)
	_ok("%s/body meets the shell" % name, absf(highest - mouth) < SEAT_TOLERANCE,
		"body tops out at %.5f, bay mouth is %.5f (gap %.4f mm)"
		% [highest, mouth, (highest - mouth) * 1000.0])

	if name == "TransferPak":
		_check_cartridge_bay(pak)
	pak.queue_free()


## The Transfer Pak's cartridge lies FLAT and slides in from the back.
##
## Checked against the bay's basis rather than eyeballed, because a .tscn stores
## a basis by ROWS while the Transform3D constructor takes COLUMNS, so a quarter
## turn written from memory comes out transposed -- and a transpose of a quarter
## turn is the OPPOSITE quarter turn, which still looks like "a cartridge in a
## slot" in a render. Note that a HALF turn cannot be checked this way at all:
## it is its own transpose.
##
## MediaDimensions authors a Game Boy cartridge standing up, 57 x 65 x 8, label
## toward +Y and edge connector at -Y.
func _check_cartridge_bay(pak: Node3D) -> void:
	var bay: Node3D = pak.get_node_or_null("CartridgeBay")
	_ok("TransferPak/has a cartridge bay", bay != null)
	if bay == null:
		return
	var b: Basis = bay.transform.basis
	var connector: Vector3 = b * Vector3(0, -1, 0)    # the cartridge's -Y end
	var face: Vector3 = b * Vector3(0, 0, 1)          # its broad face normal
	_ok("TransferPak/cartridge goes in contacts-first from the back",
		connector.dot(Vector3(0, 0, 1)) > 0.99,
		"connector ends up pointing %v, wanted +Z" % connector)
	_ok("TransferPak/cartridge lies flat rather than upright",
		absf(face.dot(Vector3(0, 1, 0))) > 0.99,
		"broad face ends up pointing %v, wanted +/-Y" % face)


func _local_aabb(pad: Node3D, mi: MeshInstance3D) -> AABB:
	var xf: Transform3D = pad.global_transform.affine_inverse() * mi.global_transform
	return xf * mi.get_aabb()


func _render(pad: Node3D, zone: Node3D) -> void:
	var sv := SubViewport.new()
	sv.size = SHOT
	sv.own_world_3d = true
	sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(sv)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.18, 0.19, 0.22)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.62, 0.64, 0.70)
	env.environment = e
	sv.add_child(env)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-28, -40, 0)
	key.light_energy = 2.0
	sv.add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(20, 150, 0)
	fill.light_energy = 0.8
	sv.add_child(fill)

	# The pad relaxes its own controls toward rest every frame it gets no joypad
	# state, which would fight anything this probe posed. Nothing is posed here,
	# so it changes no pixel today -- switched off so that stays true if a pose
	# is ever added. See n64_button_probe.gd for what it does when it bites.
	pad.set_process(false)

	var stage := Node3D.new()
	sv.add_child(stage)
	var model: Node3D = pad.get_node("Model")
	pad.remove_child(model)
	stage.add_child(model)

	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 0.20
	cam.near = 0.001
	cam.far = 10.0
	sv.add_child(cam)
	# From below and behind: the bay is on the underside at the rear, so the
	# insertion is invisible from any view that shows the button face. Framed
	# wide enough to keep the whole pad in shot -- a tight crop on the bay shows
	# the pak moving without showing what it is moving into.
	cam.position = Vector3(0.15, -0.17, -0.26)
	cam.look_at(Vector3(0.0, -0.052, -0.038), Vector3(0, 1, 0))
	cam.current = true

	var dir := "res://probe_out/n64_pak_video"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var n := 0
	for name: String in PAKS:
		var packed: PackedScene = load(PAKS[name])
		var pak: Node3D = packed.instantiate()
		# Freeze first: a pak is a RigidBody3D, and an unfrozen one falls under
		# gravity while this loop writes its position, so the render shows it
		# drifting away from the port rather than into it.
		if pak is RigidBody3D:
			(pak as RigidBody3D).freeze = true
		stage.add_child(pak)
		var seated: Vector3 = zone.position
		var start: Vector3 = seated - Vector3(0, 0.070, 0)
		var frames := 26
		for i in range(frames + 10):
			var t: float = clampf(float(i) / float(frames), 0.0, 1.0)
			# Ease out, so the pak slows as it meets the port instead of
			# arriving at full speed and stopping dead.
			t = 1.0 - pow(1.0 - t, 3.0)
			pak.position = start.lerp(seated, t)
			await _grab(sv, "%s/f%04d.png" % [dir, n])
			n += 1
		# The Transfer Pak gets a cartridge as well, because the way that goes in
		# is the whole point of its shape: flat and across the back, not
		# lengthways in line with the plug.
		if name == "TransferPak":
			n = await _load_cartridge(sv, stage, pak, dir, n)
		pak.queue_free()
		await get_tree().process_frame
	print("[n64pak] wrote %d frames to %s" % [n, dir])


## Capture one frame. The frame carries an unfilled alpha channel, so it is
## flattened before saving -- otherwise the PNG writes fully transparent and
## every viewer paints it blank white.
func _grab(sv: SubViewport, path: String) -> void:
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	var img := sv.get_texture().get_image()
	img.convert(Image.FORMAT_RGB8)
	img.save_png(path)


## Slide a Game Boy cartridge into the seated Transfer Pak, on camera.
func _load_cartridge(sv: SubViewport, stage: Node3D, pak: Node3D, dir: String,
		n: int) -> int:
	var bay: Node3D = pak.get_node_or_null("CartridgeBay")
	var packed: PackedScene = load(CART_SCENE)
	if bay == null or packed == null:
		return n
	var cart: Node3D = packed.instantiate()
	cart.systemid = "game_boy"
	if cart is RigidBody3D:
		(cart as RigidBody3D).freeze = true
	stage.add_child(cart)
	# Seated where the bay would put it, then backed off ALONG THE BAY'S OWN
	# -Z, so the approach follows the slot rather than an arbitrary world axis.
	var seated: Transform3D = pak.transform * bay.transform
	var back: Vector3 = seated.basis * Vector3(0, 1, 0)   # cartridge's +Y, out of the mouth
	for i in range(30 + 12):
		var t: float = clampf(float(i) / 30.0, 0.0, 1.0)
		t = 1.0 - pow(1.0 - t, 3.0)
		cart.transform = Transform3D(seated.basis, seated.origin + back * (0.075 * (1.0 - t)))
		await get_tree().process_frame
		await _grab(sv, "%s/f%04d.png" % [dir, n])
		n += 1
	cart.queue_free()
	await get_tree().process_frame
	return n
