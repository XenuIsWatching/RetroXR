## TestSceneBuilder — generates the "generations" test hallway.
##
## One station per system: a table, the system's TV (or a vertical PAIR of TVs
## for dual-screen handhelds), and the system itself sitting beside it with its
## video-out cable ALREADY plugged into the TV. Stations alternate left/right
## down a corridor and are grouped into a titled section per console generation.
##
## Everything is derived from GENERATIONS below — add a row there and the
## hallway lengthens, the signs renumber and the cabling wires itself. The
## corridor shell (floor/walls/ceiling/lights) is sized to fit the same table,
## which is why it is generated here rather than authored in the .tscn.
##
## Wiring reuses the save-restore path (RetroSystem.restore_cable_connection),
## so a station comes up in exactly the state a loaded save would produce.
class_name TestSceneBuilder
extends Node3D


const SYSTEM_SCENE := preload("res://Scenes/Objects/system.tscn")
const TV_SCENE := preload("res://Scenes/Objects/tv.tscn")

# --- Layout (metres) ---------------------------------------------------------

const HALL_HALF_WIDTH := 2.6      ## wall inner face at x = ±this
const WALL_HEIGHT := 3.0
const WALL_THICK := 0.15

const TABLE_W := 1.5              ## across the bay (local X)
const TABLE_D := 0.7              ## into the wall (local Z)
const TABLE_TOP_Y := 0.75
const TABLE_THICK := 0.05

const ROW_PITCH := 1.75           ## z-spacing between opposing table pairs
const SECTION_GAP := 1.0          ## extra z before each generation sign
const ENTRY_DEPTH := 3.0          ## clear floor before the first sign
const EXIT_DEPTH := 2.5           ## clear floor after the last row

## Table centre offset from the hallway axis. The bay's local +Z faces the aisle.
const BAY_X := HALL_HALF_WIDTH - TABLE_D * 0.5 - 0.08

const TV_LOCAL_X := -0.28         ## TV sits left of centre as the player sees it
const SYS_LOCAL_X := 0.30         ## system sits right of it — inside cable reach
const TV_STACK_GAP := 0.012       ## air between stacked dual-screen TVs

const LIGHT_SPACING := 4.0

# --- Detail culling ---------------------------------------------------------
# A 46 m hall puts all 34 stations in view at once, and a station is ~74
# renderables for the console plus ~38 for each TV — port recesses, snap
# highlights, button caps, labels. Submitting those for a station 30 m away
# costs a draw call each and covers a pixel or two.
#
# Parts are graded by their own AABB rather than by name, so this keeps working
# as models change. Three tiers, not two: one threshold either kept the junk or
# culled the console shells along with it, because a shell is split into many
# modestly-sized surfaces while the labels and port recesses are tiny.
#
# [below this size (m), draw distance (m)] — first match wins; anything larger
# than the last entry is a silhouette and gets SILHOUETTE_CULL_DIST.
const CULL_TIERS := [
	[0.13, 8.0],    ## labels, port recesses, snap-highlight ghosts, button caps
	[0.30, 17.0],   ## shell sub-surfaces, bezels, lids
]
const SILHOUETTE_CULL_DIST := 34.0

# --- Exhibit --------------------------------------------------------------------

## The procedural box, for hardware with no primitive model of its own.
const BOX := SystemModelRegistry.PLACEHOLDER_ID

