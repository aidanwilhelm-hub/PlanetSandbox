## Automated checks for the simulation. No window needed:
##
##   godot --headless --path . --script res://tests/run_tests.gd
##
## Exits with code 0 if everything passed, 1 otherwise.
extends SceneTree

const Simulation = preload("res://sim/simulation.gd")
const Commands = preload("res://sim/commands.gd")
const Geo = preload("res://sim/geo.gd")
const SimServer = preload("res://server/sim_server.gd")
const AgentRuntime = preload("res://agents/agent_runtime.gd")
const PatrolAgent = preload("res://agents/examples/patrol_agent.gd")
const CuriousAgent = preload("res://agents/examples/curious_agent.gd")
const AgentBridge = preload("res://agents/bridge/agent_bridge.gd")
const Protocol = preload("res://net/protocol.gd")
const Water = preload("res://sim/water.gd")
const EntityKinds = preload("res://sim/entity_kinds.gd")
const Physics = preload("res://sim/physics.gd")
const AuthGuard = preload("res://net/auth_guard.gd")
const NetServer = preload("res://net/net_server.gd")
const NetClient = preload("res://net/net_client.gd")
const PopulationKeeper = preload("res://server/population_keeper.gd")
const LocalLink = preload("res://client/local_link.gd")


## Test agent: records every observation and replays scripted answers.
class ScriptedAgent extends "res://agents/agent.gd":
	var seen: Array = []
	var answers: Array = []
	var detached_reason := ""

	func decide(obs: Dictionary) -> Variant:
		seen.append(obs)
		return answers.pop_front() if not answers.is_empty() else null

	func on_detached(reason: String) -> void:
		detached_reason = reason


## Test agent: pretends to be a slow model that never answers inside decide().
class SlowAgent extends "res://agents/agent.gd":
	var asked := 0

	func decide(_obs: Dictionary) -> Variant:
		asked += 1
		busy = true
		return null

var _failures := 0
var _checks := 0


func _initialize() -> void:
	var tests := [
		"test_terrain_is_deterministic_and_mixed",
		"test_lat_lon_round_trip",
		"test_day_cycle",
		"test_spawn_rules",
		"test_move_to_arrives_on_surface",
		"test_lat_lon_targets",
		"test_permissions",
		"test_bad_commands_are_rejected_not_crashing",
		"test_trees_cannot_move",
		"test_walkers_stop_at_water",
		"test_wander_brain_moves_critters_by_day_only",
		"test_same_inputs_same_world",
		"test_snapshot_survives_serialization",
		"test_server_steps_at_fixed_rate",
		"test_geo_bearings",
		"test_say_and_assign",
		"test_agent_spawns_and_observes",
		"test_observation_is_plain_json",
		"test_agent_actions_move_only_its_own_body",
		"test_bad_actions_become_feedback",
		"test_slow_agents_are_not_flooded",
		"test_agents_hear_each_other",
		"test_taking_over_a_critter_pauses_its_brain",
		"test_patrol_agent_patrols",
		"test_curious_agent_greets",
		"test_agents_are_deterministic",
		"test_server_runs_agents",
		"test_bridge_drives_an_npc_over_tcp",
		"test_protocol_round_trip",
		"test_auth_guard_soft_blocks",
		"test_bridge_password",
		"test_multiplayer_join_and_permissions",
		"test_multiplayer_proximity_chat",
		"test_multiplayer_creative_and_moderators",
		"test_multiplayer_wrong_password_and_block",
		"test_population_keeper",
		"test_local_link_roles",
		"test_walkers_bump_into_trees",
		"test_crowds_spread_out",
		"test_wading_in_shallow_water",
		"test_rafts_float_and_drift",
		"test_save_and_load",
		"test_server_save_file",
	]
	for t: String in tests:
		var before := _failures
		call(t)
		print("%s %s" % ["PASS" if _failures == before else "FAIL", t])
	print("\n%d checks, %d failed" % [_checks, _failures])
	quit(1 if _failures > 0 else 0)


func check(cond: bool, msg: String) -> void:
	_checks += 1
	if not cond:
		_failures += 1
		push_error("  check failed: " + msg)
		print("  check failed: " + msg)


func _land_dir(sim: Simulation) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	return sim.planet.random_land_dir(rng)


## Find a land spot with a land spot `deg` degrees away along a straight walk.
func _land_walk(sim: Simulation, deg: float) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 2000:
		var a := sim.planet.random_land_dir(rng)
		var b := Geo.random_dir_near(rng, a, deg_to_rad(deg))
		if a.angle_to(b) < deg_to_rad(deg) * 0.5:
			continue
		var all_land := true
		for s in 21:
			if not sim.planet.is_land(a.slerp(b, s / 20.0)):
				all_land = false
				break
		if all_land:
			return [a, b]
	return []


func _run(sim: Simulation, ticks: int) -> Array:
	var all_events: Array = []
	for i in ticks:
		sim.step()
		all_events.append_array(sim.events)
	return all_events


func _events_of(events: Array, type: String) -> Array:
	return events.filter(func(e: Dictionary) -> bool: return e["type"] == type)


# --- tests ---------------------------------------------------------------------

func test_terrain_is_deterministic_and_mixed() -> void:
	var a := Simulation.new({"seed": 5})
	var b := Simulation.new({"seed": 5})
	var c := Simulation.new({"seed": 6})
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var land := 0
	var differs := false
	for i in 2000:
		var d := Geo.random_dir(rng)
		check(a.planet.height_at(d) == b.planet.height_at(d), "same seed, same height")
		if a.planet.height_at(d) != c.planet.height_at(d):
			differs = true
		if a.planet.is_land(d):
			land += 1
	check(differs, "different seeds give different planets")
	var frac := land / 2000.0
	print("  land fraction: %.2f" % frac)
	check(frac > 0.25 and frac < 0.75, "planet has both land and ocean (land=%.2f)" % frac)


func test_lat_lon_round_trip() -> void:
	for lat in [-60.0, 0.0, 33.0, 80.0]:
		for lon in [-170.0, -45.0, 0.0, 90.0, 179.0]:
			var ll := Geo.lat_lon_from_dir(Geo.dir_from_lat_lon(lat, lon))
			check(absf(ll.x - lat) < 1e-3 and absf(ll.y - lon) < 1e-3, "lat/lon round trip %s,%s" % [lat, lon])


func test_day_cycle() -> void:
	var sim := Simulation.new({"day_length": 60.0, "tick_rate": 10, "start_hour": 0.0})
	check(sim.clock.day_number() == 0, "starts on day 0")
	check(absf(sim.clock.day_fraction()) < 1e-6, "starts at midnight")
	var lon0 := Geo.dir_from_lat_lon(0, 0)
	check(not sim.clock.is_daylight(lon0), "midnight is dark at lon 0")
	_run(sim, 300)  # half a day
	check(absf(sim.clock.local_hour(lon0) - 12.0) < 0.01, "noon after half a day")
	check(sim.clock.is_daylight(lon0), "noon is light at lon 0")
	check(not sim.clock.is_daylight(-lon0), "other side of the planet is dark at noon")
	_run(sim, 300)
	check(sim.clock.day_number() == 1, "a full day later it is day 1")


