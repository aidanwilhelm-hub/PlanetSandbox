## Program entry point.
##
## Normal run: starts the simulation server AND the 3D view in one window.
## Server-only run (no window): add `-- --server` to the command line.
## Optional: `-- --seed=42` picks a different planet.
## Optional: `-- --agent-port=7777` lets outside programs drive NPCs (see agents/bridge/).
## Optional: `-- --agents=3` starts the world with that many example AI explorers.
extends Node

const SimServer = preload("res://server/sim_server.gd")
const AgentBridge = preload("res://agents/bridge/agent_bridge.gd")
const CuriousAgent = preload("res://agents/examples/curious_agent.gd")
const WorldView = preload("res://client/world_view.gd")

var server: SimServer


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var config := {}
	var agent_port := 0
	var demo_agents := 0
	for a in args:
		if a.begins_with("--seed="):
			config["seed"] = int(a.trim_prefix("--seed="))
		elif a.begins_with("--agent-port="):
			agent_port = int(a.trim_prefix("--agent-port="))
		elif a.begins_with("--agents="):
			demo_agents = clampi(int(a.trim_prefix("--agents=")), 0, 100)

	server = SimServer.new()
	server.name = "SimServer"
	add_child(server)
	server.start(config)

	var rng := RandomNumberGenerator.new()
	rng.seed = server.sim.planet.world_seed
	for i in demo_agents:
		server.agents.spawn_agent(CuriousAgent.new(i + 1), "explorer", server.sim.planet.random_land_dir(rng))
	if agent_port > 0:
		var bridge := AgentBridge.new(server.agents)
		bridge.name = "AgentBridge"
		server.add_child(bridge)
		if bridge.listen(agent_port) == OK:
			print("Agent bridge listening on 127.0.0.1:%d" % agent_port)
		else:
			push_error("Agent bridge could not listen on port %d" % agent_port)

	if "--server" in args:
		_run_headless()
	else:
		var view := WorldView.new()
		view.name = "WorldView"
		add_child(view)
		view.setup(server)


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
	print("Day %d %02d:%02d | tick %d | %d entities (%d moving)" % [
		snap["time"]["day"], int(hour), int(fmod(hour, 1.0) * 60.0),
		snap["tick"], snap["entities"].size(), moving])
