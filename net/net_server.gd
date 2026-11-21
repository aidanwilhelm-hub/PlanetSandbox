## Lets other computers join the world over the network (ENet / UDP).
##
## Sits next to the SimServer. It never simulates anything itself:
##   * commands from players are checked, stamped with that player's own
##     issuer (so nobody can pretend to be the host), and handed to
##     SimServer.submit_command(), the same door everything else uses;
##   * every snapshot the SimServer publishes is sent out, 10 times a second,
##     with speech filtered by distance (proximity chat).
##
## Roles: "player" (gets an explorer; Survival = walk and talk with it,
## Creative = may also spawn and remove things) and "spectator" (watches,
## sends nothing). The host can make players moderators, who may pause,
## change speed, and kick. Every join needs the server password, if one is set.
##
## The wire format is described in net/protocol.gd.
extends Node

const Protocol = preload("res://net/protocol.gd")
const AuthGuard = preload("res://net/auth_guard.gd")
const Commands = preload("res://sim/commands.gd")
const CuriousAgent = preload("res://agents/examples/curious_agent.gd")

signal players_changed
signal log_message(text: String)

const MAX_PEERS := 32
const STATE_EVERY_TICKS := 2          ## 20 ticks/s -> 10 states/s
const HELLO_TIMEOUT := 5.0            ## seconds to send "hello" before being dropped
const COMMANDS_PER_SECOND := 20.0
const PLAYER_LIST_EVERY := 2.0        ## seconds; refreshes everyone's ping
const MAX_AGENTS_PER_PLAYER := 10

var server: Node                      ## the SimServer
var guard: AuthGuard
var mode := Protocol.MODE_CREATIVE
var chat_range := Protocol.DEFAULT_CHAT_RANGE
## Lower-case names that become moderators as soon as they join.
var mod_names: Array = []
var port := 0
var peers: Dictionary = {}            ## peer id -> info Dictionary (see _on_connected)

var _enet: ENetMultiplayerPeer
var _last_state_tick := -1000
var _last_server_state: Dictionary = {}
var _last_state: Dictionary = {}
var _list_timer := 0.0
var _orphans: Dictionary = {}         ## issuer -> true: body spawning for someone who already left
var _agent_count := 0
var _rng := RandomNumberGenerator.new()   ## spawn spots; never the sim's rng


func _init(p_server: Node, p_guard: AuthGuard = null) -> void:
	server = p_server
	guard = p_guard if p_guard != null else AuthGuard.new()
	_rng.randomize()


## Start accepting players. Returns OK or an Error code.
func listen(p_port: int = Protocol.DEFAULT_PORT, bind_address: String = "*") -> int:
	port = p_port
	_enet = ENetMultiplayerPeer.new()
	_enet.set_bind_ip(bind_address)
	var err := _enet.create_server(port, MAX_PEERS, Protocol.CHANNELS)
	if err != OK:
		_enet = null
		return err
	_enet.peer_connected.connect(_on_connected)
	_enet.peer_disconnected.connect(_on_disconnected)
	server.snapshot_published.connect(_on_snapshot)
	return OK


func stop() -> void:
	if _enet == null:
		return
	for id: int in peers.keys():
		_send(id, {"op": "kicked", "reason": "The server is shutting down."})
	_enet.poll()
	_enet.peer_disconnected.disconnect(_on_disconnected)
	_enet.close()
	peers.clear()
	_enet = null
	if server.snapshot_published.is_connected(_on_snapshot):
		server.snapshot_published.disconnect(_on_snapshot)


func _exit_tree() -> void:
	stop()


## Connected, signed-in peers, for the host's player list.
func player_list() -> Array:
	var list: Array = []
	for p: Dictionary in peers.values():
		if p["role"] == "pending":
			continue
		var ping := 0
		var pp := _enet.get_peer(p["id"]) if _enet != null else null
		if pp != null:
			ping = int(pp.get_statistic(ENetPacketPeer.PEER_ROUND_TRIP_TIME))
		list.append({"peer_id": p["id"], "name": p["name"], "role": p["role"],
			"mod": p["mod"], "entity_id": p["entity_id"], "ping": ping})
	return list


## Make a player a moderator (or not). Host only: there is no network message for it.
func set_mod(peer_id: int, on: bool) -> void:
	var p: Variant = peers.get(peer_id)
	if p == null or p["role"] == "pending" or p["mod"] == on:
		return
	p["mod"] = on
	_send_you(p)
	_send(peer_id, {"op": "notice", "text": "You are now a moderator." if on else "You are no longer a moderator."})
	log_message.emit("%s is %s a moderator" % [p["name"], "now" if on else "no longer"])
	_players_updated()