func test_spawn_rules() -> void:
	var sim := Simulation.new()
	var land := _land_dir(sim)
	var water := Vector3.ZERO
	var rng := RandomNumberGenerator.new()
	for i in 1000:
		var d := Geo.random_dir(rng)
		if not sim.planet.is_land(d):
			water = d
			break
	sim.submit_command(Commands.spawn(Commands.ADMIN, "explorer", land))
	sim.submit_command(Commands.spawn(Commands.ADMIN, "explorer", water))
	sim.submit_command(Commands.spawn(Commands.ADMIN, "dragon", land))
	sim.step()
	check(sim.entities.size() == 1, "only the valid spawn happened")
	check(_events_of(sim.events, "command_rejected").size() == 2, "two spawns rejected")
	check(_events_of(sim.events, "entity_spawned").size() == 1, "spawn event emitted")


func test_move_to_arrives_on_surface() -> void:
	var sim := Simulation.new()
	var walk := _land_walk(sim, 4.0)
	check(walk.size() == 2, "found a land walk for the test")
	if walk.is_empty():
		return
	sim.submit_command(Commands.spawn(Commands.ADMIN, "explorer", walk[0]))
	sim.step()
	var id: int = sim.entities.keys()[0]
	sim.submit_command(Commands.move_to(Commands.ADMIN, id, walk[1]))
	var events := _run(sim, 2000)
	var e := sim.get_entity(id)
	check(_events_of(events, "entity_arrived").size() == 1, "arrived exactly once")
	check(e.dir.is_equal_approx(walk[1]), "ended at the target")
	check(e.state == "idle" and not e.has_target, "idle after arriving")
	var expected_r: float = sim.planet.radius + maxf(sim.planet.height_at(e.dir), 0.0)
	check(absf(e.position.length() - expected_r) < 1e-3, "standing on the surface")


func test_lat_lon_targets() -> void:
	var sim := Simulation.new()
	var ll := Geo.lat_lon_from_dir(_land_dir(sim))
	sim.submit_command({"type": "spawn", "issuer": "admin", "kind": "explorer", "target": {"lat": ll.x, "lon": ll.y}})
	sim.submit_command({"type": "spawn", "issuer": "admin", "kind": "explorer", "target": {"lat": 120, "lon": 0}})
	sim.step()
	check(sim.entities.size() == 1, "lat/lon spawn works, impossible latitude rejected")


func test_permissions() -> void:
	var sim := Simulation.new()
	var land := _land_dir(sim)
	sim.submit_command(Commands.spawn(Commands.ADMIN, "explorer", land, "player:alice"))
	sim.step()
	var id: int = sim.entities.keys()[0]
	sim.submit_command(Commands.move_to("player:bob", id, land))
	sim.step()
	check(_events_of(sim.events, "command_rejected").size() == 1, "bob can't move alice's explorer")
	sim.submit_command(Commands.spawn("player:alice", "tree", land))
	sim.step()
	check(_events_of(sim.events, "command_rejected").size() == 1, "non-admin can't spawn")
	sim.submit_command(Commands.stop("player:alice", id))
	sim.submit_command(Commands.despawn("player:alice", id))
	sim.step()
	check(_events_of(sim.events, "command_rejected").is_empty(), "alice controls her own explorer")
	check(sim.entities.is_empty(), "despawned")


func test_bad_commands_are_rejected_not_crashing() -> void:
	var sim := Simulation.new()
	sim.populate(0, 0, 1)
	var id: int = sim.entities.keys()[0]
	var bad := [
		{},
		{"type": "fly"},
		{"type": "move_to", "issuer": "admin"},
		{"type": "move_to", "issuer": "admin", "entity_id": id},
		{"type": "move_to", "issuer": "admin", "entity_id": id, "target": "north"},
		{"type": "move_to", "issuer": "admin", "entity_id": id, "target": [0, 0, 0]},
		{"type": "move_to", "issuer": "admin", "entity_id": id, "target": Vector3(INF, 0, 0)},
		{"type": "despawn", "issuer": "admin", "entity_id": 999},
	]
	for cmd: Dictionary in bad:
		sim.submit_command(cmd)
	sim.step()
	check(_events_of(sim.events, "command_rejected").size() == bad.size(), "every bad command rejected")
	check(sim.entities.size() == 1, "world unchanged")


func test_trees_cannot_move() -> void:
	var sim := Simulation.new()
	sim.populate(1, 0, 0)
	var id: int = sim.entities.keys()[0]
	sim.submit_command(Commands.move_to(Commands.ADMIN, id, Vector3.UP))
	sim.step()
	check(_events_of(sim.events, "command_rejected").size() == 1, "tree refused to move")


func test_walkers_stop_at_water() -> void:
	var sim := Simulation.new()
	var land := _land_dir(sim)
	sim.submit_command(Commands.spawn(Commands.ADMIN, "explorer", land))
	sim.step()
	var id: int = sim.entities.keys()[0]
	sim.submit_command(Commands.move_to(Commands.ADMIN, id, -land))  # other side of the world
	var events := _run(sim, 20 * 200)
	var e := sim.get_entity(id)
	check(_events_of(events, "entity_blocked").size() >= 1 or _events_of(events, "entity_arrived").size() == 1,
		"either reached the far side or stopped at water")
	check(sim.planet.height_at(e.dir) > -Water.WADE_DEPTH, "never walked into deep water")


func test_wander_brain_moves_critters_by_day_only() -> void:
	var sim := Simulation.new({"seed": 3, "day_length": 120.0, "start_hour": 0.0})
	sim.populate(0, 40, 0)
	var start := {}
	for e in sim.entities.values():
		start[e.id] = e.dir
	_run(sim, 20 * 120)  # one full day
	var moved := 0
	for e in sim.entities.values():
		if not e.dir.is_equal_approx(start[e.id]):
			moved += 1
	check(moved > 20, "most critters wandered during a day (%d/40)" % moved)
	var night_movers := 0
	for e in sim.entities.values():
		if e.has_target and not sim.clock.is_daylight(e.dir):
			night_movers += 1
	_run(sim, 1)
	for e in sim.entities.values():
		if e.has_target and not sim.clock.is_daylight(e.dir):
			night_movers += 1
	check(night_movers == 0, "critters in the dark are resting")


