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

## Teacher exports (scripted mechanics only)

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
Mixed selection cycles separately within each split, retaining all five training
wordings. Episode IDs include requested selection, resolved wording, and prompt seed
for matched collections. Historical seed labels exclude variant and
wording; multiples of five enter validation. These aliases do not establish
physical independence because the simulator does not consume the seed. Held-out wordings are rejected.
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
uv run tool recipes.external.coworld.train \
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

## Ordinary native private capture

Set `COGAME_SAVE_TRAJECTORY_URI` to a private, episode-scoped destination to
collect decisions from the ordinary game server. The public player interface,
simultaneous three-seat views, physical kernel and clocks are unchanged. The private destination must differ from the public results and
replay destinations. Without it, the capture path does no private projection or
hashing.

Records preserve the actual native request body and safe headers, received
response body bytes exposed by Curly, status, receipt/request IDs, failed attempts,
parsed proposals and installed standing orders. These are the HTTP entity bytes
returned by the native transport; compressed wire bytes and raw header bytes are
not available and are not claimed. Authorization and cookie headers are excluded.
The native parser remains tolerant, while learning eligibility requires strict
JSON and unchanged supplied types and values. Supported fences and omitted native
defaults can qualify; normalization, truncation, ignored fields, duplicate keys,
nonfinite numbers, fallback and external actions cannot become selected model
labels. Provider receipt verification remains a separate admission requirement.

The native standing-order parser rejects non-Unicode scalar strings or keys,
including ignored fields, before installing an order. These replies follow the
existing invalid-response retry and Steward fallback path; valid text, tolerant
parsing, defaults and rune caps remain unchanged. Original received response
bytes remain captured before rejection and are never repaired into labels.
Recursive Unicode scalar checks separately protect private JSONL. If any native
evidence cannot be represented there, its original serialization is retained as
base64 with no selected attempt, no action target and no active attempts; actual
fallbacks remain fallbacks. Such an episode is marked as an evidence failure.
The mixed HTTP fixture requires subsequent requests and the public replay to
remain Unicode scalar UTF-8 while retaining malformed response bytes privately.

`notes` overwrites the prior notebook, including when omitted or empty. Frozen
seat views contain only that seat's notebook, and per-seat execution metadata
removes foreign notebooks from order events. Public `say` and previous orders are
visible next shift. The existing postgame spectator replay already serializes
order-event notes; this capture change does not change that replay visibility.

An installed `strip` order remains the authoritative standing action even when
the kernel blocks or redirects its physical work. Per-tick state hashes, actual
events and replay frames record what happened physically. Primitive control bytes
are not recorded and are not represented as if they were.

The physical family is bound to the actual initialized floor and module state
before any history. All four published variants and all unused seed aliases share
one conservative physical family. Separate causal condition hashes retain the
active rule and deterministic supply/degradation differences. Changing the seed
does not produce a new world: the simulator never consumes it. The historical
offline exporter's seed-modulo partitions therefore establish no independent
physical holdout. Preserve existing exports as historical mechanics evidence;
condition or wording holdouts answer only separately predeclared, limited
questions and must not be reported as independent worlds.

For a complete local native system check, build the ordinary game, bundled player
and independent checker using the pinned toolchain and dependencies, then run:

```sh
python tools/test_native_capture.py --game /path/to/factory-commons \
  --player /path/to/factory-commons-player --variant factory-commons \
  --output /private/unique-factory-check
/path/to/check-native /private/unique-factory-check/config.json \
  /private/unique-factory-check/trajectory.jsonl \
  /private/unique-factory-check/replay.json 'native fixture only'
```

The Python harness requires `websockets` for actual spectator and external-player
WebSocket probes. It preserves 15 shifts × 60 ticks, 12-second batch pacing,
20-second native HTTP deadlines, one retry and the 20-second shutdown grace. It
requires HTTP health before players, continuously drains the spectator stream,
checks Pong/health/client during waits, and logs process/resource and transport
metrics throughout execution. Runs are bounded to 360 seconds, 16 MiB retained
output and a 2 GiB free-disk floor. Its sentinel is bound only to loopback, child
environments exclude provider credentials, and every generated call/receipt is
explicitly fixture-only. These games produce zero teacher-authorized targets and
make no claims about model strategy quality or learning.
