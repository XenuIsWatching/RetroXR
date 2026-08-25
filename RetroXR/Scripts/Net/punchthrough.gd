## Punchthrough — opens a direct path between two players behind NAT.
##
## The registry hands out a punch endpoint and the OID of the host; this drives
## the conversation with that endpoint until both ends hold a UDP port the other
## can reach. Everything after that is ENet, peer to peer, and never touches our
## infrastructure again.
##
## The shape of the exchange, which is worth knowing before reading any of it:
##
##   1. TCP to noray. It answers with set-oid (public, shareable) and set-pid
##      (secret, proves this connection is ours).
##   2. Send the PID over UDP to the registrar port, repeatedly, until it says
##      OK. That teaches noray the external address of THIS machine, and the
##      local port it went out of is the one both peers must keep using.
##   3. The joiner asks noray to connect it to an OID. Noray tells BOTH sides
##      the address of the other.
##   4. Both blast small status packets at each other until each has seen one
##      from the other. That is the hole being punched: the return path only
##      exists because something went out first.
##
## Ported from the netfox.noray addon (github.com/foxssake/netfox), MIT, rather
## than vendored. See ATTRIBUTIONS.txt beside this file for what was taken and
## why it was not simply installed.
##
## Relay is deliberately not here. Noray implements it, and connect-relay is one
## command away, but a relayed session spends our bandwidth rather than the
## bandwidth of the two players. The server can be given a relay later without
## any client shipping again; until then a pair that cannot be punched is told
## so, plainly.
class_name Punchthrough
extends Node

## Noray defaults. Both arrive from the registry in practice, so these are the
## fallback rather than the source of truth.
const DEFAULT_PUNCH_PORT := 8890
const DEFAULT_REGISTRAR_PORT := 8809

## How long each phase gets before it is called a failure. The punch itself is
## the short one on purpose: if the packets were going to arrive they would have
## arrived, and a player watching a spinner learns nothing from the extra wait.
const CONNECT_TIMEOUT := 8.0
const REGISTER_TIMEOUT := 8.0
const HANDSHAKE_TIMEOUT := 8.0
const HANDSHAKE_INTERVAL := 0.1

enum Result {
	OK,
	## Noray itself could not be reached: DNS, the box, or the port.
	UNREACHABLE,
	## Noray was reached but never answered the way the protocol says.
	PROTOCOL_ERROR,
	## The other side never appeared. Almost always symmetric NAT or CGNAT.
	UNPUNCHABLE,
	## No room with that OID, or the host stopped hosting mid-attempt.
	NO_SUCH_HOST,
}

## A joiner appeared and its address is punched. The host connects nothing here
## - it is already listening - but it must keep answering until the newcomer
## finishes, which is what this signal is for.
signal peer_punched(address: String, port: int)

var _tcp := StreamPeerTCP.new()
var _buf := ""
var _oid := ""
var _pid := ""
var _local_port := -1
var _address := ""
var _pending := []


# ---------------------------------------------------------------------------
# The two things a caller wants
# ---------------------------------------------------------------------------

## Become reachable. Returns {result, oid, local_port}: create the ENet server
## on local_port and publish oid to the registry as the room.
##
## The node stays live afterwards and emits peer_punched for each joiner. Free
## it when the session ends.
func host(punch_host: String, punch_port := DEFAULT_PUNCH_PORT,
		  registrar_port := DEFAULT_REGISTRAR_PORT) -> Dictionary:
	var res := await _open(punch_host, punch_port)
	if res != Result.OK:
		return {"result": res, "oid": "", "local_port": -1}

	_put("register-host")
	# Both ids, not just the public one: without the PID the registrar below has
	# no way to tell which TCP connection the UDP packet belongs to.
	if not await _await_ids():
		return {"result": Result.PROTOCOL_ERROR, "oid": "", "local_port": -1}

	if not await _register_remote(registrar_port):
		return {"result": Result.UNREACHABLE, "oid": "", "local_port": -1}

	return {"result": Result.OK, "oid": _oid, "local_port": _local_port}


