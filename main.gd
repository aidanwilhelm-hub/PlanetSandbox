## Program entry point.
##
## Normal run: starts the simulation server AND the 3D view in one window.
## Server-only run (no window): add `-- --server` to the command line.
## Optional: `-- --seed=42` picks a different planet.
extends Node

const SimServer = preload("res://server/sim_server.gd")
const WorldView = preload("res://client/world_view.gd")

var server: SimServer


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var config := {}
	for a in args:
		if a.begins_with("--seed="):
			config["seed"] = int(a.trim_prefix("--seed="))

	server = SimServer.new()
	server.name = "SimServer"
	add_child(server)
	server.start(config)

	if "--server" in args:
		_run_headless()
	else:
		var view := WorldView.new()
		view.name = "WorldView"
		add_child(view)
		view.setup(server)


# --- server-only mode -------------------------------------------------------

var _last_report_second := -1


func _run_headless() -> void:
	Engine.max_fps = 60
	print("Planet Sandbox server running (seed %d). Press Ctrl+C to stop." % server.sim.planet.world_seed)
	server.snapshot_published.connect(_report)


func _report(snap: Dictionary) -> void:
	for ev: Dictionary in snap["events"]:
		if ev["type"] in ["entity_spawned", "entity_despawned", "command_rejected"]:
			print("  event: ", ev)
	var second := int(snap["time"]["elapsed"])
	if second / 5 == _last_report_second / 5:
		return
	_last_report_second = second
	var hour: float = snap["time"]["hour_at_lon0"]
	var moving := 0
	for e: Dictionary in snap["entities"]:
		if e["state"] == "moving":
			moving += 1
	print("Day %d %02d:%02d | tick %d | %d entities (%d moving)" % [
		snap["time"]["day"], int(hour), int(fmod(hour, 1.0) * 60.0),
		snap["tick"], snap["entities"].size(), moving])
