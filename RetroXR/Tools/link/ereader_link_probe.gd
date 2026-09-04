## A dotcode card scanned in one machine, reaching the game in another.
##
##     "$godot" --path RetroXR --resolution 320x240 --position 20,20 \
##         res://Tools/link/ereader_link_probe.tscn -- --roms=Z:/roms/gba
##     "$godot" --headless --path RetroXR res://Tools/link/ereader_link_probe.tscn -- \
##         --roms=Z:/roms/gba --no-cable
##
## Wants two real cores, two real ROMs and a real card, so it is a probe rather
## than a suite. The pairing is Super Mario Advance 4 and one of its level
## cards, which is the case the hardware was sold on: the card holds a level,
## the reader cannot play it, and the cable is the only route it can take. A
## card that runs standalone -- Air Hockey-e, the NES ports -- proves nothing
## here, because it would light the screen up with the lead unplugged.
##
## THE READER MUST BE A + UNIT. The original Card e-Reader (PEAJ) has no link
## port, so a run against ereader.gba is not a failed link but a machine with
## nowhere to plug the lead in. Cards are region locked as well: a PSAE reader
## (ereader_usa.gba) wants the US half of the set, a PSAJ one
## (ereader_plus.gba) the Japanese half.
##
## WHAT THE RUN HAS TO SHOW
##
## The PASS lines are a transport check only -- cabled, both machines see two
## peers and the bus carries traffic; --no-cable sees none and is silent. A real
## level card additionally lands 999 words, a checksum matching the one sent
## (01F39C3C for Classic World 1-1), the FCFC terminator, and F5F5 back from the
## game meaning receive OK.
##
## THE ROUTE, WHICH IS NOT GUESSABLE
##
##   game    Level Card is a fourth entry on the SAVE FILE screen, not a mode.
##           Three DOWN past the files, A into World-e, two RIGHT along the map
##           to the blue panel, A for the card list, A again to ask for the
##           reader. It then LISTENS BRIEFLY and re-prompts, so its OK is
##           pressed repeatedly across the reader's attempt rather than once.
##   reader  Communication -> To Game Boy Advance -> "Connect the e-Reader ...
##           press A when finished" -> Connecting.
##
## Two options are load-bearing and neither is tuning:
##
##   --hold=4    these menus auto-repeat, so a twelve-frame hold is TWO cursor
##               moves. On the reader's two-row menu that is Scan Card ->
##               Communication -> Scan Card, landing back where it started and
##               looking exactly like a press that never registered.
##   --game-head selfId comes from the head of LinkConnectGroup, not from which
##               machine was switched on first, and the multiplayer driver
##               refuses a transfer from anyone but id 0. The reader is the half
##               that waits to receive, so with the reader as head nobody ever
##               drives: ~100 messages and a deadlock, against 16340+ with the
##               game as head.
##
## What crosses first is Super Mario Advance 4's OWN scanner program -- that is
## what "Load application from Game Boy Advance" means. The reader stops being
## an e-Reader and runs a Super Mario Bros 3 screen headed Level Card, which is
## what then asks for the dotcode.
##
## Filming: --film-every=8 or finer when asking why something did NOT happen,
## and diff neighbouring frames rather than reading a handful of stills. A
## banner that is up for a moment sits between two coarse samples.
extends Node

## The FORK build, which is the only one carrying ereader_disk.c. The stock
## mgba_libretro publishes no disk control for any cartridge, so a run against it
## reports has=false and never queues a card -- which looks exactly like an
## e-Reader that refused one.
const CORE_DEFAULT := "mgba_ereader"
const PINNED := {
	"mgba_link_cable": "ON",
	"mgba_skip_bios": "OFF",
	"mgba_use_bios": "ON",
}

const BUTTONS := {
	"b": 1 << 0, "select": 1 << 2, "start": 1 << 3,
	"up": 1 << 4, "down": 1 << 5, "left": 1 << 6, "right": 1 << 7,
	"a": 1 << 8, "l": 1 << 10, "r": 1 << 11,
}

