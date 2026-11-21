## Simple collisions: things that overlap are pushed apart along the ground.
##
## Every entity is a circle on the surface (its kind's "radius"). After
## everything has moved each tick, overlapping pairs are separated: two movable
## things share the push, a movable thing gives way completely to a fixed one
## (a tree), and two fixed things are left alone. A push that would shove a
## walker into deep water, or a raft onto land, is not applied.
##
## A spatial hash keeps this fast: only neighbors in nearby cells are checked.
## Everything here is deterministic (fixed order, no randomness).
extends RefCounted

const EntityKinds = preload("res://sim/entity_kinds.gd")
const Water = preload("res://sim/water.gd")
const Geo = preload("res://sim/geo.gd")

const CELL := 4.0           ## meters; at least the largest radius * 2
const STIFFNESS := 0.8      ## how much of an overlap is fixed per tick (soft feels natural)


## Push overlapping entities apart. Returns how many pairs touched.
static func resolve(sim: RefCounted) -> int:
	var grid: Dictionary = {}
	for e in sim.entities.values():
		var key := _cell(e.position)
		if not grid.has(key):
			grid[key] = []
		grid[key].append(e)

	var pushes: Dictionary = {}   ## entity -> Vector3 (world space)
	var touching := 0
	for e in sim.entities.values():
		var a_def: Dictionary = EntityKinds.KINDS[e.kind]
		var c := _cell(e.position)
		for dx in [-1, 0, 1]:
			for dy in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					var key := c + Vector3i(dx, dy, dz)
					if not grid.has(key):
						continue
					for o in grid[key]:
						if o.id <= e.id:
							continue   # each pair once
						var b_def: Dictionary = EntityKinds.KINDS[o.kind]
						var a_moves: bool = a_def["mobile"]
						var b_moves: bool = b_def["mobile"]
						if not a_moves and not b_moves:
							continue
						var min_dist: float = a_def["radius"] + b_def["radius"]
						var offset: Vector3 = e.position - o.position
						var dist := offset.length()
						if dist >= min_dist:
							continue
						touching += 1
						var normal := offset / dist if dist > 1e-4 else Geo.any_tangent(e.dir)
						var amount := (min_dist - dist) * STIFFNESS
						var a_share := 0.5 if a_moves and b_moves else (1.0 if a_moves else 0.0)
						if a_share > 0.0:
							pushes[e] = pushes.get(e, Vector3.ZERO) + normal * amount * a_share
						if a_share < 1.0:
							pushes[o] = pushes.get(o, Vector3.ZERO) - normal * amount * (1.0 - a_share)

	for e in pushes:
		var push: Vector3 = pushes[e]
		push -= e.dir * push.dot(e.dir)   # along the ground only
		var moved: Vector3 = (e.position + push).normalized()
		if Water.can_be_at(sim.planet, EntityKinds.KINDS[e.kind], moved):
			e.dir = moved
			e.position = sim.planet.surface_point(moved)
	return touching


static func _cell(p: Vector3) -> Vector3i:
	return Vector3i(floori(p.x / CELL), floori(p.y / CELL), floori(p.z / CELL))
