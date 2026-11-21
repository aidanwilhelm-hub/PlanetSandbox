## The catalog of things that can exist in the world.
##
## To add a new kind of entity, add an entry here (and, optionally, a look for
## it in client/entity_visuals.gd). Brains are named in sim/simulation.gd.
##
##   speed     surface meters per simulated second
##   mobile    can it be told to move (and be pushed around)?
##   terrain   "land": walks on land and wades through shallow water;
##             "water": floats, and drifts with the currents
##   radius    meters; things closer than their two radii push each other apart
##   brain     built-in behavior, if any
extends RefCounted

const KINDS := {
	# A small animal that wanders during the day and stays put at night.
	"critter": {"speed": 3.0, "mobile": true, "terrain": "land", "radius": 0.6, "brain": "wander"},
	# A walker with no built-in brain. You (or an AI agent, or a player) give it orders.
	"explorer": {"speed": 6.0, "mobile": true, "terrain": "land", "radius": 0.8, "brain": ""},
	# Scenery. Doesn't move, and walkers bump into it.
	"tree": {"speed": 0.0, "mobile": false, "terrain": "land", "radius": 1.0, "brain": ""},
	# A small raft. Floats, drifts with the currents, and can be steered across water.
	"raft": {"speed": 5.0, "mobile": true, "terrain": "water", "radius": 1.6, "brain": ""},
}