## The route to Super Mario Advance 4's Level Card screen, which is the receiving
## end of the transfer. Written as
## "<seconds>:<button>[:<taps>[:<hold frames>]]", scheduled on the machine's own
## frames.
##
##   attract -> title -> Select a File
##   three DOWN to Level Card (past File 1..3), A to enter World-e
##   two RIGHT along the map to the blue panel, A to open the card list
##   A again on the list, which is what asks for the e-Reader
##
## It ends on "Preparing to communicate with the Nintendo e-Reader / Now ready to
## communicate", so the RECEIVING half of the transfer is reached and waiting.
##
## Each leg was found by screenshot and none of it is guessable: the file screen
## carries Level Card as a fourth "file" rather than as a mode, and the map walk
## is two squares, not one.
const READER_ROUTE := "20:a:1,106:down:1,114:a:1,124:down:1,132:a:1,144:a:1,195:a:1,215:a:1,235:a:1"
const GAME_ROUTE := "18:start:1,26:start:1,34:start:1,42:start:1,49:a:1,60:down:1:10,63:down:1:10,66:down:1:10,70:a:1:10,82:right:1:20,90:right:1:20,105:a:3:8,138:a:3:8,145:a:3:8,152:a:3:8,159:a:3:8,166:a:3:8,173:a:3:8,180:a:3:8,187:a:3:8,194:a:3:8,201:a:3:8,208:a:3:8,215:a:3:8,222:a:3:8,229:a:3:8,236:a:3:8,243:a:3:8,250:a:3:8,257:a:3:8,264:a:3:8,271:a:3:8,278:a:3:8,285:a:3:8,292:a:3:8,299:a:3:8,306:a:3:8,313:a:3:8,320:a:3:8,327:a:3:8,334:a:3:8,341:a:3:8,348:a:3:8,355:a:3:8,362:a:3:8,369:a:3:8,376:a:3:8,383:a:3:8,390:a:3:8,397:a:3:8,404:a:3:8,411:a:3:8,418:a:3:8,425:a:3:8,432:a:3:8,439:a:3:8,446:a:3:8,453:a:3:8,460:a:3:8,467:a:3:8,474:a:3:8,481:a:3:8,488:a:3:8,495:a:3:8,502:a:3:8,509:a:3:8,516:a:3:8,523:a:3:8,530:a:3:8,537:a:3:8,544:a:3:8,551:a:3:8,558:a:3:8,565:a:3:8,572:a:3:8,579:a:3:8,586:a:3:8,593:a:3:8,600:a:3:8,607:a:3:8,614:a:3:8,621:a:3:8,628:a:3:8,635:a:3:8,642:a:3:8,649:a:3:8,656:a:3:8,663:a:3:8,670:a:3:8,677:a:3:8,684:a:3:8,691:a:3:8,698:a:3:8"

var _reader: Libretro = null
var _game: Libretro = null
var _core := CORE_DEFAULT
var _reader_rom := ""
var _game_rom := ""
var _card := ""
var _roms := "Z:/roms/gba"
var _cabled := true
var _seconds := 700.0
var _shot := ""
var _taps := 3
var _hold := 4
var _shot_every := 20.0
var _shot_from := 10.0
var _reader_keys := READER_ROUTE
var _game_keys := GAME_ROUTE
var _opt_path := ""
var _opt_backup := ""
var _restored := false
var _game_first := false
var _game_head := true
var _settle := 60
var _stagger := 0
var _sram := ""
var _film := ""
var _film_every := 6
var _film_next := 0
var _film_n := 0
var _queue_at := 152.0
var _queued := false
var _fail: Array[String] = []


func _ready() -> void:
	get_tree().create_timer(1200.0).timeout.connect(func() -> void:
		print("[erl] TIMEOUT")
		_restore()
		get_tree().quit(1))
	await _run()


