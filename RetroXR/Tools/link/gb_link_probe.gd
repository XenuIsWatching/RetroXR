## Two real gambatte cores on one link bus.
##
##     "$godot" --headless --path RetroXR res://Tools/link/gb_link_probe.tscn
##
## A probe rather than a test, because it needs a gambatte built with the link
## driver, so it cannot gate a commit. What it proves is the claim no headless
## suite can reach: that two instances of one core, each loaded from its own copy
## of the shared library, exchange real serial bytes through the frontend's bus.
##
## The ROMs are ours (Tools/gen_gblink_rom.py) and do one thing -- swap a known
## byte for ever, and paint the screen white while the byte coming back is the
## right one. So the oracle is the picture, and the failure modes are legible:
## black is a machine that has never completed a transfer, dark grey is one
## completing transfers with the wrong byte in them.
##
## The link and the bootloader are set through the core's options FILE rather
## than SetCoreOption, because gambatte reads both while loading the game and
## SetCoreOption only reaches a core that is already running. The file is the
## player's own, so it is snapshotted and put back at both ends.
extends Node

## Which core, and the options that switch its cable on and its boot ROM off.
##
## Both are asked for by name because a Game Boy game runs on more than one:
## gambatte is the room's default and mGBA carries a Game Boy core too. The boot
## ROM matters because these ROMs carry no Nintendo logo, so a real one would
## refuse to hand them control.
const CORE_OPTIONS := {
	"gambatte": [["gambatte_gb_link_mode", "Link Cable"], ["gambatte_gb_bootloader", "disabled"]],
	"mgba": [["mgba_link_cable", "ON"], ["mgba_use_bios", "OFF"]],
}

var _core := "gambatte"

## How long the two machines are left running. The master ROM clocks a byte
## about every 27 ms, so this is dozens of exchanges rather than one lucky one.
const RUN_SECONDS := 4.0

var _pass := 0
var _fail := 0
var _opt_path := ""
var _opt_backup := ""
var _had_opt := false
var _restored := false


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[gb-link] TIMEOUT")
		_restore()
		get_tree().quit(1))
	await _run()


func _ok(name: String, cond: bool, detail := "") -> void:
	if cond:
		_pass += 1
		print("[gb-link] PASS  %s" % name)
	else:
		_fail += 1
		print("[gb-link] FAIL  %s%s" % [name, "  — " + detail if not detail.is_empty() else ""])


func _eq(name: String, got: Variant, want: Variant) -> void:
	_ok(name, got == want, "got %s, want %s" % [str(got), str(want)])


func _finish() -> void:
	_restore()
	print("[gb-link] ---- %d passed, %d failed ----" % [_pass, _fail])
	get_tree().quit(1 if _fail > 0 else 0)


