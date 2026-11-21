## The 3D view: draws snapshots from the server and turns your clicks and key
## presses into commands.
##
## It never changes the simulation directly. Everything goes through
## server.submit_command(), the same door a remote player or an AI agent
## will use, so the view can later run on a different machine unchanged.
extends Node3D

const Planet = preload("res://sim/planet.gd")
const Commands = preload("res://sim/commands.gd")
const MeshBuilder = preload("res://client/planet_mesh_builder.gd")
const EntityVisuals = preload("res://client/entity_visuals.gd")
const OrbitCamera = preload("res://client/orbit_camera.gd")
const Hud = preload("res://client/hud.gd")

## In single-player the person at the keyboard is the admin.
const ISSUER := Commands.ADMIN
const CLICK_PICK_PIXELS := 22.0

var server: Node
var planet: Planet          ## a local copy, rebuilt from the seed, for drawing and mouse picking
var camera: OrbitCamera
var sun: DirectionalLight3D
var hud: Hud
var selected_id := -1

var _visuals: Dictionary = {}   ## entity id -> Node3D
var _latest: Dictionary = {}    ## entity id -> latest entity dict from the server
var _snapshot: Dictionary = {}
var _ring: MeshInstance3D
var _focused_once := false


func setup(p_server: Node) -> void:
	server = p_server
	_build_scene()
	server.snapshot_published.connect(_on_snapshot)
	server.publish()


func _build_scene() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.01, 0.015, 0.03)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.35, 0.42, 0.6)
	env.ambient_light_energy = 0.25
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	add_child(world_env)

	sun = DirectionalLight3D.new()
	sun.light_energy = 1.4
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 600.0
	add_child(sun)

	camera = OrbitCamera.new()
	add_child(camera)
	camera.make_current()

	hud = Hud.new()
	add_child(hud)

	_ring = MeshInstance3D.new()
	var torus := TorusMesh.new()
	torus.inner_radius = 1.4
	torus.outer_radius = 1.8
	_ring.mesh = torus
	var ring_mat := StandardMaterial3D.new()
	ring_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	ring_mat.albedo_color = Color(1.0, 0.9, 0.2)
	_ring.material_override = ring_mat
	_ring.visible = false
	add_child(_ring)


func _build_planet(info: Dictionary) -> void:
	planet = Planet.new(int(info["seed"]), float(info["radius"]), float(info["max_height"]))
	var terrain := MeshInstance3D.new()
	terrain.name = "Terrain"
	terrain.mesh = MeshBuilder.build(planet)
	add_child(terrain)
	add_child(MeshBuilder.build_ocean(planet))
	camera.planet_radius = planet.radius
	camera.distance = planet.radius * 2.4


# --- drawing snapshots -------------------------------------------------------

func _on_snapshot(snap: Dictionary) -> void:
	if planet == null:
		_build_planet(snap["planet"])
	_snapshot = snap

	var sun_dir: Vector3 = snap["time"]["sun_direction"]
	var up_hint := Vector3.UP if absf(sun_dir.y) < 0.95 else Vector3.RIGHT
	sun.basis = Basis.looking_at(-sun_dir, up_hint)

	var seen := {}
	for e: Dictionary in snap["entities"]:
		var id: int = e["id"]
		seen[id] = true
		_latest[id] = e
		if not _visuals.has(id):
			var node := EntityVisuals.create(e["kind"])
			add_child(node)
			node.position = e["position"]
			_visuals[id] = node
			if not _focused_once and e["kind"] == "explorer":
				_focused_once = true
				camera.focus_on(node.position)
	for id: int in _visuals.keys():
		if not seen.has(id):
			_visuals[id].queue_free()
			_visuals.erase(id)
			_latest.erase(id)
			if id == selected_id:
				_select(-1)

	for ev: Dictionary in snap["events"]:
		_log_event(ev)
	hud.show_status(snap)
	_refresh_selected_info()


func _process(delta: float) -> void:
	var blend := clampf(delta * 12.0, 0.0, 1.0)
	for id: int in _visuals:
		var node: Node3D = _visuals[id]
		var e: Dictionary = _latest[id]
		node.position = node.position.lerp(e["position"], blend)
		_orient(node, e["heading"])
	if selected_id != -1 and _visuals.has(selected_id):
		var n: Node3D = _visuals[selected_id]
		_ring.transform = n.transform
		_ring.position += n.basis.y * 0.15


## Stand the node up on the surface and face it along `heading`.
func _orient(node: Node3D, heading: Vector3) -> void:
	var up := node.position.normalized()
	var fwd := heading - up * heading.dot(up)
	if fwd.length_squared() < 1e-6:
		fwd = up.cross(Vector3.UP if absf(up.y) < 0.9 else Vector3.RIGHT)
	node.basis = Basis.looking_at(fwd.normalized(), up)


