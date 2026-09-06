## NetplayReadiness -- one place that decides what a player is told about a
## session, before and during it.
##
## Every verdict here is already computed somewhere in the stack; what was
## missing was somewhere to READ them from. The session gates on bools and
## push_warning()s its reasons into a log no player sees, so a machine that
## cannot hold a session degrades to LIVE-on-host in silence. This turns each of
## those decisions into a row with a verdict, a reason and, where one exists, a
## remedy.
##
## Pure: no nodes, no RPC, no signals. It is handed dictionaries and returns
## dictionaries, which is what makes it testable without standing up two
## NetworkManagers.
##
## It deliberately re-derives nothing. Capability questions go to NetplayCores,
## build identity to NetplaySession.identity_mismatch (which already orders its
## checks correctly), firmware to the digest the host sent. A second
## implementation of any of those would be a second answer to disagree with the
## one the session actually gates on.
class_name NetplayReadiness
extends RefCounted

## READY plays. WARN plays with something worth saying. BLOCKED cannot start.
## PENDING is not a problem -- it is a measurement that has not happened yet,
## and conflating it with WARN is the specific mistake this enum exists to stop:
## serialize_size is 0 on both peers at cold start, every time.
enum Verdict { READY = 0, WARN = 1, BLOCKED = 2, PENDING = 3 }

const VERDICT_WORD: Dictionary = {
	Verdict.READY: "Ready",
	Verdict.WARN: "Playable",
	Verdict.BLOCKED: "Blocked",
	Verdict.PENDING: "Checking",
}


## A row for one machine: may this core hold a session at all, and if not, what
## should the player press instead.
##
## `systemid` is what makes a remedy possible -- without it the table can say a
## core is unvetted but not what covers the same machine.
static func machine_row(machine_id: Variant, label: String, core_name: String,
		systemid: String) -> Dictionary:
	var detail: Array[Dictionary] = []
	var why := NetplayCores.why_not_capable(core_name)
	var strategy := NetplayCores.listed_strategy(core_name)

	detail.append(_row("Core", core_name if not core_name.is_empty() else "(none)"))
	if strategy >= 0:
		detail.append(_row("Strategy", NetplaySession.strategy_str(strategy).capitalize()))
		detail.append(_row("Late join",
			"supported" if NetplayCores.state_transfer_capable(core_name)
			else "not supported -- players must join before the game starts"))
		detail.append(_row("Cross-architecture",
			"allowed" if NetplayCores.allows_cross_play(core_name)
			else "same architecture only -- a headset cannot play a desktop"))
		var forced: Dictionary = NetplayCores.forced_options(core_name)
		for key: String in forced:
			detail.append(_row("Forced option", "%s = %s" % [key, str(forced[key])]))

	if why.is_empty():
		return _make("machine", machine_id, label, Verdict.READY,
			"Vetted for %s netplay" % NetplaySession.strategy_str(strategy),
			detail, {})

	var remedy: Dictionary = {}
	var substitute := NetplayCores.suggest_substitute(core_name, systemid)
	if not substitute.is_empty():
		remedy = {
			"kind": "swap_core",
			"core": substitute,
			"machine": machine_id,
			"strategy": NetplayCores.listed_strategy(substitute),
		}
	else:
		detail.append(_row("Substitute", "no vetted core covers this system yet"))
	return _make("machine", machine_id, label, Verdict.BLOCKED, why, detail, remedy)


## A row for one peer: does their build match ours, and may they play at all.
##
## `want` is the host identity, `got` is this peer's. Both are the four-field
## dictionary the C++ publishes plus the GDScript-stamped `arch`, and both are
## EMPTY until content has loaded -- which is readiness, not failure, so an
## empty one reads PENDING.
static func peer_row(peer_id: int, label: String, core_name: String,
		want: Dictionary, got: Dictionary) -> Dictionary:
	var detail: Array[Dictionary] = []
	if want.is_empty() or got.is_empty():
		detail.append(_row("Core build", "waiting for the core to report"))
		return _make("peer", peer_id, label, Verdict.PENDING,
			"Starting the core...", detail, {})

	detail.append(_row("Host build", NetplaySession.identity_str(want)))
	detail.append(_row("Their build", NetplaySession.identity_str(got)))
	detail.append(_row("Architecture", "%s vs %s"
		% [str(want.get("arch", "?")), str(got.get("arch", "?"))]))
	detail.append(_row("Savestate size", _size_words(want, got)))

	var bad := NetplaySession.identity_mismatch(want, got, core_name)
	if bad.is_empty():
		return _make("peer", peer_id, label, Verdict.READY, "Build matches", detail, {})
	return _make("peer", peer_id, label, Verdict.BLOCKED, bad, detail, {})


