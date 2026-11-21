## A tiny built-in behavior: wander around nearby during the day, stop at night.
##
## Brains don't touch entities directly. Each tick they look at the world and
## return commands, exactly like a player or an AI agent would. That keeps the
## rules in one place (the Simulation) and is the pattern step 2 builds on.
extends RefCounted

const Commands = preload("res://sim/commands.gd")
const Geo = preload("res://sim/geo.gd")

const ISSUER := "brain:wander"
const WANDER_CHANCE := 0.01        ## chance per tick to start walking when idle
const MAX_WANDER_DEG := 6.0        ## how far a single walk may go


func think(sim: RefCounted, e: RefCounted) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if not sim.clock.is_daylight(e.dir):
		if e.has_target:
			out.append(Commands.stop(ISSUER, e.id))
		return out
	if not e.has_target and sim.rng.randf() < WANDER_CHANCE:
		var d := Geo.random_dir_near(sim.rng, e.dir, deg_to_rad(MAX_WANDER_DEG))
		if sim.planet.is_land(d):
			out.append(Commands.move_to(ISSUER, e.id, d))
	return out