func _log_event(ev: Dictionary) -> void:
	match ev["type"]:
		"entity_spawned":
			hud.log_line("+ %s #%d appeared" % [ev["kind"], ev["entity_id"]])
		"entity_despawned":
			hud.log_line("- %s #%d removed" % [ev["kind"], ev["entity_id"]])
		"command_rejected":
			hud.log_line("! command refused: %s" % ev["reason"])
		"entity_arrived":
			if ev["entity_id"] == selected_id:
				hud.log_line("#%d arrived" % ev["entity_id"])
		"entity_blocked":
			if ev["entity_id"] == selected_id:
				hud.log_line("#%d stopped: %s" % [ev["entity_id"], ev["reason"]])


# --- input -> commands --------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if planet == null:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and camera.drag_distance < 6.0:
			_select(_pick_entity(mb.position))
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed and selected_id != -1:
			var target: Variant = _pick_ground(mb.position)
			if target != null:
				server.submit_command(Commands.move_to(ISSUER, selected_id, target))
	elif event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		match key:
			KEY_N:
				_spawn_at_mouse("critter")
			KEY_T:
				_spawn_at_mouse("tree")
			KEY_E:
				_spawn_at_mouse("explorer")
			KEY_DELETE, KEY_BACKSPACE, KEY_X:
				if selected_id != -1:
					server.submit_command(Commands.despawn(ISSUER, selected_id))
			KEY_F:
				if _visuals.has(selected_id):
					camera.focus_on(_visuals[selected_id].position)
			KEY_SPACE:
				server.set_paused(not server.paused)
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				server.set_speed(server.speed * 2.0)
			KEY_MINUS, KEY_KP_SUBTRACT:
				server.set_speed(server.speed / 2.0)
			KEY_PERIOD:
				if server.paused:
					server.step_once()
			KEY_ESCAPE:
				_select(-1)


func _spawn_at_mouse(kind: String) -> void:
	var target: Variant = _pick_ground(get_viewport().get_mouse_position())
	if target == null:
		hud.log_line("! point the mouse at the planet to spawn")
		return
	server.submit_command(Commands.spawn(ISSUER, kind, target))


func _select(id: int) -> void:
	selected_id = id
	_ring.visible = id != -1
	_refresh_selected_info()


func _refresh_selected_info() -> void:
	if selected_id == -1 or not _latest.has(selected_id):
		hud.show_selected(null, 0.0, false)
		return
	var e: Dictionary = _latest[selected_id]
	var t: Dictionary = _snapshot["time"]
	var sun_dir: Vector3 = t["sun_direction"]
	var hour := fposmod(float(t["hour_at_lon0"]) / 24.0 + float(e["lon"]) / 360.0, 1.0) * 24.0
	hud.show_selected(e, hour, (e["dir"] as Vector3).dot(sun_dir) > 0.0)


## The visible entity closest to the cursor, or -1.
func _pick_entity(screen_pos: Vector2) -> int:
	var best := -1
	var best_dist := CLICK_PICK_PIXELS
	var cam_pos := camera.global_position
	for id: int in _visuals:
		var node: Node3D = _visuals[id]
		var p := node.position + node.basis.y * 1.0
		if camera.is_position_behind(p):
			continue
		# hidden behind the planet?
		var to_p := p - cam_pos
		var t_hit := _ray_sphere(cam_pos, to_p.normalized(), planet.radius * 0.97)
		if t_hit >= 0.0 and t_hit < to_p.length():
			continue
		var d := camera.unproject_position(p).distance_to(screen_pos)
		if d < best_dist:
			best_dist = d
			best = id
	return best


## Where the mouse ray hits the ground, as a unit direction, or null.
func _pick_ground(screen_pos: Vector2) -> Variant:
	var origin := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	var outer := planet.radius + planet.max_height
	var t := _ray_sphere(origin, dir, outer)
	if t < 0.0:
		return null
	var step := 0.4
	var t_end := t + outer * 2.0
	while t < t_end:
		var p := origin + dir * t
		if p.length() <= planet.radius + maxf(planet.height_at(p), 0.0):
			# refine between the previous step and this one
			var lo := t - step
			var hi := t
			for i in 10:
				var mid := (lo + hi) * 0.5
				var q := origin + dir * mid
				if q.length() <= planet.radius + maxf(planet.height_at(q), 0.0):
					hi = mid
				else:
					lo = mid
			return (origin + dir * hi).normalized()
		t += step
	return null


## Distance along the ray to the first hit with a sphere at the origin, or -1.
static func _ray_sphere(origin: Vector3, dir: Vector3, radius: float) -> float:
	var b := origin.dot(dir)
	var c := origin.dot(origin) - radius * radius
	var disc := b * b - c
	if disc < 0.0:
		return -1.0
	var s := sqrt(disc)
	if -b - s >= 0.0:
		return -b - s
	if -b + s >= 0.0:
		return -b + s
	return -1.0