func test_same_inputs_same_world() -> void:
	var hashes: Array[int] = []
	for run in 2:
		var sim := Simulation.new({"seed": 77})
		sim.populate()
		var explorer_id := -1
		for e in sim.entities.values():
			if e.kind == "explorer":
				explorer_id = e.id
		for i in 1500:
			if i == 100:
				sim.submit_command(Commands.move_to(Commands.ADMIN, explorer_id, {"lat": 10, "lon": 10}))
			sim.step()
		hashes.append(sim.state_hash())
	check(hashes[0] == hashes[1], "same seed + same commands = identical world")
	var other := Simulation.new({"seed": 78})
	other.populate()
	check(other.state_hash() != hashes[0], "different seed = different world")


func test_snapshot_survives_serialization() -> void:
	var sim := Simulation.new()
	sim.populate(5, 5, 1)
	_run(sim, 50)
	var snap := sim.snapshot()
	# Binary, as Godot's networking would send it.
	var round_trip: Dictionary = bytes_to_var(var_to_bytes(snap))
	check(var_to_str(round_trip) == var_to_str(snap), "binary round trip is lossless")
	# Text, as an outside AI agent would receive it.
	var json := JSON.stringify(snap)
	check(json.length() > 100 and JSON.parse_string(json) is Dictionary, "snapshot converts to JSON")


func test_server_steps_at_fixed_rate() -> void:
	var server := SimServer.new()
	server.start({}, false)
	var published := []
	server.snapshot_published.connect(func(s: Dictionary) -> void: published.append(s))
	server._process(1.0)  # one real second at speed 1 => tick_rate steps
	check(server.sim.clock.tick == server.sim.clock.tick_rate, "one second = tick_rate ticks")
	server.set_speed(4.0)
	server._process(0.5)
	check(server.sim.clock.tick == server.sim.clock.tick_rate * 3, "speed x4 runs 4x faster")
	server.set_paused(true)
	server._process(10.0)
	check(server.sim.clock.tick == server.sim.clock.tick_rate * 3, "paused means no ticks")
	check(published.size() > 0, "snapshots were published")
	server.free()


# --- agents --------------------------------------------------------------------

func _tick(sim: Simulation, runtime: AgentRuntime, n: int) -> Array:
	var all_events: Array = []
	for i in n:
		sim.step()
		all_events.append_array(sim.events)
		runtime.tick()
	return all_events


func _agent_world() -> Array:
	var sim := Simulation.new()
	return [sim, AgentRuntime.new(sim)]


func test_geo_bearings() -> void:
	var origin := Geo.dir_from_lat_lon(0, 0)
	check(absf(Geo.bearing_deg(origin, Geo.dir_from_lat_lon(10, 0))) < 1e-3, "north is 0")
	check(absf(Geo.bearing_deg(origin, Geo.dir_from_lat_lon(0, 10)) - 90.0) < 1e-3, "east is 90")
	check(absf(Geo.bearing_deg(origin, Geo.dir_from_lat_lon(-10, 0)) - 180.0) < 1e-3, "south is 180")
	check(absf(Geo.bearing_deg(origin, Geo.dir_from_lat_lon(0, -10)) - 270.0) < 1e-3, "west is 270")
	var rng := RandomNumberGenerator.new()
	rng.seed = 4
	for i in 50:
		var from := Geo.random_dir(rng)
		var bearing := rng.randf_range(0.0, 360.0)
		var to := Geo.destination(from, bearing, 0.1)
		check(absf(from.angle_to(to) - 0.1) < 1e-4, "destination goes the right distance")
		var back := Geo.bearing_deg(from, to)
		check(absf(angle_difference(deg_to_rad(back), deg_to_rad(bearing))) < 1e-3, "destination goes the right way")


func test_say_and_assign() -> void:
	var sim := Simulation.new()
	sim.populate(0, 1, 1)
	var critter := -1
	var explorer := -1
	for e in sim.entities.values():
		if e.kind == "critter":
			critter = e.id
		else:
			explorer = e.id
	sim.submit_command(Commands.say(Commands.ADMIN, explorer, "hello world"))
	sim.submit_command(Commands.say(Commands.ADMIN, explorer, "   "))
	sim.submit_command(Commands.say("player:bob", explorer, "not mine"))
	sim.submit_command(Commands.say(Commands.ADMIN, explorer, "x".repeat(1000)))
	sim.step()
	var said := _events_of(sim.events, "entity_said")
	check(said.size() == 2 and said[0]["text"] == "hello world", "say emits what was said")
	check(said.size() == 2 and said[1]["text"].length() == Commands.MAX_SAY_LENGTH, "long speech is cut")
	check(_events_of(sim.events, "command_rejected").size() == 2, "empty or unauthorized speech refused")
	sim.submit_command(Commands.assign("player:bob", explorer, "player:bob"))
	sim.submit_command(Commands.assign(Commands.ADMIN, critter, "player:bob"))
	sim.step()
	check(_events_of(sim.events, "command_rejected").size() == 1, "only admin can assign")
	check(sim.get_entity(critter).controller == "player:bob", "assign hands over control")
	sim.submit_command(Commands.stop("player:bob", critter))
	sim.step()
	check(_events_of(sim.events, "command_rejected").is_empty(), "new controller may command it")


func test_agent_spawns_and_observes() -> void:
	var w := _agent_world()
	var sim: Simulation = w[0]
	var runtime: AgentRuntime = w[1]
	var agent := ScriptedAgent.new()
	agent.agent_name = "tester"
	agent.think_every = 1
	var ctrl := runtime.spawn_agent(agent, "explorer", _land_dir(sim))
	check(ctrl.begins_with("agent:tester:"), "controller names the agent")
	check(agent.entity_id == -1, "no body until the spawn is applied")
	_tick(sim, runtime, 3)
	check(agent.entity_id != -1 and sim.get_entity(agent.entity_id).controller == ctrl, "agent got its body")
	check(agent.seen.size() >= 2, "agent decides every tick when think_every = 1")
	var obs: Dictionary = agent.seen[-1]
	for key in ["tick", "time", "self", "nearby", "surroundings", "events", "feedback", "world"]:
		check(obs.has(key), "observation has '%s'" % key)
	check(obs["self"]["id"] == agent.entity_id and obs["self"]["kind"] == "explorer", "observation describes itself")
	check(obs["surroundings"].size() == 8, "eight compass directions")
	var spawned: Array = agent.seen[0]["events"].filter(func(e: Dictionary) -> bool: return e["type"] == "entity_spawned")
	check(spawned.size() == 1, "first observation reports its own spawn")
	var slow := ScriptedAgent.new()
	slow.think_every = 10
	runtime.spawn_agent(slow, "explorer", _land_dir(sim))
	_tick(sim, runtime, 101)
	check(slow.seen.size() >= 9 and slow.seen.size() <= 11, "think_every = 10 means ~10 decisions in 100 ticks (%d)" % slow.seen.size())


