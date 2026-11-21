## The authoritative world simulation.
##
## This is pure data + rules: no rendering, no input, no networking, no Nodes.
## It only changes when step() is called, and only through commands. That
## makes it:
##   * multiplayer-ready: a server runs this, clients just send commands and
##     draw snapshots;
##   * AI-ready: agents observe snapshots and send the same commands players do;
##   * testable: tests/run_tests.gd drives it without opening a window.
extends RefCounted

const Planet = preload("res://sim/planet.gd")
const SimClock = preload("res://sim/sim_clock.gd")
const Entity = preload("res://sim/entity.gd")
const Commands = preload("res://sim/commands.gd")
const EntityKinds = preload("res://sim/entity_kinds.gd")
const Geo = preload("res://sim/geo.gd")
const WanderBrain = preload("res://sim/brains/wander_brain.gd")
const Water = preload("res://sim/water.gd")
const Physics = preload("res://sim/physics.gd")

const SAVE_VERSION := 1
## A walker that makes no progress for this many ticks gives up (something is in the way).
const STUCK_TICKS := 40

var planet: Planet
var clock: SimClock
var rng := RandomNumberGenerator.new()   ## the ONLY randomness the sim may use
var entities: Dictionary = {}            ## id (int) -> Entity
var events: Array[Dictionary] = []       ## what happened during the latest step()

var _next_id := 1
var _pending: Array[Dictionary] = []
var _brains: Dictionary = {}             ## brain name -> object with think(sim, entity)
var _config: Dictionary = {}


## config keys (all optional): seed, radius, max_height, tick_rate, day_length,
## year_length_days, axial_tilt, start_hour
func _init(config: Dictionary = {}) -> void:
	_configure(config)
	register_brain("wander", WanderBrain.new())


func _configure(config: Dictionary) -> void:
	_config = config.duplicate(true)
	var world_seed := int(config.get("seed", 12345))
	planet = Planet.new(world_seed, float(config.get("radius", 100.0)), float(config.get("max_height", 6.0)))
	clock = SimClock.new(
		int(config.get("tick_rate", 20)),
		float(config.get("day_length", 120.0)),
		float(config.get("year_length_days", 8.0)),
		float(config.get("axial_tilt", 23.0)),
		float(config.get("start_hour", 9.0)))
	rng.seed = world_seed


## Plug in a built-in behavior by name. Entities whose kind lists this brain use it.
func register_brain(brain_name: String, brain: Object) -> void:
	_brains[brain_name] = brain


## Fill a fresh world with starting entities.
func populate(trees: int = 80, critters: int = 25, explorers: int = 1) -> void:
	for i in trees:
		_spawn_on_random_land("tree")
	for i in critters:
		_spawn_on_random_land("critter")
	for i in explorers:
		_spawn_on_random_land("explorer")


## Queue a command. It is validated and applied during the next step().
func submit_command(cmd: Dictionary) -> void:
	_pending.append(cmd.duplicate(true))


## Advance the world by exactly one tick.
func step() -> void:
	events.clear()
	# 1. Built-in brains look at the world and queue commands like anyone else.
	#    A brain only runs while it is in control (an AI agent or player who
	#    takes over a critter switches its brain off).
	for e: Entity in entities.values():
		if e.brain != "" and _brains.has(e.brain) and e.controller == "brain:" + e.brain:
			_pending.append_array(_brains[e.brain].think(self, e))
	# 2. Apply every queued command, in the order received.
	var queue := _pending
	_pending = []
	for cmd in queue:
		var reason := _apply_command(cmd)
		if reason != "":
			_emit("command_rejected", {"command": cmd, "reason": reason})
	# 3. Run systems.
	_move_entities()
	clock.tick += 1


## A complete, serializable picture of the world. This is what gets sent to
## clients (and, later, to AI agents).
func snapshot() -> Dictionary:
	var list: Array = []
	for e: Entity in entities.values():
		list.append(e.to_dict())
	return {
		"tick": clock.tick,
		"time": clock.to_dict(),
		"planet": planet.to_dict(),
		"entities": list,
		"events": events.duplicate(true),
	}


## Fingerprint of the world state. Two sims with equal hashes are identical.
func state_hash() -> int:
	var s := snapshot()
	s.erase("events")
	return var_to_str(s).hash()


func get_entity(id: int) -> Entity:
	return entities.get(id)


## Entities within `distance` (straight-line) of a world point, nearest first.
func entities_near(point: Vector3, distance: float) -> Array:
	var found: Array = []
	for e: Entity in entities.values():
		if e.position.distance_to(point) <= distance:
			found.append(e)
	found.sort_custom(func(a: Entity, b: Entity) -> bool:
		return a.position.distance_squared_to(point) < b.position.distance_squared_to(point))
	return found


