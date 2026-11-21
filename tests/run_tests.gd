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
