## hdhomerun_tests — the wire format the TV tuner is found over, and the lineup
## that comes back.
##
## HDHomeRun discovery is a UDP broadcast with a checksummed binary frame. None
## of it reports an error when it is wrong: a bad CRC means the device ignores
## the packet, the broadcast times out, and the player is told there is no tuner
## on the network. There is nothing in a log to distinguish that from a tuner
## that is genuinely switched off, which is why the framing is worth pinning
## against fixed bytes rather than against itself.
##
## Everything here is offline. The socket is never opened: _frame, _put_tag,
## _crc32, _is_discover_reply, _map_lineup, _rehost and _host_of are pure, and
## the CRC is checked against published IEEE 802.3 vectors rather than against
## whatever this implementation happens to produce today.
##
##   "$godot" --headless --path RetroXR res://Tests/hdhomerun_tests.tscn
extends Node

var _passed := 0
var _failed := 0

var _hdhr: HDHomeRun = null


func _ready() -> void:
	get_tree().create_timer(30.0).timeout.connect(func() -> void:
		push_error("[hdhr] TIMEOUT")
		get_tree().quit(1))

	_hdhr = HDHomeRun.new()
	add_child(_hdhr)

	_group_crc()
	_group_frame()
	_group_lineup()
	_group_hosts()

	print("[hdhr] %d checks, %d failed" % [_passed + _failed, _failed])
	print("[hdhr] RESULT=%s" % ("PASS" if _failed == 0 else "FAIL"))
	get_tree().quit(1 if _failed > 0 else 0)


func _ok(cond: bool, what: String, detail := "") -> void:
	if cond:
		_passed += 1
		print("[hdhr] ok   %s" % what)
	else:
		_failed += 1
		print("[hdhr] FAIL %s%s" % [what, "" if detail.is_empty() else "  -- " + detail])


func _eq(got: Variant, want: Variant, what: String) -> void:
	_ok(got == want, what, "got %s, want %s" % [got, want])


func _bytes(a: Array) -> PackedByteArray:
	var out := PackedByteArray()
	for v: int in a:
		out.append(v)
	return out


# ── crc/ ──────────────────────────────────────────────────────────────────────

## Against the published IEEE 802.3 answers, not against ourselves. A CRC that
## is self-consistently wrong is exactly the failure this cannot otherwise see —
## the device simply drops the packet.
func _group_crc() -> void:
	_eq(_hdhr._crc32(PackedByteArray()), 0x00000000, "crc/empty input is zero")
	_eq(_hdhr._crc32("123456789".to_ascii_buffer()), 0xCBF43926,
		"crc/the standard check value for '123456789'")
	_eq(_hdhr._crc32("a".to_ascii_buffer()), 0xE8B7BE43, "crc/single byte 'a'")
	_eq(_hdhr._crc32(_bytes([0, 0, 0, 0])), 0x2144DF1C, "crc/four zero bytes")

	# It must stay inside 32 bits: GDScript ints are 64-bit and an unmasked
	# shift would carry sign or overflow into the top half.
	var wide := _hdhr._crc32(_bytes([0xFF, 0xFF, 0xFF, 0xFF]))
	_ok(wide >= 0 and wide <= 0xFFFFFFFF, "crc/the result stays a uint32",
		"got %d" % wide)


# ── frame/ ────────────────────────────────────────────────────────────────────

