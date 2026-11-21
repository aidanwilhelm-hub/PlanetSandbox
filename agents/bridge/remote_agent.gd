## An agent whose decisions are made by another program (Python, an LLM
## harness, anything that speaks JSON over TCP). Created by the AgentBridge;
## you don't make these yourself.
extends "res://agents/agent.gd"

var peer: StreamPeerTCP


func decide(obs: Dictionary) -> Variant:
	if peer == null or peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return null
	# Wait for the program's answer before sending the next observation, so a
	# slow model (seconds per decision) never falls behind a queue of stale ones.
	busy = true
	send({"op": "observe", "obs": obs})
	return null


func on_detached(reason: String) -> void:
	send({"op": "left", "reason": reason})


func send(msg: Dictionary) -> void:
	if peer != null and peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		peer.put_data((JSON.stringify(msg) + "\n").to_utf8_buffer())
