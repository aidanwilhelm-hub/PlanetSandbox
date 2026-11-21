## The multiplayer wire format, shared by the server and clients.
##
## Every packet is one Dictionary with an "op" key, turned into bytes with
## var_to_bytes() (never the "with objects" variant, so a hostile peer can't
## send code) and compressed with zstd. Vectors travel as-is.
##
## Client -> server
##   hello    {name, role: "player"|"spectator", password, version}
##   cmd      {command}                  any command dict; the server sets "issuer"
##   agent    {kind, target}             spawn an AI explorer (Creative mode)
##   time     {paused?, speed?, step?}   host and moderators only
##   kick     {peer_id}                  moderators only
##   respawn  {}                         a player whose explorer is gone
##
## Server -> client
##   welcome  {peer_id, issuer, role, mod, mode, chat_range, planet, entity_id}
##   denied   {reason}                   then the connection is closed
##   state    {tick, time, server, entities}   10 times a second, own channel
##   events   {events}                   reliable; shown with the next state
##   you      {entity_id, mod}           your explorer or moderator status changed
##   players  {list}                     who is connected, with ping
##   notice   {text}                     a line for your log (e.g. "not allowed")
##   planet   {planet}                   the host loaded a saved world
##   kicked   {reason}
extends RefCounted

const VERSION := 1
const DEFAULT_PORT := 7000
const CHANNELS := 2
const CH_RELIABLE := 0      ## control messages and events
const CH_STATE := 1         ## world states, so they never hold up chat or notices
const MAX_PACKET := 4 * 1024 * 1024
const DEFAULT_CHAT_RANGE := 30.0   ## meters along the surface
const MAX_NAME := 24

const MODE_SURVIVAL := "survival"
const MODE_CREATIVE := "creative"


static func encode(msg: Dictionary) -> PackedByteArray:
	var raw := var_to_bytes(msg)
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, raw.size())
	out.append_array(raw.compress(FileAccess.COMPRESSION_ZSTD))
	return out


## The message, or null if the bytes aren't a valid one.
static func decode(bytes: PackedByteArray) -> Variant:
	if bytes.size() < 5:
		return null
	var size := bytes.decode_u32(0)
	if size == 0 or size > MAX_PACKET:
		return null
	var raw := bytes.slice(4).decompress(size, FileAccess.COMPRESSION_ZSTD)
	if raw.size() != size:
		return null
	var msg: Variant = bytes_to_var(raw)
	if not msg is Dictionary or not (msg as Dictionary).has("op"):
		return null
	return msg


## A display name that is safe to put in a controller id ("player:<name>:<n>").
static func clean_name(value: Variant) -> String:
	var s := str(value).strip_edges().replace(":", "_").replace("\n", " ")
	s = s.left(MAX_NAME)
	return s if s != "" else "player"


## "player:alice:5" -> "alice", "agent:curious:3" -> "curious (AI)".
static func controller_label(controller: String) -> String:
	var parts := controller.split(":")
	if parts.size() >= 2:
		match parts[0]:
			"player":
				return parts[1]
			"agent":
				return "%s (AI)" % parts[1]
	return ""
