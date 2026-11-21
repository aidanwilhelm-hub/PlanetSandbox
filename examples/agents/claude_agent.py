"""An NPC whose mind is Claude.

Every few seconds of game time Claude gets the NPC's observation as JSON and
answers with a short thought plus a list of actions.

Setup (once):
    pip install anthropic
    set ANTHROPIC_API_KEY=...        (or: ant auth login)

Run (with the game started using `-- --agent-port=7777`):
    python claude_agent.py
    python claude_agent.py --persona "a grumpy old cartographer" --name carto
"""

import argparse
import json

import anthropic

from planet_agent import run

MODEL = "claude-opus-5-5"

SYSTEM = """You are the mind of an NPC explorer living on a small 3D planet.
Persona: {persona}

Each turn you receive what your NPC can perceive, as JSON:
- self: your position (lat/lon degrees), heading (compass degrees), state, biome
- time: local hour and whether it is day where you stand
- nearby: other things within sight, with distance (meters) and compass bearing
- surroundings: for each compass direction, how many meters of walkable land lie ahead
- events: what happened to you since last turn (arrivals, blocked by water, things you heard)
- feedback: problems with your previous actions

You can't swim: walking into water stops you at the shore. Prefer directions with
plenty of walkable land. Explorers move about 6 m per second.

Actions (all about your own body):
- move_to: walk to lat/lon
- move: walk `distance` meters toward compass `bearing` (0 = north, 90 = east)
- approach: walk to where entity `entity_id` is now
- stop: stand still
- say: speak `text` aloud (under 120 characters); nearby NPCs hear it
- wait: do nothing

Usually take one or two actions. If you are already walking somewhere sensible,
an empty list keeps you going. Answer anyone who talks to you. Stay in character."""

ACTION_SCHEMA = {
    "type": "object",
    "properties": {
        "action": {"type": "string", "enum": ["move_to", "move", "approach", "stop", "say", "wait"]},
        "lat": {"type": ["number", "null"]},
        "lon": {"type": ["number", "null"]},
        "bearing": {"type": ["number", "null"]},
        "distance": {"type": ["number", "null"]},
        "entity_id": {"type": ["integer", "null"]},
        "text": {"type": ["string", "null"]},
    },
    "required": ["action", "lat", "lon", "bearing", "distance", "entity_id", "text"],
    "additionalProperties": False,
}

RESPONSE_SCHEMA = {
    "type": "object",
    "properties": {
        "thought": {"type": "string"},
        "actions": {"type": "array", "items": ACTION_SCHEMA},
    },
    "required": ["thought", "actions"],
    "additionalProperties": False,
}


def make_decide(persona, name, memory_turns=6):
    client = anthropic.Anthropic()
    system = SYSTEM.format(persona=persona)
    history = []  # recent (observation, answer) pairs, so the NPC remembers what it was doing

    def decide(obs):
        messages = []
        for past_obs, past_answer in history[-memory_turns:]:
            messages.append({"role": "user", "content": json.dumps(past_obs)})
            messages.append({"role": "assistant", "content": past_answer})
        messages.append({"role": "user", "content": json.dumps(obs)})
        try:
            response = client.beta.messages.create(
                model=MODEL,
                max_tokens=2000,
                system=system,
                messages=messages,
                output_config={"effort": "low", "format": {"type": "json_schema", "schema": RESPONSE_SCHEMA}},
                # If a request is ever declined, let the API retry it on a fallback model.
                betas=["server-side-fallback-2026-07-01"],
                fallbacks="default",
            )
        except anthropic.RateLimitError:
            print(f"[{name}] rate limited; standing still this turn")
            return []
        except anthropic.APIStatusError as e:
            print(f"[{name}] API error {e.status_code}: {e.message}")
            return []
        except anthropic.APIConnectionError:
            print(f"[{name}] can't reach the API; standing still this turn")
            return []

        if response.stop_reason == "refusal":
            return []
        text = next((b.text for b in response.content if b.type == "text"), None)
        if text is None:
            return []
        answer = json.loads(text)
        history.append((obs, text))
        print(f"[{name}] {answer['thought']}")
        # Drop the unused (null) fields before sending the actions to the game.
        return [{k: v for k, v in a.items() if v is not None} for a in answer["actions"]]

    return decide


def main():
    parser = argparse.ArgumentParser(description="Let Claude drive an NPC in Planet Sandbox.")
    parser.add_argument("--name", default="claude")
    parser.add_argument("--persona", default="a cheerful, curious naturalist who loves meeting critters")
    parser.add_argument("--port", type=int, default=7777)
    parser.add_argument("--think-every", type=int, default=60,
                        help="ticks between decisions (20 ticks = 1 second of game time)")
    args = parser.parse_args()
    run(make_decide(args.persona, args.name), name=args.name, port=args.port, think_every=args.think_every)


if __name__ == "__main__":
    main()
