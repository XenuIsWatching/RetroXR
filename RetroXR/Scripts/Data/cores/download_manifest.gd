## DownloadManifest — tracks which cores have been downloaded and when.
##
## Persists to {core_dir}/cores_manifest.json.
## Schema:
##   {
##     "cores": {
##       "fceumm": {
##         "filename":      "fceumm_libretro.dll",
##         "remote_date":   "05-Mar-2026 03:12",
##         "downloaded_at": "2026-03-05T14:30:00"
##       }, ...
##     }
##   }
class_name DownloadManifest
extends RefCounted


var _core_dir: String = ""
var _data: Dictionary = {}  # "cores" -> { core_name -> { ... } }


func setup(core_dir: String) -> void:
	_core_dir = core_dir
	load_manifest()


# ---------------------------------------------------------------------------
# Load / Save
# ---------------------------------------------------------------------------

func load_manifest() -> void:
	_data = JsonStore.read_dict(_manifest_path(), "DownloadManifest")
	if not _data.has("cores"):
		_data["cores"] = {}


## False when the write did not land. A lost manifest makes every installed
## core look absent on the next launch, which the Cores tab then offers to
## download again.
func save() -> bool:
	return JsonStore.write_dict(_manifest_path(), _data, "DownloadManifest")


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

func is_downloaded(core_name: String) -> bool:
	return _cores().has(core_name)


## Returns the remote_date string stored at download time, or "" if not downloaded.
func get_remote_date(core_name: String) -> String:
	return _cores().get(core_name, {}).get("remote_date", "")


# ---------------------------------------------------------------------------
# Mutations
# ---------------------------------------------------------------------------

## filename is the library the core actually installed as; when empty the
## conventional name is assumed (cores that break the convention, like azahar
## on Android, pass theirs explicitly).
func set_downloaded(core_name: String, remote_date: String, filename := "") -> void:
	var lib_suffix := "_libretro_android" if OS.get_name() == "Android" else "_libretro"
	var lib_ext := ".dylib" if OS.get_name() == "macOS" else (".so" if OS.get_name() in ["Android", "Linux"] else ".dll")
	if filename.is_empty():
		filename = core_name + lib_suffix + lib_ext
	_cores()[core_name] = {
		"filename":      filename,
		"remote_date":   remote_date,
		"downloaded_at": Time.get_datetime_string_from_system(false, true)
	}
	save()


func remove(core_name: String) -> void:
	_cores().erase(core_name)
	save()


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _manifest_path() -> String:
	return _core_dir.path_join("cores_manifest.json")


func _cores() -> Dictionary:
	if not _data.has("cores"):
		_data["cores"] = {}
	return _data["cores"]
