## What each kind of entity looks like. Purely cosmetic.
extends RefCounted


static func create(kind: String) -> Node3D:
	var root := Node3D.new()
	match kind:
		"tree":
			_add_part(root, _cylinder(0.25, 0.3, 1.4), Color(0.4, 0.26, 0.14), 0.7)
			_add_part(root, _cylinder(0.0, 1.3, 3.2), Color(0.12, 0.45, 0.2), 2.8)
		"critter":
			_add_part(root, _capsule(0.5, 1.4), Color(0.95, 0.55, 0.2), 0.7)
		"explorer":
			_add_part(root, _capsule(0.7, 2.6), Color(0.2, 0.85, 0.95), 1.3)
			# a "nose" so you can see which way it faces
			var nose := _add_part(root, _cylinder(0.0, 0.35, 0.9), Color(1, 1, 1), 2.0)
			nose.rotation_degrees.x = -90.0
			nose.position.z = -0.8
		_:
			_add_part(root, BoxMesh.new(), Color.MAGENTA, 0.5)
	return root


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
