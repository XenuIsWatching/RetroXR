extends Node

## Posters: image loading, the sheet's dimensions, sticking to a surface, riding
## the thing it stuck to, and the save/restore round trip.
##
##   godot --headless --path RetroXR res://Tests/poster_tests.tscn
##   godot --headless --path RetroXR res://Tests/poster_tests.tscn -- --only=stick
##
## Exits non-zero on failure, so it can gate a commit.
##
## Physics runs fine headless — the dummy renderer stubs RENDERING, not Jolt — so
## the stick cases are real: a body, a wall, a raycast and a reparent. What cannot
## be checked here is how any of it LOOKS; that needs a windowed probe.
##
## The image cases need a file to read, so the suite writes its own PNG (with a
## transparent corner, to exercise the alpha path) into the real posters folder and
## removes it at both ends.

const GROUPS := ["image", "stick", "release", "peel", "preview", "desktop", "roll", "conform", "menu", "persist"]
const SLOT := "__poster_selftest"
const TEST_IMAGE := "__poster_selftest.png"

var _fail := 0
var _ran := 0
var _only := ""
var _img_path := ""


func _ready() -> void:
	get_tree().create_timer(120.0).timeout.connect(func():
		print("[test] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.trim_prefix("--only=")

	_img_path = _write_test_image()
	if _img_path.is_empty():
		print("[test] could not write a test image")
		get_tree().quit(1)
		return

	if _want("image"):
		await _test_image()
	if _want("stick"):
		await _test_stick()
	if _want("release"):
		await _test_release()
	if _want("peel"):
		await _test_peel()
	if _want("preview"):
		await _test_preview()
	if _want("desktop"):
		await _test_desktop()
	if _want("roll"):
		await _test_roll()
		await _test_inherit_roll()
	if _want("conform"):
		await _test_conform()
	if _want("menu"):
		await _test_menu()
	if _want("persist"):
		await _test_persist()

	_cleanup()
	print("[test] %d cases, %s" % [_ran,
		"PASS" if _fail == 0 else "%d FAILURE(S)" % _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ── The image, and the sheet it sizes ─────────────────────────────────────────

func _test_image() -> void:
	var listed := RomLibrary.scan_posters()
	var names: Array = []
	for e: Dictionary in listed:
		names.append(str(e["path"]))
	_ok(_img_path in names, "image/scan_posters finds a dropped file")

	var p := _make_poster()
	await get_tree().process_frame

	# 160x120 source, so 4:3, and the long edge is the one that measures 0.5.
	var sz: Vector2 = p.get_sheet_size()
	_ok(absf(sz.x - 0.5) < 0.001, "image/long edge is 0.5 m (%.3f)" % sz.x)
	_ok(absf(sz.y - 0.375) < 0.001, "image/short edge follows the aspect (%.3f)" % sz.y)

	var mesh := p.get_node("Surface/FlatMesh") as MeshInstance3D
	_ok((mesh.mesh as QuadMesh).size.is_equal_approx(sz), "image/quad matches the sheet")

	var mat := mesh.get_surface_override_material(0) as StandardMaterial3D
	_ok(mat != null, "image/a material was built")
	# The trap: ALPHA would put this in the transparent pass with depth writes off,
	# and two posters would then sort per-triangle against each other.
	_ok(mat.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR,
		"image/an image with alpha uses SCISSOR, not blend")
	_ok(mat.albedo_texture.get_image().has_mipmaps(), "image/mipmaps generated")
	_ok(mat.emission_enabled and absf(mat.emission_energy_multiplier - 0.1) < 0.001,
		"image/emission at 0.1, as the room's own posters carry")

	# One scalar drives both edges, so the aspect cannot drift.
	p.size_scale = 2.0
	await get_tree().process_frame
	var big: Vector2 = p.get_sheet_size()
	_ok(absf(big.x - 1.0) < 0.001, "image/resize scales the long edge (%.3f)" % big.x)
	_ok(absf((big.x / big.y) - (sz.x / sz.y)) < 0.0001, "image/aspect survives a resize")
	var box := (p.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	_ok(absf(box.size.x - big.x) < 0.001, "image/the collider followed the resize")

	# A .tscn sub-resource is shared unless it says otherwise, and these are written
	# per instance — so resizing one poster must not resize the next.
	var q := _make_poster()
	await get_tree().process_frame
	var qbox := (q.get_node("CollisionShape3D") as CollisionShape3D).shape as BoxShape3D
	_ok(not is_equal_approx(qbox.size.x, box.size.x),
		"image/each poster owns its own mesh and shapes")

	# An image that has been deleted must not crash the spawn.
	var gone := _make_poster("user://__no_such_poster.png")
	await get_tree().process_frame
	_ok(is_instance_valid(gone), "image/a missing file still spawns a sheet")

	p.queue_free()
	q.queue_free()
	gone.queue_free()
	await get_tree().process_frame


# ── Sticking, riding, peeling ─────────────────────────────────────────────────

func _test_stick() -> void:
	var wall := _make_wall(Vector3(0, 1.5, -2.0))
	await get_tree().physics_frame

	var p := _make_poster()
	await get_tree().process_frame
	p.global_transform = Transform3D(Basis(), Vector3(0, 1.5, -1.88))

	# A RAY release, which is how a poster reaches a far wall — and the case a
	# dropped-driven stick would miss entirely, because _end_ray_grab restores the
	# body itself and never calls let_go().
	await _release(p)

	_ok(p.is_stuck(), "stick/sticks on a ray-style release, with no dropped signal")
	_ok(p.stick_target() == wall, "stick/the wall is the host")
	_ok(p.get_parent() == wall, "stick/reparented so it rides the host")
	_ok(p.freeze, "stick/parked, so it cannot be knocked off")
	# Wall centre -2.0, half-depth 0.075 -> face at -1.925, plus the 2 mm skin.
	_ok(absf(p.global_position.z - (-1.923)) < 0.01,
		"stick/sits on the wall face (z %.4f)" % p.global_position.z)
	_ok(p.global_transform.basis.z.dot(Vector3(0, 0, 1)) > 0.99, "stick/faces the room")
	_ok(absf(p.global_transform.basis.y.dot(Vector3.UP) - 1.0) < 0.01, "stick/hangs upright")

	# The whole point of reparenting: carrying the host carries the poster.
	var before: Vector3 = p.global_position
	wall.global_position += Vector3(0.5, 0.25, 0.0)
	await get_tree().physics_frame
	_ok(p.global_position.distance_to(before + Vector3(0.5, 0.25, 0.0)) < 0.001,
		"stick/rides the host when it moves")

	# A grab IS the peel — every hold restores freeze on its own.
	p.picked_up.emit(p)
	await get_tree().physics_frame
	_ok(not p.is_stuck(), "stick/a grab peels it")
	_ok(p.get_parent() != wall, "stick/peeling hands it back to the room")

	# Released against nothing, it stays loose rather than sticking to air.
	var loose := _make_poster()
	await get_tree().process_frame
	loose.global_transform = Transform3D(Basis(), Vector3(6, 1.5, 6))
	await _release(loose)
	_ok(not loose.is_stuck(), "stick/nothing in reach means no stick")

	p.queue_free()
	loose.queue_free()
	wall.queue_free()
	await get_tree().process_frame


# ── Save and restore ──────────────────────────────────────────────────────────

func _test_persist() -> void:
	var sp := ScenePersistence.new("arcade")
	var wall := _make_wall(Vector3(0, 1.5, -2.0))
	await get_tree().physics_frame

	var p := _make_poster()
	p.add_to_group("spawned")
	await get_tree().process_frame
	p.size_scale = 1.75
	p.global_transform = Transform3D(Basis(), Vector3(0.4, 1.5, -1.88))
	await _release(p)
	_ok(p.is_stuck(), "persist/stuck before saving")

	_ok(sp.save_slot(self, SLOT), "persist/saved")

	# Read the file, not just the room: this is what separates "recorded wrong"
	# from "restored wrong", and the two need different fixes.
	var file := "user://scenes/arcade/%s.json" % SLOT
	var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(file))
	var entry: Dictionary = {}
	for o: Variant in (raw as Dictionary).get("objects", []):
		if str((o as Dictionary).get("type", "")) == "poster":
			entry = o as Dictionary
	_ok(not entry.is_empty(), "persist/a poster entry reached the file")
	_ok(str(entry.get("image_path", "")) == _img_path, "persist/image_path recorded")
	_ok(absf(float(entry.get("size_scale", 0.0)) - 1.75) < 0.001, "persist/size recorded")
	_ok(bool(entry.get("stuck", false)), "persist/stuck recorded")

	sp.clear_scene(self)
	for i in range(20):
		await get_tree().physics_frame
	_eq(_count_posters(), 0, "persist/cleared")

	await sp.load_slot_async(self, SLOT)
	for i in range(40):
		await get_tree().physics_frame
	_eq(_count_posters(), 1, "persist/restored exactly one")

	var back: Poster = null
	for n in get_tree().get_nodes_in_group("spawned"):
		if n is Poster:
			back = n as Poster
	if back != null:
		_ok(back.image_path == _img_path, "persist/image came back")
		_ok(absf(back.size_scale - 1.75) < 0.001, "persist/size came back")
		_ok(absf(back.get_sheet_size().x - 0.875) < 0.002,
			"persist/dimensions re-derived from the restored size")
		_ok(back.is_stuck(), "persist/came back stuck to the wall")
		# The restore hands gravity back to everything it froze; a stuck poster
		# must not take that as permission to fall.
		var settled: Vector3 = back.global_position
		for i in range(30):
			await get_tree().physics_frame
		_ok(back.global_position.distance_to(settled) < 0.005,
			"persist/did not fall after the restore let go")

	sp.clear_scene(self)
	for i in range(10):
		await get_tree().physics_frame
	wall.queue_free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(file))


# ── Harness ───────────────────────────────────────────────────────────────────

func _want(name: String) -> bool:
	return _only.is_empty() or _only == name


func _make_poster(path: String = "") -> Poster:
	var p := preload("res://Scenes/Objects/media/poster.tscn").instantiate() as Poster
	p.image_path = _img_path if path.is_empty() else path
	add_child(p)
	return p


## Mesh AND collider at the same size, the way the rooms author their walls —
## which is what makes the poster_flat opt-out worth testing: without a mesh
## there is nothing to sample and conform would bail for the wrong reason.
func _make_wall(at: Vector3) -> StaticBody3D:
	var wall := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4, 3, 0.15)
	cs.shape = box
	wall.add_child(cs)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = box.size
	mi.mesh = bm
	wall.add_child(mi)
	add_child(wall)
	wall.global_position = at
	return wall


## Hold then release the way a ray grab does: freeze on, freeze off, and no signal
## in between.
func _release(p: Poster) -> void:
	p.freeze = true
	for i in range(4):
		await get_tree().physics_frame
	p.freeze = false
	for i in range(14):
		await get_tree().physics_frame


func _count_posters() -> int:
	var n := 0
	for x in get_tree().get_nodes_in_group("spawned"):
		if x is Poster:
			n += 1
	return n


## A 160x120 PNG with one transparent corner, written into the real posters folder
## — scan_posters derives that path and it cannot be pointed anywhere safer.
func _write_test_image() -> String:
	var dir := RomLibrary.default_posters_root()
	DirAccess.make_dir_recursive_absolute(dir)
	var img := Image.create(160, 120, false, Image.FORMAT_RGBA8)
	for y in range(120):
		for x in range(160):
			var a := 0.0 if (x < 40 and y < 30) else 1.0
			img.set_pixel(x, y, Color(float(x) / 160.0, float(y) / 120.0, 0.8, a))
	var path := dir.path_join(TEST_IMAGE)
	if img.save_png(path) != OK:
		return ""
	return path


func _cleanup() -> void:
	if not _img_path.is_empty():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_img_path))
	var slot := ProjectSettings.globalize_path("user://scenes/arcade/%s.json" % SLOT)
	if FileAccess.file_exists(slot):
		DirAccess.remove_absolute(slot)


