## Print a core's option table, as the core itself declares it.
##
## Peeked, so this costs a dlopen and no emulation: the same read the options
## panel does on a powered-off machine. Exists because "which option gates the
## expansion hardware" is a question about a specific build of a specific core,
## and the answer drifts between versions in a way documentation does not.
##
##     "$godot" --headless --path RetroXR res://Tools/cores/core_options_probe.tscn \
##         -- --core=picodrive --root=C:/cores [--match=cd,32x,bios]
extends Node


func _ready() -> void:
	var core := ""
	var root := ""
	var match_terms: Array[String] = []
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--core="):
			core = s.trim_prefix("--core=")
		elif s.begins_with("--root="):
			root = s.trim_prefix("--root=")
		elif s.begins_with("--match="):
			for t in s.trim_prefix("--match=").split(",", false):
				match_terms.append(String(t).to_lower())

	if core.is_empty():
		print("[opt] need --core=<name>")
		get_tree().quit(1)
		return
	if root.is_empty():
		root = CoreDownloadManager.default_core_root()

	var peeked: Dictionary = CoreOptionsStore.peek(root, core)
	var definitions: Dictionary = peeked.get("definitions", {})
	var defaults: Dictionary = peeked.get("values", {})
	print("[opt] CORE %s — %d options declared" % [core, definitions.size()])

	var keys := definitions.keys()
	keys.sort()
	for k: String in keys:
		var defn: Object = definitions[k]
		var desc: String = defn.GetDescription()
		var hay := (k + " " + desc).to_lower()
		if not match_terms.is_empty():
			var hit := false
			for t in match_terms:
				if hay.contains(t):
					hit = true
					break
			if not hit:
				continue
		var values: Array = defn.GetValues()
		var names := PackedStringArray()
		for v in values:
			names.append(str(v.GetValue()))
		print("[opt] %-40s = %-14s | %s | %s" % [
			k, str(defaults.get(k, "?")), desc, "/".join(names.slice(0, 10))])

	get_tree().quit(0)
