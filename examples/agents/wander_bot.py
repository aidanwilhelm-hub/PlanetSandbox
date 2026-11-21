"""The smallest useful bot: walk toward open land by day, rest at night."""

from planet_agent import run


def decide(obs):
    if not obs["time"]["is_day"]:
        return [{"action": "stop"}]
    if obs["self"]["state"] == "moving":
        return []
    best = max(obs["surroundings"], key=lambda s: s["walkable"])
    return [{"action": "move", "bearing": best["bearing"], "distance": best["walkable"]}]


if __name__ == "__main__":
    run(decide, name="wander-bot")
