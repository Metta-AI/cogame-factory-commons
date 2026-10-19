"""Check complete seeded mixed-wording exports for all four Factory Commons variants."""

import json
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VARIANTS = ("factory-commons", "either-or", "fragile-plant", "abundant-feed")

if __name__ == "__main__":
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as temp:
        for variant in VARIANTS:
            output = Path(temp) / variant
            subprocess.run(
                [str(binary), str(output), "10", "1", variant, "mixed", "0"],
                cwd=ROOT,
                check=True,
            )
            manifest = json.loads((output / "manifest.json").read_text())
            assert len(manifest["runs"]) == 10
            assert [run["prompt_selection"]["variant"] for run in manifest["runs"]] == [
                "canonical",
                "plain",
                "numbered",
                "questions",
                "reordered",
            ] * 2
            assert all(
                run["decisions"] == 3 * run["shifts_played"]
                and run["shifts_played"] == 15
                and len(run["scores"]) == 3
                for run in manifest["runs"]
            )
            families, counts = {}, {}
            for split in ("train", "validation"):
                rows = [
                    json.loads(line)
                    for line in (output / f"{split}.jsonl").read_text().splitlines()
                ]
                assert len(rows) == manifest[split + "_examples"] > 0
                families[split] = {row["seed"] for row in rows}
                for row in rows:
                    assert row["game"] == "factory-commons"
                    assert [message["role"] for message in row["prompt"]] == [
                        "system",
                        "user",
                    ]
                    order = json.loads(row["completion"][0]["content"])
                    assert order["job"] in {
                        "operate",
                        "strip",
                        "maintain",
                        "eat",
                        "idle",
                    }
                    assert order["cube"] in {"pink", "blue", "any"}
                    assert len(order["notes"]) <= 320 and len(order["say"]) <= 90
                    assert row["prompt_template"]["variant"] not in (
                        "heldout-briefing",
                        "heldout-reference",
                    )
                    counts[row["seed"]] = counts.get(row["seed"], 0) + 1
            assert families["train"].isdisjoint(families["validation"])
            assert all(
                counts[f"factory-commons-{run['seed']}"] == run["decisions"]
                for run in manifest["runs"]
            )
            print(variant, "10 complete mixed exports PASS", flush=True)
