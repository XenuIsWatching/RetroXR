## StatePaths — where save states live, and the only thing that writes them.
##
## Layout, a sibling of the battery-save tree so nothing new has to be learned:
##   <root>/states/<core_name>/<game_stem>/<state_id>.state   the serialized core
##   <root>/states/<core_name>/<game_stem>/<state_id>.png     the thumbnail
##   <root>/states/<core_name>/<game_stem>/<state_id>.json    frame, times, size
##
## A sidecar per state, not one index per game: deleting a state is deleting its
## three files, a half-written sidecar loses one state rather than the list, and
## the capture path and the RomM sync thread never read-modify-write the same
## file. Listing scans the directory and trusts no index, exactly as
## SramPaths.list_saves does.
##
## `state_id` is `<unix_ms>-<6 hex>`, minted once and never reused. It is the
## row's identity, which is what makes overwrite a pseudo-slot: overwriting
## replaces the three files' CONTENTS, keeps the id, and so keeps the row's link
## to its copy on the server. The random half is not decoration — two consoles in
## the room can run the same game on the same core and write into this folder.
##
## The list sorts by mtime, not by the id, so an overwritten state rises to the
## top showing when it was last written while its id stays put.
class_name StatePaths
extends RefCounted

## Twice the 96×72 box the tab draws, so the picture survives the panel growing.
## PNG rather than JPEG: at this size a losslessly-compressed pixel-art frame is
## no bigger, and JPEG rings around exactly the hard pixel edges these are made of.
const THUMB_MAX_W := 192

## What a capture hands the worker. Every field is a plain value or a
## copy-on-write Godot type, so the task owns it outright.
class Job extends RefCounted:
	var state_path := ""
	var shot_path := ""
	var meta_path := ""
	var data := PackedByteArray()
	var shot: Image = null
	var frame := 0
	var core := ""
	var rom := ""
	var created_at := 0


static func game_stem(rom_path: String) -> String:
	return rom_path.get_file().get_basename()


static func states_root() -> String:
	return CoreDownloadManager.default_core_root().path_join("states")


static func game_dir(core_name: String, rom_path: String) -> String:
	return states_root().path_join(core_name).path_join(game_stem(rom_path))


static func state_path(core_name: String, rom_path: String, state_id: String) -> String:
	return game_dir(core_name, rom_path).path_join(state_id + ".state")


static func shot_path(core_name: String, rom_path: String, state_id: String) -> String:
	return game_dir(core_name, rom_path).path_join(state_id + ".png")


static func meta_path(core_name: String, rom_path: String, state_id: String) -> String:
	return game_dir(core_name, rom_path).path_join(state_id + ".json")


## A fresh identity. Time first so the raw folder sorts sensibly outside the app;
## 24 random bits after it because two machines can capture in the same
## millisecond and the loser would otherwise overwrite the winner.
static func mint_id() -> String:
	return "%d-%06x" % [Time.get_unix_time_from_system() * 1000.0, randi() & 0xFFFFFF]


## Is this one of ours? Guards the directory scan against anything else that
## finds its way into the folder, and the RomM layer against a server filename
## it did not mint.
static func is_state_id(state_id: String) -> bool:
	var parts := state_id.split("-")
	return parts.size() == 2 and parts[0].is_valid_int() and parts[1].is_valid_hex_number()


## Every state for this game, newest-written first. Entries:
##   {state_id, path, shot, meta, mtime, bytes}
##
## Deliberately parses no JSON: this runs on every repopulate of the tab, and
## everything a row shows comes from the scan. The sidecar is read only when a
## state is actually loaded — see read_meta.
static func list_states(core_name: String, rom_path: String) -> Array:
	var out: Array = []
	var dir := game_dir(core_name, rom_path)
	if core_name.is_empty() or not DirAccess.dir_exists_absolute(dir):
		return out
	for fname: String in DirAccess.get_files_at(dir):
		if fname.get_extension().to_lower() != "state":
			continue
		var state_id := fname.get_basename()
		if not is_state_id(state_id):
			continue
		var path := dir.path_join(fname)
		var shot := shot_path(core_name, rom_path, state_id)
		out.append({
			"state_id": state_id,
			"path": path,
			"shot": shot if FileAccess.file_exists(shot) else "",
			"meta": meta_path(core_name, rom_path, state_id),
			"mtime": FileAccess.get_modified_time(path),
			"bytes": NetFileTransfer.size_of(path),
		})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["mtime"]) > int(b["mtime"]))
	return out


