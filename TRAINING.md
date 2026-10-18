# Factory Commons training

## Episode-stable prompt variants

`canonical` preserves the original system prompt. Five training introductions
(`canonical`, `plain`, `numbered`, `questions`, `reordered`) paraphrase the role,
other cogs, shared factory, and absence of teams. Shared rules stay fixed.
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

## Reviewed candidate exports

Build once and export from a clean committed checkout:

```sh
nim c -d:release --path:src -o:/tmp/factory-export tools/export_posttrain.nim
for variant in factory-commons either-or fragile-plant abundant-feed; do
  /tmp/factory-export "/tmp/factory-${variant}" 10 1 "$variant" canonical 0
done
```

The steward supplies proposals for complete published games: three cogs,
15 shifts, and 60 ticks per shift. The engine's ordinary early endings remain
valid. The exporter freezes observations, parses orders, applies them, and
records actual per-tick actions and resulting frames without changing simulation.

Private `trajectories.jsonl`, `execution.jsonl`, and `manifest.json` files retain
source revision, exact messages, hashes, installed orders, event intervals,
actions, frames, and outcomes. Teacher rows have no inference request, platform
call identifier, or behavior log probabilities. Files use private permissions.

These are candidates. Convert with Coworld's `export_complete_episodes`, then
use Metta's independent source-hash review gate before label export. Keep each
`factory-commons-SEED` family together across game variants and wordings.
No automatic train/validation files are emitted. At least ten games are required;
existing destinations and held-out wording exports are rejected.

## Native evidence and validation

Optional `FACTORY_COMMONS_HOST_TRACE_PATH` and `FACTORY_COMMONS_ATTEMPT_TRACE_DIR`
capture private host decisions and actual model attempts. Set
`FACTORY_COMMONS_SOURCE_REVISION` to the qualified revision. Evidence preserves
request bodies, retry messages, hashes, raw responses, parse results, failures,
installed orders, actions, and replay frames. Keep these files private.

```sh
python3 tools/test_prompt_games.py /tmp/factory-bridge /tmp/original-factory-bridge
python3 tools/test_export_posttrain.py /tmp/factory-export
python3 tools/test_native_prompts.py /tmp/factory-game /tmp/factory-player /tmp/factory-native
```

The prompt panel plays 101 complete games with eight original numeric comparisons.
The export panel checks 40 games. The native panel plays eleven published games
with real host/player processes and a reserved closed inference endpoint;
`--smoke` runs two canonical variants. These checks establish invariants and
execution, not successful provider inference or improved learning.

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