func kick(peer_id: int, reason: String = "Kicked by the host.") -> void:
	var p: Variant = peers.get(peer_id)
	if p == null or _enet == null:
		return
	_send(peer_id, {"op": "kicked", "reason": reason})
	log_message.emit("%s was kicked (%s)" % [p["name"], reason])
	_disconnect_later(peer_id)


func _process(delta: float) -> void:
	if _enet == null:
		return
	_enet.poll()
	while _enet != null and _enet.get_available_packet_count() > 0:
		var from := _enet.get_packet_peer()
		var bytes := _enet.get_packet()
		_handle(from, bytes)
	if _enet == null:
		return
	for p: Dictionary in peers.values():
		p["tokens"] = minf(COMMANDS_PER_SECOND, float(p["tokens"]) + delta * COMMANDS_PER_SECOND)
		if p["role"] == "pending":
			p["age"] = float(p["age"]) + delta
			if p["age"] > HELLO_TIMEOUT:
				p["age"] = -1e9   # only once
				_disconnect_later(p["id"])
	_list_timer += delta
	if _list_timer >= PLAYER_LIST_EVERY:
		_list_timer = 0.0
		_broadcast_players()


# --- connections ------------------------------------------------------------

func _on_connected(id: int) -> void:
	var address := ""
	var pp := _enet.get_peer(id)
	if pp != null:
		address = pp.get_remote_address()
	peers[id] = {
		"id": id, "address": address, "role": "pending", "name": "", "issuer": "",
		"mod": false, "entity_id": -1, "spawning": false, "agents": 0,
		"tokens": COMMANDS_PER_SECOND, "age": 0.0, "events": [],
	}


func _on_disconnected(id: int) -> void:
	var p: Variant = peers.get(id)
	peers.erase(id)
	if p == null or p["role"] == "pending":
		return
	if p["role"] == "player":
		if p["entity_id"] != -1 and server.sim.get_entity(p["entity_id"]) != null:
			server.submit_command(Commands.despawn(Commands.ADMIN, p["entity_id"]))
		elif p["spawning"]:
			_orphans[p["issuer"]] = true
	log_message.emit("%s left" % p["name"])
	_players_updated()


func _disconnect_later(id: int) -> void:
	var pp := _enet.get_peer(id)
	if pp != null:
		pp.peer_disconnect_later()


func _hello(p: Dictionary, msg: Dictionary) -> void:
	var verdict := guard.check(p["address"], str(msg.get("password", "")))
	if verdict == "blocked":
		_deny(p, "Too many wrong passwords. Try again in %d minutes." % guard.minutes_left(p["address"]))
		return
	if verdict == "wrong":
		log_message.emit("Wrong password from %s" % p["address"])
		if guard.is_blocked(p["address"]):
			log_message.emit("%s is blocked for %d minutes after too many wrong passwords" % [
				p["address"], guard.minutes_left(p["address"])])
		_deny(p, "Wrong password.")
		return
	if int(msg.get("version", 0)) != Protocol.VERSION:
		_deny(p, "Version mismatch (server %d, you %s). Update your copy of the game." % [
			Protocol.VERSION, str(msg.get("version", "?"))])
		return
	p["name"] = Protocol.clean_name(msg.get("name", "player"))
	p["role"] = "spectator" if str(msg.get("role", "")) == "spectator" else "player"
	p["issuer"] = "%s:%s:%d" % [p["role"], p["name"], p["id"]]
	p["mod"] = mod_names.has(p["name"].to_lower())
	_send(p["id"], {
		"op": "welcome", "peer_id": p["id"], "issuer": p["issuer"], "role": p["role"],
		"mod": p["mod"], "mode": mode, "chat_range": chat_range,
		"planet": server.sim.planet.to_dict(), "entity_id": -1,
	})
	if not _last_state.is_empty():
		_send(p["id"], _last_state, true)
	if p["role"] == "player":
		_spawn_body(p)
	log_message.emit("%s joined as %s%s" % [p["name"], p["role"], " (moderator)" if p["mod"] else ""])
	_players_updated()


func _deny(p: Dictionary, reason: String) -> void:
	_send(p["id"], {"op": "denied", "reason": reason})
	p["age"] = -1e9
	_disconnect_later(p["id"])


