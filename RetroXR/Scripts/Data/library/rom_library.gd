## RomLibrary — manages the %USERPROFILE%/roms/{systemid}/ directory structure.
##
## ROM directories are created automatically at startup (via CoreDefaults.load_defaults())
## and on core download completion. scan_roms() filters by supported_extensions.
class_name RomLibrary
extends RefCounted


## Root directory for ROMs.
## On Android: app external files dir (no permission needed). On Windows: %USERPROFILE%/retroxr/roms.
static func default_roms_root() -> String:
	if OS.get_name() == "Android":
		return "/sdcard/Android/data/com.xenu.retroxr/files/roms"
	if OS.get_name() in ["Linux", "macOS"]:
		return OS.get_environment("HOME") + "/retroxr/roms"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retroxr/roms"


## Absolute path for a single system's ROM folder.
static func rom_dir_for_system(systemid: String) -> String:
	return default_roms_root().path_join(systemid)


## Create just the top-level roms/ root (no systemid). Safe to call any time.
static func ensure_roms_root() -> void:
	var path := default_roms_root()
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Ensured roms root: ", path)
	else:
		push_warning("[RomLibrary] Failed to create roms root '%s' (err %d)" % [path, err])


## Create the ROM folder for a system (idempotent — always calls make_dir_recursive).
static func ensure_rom_dir(systemid: String) -> void:
	if systemid.is_empty():
		return
	var path := rom_dir_for_system(systemid)
	if DirAccess.dir_exists_absolute(path):
		return
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Created rom dir: ", path)
	else:
		push_warning("[RomLibrary] Failed to create rom dir '%s' (err %d)" % [path, err])


## Scan a system's ROM folder and return all matching files.
## extensions: lowercase strings without dots, e.g. ["nes", "fds"].
## Returns Array of {path: String, label: String} sorted by label, or [] if folder missing.
##
## Multi-file disc images (bin/cue, img/ccd, mdf/mds) are collapsed to their
## descriptor file — the data-only companion is hidden when its descriptor exists.
static func scan_roms(systemid: String, extensions: Array[String]) -> Array[Dictionary]:
	var dir_path := rom_dir_for_system(systemid)
	var dir := DirAccess.open(dir_path)
	if not dir:
		return []

	# A dotcode card is one to two strip files and belongs in the browser ONCE,
	# the same way a bin/cue pair does. It cannot go through SHADOWED_BY below:
	# that pairs by extension and both strips are .raw, so grouping is by name.
	if systemid == EReaderCards.SYSTEMID:
		return _scan_ereader_cards(dir_path)

	# data ext -> descriptor ext that supersedes it
	const SHADOWED_BY := {"bin": "cue", "img": "ccd", "mdf": "mds"}

	# First pass: collect all filenames present in the directory. Key by lowercase
	# for case-insensitive descriptor lookups, but keep the ORIGINAL-case name as
	# the value — the real path must preserve case (Linux is case-sensitive, so a
	# lowercased path fails to open; that broke ROM loading + scraper hashing).
	var all_files: Dictionary = {}  # lowercase filename -> original filename
	var subdirs: Array[String] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if dir.current_is_dir():
			subdirs.append(fname)
		else:
			all_files[fname.to_lower()] = fname
		fname = dir.get_next()
	dir.list_dir_end()

	# Second pass: build results, skipping data files whose descriptor exists
	var results: Array[Dictionary] = []
	for lower: String in all_files:
		var file: String = all_files[lower]   # original-case filename
		if file.begins_with("."):
			continue
		var ext := lower.get_extension()   # lowercase for case-insensitive matching
		if ext in SHADOWED_BY:
			var descriptor_ext: String = SHADOWED_BY[ext]
			var descriptor_lower := lower.get_basename() + "." + descriptor_ext
			if descriptor_lower in all_files and (extensions.is_empty() or descriptor_ext in extensions):
				continue  # hidden — the .cue/.ccd/.mds entry covers it
		if not extensions.is_empty() and ext not in extensions:
			continue
		var full_path := dir_path.path_join(file)   # original case preserved
		# An adapter's dump is HARDWARE, not a game. A reader's cartridge dump is
		# an ordinary Game Boy Advance ROM and lives on this shelf, but it is the
		# machine the e-Reader tile spawns -- listing it here too offers it as
		# something to play, and a player who deletes it from the list has
		# deleted their reader.
		#
		# Asked here rather than in the browser because a dump matched to a RomM
		# entry becomes a "both" row: filtering the local-only pass would leave it
		# showing anyway. This hides it from every consumer at once.
		#
		# Costs nothing on a platform with no adapter, and one cached directory
		# probe on one that has -- see AdapterRoms, which exists for that reason.
		if AdapterRoms.is_adapter_rom(systemid, full_path):
			continue
		results.append({"path": full_path, "label": file.get_basename()})

	var info := SystemInfo.for_system(systemid)
	if info != null and info.folder_content:
		results.append_array(_scan_content_folders(
			dir_path, subdirs, CoreInfoDatabase.extensions_for_systemid(systemid),
			extensions))

	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["label"] as String).naturalnocasecmp_to(b["label"] as String) < 0
	)
	return results


