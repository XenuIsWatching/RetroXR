## cores_data_tests — the pure-logic half of the core layer.
##
## Four classes that decide what a core IS and what it must be told, none of
## which had a test: CoreInfoParser (reading a libretro .info), CoreSources (the
## cores this project builds itself rather than taking from the buildbot),
## ForcedCoreOptions (the options that make hardware that hardware) and
## DownloadManifest (what is installed and how old it is).
##
## None of it needs a core, a ROM or the network. The parser is given files this
## suite writes; the rest are tables and rules.
##
## ForcedCoreOptions is the part worth having covered. Every answer in it was
## MEASURED against a real core and the reasons are written out beside each one
## — a 64DD with its drive switched off has nothing to load a disk into, an N64
## whose core defaults to "Expansion Pak installed" has 8 MB whether or not a
## player placed the pack. A wrong answer here is a machine that boots to a
## black screen, which is exactly the failure that reads as "the emulator is
## broken" rather than as a setting.
##
##   "$godot" --headless --path RetroXR res://Tests/cores_data_tests.tscn
extends Node

## Cases in this file, NOT counting the guard below -- it is checked before
## it has recorded itself.
const EXPECTED_CASES := 41

var _passed := 0
var _failed := 0

var _dir := ""


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		push_error("[cores] TIMEOUT")
		get_tree().quit(1))

	_dir = OS.get_user_data_dir().path_join("__cores_selftest")
	DirAccess.make_dir_recursive_absolute(_dir)

	_group_parser()
	_group_sources()
	_group_forced()
	_group_manifest()

	# A case that never RAN is not a case that passed. GDScript has no
	# try/catch, so one bad index aborts the function it is in and every case
	# after it simply never prints -- mutation-testing this suite is how that was
	# found here, exactly as card_tests records finding it. Bump when adding.
	_eq(_passed + _failed, EXPECTED_CASES, "suite/every case ran")

	_cleanup()
	print("[cores] %d checks, %d failed" % [_passed + _failed, _failed])
	print("[cores] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _cleanup() -> void:
	var d := DirAccess.open(_dir)
	if d == null:
		return
	d.list_dir_begin()
	var n := d.get_next()
	while not n.is_empty():
		if not d.current_is_dir():
			DirAccess.remove_absolute(_dir.path_join(n))
		n = d.get_next()
	d.list_dir_end()
	DirAccess.remove_absolute(_dir)


func _ok(cond: bool, what: String, detail := "") -> void:
	if cond:
		_passed += 1
		print("[cores] ok   %s" % what)
	else:
		_failed += 1
		print("[cores] FAIL %s%s" % [what, "" if detail.is_empty() else "  -- " + detail])


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what, "got %s, want %s" % [got, want])


func _write(name: String, text: String) -> String:
	var path := _dir.path_join(name)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()
	return path


# ── parser/ ───────────────────────────────────────────────────────────────────

func _group_parser() -> void:
	var path := _write("fceumm_libretro.info",
		"# a comment\n"
		+ "display_name = \"Nintendo - NES\"\n"
		+ "\n"
		+ "supported_extensions = \"nes|fds|unf\"\n"
		+ "categories = Emulator\n"
		+ "  spaced_key   =   \"trimmed\"  \n"
		+ "novalue\n"
		+ "= orphan\n"
		+ "url = \"http://example.com/a=b\"\n")
	var info := CoreInfoParser.parse_info_file(path)

	# The core name is the FILENAME's, not a field: it is what matches the
	# library on disk (fceumm_libretro.dll), so it cannot come from the content.
	_eq(info.get("core_name", "<none>"), "fceumm", "parser/the core name comes off the filename")
	_eq(info.get("info_path", "<none>"), path, "parser/the path is carried through")

	_eq(info.get("display_name", "<none>"), "Nintendo - NES", "parser/a quoted value is unquoted")
	_eq(info.get("categories", "<none>"), "Emulator", "parser/an unquoted value is taken as-is")
	_eq(info.get("spaced_key", "<none>"), "trimmed", "parser/keys and values are trimmed")
	_ok(not info.has("#"), "parser/a comment line is skipped")
	_ok(not info.has("novalue"), "parser/a line with no = is skipped")
	# Split on the FIRST = only, or a URL with a query string loses its tail.
	_eq(info.get("url", "<none>"), "http://example.com/a=b", "parser/only the first = splits")
	_ok(not info.has(""), "parser/a line starting with = contributes no empty key")

	# "notes" is the one multi-line key, and its own separator is "|" — joining
	# rather than last-wins is what keeps a firmware checksum table whole.
	var notes := CoreInfoParser.parse_info_file(_write("bk_libretro.info",
		"notes = \"first\"\nnotes = \"second\"\nother = \"a\"\nother = \"b\"\n"))
	_eq(notes.get("notes", "<none>"), "first|second", "parser/notes lines are joined, not replaced")
	_eq(notes.get("other", "<none>"), "b", "parser/every other key is last-wins")

	# A file that is not there is not a crash, and still reports what it can.
	var missing := CoreInfoParser.parse_info_file(_dir.path_join("nope_libretro.info"))
	_eq(missing.get("core_name", "<none>"), "nope", "parser/a missing file still names its core")