## Console generations, in order down the hallway. Each system is
## [systemid, model_id, plaque name].
##
## Every station names a primitive — the platform's own stand-in model where it
## has one, else BOX. Nothing here resolves to an imported shell, so the hall is
## the line-up a build shipped without imported-assets/ comes up with.
const GENERATIONS: Array = [
	{
		"title": "2ND GENERATION", "years": "1976 – 1983",
		"systems": [
			["atari_2600", BOX, "Atari 2600"],
			["atari_5200", BOX, "Atari 5200"],
		],
	},
	{
		"title": "3RD GENERATION", "years": "1983 – 1987",
		"systems": [
			["nes", BOX, "Nintendo Entertainment System"],
			["master_system", BOX, "Sega Master System"],
			["atari_7800", BOX, "Atari 7800"],
		],
	},
	{
		"title": "4TH GENERATION", "years": "1987 – 1993",
		"systems": [
			["super_nes", BOX, "Super Nintendo"],
			["mega_drive", BOX, "Sega Genesis"],
			["neogeo", BOX, "Neo Geo AES"],
			["pc_engine", BOX, "PC Engine / TurboGrafx-16"],
			["game_boy", "game_boy_primitive", "Game Boy"],
			["atari_lynx", "atari_lynx", "Atari Lynx"],
			["supervision", "supervision", "Watara Supervision"],
		],
	},
	{
		"title": "5TH GENERATION", "years": "1993 – 1998",
		"systems": [
			["playstation", BOX, "PlayStation"],
			["nintendo_64", BOX, "Nintendo 64"],
			["sega_saturn", BOX, "Sega Saturn"],
			["3do", BOX, "Panasonic 3DO"],
			["atari_jaguar", BOX, "Atari Jaguar"],
			["virtual_boy", "virtual_boy_primitive", "Virtual Boy"],
			["neo_geo_pocket", "neo_geo_pocket", "Neo Geo Pocket"],
			["wonderswan", "wonderswan", "Bandai WonderSwan"],
		],
	},
	{
		"title": "6TH GENERATION", "years": "1998 – 2005",
		"systems": [
			["dreamcast", BOX, "Sega Dreamcast"],
			["playstation2", BOX, "PlayStation 2"],
			["gamecube", BOX, "Nintendo GameCube"],
			["game_boy_advance", "game_boy_advance_primitive", "Game Boy Advance"],
			["game_boy_advance", "game_boy_advance_sp_primitive", "Game Boy Advance SP"],
			["pokemon_mini", "pokemon_mini", "Pokémon mini"],
		],
	},
	{
		"title": "7TH GENERATION", "years": "2004 – 2012",
		"systems": [
			["nds", "nds_primitive", "Nintendo DS"],
			["playstation_portable", "psp_primitive", "PlayStation Portable"],
		],
	},
	{
		"title": "8TH GENERATION", "years": "2011 – 2017",
		"systems": [
			["3ds", "n3ds_primitive", "Nintendo 3DS"],
		],
	},
]

# --- Shared materials --------------------------------------------------------

var _mat_floor: StandardMaterial3D
var _mat_wall: StandardMaterial3D
var _mat_ceiling: StandardMaterial3D
var _mat_table_top: StandardMaterial3D
var _mat_table_frame: StandardMaterial3D
var _mat_fixture: StandardMaterial3D
var _mat_sign: StandardMaterial3D

var _hall_length: float = 0.0


## Claim the scene id before any _ready() runs. SpawnMenuController auto-loads
## the last arcade save on startup whenever SceneManager still reads "arcade",
## and that load begins by freeing every node in the "spawned" group — which
## includes the video-out cables these stations plug in. Arriving here through
## SceneManager.change_scene() sets the id already; running the scene directly
## (F6, or a headless probe) does not.
func _enter_tree() -> void:
	var sm := get_node_or_null("/root/SceneManager")
	if sm != null:
		sm.current_scene_id = "test"


func _ready() -> void:
	_make_materials()
	var rows := _build_stations()
	_build_shell(rows)
	print("[TestScene] %d stations across %d generations, hallway %.1f m" %
		[_station_count(), GENERATIONS.size(), _hall_length])


func _station_count() -> int:
	var n := 0
	for gen: Dictionary in GENERATIONS:
		n += (gen["systems"] as Array).size()
	return n


# --- Stations ----------------------------------------------------------------

