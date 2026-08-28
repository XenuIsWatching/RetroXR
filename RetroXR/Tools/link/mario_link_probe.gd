## Two GBAs on one cable, playing Mario Bros. together.
##
##     "$godot" --headless --path RetroXR res://Tools/link/mario_link_probe.tscn -- --roms=Z:/roms
##
## The probe that asks the question the others cannot: does a real game actually
## play over this link, or does the cable merely negotiate?
##
## Super Mario Advance is the ROM for it. It carries the Mario Bros. arcade game
## alongside Super Mario Bros. 2, and that mode is a two-to-four player link game.
## Point --roms at a library holding a copy; nothing is bundled.
##
## Reaching the mode needs input, so this presses through the intro, the menu and
## the lobby rather than sitting at the title. That makes it fragile in a way a
## test may not be: a different revision puts a cursor somewhere else and the run
## proves nothing, which is why it lives here rather than in Tests/. What it does
## assert is the shape of a session that is genuinely running, and both halves of
## that matter:
##
##   RATE  -- a GBA multiplayer game in play clocks about nine transfers per
##            frame, not one. One a frame is the IDLE rate, the pairing poll, and
##            a run that stops there has negotiated a cable and played nothing.
##   SPEED -- and both machines still run at 60 fps while doing it. The bus
##            rendezvouses the two emulation threads tens of thousands of times a
##            second, so a link that carried the traffic by halving the framerate
##            would satisfy the first number and be worthless.
##
## The GAME is what proves it. Two cores at the right transfer rate could still be
## trading rubbish, so the run also saves both screens: at PHASE 1 they show the
## same level with P1 marked on one machine and P2 on the other.
extends Node

const CORE := "mgba"
## Core options this probe pins, and what it pins them to.
##
## The link one is the point of the exercise. The BIOS one is here because this
## probe reaches Mario Bros. by pressing buttons at counted frames, and the BIOS
## start-up animation is about two seconds of them: whether it plays depends on
## the player's own settings, so leaving it alone made the run depend on what
## somebody last changed in a menu. It did not fail loudly either. The title
## press landed mid-fade, the cursor never came off Single Player, and the result
## read as a link carrying nothing.
##
## The VALUE, not the label the menu prints beside it. Writing "enabled" put a
## string these options do not offer into the file: the core read it, matched
## nothing, and left the link driver uninstalled, so the probe was exercising a
## configuration no player can produce and passed while the room failed.
const PINNED := {
	"mgba_link_cable": "ON",
	"mgba_skip_bios": "ON",
}

## A GBA cartridge's save, as Super Mario Advance sizes it.
const SRAM_BYTES := 512

const BTN_A := 1 << 8
const BTN_START := 1 << 3
const BTN_DOWN := 1 << 5
const BTN_RIGHT := 1 << 7
const BTN_LEFT := 1 << 6

var _opt_path := ""
var _opt_backup := ""
var _restored := false
## Every machine on the cable, in bus order. The first owns the clock.
var _m: Array[Libretro] = []
## The two the menu navigation talks about: the machine that calls, and one that
## answers. With more than two players every machine after the first answers, and
## the guest-facing steps run over all of them.
var _a: Libretro = null
var _b: Libretro = null
var _wall_prev := 0
var _frames_prev: Array[int] = []
var _filming := false
## Set by --order=cable-first-renumber: move every machine's seat mid-play.
var _renumber := false
## Set by --order=cable-first-regroup: the control. Re-declare the SAME bus with
## the SAME anchor, so the seats do not move and only the re-declaration is
## tested. Tells a renumber apart from a bus rebuild.
var _regroup := false
## WHEN the seats move: "play" (default) mid-match, or "lobby" at the pairing
## screen. The distinction is the whole question. A game in a running match
## cannot be handed a new player number -- no cable can do that to real hardware
## either, since re-chaining means unplugging -- so a stall there proves nothing
## about whether the machine is broken. A game sitting on its pairing screen is
## polling by design, and if it picks the renumber up from there then a seat
## change costs a player the walk back to that screen and nothing more, which is
## what decides whether the room still has to power-cycle anybody.
var _reseat_at := "play"
## Frames to sit and WATCH after the seats move, before the run carries on.
##
## A console reset is not what hardware does when a link changes under it. GBATEK
## has the roles as physical and live -- SIOCNT bit 2 is the SI terminal, "0=
## Parent, 1=Child", and the master's SI is always low -- and the ID bits are "
## undefined until the first transfer has completed", so they are a RESULT of
## each transfer rather than a setting. Games are expected to cope: the homebrew
## LinkCable library carries a timeout, "maximum number of frames without
## receiving data from other player before marking them as disconnected or
## resetting the connection", and 0xFFFF is the reserved value for a client that
## is not there.
##
## So a renumbered party should be expected to notice and re-establish IN ITS OWN
## TIME, and the first measurement of this watched only 600 frames, which is ten
## seconds and no evidence at all about a timeout longer than that. This is the
## knob that tells a game that has hung apart from a game that has not been given
## long enough.
var _reseat_settle := 0
var _film_frame := 0


