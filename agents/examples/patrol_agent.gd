## Example: walk a loop of waypoints forever. About as simple as an agent gets.
extends "res://agents/agent.gd"

## Places to visit, in order, as {"lat": .., "lon": ..}. Leave empty to patrol
## a small square around wherever the agent first appears.
var waypoints: Array = []
var _next := 0


func _init(p_waypoints: Array = []) -> void:
	agent_name = "patrol"
	waypoints = p_waypoints


func on_attached(obs: Dictionary) -> void:
	if waypoints.is_empty():
		var lat: float = obs["self"]["lat"]
		var lon: float = obs["self"]["lon"]
		for corner in [[2, 0], [2, 2], [0, 2], [0, 0]]:
			waypoints.append({"lat": lat + corner[0], "lon": lon + corner[1]})


func decide(obs: Dictionary) -> Variant:
	if obs["self"]["state"] == "moving":
		return null                       # still walking; let it be
	var wp: Dictionary = waypoints[_next]
	_next = (_next + 1) % waypoints.size()
	return {"action": "move_to", "lat": wp["lat"], "lon": wp["lon"]}