func _spawn_body(p: Dictionary) -> void:
	var where: Vector3 = server.sim.planet.random_land_dir(_rng)
	p["spawning"] = true
	server.submit_command(Commands.spawn(Commands.ADMIN, "explorer", where, p["issuer"]))


# --- messages from clients ----------------------------------------------------

func _handle(id: int, bytes: PackedByteArray) -> void:
	var p: Variant = peers.get(id)
	if p == null:
		return
	var msg: Variant = Protocol.decode(bytes)
	if msg == null:
		return
	var op := str(msg.get("op", ""))
	if p["role"] == "pending":
		if op == "hello":
			_hello(p, msg)
		return
	match op:
		"cmd":
			_command(p, msg.get("command"))
		"agent":
			_request_agent(p, msg)
		"time":
			_time_control(p, msg)
		"kick":
			_mod_kick(p, int(msg.get("peer_id", -1)))
		"respawn":
			if p["role"] == "player" and p["entity_id"] == -1 and not p["spawning"]:
				_spawn_body(p)


func _command(p: Dictionary, cmd: Variant) -> void:
	if not cmd is Dictionary or p["role"] != "player":
		return   # spectators only watch
	if not _take_token(p):
		return
	var c: Dictionary = (cmd as Dictionary).duplicate(true)
	c["issuer"] = p["issuer"]   # whatever the client claimed, this is who they are
	var type := str(c.get("type", ""))
	match type:
		Commands.MOVE_TO, Commands.STOP, Commands.SAY:
			pass   # the simulation itself checks the entity is theirs
		Commands.SPAWN:
			if not _may_edit(p):
				_notice(p, "Spawning is only allowed in Creative mode.")
				return
			c["controller"] = ""   # nobody spawns bodies for someone else
			c["by"] = p["issuer"]
			c["issuer"] = Commands.ADMIN
		Commands.DESPAWN:
			if not _may_edit(p):
				_notice(p, "Removing things is only allowed in Creative mode.")
				return
			var e = server.sim.get_entity(int(c.get("entity_id", -1)))
			if e != null and str(e.controller).begins_with("player:"):
				_notice(p, "You can't remove a player's explorer.")
				return
			c["by"] = p["issuer"]
			c["issuer"] = Commands.ADMIN
		_:
			_notice(p, "Players can't use '%s'." % type)
			return
	server.submit_command(c)


func _request_agent(p: Dictionary, msg: Dictionary) -> void:
	if p["role"] != "player" or not _take_token(p):
		return
	if not _may_edit(p):
		_notice(p, "AI explorers can only be added in Creative mode.")
		return
	if int(p["agents"]) >= MAX_AGENTS_PER_PLAYER:
		_notice(p, "You've added the most AI explorers allowed (%d)." % MAX_AGENTS_PER_PLAYER)
		return
	var target: Variant = Commands.parse_target(msg.get("target"))
	if target == null:
		return
	p["agents"] = int(p["agents"]) + 1
	_agent_count += 1
	server.agents.spawn_agent(CuriousAgent.new(1000 + _agent_count), "explorer", target)


func _time_control(p: Dictionary, msg: Dictionary) -> void:
	if not p["mod"]:
		_notice(p, "Only the host and moderators can pause or change speed.")
		return
	if msg.has("paused"):
		server.set_paused(bool(msg["paused"]))
	if msg.has("speed"):
		server.set_speed(float(msg["speed"]))
	if msg.get("step", false) and server.paused:
		server.step_once()


func _mod_kick(p: Dictionary, target_id: int) -> void:
	var t: Variant = peers.get(target_id)
	if not p["mod"] or t == null or t["mod"] or target_id == p["id"]:
		_notice(p, "You can't kick that player.")
		return
	kick(target_id, "Kicked by %s." % p["name"])


func _may_edit(p: Dictionary) -> bool:
	return p["role"] == "player" and mode == Protocol.MODE_CREATIVE


func _take_token(p: Dictionary) -> bool:
	if float(p["tokens"]) < 1.0:
		return false
	p["tokens"] = float(p["tokens"]) - 1.0
	return true


# --- sending the world out ------------------------------------------------------

