## Sim mode: keeps an AI world going on its own.
##
## Every couple of simulated seconds it tops the world back up to
## `target_agents` AI explorers (the example "curious" agent) and at least
## `min_critters` critters, so a world left running for days doesn't empty out.
## Agents that join through the agent bridge count toward the total too.
extends Node

const Commands = preload("res://sim/commands.gd")
const CuriousAgent = preload("res://agents/examples/curious_agent.gd")

const CHECK_EVERY_TICKS := 40

var server: Node        ## SimServer
var target_agents := 8
var min_critters := 15

var _last_check := -CHECK_EVERY_TICKS
var _spawned := 0
var _pending: Dictionary = {}   ## agent -> tick we asked for its body
var _rng := RandomNumberGenerator.new()


func _init(p_server: Node, p_target_agents: int = 8, p_min_critters: int = 15) -> void:
	server = p_server
	target_agents = p_target_agents
	min_critters = p_min_critters
	_rng.seed = int(server.sim.planet.world_seed) + 7
	server.snapshot_published.connect(_on_snapshot)
	server.agents.agent_attached.connect(func(a: RefCounted, _id: int) -> void: _pending.erase(a))
	server.agents.agent_detached.connect(func(a: RefCounted, _id: int, _why: String) -> void: _pending.erase(a))


func _on_snapshot(snap: Dictionary) -> void:
	if int(snap["tick"]) - _last_check < CHECK_EVERY_TICKS:
		return
	_last_check = int(snap["tick"])
	top_up()


func top_up() -> void:
	var sim = server.sim
	# Bodies we asked for that haven't appeared yet still count (for a while).
	for a in _pending.keys():
		if sim.clock.tick - int(_pending[a]) > CHECK_EVERY_TICKS:
			_pending.erase(a)
	for i in maxi(0, target_agents - server.agents.agents.size() - _pending.size()):
		var where: Vector3 = sim.planet.random_land_dir(_rng)
		if where != Vector3.ZERO:
			_spawned += 1
			var agent := CuriousAgent.new(_spawned)
			_pending[agent] = sim.clock.tick
			server.agents.spawn_agent(agent, "explorer", where)
	var critters := 0
	for e in sim.entities.values():
		if e.kind == "critter":
			critters += 1
	for i in maxi(0, min_critters - critters):
		var where: Vector3 = sim.planet.random_land_dir(_rng)
		if where != Vector3.ZERO:
			server.submit_command(Commands.spawn(Commands.ADMIN, "critter", where))