func _ok(cond: bool, what: String) -> void:
	_ran += 1
	if cond:
		print("[test] ok   %s" % what)
	else:
		_fail += 1
		print("[test] FAIL %s" % what)


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what if got == want else "%s (got %s, want %s)" % [what, got, want])


# ── Conforming to a curved surface ────────────────────────────────────────────

func _test_conform() -> void:
	# A cylinder standing on Y, so its circle is in X-Z and the sheet has to wrap
	# around it horizontally. Radius 0.4, roughly a CRT shoulder.
	var host := StaticBody3D.new()
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.4
	cyl.bottom_radius = 0.4
	cyl.height = 2.0
	mi.mesh = cyl
	host.add_child(mi)
	var cs := CollisionShape3D.new()
	# A deliberately crude collider — a box around the cylinder, the way most of
	# the room's GLB furniture is wrapped. Conform must ignore it and read the mesh.
	var box := BoxShape3D.new()
	box.size = Vector3(0.8, 2.0, 0.8)
	cs.shape = box
	host.add_child(cs)
	add_child(host)
	host.global_position = Vector3(0, 1.2, -3.0)
	await get_tree().physics_frame

	var p := _make_poster()
	await get_tree().process_frame
	p.size_scale = 0.6                      # 0.3 x 0.225, well inside the barrel
	p.global_transform = Transform3D(Basis(), Vector3(0, 1.2, -2.55))
	await _release(p)
	_ok(p.is_stuck(), "conform/stuck to the cylinder")

	p.set_fit_mode(Poster.FitMode.CONFORM)
	for i in range(20):
		await get_tree().physics_frame

	var cm := p.get_node_or_null("Surface/ConformMesh") as MeshInstance3D
	_ok(cm != null and cm.mesh != null, "conform/a wrapped mesh was built")
	if cm == null or cm.mesh == null:
		host.queue_free()
		p.queue_free()
		return
	_ok(not (p.get_node("Surface/FlatMesh") as MeshInstance3D).visible,
		"conform/the flat quad gives way to it")

	var arrays := cm.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	_ok(verts.size() > 40, "conform/subdivided (%d verts)" % verts.size())
	_ok(norms.size() == verts.size() and uvs.size() == verts.size(),
		"conform/normals and UVs per vertex")

	# The real check: every vertex should sit on the cylinder, 0.4 from its axis.
	# A flat sheet would leave the corners short by centimetres.
	var worst := 0.0
	var flat_worst := 0.0
	for i in range(verts.size()):
		var world: Vector3 = p.global_transform * verts[i]
		var rel := world - host.global_position
		var r := Vector2(rel.x, rel.z).length()
		worst = maxf(worst, absf(r - 0.4))
		# Same point if the sheet had stayed flat (z of the vertex zeroed).
		var flat_v: Vector3 = Vector3(verts[i].x, verts[i].y, 0.0)
		var fw: Vector3 = p.global_transform * flat_v
		var frel := fw - host.global_position
		flat_worst = maxf(flat_worst, absf(Vector2(frel.x, frel.z).length() - 0.4))
	_ok(worst < 0.006, "conform/every vertex lies on the cylinder (worst %.4f m)" % worst)
	_ok(flat_worst > worst * 2.0,
		"conform/and a flat sheet would not (flat worst %.4f m)" % flat_worst)

	# Normals must be smooth, not the facets a trimesh hit reports. Compared along a
	# ROW: consecutive array indices wrap from one edge of the sheet to the other,
	# where the normals genuinely differ by the whole wrap angle.
	var w := 18   # nx + 1 for this sheet
	var min_dot := 1.0
	for k in range(norms.size()):
		if (k + 1) % w == 0:
			continue
		min_dot = minf(min_dot, norms[k].dot(norms[k + 1]))
	_ok(min_dot > 0.99, "conform/normals vary smoothly along a row (worst %.4f)" % min_dot)

	# UVs still span the sheet exactly, so the art fills it.
	var umin := 2.0
	var umax := -1.0
	for uv in uvs:
		umin = minf(umin, uv.x)
		umax = maxf(umax, uv.x)
	_ok(absf(umin) < 0.001 and absf(umax - 1.0) < 0.001,
		"conform/UVs still span 0..1 (%.3f..%.3f)" % [umin, umax])

	# A wall is tagged as its own surface, so it must NOT be sampled.
	var wall := _make_wall(Vector3(0, 1.5, 4.0))
	wall.add_to_group("poster_flat")
	await get_tree().physics_frame
	var wp := _make_poster()
	await get_tree().process_frame
	# In FRONT of the wall for a sheet whose probe runs along its own -Z.
	wp.global_transform = Transform3D(Basis(), Vector3(0, 1.5, 4.12))
	wp.fit_mode = Poster.FitMode.CONFORM
	await _release(wp)
	for i in range(20):
		await get_tree().physics_frame
	_ok(wp.is_stuck(), "conform/the wall poster stuck at all")
	_ok(wp.get_node_or_null("Surface/ConformMesh") == null,
		"conform/a poster_flat surface is never sampled")
	_ok((wp.get_node("Surface/FlatMesh") as MeshInstance3D).visible,
		"conform/it stays a flat quad")

	p.queue_free()
	wp.queue_free()
	host.queue_free()
	wall.queue_free()
	await get_tree().process_frame


