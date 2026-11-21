## Runs agents next to the authoritative simulation.
##
## Lives on the server (SimServer owns one). After every simulation tick it:
##   1. collects the events each agent should know about,
##   2. asks agents whose turn it is to decide (observe -> decide),
##   3. turns their actions into commands under the agent's own controller
##      name (act). Commands are applied on the next tick, like everyone's.
##
## Typical use:
##
##   var runtime := AgentRuntime.new(sim)
##   runtime.spawn_agent(PatrolAgent.new(), "explorer", {"lat": 5, "lon": 5})
##   # ...then call runtime.tick() after every sim.step()
##
## Agents get bodies in one of two ways:
##   spawn_agent(agent, kind, where)  a new entity is spawned for the agent;
##   attach(agent, entity_id)         the agent takes over an existing one.
## Either way the entity's controller becomes "agent:<name>:<n>", so the
## agent (and only the agent, plus admin) can command it.
extends RefCounted

const Commands = preload("res://sim/commands.gd")
const Actions = preload("res://agents/actions.gd")
const Observation = preload("res://agents/observation.gd")

## Emitted for things a host may want to log or show.
signal agent_attached(agent: RefCounted, entity_id: int)
signal agent_detached(agent: RefCounted, entity_id: int, reason: String)

const MAX_EVENTS_PER_OBSERVATION := 20

var sim: RefCounted
var agents: Array = []          ## attached agents, in attach order

var _submit: Callable
var _counter := 0
var _waiting_for_spawn: Dictionary = {}   ## controller -> agent
var _inbox: Dictionary = {}               ## agent -> Array of events since last decision
var _feedback: Dictionary = {}            ## agent -> Array of error strings
var _just_attached: Array = []
var _previous_controller: Dictionary = {}  ## agent -> controller to restore on detach


## `submit` is where commands go; defaults to sim.submit_command. A server
## passes its own submit_command so agent commands take the same path as
## everyone else's.
func _init(p_sim: RefCounted, submit: Callable = Callable()) -> void:
	sim = p_sim
	_submit = submit if submit.is_valid() else sim.submit_command


## Spawn a new entity for `agent`. It appears (and the agent starts deciding)
## after the next tick. Returns the controller name the body will have.
func spawn_agent(agent: RefCounted, kind: String, where: Variant) -> String:
	var ctrl := _new_controller(agent)
	_waiting_for_spawn[ctrl] = agent
	_submit.call(Commands.spawn(Commands.ADMIN, kind, where, ctrl))
	return ctrl


## Give `agent` control of an existing entity. Returns false if it doesn't exist
## or already belongs to another agent.
func attach(agent: RefCounted, entity_id: int) -> bool:
	var e = sim.get_entity(entity_id)
	if e == null or agent_for(entity_id) != null:
		return false
	var ctrl := _new_controller(agent)
	_submit.call(Commands.assign(Commands.ADMIN, entity_id, ctrl))
	_previous_controller[agent] = e.controller
	_bind(agent, entity_id, ctrl)
	return true


## Take the body away from `agent`. With despawn=true the body is removed,
## otherwise it is handed back to admin and just stands there.
func detach(agent: RefCounted, despawn: bool = false, reason: String = "detached") -> void:
	for ctrl in _waiting_for_spawn.keys():
		if _waiting_for_spawn[ctrl] == agent:
			_waiting_for_spawn.erase(ctrl)
	if not agents.has(agent):
		return
	var id: int = agent.entity_id
	if sim.get_entity(id) != null:
		if despawn:
			_submit.call(Commands.despawn(Commands.ADMIN, id))
		else:
			_submit.call(Commands.stop(Commands.ADMIN, id))
			_submit.call(Commands.assign(Commands.ADMIN, id, str(_previous_controller.get(agent, ""))))
	_unbind(agent, reason)


## Let go of every agent without touching the world (used when a saved world
## is loaded: the old bodies are gone). Bridge agents may join again.
func clear(reason: String) -> void:
	_waiting_for_spawn.clear()
	for agent in agents.duplicate():
		_unbind(agent, reason)


func agent_for(entity_id: int) -> RefCounted:
	for a in agents:
		if a.entity_id == entity_id:
			return a
	return null


## The observation `agent` would get right now (handy for debugging and UIs).
func observe(agent: RefCounted) -> Dictionary:
	var e = sim.get_entity(agent.entity_id)
	if e == null:
		return {}
	return Observation.build(sim, e, agent.sight_range, _inbox.get(agent, []), _feedback.get(agent, []))


