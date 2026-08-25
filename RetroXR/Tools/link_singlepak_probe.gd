## Single-cartridge play: one machine sends the other the game.
##
##     "$godot" --headless --path RetroXR res://Tools/link_singlepak_probe.tscn -- --roms=Z:/roms
##
## Both machines end up playing Mario Bros. together, and one of them has nothing
## in it.
##
## The host has Super Mario Advance in it. The client has NOTHING in it -- no
## cartridge at all -- and sits on the GAME BOY screen its BIOS draws when there
## is nothing to boot, listening on the link port. The host sends it a program to
## run out of RAM, and both play.
##
## Two things had to exist for this to be testable at all, and both are worth
## naming because either one missing looks like the other having failed:
##
##   * The core has to start with no content. It used to dereference the game
##     info without checking it, so a machine with no cartridge could not be
##     asked for, never mind booted.
##   * The link has to carry NORMAL mode. Multiplayer is what a game in play
##     uses and it is not what a program is sent over: that is 32-bit normal
##     transfers, 256 cycles each against multiplayer's 5755, which is why the
##     bus's commit horizon follows the mode instead of being one number.
##
## The ROM has to carry a payload to send. A cartridge that can do this holds a
## SECOND complete GBA header inside itself -- the image it hands the client --
## and the probe checks for one rather than assuming, because a game without one
## can only ever refuse and that is not the same as a link that failed.
extends Node

const CORE := "mgba"
const PINNED := {
	"mgba_link_cable": "ON",
	"mgba_skip_bios": "OFF",
}

const BTN_A := 1 << 8
const BTN_B := 1 << 0
const BTN_START := 1 << 3
const BTN_DOWN := 1 << 5

var _opt_path := ""
var _opt_backup := ""
var _restored := false
var _host: Libretro = null
## The first client, which is the one the two-machine wording talks about.
var _client: Libretro = null
var _clients: Array[Libretro] = []
## Host and clients together, in bus order.
var _all: Array[Libretro] = []
var _fail := 0


func _ready() -> void:
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[pak] TIMEOUT")
		_restore()
		get_tree().quit(1))
	await _run()