func _run() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--core="):
			_core = arg.substr(7)
	if not CORE_OPTIONS.has(_core):
		print("[gb-link] SKIP  no link options known for %s" % _core)
		get_tree().quit(0)
		return
	print("[gb-link] core %s" % _core)

	var root := CoreDownloadManager.default_core_root()
	var master_rom := ProjectSettings.globalize_path("res://Tools/gblink/link_master.gb")
	var slave_rom := ProjectSettings.globalize_path("res://Tools/gblink/link_slave.gb")

	if not FileAccess.file_exists(master_rom) or not FileAccess.file_exists(slave_rom):
		print("[gb-link] SKIP  run Tools/gen_gblink_rom.py first")
		get_tree().quit(0)
		return
	if not FileAccess.file_exists("%s/cores/%s_libretro.dll" % [root, _core]) \
			and not FileAccess.file_exists("%s/cores/%s_libretro.so" % [root, _core]):
		print("[gb-link] SKIP  no %s core installed under %s" % [_core, root])
		get_tree().quit(0)
		return

	print("[gb-link] root %s" % root)
	if not _write_options(root):
		print("[gb-link] SKIP  could not write the core options file")
		get_tree().quit(0)
		return

	var a := Libretro.new()
	var b := Libretro.new()
	add_child(a)
	add_child(b)

	a.StartContent(root, _core, master_rom)
	b.StartContent(root, _core, slave_rom)

	# Both cores have to get through retro_load_game to attach, which is a thread
	# hand-off and a file load away.
	for i in range(240):
		await get_tree().process_frame

	# Attached but cabled to nothing: the bus has no idea these two belong
	# together until the room says so, which is the whole point of a cable.
	_eq("master alone sees no peers", a.LinkPeerCount(0), 0)
	_eq("slave alone sees no peers", b.LinkPeerCount(0), 0)

	# The two controls this whole probe rests on, taken while the machines are
	# uncabled. A Game Boy clocking a cable with nothing on it reads 0xFF, so the
	# master is sitting in its mismatch state; a Game Boy waiting on an external
	# clock that never comes waits for ever, so the slave has never completed a
	# transfer at all. Neither shade is asserted against a number -- gambatte
	# picks a palette per game and the absolute value is its business. What is
	# asserted is that the linked screens are neither of these.
	var shade_bad := _shade(a.GetVideoImage())
	var shade_idle := _shade(b.GetVideoImage())
	print("[gb-link] uncabled: master %s, slave %s" % [str(shade_bad), str(shade_idle)])
	_ok("the two uncabled machines are in different states", shade_bad != shade_idle,
			"both %s" % str(shade_bad))

	_ok("cabling them together succeeds", a.LinkConnect(b, 0, 0))
	await get_tree().process_frame
	_eq("master sees both machines", a.LinkPeerCount(0), 2)
	_eq("slave sees both machines", b.LinkPeerCount(0), 2)

	var sent_before := a.LinkSent(0)
	var got_before := b.LinkTraffic(0)

	var frames := int(RUN_SECONDS * 60.0)
	for i in range(frames):
		await get_tree().process_frame

	var sent := a.LinkSent(0) - sent_before
	var got := b.LinkTraffic(0) - got_before
	print("[gb-link] master sent %d, slave took %d, master took %d" % [sent, got, a.LinkTraffic(0)])
	_ok("the master put messages on the wire", sent > 0, "sent %d" % sent)
	_ok("the slave took them off it", got > 0, "delivered %d" % got)

	var img_a := a.GetVideoImage()
	var img_b := b.GetVideoImage()
	var shade_a := _shade(img_a)
	var shade_b := _shade(img_b)
	print("[gb-link] cabled: master %s, slave %s" % [str(shade_a), str(shade_b)])
	_save(img_a, "master")
	_save(img_b, "slave")

	_ok("the master read the byte the slave was holding",
			shade_a != shade_bad and shade_a != shade_idle,
			"still showing %s" % str(shade_a))
	_ok("the slave read the byte the master clocked",
			shade_b != shade_bad and shade_b != shade_idle,
			"still showing %s" % str(shade_b))
	_ok("and both agree, because they agreed on the bytes", shade_a == shade_b,
			"%s vs %s" % [str(shade_a), str(shade_b)])

	# And the cable comes out again. A machine clocking a lead with nothing on the
	# other end reads 0xFF, so the master falls back to exactly the shade it wore
	# before it was ever cabled.
	a.LinkDisconnect(0)
	await get_tree().process_frame
	_eq("master is alone again", a.LinkPeerCount(0), 0)
	_eq("slave is alone again", b.LinkPeerCount(0), 0)
	for i in range(90):
		await get_tree().process_frame
	_eq("pulling the lead is felt at once", _shade(a.GetVideoImage()), shade_bad)

	# Put it back. Seating a cable rebuilds the bus, which takes both machines off
	# their timelines and makes each forget what the other was holding, so the
	# link has to be negotiated from nothing a second time with two guests that
	# have no idea anything happened.
	#
	# What this does NOT cover, though the driver guards against it: an
	# announcement made while the peer is still off its timeline is dropped by the
	# bus, so a driver that announces itself once on a membership change can be
	# left unheard. It cannot be provoked here, because the master clocks the wire
	# every 28 ms and being clocked is itself something that changes the slave's
	# state and gets it published again. Disabling the driver's repeat costs
	# exactly one transfer, which no assertion on a screen can see.
	_ok("re-cabling them succeeds", a.LinkConnect(b, 0, 0))
	for i in range(150):
		await get_tree().process_frame
	_eq("and the link comes back on its own", _shade(a.GetVideoImage()), shade_a)

	# A machine can be switched off and on with the lead still in it. A reset takes
	# this end off its own timeline -- the cycle counter restarts, so the driver
	# re-anchors, and anything queued for it is dropped -- while the peer carries
	# on and never notices. Bus membership does not change, so nothing prompts the
	# other end to speak: what brings the link back is the next transfer, because
	# being clocked is itself a change the peer publishes.
	#
	# The port must survive it. mGBA routes a reset through GBSIOSetDriver, which
	# deinits the driver and inits it again, so a deinit that left the bus would
	# take the machine off the wire every time a guest was reset -- with the cable
	# still visibly plugged in.
	#
	# The peer count is the weaker half of that and cannot see it happen: the init
	# re-attaches immediately, so by the time this reads the count it is 2 again
	# whether or not the port was ever dropped. What catches a transient detach is
	# the shade -- the machine comes back on the bus with its identity rebuilt and
	# never recovers the link. Verified by making deinit detach: the count case
	# still passes, the shade case goes red.
	a.RequestReset()
	for i in range(180):
		await get_tree().process_frame
	_eq("a reset never takes the port off the wire", a.LinkPeerCount(0), 2)
	_eq("and the master rejoins the link on its own",
			_shade(a.GetVideoImage()), shade_a)

	# The other end of the same question. The slave is the one being clocked, so
	# it comes back by a different route: it has to re-arm and be found armed.
	b.RequestReset()
	for i in range(180):
		await get_tree().process_frame
	_eq("the same holds when it is the slave that resets", b.LinkPeerCount(0), 2)
	_eq("and the slave rejoins the link on its own",
			_shade(b.GetVideoImage()), shade_b)

	# Stopping a cabled core must not wedge the other: its emulation thread is
	# parked on the barrier waiting for a peer that will never publish again.
	a.StopContent()
	for i in range(120):
		await get_tree().process_frame
	_eq("stopping one end leaves the other alone", b.LinkPeerCount(0), 0)

	b.StopContent()
	for i in range(120):
		await get_tree().process_frame

	a.queue_free()
	b.queue_free()
	await get_tree().process_frame

	await _fast_pass(root)
	_finish()