# ── The options menu contract ─────────────────────────────────────────────────

func _test_menu() -> void:
	var p := _make_poster()
	await get_tree().process_frame

	# The controller finds a host by TYPE and then calls this without checking, so
	# a poster registered in those chains must answer it.
	_ok(p.has_method("toggle_options_ui"), "menu/the poster exports toggle_options_ui")

	var src := FileAccess.get_file_as_string(
		"res://Scripts/UI/spawn_menu/spawn_menu_controller.gd")
	# BOTH chains — the VR pointer's and the desktop Tab's. Missing either means the
	# menu silently does nothing on that platform. The chains used to name each
	# type; they now ask the object, and a poster is a pickable with a menu of
	# its own, so it is matched by either half of that test.
	_eq(src.count('node.has_method("toggle_options_ui") or node is XRToolsPickable'), 2,
		"menu/registered in both host chains")

	var panel := p.get_node_or_null("PosterOptionsPanel")
	_ok(panel != null, "menu/the panel is on the poster")
	_ok(panel != null and not panel.visible, "menu/and starts hidden")
	p.toggle_options_ui(null)
	_ok(panel != null and panel.visible, "menu/opens")
	p.toggle_options_ui(null)
	_ok(panel != null and not panel.visible, "menu/and closes again")

	# Peel is offered as a verb too, for a poster out of arm's reach.
	_ok(p.has_method("peel"), "menu/peel is callable without a grab")
	p.peel()
	_ok(not p.is_stuck(), "menu/peeling an unstuck poster is safe")

	p.queue_free()
	await get_tree().process_frame


