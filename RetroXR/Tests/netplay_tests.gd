extends Node

## Netplay self-tests — the whole lockstep stack, headless, with mock cores.
##
##   "$godot" --headless --path RetroXR res://Tests/netplay_tests.tscn
##   "$godot" --headless --path RetroXR res://Tests/netplay_tests.tscn -- --only=start
##
## Exits non-zero on failure, so it can gate a commit. ~60 s, no ROM, no core,
## no headset, no display.
##
## Two kinds of case here, and the split is deliberate.
##
## The pure ones (cores/ identity/ wire/ owners/ assemble/) drive a NetplaySession
## with a stub parent and no network at all, because the wire format, the port
## bookkeeping and the assembler are decisions, not conversations.
##
## The rest run TWO — for the join cases, THREE — complete NetworkManagers in
## this one process, each with its own SceneMultiplayer, talking over real
## loopback ENet. That is closer to two copies of the app than two OS processes
## would be for anything this suite can assert: the RPCs, the channels, the
## serialization and the handshake are all the real ones, and the run stays
## deterministic and headless. What it does NOT cover is a real core's
## arithmetic; that needs two machines and lives in Tools/netplay/netplay_spike.gd
## (--spike-state-out / --spike-state-in for the cross-architecture leg).
##
## The mock core implements the C++ frame gate — it runs frame N only when
## PostNetplayInputs(N) arrives in order — and folds a deterministic RAM CRC from
## exactly the inputs posted, so two peers fed the same assembled frames produce
## identical CRC streams. It also reports a core IDENTITY the way the real
## Wrapper does: empty until content has loaded, then library_name/version/
## api_version/serialize_size. Several cases here exist only because that is
## asynchronous.

const NM_SCRIPT := preload("res://Scripts/Net/network_manager.gd")
const GROUPS := ["cores", "substitute", "manifest", "hashcache", "progress", "hudnotify", "readiness", "identity", "roomcode",
	"punch", "wire", "owners", "assemble", "start", "lockstep", "desync", "join",
	"transfer", "leave", "rollback", "link"]
const PORT := 42913

## What a real fceumm reports, near enough. The exact strings do not matter to
## any case — only that two peers can be made to agree or disagree about them.
const IDENT_A := {"library_name": "FCEUmm", "library_version": "(SVN)",
	"api_version": 1, "serialize_size": 13701}

var _fail := 0
var _ran := 0
var _only := ""


func _ready() -> void:
	get_tree().create_timer(180.0).timeout.connect(func() -> void:
		print("[test] TIMEOUT")
		get_tree().quit(1))
	get_tree().current_scene = self

	for a in OS.get_cmdline_user_args():
		if a.begins_with("--only="):
			_only = a.trim_prefix("--only=")

	if _want("cores"):
		_test_cores()
	if _want("substitute"):
		_test_substitute()
	if _want("manifest"):
		_test_manifest()
	if _want("hudnotify"):
		_test_hudnotify()
	if _want("progress"):
		await _test_progress()
	if _want("hashcache"):
		_test_hashcache()
	if _want("readiness"):
		_test_readiness()
	if _want("badge"):
		_test_badge()
	if _want("identity"):
		_test_identity()
	if _want("roomcode"):
		await _test_room_code()
	if _want("punch"):
		_test_punch()
	if _want("wire"):
		await _test_wire()
	if _want("owners"):
		await _test_owners()
	if _want("assemble"):
		await _test_assemble()
	if _want("start"):
		await _test_start()
	if _want("lockstep"):
		await _test_lockstep()
	if _want("desync"):
		await _test_desync()
	if _want("join"):
		await _test_join()
	if _want("transfer"):
		await _test_transfer()
	if _want("leave"):
		await _test_leave()
	if _want("rollback"):
		await _test_rollback()
	if _want("strategy"):
		await _test_strategy()
	if _want("link"):
		await _test_link()

	print("[test] %d cases, %s" % [_ran,
		"PASS" if _fail == 0 else "%d FAILURE(S)" % _fail])
	get_tree().quit(0 if _fail == 0 else 1)


# ══ The allowlist ═════════════════════════════════════════════════════════════
# A core is netplay-capable only after netplay_spike has proven it deterministic.
# The table is the record of what was measured, so the rules that read it are
# worth pinning: an unvetted core must be indistinguishable from an unknown one.

func _test_cores() -> void:
	_ok(NetplayCores.is_capable("fceumm"), "cores/a vetted core is capable")
	_ok(not NetplayCores.is_capable("dolphin"),
		"cores/a listed but unvetted core is not")
	_ok(not NetplayCores.is_capable("__never_vetted"),
		"cores/an unlisted core is not")
	_ok(not NetplayCores.is_capable(""), "cores/no core at all is not")

	# rollback needs BOTH determinism and a state cheap enough to take every
	# frame, so it can never be true where is_capable is false.
	for core: String in NetplayCores.CORES:
		if NetplayCores.rollback_capable(core):
			_ok(NetplayCores.is_capable(core),
				"cores/%s cannot roll back without being verified" % core)
	_ok(NetplayCores.rollback_capable("fceumm"), "cores/fceumm rolls back")
	_ok(not NetplayCores.rollback_capable("__never_vetted"),
		"cores/an unvetted core does not roll back")

	# forced_options is handed to a core at start; a caller mutating what it got
	# back would edit the table for every later session in this process.
	var opts := NetplayCores.forced_options("fceumm")
	opts["poisoned"] = "yes"
	_ok(not NetplayCores.forced_options("fceumm").has("poisoned"),
		"cores/forced options are copied, not shared")
	_ok(NetplayCores.forced_options("nonesuch").is_empty(),
		"cores/an unknown core forces nothing")

	# TWO PROPERTIES. Cold-start determinism is what a session needs to PLAY;
	# savestate reload fidelity is what a late join and a resync need. gambatte
	# is the case that forced them apart: it reproduced exactly across two
	# processes from frame 0 while failing 16 of 20 checkpoints after reloading
	# its own state. Collapsing them either bars a core that plays fine or
	# promises a late join that cannot work, so they stay separate keys even
	# though every core in the table now earns both.
	_ok(NetplayCores.is_capable("gambatte"), "cores/gambatte can hold a session")
	# It earns the second one only with the frame-dupe pacing turned off, which
	# is why the entry carries an option rather than just a flag: the dupe is
	# emitted from a running total of audio samples that a state load resets, so
	# a transferred state slipped one frame against the run it came from.
	_ok(NetplayCores.state_transfer_capable("gambatte"),
		"cores/and can put a state on the wire")
	_ok(NetplayCores.forced_options("gambatte").get("gambatte_frame_dupe", "") == "disabled",
		"cores/because netplay forces its frame pacing off")
	_ok(NetplayCores.state_transfer_capable("fceumm"),
		"cores/fceumm can do both")
	# pcsx_rearmed is the live example of the split now that gambatte has been
	# fixed: it reproduces exactly from a cold start across two processes and
	# fails 8 of 20 checkpoints after reloading its own state, so a session
	# plays and a late join must not be offered.
	_ok(NetplayCores.is_capable("pcsx_rearmed"),
		"cores/pcsx_rearmed can hold a session")
	_ok(not NetplayCores.state_transfer_capable("pcsx_rearmed"),
		"cores/but cannot put a state on the wire")
	_ok(not NetplayCores.state_transfer_capable("__never_vetted"),
		"cores/an unvetted core can do neither")
	_ok(not NetplayCores.state_transfer_capable("nonesuch"),
		"cores/nor an unknown one")
	# A core that cannot roll back must not be offered rollback, and a core with
	# no transferable state cannot: rollback rewinds through one every frame.
	_ok(not NetplayCores.rollback_capable("pcsx_rearmed"),
		"cores/pcsx_rearmed does not roll back, having no state to rewind through")

	# The debug override exists to let a core be MEASURED. Shipping it a state
	# that will not restore measures nothing, so it must not reach across into
	# state transfer — the one place the answer is already known to be no.
	NetplayCores.debug_allow_unverified = true
	_ok(NetplayCores.is_capable("dolphin"),
		"cores/the override lets an unvetted core start")
	_ok(not NetplayCores.state_transfer_capable("dolphin"),
		"cores/but never lets it transfer a state")
	NetplayCores.debug_allow_unverified = false
	_ok(not NetplayCores.is_capable("dolphin"), "cores/and the override is off again")

	# THREE STRATEGIES, and the table says which a core has evidence for. A core
	# that only has determinism must never be handed rollback, whatever is asked
	# of it: rollback rewinds through a savestate every frame, and the reason
	# these cores are determinism-only is that they have no state to rewind
	# through.
	_ok(NetplayCores.strategies_for("fceumm").has(NetplayCores.Strategy.ROLLBACK),
		"cores/fceumm is vetted for rollback")
	_eq(NetplayCores.strategies_for("dolphin"), [],
		"cores/an unverified core is vetted for nothing")
	_ok(NetplayCores.strategies_for("nonesuch").is_empty(),
		"cores/and so is an unknown one")
	# Verified is not a blanket yes: it earns the entry, and the entry says which
	# strategies the evidence actually covers. pcsx_rearmed is the standing case
	# -- it reproduces perfectly from a cold start and cannot reload its own
	# state, so determinism is the only one of the three it can hold.
	_eq(NetplayCores.strategies_for("pcsx_rearmed"), [NetplayCores.Strategy.DETERMINISM],
		"cores/a core vetted for some strategies gets only those")
	# And rollback is never offered without the state transfer it rewinds
	# through, which is the pairing the two keys exist to keep honest.
	for core: String in NetplayCores.CORES:
		if NetplayCores.rollback_capable(core):
			_ok(NetplayCores.state_transfer_capable(core),
				"cores/%s cannot roll back without a state to rewind through" % core)
	# gambatte was the standing example of a lockstep-only core, on the reasoning
	# that it could not reload its own state. That stopped being true when the
	# frame-dupe pacing was gated, and the entry was never re-measured. It rolls
	# back now: 275 rewind anchors clean, 164 rewinds over a run whose CRC stream
	# is identical to the lockstep one, 84 KB a state and 5 us to take it. The
	# rewind is what found the last defect -- the blit event and the blank-LCD
	# flag were rebuilt on load rather than saved, which one mid-run reload
	# survives and a rollback session hits every few seconds.
	_ok(NetplayCores.strategies_for("gambatte").has(NetplayCores.Strategy.ROLLBACK),
		"cores/gambatte is vetted for rollback")
	_ok(NetplayCores.strategies_for("mgba").has(NetplayCores.Strategy.DETERMINISM),
		"cores/mgba is vetted for determinism, which a GC-GBA group needs")
	# Strongest first, so a group can take the head of the intersection.
	_eq(NetplayCores.strategies_for("fceumm")[0], NetplayCores.Strategy.ROLLBACK,
		"cores/the list is strongest first")

	# CROSS-PLAY is a separate question from the strategy. A core can be
	# determinism-only and still safe across architectures, or roll back happily
	# and only ever same-arch. Defaults to false because absence of evidence is
	# not evidence.
	_ok(NetplayCores.allows_cross_play("fceumm"),
		"cores/fceumm is vetted x64 against arm64")
	_ok(not NetplayCores.allows_cross_play("dolphin"),
		"cores/dolphin is not, because it picks its CPU backend from the host")
	# snes9x is fully verified and still does not cross, which is the point of
	# keeping the two apart: passing determinism vetting on one machine says
	# nothing about whether the same arithmetic survives a different CPU.
	_ok(NetplayCores.is_capable("snes9x") and not NetplayCores.allows_cross_play("snes9x"),
		"cores/being verified does not imply crossing architectures")
	_ok(not NetplayCores.allows_cross_play("nonesuch"),
		"cores/nor does being unknown")

	# A large core buys back the hitch of hashing its whole RAM with a longer gap.
	_eq(NetplayCores.crc_interval("fceumm"), NetplayCores.DEFAULT_CRC_INTERVAL,
		"cores/a small core takes the default CRC gap")
	_ok(NetplayCores.crc_interval("dolphin") > NetplayCores.DEFAULT_CRC_INTERVAL,
		"cores/a 24 MB one asks for a longer gap")
	_eq(NetplayCores.crc_interval("nonesuch"), NetplayCores.DEFAULT_CRC_INTERVAL,
		"cores/an unknown core takes the default")

	# Dolphin returns 0 for RETRO_MEMORY_SAVE_RAM and keeps its memory cards in a
	# folder of its own, so the frontend's SRAM sync reaches nothing and two
	# peers' cards differ in silence.
	_ok(NetplayCores.uses_scratch_saves("dolphin"),
		"cores/dolphin needs a scratch save folder")
	_ok(not NetplayCores.uses_scratch_saves("fceumm"),
		"cores/a core with real SAVE_RAM does not")

	# Every entry has to answer every question the table is asked, so a missing
	# key cannot read as a quiet false.
	for core: String in NetplayCores.CORES:
		var e: Dictionary = NetplayCores.CORES[core]
		for key: String in ["verified", "state_transfer", "strategies", "cross_play",
				"systems", "options"]:
			_ok(e.has(key), "cores/%s declares %s" % [core, key])
		# Every strategy named has to be one that exists, or a typo reads as a
		# capability nothing will ever select.
		for s: int in (e["strategies"] as Array):
			_ok(NetplayCores.STRATEGY_ORDER.has(s),
				"cores/%s names only real strategies" % core)


# ══ The core list's netplay badge ═════════════════════════════════════════════
# What the menu tells a player about a core, which is a different question from
# what a session will allow. is_capable() answers true for EVERY core name once
# the debug switch is on, so a badge built on it would mark the whole list; the
# badge reads listed_strategy instead, and these pin that difference.

func _test_badge() -> void:
	_eq(NetplayCores.listed_strategy("fceumm"), NetplayCores.Strategy.ROLLBACK,
		"badge/a vetted core reports its strongest strategy")
	_eq(NetplayCores.listed_strategy("pcsx_rearmed"), NetplayCores.Strategy.DETERMINISM,
		"badge/a determinism-only core reports determinism")
	_eq(NetplayCores.listed_strategy("dolphin"), -1,
		"badge/a listed but unvetted core reports none")
	_eq(NetplayCores.listed_strategy("__never_vetted"), -1,
		"badge/an unlisted core reports none")
	_eq(NetplayCores.listed_strategy(""), -1, "badge/no core at all reports none")

	# The whole reason listed_strategy exists rather than reusing is_capable.
	var was := NetplayCores.debug_allow_unverified
	NetplayCores.debug_allow_unverified = true
	_eq(NetplayCores.listed_strategy("__never_vetted"), -1,
		"badge/the debug switch does not badge an unlisted core")
	_eq(NetplayCores.listed_strategy("dolphin"), -1,
		"badge/nor an unvetted one")
	NetplayCores.debug_allow_unverified = was

	_ok(MenuIcons.netplay_badge(13, "dolphin") == null,
		"badge/an unvetted core gets no badge")
	_ok(MenuIcons.netplay_badge(13, "__never_vetted") == null,
		"badge/an unlisted core gets no badge")

	var lbl := MenuIcons.netplay_badge(13, "fceumm")
	_ok(lbl != null, "badge/a vetted core gets one")
	if lbl == null:
		return
	_ok(lbl.text.contains("Rollback"), "badge/it names the strategy")
	_ok(lbl.text.contains(String.chr(MenuIcons.NETPLAY)),
		"badge/it carries the glyph codepoint")

	# A tofu box is a SILENT failure: the label still draws, at the right size, as
	# a hollow rectangle. Both halves matter — that a font is attached, and that
	# the attached font really has this Private Use Area character.
	var f: Font = lbl.get_theme_font("font")
	_ok(f != null, "badge/it has a font attached")
	if f != null:
		_ok(f.has_char(MenuIcons.NETPLAY),
			"badge/the attached font really has U+%X" % MenuIcons.NETPLAY)

	lbl.free()


# ══ Core build identity ═══════════════════════════════════════════════════════
# The reason this exists at all: cores come from buildbot.libretro.com under
# nightly/<platform>/latest/, so a Windows player and a Quest player take their
# fceumm from two different directories, cut at two different times, from two
# different commits. They can never hold the same FILE, which is why the check
# is on what the core says it is rather than on a hash of the binary.