## One row per CARD, carrying its first strip. A card finds its other strip from
## the library, so the path here is an identity rather than the whole medium.
##
## Cards whose dump is unusable are left out rather than offered: a strip of the
## wrong length is one GBACartEReaderScan drops silently, so spawning it would
## give a card that does nothing and says nothing about why.
static func _scan_ereader_cards(dir_path: String) -> Array[Dictionary]:
	var results: Array[Dictionary] = []
	for card: Dictionary in EReaderCards.cards(dir_path):
		if str(card["shape"]) == EReaderCards.SHAPE_BROKEN:
			continue
		var strips: Array = card["strips"]
		if strips.is_empty():
			continue
		results.append({
			"path": str((strips[0] as Dictionary)["path"]),
			"label": str(card["label"]),
		})
	return results


## Index scan results by lowercase basename, resolving same-stem collisions.
##
## The library keys on the stem rather than the filename so a row survives its
## file changing extension underneath it — a RomM .zip unpacking into .3ds, a
## .cue standing in for the .bin beside it. The cost is that every file sharing a
## stem competes for one key, and the loser is not shown at all.
##
## Highest score wins:
##   2  a manifest (cue/gdi/m3u/ccd) — the descriptor a core is handed, never a
##      raw track sitting beside it
##   1  an extension some core declares for this system: an actual game
##   0  everything else — a battery save, a savestate, a screenshot
##
## Tier 1 over 0 is the load-bearing one. Emulator front ends routinely keep
## `Game.srm` next to `Game.sfc`, and an imported library arrives that way; with
## last-one-wins whichever the directory happened to yield second took the key,
## and if that was the save then the GAME vanished from the library entirely.
## Nothing said so — the row was simply absent.
static func index_by_basename(roms: Array[Dictionary], rom_exts: Array[String]) -> Dictionary:
	var by_name: Dictionary = {}
	var score: Dictionary = {}
	for rom: Dictionary in roms:
		var path := str(rom["path"])
		var key := path.get_file().get_basename().to_lower()
		var ext := path.get_extension().to_lower()
		var rank := 0
		if ext in RommCatalog.MANIFEST_EXTS:
			rank = 2
		elif ext in rom_exts:
			rank = 1
		# Strictly greater, so the first of an equal pair keeps the key and the
		# scan's own ordering decides — not the directory's.
		if by_name.has(key) and rank <= int(score[key]):
			continue
		by_name[key] = rom
		score[key] = rank
	return by_name


## One game per subfolder: find the marker file the core is handed inside each.
##
## The folder name is the label, not the marker's basename — markers are named by
## ScummVM target id ("monkey", "atlantis-amiga"), while the folder carries the
## human title.
##
## Matches on what the core declares it can load, NOT the caller's filter, because
## the library is also scanned unfiltered (the RomM path does, to spot downloaded
## .zips); keying off the caller would mean picking an arbitrary data file
## (MONKEY.001, Track3.fla) out of the folder.
static func _scan_content_folders(dir_path: String, subdirs: Array[String],
		marker_exts: Array[String], extensions: Array[String]) -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	if marker_exts.is_empty():
		return found
	for sub: String in subdirs:
		if sub.begins_with("."):
			continue
		var sub_path := dir_path.path_join(sub)
		var inner := DirAccess.open(sub_path)
		if not inner:
			continue
		inner.list_dir_begin()
		var f := inner.get_next()
		while f != "":
			var ext := f.get_extension().to_lower()
			if not inner.current_is_dir() and not f.begins_with(".") \
					and ext in marker_exts \
					and (extensions.is_empty() or ext in extensions):
				found.append({"path": sub_path.path_join(f), "label": sub})
				break
			f = inner.get_next()
		inner.list_dir_end()
	return found


