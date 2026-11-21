# Planet Sandbox

A small 3D planet you can watch and poke at. It has terrain with oceans,
mountains and ice caps, a day/night cycle with seasons, and creatures that
wander around during the day and rest at night. You can spawn things, select
them, and send them walking across the planet.

![The planet](docs/screenshot.png)

This is **step 2 of 4**. It is built so the next steps slot in cleanly:

1. **Core simulation**: planet, terrain, time, entities, commands.
2. **AI agent NPCs** (this): any AI model or scripted bot can drive an NPC. See [AI agent NPCs](#ai-agent-npcs).
3. **Multiplayer** and a hands-off "just watch" sim mode.
4. **Game mode** with goals and progression.

---

## How to run it

You need **Godot 4.5** (free, about 100 MB, no installer).

1. Download Godot 4.5 for your system from <https://godotengine.org/download>
   (the normal version, not the ".NET" one). Unzip it and open it.
2. Get this project on your computer. Either:
   - on GitHub, click the green **Code** button → **Download ZIP**, then unzip it, or
   - `git clone https://github.com/aidanwilhelm-hub/PlanetSandbox.git`
3. In Godot's Project Manager click **Import**, pick the `project.godot` file
   inside the project folder, then click **Import & Edit**.
   (The first time, Godot spends a few seconds preparing files. That's normal.)
4. Press **F5** (or the ▶ "Run Project" button in the top-right).

A window opens showing the planet.

### Controls

| Do this | To |
|---|---|
| Left-drag, or arrow keys | Spin around the planet |
| Mouse wheel | Zoom in / out |
| Left-click a thing | Select it (a yellow ring appears) |
| Right-click the ground | Send the selected thing walking there |
| **N** / **T** / **E** | Spawn a critter / tree / explorer where the mouse points |
| **A** | Spawn an AI-driven explorer (the example "curious" agent) where the mouse points |
| **Delete** (or **X**) | Remove the selected thing |
| **F** | Point the camera at the selected thing |
| **Space** | Pause / resume |
| **+** / **-** | Speed time up / slow it down (x0.25 to x32) |
| **.** | Advance one tick while paused |
| **Esc** | Deselect |

What lives here right now:

- **Explorer** (cyan, with a white nose): has no mind of its own. It walks
  wherever you send it, unless an AI agent is driving it. AI explorers say
  things now and then (speech bubbles, and a line in the log).
- **Critter** (orange): wanders nearby by day, stops when its spot goes dark.
- **Tree** (green cone): scenery; it refuses to move.

Walkers can't swim: if a path crosses water they stop at the shore.

A full day is 2 minutes of real time at x1 speed, and a year is 8 days, so the
sun drifts north and south as the seasons change.

### Other ways to run it (from a terminal)

Replace `godot` below with the path to the Godot program you downloaded, and
run these from inside the project folder.

```bash
# Run the simulation with no window at all (prints a status line every 5 sim-seconds).
# This is what a dedicated multiplayer server will look like.
godot --headless --path . -- --server

# Try a different planet
godot --path . -- --seed=42

# Start with 5 AI explorers already roaming.
godot --path . -- --agents=5

# Let outside programs (Python, an LLM...) drive NPCs. See "AI agent NPCs" below.
godot --path . -- --agent-port=7777

# Run the automated tests (no window). Prints PASS/FAIL per test.
godot --headless --path . --script res://tests/run_tests.gd
```

---

## How it's built (and why)

The single most important idea: **the simulation knows nothing about the screen,
and the screen never changes the simulation directly.**

```
   you / AI agent / remote player
                │  commands  ("move explorer 3 to lat 10, lon 45")
                ▼
   ┌───────────────────────────┐
   │  SimServer  (server/)     │   runs the sim at a fixed 20 ticks per second
   │   └─ Simulation (sim/)    │   validates commands, moves things, keeps time
   └───────────────────────────┘
                │  snapshots  (everything in the world + what just happened)
                ▼
   WorldView (client/)            draws the snapshot, turns clicks into commands
```

- **`sim/`**: the world itself, as plain data and rules. No graphics, no input.
  - `simulation.gd`: owns the world. `submit_command()` queues an order,
    `step()` advances one tick, `snapshot()` describes everything.
  - `planet.gd`: terrain heights and biomes, generated from a seed. Any machine
    with the same seed builds the identical planet, so terrain never has to be
    sent over the network.
  - `sim_clock.gd`: ticks, days, the sun's position, seasons.
  - `entity.gd`, `entity_kinds.gd`: what a "thing" is, and the catalog of kinds.
  - `commands.gd`: the only ways to change the world: `spawn`, `despawn`,
    `say` (an entity speaks), `assign` (admin hands an entity to a player or agent),
    `move_to`, `stop`.
  - `brains/wander_brain.gd`: the critters' behavior. It doesn't move critters
    itself; it *sends commands* like anyone else would.
- **`agents/`**: the AI agent NPC layer (see below). Runs on the server, next
  to the simulation, and only ever talks to it through commands.
- **`server/sim_server.gd`**: runs the sim on a steady clock, handles pause and
  speed, and publishes snapshots.
- **`client/`**: everything you see: planet mesh, ocean, sun, camera, labels.
- **`tests/run_tests.gd`**: automated checks (determinism, rules, day cycle...).

### Commands

A command is a small dictionary, so it can come from a keyboard, a network
packet, or an AI model's JSON output:

```gdscript
{"type": "move_to", "issuer": "admin", "entity_id": 3, "target": {"lat": 10, "lon": 45}}
{"type": "spawn",   "issuer": "admin", "kind": "critter", "target": {"lat": -20, "lon": 100}}
{"type": "stop",    "issuer": "player:alice", "entity_id": 7}
{"type": "despawn", "issuer": "admin", "entity_id": 7}
{"type": "say",     "issuer": "agent:bob:1", "entity_id": 7, "text": "hello!"}
{"type": "assign",  "issuer": "admin", "entity_id": 7, "controller": "player:alice"}
```

Every command says who sent it (`issuer`). Each entity has a `controller`, and
only its controller (or `admin`) may command it. Bad or unauthorized commands
are refused with a reason (it shows up in the on-screen log) and never crash
the sim. In single-player, you are `admin`.

### Why this sets up the next steps

- **AI agents (step 2, done):** see [AI agent NPCs](#ai-agent-npcs) below.
- **Multiplayer (step 3):** the server already accepts commands from "anyone"
  and publishes snapshots. Agents already live on the server and go through
  the same permission rules as players, so they work unchanged in multiplayer. Step 3 adds the network pipe between them. The sim is
  deterministic (same seed + same commands = same world, checked by a test), and
  a "watch-only" viewer is simply a client that never sends commands.
- **Adding content:** a new creature is one line in `sim/entity_kinds.gd` plus
  (optionally) a look in `client/entity_visuals.gd`.

---

## AI agent NPCs

An agent is anything that can **observe, decide, act**:

1. **Observe.** Every few ticks the agent gets a small JSON-friendly picture of
   what its NPC can perceive: where it is, the time of day, what's nearby
   (with distance and compass bearing), how much walkable land lies in each
   direction, what happened to it since last time (arrived, blocked by water,
   heard someone speak), and feedback on any actions that didn't work.
2. **Decide.** Your code (a few `if`s, a Python script, an LLM...) picks
   actions.
3. **Act.** The actions become ordinary commands under the agent's own
   controller name, so an agent can only ever move **its own body**, and the
   same rules apply to it as to a human player.

### A whole agent in GDScript

```gdscript
extends "res://agents/agent.gd"

func decide(obs: Dictionary) -> Variant:
    if not obs["time"]["is_day"]:
        return {"action": "stop"}
    return {"action": "move", "bearing": randf() * 360.0, "distance": 15}
```

Put it to work (for example in `main.gd`, after `server.start()`):

```gdscript
server.agents.spawn_agent(MyAgent.new(), "explorer", {"lat": 10, "lon": 20})
# or take over something that already exists:
server.agents.attach(MyAgent.new(), some_entity_id)
```

Optional knobs on an agent: `think_every` (ticks between decisions, default 10,
i.e. twice a second), `sight_range` (meters, default 30), and the hooks
`on_attached(obs)` / `on_detached(reason)`. Taking over a critter switches off
its built-in wander brain until the agent lets go.

**Slow thinkers** (an LLM call takes seconds): set `busy = true` in `decide()`,
return `null`, and call `act(actions)` when the answer arrives. The NPC keeps
doing what it was last told meanwhile, and the agent isn't asked again until
it has answered.

### Actions

| Action | Example | Does |
|---|---|---|
| `move_to` | `{"action": "move_to", "lat": 10, "lon": 45}` | walk to a place |
| `move` | `{"action": "move", "bearing": 90, "distance": 20}` | walk 20 m east (0 = north) |
| `approach` | `{"action": "approach", "entity_id": 12}` | walk to where #12 is now |
| `stop` | `{"action": "stop"}` | stand still |
| `say` | `{"action": "say", "text": "hello!"}` | speak; agents within sight range hear it |
| `wait` | `{"action": "wait"}` | nothing |

Return one action, a list of them, or `null` / `[]` to carry on as you are.
Mistakes never crash anything: they come back in the next observation's
`feedback` (malformed actions) or `events` (`action_refused`, for actions the
world said no to).

### Driving an NPC from Python, or any other language

Start the game with the agent bridge on:

```bash
godot --path . -- --agent-port=7777
```

Then, from `examples/agents/` (needs only Python 3, no packages):

```python
from planet_agent import run

def decide(obs):
    best = max(obs["surroundings"], key=lambda s: s["walkable"])
    return [{"action": "move", "bearing": best["bearing"], "distance": best["walkable"]}]

run(decide, name="my-bot")
```

`python wander_bot.py` is a ready-made version. The protocol is one JSON object
per line over TCP (only reachable from this computer), so any language works.
It is documented at the top of `agents/bridge/agent_bridge.gd`. Close the
connection and the NPC disappears.

### Letting Claude be the NPC's mind

```bash
pip install anthropic
export ANTHROPIC_API_KEY=your-key-here      # Windows: set ANTHROPIC_API_KEY=your-key-here
python examples/agents/claude_agent.py --persona "a grumpy old cartographer"
```

Each turn Claude reads the observation, thinks briefly, and replies with
actions (and in-character speech). It decides about every 3 seconds of game
time by default (`--think-every 60` ticks); each decision is one API call, so
leave it running only as long as you want to pay for. Several can run at once,
each in its own terminal, and they hear and answer each other.

### Files

- `agents/agent.gd`: the base class (observe, decide, act).
- `agents/observation.gd`: builds what an agent perceives.
- `agents/actions.gd`: the action list and how each becomes a command.
- `agents/agent_runtime.gd`: runs agents after every tick, on the server.
- `agents/examples/`: `patrol_agent.gd` (walks waypoints) and
  `curious_agent.gd` (greets everything it meets, avoids water, rests at
  night, answers when spoken to).
- `agents/bridge/`: the TCP bridge for outside programs.
- `examples/agents/`: Python client, a wander bot, and the Claude agent.

Agents are deterministic when their own code is (the example agents seed their
own random numbers), and a test checks that the same seed and the same agents
give an identical world.