func _test_identity() -> void:
	var a := IDENT_A.duplicate()
	var b := IDENT_A.duplicate()
	_ok(NetplaySession.identity_mismatch(a, b).is_empty(),
		"identity/the same build plays itself")

	b["library_version"] = "(SVN 2026-08-21)"
	var msg := NetplaySession.identity_mismatch(a, b)
	_ok(not msg.is_empty(), "identity/a different build version is refused")
	_ok(msg.contains("(SVN)") and msg.contains("(SVN 2026-08-21)"),
		"identity/and the refusal names BOTH builds, not just that they differ")

	b = IDENT_A.duplicate()
	b["library_name"] = "Nestopia"
	_ok(not NetplaySession.identity_mismatch(a, b).is_empty(),
		"identity/a different core entirely is refused")

	# The savestate size is not cosmetic: a late join and every desync resync
	# ship the host's serialized state for this peer to load. Different sizes
	# means that transfer cannot work, and the symptom is a failed join.
	b = IDENT_A.duplicate()
	b["serialize_size"] = 13702
	msg = NetplaySession.identity_mismatch(a, b)
	_ok(not msg.is_empty(), "identity/a different savestate size is refused")
	_ok(msg.contains("13701") and msg.contains("13702"),
		"identity/and the refusal gives both sizes")

	# 0 is "not measured yet", not "zero bytes", and the difference decides
	# whether netplay can start at all. A core cannot always be asked its
	# savestate size before it has run a frame (Dolphin segfaults on the
	# question), and under the gate NO peer has run one at cold start, because
	# the gate is waiting on the readiness this check is part of. Treating an
	# unmeasured size as a difference refuses every session on both platforms.
	b = IDENT_A.duplicate()
	b["serialize_size"] = 0
	_ok(NetplaySession.identity_mismatch(a, b).is_empty(),
		"identity/a size not measured yet is not a difference")
	_ok(NetplaySession.identity_mismatch(b, a).is_empty(),
		"identity/in either direction")
	var both_unmeasured := IDENT_A.duplicate()
	both_unmeasured["serialize_size"] = 0
	_ok(NetplaySession.identity_mismatch(both_unmeasured, both_unmeasured.duplicate()).is_empty(),
		"identity/nor when neither side has measured one")
	# ...but the version check still has to bite through an unmeasured size,
	# or "not measured" becomes a way to get past the whole check.
	var unmeasured_other := IDENT_A.duplicate()
	unmeasured_other["serialize_size"] = 0
	unmeasured_other["library_version"] = "(SVN 2026-08-20)"
	_ok(not NetplaySession.identity_mismatch(a, unmeasured_other).is_empty(),
		"identity/an unmeasured size does not excuse a different build")

	b = IDENT_A.duplicate()
	b["api_version"] = 2
	_ok(not NetplaySession.identity_mismatch(a, b).is_empty(),
		"identity/a different libretro API is refused")

	# An absent identity is a refusal, never a pass. This is the case that
	# decides whether the whole check can be defeated by a core that says
	# nothing, and "unknown means allowed" is how a guard becomes decoration.
	_ok(not NetplaySession.identity_mismatch({}, a).is_empty(),
		"identity/a host that reported nothing is refused")
	_ok(not NetplaySession.identity_mismatch(a, {}).is_empty(),
		"identity/a peer that reported nothing is refused")
	_ok(not NetplaySession.identity_mismatch({}, {}).is_empty(),
		"identity/two peers reporting nothing are still refused")

	_eq(NetplaySession.identity_str(IDENT_A), "FCEUmm (SVN)",
		"identity/a build reads as name and version")
	_eq(NetplaySession.identity_str({}), "(unknown)",
		"identity/and an absent one says so")

	# ── Architecture ──────────────────────────────────────────────────────────
	# Two peers can hold the same build of the same core and still compute
	# different answers: Dolphin picks JIT64 on x86_64 and JITARM64 on arm64,
	# which are two different compilers for the same PowerPC. So the identity
	# carries the HOST's architecture as well as the core's build, and whether a
	# difference is fatal is a per-core fact.
	var x64 := IDENT_A.duplicate()
	x64["arch"] = "x86_64"
	var arm := IDENT_A.duplicate()
	arm["arch"] = "arm64"

	_ok(NetplaySession.identity_mismatch(x64, x64.duplicate(), "dolphin").is_empty(),
		"identity/matching architectures play, cross-play or not")

	var cross := NetplaySession.identity_mismatch(x64, arm, "dolphin")
	_ok(not cross.is_empty(),
		"identity/a core not vetted across architectures refuses the other one")
	_ok(cross.contains("x86_64") and cross.contains("arm64"),
		"identity/and the refusal names both, so the player knows which end to change")

	# The other direction of the same flag. Without this the check passes just as
	# well against code that refuses every architecture difference outright.
	_ok(NetplaySession.identity_mismatch(x64, arm, "fceumm").is_empty(),
		"identity/a core vetted across them is let through")

	# An identity with no stamp predates the check. Judging it would refuse every
	# peer on the strength of a field neither of them sent.
	_ok(NetplaySession.identity_mismatch(IDENT_A, arm, "dolphin").is_empty(),
		"identity/an unstamped identity is not judged on architecture")
	_ok(NetplaySession.identity_mismatch(x64, IDENT_A, "dolphin").is_empty(),
		"identity/in either position")

	# An unknown core answers false to allows_cross_play, so it is held to
	# same-arch — the safe way round for something with no evidence at all.
	_ok(not NetplaySession.identity_mismatch(x64, arm, "nonesuch").is_empty(),
		"identity/an unknown core is held to one architecture")


# ══ Room codes ════════════════════════════════════════════════════════════════
# The six characters a host reads out over voice chat. The alphabet is chosen so
# that a code cannot contain a character someone will hear or read wrong, and
# the two calls are ordered — normalize, then validate — so that what passed the
# gate is exactly what gets sent to the registry.
func _test_room_code() -> void:
	_eq(RoomCode.ALPHABET.length(), 30, "roomcode/the alphabet is 30 symbols")
	_eq(RoomCode.LENGTH, 6, "roomcode/a code is six characters")

	# Both halves of every confusable pair are absent. Dropping only one would
	# make the survivor a rewrite target and hide a typo as a wrong-code lookup.
	for c in ["I", "L", "O", "U", "0", "1"]:
		_ok(not RoomCode.ALPHABET.contains(c),
			"roomcode/the alphabet excludes %s" % c)
	var seen := {}
	for c in RoomCode.ALPHABET:
		seen[c] = true
	_eq(seen.size(), RoomCode.ALPHABET.length(),
		"roomcode/no symbol appears twice")

	_eq(RoomCode.normalize("k7mpq4"), "K7MPQ4", "roomcode/input is upper-cased")
	_eq(RoomCode.normalize("  K7MPQ4  "), "K7MPQ4",
		"roomcode/surrounding space is dropped")
	_eq(RoomCode.normalize("K7M PQ4"), "K7MPQ4",
		"roomcode/space inside a code is dropped")
	_eq(RoomCode.normalize("K7M-PQ4"), "K7MPQ4",
		"roomcode/a hyphen someone added is dropped")
	_eq(RoomCode.normalize("k7m_pq4"), "K7MPQ4",
		"roomcode/an underscore is dropped too")
	_eq(RoomCode.normalize(""), "", "roomcode/nothing normalizes to nothing")

	# A character outside the alphabet must survive normalization. Rewriting it
	# here would let an unmintable code reach the registry as a plausible one.
	_eq(RoomCode.normalize("k7mpq0"), "K7MPQ0",
		"roomcode/a confusable is kept for the validator to reject")

	_ok(RoomCode.is_valid("K7MPQ4"), "roomcode/a well-formed code is valid")
	_ok(RoomCode.is_valid("ZZZZZZ"), "roomcode/so is one letter repeated")
	_ok(RoomCode.is_valid("234567"), "roomcode/so is an all-digit code")

	_ok(not RoomCode.is_valid("K7MPQ"), "roomcode/five characters is not a code")
	_ok(not RoomCode.is_valid("K7MPQ44"),
		"roomcode/seven characters is not a code")
	_ok(not RoomCode.is_valid(""), "roomcode/an empty field is not a code")
	for c in ["I", "L", "O", "U", "0", "1"]:
		_ok(not RoomCode.is_valid("K7MPQ" + c),
			"roomcode/%s is refused inside a code" % c)
	_ok(not RoomCode.is_valid("K7MPQ!"), "roomcode/punctuation is refused")

	# is_valid judges the sent form, so lowercase fails rather than quietly
	# passing — a caller that skipped normalize finds out here, not at the
	# registry.
	_ok(not RoomCode.is_valid("k7mpq4"),
		"roomcode/an unnormalized code does not pass the gate")
	_ok(not RoomCode.is_valid("K7M-PQ4"),
		"roomcode/nor does one still carrying its hyphen")
	_ok(RoomCode.is_valid(RoomCode.normalize("k7m-pq4")),
		"roomcode/normalize then validate is the accepted order")

	# Every symbol the server can mint has to survive its own round trip.
	for c in RoomCode.ALPHABET:
		var code: String = c.repeat(RoomCode.LENGTH)
		_ok(RoomCode.is_valid(RoomCode.normalize(code.to_lower())),
			"roomcode/%s round-trips" % c)


	# ── The registry, mocked. No server: the response shapes are pure static
	# functions precisely so a suite can hold them to their contract.
	var made := RendezvousClient.parse_created({
		"code": "K7MPQ4", "secret": "s3cr3t", "ttl": 90,
		"punch_host": "punch.retroxr.app", "punch_port": 8890,
	})
	_eq(made.get("code", ""), "K7MPQ4", "roomcode/a created room carries its code")
	_eq(made.get("secret", ""), "s3cr3t", "roomcode/and the secret that owns it")
	_eq(made.get("punch_port", 0), 8890, "roomcode/and where to punch")

	# The punch endpoint arrives in the response so it can move without a client
	# update. A record that omits it is unusable, not a default.
	_ok(RendezvousClient.parse_created({
			"code": "K7MPQ4", "secret": "s", "ttl": 90,
		}).is_empty(),
		"roomcode/a room with no punch endpoint is refused")
	_ok(RendezvousClient.parse_created({
			"code": "K7MPQ4", "secret": "s", "punch_host": "h", "punch_port": 0,
		}).is_empty(),
		"roomcode/port 0 is not a punch endpoint")
	_ok(RendezvousClient.parse_created({
			"code": "K7MPQ4", "secret": "s", "punch_host": "h",
			"punch_port": 70000,
		}).is_empty(),
		"roomcode/nor is a port above the range")
	_ok(RendezvousClient.parse_created({
			"code": "K7MPQ4", "punch_host": "h", "punch_port": 8890,
		}).is_empty(),
		"roomcode/a room with no secret is refused")

	# A code the client would reject from a player it must reject from the
	# server too, rather than hand someone an unreadable string to dictate.
	_ok(RendezvousClient.parse_created({
			"code": "K7MPQ0", "secret": "s", "punch_host": "h",
			"punch_port": 8890,
		}).is_empty(),
		"roomcode/a minted code containing a confusable is refused")
	_ok(RendezvousClient.parse_created({
			"code": "K7MPQ44", "secret": "s", "punch_host": "h",
			"punch_port": 8890,
		}).is_empty(),
		"roomcode/so is one of the wrong length")
	_ok(RendezvousClient.parse_created("not a dictionary at all").is_empty(),
		"roomcode/a non-dictionary body is refused")
	_ok(RendezvousClient.parse_created(null).is_empty(),
		"roomcode/so is nothing at all")

	var found := RendezvousClient.parse_room({
		"oid": "abc123", "name": "Ryan", "protocol_version": 7,
		"punch_host": "punch.retroxr.app", "punch_port": 8890,
	})
	_eq(found.get("oid", ""), "abc123", "roomcode/a looked-up room carries the host oid")
	_eq(found.get("protocol_version", -1), 7,
		"roomcode/and the protocol version to check before connecting")

	# Without a version there is nothing to compare, and an unverifiable peer is
	# refused here rather than found out as a desync later.
	_ok(RendezvousClient.parse_room({
			"oid": "abc123", "punch_host": "h", "punch_port": 8890,
		}).is_empty(),
		"roomcode/a room with no protocol version is refused")
	_ok(RendezvousClient.parse_room({
			"protocol_version": 7, "punch_host": "h", "punch_port": 8890,
		}).is_empty(),
		"roomcode/a room with no host oid is refused")
	# Version 0 is a real version, not a missing one.
	_ok(not RendezvousClient.parse_room({
			"oid": "abc", "protocol_version": 0, "punch_host": "h",
			"punch_port": 8890,
		}).is_empty(),
		"roomcode/protocol version zero is still a version")

	_eq(RendezvousClient.parse_heartbeat({"ok": true, "ttl": 90}), 90,
		"roomcode/a heartbeat renews the lease")
	_eq(RendezvousClient.parse_heartbeat({"ok": false, "ttl": 90}), -1,
		"roomcode/a refused heartbeat renews nothing")
	_eq(RendezvousClient.parse_heartbeat({"ok": true}), -1,
		"roomcode/nor does one that does not say how long")
	_eq(RendezvousClient.parse_heartbeat({"ok": true, "ttl": 0}), -1,
		"roomcode/a zero lease is not a lease")
	_eq(RendezvousClient.parse_heartbeat(null), -1,
		"roomcode/an empty heartbeat answer renews nothing")


	# ── The decisions host_online and join_by_code make before any packet
	# leaves. Everything past this point needs a registry and two real
	# networks, and is deliberately not faked here.
	var nm := _branch("RC%d" % _ran)

	# A malformed code is answered locally. Spending a round trip to be told
	# what this call already knows would also make a typo and an expired room
	# arrive as the same message.
	# A lambda captures by value, so the message has to land somewhere mutable.
	var said := [""]
	nm.status_changed.connect(func(t: String) -> void: said[0] = t)
	_eq(await nm.join_by_code("not-a-code"), ERR_INVALID_PARAMETER,
		"roomcode/a malformed code is refused without asking anyone")
	_ok(not nm.is_active(), "roomcode/and starts no session")
	_ok(str(said[0]).contains("not a room code"), "roomcode/and says so plainly")

	_eq(nm.room_code(), "", "roomcode/nothing is hosting a code yet")

	# The failure copy is the whole point of typing the failures. A player who
	# cannot be punched to must be told what to try, because roughly one
	# attempt in five lands here and a blank message just gets retried.
	var unpunchable: String = nm.punch_failure(Punchthrough.Result.UNPUNCHABLE)
	_ok(unpunchable.contains("hotspot"),
		"roomcode/an unpunchable pair is told the likely cause")
	_ok(unpunchable.contains("LAN") or unpunchable.contains("Wi-Fi"),
		"roomcode/and what to try instead")
	_ok(nm.punch_failure(Punchthrough.Result.NO_SUCH_HOST).contains("no longer"),
		"roomcode/a room that stopped says so, not that the network failed")
	_ok(nm.punch_failure(Punchthrough.Result.UNREACHABLE).contains("LAN"),
		"roomcode/a dead registry points at LAN hosting")

	# A punch server that answers the socket and then ignores the conversation
	# is not the same fault as one that cannot be reached, and saying so cost a
	# real debugging session once. These must not drift back together.
	var protocol_msg: String = nm.punch_failure(Punchthrough.Result.PROTOCOL_ERROR)
	_ok(protocol_msg.contains("punch"),
		"roomcode/a silent punch server names the punch server")
	_ok(protocol_msg != nm.punch_failure(Punchthrough.Result.UNREACHABLE),
		"roomcode/and does not read as an unreachable registry")
	_ok(protocol_msg.contains("LAN"),
		"roomcode/while still pointing at the way out")
	_ok(unpunchable != nm.punch_failure(Punchthrough.Result.UNREACHABLE),
		"roomcode/the two failures do not read the same")

	nm.get_parent().queue_free()

