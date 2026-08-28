## Core-identity probe — the two moments GetCoreIdentity has to survive.
##
##   "$godot" --headless --path RetroXR res://Tools/netplay/core_identity_probe.tscn -- \
##       --ident-core=fceumm "--ident-rom=C:/path/to/rom.nes"
##
## A probe, not a test: it needs a real core and real content, so it cannot live
## in Tests/. It asserts and exits non-zero, so it can still gate a change to
## the identity code by hand.
##
## Two runs against one core, and the point is that they pull in OPPOSITE
## directions — a naive implementation can pass either one alone.
##
## GATED starts the core the way a netplay cold start does: SetNetplayMode at
## frame 0, and nothing posted, because nothing MAY be posted until every peer
## reports ready and readiness is this dictionary being non-empty. So the
## identity has to arrive with ZERO frames run. Publishing it after the first
## retro_run deadlocks here, and the symptom is every netplay session failing
## its 10 s deadline with "core did not come up".
##
## UNGATED is a normal boot, and exists to prove the savestate size is really
## measured rather than left at 0 for ever.
##
## And the size must NOT be measured at load, which is what makes the two halves
## land at different moments: Dolphin answers retro_serialize_size by
## marshalling onto its CPU thread and walking every subsystem, so asking before
## it has run segfaults the process on a machine that does not exist yet. Run
## this against dolphin, not just a quick NES core — fceumm alone cannot fail
## that half.
##
## **Give Dolphin one leg per process.** Both legs in one run means a restart,
## and Dolphin is one of the cores that will not unwind (see ShutdownForExit);
## the abandoned thread segfaults the process on the way out and it reads
## exactly like an identity crash. Two runs, `--ident-leg=gated` then
## `--ident-leg=ungated`, and both must print RESULT=PASS:
##
##   ... res://Tools/netplay/core_identity_probe.tscn -- --ident-core=dolphin \
##       --ident-leg=gated "--ident-rom=.../Wind Waker.rvz"
extends Node

static var _home := OS.get_environment("HOME") if OS.get_name() == "Linux" \
		else OS.get_environment("USERPROFILE").replace("\\", "/")

var root_dir := _home + "/retroxr/libretro"
var core := "fceumm"
var rom := _home + "/retroxr/roms/nes/probe.nes"

var _lib: Node = null
var _gated := true
var _ticks := 0
var _saw_identity := false
var _fail := 0
var _done := false
## _next() awaits, and _process keeps being called across the await. Without
## this the probe re-enters it and restarts the core underneath itself, which on
## Dolphin is several overlapping StartContent calls and a segfault that looks
## exactly like the bug being probed for.
var _switching := false
## "both" (default), "gated" or "ungated".
var _leg := "both"


func _ready() -> void:
	for arg: String in OS.get_cmdline_user_args():
		arg = arg.strip_edges()
		if arg.begins_with("--ident-core="):
			core = arg.trim_prefix("--ident-core=")
		elif arg.begins_with("--ident-rom="):
			rom = arg.trim_prefix("--ident-rom=")
		elif arg.begins_with("--ident-root="):
			root_dir = arg.trim_prefix("--ident-root=")
		elif arg.begins_with("--ident-leg="):
			# One leg per process. Some cores cannot be restarted in-process at
			# all — Dolphin abandons a thread that will not unwind — so running
			# both legs back to back can segfault for reasons that have nothing
			# to do with the identity. Two runs, one leg each, keeps a red
			# result meaningful.
			_leg = arg.trim_prefix("--ident-leg=")
	get_tree().create_timer(120.0).timeout.connect(func() -> void:
		print("[ident] FAIL %s gated=%s: identity never arrived (%d ticks)"
			% [core, _gated, _ticks])
		get_tree().quit(1))
	var obj: Object = ClassDB.instantiate("Libretro")
	_lib = obj as Node
	add_child(_lib)
	if not _lib.has_method("GetCoreIdentity"):
		print("[ident] FAIL the extension has no GetCoreIdentity; rebuild it")
		get_tree().quit(1)
		return
	_start(_leg != "ungated")


func _start(gated: bool) -> void:
	_gated = gated
	_ticks = 0
	_saw_identity = false
	if gated:
		_lib.SetNetplayMode(true, 0x1, 0)
	_lib.StartContent(root_dir, core, rom)
	print("[ident] %s %s (%s)" % [core, rom.get_file(), "GATED" if gated else "ungated"])


func _process(_d: float) -> void:
	if _lib == null or _done or _switching:
		return
	_ticks += 1
	var ident: Dictionary = _lib.GetCoreIdentity()
	if ident.is_empty():
		return
	var frames: int = _lib.GetFrameCount()
	var size := int(ident.get("serialize_size", -1))

	if not _saw_identity:
		_saw_identity = true
		print("[ident] %s %s: identity at tick %d, frames run=%d, %s %s, size=%d"
			% [core, "gated" if _gated else "ungated", _ticks, frames,
				str(ident.get("library_name", "?")), str(ident.get("library_version", "?")),
				size])
		if str(ident.get("library_name", "")).is_empty():
			_bad("the core reported no library_name")
		if int(ident.get("api_version", 0)) <= 0:
			_bad("the core reported no api_version")
		if _gated:
			# The whole gated case: a netplay peer answers ready HERE, and the
			# gate has not let a single frame through.
			if frames != 0:
				_bad("gated: %d frames ran before the identity appeared" % frames)
			if size != 0:
				_bad("gated: the savestate size was measured before any frame ran")
			# Let it run now, so the size half can be checked too.
			_lib.SetNetplayMode(false, 0x1, 0)
		return

	if size > 0:
		print("[ident] %s %s: size %d measured at frame %d"
			% [core, "gated" if _gated else "ungated", size, frames])
		if frames < 1:
			_bad("the size was measured without a frame having run")
		_next()
	elif frames > 120:
		_bad("%d frames ran and the savestate size is still unmeasured" % frames)
		_next()


func _next() -> void:
	_switching = true
	_lib.StopContent()
	await get_tree().create_timer(3.0).timeout
	if not _lib.GetCoreIdentity().is_empty():
		_bad("the identity outlived the content run")
	if _gated and _leg == "both":
		await get_tree().create_timer(0.5).timeout
		_start(false)
		_switching = false
		return
	_done = true
	print("[ident] RESULT=%s" % ("FAIL" if _fail > 0 else "PASS"))
	get_tree().quit(1 if _fail > 0 else 0)


func _bad(why: String) -> void:
	_fail += 1
	print("[ident] FAIL %s: %s" % [core, why])
