## Program entry point.
##
## With no options, a start menu appears. Or pick from the command line
## (everything after `--`):
##
##   (nothing)                start menu
##   --single                 play alone (also implied by --seed / --agents / --agent-port)
##   --host                   play, and let others on your network join
##   --server                 dedicated server: no window, others join it
##   --join=ADDRESS[:PORT]    join someone else's game
##   --watch                  watch AI agents run a world on their own (sim mode);
##                            with --join, join as a spectator instead
##   --sim                    keep the world stocked with AI explorers (for --host/--server)
##
## Options:
##   --name=NAME              your name when joining
##   --port=7000              network port for --host/--server/--join
##   --password=SECRET        server password (needed by every player, spectator and AI agent)
##   --mode=creative|survival what joining players may do (default creative)
##   --mods=alice,bob         these names become moderators when they join
##   --seed=42                a different planet
##   --agents=3               start with that many example AI explorers (sim mode default 8)
##   --agent-port=7777        let outside programs drive NPCs (see agents/bridge/)
extends Node

const Protocol = preload("res://net/protocol.gd")
const SimServer = preload("res://server/sim_server.gd")
const PopulationKeeper = preload("res://server/population_keeper.gd")
const NetServer = preload("res://net/net_server.gd")
const AuthGuard = preload("res://net/auth_guard.gd")
const AgentBridge = preload("res://agents/bridge/agent_bridge.gd")
const CuriousAgent = preload("res://agents/examples/curious_agent.gd")
const WorldView = preload("res://client/world_view.gd")
const LocalLink = preload("res://client/local_link.gd")
const RemoteLink = preload("res://client/remote_link.gd")
const MainMenu = preload("res://client/main_menu.gd")

const SIM_MODE_AGENTS := 8

var server: SimServer
var net: NetServer
var link: Node
var view: Node3D
var menu: MainMenu


func _ready() -> void:
	var opts := _parse_args(OS.get_cmdline_user_args())
	if opts["launch"] == "menu":
		_show_menu("")
	else:
		_launch(opts)


func _parse_args(args: PackedStringArray) -> Dictionary:
	var o := {"launch": "", "port": Protocol.DEFAULT_PORT, "password": "", "name": "player",
		"server_mode": Protocol.MODE_CREATIVE, "mods": [], "agents": -1, "agent_port": 0,
		"sim": false, "spectator": false, "config": {}}
	var watch := false
	for a in args:
		var value := a.get_slice("=", 1) if "=" in a else ""
		if a == "--single":
			o["launch"] = "single"
		elif a == "--host":
			o["launch"] = "host"
		elif a == "--server":
			o["launch"] = "server"
		elif a.begins_with("--join="):
			o["launch"] = "join"
			o["address"] = value
		elif a == "--watch":
			watch = true
		elif a == "--sim":
			o["sim"] = true
		elif a.begins_with("--name="):
			o["name"] = Protocol.clean_name(value)
		elif a.begins_with("--port="):
			o["port"] = int(value)
		elif a.begins_with("--password="):
			o["password"] = value
		elif a.begins_with("--mode="):
			o["server_mode"] = Protocol.MODE_SURVIVAL if value.to_lower() == "survival" else Protocol.MODE_CREATIVE
		elif a.begins_with("--mods="):
			for n in value.split(",", false):
				o["mods"].append(Protocol.clean_name(n).to_lower())
		elif a.begins_with("--seed="):
			o["config"]["seed"] = int(value)
		elif a.begins_with("--agent-port="):
			o["agent_port"] = int(value)
		elif a.begins_with("--agents="):
			o["agents"] = clampi(int(value), 0, 100)
	if watch:
		if o["launch"] == "join":
			o["spectator"] = true
		elif o["launch"] == "":
			o["launch"] = "watch"
	if o["launch"] == "":
		o["launch"] = "menu" if args.is_empty() else "single"
	return o


func _show_menu(status: String) -> void:
	menu = MainMenu.new()
	menu.name = "MainMenu"
	add_child(menu)
	menu.show_status(status)
	menu.chosen.connect(func(choice: Dictionary) -> void:
		menu.queue_free()
		menu = null
		var opts := _parse_args(PackedStringArray(["--single"]))   # the defaults
		opts.merge(choice, true)
		_launch(opts))


