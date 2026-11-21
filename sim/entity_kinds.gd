## The catalog of things that can exist in the world.
##
## To add a new kind of entity, add an entry here (and, optionally, a look for
## it in client/entity_visuals.gd). Brains are named in sim/simulation.gd.
extends RefCounted

const KINDS := {
	# A small animal that wanders during the day and stays put at night.
	"critter": {"speed": 3.0, "mobile": true, "needs_land": true, "brain": "wander"},
	# A walker with no built-in brain. You (and, later, AI agents) give it orders.
	"explorer": {"speed": 6.0, "mobile": true, "needs_land": true, "brain": ""},
	# Scenery. Doesn't move.
	"tree": {"speed": 0.0, "mobile": false, "needs_land": true, "brain": ""},
}