## [type:2 BE][length:2 BE][payload][crc32:4 LE]
func _group_frame() -> void:
	var payload := _bytes([0x01, 0x04, 0xFF, 0xFF, 0xFF, 0xFF])
	var f := _hdhr._frame(0x0002, payload)

	_eq(f.size(), 4 + payload.size() + 4, "frame/header plus payload plus crc")
	_eq(f[0], 0x00, "frame/type is big-endian, high byte first")
	_eq(f[1], 0x02, "frame/type low byte")
	_eq(f[2], 0x00, "frame/length is big-endian too")
	_eq(f[3], payload.size(), "frame/length counts the payload only")
	for i in payload.size():
		_eq(f[4 + i], payload[i], "frame/payload byte %d survives" % i)

	# The CRC covers header AND payload, and goes on the end little-endian --
	# the one field in this frame that is not big-endian.
	var expect := _hdhr._crc32(f.slice(0, f.size() - 4))
	var got := f[f.size() - 4] | (f[f.size() - 3] << 8) \
		| (f[f.size() - 2] << 16) | (f[f.size() - 1] << 24)
	_eq(got, expect, "frame/crc is little-endian over everything before it")

	# A tag is [tag][len=4][value big-endian].
	var buf := PackedByteArray()
	_hdhr._put_tag(buf, 0x01, 0x01020304)
	_eq(buf.size(), 6, "frame/a tag is six bytes")
	_eq(buf[0], 0x01, "frame/tag id first")
	_eq(buf[1], 4, "frame/then its length")
	_eq([buf[2], buf[3], buf[4], buf[5]], [0x01, 0x02, 0x03, 0x04],
		"frame/tag value is big-endian")

	# Only a reply of the right type is a reply, and a runt is never one.
	_ok(_hdhr._is_discover_reply(_bytes([0x00, 0x03, 0, 0, 0, 0, 0, 0])),
		"frame/a discover reply is recognised")
	_ok(not _hdhr._is_discover_reply(_bytes([0x00, 0x02, 0, 0, 0, 0, 0, 0])),
		"frame/our own request type is not a reply")
	_ok(not _hdhr._is_discover_reply(_bytes([0x00, 0x03])),
		"frame/a packet too short to hold a header is not a reply")
	_ok(not _hdhr._is_discover_reply(PackedByteArray()),
		"frame/an empty packet is not a reply")


# ── lineup/ ───────────────────────────────────────────────────────────────────

## What the device says its channels are, and what the room needs them to be.
func _group_lineup() -> void:
	_hdhr._host = "10.0.0.9"
	var mapped := _hdhr._map_lineup([
		{"GuideNumber": "5.1", "GuideName": "KTLA", "HD": 1,
			"URL": "http://tuner.local:5004/auto/v5.1"},
		{"GuideNumber": "9.1", "GuideName": "KOCE",
			"URL": "http://tuner.local:5004/auto/v9.1"},
		{"GuideNumber": "12.1", "GuideName": "No URL"},
		"not a row at all",
	])

	_eq(mapped.size(), 2, "lineup/rows without a URL and non-rows are dropped")
	_eq(mapped[0]["number"], "5.1", "lineup/the guide number is carried")
	_eq(mapped[0]["name"], "KTLA", "lineup/and the name")
	_eq(mapped[0]["source"], "hdhomerun", "lineup/the source is stamped")
	# HD arrives as 1 or absent, never as a JSON bool, so it is compared as an int.
	_ok(bool(mapped[0]["hd"]), "lineup/HD 1 reads as true")
	_ok(not bool(mapped[1]["hd"]), "lineup/an absent HD reads as false")


# ── hosts/ ────────────────────────────────────────────────────────────────────

## A tuner advertises whatever hostname it likes and the room may not be able to
## resolve it — the address that actually answered is the one that works.
func _group_hosts() -> void:
	_hdhr._host = "192.168.1.50"
	_eq(_hdhr._rehost("http://tuner.local:5004/auto/v5.1"),
		"http://192.168.1.50:5004/auto/v5.1",
		"hosts/the advertised hostname is swapped for the one that answered")
	_eq(_hdhr._rehost("http://tuner.local:5004"),
		"http://192.168.1.50:5004",
		"hosts/a URL with no path still rehosts")
	_ok(_hdhr._rehost("http://tuner.local/auto/v1").begins_with("http://192.168.1.50:"),
		"hosts/a URL with no port gets the control port")

	_eq(_hdhr._host_of("http://1.2.3.4:5004/lineup.json"), "1.2.3.4",
		"hosts/the host is taken out of a full URL")
	_eq(_hdhr._host_of("https://1.2.3.4:5004"), "1.2.3.4", "hosts/https too")
	_eq(_hdhr._host_of("1.2.3.4"), "1.2.3.4", "hosts/a bare address is itself")
