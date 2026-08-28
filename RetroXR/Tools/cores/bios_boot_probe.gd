## BIOS-boot survey probe: can this core start with NOTHING in the machine, and
## what does it call the option that plays a boot ROM?
##
## Answers the two questions the BiosBoot table cannot be written without, and
## which no static data can answer. Every core in the target list declares
## `supports_no_game = "false"` in its .info -- including pcsx_rearmed and mgba,
## which boot to a BIOS perfectly well -- so the flag is measured here by
## actually starting the core with an empty path and watching the frame counter.
##
## ONE CORE PER PROCESS, always. Handing a core a null retro_game_info runs code
## paths its author may never have exercised, and the extension is built
## -fno-exceptions with no sandbox around the core: a bad one takes the whole
## process down. Tools/bios_boot_survey.ps1 launches Godot once per core so a
## casualty is one row of the table and not the whole run. Never loop cores here.
##
## Windowed, not --headless: the dummy renderer gives a HW-render core (flycast,
## dolphin) nowhere to draw, and "no picture" would then say nothing about the
## core. Frame count is the primary oracle regardless; the picture corroborates.
##
##   godot --path RetroXR --resolution 320x240 --position 20,20
##       res://Tools/cores/bios_boot_probe.tscn -- --core=pcsx_rearmed --systemid=playstation
##
## Prints one machine-parsable line per run for the survey to collect:
##   [biosprobe] RESULT core=<name> systemid=<id> no_content=<yes|no> frames=<n> lit=<f>
extends Node3D

## Option keys worth showing. A core names its boot-ROM switch whatever it likes
## -- mgba_use_bios, dolphin_skip_gc_bios, reicast_hle_bios, gambatte_gb_bootloader
## -- so the survey prints anything that smells like one and a human picks.
const OPTION_HINTS := ["bios", "boot", "ipl", "hle", "syscard", "firmware", "splash"]

## Long enough for a BIOS to get past its own black lead-in. A Dreamcast or PS1
## BIOS spends its first seconds dark, so an early-only sample cannot tell
## "still starting" from "never draws".
const SAMPLE_AT := [3.0, 6.0, 10.0, 15.0]

var core := ""
var systemid := ""
var root_dir := ""
## An empty disc image to hand the core INSTEAD of no content. A CD machine with
## a disc it cannot read is a machine with no game in it, which on real hardware
## is the state that shows the BIOS menu -- and it is how players actually reach
## the PS1 and Saturn BIOS in RetroArch. Measured separately because it is a
## different mechanism from a no-content start, not a variation on one.
var rom := ""
## Which no-content convention to hand retro_load_game. Neither is safe
## everywhere -- mgba segfaults on a null pointer where it survives a zeroed
## struct -- so the survey runs BOTH per core and the table records the winner.
var pass_null := true
## Where to save the last sampled frame. A lit frame is not proof of a BIOS --
## a solid error screen is lit too -- so a row only goes in the table once
## somebody has LOOKED at what the core actually drew.
var shot := ""

var _lib: Node = null
var _frames_best := 0
var _lit_best := 0.0
var _load_failed := ""


func _ready() -> void:
	for arg in OS.get_cmdline_user_args():
		var a := String(arg).strip_edges()
		if a.begins_with("--core="):
			core = a.trim_prefix("--core=")
		elif a.begins_with("--systemid="):
			systemid = a.trim_prefix("--systemid=")
		elif a.begins_with("--root="):
			root_dir = a.trim_prefix("--root=")
		elif a.begins_with("--nullinfo="):
			pass_null = a.trim_prefix("--nullinfo=") != "0"
		elif a.begins_with("--rom="):
			rom = a.trim_prefix("--rom=")
		elif a.begins_with("--shot="):
			shot = a.trim_prefix("--shot=")
	if root_dir.is_empty():
		root_dir = CoreDownloadManager.default_core_root()

	# A core that hangs rather than refusing must not hold the survey open.
	get_tree().create_timer(SAMPLE_AT[-1] + 30.0).timeout.connect(func() -> void:
		print("[biosprobe] TIMEOUT")
		print("[biosprobe] RESULT core=%s systemid=%s nullinfo=%d no_content=hang frames=%d lit=%.4f"
			% [core, systemid, 1 if pass_null else 0, _frames_best, _lit_best])
		get_tree().quit(1))

	if core.is_empty():
		print("[biosprobe] SKIP: need --core=<name>")
		get_tree().quit(0)
		return

	_report_firmware()
	_report_options()
	_try_no_content()


## What the .info says this core wants, and what is actually on disk. Read
## through the shipped subsystem rather than a private scan, so the survey sees
## exactly what BiosBoot will see at power-on -- including the md5 verification,
## which is what separates a present BIOS from a wrong-region one.
func _report_firmware() -> void:
	var reqs := FirmwareRequirements.for_core(core)
	if reqs.is_empty():
		print("[biosprobe] firmware: core declares none")
		return
	var names := {
		FirmwareState.Status.PRESENT: "PRESENT",
		FirmwareState.Status.MISMATCH: "MISMATCH",
		FirmwareState.Status.MISSING_REQUIRED: "MISSING-REQUIRED",
		FirmwareState.Status.MISSING_OPTIONAL: "missing-optional",
	}
	for row in FirmwareState.shared().evaluate(core, reqs):
		print("[biosprobe] firmware: %-16s %s" % [
			str(names.get(int(row.get("status", 0)), "?")), str(row.get("path", ""))])