## Call once after every sim.step().
func tick() -> void:
	_route_events(sim.events)
	for agent in _just_attached:
		if agents.has(agent):
			agent.on_attached(observe(agent))
	_just_attached.clear()
	for agent in agents.duplicate():
		_run(agent)


# --- internals --------------------------------------------------------------

func _run(agent: RefCounted) -> void:
	var e = sim.get_entity(agent.entity_id)
	if e == null:
		_unbind(agent, "body gone")
		return
	var t: int = sim.clock.tick
	# Stagger agents so they don't all think on the same tick.
	var every := maxi(1, int(agent.think_every))
	if not agent.busy and (t + agent.entity_id) % every == 0:
		var obs := observe(agent)
		_inbox[agent] = []
		_feedback[agent] = []
		var decision: Variant = agent.decide(obs)
		if decision != null:
			agent.act(decision)
	var actions: Array = agent.take_actions()
	if actions.is_empty():
		return
	var result := Actions.translate(sim, agent.controller, agent.entity_id, actions)
	for cmd in result["commands"]:
		_submit.call(cmd)
	(_feedback[agent] as Array).append_array(result["errors"])


## Hand each event to the agents that would notice it.
func _route_events(events: Array) -> void:
	for ev: Dictionary in events:
		if ev["type"] == "entity_spawned":
			var ctrl := str(ev.get("controller", ""))
			if _waiting_for_spawn.has(ctrl):
				var agent: RefCounted = _waiting_for_spawn[ctrl]
				_waiting_for_spawn.erase(ctrl)
				_bind(agent, int(ev["entity_id"]), ctrl)
		elif ev["type"] == "command_rejected":
			var cmd: Dictionary = ev.get("command", {})
			var ctrl := str(cmd.get("issuer", ""))
			if cmd.get("type") == Commands.SPAWN and _waiting_for_spawn.has(str(cmd.get("controller", ""))):
				var agent: RefCounted = _waiting_for_spawn[str(cmd.get("controller", ""))]
				_waiting_for_spawn.erase(str(cmd.get("controller", "")))
				var why := "spawn refused: %s" % ev["reason"]
				agent.on_detached(why)
				agent_detached.emit(agent, -1, why)
				continue
			for a in agents:
				if a.controller == ctrl:
					_deliver(a, {"type": "action_refused", "command": cmd.get("type", ""), "reason": ev["reason"]})
			continue
		for a in agents:
			if _concerns(a, ev):
				_deliver(a, _describe(a, ev))


func _concerns(agent: RefCounted, ev: Dictionary) -> bool:
	var id := int(ev.get("entity_id", -1))
	if id == agent.entity_id:
		return true
	if ev["type"] in ["entity_said", "entity_spawned"]:
		var me = sim.get_entity(agent.entity_id)
		var other = sim.get_entity(id)
		if me == null or other == null:
			return false
		return me.dir.angle_to(other.dir) * sim.planet.radius <= agent.sight_range
	return false


## Rephrase an event from the agent's point of view.
func _describe(agent: RefCounted, ev: Dictionary) -> Dictionary:
	var id := int(ev.get("entity_id", -1))
	if ev["type"] == "entity_said":
		if id == agent.entity_id:
			return {"type": "you_said", "text": ev["text"], "tick": ev["tick"]}
		return {"type": "heard", "from": id, "text": ev["text"], "tick": ev["tick"]}
	var out := ev.duplicate(true)
	out.erase("controller")
	return out


func _deliver(agent: RefCounted, ev: Dictionary) -> void:
	var box: Array = _inbox.get(agent, [])
	box.append(ev)
	while box.size() > MAX_EVENTS_PER_OBSERVATION:
		box.pop_front()
	_inbox[agent] = box


func _new_controller(agent: RefCounted) -> String:
	_counter += 1
	var n := str(agent.agent_name).strip_edges().replace(":", "_")
	return "agent:%s:%d" % [n if n != "" else "agent", _counter]


func _bind(agent: RefCounted, entity_id: int, ctrl: String) -> void:
	agent.entity_id = entity_id
	agent.controller = ctrl
	agent.busy = false
	agents.append(agent)
	_inbox[agent] = []
	_feedback[agent] = []
	_just_attached.append(agent)
	agent_attached.emit(agent, entity_id)


func _unbind(agent: RefCounted, reason: String) -> void:
	var id: int = agent.entity_id
	agents.erase(agent)
	_inbox.erase(agent)
	_feedback.erase(agent)
	_just_attached.erase(agent)
	_previous_controller.erase(agent)
	agent.on_detached(reason)
	agent.entity_id = -1
	agent_detached.emit(agent, id, reason)