## Lays out every generation section and returns the z of the last table row.
func _build_stations() -> float:
	var z := -ENTRY_DEPTH
	for gen: Dictionary in GENERATIONS:
		_build_sign(gen["title"], gen["years"], z)
		z -= SECTION_GAP
		var systems: Array = gen["systems"]
		for i in systems.size():
			var entry: Array = systems[i]
			# Alternate left/right; a new pair steps one row further down.
			var side := -1.0 if i % 2 == 0 else 1.0
			var row_z := z - float(i / 2) * ROW_PITCH
			_build_station(entry[0], entry[1], entry[2], side, row_z)
		z -= float((systems.size() + 1) / 2) * ROW_PITCH
	return z + ROW_PITCH


## One table + system + TV(s), fully cabled.
func _build_station(systemid: String, model_id: String, plaque: String,
		side: float, z: float) -> void:
	# Bay frame: origin at the table centre on the floor, local +Z facing the aisle.
	var yaw := PI * 0.5 if side < 0.0 else -PI * 0.5
	var bay := Transform3D(Basis(Vector3.UP, yaw), Vector3(side * BAY_X, 0.0, z))

	# Named for the plaque: a station is one exhibit, and two of them can sit under
	# the same platform — the two Game Boy Advance stations — which a systemid stem
	# cannot tell apart.
	var name_stem := plaque.replace(" ", "_").validate_node_name()
	_build_table(bay, name_stem, plaque)

	# System first — its channel count decides how many TVs the station needs.
	var sys := SYSTEM_SCENE.instantiate() as RetroSystem
	sys.name = "Sys_%s" % name_stem
	sys.systemid = systemid
	sys.model_id = model_id
	sys.system_label = plaque
	# Handhelds default their video out OFF; consoles ignore this (their cable is
	# always live). Every station in the hallway is wired to a set, so force it.
	sys.force_video_out(true)
	add_child(sys)
	sys.freeze = true
	sys.ignore_gravity = true
	sys.transform = bay * Transform3D(Basis.IDENTITY,
		Vector3(SYS_LOCAL_X, _rest_y(sys, TABLE_TOP_Y), 0.0))

	# One TV per video-out channel, stacked bottom-up. Channel 0 is the TOP
	# picture on dual-screen hardware, so it takes the HIGHEST TV.
	var channels := sys.get_channel_count()
	for ch in channels:
		var tv := TV_SCENE.instantiate() as RetroTV
		tv.name = "TV_%s_%d" % [name_stem, ch]
		add_child(tv)
		tv.freeze = true
		var level := channels - 1 - ch
		var surface_y := TABLE_TOP_Y + float(level) * (_shape_height(tv) + TV_STACK_GAP)
		tv.transform = bay * Transform3D(Basis.IDENTITY,
			Vector3(TV_LOCAL_X, _rest_y(tv, surface_y), 0.0))
		# Cables spawn deferred, so this parks as a pending restore and snaps
		# itself as soon as the plug exists.
		sys.restore_cable_connection(tv, ch)
		_cull_detail(tv)

	# Deferred for the system: the model scene is instantiated in its _ready,
	# so its meshes do not exist yet at this point.
	_cull_detail.call_deferred(sys)


## Table: top slab, skirt and four legs, plus the name plaque on the front edge.
func _build_table(bay: Transform3D, name_stem: String, plaque: String) -> void:
	var body := StaticBody3D.new()
	body.name = "Table_%s" % name_stem
	body.collision_mask = 0
	body.transform = bay
	add_child(body)

	var leg_h := TABLE_TOP_Y - TABLE_THICK
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(TABLE_W, TABLE_TOP_Y, TABLE_D)
	col.shape = box
	col.position = Vector3(0.0, TABLE_TOP_Y * 0.5, 0.0)
	body.add_child(col)

	body.add_child(_box_mesh("Top", Vector3(TABLE_W, TABLE_THICK, TABLE_D),
		Vector3(0.0, TABLE_TOP_Y - TABLE_THICK * 0.5, 0.0), _mat_table_top))
	body.add_child(_box_mesh("SkirtFront", Vector3(TABLE_W, 0.08, 0.03),
		Vector3(0.0, leg_h - 0.05, TABLE_D * 0.5 - 0.03), _mat_table_frame))
	body.add_child(_box_mesh("SkirtBack", Vector3(TABLE_W, 0.08, 0.03),
		Vector3(0.0, leg_h - 0.05, -TABLE_D * 0.5 + 0.03), _mat_table_frame))
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			body.add_child(_box_mesh("Leg", Vector3(0.06, leg_h, 0.06),
				Vector3(sx * (TABLE_W * 0.5 - 0.06), leg_h * 0.5,
					sz * (TABLE_D * 0.5 - 0.06)), _mat_table_frame))

	_cull_detail(body)

	var label := Label3D.new()
	label.name = "Plaque"
	label.text = plaque
	label.pixel_size = 0.0012
	label.font_size = 40
	label.outline_size = 10
	label.modulate = Color(0.95, 0.93, 0.85)
	label.outline_modulate = Color(0, 0, 0)
	label.position = Vector3(0.0, TABLE_TOP_Y + 0.02, TABLE_D * 0.5 + 0.005)
	label.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	body.add_child(label)


