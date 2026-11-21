## Server link for a simulation running in this same program.
##
## Used for single player, for the host's own window (then `net` is the
## NetServer and the host can manage players), and for watching a local AI
## world (`spectator` = true: nothing you press changes the world).
extends "res://client/server_link.gd"

const CuriousAgent = preload("res://agents/examples/curious_agent.gd")

var server: Node     ## SimServer
var net: Node        ## NetServer, or null

var _agent_count := 0


func _init(p_server: Node, p_net: Node = null, spectator: bool = false) -> void:
	server = p_server
	net = p_net
	is_host = net != null
	networked = is_host
	role = "spectator" if spectator else "admin"
	issuer = "spectator" if spectator else Commands.ADMIN
	if net != null:
		mode = net.mode
		chat_range = net.chat_range
		net.players_changed.connect(_on_players_changed)
		net.log_message.connect(func(text: String) -> void: notice.emit(text))
	server.snapshot_published.connect(_on_snapshot)


func _on_snapshot(snap: Dictionary) -> void:
	var srv: Dictionary = snap.get("server", {})
	paused = srv.get("paused", false)
	speed = srv.get("speed", 1.0)
	snapshot_published.emit(snap)


func _on_players_changed() -> void:
	players = net.player_list()
	players_changed.emit(players)


func submit_command(cmd: Dictionary) -> void:
	if role == "admin":
		var c := cmd.duplicate()
		c["issuer"] = Commands.ADMIN
		server.submit_command(c)


func publish() -> void:
	server.publish()


func set_paused(value: bool) -> void:
	if can_control_time():
		server.set_paused(value)


func set_speed(value: float) -> void:
	if can_control_time():
		server.set_speed(value)


func step_once() -> void:
	if can_control_time():
		server.step_once()


func request_agent(kind: String, target: Variant) -> void:
	if role != "admin":
		return
	_agent_count += 1
	server.agents.spawn_agent(CuriousAgent.new(_agent_count), kind, target)


func kick(peer_id: int) -> void:
	if net != null:
		net.kick(peer_id)


func set_mod(peer_id: int, on: bool) -> void:
	if net != null:
		net.set_mod(peer_id, on)


## Your own local world: you may always pause it or change its speed, even
## while only watching.
func can_control_time() -> bool:
	return true


func can_save() -> bool:
	return true


static func slot_path(slot: int) -> String:
	return "user://saves/slot_%d.save" % slot


func slot_info(slot: int) -> String:
	var path := slot_path(slot)
	if not FileAccess.file_exists(path):
		return ""
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var save: Variant = f.get_var(false)
	if not save is Dictionary:
		return "damaged"
	var when := str(save.get("saved_at", "")).replace("T", " ").left(16)
	return "%s   day %d   %d things" % [when, int(save.get("day", 0)), (save.get("entities", []) as Array).size()]


func save_slot(slot: int) -> String:
	var err: int = server.save_game(slot_path(slot))
	if err != OK:
		return error_string(err)
	notice.emit("Saved the world to slot %d." % slot)
	return ""


func load_slot(slot: int) -> String:
	var err: String = server.load_game(slot_path(slot))
	if err == "":
		notice.emit("Loaded slot %d." % slot)
	return err
