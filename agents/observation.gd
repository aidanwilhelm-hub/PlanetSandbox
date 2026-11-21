## Builds what an agent can perceive: a small, JSON-safe Dictionary.
##
## Everything is numbers, strings, bools, arrays and dictionaries (no Vector3),
## so the same observation can be handed to a GDScript agent, sent over a
## socket to a Python script, or pasted into an LLM prompt unchanged.
##
## {
##   "tick": 1200,
##   "time": {"day": 0, "local_hour": 14.5, "is_day": true},
##   "self": {"id": 7, "kind": "explorer", "lat": 12.3, "lon": -40.1,
##            "heading": 90.0, "state": "moving", "biome": "grass",
##            "elevation": 1.8, "target": {"lat": 13.0, "lon": -39.0, "distance": 25.0}},
##   "nearby": [ {"id": 3, "kind": "critter", "distance": 8.2, "bearing": 45.0,
##                "lat": .., "lon": .., "state": "idle", "controlled_by_agent": false} ],
##   "surroundings": [ {"direction": "N", "bearing": 0, "walkable": 30.0, "biome": "forest"}, ...],
##   "events": [ {"type": "entity_arrived", ...}, {"type": "heard", "from": 3, "text": "hi"} ],
##   "feedback": ["move: missing 'bearing'"],
##   "world": {"radius": 100.0, "sight_range": 30.0}
## }
##
## Units: distances in meters along the surface, angles in degrees,
## bearings are compass bearings (0 = north, 90 = east).
extends RefCounted

const Geo = preload("res://sim/geo.gd")

const MAX_NEARBY := 12
const COMPASS := ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
const WALK_SAMPLES := 6


static func build(sim: RefCounted, e: RefCounted, sight_range: float,
		events: Array = [], feedback: Array = []) -> Dictionary:
	var planet = sim.planet
	var ll := Geo.lat_lon_from_dir(e.dir)
	var me := {
		"id": e.id,
		"kind": e.kind,
		"lat": _r(ll.x),
		"lon": _r(ll.y),
		"heading": _r(Geo.heading_to_bearing_deg(e.dir, e.heading)),
		"state": e.state,
		"biome": planet.biome_at(e.dir),
		"elevation": _r(planet.height_at(e.dir)),
		"target": null,
	}
	if e.has_target:
		var tl := Geo.lat_lon_from_dir(e.target_dir)
		me["target"] = {"lat": _r(tl.x), "lon": _r(tl.y),
			"distance": _r(e.dir.angle_to(e.target_dir) * planet.radius)}

	return {
		"tick": sim.clock.tick,
		"time": {
			"day": sim.clock.day_number(),
			"local_hour": _r(sim.clock.local_hour(e.dir)),
			"is_day": sim.clock.is_daylight(e.dir),
		},
		"self": me,
		"nearby": _nearby(sim, e, sight_range),
		"surroundings": _surroundings(planet, e.dir, sight_range),
		"events": events.duplicate(true),
		"feedback": feedback.duplicate(),
		"world": {"radius": planet.radius, "sight_range": sight_range},
	}


static func _nearby(sim: RefCounted, e: RefCounted, sight_range: float) -> Array:
	var r: float = sim.planet.radius
	var max_angle := sight_range / r
	var found: Array = []
	for other in sim.entities.values():
		if other.id == e.id:
			continue
		var angle: float = e.dir.angle_to(other.dir)
		if angle > max_angle:
			continue
		var ll := Geo.lat_lon_from_dir(other.dir)
		found.append({
			"id": other.id,
			"kind": other.kind,
			"distance": _r(angle * r),
			"bearing": _r(Geo.bearing_deg(e.dir, other.dir)),
			"lat": _r(ll.x),
			"lon": _r(ll.y),
			"state": other.state,
			"controlled_by_agent": str(other.controller).begins_with("agent:"),
		})
	found.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return a["distance"] < b["distance"] or (a["distance"] == b["distance"] and a["id"] < b["id"]))
	return found.slice(0, MAX_NEARBY)


## For each compass direction: how far you can walk before hitting water
## (up to sight range), and the biome where that stretch ends ("ocean" if
## water is what stopped it).
static func _surroundings(planet: RefCounted, dir: Vector3, sight_range: float) -> Array:
	var out: Array = []
	for i in COMPASS.size():
		var bearing := i * 45.0
		var walkable := 0.0
		var biome := ""
		for s in range(1, WALK_SAMPLES + 1):
			var dist := sight_range * s / WALK_SAMPLES
			var p := Geo.destination(dir, bearing, dist / planet.radius)
			biome = planet.biome_at(p)
			if not planet.is_land(p):
				break
			walkable = dist
		out.append({"direction": COMPASS[i], "bearing": bearing, "walkable": _r(walkable), "biome": biome})
	return out


## Round to 0.1 so observations stay short and readable.
static func _r(x: float) -> float:
	return snappedf(x, 0.1)
