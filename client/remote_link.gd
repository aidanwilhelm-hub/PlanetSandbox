## Server link for a world running on another computer.
##
## Wraps a NetClient: turns the server's messages into ordinary snapshots for
## the view, and the view's commands into network messages. The server checks
## everything; this side only avoids sending what would be refused anyway.
extends "res://client/server_link.gd"

const NetClient = preload("res://net/net_client.gd")

var client: NetClient
var connected := false

var _planet: Dictionary = {}
var _last: Dictionary = {}


func _init() -> void:
	role = "pending"
	issuer = ""
	networked = true


## hello = {name, role: "player"|"spectator", password}. Returns OK or an error.
func join(address: String, port: int, hello: Dictionary) -> int:
	client = NetClient.new()
	client.name = "NetClient"
	add_child(client)
	client.welcomed.connect(_on_welcome)
	client.state_received.connect(_on_state)
	client.message_received.connect(_on_message)
	client.disconnected.connect(_on_disconnected)
	notice.emit("Connecting to %s:%d..." % [address, port])
	return client.connect_to(address, port, hello)


func _on_welcome(info: Dictionary) -> void:
	connected = true
	role = str(info["role"])
	issuer = str(info["issuer"])
	is_mod = bool(info.get("mod", false))
	mode = str(info.get("mode", Protocol.MODE_CREATIVE))
	chat_range = float(info.get("chat_range", Protocol.DEFAULT_CHAT_RANGE))
	my_entity_id = int(info.get("entity_id", -1))
	_planet = info["planet"]
	notice.emit("Joined as %s (%s mode)." % [role_label(), mode.capitalize()])
	identity_changed.emit()


func _on_state(state: Dictionary, events: Array) -> void:
	var srv: Dictionary = state.get("server", {})
	paused = srv.get("paused", false)
	speed = srv.get("speed", 1.0)
	_last = {
		"tick": state["tick"], "time": state["time"], "planet": _planet,
		"entities": state["entities"], "server": srv, "events": events,
	}
	snapshot_published.emit(_last)


func _on_message(msg: Dictionary) -> void:
	match str(msg["op"]):
		"you":
			my_entity_id = int(msg.get("entity_id", -1))
			is_mod = bool(msg.get("mod", false))
			identity_changed.emit()
		"players":
			players = msg.get("list", [])
			players_changed.emit(players)
		"notice":
			notice.emit(str(msg.get("text", "")))
		"denied":
			notice.emit("! Couldn't join: %s" % msg.get("reason", ""))
		"kicked":
			notice.emit("! %s" % msg.get("reason", "Kicked."))


func _on_disconnected(reason: String) -> void:
	connected = false
	notice.emit("! " + reason)


func submit_command(cmd: Dictionary) -> void:
	if role == "player":
		client.send({"op": "cmd", "command": cmd})


func publish() -> void:
	if not _last.is_empty():
		var again := _last.duplicate()
		again["events"] = []
		snapshot_published.emit(again)


func set_paused(value: bool) -> void:
	if can_control_time():
		client.send({"op": "time", "paused": value})


func set_speed(value: float) -> void:
	if can_control_time():
		client.send({"op": "time", "speed": clampf(value, 0.25, 32.0)})


func step_once() -> void:
	if can_control_time():
		client.send({"op": "time", "step": true})


func request_agent(kind: String, target: Variant) -> void:
	if can_edit_world():
		client.send({"op": "agent", "kind": kind, "target": target})


func kick(peer_id: int) -> void:
	if is_mod:
		client.send({"op": "kick", "peer_id": peer_id})


func respawn() -> void:
	if role == "player" and my_entity_id == -1:
		client.send({"op": "respawn"})