func _plain(v: Variant) -> bool:
	if v == null or v is bool or v is int or v is float or v is String:
		return true
	if v is Array:
		for x in v:
			if not _plain(x):
				return false
		return true
	if v is Dictionary:
		for k in v:
			if not k is String or not _plain(v[k]):
				return false
		return true
	return false


func test_observation_is_plain_json() -> void:
	var sim := Simulation.new()
	sim.populate(20, 20, 0)
	var runtime := AgentRuntime.new(sim)
	var agent := ScriptedAgent.new()
	agent.sight_range = 60.0
	agent.think_every = 1
	runtime.spawn_agent(agent, "explorer", _land_dir(sim))
	_tick(sim, runtime, 40)
	var obs: Dictionary = agent.seen[-1]
	check(_plain(obs), "observation holds only JSON types (no Vector3 etc.)")
	check(JSON.parse_string(JSON.stringify(obs)) is Dictionary, "observation converts to JSON")
	var last := -1.0
	var ok := true
	for n: Dictionary in obs["nearby"]:
		ok = ok and n["distance"] >= last and n["distance"] <= 60.0
		last = n["distance"]
	check(ok, "nearby things are within sight, nearest first")
	check(obs["nearby"].size() <= 12, "nearby list is capped")


func test_agent_actions_move_only_its_own_body() -> void:
	var w := _agent_world()
	var sim: Simulation = w[0]
	var runtime: AgentRuntime = w[1]
	var walk := _land_walk(sim, 4.0)
	sim.submit_command(Commands.spawn(Commands.ADMIN, "explorer", walk[0], "player:alice"))
	sim.step()
	var alice_id: int = sim.entities.keys()[0]
	var agent := ScriptedAgent.new()
	agent.think_every = 1
	runtime.spawn_agent(agent, "explorer", walk[0])
	_tick(sim, runtime, 2)
	var target := Geo.lat_lon_from_dir(walk[1])
	# Sneaks in someone else's id: ignored, actions are always about its own body.
	agent.act({"action": "move_to", "lat": target.x, "lon": target.y, "entity_id": alice_id})
	_tick(sim, runtime, 2)
	check(sim.get_entity(agent.entity_id).has_target, "agent's own body moves")
	check(not sim.get_entity(alice_id).has_target, "alice's explorer is untouched")
	sim.submit_command(Commands.stop("player:alice", agent.entity_id))
	sim.step()
	check(_events_of(sim.events, "command_rejected").size() == 1, "players can't command an agent's body")
	var events := _tick(sim, runtime, 2000)
	check(_events_of(events, "entity_arrived").size() == 1, "agent arrived")
	check(sim.get_entity(agent.entity_id).dir.distance_to(walk[1]) < 1e-3, "agent ended at its target")


func test_bad_actions_become_feedback() -> void:
	var w := _agent_world()
	var sim: Simulation = w[0]
	var runtime: AgentRuntime = w[1]
	var agent := ScriptedAgent.new()
	agent.think_every = 1
	runtime.spawn_agent(agent, "explorer", _land_dir(sim))
	_tick(sim, runtime, 2)
	agent.act([
		{"action": "fly"},
		{"action": "move_to", "lat": 10},
		{"action": "move_to", "lat": "abc", "lon": 0},
		{"action": "move", "bearing": "north", "distance": 5},
		{"action": "approach", "entity_id": 9999},
		{"action": "say", "text": ""},
		"jump",
		{"action": "wait"},
	])
	_tick(sim, runtime, 3)
	var feedback: Array = []
	var refused: Array = []
	for obs: Dictionary in agent.seen.slice(-3):
		feedback.append_array(obs["feedback"])
		refused.append_array(obs["events"].filter(func(e: Dictionary) -> bool: return e["type"] == "action_refused"))
	check(feedback.size() == 4, "malformed actions explained in feedback (%d: %s)" % [feedback.size(), str(feedback)])
	check(refused.size() == 3, "actions the world refused are reported (%d)" % refused.size())
	check(not sim.get_entity(agent.entity_id).has_target, "nothing moved")


func test_slow_agents_are_not_flooded() -> void:
	var w := _agent_world()
	var sim: Simulation = w[0]
	var runtime: AgentRuntime = w[1]
	var agent := SlowAgent.new()
	agent.think_every = 1
	runtime.spawn_agent(agent, "explorer", _land_dir(sim))
	_tick(sim, runtime, 50)
	check(agent.asked == 1, "a busy agent is asked once")
	agent.act({"action": "say", "text": "finally"})
	var events := _tick(sim, runtime, 2)
	check(_events_of(events, "entity_said").size() == 1, "its late answer is carried out")
	check(agent.asked == 2, "and then it is asked again")


func _heard(agent: ScriptedAgent) -> Array:
	var out: Array = []
	for obs: Dictionary in agent.seen:
		out.append_array(obs["events"].filter(func(e: Dictionary) -> bool: return e["type"] == "heard"))
	return out


func test_agents_hear_each_other() -> void:
	var w := _agent_world()
	var sim: Simulation = w[0]
	var runtime: AgentRuntime = w[1]
	var spot := _land_dir(sim)
	var a := ScriptedAgent.new()
	var b := ScriptedAgent.new()
	var far := ScriptedAgent.new()
	for x in [a, b, far]:
		x.think_every = 1
	runtime.spawn_agent(a, "explorer", spot)
	runtime.spawn_agent(b, "explorer", spot)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var far_spot := spot
	while far_spot.angle_to(spot) < 1.0:
		far_spot = sim.planet.random_land_dir(rng)
	runtime.spawn_agent(far, "explorer", far_spot)
	_tick(sim, runtime, 2)
	a.act({"action": "say", "text": "anyone there?"})
	_tick(sim, runtime, 2)
	var b_heard := _heard(b)
	check(b_heard.size() == 1 and b_heard[0]["from"] == a.entity_id and b_heard[0]["text"] == "anyone there?", "nearby agent hears")
	check(_heard(far).is_empty(), "far-away agent doesn't")
	check(_heard(a).is_empty(), "speaker doesn't 'hear' itself")


func test_taking_over_a_critter_pauses_its_brain() -> void:
	var sim := Simulation.new({"seed": 3, "start_hour": 12.0})
	sim.populate(0, 1, 0)
	var runtime := AgentRuntime.new(sim)
	var critter = sim.entities.values()[0]
	var agent := ScriptedAgent.new()
	check(runtime.attach(agent, critter.id), "agent attaches to an existing critter")
	check(not runtime.attach(ScriptedAgent.new(), critter.id), "one agent per body")
	var events := _tick(sim, runtime, 20 * 60)
	check(critter.controller == agent.controller, "critter now answers to the agent")
	check(_events_of(events, "command_rejected").is_empty(), "the wander brain stays quiet instead of fighting the agent")
	runtime.detach(agent)
	_tick(sim, runtime, 1)
	check(critter.controller == "brain:wander", "detaching hands it back to its brain")
	check(agent.detached_reason == "detached" and runtime.agents.is_empty(), "agent was told and removed")