# ── Releasing it the way a player actually does ───────────────────────────────
#
# The cases above place the sheet 2 cm from the wall and perfectly square, which
# is not how anyone holds a poster. These are the real gestures: at arm's length,
# at an angle, and facing the wrong way round.

func _test_release() -> void:
	var wall := _make_wall(Vector3(0, 1.5, -2.0))
	await get_tree().physics_frame

	# 1. Let go at arm's length rather than pressed against the plaster.
	var far := _make_poster()
	await get_tree().process_frame
	far.global_transform = Transform3D(Basis(), Vector3(0, 1.5, -1.68))
	await _release(far)
	_ok(far.is_stuck(), "release/sticks from a hand's length away")

	# 2. Held at an angle, as a hand holds it.
	var tilted := _make_poster()
	await get_tree().process_frame
	var b := Basis(Vector3.UP, deg_to_rad(22.0)) * Basis(Vector3.RIGHT, deg_to_rad(-14.0))
	tilted.global_transform = Transform3D(b, Vector3(-0.4, 1.5, -1.74))
	await _release(tilted)
	_ok(tilted.is_stuck(), "release/sticks when held at an angle")
	if tilted.is_stuck():
		_ok(tilted.global_transform.basis.z.dot(Vector3(0, 0, 1)) > 0.99,
			"release/and squares up to the wall it found")

	# 3. Facing the wrong way — the sheet's back to the wall. Nothing about a
	#    poster says which face the player had toward them.
	var backwards := _make_poster()
	await get_tree().process_frame
	backwards.global_transform = Transform3D(Basis(Vector3.UP, PI), Vector3(0.5, 1.5, -1.74))
	await _release(backwards)
	_ok(backwards.is_stuck(), "release/sticks when held back-to-front")

	# 4. THE RAY GESTURE, which is how a poster reaches a far wall. The sheet
	#    floats at the beam's hold distance, facing however it was grabbed — so
	#    its own faces look at nothing and only the aim knows what was chosen.
	var aimed := _make_poster()
	await get_tree().process_frame
	aimed.global_transform = Transform3D(Basis(Vector3.UP, deg_to_rad(70.0)),
		Vector3(0, 1.5, -0.6))          # 1.3 m out from the wall, turned away
	aimed.set_aim_direction(Vector3(0, 0, -1))
	await _release(aimed)
	_ok(aimed.is_stuck(), "release/a ray release sticks where the beam points")
	if aimed.is_stuck():
		_ok(absf(aimed.global_position.z - (-1.923)) < 0.01,
			"release/and lands on that wall, not where it floated (z %.3f)"
				% aimed.global_position.z)
	aimed.queue_free()

	# 5. An OBJECT, not the room. A television is an XRToolsPickable on the
	#    Pickable layer, not world geometry — a probe that searched only World
	#    stuck to every wall and passed straight through every machine.
	var prop := RigidBody3D.new()
	prop.freeze = true
	prop.collision_layer = 4          # Pickable, exactly as a TV or console is
	var pcs := CollisionShape3D.new()
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(0.6, 0.5, 0.4)
	pcs.shape = pbox
	prop.add_child(pcs)
	add_child(prop)
	prop.global_position = Vector3(2.5, 1.2, -1.0)
	await get_tree().physics_frame
	var on_prop := _make_poster()
	await get_tree().process_frame
	on_prop.size_scale = 0.5
	on_prop.global_transform = Transform3D(Basis(), Vector3(2.5, 1.2, -0.66))
	await _release(on_prop)
	_ok(on_prop.is_stuck(), "release/sticks to an object, not just the room")
	_ok(on_prop.is_stuck() and on_prop.get_parent() == prop,
		"release/and rides that object")
	on_prop.queue_free()
	prop.queue_free()

	far.queue_free()
	tilted.queue_free()
	backwards.queue_free()
	wall.queue_free()
	await get_tree().process_frame


