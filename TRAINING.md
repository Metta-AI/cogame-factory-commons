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
Factory Commons's job and cube choices could support a factorized discrete RL
codec, but the current Metta RL and PufferLib bridges do not expose its action
and observation.
