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
	check(sim.planet.is_land(e.dir), "never walked into the sea")


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