## Reach a host by the OID the registry gave for its code. Returns
## {result, host_addr, host_port, local_port}: hand all three to
## ENetMultiplayerPeer.create_client, local_port last.
func join(punch_host: String, host_oid: String,
		  punch_port := DEFAULT_PUNCH_PORT,
		  registrar_port := DEFAULT_REGISTRAR_PORT) -> Dictionary:
	var fail := {"result": Result.UNREACHABLE, "host_addr": "", "host_port": 0,
		"local_port": -1}

	var res := await _open(punch_host, punch_port)
	if res != Result.OK:
		fail["result"] = res
		return fail

	_put("register-host")
	if not await _await_ids():
		fail["result"] = Result.PROTOCOL_ERROR
		return fail

	if not await _register_remote(registrar_port):
		return fail

	# Noray answers this by telling BOTH ends about each other. Nothing comes
	# back if the OID is unknown, so a silent timeout here means the room is
	# gone rather than the network being at fault.
	_put("connect", host_oid)
	var peer := await _await_connect()
	if peer.is_empty():
		fail["result"] = Result.NO_SUCH_HOST
		return fail

	var udp := PacketPeerUDP.new()
	if udp.bind(_local_port) != OK:
		fail["result"] = Result.PROTOCOL_ERROR
		return fail
	udp.set_dest_address(peer["address"], peer["port"])

	var shook := await _handshake(udp)
	udp.close()

	if not shook:
		fail["result"] = Result.UNPUNCHABLE
		fail["host_addr"] = peer["address"]
		fail["host_port"] = peer["port"]
		return fail

	# The mapping lives for tens of seconds after the socket closes, which is
	# the only reason it is safe to hand the same port straight to ENet. It is
	# also the known risk in this design on Windows and on Quest: if the rebind
	# is refused, hold the mapping open with a second socket across the swap
	# rather than lengthening this wait.
	return {
		"result": Result.OK,
		"host_addr": peer["address"],
		"host_port": peer["port"],
		"local_port": _local_port,
	}


# ---------------------------------------------------------------------------
# Protocol — pure, so it can be tested without a noray
# ---------------------------------------------------------------------------

## One line of the noray protocol: a command, optionally followed by one space
## and a parameter. Returns {command, data}, both empty for a blank line.
static func parse_command(line: String) -> Dictionary:
	if line.is_empty():
		return {"command": "", "data": ""}
	var space := line.find(" ")
	if space < 0:
		return {"command": line, "data": ""}
	return {"command": line.substr(0, space), "data": line.substr(space + 1)}


## Splits a received buffer into whole lines, returning the commands and the
## unconsumed remainder. A partial line is kept rather than parsed: TCP is a
## stream, and a command split across two reads is normal rather than an error.
static func ingest(buffer: String) -> Dictionary:
	var out: Array[Dictionary] = []
	var rest := buffer
	while true:
		var nl := rest.find("\n")
		if nl < 0:
			break
		var line := rest.substr(0, nl)
		rest = rest.substr(nl + 1)
		if not line.is_empty():
			out.append(parse_command(line))
	return {"commands": out, "rest": rest}


## The address noray reports for a peer, as host:port. Returns {} if it is not
## one - an unparsable address must not become port 0 on some default host.
static func parse_address(data: String) -> Dictionary:
	var colon := data.rfind(":")
	if colon <= 0:
		return {}
	var host := data.substr(0, colon)
	var port := data.substr(colon + 1).to_int()
	if host.is_empty() or port <= 0 or port > 65535:
		return {}
	return {"address": host, "port": port}


## The handshake packet: which of the three things this side has seen. Both ends
## send it repeatedly, and each stops when it can see itself reflected.
static func encode_status(did_read: bool, did_write: bool,
						  did_handshake: bool) -> String:
	var r := "r" if did_read else "-"
	var w := "w" if did_write else "-"
	var x := "x" if did_handshake else "-"
	return "$" + r + w + x


static func decode_status(packet: String) -> Dictionary:
	return {
		"did_read": packet.contains("r"),
		"did_write": packet.contains("w"),
		"did_handshake": packet.contains("x"),
	}


# ---------------------------------------------------------------------------
# The host side of a punch
# ---------------------------------------------------------------------------

## Answer a joiner that noray has just told us about.
##
## The host cannot do what the joiner does. Its punched port is already held by
## the ENet server, so a second socket cannot bind it, and the packets have to
## leave through ENet itself. Nothing can be received this way, which is why
## this only blasts: the joiner is the side that decides the punch worked.
func blast_over_enet(peer: ENetMultiplayerPeer, address: String, port: int,
					 timeout := HANDSHAKE_TIMEOUT) -> void:
	var status := encode_status(true, true, true).to_ascii_buffer()
	var left := timeout
	while left > 0.0:
		if peer.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
			return
		peer.host.socket_send(address, port, status)
		await get_tree().create_timer(HANDSHAKE_INTERVAL).timeout
		left -= HANDSHAKE_INTERVAL