func _launch(o: Dictionary) -> void:
	if o["launch"] == "join":
		_join(o)
		return

	server = SimServer.new()
	server.name = "SimServer"
	add_child(server)
	server.start(o["config"])

	var sim_mode: bool = o["sim"] or o["launch"] == "watch"
	if sim_mode:
		var keeper := PopulationKeeper.new(server, o["agents"] if o["agents"] >= 0 else SIM_MODE_AGENTS)
		keeper.name = "PopulationKeeper"
		server.add_child(keeper)
		keeper.top_up()
	elif o["agents"] > 0:
		var rng := RandomNumberGenerator.new()
		rng.seed = server.sim.planet.world_seed
		for i in o["agents"]:
			server.agents.spawn_agent(CuriousAgent.new(i + 1), "explorer", server.sim.planet.random_land_dir(rng))

	var guard := AuthGuard.new(o["password"])
	if o["launch"] in ["host", "server"]:
		net = NetServer.new(server, guard)
		net.name = "NetServer"
		net.mode = o["server_mode"]
		net.mod_names = o["mods"]
		server.add_child(net)
		net.log_message.connect(func(text: String) -> void: print("[net] ", text))
		if net.listen(o["port"]) == OK:
			print("Multiplayer: listening on port %d (%s mode)%s" % [o["port"], net.mode,
				"" if guard.is_required() else ". No password set: anyone who can reach this computer can join"])
		else:
			push_error("Multiplayer: could not listen on port %d (is it already in use?)" % o["port"])

	if o["agent_port"] > 0:
		var bridge := AgentBridge.new(server.agents)
		bridge.name = "AgentBridge"
		bridge.guard = guard
		server.add_child(bridge)
		if bridge.listen(o["agent_port"]) == OK:
			print("Agent bridge listening on port %d (%s)" % [o["agent_port"],
				"password required, other computers allowed" if guard.is_required() else "this computer only"])
		else:
			push_error("Agent bridge could not listen on port %d" % o["agent_port"])

	if o["launch"] == "server":
		_run_headless()
		return
	link = LocalLink.new(server, net, o["launch"] == "watch")
	link.name = "Link"
	add_child(link)
	_open_view()
	if net != null and net.port != 0:
		link.notice.emit("Hosting on port %d, %s mode%s." % [net.port, net.mode.capitalize(),
			", password set" if guard.is_required() else ", no password"])


func _join(o: Dictionary) -> void:
	var address: String = str(o.get("address", "127.0.0.1"))
	var port: int = o["port"]
	if ":" in address:
		port = int(address.get_slice(":", 1))
		address = address.get_slice(":", 0)
	if address == "":
		address = "127.0.0.1"
	var remote := RemoteLink.new()
	remote.name = "Link"
	link = remote
	add_child(remote)
	_open_view()
	var hello := {"name": o["name"], "role": "spectator" if o["spectator"] else "player",
		"password": o["password"]}
	if remote.join(address, port, hello) != OK:
		_back_to_menu("Couldn't start a connection to %s:%d." % [address, port])
		return
	remote.client.disconnected.connect(func(reason: String) -> void:
		# Give people a moment to read the log, then return to the menu.
		get_tree().create_timer(2.5).timeout.connect(func() -> void: _back_to_menu(reason)))


func _open_view() -> void:
	view = WorldView.new()
	view.name = "WorldView"
	add_child(view)
	view.setup(link)


func _back_to_menu(reason: String) -> void:
	for n in [view, link, server]:
		if n != null and is_instance_valid(n):
			n.queue_free()
	view = null
	link = null
	server = null
	net = null
	if menu == null:
		_show_menu(reason)


# --- server-only mode -------------------------------------------------------

var _last_report_second := -1


func _run_headless() -> void:
	Engine.max_fps = 60
	print("Planet Sandbox server running (seed %d). Press Ctrl+C to stop." % server.sim.planet.world_seed)
	server.snapshot_published.connect(_report)


func _report(snap: Dictionary) -> void:
	for ev: Dictionary in snap["events"]:
		if ev["type"] in ["entity_spawned", "entity_despawned", "command_rejected", "entity_said"]:
			print("  event: ", ev)
	var second := int(snap["time"]["elapsed"])
	if second / 5 == _last_report_second / 5:
		return
	_last_report_second = second
	var hour: float = snap["time"]["hour_at_lon0"]
	var moving := 0
	for e: Dictionary in snap["entities"]:
		if e["state"] == "moving":
			moving += 1
	var players := ""
	if net != null:
		players = " | %d connected" % net.player_list().size()
	print("Day %d %02d:%02d | tick %d | %d entities (%d moving)%s" % [
		snap["time"]["day"], int(hour), int(fmod(hour, 1.0) * 60.0),
		snap["tick"], snap["entities"].size(), moving, players])
