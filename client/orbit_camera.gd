## A camera that orbits the planet. Drag with the left mouse button (or use the
## arrow keys) to spin, scroll to zoom.
extends Camera3D

var planet_radius := 100.0
var yaw := 0.6
var pitch := 0.35
var distance := 280.0
var drag_distance := 0.0   ## how far the mouse moved during the current left-drag

var _dragging := false


func _ready() -> void:
	near = 0.3
	far = 5000.0
	fov = 55.0
	_apply()


## Point the camera at a world position (keeps the current zoom).
func focus_on(point: Vector3) -> void:
	var d := point.normalized()
	pitch = asin(clampf(d.y, -0.99, 0.99))
	yaw = atan2(d.x, d.z)
	_apply()


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
		var sens := 0.004 * (distance - planet_radius) / 150.0 + 0.0005
		yaw -= mm.relative.x * sens
		pitch = clampf(pitch + mm.relative.y * sens, -1.5, 1.5)
		_apply()


func _process(delta: float) -> void:
	var spin := Vector2(
		Input.get_axis("ui_left", "ui_right"),
		Input.get_axis("ui_down", "ui_up"))
	if spin != Vector2.ZERO:
		var rate := 1.2 * (distance - planet_radius) / 150.0 + 0.1
		yaw += spin.x * rate * delta
		pitch = clampf(pitch + spin.y * rate * delta, -1.5, 1.5)
		_apply()


func _zoom(factor: float) -> void:
	var height := clampf((distance - planet_radius) * factor, 12.0, 700.0)
	distance = planet_radius + height
	_apply()


func _apply() -> void:
	position = Vector3(cos(pitch) * sin(yaw), sin(pitch), cos(pitch) * cos(yaw)) * distance
	look_at(Vector3.ZERO, Vector3.UP)
