## CoreDownloadManager — HTTP fetch, zip extraction, and download orchestration.
##
## Must be added to the scene tree (it creates HTTPRequest child nodes).
## Usage:
##   var mgr := CoreDownloadManager.new()
##   add_child(mgr)
##   mgr.fetch_available_cores(func(cores): ...)
##   mgr.download_core("fceumm", func(p): ..., func(ok, err): ...)
class_name CoreDownloadManager
extends Node


static func _buildbot_url() -> String:
	if OS.get_name() == "Android":
		return "https://buildbot.libretro.com/nightly/android/latest/arm64-v8a/"
	if OS.get_name() == "Linux":
		return "https://buildbot.libretro.com/nightly/linux/x86_64/latest/"
	if OS.get_name() == "macOS":
		var arch := Engine.get_architecture_name()
		if arch not in ["arm64", "x86_64"]:
			arch = "arm64"
		return "https://buildbot.libretro.com/nightly/apple/osx/%s/latest/" % arch
	return "https://buildbot.libretro.com/nightly/windows/x86_64/latest/"


## Library-name suffixes this platform may see, canonical first.
## Android cores are conventionally "<core>_libretro_android.so", but that infix
## is a convention rather than a rule — azahar's CMake never set an Android
## OUTPUT_NAME, so the buildbot ships "azahar_libretro.so.zip". Accept both.
##
## The naming-dependent helpers take the suffix list and extension as optional
## arguments so a desktop probe can drive the Android naming without a device.
static func core_lib_suffixes() -> PackedStringArray:
	if OS.get_name() == "Android":
		return PackedStringArray(["_libretro_android", "_libretro"])
	return PackedStringArray(["_libretro"])


## Library filenames a core may be installed under, canonical first.
static func core_lib_filenames(core_name: String, suffixes := PackedStringArray(),
							   ext := "") -> PackedStringArray:
	if suffixes.is_empty():
		suffixes = core_lib_suffixes()
	if ext.is_empty():
		ext = _core_lib_ext()
	var names := PackedStringArray()
	for suffix: String in suffixes:
		names.append(core_name + suffix + ext)
	return names


## Strips the library suffix+extension off a filename, returning the bare core
## name — or "" if the filename is not a core library for this platform.
static func core_name_from_lib_filename(filename: String, suffixes := PackedStringArray(),
										ext := "") -> String:
	if suffixes.is_empty():
		suffixes = core_lib_suffixes()
	if ext.is_empty():
		ext = _core_lib_ext()
	for suffix: String in suffixes:
		var tail := suffix + ext
		if filename.ends_with(tail):
			return filename.trim_suffix(tail)
	return ""


## Filename the core is actually installed under, or "" if it isn't installed.
static func installed_core_lib(core_name: String) -> String:
	for filename: String in core_lib_filenames(core_name):
		if FileAccess.file_exists(default_cores_dir().path_join(filename)):
			return filename
	return ""

static func _core_lib_ext() -> String:
	if OS.get_name() in ["Android", "Linux"]:
		return ".so"
	if OS.get_name() == "macOS":
		return ".dylib"
	return ".dll"

## Default root directory for libretro data.
## On Android this is INTERNAL storage (/data/user/0/com.xenu.retroxr/files/libretro),
## a different filesystem from the ROM tree on /sdcard — `adb push` cannot reach it.
## On Linux: $HOME/retroxr/libretro. On Windows: %USERPROFILE%/retroxr/libretro.
static func default_core_root() -> String:
	if OS.get_name() == "Android":
		return OS.get_user_data_dir() + "/libretro"
	if OS.get_name() in ["Linux", "macOS"]:
		return OS.get_environment("HOME") + "/retroxr/libretro"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retroxr/libretro"


## Absolute path to the cores subdirectory (where DLLs live).
static func default_cores_dir() -> String:
	return default_core_root().path_join("cores")


## The manifest lives in the root (not cores/) so it isn't confused for a DLL.
static func default_manifest_dir() -> String:
	return default_core_root()


## Where a core looks for its BIOS/firmware — the dir handed to
## RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY. Per-core, not the shared RetroArch
## `system/`, so two cores serving one system each need their own copy of a BIOS.
## Mirrors Wrapper.cpp, which builds <root>/system/<core_name> and creates it on
## the core's first request.
static func default_system_dir(core_name: String) -> String:
	return default_core_root().path_join("system").path_join(core_name)