## Return the scraped manual path (in media/manual/ directory).
## Prefers .pdf; falls back to .cbz; returns .pdf path if neither exists.
static func scraped_manual_path(systemid: String, romname: String) -> String:
	var base := romname.get_basename()
	var dir := rom_dir_for_system(systemid).path_join("media/manual")
	for ext in ["pdf", "cbz"]:
		var path := dir.path_join(base + "." + ext)
		if FileAccess.file_exists(path):
			return path
	return dir.path_join(base + ".pdf")


## Root directory for books (PDFs).
## Sits alongside the roms/ folder in the same files root.
static func default_books_root() -> String:
	if OS.get_name() == "Android":
		return "/sdcard/Android/data/com.xenu.retroxr/files/books"
	if OS.get_name() in ["Linux", "macOS"]:
		return OS.get_environment("HOME") + "/retroxr/books"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retroxr/books"


## Create the books root if it doesn't already exist.
static func ensure_books_root() -> void:
	var path := default_books_root()
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Ensured books root: ", path)
	else:
		push_warning("[RomLibrary] Failed to create books root '%s' (err %d)" % [path, err])


## Scan the books root and return all PDF files sorted by name.
## Returns Array of {path: String, label: String}.
static func scan_books() -> Array[Dictionary]:
	var dir_path := default_books_root()
	var dir := DirAccess.open(dir_path)
	if not dir:
		return []
	var results: Array[Dictionary] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var ext := fname.get_extension().to_lower()
		if not dir.current_is_dir() and (ext == "pdf" or ext == "cbz"):
			results.append({"path": dir_path.path_join(fname), "label": fname.get_basename()})
		fname = dir.get_next()
	dir.list_dir_end()
	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["label"] as String).naturalnocasecmp_to(b["label"] as String) < 0
	)
	return results


## Video file extensions playable via the VlcPlayer GDExtension.
const VIDEO_EXTENSIONS := ["mp4", "mkv", "avi", "webm", "mov"]


## Root directory for videos.
## Sits alongside the roms/ and books/ folders in the same files root.
static func default_videos_root() -> String:
	if OS.get_name() == "Android":
		return "/sdcard/Android/data/com.xenu.retroxr/files/videos"
	if OS.get_name() in ["Linux", "macOS"]:
		return OS.get_environment("HOME") + "/retroxr/videos"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retroxr/videos"


## Create the videos root if it doesn't already exist.
static func ensure_videos_root() -> void:
	var path := default_videos_root()
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Ensured videos root: ", path)
	else:
		push_warning("[RomLibrary] Failed to create videos root '%s' (err %d)" % [path, err])


## Scan the videos root and return all video files sorted by name.
## Returns Array of {path: String, label: String}.
static func scan_videos() -> Array[Dictionary]:
	var dir_path := default_videos_root()
	var dir := DirAccess.open(dir_path)
	if not dir:
		return []
	var results: Array[Dictionary] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var ext := fname.get_extension().to_lower()
		if not dir.current_is_dir() and ext in VIDEO_EXTENSIONS:
			results.append({"path": dir_path.path_join(fname), "label": fname.get_basename()})
		fname = dir.get_next()
	dir.list_dir_end()
	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["label"] as String).naturalnocasecmp_to(b["label"] as String) < 0
	)
	return results


## Image extensions a poster can be made from.
const POSTER_EXTENSIONS := ["png", "jpg", "jpeg", "webp"]


## Root directory for posters.
## Sits alongside the roms/ and books/ folders in the same files root.
static func default_posters_root() -> String:
	if OS.get_name() == "Android":
		return "/sdcard/Android/data/com.xenu.retroxr/files/posters"
	if OS.get_name() in ["Linux", "macOS"]:
		return OS.get_environment("HOME") + "/retroxr/posters"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retroxr/posters"


## Create the posters root if it doesn't already exist.
static func ensure_posters_root() -> void:
	var path := default_posters_root()
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Ensured posters root: ", path)
	else:
		push_warning("[RomLibrary] Failed to create posters root '%s' (err %d)" % [path, err])


