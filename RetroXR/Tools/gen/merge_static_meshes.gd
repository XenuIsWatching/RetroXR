@tool
## Post-import merge of a model's STATIC meshes by material.
##
## Godot's mobile renderer draws every visible surface separately, so a shell
## that arrives as forty small meshes costs forty draws however few materials
## it uses. This runs when a GLB in PLAN is imported (set as the file's
## `import_script/path`) and, under one node of the model, folds every mesh
## that shares a material into a single ArrayMesh surface, baking each piece's
## transform relative to that node. A PlayStation's top shell goes from
## seventeen meshes to nine this way, with nothing the eye can tell apart.
##
## What it leaves alone is the point. `keep` names nodes - and whole subtrees
## under them - that must survive as they are: anything a script finds by name
## (`playstation_model.gd` wants JackSerial and MemCard1), anything a widget
## moves (buttons, lids, sticks), anything with its own material state (an
## LED). A merged piece keeps no name, so a keep list is a promise about every
## script that will ever look inside the model; check the model's script for
## find_child / get_node calls before shortening one.
##
## Draw counts before and after: Tools/perf/draw_census. To apply to a new
## model, add its row here, set the script on the GLB's import, and reimport
## (delete the .godot/imported/<file>.glb-*.scn or reimport from the editor).
extends EditorScenePostImport

## Source file basename -> { root: node to merge under, keep: [names] }.
## A name in `keep` protects that node and everything below it.
const PLAN := {
	"ps1_console": {
		"root": "ShellTop",
		"keep": ["JackSerial", "JackAvMulti", "JackVideo", "JackAudioL", "JackAudioR"],
	},
	"ps1_dualshock": {
		"root": "Controller_DuelShock",
		"keep": ["ControlsFrame"],
	},
	"ps1_memory_card": {
		"root": "Memory_Card",
		"keep": [],
	},
	"nes_console": {
		"root": "NesDeck_13",
		"keep": ["NesLidPivot", "ButtonResetPivot", "ButtonPowerPivot", "PowerLightPivot",
			"JackYellow", "JackRed", "NesDeck", "NesDeckDark", "NesDeckBlack", "RearPanel"],
	},
}


func _post_import(scene: Node) -> Object:
	var key := get_source_file().get_file().get_basename()
	if not PLAN.has(key):
		return scene
	var plan: Dictionary = PLAN[key]
	var root := scene.find_child(String(plan["root"]), true, false)
	if root == null:
		push_warning("[merge] %s: no node named %s" % [key, plan["root"]])
		return scene
	var keep: Array = plan["keep"]
	var pieces: Array[MeshInstance3D] = []
	_collect(root, root, keep, pieces)
	if pieces.size() < 2:
		return scene

	# Group every surface by its material; one merged surface per group.
	var groups: Dictionary = {}   # material instance id -> [material, [[mi, surface], ...]]
	var order: Array = []
	for mi in pieces:
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s)
			var id := mat.get_instance_id() if mat != null else 0
			if not groups.has(id):
				groups[id] = [mat, []]
				order.append(id)
			groups[id][1].append([mi, s])

	var merged := ArrayMesh.new()
	var merged_surfaces := 0
	var absorbed: Dictionary = {}
	for id in order:
		var entries: Array = groups[id][1]
		if entries.size() < 2:
			continue   # nothing to gain from one piece; it stays its own node
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for e: Array in entries:
			var mi: MeshInstance3D = e[0]
			st.append_from(mi.mesh, int(e[1]), _relative_to(root, mi))
			absorbed[mi.get_instance_id()] = mi
		st.commit(merged)
		merged.surface_set_material(merged_surfaces, groups[id][0])
		merged_surfaces += 1
	if merged_surfaces == 0:
		return scene

	# A piece with a surface that was NOT merged (its material is unique) still
	# has to keep drawing that surface. None of the models in PLAN have such a
	# piece, and a mixed one is easier to leave whole than to split.
	for mi_id in absorbed.keys():
		var mi: MeshInstance3D = absorbed[mi_id]
		var all_merged := true
		for s in mi.mesh.get_surface_count():
			var mat := mi.get_active_material(s)
			var id := mat.get_instance_id() if mat != null else 0
			if groups[id][1].size() < 2:
				all_merged = false
		if not all_merged:
			push_warning("[merge] %s: %s mixes merged and unique surfaces; left whole" % [key, mi.name])
			return scene

	var out := MeshInstance3D.new()
	out.name = "%s_merged" % root.name
	out.mesh = merged
	var first: MeshInstance3D = absorbed.values()[0]
	out.layers = first.layers
	out.cast_shadow = first.cast_shadow
	root.add_child(out)
	out.owner = scene
	for mi_id in absorbed.keys():
		var mi: MeshInstance3D = absorbed[mi_id]
		mi.get_parent().remove_child(mi)
		mi.free()
	print("[merge] %s: %d meshes -> %d surface(s) under %s" % [key, absorbed.size(), merged_surfaces, root.name])
	return scene


## Every MeshInstance3D below `node` that is not protected by `keep`.
func _collect(node: Node, root: Node, keep: Array, out: Array[MeshInstance3D]) -> void:
	for child in node.get_children():
		if keep.has(child.name):
			continue
		var mi := child as MeshInstance3D
		if mi != null and mi.mesh != null and mi.mesh.get_surface_count() > 0:
			out.append(mi)
		_collect(child, root, keep, out)


## A node's transform in `root`'s frame.
func _relative_to(root: Node, node: Node3D) -> Transform3D:
	var xf := node.transform
	var p := node.get_parent()
	while p != null and p != root:
		var p3 := p as Node3D
		if p3 != null:
			xf = p3.transform * xf
		p = p.get_parent()
	return xf