# ══ The punch ═════════════════════════════════════════════════════════════════
# The noray protocol, ported rather than vendored (Scripts/Net/ATTRIBUTIONS.txt).
# Only the parsing is here. Whether a punch actually opens a path cannot be
# answered on one LAN by anything, so it is not pretended at: that answer comes
# from two real networks, and the cases below only make sure that what noray
# says is understood correctly when it does.
func _test_punch() -> void:
	var c := Punchthrough.parse_command("register-host")
	_eq(c["command"], "register-host", "punch/a bare command parses")
	_eq(c["data"], "", "punch/and carries no data")

	c = Punchthrough.parse_command("set-oid abc123")
	_eq(c["command"], "set-oid", "punch/a command with a parameter parses")
	_eq(c["data"], "abc123", "punch/and keeps the parameter")

	# Everything after the first space is the parameter. No command in this
	# protocol takes two, and splitting on every space would silently truncate
	# one that ever did.
	c = Punchthrough.parse_command("cmd a b c")
	_eq(c["data"], "a b c", "punch/a parameter containing spaces survives whole")
	_eq(Punchthrough.parse_command("")["command"], "",
		"punch/an empty line is not a command")

	# TCP is a stream. A command split across two reads is ordinary, and the
	# half-line has to wait rather than be parsed as a short command.
	var got := Punchthrough.ingest("set-oid abc
set-pid de")
	var cmds: Array = got["commands"]
	_eq(cmds.size(), 1, "punch/only the whole line is taken")
	_eq(cmds[0]["command"], "set-oid", "punch/and it is the first one")
	_eq(got["rest"], "set-pid de", "punch/the partial line is kept for later")

	got = Punchthrough.ingest(got["rest"] + "f456
")
	cmds = got["commands"]
	_eq(cmds.size(), 1, "punch/the rest completes on the next read")
	_eq(cmds[0]["data"], "def456", "punch/rejoined across the split")
	_eq(got["rest"], "", "punch/and nothing is left over")

	got = Punchthrough.ingest("a

b
")
	_eq((got["commands"] as Array).size(), 2, "punch/blank lines are not commands")

	got = Punchthrough.ingest("no newline yet")
	_eq((got["commands"] as Array).size(), 0, "punch/an unterminated line yields nothing")
	_eq(got["rest"], "no newline yet", "punch/and is kept entire")

	var addr := Punchthrough.parse_address("203.0.113.7:41234")
	_eq(addr.get("address", ""), "203.0.113.7", "punch/a peer address parses")
	_eq(addr.get("port", 0), 41234, "punch/with its port")

	# An unusable address must not become port 0 on some default host: that
	# would turn a protocol fault into a connection attempt against nothing.
	_ok(Punchthrough.parse_address("203.0.113.7").is_empty(),
		"punch/an address with no port is refused")
	_ok(Punchthrough.parse_address(":41234").is_empty(),
		"punch/a port with no address is refused")
	_ok(Punchthrough.parse_address("203.0.113.7:0").is_empty(),
		"punch/port zero is refused")
	_ok(Punchthrough.parse_address("203.0.113.7:70000").is_empty(),
		"punch/a port above the range is refused")
	_ok(Punchthrough.parse_address("").is_empty(),
		"punch/an empty address is refused")

	_eq(Punchthrough.encode_status(false, false, false), "$---",
		"punch/a fresh handshake has seen nothing")
	_eq(Punchthrough.encode_status(true, true, true), "$rwx",
		"punch/a finished one has seen everything")
	_eq(Punchthrough.encode_status(false, true, false), "$-w-",
		"punch/having sent is not having received")

	for flags in [[false, false, false], [true, false, false],
			[false, true, false], [false, false, true], [true, true, true]]:
		var enc: String = Punchthrough.encode_status(flags[0], flags[1], flags[2])
		var dec: Dictionary = Punchthrough.decode_status(enc)
		_ok(dec["did_read"] == flags[0] and dec["did_write"] == flags[1]
				and dec["did_handshake"] == flags[2],
			"punch/%s round-trips" % enc)


# ══ The wire format ═══════════════════════════════════════════════════════════
# Everything crossing the wire is integers, which is what makes cross-platform
# play possible at all — but each field is packed to a fixed width, and a value
# that does not survive the round trip is a desync with no other symptom.

func _test_wire() -> void:
	var np := _stub_session()

	# A joypad port: 16-bit button mask plus four SIGNED analog axes. The signs
	# are the whole point — an axis packed unsigned reads as full deflection the
	# other way, which is a controller that plays by itself.
	for vals: Array in [[0, 0, 0, 0, 0], [0xFFFF, 32767, -32768, 1, -1],
			[0x8001, -32768, 32767, -12345, 12345], [1 << 15, 100, -200, 300, -400]]:
		var buf := StreamPeerBuffer.new()
		NetplayWire.put_port(buf, 3, vals)
		buf.seek(0)
		_eq(buf.get_u8(), 3, "wire/port %s keeps its index" % str(vals[0]))
		_eq(NetplayWire.get_port(buf), vals, "wire/port %s round-trips" % str(vals))

	# Aux is per port: two accelerometers, two gyros and four IR/touch points.
	# Exercise every signed field and the last pointer so an offset error cannot
	# silently leave Wii MotionPlus or one IR blob local-only.
	var aux_zero: Array = NetplayWire.aux_default()
	var aux_full: Array = NetplayWire.aux_default()
	aux_full[0] = 0xFF
	for i in range(1, 13):
		aux_full[i] = -30000 + i * 4000
	for i in range(13, NetplaySession.AUX_INTS_PER_PORT):
		aux_full[i] = -32768 + i * 2000
	for i in [15, 18, 21, 24]:
		aux_full[i] = 1
	for aux: Array in [aux_zero, aux_full]:
		var buf2 := StreamPeerBuffer.new()
		NetplayWire.put_aux(buf2, aux)
		# Against the CONSTANT the readers budget with, not against a number
		# written out here — the two disagreeing is the bug this pins down.
		_eq(buf2.get_size(), NetplaySession.AUX_BYTES_PER_PORT,
			"wire/aux is exactly the size every reader budgets for")
		buf2.seek(0)
		_eq(NetplayWire.get_aux(buf2), aux, "wire/aux %s round-trips" % str(aux))

	# The pressed flag is a bit, not a number: anything non-zero has to come back
	# as exactly 1 or the two peers fold different values into their CRCs.
	var bufp := StreamPeerBuffer.new()
	var pressed_aux: Array = NetplayWire.aux_default()
	pressed_aux[0] = 1 << 7
	pressed_aux[24] = 99
	NetplayWire.put_aux(bufp, pressed_aux)
	bufp.seek(0)
	_eq(NetplayWire.get_aux(bufp)[24], 1, "wire/a pressed pointer normalises to 1")

	# Keyboard: keycode plus a down bit plus a character, per slot.
	var keys: Array = [65 | 65536, 97, 66, 98]
	var bufk := StreamPeerBuffer.new()
	NetplayWire.put_keys(bufk, keys)
	_eq(bufk.get_size(), NetplaySession.KEY_BYTES,
		"wire/keys are exactly the size every reader budgets for")
	bufk.seek(0)
	var got: Array = NetplayWire.get_keys(bufk)
	_eq(got.size(), NetplaySession.KEY_SLOTS * 2, "wire/keys unpack to every slot")
	_eq(got[0], 65 | 65536, "wire/a key-down survives with its down bit")
	_eq(got[1], 97, "wire/and its character")
	_eq(got[2], 66, "wire/a key-up survives without one")
	_eq(got[3], 98, "wire/and its character")
	_eq(got[4], 0, "wire/an unused slot is empty")

	# More transitions than slots: the overflow must not corrupt the slots that
	# did fit. (The scheduler rolls the remainder to the next frame.)
	var many: Array = []
	for i in range(NetplaySession.KEY_SLOTS * 2 + 4):
		many.append(100 + i)
	var bufo := StreamPeerBuffer.new()
	NetplayWire.put_keys(bufo, many)
	bufo.seek(0)
	var over: Array = NetplayWire.get_keys(bufo)
	_eq(over[0], 100, "wire/an overfull key block keeps its first slot")
	_eq(over[NetplaySession.KEY_SLOTS * 2 - 1], 100 + NetplaySession.KEY_SLOTS * 2 - 1,
		"wire/and its last")

	# The two readers refuse to unpack a frame they do not have all of, and they
	# budget for it with arithmetic written out by hand at each call site. That
	# arithmetic has to equal what the writers actually produce: when it asked
	# for two bytes more, both readers bailed out on the LAST frame of every
	# packet, which the redundancy window hid for streamed frames and could not
	# hide for a re-request (one frame per packet, dropped every time).
	var one := StreamPeerBuffer.new()
	one.put_u32(7)
	for _p in range(2):
		one.put_u16(0)
		one.put_16(0); one.put_16(0); one.put_16(0); one.put_16(0)
	for _p in range(NetplaySession.PORTS_PER_MACHINE):
		NetplayWire.put_aux(one, NetplayWire.aux_default())
	NetplayWire.put_keys(one, [])
	_eq(one.get_size(), 4 + 2 * 10 + NetplaySession.AUX_BYTES + NetplaySession.KEY_BYTES,
		"wire/a broadcast frame is exactly the size the client budgets for")
	# And the shared function agrees with the bytes actually produced. The line
	# above keeps its arithmetic written out ON PURPOSE: if both the writer and
	# the reader ask the same function, a wrong function is invisible to them
	# both. This is the independent oracle, and that is the whole point.
	_eq(NetplayWire.broadcast_frame_bytes(2, 1), one.get_size(),
		"wire/broadcast_frame_bytes matches what the writer produced")

	var inp := StreamPeerBuffer.new()
	inp.put_u32(7)
	inp.put_u8(1)
	NetplayWire.put_port(inp, 0, [0, 0, 0, 0, 0])
	for _p in range(NetplaySession.PORTS_PER_MACHINE):
		NetplayWire.put_aux(inp, NetplayWire.aux_default())
	NetplayWire.put_keys(inp, [])
	_eq(NetplayWire.local_frame_bytes(1, 1), inp.get_size(),
		"wire/local_frame_bytes matches what the writer produced")
	_eq(inp.get_size(), 4 + 1 + 11 + NetplaySession.AUX_BYTES + NetplaySession.KEY_BYTES,
		"wire/and an input frame is the size the host budgets for")

	# Five-frame redundancy used to exceed ENet's MTU once linked machines each
	# gained their own sensor/pointer tail. The window shrinks, never the frame:
	# dropping aux data to fit would make only the network copy deterministic.
	for machines in [1, 2, 4]:
		var broadcast_frame: int = 4 + int(machines) * 4 * 10 \
			+ int(machines) * (NetplaySession.AUX_BYTES + NetplaySession.KEY_BYTES)
		var window: int = np._unreliable_frame_window(broadcast_frame)
		_ok(1 + window * broadcast_frame <= NetplaySession.UNRELIABLE_PAYLOAD_MAX,
			"wire/%d-machine redundancy stays below the unreliable payload budget" % machines)
		_ok(window >= 1, "wire/%d-machine packets still carry a complete frame" % machines)

	# The assembled frame is one flat int array with a fixed layout; the gate
	# indexes straight into it, so a field landing one slot over is silent.
	var port0_aux: Array = NetplayWire.aux_default()
	port0_aux[0] = 0x91
	port0_aux[1] = 11
	port0_aux[7] = -12
	port0_aux[13] = 14
	port0_aux[15] = 1
	port0_aux[22] = -15
	port0_aux[24] = 1
	var flat := np.flat_from_frame({0: [1, 2, 3, 4, 5], 2: [6, 7, 8, 9, 10]},
		{0: port0_aux}, {0: [70 | 65536, 102]})
	_eq(flat.size(), 20 + NetplaySession.AUX_INTS + NetplaySession.KEY_SLOTS * 2,
		"wire/an assembled frame is one fixed-size block")
	_eq(flat[0], 1, "wire/port 0 lands at 0")
	_eq(flat[10], 6, "wire/port 2 lands at 10")
	_eq(flat[5], 0, "wire/an absent port is neutral, not stale")
	_eq(flat[20], 0x91, "wire/aux follows the four ports")
	_eq(flat[27], -12, "wire/gyro follows accelerometer state")
	_eq(flat[44], 1, "wire/and ends with the fourth pointer button")
	_eq(flat[20 + NetplaySession.AUX_INTS], 70 | 65536, "wire/keys follow aux")

	# A linked machine owns a separate aux/key tail. Sharing one tail copied the
	# anchor handheld's tilt into every core and discarded the far machine's.
	var far_wire_machine := Node.new()
	np._group = [self, far_wire_machine]
	var near_aux: Array = NetplayWire.aux_default()
	near_aux[0] = 1
	near_aux[1] = 10
	var far_aux: Array = NetplayWire.aux_default()
	far_aux[0] = 1 << 4
	far_aux[13] = 40
	far_aux[14] = 50
	far_aux[15] = 1
	var linked_flat := np.flat_from_frame({},
		{0: near_aux, 4: far_aux},
		{0: [65, 97], 1: [66 | 65536, 98]})
	var near_slice := np.slice_for_machine(linked_flat, 0)
	var far_slice := np.slice_for_machine(linked_flat, 1)
	_eq(near_slice[20], 1, "wire/the anchor keeps its own aux flags")
	_eq(near_slice[21], 10, "wire/the anchor keeps its own sensor")
	_eq(far_slice[20], 1 << 4, "wire/the far machine keeps its own aux flags")
	_eq(far_slice[33], 40, "wire/the far machine keeps its own pointer")
	_eq(near_slice[20 + NetplaySession.AUX_INTS], 65,
		"wire/the anchor keeps its own keyboard")
	_eq(far_slice[20 + NetplaySession.AUX_INTS], 66 | 65536,
		"wire/the far machine keeps its own keyboard")
	far_wire_machine.free()

	np.get_parent().queue_free()
	await get_tree().process_frame


# ══ Who owns which port ═══════════════════════════════════════════════════════
# A port has exactly one owner per frame. Two peers supplying one port, or none
# supplying it, are the two ways a lockstep pipeline forks or stops.

func _test_owners() -> void:
	var np := _stub_session()           # this peer is 1

	# Decoding a global port for the players list. A port is
	# machine * PORTS_PER_MACHINE + port, which is what lets a cabled pair's two
	# machines share one numbering; showing "Port 1" for both would be a lie.
	var nm := _branch("OWN")
	var per: int = NetplayWire.PORTS_PER_MACHINE
	_eq(nm.netplay_machine_of(0), 0, "owners/port 0 is the first machine")
	_eq(nm.netplay_port_of(0), 0, "owners/and its first pad")
	_eq(nm.netplay_machine_of(per), 1, "owners/the next block is the second machine")
	_eq(nm.netplay_port_of(per), 0, "owners/whose first pad starts over")
	_eq(nm.netplay_machine_of(per + 3), 1, "owners/a later pad on that machine")
	_eq(nm.netplay_port_of(per + 3), 3, "owners/keeps its own index")
	# No session means no owners, rather than a stale map from the last game.
	_ok(nm.netplay_owners().is_empty(), "owners/no session reports no owners")
	nm.queue_free()

	np._set_owners({0: 1, 2: 7})
	_eq(Array(np._all_ports), [0, 2], "owners/participating ports are sorted")
	_eq(np._port_mask, 0b101, "owners/and reduced to a mask")
	_ok(np._is_participating(0) and np._is_participating(2),
		"owners/a listed port participates")
	_ok(not np._is_participating(1), "owners/an unlisted one does not")
	_ok(np._local_ports.has(0) and not np._local_ports.has(2),
		"owners/only our own ports are sampled locally")

	# Passing a controller to another player. Every peer flips at the same
	# agreed frame, so the frames either side of the boundary must resolve to
	# different owners — that is the whole mechanism.
	np._pending[0] = {"frame": 100, "old": 1, "new": 7, "applied": false}
	_eq(np._owner_for_frame(0, 99), 1, "owners/before the boundary, the old owner")
	_eq(np._owner_for_frame(0, 100), 7, "owners/at it, the new one")
	_eq(np._owner_for_frame(0, 101), 7, "owners/and after")
	_eq(np._owner_for_frame(2, 100), 7, "owners/an unaffected port is untouched")

	np._apply_pending_transfers(99)
	_eq(int(np._owners[0]), 1, "owners/a handoff does not land early")
	_ok(np._local_ports.has(0), "owners/and we keep sampling until it does")
	np._apply_pending_transfers(100)
	_eq(int(np._owners[0]), 7, "owners/it lands exactly at its frame")
	_ok(not np._local_ports.has(0), "owners/and we stop sampling the port we gave away")

	# A dropped controller: nobody owns the port, and the host fills it with
	# neutral input rather than waiting for a peer that will never send.
	np._set_owners({0: 0, 1: 1})
	_eq(np._owner_for_frame(0, 5), 0, "owners/a dropped controller is unowned")
	_ok(not np._local_ports.has(0), "owners/and nobody samples it")

	# The input seam. A participating port is swallowed whatever happens to it,
	# because the gate is the only thing allowed to drive it.
	np._set_owners({0: 1, 1: 9})
	# The session addresses ports as machine * PORTS_PER_MACHINE + port, so it
	# needs a group to look a machine up in, not just an anchor.
	var sys := np._system
	var grp := np._group
	np._system = self
	np._group = [self]
	np._running = true
	_ok(np.route(self, 0, {"btn": 5}), "owners/our own participating port is consumed")
	_ok(np.route(self, 1, {"btn": 5}), "owners/so is a port another peer owns")
	_ok(not np.route(self, 3, {"btn": 5}), "owners/a port outside the game is left alone")
	_ok(not np.route(null, 0, {"btn": 5}), "owners/and so is another machine's")
	_eq(np._capture_local(), {0: [5, 0, 0, 0, 0]}, "owners/what we captured is what we routed")

	# Held buttons persist frame to frame; mouse motion is a per-frame quantity
	# and must not be re-applied, or the pointer runs away at a constant speed.
	np.route(self, 0, {"btn": 3, "alx": 40, "aly": -40, "drain": true})
	_eq(np._capture_local(), {0: [3, 40, -40, 0, 0]}, "owners/a delta device is captured once")
	_eq(np._capture_local(), {0: [3, 0, 0, 0, 0]}, "owners/and drains, keeping its buttons")

	# Lightgun state shares the five-int port block but has different semantics.
	np._pending_local_route.erase(0)
	np.set_lightgun_button(self, 0, 2, true)
	np.set_lightgun_aim(self, 0, -1200, 2300, false)
	_eq(np._capture_local()[0], [1 << 2, -1200, 2300, 0, 0],
		"owners/lightgun buttons and aim enter the deterministic port frame")

	# Motion data is scoped to the actual controller port, including both Wii
	# sensors, gyro and all four IR blobs.
	np._set_owners({0: 1, 2: 1})
	_ok(np.set_aux_sensor(self, 2, 1, 101, -202, 303),
		"owners/a second controller's accelerometer is consumed")
	_ok(np.set_aux_sensor(self, 2, 0, -404, 505, -606, true),
		"owners/gyro input is consumed")
	_ok(np.set_aux_pointer(self, 2, 3, 700, -800, true),
		"owners/the fourth IR point is consumed")
	var aux: Array = np._local_aux[2]
	_eq(aux[0], (1 << 1) | (1 << 2) | (1 << 7),
		"owners/aux validity tracks sensor, gyro and pointer independently")
	_eq([aux[4], aux[5], aux[6]], [101, -202, 303],
		"owners/the second accelerometer keeps its own values")
	_eq([aux[7], aux[8], aux[9]], [-404, 505, -606], "owners/gyro axes stay signed")
	_eq([aux[22], aux[23], aux[24]], [700, -800, 1],
		"owners/the fourth pointer keeps its state")

	# Reassigning a port must not carry its former owner's last held button into
	# the new owner's first frame.
	np._pending_local_route[0] = [0xFFFF, 1, 2, 3, 4]
	np._complete_upto = 10
	np._delay = 2
	np._schedule_transfer(0, 7)
	_ok(not np._pending_local_route.has(0), "owners/a handoff clears stale local input")

	# Reliable topology/media barriers cannot freeze the session forever if a
	# connected peer wedges without disconnecting.
	np._link_deadlines[4] = 99
	np._disc_deadlines[5] = 200
	_eq(np._expired_operation(100), "link operation 4 acknowledgement timed out",
		"owners/a link acknowledgement has a deadline")
	np._link_deadlines.clear()
	_eq(np._expired_operation(201), "disc operation 5 acknowledgement timed out",
		"owners/a disc acknowledgement has a deadline")
	np._disc_deadlines.clear()
	np._reset_deadlines[6] = 300
	_eq(np._expired_operation(300), "reset 6 acknowledgement timed out",
		"owners/a reset acknowledgement has a deadline")

	np._running = false
	np._system = sys
	np._group = grp
	np.get_parent().queue_free()
	await get_tree().process_frame


# ══ Assembly ══════════════════════════════════════════════════════════════════

func _test_assemble() -> void:
	var np := _stub_session()
	np._set_owners({0: 1, 1: 5})

	np._recv_put(0, 0, [1, 0, 0, 0, 0])
	_ok(not np._frame_ready(0), "assemble/a frame missing an owned port is not ready")
	np._recv_put(0, 1, [2, 0, 0, 0, 0])
	_ok(np._frame_ready(0), "assemble/with every port present it is")

	# Unowned is not the same as missing. A dropped controller would otherwise
	# stall the assembler for ever, waiting on a peer that does not exist.
	np._set_owners({0: 1, 1: 0})
	np._recv.clear()
	np._recv_put(3, 0, [1, 0, 0, 0, 0])
	_ok(np._frame_ready(3), "assemble/an unowned port does not hold a frame up")

	# Pruning keeps the tables bounded during a long game. What it must never
	# drop is anything at or ahead of the gate.
	np._next_post = 500
	for f in [100, 379, 380, 381, 499, 500, 600]:
		np._frames[f] = PackedInt32Array()
		np._local_inputs[f] = {}
		np._crc_table[f] = {}
	np._prune()
	var floor_frame: int = 500 - NetplaySession.PRUNE_BEHIND
	_ok(not np._frames.has(100), "assemble/prune drops what is far behind")
	_ok(not np._frames.has(floor_frame - 1), "assemble/right up to the floor")
	_ok(np._frames.has(floor_frame), "assemble/and keeps the floor itself")
	_ok(np._frames.has(500) and np._frames.has(600),
		"assemble/never touching the gate or what is ahead of it")
	_ok(not np._local_inputs.has(100) and not np._crc_table.has(100),
		"assemble/every per-frame table is pruned together")

	# A landed handoff is dropped only once the pipeline has posted past it;
	# dropping it early would let a late packet be credited to the wrong peer.
	np._pending[0] = {"frame": 500, "old": 1, "new": 5, "applied": true}
	np._next_post = 500
	np._prune()
	_ok(np._pending.has(0), "assemble/a handoff survives until the gate passes it")
	np._next_post = 501
	np._prune()
	_ok(not np._pending.has(0), "assemble/and is dropped once it has")

	np.get_parent().queue_free()
	await get_tree().process_frame


# ══ Cold start ════════════════════════════════════════════════════════════════
# The asynchronous part, and where three of the four cross-platform bugs lived.
# StartContent spins the emulation thread and returns; the core may still be
# missing, refused or wedged. Until it reports an identity there is nothing to
# be ready WITH.

func _test_start() -> void:
	# The host does not invite anyone until its own core is up, because until
	# then it cannot say what build everybody has to match.
	var w := await _pair()
	w.host_sys.lib.ready_after = 6
	var started: bool = w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 1: w.client_id}, 3, 0)
	_ok(started, "start/the host accepts the request")
	await _await_frames(2)
	_ok(not w.client_sys.started, "start/and invites nobody while its own core comes up")
	_ok(w.host_np.is_active(), "start/but counts as active, so a second press is refused")
	_ok(not w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 1: w.client_id}, 3, 0), "start/which it is")
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"start/a slow core still gets there")
	_ok(w.client_sys.started, "start/and the client started its core too")

	# The whole point of fix #2: the peer runs the core the HOST named. Its own
	# default is a per-player, per-platform answer — a core the buildbot ships
	# for Windows may not exist for Android at all.
	_eq(w.client_sys.started_core, "fceumm",
		"start/the client runs the host's core, not its own default")
	_eq(w.host_sys.started_core, "fceumm", "start/and so does the host")
	_ok(w.client_sys.default_core != "fceumm",
		"start/(the client's own default really was something else)")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)

	# A peer that cannot start a core at all. This is the cross-platform case:
	# the core is not installed for this platform, or the machine has no
	# cartridge. It must report the failure, never report itself ready.
	w = await _pair()
	w.client_sys.refuse = true
	var stops: Array = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return stops.size() > 0),
		"start/a peer with no core ends the cold start")
	_ok(not w.host_np.is_running(), "start/rather than leaving the host running alone")
	_ok(str(stops[0] if stops.size() > 0 else "").contains("core"),
		"start/and the reason says so")
	_free(w)

	# A core that comes up but is a DIFFERENT BUILD. Same core name, same ROM,
	# two nightlies: this is what cross-platform play looks like by default,
	# because the four platforms build from four directories at four times.
	w = await _pair()
	w.client_sys.lib.identity = IDENT_A.duplicate()
	w.client_sys.lib.identity["library_version"] = "(SVN 2026-08-20)"
	stops = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return stops.size() > 0),
		"start/a peer on a different build of the same core is refused")
	var why: String = str(stops[0] if stops.size() > 0 else "")
	_ok(why.contains("mismatch"), "start/and the reason is the mismatch, not a desync")
	_ok(why.contains("(SVN 2026-08-20)"), "start/naming the build that differs")
	_ok(not w.client_np.is_running(), "start/the refusing peer stops itself too")
	_free(w)

	# The same, one field over: a build whose savestates are a different size.
	# Left alone this surfaces much later, as a failed late join.
	w = await _pair()
	w.client_sys.lib.identity = IDENT_A.duplicate()
	w.client_sys.lib.identity["serialize_size"] = 20000
	stops = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return stops.size() > 0),
		"start/a build with different savestates is refused")
	_ok(str(stops[0] if stops.size() > 0 else "").contains("savestate"),
		"start/and the reason names the savestate, not the version")
	_free(w)

	# READINESS MUST NOT COST A FRAME. The gate runs frame 0 only once inputs
	# for it are posted, which happens only once every peer is ready, and being
	# ready IS reporting an identity. A core that only identifies itself after
	# running deadlocks that circle, and it is not a hypothetical: the identity
	# was briefly published after the first retro_run (to keep Dolphin from
	# being asked its savestate size before it had a machine to measure) and
	# every real cold start hung until its deadline.
	w = await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"start/a normal cold start completes")
	_eq(w.host_sys.lib.frames_at_identity, 0,
		"start/the host answered ready with no frame run")
	_eq(w.client_sys.lib.frames_at_identity, 0,
		"start/and so did the client")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)

	# The same thing from the other side: a core that WILL not identify itself
	# until it has run must fail, not quietly half-start. If this one ever goes
	# green, the gate has stopped gating.
	w = await _pair()
	w.client_sys.lib.identity_needs_frame = true
	stops = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	await _until(func() -> bool: return not w.client_np._await_core.is_empty())
	w.client_np._await_deadline = Time.get_ticks_msec() + 150
	_ok(await _until(func() -> bool: return stops.size() > 0),
		"start/a core that identifies itself only after a frame cannot start")
	_eq(w.client_sys.lib.GetFrameCount(), 0,
		"start/because the gate never let it run one")
	_free(w)

	# A core that never comes up. StartContent succeeded, the node exists, and
	# nothing will ever load — the deadline is the only thing between that and
	# a peer that reports ready with no core behind it.
	w = await _pair()
	w.client_sys.lib.ready_after = 1 << 30
	stops = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	await _until(func() -> bool: return not w.client_np._await_core.is_empty())
	w.client_np._await_deadline = Time.get_ticks_msec() + 150
	_ok(await _until(func() -> bool: return stops.size() > 0),
		"start/a core that never loads times out")
	_ok(str(stops[0] if stops.size() > 0 else "").contains("did not come up"),
		"start/and says it never came up")
	_free(w)

	# The host's own core failing is a refusal at the door, not a stopped
	# session: nobody was ever invited.
	w = await _pair()
	w.host_sys.refuse = true
	_ok(not w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 1: w.client_id}, 3, 0), "start/a host with no core refuses to host")
	_ok(not w.host_np.is_active(), "start/and is left with nothing running")
	_free(w)

	# An unverified core is refused before any of this — the allowlist is the
	# outer gate and nothing about identity can open it.
	w = await _pair()
	_ok(not w.host_nm.netplay_start_host(w.host_sys, "__never_vetted", "MD5",
		{0: 1, 1: w.client_id}, 3, 0), "start/an unvetted core cannot host")
	_ok(not w.host_sys.started, "start/and its core is never even started")
	_free(w)


