## The things an agent can do, and how each turns into a simulation command.
##
## Actions are small JSON-friendly dictionaries. The agent never says WHICH
## entity to move: it always means its own body, so an agent can't puppet
## anyone else even if it tries.
##
##   {"action": "move_to", "lat": 10, "lon": 45}          walk to a place
##   {"action": "move", "bearing": 90, "distance": 20}     walk 20 m east
##   {"action": "approach", "entity_id": 12}               walk to where entity 12 is now
##   {"action": "stop"}                                    stand still
##   {"action": "say", "text": "hello!"}                   speak (nearby agents hear it)
##   {"action": "wait"}                                    do nothing this time
##
## translate() returns {"commands": [...], "errors": [...]}. Errors are sent
## back to the agent in its next observation under "feedback".
extends RefCounted

const Commands = preload("res://sim/commands.gd")
const Geo = preload("res://sim/geo.gd")

const ACTIONS := ["move_to", "move", "approach", "stop", "say", "wait"]
## A single "move" may not go further than this (meters).
const MAX_MOVE_DISTANCE := 200.0


static func translate(sim: RefCounted, issuer: String, entity_id: int, actions: Array) -> Dictionary:
	var commands: Array = []
	var errors: Array = []
	var e = sim.get_entity(entity_id)
	for a in actions:
		if not a is Dictionary:
			errors.append("action must be an object, got: %s" % str(a).left(60))
			continue
		var name := str(a.get("action", ""))
		match name:
			"move_to":
				if not (a.has("lat") and a.has("lon")):
					errors.append("move_to: needs 'lat' and 'lon'")
					continue
				commands.append(Commands.move_to(issuer, entity_id, {"lat": _num(a["lat"]), "lon": _num(a["lon"])}))
			"move":
				if e == null:
					continue
				if not (a.has("bearing") and a.has("distance")):
					errors.append("move: needs 'bearing' (degrees, 0 = north) and 'distance' (meters)")
					continue
				var dist := clampf(_num(a["distance"]), 0.0, MAX_MOVE_DISTANCE)
				var to := Geo.destination(e.dir, _num(a["bearing"]), dist / sim.planet.radius)
				commands.append(Commands.move_to(issuer, entity_id, to))
			"approach":
				var other = sim.get_entity(int(_num(a.get("entity_id", -1))))
				if other == null:
					errors.append("approach: no entity with id %s" % str(a.get("entity_id")))
					continue
				commands.append(Commands.move_to(issuer, entity_id, other.dir))
			"stop":
				commands.append(Commands.stop(issuer, entity_id))
			"say":
				commands.append(Commands.say(issuer, entity_id, str(a.get("text", ""))))
			"wait", "":
				pass
			_:
				errors.append("unknown action '%s' (known: %s)" % [name, ", ".join(ACTIONS)])
	return {"commands": commands, "errors": errors}


## Numbers from JSON arrive as floats; from GDScript they may be ints or strings.
static func _num(v: Variant) -> float:
	if v is float or v is int:
		return float(v)
	if v is String and (v as String).is_valid_float():
		return (v as String).to_float()
	return NAN