func _ready() -> void:
	get_tree().create_timer(300.0).timeout.connect(func() -> void:
		print("[mario] TIMEOUT")
		_restore()
		get_tree().quit(1))
	await _run()


func _run() -> void:
	var rom := _find_rom()
	if rom.is_empty():
		print("[mario] SKIP  no Super Mario Advance ROM found")
		print("[mario]       looked for a .gba whose name contains 'super mario advance'")
		get_tree().quit(0)
		return
	print("[mario] rom  %s" % rom)

	_filming = "--film" in _args()

	var root := CoreDownloadManager.default_core_root()
	if not _enable_link_option(root):
		print("[mario] SKIP  could not write the core options file")
		get_tree().quit(0)
		return

	# Two by default, up to the four a GBA link cable carries.
	var players := 2
	for arg in _args():
		if arg.begins_with("--players="):
			players = clampi(int(arg.substr(10)), 2, 4)
	for i in range(players):
		var machine := Libretro.new()
		add_child(machine)
		_m.append(machine)
	_a = _m[0]
	_b = _m[1]
	print("[mario] players=%d" % players)

	# Boot both machines from an ERASED cartridge, and never write one back.
	#
	# Without this the probe is not repeatable, and it failed silently rather
	# than loudly: the game writes a save, the save changes how it boots, and a
	# run that navigates the menu by pressing buttons at counted frames walks
	# into a different screen than the one it was written against. After enough
	# runs the title press landed mid-fade and the cursor never moved off Single
	# Player, which reads exactly like a link that carries nothing.
	#
	# 0xFF because that is what unwritten cartridge SRAM reads as; zeroes are a
	# save file full of zeroes, which is not the same thing. The path is pointed
	# at a scratch file as well, so a run cannot flush over the player's own save.
	var blank := PackedByteArray()
	blank.resize(SRAM_BYTES)
	blank.fill(0xFF)
	var scratch := OS.get_cache_dir().path_join("retroxr_mario_link_probe")
	DirAccess.make_dir_recursive_absolute(scratch)
	for i in _m.size():
		_m[i].SetSramPath(scratch.path_join("probe_%d.srm" % i))
		_m[i].SetSramData(blank)

	# Deliberately NOT calling SetInputEnabled. That flag lets a wrapper poll the
	# global Godot Input singleton, and it OVERWRITES the joypad every frame, so
	# turning it on throws away everything SetJoypadState puts there. Off is what
	# a probe wants: the state it sets is the state the core sees.

	# Cable first, then switch the machines on one at a time.
	#
	# This is the order a room produces and it is the harder one, so it is the
	# one that gets tested. A saved room restores its leads before anything is
	# powered up, and a player switches two handhelds on one after the other, so
	# the cable's membership changes UNDER a core that is already running and
	# already driving its serial port. Starting both machines in the same frame
	# with the lead already seated hides a whole class of fault, because then the
	# count is settled before the guest ever looks at it.
	var order := "cable-first"
	var power_order := "forward"
	var power_gap := 90
	for arg in _args():
		if arg.begins_with("--order="):
			order = arg.substr(8)
		if arg.begins_with("--power-order="):
			power_order = arg.substr(14)
		if arg.begins_with("--power-gap="):
			power_gap = maxi(1, int(arg.substr(12)))
	_renumber = order == "cable-first-renumber"
	_regroup = order == "cable-first-regroup"
	for arg in _args():
		if arg.begins_with("--reseat-at="):
			_reseat_at = arg.substr(12)
		if arg.begins_with("--reseat-settle="):
			_reseat_settle = int(arg.substr(16))
	for i in range(20):
		await get_tree().process_frame

	var joined := false
	match order:
		"cable-first", "cable-first-renumber", "cable-first-regroup":
			# A saved room restores its leads before anything is powered up, then
			# the player switches two handhelds on one after the other.
			joined = _cable()
			var started := await _start_in_order(root, rom, power_order, power_gap)
			# The machines that booted before the last one arrived cached "nobody
			# there". That membership change is what LinkCable restarts on, and
			# LinkConnect is the raw call below the room, so the probe does it.
			await _wait_frames(30)
			for machine: Libretro in started.slice(0, started.size() - 1):
				machine.RequestReset()
			await _wait_frames(30)
		"cable-last":
			# Both running, then the lead goes in. What a player does by hand.
			#
			# Without the restart this order carries exactly zero transfers. A GBA
			# reads whether anything is on the other end once, while it boots, and
			# never asks again.
			await _start_in_order(root, rom, power_order, power_gap)
			await _wait_frames(200)
			joined = _cable()
			for machine: Libretro in _m:
				machine.RequestReset()
			await _wait_frames(30)
		"cable-last-raw":
			# Both running, then the lead goes in, and NOBODY is reset. The room
			# throws a machine back to its boot logo when it gains a cable it
			# booted without, and this is the case that says whether it still has
			# to: if a game can pick a link up mid-session, that restart is a run
			# thrown away for nothing.
			await _start_in_order(root, rom, power_order, power_gap)
			await _wait_frames(200)
			joined = _cable()
			await _wait_frames(30)
		"cable-first-raw":
			# The lead in first and the machines switched on one at a time, which
			# is what a restored room does, with no restart either.
			joined = _cable()
			await _start_in_order(root, rom, power_order, power_gap)
			await _wait_frames(30)
		"cable-last-reset":
			# Both running, then the lead goes in, then both are reset. On real
			# hardware you power-cycle a pair you cabled up after the fact, and
			# this asks whether a reset is genuinely all it takes.
			await _start_in_order(root, rom, power_order, power_gap)
			await _wait_frames(200)
			joined = _cable()
			await _wait_frames(30)
			for machine: Libretro in _m:
				machine.RequestReset()
			await _wait_frames(30)
		_:
			# Both switched on in the same frame with the lead already seated.
			for machine: Libretro in _m:
				machine.StartContent(root, CORE, rom)
			joined = _cable()
	print("[mario] order=%s power=%s gap=%d cabled=%s" % [order, power_order, power_gap, str(joined)])
	_wall_prev = Time.get_ticks_msec()

	# Through the logo, then interrupt the attract demo.
	#
	# The menu does NOT wait for anyone. Boot runs logo, fade, and straight into
	# a Super Mario 2 demo; Start interrupts that and brings up the title with
	# Single Player / Multiplayer on it. Every earlier attempt pressed into the
	# demo and read the result as a menu refusing input.
	#
	# Counted in EMULATED frames rather than process frames. Headless Godot has
	# no vsync, so its loop free-runs while a core paces itself to 60 Hz, and the
	# two counts drift apart by a factor of three or more. A menu press timed in
	# process frames is therefore timed in nothing at all: the same code waits a
	# different number of game frames on every run and on every machine.
	await _wait_frames(240)
	_shot("a_demo")

	# Start interrupts the attract demo and raises the title; the game does not
	# wait on its menu. Then Down to Multiplayer and A to take it, which is the
	# route confirmed by hand.
	await _hold(BTN_START, 6, 40)
	_shot("b_title")
	await _hold(BTN_DOWN, 6, 20)
	_shot("c_multiplayer")
	# The master takes Multiplayer first and starts calling.
	await _hold(BTN_A, 6, 60, [_a])
	_shot("d_master_calling")
	# Then the guests answer, one at a time and a beat apart, as people would.
	for guest: Libretro in _guests():
		await _hold(BTN_A, 6, 60, [guest])
	_shot("d_guest_joining")

	# CHECKING. The two machines trade one word a frame while the game looks for
	# a partner, and it takes several hundred frames before it believes in one.
	# Watch the counter rather than guessing a duration.
	var quiet := 0
	var last_sent: int = _a.LinkSent(0)
	for step in range(40):
		await _wait_frames(30)
		var now_sent: int = _a.LinkSent(0)
		if now_sent == last_sent:
			quiet += 1
		else:
			quiet = 0
		last_sent = now_sent
		_report("check%02d" % step)
		# A confirm can land while the screen is mid-transition and be dropped.
		# Offering it again costs nothing on a machine that has already moved on.
		if step == 3 or step == 8 or step == 15:
			for guest: Libretro in _guests():
				await _hold(BTN_A, 6, 20, [guest])
		# Traffic stopping is the signal the handshake has SETTLED, one way or
		# the other; sitting through the rest of the loop after that only wastes
		# the run.
		if quiet >= 3 and step >= 4:
			break
	_shot("e_lobby")
	if "--lobby-only" in _args():
		_report("lobby")
		for machine: Libretro in _m:
			machine.StopContent()
		await _wait_process_frames(30)
		_restore()
		get_tree().quit(0)
		return

	# Both machines are paired and sitting on the lobby, which is the screen a game
	# polls the cable from. Moving the seats HERE is the case the room actually
	# produces -- machines are cabled up during setup, not mid-match.
	if (_renumber or _regroup) and _reseat_at == "lobby":
		await _reseat(_m[1] if _renumber else _m[0])

	# Both players are on the lobby now. Start takes the master through to the
	# Mario Bros. mode screen, where Classic or Battle is chosen, and A takes it.
	#
	# The link goes quiet between the lobby and the mode screen, which is why the
	# run keeps going rather than stopping at the first silence: pairing and
	# playing are separate conversations, and the second one has not been asked
	# for yet at the point the first ends.
	await _hold(BTN_START, 6, 90)
	_shot("f_after_start")
	_report("started")
	await _hold(BTN_A, 6, 90)
	_shot("g_after_mode")
	_report("mode")
	await _hold(BTN_A, 6, 90)
	_shot("h_after_mode2")
	_report("mode2")
	await _hold(BTN_START, 6, 90)
	_shot("i_after_start2")
	_report("start2")

	# From here on the game is in play, and everything measured at the end is
	# measured over this window alone. Counting from boot would fold in the long
	# idle poll of the pairing screens and bury the rate that matters.
	var play_sent: int = _a.LinkSent(0)
	var play_frames: int = _a.GetFrameCount()
	var play_wall: int = Time.get_ticks_msec()
	# Drive ONE player at a time, and only on its own machine.
	#
	# This is the part that cannot be faked. Machine A's joypad reaches machine
	# A's core and nothing else; the only way its Mario can appear to move on
	# machine B's screen is if the position crossed the cable. Standing still
	# proves nothing, because two cores running the same ROM from the same reset
	# will draw the same level whether or not a wire connects them.
	var script: Array[Array] = []
	for i in _m.size():
		script.append([_m[i], BTN_RIGHT, "p%d_right" % (i + 1)])
		script.append([_m[i], BTN_LEFT | BTN_A, "p%d_left_jump" % (i + 1)])
	script.append([null, 0, "idle"])
	for step in range(script.size()):
		# Move everyone's seat, once, on a session that is already trading.
		#
		# This is the half of LinkCable._restart that nothing had ever measured.
		# Two cabled pairs merging into one wider bus renumbers machines that are
		# mid-game -- a session log shows a machine that was player one becoming
		# player three -- and the room's answer is to power-cycle them. Whether it
		# still has to is the question, so this does the renumber and resets
		# NOBODY, and the per-step sent counts below say whether the link
		# survived it.
		if (_renumber or _regroup) and _reseat_at == "play" and step == 2:
			await _reseat(_m[1] if _renumber else _m[0])
		var machine: Libretro = script[step][0]
		var mask: int = script[step][1]
		if machine != null:
			machine.SetJoypadState(0, mask, 0, 0, 0, 0)
		if _filming:
			await _film(120)
		else:
			await _wait_frames(120)
		if machine != null:
			machine.SetJoypadState(0, 0, 0, 0, 0, 0)
		_shot("j_watch%d" % step)
		_report("watch%d %s" % [step, script[step][2]])

	# The master sends two messages per transfer, a start and its own word, and
	# the bus counts a broadcast once per RECIPIENT rather than once per call --
	# it counts where a message is queued, not where it is attempted. So the
	# divisor grows with the party, and reading it as two flattered a four-player
	# session into claiming 27 transfers a frame when it was doing nine.
	#
	# Measured over the watch loop alone, the only stretch where a game is
	# actually being played.
	var per_transfer: float = 2.0 * float(_m.size() - 1)
	var transfers: float = (_a.LinkSent(0) - play_sent) / per_transfer
	var frames: float = maxf(1.0, _a.GetFrameCount() - play_frames)
	var per_frame: float = transfers / frames
	var fps: float = frames / maxf(0.001, (Time.get_ticks_msec() - play_wall) / 1000.0)

	print("[mario] ---- %d transfers over %d frames: %.1f per frame, %.1f fps ----" % [
		int(transfers), int(frames), per_frame, fps])

	var failures: PackedStringArray = []
	# Checked first, because it explains every other number at once. A peer count
	# of zero on a cabled machine means its CORE never joined the bus, which is
	# the link core option not having taken -- and that reads downstream as a
	# transfer rate of zero, which says nothing about why.
	var counts: PackedInt32Array = []
	for machine: Libretro in _m:
		counts.append(machine.LinkPeerCount(0))
	if counts.has(0):
		failures.append("a machine reports no peers, so its core never joined the bus:"
			+ " check mgba_link_cable is ON in %s" % _opt_path)
	if per_frame < 5.0:
		failures.append("only %.1f transfers per frame; a session in play runs about 9, one a frame is the idle poll" % per_frame)
	if fps < 50.0:
		failures.append("machines ran at %.1f fps; the link is being paid for in emulation speed" % fps)
	for c in counts:
		if c != _m.size():
			failures.append("cable reports %s peers for %d machines" % [str(counts), _m.size()])
			break

	for f in failures:
		print("[mario] FAIL  %s" % f)
	if failures.is_empty():
		print("[mario] RESULT=PLAYING  %d cores are running a link game over one cable" % _m.size())
	else:
		print("[mario] RESULT=FAILED")

	for machine: Libretro in _m:
		machine.StopContent()
	for i in range(120):
		await get_tree().process_frame
	_restore()
	get_tree().quit(0 if failures.is_empty() else 1)