## A row for the boot media one machine needs: the ROM, then the firmware.
##
## Neither is transferable, so neither ever produces a remedy that sends bytes.
## `rom_state` is one of "have", "romm", "missing"; `firmware_diff` holds the
## per-file comparison and is empty when the digests already agree.
static func media_row(machine_id: Variant, label: String, rom_state: String,
		rom_label: String, rom_md5: String, firmware_diff: Array) -> Dictionary:
	var detail: Array[Dictionary] = []
	detail.append(_row("Game", rom_label if not rom_label.is_empty() else "(unnamed)"))
	if not rom_md5.is_empty():
		detail.append(_row("MD5", rom_md5))

	for d: Dictionary in firmware_diff:
		detail.append(_row(str(d.get("file", "?")), _firmware_words(str(d.get("state", "")))))

	if not firmware_diff.is_empty():
		return _make("media", machine_id, label, Verdict.BLOCKED,
			"Your BIOS does not match the host's", detail, {"kind": "open_bios"})

	match rom_state:
		"have":
			return _make("media", machine_id, label, Verdict.READY,
				"You have this game", detail, {})
		"romm":
			return _make("media", machine_id, label, Verdict.WARN,
				"Available from your RomM server", detail,
				{"kind": "fetch_rom", "md5": rom_md5, "machine": machine_id})
		_:
			detail.append(_row("Transfer", "game files are never sent between players"))
			return _make("media", machine_id, label, Verdict.BLOCKED,
				"You do not have this game", detail, {})


## The verdict for a whole list: the worst one present.
##
## BLOCKED outranks PENDING outranks WARN. PENDING sits above WARN because a
## check that has not finished cannot be reported as merely cosmetic.
static func overall(rows: Array) -> int:
	var worst := Verdict.READY
	for r: Dictionary in rows:
		var v := int(r.get("verdict", Verdict.READY))
		if v == Verdict.BLOCKED:
			return Verdict.BLOCKED
		if v == Verdict.PENDING:
			worst = Verdict.PENDING
		elif v == Verdict.WARN and worst != Verdict.PENDING:
			worst = Verdict.WARN
	return worst


## True when every row would let the session run. PENDING is not ready.
static func all_ready(rows: Array) -> bool:
	return overall(rows) == Verdict.READY


static func verdict_word(verdict: Verdict) -> String:
	return str(VERDICT_WORD.get(verdict, "?"))


## Compare the host's firmware rows against ours, newest question first: which
## FILE differs. Returns [] when they agree.
##
## The digest alone cannot answer this -- it is one sha256 over every row -- so
## a joiner told only that it differs learns nothing it can act on.
static func firmware_diff(want_rows: Dictionary, got_rows: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for file: String in want_rows:
		var mine := str(got_rows.get(file, ""))
		if mine.is_empty():
			out.append({"file": file, "state": "missing"})
		elif mine != str(want_rows[file]):
			out.append({"file": file, "state": "differs"})
	for file: String in got_rows:
		if not want_rows.has(file):
			out.append({"file": file, "state": "extra"})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return str(a["file"]) < str(b["file"]))
	return out


## 0 means the core has not been asked yet -- retro_serialize_size is only safe
## after the first retro_run, and the netplay gate does not run frame 0 until
## every peer is ready. Reporting that as a mismatch is how a normal cold start
## gets described as a fault.
static func _size_words(want: Dictionary, got: Dictionary) -> String:
	var a := int(want.get("serialize_size", 0))
	var b := int(got.get("serialize_size", 0))
	if a == 0 or b == 0:
		return "not measured yet"
	if a == b:
		return "%d bytes" % a
	return "%d vs %d bytes" % [a, b]


static func _firmware_words(state: String) -> String:
	match state:
		"missing":
			return "you are missing this file"
		"extra":
			return "the host does not have this file"
		_:
			return "you have a different file"


static func _row(name: String, value: String) -> Dictionary:
	return {"name": name, "value": value}


static func _make(kind: String, id: Variant, label: String, verdict: int,
		headline: String, detail: Array[Dictionary], remedy: Dictionary) -> Dictionary:
	return {
		"kind": kind,
		"id": id,
		"label": label,
		"verdict": verdict,
		"headline": headline,
		"detail": detail,
		"remedy": remedy,
	}