# ---------------------------------------------------------------------------
# Job signals
# ---------------------------------------------------------------------------
#
# Deliberately the same shape as FirmwareInstaller's, so the UI can report core
# downloads and BIOS installs through one set of handlers. `key` is stable for
# the life of a job and namespaced, so a toast keyed on it updates in place.

signal job_started(key: String, label: String, total_bytes: int)
signal job_progress(key: String, received: int, total: int)
signal job_retrying(key: String, attempt: int, max_attempts: int, reason: String)
signal job_finished(key: String, ok: bool, error: String)
signal job_cancelled(key: String)

const JOB_PREFIX := "core:"
## Network failures only. A 404 across every filename candidate is not retried:
## the core is named something else or is not published, and asking again three
## times just makes the player wait longer for the same answer.
const MAX_ATTEMPTS := 3
const RETRY_DELAY_SEC := 1.5

## Godot's HTTPRequest timeout defaults to 0, which is "wait for ever". Both of
## these fetch a small document and both settle a callback the Cores tab is
## waiting on, so a connection that opens and then stalls would leave the tab
## spinning with no error and no way back — the version probe's pending count in
## particular can only reach zero through `request_completed`.
##
## The core download deliberately has NO timeout: this is a total wall-clock
## limit rather than an idle one, and a hundred-megabyte core over a slow link
## is a legitimate request that would be cancelled part-way through.
const LISTING_TIMEOUT := 20.0
const VERSION_PROBE_TIMEOUT := 10.0


static func job_key(core_name: String) -> String:
	return JOB_PREFIX + core_name


# ---------------------------------------------------------------------------
# Public state
# ---------------------------------------------------------------------------

## Populated after fetch_available_cores() completes.
## Array of { core_name, filename, remote_date } dicts, sorted by core_name.
var available_cores: Array[Dictionary] = []

var manifest: DownloadManifest = null

## core_name -> { "http": HTTPRequest, "zip_path": String, "remote_date": String,
##                "candidates": PackedStringArray, "attempt": int, "net_attempt": int }
## Serialised by the queue below, so this holds at most one entry.
var _active_downloads: Dictionary = {}

## Pending { core_name, remote_date, label } in submission order.
var _queue: Array[Dictionary] = []
## The core being downloaded right now, or "" when idle.
var _current: String = ""

## Single HTTPRequest used for the directory listing fetch.
var _listing_request: HTTPRequest = null


# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

func _ready() -> void:
	ensure_directories()
	manifest = DownloadManifest.new()
	manifest.setup(default_manifest_dir())


func ensure_directories() -> void:
	var err := DirAccess.make_dir_recursive_absolute(default_cores_dir())
	if err != OK and err != ERR_ALREADY_EXISTS:
		push_error("CoreDownloadManager: failed to create cores dir '%s' (err %d)" % [default_cores_dir(), err])


# ---------------------------------------------------------------------------
# Fetch available cores from buildbot
# ---------------------------------------------------------------------------

## Fetches the buildbot HTML index and calls callback(cores: Array[Dictionary])
## where each dict has: core_name, filename, remote_date.
## On failure calls callback([]).
func fetch_available_cores(callback: Callable) -> void:
	if _listing_request != null:
		_listing_request.queue_free()

	_listing_request = HTTPRequest.new()
	_listing_request.use_threads = true
	_listing_request.timeout = LISTING_TIMEOUT
	add_child(_listing_request)
	_listing_request.request_completed.connect(
		func(result, response_code, _headers, body):
			_on_listing_completed(result, response_code, body, callback)
	)
	var err := _listing_request.request(_buildbot_url())
	if err != OK:
		push_error("CoreDownloadManager: failed to start listing request (err %d)" % err)
		callback.call([])


func _on_listing_completed(result: int, response_code: int,
							body: PackedByteArray, callback: Callable) -> void:
	if _listing_request:
		_listing_request.queue_free()
		_listing_request = null

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		push_error("CoreDownloadManager: listing fetch failed result=%d code=%d" % [result, response_code])
		callback.call([])
		return

	var html := body.get_string_from_utf8()
	available_cores = _apply_own_sources(_parse_listing_html(html))
	print("[CoreDownloadManager] Found %d downloadable cores on buildbot" % available_cores.size())
	# The listing is not complete until our own releases have been asked their
	# version, so the callback waits. It fires either way — a failed probe leaves
	# the shipped-with version in place rather than blocking the tab.
	_probe_own_versions(func() -> void: callback.call(available_cores))