func _run() -> void:
	var rom := _find_rom()
	if rom.is_empty():
		print("[pak] SKIP  no Super Mario Advance ROM found; pass --roms=<library>")
		get_tree().quit(0)
		return
	if not _carries_a_payload(rom):
		print("[pak] SKIP  %s carries no second GBA header, so it has nothing to send" % rom)
		get_tree().quit(0)
		return

	var root := CoreDownloadManager.default_core_root()
	var bios := root.path_join("system").path_join(CORE).path_join("gba_bios.bin")
	if not FileAccess.file_exists(bios):
		print("[pak] SKIP  need gba_bios.bin in %s; a machine with no cartridge has" % bios.get_base_dir()
			+ " nothing else to run")
		get_tree().quit(0)
		return
	if not _pin_options(root):
		print("[pak] SKIP  could not write the core options file")
		get_tree().quit(0)
		return

	# One host and up to three cartridge-less clients, which is the party a GBA
	# link cable carries.
	var clients := 1
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--clients="):
			clients = clampi(int(arg.substr(10)), 1, 3)
	_host = Libretro.new()
	add_child(_host)
	_all.append(_host)
	for i in range(clients):
		var c := Libretro.new()
		add_child(c)
		_clients.append(c)
		_all.append(c)
	_client = _clients[0]
	print("[pak] host + %d client%s" % [clients, "" if clients == 1 else "s"])

	# Which way round the lead goes in.
	#
	# --reversed puts the CARTRIDGE-LESS machine at bus index 0, which is what a
	# player produces by seating the purple end in the wrong handheld. It is a
	# reachable state and it is the one this probe exists to tell apart from a
	# broken link, because from the room it looks identical: both machines
	# cabled, both reading the right peer count, and the game refusing.
	#
	# --swap starts reversed and then re-cables the right way round mid-run,
	# WITHOUT switching anything off. That is what a player does the moment they
	# notice, and the question is whether the machines pick the new seats up.
	var reversed := false
	var swap := false
	var swap_reset := false
	var clients_first := false
	for arg in OS.get_cmdline_user_args():
		if arg == "--reversed":
			reversed = true
		elif arg == "--swap":
			reversed = true
			swap = true
		elif arg == "--swap-reset":
			reversed = true
			swap = true
			swap_reset = true
		elif arg == "--clients-first":
			clients_first = true
	print("[pak] seating: %s" % ("cartridge-less machine first" if reversed
		else "cartridge first"))

	# Cabled before anything is switched on, which is the order that works and
	# the order a room produces. Every machine reads whether anything is out
	# there while it boots and never asks again.
	var joined: bool = _cable(reversed)
	print("[pak] cabled=%s" % str(joined))

	# The client takes the null game info: no cartridge, so the BIOS is all it
	# has, and the BIOS is what listens on the link port.
	ClassDB.class_call_static("Libretro", "SetNoContentPassesNull", true)
	if clients_first:
		print("[pak] power: clients 2..%d, then host 1" % (_clients.size() + 1))
		for c: Libretro in _clients:
			c.StartContent(root, CORE, "")
			await _wait(30)
		_host.StartContent(root, CORE, rom)
	else:
		print("[pak] power: host 1, then clients 2..%d" % (_clients.size() + 1))
		_host.StartContent(root, CORE, rom)
		for c: Libretro in _clients:
			c.StartContent(root, CORE, "")
	await _wait(120)
	var peers: PackedStringArray = []
	for machine: Libretro in _all:
		peers.append(str(machine.LinkPeerCount(0)))
	print("[pak] host frames=%d  client frames=%d  peers=%s" % [
		_host.GetFrameCount(), _client.GetFrameCount(), "/".join(peers)])
	var booted := true
	var cabled := true
	for c: Libretro in _clients:
		booted = booted and c.GetFrameCount() > 0
	for machine: Libretro in _all:
		cabled = cabled and machine.LinkPeerCount(0) == _all.size()
	_check("every client is running with no cartridge", booted)
	_check("every machine is on the cable", cabled)
	_shot("a_boot")

	# Re-cable the right way round, with everything still running. No reset, no
	# power cycle: the plugs move and that is all, which is exactly what the
	# player did.
	if swap:
		for machine: Libretro in _all:
			machine.LinkDisconnect(0)
		await _wait(30)
		print("[pak] re-cabled the right way round: %s" % str(_cable(false)))
		await _wait(60)
		# What the room now does for the player. A machine that has already
		# decided it is player two does not become player one because a plug
		# moved, so the seat change is a reset, exactly as the cable arriving
		# late is one.
		if swap_reset:
			for machine: Libretro in _all:
				machine.RequestReset()
			print("[pak] and reset both machines into their new seats")
			await _wait(180)
		var after: PackedStringArray = []
		for machine: Libretro in _all:
			after.append(str(machine.LinkPeerCount(0)))
		print("[pak] after the swap peers=%s" % "/".join(after))

	# Through the host's intro to Multiplayer, the same route the two-cartridge
	# probe takes. What differs is on the other end of the wire.
	await _wait(240)
	await _hold(BTN_START, 6, 40, [_host])
	await _hold(BTN_DOWN, 6, 20, [_host])
	await _hold(BTN_A, 6, 60, [_host])
	_shot("b_multiplayer")

	# Then watch. A send is a burst, so the counters move in a way an idle poll
	# never does, and the client's screen leaves the BIOS when it starts running
	# what it was sent.
	var sent_before: int = _host.LinkSent(0)
	var client_before: int = _client.LinkSent(0)
	var peak := 0
	var last: int = _host.LinkSent(0)
	var last_reported: int = 0
	for step in range(30):
		await _wait(60)
		# Nudge only until the game is up, and then STOP.
		#
		# Start is what a player presses to pause, and pausing one end of a link
		# game is how a link game ends: carrying on pressing it through the play
		# that follows put ERROR! on both screens, which reads exactly like a
		# transfer that half worked. The presses are here to get through menus,
		# and a menu that has been left is a menu that must stop being pressed.
		if step < 14:
			var who: Array = [_host] if step < 12 else _all
			if step % 3 == 1:
				await _hold(BTN_A, 6, 10, who)
			if step % 3 == 2:
				await _hold(BTN_START, 6, 10, who)
		_shot("c_step%02d" % step)
		var now: int = _host.LinkSent(0)
		peak = maxi(peak, now - last)
		last = now
		var sent: PackedStringArray = []
		for machine: Libretro in _all:
			sent.append(str(machine.LinkSent(0)))
		print("[pak] step%02d  sent=%s" % [step, "/".join(sent)])
		if step == 28:
			last_reported = now
	_shot("d_playing")

	var host_moved: int = _host.LinkSent(0) - sent_before
	var client_moved: int = _client.LinkSent(0) - client_before
	print("[pak] ---- host sent %d, client sent %d, busiest second %d ----" % [
		host_moved, client_moved, peak])
	_check("the client answered over the wire", client_moved > 0)

	# A program being SENT is a burst, and that is what tells it apart from a
	# link that merely negotiated. Two machines idling at each other move a few
	# hundred messages a second; handing over forty kilobytes in 32-bit words
	# moves thousands, and there is no reading of an idle poll that reaches it.
	_check("a program crossed the wire rather than a handshake", peak > 4000)

	# The check that earned its place.
	#
	# It was written FAILING, when the send worked and neither machine got past
	# the LOADING screen afterwards: the wire went quiet, the client gave up with
	# ERROR!, and the host was still saying LOADING when the run ended. Three
	# greens said the feature worked and this one said it did not reach play,
	# which is what sent the trace at the hand-off and found the cause -- the
	# clock owner being read off the wrong SIOCNT bit, so the host was armed as a
	# listener and its transfer could never complete.
	#
	# A probe that stopped at "the program arrived" would have reported PASS for
	# a feature that did not work.
	var tail: int = _host.LinkSent(0) - last_reported
	_check("the game is still running at the end of the run", tail > 0)

	for machine: Libretro in _all:
		machine.StopContent()
	for i in range(120):
		await get_tree().process_frame
	_restore()
	print("[pak] ---- %s ----" % ("PASS" if _fail == 0 else "%d failed" % _fail))
	get_tree().quit(1 if _fail > 0 else 0)


