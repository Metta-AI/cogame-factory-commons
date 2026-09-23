"""Exercise every certified Factory Commons variant through the JSONL bridge."""

import json
import subprocess
import sys
from pathlib import Path


manifest = Path(__file__).resolve().parents[1] / "coworld_manifest_template.json"
for variant in ("factory-commons", "either-or", "fragile-plant", "abundant-feed"):
    with subprocess.Popen(
        [sys.argv[1], str(manifest), variant],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
    ) as bridge:
        assert bridge.stdin is not None and bridge.stdout is not None

        def request(payload):
            bridge.stdin.write(json.dumps(payload) + "\n")
            bridge.stdin.flush()
            return json.loads(bridge.stdout.readline())

        observation = request({"kind": "reset", "seed": "bridge-test", "players": 3})
        masks = set()
        decisions = 0
        while observation["kind"] == "decision":
            encoded = request({"kind": "encode"})
            assert encoded["decision_id"] == observation["decision_id"]
            assert len(encoded["values"]) == 54
            assert [len(head["choices"]) for head in encoded["action_heads"]] == [5, 3]
            masks.add(tuple(choice is not None for choice in encoded["action_heads"][0]["choices"]))
            response = request({"kind": "teacher"})["response"]
            action = json.loads(response)
            for head in encoded["action_heads"]:
                assert action[head["name"]] in head["choices"]
            result = request({"kind": "step", "decision_id": observation["decision_id"], "response": response})
            assert result["kind"] == "accepted" and result["action"] == action
            observation = result["observation"]
            decisions += 1
        assert decisions == 45 and set(observation["scores"]) == {"0", "1", "2"}
        if variant == "either-or":
            assert (True, False, True, True, True) in masks
        bridge.stdin.close()
        assert bridge.wait() == 0
    print(f"{variant}: {decisions} decisions")
