## Base class for an AI-driven NPC: observe the world, decide, act.
##
## Write a new agent by extending this script and overriding decide():
##
##   extends "res://agents/agent.gd"
##
##   func decide(obs: Dictionary) -> Variant:
##       if not obs["time"]["is_day"]:
##           return {"action": "stop"}
##       return {"action": "move", "bearing": randf() * 360.0, "distance": 10}
##
## Then hand it to the AgentRuntime (see agents/agent_runtime.gd):
##
##   runtime.spawn_agent(MyAgent.new(), "explorer", {"lat": 10, "lon": 20})
##
## `obs` is plain JSON-safe data (see agents/observation.gd). decide() returns
## one action, an Array of actions, or null for "keep doing what I'm doing".
## The action list is in agents/actions.gd.
##
## Slow deciders (an LLM call, a remote process): set `busy = true`, return
## null, and call act() whenever the answer arrives. The runtime won't ask a
## busy agent for another decision until act() clears the flag.
##
## Agents never touch the simulation. Everything they do becomes an ordinary
## command, issued under their own controller name, so they can only ever move
## their own body and go through the same rules as a human player.
extends RefCounted

## Shown in logs and used to build the controller name ("agent:<name>:<n>").
var agent_name := "agent"
## Decide every N simulation ticks (20 ticks = 1 simulated second).
var think_every := 10
## How far the agent can see and hear, in meters along the surface.
var sight_range := 30.0

## Filled in by the runtime.
var entity_id := -1
var controller := ""

## True while a decision is in flight. Set it yourself for async agents.
var busy := false

var _outbox: Array = []


## Override this. Return an action Dictionary, an Array of them, or null.
func decide(_obs: Dictionary) -> Variant:
	return null


## Called once the agent has a body in the world. Optional.
func on_attached(_obs: Dictionary) -> void:
	pass


## Called when the agent loses its body (despawned, detached, disconnected). Optional.
func on_detached(_reason: String) -> void:
	pass


## Queue actions to perform. Safe to call at any time, from any callback.
## Also clears `busy`, so the agent will be asked to decide again.
func act(actions: Variant) -> void:
	busy = false
	if actions == null:
		return
	if actions is Dictionary:
		_outbox.append(actions)
	elif actions is Array:
		_outbox.append_array(actions)


## Used by the runtime. Returns and clears everything queued by act().
func take_actions() -> Array:
	var out := _outbox
	_outbox = []
	return out
