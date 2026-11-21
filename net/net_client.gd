## The client side of the network connection: joins a NetServer, sends
## messages, and hands back what the server says. It knows nothing about
## drawing; client/remote_link.gd turns its messages into snapshots.
extends Node

const Protocol = preload("res://net/protocol.gd")

signal welcomed(info: Dictionary)
## A world state arrived, with every event received since the previous one.
signal state_received(state: Dictionary, events: Array)
## Any other message from the server (players, you, notice...).
signal message_received(msg: Dictionary)
## The connection ended (or never started). `reason` is for showing to people.
signal disconnected(reason: String)

var is_welcomed := false

var _enet: ENetMultiplayerPeer
var _hello: Dictionary = {}
var _pending_events: Array = []
var _end_reason := ""
var _was_connected := false
var _closed := false


## Start connecting. `hello` = {name, role, password}; version is added here.
func connect_to(address: String, port: int, hello: Dictionary) -> int:
	_hello = hello.duplicate()
	_hello["op"] = "hello"
	_hello["version"] = Protocol.VERSION
	_enet = ENetMultiplayerPeer.new()
	var err := _enet.create_client(address, port, Protocol.CHANNELS)
	if err != OK:
		_enet = null
		return err
	_enet.peer_connected.connect(_on_peer_connected)
	_enet.peer_disconnected.connect(_on_peer_disconnected)
	return OK


func send(msg: Dictionary) -> void:
	if _closed or _enet == null or _enet.get_connection_status() != MultiplayerPeer.CONNECTION_CONNECTED:
		return
	_enet.set_target_peer(MultiplayerPeer.TARGET_PEER_SERVER)
	_enet.transfer_channel = Protocol.CH_RELIABLE
	_enet.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	_enet.put_packet(Protocol.encode(msg))


func close() -> void:
	if _enet != null:
		_enet.close()
	_finish("You left the server.")


func _exit_tree() -> void:
	if _enet != null:
		_enet.close()
		_enet = null


func _process(_delta: float) -> void:
	if _closed:
		_enet = null   # released here, never from inside its own poll()
		return
	if _enet == null:
		return
	_enet.poll()
	while not _closed and _enet.get_available_packet_count() > 0:
		var msg: Variant = Protocol.decode(_enet.get_packet())
		if msg != null:
			_on_message(msg)
	if not _closed and _enet.get_connection_status() == MultiplayerPeer.CONNECTION_DISCONNECTED:
		_finish(_end_reason if _end_reason != "" else
			("Lost the connection to the server." if _was_connected else "Couldn't reach the server."))


func _on_peer_connected(id: int) -> void:
	if id == MultiplayerPeer.TARGET_PEER_SERVER:
		_was_connected = true
		send(_hello)


func _on_peer_disconnected(id: int) -> void:
	if id == MultiplayerPeer.TARGET_PEER_SERVER:
		_finish(_end_reason if _end_reason != "" else "Lost the connection to the server.")


func _on_message(msg: Dictionary) -> void:
	match str(msg["op"]):
		"welcome":
			is_welcomed = true
			welcomed.emit(msg)
		"events":
			var evs: Variant = msg.get("events", [])
			if evs is Array:
				_pending_events.append_array(evs)
		"state":
			var evs := _pending_events
			_pending_events = []
			state_received.emit(msg, evs)
		"denied", "kicked":
			_end_reason = str(msg.get("reason", "Disconnected by the server."))
			message_received.emit(msg)
		_:
			message_received.emit(msg)


func _finish(reason: String) -> void:
	if _closed:
		return
	_closed = true
	is_welcomed = false
	disconnected.emit(reason)
