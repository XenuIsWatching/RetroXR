## FirmwareDigest — is every peer running the same BIOS?
##
## Netplay compares firmware by digest rather than by shipping it: BIOS dumps are
## not ours to transfer, so each peer hashes what it has and the session refuses
## a mismatch instead of fixing one. Every path a core declares is hashed,
## directories walked in full, and a file that is simply absent is recorded as
## "<missing>" rather than skipped — otherwise a peer missing a BIOS and a peer
## with a different one would produce the same digest as a peer with neither.
##
## Lifted out of RetroSystem, which had grown netplay's vocabulary alongside
## seven others. These functions read no machine state at all — they take a core
## name and answer from FirmwareRequirements and the files on disk — so they
## needed nothing passing in and gained nothing from living on a node.
class_name FirmwareDigest
extends RefCounted


## One line per file, sorted, hashed. Sorted because two peers must agree on the
## digest of the same set regardless of the order their filesystems listed it —
## two filesystems will not walk a directory in the same order, and a digest
## that depended on that would refuse sessions between identical installs.
##
## Each name is LENGTH-PREFIXED, which is not decoration. With a plain
## "name=hash" joined by newlines, one file whose name happens to contain an
## equals sign and a newline encodes byte-for-byte the same as two ordinary
## files — so a filename could forge the digest of a different firmware set,
## and the check that exists to prove two peers hold the same BIOS would pass
## on two that do not. The prefix makes the encoding unambiguous.
##
## Changing this changes the digest, so peers must run the same build to agree.
## They already must: the core identity check beside this one compares build
## strings, and a cross-build pair fails there first.
static func of(rows: Dictionary) -> String:
	var lines: Array[String] = []
	for relative: String in rows:
		lines.append("%d:%s=%s" % [relative.length(), relative, str(rows[relative])])
	lines.sort()
	return "\n".join(PackedStringArray(lines)).sha256_text()


## relative path -> content hash, for everything this core's firmware declares.
static func rows(core: String) -> Dictionary:
	var out: Dictionary = {}
	for requirement: Dictionary in FirmwareRequirements.for_core(core):
		var relative := str(requirement.get("path", ""))
		if relative.is_empty():
			continue
		var dest := FirmwareRequirements.destination(core, relative)
		if DirAccess.dir_exists_absolute(dest):
			_append_dir(dest, relative, out)
		elif FileAccess.file_exists(dest):
			out[relative] = NetFileTransfer.hash_of(dest)
		else:
			out[relative] = "<missing>"
	return out


## The digest of this core's firmware as it stands on this machine.
static func signature(core: String) -> String:
	return of(rows(core))


## Stamp a boot spec with both the digest and the rows behind it — the rows are
## what lets a refusal say WHICH file differs rather than only that one does.
## A core with no firmware requirement is left unstamped.
static func stamp(spec: Dictionary, core: String) -> void:
	if FirmwareRequirements.for_core(core).is_empty():
		return
	var listing := rows(core)
	spec["firmware"] = of(listing)
	spec["firmware_rows"] = listing


## What to tell the player when the digests disagree.
static func failure_text(core: String, diff: Array) -> String:
	if diff.is_empty():
		return "your BIOS for %s does not match the host's" % core
	var parts: Array[String] = []
	for d: Dictionary in diff:
		var file := str(d.get("file", "?"))
		match str(d.get("state", "")):
			"missing":
				parts.append("%s is missing" % file)
			"extra":
				parts.append("%s is not on the host" % file)
			_:
				parts.append("%s differs" % file)
	return "your BIOS for %s does not match the host's: %s" % [core, ", ".join(parts)]


## Walk a firmware directory, hashing every file under it. Recursive because a
## core may declare a directory whose contents are the requirement.
static func _append_dir(root: String, relative: String, out: Dictionary) -> void:
	var dir := DirAccess.open(root)
	if dir == null:
		out[relative] = "<missing>"
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while not name.is_empty():
		var full := root.path_join(name)
		var child := relative.path_join(name)
		if dir.current_is_dir():
			_append_dir(full, child, out)
		else:
			out[child] = NetFileTransfer.hash_of(full)
		name = dir.get_next()
	dir.list_dir_end()