## Replace the buildbot's entry for any core we publish ourselves, so the row the
## player sees offers OUR build.
##
## An override rather than a second row: CoreSources is deliberately keyed by the
## same core_name as the buildbot's, because the frontend derives system/<core>
## and save/<core> from it and a second name would strand the Sys folder and
## every save. Two rows would also mean two cores fighting over one filename.
##
## Cores we publish but do not build for this platform are left exactly as the
## buildbot listed them — CoreSources.has() is false there, so a Linux player
## still gets the stock Dolphin instead of a row that cannot download.
func _apply_own_sources(entries: Array[Dictionary]) -> Array[Dictionary]:
	for entry: Dictionary in entries:
		var core_name: String = entry.get("core_name", "")
		if not CoreSources.has(core_name):
			continue
		entry["filename"] = CoreSources.asset_for(core_name)
		# The tag stands in for the buildbot's timestamp. Anyone holding the stock
		# build has a date stored, which differs, so the row reads UPDATE.
		# Replaced by the live tag if the probe below reaches GitHub.
		entry["remote_date"] = CoreSources.version_of(core_name)
		entry["source"] = "retroxr"
	return entries


## Ask GitHub what the newest release of each core we publish is called, and put
## that in the entry the row reads.
##
## Needed because the download URL is the /releases/latest/ form, which is what
## lets a new core build reach players without a new app build — but it means the
## app cannot tell from the URL alone whether anything changed. Without this the
## manager would happily fetch a newer core while reporting "Re-Download", and an
## update would only ever arrive by accident.
##
## Every failure path still calls `done`. A player with no network, or a rate
## limit hit, gets the version this app shipped knowing about and a working tab.
func _probe_own_versions(done: Callable) -> void:
	var names := CoreSources.active_core_names()
	if names.is_empty():
		done.call()
		return
	# A Dictionary, not an int: GDScript lambdas capture locals by value, so a
	# plain counter would be decremented on copies and never reach zero.
	var state := {"pending": names.size()}
	for core_name: String in names:
		var http := HTTPRequest.new()
		http.use_threads = true
		http.timeout = VERSION_PROBE_TIMEOUT
		add_child(http)
		var settle := func() -> void:
			http.queue_free()
			state["pending"] = int(state["pending"]) - 1
			if int(state["pending"]) == 0:
				done.call()
		http.request_completed.connect(
			func(result: int, code: int, _headers: PackedStringArray, rbody: PackedByteArray) -> void:
				if result == HTTPRequest.RESULT_SUCCESS and code == 200:
					var parsed: Variant = JSON.parse_string(rbody.get_string_from_utf8())
					if parsed is Dictionary:
						var tag := str((parsed as Dictionary).get("tag_name", ""))
						if not tag.is_empty():
							for entry: Dictionary in available_cores:
								if entry.get("core_name", "") == core_name:
									entry["remote_date"] = tag
							print("[CoreDownloadManager] %s: newest release is %s" % [core_name, tag])
				else:
					push_warning("CoreDownloadManager: version probe for '%s' failed (result %d, HTTP %d) — using %s"
						% [core_name, result, code, CoreSources.version_of(core_name)])
				settle.call())
		# GitHub rejects API requests with no User-Agent.
		var err := http.request(CoreSources.api_url(core_name), PackedStringArray([
			"User-Agent: retroXR",
			"Accept: application/vnd.github+json",
		]))
		if err != OK:
			push_warning("CoreDownloadManager: could not start version probe for '%s' (err %d)"
				% [core_name, err])
			settle.call()


## Parse the h5ai fallback table embedded in the raw HTML.
## The page always includes a <div id="fallback"> table for non-JS browsers with:
##   <a href="/nightly/.../fceumm_libretro.dll.zip">fceumm_libretro.dll.zip</a>
##   <td class="fb-d">2026-03-06 03:10</td>
func _parse_listing_html(html: String, suffixes := PackedStringArray(),
						 ext := "") -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	if suffixes.is_empty():
		suffixes = core_lib_suffixes()
	if ext.is_empty():
		ext = _core_lib_ext()

	# Match relative hrefs that end in any of the platform-appropriate zip patterns
	var zip_ext := ext + "\\.zip"
	var suffix_alts := PackedStringArray()
	for suffix: String in suffixes:
		suffix_alts.append(suffix.replace("_", "\\_"))
	var lib_suffix := "(?:" + "|".join(suffix_alts) + ")"
	var href_regex := RegEx.new()
	href_regex.compile('href="[^"]*?/([^"/_][^"]*?' + lib_suffix + zip_ext + ')"')

	# Date in the adjacent fb-d cell: "2026-03-06 03:10"
	var date_regex := RegEx.new()
	date_regex.compile('<td class="fb-d">(\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2})</td>')

	var href_matches := href_regex.search_all(html)
	var date_matches := date_regex.search_all(html)

	# Build a list of (position, date_string) so we can match each file to its nearest date
	var dates: Array = []
	for dm: RegExMatch in date_matches:
		dates.append({"pos": dm.get_start(), "date": dm.get_string(1)})

	for m: RegExMatch in href_matches:
		var filename: String = m.get_string(1).get_file()  # strip any leading path

		var core_name := core_name_from_lib_filename(filename.trim_suffix(".zip"), suffixes, ext)
		if core_name.is_empty():
			continue

		# Find closest date entry that comes after this href in the HTML
		var href_pos := m.get_start()
		var remote_date := ""
		for d in dates:
			if d["pos"] > href_pos:
				remote_date = d["date"]
				break

		results.append({
			"core_name":   core_name,
			"filename":    filename,
			"remote_date": remote_date
		})

	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["core_name"] < b["core_name"]
	)
	return results