## The same exchange at the Game Boy Color's own rate.
##
## SC bit 1 picks a 262144 Hz clock over the Game Boy's 8192, which is a transfer
## of 128 cycles against 4096 -- thirty-two times shorter than the horizon the
## driver uses for a Game Boy, so the whole timing has to move underneath it or
## every byte lands after the transfer that carried it. Nothing on a Game Boy can
## reach this path: the bit reads back as one on a DMG whatever is written, so a
## machine has to be a Game Boy Color for it to mean anything, and these two ROMs
## carry the flag in their header that makes one.
func _fast_pass(root: String) -> void:
	var master_rom := ProjectSettings.globalize_path("res://Tools/gblink/link_master_fast.gbc")
	var slave_rom := ProjectSettings.globalize_path("res://Tools/gblink/link_slave_fast.gbc")
	if not FileAccess.file_exists(master_rom) or not FileAccess.file_exists(slave_rom):
		print("[gb-link] SKIP  no fast-clock ROMs; run Tools/gen_gblink_rom.py")
		return

	var a := Libretro.new()
	var b := Libretro.new()
	add_child(a)
	add_child(b)
	a.StartContent(root, _core, master_rom)
	b.StartContent(root, _core, slave_rom)
	for i in range(240):
		await get_tree().process_frame

	var shade_bad := _shade(a.GetVideoImage())
	var shade_idle := _shade(b.GetVideoImage())
	print("[gb-link] fast uncabled: master %s, slave %s" % [shade_bad, shade_idle])
	_ok("fast: the two uncabled machines are in different states", shade_bad != shade_idle,
			"both %s" % shade_bad)

	_ok("fast: cabling them together succeeds", a.LinkConnect(b, 0, 0))
	await get_tree().process_frame
	_eq("fast: master sees both machines", a.LinkPeerCount(0), 2)

	var sent_before := a.LinkSent(0)
	for i in range(int(RUN_SECONDS * 60.0)):
		await get_tree().process_frame
	var sent := a.LinkSent(0) - sent_before
	print("[gb-link] fast: master sent %d" % sent)
	_ok("fast: the master put messages on the wire", sent > 0, "sent %d" % sent)

	var img_a := a.GetVideoImage()
	var img_b := b.GetVideoImage()
	var shade_a := _shade(img_a)
	var shade_b := _shade(img_b)
	print("[gb-link] fast cabled: master %s, slave %s" % [shade_a, shade_b])
	_save(img_a, "fast_master")
	_save(img_b, "fast_slave")
	_ok("fast: the master read the byte the slave was holding",
			shade_a != shade_bad and shade_a != shade_idle, "still showing %s" % shade_a)
	_ok("fast: the slave read the byte the master clocked",
			shade_b != shade_bad and shade_b != shade_idle, "still showing %s" % shade_b)
	_ok("fast: and both agree", shade_a == shade_b, "%s vs %s" % [shade_a, shade_b])

	a.StopContent()
	b.StopContent()
	for i in range(120):
		await get_tree().process_frame
	a.queue_free()
	b.queue_free()
	await get_tree().process_frame