# ── Taking one back off ───────────────────────────────────────────────────────
#
# A parked poster is FROZEN, and every hold snapshots `freeze` into
# `restore_freeze` and hands it back on release. So picking a stuck poster up and
# letting go left it hanging in mid-air: the release faithfully restored the park.
# The snapshot has to be corrected, not just the flag — the same correction
# RetroTV._on_tv_grabbed makes for its own park.

func _test_peel() -> void:
	var wall := _make_wall(Vector3(0, 1.5, -2.0))
	await get_tree().physics_frame

	# By hand.
	var p := _make_poster()
	await get_tree().process_frame
	p.global_transform = Transform3D(Basis(), Vector3(0, 1.5, -1.80))
	await _release(p)
	_ok(p.is_stuck(), "peel/stuck to begin with")

	_grab(p)
	_ok(not p.is_stuck(), "peel/a grab takes it off the surface")
	_ok(not p.restore_freeze,
		"peel/and clears the park the release would otherwise restore")
	_let_go(p)
	for i in range(6):
		await get_tree().physics_frame
	_ok(not p.freeze, "peel/it is live again after the drop")
	var y0: float = p.global_position.y
	for i in range(25):
		await get_tree().physics_frame
	_ok(p.global_position.y < y0 - 0.02,
		"peel/and falls instead of hanging (dropped %.3f m)" % (y0 - p.global_position.y))

	# By ray, which fires no signal at all — the poster has to notice the beam.
	var r := _make_poster()
	await get_tree().process_frame
	r.global_transform = Transform3D(Basis(), Vector3(0.6, 1.5, -1.80))
	await _release(r)
	_ok(r.is_stuck(), "peel/second one stuck")
	r.peel()
	_ok(not r.is_stuck(), "peel/the menu verb takes it off too")
	_ok(not r.freeze, "peel/and hands it straight back to physics")

	p.queue_free()
	r.queue_free()
	wall.queue_free()
	await get_tree().process_frame