## Generation header spanning the hallway, reading back toward the entrance.
func _build_sign(title: String, years: String, z: float) -> void:
	var root := Node3D.new()
	root.name = "Sign_%s" % title.replace(" ", "_")
	root.position = Vector3(0.0, 0.0, z)
	add_child(root)

	root.add_child(_box_mesh("Header", Vector3(HALL_HALF_WIDTH * 2.0, 0.5, 0.08),
		Vector3(0.0, WALL_HEIGHT - 0.45, 0.0), _mat_sign))

	var label := Label3D.new()
	label.name = "Title"
	label.text = title
	label.pixel_size = 0.0022
	label.font_size = 48
	label.outline_size = 12
	label.modulate = Color(1.0, 0.85, 0.35)
	label.outline_modulate = Color(0, 0, 0)
	label.position = Vector3(0.0, WALL_HEIGHT - 0.36, 0.05)
	root.add_child(label)

	var sub := Label3D.new()
	sub.name = "Years"
	sub.text = years
	sub.pixel_size = 0.0022
	sub.font_size = 26
	sub.outline_size = 8
	sub.modulate = Color(0.8, 0.85, 0.95)
	sub.outline_modulate = Color(0, 0, 0)
	sub.position = Vector3(0.0, WALL_HEIGHT - 0.62, 0.05)
	root.add_child(sub)


# --- Corridor shell ----------------------------------------------------------

## Floor, walls, ceiling and lighting, sized to whatever the stations came to.
func _build_shell(last_row_z: float) -> void:
	var far_z := last_row_z - EXIT_DEPTH
	_hall_length = absf(far_z) + 2.0
	var mid_z := (2.0 + far_z) * 0.5
	var w := HALL_HALF_WIDTH * 2.0

	var shell := StaticBody3D.new()
	shell.name = "Shell"
	shell.collision_mask = 0
	add_child(shell)

	_add_slab(shell, "Floor", Vector3(w, 0.2, _hall_length),
		Vector3(0.0, -0.1, mid_z), _mat_floor)
	_add_slab(shell, "Ceiling", Vector3(w, 0.15, _hall_length),
		Vector3(0.0, WALL_HEIGHT + 0.075, mid_z), _mat_ceiling)
	for sx: float in [-1.0, 1.0]:
		_add_slab(shell, "SideWall", Vector3(WALL_THICK, WALL_HEIGHT, _hall_length),
			Vector3(sx * (HALL_HALF_WIDTH + WALL_THICK * 0.5), WALL_HEIGHT * 0.5, mid_z),
			_mat_wall)
	_add_slab(shell, "EndWall", Vector3(w + WALL_THICK * 2.0, WALL_HEIGHT, WALL_THICK),
		Vector3(0.0, WALL_HEIGHT * 0.5, far_z - WALL_THICK * 0.5), _mat_wall)
	_add_slab(shell, "BackWall", Vector3(w + WALL_THICK * 2.0, WALL_HEIGHT, WALL_THICK),
		Vector3(0.0, WALL_HEIGHT * 0.5, 2.0 + WALL_THICK * 0.5), _mat_wall)

	var count := int(ceilf(_hall_length / LIGHT_SPACING))
	for i in count:
		var z := 1.0 - (float(i) + 0.5) * (_hall_length / float(count))
		add_child(_box_mesh("Fixture", Vector3(1.6, 0.05, 0.28),
			Vector3(0.0, WALL_HEIGHT - 0.03, z), _mat_fixture))
		var light := OmniLight3D.new()
		light.name = "HallLight"
		light.position = Vector3(0.0, WALL_HEIGHT - 0.25, z)
		light.light_color = Color(1.0, 0.96, 0.9)
		light.light_energy = 2.2
		light.omni_range = 9.0
		light.add_to_group("ceiling_light")
		add_child(light)


