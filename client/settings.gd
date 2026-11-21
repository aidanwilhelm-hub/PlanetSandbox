## Player preferences, kept between runs in user://settings.cfg.
##
## Everything reads Settings.get_value("name"); the in-game menu changes them
## with Settings.set_value(), which saves right away and tells listeners.
extends RefCounted

const PATH := "user://settings.cfg"
const DEFAULTS := {
	"mouse_sensitivity": 1.0,   ## multiplier for camera drag and first-person look
	"fov": 55.0,                ## camera field of view, degrees
	"fullscreen": false,
	"shadows": true,
	"speech_bubbles": true,     ## text over heads when something speaks
	"show_help": true,          ## the controls list in the top-right corner
	"first_person": true,       ## zooming all the way in switches to first person
}

static var _values: Dictionary = {}
static var _loaded := false
static var _listeners: Array[Callable] = []


static func get_value(key: String) -> Variant:
	_ensure_loaded()
	return _values.get(key, DEFAULTS.get(key))


static func set_value(key: String, value: Variant) -> void:
	_ensure_loaded()
	_values[key] = value
	var cfg := ConfigFile.new()
	for k: String in _values:
		cfg.set_value("settings", k, _values[k])
	cfg.save(PATH)
	if key == "fullscreen":
		apply_window()
	for c in _listeners.duplicate():
		if c.is_valid():
			c.call(key)
		else:
			_listeners.erase(c)


## `callback(key: String)` runs whenever a setting changes.
static func listen(callback: Callable) -> void:
	_listeners.append(callback)


static func apply_window() -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if get_value("fullscreen")
		else DisplayServer.WINDOW_MODE_WINDOWED)


static func _ensure_loaded() -> void:
	if _loaded:
		return
	_loaded = true
	_values = DEFAULTS.duplicate()
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		for k: String in DEFAULTS:
			var v: Variant = cfg.get_value("settings", k, DEFAULTS[k])
			if typeof(v) == typeof(DEFAULTS[k]):
				_values[k] = v