## What XRToolsPickable.pick_up does to the body, without a controller.
func _grab(p: Poster) -> void:
	p.restore_freeze = p.freeze
	p.freeze = true
	p.picked_up.emit(p)


## ...and what let_go does.
func _let_go(p: Poster) -> void:
	p.freeze = p.restore_freeze


# ── Preview and hover feedback ────────────────────────────────────────────────

func _test_preview() -> void:
	var wall := _make_wall(Vector3(0, 1.5, -2.0))
	await get_tree().physics_frame
	var p := _make_poster()
	await get_tree().process_frame
	p.global_transform = Transform3D(Basis(), Vector3(0, 1.5, -1.0))
	# Held on a beam aimed at the wall — the case the preview exists for. A hand
	# never holds it a metre out and expects it to fly.
	p.set_aim_direction(Vector3(0, 0, -1))

	# The preview and the commit must come from the same arithmetic, or the ghost
	# lies about where the sheet lands.
	var predicted: Dictionary = p.predict_stick()
	_ok(not predicted.is_empty(), "preview/a landing is predicted from a held pose")
	var pose: Transform3D = p.pose_for_stick(predicted)
	await _release(p)
	_ok(p.is_stuck(), "preview/it then sticks")
	_ok(p.global_position.distance_to(pose.origin) < 0.001,
		"preview/exactly where the preview said (%.4f m off)"
			% p.global_position.distance_to(pose.origin))

	# The hint glyph is the one asked for, and only shows while previewing.
	var hint := p.get_node_or_null("StickHint") as Label3D
	_ok(hint != null, "preview/there is a stick hint")
	if hint != null:
		_eq(hint.text, String.chr(0xF136B), "preview/it prints the sticker glyph")
		_ok(not hint.visible, "preview/hidden once it has landed")

	# Hover outline.
	var outline := p.get_node_or_null("Surface/HoverOutline") as MeshInstance3D
	_ok(outline != null, "preview/there is a hover outline")
	if outline != null:
		_ok(not outline.visible, "preview/off until something points at it")
		p.request_highlight(self, true)
		_ok(outline.visible, "preview/on when it can be picked up")
		p.request_highlight(self, false)
		_ok(not outline.visible, "preview/off again")
		var sz: Vector2 = p.get_sheet_size()
		_ok((outline.mesh as QuadMesh).size.x > sz.x,
			"preview/and stands proud of the sheet")

	# And on while a LOOSE poster is held, with nothing pointing at it: both the
	# hand and the beam drop the highlight at pick-up, so the rim would otherwise
	# go dark exactly while you are aiming the thing you are holding. A fresh
	# sheet, because the one above is already on the wall.
	var loose := _make_poster()
	await get_tree().process_frame
	loose.global_transform = Transform3D(Basis(), Vector3(8, 1.5, 8))
	var lo := loose.get_node("Surface/HoverOutline") as MeshInstance3D
	_ok(not lo.visible, "preview/a loose poster lying about has no rim")
	loose.freeze = true
	await get_tree().process_frame
	_ok(lo.visible, "preview/on while held, even unstuck")
	loose.freeze = false
	await get_tree().process_frame
	_ok(not lo.visible, "preview/off once let go")
	loose.queue_free()

	p.queue_free()
	wall.queue_free()
	await get_tree().process_frame