# ══ The pipeline ══════════════════════════════════════════════════════════════

func _test_lockstep() -> void:
	var w := await _pair()
	var desyncs: Array = []
	w.host_np.desync_detected.connect(func(pid: int, f: int) -> void: desyncs.append([pid, f]))
	w.host_np._pending_local_route[0] = [0x0F, 100, -200, 0, 0]
	w.client_np._pending_local_route[1] = [0xF0, -50, 75, 0, 0]

	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"lockstep/both peers reach running")
	await _await_frames(240)
	var hc: int = w.host_sys.lib.GetFrameCount()
	var cc: int = w.client_sys.lib.GetFrameCount()
	# Headless ticks are uncapped, so throughput here is latency-bound (about
	# `delay` frames per loopback round trip) rather than one frame per 16.6 ms.
	_ok(hc >= 40, "lockstep/the pipeline flows (%d frames)" % hc)
	_ok(absi(hc - cc) <= 10, "lockstep/and both peers stay together (%d vs %d)" % [hc, cc])
	_eq(desyncs.size(), 0, "lockstep/a clean run reports no desync")

	# Exercise the expanded device frame over real ENet, not just the packers.
	w.host_np.set_aux_sensor(w.host_sys, 0, 0, 111, -222, 333)
	w.host_np.set_aux_sensor(w.host_sys, 0, 0, -444, 555, -666, true)
	w.host_np.set_aux_pointer(w.host_sys, 0, 3, 1234, -2345, true)
	w.client_np.set_aux_sensor(w.client_sys, 1, 1, 777, 888, -999)
	w.host_np._pending_local_route.erase(0)
	w.host_np.set_lightgun_button(w.host_sys, 0, 2, true)
	w.host_np.set_lightgun_aim(w.host_sys, 0, -3000, 4000, false)
	await _await_frames(40)
	var host_frame: PackedInt32Array = w.host_sys.lib.last_input
	var client_frame: PackedInt32Array = w.client_sys.lib.last_input
	_eq(host_frame, client_frame,
		"lockstep/lightgun, accelerometer, gyro and pointer data agree end to end")
	_eq([host_frame[0], host_frame[1], host_frame[2], host_frame[3]],
		[1 << 2, -3000, 4000, 0], "lockstep/the lightgun state keeps its port layout")
	_eq([host_frame[20], host_frame[21], host_frame[22], host_frame[23]],
		[(1 << 0) | (1 << 2) | (1 << 7), 111, -222, 333],
		"lockstep/the primary accelerometer and validity flags arrive")
	_eq([host_frame[27], host_frame[28], host_frame[29]], [-444, 555, -666],
		"lockstep/gyro axes arrive on the same controller port")
	_eq([host_frame[42], host_frame[43], host_frame[44]], [1234, -2345, 1],
		"lockstep/the fourth IR point arrives")
	_eq([host_frame[49], host_frame[50], host_frame[51]], [777, 888, -999],
		"lockstep/a second port keeps its second sensor separate")

	# One peer stops sending. Lockstep means exactly this: everyone waits.
	var before: int = w.host_sys.lib.GetFrameCount()
	w.client_np._running = false
	await _await_frames(40)
	var during: int = w.host_sys.lib.GetFrameCount()
	_ok(during - before <= 8, "lockstep/a stalled peer freezes the host too (%d to %d)"
		% [before, during])
	w.client_np._running = true
	w.client_np._last_progress_ms = Time.get_ticks_msec()
	await _await_frames(120)
	var after: int = w.host_sys.lib.GetFrameCount()
	_ok(after > during + 10, "lockstep/and the pipeline resumes when it comes back")
	_ok(absi(after - w.client_sys.lib.GetFrameCount()) <= 12,
		"lockstep/reconverging rather than drifting")

	# Stopping while stalled must not deadlock: the host is blocked at the gate
	# and the client is not answering.
	w.client_np._running = false
	await _await_frames(20)
	w.host_nm.netplay_stop("test stop")
	await _await_frames(20)
	_ok(not w.host_np.is_running(), "lockstep/a stop during a stall lands")
	_ok(not w.host_np.is_active(), "lockstep/leaving nothing active")
	_ok(not w.client_np.is_running(), "lockstep/and reaches the stalled peer")
	_ok(w.client_sys.stopped, "lockstep/whose core is stopped, not left running")
	_free(w)

	# A room transition invalidates every system node in the group. It must stop
	# the game before ObjectSync clears those ids, or both gates wait forever on
	# cores that belonged to the previous room.
	w = await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.client_np.is_running()),
		"lockstep/a game is running before a client room transition")
	w.client_nm._on_scene_changed("different_room")
	_ok(await _until(func() -> bool:
		return not w.host_np.is_active() and not w.client_np.is_active()),
		"lockstep/a room transition stops netplay on every peer")
	_free(w)

	# A peer can remain connected while its main thread is wedged. Reliable RPC
	# then never ACKs, so the explicit operation deadline must release the gate.
	w = await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running()),
		"lockstep/a game is running before an operation ACK timeout")
	w.host_np._link_waiting[99] = {w.client_id: true}
	w.host_np._link_deadlines[99] = Time.get_ticks_msec() - 1
	w.host_np._check_stall()
	_ok(await _until(func() -> bool: return not w.host_np.is_active()),
		"lockstep/a missing operation ACK stops instead of freezing forever")
	_free(w)


# ══ Desync ════════════════════════════════════════════════════════════════════

func _test_desync() -> void:
	var w := await _pair()
	var desyncs: Array = []
	w.host_np.desync_detected.connect(func(pid: int, f: int) -> void: desyncs.append([pid, f]))
	w.client_sys.lib.desync = true
	w.host_np._pending_local_route[0] = [0x01, 0, 0, 0, 0]
	w.client_np._pending_local_route[1] = [0x02, 0, 0, 0, 0]
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return desyncs.size() > 0, 900),
		"desync/a peer whose core diverges is caught")
	_eq(int(desyncs[0][0]) if desyncs.size() > 0 else -1, w.client_id,
		"desync/and named")
	# Three strikes: a peer that will not converge is demoted rather than left
	# stalling the assembler for everyone else.
	_ok(await _until(func() -> bool:
			return w.host_np._spectators.has(w.client_id), 1800),
		"desync/one that keeps diverging becomes a spectator")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)

	# ── Under determinism, there is nothing to repair with ────────────────────
	# The strike-and-resync path above ships a savestate to put the odd one out
	# back in step. A determinism session's cores cannot reproduce one, so the
	# same three strikes would just mean the diverged peer plays on with a
	# machine nobody else agrees with, sending input the host drops. Report the
	# frame and stop, which is what Dolphin's own netplay does.
	NetplayCores.debug_allow_unverified = true
	var d := await _pair()
	d.host_sys.machine_core = "dolphin"
	d.client_sys.machine_core = "dolphin"
	var reasons: Array = []
	d.host_np.session_stopped.connect(func(r: String) -> void: reasons.append(r))
	d.client_sys.lib.desync = true
	d.host_np._pending_local_route[0] = [0x01, 0, 0, 0, 0]
	d.client_np._pending_local_route[1] = [0x02, 0, 0, 0, 0]
	d.host_nm.netplay_start_host(d.host_sys, "dolphin", "MD5", {0: 1, 1: d.client_id}, 3, -1)
	_ok(await _until(func() -> bool: return d.host_np.is_running()),
		"desync/a determinism session is running")
	_eq(d.host_np._strategy, NetplayCores.Strategy.DETERMINISM,
		"desync/and really is on determinism")
	_ok(await _until(func() -> bool: return not reasons.is_empty(), 1800),
		"desync/the first disagreement stops it, rather than striking three times")
	_ok(str(reasons[-1] if not reasons.is_empty() else "").contains("frame"),
		"desync/and the reason names the frame it happened on")
	_ok(not d.host_np._spectators.has(d.client_id),
		"desync/nobody is demoted, because nobody was repaired")
	NetplayCores.debug_allow_unverified = false
	await _await_frames(5)
	_free(d)


# ══ Late join ═════════════════════════════════════════════════════════════════

