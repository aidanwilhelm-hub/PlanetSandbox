## The start screen: play alone, watch an AI world, host a game, or join one.
## Emits `chosen` with the same options the command line accepts (see main.gd).
extends CanvasLayer

const Protocol = preload("res://net/protocol.gd")

signal chosen(options: Dictionary)

var _name: LineEdit
var _host_port: SpinBox
var _host_password: LineEdit
var _host_mode: OptionButton
var _join_address: LineEdit
var _join_password: LineEdit
var _join_watch: CheckBox
var _status: Label


func _ready() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.02, 0.03, 0.06)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(520, 0)
	box.add_theme_constant_override("separation", 10)
	center.add_child(box)

	var title := Label.new()
	title.text = "Planet Sandbox"
	title.add_theme_font_size_override("font_size", 40)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)

	_name = _field(box, "Your name", "player")

	var solo := HBoxContainer.new()
	box.add_child(solo)
	_button(solo, "Play alone", func() -> void: chosen.emit({"launch": "single"}))
	_button(solo, "Watch an AI world", func() -> void: chosen.emit({"launch": "watch"}))

	box.add_child(HSeparator.new())
	_heading(box, "Host a game (others on your network can join)")
	var port_row := HBoxContainer.new()
	box.add_child(port_row)
	var pl := Label.new()
	pl.text = "Port"
	pl.custom_minimum_size = Vector2(140, 0)
	port_row.add_child(pl)
	_host_port = SpinBox.new()
	_host_port.min_value = 1024
	_host_port.max_value = 65535
	_host_port.value = Protocol.DEFAULT_PORT
	port_row.add_child(_host_port)
	_host_mode = OptionButton.new()
	_host_mode.add_item("Creative")
	_host_mode.add_item("Survival")
	_host_mode.tooltip_text = "Creative: players may spawn and remove things.\nSurvival: players only control their own explorer."
	port_row.add_child(_host_mode)
	_host_password = _field(box, "Password", "", true)
	_button(box, "Host", _host)

	box.add_child(HSeparator.new())
	_heading(box, "Join a game")
	_join_address = _field(box, "Address", "127.0.0.1:%d" % Protocol.DEFAULT_PORT)
	_join_password = _field(box, "Password", "", true)
	_join_watch = CheckBox.new()
	_join_watch.text = "Just watch (spectator)"
	box.add_child(_join_watch)
	_button(box, "Join", _join)

	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Color(1.0, 0.75, 0.4))
	box.add_child(_status)


func show_status(text: String) -> void:
	_status.text = text


func _host() -> void:
	chosen.emit({
		"launch": "host", "name": _player_name(), "port": int(_host_port.value),
		"password": _host_password.text,
		"server_mode": Protocol.MODE_CREATIVE if _host_mode.selected == 0 else Protocol.MODE_SURVIVAL,
	})


func _join() -> void:
	chosen.emit({
		"launch": "join", "name": _player_name(), "address": _join_address.text.strip_edges(),
		"password": _join_password.text, "spectator": _join_watch.button_pressed,
	})


func _player_name() -> String:
	return Protocol.clean_name(_name.text)


func _field(parent: Control, label: String, value: String, secret: bool = false) -> LineEdit:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(140, 0)
	row.add_child(l)
	var e := LineEdit.new()
	e.text = value
	e.secret = secret
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(e)
	return e


func _heading(parent: Control, text: String) -> void:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", 18)
	parent.add_child(l)


func _button(parent: Control, text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(action)
	parent.add_child(b)
