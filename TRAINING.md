# Factory Commons training

Factory Commons has a local simulator and hosted text players. Export complete
games for Metta post-training with the same per-seat prompts and reply parser
as the hosted player:

```bash
nimby sync nimby.lock
nim r --path:src tools/export_posttrain.nim /tmp/factory-default 10 1 factory-commons
nim r --path:src tools/export_posttrain.nim /tmp/factory-either 10 1 either-or
nim r --path:src tools/export_posttrain.nim /tmp/factory-fragile 10 1 fragile-plant
nim r --path:src tools/export_posttrain.nim /tmp/factory-abundant 10 1 abundant-feed
```

The exporter reads each certified `game_config` from
`coworld_manifest_template.json`, runs seeded games with the published steward
player, and writes `train.jsonl`, `validation.jsonl`,
and `manifest.json`. Seeds divisible by five go to validation, keeping each
game entirely in one split. Each standing order passes the hosted parser and
native simulator. The exporter refuses an existing output directory.

Train the text policy with Metta's post-training CLI:

```bash
uv run python -m metta_posttrain.train --dataset /tmp/factory-default \
  --output /tmp/factory-model --model Qwen/Qwen2.5-0.5B-Instruct \
  --max-steps 100 --max-length 4096
```

The dataset imitates scripted play; its loss does not measure policy quality.

For native PufferLib reinforcement learning, compile the persistent decision
bridge and pass it to Metta's Coworld recipe:

```bash
nim c -d:release --path:src -o:factory-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py ./factory-train-bridge
uv run ./tools/run.py recipes.external.coworld.train \
  'command=["/absolute/path/to/factory-train-bridge","/absolute/path/to/coworld_manifest_template.json","factory-commons"]' \
  players=3 total_timesteps=100000
```

The last command runs from the Metta repository. Change the final argument to
`either-or`, `fragile-plant`, or `abundant-feed` for the other certified
variants. The bridge exposes 54 player-visible numeric values and independent
job and cube heads with widths 5 and 3. The job mask follows the game's
published legal-job list, including strip lockout. The steward provides
opponent actions and optional teacher labels. Metta recipe support is in
#24679, stacked on #24573.