func _run() -> void:
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--roms="):
			_roms = s.substr(7)
		elif s.begins_with("--card="):
			_card = s.substr(7)
		elif s.begins_with("--game="):
			_game_rom = s.substr(7)
		elif s.begins_with("--reader="):
			_reader_rom = s.substr(9)
		elif s.begins_with("--seconds="):
			_seconds = s.substr(10).to_float()
		elif s.begins_with("--shot="):
			_shot = s.substr(7)
		elif s.begins_with("--core="):
			_core = s.substr(7)
		elif s.begins_with("--reader-keys="):
			_reader_keys = s.substr(14)
		elif s.begins_with("--game-keys="):
			_game_keys = s.substr(12)
		elif s.begins_with("--queue-at="):
			_queue_at = s.substr(11).to_float()
		elif s.begins_with("--hold="):
			_hold = maxi(1, s.substr(7).to_int())
		elif s.begins_with("--taps="):
			_taps = s.substr(7).to_int()
		elif s.begins_with("--shot-every="):
			_shot_every = s.substr(13).to_float()
		elif s.begins_with("--shot-from="):
			_shot_from = s.substr(12).to_float()
		elif s.begins_with("--film="):
			_film = s.substr(7)
			DirAccess.make_dir_recursive_absolute(_film)
		elif s.begins_with("--film-every="):
			_film_every = s.substr(13).to_int()
		elif s.begins_with("--sram="):
			_sram = s.substr(7)
		elif s.begins_with("--stagger="):
			_stagger = s.substr(10).to_int()
		elif s == "--game-head":
			_game_head = true
		elif s == "--game-first":
			_game_first = true
		elif s.begins_with("--settle="):
			_settle = s.substr(9).to_int()
		elif s == "--no-cable":
			_cabled = false

	var root := CoreDownloadManager.default_core_root()
	var sysdir := root.path_join("system").path_join(_core)
	# The reader dumps were installed under the STOCK core's system dir, which is
	# not where the fork core's BIOS has to live. Two different directories, and
	# only the BIOS one is the core's own.
	if _reader_rom.is_empty():
		_reader_rom = sysdir.path_join("ereader_usa.gba")
		if not FileAccess.file_exists(_reader_rom):
			_reader_rom = root.path_join("system").path_join("mgba").path_join("ereader_usa.gba")
	if not FileAccess.file_exists(_reader_rom):
		print("[erl] SKIP  no reader ROM at %s" % _reader_rom)
		get_tree().quit(0)
		return
	if _game_rom.is_empty():
		_game_rom = _find_game()
	if _game_rom.is_empty():
		print("[erl] SKIP  no Super Mario Advance 4 ROM under %s" % _roms)
		get_tree().quit(0)
		return
	if _card.is_empty():
		_card = _find_card()
	if _card.is_empty():
		print("[erl] SKIP  no Super Mario Advance 4-e level card in the library")
		get_tree().quit(0)
		return
	if not FileAccess.file_exists(sysdir.path_join("gba_bios.bin")):
		print("[erl] SKIP  need gba_bios.bin in %s" % sysdir)
		get_tree().quit(0)
		return
	if not _pin_options(root):
		print("[erl] SKIP  could not write the core options file")
		get_tree().quit(0)
		return

	print("[erl] reader=%s" % _reader_rom.get_file())
	print("[erl] game=%s" % _game_rom.get_file())
	print("[erl] card=%s (%d bytes)" % [_card.get_file(), _size_of(_card)])
	print("[erl] cabled=%s" % str(_cabled))

	_reader = Libretro.new()
	add_child(_reader)
	_game = Libretro.new()
	add_child(_game)
	_reader.connect("disk_control_ready",
		func(h: bool, c: int, i: int, e: bool) -> void:
			print("[erl] reader disk has=%s images=%d index=%d ejected=%s" % [h, c, i, e]))

	# Cabled before either is switched on. Each machine reads whether anything is
	# out there while it boots and never asks again.
	if _cabled:
		# WHO IS HEAD OF THE GROUP IS WHO BECOMES PLAYER ONE.
		#
		# selfId is not the order machines are switched on -- that was tested and
		# changes nothing -- it is the order they are named to LinkConnectGroup,
		# and the head takes id 0. In multiplayer mode the driver refuses a
		# transfer from anyone but id 0, so the head is the only machine that can
		# ever drive the exchange. With the reader as head the reader is parent
		# and sits waiting to receive, while the game, which wants to poll, is
		# barred. --game-head swaps them.
		var ports := PackedInt32Array()
		ports.append(0)
		ports.append(0)
		var head: Libretro = _game if _game_head else _reader
		var others: Array = [_reader if _game_head else _game]
		print("[erl] head=%s joined=%s" % [
			"game" if _game_head else "reader", str(head.LinkConnectGroup(others, ports))])

	# WHICH MACHINE IS SWITCHED ON FIRST DECIDES WHETHER EITHER SEES THE OTHER.
	#
	# LinkConnectGroup names the bus, but a machine only JOINS it inside
	# StartContent, when its core loads. A GBA reads its port while it boots and
	# never asks again, so the machine powered on first boots into a bus with
	# nobody else on it -- and stays alone however many peers the frontend counts
	# afterwards. Powering the far machine on first, and letting it attach before
	# the near one boots, is the cable-then-power order off the back of the box.
	# Three orders, because which machine is switched on when decides what each
	# one believes about the port, and the two obvious orders are both wrong.
	#
	#   default    reader first. Its FIRST probe reads connected -> 0, because the
	#              far machine has not joined the bus yet -- the join happens
	#              inside StartContent, not in LinkConnectGroup.
	#   --game-first
	#              far machine first. The reader then boots with a peer already
	#              there and WEDGES ON THE BIOS LOGO, never reaching its ROM: a
	#              real GBA seeing a partner at power-on has somewhere else to be.
	#   --stagger=N
	#              reader first, far machine N reader-frames later. Late enough to
	#              clear the BIOS, early enough that the cartridge's own startup
	#              still finds a peer.
	# The reader's menu is a function of its FLASH, not only of its ROM: a save
	# restored here is a reader that has already scanned something, and the rows
	# it offers change accordingly.
	if not _sram.is_empty() and _reader.has_method("SetSramPath"):
		_reader.SetSramPath(_sram)
		print("[erl] reader sram=%s" % _sram.get_file())

	# ORDER DECIDES WHO MAY START A TRANSFER, not just what each machine believes
	# about the port. selfId is handed out by the order machines JOIN the bus, and
	# the multiplayer branch of the driver refuses a transfer from anyone but
	# selfId 0. Power the reader on first and it takes id 0 for ever, so the game
	# can never initiate however ready it is.
	if _game_first:
		_game.StartContent(root, _core, _game_rom)
		while int(_game.GetFrameCount()) < _settle:
			await get_tree().process_frame
		print("[erl] game up at %d frames, now powering the reader" % int(_game.GetFrameCount()))
		_reader.StartContent(root, _core, _reader_rom)
	elif _stagger > 0:
		_reader.StartContent(root, _core, _reader_rom)
		while int(_reader.GetFrameCount()) < _stagger:
			await get_tree().process_frame
		print("[erl] reader at %d frames, now powering the far machine" % int(_reader.GetFrameCount()))
		_game.StartContent(root, _core, _game_rom)
	else:
		_reader.StartContent(root, _core, _reader_rom)
		_game.StartContent(root, _core, _game_rom)

	await _drive()
	_report()


