## The 3D view: draws snapshots and turns your clicks and key presses into
## commands.
##
## It never changes the simulation directly, and never even knows where the
## simulation runs. Everything goes through a server link (client/server_link.gd):
## the same code draws single player, hosting, joining someone else's game,
## and watching an AI world.
extends Node3D

const Planet = preload("res://sim/planet.gd")
const Commands = preload("res://sim/commands.gd")
const Protocol = preload("res://net/protocol.gd")
const MeshBuilder = preload("res://client/planet_mesh_builder.gd")
const EntityVisuals = preload("res://client/entity_visuals.gd")
const OrbitCamera = preload("res://client/orbit_camera.gd")
const Hud = preload("res://client/hud.gd")
const SpectatorControls = preload("res://client/spectator_controls.gd")

const CLICK_PICK_PIXELS := 22.0

var link: Node              ## a server link (local or remote)
var planet: Planet          ## a local copy, rebuilt from the seed, for drawing and mouse picking
var camera: OrbitCamera
var sun: DirectionalLight3D
var hud: Hud
var spectator: SpectatorControls
var selected_id := -1
var follow_id := -1         ## the camera tracks this entity (-1 = free camera)

var _visuals: Dictionary = {}   ## entity id -> Node3D
var _latest: Dictionary = {}    ## entity id -> latest entity dict from the server
var _snapshot: Dictionary = {}
var _ring: MeshInstance3D
var _focused_once := false
var _focus_own := true


func setup(p_link: Node) -> void:
	link = p_link
	_build_scene()
	spectator = SpectatorControls.new(self, link.role == "spectator")
	spectator.name = "SpectatorControls"
	add_child(spectator)
	link.snapshot_published.connect(_on_snapshot)
	link.notice.connect(hud.log_line)
	link.players_changed.connect(func(_list: Array) -> void: _refresh_players())
	link.identity_changed.connect(_on_identity_changed)
	hud.chat_submitted.connect(_send_chat)
	hud.kick_pressed.connect(func(id: int) -> void: link.kick(id))
	hud.mod_toggled.connect(func(id: int, on: bool) -> void: link.set_mod(id, on))
	hud.set_help(link)
	_refresh_players()
	link.publish()


func _on_identity_changed() -> void:
	hud.set_help(link)
	_refresh_players()
	_focus_own = true


func _refresh_players() -> void:
	hud.show_players(link.players, link.is_host, link.is_host or link.is_mod)


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
			if not _focused_once and e["kind"] == "explorer" and link.role != "player":
				_focused_once = true
				camera.focus_on(node.position)
	for id: int in _visuals.keys():
		if not seen.has(id):
			_visuals[id].queue_free()
			_visuals.erase(id)
			_latest.erase(id)
			if id == selected_id:
				_select(-1)
			if id == follow_id:
				follow_id = -1

	if _focus_own and link.my_entity_id != -1 and _visuals.has(link.my_entity_id):
		_focus_own = false
		_focused_once = true
		_select(link.my_entity_id)
		camera.distance = minf(camera.distance, planet.radius * 1.6)
		camera.focus_on(_visuals[link.my_entity_id].position)

	for ev: Dictionary in snap["events"]:
		_log_event(ev)
	hud.show_status(snap, link)
	_refresh_selected_info()


func _process(delta: float) -> void:
	var blend := clampf(delta * 12.0, 0.0, 1.0)
	for id: int in _visuals:
		var node: Node3D = _visuals[id]
		var e: Dictionary = _latest[id]
		node.position = node.position.lerp(e["position"], blend)
		_orient(node, e["heading"])
		var speech := node.get_node_or_null("Speech") as Label3D
		if speech != null:
			speech.visible = (camera.global_position - node.position).dot(node.position) > 0.0
	if follow_id != -1 and _visuals.has(follow_id):
		camera.focus_on(_visuals[follow_id].position)
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
		"entity_said":
			var who := speaker_name(ev["entity_id"])
			var far := ""
			if float(ev.get("distance", 0.0)) >= 1.0:
				far = "  (%d m)" % int(ev["distance"])
			hud.chat_line("%s: %s%s" % [who, ev["text"], far])
			_show_speech(ev["entity_id"], ev["text"])
			spectator.on_speech(ev["entity_id"])


