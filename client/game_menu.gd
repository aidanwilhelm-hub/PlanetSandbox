## The in-game menu (Esc): resume, settings, save, load, and leaving.
##
## Saving and loading only show up when the world runs on this computer
## (playing alone, hosting, or watching a local AI world).
extends CanvasLayer

const Settings = preload("res://client/settings.gd")

signal closed
signal exit_to_menu
signal quit_game

const SLOTS := 3

var link: Node
var _panel: PanelContainer
var _pages: Dictionary = {}     ## name -> VBoxContainer
var _status: Label


func _init(p_link: Node) -> void:
	link = p_link
	layer = 10
	visible = false


func _ready() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.45)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_panel = PanelContainer.new()
	_panel.custom_minimum_size = Vector2(460, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.07, 0.09, 0.13, 0.97)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(22)
	style.border_color = Color(0.3, 0.45, 0.6)
	style.set_border_width_all(1)
	_panel.add_theme_stylebox_override("panel", style)
	center.add_child(_panel)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	_panel.add_child(outer)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Color(1.0, 0.8, 0.45))
	_build_main(outer)
	_build_settings(outer)
	_build_slots(outer, "save")
	_build_slots(outer, "load")
	outer.add_child(_status)


func open() -> void:
	visible = true
	_status.text = ""
	_show("main")


func close() -> void:
	if visible:
		visible = false
		closed.emit()


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if (event as InputEventKey).keycode == KEY_ESCAPE:
			if _pages["main"].visible:
				close()
			else:
				_show("main")
		get_viewport().set_input_as_handled()   # the world doesn't get keys while the menu is up


func _show(page: String) -> void:
	for p: String in _pages:
		_pages[p].visible = p == page
	if page == "save" or page == "load":
		_refresh_slots(page)


# --- pages -------------------------------------------------------------------

func _build_main(parent: Control) -> void:
	var page := _page(parent, "main", "Menu")
	_button(page, "Resume", close)
	_button(page, "Settings", _show.bind("settings"))
	if link.can_save():
		_button(page, "Save game", _show.bind("save"))
		_button(page, "Load game", _show.bind("load"))
	_button(page, "Leave game" if link.role == "player" or link.role == "spectator" and link.networked
		else "Exit to main menu", func() -> void: exit_to_menu.emit())
	_button(page, "Quit to desktop", func() -> void: quit_game.emit())


func _build_settings(parent: Control) -> void:
	var page := _page(parent, "settings", "Settings")
	_slider(page, "Mouse sensitivity", "mouse_sensitivity", 0.25, 3.0, 0.05)
	_slider(page, "Field of view", "fov", 40.0, 90.0, 1.0)
	_toggle(page, "Fullscreen", "fullscreen")
	_toggle(page, "Shadows", "shadows")
	_toggle(page, "Speech bubbles over heads", "speech_bubbles")
	_toggle(page, "Show the controls list", "show_help")
	_toggle(page, "First person when zoomed all the way in", "first_person")
	_button(page, "Back", _show.bind("main"))


func _build_slots(parent: Control, kind: String) -> void:
	var page := _page(parent, kind, "Save game" if kind == "save" else "Load game")
	for i in range(1, SLOTS + 1):
		var b := _button(page, "Slot %d" % i, _use_slot.bind(kind, i))
		b.name = "Slot%d" % i
	_button(page, "Back", _show.bind("main"))


func _refresh_slots(kind: String) -> void:
	for i in range(1, SLOTS + 1):
		var b := _pages[kind].get_node("Slot%d" % i) as Button
		var info: String = link.slot_info(i)
		b.text = "Slot %d:  %s" % [i, info if info != "" else "empty"]
		b.disabled = kind == "load" and info == ""


func _use_slot(kind: String, slot: int) -> void:
	if kind == "save":
		var err: String = link.save_slot(slot)
		_status.text = "Saved to slot %d." % slot if err == "" else "Couldn't save: %s" % err
		_refresh_slots("save")
	else:
		var err: String = link.load_slot(slot)
		if err == "":
			_status.text = ""
			close()
		else:
			_status.text = "Couldn't load: %s" % err


# --- widgets -------------------------------------------------------------------

func _page(parent: Control, page_name: String, title: String) -> VBoxContainer:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 26)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	page.add_child(t)
	parent.add_child(page)
	_pages[page_name] = page
	return page


func _button(parent: Control, text: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	parent.add_child(b)
	return b


func _toggle(parent: Control, text: String, key: String) -> void:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = bool(Settings.get_value(key))
	c.toggled.connect(func(on: bool) -> void: Settings.set_value(key, on))
	parent.add_child(c)


func _slider(parent: Control, text: String, key: String, lo: float, hi: float, step: float) -> void:
	var row := HBoxContainer.new()
	var l := Label.new()
	l.custom_minimum_size = Vector2(170, 0)
	row.add_child(l)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = float(Settings.get_value(key))
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var show := func(v: float) -> void: l.text = "%s  %s" % [text, str(snappedf(v, step))]
	show.call(s.value)
	s.value_changed.connect(func(v: float) -> void:
		show.call(v)
		Settings.set_value(key, v))
	row.add_child(s)
	parent.add_child(row)
