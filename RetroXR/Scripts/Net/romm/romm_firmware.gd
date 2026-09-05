## RommFirmware — the firmware RomM is holding, indexed so a core's declared
## BIOS can be looked up by name.
##
## RomM 5.x mirrors its ROM endpoints for firmware:
##   GET /api/firmware[?platform_id=N]        list
##   GET /api/firmware/{id}/content/{name}    download
##
## The list response carries no platform_id field — only `file_path`, which is
## "bios/<platform slug>". One unfiltered call is enough; filtering per platform
## would mean one request per platform for no extra information.
##
## Two indexes, because cores declare their firmware two ways. Most name a file
## ("scph5500.bin"), which joins on the basename. The PS2 cores name a FOLDER
## ("pcsx2/bios") and never say what goes in it, so the only join left is the
## platform: `file_path`'s trailing component is the server's fs_slug, which
## RommPlatforms maps to a systemid.
class_name RommFirmware
extends Node


## `error` is set only when `ok` is false, and is phrased for a toast.
##
## A signal, where the rest of Net/romm/ completes through a callback argument,
## and deliberately so: the listing is fetched once and REDRAWS a tab that may
## not have existed when the request went out. A callback binds one caller at
## request time; this has to reach whoever is on screen when the reply lands.
##
## Which is also why refresh() stays quiet on its early exits. A caller already
## in flight will be told by the request it is waiting on, and the automatic
## call on an already-loaded list has nothing new to redraw — emitting there
## would re-toast a server that is merely still down.
signal listed(ok: bool, count: int, error: String)

var config: RommConfig = null

## lowercase basename -> {id, file_name, size, md5, systemid}
var _by_name: Dictionary = {}
## systemid -> [entry, ...], name-sorted
var _by_system: Dictionary = {}
var _loaded := false
var _in_flight := false


func setup(cfg: RommConfig) -> void:
	config = cfg


func is_loaded() -> bool:
	return _loaded


## Look a declared firmware path up on the server.
##
## Matching is on the basename, case-insensitively: the .info path may be
## nested ("Machines/Shared Roms/MSX.rom") while the server stores a flat
## name, and the two disagree on case (server "MSX.ROM").
## Returns {} when the server does not have it.
func find(firmware_path: String) -> Dictionary:
	if not _loaded:
		return {}
	return _by_name.get(firmware_path.get_file().to_lower(), {})


## Everything the server holds for one project systemid, name-sorted.
##
## This is what a folder requirement gets offered: the core will take any of
## them, so the choice is the user's.
func find_for_system(systemid: String) -> Array:
	if not _loaded or systemid.is_empty():
		return []
	return _by_system.get(systemid, [])


## The platform folder a firmware entry sits in on the server.
##
## `file_path` is "bios/<fs_slug>" — the fs_slug is the folder the user named,
## so it is fed to RommPlatforms as one. A path with no folder part yields "",
## which maps to nothing rather than to whatever the bare filename resembles.
static func platform_slug_from_path(file_path: String) -> String:
	var p := file_path.replace("\\", "/").trim_suffix("/")
	var cut := p.rfind("/")
	return "" if cut < 0 else p.substr(cut + 1).to_lower().strip_edges()


## Request path for a firmware entry's content.
static func content_path(id: int, file_name: String) -> String:
	return "/api/firmware/%d/content/%s" % [id, file_name.uri_encode()]


## Fetch the list once per session. `force` re-fetches (the Re-check button).
##
## `listed` announces the ARRIVAL of new data, so the already-loaded path stays
## silent. Emitting it here would re-enter any handler that redraws a view whose
## rebuild calls refresh() — which is exactly what the BIOS tab does, and it
## recursed until the stack blew.
func refresh(force: bool = false) -> void:
	if _in_flight:
		return
	if _loaded and not force:
		return
	if config == null or not config.is_configured():
		return

	_in_flight = true
	var req := HTTPRequest.new()
	req.timeout = 20.0
	add_child(req)
	req.request_completed.connect(
		func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
			_in_flight = false
			req.queue_free()
			# A refused connection or a timeout never carries an HTTP code, so
			# this is checked first — reporting the code here reads "HTTP 0".
			if result != HTTPRequest.RESULT_SUCCESS:
				listed.emit(false, 0, "Couldn't reach RomM")
				return
			if code != 200:
				listed.emit(false, 0, "RomM returned HTTP %d" % code)
				return
			var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
			if not (parsed is Array):
				listed.emit(false, 0, "Unreadable reply from RomM")
				return
			_index(parsed as Array)
			_loaded = true
			listed.emit(true, _by_name.size(), "")
	)
	var url: String = config.base_url + "/api/firmware"
	if req.request(url, config.auth_headers(), HTTPClient.METHOD_GET) != OK:
		_in_flight = false
		req.queue_free()
		listed.emit(false, 0, "Bad RomM address")


func _index(items: Array) -> void:
	_by_name.clear()
	_by_system.clear()
	var overrides: Dictionary = config.platform_overrides if config != null else {}

	for item: Variant in items:
		if not (item is Dictionary):
			continue
		var d := item as Dictionary
		var file_name := str(d.get("file_name", ""))
		if file_name.is_empty():
			continue
		# A file the server has a record of but no longer holds cannot be
		# fetched; leaving it out means the row reads "not on the server",
		# which is the truth, rather than offering a download that 404s.
		if bool(d.get("missing_from_fs", false)):
			continue

		var slug := platform_slug_from_path(str(d.get("file_path", "")))
		var systemid := RommPlatforms.systemid_for({"fs_slug": slug}, overrides)

		var entry := {
			"id": int(d.get("id", 0)),
			"file_name": file_name,
			"size": int(d.get("file_size_bytes", 0)),
			"md5": str(d.get("md5_hash", "")).to_lower(),
			"systemid": systemid,
		}
		_by_name[file_name.to_lower()] = entry
		if not systemid.is_empty():
			if not _by_system.has(systemid):
				_by_system[systemid] = []
			(_by_system[systemid] as Array).append(entry)

	# Sorted here, once, rather than in the view: the picker is rebuilt on every
	# repaint and a server's own order is not one a person would pick from.
	for sid: String in _by_system:
		(_by_system[sid] as Array).sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return str(a["file_name"]).naturalnocasecmp_to(str(b["file_name"])) < 0
		)