## Scan the posters root and return all image files sorted by name.
## Returns Array of {path: String, label: String}.
static func scan_posters() -> Array[Dictionary]:
	var dir_path := default_posters_root()
	var dir := DirAccess.open(dir_path)
	if not dir:
		return []
	var results: Array[Dictionary] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var ext := fname.get_extension().to_lower()
		if not dir.current_is_dir() and ext in POSTER_EXTENSIONS:
			results.append({"path": dir_path.path_join(fname), "label": fname.get_basename()})
		fname = dir.get_next()
	dir.list_dir_end()
	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["label"] as String).naturalnocasecmp_to(b["label"] as String) < 0
	)
	return results


## Path to the TV root — the set's channel list (channels.json) lives here, and
## it is where a guide cache or channel logos would go later.
static func default_tv_root() -> String:
	if OS.get_name() == "Android":
		return "/sdcard/Android/data/com.xenu.retroxr/files/tv"
	if OS.get_name() in ["Linux", "macOS"]:
		return OS.get_environment("HOME") + "/retroxr/tv"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retroxr/tv"


## Create the tv root if it doesn't already exist.
static func ensure_tv_root() -> void:
	var path := default_tv_root()
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Ensured tv root: ", path)
	else:
		push_warning("[RomLibrary] Failed to create tv root '%s' (err %d)" % [path, err])


## Path to the DVDs root — real DVD images (a VIDEO_TS/ folder, or an .iso/.img
## file) live here, played by the libVLC-backed DVDPlayer.
static func default_dvd_root() -> String:
	if OS.get_name() == "Android":
		return "/sdcard/Android/data/com.xenu.retroxr/files/dvd"
	if OS.get_name() in ["Linux", "macOS"]:
		return OS.get_environment("HOME") + "/retroxr/dvd"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retroxr/dvd"


## Create the dvd root if it doesn't already exist.
static func ensure_dvd_root() -> void:
	var path := default_dvd_root()
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Ensured dvd root: ", path)
	else:
		push_warning("[RomLibrary] Failed to create dvd root '%s' (err %d)" % [path, err])


## Scan the dvd root. Each disc is either a subfolder containing a VIDEO_TS/ dir,
## or a standalone .iso/.img image. Returns Array of {path: String, label: String}.
static func scan_dvds() -> Array[Dictionary]:
	var root := default_dvd_root()
	var dir := DirAccess.open(root)
	if not dir:
		return []
	var results: Array[Dictionary] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var full: String = root.path_join(fname)
		if dir.current_is_dir():
			if DirAccess.dir_exists_absolute(full.path_join("VIDEO_TS")):
				results.append({"path": full, "label": fname})
		elif fname.get_extension().to_lower() in ["iso", "img"]:
			results.append({"path": full, "label": fname.get_basename()})
		fname = dir.get_next()
	dir.list_dir_end()
	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["label"] as String).naturalnocasecmp_to(b["label"] as String) < 0
	)
	return results


## Audio file extensions playable via libVLC (used by the CD/cassette players).
const MUSIC_EXTENSIONS := ["mp3", "flac", "ogg", "wav", "m4a", "aac", "opus", "wma"]


## Root directory for music. Each subfolder is an album (multi-track); loose
## audio files are single-track albums. Sits alongside roms/, videos/, dvd/.
static func default_music_root() -> String:
	if OS.get_name() == "Android":
		return "/sdcard/Android/data/com.xenu.retroxr/files/music"
	if OS.get_name() in ["Linux", "macOS"]:
		return OS.get_environment("HOME") + "/retroxr/music"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retroxr/music"


## Create the music root if it doesn't already exist.
static func ensure_music_root() -> void:
	var path := default_music_root()
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Ensured music root: ", path)
	else:
		push_warning("[RomLibrary] Failed to create music root '%s' (err %d)" % [path, err])


## True when the folder contains at least one playable audio file.
static func _dir_has_audio(dir_path: String) -> bool:
	var dir := DirAccess.open(dir_path)
	if not dir:
		return false
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.get_extension().to_lower() in MUSIC_EXTENSIONS:
			dir.list_dir_end()
			return true
		fname = dir.get_next()
	dir.list_dir_end()
	return false