func test_patrol_agent_patrols() -> void:
	var w := _agent_world()
	var sim: Simulation = w[0]
	var runtime: AgentRuntime = w[1]
	var walk := _land_walk(sim, 3.0)
	var a := Geo.lat_lon_from_dir(walk[0])
	var b := Geo.lat_lon_from_dir(walk[1])
	runtime.spawn_agent(PatrolAgent.new([{"lat": b.x, "lon": b.y}, {"lat": a.x, "lon": a.y}]), "explorer", walk[0])
	var events := _tick(sim, runtime, 20 * 60)
	var arrivals := _events_of(events, "entity_arrived")
	check(arrivals.size() >= 2, "patrol went back and forth (%d arrivals)" % arrivals.size())


func test_curious_agent_greets() -> void:
	var sim := Simulation.new({"start_hour": 10.0})
	var runtime := AgentRuntime.new(sim)
	var walk := _land_walk(sim, 4.0)
	sim.submit_command(Commands.spawn(Commands.ADMIN, "explorer", walk[1]))   # an idle explorer to find
	runtime.spawn_agent(CuriousAgent.new(), "explorer", walk[0])
	var events := _tick(sim, runtime, 20 * 30)
	var greetings := _events_of(events, "entity_said").filter(func(e: Dictionary) -> bool:
		return str(e["text"]).begins_with("Hello"))
	check(greetings.size() == 1, "curious agent walked over and said hello once (%d)" % greetings.size())


func _agent_run_hash() -> int:
	var sim := Simulation.new({"seed": 21})
	sim.populate(30, 20, 0)
	var runtime := AgentRuntime.new(sim)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	for i in 4:
		runtime.spawn_agent(CuriousAgent.new(i), "explorer", sim.planet.random_land_dir(rng))
	runtime.spawn_agent(PatrolAgent.new(), "explorer", sim.planet.random_land_dir(rng))
	_tick(sim, runtime, 20 * 120)
	return sim.state_hash()


func test_agents_are_deterministic() -> void:
	check(_agent_run_hash() == _agent_run_hash(), "same seed + same agents = identical world")


func test_server_runs_agents() -> void:
	var server := SimServer.new()
	server.start({}, false)
	var agent := ScriptedAgent.new()
	agent.think_every = 1
	agent.answers = [{"action": "say", "text": "on the server"}]
	server.agents.spawn_agent(agent, "explorer", _land_dir(server.sim))
	var said := []
	server.snapshot_published.connect(func(s: Dictionary) -> void:
		said.append_array(_events_of(s["events"], "entity_said")))
	server._process(0.5)
	check(agent.entity_id != -1 and agent.seen.size() > 0, "server ticks its agents")
	check(said.size() == 1, "agent speech reaches the published snapshots")
	server.free()


func _send_line(client: StreamPeerTCP, msg: Variant) -> void:
	var text: String = msg if msg is String else JSON.stringify(msg)
	client.put_data((text + "\n").to_utf8_buffer())


func _read_client_lines(client: StreamPeerTCP) -> Array:
	client.poll()
	var n := client.get_available_bytes()
	if n <= 0:
		return []
	var text: String = (client.get_partial_data(n)[1] as PackedByteArray).get_string_from_utf8()
	var out: Array = []
	for line in text.split("\n", false):
		var m: Variant = JSON.parse_string(line)
		if m is Dictionary:
			out.append(m)
	return out


func _pump(sim: Simulation, runtime: AgentRuntime, bridge: Node, client: StreamPeerTCP, frames: int) -> Array:
	var said: Array = []
	for i in frames:
		client.poll()
		bridge._process(0.0)
		sim.step()
		said.append_array(_events_of(sim.events, "entity_said"))
		runtime.tick()
		OS.delay_msec(2)
	return said


func test_bridge_drives_an_npc_over_tcp() -> void:
	var sim := Simulation.new()
	var runtime := AgentRuntime.new(sim)
	var bridge := AgentBridge.new(runtime)
	var port := 47000 + randi() % 1000
	check(bridge.listen(port) == OK, "bridge listens")
	var client := StreamPeerTCP.new()
	client.connect_to_host("127.0.0.1", port)
	_pump(sim, runtime, bridge, client, 20)
	check(client.get_status() == StreamPeerTCP.STATUS_CONNECTED, "client connected")
	var ll := Geo.lat_lon_from_dir(_land_dir(sim))
	_send_line(client, {"op": "join", "name": "py", "kind": "explorer", "lat": ll.x, "lon": ll.y, "think_every": 2})
	_pump(sim, runtime, bridge, client, 40)
	var ops := _read_client_lines(client).map(func(m: Dictionary) -> String: return m.get("op", ""))
	check(ops.has("joined"), "server confirms the join (%s)" % str(ops))
	check(ops.count("observe") == 1, "exactly one observation until we answer (%s)" % str(ops))
	_send_line(client, {"op": "act", "actions": [{"action": "say", "text": "hi from python"}]})
	_send_line(client, "not json")
	var said := _pump(sim, runtime, bridge, client, 40)
	check(said.size() == 1 and said[0]["text"] == "hi from python", "remote action happened in the world")
	ops = _read_client_lines(client).map(func(m: Dictionary) -> String: return m.get("op", ""))
	check(ops.has("error"), "garbage gets an error, not a crash")
	check(ops.has("observe"), "next observation after answering")
	client.disconnect_from_host()
	_pump(sim, runtime, bridge, client, 20)
	check(runtime.agents.is_empty(), "disconnecting removes the agent")
	check(sim.entities.is_empty(), "and its body")
	bridge.free()


# --- multiplayer ---------------------------------------------------------------

func test_protocol_round_trip() -> void:
	var sim := Simulation.new()
	sim.populate()
	var snap := sim.snapshot()
	var msg := {"op": "state", "tick": snap["tick"], "time": snap["time"], "entities": snap["entities"]}
	var bytes := Protocol.encode(msg)
	var back: Variant = Protocol.decode(bytes)
	check(back is Dictionary and var_to_str(back) == var_to_str(msg), "state survives encode/decode exactly")
	check(bytes.size() < 20000, "a full world state is small enough to send 10x a second (%d bytes)" % bytes.size())
	check(Protocol.decode(PackedByteArray([1, 2, 3, 4, 5, 6])) == null, "garbage decodes to null")
	check(Protocol.decode(Protocol.encode({"no_op": 1})) == null, "a message needs an op")
	check(Protocol.clean_name(" al:ice ") == "al_ice", "names can't break controller ids")
	check(Protocol.controller_label("player:alice:5") == "alice", "player label")