## Join every machine onto one bus. Bus index 0 is the seat the hardware calls
## player one, and LinkConnectGroup takes it from the machine the call is made
## on, so which machine that is decides the whole ordering.
func _cable(cartridge_last: bool) -> bool:
	# Built up rather than picked with a ternary: an empty array literal in one
	# branch of one is an untyped Array, and assigning that to a typed variable
	# is a runtime error, which came out as the re-cable silently returning false.
	var order: Array[Libretro] = []
	if cartridge_last:
		order.append_array(_clients)
		order.append(_host)
	else:
		order.append(_host)
		order.append_array(_clients)
	var head: Libretro = order[0]
	var others: Array = []
	var ports := PackedInt32Array()
	ports.append(0)
	for i in range(1, order.size()):
		others.append(order[i])
		ports.append(0)
	return head.LinkConnectGroup(others, ports)


func _check(name: String, cond: bool) -> void:
	if cond:
		print("[pak] PASS  %s" % name)
	else:
		_fail += 1
		print("[pak] FAIL  %s" % name)


## A cartridge that can send a client its program carries a SECOND complete GBA
## header: the 4-byte branch and the 156-byte Nintendo logo the BIOS verifies,
## exactly as at the start of the file. Checked rather than assumed, because a
## game without one can only refuse, and a refusal is not a broken link.
func _carries_a_payload(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var data := f.get_buffer(f.get_length())
	f.close()
	if data.size() < 0xC0:
		return false
	var logo := data.slice(4, 4 + 156)
	var found := 0
	var at := 0
	while true:
		var i: int = _find_bytes(data, logo, at)
		if i < 0:
			break
		found += 1
		if found > 1:
			print("[pak] rom carries a sendable image at 0x%08X" % (i - 4))
			return true
		at = i + 1
	return false


func _find_bytes(hay: PackedByteArray, needle: PackedByteArray, from: int) -> int:
	var limit: int = hay.size() - needle.size()
	var i := from
	while i <= limit:
		if hay[i] == needle[0] and hay.slice(i, i + needle.size()) == needle:
			return i
		i += 1
	return -1


func _wait(n: int) -> void:
	var targets: Array[int] = []
	for machine: Libretro in _all:
		targets.append(machine.GetFrameCount() + n)
	var deadline: int = Time.get_ticks_msec() + 30000
	while Time.get_ticks_msec() < deadline:
		var done := true
		for i in _all.size():
			if _all[i].GetFrameCount() < targets[i]:
				done = false
		if done:
			return
		await get_tree().process_frame


func _hold(mask: int, press: int, gap: int, who: Array) -> void:
	for machine: Libretro in who:
		machine.SetJoypadState(0, mask, 0, 0, 0, 0)
	await _wait(press)
	for machine: Libretro in who:
		machine.SetJoypadState(0, 0, 0, 0, 0, 0)
	await _wait(gap)


func _shot(tag: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))
	for i in _all.size():
		var img: Image = _all[i].GetVideoImage()
		if img != null and not img.is_empty():
			img.save_png("res://probe_out/pak_%s_%s.png" % [
				tag, "host" if i == 0 else "client%d" % i])


func _find_rom() -> String:
	var roots: PackedStringArray = [RomLibrary.default_roms_root()]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--roms="):
			roots.append(arg.substr(7))
	for root in roots:
		for systemid in ["game_boy_advance", "gba"]:
			var dir_path: String = root.path_join(systemid)
			var dir := DirAccess.open(dir_path)
			if dir == null:
				continue
			for f in dir.get_files():
				var lower := f.to_lower()
				if lower.ends_with(".gba") and lower.contains("super mario advance") \
						and not lower.contains("advance 2") and not lower.contains("advance 3") \
						and not lower.contains("advance 4") and not lower.contains("demo"):
					return dir_path.path_join(f)
	return ""


func _pin_options(root: String) -> bool:
	_opt_path = "%s/core_options/%s.opt" % [root, CORE]
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