## Put every machine on one wire.
##
## LinkConnectGroup rather than LinkConnect, because a link cable CHAINS: the
## third and fourth players join through the junction moulded into the lead, and
## what the bus is told is the whole set that ends up sharing the wire. A pair is
## just the smallest case of that, so both go through the same call and the
## two-player path is not a separate thing that could rot on its own.
func _cable() -> bool:
	var others: Array = []
	var ports := PackedInt32Array()
	ports.append(0)
	for k in range(1, _m.size()):
		others.append(_m[k])
		ports.append(0)
	return _m[0].LinkConnectGroup(others, ports)


## Power the handhelds one at a time so attachment order is a controlled part
## of the test instead of three racing emulation threads.
func _start_in_order(root: String, rom: String, order: String, gap: int) -> Array[Libretro]:
	var indices: Array[int] = []
	match order:
		"reverse":
			for i in range(_m.size() - 1, -1, -1):
				indices.append(i)
		"outside-in":
			for i in [0, _m.size() - 1, 1, _m.size() - 2]:
				if i >= 0 and i < _m.size() and not indices.has(i):
					indices.append(i)
		_:
			for i in _m.size():
				indices.append(i)
	var started: Array[Libretro] = []
	for index in indices:
		var machine: Libretro = _m[index]
		machine.StartContent(root, CORE, rom)
		started.append(machine)
		var target := machine.GetFrameCount() + gap
		while machine.GetFrameCount() < target:
			await get_tree().process_frame
	return started