# ── Desktop resize, and a rim that follows the art ────────────────────────────

func _test_desktop() -> void:
	var p := _make_poster()
	await get_tree().process_frame

	# Q/E only bite while it is held and not already on a surface.
	var before := p.size_scale
	Input.action_press("ui_accept")   # unrelated key, to prove nothing else moves it
	await get_tree().process_frame
	Input.action_release("ui_accept")
	_ok(is_equal_approx(p.size_scale, before), "desktop/an unrelated key changes nothing")

	# A sticker, not just a poster: 0.05x is a 25 mm badge on a console.
	p.size_scale = 0.05
	await get_tree().process_frame
	_ok(absf(p.size_scale - 0.05) < 0.0001, "desktop/scales down to 0.05x")
	_ok(absf(p.get_sheet_size().x - 0.025) < 0.0005,
		"desktop/which is a 25 mm sheet (%.4f m)" % p.get_sheet_size().x)
	p.size_scale = 0.001
	_ok(absf(p.size_scale - 0.05) < 0.0001, "desktop/and no smaller")
	p.size_scale = 99.0
	_ok(absf(p.size_scale - 3.0) < 0.0001, "desktop/still capped at 3x")
	p.size_scale = 1.0
	await get_tree().process_frame

	# The rim samples the poster's own alpha rather than covering its rectangle —
	# a die-cut star must not light up as a slab.
	var outline := p.get_node("Surface/HoverOutline") as MeshInstance3D
	var mat := outline.material_override as ShaderMaterial
	_ok(mat != null, "desktop/the rim is a shader, not a plain quad")
	if mat != null:
		_ok(mat.get_shader_parameter("poster_tex") != null,
			"desktop/it is given the poster's own texture to cut itself out with")
		_ok(absf(float(mat.get_shader_parameter("cutoff")) - 0.5) < 0.001,
			"desktop/at the same threshold the sheet scissors at")
		var src := FileAccess.get_file_as_string("res://Shaders/poster_outline.gdshader")
		# ALPHA would move it to the transparent pass and cost depth writes.
		_ok(src.contains("discard") and not src.contains("ALPHA ="),
			"desktop/and discards rather than writing ALPHA")

	p.queue_free()
	await get_tree().process_frame


# ── Turning one on the wall ───────────────────────────────────────────────────

