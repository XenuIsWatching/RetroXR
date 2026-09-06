## firmware_digest_tests — the BIOS-match gate that decides whether two peers
## may share a netplay session.
##
## FirmwareDigest is pure, static, and had no test reference at all, which is a
## poor combination for something whose disagreement REFUSES a session. Every
## function here needs no server, no core and no files on disk: the digest is
## computed from a dictionary the caller supplies.
##
## The invariant that matters most is order independence. Two peers build their
## rows by walking a firmware directory, and two filesystems will not list the
## same directory in the same order — so a digest that depended on insertion
## order would refuse sessions between identical installs, intermittently, with
## the message telling the player their BIOS does not match when it does.
##
##   "$godot" --headless --path RetroXR res://Tests/firmware_digest_tests.tscn
extends Node

## Cases in this file, NOT counting the guard below -- it is checked before
## it has recorded itself.
##
## A case that never RAN is not a case that passed. GDScript has no
## try/catch, so one bad index aborts the function it is in and every case
## after it simply never prints, leaving a green run that checked less than
## it claims. card_tests records finding this the hard way; mutation-testing
## cores_data_tests found it again.
const EXPECTED_CASES := 14

var _passed := 0
var _failed := 0


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		push_error("[fwdigest] TIMEOUT")
		get_tree().quit(1))

	_group_digest()
	_group_message()

	_eq(_passed + _failed, EXPECTED_CASES, "suite/every case ran")

	print("[fwdigest] %d checks, %d failed" % [_passed + _failed, _failed])
	print("[fwdigest] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if cond:
		_passed += 1
		print("[fwdigest] ok   %s" % what)
	else:
		_failed += 1
		print("[fwdigest] FAIL %s%s" % [what, "" if detail.is_empty() else "  -- " + detail])


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what, "got %s, want %s" % [got, want])


# ── digest/ ───────────────────────────────────────────────────────────────────

func _group_digest() -> void:
	var a := {"bios.bin": "aaa", "sub/other.bin": "bbb", "third.rom": "ccc"}
	# The same set, inserted in a different order — which is exactly what two
	# machines walking the same directory produce.
	var b := {"third.rom": "ccc", "bios.bin": "aaa", "sub/other.bin": "bbb"}
	_eq(FirmwareDigest.of(a), FirmwareDigest.of(b),
		"digest/insertion order does not change the digest")

	_ok(not FirmwareDigest.of(a).is_empty(), "digest/a populated set hashes to something")
	_eq(FirmwareDigest.of(a).length(), 64, "digest/it is a sha256 in hex")

	# A changed hash must change the digest, or a mismatched BIOS passes the gate.
	var changed := a.duplicate()
	changed["bios.bin"] = "different"
	_ok(FirmwareDigest.of(changed) != FirmwareDigest.of(a),
		"digest/a changed file hash changes the digest")

	# A missing file must change it too. The peer with fewer files is not a match.
	var fewer := a.duplicate()
	fewer.erase("third.rom")
	_ok(FirmwareDigest.of(fewer) != FirmwareDigest.of(a),
		"digest/a missing file changes the digest")

	# A renamed file with the same content is a different requirement.
	var renamed := {"bios.bin": "aaa", "sub/other.bin": "bbb", "renamed.rom": "ccc"}
	_ok(FirmwareDigest.of(renamed) != FirmwareDigest.of(a),
		"digest/the path is part of the digest, not only the content")

	# Empty is stable and equal to itself, so two peers with no firmware agree.
	_eq(FirmwareDigest.of({}), FirmwareDigest.of({}),
		"digest/two empty sets agree")
	_ok(FirmwareDigest.of({}) != FirmwareDigest.of(a),
		"digest/an empty set does not match a populated one")

	# The separator must not be forgeable: one file whose name contains the
	# joining characters must not collide with two files.
	var tricky := {"a=1\nb": "2"}
	var plain := {"a": "1", "b": "2"}
	_ok(FirmwareDigest.of(tricky) != FirmwareDigest.of(plain),
		"digest/a name carrying the separator does not collide with two rows")


# ── message/ ──────────────────────────────────────────────────────────────────

## The text a refused player actually reads. It is the only explanation they get
## for a session that will not start, so each state has to name the file.
func _group_message() -> void:
	var empty := FirmwareDigest.failure_text("mgba", [])
	_ok(empty.contains("mgba"), "message/names the core when there is no detail")

	var missing := FirmwareDigest.failure_text("mgba",
		[{"file": "gba_bios.bin", "state": "missing"}])
	_ok(missing.contains("gba_bios.bin") and missing.contains("missing"),
		"message/a missing file is named and called missing", missing)

	var extra := FirmwareDigest.failure_text("mgba",
		[{"file": "spare.bin", "state": "extra"}])
	_ok(extra.contains("spare.bin") and extra.contains("not on the host"),
		"message/an extra file says the host does not have it", extra)

	var differs := FirmwareDigest.failure_text("mgba",
		[{"file": "gba_bios.bin", "state": "checksum"}])
	_ok(differs.contains("gba_bios.bin") and differs.contains("differs"),
		"message/any other state reads as differing", differs)

	var many := FirmwareDigest.failure_text("mgba", [
		{"file": "one.bin", "state": "missing"},
		{"file": "two.bin", "state": "extra"},
	])
	_ok(many.contains("one.bin") and many.contains("two.bin"),
		"message/every file in the diff is named", many)
