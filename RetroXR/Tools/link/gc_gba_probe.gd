## A GameCube and its Game Boy Advances, on one bus.
##
##     "$godot" --headless --path RetroXR res://Tools/link/gc_gba_probe.tscn -- --roms=Z:/roms
##
## Four Swords Adventures gives each player a GBA on the end of a GameCube lead:
## a second screen for caves and inventories, and the only way the game is meant
## to be played. On real hardware the console sends each handheld a program to
## run out of RAM, so the GBAs have no cartridges in them.
##
## This is the first thing on this bus that is not two of the same machine. A
## GameCube counts at about 729 million ticks a second and a Game Boy Advance at
## 16.7 million, and neither ever sees the other's units: the frontend converts,
## which is what the clock rate declared at attach has been for all along.
##
## It is also why the link had to stop working out which core was calling from
## the calling thread. Dolphin runs its CPU on a thread of its own whenever
## dual-core is on, so every call from its serial port arrives from somewhere the
## frontend had never heard of.
##
##   --gbas=N   how many handhelds, 1 to 4. The game wants one per player.
extends Node

const GC_CORE := "dolphin"
const GBA_CORE := "mgba"

## What a GBA on the end of a GameCube lead is, as libretro counts devices.
## Matches RETRO_DEVICE_GBA_LINK in DolphinLibretro: (7 << 8) | RETRO_DEVICE_NONE.
const RETRO_DEVICE_GBA_LINK := (7 << 8) | 0

## The bus port a GBA keeps for a GameCube lead, beside the one its link cable
## uses. One EXT socket, two kinds of conversation, and the frontend refuses to
## join the wrong pair because their protocol ids differ.
const GBA_JOY_PORT := 1

const PINNED := {
	"mgba_link_cable": "ON",
	"mgba_skip_bios": "OFF",
}

const BTN_A := 1 << 8
const BTN_START := 1 << 3
const BTN_LEFT := 1 << 6

var _opt_path := ""
var _opt_backup := ""
var _restored := false
var _gc: Libretro = null
var _gbas: Array[Libretro] = []
var _fail := 0
var _filming := false
var _film_frame := 0


func _ready() -> void:
	get_tree().create_timer(420.0).timeout.connect(func() -> void:
		print("[gcgba] TIMEOUT")
		_restore()
		get_tree().quit(1))
	await _run()


