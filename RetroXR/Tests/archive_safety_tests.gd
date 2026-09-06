## archive_safety_tests — where an archive member is allowed to land.
##
## ArchiveSafety is the boundary two unpackers sit behind: the RomM download path
## and the firmware installer. Both take archives built by somebody else's
## server, so a member name is attacker-controlled input, and joining one to a
## destination directory without checking it is zip-slip — an entry called
## `../../../../something` writes wherever it likes.
##
## It had no test at all, which is a poor combination with "the only thing
## standing between a hostile archive and the player's filesystem". Every case
## here is a shape a real archive can carry: a Windows-built zip using
## backslashes, a drive letter, a leading slash, a UNC path, a name that looks
## harmless segment by segment and simplifies to an escape.
##
##   "$godot" --headless --path RetroXR res://Tests/archive_safety_tests.tscn
extends Node

## Cases in this file, NOT counting the guard below -- it is checked before
## it has recorded itself.
##
## A case that never RAN is not a case that passed. GDScript has no
## try/catch, so one bad index aborts the function it is in and every case
## after it simply never prints, leaving a green run that checked less than
## it claims. card_tests records finding this the hard way; mutation-testing
## cores_data_tests found it again.
const EXPECTED_CASES := 27

var _passed := 0
var _failed := 0

## A single backslash, built rather than escaped: a Windows-built archive uses
## them as separators and a checker that only understands "/" would pass
## `..\..\x` straight through.
var _bs := char(92)


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		push_error("[archsafe] TIMEOUT")
		get_tree().quit(1))

	_group_refused()
	_group_allowed()
	_group_links()

	_eq(_passed + _failed, EXPECTED_CASES, "suite/every case ran")

	print("[archsafe] %d checks, %d failed" % [_passed + _failed, _failed])
	print("[archsafe] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if cond:
		_passed += 1
		print("[archsafe] ok   %s" % what)
	else:
		_failed += 1
		print("[archsafe] FAIL %s%s" % [what, "" if detail.is_empty() else "  -- " + detail])


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what, "got %s, want %s" % [got, want])


## "" is the refusal, so every one of these must come back empty.
func _refused(entry: String, what: String) -> void:
	_ok(ArchiveSafety.safe_member(entry).is_empty(), what,
		"safe_member(%s) returned '%s'" % [entry, ArchiveSafety.safe_member(entry)])


# ── refused/ ──────────────────────────────────────────────────────────────────

func _group_refused() -> void:
	_refused("", "refused/an empty name")
	_refused("..", "refused/a bare parent")
	_refused("../secrets", "refused/a leading parent segment")
	_refused("a/../../secrets", "refused/a parent in the middle that escapes")
	_refused("/etc/passwd", "refused/an absolute path")
	_refused("//server/share/x", "refused/a UNC path")
	_refused("C:/Windows/System32/x", "refused/a drive letter")
	_refused("C:x", "refused/a bare drive-relative name")

	# The Windows half. Note simplify_path() already treats a backslash as a
	# separator, so the first two would be refused even without the fold — they
	# pin the behaviour, not the mechanism.
	_refused(".." + _bs + "secrets", "refused/a backslash parent segment")
	_refused(".." + _bs + ".." + _bs + "secrets", "refused/several of them")
	_refused(_bs + "abs" + _bs + "path", "refused/a leading backslash")

	# THIS one is what the backslash fold is actually for, and it is the case
	# that distinguishes: unfolded, the whole thing is one segment that no ".."
	# test matches, and simplify_path quietly resolves it to plain "b" -- so the
	# member lands at a path the archive never named. Measured both ways.
	_refused("a" + _bs + ".." + _bs + "b",
		"refused/a backslash parent that would otherwise resolve to another file")

	# A NUL would truncate the path at the OS layer, but it cannot arrive as one:
	# Godot decodes an undecodable byte to U+FFFD before GDScript sees it. That
	# character is what is refused, and char(0) IS it -- which is exactly why the
	# old to_utf8_buffer().has(0) test could never fire.
	_refused("good" + char(0) + "bin", "refused/a name mangled by an undecodable byte")
	_refused("sub/bad" + char(0xFFFD) + ".bin", "refused/the replacement character anywhere")

	# Empty and dot segments, which simplify away and can leave an escape behind.
	_refused("./", "refused/a lone dot segment")
	_refused("a//b", "refused/an empty segment")
	_refused("a/./b", "refused/an interior dot segment")


# ── allowed/ ──────────────────────────────────────────────────────────────────

## The rules have to let ordinary archives through: refusing everything would be
## a perfectly safe unpacker that never unpacks anything.
func _group_allowed() -> void:
	_eq(ArchiveSafety.safe_member("bios.bin"), "bios.bin", "allowed/a plain file")
	_eq(ArchiveSafety.safe_member("sub/bios.bin"), "sub/bios.bin", "allowed/a nested file")
	_eq(ArchiveSafety.safe_member("a/b/c/deep.rom"), "a/b/c/deep.rom",
		"allowed/several levels deep")
	# A folder archive built on Windows is an ordinary archive, and its members
	# must land in the same place they would from a zip built anywhere else.
	_eq(ArchiveSafety.safe_member("sub" + _bs + "bios.bin"), "sub/bios.bin",
		"allowed/backslashes are folded to the one separator")
	# A dot inside a name is not a dot SEGMENT.
	_eq(ArchiveSafety.safe_member("v1.2/bios.rom"), "v1.2/bios.rom",
		"allowed/dots inside a segment are fine")
	_eq(ArchiveSafety.safe_member(".hidden/bios.rom"), ".hidden/bios.rom",
		"allowed/a leading-dot directory is not a parent segment")


# ── links/ ────────────────────────────────────────────────────────────────────

## Lexical checks cannot see a symlink: root/link/file is a clean-looking name
## that resolves outside root. parent_is_link is asked before extraction creates
## the descendants.
func _group_links() -> void:
	var root := OS.get_user_data_dir().path_join("__archsafe_selftest")
	DirAccess.make_dir_recursive_absolute(root)
	DirAccess.make_dir_recursive_absolute(root.path_join("plain"))

	_ok(not ArchiveSafety.parent_is_link(root, "plain/file.bin"),
		"links/an ordinary directory is not a link")
	_ok(not ArchiveSafety.parent_is_link(root, "file.bin"),
		"links/a member at the top has no parent to check")
	# A parent that does not exist yet is the ordinary case — extraction is about
	# to create it — and must not be mistaken for a link.
	_ok(not ArchiveSafety.parent_is_link(root, "not/made/yet.bin"),
		"links/a parent that does not exist yet is allowed")
	# A root that cannot be opened is not a licence to proceed blindly, but it is
	# also not a link; the caller's own checks still apply.
	_ok(not ArchiveSafety.parent_is_link(root.path_join("missing"), "a/b.bin"),
		"links/an unopenable root reports no link")

	DirAccess.remove_absolute(root.path_join("plain"))
	DirAccess.remove_absolute(root)
