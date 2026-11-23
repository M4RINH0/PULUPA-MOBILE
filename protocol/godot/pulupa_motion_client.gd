class_name PulupaMotionClient
extends Node

signal snapshot_received(players: Array)
signal connection_closed(code: int)

const REQUEST := '{"v":1,"type":"snapshot"}'
const REQUEST_INTERVAL_US := 16667
const REQUEST_TIMEOUT_US := 2000000

var _socket := WebSocketPeer.new()
var _running := false
var _sent_at_us := -1
var _next_request_us := 0
var _players: Array = []


func connect_local(port: int = 8765) -> Error:
	if _running:
		return ERR_ALREADY_IN_USE
	_socket = WebSocketPeer.new()
	_socket.max_queued_packets = 8
	_socket.inbound_buffer_size = 8192
	var result := _socket.connect_to_url("ws://127.0.0.1:%d/ws/game" % port)
	_running = result == OK
	_sent_at_us = -1
	_next_request_us = 0
	return result


func _process(_delta: float) -> void:
	if not _running:
		return
	_socket.poll()
	var state := _socket.get_ready_state()
	if state == WebSocketPeer.STATE_CLOSED:
		_running = false
		_players = []
		connection_closed.emit(_socket.get_close_code())
		return
	if state != WebSocketPeer.STATE_OPEN:
		return
	while _socket.get_available_packet_count() > 0:
		var packet := _socket.get_packet()
		if not _socket.was_string_packet():
			continue
		var decoded: Variant = JSON.parse_string(packet.get_string_from_utf8())
		if decoded is Dictionary and decoded.get("v") == 1 and decoded.get("type") == "snapshot":
			var players: Variant = decoded.get("players")
			if players is Array:
				_sent_at_us = -1
				_players = players
				snapshot_received.emit(_players)
	var now := Time.get_ticks_usec()
	if _sent_at_us >= 0:
		if now - _sent_at_us > REQUEST_TIMEOUT_US:
			_socket.close(1001, "Snapshot timeout")
		return
	if now >= _next_request_us and _socket.send_text(REQUEST) == OK:
		_sent_at_us = now
		_next_request_us = now + REQUEST_INTERVAL_US


func orientation_for(player_id: int) -> Variant:
	for entry in _players:
		if entry.get("player") != player_id or not entry.get("connected", false) or not entry.get("calibrated", false):
			continue
		var motion: Variant = entry.get("motion")
		if not (motion is Dictionary) or not motion.get("calibrated", false) or not motion.get("valid", false):
			return null
		var q: Array = motion["q"]
		return Quaternion(q[0], q[1], q[2], q[3]).normalized()
	return null


func _exit_tree() -> void:
	if _socket.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_socket.close()
