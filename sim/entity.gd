## One thing in the world (a critter, a tree, an explorer...).
##
## Plain data only. Entities never change themselves; the Simulation changes
## them in response to commands.
extends RefCounted

const Geo = preload("res://sim/geo.gd")

var id: int
var kind: String
var dir := Vector3.UP             ## where it is: unit vector from planet center
var position := Vector3.ZERO      ## world-space point on the surface (derived from dir)
var heading := Vector3.FORWARD    ## which way it is facing (tangent to the surface)
var speed := 0.0                  ## surface units per simulated second
var controller := ""              ## who may command it ("" = admin only)
var brain := ""                   ## built-in behavior that drives it, if any
var state := "idle"               ## idle | moving
var has_target := false
var target_dir := Vector3.ZERO
var medium := "dry"               ## dry | wading | floating (see sim/water.gd)
var data: Dictionary = {}         ## free-form extra state for future systems

## Bookkeeping for "stuck" detection; not part of the world's public state.
var stuck_ticks := 0
var best_distance := INF


func to_dict() -> Dictionary:
	var ll := Geo.lat_lon_from_dir(dir)
	return {
		"id": id,
		"kind": kind,
		"position": position,
		"dir": dir,
		"lat": ll.x,
		"lon": ll.y,
		"heading": heading,
		"state": state,
		"medium": medium,
		"controller": controller,
		"brain": brain,
		"target": target_dir if has_target else null,
		"data": data.duplicate(true),
	}
