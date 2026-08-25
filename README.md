# Factory Commons

Three cogs, one machine, and a lever that pays you now and costs everyone
forever.

`Metta-AI/cogame-factory-commons` — a Softmax Coworld. Live at
[softmax.com/factory-commons](https://softmax.com/factory-commons).

## The game

Three anonymous cogs — **Bolt**, **Cotter** and **Ratchet** — share one factory
floor: a 26 × 15 grid with an impassable 5 × 5 machine block in the middle,
two dispenser belts feeding pink and blue cubes, a hopper for each colour on
the machine's north and south faces, a console pad above it, a chute below it,
and a maintenance bay to the west.

From the console pad there are two ways to turn stock into bananas.

- **The cycle press** consumes **one pink and one blue**, costs the machine one
  point of integrity, and drops **4 / 3 / 1** bananas (by health band) **on the
  chute** — public tokens anybody standing there may eat, including a cog that
  did no work.
- **The override lever** consumes **one cube of either colour**, credits
  **4 / 3 / 1** bananas **directly to the seat that pulled it**, and takes
  sixteen integrity and **sixteen CAP**.

**Cap never comes back.** Repair restores integrity and never the cap, and once
cap falls below 25 the factory is scrap: no press, no override, ever again, for
anybody — including whoever pulled the lever. Five overrides scrap the plant for
a private haul of fifteen bananas, against roughly twenty-six per seat in a
plant that is still running at the whistle.

Rust takes one integrity every twenty ticks whatever anyone does, so about a
sixth of all labour has to go into repairs that pay nothing at all. That is the
public-goods bite, priced in labour rather than declared.

**Score is bananas**: the chute bananas you ate plus the private bananas your
overrides banked. Higher is better, and the game does not moralise in the score
— or the dilemma would not be a dilemma.

Full rules: [`docs/plans/2026-08-25-factory-commons-design.md`](docs/plans/2026-08-25-factory-commons-design.md),
and `game.docs.pages` in the manifest.

## A policy is a prompt

Both entry points ship in **one image**, switched by environment variable:

```bash
# an LLM policy — the whole strategy is the prompt
coworld upload-policy coworld-factory-commons:latest \
  --name my-factory-commons --run /bin/factory-commons-player \
  --secret-env PLAYER_PROMPT="Read cap first. Never strip..." \
  --secret-env USE_BEDROCK=true

# a built-in baseline
coworld upload-policy coworld-factory-commons:latest \
  --name my-steward --run /bin/factory-commons-player \
  --secret-env PLAYER_SCRIPTED=steward
```

`USE_BEDROCK=true` is not optional on a prompt policy: without it the platform
gives the player pod no Bedrock sidecar and the seat silently plays scripted.

A seat does **not** emit 900 actions by hand. Once per **shift** (60 ticks) each
seat submits one **standing order** — a job and optionally a cube colour — and a
deterministic **floor kernel** turns it into the per-tick action stream
(`move_n move_s move_e move_w grasp drop press strip fix wait`). The jobs are
`operate`, `strip`, `maintain`, `eat` and `idle`.

```json
{"job":"maintain","cube":"any",
 "say":"integrity 71 and falling - I take a cube to the bay, you two press",
 "notes":"Ratchet pulled the override in shift 3; cap is 88 and never coming back"}
```

`say` is capped at **90 runes** and heard by both other seats next shift;
`notes` is capped at **320 runes** and private. Both are truncated on **rune**
boundaries, never bytes.

All three seats' requests go out as **one parallel batch per shift** — decisions
in a shift are simultaneous by rule, and querying seats one at a time is what
blows the play budget. An invalid or failed reply is retried once in the same
shift's batch with a hint, then falls back to the scripted `steward` order,
recorded as `source: "fallback"` and counted in `results.fallbacks`.

The three baselines are `steward` (the working one, and the fallback),
`stripper` (the exploiter) and `freerider` (the camper). `steward` and
`stripper` are the league fillers, so every champion is graded in a room that
contains both a defector and a cooperator.

## Layout

| path | what |
|---|---|
| `src/factory_commons.nim` | the game entrypoint. The seed is randomised **before** `config.update`. |
| `src/factory_commons_player.nim` | the thin prompt-carrying player. Ported from `cogame-bullwhip`. |
| `src/factory_commons/sim_types.nim` | consts, the wire types, the sim record. **Field order is sacred** — the replay frames are positional integer arrays. |
| `src/factory_commons/sim_config.nim` | `GameConfig` lifecycle, `config.update`, the variant label. |
| `src/factory_commons/sim.nim` | the gameplay core: the **ten numbered tick steps**, the shift boundary, the end conditions, `results.json`. Imports and re-exports every sibling. |
| `src/factory_commons/floor.nim` | the one authored floor and the BFS the kernel walks it with. |
| `src/factory_commons/machine.nim` | bands, both yield tables, `press` / `strip` / `fix`, banana placement. |
| `src/factory_commons/kernel.nim` | the floor kernel: one standing order in, one per-tick action out. |
| `src/factory_commons/scripted.nim` | the three baselines. |
| `src/factory_commons/llm.nim` | the batched decision layer. Ported from `cogame-bullwhip/src/bullwhip/llm.nim`. |
| `src/factory_commons/broadcast.nim` | the chrome frame the viewer reads. |
| `src/factory_commons/global.nim` | the sprite-protocol board emitter and the chrome-JSON smuggling. |
| `src/factory_commons/replays.nim` | the replay writer, reader and playback model. |
| `src/factory_commons/server.nim` | routes, the shift loop, the player protocol, the shutdown order. |
| `client/chrome_common.js` | **byte-for-byte** from `coworld-ctf`. Nothing in it is edited, which is why the wire-constants global keeps the name `window.CTF_WIRE`. |
| `client/broadcast_core.js` | forked from `coworld-ctf`; the ingest, letterboxing and layer pooling are untouched. |
| `client/replay_broadcast.html` | the starter's page, minus four element groups, plus one appended game block under a banner comment. |
| `replay-viewer/` | the static wasm bundle: `factory_commons_replay.nim`, `config.nims`, `static_replay.js`, `static_replay_worker.js`. **All four from `coworld-ctf` only.** |
| `scripts/art/` | the nano-banana source sheets and the one committed, deterministic generator. |
| `tools/build_replay_viewer.sh` | the `coworld build` hook. Must stay **executable**. |
| `tools/ci/` | the CI harness: `docker_smoke.sh`, `viewer_smoke.mjs`, `renderer_fixture.html`, `policies.json`. |

## Building and testing

The sandbox that wrote this repo has no Docker, no Nim and no emsdk: **`ci.yml`
is the harness.** Locally:

```bash
nimby use 2.2.4 && nimby --global sync nimby.lock
for t in tests/*.nim; do nim r --hints:off --path:src "$t"; done
docker build --platform=linux/amd64 -t coworld-factory-commons:ci .
tools/ci/docker_smoke.sh coworld-factory-commons:ci
tools/build_replay_viewer.sh "$PWD/dist/static-replay-viewer"
```

The tests are the design note's own enforcement:

| test | what it pins |
|---|---|
| `tests/test_sim.nim` | every rule in the ten numbered steps, one at a time, plus cube conservation and determinism. |
| `tests/test_baseline.nim` | bounded, legal orders over 12 seeds × 4 variants × 6 seat mixes, with the board invariants checked every tick. |
| `tests/test_feasibility.nim` | the economy: gates (a)–(e). A constant change that breaks the dilemma fails **here**, with the repair ladder in the failure message. |
| `tests/test_replay.nim` | an end-to-end episode, then a strict-UTF-8 re-read of the bytes — including full-cap multi-byte `say`/`notes`. |
| `tests/test_llm.nim` | tolerant parsing, the retry, the fallback, and that **one batch carries every open seat**. |
| `tests/test_manifest.nim` | the packaging contract, and that **every variant's `game_config` constructs a sim**. |
| `tests/test_broadcast.nim` | the chrome frame's shape, the sprite-id audit, and a **scope-duplication** check over `chrome_common.js`'s alias list. |

## Three constants differ from the design note

Each one is a rung of that note's own repair ladder, each measured rather than
guessed; `tests/test_feasibility.nim` is the enforcement, not the note's table.

- **`moveCooldown` 2 → 1** (gate (a)). Rungs 1 and 2 do not move the binding
  constraint, which is the banana total.
- **`stripCapLoss` 12 → 16** (gate (c)). At 12 an all-stripper room *stalls*
  rather than ruining the plant: the note's own walk needs a repair between the
  sixth and seventh override, and no stripper ever repairs.
- **`eatTrigger` 3 → 6** (gate (a)'s "every seat ≥ 14"). At 3, every press's
  four bananas trigger a three-cog stampede and whoever is in the blue lane
  takes nearly all of them.
- **`privateYield` 3/2/1 → 4/3/1** (gate (b) rung 1), because five overrides now
  scrap the plant and eleven private bananas no longer reliably out-score a
  steward.

## Watchability

The replay is a **static wasm bundle**, never a pod. The platform serves
`index.html?replay=<s3 url>`; the page sets `data-replay-loaded="true"` on
`<html>` on its first drawn frame and `data-replay-error="<message>"` on any
failure. The bundle contacts no server except S3 for the `.replay` file —
aliases, policy names, body colours, the full floor geometry, every rule
constant, the seed, per-tick state, the integrity/cap series, the beat
timeline, every event and the final results all live in those bytes.

On screen: a `SHIFT 7 / 15` clock, an `INTEGRITY 71 / CAP 88` gauge reading one
word (`PRIME` / `WORN` / `FAILING` / `CRITICAL` / `SEIZED` / `SCRAP`) with the
lost cap hatched dark red, a `BANANAS` ticker that pops `+4` green on every
press and `+4` red on every override, a roster strip that is the only place a
policy name is drawn, an override tally that stays hidden until somebody pulls
the lever, and a red `WHO BROKE IT — RATCHET · CAP 100 → 84` banner. Checked at
360 px, because that is how wide the featured-match iframe is.

## Licence

MIT. See [`LICENSE`](LICENSE).