# --- Helpers -----------------------------------------------------------------

func _add_slab(body: StaticBody3D, slab_name: String, size: Vector3, pos: Vector3,
		mat: StandardMaterial3D) -> void:
	body.add_child(_box_mesh(slab_name, size, pos, mat))
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	col.position = pos
	body.add_child(col)


func _box_mesh(mesh_name: String, size: Vector3, pos: Vector3,
		mat: StandardMaterial3D) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = mesh_name
	var box := BoxMesh.new()
	box.size = size
	mi.mesh = box
	mi.position = pos
	mi.set_surface_override_material(0, mat)
	return mi


## Give every renderable under `root` a draw distance, sized by how big the part
## itself is. Nothing is hidden that you could have made out anyway.
func _cull_detail(root: Node) -> void:
	if root == null or not is_instance_valid(root):
		return
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if not (n is GeometryInstance3D):
			continue
		var g := n as GeometryInstance3D
		var span: float = (g as VisualInstance3D).get_aabb().size.length()
		var dist: float = SILHOUETTE_CULL_DIST
		for tier: Array in CULL_TIERS:
			if span < float(tier[0]):
				dist = float(tier[1])
				break
		g.visibility_range_end = dist
		g.visibility_range_end_margin = dist * 0.12


## The y a body must sit at for the bottom of its collision to rest on
## `surface_y`. Every system model resizes its shapes to its shell, so reading
## them back beats hardcoding a per-console drop height.
##
## All of the body's own shapes, not just the one named "CollisionShape3D": the
## Virtual Boy keeps that one on the visor alone, for hand-grab feel, and carries
## its stand on two more. Measuring the named shape by itself rested the VISOR on
## the table and buried the stand inside it.
func _rest_y(body: PhysicsBody3D, surface_y: float) -> float:
	var bottom := INF
	for child in body.get_children():
		var col := child as CollisionShape3D
		if col == null or not (col.shape is BoxShape3D):
			continue
		bottom = minf(bottom, col.position.y - (col.shape as BoxShape3D).size.y * 0.5)
	if is_inf(bottom):
		return surface_y + 0.05
	return surface_y - bottom


func _shape_height(body: PhysicsBody3D) -> float:
	var col := body.get_node_or_null("CollisionShape3D") as CollisionShape3D
	if col != null and col.shape is BoxShape3D:
		return (col.shape as BoxShape3D).size.y
	return 0.4


func _make_materials() -> void:
	_mat_floor = _flat(Color(0.13, 0.13, 0.15), 0.85)
	_mat_wall = _flat(Color(0.30, 0.30, 0.34), 0.9)
	_mat_ceiling = _flat(Color(0.62, 0.62, 0.6), 0.95)
	_mat_table_top = _flat(Color(0.24, 0.15, 0.09), 0.55)
	_mat_table_frame = _flat(Color(0.13, 0.09, 0.06), 0.7)
	_mat_sign = _flat(Color(0.09, 0.10, 0.16), 0.8)
	_mat_fixture = _flat(Color(0.92, 0.9, 0.85), 0.4)
	_mat_fixture.emission_enabled = true
	_mat_fixture.emission = Color(1.0, 0.96, 0.9)
	_mat_fixture.emission_energy_multiplier = 1.6


func _flat(albedo: Color, rough: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = albedo
	m.roughness = rough
	return m