func _test_join() -> void:
	var w := await _pair()
	w.host_np._pending_local_route[0] = [0x01, 0, 0, 0, 0]
	w.client_np._pending_local_route[1] = [0x02, 0, 0, 0, 0]
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running()),
		"join/a game is running to join")
	await _await_frames(60)
	w.host_sys.lib.save_size = NetplaySession.STATE_CHUNK_SIZE * 2 + 123

	# A third player arrives mid-game. The host stalls everyone, ships a
	# savestate, and resumes once the newcomer has loaded it.
	var third := _branch("J")
	var jsys := MockSys.new()
	jsys.name = "Sys"
	third.add_child(jsys)
	third._netplay.system_override = jsys
	var jnp: NetplaySession = third._netplay
	third.join_game("::1", PORT)
	_ok(await _until(func() -> bool: return w.host_nm.peers.size() == 3),
		"join/the newcomer is in the roster")
	_ok(await _until(func() -> bool: return jnp.is_running(), 900),
		"join/and is running the same game")
	_ok(jsys.started, "join/having started a core of its own")
	_eq(jsys.started_core, "fceumm", "join/the host's core, again")
	_ok(jsys.lib.loaded_state, "join/from the host's savestate rather than from boot")
	_eq(jsys.lib.loaded_state_size, NetplaySession.STATE_CHUNK_SIZE * 2 + 123,
		"join/a multi-chunk state arrives complete")
	_ok(jsys.lib.GetFrameCount() > 0, "join/at the frame the game had reached")
	_ok(await _until(func() -> bool: return not w.host_np._join_paused),
		"join/and the pipeline is running again for everyone")
	var at_resume: int = w.host_sys.lib.GetFrameCount()
	await _await_frames(90)
	_ok(w.host_sys.lib.GetFrameCount() > at_resume, "join/which really does advance")

	w.host_nm.netplay_stop("done")
	await _await_frames(10)
	third.get_parent().queue_free()
	_free(w)
	await _await_frames(5)

	# A newcomer on a different build. The identity check has to hold on the
	# late-join path too, or the one route that ships a savestate between two
	# peers is the one route with no build check on it.
	w = await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	await _until(func() -> bool: return w.host_np.is_running())
	await _await_frames(40)
	var odd := _branch("K")
	var osys := MockSys.new()
	osys.name = "Sys"
	odd.add_child(osys)
	osys.lib.identity = IDENT_A.duplicate()
	osys.lib.identity["library_version"] = "(SVN 2026-08-19)"
	odd._netplay.system_override = osys
	odd.join_game("::1", PORT)
	_ok(await _until(func() -> bool: return w.host_np._spectators.has(_other_id(w.host_nm, w.client_id)), 900),
		"join/a newcomer on a different build is refused")
	_ok(not osys.lib.loaded_state, "join/and never loads the host's savestate")
	_ok(w.host_np.is_running(), "join/while the running game carries on without them")
	w.host_nm.netplay_stop("done")
	await _await_frames(10)
	odd.get_parent().queue_free()
	_free(w)
	await _await_frames(5)

	# A failed host snapshot must release the gate and demote only the newcomer.
	# Leaving _joining populated here freezes the existing game forever.
	w = await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	await _until(func() -> bool: return w.host_np.is_running())
	await _await_frames(40)
	w.host_sys.lib.save_fails = true
	var broken := _branch("JF")
	var bsys := MockSys.new()
	bsys.name = "Sys"
	broken.add_child(bsys)
	broken._netplay.system_override = bsys
	broken.join_game("::1", PORT)
	_ok(await _until(func() -> bool:
		var newcomer := _other_id(w.host_nm, w.client_id)
		return newcomer > 0 and w.host_np._spectators.has(newcomer), 900),
		"join/a failed host snapshot demotes the newcomer")
	_ok(not w.host_np._join_paused and w.host_np._joining.is_empty(),
		"join/and releases every late-join gate")
	var after_failure: int = w.host_sys.lib.GetFrameCount()
	await _await_frames(90)
	_ok(w.host_sys.lib.GetFrameCount() > after_failure,
		"join/the existing game advances after snapshot failure")
	w.host_nm.netplay_stop("done")
	await _await_frames(10)
	broken.get_parent().queue_free()
	_free(w)
	await _await_frames(5)

	# A core that never answers save must not hold every existing player at the
	# frozen boundary forever. Drive the deadline directly so the test stays fast.
	w = await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	await _until(func() -> bool: return w.host_np.is_running())
	w.host_sys.lib.save_hangs = true
	var hung := _branch("JH")
	var hsys := MockSys.new()
	hsys.name = "Sys"
	hung.add_child(hsys)
	hung._netplay.system_override = hsys
	hung.join_game("::1", PORT)
	_ok(await _until(func() -> bool:
		return w.host_np._join_paused and not w.host_np._joining.is_empty(), 900),
		"join/a non-answering save reaches the bounded capture phase")
	var hung_id := _other_id(w.host_nm, w.client_id)
	w.host_np._join_deadlines[hung_id] = 0
	w.host_np._check_join_timeouts()
	_ok(not w.host_np._join_paused and w.host_np._spectators.has(hung_id),
		"join/a save timeout releases the game and demotes only the newcomer")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	hung.get_parent().queue_free()
	_free(w)
	await _await_frames(5)

	# A peer whose core rejects the received state cleans the partially started
	# core up before remaining a spectator.
	w = await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	await _until(func() -> bool: return w.host_np.is_running())
	var load_bad := _branch("JL")
	var lsys := MockSys.new()
	lsys.name = "Sys"
	lsys.lib.load_fails = true
	load_bad.add_child(lsys)
	var lnp: NetplaySession = load_bad._netplay
	lnp.system_override = lsys
	load_bad.join_game("::1", PORT)
	_ok(await _until(func() -> bool:
		var newcomer := _other_id(w.host_nm, w.client_id)
		return newcomer > 0 and w.host_np._spectators.has(newcomer), 900),
		"join/a rejected state leaves the newcomer as a spectator")
	_ok(lsys.stopped and lnp._group.is_empty(),
		"join/and tears down its partially started core and session state")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	load_bad.get_parent().queue_free()
	_free(w)
	await _await_frames(5)

	# The receiver has its own deadline after the stream, covering a core that
	# accepts the command but never reports whether the state loaded.
	w = await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	await _until(func() -> bool: return w.host_np.is_running())
	var load_hung := _branch("JLT")
	var lhsys := MockSys.new()
	lhsys.name = "Sys"
	lhsys.lib.load_hangs = true
	load_hung.add_child(lhsys)
	var lh_np: NetplaySession = load_hung._netplay
	lh_np.system_override = lhsys
	load_hung.join_game("::1", PORT)
	_ok(await _until(func() -> bool:
		return lhsys.started and lh_np._join_receive_deadline > 0 \
			and lh_np._await_core.is_empty(), 900),
		"join/a non-answering load reaches the bounded load phase")
	# Zero means disabled in normal operation; use an already-expired positive
	# value to exercise the timeout branch.
	lh_np._join_receive_deadline = 1
	lh_np._check_join_timeouts()
	_ok(lhsys.stopped, "join/a load timeout stops the partially loaded core")
	_ok(lh_np._group.is_empty(), "join/a load timeout clears the local session state")
	_ok(await _until(func() -> bool:
		var newcomer := _other_id(w.host_nm, w.client_id)
		return newcomer > 0 and w.host_np._spectators.has(newcomer), 900),
		"join/and tells the host to resume without it")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	load_hung.get_parent().queue_free()
	_free(w)

	# ── A core that cannot put a state on the wire ────────────────────────────
	# gambatte plays perfectly from a cold start and cannot reproduce its own
	# savestate, so there is nothing to send a latecomer. That is a legitimate
	# answer; saying it OUT LOUD is the part that was missing. Standing in the
	# room beside a cabinet that is visibly being played, with a blank screen and
	# no explanation anywhere, is indistinguishable from the game being broken.
	#
	# Dolphin is the core this is written against, and it has to be: every other
	# entry can now put a state on the wire, so gambatte -- which used to be the
	# example -- would simply late-join and never reach this path. The debug
	# override lets it start; it deliberately does NOT reach across into state
	# transfer, which is exactly the combination needed here.
	NetplayCores.debug_allow_unverified = true
	var g := await _pair()
	g.host_sys.machine_core = "dolphin"
	g.client_sys.machine_core = "dolphin"
	g.host_nm.netplay_start_host(g.host_sys, "dolphin", "MD5", {0: 1, 1: g.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return g.host_np.is_running()),
		"join/a game with no transferable state is running")

	var latecomer := _branch("L")
	var late_sys := MockSys.new()
	late_sys.name = "Sys"
	late_sys.machine_core = "dolphin"
	latecomer.add_child(late_sys)
	latecomer._netplay.system_override = late_sys
	var told := []
	latecomer.status_changed.connect(func(text: String) -> void: told.append(text))
	latecomer.join_game("::1", PORT)
	_ok(await _until(func() -> bool: return g.host_nm.peers.size() == 3),
		"join/the latecomer is in the room")
	# The status line carries connection chatter too, so look for the refusal
	# among what arrived rather than assuming it is the last thing said.
	var refused := func() -> bool:
		for t: String in told:
			if t.contains("RESET"):
				return true
		return false
	_ok(await _until(refused),
		"join/and is TOLD it cannot join this one, rather than left blank")
	_ok(await _until(func() -> bool:
			return g.host_np._spectators.has(_other_id(g.host_nm, g.client_id))),
		"join/the host keeps them as a spectator")
	_ok(g.host_np.is_running(),
		"join/and the game the others are playing carries on")

	# ── Reaching for a pad is how they ask ────────────────────────────────────
	# Ownership follows whoever is HOLDING a controller, so picking one up is
	# already the gesture for taking a turn. A spectator doing it used to be
	# dropped on the floor by the same line that stops a departed peer owning a
	# port. It is the one moment we know somebody wants in.
	var late_id := _other_id(g.host_nm, g.client_id)
	var asked: Array = []
	g.host_np.join_requested.connect(func(pid: int, port: int) -> void: asked.append([pid, port]))
	g.host_np.handoff_port(g.host_sys, 0, late_id)
	_eq(asked.size(), 1, "join/a spectator reaching for a pad asks to play")
	_eq(int(asked[0][0]) if not asked.is_empty() else -1, late_id,
		"join/and the machine knows who it was")
	_ok(g.host_np.pending_join_peers().has(late_id),
		"join/the request waits for somebody to act on it")

	# The other half. A player already in the game picking up a pad must still
	# just take the port, or this reads as "every grab is a join request".
	var before := g.host_np.pending_join_peers().size()
	g.host_np.handoff_port(g.host_sys, 0, g.client_id)
	_eq(g.host_np.pending_join_peers().size(), before,
		"join/a player already in the game is handed the port, not queued")

	# Asking twice is still one person waiting.
	g.host_np.handoff_port(g.host_sys, 1, late_id)
	_eq(g.host_np.pending_join_peers().size(), 1,
		"join/asking again does not queue them twice")

	# What RESET does while somebody is waiting: start the game again with them
	# in it. A scheduled retro_reset would keep the session, and with it the
	# ownership decided before they arrived.
	#
	# The mechanism, not the button. RetroSystem.reset() picks this over
	# netplay_schedule_reset when a claim is pending, and MockSys is not a
	# RetroSystem, so the dispatch itself is only exercised on a real machine.
	_ok(g.host_nm.netplay_rejoin_restart(g.host_sys),
		"join/a restart to admit them is accepted")
	_ok(await _until(func() -> bool: return g.host_np.is_running(), 1800),
		"join/and a fresh session comes up")
	_ok(g.host_np.pending_join_peers().is_empty(),
		"join/with nobody left waiting")

	# And it refuses when nobody is: RESET must stay an ordinary reset then.
	_ok(not g.host_nm.netplay_rejoin_restart(g.host_sys),
		"join/with no one waiting there is nothing to restart for")

	g.host_nm.netplay_stop("done")
	await _await_frames(5)
	NetplayCores.debug_allow_unverified = false
	latecomer.queue_free()
	_free(g)


# ══ What a state costs on the wire ════════════════════════════════════════════
# A late join and every desync resync ship a full savestate per machine, and on
# a heavy core that is the difference between a pause and a session nobody
# waits out. A real Dolphin state measured 92291907 bytes; compressed, 6590109,
# in 48 ms. Nothing in this path used to compress at all.

func _test_transfer() -> void:
	# The mechanism, against the constant the protocol actually uses. A console
	# savestate is mostly zeroed RAM, which is why the real ratio is a few
	# percent rather than the ~50% a small structured payload gives.
	var raw := PackedByteArray()
	raw.resize(1 << 20)
	for i in range(0, raw.size(), 4096):
		raw[i] = (i / 4096) & 0xFF          # sparse, like real RAM
	var packed := raw.compress(NetplaySession.STATE_COMPRESSION)
	_ok(packed.size() < raw.size() / 4,
		"transfer/a sparse state compresses to well under a quarter (%d -> %d)"
			% [raw.size(), packed.size()])
	var back := packed.decompress(raw.size(), NetplaySession.STATE_COMPRESSION)
	_eq(back.size(), raw.size(), "transfer/and decompresses to its declared size")
	_ok(back == raw, "transfer/byte for byte")

	# The size has to be carried, not guessed: decompress() needs it up front,
	# and it is also the only bound on what a manifest can make a peer allocate.
	var short_guess := packed.decompress(raw.size() / 2, NetplaySession.STATE_COMPRESSION)
	_ok(short_guess.size() != raw.size(),
		"transfer/a wrong declared size does not silently yield the right buffer")

	# End to end: a joiner must receive every byte the host saved, through
	# compress, chunk, hash-verify and decompress. Two chunks' worth plus a
	# remainder, so the last partial chunk is exercised too.
	var w := await _pair()
	var big := NetplaySession.STATE_CHUNK_SIZE * 3 + 977
	w.host_sys.lib.save_size = big
	w.host_np._pending_local_route[0] = [0x01, 0, 0, 0, 0]
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running()),
		"transfer/a game is running to join")
	await _await_frames(60)

	var third := _branch("T")
	var tsys := MockSys.new()
	tsys.name = "Sys"
	third.add_child(tsys)
	third._netplay.system_override = tsys
	third.join_game("127.0.0.1", PORT)
	_ok(await _until(func() -> bool: return tsys.lib.loaded_state, 900),
		"transfer/the joiner loaded a state")
	_eq(tsys.lib.loaded_state_size, big,
		"transfer/every byte survived compress, chunk and decompress")
	w.host_nm.netplay_stop("done")
	await _await_frames(10)
	third.get_parent().queue_free()
	_free(w)


# ══ Somebody leaves ═══════════════════════════════════════════════════════════

func _test_leave() -> void:
	# A port owner walking out stalls the assembler for ever — there is nobody
	# left to supply that port — so the game ends for everyone.
	var w := await _pair()
	var stops: Array = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running()), "leave/a game is running")
	w.host_np.on_peer_left(w.client_id)
	_ok(stops.size() > 0, "leave/a departing port owner ends the game")
	_ok(not w.host_np.is_running(), "leave/for the host too")
	_free(w)

	# A peer that owns nothing is just cleaned up.
	w = await _pair()
	stops = []
	w.host_np.session_stopped.connect(func(r: String) -> void: stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running()),
		"leave/a one-owner game runs")
	w.host_np.on_peer_left(w.client_id)
	_eq(stops.size(), 0, "leave/a departing spectator does not end it")
	_ok(w.host_np.is_running(), "leave/and it keeps running")

	# A handoff in flight to or from the departed peer would stall the gate at
	# its boundary: nobody supplies that port for the affected frames.
	w.host_np._pending[0] = {"frame": 9999, "old": 1, "new": 4242, "applied": false}
	w.host_np.on_peer_left(4242)
	_ok(stops.size() > 0, "leave/a pending handoff to a departed peer ends it")
	_free(w)


# ══ Rollback and the link cable ═══════════════════════════════════════════════
# Rollback rewinds ONE core. A cabled machine's state is half a conversation, so
# rewinding one end replays a transfer the far end has already answered — and
# both peers are then wrong in the same way, which the CRC checker cannot see.

func _test_rollback() -> void:
	var w := await _pair()
	var owners := {0: 1, 1: w.client_id}

	w.host_sys.lib.link_peers = {}
	_ok(w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1),
		"rollback/an uncabled machine starts")
	_ok(w.host_np._rollback, "rollback/and is allowed to roll back")
	await _until(func() -> bool: return w.host_np.is_running())
	w.host_np.handoff_port(w.host_sys, 0, w.client_id)
	_ok(await _until(func() -> bool: return not w.client_sys.lib.rollback_masks.is_empty()),
		"rollback/an ownership change reaches every peer's emulation gate")
	_ok(not w.host_sys.lib.rollback_masks.is_empty(),
		"rollback/the host schedules its own mask too")
	var transfer_frame := int(w.host_sys.lib.rollback_masks[-1][0])
	_eq(w.host_sys.lib.rollback_masks[-1][1], 0,
		"rollback/the old owner stops sampling at the boundary")
	_eq(w.client_sys.lib.rollback_masks[-1][1], 0b11,
		"rollback/the new owner samples both of its ports there")
	w.host_np._apply_pending_transfers(transfer_frame)
	w.client_np._apply_pending_transfers(transfer_frame)
	_eq(w.host_np._owners[0], w.client_id,
		"rollback/the logical owner lands on the same scheduled frame")
	_ok(w.host_np.is_running() and w.client_np.is_running(),
		"rollback/the session keeps running through the handoff")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)

	w.host_sys.lib.link_peers = {0: 2}
	_ok(w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1),
		"rollback/a cabled machine still starts")
	_ok(not w.host_np._rollback, "rollback/but in lockstep, whatever was asked for")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)

	# The far port counts too: a console lead sits on port 1, and a guard that
	# only looked at port 0 would wave it straight through.
	w.host_sys.lib.link_peers = {1: 2}
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1)
	_ok(not w.host_np._rollback, "rollback/a console lead counts as a cable")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)

	# A lead hanging out of a socket with nobody on the far end is not a link,
	# and refusing it would be rollback switched off everywhere.
	w.host_sys.lib.link_peers = {0: 1}
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1)
	_ok(w.host_np._rollback, "rollback/a lone machine on a bus still rolls back")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)

	# A room controller can be passed between hands and may carry motion data.
	# Starting it in rollback used to make both operations silently ineffective.
	var movable := MockController.new()
	w.host_sys.add_child(movable)
	w.host_sys._port_controllers = [movable]
	w.host_sys.lib.link_peers = {}
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1)
	_ok(not w.host_np._rollback,
		"rollback/a movable room peripheral forces the ownership-safe lockstep path")
	w.host_nm.netplay_stop("done")
	w.host_sys._port_controllers.clear()
	await _await_frames(5)

	# A fixed physical-pad receiver does not change input ownership when someone
	# moves its box, so it may keep rollback. A keyboard receiver cannot: key
	# transitions use the lockstep event tail rather than the native live slot.
	var receiver := MockPadReceiver.new()
	w.host_sys._port_controllers = [receiver]
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1)
	_ok(w.host_np._rollback, "rollback/a fixed gamepad receiver may still roll back")
	w.host_nm.netplay_stop("done")
	w.host_sys._port_controllers.clear()
	receiver.free()
	await _await_frames(5)
	var keyboard := MockKeyboardReceiver.new()
	w.host_sys._port_controllers = [keyboard]
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1)
	_ok(not w.host_np._rollback,
		"rollback/a keyboard receiver uses lockstep so key events are not lost")
	w.host_nm.netplay_stop("done")
	w.host_sys._port_controllers.clear()
	keyboard.free()
	await _await_frames(5)

	# Auto (-1) follows the core's own table rather than anything asked for.
	w.host_sys.lib.link_peers = {}
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, -1)
	_eq(w.host_np._rollback, NetplayCores.rollback_capable("fceumm"),
		"rollback/auto asks the core")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)


# ══ Which strategy a session runs under ═══════════════════════════════════════
# A session is a GROUP, and a cabled group can be heterogeneous — a GameCube
# joined to four Game Boy Advances is one session over Dolphin and mGBA at once.
# So the strategy is the intersection of what its machines are vetted for, not
# the anchor's answer: a strategy only half the group can hold is not one the
# session can hold.

func _test_strategy() -> void:
	var w := await _pair()
	var owners := {0: 1, 1: w.client_id}

	# Asking for rollback does not get it from a core with no evidence for it.
	# Dolphin is unverified, so the debug override is what lets it start at all;
	# the strategy it lands on is still the table's answer, not the caller's.
	NetplayCores.debug_allow_unverified = true
	w.host_sys.machine_core = "dolphin"
	_ok(w.host_nm.netplay_start_host(w.host_sys, "dolphin", "MD5", owners, 3, 1),
		"strategy/a determinism-only core starts")
	_eq(w.host_np._strategy, NetplayCores.Strategy.DETERMINISM,
		"strategy/on determinism, though rollback was asked for")
	_ok(not w.host_np._rollback, "strategy/and the rollback engine stays off")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)

	# Forcing lockstep cannot conjure it either: the group decides what exists.
	w.host_nm.netplay_start_host(w.host_sys, "dolphin", "MD5", owners, 3, 0)
	_eq(w.host_np._strategy, NetplayCores.Strategy.DETERMINISM,
		"strategy/nor does asking for lockstep give a core one it lacks")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	NetplayCores.debug_allow_unverified = false

	# An ordinary verified core is unaffected: still rollback when it can.
	w.host_sys.machine_core = "fceumm"
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", owners, 3, 1)
	_eq(w.host_np._strategy, NetplayCores.Strategy.ROLLBACK,
		"strategy/a rollback-capable core still rolls back")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	w.host_nm.leave_session()
	await _await_frames(5)

	# ── The intersection, over a real two-machine group ───────────────────────
	var c := await _pair_cabled()
	var cowners := {0: 1, 1: c.client_id}

	# fceumm is [rollback, lockstep] and mGBA is [lockstep, determinism]. The only
	# thing both hold is lockstep — which is also what the cable would have
	# forced, so this passes for the right reason only alongside the case below.
	c.host_far.machine_core = "mgba"
	c.client_far.machine_core = "mgba"
	_ok(c.host_nm.netplay_start_host(c.host_sys, "fceumm", "MD5", cowners, 3, 1),
		"strategy/a mixed group starts")
	_eq(c.host_np._strategy, NetplayCores.Strategy.LOCKSTEP,
		"strategy/on the one strategy both its cores hold")
	c.host_nm.netplay_stop("done")
	await _await_frames(5)

	# The pairing Four Swords Adventures actually needs: a console and a handheld
	# whose cores share determinism and nothing else. A cabled machine used to
	# mean lockstep unconditionally; this is the case that lands past it.
	NetplayCores.debug_allow_unverified = true
	c.host_sys.machine_core = "dolphin"
	c.client_sys.machine_core = "dolphin"
	_ok(c.host_nm.netplay_start_host(c.host_sys, "dolphin", "MD5", cowners, 3, 1),
		"strategy/a console cabled to a handheld starts")
	_eq(c.host_np._strategy, NetplayCores.Strategy.DETERMINISM,
		"strategy/on determinism, not the lockstep a cable used to force")
	c.host_nm.netplay_stop("done")
	await _await_frames(5)

	# And a cabled pair whose cores share NOTHING is a refusal, not a fallback.
	# fceumm holds rollback and lockstep; Dolphin holds only determinism.
	c.host_sys.machine_core = "fceumm"
	c.host_far.machine_core = "dolphin"
	_ok(not c.host_nm.netplay_start_host(c.host_sys, "fceumm", "MD5", cowners, 3, -1),
		"strategy/a group whose cores agree on nothing refuses to start")
	_ok(not c.host_np.is_running(), "strategy/and nothing is left running")
	NetplayCores.debug_allow_unverified = false
	await _await_frames(5)

	# The slowest machine sets the CRC pace, and it has to REACH the core: the
	# native hook has existed and gone uncalled, which left every core hashing at
	# a 2 KB machine's cadence.
	NetplayCores.debug_allow_unverified = true
	c.host_sys.machine_core = "dolphin"
	c.host_far.machine_core = "dolphin"
	c.client_sys.machine_core = "dolphin"
	c.client_far.machine_core = "dolphin"
	c.host_nm.netplay_start_host(c.host_sys, "dolphin", "MD5", cowners, 3, -1)
	_eq(c.host_sys.lib.crc_interval, NetplayCores.crc_interval("dolphin"),
		"strategy/the core is told how often to hash its RAM")
	_eq(c.host_far.lib.crc_interval, NetplayCores.crc_interval("dolphin"),
		"strategy/every machine on the bus, not just the anchor")
	c.host_nm.netplay_stop("done")
	await _await_frames(5)
	NetplayCores.debug_allow_unverified = false

	# Hashing a GameCube's 24 MB at a Game Boy's cadence would put the hitch on
	# every peer, because every peer runs every machine.
	var mixed: Array = [{"core": "fceumm"}, {"core": "dolphin"}]
	c.host_np._machine_specs = mixed
	_eq(c.host_np._group_crc_interval(), NetplayCores.crc_interval("dolphin"),
		"strategy/the group takes the longest CRC gap any machine asks for")
	c.host_np._machine_specs = [{"core": "fceumm"}]
	_eq(c.host_np._group_crc_interval(), NetplayCores.DEFAULT_CRC_INTERVAL,
		"strategy/and the default when nothing asks for more")

	# Cross-play is an AND: one same-arch-only core makes the whole group so,
	# because every peer runs every machine.
	_ok(c.host_np._group_allows_cross_play(),
		"strategy/a group of cross-play cores may cross architectures")
	c.host_np._machine_specs = mixed
	_ok(not c.host_np._group_allows_cross_play(),
		"strategy/one core that may not stops the whole group")

	c.host_nm.leave_session()
	await _await_frames(5)