## What one state's sidecar says, or {} when it has none. A state written by an
## older build, or one whose sidecar was lost, still loads — the frame falls back
## to 0, which only costs the netplay schedule its head start.
static func read_meta(core_name: String, rom_path: String, state_id: String) -> Dictionary:
	# Silent on a missing or unreadable sidecar (no owner passed): the docstring
	# above says a state without one still loads, so this is an ordinary case
	# rather than something to complain about in the log.
	return JsonStore.read_dict(meta_path(core_name, rom_path, state_id))


## What the whole list costs on disk, for the tab's header. States are not small
## and every one of them uploads, so the growth is worth showing.
static func total_bytes(core_name: String, rom_path: String) -> int:
	var total := 0
	for row: Dictionary in list_states(core_name, rom_path):
		total += int(row["bytes"])
		var shot: String = row["shot"]
		if not shot.is_empty():
			total += NetFileTransfer.size_of(shot)
	return total


## Erase one state — all three of its files. The .state going is what makes it
## gone; a stray sidecar left behind by a failure is invisible to list_states.
static func delete_state(core_name: String, rom_path: String, state_id: String) -> bool:
	if core_name.is_empty() or not is_state_id(state_id):
		return false
	var main := state_path(core_name, rom_path, state_id)
	if not FileAccess.file_exists(main):
		return false
	var ok := DirAccess.remove_absolute(main) == OK
	for extra in [shot_path(core_name, rom_path, state_id),
			meta_path(core_name, rom_path, state_id)]:
		if FileAccess.file_exists(extra):
			DirAccess.remove_absolute(extra)
	return ok


## The core's frame, cut down to a thumbnail. Pure, so it is testable with no GPU
## and safe to run on a worker.
##
## The core draws opaque and never writes the alpha channel — every pixel comes
## back alpha 0 — so a format that keeps alpha saves a fully transparent
## rectangle. Dropping it is both the fix and what the encoder wants.
##
## Downscale only. A 160×144 Game Boy frame stays 160×144; blowing it up to fill
## a box only makes it blurry.
static func thumbnail(src: Image) -> Image:
	var img := src.duplicate() as Image
	if img.get_format() != Image.FORMAT_RGB8:
		img.convert(Image.FORMAT_RGB8)
	if img.get_width() > THUMB_MAX_W:
		var h := maxi(1, int(round(img.get_height() * THUMB_MAX_W / float(img.get_width()))))
		img.resize(THUMB_MAX_W, h, Image.INTERPOLATE_LANCZOS)
	return img


## Write one state's three files. Runs on a WorkerThreadPool task — a 50 MB
## Dolphin state costs 100-300 ms to write on a Quest, which is three seconds of
## frames if it happens on the main thread.
##
## Every write is `.part` then rename, so a state that is interrupted leaves
## nothing list_states will offer. The .state goes last for the same reason: it
## is what makes the row exist, so its picture and its sidecar are already in
## place by the time anything can see it.
##
## Returns "" on success, or a sentence to show the player.
static func write_job(job: Job) -> String:
	if DirAccess.make_dir_recursive_absolute(job.state_path.get_base_dir()) != OK:
		return "cannot create the folder for save states"

	if job.shot != null:
		var thumb := thumbnail(job.shot)
		var buf := thumb.save_png_to_buffer()
		# A missing picture never fails a capture; the row shows a placeholder.
		if not buf.is_empty():
			_write_atomic(job.shot_path, buf)

	var meta := {
		"frame": job.frame,
		"core": job.core,
		"rom": job.rom.get_file(),
		"bytes": job.data.size(),
		"created_at": job.created_at,
		"updated_at": int(Time.get_unix_time_from_system()),
	}
	# An overwrite keeps the row's original birthday rather than restamping it.
	var existing := JsonStore.read_dict(job.meta_path)
	if existing.has("created_at"):
		meta["created_at"] = int(existing["created_at"])
	_write_atomic(job.meta_path, JSON.stringify(meta).to_utf8_buffer())

	if not _write_atomic(job.state_path, job.data):
		return "cannot write the save state to disk"
	return ""



static func _write_atomic(path: String, bytes: PackedByteArray) -> bool:
	var part := path + ".part"
	var f := FileAccess.open(part, FileAccess.WRITE)
	if f == null:
		push_error("[StatePaths] cannot open %s (%d)" % [part, FileAccess.get_open_error()])
		return false
	f.store_buffer(bytes)
	f.close()
	if FileAccess.file_exists(path) and DirAccess.remove_absolute(path) != OK:
		push_error("[StatePaths] cannot replace %s" % path)
		DirAccess.remove_absolute(part)
		return false
	if DirAccess.rename_absolute(part, path) != OK:
		push_error("[StatePaths] cannot promote %s" % part)
		DirAccess.remove_absolute(part)
		return false
	return true