## Run both machines on one clock, but never press on both in the same window.
##
## The reader and the game have distinct roles here, so this is less brittle than
## two peers racing for a clock -- but a press still lands on one machine at a
## time, because a menu that moved under a script is the hardest fault to read
## back out of a screenshot.
func _drive() -> void:
	var t := 0.0
	var reader_route := _parse_route(_reader_keys)
	var game_route := _parse_route(_game_keys)
	var shot_at := _shot_from
	while t < _seconds:
		await get_tree().process_frame
		t += get_process_delta_time()
		_step(_reader, reader_route, int(_reader.GetFrameCount()))
		_step(_game, game_route, int(_game.GetFrameCount()))

		# The card goes in BEFORE the scan is asked for: QueueCard only queues,
		# and the hardware pulls one off when the software starts scanning. Ask
		# first and it scans an empty slot and errors whatever arrives after.
		# WHEN the card is queued is part of the test, not a detail. Queued at boot
		# it is scanned the moment the reader reaches its scan screen, which is a
		# minute before Super Mario Advance 4 asks to communicate -- and the reader
		# then says the code can only be used with that game and throws it away.
		if not _queued and int(_reader.GetFrameCount()) >= int(_queue_at * 60.0):
			_queued = true
			_reader.SetDiskEjectState(true)
			_reader.ReplaceDiskImage(0, _card)
			_reader.SetDiskEjectState(false)
			_reader.RequestDiskInfo()
			print("[erl] t=%4.1f card queued" % t)

		# Film both screens on the reader's clock, so the strip is even however
		# the wall clock behaves. Watching the run back is the only way to see a
		# menu that moved and returned between two stills, which is how several
		# screens here were misread as machines that never budged.
		if not _film.is_empty():
			var rf := int(_reader.GetFrameCount())
			if rf >= _film_next:
				_film_next = rf + _film_every
				_save(_reader, "%s/r_%05d.png" % [_film, _film_n])
				_save(_game, "%s/g_%05d.png" % [_film, _film_n])
				_film_n += 1

		if t >= shot_at:
			_sample(t)
			shot_at += _shot_every


