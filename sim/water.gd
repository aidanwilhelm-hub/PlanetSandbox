## Water rules: where things may be, how fast they move there, and currents.
##
##   * Land walkers wade through shallow water (up to WADE_DEPTH deep) at
##     half speed and stop where it gets deeper.
##   * Floating things (rafts) need at least FLOAT_DEPTH of water under them,
##     stop at the shore, and drift with the currents all the time.
##   * Currents come from the planet's seed like the terrain, so every machine
##     agrees on them. They are strongest in deep water and fade near the shore.
##
## Pure functions of the planet; no state.
extends RefCounted

const Geo = preload("res://sim/geo.gd")

const WADE_DEPTH := 1.0        ## meters of water a walker can wade through
const FLOAT_DEPTH := 0.4       ## meters of water a raft needs
const WADE_SPEED := 0.5        ## speed multiplier while wading
const MAX_CURRENT := 1.2       ## meters per second, in the open sea


static func depth(planet: RefCounted, dir: Vector3) -> float:
	return -planet.height_at(dir)


## May something of this kind stand (or float) at `dir`?
static func can_be_at(planet: RefCounted, kind_def: Dictionary, dir: Vector3) -> bool:
	if kind_def["terrain"] == "water":
		return depth(planet, dir) >= FLOAT_DEPTH
	return depth(planet, dir) < WADE_DEPTH


## Why something can't go to `dir`, or "" if it can.
static func blocked_reason(planet: RefCounted, kind_def: Dictionary, dir: Vector3) -> String:
	if can_be_at(planet, kind_def, dir):
		return ""
	return "land ahead" if kind_def["terrain"] == "water" else "water ahead"


## "dry", "wading" or "floating".
static func medium(planet: RefCounted, kind_def: Dictionary, dir: Vector3) -> String:
	if kind_def["terrain"] == "water":
		return "floating"
	return "wading" if depth(planet, dir) > 0.0 else "dry"


static func speed_factor(planet: RefCounted, kind_def: Dictionary, dir: Vector3) -> float:
	if kind_def["terrain"] == "land" and depth(planet, dir) > 0.0:
		return WADE_SPEED
	return 1.0


## The water's flow at `dir` in meters per second (a vector along the surface).
static func current_at(planet: RefCounted, dir: Vector3) -> Vector3:
	var d := dir.normalized()
	var deep := clampf(depth(planet, d) / 2.0, 0.0, 1.0)
	if deep <= 0.0:
		return Vector3.ZERO
	var angle: float = planet.current_noise(d, 0) * TAU
	var strength: float = (0.55 + 0.45 * planet.current_noise(d, 1)) * MAX_CURRENT * deep
	var north := Geo.north_at(d)
	var east := north.cross(d)
	return (north * cos(angle) + east * sin(angle)) * strength
