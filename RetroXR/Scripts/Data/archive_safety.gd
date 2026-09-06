## ArchiveSafety — where an archive member is allowed to land.
##
## An archive's member names come from whoever built the archive, which for this
## project means a RomM server rather than the player. Joining one to a
## destination directory without checking it is the zip-slip bug: an entry named
## `../../../../something` walks out of the folder the caller meant to fill and
## writes wherever it likes.
##
## The rules were already written once, correctly, for the RomM download path.
## They live here now because the firmware installer unpacks archives from the
## same server and had NONE of them — it joined the raw entry name straight onto
## the destination. Two unpackers, one set of rules.
class_name ArchiveSafety
extends RefCounted


## The member's path relative to the destination, or "" if it may not be used.
##
## Refuses, in order: an empty name or one carrying a NUL; an absolute path, a
## UNC path, or anything with a drive colon; any segment that is empty, "." or
## ".."; and finally re-checks the simplified path, because a name can look
## harmless segment by segment and still simplify to an escape.
##
## Backslashes are folded to forward slashes first: a Windows-built archive uses
## them, and a check that only understood "/" would pass `..\..\x` untouched.
## The replacement character. A NUL byte in an entry name would truncate the
## path at the OS layer, so that what is checked and what is opened differ — but
## a NUL can never reach this function as one. Godot decodes an undecodable byte
## into U+FFFD before GDScript sees the string, which is why the check this
## replaces (`to_utf8_buffer().has(0)`) could never fire: measured, that buffer
## comes back EF BF BD and contains no zero at all.
##
## So the thing to refuse is the replacement character itself. It is what a NUL
## becomes, and equally what any other byte the archive's encoding could not
## decode becomes — a name we cannot reproduce faithfully is a name we should
## not be writing to disk.
const MANGLED := 0xFFFD


static func safe_member(entry_name: String) -> String:
	if entry_name.is_empty() or entry_name.contains(char(MANGLED)):
		return ""
	var normalized := entry_name.replace("\\", "/")
	if normalized.is_absolute_path() or normalized.begins_with("/") \
			or normalized.begins_with("//") or normalized.contains(":"):
		return ""
	var parts := normalized.split("/", true)
	for part: String in parts:
		if part.is_empty() or part == "." or part == "..":
			return ""
	var relative := normalized.simplify_path()
	if relative.is_empty() or relative == "." or relative == ".." \
			or relative.begins_with("../"):
		return ""
	return relative


## Existing directory symlinks defeat lexical prefix checks: root/link/file can
## resolve outside root however clean the member name looks. Check each parent
## before extraction creates descendants.
static func parent_is_link(root: String, relative: String) -> bool:
	var dir := DirAccess.open(root)
	if dir == null:
		return false
	var parts := relative.split("/", false)
	var parent := ""
	for i in range(parts.size() - 1):
		parent = parts[i] if parent.is_empty() else parent.path_join(parts[i])
		if dir.is_link(parent):
			return true
		if not DirAccess.dir_exists_absolute(root.path_join(parent)):
			break
	return false
