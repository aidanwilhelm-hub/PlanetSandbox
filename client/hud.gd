## On-screen text: clock, selection info, recent events, chat, the player
## list and the controls.
extends CanvasLayer

signal chat_submitted(text: String)
signal kick_pressed(peer_id: int)
signal mod_toggled(peer_id: int, on: bool)

const HELP_ADMIN := """Left-drag / arrows: spin   Scroll: zoom
Left-click: select   Right-click: move selected here
N: spawn critter   T: tree   E: explorer   A: AI explorer   Del: remove selected
F: focus selected   Tab: follow next AI   G: auto-follow
Space: pause   + / -: speed   . : step (paused)   Enter: chat   P: players"""
const HELP_PLAYER := """Left-drag / arrows: spin   Scroll: zoom
Right-click: walk there   F: find your explorer   Enter: chat
Left-click: select   Tab: follow next AI   G: auto-follow   P: players"""
const HELP_CREATIVE := """
N: spawn critter   T: tree   E: explorer   A: AI explorer   Del: remove selected"""
const HELP_MOD := """
Space: pause   + / -: speed   . : step (paused)"""
const HELP_SPECTATOR := """Left-drag / arrows: spin   Scroll: zoom
Tab: follow next AI   G: auto-follow on/off   Esc: stop following
Left-click: select   F: focus selected   P: players"""
const HELP_LOCAL_TIME := """
Space: pause   + / -: speed   . : step (paused)"""

const MAX_LOG_LINES := 8
const MAX_CHAT_LINES := 12

var _status: Label
var _selected: Label
var _log: Label
var _chat: Label
var _help: Label
var _chat_input: LineEdit
var _players_panel: PanelContainer
var _players_box: VBoxContainer
var _lines: Array[String] = []
var _chat_lines: Array[String] = []


func _ready() -> void:
	_status = _make_label(Vector2(16, 12), 20)
	_selected = _make_label(Vector2(16, 112), 16)
	_log = _make_label(Vector2.ZERO, 14)
	_log.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 16)
	_log.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_help = _make_label(Vector2.ZERO, 14)
	_help.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	_help.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_help.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	_chat = _make_label(Vector2.ZERO, 15)
	_chat.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	_chat.offset_bottom = -52
	_chat.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_chat.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_chat.custom_minimum_size = Vector2(460, 0)
	_chat.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART

	_chat_input = LineEdit.new()
	_chat_input.placeholder_text = "Say something (Enter to send, Esc to cancel)"
	_chat_input.max_length = 200
	_chat_input.custom_minimum_size = Vector2(460, 0)
	_chat_input.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	_chat_input.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_chat_input.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_chat_input.visible = false
	_chat_input.text_submitted.connect(_on_chat_submitted)
	_chat_input.gui_input.connect(_on_chat_key)
	add_child(_chat_input)

	_players_panel = PanelContainer.new()
	_players_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_MINSIZE, 16)
	_players_panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_players_panel.visible = false
	_players_box = VBoxContainer.new()
	_players_panel.add_child(_players_box)
	add_child(_players_panel)


func set_help(link: Node) -> void:
	var text := HELP_SPECTATOR
	match link.role:
		"admin":
			text = HELP_ADMIN
		"player":
			text = HELP_PLAYER
			if link.can_edit_world():
				text += HELP_CREATIVE
			if link.can_control_time():
				text += HELP_MOD
		"spectator":
			if link.can_control_time():
				text += HELP_LOCAL_TIME
		_:
			text = ""
	_help.text = text


func show_status(snap: Dictionary, link: Node) -> void:
	var t: Dictionary = snap["time"]
	var srv: Dictionary = snap.get("server", {})
	var flag := "  [PAUSED]" if srv.get("paused", false) else ""
	var who := "You: %s" % link.role_label()
	if link.networked:
		who += "   %s mode" % str(link.mode).capitalize()
	if link.networked:
		who += "   %d connected" % link.players.size()
	_status.text = "Day %d  %s (at longitude 0)   speed x%s%s\ntick %d   %d entities\n%s" % [
		t["day"], _fmt_hour(t["hour_at_lon0"]), str(srv.get("speed", 1.0)), flag,
		snap["tick"], snap["entities"].size(), who]


func show_selected(e: Variant, local_hour: float, daylight: bool, following: bool = false) -> void:
	if e == null:
		_selected.text = "Nothing selected (left-click an entity)"
		return
	var ctrl: String = e["controller"]
	_selected.text = "%s #%d  %s  (%s)\nlat %.1f  lon %.1f   local time %s, %s\ncontrolled by: %s" % [
		"Following" if following else "Selected", e["id"], e["kind"], e["state"], e["lat"], e["lon"],
		_fmt_hour(local_hour), "day" if daylight else "night", ctrl if ctrl != "" else "admin only"]


func log_line(text: String) -> void:
	_lines.append(text)
	while _lines.size() > MAX_LOG_LINES:
		_lines.pop_front()
	_log.text = "\n".join(_lines)


func chat_line(text: String) -> void:
	_chat_lines.append(text)
	while _chat_lines.size() > MAX_CHAT_LINES:
		_chat_lines.pop_front()
	_chat.text = "\n".join(_chat_lines)


func open_chat() -> void:
	_chat_input.visible = true
	_chat_input.text = ""
	_chat_input.grab_focus()


func is_chat_open() -> bool:
	return _chat_input.visible


func toggle_players() -> void:
	_players_panel.visible = not _players_panel.visible


## Rebuild the player list. `can_mod`: show Make mod buttons (host);
## `can_kick`: show Kick buttons (host and moderators).
func show_players(list: Array, can_mod: bool, can_kick: bool) -> void:
	for c in _players_box.get_children():
		c.queue_free()
	var title := Label.new()
	title.text = "Players (%d)   P to hide" % list.size()
	_players_box.add_child(title)
	if list.is_empty():
		var none := Label.new()
		none.text = "Nobody else is connected."
		_players_box.add_child(none)
	for p: Dictionary in list:
		var row := HBoxContainer.new()
		var l := Label.new()
		l.text = "%s  (%s%s)  %d ms" % [p["name"], p["role"], ", mod" if p["mod"] else "", p["ping"]]
		l.custom_minimum_size = Vector2(260, 0)
		row.add_child(l)
		var id: int = p["peer_id"]
		if can_mod and p["role"] == "player":
			var b := Button.new()
			b.text = "Remove mod" if p["mod"] else "Make mod"
			b.focus_mode = Control.FOCUS_NONE
			var on: bool = not p["mod"]
			b.pressed.connect(func() -> void: mod_toggled.emit(id, on))
			row.add_child(b)
		if can_kick and (can_mod or not p["mod"]):
			var k := Button.new()
			k.text = "Kick"
			k.focus_mode = Control.FOCUS_NONE
			k.pressed.connect(func() -> void: kick_pressed.emit(id))
			row.add_child(k)
		_players_box.add_child(row)


func _on_chat_submitted(text: String) -> void:
	_close_chat()
	if text.strip_edges() != "":
		chat_submitted.emit(text.strip_edges())


func _on_chat_key(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and (event as InputEventKey).keycode == KEY_ESCAPE:
		_close_chat()
		get_viewport().set_input_as_handled()


func _close_chat() -> void:
	_chat_input.visible = false
	_chat_input.release_focus()


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