# ══ A cabled pair ═════════════════════════════════════════════════════════════
# A link cable never crosses the network. LinkCoordinator is a process-wide
# singleton joining two cores in the SAME process, so under netplay every peer
# runs both machines and it is determinism, not a wire, that keeps the two
# buses agreeing.
#
# Which means a cabled pair is one session over TWO machines, and the session
# used to hold exactly one. The far machine was left out: on the host it ran
# anyway (it is in the room), on a client it did not run at all, so the client's
# gated core sat on a bus whose other end never published — and the coordinator
# waits for a peer that is behind rather than guessing, with deliberately no
# timeout. Host fine, client wedged, which is the worst shape a fault can have.

func _test_link() -> void:
	# A topology change cannot land while either local emulation thread is still
	# finishing an earlier frame. The old head-only schedule let the fast core
	# change the bus underneath the slow one.
	var barrier_np := _stub_session()
	var barrier_near := MockSys.new()
	var barrier_far := MockSys.new()
	barrier_np.add_child(barrier_near)
	barrier_np.add_child(barrier_far)
	barrier_near.lib.setup_gate(1, 5)
	barrier_far.lib.setup_gate(1, 4)
	barrier_np._group = [barrier_near, barrier_far]
	barrier_np._libs = [barrier_near.lib, barrier_far.lib]
	barrier_np._lib = barrier_near.lib
	barrier_np._next_post = 5
	barrier_np._frames[5] = barrier_np.flat_from_frame({}, {}, {})
	barrier_np._apply_link_op(1, PackedInt32Array([0, 1]),
		PackedInt32Array([0, 0]), 5)
	barrier_np._drain_to_core()
	_eq(barrier_np._next_post, 5,
		"link/a slow local core holds the topology boundary shut")
	_eq(barrier_near.lib.link_applied.size(), 0,
		"link/so the fast core cannot change the bus underneath it")
	barrier_far.lib.PostNetplayInputs(4, PackedInt32Array())
	barrier_np._drain_to_core()
	_eq(barrier_np._next_post, 6,
		"link/the boundary opens once every local core reaches it")
	_eq(barrier_near.lib.link_applied, [5],
		"link/and topology lands before the boundary frame runs")
	barrier_np.get_parent().queue_free()
	await get_tree().process_frame

	# The control. An uncabled machine is a group of one, and must stay one.
	var w := await _pair()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"link/an uncabled machine starts on its own")
	_eq(w.host_np.group_size(), 1, "link/and is a group of one")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)

	# A running machine does not need a cartridge to have state. In single-pak
	# GBA play the empty handheld boots its BIOS, receives a program into RAM and
	# then serializes like any other core. The cold-start descriptor, not a fake
	# ROM hash, is what a new peer needs before that state can be loaded.
	w = await _pair_cabled()
	w.host_far.boot_mode = "no_content"
	w.host_far.rom_md5 = ""
	w.host_far.boot_options = {"skip_bios": "off"}
	w.host_far.firmware_signature = "gba-bios-A"
	w.client_far.boot_mode = "no_content"
	w.client_far.rom_md5 = ""
	w.client_far.firmware_signature = "gba-bios-A"
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 4: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"link/a cartridge-less far machine cold-starts with the linked game")
	_eq(str(w.host_np._machine_specs[1].get("mode", "")), "no_content",
		"link/its BIOS-only launch mode replaces the nonexistent ROM hash")
	_eq((w.host_np._machine_specs[1].get("options", {}) as Dictionary).get("skip_bios"),
		"off", "link/the BIOS boot option is pinned for every peer")
	_eq(w.host_far.prepared_boot, "no_content",
		"link/the host prepares the BIOS-only core")
	_eq(w.client_far.prepared_boot, "no_content",
		"link/and every peer reproduces that boot before state transfer")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)

	# A matching core build is not enough when the firmware bytes differ: the
	# BIOS executes before the transferred program and is part of determinism.
	w = await _pair_cabled()
	w.host_far.boot_mode = "no_content"
	w.host_far.rom_md5 = ""
	w.host_far.firmware_signature = "gba-bios-A"
	w.client_far.boot_mode = "no_content"
	w.client_far.rom_md5 = ""
	w.client_far.firmware_signature = "gba-bios-B"
	var firmware_stops: Array = []
	w.host_np.session_stopped.connect(func(r: String) -> void: firmware_stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 4: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return not firmware_stops.is_empty()),
		"link/different BIOS bytes refuse the session")
	_ok(w.client_np._group.is_empty() and w.client_sys.stopped and w.client_far.stopped,
		"link/the rejected peer clears prepared media and partial session state")
	_free(w)

	# Empty-image BIOS boots (for example a PlayStation's no-disc screen) use a
	# different mechanism and must not accidentally take the null-content path.
	w = await _pair()
	w.host_sys.boot_mode = "empty_media"
	w.host_sys.rom_md5 = ""
	w.client_sys.boot_mode = "empty_media"
	w.client_sys.rom_md5 = ""
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "", {0: 1}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"link/a general empty-media BIOS boot can start a session")
	_eq(w.client_sys.prepared_boot, "empty_media",
		"link/the peer regenerates empty media instead of asking for a ROM")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_free(w)

	# A heterogeneous bus names every machine's core independently. Until both
	# have passed determinism vetting, refuse the session instead of silently
	# booting the far machine with the anchor's unrelated core.
	w = await _pair_cabled()
	# A name no table will ever hold. Using a real-but-unvetted core here ties
	# the case to that core staying unvetted, and it did not: snes9x passed and
	# turned this red for a reason that had nothing to do with the bus.
	w.host_far.machine_core = "__never_vetted"
	_ok(not w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 4: w.client_id}, 3, 0),
		"link/an unverified far-machine core refuses the whole bus")
	_ok(not w.host_sys.started and not w.host_far.started,
		"link/and no machine is launched with the wrong core")
	_free(w)

	# Build identity is per machine too. Matching anchors must not hide a
	# different far-end build whose savestate and arithmetic can diverge.
	w = await _pair_cabled()
	w.client_far.lib.identity = IDENT_A.duplicate()
	w.client_far.lib.identity["library_version"] = "(different far build)"
	var far_stops: Array = []
	w.host_np.session_stopped.connect(func(r: String) -> void: far_stops.append(r))
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5",
		{0: 1, 4: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return far_stops.size() > 0),
		"link/a far-machine build mismatch aborts the start")
	_ok(str(far_stops[0] if not far_stops.is_empty() else "").contains("machine 1"),
		"link/and identifies which machine differs")
	_free(w)

	# The pair. Both peers must bring up BOTH machines, or the bus is asymmetric.
	w = await _pair_cabled()
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 4: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running()),
		"link/a cabled pair starts")
	_eq(w.host_np.group_size(), 2, "link/as a group of two")
	_ok(w.host_far.started, "link/the host runs the far machine")
	_ok(w.client_far.started, "link/and so does the client — the bus needs both ends")
	_eq(w.client_far.started_core, "fceumm",
		"link/the far machine runs the host's core too")
	_eq(w.client_far.resolved_md5, "FAR_MD5",
		"link/the far machine verifies its own cartridge, not the anchor's")
	_eq(w.client_far.received_sram, PackedByteArray([9, 8, 7]),
		"link/and boots from its corresponding host save")
	_ok(w.host_sys.link_refreshes > 0 and w.client_sys.link_refreshes > 0,
		"link/each peer re-seats the bus after restarting its cores")
	w.client_np.set_aux_sensor(w.client_far, 0, 0, 111, -222, 333)
	_ok(w.client_np._local_aux.has(4),
		"link/the far machine can supply its own sensor block")
	_eq((w.client_np._local_aux[4] as Array)[1], 111,
		"link/without writing the anchor's sensor block")
	_ok(w.client_np.queue_key_event(w.client_far, 65, true, 97),
		"link/the far machine can queue its own keyboard input")
	_ok(w.client_np._local_keys.has(1),
		"link/and the event is scoped to that machine")

	# Ports are per machine, so the second machine's pad is a different port
	# from the first machine's pad, and both are in the same frame.
	await _await_frames(120)
	_ok(w.host_far.lib.GetFrameCount() > 0, "link/the far machine is actually running")
	_ok(absi(w.host_far.lib.GetFrameCount() - w.client_far.lib.GetFrameCount()) <= 10,
		"link/in step across peers, like the near one")
	_ok(absi(w.host_sys.lib.GetFrameCount() - w.host_far.lib.GetFrameCount()) <= 10,
		"link/and in step with the machine it is cabled to")
	var far_controller := MockController.new()
	far_controller._connected_system = w.host_far
	far_controller._port_index = 0
	w.host_nm.add_child(far_controller)
	w.host_np.handoff_controller(far_controller, 1)
	_ok(w.host_np._pending.has(4),
		"link/a controller on the far machine hands off its global port")
	w.host_np.schedule_disk_op(w.host_far, 0, "", 2)
	w.host_np.schedule_disk_op(w.host_far, 1, "FAR_DISC", 2)
	_ok(await _until(func() -> bool:
		return w.host_far.lib.disc_ops.size() == 2 and w.client_far.lib.disc_ops.size() == 2),
		"link/a far machine's disc operation reaches both peers")
	_eq(w.host_far.lib.disc_ops[0][0], w.host_far.lib.disc_ops[1][0],
		"link/rapid eject and replace keep both operations at one boundary")
	_ok(await _until(func() -> bool: return w.host_np._disc_waiting.is_empty()),
		"link/and every peer arms it before assembly resumes")
	_eq(w.host_sys.lib.disc_ops.size(), 0,
		"link/without being applied to the anchor machine")
	w.host_np.schedule_reset(w.host_far)
	_ok(await _until(func() -> bool:
		return w.host_far.lib.reset_ops.size() == 1 \
			and w.client_far.lib.reset_ops.size() == 1),
		"link/a far machine reset reaches both peers")
	_eq(w.host_far.lib.reset_ops[0], w.client_far.lib.reset_ops[0],
		"link/the reset lands on the same emulated frame")
	_ok(w.host_far.reset_visuals == 1 and w.client_far.reset_visuals == 1,
		"link/the reset effect is shown on both peers")
	_eq(w.host_sys.lib.reset_ops.size(), 0,
		"link/without resetting another machine in the group")
	_ok(await _until(func() -> bool: return w.host_np._reset_waiting.is_empty()),
		"link/and every peer arms the reset before assembly resumes")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	_ok(w.host_far.stopped and w.client_far.stopped,
		"link/stopping the session stops every machine in it")
	_free(w)

	# Seating a plug mid-game changes deterministic state on both cores, so it
	# has to land on the SAME emulated frame everywhere — the same rule as a
	# disc swap. Applying it the instant a hand moves forks the session.
	w = await _pair_cabled()
	w.host_far.boot_mode = "no_content"
	w.host_far.rom_md5 = ""
	w.client_far.boot_mode = "no_content"
	w.client_far.rom_md5 = ""
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 4: w.client_id}, 3, 0)
	await _until(func() -> bool: return w.host_np.is_running() and w.client_np.is_running())
	await _await_frames(60)
	# The HEAD of the bus applies the op while every core is still gated below
	# the boundary frame, before that frame is posted to any of them.
	var applied: Array = []
	w.host_sys.lib.link_applied = applied
	var client_applied: Array = []
	w.client_sys.lib.link_applied = client_applied
	w.host_np.schedule_link_op(w.host_sys, 1, [0, 1], [0, 0])
	_eq(applied.size(), 0, "link/a plug seated mid-game is not applied at once")
	_ok(await _until(func() -> bool: return applied.size() > 0 and client_applied.size() > 0),
		"link/it reaches every peer")
	_eq(int(applied[0]) if applied.size() > 0 else -1,
		int(client_applied[0]) if client_applied.size() > 0 else -2,
		"link/and lands on the same frame on both")

	# And a pull is the same decision in reverse.
	applied.clear()
	client_applied.clear()
	w.host_np.schedule_link_op(w.host_sys, 0, [0], [0])
	_eq(applied.size(), 0, "link/pulling a plug is not applied at once either")
	_ok(await _until(func() -> bool: return applied.size() > 0 and client_applied.size() > 0),
		"link/it too reaches every peer")
	_eq(int(applied[0]) if applied.size() > 0 else -1,
		int(client_applied[0]) if client_applied.size() > 0 else -2,
		"link/on one agreed frame")

	# More than one cable can move before the same future boundary. A map keyed
	# only by frame used to let the second event erase the first.
	applied.clear()
	client_applied.clear()
	w.host_np.schedule_link_op(w.host_sys, 1, [0, 1], [0, 0])
	w.host_np.schedule_link_op(w.host_sys, 0, [0], [0])
	_ok(await _until(func() -> bool: return applied.size() >= 2 and client_applied.size() >= 2),
		"link/two operations sharing a frame both land")
	_eq(applied.slice(0, 2), client_applied.slice(0, 2),
		"link/and land at the same boundaries on both peers")

	# A core savestate does not serialize the process-wide LinkCoordinator bus,
	# so linked late join also transfers that bus's clocks and in-flight messages.
	var linked_joiner := _branch("LJ")
	var join_near := MockSys.new()
	var join_far := MockSys.new()
	join_near.name = "Sys"
	join_far.name = "Far"
	join_near.link_group = [join_near, join_far]
	join_far.link_group = [join_near, join_far]
	join_far.boot_mode = "no_content"
	join_far.rom_md5 = ""
	join_near.lib.link_peers = {0: 2}
	join_far.lib.link_peers = {0: 2}
	linked_joiner.add_child(join_near)
	linked_joiner.add_child(join_far)
	var join_np: NetplaySession = linked_joiner._netplay
	join_np.systems_override = {0: join_near, 1: join_far}
	linked_joiner.join_game("::1", PORT)
	_ok(await _until(func() -> bool:
		return join_np.is_running(), 900),
		"link/a late joiner starts every core in the linked game")
	_ok(join_near.lib.loaded_state and join_far.lib.loaded_state,
		"link/the newcomer restores the game and BIOS-only core savestates")
	_eq(join_far.prepared_boot, "no_content",
		"link/the late joiner cold-boots the empty handheld before loading its RAM state")
	_ok(not join_near.lib.restored_link_state.is_empty(),
		"link/and restores the external bus state before resuming")
	_ok(await _until(func() -> bool: return not w.host_np._join_paused),
		"link/the existing peers resume after the linked snapshot")
	w.host_nm.netplay_stop("done")
	await _await_frames(5)
	linked_joiner.get_parent().queue_free()
	_free(w)


# ══ Mocks ═════════════════════════════════════════════════════════════════════