## Every machine except the one that owns the clock.
func _guests() -> Array:
	return _m.slice(1)


## Hand every machine a different seat, with no reset anywhere.
##
## Anchored on machine 1 rather than machine 0, because LinkConnectGroup makes
## the CALLER seat zero: re-declaring the same set from a different anchor moves
## every machine's player number and takes the clock away from whoever had it,
## which is exactly what a merge does to the pair that was already playing.
##
## The membership is deliberately unchanged. A machine appearing or disappearing
## would also change the transfer length and the peer count, and then a stall
## could be blamed on either; this moves the seats and nothing else.
##
## READ THE PER-MACHINE COUNTS, NOT THE SUMMARY, in this mode. The summary
## divides _a's sent count by the rate a MASTER sends at, two messages per
## transfer against a slave's one -- and the whole point here is that _a stops
## being the master half way through. A perfectly healthy link therefore reports
## about half its real rate and fails the run, which is a false negative, not a
## finding. The true rate is (both machines' deltas) / 3 for a pair.
func _reseat(anchor: Libretro) -> void:
	var others: Array = []
	var ports := PackedInt32Array()
	ports.append(0)
	for k in range(_m.size()):
		if _m[k] != anchor:
			others.append(_m[k])
			ports.append(0)
	var before: int = _a.LinkSent(0)
	var ok: bool = anchor.LinkConnectGroup(others, ports)
	print("[mario] RESEAT  group=%s  anchor=m%d  nobody reset  (sent so far %d)" % [str(ok), _m.find(anchor), before])
	if _reseat_settle <= 0:
		return
	# Sit and watch. Reported in slices so a recovery that takes twenty seconds is
	# visible as the moment it happens rather than as one number at the end.
	var slice := 300
	var waited := 0
	while waited < _reseat_settle:
		await _wait_frames(mini(slice, _reseat_settle - waited))
		waited += slice
		var counts := PackedStringArray()
		for k in _m.size():
			counts.append(str(_m[k].LinkSent(0)))
		print("[mario] SETTLE +%d frames  sent=%s" % [waited, "/".join(counts)])


