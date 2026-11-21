## Example: a curious explorer.
##
## By day it walks toward whatever it hasn't greeted yet, says hello, and
## otherwise roams in a direction with plenty of land ahead. At night it stops
## and rests. If someone talks to it, it answers.
##
## It shows every part of an observation: time, nearby things, surroundings
## (to avoid the sea), events (arrivals, things it heard) and feedback.
extends "res://agents/agent.gd"

const GREET_DISTANCE := 4.0
## Answer the same speaker at most once in this many ticks (30 s), so two
## curious agents don't greet each other back and forth forever.
const ANSWER_COOLDOWN_TICKS := 600

var _greeted := {}            ## entity id -> true (or "gave up")
var _chasing := -1
var _answered := {}           ## speaker id -> tick we last answered them
var _rng := RandomNumberGenerator.new()


func _init(rng_seed: int = 1) -> void:
	agent_name = "curious"
	_rng.seed = rng_seed


func decide(obs: Dictionary) -> Variant:
	var me: Dictionary = obs["self"]
	var actions: Array = []

	for ev: Dictionary in obs["events"]:
		if ev["type"] == "entity_blocked" and _chasing != -1:
			_greeted[_chasing] = true     # can't reach it (water in the way); forget it
			_chasing = -1
		elif ev["type"] == "heard":
			var from: int = ev["from"]
			if int(ev["tick"]) - int(_answered.get(from, -ANSWER_COOLDOWN_TICKS)) >= ANSWER_COOLDOWN_TICKS:
				_answered[from] = int(ev["tick"])
				actions.append({"action": "say", "text": "Hi #%d! I'm out exploring." % from})

	if not obs["time"]["is_day"]:
		if me["state"] == "moving":
			actions.append({"action": "stop"})
			actions.append({"action": "say", "text": "Getting dark. Resting here."})
		return actions

	# Something new and close? Say hello. Something new but further? Go look.
	for other: Dictionary in obs["nearby"]:
		if _greeted.has(other["id"]) or other["kind"] == "tree":
			continue
		if other["distance"] <= GREET_DISTANCE:
			_greeted[other["id"]] = true
			actions.append({"action": "stop"})
			actions.append({"action": "say", "text": "Hello, %s #%d!" % [other["kind"], other["id"]]})
			return actions
		_chasing = other["id"]
		actions.append({"action": "approach", "entity_id": other["id"]})
		return actions

	_chasing = -1
	# Nothing interesting: roam toward the direction with the most land.
	if me["state"] != "moving":
		var best: Dictionary = obs["surroundings"][_rng.randi() % 8]
		for s: Dictionary in obs["surroundings"]:
			if s["walkable"] > best["walkable"] or (s["walkable"] == best["walkable"] and _rng.randf() < 0.3):
				best = s
		if best["walkable"] > 0.0:
			actions.append({"action": "move", "bearing": best["bearing"], "distance": best["walkable"]})
		else:
			actions.append({"action": "say", "text": "Water all around me!"})
	return actions