## One route entry is "<seconds>:<button>[:<taps>[:<hold frames>]]".
## emulated frames -- a menu polls the pad far more slowly than it runs, and a
## press seeded to the frame boundary is the zero-frame press that made an
## earlier probe look like a reader that ignored its buttons.
func _parse_route(spec: String) -> Array:
	var out: Array = []
	for pair in spec.split(",", false):
		var bits := String(pair).split(":")
		if bits.size() < 2:
			continue
		var btn := String(bits[1]).strip_edges().to_lower()
		if not BUTTONS.has(btn):
			print("[erl] unknown button '%s' in route" % btn)
			continue
		# A tap is one menu move, measured: one entry of two taps walked Select a
		# File from File 1 to File 3. So the count is the distance, and an entry
		# carries its own -- three to reach Level Card, one to choose it.
		var taps := _taps
		if bits.size() >= 3:
			taps = maxi(1, String(bits[2]).to_int())
		# Hold is per entry because one length does not serve both jobs. A menu
		# repeats, so four frames is one move and twelve is two; a world map
		# ignores four frames altogether and wants a press long enough to start
		# Mario walking. Same button, opposite requirement.
		var hold := _hold
		if bits.size() >= 4:
			hold = maxi(1, String(bits[3]).to_int())
		out.append({"t": String(bits[0]).to_float(), "btn": int(BUTTONS[btn]),
			"name": btn, "taps": taps, "hold": hold, "done": false})
	return out


## A route entry is a BURST of taps, not one press, and that is measured rather
## than tidy. A single 0.25 s press -- fifteen emulated frames -- reliably breaks
## an attract demo and reliably does NOT move a menu: the reader sat on its title
## through one press and walked to its menu under a repeated one, and Super Mario
## Advance 4 did the same on both of its title screens. Whatever the cause, one
## tap is not a press these menus act on, so every entry taps _taps times.
## Scheduled on the MACHINE'S OWN frame count, never the wall clock.
##
## Frame pacing varies enough between runs that the same invocation reaches
## different screens: two runs of an identical route landed one on Select a File
## and the other back on the title. A route written in seconds is therefore not a
## route at all, it is a guess that happened to work once. Seconds in the route
## are a convenience and are converted at 60 fps here.
func _step(lib: Libretro, route: Array, f: int) -> void:
	var held := 0
	for e: Dictionary in route:
		var at := int(float(e["t"]) * 60.0)
		var hold := int(e["hold"])
		for k in int(e["taps"]):
			var from: int = at + k * (hold * 2)
			if f >= from and f < from + hold:
				held |= int(e["btn"])
		if f >= at and not bool(e["done"]):
			e["done"] = true
			print("[erl] f=%-6d %s press %s x%d" % [
				f, "reader" if lib == _reader else "game", e["name"], int(e["taps"])])
	lib.SetJoypadState(0, held, 0, 0, 0, 0)


func _sample(at: float) -> void:
	print("[erl] t=%4.1f reader frames=%-6d peers=%d traffic=%-7d | game frames=%-6d peers=%d traffic=%d" % [
		at, int(_reader.GetFrameCount()), int(_reader.LinkPeerCount(0)),
		int(_reader.LinkTraffic(0)),
		int(_game.GetFrameCount()), int(_game.LinkPeerCount(0)),
		int(_game.LinkTraffic(0))])
	if _shot.is_empty():
		return
	_save(_reader, "%s_reader_%05.1f.png" % [_shot, at])
	_save(_game, "%s_game_%05.1f.png" % [_shot, at])


