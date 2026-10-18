"""Complete published Factory Commons games with frozen observations and matched wording."""

import hashlib
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BRIDGE, ORIGINAL = [Path(value).resolve() for value in sys.argv[1:3]]
VARIANTS = ("factory-commons", "either-or", "fragile-plant", "abundant-feed")
WORDINGS = (
    "canonical",
    "plain",
    "numbered",
    "questions",
    "reordered",
    "heldout-briefing",
    "heldout-reference",
)


def play(
    variant,
    seed,
    wording="canonical",
    prompt_seed=0,
    original=False,
    normalize=False,
    locked_strip=False,
):
    command = [
        str(ORIGINAL if original else BRIDGE),
        str(ROOT / "coworld_manifest_template.json"),
        variant,
    ]
    if not original:
        command.append("text")
    with subprocess.Popen(
        command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True
    ) as process:
        assert process.stdin is not None and process.stdout is not None

        def request(value):
            process.stdin.write(json.dumps(value) + "\n")
            process.stdin.flush()
            return json.loads(process.stdout.readline())

        observation = request(
            {
                "kind": "reset",
                "seed": str(seed),
                "players": 3,
                "promptVariant": wording,
                "promptSeed": prompt_seed,
                "split": "test",
            }
        )
        trace, physical, systems = [], [], {}
        locked_orders = 0
        frozen = None
        last_orders = [{"job": "idle", "cube": "any"} for _ in range(3)]
        previous_cogs = None
        while observation["kind"] == "decision":
            index, seat = observation["decision_id"], observation["seat"]
            assert index == len(trace) and seat == index % 3
            view = observation["semantic_view"].copy()
            messages = observation["messages"]
            assert (
                systems.setdefault(seat, messages[0]["content"])
                == messages[0]["content"]
            )
            if not original:
                metadata = view.pop("prompt_template")
                assert metadata["bank"] == "factory-commons-rules-v1"
                assert metadata["variant"] == (
                    WORDINGS[prompt_seed] if wording == "mixed" else wording
                )
                for message in messages:
                    assert (
                        metadata[message["role"] + "_sha256"].lower()
                        == hashlib.sha256(message["content"].encode()).hexdigest()
                    )
                cogs = [
                    {key: value for key, value in cog.items() if key != "you"}
                    for cog in view["cogs"]
                ]
                public = (view["machine"], cogs, view["history"], view["bananas"])
                if seat == 0:
                    frozen = public
                    if previous_cogs is not None:
                        assert [cog["lastOrder"] for cog in cogs] == last_orders
                    previous_cogs = cogs
                assert public == frozen
                assert all("notes" not in cog for cog in view["cogs"])
                if normalize:
                    for other in range(3):
                        if other != seat:
                            assert (
                                f"PRIVATE-{other}-"
                                not in json.dumps(view) + messages[1]["content"]
                            )
                    if index >= 3:
                        assert (
                            view["notes"].startswith(f"PRIVATE-{seat}-")
                            and len(view["notes"]) == 320
                        )
            action = json.loads(request({"kind": "teacher"})["response"])
            if locked_strip and "strip" not in view["legalJobs"]:
                action["job"] = "strip"
                locked_orders += 1
            if normalize:
                action["job"] = " " + action["job"].upper() + " "
                action["cube"] = " " + action["cube"].upper() + " "
                action["say"] = f"PUBLIC-{seat}\n" + "δ" * 100
                action["notes"] = f"PRIVATE-{seat}-" + "λ" * 350
            result = request(
                {"kind": "step", "decision_id": index, "response": json.dumps(action)}
            )
            assert result["kind"] == "accepted"
            installed = result["action"]
            last_orders[seat] = {key: installed[key] for key in ("job", "cube")}
            if normalize:
                assert installed["job"] == action["job"].strip().lower()
                assert installed["cube"] == action["cube"].strip().lower()
                assert len(installed["notes"]) == 320 and len(installed["say"]) == 90
                assert "\n" not in installed["say"]
            else:
                assert installed == action
            trace.append((view, messages[1]["content"], installed))
            physical.append(
                (
                    view["machine"],
                    view["history"],
                    [
                        (cog["cell"], cog["score"], cog["carrying"])
                        for cog in view["cogs"]
                    ],
                    installed["job"],
                    installed["cube"],
                )
            )
            observation = result["observation"]
        process.stdin.close()
        assert process.wait(timeout=10) == 0
        assert len(trace) == 45 and set(observation["scores"]) == {"0", "1", "2"}
        if locked_strip:
            assert locked_orders > 0
        return trace, physical, observation, systems


for variant in VARIANTS:
    for seed in (17, 946001):
        original = play(variant, seed, original=True)
        canonical = None
        systems = []
        for wording, prompt_seed in [(name, 0) for name in WORDINGS] + [
            ("mixed", index) for index in range(5)
        ]:
            result = play(variant, seed, wording, prompt_seed)
            assert result[1:3] == original[1:3]
            if wording == "canonical":
                canonical = result
                assert result[3] == original[3]
            else:
                assert result[:3] == canonical[:3]
            if wording == "mixed":
                assert result[3] == systems[prompt_seed]
            else:
                systems.append(result[3])
        assert all(len({system[seat] for system in systems}) == 7 for seat in range(3))
    play(variant, 17, normalize=True)
    print(
        variant,
        "24 matched text games, two original games, private notes and normalization PASS",
        flush=True,
    )
for wording in WORDINGS[-2:]:
    rejected = subprocess.run(
        [
            str(BRIDGE),
            str(ROOT / "coworld_manifest_template.json"),
            VARIANTS[0],
            "text",
        ],
        input=json.dumps(
            {
                "kind": "reset",
                "seed": "17",
                "players": 3,
                "promptVariant": wording,
                "split": "train",
            }
        )
        + "\n",
        text=True,
        capture_output=True,
        timeout=10,
    )
    assert (
        rejected.returncode != 0
        and "held-out wording is evaluation-only" in rejected.stderr
    )
play("either-or", 17, locked_strip=True)
print(
    "101 complete text games, eight original comparisons, held-out training gate and locked-strip acceptance PASS"
)