# ── sources/ ──────────────────────────────────────────────────────────────────

## The cores this project builds itself. Every accessor must answer "" for a core
## that is not in the table, because the download manager decides between our
## release and the buildbot by asking exactly that.
func _group_sources() -> void:
	_ok(not CoreSources.has("fceumm"),
		"sources/an ordinary buildbot core is not ours")
	_eq(CoreSources.base_url("fceumm"), "", "sources/and has no release URL")
	_eq(CoreSources.api_url("fceumm"), "", "sources/nor an API URL")
	_eq(CoreSources.asset_for("fceumm"), "", "sources/nor an asset")
	_eq(CoreSources.version_of("fceumm"), "", "sources/nor a known tag")

	# dolphin is one of ours on every desktop platform.
	_ok(CoreSources.base_url("dolphin").begins_with("https://github.com/"),
		"sources/one of ours hangs off a GitHub release")
	# The /releases/latest/ form, never a tagged one: a tag here would mean every
	# core build needed a new app build to point at it.
	_ok(CoreSources.base_url("dolphin").ends_with("/releases/latest/download/"),
		"sources/the download URL is the latest form, not a tag")
	_ok(CoreSources.api_url("dolphin").begins_with("https://api.github.com/repos/"),
		"sources/and the API URL asks GitHub what latest is")
	# Both URLs must name the same repository, or the app would download one
	# build and report another's version.
	var repo := CoreSources.base_url("dolphin").trim_prefix("https://github.com/") \
		.trim_suffix("/releases/latest/download/")
	_ok(CoreSources.api_url("dolphin").contains(repo),
		"sources/the two URLs name the same repository", repo)

	# active_core_names is what the version probe walks, so it must list only
	# cores we actually build for THIS platform. Asserted as one case rather than
	# one per core: the list is platform-dependent, and a per-core case would
	# make this suite's own total differ between Windows and the Linux CI runner.
	var not_built := PackedStringArray()
	for name: String in CoreSources.active_core_names():
		if not CoreSources.has(name):
			not_built.append(name)
	_ok(not_built.is_empty(), "sources/every active core is built for this platform",
		", ".join(not_built))


# ── forced/ ───────────────────────────────────────────────────────────────────