## The C++ frame gate, a deterministic RAM CRC, and a core identity that appears
## only once "content has loaded" — which is what makes the cold-start cases
## mean anything.
class MockLib extends Node:
	signal netplay_crc(frame: int, crc: int)
	signal savestate_ready(data: PackedByteArray, frame: int)
	signal savestate_loaded(ok: bool)

	var identity: Dictionary = {"library_name": "FCEUmm", "library_version": "(SVN)",
		"api_version": 1, "serialize_size": 13701}
	## Process frames between the core being started and it reporting itself up.
	## The real thing loads on another thread; 0 here is the lucky case, not the
	## normal one.
	var ready_after := 0
	## Model a core that only reports itself once it has RUN a frame. The real
	## Wrapper must never behave this way and the start/ group proves why: under
	## the gate no frame runs until every peer is ready, and readiness is the
	## identity, so the two wait on each other for ever.
	var identity_needs_frame := false
	## The frame count at the moment the identity first became available, so a
	## case can assert a peer answered ready without its core having run.
	var frames_at_identity := -1
	var desync := false
	var loaded_state := false
	var loaded_state_size := 0
	var save_fails := false
	var save_hangs := false
	var load_fails := false
	var load_hangs := false
	var save_size := 8
	var link_peers: Dictionary = {}
	## Frames at which a scheduled link op landed on this core, appended in
	## order. A case hands in its own array so it can watch a single window.
	var link_applied: Array = []
	var disc_ops: Array = []
	var reset_ops: Array = []
	var rollback_masks: Array = []
	## Frames between RAM CRC checkpoints, as the session set it. -1 until asked,
	## so a case can tell "never called" from "called with the default".
	var crc_interval := -1
	var last_input := PackedInt32Array()
	var restored_link_state: Array = []

	var _count := 0
	var _acc := 0
	var _enabled := false
	var _ticks := -1
	var _start_frame := 0

	func _process(_d: float) -> void:
		if _ticks >= 0:
			_ticks += 1

	func GetCoreIdentity() -> Dictionary:
		if _ticks < 0 or _ticks < ready_after:
			return {}
		if identity_needs_frame and _count <= _start_frame:
			return {}
		if frames_at_identity < 0:
			frames_at_identity = _count - _start_frame
		return identity

	func LinkPeerCount(port: int) -> int:
		return int(link_peers.get(port, 0))

	func LinkConnectGroup(_peers: Array, _ports: PackedInt32Array) -> bool:
		link_applied.append(_count)
		return true

	func LinkDisconnect(_port: int) -> void:
		link_applied.append(_count)

	func LinkCaptureGroup(others: Array, ports: PackedInt32Array) -> Array:
		var out: Array = []
		for i in range(others.size() + 1):
			out.append({"published": true, "origin": 100 + i,
				"local_delta": 200 + i, "safe_delta": 300 + i,
				"last_grant": 400 + i, "inbox": []})
		return out if ports.size() == others.size() + 1 else []

	func LinkRestoreGroup(others: Array, ports: PackedInt32Array, states: Array) -> bool:
		if ports.size() != others.size() + 1 or states.size() != ports.size():
			return false
		restored_link_state = states.duplicate(true)
		return true

	func ScheduleDiscOp(frame: int, op: int, index: int, path: String) -> void:
		disc_ops.append([frame, op, index, path])

	func ScheduleReset(frame: int) -> void:
		reset_ops.append(frame)

	func ScheduleNetplayLocalMask(frame: int, mask: int) -> bool:
		rollback_masks.append([frame, mask])
		return true

	func SetNetplayCrcInterval(frames: int) -> void:
		crc_interval = frames

	func setup_gate(_mask: int, start_frame: int) -> void:
		_enabled = true
		_ticks = 0
		_count = start_frame
		_start_frame = start_frame
		frames_at_identity = -1
		_acc = start_frame          # deterministic seed, identical across peers

	func stop() -> void:
		_enabled = false
		_ticks = -1

	func GetFrameCount() -> int:
		return _count

	func PostNetplayInputs(frame: int, flat: PackedInt32Array) -> void:
		if not _enabled or frame != _count:
			return                  # the gate: only the expected next frame runs
		last_input = flat.duplicate()
		var h := frame
		for v in flat:
			h = (h * 1103515245 + int(v) + 12345) & 0x3FFFFFFF
		_acc = (_acc ^ h) & 0x3FFFFFFF
		_count += 1
		if _count % 60 == 0:
			netplay_crc.emit(_count, (_acc ^ 0xABCDE) & 0x3FFFFFFF if desync else _acc)

	func RequestSaveState() -> void:
		if save_hangs:
			return
		if save_fails:
			savestate_ready.emit(PackedByteArray(), _count)
			return
		var d := PackedByteArray()
		d.resize(save_size)
		if d.size() >= 8:
			d.encode_s64(0, _acc)
		savestate_ready.emit(d, _count)

	func RequestLoadState(data: PackedByteArray, frame: int) -> void:
		if load_hangs:
			return
		if load_fails:
			savestate_loaded.emit(false)
			return
		_count = frame
		_acc = data.decode_s64(0) if data.size() >= 8 else frame
		_enabled = true
		loaded_state = true
		loaded_state_size = data.size()
		savestate_loaded.emit(true)


## The net_start_core / net_stop_core seam. `default_core` is deliberately not
## the core any test hosts with: a peer taking its OWN default is the bug the
## start/ group is about.
class MockSys extends Node:
	var lib: MockLib
	var default_core := "nestopia"
	var refuse := false             # this machine cannot start a core at all
	var started := false
	var stopped := false
	var started_core := ""
	var machine_core := "fceumm"
	var rom_md5 := "MD5"
	var rom_path := "mock.rom"
	var boot_mode := "rom"
	var empty_media_extension := "cue"
	var boot_options: Dictionary = {}
	var firmware_signature := ""
	var prepared_boot := ""
	var resolved_md5 := ""
	var sram_bytes := PackedByteArray()
	var received_sram := PackedByteArray()
	var link_refreshes := 0
	var reset_visuals := 0
	var _port_controllers: Array = []

	## The session asks through the public accessors, so a mock answers them too.
	func port_holders() -> Array: return _port_controllers
	func get_model() -> Variant: return null

	## The machines on this one's link bus, itself included, or empty when the
	## machine is not cabled to anything. This is the seam the session asks
	## through, so a probe needs no cables and no room.
	var link_group: Array = []

	func net_play_reset() -> void:
		reset_visuals += 1

	func _init() -> void:
		lib = MockLib.new()
		lib.name = "Lib"
		add_child(lib)

	func get_libretro_node() -> Node:
		return lib

	func net_start_core(core: String, port_mask: int, start_frame: int, _options: Dictionary) -> Node:
		if refuse:
			return null
		started = true
		stopped = false
		started_core = core if not core.is_empty() else default_core
		lib.setup_gate(port_mask, start_frame)
		return lib

	func net_stop_core() -> void:
		stopped = true
		lib.stop()

	func resolve_core_name() -> String:
		return machine_core

	func net_rom_md5() -> String:
		return rom_md5

	func net_boot_spec(_core: String) -> Dictionary:
		var spec: Dictionary
		match boot_mode:
			"rom": spec = {"mode": "rom", "rom_md5": rom_md5}
			"no_content": spec = {"mode": "no_content"}
			"empty_media": spec = {"mode": "empty_media",
				"extension": empty_media_extension}
			_: return {}
		if not boot_options.is_empty():
			spec["boot_options"] = boot_options.duplicate()
		if not firmware_signature.is_empty():
			spec["firmware"] = firmware_signature
		return spec

	func net_prepare_boot(spec: Dictionary) -> bool:
		prepared_boot = str(spec.get("mode", "rom"))
		if prepared_boot != boot_mode:
			return false
		if spec.has("firmware") and str(spec["firmware"]) != firmware_signature:
			return false
		return net_resolve_rom(str(spec.get("rom_md5", ""))) \
			if prepared_boot == "rom" else true

	func net_resolve_rom(md5: String) -> bool:
		resolved_md5 = md5
		return true

	func net_sram_file_bytes() -> PackedByteArray:
		return sram_bytes

	func net_set_sram(_path: String, data: PackedByteArray) -> void:
		received_sram = data

	func net_link_group() -> Array:
		return link_group

	func net_link_buses() -> Array:
		if link_group.size() < 2:
			return []
		var bus: Array = []
		for machine: Object in link_group:
			bus.append({"machine": machine, "port": 0})
		return [bus]

	func net_refresh_link_cables() -> void:
		link_refreshes += 1


class MockController extends Node:
	var _connected_system: Object = null
	var _port_index := -1
	func is_picked_up() -> bool: return false
	func get_connected_system() -> Object: return _connected_system
	func get_port_index() -> int: return _port_index


class MockPadReceiver extends InputReceiver:
	func _ready() -> void: pass


class MockKeyboardReceiver extends KeyboardReceiver:
	func _ready() -> void: pass


## A NetworkManager stand-in for the cases that need a session but no network.
class StubNM extends Node:
	var peers: Dictionary = {1: {}}
	var _object_sync: Node = null
	var host := true

	# The surface NetHudNotifier subscribes to. Declared here rather than driving
	# a real NetworkManager so the mapping from event to sentence can be tested
	# without a peer, a camera or a viewport.
	signal peer_registered(id: int, info: Dictionary)
	signal peer_left(id: int)
	signal serve_started(peer_id: int, md5: String, kind: String, size: int, name: String)
	signal serve_progress(peer_id: int, md5: String, sent: int, total: int)
	signal serve_done(peer_id: int, md5: String)
	signal serve_refused(peer_id: int, md5: String, reason: String)
	signal netplay_state_progress(peer_id: int, phase: String, received: int, total: int)
	signal netplay_join_requested(peer_id: int, port: int)
	signal netplay_desync(peer_id: int, frame: int)
	signal netplay_blocked(reason: String, machine: Object, remedy: Dictionary)
	signal netplay_session_stopped(reason: String)

	func is_host() -> bool:
		return host


# ══ Harness ═══════════════════════════════════════════════════════════════════

class Pair:
	var host_nm: Node
	var client_nm: Node
	var host_sys: MockSys
	var client_sys: MockSys
	var host_np: NetplaySession
	var client_np: NetplaySession
	var client_id := -1
	## The far end of a link cable, when the pair was built cabled. Each peer
	## replicates BOTH machines, so there are two of these, one per branch.
	var host_far: MockSys
	var client_far: MockSys


## A session with a stub parent and no multiplayer peer, for the pure cases.
func _stub_session() -> NetplaySession:
	var nm := StubNM.new()
	add_child(nm)
	var np := NetplaySession.new()
	np.name = "Netplay"
	nm.add_child(np)
	return np


## One NetworkManager under its own SceneMultiplayer, so two of them can talk
## over loopback inside this one process.
func _branch(bname: String) -> Node:
	var root := Node.new()
	root.name = bname
	add_child(root)
	var api := SceneMultiplayer.new()
	get_tree().set_multiplayer(api, root.get_path())
	var nm := NM_SCRIPT.new()
	nm.name = "NetworkManager"
	nm.world_root = root
	nm.pose_source = func() -> PackedFloat32Array: return PackedFloat32Array()
	root.add_child(nm)
	return nm


## A connected host + client, each with a mock machine wired into its session.
func _pair() -> Pair:
	var p := Pair.new()
	p.host_nm = _branch("H%d" % _ran)
	p.client_nm = _branch("C%d" % _ran)
	p.host_sys = MockSys.new()
	p.host_sys.name = "Sys"
	p.host_nm.add_child(p.host_sys)
	p.client_sys = MockSys.new()
	p.client_sys.name = "Sys"
	p.client_nm.add_child(p.client_sys)
	p.host_np = p.host_nm._netplay
	p.client_np = p.client_nm._netplay
	p.host_np.system_override = p.host_sys
	p.client_np.system_override = p.client_sys
	p.host_nm.host_game(PORT)
	# Godot 4.7's ENet loopback is IPv6-only on some Linux hosts even though
	# ordinary IPv4 UDP works there.  This is an in-process transport test, so
	# use the native loopback address and leave LAN address coverage to device QA.
	p.client_nm.join_game("::1", PORT)
	if not await _until(func() -> bool:
			return p.host_nm.peers.size() == 2 and p.client_nm.peers.size() == 2):
		_ok(false, "harness/the two peers never connected")
		return p
	p.client_id = _other_id(p.host_nm, 1)
	return p


## The same pair with a second machine cabled to the first on both peers. Every
## peer replicates the whole bus, so each branch gets its own far machine, and
## the session is told about it through net_link_group().
func _pair_cabled() -> Pair:
	var p := await _pair()
	p.host_far = MockSys.new()
	p.host_far.name = "Far"
	p.host_far.rom_md5 = "FAR_MD5"
	p.host_far.sram_bytes = PackedByteArray([9, 8, 7])
	p.host_nm.add_child(p.host_far)
	p.client_far = MockSys.new()
	p.client_far.name = "Far"
	p.client_far.rom_md5 = "LOCAL_OTHER"
	p.client_nm.add_child(p.client_far)
	# Two machines with a lead between them: each names the whole bus, itself
	# first, and the session takes the order from the machine it was started on.
	p.host_sys.link_group = [p.host_sys, p.host_far]
	p.host_far.link_group = [p.host_sys, p.host_far]
	p.client_sys.link_group = [p.client_sys, p.client_far]
	p.client_far.link_group = [p.client_sys, p.client_far]
	# Both cores report themselves cabled, which is also what stops rollback.
	for lib: MockLib in [p.host_sys.lib, p.host_far.lib, p.client_sys.lib, p.client_far.lib]:
		lib.link_peers = {0: 2}
	# Each branch resolves its own two machines by the group's net ids.
	p.host_np.systems_override = {0: p.host_sys, 1: p.host_far}
	p.client_np.systems_override = {0: p.client_sys, 1: p.client_far}
	return p


func _other_id(nm: Node, exclude: int) -> int:
	for id: int in nm.peers:
		if id != 1 and id != exclude:
			return id
	for id: int in nm.peers:
		if id != 1:
			return id
	return -1


func _free(p: Pair) -> void:
	for nm: Node in [p.host_nm, p.client_nm]:
		if is_instance_valid(nm):
			nm.leave_session("test over")
			if is_instance_valid(nm.get_parent()):
				nm.get_parent().queue_free()


