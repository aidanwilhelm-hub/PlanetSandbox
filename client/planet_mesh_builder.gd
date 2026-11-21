## Builds the visible planet mesh from the simulation's Planet.
##
## Uses a "cube sphere": six square grids pushed out into a ball, which gives
## evenly sized triangles without the pinched poles of a UV sphere.
extends RefCounted

const BIOME_COLORS := {
	"deep_ocean": Color(0.05, 0.12, 0.28),
	"ocean": Color(0.12, 0.28, 0.42),
	"beach": Color(0.86, 0.80, 0.56),
	"grass": Color(0.32, 0.58, 0.24),
	"forest": Color(0.16, 0.40, 0.17),
	"rock": Color(0.46, 0.41, 0.36),
	"snow": Color(0.94, 0.95, 0.97),
}


static func build(planet: RefCounted, resolution: int = 96) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]
	var base := 0
	for normal: Vector3 in faces:
		var axis_a := Vector3(normal.y, normal.z, normal.x)
		var axis_b := normal.cross(axis_a)
		for y in resolution + 1:
			for x in resolution + 1:
				var p := Vector2(x, y) / float(resolution) * 2.0 - Vector2.ONE
				var dir := (normal + axis_a * p.x + axis_b * p.y).normalized()
				var h: float = planet.height_at(dir)
				var color: Color = BIOME_COLORS[planet.biome_at(dir)]
				# Slight shading by height so flat biomes don't look like paint.
				color = color.darkened(0.12 * (1.0 - clampf(absf(h) / planet.max_height * 2.0, 0.0, 1.0)))
				st.set_color(color)
				st.add_vertex(dir * (planet.radius + h))
		# Godot treats clockwise triangles (seen from outside) as the front side.
		var flip := axis_a.cross(axis_b).dot(normal) > 0.0
		var row := resolution + 1
		for y in resolution:
			for x in resolution:
				var i := base + y * row + x
				var quad := [i, i + 1, i + row, i + 1, i + row + 1, i + row]
				if flip:
					quad = [i, i + row, i + 1, i + 1, i + row, i + row + 1]
				for idx: int in quad:
					st.add_index(idx)
		base += row * row
	st.generate_normals()
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.95
	mesh.surface_set_material(0, mat)
	return mesh


static func build_ocean(planet: RefCounted) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = planet.radius
	sphere.height = planet.radius * 2.0
	sphere.radial_segments = 128
	sphere.rings = 64
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.10, 0.32, 0.62, 0.72)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.12
	mat.metallic_specular = 0.8
	var inst := MeshInstance3D.new()
	inst.mesh = sphere
	inst.material_override = mat
	inst.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return inst