## Options that are not preferences. Each was measured against the core.
func _group_forced() -> void:
	# The 64DD reaches a machine two ways and the systemid says only one of them:
	# a disk from the library makes a nintendo_64dd machine, while bolting the
	# drive under a console leaves it a nintendo_64 with an expansion. Asking
	# only about the systemid left the assembled machine's drive switched off.
	var by_system := ForcedCoreOptions.disk_drive("parallel_n64", "nintendo_64dd", [], "")
	_eq(by_system.get("parallel-n64-64dd-hardware"), "enabled",
		"forced/a 64DD machine switches the drive on")
	var by_expansion := ForcedCoreOptions.disk_drive(
		"parallel_n64", "nintendo_64", ["nintendo_64dd"], "")
	_eq(by_expansion.get("parallel-n64-64dd-hardware"), "enabled",
		"forced/and so does a console with the drive bolted under it")
	_eq(ForcedCoreOptions.disk_drive("parallel_n64", "nintendo_64", [], ""), {},
		"forced/a plain N64 is left alone")

	# The Expansion Pak is pinned in BOTH directions: the core's own default is
	# "installed", so leaving it alone gives 8 MB to a machine with no pack in it.
	var with_pak := ForcedCoreOptions.expansion_pak("mupen64plus_next", ["expansion_pak"])
	var without := ForcedCoreOptions.expansion_pak("mupen64plus_next", [])
	_eq(with_pak.get("mupen64plus-ForceDisableExtraMem"), "False",
		"forced/a placed Expansion Pak is not disabled")
	_eq(without.get("mupen64plus-ForceDisableExtraMem"), "True",
		"forced/and an absent one is, rather than left at the core's default")
	# The other N64 core's key is named the opposite of what it means, which is
	# the trap: parallel-n64-disable_expmem describes itself as "Enable Expansion
	# Pak RAM", so "enabled" names the RAM and not the disabling. Measured, not
	# read off the key. Asserted here in the direction the core actually takes.
	_eq(ForcedCoreOptions.expansion_pak("parallel_n64", ["expansion_pak"])
			.get("parallel-n64-disable_expmem"), "enabled",
		"forced/the other N64 core's key is named the opposite of what it means")
	_eq(ForcedCoreOptions.expansion_pak("parallel_n64", [])
			.get("parallel-n64-disable_expmem"), "disabled",
		"forced/and a bare console is pushed off its default there too")
	_eq(ForcedCoreOptions.expansion_pak("fceumm", ["expansion_pak"]), {},
		"forced/a core with no such option gets nothing")

	# The FM Sound Unit is gated on the SYSTEM as well, unlike the Pak: the same
	# core runs the Mega Drive, Game Gear and SG-1000, and without the gate every
	# one of those would be pinned "disabled" for a chip they never had.
	_eq(ForcedCoreOptions.fm_sound_unit("genesis_plus_gx", "master_system",
			["fm_sound_unit"]).get("genesis_plus_gx_ym2413"), "enabled",
		"forced/a Master System with the unit enables the YM2413")
	_eq(ForcedCoreOptions.fm_sound_unit("genesis_plus_gx", "master_system", [])
			.get("genesis_plus_gx_ym2413"), "disabled",
		"forced/without it the chip is pinned off, not left on auto")
	_eq(ForcedCoreOptions.fm_sound_unit("genesis_plus_gx", "mega_drive",
			["fm_sound_unit"]), {},
		"forced/a Mega Drive on the same core is untouched")


# ── manifest/ ─────────────────────────────────────────────────────────────────

## What is installed and how old it is. The manager offers an update by testing
## the stored stamp for INEQUALITY, so what matters is that it round-trips.
func _group_manifest() -> void:
	var m := DownloadManifest.new()
	m.setup(_dir)

	_ok(not m.is_downloaded("fceumm"), "manifest/an unknown core is not installed")
	_eq(m.get_remote_date("fceumm"), "", "manifest/and has no stamp")

	m.set_downloaded("fceumm", "2026-03-06", "fceumm_libretro.dll")
	_ok(m.is_downloaded("fceumm"), "manifest/a recorded core reads as installed")
	_eq(m.get_remote_date("fceumm"), "2026-03-06", "manifest/with its stamp")

	# A second manifest over the same directory must see it: the whole point of
	# the file is that it survives the app closing.
	var reopened := DownloadManifest.new()
	reopened.setup(_dir)
	_eq(reopened.get_remote_date("fceumm"), "2026-03-06",
		"manifest/and it survives being reopened")

	m.set_downloaded("fceumm", "2026-04-01", "fceumm_libretro.dll")
	_eq(m.get_remote_date("fceumm"), "2026-04-01", "manifest/re-recording replaces the stamp")
	m.remove("fceumm")
	_ok(not m.is_downloaded("fceumm"), "manifest/removing forgets the core")
	_eq(m.get_remote_date("fceumm"), "", "manifest/and its stamp with it")
