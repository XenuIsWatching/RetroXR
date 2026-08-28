## Instantiate every system model scene and dump the geometry a change could
## plausibly disturb — shell presence, node count, body_size, screen pose.
##
## Capture a baseline before touching model code, then diff after. Written for the
## primitive_shell removal, where "it still compiles" was not evidence, and kept
## because any change to how a model builds itself wants the same check.
##
##   godot --headless --path RetroXR --script res://Tools/models/model_equiv_probe.gd -- --out=res://probe_out/models_before.txt
extends Node

const DIR := "res://Scenes/Objects/system_models"


func _ready() -> void:
	var out := "res://probe_out/models.txt"
	get_tree().create_timer(90.0).timeout.connect(func(): get_tree().quit(1))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	DirAccess.make_dir_recursive_absolute(
		ProjectSettings.globalize_path(out.get_base_dir()))

	var names: Array[String] = []
	var d := DirAccess.open(DIR)
	d.list_dir_begin()
	var f := d.get_next()
	while f != "":
		if f.ends_with(".tscn"):
			names.append(f.get_basename())
		f = d.get_next()
	names.sort()

	var lines: Array[String] = []
	for n in names:
		lines.append(_probe("%s/%s.tscn" % [DIR, n], n))
	var text := "\n".join(lines) + "\n"
	var fh := FileAccess.open(out, FileAccess.WRITE)
	fh.store_string(text)
	fh.close()
	print(text)
	print("[probe] %d scenes -> %s" % [names.size(), out])
	get_tree().quit(0)


func _probe(path: String, id: String) -> String:
	var packed := load(path) as PackedScene
	if packed == null:
		return "%-28s LOAD_FAILED" % id
	var m := packed.instantiate() as Node3D
	if m == null:
		return "%-28s NOT_NODE3D" % id
	# Into the tree so _ready() runs — that is the code path being changed.
	get_tree().root.add_child(m)

	var shell := m.get_node_or_null("Shell")
	var body: Variant = m.get("body_size")
	# Screen pose is the thing _upgrade_to_glb repositions, so it is the most
	# sensitive single number here.
	var screen := m.find_child("Screen", true, false) as Node3D
	if screen == null:
		screen = m.find_child("ScreenMesh", true, false) as Node3D

	var line := "%-28s shell=%s children=%d body=%s screen=%s" % [
		id,
		"Y" if shell != null else "n",
		_count(m),
		_v(body),
		_xf(screen, m),
	]
	m.queue_free()
	return line


func _count(n: Node) -> int:
	var c := 1
	for ch in n.get_children():
		c += _count(ch)
	return c


func _v(v: Variant) -> String:
	if v is Vector3:
		return "(%.4f,%.4f,%.4f)" % [(v as Vector3).x, (v as Vector3).y, (v as Vector3).z]
	return "-"


func _xf(n: Node3D, rel: Node3D) -> String:
	if n == null:
		return "-"
	var t := rel.global_transform.affine_inverse() * n.global_transform
	var s := t.basis.get_scale()
	return "p(%.4f,%.4f,%.4f)s(%.4f,%.4f,%.4f)" % [
		t.origin.x, t.origin.y, t.origin.z, s.x, s.y, s.z]
