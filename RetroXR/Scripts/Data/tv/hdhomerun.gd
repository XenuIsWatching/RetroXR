## HDHomeRun — finds a SiliconDust tuner on the LAN and reads its channel lineup.
##
## Add as a child node (it needs the tree for HTTPRequest), call find_lineup(),
## then wait on lineup_ready or discovery_failed.
##
## Discovery is layered, cheapest and most reliable first:
##   1. an explicit host from channels.json  — the user said where it is
##   2. the last address that worked         — cached in user://
##   3. a UDP broadcast on port 65001        — SiliconDust's own protocol
##   4. http://hdhomerun.local/discover.json — mDNS, last because it is the
##      flakiest link: resolution here has returned a link-local IPv6 ahead of
##      IPv4 and hung a resolver outright, and Android may not resolve .local
##      at all. Everything above yields a bare IPv4, which always works.
##
## Every URL the device hands back is rewritten onto the address that answered,
## for the same reason: lineup.json advertises `http://hdhr-xxxxxxxx.local:5004/`
## and the headset must not have to resolve that at play time.
class_name HDHomeRun
extends Node

## channels: Array[Dictionary] as described in TVChannels; info describes the box.
signal lineup_ready(channels: Array, info: Dictionary)
signal discovery_failed(message: String)

const DISCOVER_PORT := 65001
const CONTROL_PORT := 5004
const CACHE_PATH := "user://tv_lineup_cache.json"

const _TYPE_DISCOVER_REQ := 0x0002
const _TYPE_DISCOVER_RPY := 0x0003
const _TAG_DEVICE_TYPE := 0x01
const _TAG_DEVICE_ID := 0x02
const _DEVICE_TYPE_TUNER := 0x00000001
const _DEVICE_ID_WILDCARD := 0xFFFFFFFF

## Broadcast is a single round trip on a quiet LAN; a slow box still answers well
## inside this, and a missing one should not stall the options panel.
const BROADCAST_TIMEOUT := 1.5
const HTTP_TIMEOUT := 6.0

var _http: HTTPRequest = null
var _host := ""
var _info: Dictionary = {}
var _busy := false


func _ready() -> void:
	_http = HTTPRequest.new()
	_http.timeout = HTTP_TIMEOUT
	add_child(_http)


## Find a tuner and read its lineup. `host` empty means discover.
func find_lineup(host: String = "", allow_discovery: bool = true) -> void:
	if _busy:
		return
	_busy = true
	_info = {}

	var candidates: Array[String] = []
	if not host.strip_edges().is_empty():
		candidates.append(host.strip_edges())
	elif allow_discovery:
		var cached := _cached_host()
		if not cached.is_empty():
			candidates.append(cached)
		var found := await _broadcast_discover()
		for ip in found:
			if not candidates.has(ip):
				candidates.append(ip)
		if not candidates.has("hdhomerun.local"):
			candidates.append("hdhomerun.local")
	else:
		_fail("No tuner address set")
		return

	for candidate in candidates:
		var ok := await _try_host(candidate)
		if ok:
			return
	_fail("Tuner not found" if host.is_empty() else "No response at %s" % host)


## One HTTP round trip to discover.json, then lineup.json. Returns success.
func _try_host(host: String) -> bool:
	var base := host
	if not base.begins_with("http://") and not base.begins_with("https://"):
		base = "http://" + base

	var discover: Variant = await _get_json(base + "/discover.json")
	if not (discover is Dictionary):
		return false
	var d: Dictionary = discover
	if not d.has("LineupURL") and not d.has("DeviceID"):
		return false

	_host = _host_of(base)
	_info = {
		"name": str(d.get("FriendlyName", "HDHomeRun")),
		"model": str(d.get("ModelNumber", "")),
		"device_id": str(d.get("DeviceID", "")),
		"tuners": int(d.get("TunerCount", 0)),
		"host": _host,
	}

	# One retry: the box intermittently refuses a lineup.json that follows hard on
	# the heels of a previous one (observed in testing), and reporting "no lineup"
	# for what is really a busy moment would send the user off to rescan channels
	# that are perfectly fine.
	var lineup: Variant = await _get_json(base + "/lineup.json")
	if not (lineup is Array):
		await get_tree().create_timer(0.5).timeout
		lineup = await _get_json(base + "/lineup.json")
	if not (lineup is Array):
		# The box answered discover.json, so it is a tuner -- an empty or failed
		# lineup means it has not been scanned, which is worth saying plainly
		# rather than reporting as "not found".
		_fail("%s has no channel lineup — run a channel scan" % _info["name"])
		return true

	var channels := _map_lineup(lineup as Array)
	if channels.is_empty():
		_fail("%s has no channel lineup — run a channel scan" % _info["name"])
		return true

	_save_cache(channels)
	_busy = false
	lineup_ready.emit(channels, _info)
	return true