func can_control(issuer: String, e: Entity) -> bool:
	return issuer == Commands.ADMIN or (e.controller != "" and issuer == e.controller)


# --- internals --------------------------------------------------------------

## Returns "" if applied, otherwise the reason it was rejected.
func _apply_command(cmd: Dictionary) -> String:
	var type := str(cmd.get("type", ""))
	var issuer := str(cmd.get("issuer", ""))
	match type:
		Commands.SPAWN:
			if issuer != Commands.ADMIN:
				return "only admin can spawn"
			var kind := str(cmd.get("kind", ""))
			if not EntityKinds.KINDS.has(kind):
				return "unknown kind '%s'" % kind
			var target: Variant = Commands.parse_target(cmd.get("target"))
			if target == null:
				return "invalid target"
			var def: Dictionary = EntityKinds.KINDS[kind]
			if def["terrain"] == "land" and not planet.is_land(target):
				return "target is not land"
			if def["terrain"] == "water" and not Water.can_be_at(planet, def, target):
				return "target is not open water"
			_spawn(kind, target, str(cmd.get("controller", "")))
			return ""
		Commands.ASSIGN:
			if issuer != Commands.ADMIN:
				return "only admin can assign entities"
			var e := get_entity(int(cmd.get("entity_id", -1)))
			if e == null:
				return "no such entity"
			e.controller = str(cmd.get("controller", ""))
			_emit("entity_assigned", {"entity_id": e.id, "controller": e.controller})
			return ""
		Commands.DESPAWN, Commands.MOVE_TO, Commands.STOP, Commands.SAY:
			var e := get_entity(int(cmd.get("entity_id", -1)))
			if e == null:
				return "no such entity"
			if not can_control(issuer, e):
				return "'%s' may not control entity %d" % [issuer, e.id]
			if type == Commands.DESPAWN:
				entities.erase(e.id)
				_emit("entity_despawned", {"entity_id": e.id, "kind": e.kind})
			elif type == Commands.STOP:
				_stop(e)
			elif type == Commands.SAY:
				var text := str(cmd.get("text", "")).strip_edges()
				if text == "":
					return "nothing to say"
				_emit("entity_said", {"entity_id": e.id, "text": text.left(Commands.MAX_SAY_LENGTH)})
			else:
				if not EntityKinds.KINDS[e.kind]["mobile"]:
					return "entity %d can't move" % e.id
				var target: Variant = Commands.parse_target(cmd.get("target"))
				if target == null:
					return "invalid target"
				e.target_dir = target
				e.has_target = true
				e.best_distance = INF
				e.stuck_ticks = 0
				e.state = "moving"
			return ""
	return "unknown command type '%s'" % type


func _spawn(kind: String, dir: Vector3, controller: String = "") -> Entity:
	var def: Dictionary = EntityKinds.KINDS[kind]
	var e := Entity.new()
	e.id = _next_id
	_next_id += 1
	e.kind = kind
	e.dir = dir.normalized()
	e.position = planet.surface_point(e.dir)
	e.heading = Geo.any_tangent(e.dir)
	e.speed = def["speed"]
	e.brain = def["brain"]
	e.medium = Water.medium(planet, def, e.dir)
	if controller != "":
		e.controller = controller
	elif e.brain != "":
		e.controller = "brain:" + e.brain
	entities[e.id] = e
	_emit("entity_spawned", {"entity_id": e.id, "kind": kind, "controller": e.controller})
	return e


func _spawn_on_random_land(kind: String) -> void:
	var d := planet.random_land_dir(rng)
	if d != Vector3.ZERO:
		_spawn(kind, d)


func _move_entities() -> void:
	var dt := clock.dt()
	for e: Entity in entities.values():
		var def: Dictionary = EntityKinds.KINDS[e.kind]
		if not def["mobile"]:
			continue
		if e.has_target:
			var step: float = e.speed * Water.speed_factor(planet, def, e.dir) * dt
			var next := Geo.rotate_toward(e.dir, e.target_dir, step / planet.radius)
			var why := Water.blocked_reason(planet, def, next)
			if why != "":
				_stop(e)
				_emit("entity_blocked", {"entity_id": e.id, "reason": why})
			else:
				var moved := next - e.dir
				if moved.length_squared() > 1e-14:
					e.heading = moved.normalized()
				e.dir = next
				if next == e.target_dir:
					_stop(e)
					_emit("entity_arrived", {"entity_id": e.id})
		if def["terrain"] == "water":
			# Floating things drift with the current, whatever else they are doing.
			var drift := Water.current_at(planet, e.dir) * dt
			var drifted := (e.dir + drift / planet.radius).normalized()
			if drift != Vector3.ZERO and Water.can_be_at(planet, def, drifted):
				e.dir = drifted
		e.position = planet.surface_point(e.dir)

	Physics.resolve(self)

	for e: Entity in entities.values():
		var def: Dictionary = EntityKinds.KINDS[e.kind]
		if not def["mobile"]:
			continue
		e.medium = Water.medium(planet, def, e.dir)
		if e.has_target:
			_check_stuck(e, def)


