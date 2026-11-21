## Commands: the ONLY way anything changes the world.
##
## Types: spawn, despawn, move_to, stop, say, assign.
##
## A command is a plain Dictionary, so it can come from the local player, a
## network packet, a built-in brain, or an AI agent, and all of them are
## validated by the same rules in Simulation._apply_command().
##
##   {"type": "move_to", "issuer": "admin", "entity_id": 3, "target": {"lat": 10, "lon": 45}}
##
## "target" may be a Vector3 direction, [x, y, z], or {"lat": deg, "lon": deg}.
extends RefCounted

const Geo = preload("res://sim/geo.gd")

const MOVE_TO := "move_to"
const STOP := "stop"
const SPAWN := "spawn"
const DESPAWN := "despawn"
const SAY := "say"           ## an entity speaks; nearby agents hear it
const ASSIGN := "assign"     ## admin hands an entity to a controller (player, agent...)

## Longest thing an entity may say in one command.
const MAX_SAY_LENGTH := 200

## The issuer allowed to do anything (the local player in single-player,
## the host/server operator in multiplayer).
const ADMIN := "admin"


static func move_to(issuer: String, entity_id: int, target: Variant) -> Dictionary:
	return {"type": MOVE_TO, "issuer": issuer, "entity_id": entity_id, "target": target}


static func stop(issuer: String, entity_id: int) -> Dictionary:
	return {"type": STOP, "issuer": issuer, "entity_id": entity_id}


static func spawn(issuer: String, kind: String, target: Variant, controller: String = "") -> Dictionary:
	return {"type": SPAWN, "issuer": issuer, "kind": kind, "target": target, "controller": controller}


static func despawn(issuer: String, entity_id: int) -> Dictionary:
	return {"type": DESPAWN, "issuer": issuer, "entity_id": entity_id}


static func say(issuer: String, entity_id: int, text: String) -> Dictionary:
	return {"type": SAY, "issuer": issuer, "entity_id": entity_id, "text": text}


## controller "" means "admin only" again.
static func assign(issuer: String, entity_id: int, controller: String) -> Dictionary:
	return {"type": ASSIGN, "issuer": issuer, "entity_id": entity_id, "controller": controller}


## Turn any accepted target format into a unit direction, or null if invalid.
static func parse_target(value: Variant) -> Variant:
	var v := Vector3.ZERO
	if value is Vector3:
		v = value
	elif value is Array and value.size() == 3:
		v = Vector3(float(value[0]), float(value[1]), float(value[2]))
	elif value is Dictionary and value.has("lat") and value.has("lon"):
		var lat := float(value["lat"])
		if not (lat >= -90.0 and lat <= 90.0):  # also rejects NaN
			return null
		v = Geo.dir_from_lat_lon(lat, float(value["lon"]))
	else:
		return null
	if not v.is_finite() or v.length_squared() < 1e-12:
		return null
	return v.normalized()