func _map_lineup(rows: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for row_v: Variant in rows:
		if not (row_v is Dictionary):
			continue
		var row: Dictionary = row_v
		var url := str(row.get("URL", "")).strip_edges()
		if url.is_empty():
			continue
		out.append({
			"number": str(row.get("GuideNumber", "")),
			"name": str(row.get("GuideName", "")),
			"url": _rehost(url),
			"source": "hdhomerun",
			# HD arrives as 1 or absent, never as a JSON bool.
			"hd": int(row.get("HD", 0)) == 1,
		})
	return out


## Swap whatever hostname the device advertises for the address that answered.
func _rehost(url: String) -> String:
	var rest := url.trim_prefix("http://")
	var slash := rest.find("/")
	# Path may be absent; treat the whole remainder as authority in that case.
	var path := rest.substr(slash) if slash >= 0 else ""
	var authority := rest.substr(0, slash) if slash >= 0 else rest
	var colon := authority.rfind(":")
	var port := authority.substr(colon) if colon >= 0 else ":%d" % CONTROL_PORT
	return "http://%s%s%s" % [_host, port, path]


func _host_of(base: String) -> String:
	var rest := base.trim_prefix("http://").trim_prefix("https://")
	var slash := rest.find("/")
	if slash >= 0:
		rest = rest.substr(0, slash)
	var colon := rest.rfind(":")
	return rest.substr(0, colon) if colon >= 0 else rest


func _get_json(url: String) -> Variant:
	if _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		_http.cancel_request()
	var err := _http.request(url)
	if err != OK:
		return null
	var result: Array = await _http.request_completed
	var code: int = result[1]
	var body: PackedByteArray = result[3]
	if int(result[0]) != HTTPRequest.RESULT_SUCCESS:
		push_warning("[HDHomeRun] %s -> transport result %d" % [url, int(result[0])])
		return null
	if code == 503:
		# The documented answer when every tuner is already streaming. Distinct
		# from "not there" -- the set should say so rather than show no signal.
		_fail("All tuners in use")
		return null
	if code != 200:
		push_warning("[HDHomeRun] %s -> HTTP %d" % [url, code])
		return null
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		push_warning("[HDHomeRun] %s -> bad JSON (%d bytes): %s"
			% [url, body.size(), json.get_error_message()])
		return null
	return json.data


# ── UDP broadcast discovery ───────────────────────────────────────────────────

## SiliconDust's own discovery: a tag-length-value packet to 255.255.255.255,
## answered by every tuner on the subnet. Blocking, but bounded and sub-second,
## and unlike mDNS it works the same on desktop and on the headset.
func _broadcast_discover() -> Array[String]:
	var found: Array[String] = []
	var payload := PackedByteArray()
	_put_tag(payload, _TAG_DEVICE_TYPE, _DEVICE_TYPE_TUNER)
	_put_tag(payload, _TAG_DEVICE_ID, _DEVICE_ID_WILDCARD)
	var request := _frame(_TYPE_DISCOVER_REQ, payload)

	# One socket per local IPv4, each bound to that address. A machine with a VM
	# bridge, a VPN and a real NIC has several, and a socket left to pick for
	# itself sends 255.255.255.255 out exactly one of them -- picking wrong here
	# is silent, and the fallback is the mDNS name this whole path exists to
	# avoid. Binding per interface asks all of them.
	var sockets: Array[PacketPeerUDP] = []
	for addr in _local_ipv4():
		var udp := PacketPeerUDP.new()
		udp.set_broadcast_enabled(true)
		if udp.bind(0, addr) != OK:
			continue
		if udp.set_dest_address("255.255.255.255", DISCOVER_PORT) != OK:
			udp.close()
			continue
		udp.put_packet(request)
		sockets.append(udp)
	if sockets.is_empty():
		return found

	var deadline := Time.get_ticks_msec() + int(BROADCAST_TIMEOUT * 1000.0)
	while Time.get_ticks_msec() < deadline:
		var idle := true
		for udp in sockets:
			while udp.get_available_packet_count() > 0:
				idle = false
				var packet := udp.get_packet()
				var ip := udp.get_packet_ip()
				if _is_discover_reply(packet) and not ip.is_empty() and not found.has(ip):
					found.append(ip)
					print("[HDHomeRun] Broadcast reply from %s" % ip)
		if not found.is_empty():
			break
		if idle:
			await get_tree().process_frame
	for udp in sockets:
		udp.close()
	return found


## Every non-loopback IPv4 this host owns.
func _local_ipv4() -> Array[String]:
	var out: Array[String] = []
	for a in IP.get_local_addresses():
		var addr := str(a)
		if addr.contains(":"):
			continue                      # IPv6; HDHomeRun discovery is v4 only
		if addr.begins_with("127."):
			continue
		out.append(addr)
	return out


func _is_discover_reply(packet: PackedByteArray) -> bool:
	if packet.size() < 8:
		return false
	return (packet[0] << 8 | packet[1]) == _TYPE_DISCOVER_RPY


## [type:2 BE][length:2 BE][payload][crc32:4 LE]
func _frame(type: int, payload: PackedByteArray) -> PackedByteArray:
	var out := PackedByteArray()
	out.append((type >> 8) & 0xFF)
	out.append(type & 0xFF)
	out.append((payload.size() >> 8) & 0xFF)
	out.append(payload.size() & 0xFF)
	out.append_array(payload)
	var crc := _crc32(out)
	for i in 4:
		out.append((crc >> (8 * i)) & 0xFF)
	return out


func _put_tag(buf: PackedByteArray, tag: int, value: int) -> void:
	buf.append(tag)
	buf.append(4)
	for i in 4:
		buf.append((value >> (8 * (3 - i))) & 0xFF)


## CRC-32 (IEEE 802.3), reflected, as libhdhomerun computes it.
func _crc32(data: PackedByteArray) -> int:
	var crc := 0xFFFFFFFF
	for b in data:
		crc ^= b
		for _i in 8:
			var mask := -(crc & 1)
			crc = (crc >> 1) ^ (0xEDB88320 & mask)
			crc &= 0xFFFFFFFF
	return (~crc) & 0xFFFFFFFF


# ── cache ─────────────────────────────────────────────────────────────────────

## Remember the address and the lineup, so a cold start with the tuner asleep
## still shows a channel list and a retry does not wait on discovery again.
func _save_cache(channels: Array[Dictionary]) -> void:
	# A disposable cache: an unwritable one costs a discovery round on the next
	# cold start and nothing else, so the failure is not worth a complaint.
	JsonStore.write_dict(CACHE_PATH, {
		"host": _host,
		"info": _info,
		"channels": channels,
	})


static func load_cache() -> Dictionary:
	if not FileAccess.file_exists(CACHE_PATH):
		return {}
	var file := FileAccess.open(CACHE_PATH, FileAccess.READ)
	if not file:
		return {}
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return {}
	return json.data if json.data is Dictionary else {}


func _cached_host() -> String:
	return str(load_cache().get("host", ""))


func _fail(message: String) -> void:
	_busy = false
	push_warning("[HDHomeRun] %s" % message)
	# Deferred: some failures (no address set) are reached without ever yielding,
	# and a caller that connects on the line after find_lineup() would miss a
	# signal emitted inline -- then wait forever for one that already happened.
	discovery_failed.emit.call_deferred(message)
