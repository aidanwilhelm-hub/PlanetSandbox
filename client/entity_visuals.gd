## What each kind of entity looks like, and how it moves. Purely cosmetic:
## the simulation never sees any of this.
extends RefCounted

const WALK_CYCLE := 9.0       ## leg swings (radians) per second at full walking speed
const LEG_SWING := 0.7        ## radians
const ARM_SWING := 0.5


static func create(kind: String) -> Node3D:
	var root := Node3D.new()
	var body := Node3D.new()      ## everything that bobs; animate() moves this
	body.name = "Body"
	root.add_child(body)
	match kind:
		"tree":
			_add_part(body, _cylinder(0.25, 0.3, 1.4), Color(0.4, 0.26, 0.14), 0.7)
			_add_part(body, _cylinder(0.0, 1.3, 3.2), Color(0.12, 0.45, 0.2), 2.8)
		"critter":
			_add_part(body, _capsule(0.5, 1.4), Color(0.95, 0.55, 0.2), 0.7)
			var eye := _add_part(body, _sphere(0.12), Color(0.1, 0.1, 0.1), 1.0)
			eye.position.z = -0.42
		"explorer":
			var cyan := Color(0.2, 0.85, 0.95)
			var dark := Color(0.12, 0.4, 0.5)
			_add_part(body, _capsule(0.55, 1.5), cyan, 1.55)
			_add_part(body, _sphere(0.42), Color(0.95, 0.85, 0.72), 2.6)
			# a "nose" so you can see which way it faces
			var nose := _add_part(body, _cylinder(0.0, 0.22, 0.6), Color(1, 1, 1), 2.6)
			nose.rotation_degrees.x = -90.0
			nose.position.z = -0.55
			_limb(body, "LegL", Vector3(-0.25, 0.95, 0), _capsule(0.18, 1.0), dark)
			_limb(body, "LegR", Vector3(0.25, 0.95, 0), _capsule(0.18, 1.0), dark)
			_limb(body, "ArmL", Vector3(-0.66, 2.0, 0), _capsule(0.13, 0.85), cyan)
			_limb(body, "ArmR", Vector3(0.66, 2.0, 0), _capsule(0.13, 0.85), cyan)
		"raft":
			var wood := Color(0.55, 0.36, 0.18)
			var deck := _add_part(body, BoxMesh.new(), wood, 0.15)
			deck.scale = Vector3(1.9, 0.3, 2.8)
			_add_part(body, _cylinder(0.07, 0.07, 2.4), wood.darkened(0.3), 1.4)
			var sail := _add_part(body, BoxMesh.new(), Color(0.95, 0.93, 0.85), 1.7)
			sail.scale = Vector3(0.05, 1.5, 1.2)
			sail.position.z = 0.25
		_:
			_add_part(body, BoxMesh.new(), Color.MAGENTA, 0.5)
	return root


## Move a node's parts for one frame. `moving`: the thing is walking (or
## sailing); `medium`: "dry", "wading" or "floating"; `t`: seconds since start.
static func animate(node: Node3D, kind: String, moving: bool, medium: String, delta: float, t: float) -> void:
	var body := node.get_node_or_null("Body") as Node3D
	if body == null:
		return
	var phase: float = node.get_meta("phase", node.get_instance_id() % 100 * 0.37)
	var amount: float = node.get_meta("walk", 0.0)   # eases in and out of walking
	amount = move_toward(amount, 1.0 if moving else 0.0, delta * 5.0)
	var rate := WALK_CYCLE * (0.5 if medium == "wading" else 1.0)
	phase += delta * rate * maxf(amount, 0.15 if moving else 0.0)
	node.set_meta("phase", phase)
	node.set_meta("walk", amount)
	var swing := sin(phase) * amount

	match kind:
		"explorer":
			_swing(body, "LegL", swing * LEG_SWING)
			_swing(body, "LegR", -swing * LEG_SWING)
			_swing(body, "ArmL", -swing * ARM_SWING)
			_swing(body, "ArmR", swing * ARM_SWING)
			body.position.y = absf(sin(phase)) * 0.08 * amount
		"critter":
			body.position.y = absf(sin(phase * 0.8)) * 0.3 * amount   # little hops
	# Water: floating things bob and rock on the waves; waders sink in a little.
	match medium:
		"floating":
			var wave := t * 1.6 + node.position.x * 0.3 + node.position.z * 0.2
			body.position.y = sin(wave) * 0.14 - 0.05
			body.rotation.x = sin(wave * 0.9) * 0.06
			body.rotation.z = cos(wave * 0.7) * 0.05
		"wading":
			body.position.y += -0.35


static func _swing(body: Node3D, part: String, angle: float) -> void:
	var limb := body.get_node_or_null(part) as Node3D
	if limb != null:
		limb.rotation.x = angle


## A limb that swings from a joint at `joint` (hip or shoulder).
static func _limb(body: Node3D, part: String, joint: Vector3, mesh: Mesh, color: Color) -> void:
	var pivot := Node3D.new()
	pivot.name = part
	pivot.position = joint
	body.add_child(pivot)
	var piece := _add_part(pivot, mesh, color, 0.0)
	piece.position.y = -float(mesh.get("height")) * 0.5 + 0.1


static func _add_part(root: Node3D, mesh: Mesh, color: Color, height: float) -> MeshInstance3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.8
	var inst := MeshInstance3D.new()
	inst.mesh = mesh
	inst.material_override = mat
	inst.position.y = height
	root.add_child(inst)
	return inst


static func _cylinder(top: float, bottom: float, height: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = height
	m.radial_segments = 10
	m.rings = 1
	return m


static func _capsule(radius: float, height: float) -> CapsuleMesh:
	var m := CapsuleMesh.new()
	m.radius = radius
	m.height = height
	m.radial_segments = 12
	m.rings = 4
	return m


static func _sphere(radius: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = 12
	m.rings = 6
	return m