func test_auth_guard_soft_blocks() -> void:
	var g := AuthGuard.new("secret")
	g.now_override = 100.0
	check(g.check("1.2.3.4", "secret") == "ok", "right password")
	for i in AuthGuard.MAX_FAILURES - 1:
		g.check("1.2.3.4", "nope")
	check(not g.is_blocked("1.2.3.4"), "not blocked after 9 wrong guesses")
	check(g.check("1.2.3.4", "nope") == "wrong", "10th wrong guess")
	check(g.check("1.2.3.4", "secret") == "blocked", "after 10 wrong guesses even the right password is refused")
	check(g.check("5.6.7.8", "secret") == "ok", "other addresses are unaffected")
	check(g.minutes_left("1.2.3.4") == 10, "blocked for 10 minutes")
	g.now_override = 100.0 + AuthGuard.BLOCK_SECONDS + 1.0
	check(g.check("1.2.3.4", "secret") == "ok", "block ends, then the right password works")
	check(AuthGuard.new("").check("x", "") == "ok", "no password set = anyone may join")


func test_bridge_password() -> void:
	var sim := Simulation.new()
	var runtime := AgentRuntime.new(sim)
	var bridge := AgentBridge.new(runtime)
	bridge.guard = AuthGuard.new("pw")
	var port := 48000 + randi() % 1000
	check(bridge.listen(port) == OK, "bridge with password listens")
	var bad := StreamPeerTCP.new()
	bad.connect_to_host("127.0.0.1", port)
	_pump(sim, runtime, bridge, bad, 20)
	_send_line(bad, {"op": "join", "name": "x", "password": "wrong"})
	_pump(sim, runtime, bridge, bad, 20)
	var msgs := _read_client_lines(bad)
	check(msgs.size() > 0 and msgs[0].get("message", "") == "wrong password", "wrong password refused (%s)" % str(msgs))
	check(runtime.agents.is_empty() and sim.entities.is_empty(), "no body for a wrong password")
	var good := StreamPeerTCP.new()
	good.connect_to_host("127.0.0.1", port)
	_pump(sim, runtime, bridge, good, 20)
	_send_line(good, {"op": "join", "name": "y", "password": "pw"})
	_pump(sim, runtime, bridge, good, 30)
	var ops := _read_client_lines(good).map(func(m: Dictionary) -> String: return m.get("op", ""))
	check(ops.has("joined"), "right password joins (%s)" % str(ops))
	bridge.free()


## A little networked world in one process: a SimServer, a NetServer and clients.
class NetWorld:
	var server: Node
	var net: Node
	var clients: Array = []
	var port := 0

	func _init(password: String, mode: String) -> void:
		server = SimServer.new()
		server.start({}, false)
		net = NetServer.new(server, AuthGuard.new(password))
		net.mode = mode
		port = 49000 + randi() % 1000
		net.listen(port, "127.0.0.1")

	func join(player_name: String, password: String, role: String = "player") -> Dictionary:
		var c := NetClient.new()
		var log := {"client": c, "welcome": null, "states": [], "events": [], "msgs": [], "closed": ""}
		c.welcomed.connect(func(info: Dictionary) -> void: log["welcome"] = info)
		c.state_received.connect(func(st: Dictionary, evs: Array) -> void:
			log["states"].append(st)
			log["events"].append_array(evs))
		c.message_received.connect(func(m: Dictionary) -> void: log["msgs"].append(m))
		c.disconnected.connect(func(reason: String) -> void: log["closed"] = reason)
		c.connect_to("127.0.0.1", port, {"name": player_name, "role": role, "password": password})
		clients.append(log)
		return log

	## Run everything for a number of frames (real time passes so ENet can work).
	func pump(frames: int, dt: float = 0.02) -> void:
		for i in frames:
			server._process(dt)
			net._process(dt)
			for log: Dictionary in clients:
				(log["client"] as Node)._process(dt)
			OS.delay_msec(3)

	## Pump until cond() is true (or give up).
	func pump_until(cond: Callable, max_frames: int = 300) -> bool:
		for i in max_frames:
			if cond.call():
				return true
			pump(1)
		return cond.call()

	func body(log: Dictionary) -> int:
		var last := -1
		for m: Dictionary in log["msgs"]:
			if m["op"] == "you":
				last = int(m["entity_id"])
		return last

	func send(log: Dictionary, msg: Dictionary) -> void:
		(log["client"] as Node).send(msg)

	func close() -> void:
		for log: Dictionary in clients:
			(log["client"] as Node).free()
		net.stop()
		net.free()
		server.free()


func _said_texts(events: Array) -> Array:
	return _events_of(events, "entity_said").map(func(e: Dictionary) -> String: return e["text"])


func test_multiplayer_join_and_permissions() -> void:
	var w := NetWorld.new("pw", Protocol.MODE_SURVIVAL)
	var alice := w.join("alice", "pw")
	var bob := w.join("bob", "pw")
	var watcher := w.join("eve", "pw", "spectator")
	check(w.pump_until(func() -> bool: return w.body(alice) != -1 and w.body(bob) != -1 and watcher["welcome"] != null),
		"two players and a spectator join")
	check(alice["welcome"]["issuer"].begins_with("player:alice:"), "server names the player")
	check(alice["welcome"]["planet"]["seed"] == w.server.sim.planet.world_seed, "welcome carries the planet seed")
	check(watcher["welcome"]["role"] == "spectator", "spectator role")
	w.pump(10)
	check(alice["states"].size() > 0, "players receive world states")
	var last_state: Dictionary = alice["states"].back()
	check(last_state["entities"].size() == w.server.sim.entities.size(), "states hold every entity")
	check(not last_state.has("planet"), "terrain is never re-sent")
	var a_id := w.body(alice)
	var b_id := w.body(bob)
	var a_ent = w.server.sim.get_entity(a_id)
	check(a_ent != null and str(a_ent.controller).begins_with("player:alice"), "alice controls her own explorer")

	# Pretending to be the host doesn't work.
	var before: int = w.server.sim.entities.size()
	w.send(alice, {"op": "cmd", "command": {"type": "spawn", "issuer": "admin", "kind": "tree", "target": a_ent.dir}})
	w.send(alice, {"op": "cmd", "command": {"type": "despawn", "issuer": "admin", "entity_id": b_id}})
	w.pump(15)
	check(w.server.sim.entities.size() == before, "survival players can't spawn or remove, even claiming to be admin")
	check(alice["msgs"].any(func(m: Dictionary) -> bool: return m["op"] == "notice"), "and are told why")

	# Own explorer yes, someone else's no.
	var b_ent = w.server.sim.get_entity(b_id)
	w.send(alice, {"op": "cmd", "command": {"type": "move_to", "issuer": "admin", "entity_id": a_id, "target": b_ent.dir}})
	w.send(alice, {"op": "cmd", "command": {"type": "move_to", "issuer": "admin", "entity_id": b_id, "target": a_ent.dir}})
	w.pump(15)
	check(a_ent.has_target or a_ent.dir != a_ent.target_dir, "alice can walk her explorer")
	check(not b_ent.has_target, "alice can't move bob's explorer")
	check(_events_of(alice["events"], "command_rejected").size() >= 1, "alice hears about her refused command")
	check(_events_of(bob["events"], "command_rejected").is_empty(), "bob doesn't see alice's refusals")

	# Spectators can't do anything.
	w.send(watcher, {"op": "cmd", "command": {"type": "stop", "entity_id": a_id}})
	w.send(watcher, {"op": "time", "paused": true})
	w.pump(10)
	check(not w.server.paused, "spectator can't pause")
	w.send(alice, {"op": "time", "paused": true})
	w.pump(10)
	check(not w.server.paused, "a player who isn't a moderator can't pause")

	# Leaving removes your explorer.
	(bob["client"] as Node).close()
	check(w.pump_until(func() -> bool: return w.server.sim.get_entity(b_id) == null), "bob's explorer disappears when he leaves")
	check(w.pump_until(func() -> bool: return w.net.player_list().size() == 2), "player list updates")
	w.close()