func _on_snapshot(snap: Dictionary) -> void:
	_track_bodies(snap["events"])
	for p: Dictionary in peers.values():
		if p["role"] != "pending":
			(p["events"] as Array).append_array(_events_for(p, snap["events"]))
	var srv: Dictionary = snap.get("server", {})
	if snap["tick"] - _last_state_tick < STATE_EVERY_TICKS and srv == _last_server_state:
		return
	_last_state_tick = snap["tick"]
	_last_server_state = srv.duplicate()
	_last_state = {"op": "state", "tick": snap["tick"], "time": snap["time"],
		"server": srv, "entities": snap["entities"]}
	var state_bytes := Protocol.encode(_last_state)
	for p: Dictionary in peers.values():
		if p["role"] == "pending":
			continue
		if not (p["events"] as Array).is_empty():
			_send(p["id"], {"op": "events", "events": p["events"]})
			p["events"] = []
		_put(p["id"], state_bytes, true)


## Notice when players' explorers appear or disappear.
func _track_bodies(events: Array) -> void:
	for ev: Dictionary in events:
		if ev["type"] == "entity_spawned":
			var ctrl := str(ev.get("controller", ""))
			if _orphans.has(ctrl):
				_orphans.erase(ctrl)
				server.submit_command(Commands.despawn(Commands.ADMIN, ev["entity_id"]))
				continue
			for p: Dictionary in peers.values():
				if p["issuer"] == ctrl and p["spawning"]:
					p["spawning"] = false
					p["entity_id"] = ev["entity_id"]
					_send_you(p)
					_players_updated()
		elif ev["type"] == "entity_despawned":
			for p: Dictionary in peers.values():
				if p["entity_id"] == ev["entity_id"]:
					p["entity_id"] = -1
					_send_you(p)
					_notice(p, "Your explorer is gone. Press R to get a new one.")
					_players_updated()
		elif ev["type"] == "command_rejected":
			var cmd: Dictionary = ev.get("command", {})
			if cmd.get("type") == Commands.SPAWN:
				for p: Dictionary in peers.values():
					if p["spawning"] and p["issuer"] == str(cmd.get("controller", "")):
						p["spawning"] = false   # try again with R


## What one peer gets to know about: speech only within chat range (proximity
## chat), refusals only for their own commands, everything else as is.
func _events_for(p: Dictionary, events: Array) -> Array:
	var out: Array = []
	for ev: Dictionary in events:
		match ev["type"]:
			"command_rejected":
				var cmd: Dictionary = ev.get("command", {})
				if str(cmd.get("issuer", "")) == p["issuer"] or str(cmd.get("by", "")) == p["issuer"]:
					out.append(ev)
			"entity_said":
				var d := _hearing_distance(p, int(ev["entity_id"]))
				if d >= 0.0:
					var heard := ev.duplicate()
					heard["distance"] = d
					out.append(heard)
			_:
				out.append(ev)
	return out


## Meters between this peer's explorer and the speaker, or -1 if out of earshot.
## Spectators hear everything (distance 0).
func _hearing_distance(p: Dictionary, speaker_id: int) -> float:
	if p["role"] == "spectator":
		return 0.0
	if speaker_id == p["entity_id"]:
		return 0.0
	var me = server.sim.get_entity(p["entity_id"])
	var them = server.sim.get_entity(speaker_id)
	if me == null or them == null:
		return -1.0
	var d: float = me.dir.angle_to(them.dir) * server.sim.planet.radius
	return d if d <= chat_range else -1.0


func _send_you(p: Dictionary) -> void:
	_send(p["id"], {"op": "you", "entity_id": p["entity_id"], "mod": p["mod"]})


func _notice(p: Dictionary, text: String) -> void:
	_send(p["id"], {"op": "notice", "text": text})


func _players_updated() -> void:
	players_changed.emit()
	_broadcast_players()


func _broadcast_players() -> void:
	if _enet == null:
		return
	var list := player_list()
	for p: Dictionary in peers.values():
		if p["role"] != "pending":
			_send(p["id"], {"op": "players", "list": list})


## `state_channel`: world states go on their own channel, so a big state never
## holds up a chat line or a notice.
func _send(id: int, msg: Dictionary, state_channel: bool = false) -> void:
	_put(id, Protocol.encode(msg), state_channel)


## Everything is sent reliably: a world state is ~6 KB, bigger than one UDP
## packet, and an unreliable message that size is lost whenever any one of
## its pieces is. On a home network this is plenty fast.
func _put(id: int, bytes: PackedByteArray, state_channel: bool) -> void:
	if _enet == null:
		return
	var pp := _enet.get_peer(id)
	if pp == null or pp.get_state() != ENetPacketPeer.STATE_CONNECTED:
		return
	_enet.set_target_peer(id)
	_enet.transfer_channel = Protocol.CH_STATE if state_channel else Protocol.CH_RELIABLE
	_enet.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE
	_enet.put_packet(bytes)