# ---------------------------------------------------------------------------
# Internals
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	_tcp.poll()
	var available := _tcp.get_available_bytes()
	if available <= 0:
		return

	var parsed := ingest(_buf + _tcp.get_utf8_string(available))
	_buf = parsed["rest"]
	for cmd: Dictionary in parsed["commands"]:
		_handle(cmd["command"], cmd["data"])


func _handle(command: String, data: String) -> void:
	match command:
		"set-oid":
			_oid = data
		"set-pid":
			_pid = data
		"connect":
			var peer := parse_address(data)
			if peer.is_empty():
				push_warning("[Punchthrough] unusable connect address: %s" % data)
				return
			_pending.append(peer)
			peer_punched.emit(peer["address"], peer["port"])
		"connect-relay":
			# Never asked for, so never expected. Noted rather than acted on:
			# taking it would silently move the session onto our bandwidth.
			push_warning("[Punchthrough] ignoring an unrequested relay offer")
		_:
			pass


func _open(punch_host: String, punch_port: int) -> int:
	# IPv4 explicitly. Noray matches the source address of the UDP registration
	# against this TCP connection, and a pair that disagree about family look to
	# it like two different machines.
	var resolved := IP.resolve_hostname(punch_host, IP.TYPE_IPV4)
	if resolved.is_empty():
		return Result.UNREACHABLE

	if _tcp.connect_to_host(resolved, punch_port) != OK:
		return Result.UNREACHABLE
	_tcp.set_no_delay(true)
	_buf = ""

	var left := CONNECT_TIMEOUT
	while _tcp.get_status() == StreamPeerTCP.STATUS_CONNECTING and left > 0.0:
		_tcp.poll()
		await get_tree().process_frame
		left -= get_process_delta_time()

	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return Result.UNREACHABLE

	_address = resolved
	return Result.OK


func _put(command: String, data := "") -> void:
	if _tcp.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return
	var line := command if data.is_empty() else "%s %s" % [command, data]
	_tcp.put_data((line + "\n").to_utf8_buffer())


func _await_ids() -> bool:
	var left := CONNECT_TIMEOUT
	while left > 0.0:
		if not _oid.is_empty() and not _pid.is_empty():
			return true
		await get_tree().process_frame
		left -= get_process_delta_time()
	return false


## Teach noray the external address of this machine. The port this leaves from
## is the whole point: it is the one the far peer will be told about, so it is
## the one ENet has to use afterwards.
func _register_remote(registrar_port: int) -> bool:
	if _pid.is_empty():
		return false

	var udp := PacketPeerUDP.new()
	if udp.bind(0) != OK:
		return false
	udp.set_dest_address(_address, registrar_port)

	var packet := _pid.to_utf8_buffer()
	var left := REGISTER_TIMEOUT
	var ok := false
	while left > 0.0 and not ok:
		udp.put_packet(packet)
		while udp.get_available_packet_count() > 0:
			if udp.get_packet().get_string_from_utf8() == "OK":
				_local_port = udp.get_local_port()
				ok = true
			break
		if ok:
			break
		await get_tree().create_timer(HANDSHAKE_INTERVAL).timeout
		left -= HANDSHAKE_INTERVAL

	udp.close()
	return ok


func _await_connect() -> Dictionary:
	var left := CONNECT_TIMEOUT
	while left > 0.0:
		if not _pending.is_empty():
			return _pending.pop_front()
		await get_tree().process_frame
		left -= get_process_delta_time()
	return {}


## Trade status packets until each end has seen the other. Reading one at all is
## the proof: the return path exists only because something of ours went out
## first and opened it.
func _handshake(udp: PacketPeerUDP) -> bool:
	var did_read := false
	var did_handshake := false
	var left := HANDSHAKE_TIMEOUT

	while left > 0.0:
		while udp.get_available_packet_count() > 0:
			var theirs := decode_status(udp.get_packet().get_string_from_ascii())
			did_read = true
			if theirs["did_read"]:
				did_handshake = true
			if theirs["did_handshake"] and did_handshake:
				return true

		udp.put_packet(encode_status(did_read, true, did_handshake).to_ascii_buffer())
		await get_tree().create_timer(HANDSHAKE_INTERVAL).timeout
		left -= HANDSHAKE_INTERVAL

	# Their packets reached us even though the full three-way never closed. The
	# path is open; the far end just never got to say so. Worth connecting on.
	return did_read