# ---------------------------------------------------------------------------
# Download state
# ---------------------------------------------------------------------------

## Remove an installed core's library and forget it.
##
## Deliberately narrow: the .dll/.so and the manifest row, nothing else. A core's
## system directory holds BIOS dumps the user may have spent real effort getting,
## and its .opt file holds tuning — neither is re-downloadable the way the core
## itself is, and both belong to the machine rather than to this binary. They are
## offered separately by the cleanup sweep once nothing claims them.
##
## Returns {ok, freed, error}. `freed` is bytes reclaimed.
static func uninstall(core_name: String) -> Dictionary:
	if core_name.is_empty():
		return {"ok": false, "freed": 0, "error": "No core named"}

	var dir := default_cores_dir()
	var freed := 0
	var removed := 0
	var last_error := ""

	# Every naming variant, not just the canonical one: Android installs land as
	# either `_libretro_android.so` or `_libretro.so` depending on what the
	# buildbot served, and removing only the first leaves the core still loadable.
	for filename: String in core_lib_filenames(core_name):
		var path := dir.path_join(filename)
		if not FileAccess.file_exists(path):
			continue
		var size := 0
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			size = int(f.get_length())
			f.close()
		if DirAccess.remove_absolute(path) == OK:
			freed += size
			removed += 1
		else:
			last_error = "Could not remove %s" % filename

	if removed == 0:
		return {"ok": false, "freed": 0,
			"error": last_error if not last_error.is_empty() else "Core is not installed"}

	# Only after the file is gone. A manifest that forgets a core still on disk
	# reports it as downloadable and re-downloads over itself.
	var mf := DownloadManifest.new()
	mf.setup(default_manifest_dir())
	mf.remove(core_name)

	return {"ok": true, "freed": freed, "error": last_error}


