## RendezvousClient — the room-code registry.
##
## Four calls against `net.retroxr.app`: a host creates a room and gets a code
## back, keeps it alive with a heartbeat, and deletes it when the session ends;
## a joiner looks a code up. The registry carries no game traffic — it hands out
## the punch endpoint and the noray OID of the host, and everything after that
## is peer to peer.
##
## Structured after RommClient._request_json (Scripts/Net/romm/romm_client.gd),
## the established shape in this project for an HTTPRequest-per-call client:
## use_threads, queue_free in the completion lambda, and a callback that fires
## exactly once on every path.
##
## Two things here are deliberate and load-bearing:
##
## Only the registry URL is hardcoded. `punch_host`/`punch_port` arrive in the
## response, so the punch endpoint can move without shipping a new client — and
## on a store build, without a resubmission.
##
## Failure is typed, because the caller must treat the kinds differently. A
## registry that cannot be reached has to fall back to LAN entry silently: the
## rendezvous going down cannot take local play with it. A code that does not
## resolve is something the player did, and has to be said out loud. Collapsing
## those two into one boolean gives either a silent dead end or a frightening
## message about a feature that is working.
class_name RendezvousClient
extends Node

const DEFAULT_BASE_URL := "https://net.retroxr.app/v1"

## Short on purpose. RommClient waits 30 s because abandoning an achievement
## unlock loses it; here a slow answer must give way to the LAN path rather than
## hold a player in front of a dead panel.
const REQUEST_TIMEOUT := 10.0

enum Result {
	OK,
	## Nothing answered: no network, DNS, TLS, or the box is down. Fall back.
	UNREACHABLE,
	## The registry answered, and there is no such room. Say so.
	NOT_FOUND,
	## The registry refused: rate limit, room cap, or a bad secret.
	REFUSED,
	## Something answered in a shape this client cannot use.
	BAD_RESPONSE,
}

## The registry to talk to. A loopback probe points this at the local compose
## stack; nothing else should change it.
var base_url := DEFAULT_BASE_URL


# ---------------------------------------------------------------------------
# Calls
# ---------------------------------------------------------------------------

## Claim a room code for a session this peer is hosting.
## callback(result: Result, room: Dictionary) — on OK, room carries
## code, secret, ttl, punch_host, punch_port.
func create_room(oid: String, room_name: String, protocol_version: int,
				 callback: Callable) -> void:
	var body := JSON.stringify({
		"oid": oid,
		"name": room_name,
		"protocol_version": protocol_version,
	})
	_request("/rooms", HTTPClient.METHOD_POST, body, "",
		func(res: int, data: Variant) -> void:
			if res != Result.OK:
				callback.call(res, {})
				return
			var room := parse_created(data)
			callback.call(Result.OK if not room.is_empty() else Result.BAD_RESPONSE, room)
	)


## Tell the registry the room is still live. callback(result: Result, ttl: int).
func heartbeat(code: String, secret: String, callback: Callable) -> void:
	_request("/rooms/%s/heartbeat" % code, HTTPClient.METHOD_POST, "", secret,
		func(res: int, data: Variant) -> void:
			if res != Result.OK:
				callback.call(res, 0)
				return
			var ttl := parse_heartbeat(data)
			callback.call(Result.OK if ttl > 0 else Result.BAD_RESPONSE, ttl)
	)


## Drop the room. Best effort: the TTL collects it anyway if this never lands.
## callback(result: Result).
func close_room(code: String, secret: String, callback := Callable()) -> void:
	_request("/rooms/%s" % code, HTTPClient.METHOD_DELETE, "", secret,
		func(res: int, _data: Variant) -> void:
			if callback.is_valid():
				callback.call(res)
	)


## Resolve a code a player typed. callback(result: Result, room: Dictionary) —
## on OK, room carries oid, name, protocol_version, punch_host, punch_port.
##
## The code is normalized and gated here rather than sent as typed: a malformed
## code is a local answer, and asking the registry about one would spend a round
## trip to be told the same thing in a message that also means "expired".
func lookup(raw_code: String, callback: Callable) -> void:
	var code := RoomCode.normalize(raw_code)
	if not RoomCode.is_valid(code):
		callback.call(Result.NOT_FOUND, {})
		return
	_request("/rooms/%s" % code, HTTPClient.METHOD_GET, "", "",
		func(res: int, data: Variant) -> void:
			if res != Result.OK:
				callback.call(res, {})
				return
			var room := parse_room(data)
			callback.call(Result.OK if not room.is_empty() else Result.BAD_RESPONSE, room)
	)


