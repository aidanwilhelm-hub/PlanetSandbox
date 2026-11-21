## Runs the authoritative Simulation at a fixed rate and publishes snapshots.
##
## Today the "client" (the 3D view) lives in the same program and talks to this
## node directly. In step 3 a network layer will sit between them: remote
## players' commands arrive here through submit_command(), and the snapshots
## from `snapshot_published` get sent back over the wire. Nothing in the
## simulation needs to change for that.
extends Node

const Simulation = preload("res://sim/simulation.gd")

## Emitted after the sim advances. Carries a full snapshot plus every event
## that happened since the previous publish.
signal snapshot_published(snapshot: Dictionary)

const MAX_STEPS_PER_FRAME := 64
const MIN_SPEED := 0.25
const MAX_SPEED := 32.0

var sim: Simulation
var paused := false
var speed := 1.0   ## 1.0 = real time; 4.0 = four times faster

var _accumulator := 0.0   ## ticks owed to the simulation
var _events_since_publish: Array = []


func start(config: Dictionary = {}, populate: bool = true) -> void:
	sim = Simulation.new(config)
	if populate:
		sim.populate()
	_events_since_publish.append_array(sim.events)
	sim.events.clear()
	publish()


## Entry point for every command, from any source.
func submit_command(cmd: Dictionary) -> void:
	sim.submit_command(cmd)


func set_paused(value: bool) -> void:
	paused = value
	publish()


func set_speed(value: float) -> void:
	speed = clampf(value, MIN_SPEED, MAX_SPEED)
	publish()


## Advance exactly one tick (handy while paused).
func step_once() -> void:
	sim.step()
	_events_since_publish.append_array(sim.events)
	publish()


func publish() -> void:
	var snap := sim.snapshot()
	snap["events"] = _events_since_publish
	snap["server"] = {"paused": paused, "speed": speed}
	_events_since_publish = []
	snapshot_published.emit(snap)


func _process(delta: float) -> void:
	if sim == null or paused:
		return
	# Count in ticks (not seconds) and allow a hair of float error.
	_accumulator += delta * speed * sim.clock.tick_rate
	var steps := 0
	while _accumulator >= 1.0 - 1e-6 and steps < MAX_STEPS_PER_FRAME:
		sim.step()
		_events_since_publish.append_array(sim.events)
		_accumulator -= 1.0
		steps += 1
	if steps == MAX_STEPS_PER_FRAME:
		_accumulator = 0.0  # running behind; drop the backlog instead of spiraling
	if steps > 0:
		publish()