## Scan the music root and return all albums. Each album is either a subfolder
## containing audio files, or a standalone audio file (a single-track album).
## Returns Array of {path: String, label: String}.
static func scan_music() -> Array[Dictionary]:
	var root := default_music_root()
	var dir := DirAccess.open(root)
	if not dir:
		return []
	var results: Array[Dictionary] = []
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		var full: String = root.path_join(fname)
		if dir.current_is_dir():
			if _dir_has_audio(full):
				results.append({"path": full, "label": fname})
		elif fname.get_extension().to_lower() in MUSIC_EXTENSIONS:
			results.append({"path": full, "label": fname.get_basename()})
		fname = dir.get_next()
	dir.list_dir_end()
	results.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return (a["label"] as String).naturalnocasecmp_to(b["label"] as String) < 0
	)
	return results


## Resolve an album path into an ordered list of track file paths. A folder is
## expanded to its audio files (natural sort); a single file yields itself.
static func music_tracks(album_path: String) -> PackedStringArray:
	var tracks := PackedStringArray()
	if album_path.is_empty():
		return tracks
	if DirAccess.dir_exists_absolute(album_path):
		var dir := DirAccess.open(album_path)
		if dir:
			var names: Array[String] = []
			dir.list_dir_begin()
			var fname := dir.get_next()
			while fname != "":
				if not dir.current_is_dir() and fname.get_extension().to_lower() in MUSIC_EXTENSIONS:
					names.append(fname)
				fname = dir.get_next()
			dir.list_dir_end()
			names.sort_custom(func(a: String, b: String) -> bool:
				return a.naturalnocasecmp_to(b) < 0)
			for n in names:
				tracks.append(album_path.path_join(n))
	elif FileAccess.file_exists(album_path):
		tracks.append(album_path)
	return tracks


## Find a local album (folder or file) in the music root whose basename matches
## `name`, for verify-by-name netplay resolution (albums have no single hash).
## Returns the local path, or "" if the peer doesn't have that album.
static func find_music_album(name: String) -> String:
	if name.is_empty():
		return ""
	var root := default_music_root()
	var dir := DirAccess.open(root)
	if not dir:
		return ""
	var result := ""
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if fname == name:
			result = root.path_join(fname)
			break
		fname = dir.get_next()
	dir.list_dir_end()
	return result


## Root directory for mod packs, beside roms/ and books/ in the same files root.
##
## On Android this is the EXTERNAL tree on purpose, so a mod can be `adb push`ed
## like a ROM. The app only ever reads from here — see ensure_mods_root.
static func default_mods_root() -> String:
	if OS.get_name() == "Android":
		return "/sdcard/Android/data/com.xenu.retroxr/files/mods"
	if OS.get_name() in ["Linux", "macOS"]:
		return OS.get_environment("HOME") + "/retroxr/mods"
	return OS.get_environment("USERPROFILE").replace("\\", "/") + "/retroxr/mods"


## Create the mods root if it doesn't already exist, and report whether it is
## there afterwards.
##
## Unlike its siblings this one TOLERATES failure rather than warning about it.
## A directory created by `adb push` under Android/data is 0770 owned by shell,
## with a group the app is not in, so the app cannot create anything inside one
## and make_dir_recursive_absolute can fail on a folder that is perfectly
## readable. Since mods are only ever read, that is not an error worth shouting
## about — the scan below works fine either way.
static func ensure_mods_root() -> bool:
	var path := default_mods_root()
	if DirAccess.dir_exists_absolute(path):
		return true
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err == OK:
		print("[RomLibrary] Ensured mods root: ", path)
		return true
	print("[RomLibrary] mods root '%s' is absent and could not be created (err %d)"
		% [path, err])
	return false


## Every mod container in the mods root, sorted by name.
## Returns Array of {path: String, label: String}.
static func scan_mods() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var root := default_mods_root()
	var dir := DirAccess.open(root)
	if dir == null:
		return out
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			var ext := fname.get_extension().to_lower()
			if ext == "zip" or ext == "pck":
				out.append({"path": root.path_join(fname), "label": fname})
		fname = dir.get_next()
	dir.list_dir_end()
	out.sort_custom(func(a, b): return str(a["label"]).naturalnocasecmp_to(str(b["label"])) < 0)
	return out