## Wait for a number of EMULATED frames on the slowest machine.
##
## The distinction matters more than it looks. A headless run has no vsync, so
## get_tree().process_frame comes round several times per emulated frame, and a
## menu press counted in process frames lands for a fraction of a game frame or
## for ten of them depending on how loaded the box is. Counted here, a press is
## the same length every time.
func _wait_frames(n: int) -> void:
	var targets: Array[int] = []
	for machine: Libretro in _m:
		targets.append(machine.GetFrameCount() + n)
	while true:
		var done := true
		for i in _m.size():
			if _m[i].GetFrameCount() < targets[i]:
				done = false
		if done:
			return
		await get_tree().process_frame


func _wait_process_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


## Save both screens every emulated frame, for encoding into a side-by-side clip.
##
## A still cannot show a link game working. Two machines can agree on a level and
## still be running two separate games in it, and the only thing that tells them
## apart is whether one player's Mario moves on the other player's screen.
func _film(n: int) -> void:
	var dir := "res://probe_out/film"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(dir))
	var target_a: int = _a.GetFrameCount() + n
	while _a.GetFrameCount() < target_a:
		await get_tree().process_frame
		var ia: Image = _a.GetVideoImage()
		var ib: Image = _b.GetVideoImage()
		if ia == null or ib == null or ia.is_empty() or ib.is_empty():
			continue
		ia.save_png("%s/%05d_a.png" % [dir, _film_frame])
		ib.save_png("%s/%05d_b.png" % [dir, _film_frame])
		_film_frame += 1


