## Math helpers for positions on a sphere. Pure functions, no state.
##
## The simulation describes "where" with a unit direction vector from the
## planet's center (a "dir"). Latitude/longitude helpers exist so humans and
## AI agents can talk about places in a familiar way.
extends RefCounted


static func dir_from_lat_lon(lat_deg: float, lon_deg: float) -> Vector3:
	var lat := deg_to_rad(lat_deg)
	var lon := deg_to_rad(lon_deg)
	return Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))


## Returns Vector2(latitude, longitude) in degrees.
static func lat_lon_from_dir(dir: Vector3) -> Vector2:
	var d := dir.normalized()
	return Vector2(rad_to_deg(asin(clampf(d.y, -1.0, 1.0))), rad_to_deg(atan2(d.x, d.z)))


## Any unit vector perpendicular to `dir` (a valid "facing" on the surface).
static func any_tangent(dir: Vector3) -> Vector3:
	var helper := Vector3.UP if absf(dir.y) < 0.9 else Vector3.RIGHT
	return dir.cross(helper).normalized()


## Rotate `from` toward `to` along the great circle, by at most `max_angle` radians.
static func rotate_toward(from: Vector3, to: Vector3, max_angle: float) -> Vector3:
	var angle := from.angle_to(to)
	if angle <= max_angle:
		return to
	var axis := from.cross(to)
	if axis.length_squared() < 1e-12:
		axis = any_tangent(from)
	return from.rotated(axis.normalized(), max_angle).normalized()


## Uniformly random direction on the sphere.
static func random_dir(rng: RandomNumberGenerator) -> Vector3:
	var z := rng.randf_range(-1.0, 1.0)
	var t := rng.randf_range(0.0, TAU)
	var r := sqrt(1.0 - z * z)
	return Vector3(r * cos(t), z, r * sin(t))


## Random direction within `max_angle` radians of `center`.
static func random_dir_near(rng: RandomNumberGenerator, center: Vector3, max_angle: float) -> Vector3:
	var axis := center.cross(random_dir(rng))
	if axis.length_squared() < 1e-9:
		axis = any_tangent(center)
	return center.rotated(axis.normalized(), rng.randf_range(0.0, max_angle)).normalized()
