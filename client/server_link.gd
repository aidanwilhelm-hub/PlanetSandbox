## What the 3D view talks to instead of the server itself.
##
## Two versions share this interface:
##   local_link.gd   the simulation runs in this program (single player, host,
##                   or watching a local AI world);
##   remote_link.gd  the simulation runs on another computer (joining a game).
## The view never needs to know which one it has.
extends Node

const Commands = preload("res://sim/commands.gd")
const Protocol = preload("res://net/protocol.gd")

## A full picture of the world plus the events since the last one.
signal snapshot_published(snapshot: Dictionary)
## A line for the on-screen log ("Connected", "Not allowed"...).
signal notice(text: String)
## The player list changed (multiplayer only).
signal players_changed(list: Array)
## Your explorer, role or moderator status changed.
signal identity_changed

var role := "admin"          ## admin (the host / single player) | player | spectator
var issuer := Commands.ADMIN ## the name your commands are sent under
var my_entity_id := -1       ## your own explorer, for players
var is_mod := false
var is_host := false         ## may appoint moderators and kick anyone
var networked := false       ## other people can be in this world
var mode := Protocol.MODE_CREATIVE
var chat_range := Protocol.DEFAULT_CHAT_RANGE
var paused := false
var speed := 1.0
var players: Array = []      ## [{peer_id, name, role, mod, entity_id, ping}]


func submit_command(_cmd: Dictionary) -> void:
	pass


## Ask for the latest snapshot to be sent again.
func publish() -> void:
	pass


func set_paused(_value: bool) -> void:
	pass


func set_speed(_value: float) -> void:
	pass


func step_once() -> void:
	pass


## Add an AI explorer (the example "curious" agent) at `target`.
func request_agent(_kind: String, _target: Variant) -> void:
	pass


func kick(_peer_id: int) -> void:
	pass


func set_mod(_peer_id: int, _on: bool) -> void:
	pass


## Get a new explorer after yours was removed.
func respawn() -> void:
	pass


func can_edit_world() -> bool:
	return role == "admin" or (role == "player" and mode == Protocol.MODE_CREATIVE)


func can_control_time() -> bool:
	return role == "admin" or (role == "player" and is_mod)


func can_chat() -> bool:
	return role != "spectator"


func role_label() -> String:
	match role:
		"admin":
			return "host" if is_host else "single player"
		"player":
			return "player, moderator" if is_mod else "player"
	return "spectator"


## Saving and loading the world: only when it runs on this computer.
func can_save() -> bool:
	return false


## A short description of what's in a save slot ("" = empty).
func slot_info(_slot: int) -> String:
	return ""


## Returns "" or what went wrong.
func save_slot(_slot: int) -> String:
	return "saving isn't possible here"


func load_slot(_slot: int) -> String:
	return "loading isn't possible here"
