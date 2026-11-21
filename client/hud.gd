## On-screen text: clock, selection info, recent events, and controls.
extends CanvasLayer

const HELP := """Left-drag / arrows: spin   Scroll: zoom
Left-click: select   Right-click: move selected here
N: spawn critter   T: tree   E: explorer   Del: remove selected
F: focus selected   Space: pause   + / -: speed   . : step (paused)"""

var _status: Label
var _selected: Label
var _log: Label
var _lines: Array[String] = []


func _ready() -> void:
	_status = _make_label(Vector2(16, 12), 20)
	_selected = _make_label(Vector2(16, 70), 16)
	_log = _make_label(Vector2.ZERO, 14)
	_log.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 16)
	_log.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var help := _make_label(Vector2.ZERO, 14)
	help.text = HELP
	help.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	help.grow_horizontal = Control.GROW_DIRECTION_BEGIN


func show_status(snap: Dictionary) -> void:
	var t: Dictionary = snap["time"]
	var srv: Dictionary = snap.get("server", {})
	var flag := "  [PAUSED]" if srv.get("paused", false) else ""
	_status.text = "Day %d  %s (at longitude 0)   speed x%s%s\ntick %d   %d entities" % [
		t["day"], _fmt_hour(t["hour_at_lon0"]), str(srv.get("speed", 1.0)), flag,
		snap["tick"], snap["entities"].size()]


func show_selected(e: Variant, local_hour: float, daylight: bool) -> void:
	if e == null:
		_selected.text = "Nothing selected (left-click an entity)"
		return
	_selected.text = "Selected #%d  %s  (%s)\nlat %.1f  lon %.1f   local time %s, %s\ncontrolled by: %s" % [
		e["id"], e["kind"], e["state"], e["lat"], e["lon"], _fmt_hour(local_hour),
		"day" if daylight else "night", e["controller"] if e["controller"] != "" else "admin only"]


func log_line(text: String) -> void:
	_lines.append(text)
	while _lines.size() > 8:
		_lines.pop_front()
	_log.text = "\n".join(_lines)


static func _fmt_hour(h: float) -> String:
	return "%02d:%02d" % [int(h), int(fmod(h, 1.0) * 60.0)]


func _make_label(pos: Vector2, size: int) -> Label:
	var l := Label.new()
	l.position = pos
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	add_child(l)
	return l