## A walker pressing against something it can't get past (a tree, a crowd)
## eventually stops. If it is already close to where it was going, that counts
## as arriving.
func _check_stuck(e: Entity, def: Dictionary) -> void:
	var dist := e.dir.angle_to(e.target_dir) * planet.radius
	if dist < e.best_distance - 0.05:
		e.best_distance = dist
		e.stuck_ticks = 0
		return
	e.stuck_ticks += 1
	if e.stuck_ticks < STUCK_TICKS:
		return
	_stop(e)
	if dist <= float(def["radius"]) * 4.0:
		_emit("entity_arrived", {"entity_id": e.id})
	else:
		_emit("entity_blocked", {"entity_id": e.id, "reason": "something in the way"})


func _stop(e: Entity) -> void:
	e.has_target = false
	e.state = "idle"
	e.stuck_ticks = 0


# --- saving and loading -------------------------------------------------------

## Everything needed to rebuild this exact world later. Players and AI agents
## are not saved (they are people and programs, not world state): their
## bodies are kept, handed back to their built-in brain or to nobody.
func save_state() -> Dictionary:
	var list: Array = []
	for e: Entity in entities.values():
		var ctrl := e.controller
		if not ctrl.begins_with("brain:"):
			ctrl = "brain:" + e.brain if e.brain != "" else ""
		list.append({
			"id": e.id, "kind": e.kind, "dir": e.dir, "heading": e.heading, "speed": e.speed,
			"controller": ctrl, "brain": e.brain, "state": e.state, "has_target": e.has_target,
			"target_dir": e.target_dir, "data": e.data.duplicate(true),
			"stuck_ticks": e.stuck_ticks, "best_distance": e.best_distance,
		})
	return {
		"version": SAVE_VERSION, "config": _config.duplicate(true), "tick": clock.tick,
		"next_id": _next_id, "rng_state": rng.state, "entities": list,
	}


## Replace this world with a saved one. Returns "" or what was wrong with it.
func load_state(save: Dictionary) -> String:
	if int(save.get("version", 0)) != SAVE_VERSION:
		return "this save is from a different version of the game"
	if not save.get("config") is Dictionary or not save.get("entities") is Array:
		return "the save file is damaged"
	_configure(save["config"])
	clock.tick = int(save.get("tick", 0))
	_next_id = int(save.get("next_id", 1))
	rng.state = int(save.get("rng_state", rng.state))
	entities.clear()
	_pending.clear()
	events.clear()
	for d: Variant in save["entities"]:
		if not d is Dictionary or not EntityKinds.KINDS.has(str(d.get("kind", ""))) \
				or not d.get("dir") is Vector3 or not (d["dir"] as Vector3).is_normalized():
			continue
		var e := Entity.new()
		e.id = int(d["id"])
		e.kind = str(d["kind"])
		e.dir = d.get("dir", Vector3.UP)   # exactly as saved (re-normalizing would nudge it)
		e.position = planet.surface_point(e.dir)
		e.heading = d.get("heading", Geo.any_tangent(e.dir))
		e.speed = float(d.get("speed", EntityKinds.KINDS[e.kind]["speed"]))
		e.controller = str(d.get("controller", ""))
		e.brain = str(d.get("brain", ""))
		e.state = str(d.get("state", "idle"))
		e.has_target = bool(d.get("has_target", false))
		e.target_dir = d.get("target_dir", Vector3.ZERO)
		e.data = d.get("data", {})
		e.stuck_ticks = int(d.get("stuck_ticks", 0))
		e.best_distance = float(d.get("best_distance", INF))
		e.medium = Water.medium(planet, EntityKinds.KINDS[e.kind], e.dir)
		entities[e.id] = e
		_next_id = maxi(_next_id, e.id + 1)
	_emit("world_loaded", {"entities": entities.size()})
	return ""


func _emit(type: String, payload: Dictionary) -> void:
	payload["type"] = type
	payload["tick"] = clock.tick
	events.append(payload)