func _run() -> void:
	var count := 2
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--gbas="):
			count = clampi(int(arg.substr(7)), 1, 4)

	var iso := _find_iso()
	if iso.is_empty():
		print("[gcgba] SKIP  no Four Swords Adventures image found; pass --roms=<library>")
		get_tree().quit(0)
		return
	print("[gcgba] iso  %s" % iso)

	# --root= points this run at a PRIVATE core root, cores, system folders,
	# options and all. Worth having because this probe writes to a root as well
	# as reading from it (see _pin_options), and because more than one person can
	# be building mGBA at a time: measuring a change of your own by dropping it
	# into the shared cores folder overwrites whatever somebody else just put
	# there, and the first sign of it is their build behaving strangely.
	var root := CoreDownloadManager.default_core_root()
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--root="):
			root = arg.trim_prefix("--root=")
			print("[gcgba] core root: %s" % root)
		elif arg.begins_with("--latency="):
			# Raise the mixer's target queue depth for this run. The default is
			# 2048 frames, about 43 ms, and that was sized against the longest
			# MAIN-THREAD stall the app suffers. A linked machine is also stalled
			# by the bus, which is a source that budget never counted. Not saved:
			# it lasts as long as this process.
			var mx: Object = _meta_audio()
			if mx != null:
				mx.call("set_target_latency_ms", float(arg.trim_prefix("--latency=")))
				print("[gcgba] audio target now %.0f ms" % float(mx.call("get_target_latency_ms")))
			else:
				print("[gcgba] no Meta XR audio to retune; leaving the default")
	for pair: Array in [[GC_CORE, "dolphin_libretro.dll"], [GBA_CORE, "mgba_libretro.dll"]]:
		if not FileAccess.file_exists(root.path_join("cores").path_join(pair[1])):
			print("[gcgba] SKIP  %s is not installed" % pair[0])
			get_tree().quit(0)
			return
	var bios := root.path_join("system").path_join(GBA_CORE).path_join("gba_bios.bin")
	if not FileAccess.file_exists(bios):
		print("[gcgba] SKIP  need gba_bios.bin at %s" % bios)
		get_tree().quit(0)
		return
	if not _pin_options(root):
		print("[gcgba] SKIP  could not write the core options file")
		get_tree().quit(0)
		return

	_gc = Libretro.new()
	add_child(_gc)
	for i in range(count):
		var gba := Libretro.new()
		add_child(gba)
		_gbas.append(gba)
	print("[gcgba] one GameCube, %d handheld%s" % [count, "" if count == 1 else "s"])

	# --plain runs the GameCube on its own with ordinary controllers, which is the
	# control this needs: a console that will not boot here says nothing about a
	# link, and the two failures look identical from the outside.
	var plain := "--plain" in OS.get_cmdline_user_args()

	# --cable seats REAL leads instead of calling LinkConnect, which is the only
	# way to find out whether a player can do this. Everything else here talks to
	# the bus directly and would keep passing with the cable in the room broken.
	if "--cable" in OS.get_cmdline_user_args():
		await _run_with_cables(root, iso, count)
		return

	# Cable each handheld to a controller port BEFORE anything is switched on.
	# Both machines read whether anything is out there while they boot.
	if not plain:
		for i in _gbas.size():
			var joined: bool = _gc.LinkConnect(_gbas[i], i, GBA_JOY_PORT)
			_check("handheld %d is cabled to port %d" % [i + 1, i + 1], joined)

		# Tell the GameCube what is plugged into those ports. A device type, which
		# is what libretro already means by that question, rather than a core
		# option.
		for i in _gbas.size():
			_gc.SetControllerPortDevice(i, RETRO_DEVICE_GBA_LINK)
	else:
		print("[gcgba] plain: no handhelds cabled, ordinary controllers")

	# The handhelds have NOTHING in them: no cartridge, so the BIOS is all they
	# have, and the BIOS is what listens on the port.
	ClassDB.class_call_static("Libretro", "SetNoContentPassesNull", true)
	for gba: Libretro in _gbas:
		gba.StartContent(root, GBA_CORE, "")
	_gc.StartContent(root, GC_CORE, iso)

	await _settle(180)
	print("[gcgba] gc frames=%d  handheld frames=%s" % [
		_gc.GetFrameCount(), str(_gbas.map(func(m: Libretro) -> int: return m.GetFrameCount()))])
	var running := true
	for gba: Libretro in _gbas:
		running = running and gba.GetFrameCount() > 0
	_check("every handheld is running with no cartridge", running)
	_check("the GameCube is running", _gc.GetFrameCount() > 0)
	_shot("a_boot")

	# Through the title and into the game, pressed on the HANDHELDS.
	#
	# Not on the GameCube: in this game the handheld IS the controller, so a port
	# with one on it has no pad behind it and a press aimed at the console reaches
	# nothing at all. That is not a quirk of the probe -- it is the arrangement
	# the game is built around, and it took a title screen that would not move
	# through forty-eight presses to notice.
	var before := _sent()
	_filming = "--film" in OS.get_cmdline_user_args()
	for step in range(110):
		if _filming and step >= 62:
			await _film(60)
		else:
			await _settle(60)
		# Start on the title, then A through whatever it puts up next. Pressed
		# often rather than once, because this is a menu nobody has mapped and a
		# press that lands mid-fade is a press that did nothing.
		# Start only while the title is up, then A and nothing else.
		#
		# Alternating the two past the title walked in and out of the memory-card
		# dialog for ever: A takes the highlighted answer, Start backs out of the
		# menu that put it there, and pressing both in turn is a loop rather than
		# a route.
		if step < 6:
			await _press(BTN_START, _gbas)
		elif step >= 22 and step % 3 == 0:
			# Start skips the opening story, which runs for a good while before
			# anybody gets to move.
			await _press(BTN_START, _gbas)
		elif step >= 16 or step % 2 == 0:
			# Past the two dialogs it is A the whole way: the save-slot list and
			# everything after it want the highlighted entry taken, and a LEFT
			# there walks off onto Copy and Erase.
			await _press(BTN_A, _gbas)
		else:
			# Left first, then A. The game asks two yes/no questions on the way in
			# and both default to the answer that goes back rather than on: it
			# offers to make a save file, and when told no asks whether to carry on
			# without one. A alone takes the highlighted answer, so every other
			# press moves off it first.
			await _press(BTN_LEFT, _gbas)
			await _press(BTN_A, _gbas)
		_shot("b_step%02d" % step)
		_sample_audio()
		print("[gcgba] step%02d  sent=%s  peers=%s" % [step, str(_sent()), str(_peers())])
	_shot("c_end")

	print("[gcgba] audio sink floor per machine (%% of 100 ms held): %s" % str(_floor))
	print("[gcgba] samples under 20%%: %s of %d" % [str(_dips), _samples])
	print("[gcgba] samples EMPTY (a hole in the sound): %s of %d" % [str(_empty), _samples])
	# The mixer's OWN count, which is the authoritative one. An occupancy sample
	# that reads zero is not proof of a gap: the mixer drains in 256-frame blocks
	# and a producer refilling once an emulated frame can legitimately touch
	# bottom between the two without anything being heard. This counter only goes
	# up when the mixer actually wanted samples and had none.
	var mx: Object = _meta_audio()
	if mx != null and mx.has_method("get_underrun_count"):
		print("[gcgba] mixer underruns (the real number): %d" % int(mx.call("get_underrun_count")))
	else:
		print("[gcgba] mixer exposes no underrun count")

	var moved := 0
	var now := _sent()
	for i in now.size():
		moved += now[i] - before[i]
	print("[gcgba] ---- %d messages crossed ----" % moved)
	_check("the GameCube and the handhelds are talking", moved > 0)

	for machine: Libretro in _all():
		machine.StopContent()
	for i in range(120):
		await get_tree().process_frame
	_restore()
	print("[gcgba] ---- %s ----" % ("PASS" if _fail == 0 else "%d failed" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


## Save every machine's screen each frame, for encoding into one clip.
##
## A GameCube and its handhelds are not the same size or the same shape, and what
## makes the thing legible is seeing them together: the television doing one
## thing and the little screens doing another, at the same moment.
func _film(frames: int) -> void:
	var dir := "res://probe_out/gcfilm"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var machines := _all()
	var target: int = _gc.GetFrameCount() + frames
	var deadline: int = Time.get_ticks_msec() + 25000
	while _gc.GetFrameCount() < target and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		var shots: Array[Image] = []
		for machine: Libretro in machines:
			var img: Image = machine.GetVideoImage()
			if img == null or img.is_empty():
				shots.clear()
				break
			shots.append(img)
		if shots.is_empty():
			continue
		for i in shots.size():
			shots[i].save_png("%s/%05d_%d.png" % [dir, _film_frame, i])
		_film_frame += 1


## The same thing, done with leads a hand could pick up.
##
## Spawns a GameCube and N handhelds as room objects, then seats a DOL-011 into
## each: the wide end into a controller socket, the barrel into an EXT port. The
## console is told what is on the port by the plug seating, not by anything here.
func _run_with_cables(root: String, iso: String, count: int) -> void:
	var sys_scene := load("res://Scenes/Objects/system.tscn") as PackedScene
	var console := sys_scene.instantiate() as RetroSystem
	console.systemid = "gamecube"
	console.core_name = GC_CORE
	console.name = "GameCube"
	add_child(console)

	var handhelds: Array[RetroSystem] = []
	for i in range(count):
		var hh := sys_scene.instantiate() as RetroSystem
		hh.systemid = "game_boy_advance"
		hh.core_name = GBA_CORE
		hh.name = "GBA%d" % (i + 1)
		add_child(hh)
		handhelds.append(hh)
	await get_tree().process_frame

	var leads: Array[GcGbaCable] = []
	var cable_scene := load("res://Scenes/Objects/cables/gc_gba_cable.tscn") as PackedScene
	for i in range(count):
		var lead := cable_scene.instantiate() as GcGbaCable
		lead.name = "Lead%d" % (i + 1)
		add_child(lead)
		leads.append(lead)
	await get_tree().process_frame

	# Seat both ends. The console's controller sockets are ordinary snap zones,
	# the handheld's EXT port is a LinkPort, and neither end of this lead answers
	# to the other's filter -- which is what stops a player putting it in
	# backwards.
	for i in range(count):
		var slot := console.find_child("ControllerPort%d" % (i + 1), true, false) as XRToolsSnapZone
		if slot == null:
			var zones: Array[Node] = console.find_children("*", "XRToolsSnapZone", true, false)
			for z: Node in zones:
				if z.name.begins_with("ControllerPort") or z.name.begins_with("Port"):
					if z.get_meta("gc_taken", false):
						continue
					z.set_meta("gc_taken", true)
					slot = z as XRToolsSnapZone
					break
		var ext := handhelds[i].find_child("LinkPort", true, false) as XRToolsSnapZone
		_check("console socket %d exists" % (i + 1), slot != null)
		_check("handheld %d has an EXT port" % (i + 1), ext != null)
		if slot == null or ext == null:
			continue
		slot.pick_up_object(leads[i].get_node("PlugA0"))
		ext.pick_up_object(leads[i].get_node("PlugB0"))
	for i in range(20):
		await get_tree().process_frame

	# Now switch everything on. Cabled first, powered second, which is the order
	# a restored room produces and the order that works.
	for hh: RetroSystem in handhelds:
		hh.rom_path = ""
		hh.power_on()
	console.rom_path = iso
	console.power_on()
	for i in range(600):
		await get_tree().process_frame

	var counts: PackedStringArray = []
	var joined := true
	for i in range(count):
		var gc_lib: Libretro = console.get_libretro_node()
		var hh_lib: Libretro = handhelds[i].get_libretro_node()
		var a: int = gc_lib.LinkPeerCount(i)
		var b: int = hh_lib.LinkPeerCount(GBA_JOY_PORT)
		counts.append("%d/%d" % [a, b])
		joined = joined and a == 2 and b == 2
	print("[gcgba] cabled by hand: peers %s" % "/".join(counts))
	_check("every lead joined its console port to its handheld", joined)

	console.power_off()
	for hh: RetroSystem in handhelds:
		hh.power_off()
	for i in range(60):
		await get_tree().process_frame
	_restore()
	print("[gcgba] ---- %s ----" % ("PASS" if _fail == 0 else "%d failed" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


func _all() -> Array[Libretro]:
	var out: Array[Libretro] = [_gc]
	out.append_array(_gbas)
	return out


func _sent() -> Array[int]:
	var out: Array[int] = []
	for i in _gbas.size():
		out.append(_gc.LinkSent(i))
	for gba: Libretro in _gbas:
		out.append(gba.LinkSent(GBA_JOY_PORT))
	return out


func _peers() -> Array[int]:
	var out: Array[int] = []
	for i in _gbas.size():
		out.append(_gc.LinkPeerCount(i))
	for gba: Libretro in _gbas:
		out.append(gba.LinkPeerCount(GBA_JOY_PORT))
	return out


func _check(name: String, cond: bool) -> void:
	if cond:
		print("[gcgba] PASS  %s" % name)
	else:
		_fail += 1
		print("[gcgba] FAIL  %s" % name)


## Wait for emulated frames on every machine, and never for ever.
##
## A GameCube and a Game Boy Advance do not run at the same rate and a machine
## that has stalled must not hang the run, so this is a floor on progress rather
## than a barrier.
## The audio sink's depth, sampled per machine.
##
## The number that decides whether the sound breaks up, and the only one that
## measures the SYMPTOM rather than a cause. The sink holds 100 ms; a core whose
## emulation thread is parked at a link rendezvous is not producing samples, so
## every stall drains it and a stall longer than the sink is a hole in the
## audio. Averages hide this completely: a run can spend 75% of itself blocked
## in short stalls and never miss a sample, or stall once for 200 ms and crackle.
var _floor: Array[int] = []
var _dips: Array[int] = []


var _samples := 0
var _empty: Array[int] = []


func _sample_audio() -> void:
	var all := _all()
	if _floor.size() != all.size():
		_floor.resize(all.size())
		_dips.resize(all.size())
		_empty.resize(all.size())
		_floor.fill(100)
		_dips.fill(0)
		_empty.fill(0)
	_samples += 1
	for i in range(all.size()):
		var occ: int = int(all[i].GetAudioBufferOccupancy())
		if occ < _floor[i]:
			_floor[i] = occ
		# Under a fifth of the sink is a machine within ~20 ms of silence.
		if occ < 20:
			_dips[i] += 1
		# And empty is a hole in the sound, not a near miss.
		if occ <= 0:
			_empty[i] += 1


func _settle(frames: int) -> void:
	var deadline: int = Time.get_ticks_msec() + 25000
	var base: Array[int] = []
	for machine: Libretro in _all():
		base.append(machine.GetFrameCount())
	while Time.get_ticks_msec() < deadline:
		_sample_audio()
		var done := true
		var machines := _all()
		for i in machines.size():
			var now: int = machines[i].GetFrameCount()
			if now < base[i]:
				base[i] = now
			if now - base[i] < frames:
				done = false
		if done:
			return
		await get_tree().process_frame


func _press(mask: int, who: Array) -> void:
	for machine: Libretro in who:
		machine.SetJoypadState(0, mask, 0, 0, 0, 0)
	await _settle(6)
	for machine: Libretro in who:
		machine.SetJoypadState(0, 0, 0, 0, 0, 0)
	await _settle(10)


func _shot(tag: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))
	var machines := _all()
	for i in machines.size():
		var img: Image = machines[i].GetVideoImage()
		if img != null and not img.is_empty():
			img.save_png("res://probe_out/gcgba_%s_%s.png" % [
				tag, "gc" if i == 0 else "gba%d" % i])


func _find_iso() -> String:
	var roots: PackedStringArray = [RomLibrary.default_roms_root()]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--roms="):
			roots.append(arg.substr(7))
	for root in roots:
		for systemid in ["nintendo_gamecube", "gc", "gamecube"]:
			var dir_path: String = root.path_join(systemid)
			var dir := DirAccess.open(dir_path)
			if dir == null:
				continue
			for f in dir.get_files():
				var lower := f.to_lower()
				if lower.contains("four swords") and not lower.contains("(unl)") \
						and (lower.ends_with(".rvz") or lower.ends_with(".iso") \
							or lower.ends_with(".gcm") or lower.ends_with(".ciso")):
					return dir_path.path_join(f)
	return ""


func _pin_options(root: String) -> bool:
	_opt_path = "%s/core_options/%s.opt" % [root, GBA_CORE]
	var existing := ""
	if FileAccess.file_exists(_opt_path):
		var reader := FileAccess.open(_opt_path, FileAccess.READ)
		if reader != null:
			existing = reader.get_as_text()
			reader.close()
	_opt_backup = existing

	var lines: PackedStringArray = []
	for line in existing.split("\n", false):
		var pinned := false
		for key: String in PINNED:
			if line.begins_with(key):
				pinned = true
		if not pinned:
			lines.append(line)
	for key: String in PINNED:
		lines.append('%s = "%s"' % [key, PINNED[key]])

	var writer := FileAccess.open(_opt_path, FileAccess.WRITE)
	if writer == null:
		return false
	writer.store_string("\n".join(lines) + "\n")
	writer.close()
	return true


func _restore() -> void:
	if _restored or _opt_path.is_empty():
		return
	_restored = true
	var writer := FileAccess.open(_opt_path, FileAccess.WRITE)
	if writer != null:
		writer.store_string(_opt_backup)
		writer.close()


## The Meta XR mixer, or null where it is not the audio backend.
func _meta_audio() -> Object:
	if not Engine.has_singleton("MetaXRAudio"):
		return null
	var mx: Object = Engine.get_singleton("MetaXRAudio")
	if mx == null or not bool(mx.call("is_available")):
		return null
	return mx