func _test_roll() -> void:
	var wall := _make_wall(Vector3(0, 1.5, -2.0))
	await get_tree().physics_frame
	var p := _make_poster()
	await get_tree().process_frame
	p.global_transform = Transform3D(Basis(), Vector3(0, 1.5, -1.80))
	await _release(p)
	_ok(p.is_stuck(), "roll/stuck to begin with")

	# Square to the world when it lands — the right first guess.
	_ok(absf(p.global_transform.basis.y.dot(Vector3.UP) - 1.0) < 0.01,
		"roll/lands upright")
	var at: Vector3 = p.global_position

	p.rotate_cw()
	await get_tree().process_frame
	_ok(absf(p.roll_degrees - 15.0) < 0.001, "roll/one step clockwise is 15 deg")
	# Turned in the plane of the wall: the face still points out of it, and the
	# sheet has not moved off its anchor.
	_ok(p.global_transform.basis.z.dot(Vector3(0, 0, 1)) > 0.999,
		"roll/still lies flat on the wall")
	_ok(p.global_position.distance_to(at) < 0.001, "roll/and spins in place")
	var tilt := rad_to_deg(acos(clampf(p.global_transform.basis.y.dot(Vector3.UP), -1.0, 1.0)))
	_ok(absf(tilt - 15.0) < 0.5, "roll/the sheet really turned (%.1f deg)" % tilt)

	for i in range(3):
		p.rotate_ccw()
	await get_tree().process_frame
	_ok(absf(p.roll_degrees - (-30.0)) < 0.001, "roll/steps back the other way")

	# It has to survive a save, or a hung room comes back straightened.
	var sp := ScenePersistence.new("arcade")
	p.add_to_group("spawned")
	_ok(sp.save_slot(self, SLOT), "roll/saved")
	var raw: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("user://scenes/arcade/%s.json" % SLOT))
	var entry: Dictionary = {}
	for o: Variant in (raw as Dictionary).get("objects", []):
		if str((o as Dictionary).get("type", "")) == "poster":
			entry = o as Dictionary
	_ok(absf(float(entry.get("roll", 0.0)) - (-30.0)) < 0.001, "roll/recorded")

	sp.clear_scene(self)
	for i in range(20):
		await get_tree().physics_frame
	await sp.load_slot_async(self, SLOT)
	for i in range(40):
		await get_tree().physics_frame
	var back: Poster = null
	for n in get_tree().get_nodes_in_group("spawned"):
		if n is Poster:
			back = n as Poster
	_ok(back != null and absf(back.roll_degrees - (-30.0)) < 0.001,
		"roll/came back turned")
	if back != null and back.is_stuck():
		var t2 := rad_to_deg(acos(clampf(back.global_transform.basis.y.dot(Vector3.UP), -1.0, 1.0)))
		_ok(absf(t2 - 30.0) < 1.0, "roll/and is actually hanging at that angle (%.1f)" % t2)

	sp.clear_scene(self)
	for i in range(10):
		await get_tree().physics_frame
	DirAccess.remove_absolute(ProjectSettings.globalize_path(
		"user://scenes/arcade/%s.json" % SLOT))
	wall.queue_free()
	await get_tree().process_frame


## The off-hand stick already turns a ray-held object; landing used to square that
## away. A beam release keeps the angle, a hand release still squares up.

func _test_inherit_roll() -> void:
	var wall := _make_wall(Vector3(0, 1.5, -2.0))
	await get_tree().physics_frame

	# Beam: held turned 25 deg about the beam axis, aimed at the wall.
	var beam := _make_poster()
	await get_tree().process_frame
	beam.global_transform = Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(25.0)),
		Vector3(-0.5, 1.5, -1.0))
	beam.set_aim_direction(Vector3(0, 0, -1))
	await _release(beam)
	_ok(beam.is_stuck(), "inherit/a turned sheet still sticks")
	_ok(absf(beam.roll_degrees - 25.0) < 1.0,
		"inherit/it lands at the angle it was held (%.1f deg)" % beam.roll_degrees)
	var tilt := rad_to_deg(acos(clampf(
		beam.global_transform.basis.y.dot(Vector3.UP), -1.0, 1.0)))
	_ok(absf(tilt - 25.0) < 1.0, "inherit/and really hangs at it (%.1f)" % tilt)

	# Hand: same tilt, no beam. A wrist is not a deliberate angle.
	var hand := _make_poster()
	await get_tree().process_frame
	hand.global_transform = Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(25.0)),
		Vector3(0.5, 1.5, -1.80))
	await _release(hand)
	_ok(hand.is_stuck(), "inherit/a hand-placed sheet sticks")
	_ok(absf(hand.roll_degrees) < 0.001, "inherit/and squares up instead")

	beam.queue_free()
	hand.queue_free()
	wall.queue_free()
	await get_tree().process_frame