## The one shade the whole screen is painted, or an empty string if it is not
## flat. The ROMs draw a single blank tile everywhere, so a flat screen is the
## normal case and anything else means the machine is not running our code.
func _shade(img: Image) -> String:
	if img == null or img.is_empty():
		return "<no picture>"
	var first := img.get_pixel(0, 0)
	for y in range(0, img.get_height(), 8):
		for x in range(0, img.get_width(), 8):
			if not img.get_pixel(x, y).is_equal_approx(first):
				return "<not flat>"
	return "#" + first.to_html(false)


func _save(img: Image, name: String) -> void:
	if img == null or img.is_empty():
		return
	var dir := "res://probe_out"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var path := "%s/gb_link_%s.png" % [dir, name]
	img.save_png(path)
	print("[gb-link] wrote %s" % path)


## Turn the cable on and the boot ROM off, keeping a copy of whatever was there.
func _write_options(root: String) -> bool:
	_opt_path = "%s/core_options/%s.opt" % [root, _core]
	var existing := ""
	_had_opt = FileAccess.file_exists(_opt_path)
	if _had_opt:
		var reader := FileAccess.open(_opt_path, FileAccess.READ)
		if reader != null:
			existing = reader.get_as_text()
			reader.close()
	_opt_backup = existing

	var wanted: Array = CORE_OPTIONS[_core]
	var lines: PackedStringArray = []
	for line in existing.split("\n", false):
		var keep := true
		for pair: Array in wanted:
			if line.begins_with(str(pair[0])):
				keep = false
		if keep:
			lines.append(line)
	# The option's own VALUE, not the label a menu prints beside it: the core
	# compares against the value and matches nothing else.
	for pair: Array in wanted:
		lines.append('%s = "%s"' % [pair[0], pair[1]])

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
	if not _had_opt:
		DirAccess.remove_absolute(_opt_path)
		return
	var writer := FileAccess.open(_opt_path, FileAccess.WRITE)
	if writer != null:
		writer.store_string(_opt_backup)
		writer.close()
		print("[gb-link] restored %s" % _opt_path)
