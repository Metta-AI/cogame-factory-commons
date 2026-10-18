"""Export complete Factory Commons games and verify installed orders and tick evidence."""

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
EXPORTER = Path(sys.argv[1]).resolve()
OUTPUT = Path(tempfile.mkdtemp(prefix="factory-commons-source-export-"))
revision = subprocess.check_output(
    ["git", "rev-parse", "HEAD"], cwd=ROOT, text=True
).strip()
VARIANTS = ("factory-commons", "either-or", "fragile-plant", "abundant-feed")
VOCABULARY = {
    "wait",
    "move_n",
    "move_s",
    "move_e",
    "move_w",
    "grasp",
    "drop",
    "press",
    "strip",
    "fix",
}
for variant in VARIANTS:
    output = OUTPUT / variant
    subprocess.run(
        [str(EXPORTER), str(output), "10", "1", variant],
        cwd=ROOT,
        check=True,
        timeout=600,
    )
    manifest = json.loads((output / "manifest.json").read_text())
    assert manifest["source_revision"] == revision and len(manifest["runs"]) == 10
    assert (
        not (output / "train.jsonl").exists()
        and not (output / "validation.jsonl").exists()
    )
    episodes, decisions, executions = {}, {}, {}
    for filename in ("manifest.json", "trajectories.jsonl", "execution.jsonl"):
        assert (output / filename).stat().st_mode & 0o777 == 0o600
    for line in (output / "trajectories.jsonl").read_text().splitlines():
        row = json.loads(line)
        assert row["source_revision"] == revision
        episode = row["episode_id"]
        if row["event_type"] == "episode":
            episodes[episode] = row
            continue
        decisions.setdefault(episode, []).append(row)
        assert row["visibility"] == "private" and row["action_status"] == "accepted"
        (attempt,) = row["attempts"]
        assert attempt["origin"] == "teacher" and attempt["request"] is None
        assert (
            attempt["platform_call_id"] is None and attempt["behavior_logprobs"] is None
        )
        assert (
            row["selected_attempt_id"] == attempt["attempt_id"] and attempt["accepted"]
        )
        assert (
            row["executed_action"]
            == attempt["parsed_action"]
            == json.loads(attempt["response"])
        )
        view = row["observation"]
        assert all("notes" not in other for other in view["cogs"])
        metadata = view["prompt_template"]
        assert (
            metadata["bank"] == "factory-commons-rules-v1"
            and metadata["variant"] == "canonical"
        )
        for message in attempt["prompt"]:
            assert (
                metadata[message["role"] + "_sha256"].lower()
                == hashlib.sha256(message["content"].encode()).hexdigest()
            )
    with (output / "execution.jsonl").open() as stream:
        for line in stream:
            row = json.loads(line)
            executions.setdefault(row["episode_id"], []).append(row)
            assert row["visibility"] == "private" and row["source_revision"] == revision
    assert len(episodes) == 10 and set(episodes) == set(decisions) == set(executions)
    for episode, outcome in episodes.items():
        rows, shifts = decisions[episode], executions[episode]
        assert (
            outcome["status"] == "completed"
            and outcome["outcome"]["reason"] == "complete"
        )
        assert (
            outcome["outcome"]["shifts"] == 15
            and outcome["outcome"]["ending"] == "shift_limit"
        )
        assert len(rows) == 45 and len(shifts) == 15
        assert sum(row["terminal"] for row in rows) == 1 and rows[-1]["terminal"]
        last_orders = None
        for index, shift in enumerate(shifts):
            batch = rows[index * 3 : (index + 1) * 3]
            assert shift["decision_ids"] == [row["decision_id"] for row in batch]
            assert (
                shift["start_tick"] == index * 60
                and shift["end_tick"] == (index + 1) * 60
            )
            assert [frame["t"] for frame in shift["frames"]] == list(
                range(index * 60, (index + 1) * 60)
            )
            assert len(shift["kernel_actions"]) == 60
            assert all(
                len(actions) == 3 and set(actions) <= VOCABULARY
                for actions in shift["kernel_actions"]
            )
            assert shift["terminal"] == (index == 14)
            assert shift["event_end"] - shift["event_start"] == len(shift["events"])
            if index:
                assert shift["event_start"] == shifts[index - 1]["event_end"]
            orders = [event for event in shift["events"] if event["k"] == "order"]
            assert len(orders) == 3
            public = None
            for seat, (row, order) in enumerate(zip(batch, orders, strict=True)):
                assert row["seat"] == str(seat) and order["seat"] == seat
                assert row["executed_action"] == {
                    key: order[key] for key in ("job", "cube", "say", "notes")
                }
                assert order["source"] == "scripted"
                view = row["observation"]
                cogs = [
                    {key: value for key, value in cog.items() if key != "you"}
                    for cog in view["cogs"]
                ]
                snapshot = (view["machine"], cogs, view["history"], view["bananas"])
                if seat == 0:
                    public = snapshot
                assert snapshot == public
                if last_orders is not None:
                    assert [cog["lastOrder"] for cog in cogs] == last_orders
            last_orders = [
                {key: order[key] for key in ("job", "cube")} for order in orders
            ]
        for seat in range(3):
            assert (
                outcome["participant_outcomes"][str(seat)]["score"]
                == outcome["outcome"]["scores"][seat]
            )
    assert {row["seed_family"] for row in episodes.values()} == {
        f"factory-commons-{seed}" for seed in range(1, 11)
    }
    print(
        variant,
        "10 complete exports; frozen observations, hashes, installed orders and tick evidence PASS",
        flush=True,
    )
print("Evidence:", OUTPUT)
