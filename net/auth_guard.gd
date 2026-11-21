## Checks the server password and soft-blocks addresses that keep guessing.
##
## One guard is shared by the multiplayer server and the AI agent bridge, so
## wrong guesses on either count together. After MAX_FAILURES wrong passwords
## an address is refused for BLOCK_SECONDS, even with the right password.
## A correct password resets the count.
extends RefCounted

const MAX_FAILURES := 10
const BLOCK_SECONDS := 600.0

var password := ""
## Tests set this to control time; < 0 means use the real clock.
var now_override := -1.0

var _failures: Dictionary = {}       ## address -> wrong guesses in a row
var _blocked_until: Dictionary = {}  ## address -> time the block ends


func _init(p_password: String = "") -> void:
	password = p_password


func is_required() -> bool:
	return password != ""


## Returns "ok", "wrong" or "blocked".
func check(address: String, attempt: String) -> String:
	var now := _now()
	if _blocked_until.has(address):
		if now < float(_blocked_until[address]):
			return "blocked"
		_blocked_until.erase(address)
		_failures.erase(address)
	if password == "" or attempt == password:
		_failures.erase(address)
		return "ok"
	var n := int(_failures.get(address, 0)) + 1
	_failures[address] = n
	if n >= MAX_FAILURES:
		_blocked_until[address] = now + BLOCK_SECONDS
	return "wrong"


func is_blocked(address: String) -> bool:
	return _blocked_until.has(address) and _now() < float(_blocked_until[address])


## Whole minutes until `address` may try again (at least 1 while blocked).
func minutes_left(address: String) -> int:
	if not is_blocked(address):
		return 0
	return maxi(1, ceili((float(_blocked_until[address]) - _now()) / 60.0))


func _now() -> float:
	return now_override if now_override >= 0.0 else Time.get_ticks_msec() / 1000.0