## Spawn an explorer exactly `meters` from `from_dir` (on land), or return -1.
func _explorer_at_distance(sim: Simulation, from_dir: Vector3, meters: float) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	for i in 200:
		var axis := from_dir.cross(Vector3(rng.randf() - 0.5, rng.randf() - 0.5, rng.randf() - 0.5)).normalized()
		if axis.length_squared() < 0.5:
			continue
		var d := from_dir.rotated(axis, meters / sim.planet.radius)
		if sim.planet.is_land(d):
			sim.submit_command(Commands.spawn(Commands.ADMIN, "explorer", d))
			sim.step()
			for ev in sim.events:
				if ev["type"] == "entity_spawned":
					return ev["entity_id"]
	return -1


func test_multiplayer_proximity_chat() -> void:
	var w := NetWorld.new("", Protocol.MODE_SURVIVAL)
	var alice := w.join("alice", "")
	var watcher := w.join("eve", "", "spectator")
	check(w.pump_until(func() -> bool: return w.body(alice) != -1 and watcher["welcome"] != null), "joined")
	var a_dir: Vector3 = w.server.sim.get_entity(w.body(alice)).dir
	var near := _explorer_at_distance(w.server.sim, a_dir, 20.0)
	var far := _explorer_at_distance(w.server.sim, a_dir, 50.0)
	check(near != -1 and far != -1, "test speakers placed")
	w.server.submit_command(Commands.say(Commands.ADMIN, near, "hello from close by"))
	w.server.submit_command(Commands.say(Commands.ADMIN, far, "hello from far away"))
	w.send(alice, {"op": "cmd", "command": {"type": "say", "entity_id": w.body(alice), "text": "hi all"}})
	w.pump(25)
	var heard := _said_texts(alice["events"])
	check(heard.has("hello from close by"), "a player hears someone 20 m away (%s)" % str(heard))
	check(not heard.has("hello from far away"), "but not someone 50 m away")
	check(heard.has("hi all"), "and hears themselves")
	var near_ev: Array = _events_of(alice["events"], "entity_said").filter(func(e: Dictionary) -> bool:
		return e["text"] == "hello from close by")
	check(near_ev.size() == 1 and absf(float(near_ev[0]["distance"]) - 20.0) < 0.5,
		"each line carries the distance, for voice volume later")
	var all := _said_texts(watcher["events"])
	check(all.has("hello from far away") and all.has("hello from close by") and all.has("hi all"),
		"spectators hear everything")
	w.close()


func test_multiplayer_creative_and_moderators() -> void:
	var w := NetWorld.new("", Protocol.MODE_CREATIVE)
	var alice := w.join("alice", "")
	var bob := w.join("bob", "")
	check(w.pump_until(func() -> bool: return w.body(alice) != -1 and w.body(bob) != -1), "joined")
	var a_ent = w.server.sim.get_entity(w.body(alice))
	var before: int = w.server.sim.entities.size()
	w.send(alice, {"op": "cmd", "command": {"type": "spawn", "kind": "tree", "target": a_ent.dir}})
	w.send(alice, {"op": "agent", "kind": "explorer", "target": a_ent.dir})
	w.pump(15)
	check(w.server.sim.entities.size() == before + 2, "creative players can spawn things and AI explorers")
	check(w.server.agents.agents.size() == 1, "the AI explorer is running")
	w.send(alice, {"op": "cmd", "command": {"type": "despawn", "entity_id": w.body(bob)}})
	w.pump(10)
	check(w.server.sim.get_entity(w.body(bob)) != null, "but can't remove another player's explorer")

	# Moderators.
	var alice_peer: int = alice["welcome"]["peer_id"]
	var bob_peer: int = bob["welcome"]["peer_id"]
	w.net.set_mod(alice_peer, true)
	w.pump(5)
	w.send(alice, {"op": "time", "paused": true, "speed": 4.0})
	check(w.pump_until(func() -> bool: return w.server.paused), "a moderator can pause")
	check(w.server.speed == 4.0, "and change speed")
	w.send(alice, {"op": "time", "paused": false})
	w.send(bob, {"op": "kick", "peer_id": alice_peer})
	w.pump(10)
	check(alice["closed"] == "", "a non-moderator can't kick")
	w.send(alice, {"op": "kick", "peer_id": bob_peer})
	check(w.pump_until(func() -> bool: return bob["closed"] != ""), "a moderator can kick (%s)" % bob["closed"])
	check(bob["closed"].contains("alice"), "and the kicked player is told who did it")
	w.close()


func test_multiplayer_wrong_password_and_block() -> void:
	var w := NetWorld.new("pw", Protocol.MODE_SURVIVAL)
	var bad := w.join("mallory", "guess")
	check(w.pump_until(func() -> bool: return bad["closed"] != ""), "wrong password is refused")
	check(bad["closed"] == "Wrong password.", "with a clear reason (%s)" % bad["closed"])
	check(w.server.sim.entities.is_empty(), "no explorer for a wrong password")
	for i in AuthGuard.MAX_FAILURES - 1:
		w.net.guard.check("127.0.0.1", "guess")
	var right := w.join("mallory", "pw")
	check(w.pump_until(func() -> bool: return right["closed"] != ""), "soft-blocked after 10 wrong passwords")
	check(right["closed"].begins_with("Too many wrong passwords"), "told to try later (%s)" % right["closed"])
	w.close()


func test_population_keeper() -> void:
	var server := SimServer.new()
	server.start({}, false)
	var keeper := PopulationKeeper.new(server, 3, 5)
	server.add_child(keeper)
	for i in 10:
		server._process(0.1)
	check(server.agents.agents.size() == 3, "sim mode starts the AI explorers (%d)" % server.agents.agents.size())
	var critters := 0
	for e in server.sim.entities.values():
		if e.kind == "critter":
			critters += 1
	check(critters == 5, "and keeps critters stocked")
	server.agents.detach(server.agents.agents[0], true, "test")
	for i in 30:
		server._process(0.1)
	check(server.agents.agents.size() == 3, "a lost agent is replaced")
	server.free()