# ---------------------------------------------------------------------------
# Response shapes — pure, so they can be tested without a server
# ---------------------------------------------------------------------------

## The answer to a room creation. Returns {} for anything unusable.
static func parse_created(data: Variant) -> Dictionary:
	if not data is Dictionary:
		return {}
	var d: Dictionary = data
	var code := RoomCode.normalize(str(d.get("code", "")))
	# A code this client would refuse from a player is not one it can accept
	# from the registry either. Carrying it forward would put an unusable string
	# in front of someone to read out.
	if not RoomCode.is_valid(code):
		return {}
	var secret := str(d.get("secret", ""))
	if secret.is_empty():
		return {}
	var punch := _parse_punch(d)
	if punch.is_empty():
		return {}
	return {
		"code": code,
		"secret": secret,
		"ttl": int(d.get("ttl", 0)),
		"punch_host": punch["punch_host"],
		"punch_port": punch["punch_port"],
	}


## The answer to a code lookup. Returns {} for anything unusable.
static func parse_room(data: Variant) -> Dictionary:
	if not data is Dictionary:
		return {}
	var d: Dictionary = data
	var oid := str(d.get("oid", ""))
	if oid.is_empty():
		return {}
	var punch := _parse_punch(d)
	if punch.is_empty():
		return {}
	# protocol_version is compared by the caller, which owns the constant. A
	# record without one cannot be checked, and an uncheckable peer is refused
	# here rather than discovered as a desync later.
	if not d.has("protocol_version"):
		return {}
	return {
		"oid": oid,
		"name": str(d.get("name", "")),
		"protocol_version": int(d.get("protocol_version", 0)),
		"punch_host": punch["punch_host"],
		"punch_port": punch["punch_port"],
	}


## Seconds the room has left, or -1 if the answer did not say.
static func parse_heartbeat(data: Variant) -> int:
	if not data is Dictionary:
		return -1
	var d: Dictionary = data
	if not bool(d.get("ok", false)):
		return -1
	var ttl := int(d.get("ttl", 0))
	return ttl if ttl > 0 else -1


static func _parse_punch(d: Dictionary) -> Dictionary:
	var host := str(d.get("punch_host", ""))
	var port := int(d.get("punch_port", 0))
	if host.is_empty() or port <= 0 or port > 65535:
		return {}
	return {"punch_host": host, "punch_port": port}


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

## callback(result: Result, parsed: Variant)
func _request(path: String, method: int, body: String, secret: String,
			  callback: Callable) -> void:
	var headers := PackedStringArray()
	if not body.is_empty():
		headers.append("Content-Type: application/json")
	if not secret.is_empty():
		# The secret rides a header rather than a body: DELETE carries no body,
		# and one auth shape for both calls is one thing for the server to get
		# right.
		headers.append("Authorization: Bearer " + secret)

	var http := HTTPRequest.new()
	http.use_threads = true
	http.timeout = REQUEST_TIMEOUT
	add_child(http)

	http.request_completed.connect(
		func(result: int, response_code: int, _rh: PackedStringArray,
			 raw: PackedByteArray) -> void:
			http.queue_free()

			if result != HTTPRequest.RESULT_SUCCESS:
				push_warning("[Rendezvous] %s failed (result %d)" % [path, result])
				callback.call(Result.UNREACHABLE, null)
				return

			if response_code == 404:
				callback.call(Result.NOT_FOUND, null)
				return

			# 5xx is the registry itself falling over. That is the case the LAN
			# fallback exists for, so it reads as unreachable rather than as
			# something the player did.
			if response_code >= 500:
				push_warning("[Rendezvous] %s -> HTTP %d" % [path, response_code])
				callback.call(Result.UNREACHABLE, null)
				return

			if response_code < 200 or response_code >= 300:
				push_warning("[Rendezvous] %s -> HTTP %d" % [path, response_code])
				callback.call(Result.REFUSED, null)
				return

			# A body-less 204 is a legitimate answer to DELETE.
			if raw.is_empty():
				callback.call(Result.OK, {})
				return

			var json := JSON.new()
			if json.parse(raw.get_string_from_utf8()) != OK:
				push_warning("[Rendezvous] %s: bad JSON (%s)"
					% [path, json.get_error_message()])
				callback.call(Result.BAD_RESPONSE, null)
				return

			callback.call(Result.OK, json.data)
	)

	var err := http.request(base_url + path, headers, method, body)
	if err != OK:
		http.queue_free()
		push_warning("[Rendezvous] could not start %s (err %d)" % [path, err])
		callback.call(Result.UNREACHABLE, null)
