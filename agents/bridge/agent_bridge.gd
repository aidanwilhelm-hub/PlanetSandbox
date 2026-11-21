## Lets programs outside Godot drive NPCs: a tiny JSON-lines protocol over TCP.
##
## Start the game with `-- --agent-port=7777` and any language can connect to
## 127.0.0.1:7777 and send one JSON object per line:
##
##   -> {"op": "join", "name": "bob", "kind": "explorer"}       spawn a body on random land
##      (optional: "lat"/"lon" to choose where, "entity_id" to take over an
##       existing entity instead, "think_every" ticks, "sight_range" meters)
##   <- {"op": "joined", "entity_id": 42, "controller": "agent:bob:3"}
##   <- {"op": "observe", "obs": {...}}            your turn: see agents/observation.gd
##   -> {"op": "act", "actions": [{"action": "move", "bearing": 90, "distance": 20}]}
##   <- {"op": "observe", "obs": {...}}            the next one comes only after you act
##   <- {"op": "left", "reason": "..."}            body gone
##   <- {"op": "error", "message": "..."}
##
## Reply to every observation with "act" (an empty list is fine). Take as long
## as you like: the world keeps running and your NPC keeps doing whatever it
## was last told. Close the socket and your NPC is removed.
##
## See examples/agents/ for Python clients, including one driven by Claude.
##
## Only listens on 127.0.0.1 (this computer). Step 3 (multiplayer) carries the
## same messages over the real network.
extends Node

const RemoteAgent = preload("res://agents/bridge/remote_agent.gd")

const MAX_LINE_BYTES := 65536
const MAX_CLIENTS := 32

var runtime: RefCounted
var port := 0

var _server := TCPServer.new()
var _clients: Array = []      ## [{peer, buffer, agent}]
var _rng := RandomNumberGenerator.new()   ## for spawn spots; never the sim's rng


func _init(p_runtime: RefCounted) -> void:
	runtime = p_runtime
	runtime.agent_attached.connect(_on_attached)
	runtime.agent_detached.connect(_on_detached)
	_rng.randomize()


## Returns OK or an Error code.
func listen(p_port: int) -> int:
	port = p_port
	return _server.listen(port, "127.0.0.1")


func _exit_tree() -> void:
	for c in _clients:
		_drop(c, "server shutting down")
	_server.stop()


func _process(_delta: float) -> void:
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if _clients.size() >= MAX_CLIENTS:
			peer.disconnect_from_host()
			continue
		_clients.append({"peer": peer, "buffer": PackedByteArray(), "agent": null})
	for c in _clients.duplicate():
		var peer: StreamPeerTCP = c["peer"]
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			_drop(c, "disconnected")
			continue
		var n := peer.get_available_bytes()
		if n > 0:
			var got: Array = peer.get_partial_data(n)
			if got[0] == OK:
				c["buffer"].append_array(got[1])
		_read_lines(c)


func _read_lines(c: Dictionary) -> void:
	var buf: PackedByteArray = c["buffer"]
	while true:
		var nl := buf.find(10)
		if nl == -1:
			if buf.size() > MAX_LINE_BYTES:
				_send(c, {"op": "error", "message": "line too long"})
				buf.clear()
			break
		var line := buf.slice(0, nl).get_string_from_utf8().strip_edges()
		buf = buf.slice(nl + 1)
		if line != "":
			_handle(c, line)
	c["buffer"] = buf


func _handle(c: Dictionary, line: String) -> void:
	var json := JSON.new()   # (not JSON.parse_string: that prints an engine error on bad input)
	var msg: Variant = json.data if json.parse(line) == OK else null
	if not msg is Dictionary:
		_send(c, {"op": "error", "message": "expected one JSON object per line"})
		return
	match str(msg.get("op", "")):
		"join":
			_join(c, msg)
		"act":
			var agent = c["agent"]
			if agent == null:
				_send(c, {"op": "error", "message": "join first"})
				return
			var actions: Variant = msg.get("actions", [])
			agent.act(actions if actions is Array or actions is Dictionary else [])
		_:
			_send(c, {"op": "error", "message": "unknown op (use 'join' or 'act')"})


func _join(c: Dictionary, msg: Dictionary) -> void:
	if c["agent"] != null:
		_send(c, {"op": "error", "message": "already joined"})
		return
	var agent := RemoteAgent.new()
	agent.peer = c["peer"]
	agent.agent_name = str(msg.get("name", "remote")).left(32)
	agent.think_every = clampi(int(msg.get("think_every", 20)), 1, 20 * 60)
	agent.sight_range = clampf(float(msg.get("sight_range", 30.0)), 1.0, 200.0)
	agent.busy = false
	c["agent"] = agent
	if msg.has("entity_id"):
		# Only unowned things (or ones run by a built-in brain) can be taken over,
		# never a player's or another agent's.
		var e = runtime.sim.get_entity(int(msg["entity_id"]))
		var free: bool = e != null and (e.controller == "" or str(e.controller).begins_with("brain:"))
		if not free or not runtime.attach(agent, int(msg["entity_id"])):
			c["agent"] = null
			_send(c, {"op": "error", "message": "can't take over that entity"})
		return
	var where: Variant = null
	if msg.has("lat") and msg.has("lon"):
		where = {"lat": float(msg["lat"]), "lon": float(msg["lon"])}
	else:
		where = runtime.sim.planet.random_land_dir(_rng)
	runtime.spawn_agent(agent, str(msg.get("kind", "explorer")), where)


func _client_of(agent: RefCounted) -> Variant:
	for c in _clients:
		if c["agent"] == agent:
			return c
	return null


func _on_attached(agent: RefCounted, entity_id: int) -> void:
	var c: Variant = _client_of(agent)
	if c != null:
		_send(c, {"op": "joined", "entity_id": entity_id, "controller": agent.controller})


## The body is gone (or never appeared). The client may "join" again.
func _on_detached(agent: RefCounted, _entity_id: int, _reason: String) -> void:
	var c: Variant = _client_of(agent)
	if c != null:
		c["agent"] = null


func _drop(c: Dictionary, reason: String) -> void:
	_clients.erase(c)
	if c["agent"] != null:
		runtime.detach(c["agent"], true, reason)
	(c["peer"] as StreamPeerTCP).disconnect_from_host()


func _send(c: Dictionary, msg: Dictionary) -> void:
	var peer: StreamPeerTCP = c["peer"]
	if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(msg) + "\n").to_utf8_buffer())