func _await_frames(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame


func _until(cond: Callable, ticks := 600) -> bool:
	for _i in range(ticks):
		await get_tree().process_frame
		if cond.call():
			return true
	return false


# ══ Substituting a vetted core ════════════════════════════════════════════════
# `systems` had no reader before this, so these are the first cases that can
# fail if an entry's system list is wrong.

func _test_substitute() -> void:
	var gb := NetplayCores.cores_for_system("game_boy")
	_ok(gb.has("gambatte") and gb.has("mgba") and gb.has("tgbdual"),
		"substitute/every vetted Game Boy core is offered")
	_ok(not gb.has("fceumm"), "substitute/a core for another system is not")
	var nes := NetplayCores.cores_for_system("nes")
	_ok(nes.size() == 1 and nes[0] == "fceumm",
		"substitute/the NES has exactly one vetted core")
	_ok(NetplayCores.cores_for_system("").is_empty(),
		"substitute/no system means no candidates")
	_ok(NetplayCores.cores_for_system("dreamcast").is_empty(),
		"substitute/a system with no vetted core offers none")

	# dolphin is verified:false, so it must never be recommended even though it
	# is the only entry naming the GameCube.
	_ok(not NetplayCores.cores_for_system("gamecube").has("dolphin"),
		"substitute/an unverified core is never a candidate")
	_ok(NetplayCores.suggest_substitute("dolphin", "gamecube").is_empty(),
		"substitute/nothing to offer for the GameCube yet")

	_ok(NetplayCores.suggest_substitute("vba_next", "game_boy_advance") != "",
		"substitute/an unvetted GBA core gets an offer")
	_ok(NetplayCores.suggest_substitute("vba_next", "game_boy_advance") != "vba_next",
		"substitute/never offers the core it was asked about")
	_ok(NetplayCores.suggest_substitute("mgba", "game_boy_advance") != "mgba",
		"substitute/nor when that core is itself vetted")

	# Ranking: rollback beats determinism-only, and state_transfer breaks a tie.
	var gba := NetplayCores.cores_for_system("game_boy_advance")
	_ok(gba[0] == "gpsp" or gba[0] == "mgba",
		"substitute/a rollback core leads the GBA list")

	# The debug switch opens the session gate; it must not invent evidence.
	var before := NetplayCores.cores_for_system("game_boy_advance")
	NetplayCores.debug_allow_unverified = true
	_ok(NetplayCores.cores_for_system("game_boy_advance") == before,
		"substitute/the debug switch does not add candidates")
	_ok(NetplayCores.why_not_capable("vba_next") != "",
		"substitute/nor does it blank the explainer")
	NetplayCores.debug_allow_unverified = false

	_ok(NetplayCores.why_not_capable("fceumm").is_empty(),
		"substitute/a vetted core has nothing to explain")
	_ok(NetplayCores.why_not_capable("dolphin").contains("unproven"),
		"substitute/a listed-but-unverified core says so")
	_ok(NetplayCores.why_not_capable("vba_next").contains("never been vetted"),
		"substitute/an unlisted core reads differently")
	_ok(NetplayCores.why_not_capable("") != "",
		"substitute/no core at all is still a reason")


# ══ What may cross the wire ═══════════════════════════════════════════════════
# The legal boundary. TRANSFER_KINDS is where it is enforced, so these cases
# guard the const itself rather than any one call site: a kind that is not in it
# cannot be served or requested at all.

func _test_manifest() -> void:
	_ok(not NetFileTransfer.TRANSFER_KINDS.has("rom"),
		"manifest/a ROM is not a transferable kind")
	_ok(not NetFileTransfer.TRANSFER_KINDS.has("firmware"),
		"manifest/nor is firmware")
	_ok(not NetplayContent.is_transferable("rom"),
		"manifest/NetplayContent refuses a ROM")
	_ok(not NetplayContent.is_transferable("firmware"),
		"manifest/and refuses firmware")
	for kind: String in ["book", "video", "music", "save", "dvd", "poster"]:
		_ok(NetplayContent.is_transferable(kind),
			"manifest/%s may be sent" % kind)

	# NEVER_SENT has to win even if a kind were added to TRANSFER_KINDS by
	# mistake, which is the failure this belt-and-braces exists for.
	_ok(NetplayContent.NEVER_SENT.has("rom") and NetplayContent.NEVER_SENT.has("firmware"),
		"manifest/the never-sent list names both")

	_ok(NetplayContent.key_for("rom", "abc") == "rom:abc",
		"manifest/a row key survives a rebuild")

	# The sha1 the RomM lookup needs rides the same cached pass as the md5.
	var tmp := "user://__np_manifest_test.bin"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	f.store_string("netplay manifest test")
	f.close()
	var real := ProjectSettings.globalize_path(tmp)
	var sums := NetFileTransfer.checksums_of(real)
	_ok(not sums.is_empty(), "manifest/checksums come back")
	_ok(not str(sums.get("sha1", "")).is_empty(),
		"manifest/including the sha1 RomM falls back to")
	_ok(str(sums.get("md5", "")) == NetFileTransfer.hash_of(real),
		"manifest/and the md5 agrees with the cached hash")
	DirAccess.remove_absolute(real)


# ══ Host HUD notifications ════════════════════════════════════════════════════
# The mapping from event to sentence, with no 3D anywhere. The two cases that
# matter most are the ones that stop this becoming noise: only the host speaks,
# and a row is keyed so it is patched rather than piled up.

func _hud_rig(is_host := true) -> Array:
	var nm := StubNM.new()
	nm.host = is_host
	nm.peers = {
		1: {"name": "Ryan", "is_vr": true, "color_idx": 0},
		77: {"name": "Sam", "is_vr": true, "color_idx": 1},
	}
	add_child(nm)
	var stack := MenuToasts.create()
	add_child(stack)
	var notifier := NetHudNotifier.new()
	add_child(notifier)
	notifier.setup(nm, stack)
	return [nm, stack, notifier]


## Visible rows on the stack. MenuToasts keeps its bars as children, so this is
## what a player would actually see.
## What one keyed row actually SAYS. Row counts prove the keying; only the text
## proves the sentence.
func _hud_text(stack: MenuToasts, key: String) -> String:
	var toasts: Dictionary = stack.get("_toasts")
	var toast: Dictionary = toasts.get(key, {})
	var lbl: Label = toast.get("label")
	return lbl.text if lbl != null and is_instance_valid(lbl) else ""


func _hud_rows(stack: MenuToasts) -> int:
	var n := 0
	for c in stack.get_children():
		if c is Control and (c as Control).visible:
			n += 1
	return n


func _test_hudnotify() -> void:
	var rig := _hud_rig()
	var nm: StubNM = rig[0]
	var stack: MenuToasts = rig[1]
	var notifier: NetHudNotifier = rig[2]

	# A join and a leave are the same peer, so they are the same row.
	nm.peer_registered.emit(77, nm.peers[77])
	_eq(_hud_rows(stack), 1, "hudnotify/a join raises one row")
	nm.peer_left.emit(77)
	_eq(_hud_rows(stack), 1, "hudnotify/a leave replaces it rather than adding")

	# A transfer patches ONE row however many times it reports.
	nm.serve_started.emit(77, "aa", "book", 8388608, "Nintendo Power 42.pdf")
	var after_start := _hud_rows(stack)
	for i in range(20):
		nm.serve_progress.emit(77, "aa", (i + 1) * 262144, 8388608)
	_eq(_hud_rows(stack), after_start,
		"hudnotify/twenty progress reports stay one row")
	# The FILE has to be named. This carried a hash before, because the only way
	# to learn a name was a setter nothing ever called -- the toast read
	# "Sending a file to Sam" for every upload the host ever made.
	_ok(_hud_text(stack, "hud:up:77:aa").contains("Nintendo Power 42.pdf"),
		"hudnotify/an upload names the file")
	_ok(_hud_text(stack, "hud:up:77:aa").contains("Sam"),
		"hudnotify/and the player it is going to")

	nm.serve_done.emit(77, "aa")
	_eq(_hud_rows(stack), after_start, "hudnotify/and finishing still one row")
	_ok(_hud_text(stack, "hud:up:77:aa").contains("Nintendo Power 42.pdf"),
		"hudnotify/the finished row still names it")

	# Twelve files at once are twelve rows, not one hundred and twelve. The cap
	# collapses the surplus, which is why this counts <= MAX_VISIBLE + 1.
	var fresh := _hud_rig()
	var nm2: StubNM = fresh[0]
	var stack2: MenuToasts = fresh[1]
	for i in range(12):
		nm2.serve_started.emit(77, "f%d" % i, "book", 1024 * (i + 1), "f%d.pdf" % i)
		nm2.serve_progress.emit(77, "f%d" % i, 512, 1024 * (i + 1))
	_ok(_hud_rows(stack2) <= MenuToasts.MAX_VISIBLE + 1,
		"hudnotify/twelve transfers collapse rather than run off the panel")
	_ok(_hud_rows(stack2) > 1, "hudnotify/but more than one is shown")

	# THE case that stops this reporting the room's traffic to everyone in it.
	var client := _hud_rig(false)
	var cnm: StubNM = client[0]
	var cstack: MenuToasts = client[1]
	cnm.peer_registered.emit(77, cnm.peers[77])
	cnm.serve_started.emit(77, "aa", "book", 1024, "x.pdf")
	cnm.serve_progress.emit(77, "aa", 512, 1024)
	cnm.netplay_state_progress.emit(77, "capturing", 0, 0)
	cnm.netplay_desync.emit(77, 900)
	_eq(_hud_rows(cstack), 0, "hudnotify/a client is told nothing")

	# An id the roster has already dropped still makes a sentence.
	var gone := _hud_rig()
	var gnm: StubNM = gone[0]
	var gstack: MenuToasts = gone[1]
	gnm.serve_done.emit(4242, "zz")
	_eq(_hud_rows(gstack), 1, "hudnotify/an unknown peer still reports")

	# The late-join stream: capture, send, and an ending. Before the host-side
	# "done" existed this row hung at whatever the last ack said.
	var join := _hud_rig()
	var jnm: StubNM = join[0]
	var jstack: MenuToasts = join[1]
	jnm.netplay_state_progress.emit(77, "capturing", 0, 0)
	_eq(_hud_rows(jstack), 1, "hudnotify/a capture pause is announced")
	jnm.netplay_state_progress.emit(77, "transferring", 512, 1024)
	_eq(_hud_rows(jstack), 1, "hudnotify/the send patches the same row")
	jnm.netplay_state_progress.emit(77, "done", 1, 1)
	_eq(_hud_rows(jstack), 1, "hudnotify/and it ends on that row")

	# The rest of the vocabulary, each on its own key.
	var misc := _hud_rig()
	var mnm: StubNM = misc[0]
	var mstack: MenuToasts = misc[1]
	mnm.netplay_join_requested.emit(77, 1)
	mnm.netplay_desync.emit(77, 900)
	mnm.netplay_blocked.emit("'vba_next' has never been vetted", null, {})
	mnm.netplay_session_stopped.emit("powered off")
	_ok(_hud_rows(mstack) >= 2 and _hud_rows(mstack) <= MenuToasts.MAX_VISIBLE + 1,
		"hudnotify/the other events each get a row, within the cap")

	for r: Array in [rig, fresh, client, gone, join, misc]:
		for n: Node in r:
			n.queue_free()


# ══ Late-join progress ════════════════════════════════════════════════════════
# The stream tracked every byte and reported none of them, so a joiner watched a
# still menu for up to JOIN_TIMEOUT_MS. These drive a real two-peer late join
# and assert the phases actually arrive, in order, ending complete.

func _test_progress() -> void:
	var w := await _pair()
	w.host_np._pending_local_route[0] = [0x01, 0, 0, 0, 0]
	w.client_np._pending_local_route[1] = [0x02, 0, 0, 0, 0]
	w.host_nm.netplay_start_host(w.host_sys, "fceumm", "MD5", {0: 1, 1: w.client_id}, 3, 0)
	_ok(await _until(func() -> bool: return w.host_np.is_running()),
		"progress/a game is running to join")
	await _await_frames(60)
	w.host_sys.lib.save_size = NetplaySession.STATE_CHUNK_SIZE * 3 + 77

	# Record on the host, which sees capture and the whole send.
	var host_phases: Array[String] = []
	var host_last := {"received": -1, "total": 0}
	var monotonic := true
	w.host_np.join_state_progress.connect(
		func(_peer: int, phase: String, received: int, total: int) -> void:
			if host_phases.is_empty() or host_phases[-1] != phase:
				host_phases.append(phase)
			if phase == "transferring":
				if received < int(host_last["received"]):
					monotonic = false
				host_last["received"] = received
				host_last["total"] = total)

	var third := _branch("P")
	var jsys := MockSys.new()
	jsys.name = "Sys"
	third.add_child(jsys)
	third._netplay.system_override = jsys
	var jnp: NetplaySession = third._netplay

	var join_phases: Array[String] = []
	jnp.join_state_progress.connect(
		func(_peer: int, phase: String, _received: int, _total: int) -> void:
			if join_phases.is_empty() or join_phases[-1] != phase:
				join_phases.append(phase))

	third.join_game("::1", PORT)
	_ok(await _until(func() -> bool: return jnp.is_running(), 900),
		"progress/the newcomer is running the game")

	_ok(host_phases.has("capturing"),
		"progress/the host reports the snapshot pause it used to sit through silently")
	_ok(host_phases.has("transferring"), "progress/and the send")
	_eq(host_phases[0], "capturing", "progress/capture comes first")
	_ok(monotonic, "progress/a transfer never goes backwards")
	_ok(int(host_last["total"]) > 0, "progress/the total is a real byte count")
	_eq(int(host_last["received"]), int(host_last["total"]),
		"progress/and the send ends complete")

	_ok(join_phases.has("transferring"), "progress/the joiner sees bytes arriving")
	_ok(join_phases.has("verifying"),
		"progress/and the hash check, which is otherwise a silent pause")
	_ok(join_phases.has("loading"),
		"progress/and the core taking the state, the other silent one")
	# Order matters: verifying cannot be reported before the bytes are in.
	_ok(join_phases.find("transferring") < join_phases.find("verifying"),
		"progress/bytes before the check")
	_ok(join_phases.find("verifying") < join_phases.find("loading"),
		"progress/the check before the load")

	w.host_nm.netplay_stop("done")
	await _await_frames(10)
	third.get_parent().queue_free()
	_free(w)
	await _await_frames(5)


# ══ The hash cache and its warm-up ════════════════════════════════════════════
# resolve_by_md5 is a REVERSE lookup, so on a cold cache it hashes candidates
# until one matches -- at the moment a player presses Join. These cases pin that
# a warm cache answers without reading, that a cold one still answers, and that
# a changed file is never answered from a stale entry.

func _test_hashcache() -> void:
	var dir := "user://__np_warm"
	DirAccess.make_dir_recursive_absolute(dir)
	var root := ProjectSettings.globalize_path(dir)
	var paths: Array[String] = []
	for i in range(4):
		var p := root.path_join("rom%d.bin" % i)
		var f := FileAccess.open(p, FileAccess.WRITE)
		f.store_string("warm cache case %d" % i)
		f.close()
		paths.append(p)

	# Cold: nothing is known without reading.
	for p: String in paths:
		_ok(NetFileTransfer.cached_hash_of(p).is_empty(),
			"hashcache/%s starts uncached" % p.get_file())

	var done := NetFileTransfer.warm_cache([root], [], 100)
	_ok(done == 4, "hashcache/the warm-up hashed every file it found")

	# Warm: the never-blocking accessor now answers, which is the whole point.
	var warm_ok := true
	for p: String in paths:
		if NetFileTransfer.cached_hash_of(p).is_empty():
			warm_ok = false
	_ok(warm_ok, "hashcache/every file answers without hashing afterwards")
	_ok(NetFileTransfer.warm_cache([root], [], 100) == 0,
		"hashcache/a second sweep finds nothing left to do")

	# The reverse lookup finds it, which is what all of this is for.
	var want := NetFileTransfer.hash_of(paths[2])
	var found := NetFileTransfer.resolve_by_md5(want, "rom",
		NetFileTransfer.size_of(paths[2]), "", [root])
	_ok(found == paths[2], "hashcache/resolve_by_md5 finds the warmed file")

	# A rewritten file must not be answered from its old entry.
	var f2 := FileAccess.open(paths[2], FileAccess.WRITE)
	f2.store_string("changed on disk")
	f2.close()
	_ok(NetFileTransfer.hash_of(paths[2]) != want,
		"hashcache/an mtime change invalidates the entry")

	# The extension filter is what keeps a warm sweep off the videos.
	_ok(NetFileTransfer.warm_cache([root], ["nes"], 100) == 0,
		"hashcache/an extension filter excludes non-matching files")

	# The size prefilter is what stops a lookup reading the whole library: a
	# candidate of the wrong length must never be hashed at all. Proved by
	# leaving a decoy that would match if size were ignored.
	var decoy_dir := root.path_join("other")
	DirAccess.make_dir_recursive_absolute(decoy_dir)
	var decoy := decoy_dir.path_join("decoy.bin")
	var df := FileAccess.open(decoy, FileAccess.WRITE)
	df.store_string("a considerably longer decoy payload than the others")
	df.close()
	var target := paths[0]
	var target_md5 := NetFileTransfer.hash_of(target)
	var target_size := NetFileTransfer.size_of(target)
	_ok(NetFileTransfer.size_of(decoy) != target_size,
		"hashcache/the decoy is a different length")
	_eq(NetFileTransfer.resolve_by_md5(target_md5, "rom", target_size, "", [root]),
		target, "hashcache/a sized lookup still finds the real file")
	# A hash nothing matches must come back empty rather than wandering.
	_eq(NetFileTransfer.resolve_by_md5("0" .repeat(32), "rom", target_size, "", [root]),
		"", "hashcache/an unmatched hash resolves to nothing")
	DirAccess.remove_absolute(decoy)
	DirAccess.remove_absolute(decoy_dir)

	for p: String in paths:
		DirAccess.remove_absolute(p)
	DirAccess.remove_absolute(root)


# ══ Readiness verdicts ════════════════════════════════════════════════════════
# The distinction these exist to protect: PENDING is not WARN. serialize_size
# is 0 on both peers at every cold start, and calling that a mismatch describes
# a healthy session as broken.

func _test_readiness() -> void:
	var R := NetplayReadiness

	var good := R.machine_row(1, "NES", "fceumm", "nes")
	_ok(int(good["verdict"]) == R.Verdict.READY, "readiness/a vetted core is ready")
	_ok((good["remedy"] as Dictionary).is_empty(),
		"readiness/a ready machine needs no remedy")

	var bad := R.machine_row(2, "GBA", "vba_next", "game_boy_advance")
	_ok(int(bad["verdict"]) == R.Verdict.BLOCKED, "readiness/an unvetted core blocks")
	_ok(str((bad["remedy"] as Dictionary).get("kind", "")) == "swap_core",
		"readiness/and offers a swap")
	_ok(not str((bad["remedy"] as Dictionary).get("core", "")).is_empty(),
		"readiness/naming a real core")

	var hopeless := R.machine_row(3, "GameCube", "dolphin", "gamecube")
	_ok(int(hopeless["verdict"]) == R.Verdict.BLOCKED,
		"readiness/an unverified core blocks too")
	_ok((hopeless["remedy"] as Dictionary).is_empty(),
		"readiness/with no remedy when nothing covers the system")

	# Dolphin's seven forced options override the player's own config, so they
	# have to be visible somewhere.
	var forced := 0
	for d: Dictionary in (hopeless["detail"] as Array):
		if str(d["name"]) == "Forced option":
			forced += 1
	_ok(forced == 0, "readiness/an unvetted core lists no strategy detail")
	var det := R.machine_row(4, "GameCube", "dolphin", "gamecube")
	_ok(int(det["verdict"]) == R.Verdict.BLOCKED, "readiness/dolphin stays blocked")

	# Identity: both halves, and the 0 case.
	var want := {"library_name": "FCEUmm", "library_version": "1", "api_version": 1,
		"serialize_size": 0, "arch": "x86_64"}
	var same := want.duplicate()
	var row := R.peer_row(7, "Sam", "fceumm", want, same)
	_ok(int(row["verdict"]) == R.Verdict.READY, "readiness/matching builds are ready")
	var words := ""
	for d: Dictionary in (row["detail"] as Array):
		if str(d["name"]) == "Savestate size":
			words = str(d["value"])
	_ok(words == "not measured yet",
		"readiness/serialize_size 0 reads as unmeasured, not a mismatch")

	_ok(int(R.peer_row(7, "Sam", "fceumm", {}, {})["verdict"]) == R.Verdict.PENDING,
		"readiness/an empty identity is PENDING, not blocked")
	_ok(int(R.peer_row(7, "Sam", "fceumm", want, {})["verdict"]) == R.Verdict.PENDING,
		"readiness/one side still starting is PENDING")

	var other := want.duplicate()
	other["arch"] = "arm64"
	_ok(int(R.peer_row(7, "Sam", "gambatte", want, other)["verdict"]) == R.Verdict.BLOCKED,
		"readiness/a cross-arch peer blocks on a same-arch core")
	_ok(int(R.peer_row(7, "Sam", "fceumm", want, other)["verdict"]) == R.Verdict.READY,
		"readiness/but not on the one core cleared for it")

	# Media: three ROM states and a firmware difference that names the file.
	_ok(int(R.media_row(1, "NES", "have", "Mario", "abc", [])["verdict"]) == R.Verdict.READY,
		"readiness/a held ROM is ready")
	var romm := R.media_row(1, "NES", "romm", "Mario", "abc", [])
	_ok(int(romm["verdict"]) == R.Verdict.WARN, "readiness/a fetchable ROM warns")
	_ok(str((romm["remedy"] as Dictionary).get("kind", "")) == "fetch_rom",
		"readiness/and offers the fetch")
	var gone := R.media_row(1, "NES", "missing", "Mario", "abc", [])
	_ok(int(gone["verdict"]) == R.Verdict.BLOCKED, "readiness/a missing ROM blocks")
	_ok((gone["remedy"] as Dictionary).is_empty(),
		"readiness/a missing ROM is never offered as a transfer")

	var diff := R.firmware_diff({"a.bin": "1", "b.bin": "2"}, {"a.bin": "9"})
	_ok(diff.size() == 2, "readiness/firmware diff finds both problems")
	var by_file: Dictionary = {}
	for d: Dictionary in diff:
		by_file[str(d["file"])] = str(d["state"])
	_ok(str(by_file.get("a.bin", "")) == "differs", "readiness/a changed file is named")
	_ok(str(by_file.get("b.bin", "")) == "missing", "readiness/a missing file is named")
	_ok(R.firmware_diff({"a.bin": "1"}, {"a.bin": "1"}).is_empty(),
		"readiness/agreeing firmware produces no rows")
	var fw := R.media_row(1, "PS1", "have", "Game", "abc",
		[{"file": "scph5501.bin", "state": "differs"}])
	_ok(int(fw["verdict"]) == R.Verdict.BLOCKED, "readiness/a BIOS difference blocks")

	# The worst row wins, and PENDING outranks WARN.
	_ok(R.overall([good, bad]) == R.Verdict.BLOCKED, "readiness/blocked wins")
	_ok(R.overall([good, romm]) == R.Verdict.WARN, "readiness/warn beats ready")
	_ok(R.overall([good]) == R.Verdict.READY, "readiness/all ready is ready")
	var pending := R.peer_row(7, "Sam", "fceumm", {}, {})
	_ok(R.overall([romm, pending]) == R.Verdict.PENDING,
		"readiness/an unfinished check outranks a warning")
	_ok(not R.all_ready([romm]), "readiness/a warning is not ready")
	_ok(R.all_ready([good]), "readiness/a clean list is")


func _want(name: String) -> bool:
	return _only.is_empty() or _only == name


func _ok(cond: bool, what: String) -> void:
	_ran += 1
	if cond:
		print("[test] ok   %s" % what)
	else:
		_fail += 1
		print("[test] FAIL %s" % what)


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ran += 1
	if got == want:
		print("[test] ok   %s" % what)
	else:
		_fail += 1
		print("[test] FAIL %s — got %s, want %s" % [what, str(got), str(want)])