## One line of everything worth knowing: link traffic, and how fast each machine
## is actually running.
##
## Emulated speed belongs next to the traffic count because a link that looks
## slow may only be a core running slow. The barrier this rests on rendezvouses
## the two threads tens of thousands of times a second, and if that is what is
## costing the frames then a transfer rate says nothing about the game at all.
func _report(tag: String) -> void:
	var wall: int = Time.get_ticks_msec()
	var secs: float = max(1, wall - _wall_prev) / 1000.0
	var sent: PackedStringArray = []
	var peers: PackedStringArray = []
	var fps: PackedStringArray = []
	for i in _m.size():
		sent.append(str(_m[i].LinkSent(0)))
		peers.append(str(_m[i].LinkPeerCount(0)))
		var now: int = _m[i].GetFrameCount()
		fps.append("%.1f" % ((now - (_frames_prev[i] if i < _frames_prev.size() else 0)) / secs))
	print("[mario] %-9s sent=%s  peers=%s  fps=%s" % [
		tag, "/".join(sent), "/".join(peers), "/".join(fps)])
	_wall_prev = wall
	_frames_prev.clear()
	for machine: Libretro in _m:
		_frames_prev.append(machine.GetFrameCount())


## Save what machine A is showing, so a run that goes wrong can be LOOKED at.
##
## Blind button pressing through a menu is guesswork, and a probe that reports
## silence without showing where it got stuck is not evidence of anything.
func _shot(tag: String) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://probe_out"))
	# BOTH machines. Only ever photographing the master hid the whole first half
	# of the story: the two screens diverge for most of the handshake, and which
	# of them is stuck is the question being asked.
	for i in _m.size():
		var img: Image = _m[i].GetVideoImage()
		if img == null or img.is_empty():
			print("[mario] shot %s/%d: no frame yet" % [tag, i])
			continue
		img.save_png("res://probe_out/mario_%s_%s.png" % [tag, char(97 + i)])
	print("[mario] shot %s" % tag)


