## The planet's shape: a sphere with deterministic terrain.
##
## Terrain comes only from the seed, so the server and every client can rebuild
## the exact same planet from three numbers (seed, radius, max_height) instead
## of sending the whole terrain over the network.
extends RefCounted

const Geo = preload("res://sim/geo.gd")

const SEA_LEVEL := 0.0

var world_seed: int
var radius: float
var max_height: float

var _noise := FastNoiseLite.new()
var _current_noise := FastNoiseLite.new()   ## ocean currents (see sim/water.gd)


func _init(p_seed: int = 12345, p_radius: float = 100.0, p_max_height: float = 6.0) -> void:
	world_seed = p_seed
	radius = p_radius
	max_height = p_max_height
	_noise.seed = p_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.frequency = 1.1
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_noise.fractal_octaves = 5
	_noise.fractal_lacunarity = 2.0
	_noise.fractal_gain = 0.5
	_current_noise.seed = p_seed + 1
	_current_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_current_noise.frequency = 0.6


## Terrain height relative to sea level (negative = under water).
func height_at(dir: Vector3) -> float:
	var n := _noise.get_noise_3dv(dir.normalized())
	return clampf(n * 1.8 + 0.05, -1.0, 1.0) * max_height


## Smooth noise in 0..1 for the ocean currents; `channel` picks an independent field.
func current_noise(dir: Vector3, channel: int) -> float:
	var p := dir.normalized() + Vector3(channel * 7.3, channel * 3.1, 0.0)
	return clampf(_current_noise.get_noise_3dv(p) * 0.5 + 0.5, 0.0, 1.0)


func is_land(dir: Vector3) -> bool:
	return height_at(dir) > SEA_LEVEL


## Point where something standing at `dir` touches the ground (or the sea surface).
func surface_point(dir: Vector3) -> Vector3:
	var d := dir.normalized()
	return d * (radius + maxf(height_at(d), SEA_LEVEL))


func biome_at(dir: Vector3) -> String:
	var d := dir.normalized()
	var t := height_at(d) / max_height
	if t < 0.0:
		return "deep_ocean" if t < -0.35 else "ocean"
	if absf(d.y) > 0.9 or t > 0.75:
		return "snow"
	if t < 0.06:
		return "beach"
	if t > 0.5:
		return "rock"
	if t > 0.25:
		return "forest"
	return "grass"


## A random land location, or Vector3.ZERO if none was found.
func random_land_dir(rng: RandomNumberGenerator, tries: int = 500) -> Vector3:
	for i in tries:
		var d := Geo.random_dir(rng)
		if is_land(d):
			return d
	return Vector3.ZERO


func to_dict() -> Dictionary:
	return {"seed": world_seed, "radius": radius, "max_height": max_height}

