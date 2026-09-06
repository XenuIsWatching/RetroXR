## BuildInfo — which commit this build came from, and when it was built.
##
## A headset build has no git and no checkout to ask, so the answer is baked
## into res://build_info.json at export time by addons/retroxr_build_stamp.
## Running from the editor there is no stamp, so git is asked live. Both paths
## go through collect_from_git() below, which is what keeps the two answers the
## same shape — and the reason this file is @tool: the export plugin calls that
## collector from the editor. Nothing here runs on its own; it is all static.
@tool
class_name BuildInfo
extends RefCounted

## Exists only inside an exported pack, never in a checkout. Opened rather than
## file_exists()'d — res:// paths are remapped in an export and file_exists lies
## about them.
const STAMP_PATH := "res://build_info.json"

const UNKNOWN := "unknown"

static var _fields: Dictionary = {}


## Everything the plate shows, resolved once: the baked stamp if this is an
## exported build, live git if it is not.
static func fields() -> Dictionary:
	if _fields.is_empty():
		_fields = _read_stamp()
	if _fields.is_empty() and OS.has_feature("editor"):
		_fields = collect_from_git()
	if _fields.is_empty():
		_fields = {"describe": UNKNOWN}
	return _fields


## `git describe` — the nearest tag, the distance past it and the hash, in one
## string. "v0.2.0-83-g56b2372-dirty".
static func describe() -> String:
	return str(fields().get("describe", UNKNOWN))


## The nearest tag alone, or "" in a repository that has none yet.
static func tag() -> String:
	return str(fields().get("tag", ""))


static func commits_since_tag() -> int:
	return int(fields().get("commits_since_tag", 0))


static func commit_hash() -> String:
	return str(fields().get("hash", UNKNOWN))


## The commit's own date, ISO 8601 as git prints it. "" when unknown.
static func commit_date() -> String:
	return str(fields().get("commit_date", ""))


## True when the working tree had uncommitted changes at build time — the one
## thing that makes a hash a lie about what is running.
static func is_dirty() -> bool:
	return bool(fields().get("dirty", false))


## When the export ran, UTC. "" in a build that was never exported.
static func built_at() -> String:
	return str(fields().get("built", ""))


## Platform, architecture, build target and engine as one line. Derived here
## rather than stamped: every part of it is a property of the binary that is
## actually running, which is not always the one that was exported.
static func target_line() -> String:
	return "%s %s · %s · Godot %s" % [
		OS.get_name(),
		Engine.get_architecture_name(),
		"debug" if OS.is_debug_build() else "release",
		str(Engine.get_version_info().get("string", "?")),
	]


## "2026-08-10T11:42:03-04:00" -> "2026-08-10 11:42". Seconds and the UTC offset
## are noise on something read at arm's length.
static func short_date(iso: String) -> String:
	if iso.length() < 16:
		return iso
	return "%s %s" % [iso.substr(0, 10), iso.substr(11, 5)]


## Ask git directly. Editor and export-time only — a shipped build has no
## repository, and pointing this at whatever checkout the player happens to have
## launched from would describe their tree, not ours. {} when git is not there.
static func collect_from_git() -> Dictionary:
	var root := ProjectSettings.globalize_path("res://")
	var described := _git(root, ["describe", "--tags", "--always", "--dirty"])
	if described.is_empty():
		return {}

	# One call for both, because two processes cost more than the newline does.
	var head := _git(root, ["log", "-1", "--format=%h%n%cI"]).split("\n")
	# Asked for rather than parsed back out of `described`: a tag may itself
	# contain the -<n>-g<hash> shape, and git is the authority on where it ends.
	var nearest := _git(root, ["describe", "--tags", "--abbrev=0"])
	var since := ""
	if not nearest.is_empty():
		since = _git(root, ["rev-list", "--count", "%s..HEAD" % nearest])

	return {
		"describe":          described,
		"tag":               nearest,
		"commits_since_tag": int(since) if since.is_valid_int() else 0,
		"hash":              head[0] if head.size() > 0 else UNKNOWN,
		"commit_date":       head[1] if head.size() > 1 else "",
		"dirty":             described.ends_with("-dirty"),
	}


static func _git(root: String, args: Array) -> String:
	var argv := PackedStringArray(["-C", root])
	argv.append_array(PackedStringArray(args))
	var out: Array = []
	if OS.execute("git", argv, out, false) != 0:
		return ""
	return str(out[0]).strip_edges() if out.size() > 0 else ""


## The one JSON read in this project that must NOT go through JsonStore.
##
## read_dict opens with `FileAccess.file_exists(path)`, and STAMP_PATH is a
## res:// path — which an export REMAPS into the pack, so file_exists answers
## false for a file that is there and opens fine. The gate would make the whole
## plate read "unknown" on device and nowhere else, which is the one place it
## is supposed to work: in a checkout there is no stamp at all and
## collect_from_git() answers instead.
##
## The constant's own comment says this fifteen lines up. It was migrated to the
## shared reader anyway, and this is the note that should have stopped it.
##
## Silent on a missing stamp for that same reason: running from the editor,
## absent is the ordinary case.
static func _read_stamp() -> Dictionary:
	var file := FileAccess.open(STAMP_PATH, FileAccess.READ)
	if file == null:
		return {}
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}
