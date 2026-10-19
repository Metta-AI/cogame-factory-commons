# Factory Commons training

## Episode-stable prompt variants

`canonical` preserves the original system prompt. Five training wordings
(`canonical`, `plain`, `numbered`, `questions`, `reordered`) paraphrase the role,
other cogs, job responsibilities, and scoring. The v2 bank preserves machine
facts, configuration-derived numbers, strategic hints, and output grammar.
`mixed` selects using an explicit nonnegative `promptSeed % 5`, independently
of simulator randomness. Selection remains fixed throughout an episode.
`heldout-briefing` and `heldout-reference` are evaluation-only.

## Complete text collection

The bridge accepts an optional third argument, `text`. Reset accepts
`promptVariant`, `promptSeed`, and `split`; held-out training collection is rejected.
Full actions include `job`, `cube`, public `say`, and private `notes` through
the production parser. Text mode retains the hosted parser's tolerance for
`strip` orders even when the floor kernel cannot perform them. Numeric masks
retain their existing meaning.

All three seats observe one frozen state before any new order is installed.
This fixes the former bridge/export leak of earlier seats' current orders.
Seat-visible observations contain only that seat's private notes, exact message
hashes, bank version, resolved wording, and selection seed.

## Teacher exports

Build once and export from a clean committed checkout:

```sh
nim c -d:release --path:src -o:/tmp/factory-export tools/export_posttrain.nim
for variant in factory-commons either-or fragile-plant abundant-feed; do
  /tmp/factory-export "/tmp/factory-${variant}" 10 1 "$variant" mixed 0
done
```

The steward supplies proposals for complete published games: three cogs,
15 shifts, and 60 ticks per shift. The engine's ordinary early endings remain
valid. The exporter freezes observations, parses orders, applies them, and
plays each shift through the production kernel. Applied orders may be blocked
by the floor rules; an installed order does not guarantee each primitive succeeds.

The original `train.jsonl`, `validation.jsonl`, and `manifest.json` format
is preserved. Rows record wording metadata and exact message hashes.
Mixed selection advances once per game. Seed families exclude variant and
wording; multiples of five enter validation. Held-out wordings are rejected.
Output directories are private and must not already exist.

## Validation

```sh
python3 tools/test_prompt_games.py /tmp/factory-bridge
python3 tools/test_export_posttrain.py /tmp/factory-export
```

The wording workflow plays 41 complete games across all four variants, including
private notes, normalized orders, and a kernel-blocked strip order.
The export workflow checks 40 complete games, seed-family separation, and
action grammar. These checks establish mechanics and protocol behavior,
not better learning or resistance to policy collapse.

## Numeric reinforcement learning

For native PufferLib reinforcement learning, compile the persistent decision
bridge and pass it to Metta's Coworld recipe:

```bash
nim c -d:release --path:src -o:/tmp/factory-train-bridge tools/train_bridge.nim
python3 tools/test_train_bridge.py /tmp/factory-train-bridge
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