## Press a button on both machines, then let go, then wait.
## Press a button, then let go, then wait.
##
## `who` picks the machines: both by default, or one of them. Pressing both at
## once is not what two people do and not what the game expects. The parent goes
## into multiplayer first and starts calling, and the second machine joins a call
## that is already in progress; pressed together, the master reaches CHECKING and
## the other one is still on its own title screen refusing to move, which reads
## exactly like a link that never negotiated.
func _hold(mask: int, press_frames: int, gap_frames: int, who: Array = []) -> void:
	var machines: Array = who if not who.is_empty() else _m
	for machine: Libretro in machines:
		machine.SetJoypadState(0, mask, 0, 0, 0, 0)
	await _wait_frames(press_frames)
	for machine: Libretro in machines:
		machine.SetJoypadState(0, 0, 0, 0, 0, 0)
	await _wait_frames(gap_frames)


## Arguments, from the command line and from a cfg file beside it.
##
## The Quest has no command line, so an on-device run takes its arguments the way
## netplay_spike does: one per line in a cfg the harness drops in first. Read from
## /sdcard as well as user://, because that is the path adb can write without
## run-as, and deleted on sight so a crash mid-run cannot wedge the app into the
## probe on the next launch.
##
## Cached, because this is asked several times and the read has a side effect.
var _cli: PackedStringArray = []
var _cli_read := false

const EXTERNAL_CFG := "/sdcard/Android/data/com.xenu.retroxr/files/marioprobe.cfg"


func _args() -> PackedStringArray:
	if _cli_read:
		return _cli
	_cli_read = true
	_cli = OS.get_cmdline_user_args()
	for path in ["user://marioprobe.cfg", EXTERNAL_CFG]:
		if not FileAccess.file_exists(path):
			continue
		var f := FileAccess.open(path, FileAccess.READ)
		if f != null:
			while not f.eof_reached():
				var line := f.get_line().strip_edges()
				if not line.is_empty():
					_cli.append(line)
			f.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	return _cli


func _find_rom() -> String:
	var roots: PackedStringArray = [RomLibrary.default_roms_root()]
	# The bulk library lives off the project, so take it from the command line
	# rather than guessing a drive letter.
	for arg in _args():
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


func _enable_link_option(root: String) -> bool:
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
	# "ON", the option's own VALUE, not "enabled", which is only the label the
	# menu prints beside it. Writing the label put a string the option does not
	# offer into the file: the core read it, matched nothing, and left the link
	# driver uninstalled -- so a probe that wrote it was exercising a
	# configuration no player can produce, and passed while the room failed.
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
		print("[mario] restored %s" % _opt_path)
