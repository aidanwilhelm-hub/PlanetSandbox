"""Tiny client for Planet Sandbox's agent bridge. Standard library only.

Start the game with the bridge on:

    godot --path . -- --agent-port=7777

then write a decide() function and call run():

    from planet_agent import run

    def decide(obs):
        return [{"action": "move", "bearing": 90, "distance": 20}]

    run(decide, name="eastbound")

decide() gets one observation (a dict; see agents/observation.gd) and returns a
list of actions (see agents/actions.gd). It may take as long as it likes: the
world keeps running and the NPC keeps doing what it was last told.
"""

import json
import socket


def run(decide, name="python", kind="explorer", host="127.0.0.1", port=7777,
        think_every=20, sight_range=30.0, lat=None, lon=None, entity_id=None,
        verbose=True):
    """Connect, join, then answer every observation with decide(obs) until the
    NPC is removed or the game closes."""
    join = {"op": "join", "name": name, "kind": kind,
            "think_every": think_every, "sight_range": sight_range}
    if lat is not None and lon is not None:
        join.update(lat=lat, lon=lon)
    if entity_id is not None:
        join["entity_id"] = entity_id

    with socket.create_connection((host, port)) as sock:
        reader = sock.makefile("r", encoding="utf-8")

        def send(msg):
            sock.sendall((json.dumps(msg) + "\n").encode("utf-8"))

        send(join)
        for line in reader:
            msg = json.loads(line)
            op = msg.get("op")
            if op == "joined":
                if verbose:
                    print(f"[{name}] controlling entity #{msg['entity_id']} as {msg['controller']}")
            elif op == "observe":
                actions = decide(msg["obs"]) or []
                if isinstance(actions, dict):
                    actions = [actions]
                send({"op": "act", "actions": actions})
            elif op == "left":
                if verbose:
                    print(f"[{name}] left the world: {msg.get('reason')}")
                return
            elif op == "error" and verbose:
                print(f"[{name}] server says: {msg.get('message')}")
    if verbose:
        print(f"[{name}] disconnected")