## Flattened to RGB8: the core never fills alpha, so a straight save_png writes a
## fully transparent image that every viewer paints blank.
##
## The per-pixel flatten, and it has to be the per-pixel flatten. convert() to
## RGB8 was tried to make filming cheap and comes out WHITE -- every frame, a
## 12 KiB video of nothing, which is only obvious if you watch it rather than
## read a still out of the same folder. Slower and right beats faster and blank.
func _save(lib: Libretro, path: String) -> void:
	var img: Image = lib.GetVideoImage()
	if img == null or img.is_empty():
		return
	var out := PackedByteArray()
	out.resize(img.get_width() * img.get_height() * 3)
	var i := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			out[i] = int(c.r * 255.0)
			out[i + 1] = int(c.g * 255.0)
			out[i + 2] = int(c.b * 255.0)
			i += 3
	var flat := Image.create_from_data(img.get_width(), img.get_height(),
		false, Image.FORMAT_RGB8, out)
	flat.save_png(path.replace(" ", "0"))


func _report() -> void:
	var rp := int(_reader.LinkPeerCount(0))
	var gp := int(_game.LinkPeerCount(0))
	var traffic := int(_reader.LinkTraffic(0)) + int(_game.LinkTraffic(0))
	# An unplugged machine reports NO peers, not itself: the count is who else is
	# out there. Expecting 1 here was my own error and the control leg caught it.
	var want := 2 if _cabled else 0
	_check("the reader booted", int(_reader.GetFrameCount()) > 0)
	_check("the game booted", int(_game.GetFrameCount()) > 0)
	_check("the reader sees %d peer(s)" % want, rp == want)
	_check("the game sees %d peer(s)" % want, gp == want)
	if _cabled:
		_check("the bus carried traffic", traffic > 0)
	else:
		_check("an uncabled bus is silent", traffic == 0)
	print("[erl] RESULT peers=%d/%d traffic=%d" % [rp, gp, traffic])
	if _cabled:
		print("[erl] NOTE transport PASS alone does not prove the level-card payload")
	_restore()
	if _fail.is_empty():
		print("[erl] PASS")
		get_tree().quit(0)
	else:
		print("[erl] FAIL: %s" % ", ".join(_fail))
		get_tree().quit(1)


func _check(name: String, cond: bool) -> void:
	print("[erl] %s  %s" % ["PASS" if cond else "FAIL", name])
	if not cond:
		_fail.append(name)


func _find_game() -> String:
	var d := DirAccess.open(_roms)
	if d == null:
		return ""
	var best := ""
	for f in d.get_files():
		if not f.ends_with(".gba"):
			continue
		if not f.begins_with("Super Mario Advance 4"):
			continue
		# The plain USA dump, not a Virtual Console re-release or a revision.
		if f.find("(USA)") >= 0 and f.find("Virtual Console") < 0:
			if best.is_empty() or f.length() < best.length():
				best = f
	return _roms.path_join(best) if not best.is_empty() else ""


func _find_card() -> String:
	var dir := RomLibrary.default_roms_root().path_join(EReaderCards.SYSTEMID)
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	for f in d.get_files():
		if f.ends_with(".raw") and f.find("07-A001") >= 0 and f.find("(USA)") >= 0:
			return dir.path_join(f)
	return ""


func _size_of(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var n := f.get_length()
	f.close()
	return int(n)


func _pin_options(root: String) -> bool:
	_opt_path = "%s/core_options/%s.opt" % [root, _core]
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


## A core serialises its whole option set on shutdown, so a crashed run can leave
## a key moved. Put back exactly what was there.
func _restore() -> void:
	if _restored or _opt_path.is_empty():
		return
	_restored = true
	var writer := FileAccess.open(_opt_path, FileAccess.WRITE)
	if writer != null:
		writer.store_string(_opt_backup)
		writer.close()