## Machines in the scene currently resolved to this core, by display name.
##
## A core is copied to a temp directory when it loads, so deleting the original
## does not crash a running emulator — it fails the NEXT start, long after the
## action that caused it, which is the worst possible time to find out.
static func systems_using(core_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	if core_name.is_empty() or not Engine.get_main_loop() is SceneTree:
		return out
	var tree := Engine.get_main_loop() as SceneTree
	for node: Node in tree.get_nodes_in_group("retro_system"):
		if not is_instance_valid(node):
			continue
		# Duck-typed: system.gd resolves an empty core_name through CoreDefaults,
		# so the property alone would miss every machine left on its default.
		if not node.has_method("resolve_core_name"):
			continue
		if str(node.resolve_core_name()) != core_name:
			continue
		out.append(str(node.get("system_label")) if node.get("system_label") != null
			else node.name)
	return out


## Returns one of: "Download", "Re-Download", "UPDATE", "BUSY"
func get_core_state(core_name: String, remote_date: String) -> String:
	if is_queued(core_name):
		return "BUSY"
	if not manifest.is_downloaded(core_name):
		return "Download"
	# If we have a remote date and it differs from what we stored, offer UPDATE
	var stored_date := manifest.get_remote_date(core_name)
	if remote_date != "" and stored_date != "" and remote_date != stored_date:
		return "UPDATE"
	return "Re-Download"


# ---------------------------------------------------------------------------
# Download a core
# ---------------------------------------------------------------------------

## Queue a core for download. Progress and the outcome arrive on the job_*
## signals, keyed job_key(core_name) — nothing is reported through the caller's
## widgets, so a download survives the row being freed.
##
## `label` is what the player should see; defaults to the core name.
func enqueue_core(core_name: String, remote_date: String, label: String = "") -> void:
	if is_queued(core_name):
		return
	_queue.append({
		"core_name": core_name,
		"remote_date": remote_date,
		"label": label if not label.is_empty() else core_name,
	})
	_pump()


func is_queued(core_name: String) -> bool:
	if _current == core_name:
		return true
	for job: Dictionary in _queue:
		if job["core_name"] == core_name:
			return true
	return false


func is_busy() -> bool:
	return not _current.is_empty()


func queued_count() -> int:
	return _queue.size() + (1 if is_busy() else 0)


func current_key() -> String:
	return "" if _current.is_empty() else job_key(_current)


## Abandon the running download. The part-file is removed by _cleanup_download.
func cancel_current() -> void:
	if _current.is_empty():
		return
	var core_name := _current
	var zip_path: String = _active_downloads.get(core_name, {}).get("zip_path", "")
	_cleanup_download(core_name)
	if not zip_path.is_empty() and FileAccess.file_exists(zip_path):
		DirAccess.remove_absolute(zip_path)
	_current = ""
	job_cancelled.emit(job_key(core_name))
	_pump()


func cancel_all() -> void:
	var pending := _queue.duplicate()
	_queue.clear()
	for job: Dictionary in pending:
		job_cancelled.emit(job_key(str(job["core_name"])))
	cancel_current()


## One at a time: the buildbot is the same host for every core, and parallel
## downloads only trade throughput for a progress readout nobody can follow.
func _pump() -> void:
	if is_busy() or _queue.is_empty():
		return
	var job: Dictionary = _queue.pop_front()
	var core_name := str(job["core_name"])
	_current = core_name
	_active_downloads[core_name] = {
		"http":        null,
		"zip_path":    "",
		"remote_date": str(job["remote_date"]),
		"label":       str(job["label"]),
		"candidates":  _zip_candidates(core_name),
		"attempt":     0,
		"net_attempt": 0,
	}
	job_started.emit(job_key(core_name), str(job["label"]), 0)
	_start_download_attempt(core_name)


## Finish the running job and start the next one.
func _finish(core_name: String, ok: bool, error: String) -> void:
	_cleanup_download(core_name)
	if _current == core_name:
		_current = ""
	job_finished.emit(job_key(core_name), ok, error)
	_pump()


## Zip names to try for a core, best guess first: whatever the buildbot listing
## actually advertised, then each platform naming convention.
func _zip_candidates(core_name: String) -> PackedStringArray:
	# A core we publish ourselves has exactly one asset name, and guessing past it
	# would silently fall through to the buildbot's build under a name that does
	# happen to exist there. One candidate, so a miss is reported as a miss.
	if CoreSources.has(core_name):
		return PackedStringArray([CoreSources.asset_for(core_name)])
	var candidates := PackedStringArray()
	for entry: Dictionary in available_cores:
		if entry.get("core_name", "") == core_name:
			var listed: String = entry.get("filename", "")
			if not listed.is_empty():
				candidates.append(listed)
			break
	for filename: String in core_lib_filenames(core_name):
		var zip_name := filename + ".zip"
		if not candidates.has(zip_name):
			candidates.append(zip_name)
	return candidates


func _start_download_attempt(core_name: String) -> void:
	var info: Dictionary = _active_downloads[core_name]
	var zip_filename: String = (info["candidates"] as PackedStringArray)[info["attempt"] as int]
	var zip_path := default_cores_dir().path_join(zip_filename)

	var http := HTTPRequest.new()
	http.use_threads = true
	http.download_file = zip_path          # stream directly to disk
	http.download_chunk_size = 65536
	add_child(http)

	info["http"]     = http
	info["zip_path"] = zip_path

	http.request_completed.connect(
		func(result, response_code, _headers, _body):
			_on_download_completed(core_name, result, response_code)
	)

	# Our own release for the cores we publish, the buildbot for everything else.
	# Both are a directory URL with a filename on the end, so only the stem moves.
	var base := CoreSources.base_url(core_name) if CoreSources.has(core_name) else _buildbot_url()
	var err := http.request(base + zip_filename)
	if err != OK:
		push_error("CoreDownloadManager: failed to start download of '%s' (err %d)" % [core_name, err])
		_finish(core_name, false, "Could not start the request (err %d)" % err)


func _process(_delta: float) -> void:
	for core_name: String in _active_downloads.keys():
		var info: Dictionary = _active_downloads[core_name]
		var http: HTTPRequest = info["http"]
		if not is_instance_valid(http):
			continue
		var total := http.get_body_size()
		if total > 0:
			job_progress.emit(job_key(core_name), http.get_downloaded_bytes(), total)


func _on_download_completed(core_name: String, result: int, response_code: int) -> void:
	var info: Dictionary = _active_downloads.get(core_name, {})
	if info.is_empty():
		return

	var zip_path: String  = info["zip_path"]
	var remote_date: String = info["remote_date"]

	if result != HTTPRequest.RESULT_SUCCESS or response_code != 200:
		# Remove incomplete zip if it exists
		if FileAccess.file_exists(zip_path):
			DirAccess.remove_absolute(zip_path)

		# A 404 usually means this core doesn't follow the naming convention we
		# guessed (azahar has no "_android" infix on Android) — try the next one.
		var next_attempt: int = (info["attempt"] as int) + 1
		if next_attempt < (info["candidates"] as PackedStringArray).size():
			info["attempt"] = next_attempt
			_free_download_request(core_name)
			_start_download_attempt(core_name)
			return

		# Every filename tried. If the transport itself failed, the name is
		# probably fine and the network is not — that is worth another go from
		# the top. A clean HTTP error code is an answer, not a glitch.
		if result != HTTPRequest.RESULT_SUCCESS:
			var net_attempt: int = (info["net_attempt"] as int) + 1
			if net_attempt < MAX_ATTEMPTS:
				info["net_attempt"] = net_attempt
				info["attempt"] = 0
				_free_download_request(core_name)
				job_retrying.emit(job_key(core_name), net_attempt + 1, MAX_ATTEMPTS,
					"Connection failed")
				get_tree().create_timer(RETRY_DELAY_SEC).timeout.connect(
					func() -> void:
						# cancel_current() during the wait drops the entry.
						if _active_downloads.has(core_name):
							_start_download_attempt(core_name))
				return
			_finish(core_name, false, "Connection failed after %d attempts" % MAX_ATTEMPTS)
			return

		if CoreSources.has(core_name):
			_finish(core_name, false, "Not in the %s release (HTTP %d)"
				% [CoreSources.version_of(core_name), response_code])
		else:
			_finish(core_name, false, "Not available on the buildbot (HTTP %d)" % response_code)
		return

	_free_download_request(core_name)

	# Extract the zip
	var extract_err := _extract_zip(zip_path, default_cores_dir())
	# Always delete the zip regardless of extraction result
	if FileAccess.file_exists(zip_path):
		DirAccess.remove_absolute(zip_path)

	if extract_err != OK:
		_finish(core_name, false, "Could not unpack the download (err %d)" % extract_err)
		return

	# Update manifest with the name the core actually landed under
	manifest.set_downloaded(core_name, remote_date, installed_core_lib(core_name))
	print("[CoreDownloadManager] Downloaded and extracted: %s" % core_name)
	_finish(core_name, true, "")


## Extract all files from zip_path into dest_dir.
## Returns OK on success, or an error code.
func _extract_zip(zip_path: String, dest_dir: String) -> int:
	var reader := ZIPReader.new()
	var err := reader.open(zip_path)
	if err != OK:
		push_error("CoreDownloadManager: cannot open zip '%s' (err %d)" % [zip_path, err])
		return err

	for entry: String in reader.get_files():
		# Skip directory entries
		if entry.ends_with("/"):
			continue
		var data := reader.read_file(entry)
		# Flatten: write only the filename, not any path inside the zip
		var out_path := dest_dir.path_join(entry.get_file())
		var out := FileAccess.open(out_path, FileAccess.WRITE)
		if out == null:
			reader.close()
			push_error("CoreDownloadManager: cannot write '%s' (err %d)" % [out_path, FileAccess.get_open_error()])
			return FileAccess.get_open_error()
		out.store_buffer(data)
		out.close()

	reader.close()
	return OK


# ---------------------------------------------------------------------------
# Internal
# ---------------------------------------------------------------------------

func _cleanup_download(core_name: String) -> void:
	_free_download_request(core_name)
	_active_downloads.erase(core_name)


## Drop the HTTPRequest but keep the download entry, so the next filename
## candidate can reuse its callbacks.
func _free_download_request(core_name: String) -> void:
	if not _active_downloads.has(core_name):
		return
	var http: HTTPRequest = _active_downloads[core_name]["http"]
	if is_instance_valid(http):
		http.queue_free()
	_active_downloads[core_name]["http"] = null