# --- input -> commands --------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if planet == null:
		return
	if event is InputEventMouseMotion and follow_id != -1 \
			and (event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT:
		stop_following()   # grabbing the camera takes it back
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and camera.drag_distance < 6.0:
			_select(_pick_entity(mb.position))
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var who: int = _my_walker()
			var target: Variant = _pick_ground(mb.position) if who != -1 else null
			if target != null:
				link.submit_command(Commands.move_to(link.issuer, who, target))
	elif event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).keycode
		match key:
			KEY_N:
				_spawn_at_mouse("critter")
			KEY_T:
				_spawn_at_mouse("tree")
			KEY_E:
				_spawn_at_mouse("explorer")
			KEY_A:
				_spawn_agent_at_mouse()
			KEY_DELETE, KEY_BACKSPACE, KEY_X:
				if selected_id != -1 and link.can_edit_world():
					link.submit_command(Commands.despawn(link.issuer, selected_id))
			KEY_F:
				var id: int = selected_id if selected_id != -1 else link.my_entity_id
				if _visuals.has(id):
					camera.focus_on(_visuals[id].position)
			KEY_TAB:
				spectator.next_ai()
			KEY_G:
				spectator.toggle_auto()
			KEY_P:
				hud.toggle_players()
			KEY_R:
				if link.role == "player" and link.my_entity_id == -1:
					link.respawn()
			KEY_ENTER, KEY_KP_ENTER:
				if link.can_chat():
					hud.open_chat()
					get_viewport().set_input_as_handled()
			KEY_SPACE:
				link.set_paused(not link.paused)
			KEY_EQUAL, KEY_PLUS, KEY_KP_ADD:
				link.set_speed(link.speed * 2.0)
			KEY_MINUS, KEY_KP_SUBTRACT:
				link.set_speed(link.speed / 2.0)
			KEY_PERIOD:
				if link.paused:
					link.step_once()
			KEY_ESCAPE:
				stop_following()
				_select(-1)


## The entity a right-click should send walking: a player's own explorer, or
## (single player / host) whatever is selected.
func _my_walker() -> int:
	match link.role:
		"player":
			return link.my_entity_id
		"admin":
			return selected_id
	return -1


## Chat is spoken by your explorer (or, for the host, the selected entity), so
## only those near it hear it.
func _send_chat(text: String) -> void:
	var who: int = _my_walker()
	if who == -1:
		hud.log_line("! select something to speak through it" if link.role == "admin"
			else "! you need an explorer to talk (press R)")
		return
	link.submit_command(Commands.say(link.issuer, who, text))


func _spawn_at_mouse(kind: String) -> void:
	if not link.can_edit_world():
		return
	var target: Variant = _pick_ground(get_viewport().get_mouse_position())
	if target == null:
		hud.log_line("! point the mouse at the planet to spawn")
		return
	link.submit_command(Commands.spawn(link.issuer, kind, target))


## Spawn an explorer run by the example "curious" AI agent.
func _spawn_agent_at_mouse() -> void:
	if not link.can_edit_world():
		return
	var target: Variant = _pick_ground(get_viewport().get_mouse_position())
	if target == null:
		hud.log_line("! point the mouse at the planet to spawn")
		return
	link.request_agent("explorer", target)


# --- following (spectators, and anyone who presses Tab) -------------------------

func follow(id: int) -> void:
	if not _visuals.has(id):
		return
	follow_id = id
	_select(id)
	if planet != null and camera.distance > planet.radius * 1.8:
		camera.distance = planet.radius * 1.6   # close enough to read the speech


func stop_following() -> void:
	follow_id = -1
	if spectator.auto:
		spectator.toggle_auto()


## Ids of entities driven by AI agents, in a stable order.
func ai_entity_ids() -> Array:
	var ids: Array = []
	for id: int in _latest:
		if str(_latest[id]["controller"]).begins_with("agent:"):
			ids.append(id)
	ids.sort()
	return ids


## "alice", "curious (AI)", or "critter #12".
func speaker_name(id: int) -> String:
	if not _latest.has(id):
		return "#%d" % id
	var e: Dictionary = _latest[id]
	var label := Protocol.controller_label(str(e["controller"]))
	if label != "":
		return "%s #%d" % [label, id]
	return "%s #%d" % [e["kind"], id]


## A speech bubble over an entity's head for a few seconds.
func _show_speech(id: int, text: String) -> void:
	if not _visuals.has(id):
		return
	var node: Node3D = _visuals[id]
	var old := node.get_node_or_null("Speech")
	if old != null:
		old.free()
	var label := Label3D.new()
	label.name = "Speech"
	label.text = text
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.fixed_size = true          # same size on screen however far the camera is
	label.no_depth_test = true       # never hidden by hills; _process hides it on the far side
	label.pixel_size = 0.0008
	label.font_size = 28
	label.outline_size = 8
	label.width = 500.0
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	label.position = Vector3(0, 2.0, 0)
	node.add_child(label)
	# Bound to the label itself, so the connection simply vanishes if the label
	# is replaced by a newer bubble first.
	get_tree().create_timer(4.0).timeout.connect(label.queue_free)


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
	hud.show_selected(e, hour, (e["dir"] as Vector3).dot(sun_dir) > 0.0, selected_id == follow_id)


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
