## CoreDefaults — persists the user-chosen default core per systemid.
##
## Schema of core_defaults.json:
##   { "defaults": { "nes": "fceumm", "super_nes": "snes9x", ... } }
##
## Usage:
##   var cd := CoreDefaults.new()
##   cd.setup(CoreDownloadManager.default_core_root().path_join("core_defaults.json"))
##   cd.set_default_core("nes", "fceumm")
##   cd.save()
class_name CoreDefaults
extends RefCounted

var _path:     String     = ""
var _defaults: Dictionary = {}   # systemid -> core_name


static func default_path() -> String:
	return CoreDownloadManager.default_core_root().path_join("core_defaults.json")


func setup(path: String) -> void:
	_path = path
	load_defaults()


## Returns the default core_name for a systemid, or "" if none set.
func get_default_core(systemid: String) -> String:
	return _defaults.get(systemid, "")


## Set which core is the default for a systemid. Call save() to persist.
func set_default_core(systemid: String, core_name: String) -> void:
	_defaults[systemid] = core_name


## Returns a copy of the full defaults dict (systemid -> core_name).
func all_defaults() -> Dictionary:
	return _defaults.duplicate()


func save() -> void:
	if _path.is_empty():
		push_error("CoreDefaults: no path set, call setup() first")
		return
	JsonStore.write_dict(_path, {"defaults": _defaults}, "CoreDefaults")


func load_defaults() -> void:
	if _path.is_empty():
		return
	var d: Variant = JsonStore.read_dict(_path, "CoreDefaults").get("defaults")
	if d is Dictionary:
		_defaults = d as Dictionary
		# Ensure a roms/ folder exists for every configured system
		for sid: String in _defaults:
			RomLibrary.ensure_rom_dir(sid)
