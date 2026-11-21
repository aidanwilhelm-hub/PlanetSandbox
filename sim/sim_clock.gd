## Simulation time: fixed ticks, day/night cycle, and simple seasons.
##
## Time only moves when the simulation steps, never from the wall clock, so the
## same inputs always produce the same world (important for multiplayer).
extends RefCounted

const Geo = preload("res://sim/geo.gd")

var tick_rate: int          ## simulation steps per simulated second
var day_length: float       ## simulated seconds in one full day
var year_length_days: float ## days in one year (drives the seasons)
var axial_tilt_deg: float   ## how far the sun drifts north/south over a year
var start_hour: float       ## hour of day (at longitude 0) when the world starts
var tick := 0               ## number of completed simulation steps


func _init(p_tick_rate: int = 20, p_day_length: float = 120.0, p_year_days: float = 8.0,
		p_tilt: float = 23.0, p_start_hour: float = 9.0) -> void:
	tick_rate = p_tick_rate
	day_length = p_day_length
	year_length_days = p_year_days
	axial_tilt_deg = p_tilt
	start_hour = p_start_hour


func dt() -> float:
	return 1.0 / float(tick_rate)


## Simulated seconds since the very start of day 0.
func elapsed() -> float:
	return float(tick) / float(tick_rate) + start_hour / 24.0 * day_length


func day_number() -> int:
	return int(floor(elapsed() / day_length))


## 0.0 = midnight, 0.5 = noon, measured at longitude 0.
func day_fraction() -> float:
	return fposmod(elapsed(), day_length) / day_length


## Unit vector from the planet's center toward the sun.
func sun_direction() -> Vector3:
	var sun_lon := -(day_fraction() - 0.5) * 360.0
	var year_frac := elapsed() / (day_length * year_length_days)
	var sun_lat := axial_tilt_deg * sin(TAU * year_frac)
	return Geo.dir_from_lat_lon(sun_lat, sun_lon)


## Local clock time (0..24) at a place on the planet.
func local_hour(dir: Vector3) -> float:
	var lon := Geo.lat_lon_from_dir(dir).y
	return fposmod(day_fraction() + lon / 360.0, 1.0) * 24.0


func is_daylight(dir: Vector3) -> bool:
	return dir.normalized().dot(sun_direction()) > 0.0


func to_dict() -> Dictionary:
	return {
		"tick": tick,
		"tick_rate": tick_rate,
		"elapsed": elapsed(),
		"day": day_number(),
		"day_length": day_length,
		"hour_at_lon0": day_fraction() * 24.0,
		"sun_direction": sun_direction(),
	}
