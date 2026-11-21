## Camera direction for watching AI agents: Tab jumps to the next AI explorer,
## G turns the auto-director on or off. The auto-director cuts to whoever just
## spoke (when it has stayed on someone for a while) and otherwise moves on to
## another agent every SWITCH_EVERY seconds.
extends Node

const SWITCH_EVERY := 15.0
const MIN_STAY := 5.0

var view: Node3D      ## the WorldView
var auto := false

var _since_switch := 0.0
var _rng := RandomNumberGenerator.new()


func _init(p_view: Node3D, start_auto: bool) -> void:
	view = p_view
	auto = start_auto
	_rng.randomize()


func next_ai() -> void:
	var ids: Array = view.ai_entity_ids()
	if ids.is_empty():
		view.hud.log_line("No AI explorers to follow yet.")
		return
	var at := ids.find(view.follow_id)
	_switch_to(ids[(at + 1) % ids.size()])


func toggle_auto() -> void:
	auto = not auto
	view.hud.log_line("Auto-follow %s" % ("on: the camera picks who to watch" if auto else "off"))
	if auto:
		_since_switch = SWITCH_EVERY   # pick someone right away


## Called for every line of speech the view receives.
func on_speech(entity_id: int) -> void:
	if auto and _since_switch >= MIN_STAY and entity_id != view.follow_id \
			and view.ai_entity_ids().has(entity_id):
		_switch_to(entity_id)


func _process(delta: float) -> void:
	_since_switch += delta
	if not auto:
		return
	if _since_switch >= SWITCH_EVERY or (view.follow_id == -1 and _since_switch >= 1.0):
		var ids: Array = view.ai_entity_ids()
		if ids.is_empty():
			_since_switch = 0.0
			return
		if ids.size() > 1:
			ids.erase(view.follow_id)
		_switch_to(ids[_rng.randi() % ids.size()])


func _switch_to(id: int) -> void:
	_since_switch = 0.0
	view.follow(id)