## Every option whose key looks like a boot-ROM switch, at its shipped default.
## Peeked, so this costs a dlopen and no emulation -- and it is the same read the
## options panel does on a powered-off machine.
func _report_options() -> void:
	var peeked := CoreOptionsStore.peek(root_dir, core)
	var definitions: Dictionary = peeked.get("definitions", {})
	if definitions.is_empty():
		print("[biosprobe] options: core published none before content (%s)"
			% CoreOptionsStore.peek_failure_reason(root_dir, core))
		return
	var values: Dictionary = peeked.get("values", {})
	var hits := 0
	for key: String in definitions:
		var lower := key.to_lower()
		var interesting := false
		for hint: String in OPTION_HINTS:
			if lower.contains(hint):
				interesting = true
				break
		if not interesting:
			continue
		hits += 1
		var definition: Object = definitions[key]
		var choices: Array = []
		for v: Object in definition.GetValues():
			choices.append(str(v.GetValue()))
		print("[biosprobe] option: %s = %s   choices=%s   (%s)" % [
			key, str(values.get(key, "?")), str(choices), str(definition.GetDescription())])
	if hits == 0:
		print("[biosprobe] options: %d declared, none look like a boot-ROM switch"
			% definitions.size())


## The measurement. StartContent with an empty path and see whether the core
## runs. Since Wrapper no longer consults GetSupportsNoGame, a core that refuses
## says so through content_load_failed rather than by silently sitting there.
func _try_no_content() -> void:
	var lib: Object = ClassDB.instantiate("Libretro")
	_lib = lib as Node
	if _lib == null:
		print("[biosprobe] FAIL: could not instantiate Libretro node")
		get_tree().quit(1)
		return
	add_child(_lib)
	_lib.connect("content_load_failed", _on_load_failed)

	# Before StartContent: it is read on the emulation thread as the core loads.
	ClassDB.class_call_static("Libretro", "SetNoContentPassesNull", pass_null)
	if rom.is_empty():
		print("[biosprobe] starting %s with no content, %s (root=%s)" % [
			core, "null game info" if pass_null else "zeroed game info", root_dir])
	else:
		print("[biosprobe] starting %s with empty media %s (root=%s)" % [core, rom, root_dir])
	_lib.StartContent(root_dir, core, rom)

	var t0 := Time.get_ticks_msec()
	for at: float in SAMPLE_AT:
		while (Time.get_ticks_msec() - t0) < int(at * 1000.0):
			await get_tree().process_frame
			if not _load_failed.is_empty():
				break
		if not _load_failed.is_empty():
			break
		_sample(at)

	var verdict := "no"
	if not _load_failed.is_empty():
		print("[biosprobe] refused: %s" % _load_failed)
	elif _frames_best > 0:
		verdict = "yes"

	print("[biosprobe] RESULT core=%s systemid=%s nullinfo=%d media=%s no_content=%s frames=%d lit=%.4f" % [
		core, systemid, 1 if pass_null else 0,
		"empty" if not rom.is_empty() else "none", verdict, _frames_best, _lit_best])
	# Stopping is measured too. mgba survives a no-content RUN and then dies as
	# it is unloaded, which a probe that quit immediately would report as a
	# clean pass -- the RESULT line had already printed.
	_lib.StopContent()
	await get_tree().create_timer(2.0).timeout
	print("[biosprobe] survived the stop")
	await get_tree().create_timer(1.0).timeout
	print("[biosprobe] survived two seconds of running after it")
	get_tree().quit(0)


func _on_load_failed(reason: String) -> void:
	_load_failed = reason


## Frames first: a BIOS still drawing its own black lead-in is running, and a
## core that refused never advances the counter at all.
func _sample(at: float) -> void:
	var frames: int = int(_lib.GetFrameCount())
	_frames_best = maxi(_frames_best, frames)
	var lit := -1.0
	var img: Image = _lib.GetVideoImage()
	if img != null and not img.is_empty():
		lit = _lit_fraction(img)
		_lit_best = maxf(_lit_best, lit)
		if not shot.is_empty():
			img.save_png(shot)
	print("[biosprobe] t=%4.1f frames=%-6d lit=%s" % [
		at, frames, ("%.4f" % lit) if lit >= 0.0 else "(no image)"])


func _lit_fraction(img: Image) -> float:
	var w := img.get_width()
	var h := img.get_height()
	var xstep: int = maxi(1, w / 64)
	var ystep: int = maxi(1, h / 64)
	var lit := 0
	var n := 0
	for y in range(0, h, ystep):
		for x in range(0, w, xstep):
			var c := img.get_pixel(x, y)
			if maxf(c.r, maxf(c.g, c.b)) > 0.03:
				lit += 1
			n += 1
	return float(lit) / float(maxi(n, 1))
