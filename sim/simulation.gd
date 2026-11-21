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

var planet: Planet
var clock: SimClock
var rng := RandomNumberGenerator.new()   ## the ONLY randomness the sim may use
var entities: Dictionary = {}            ## id (int) -> Entity
var events: Array[Dictionary] = []       ## what happened during the latest step()

var _next_id := 1
var _pending: Array[Dictionary] = []
var _brains: Dictionary = {}             ## brain name -> object with think(sim, entity)


## config keys (all optional): seed, radius, max_height, tick_rate, day_length,
## year_length_days, axial_tilt, start_hour
func _init(config: Dictionary = {}) -> void:
	var world_seed := int(config.get("seed", 12345))
	planet = Planet.new(world_seed, float(config.get("radius", 100.0)), float(config.get("max_height", 6.0)))
	clock = SimClock.new(
		int(config.get("tick_rate", 20)),
		float(config.get("day_length", 120.0)),
		float(config.get("year_length_days", 8.0)),
		float(config.get("axial_tilt", 23.0)),
		float(config.get("start_hour", 9.0)))
	rng.seed = world_seed
	register_brain("wander", WanderBrain.new())


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
			if EntityKinds.KINDS[kind]["needs_land"] and not planet.is_land(target):
				return "target is not land"
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
				e.has_target = false
				e.state = "idle"
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
		if not e.has_target:
			continue
		var next := Geo.rotate_toward(e.dir, e.target_dir, e.speed * dt / planet.radius)
		if EntityKinds.KINDS[e.kind]["needs_land"] and not planet.is_land(next):
			e.has_target = false
			e.state = "idle"
			_emit("entity_blocked", {"entity_id": e.id, "reason": "water ahead"})
			continue
		var moved := next - e.dir
		if moved.length_squared() > 1e-14:
			e.heading = moved.normalized()
		e.dir = next
		e.position = planet.surface_point(next)
		if next == e.target_dir:
			e.has_target = false
			e.state = "idle"
			_emit("entity_arrived", {"entity_id": e.id})


func _emit(type: String, payload: Dictionary) -> void:
	payload["type"] = type
	payload["tick"] = clock.tick
	events.append(payload)
