## The camera. Normally it orbits the planet: drag with the left mouse button
## (or use the arrow keys) to spin, scroll to zoom.
##
## Zoom all the way in while something is selected (or while you have your own
## explorer) and it switches to first person: you look out of that thing's
## eyes, drag to look around, and scroll out to go back to orbiting.
extends Camera3D

const Settings = preload("res://client/settings.gd")

signal first_person_changed(on: bool)

const MIN_HEIGHT := 12.0
const MAX_HEIGHT := 700.0
const EYE_HEIGHT := 2.6

var planet_radius := 100.0
var yaw := 0.6
var pitch := 0.35
var distance := 280.0
var drag_distance := 0.0   ## how far the mouse moved during the current left-drag

var first_person := false
## What first person looks out of. The view keeps this up to date.
var fp_subject: Node3D
var fp_yaw := 0.0          ## looking left/right of the subject's facing
var fp_pitch := -0.1       ## looking up/down

var _dragging := false


func _ready() -> void:
	near = 0.3
	far = 5000.0
	fov = float(Settings.get_value("fov"))
	_apply()


## Point the camera at a world position (keeps the current zoom).
func focus_on(point: Vector3) -> void:
	if first_person:
		return
	var d := point.normalized()
	pitch = asin(clampf(d.y, -0.99, 0.99))
	yaw = atan2(d.x, d.z)
	_apply()


func set_first_person(on: bool) -> void:
	if on == first_person:
		return
	if on and not is_instance_valid(fp_subject):
		return
	first_person = on
	near = 0.05 if on else 0.3
	if on:
		fp_yaw = 0.0
		fp_pitch = -0.1
	else:
		if is_instance_valid(fp_subject):
			var p := fp_subject.position
			distance = planet_radius + MIN_HEIGHT + 4.0
			pitch = asin(clampf(p.normalized().y, -0.99, 0.99))
			yaw = atan2(p.x, p.z)
		_apply()
	first_person_changed.emit(on)


## Which way first person is looking, along the ground (for "walk forward").
func look_direction() -> Vector3:
	return -global_transform.basis.z


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			_dragging = mb.pressed
			if mb.pressed:
				drag_distance = 0.0
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(0.88)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(1.0 / 0.88)
	elif event is InputEventMouseMotion and _dragging:
		var mm := event as InputEventMouseMotion
		drag_distance += mm.relative.length()
		var user_sens: float = Settings.get_value("mouse_sensitivity")
		if first_person:
			fp_yaw -= mm.relative.x * 0.005 * user_sens
			fp_pitch = clampf(fp_pitch - mm.relative.y * 0.005 * user_sens, -1.3, 1.3)
			return
		var sens := (0.004 * (distance - planet_radius) / 150.0 + 0.0005) * user_sens
		yaw -= mm.relative.x * sens
		pitch = clampf(pitch + mm.relative.y * sens, -1.5, 1.5)
		_apply()


func _process(delta: float) -> void:
	var spin := Vector2(
		Input.get_axis("ui_left", "ui_right"),
		Input.get_axis("ui_down", "ui_up"))
	if first_person:
		if not is_instance_valid(fp_subject) or not fp_subject.is_inside_tree():
			set_first_person(false)
			return
		fp_yaw -= spin.x * 1.8 * delta
		fp_pitch = clampf(fp_pitch + spin.y * 1.2 * delta, -1.3, 1.3)
		_apply_first_person()
		return
	if spin != Vector2.ZERO:
		var rate := 1.2 * (distance - planet_radius) / 150.0 + 0.1
		yaw += spin.x * rate * delta
		pitch = clampf(pitch + spin.y * rate * delta, -1.5, 1.5)
		_apply()


func _zoom(factor: float) -> void:
	if first_person:
		if factor > 1.0:
			set_first_person(false)
		return
	var height := distance - planet_radius
	if factor < 1.0 and height <= MIN_HEIGHT + 0.01 and Settings.get_value("first_person"):
		set_first_person(true)
		return
	height = clampf(height * factor, MIN_HEIGHT, MAX_HEIGHT)
	distance = planet_radius + height
	_apply()


func _apply() -> void:
	position = Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * distance
	look_at(Vector3.ZERO, Vector3.UP)


## Stand at the subject's eyes, facing where it faces (plus where you look).
func _apply_first_person() -> void:
	var b := fp_subject.global_transform.basis
	var up := fp_subject.position.normalized()
	var forward := -b.z
	forward = (forward - up * forward.dot(up)).normalized()
	if forward.length_squared() < 0.5:
		forward = up.cross(Vector3.RIGHT).normalized()
	forward = forward.rotated(up, fp_yaw)
	var right := forward.cross(up).normalized()
	forward = forward.rotated(right, fp_pitch)
	position = fp_subject.position + up * EYE_HEIGHT - forward * 0.2
	look_at(position + forward, up)