func test_local_link_roles() -> void:
	var server := SimServer.new()
	server.start({}, false)
	var host := LocalLink.new(server)
	var watch := LocalLink.new(server, null, true)
	var d := _land_dir(server.sim)
	watch.submit_command(Commands.spawn(Commands.ADMIN, "tree", d))
	host.submit_command(Commands.spawn("someone", "critter", d))
	server.step_once()
	check(server.sim.entities.size() == 1, "only the single player's command lands")
	check(server.sim.entities.values()[0].kind == "critter", "and it is sent as admin")
	check(not watch.can_edit_world() and watch.can_control_time(), "a local watcher can't edit but can pause their own world")
	host.free()
	watch.free()
	server.free()


# --- physics, water, saving ------------------------------------------------------

func _spawn_one(sim: Simulation, kind: String, where: Vector3) -> int:
	sim.submit_command(Commands.spawn(Commands.ADMIN, kind, where))
	sim.step()
	for ev in sim.events:
		if ev["type"] == "entity_spawned":
			return ev["entity_id"]
	return -1


func test_walkers_bump_into_trees() -> void:
	var sim := Simulation.new()
	var walk := _land_walk(sim, 8.0)
	if walk.is_empty():
		check(false, "found a land walk")
		return
	var mid: Vector3 = walk[0].slerp(walk[1], 0.5).normalized()
	var tree := _spawn_one(sim, "tree", mid)
	var walker := _spawn_one(sim, "explorer", walk[0])
	sim.submit_command(Commands.move_to(Commands.ADMIN, walker, mid))   # straight into the tree
	var closest := INF
	var events: Array = []
	for i in 600:
		sim.step()
		events.append_array(sim.events)
		closest = minf(closest, sim.get_entity(walker).position.distance_to(sim.get_entity(tree).position))
	check(closest > 1.4, "the walker never walks through the tree (closest %.2f m)" % closest)
	check(sim.get_entity(tree).dir == mid, "the tree didn't budge")
	check(_events_of(events, "entity_arrived").size() + _events_of(events, "entity_blocked").size() == 1,
		"walking into a tree ends (arrived next to it) instead of pushing forever")


func test_crowds_spread_out() -> void:
	var sim := Simulation.new()
	var spot := _land_dir(sim)
	var a := _spawn_one(sim, "explorer", spot)
	var b := _spawn_one(sim, "explorer", spot)
	_run(sim, 40)
	var d := sim.get_entity(a).position.distance_to(sim.get_entity(b).position)
	check(d > 1.5, "two explorers on the same spot push each other apart (%.2f m)" % d)


## A direction with water between `lo` and `hi` meters deep.
func _water_dir(sim: Simulation, lo: float, hi: float) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in 20000:
		var d := Geo.random_dir(rng)
		var depth := Water.depth(sim.planet, d)
		if depth > lo and depth < hi:
			return d
	return Vector3.ZERO


func test_wading_in_shallow_water() -> void:
	var sim := Simulation.new()
	var shallow := _water_dir(sim, 0.2, 0.8)
	var deep := _water_dir(sim, 2.0, 99.0)
	var walker_def: Dictionary = EntityKinds.KINDS["explorer"]
	check(shallow != Vector3.ZERO and deep != Vector3.ZERO, "found shallow and deep water")
	check(Water.can_be_at(sim.planet, walker_def, shallow), "walkers may wade in shallow water")
	check(not Water.can_be_at(sim.planet, walker_def, deep), "but not deep water")
	check(Water.speed_factor(sim.planet, walker_def, shallow) == Water.WADE_SPEED, "wading is slower")
	check(Water.medium(sim.planet, walker_def, shallow) == "wading", "and shows as wading")
	check(Water.current_at(sim.planet, shallow + Vector3.ZERO).length() <= Water.MAX_CURRENT * 0.5,
		"currents are weak near the shore")


func test_rafts_float_and_drift() -> void:
	var sim := Simulation.new()
	var deep := _water_dir(sim, 3.0, 99.0)
	var raft := _spawn_one(sim, "raft", deep)
	check(raft != -1, "a raft can be put on open water")
	check(_spawn_one(sim, "raft", _land_dir(sim)) == -1, "but not on land")
	var start := sim.get_entity(raft).dir
	_run(sim, 400)
	var e := sim.get_entity(raft)
	check(e.dir.angle_to(start) * sim.planet.radius > 1.0, "an idle raft drifts with the current")
	check(Water.depth(sim.planet, e.dir) >= Water.FLOAT_DEPTH, "and stays afloat")
	check(e.to_dict()["medium"] == "floating", "it shows as floating")


func _world_hash_after(sim: Simulation, ticks: int) -> int:
	_run(sim, ticks)
	return sim.state_hash()


func test_save_and_load() -> void:
	var sim := Simulation.new({"seed": 5})
	sim.populate()
	_run(sim, 100)
	var save := sim.save_state()
	var expected := _world_hash_after(sim, 200)
	var copy := Simulation.new()   # a different (default) seed until loaded
	check(copy.load_state(bytes_to_var(var_to_bytes(save))) == "", "save loads")
	check(copy.planet.world_seed == 5, "the planet comes back too")
	check(_world_hash_after(copy, 200) == expected, "a loaded world carries on exactly as the original")
	check(Simulation.new().load_state({"version": 999}) != "", "a save from another version is refused")


func test_server_save_file() -> void:
	var server := SimServer.new()
	server.start({"seed": 9})
	var agent := ScriptedAgent.new()
	server.agents.spawn_agent(agent, "explorer", _land_dir(server.sim))
	server._process(0.2)
	var count := server.sim.entities.size()
	var path := "user://test_saves/slot_test.save"
	check(server.save_game(path) == OK, "server saves to a file")
	server.submit_command(Commands.despawn(Commands.ADMIN, server.sim.entities.keys()[0]))
	server._process(0.2)
	var loaded := [false]
	server.world_loaded.connect(func() -> void: loaded[0] = true)
	check(server.load_game(path) == "", "and loads it back")
	check(loaded[0] and server.sim.entities.size() == count, "the world is as it was saved")
	check(server.agents.agents.is_empty() and agent.detached_reason != "", "AI agents are let go on load")
	var body_ctrl := ""
	for e in server.sim.entities.values():
		if e.kind == "explorer" and e.controller.begins_with("agent:"):
			body_ctrl = e.controller
	check(body_ctrl == "", "saved bodies don't keep agent controllers")
	check(server.load_game("user://test_saves/missing.save") != "", "a missing save is reported, not a crash")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	server.free()
