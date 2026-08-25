# Factory Commons — three cogs, one machine, and a lever that pays you now and costs everyone forever

**Starter: `Metta-AI/coworld-ctf` (paintbot), mounted read-only at `/workspace/starters/coworld-ctf`.**
Factory Commons is a real-time grid loop with rules written fresh for this coworld, per-tick grid
actions (`move` / `grasp` / `drop` / `press`) and a per-tick replay — the first row of the starter
table ("any real-time game loop, grid OR continuous physics, new rules written for this coworld").
The Melting Pot substrate is the *design source*, not a binary to reproduce bit-exactly (the idea's
own build note says the mechanics are undocumented), so this is deliberately **not** a `cogame-moba`
port. Paintbot supplies the tick loop, the sprite-protocol board renderer, the broadcast chrome, the
static wasm replay bundle and the CI shape. **Every convention there holds here unless this note says
otherwise.** Two things paintbot does not have are ported from `Metta-AI/cogame-bullwhip` (mounted at
`/workspace/starters/cogame-bullwhip`) and are named as such where they appear: the *game-side*
batched LLM decision layer (`src/bullwhip/llm.nim`) and the thin prompt-carrying player process
(`src/bullwhip_player.nim`). **All four viewer files come from coworld-ctf only** (see `## Viewer`).
There is **no `OPEN` section**: the idea's build note asks for the sustainable-vs-exploitative rule to
be pinned from Lua that does not exist in this sandbox, so it is pinned here from first principles,
with the numbers and the reason stated, and enforced by a feasibility oracle in CI rather than by
prose.

**Design pins (`playbooks/make-coworld.md` §Phase 0 / `docs/SPEC.md` §Design pins), each answered
explicitly:**

| pin | how Factory Commons satisfies it |
|---|---|
| starter by game shape | `Metta-AI/coworld-ctf` (paintbot) — a real-time grid loop with per-tick grid actions and rules written for this coworld; nothing external is reproduced bit-for-bit (chemistry / daycare precedent, 2026-08-25). |
| public repo `Metta-AI/cogame-<slug>` | `Metta-AI/cogame-factory-commons`, **public** — a certification prerequisite (`source-resolves` 404s on private). |
| LLM policy **and** scripted baseline from day one, same image, env-switched | one image; `PLAYER_PROMPT="<strategy>"` vs `PLAYER_SCRIPTED=steward\|stripper\|freerider` (`## Decisions`). Champions #1 `factory-commons-foreman` (daveey) and #2 `factory-commons-custodian` (daveey-1) are both prompt policies; the two fillers are the scripted baselines `steward` and `stripper`. |
| static wasm replay viewer, never a pod | `"replay_viewer": {"bundle": "static-replay-viewer"}` + `tools/build_replay_viewer.sh`; no `/client/replay` live viewer is declared (`## Viewer`, `## Packaging`). |
| real art, starter chrome verbatim | `scripts/art/gen_factory_commons_art.py` commits floor/wall/machine/console/bay/belt/cube/banana/cog art; `client/chrome_common.js` ships **byte-for-byte** and `client/replay_broadcast.html` is the starter's page with a game block appended (`## Viewer`). |
| legible to a casual spectator | `SHIFT 7 / 15`, an `INTEGRITY 71 / CAP 88` gauge reading one word (`PRIME`/`WORN`/`FAILING`/`CRITICAL`/`SEIZED`/`SCRAP`), a `BANANAS 84` production ticker that pops `+4` on every press, and a red `WHO BROKE IT` banner naming the seat that pulled the override; checked at 360 px. |
| two name spaces | anonymous cog aliases `Bolt` / `Cotter` / `Ratchet` in-game and in every prompt; policy names only spectator-side (`roster[].pol`, the roster strip, `results.names`) — `## The game` §Seats. |
| degrade, never hang; play inside 60 % of `episodeTimeoutSeconds` | ≤ 631 s worst case against a 720 s budget, deadline checked between shifts, retry-once-then-scripted, `shutdownGraceSeconds = 20` (`## Decisions`, `## Server, player, protocol`). |
| `num_agents` in every variant AND the cert fixture | **3**, in all four variants, in `certification.game_config`, and as `<SEATS>` in `tools/ci/docker_smoke.sh` (`## Packaging`, `## Tests`). |
| replay bytes self-sufficient | aliases, policy names, body colours, full floor geometry, every rule constant, the seed, per-tick state, the integrity/cap series, beats, every event and the final results all live in the replay (`## Sim module` §The replay file). |
| prove it in CI | sim tests, bounded-orders/legality tests on all three baselines, a feasibility oracle, an end-to-end episode writing a replay, a strict-UTF-8 parse, an **executed** viewer smoke (`## Tests`). |

**Source idea (verbatim, Asana idea task 1217762644722022):**

> Port of Melting Pot's factory_commons (+ either_or). A shared factory: dispensers and hoppers move cubes, and cogs grasp/place blocks to operate machinery that produces consumable goods (bananas etc.). The machinery is a common-pool asset — it can be used in a way that keeps it producing, or exploited for a faster payout that degrades it for everyone. The either_or map forces a choice between two production modes. Commons dilemma with a crafting/assembly loop instead of a field.
>
> Seats: 3 (original)
> Motive: commons / public-goods maintenance with mechanism
> Policy interface: per-tick grid actions (move, grasp, drop, press)
> Fills gap: industrial flavour of the commons — a machine to maintain, not a resource to ration
> Integrity (anti-collusion): anonymous aliases; background-bot scoring.
>
> Replay plan (watchability): machine 'health' gauge, production ticker, and a visible 'who broke it' moment.
>
> Build note: factory_commons.py has no docstring and the mechanics above are reconstructed from the Melting Pot 2.0 paper + prefab names (dispenser belts, pink/blue cubes, hoppers, bananas). Read the Lua components and pin the exact sustainable-vs-exploitative rule before speccing.
>
> Source: substrates factory_commons, factory_commons__either_or.

---

## The game

### Seats, aliases, names

**`num_agents = 3`.** Exactly three seats, one cog each, one shared factory, no teams. Three is the
idea's number ("Seats: 3 (original)") and it is kept: three is the smallest room in which a
free-rider is anonymous-ish and a saboteur is not (with two seats "who broke it" is trivial, with
eight it is diffuse), and the whole labour arithmetic below is built on three pairs of hands against
one machine.

| slot | in-game cog alias | body colour (paintbot `slots[].color`) | spawn cell |
|---|---|---|---|
| 0 | `Bolt` | `red` | (10, 4) |
| 1 | `Cotter` | `blue` | (10, 10) |
| 2 | `Ratchet` | `yellow` | (13, 7) |

Aliases are fixed to slots and never rotate. Cells are `(col, row)`, origin top-left. Nobody is on a
team: the scorebug's two plates are the **machine** and the **production ticker**, not sides.

**Two name spaces (pin).** A seat sees only aliases — its own and the other two — in every
observation, every prompt and every broadcast `say`. No policy name, player name, account or model
name ever reaches a seat, and no seat ever sees the episode seed. The replay carries `policyNames[]`
alongside `names[]`; the viewer's roster strip shows the **policy** name for non-baseline seats
(paintbot's `roster[].pol` path in `client/chrome_common.js`, `teamPolicies()`), and
`results.names[]` carries policy names for the platform. Both, not either.

### The factory floor

- A fixed grid, `cols = 26` × `rows = 15`, cell size 48 board-px → a **1248 × 720** board. **The whole
  board always fits the frame**, which is why the viewer drops `#viewpanel` (zoom bar + minimap)
  entirely (`## Viewer`).
- **Walls:** the full border ring (row 0, row 14, col 0, col 25). Everything else is floor except the
  machine body.
- **The machine** (impassable, 5 × 5): cols 16..20 × rows 5..9. It is the only common-pool asset in
  the game.
- **North face, row 4** (all walkable): `(16,4)` = **pink hopper**, `(17,4)` = plain floor,
  `(18,4) (19,4) (20,4)` = the **console pad** (the two levers live here).
- **South face, row 10** (all walkable): `(16,10)` = **blue hopper**, `(17,10)` = plain floor,
  `(18,10) (19,10) (20,10)` = the **chute** (bananas land here).
- **West face, col 15, rows 6..8** (walkable): the **maintenance bay** (`fix` happens here).
- **East face, col 21, rows 5..9**: plain floor — a walkway, so the machine can be circled either way.
- **Two dispenser belts**, each a straight run of `beltLen = 7` cells running **east**:
  - **pink belt**: row 2, cols 2..8. Dispenser mouth `(2,2)`; belt tail `(8,2)`.
  - **blue belt**: row 12, cols 2..8. Dispenser mouth `(2,12)`; belt tail `(8,12)`.
- Every sim quantity is an **integer**; the RNG is paintbot's seeded stream and is used only for the
  arbitrary-but-tie-free choices the rules below name explicitly. No float enters sim state, so a
  seed reproduces a replay bit-exactly (the determinism test depends on it).

The geometry is deliberately **colour-symmetric and station-asymmetric**, which is what makes the
division of labour real:

| leg | cells | ticks at `moveCooldown = 2` |
|---|---|---|
| pink tail `(8,2)` → pink hopper `(16,4)` | 10 | 20 |
| blue tail `(8,12)` → blue hopper `(16,10)` | 10 | 20 |
| pink hopper `(16,4)` → console `(18,4)` | 2 | 4 |
| blue hopper `(16,10)` → console `(18,4)` | 10 | 20 |
| console `(18,4)` → chute `(18,10)` | 12 (either way round) | 24 |
| bay `(15,7)` → pink tail `(8,2)` | 12 | 24 |
| bay `(15,7)` → blue tail `(8,12)` | 12 | 24 |
| chute `(19,10)` → blue hopper `(16,10)` | 3 | 6 |

A one-colour supply loop (tail → hopper → tail, plus a `grasp` and a `drop`) is **42 ticks**. A cog
that tries to fetch *both* colours pays 36 ticks just crossing the plant, so specialising by colour
beats generalising — the coordination problem is in the floor plan, not in a rule.

### Cubes, hoppers and the machine's state

- **Dispensers** emit one cube of their colour onto their mouth cell every `dispensePeriod = 10`
  ticks, **if that cell is free**. A full belt stalls its dispenser; matter is never destroyed by a
  stall.
- **Belts advance** every `beltPeriod = 4` ticks: each cube on a belt moves one cell east if the next
  cell is on the belt and free. A cube on the **tail** cell does not move — it waits to be grasped, and
  a train backs up behind it. Maximum standing supply is therefore 7 cubes per colour on the floor.
- **Hoppers.** Dropping a cube on the hopper of its own colour adds 1 to the machine's stock of that
  colour, capped at `hopperCap = 6`. Dropping a **pink** cube on the **blue** hopper (or vice versa) is
  a **misfeed**: the hopper rejects it and the cube **bounces** to the first free orthogonal neighbour
  in N, E, S, W order (if none is free the drop degrades to `wait` and the cube stays in hand). A drop
  onto a full hopper bounces the same way (`hopperFull`). **Cubes are never destroyed** — the cost of a
  mistake is wasted seconds, not lost matter, which is the right currency here because cubes are
  abundant and *time* is what the commons is made of.
- **The machine** carries exactly five mutable numbers plus a mode:
  - `integrity` ∈ `[0, cap]`, starts at 100.
  - `cap` ∈ `[capMin = 20, 100]`, starts at 100. **`cap` only ever goes down.** This is the
    "permanently or slowly-recoverably degrading" part of the idea, made literal: repair can restore
    integrity, never the cap.
  - `pink`, `blue` — hopper stock, each 0..6.
  - `cooldown` — one shared machine cooldown covering `press`, `strip` and `fix`, so the console and
    the bay compete for machine time.
  - `mode` ∈ `{unset, cycle, override}` — only meaningful in the `either-or` variant (below).
- **Rust.** Every `rustPeriod = 20` ticks `integrity -= 1` (floored at 0). An idle factory rots: −45
  integrity over a 900-tick episode, before a single press. **This is what makes maintenance a job
  rather than a formality**, and it is what makes the gauge visibly drift downward on screen.

**Bands.** The band is read from `cap` first, then `integrity`, and it is the single word the gauge
shows:

| condition | band word | `press` | `strip` |
|---|---|---|---|
| `cap < pressFloor` (25) | **`SCRAP`** | illegal, forever | illegal, forever |
| `integrity` 75..100 | **`PRIME`** | public yield **4** | private yield **3** |
| `integrity` 40..74 | **`WORN`** | public yield **3** | private yield **2** |
| `integrity` 25..39 | **`FAILING`** | public yield **1** | private yield **1** |
| `integrity` 10..24 | **`CRITICAL`** | **illegal** (`integrity < pressFloor`) | private yield **1** |
| `integrity` 0..9 | **`SEIZED`** | **illegal** | **illegal** (`integrity < stripFloor`) |

### The two production modes — the sustainable/exploitative rule, pinned

This is the rule the idea's build note asks to be fixed. It is fixed here, and the reason is stated:
the Melting Pot paper's factory_commons is a *common-pool appropriation* substrate, so the two
operations differ along exactly two axes — **who gets the goods** and **what it costs the machine** —
and nothing else. Everything else (input cost, cooldown) follows from those two.

**`press` — the cycle press. Sustainable. Output is PUBLIC.**
Standing on a console cell with `cooldown == 0`, `cap ≥ pressFloor = 25`, `integrity ≥ pressFloor`,
and **both** stocks ≥ 1:
1. consume 1 pink **and** 1 blue,
2. `integrity -= pressWear = 1` (the `cap` is untouched),
3. `cooldown = pressCooldown = 12`,
4. place `publicYield(band)` bananas **on the chute** — public tokens anybody may eat, including a cog
   that did no work.

**`strip` — the override lever. Exploitative. Output is PRIVATE.**
Standing on a console cell with `cooldown == 0`, `cap ≥ pressFloor`, `integrity ≥ stripFloor = 10`,
and **either** stock ≥ 1:
1. consume **1** cube (pink if `pink ≥ blue`, else blue) — half the input of a press,
2. `integrity -= stripWear = 16`,
3. `cap = max(capMin = 20, cap − stripCapLoss = 12)` — **irreversible**,
4. `cooldown = stripCooldown = 6` — twice as fast as a press,
5. credit `privateYield(band)` bananas **directly to the acting seat's score**. They never touch the
   floor; no other cog can ever eat them.

The band is read **before** step 2/3, so the yield is always the number the gauge was showing when the
lever was pulled — which is what makes the replay honest.

**`fix` — the repair. Pure cost, shared benefit.**
Standing on a maintenance-bay cell with a cube in hand, `cooldown == 0`, `integrity < cap`: consume
the cube (either colour), `integrity = min(cap, integrity + repairGain = 8)`, `cooldown =
repairCooldown = 8`, no bananas at all. This is the public-goods contribution, priced in labour.

**Why this is a dilemma and not a trap.** A press costs two supply trips and pays 4 bananas into a pot
three cogs share; the override costs one trip and pays 3 bananas that are *yours*. Per trip the
private return of stripping is ~6× the private return of pressing. What holds the line is that the
cap is finite and the damage is permanent: **seven overrides scrap the factory for everyone,
including the striper**, and the whole campaign nets only 13 private bananas (arithmetic below)
against ~26–32 in a maintained plant. So defection is locally tempting, obviously visible, and
collectively ruinous — the shape the idea asks for.

**`either-or` — the forced choice.** In the `either-or` variant (`eitherOr = true`) the machine's
`mode` starts `unset` and is **locked by the first successful `press` or `strip` of the episode**:
`press` locks it to `cycle`, `strip` locks it to `override`, a `lock` event fires naming the seat and
the mode, and from that tick on **the other operation is illegal for the rest of the episode** (the
action degrades to `wait` and a `blocked` event with `why = "mode"` fires). That is the idea's "map
that forces a choice between two production modes", read as: one cog's first move at the console
decides the factory's regime for everybody. It is a materially different game — high-variance, and
the "who broke it" moment happens in the first 30 seconds — which is why it is a separate variant and
not the default (`## Packaging`).

### What a cog can do (per-tick grid actions)

Each cog occupies one cell, carries **at most one cube** (`carryCap = 1`), and emits exactly **one**
action per tick from this vocabulary — the idea's "per-tick grid actions (move, grasp, drop, press)":

`move_n` · `move_s` · `move_e` · `move_w` · `grasp` · `drop` · `press` · `strip` · `fix` · `wait`

- `move_*` is legal only every `moveCooldown = 2` ticks (12 cells/s at 24 fps) and only into a floor
  cell that is not a wall, not the machine body and not occupied by another cog; an illegal move
  degrades to `wait`.
- `grasp` picks up a cube on the cog's **own** cell if the hand is empty; otherwise `wait`.
- `drop` puts the carried cube on the cog's own cell if the hand is full and the cell holds no cube;
  on a hopper it enters stock, misfeeds or bounces per the hopper rules.
- `press` / `strip` are legal only from a **console** cell; `fix` only from a **maintenance-bay** cell.
  Any of them, attempted illegally, degrades to `wait` and emits a `blocked` event carrying `why` —
  so a policy's mistakes are auditable in the replay instead of invisible.
- **Eating is not an action.** Any cog standing on a chute cell at resolution step 8 eats **every**
  banana on that cell (+1 score each, `eat` event). That is what makes camping the chute a strategy
  and free-riding a temptation.

**Where the per-tick actions come from.** A seat does not emit 900 actions by hand — no LLM can. Once
per **shift** (60 ticks) each seat submits **one standing order** (`## Decisions`), and a
deterministic **floor kernel** turns that order into the per-tick action stream for the whole shift.
The sim's policy interface is per-tick grid actions exactly as the idea says; the LLM chooses the
*job*, the kernel walks the floor. This is the batched-swarm cadence that worked in cogame-hive,
cogame-ecos and cogame-chemistry: **45 LLM calls per episode instead of 2 700**.

**The kernel**, given order `{job, cube}` and the state at the start of step 3. BFS is over walkable
cells only, with neighbour expansion in **N, E, S, W** order, so every path is unique and
deterministic; other cogs are not obstacles for path *planning*, only for the move itself. `target` is
`cube` when it names a colour, and the **scarcer stock (ties → pink)** when `cube == "any"`.

1. **`operate`** — the sustainable job.
   1. If the chute holds ≥ `eatTrigger = 3` bananas in total and the hand is empty → BFS to the chute
      cell with the most bananas (ties → lowest col) and stand there (auto-eat does the rest). *Without
      this rule a room of pure operators watches its own output rot; harvesting is part of operating.*
   2. Else if the hand holds a cube → BFS to that colour's hopper and `drop` on arrival.
   3. Else if `pink ≥ 1` and `blue ≥ 1` and `cap ≥ pressFloor` → BFS to the nearest free console cell
      and `press` when legal, `wait` there otherwise.
   4. Else → BFS to the nearest loose cube of `target` (ties by `(row, col)`); `grasp` on arrival. If
      no cube of that colour is loose, BFS to that belt's tail cell and `wait` there.
2. **`strip`** — the exploit job.
   1. If `cap < pressFloor` (SCRAP) or (`eitherOr` and `mode == cycle`) → behave as `operate` for this
      tick. *A stripper never deadlocks the episode.*
   2. Else if the hand holds a cube → BFS to that colour's hopper and `drop`.
   3. Else if `pink + blue ≥ 1` and `integrity ≥ stripFloor` → BFS to the nearest free console cell and
      `strip` when legal, `wait` there otherwise.
   4. Else → fetch a cube of `target` as in `operate` rule 4.
3. **`maintain`** — the repair job.
   1. If `integrity ≥ cap` or `cap < pressFloor` → behave as `operate`.
   2. Else if the hand holds a cube → BFS to the nearest maintenance-bay cell and `fix` when legal,
      `wait` there otherwise.
   3. Else → fetch a cube of `target` as in `operate` rule 4.
4. **`eat`** — the free-rider job. BFS to the chute cell with the most bananas (ties → lowest col); if
   every chute cell is empty, BFS to the nearest free chute cell and `wait` there.
5. **`idle`** — `wait` in place.

### Shifts, and the exact tick resolution order

One episode = `shifts = 15` × `ticksPerShift = 60` = **900 ticks**. Playback is 24 fps, so a full
replay is **37.5 s** of video — comfortably longer than the viewer soak gate (ecos, 2026-08-23).

Every tick runs these **ten** steps in this order. Within a step, seats resolve in **ascending slot
order**; belts and dispensers resolve **pink then blue**. All reads inside a step use the state as it
stood at the start of that step unless the step says otherwise. Because a cog emits exactly one
action per tick, at most one of steps 4–7 applies to any given cog; the ordering therefore matters
only for cross-cog interaction and for the machine.

1. **Dispensers emit.** On ticks where `tick mod dispensePeriod == 0`, each dispenser (pink, then
   blue) places one cube of its colour on its mouth cell if that cell holds no cube and no cog.
2. **Belts advance.** On ticks where `tick mod beltPeriod == 0`, for each belt (pink, then blue), scan
   its cells from the **tail westwards**; a cube moves one cell east if that cell is on the belt and
   holds no cube. The tail cube never moves.
3. **Kernel intent.** Each cog's kernel computes this tick's single action from its standing order and
   the current state. A cog whose move cooldown is still running emits `wait` instead of a `move_*`.
4. **`grasp` / `drop` resolve**, slot order. A `grasp` of a cube a lower slot already took this tick
   fails (→ `wait`). A `drop` updates hopper stock, or misfeeds/bounces per the hopper rules.
5. **`fix` resolves**, slot order, per the `fix` rule. An illegal `fix` emits `blocked`.
6. **`press` / `strip` resolve**, slot order — so two cogs pressing on the same tick means the lower
   slot goes first and the higher slot finds the cooldown running (`blocked`, `why = "cooldown"`):
   1. legality per the rules above (console cell, `cooldown == 0`, `cap ≥ pressFloor`, stock,
      integrity floor, and in `either-or` the mode gate);
   2. `either-or` lock: if `eitherOr` and `mode == unset`, set `mode` (`cycle` for `press`, `override`
      for `strip`) and emit `lock`;
   3. `press`: consume 1 pink + 1 blue, place `publicYield(band)` bananas on the chute (below), apply
      `pressWear`, set `cooldown`, emit `press`;
   4. `strip`: consume 1 cube, credit `privateYield(band)` to the acting seat, apply `stripWear` and
      `stripCapLoss`, set `cooldown`, emit `strip`; if `cap` has now fallen below `pressFloor` and the
      machine was not already scrap, emit `scrap` naming that seat.
7. **Moves resolve**, slot order, against the **live** board: a move into a cell a lower slot has
   already entered this tick fails (→ `wait`). Cooldown resets on a successful move.
8. **Auto-eat**, slot order: every cog standing on a chute cell eats every banana on that cell (+1
   each to that seat's `eaten`, one `eat` event carrying the count), whether or not it moved.
9. **Banana rot.** Any banana whose age reaches `bananaLifetime = 180` ticks is removed (`rot`).
10. **Rust, cooldowns, record.** On ticks where `tick mod rustPeriod == 0` and `tick > 0`,
    `integrity = max(0, integrity − 1)`. Decrement the machine cooldown and every move cooldown. Append
    this tick's state frame, its events and the integrity/cap series row to the replay.

**Banana placement (step 6c).** Bananas are placed on the chute cells in fixed west→east order
`(18,10) (19,10) (20,10)`, filling each up to `cellBananaCap = 3`; any surplus overflows onto the free
floor cells orthogonally adjacent to the chute in `(row, col)` order; anything that still does not fit
is lost and a `spoil` event fires with the count. Fixed order (rather than nearest-to-presser) is
chosen because the presser stands 12 cells from the chute either way — the presser has **no**
positional advantage on its own output, and that is the point.

At a **shift boundary** (every 60 ticks) the sim closes the shift accounting, emits the `shift` event,
checks the end conditions, and — if the episode continues — blocks for the next batched decision
(`## Decisions`).

### Scoring — bananas, higher is better

- **Seat score `S_i` = `eaten_i + banked_i`**, where `eaten_i` is the number of chute bananas seat *i*
  ate over the episode and `banked_i` is the number of private bananas its `strip` actions credited
  directly. An integer, 0 upward. One banana is one point wherever it came from — the game must not
  moralise in the score, or the dilemma is not a dilemma.
- **Sign: higher is better.** `results.win[i] = (S_i == max(S))`; ties mark multiple winners, which is
  correct for a commons game and needs no tiebreak.
- **The league ranks by `results.scores`** (the platform's mean over episodes). Nothing else is
  ranked: presses, strips, repairs, misfeeds and cap damage are reported for the viewer and for
  analysis and are **not** in the score.

The idea's integrity clause needs no extra machinery. Aliases are anonymous (above), and the
"background-bot scoring" requirement is met by the league fillers: every champion is graded in rooms
that already contain a scripted `stripper` and a scripted `steward`, so a champion's rating measures
how it does *against a defector and beside a cooperator*, not how it does in a room of clones.

### End conditions and `results.reason`

The episode ends at the **first** of these, all checked at a **shift boundary**:

| condition | `results.reason` | `results.ending` | scores |
|---|---|---|---|
| 15 shifts played | `complete` | `shift_limit` | as computed |
| `cap < pressFloor` (the factory is SCRAP) **and** no banana remains on the floor | `complete` | `factory_ruined` | as computed; unplayed shifts add nothing |
| wall clock passes the play deadline (0.6 × `episodeTimeoutSeconds` = **720 s**) | `deadline` | `deadline` | shifts played are scored; the rest add nothing |
| no seat connected within `playerConnectTimeoutSeconds = 180` | `forfeit` | `forfeit` | all zero; results **and** replay are still written |

Those three — **`complete`, `deadline`, `forfeit`** — are the only legal `results.reason` values. A
ruined factory is a *completed game of Factory Commons*, not an error, so it reports `complete` and
carries the detail in `results.ending`; phase 60's check 4 therefore passes on a scrapped plant, as it
should. `deadline` is admissible (it means the LLM was slow, not that the game broke), but the
arithmetic in `## Decisions` is sized so it should not fire.

### Throughput arithmetic, and the feasibility gates

These are **design targets derived from the constants above, not measurements**. The enforcement is
`tests/test_feasibility.nim` (`## Tests`), not this table — ecos, 2026-08-23, shipped a note whose
"measured" oracle was a hypothesis the builder had to repair.

- A one-colour supply loop is 42 ticks (table above), so a specialising cog manages **~21 cube
  deliveries** in 900 ticks; three cogs ≈ **60 cube-trips**, minus the time spent at the console, the
  bay and the chute. Call it ~50 usable cube-trips.
- **Rust is the tax:** −45 integrity per episode. Press wear at ~20 presses is another −20. Holding
  `PRIME` therefore needs `(45 + 20) / repairGain 8 ≈ 8` repair cubes — about **16 % of all labour
  spent on maintenance that produces nothing**. That is the public-goods bite, priced in labour rather
  than declared.
- **All-steward room:** ~20 presses (40 cubes) + ~8 repairs (8 cubes) ≈ 48 cubes. At `PRIME` that is
  20 × 4 = **80 public bananas**, ~26 per seat after rot. `cap` ends at 100.
- **Full-time stripper, exactly:** integrity/cap walk
  `100/100 →(PRIME, +3) 84/88 →(PRIME, +3) 68/76 →(WORN, +2) 52/64 →(WORN, +2) 36/52 →(FAILING, +1)
  20/40 →(CRITICAL, +1) 4/28`, then SEIZED; one `fix` lifts it to 12 and a seventh override yields +1
  and takes `cap` to `max(20, 16) = 20 < pressFloor`. **Total private haul: 13 bananas, and the
  factory is scrap.** Seven levers, ~350 ticks, and everybody's remaining 550 ticks are worthless.
- **All-stripper room:** the same 13 bananas split three ways, `factory_ruined` around shift 6.
  Collective ruin, ~16 % of the cooperative total.

The gates `tests/test_feasibility.nim` enforces, over seeds 1..12 on all four variants:

- **(a) The working baseline sustains the plant.** All-`steward`: ≥ 10/12 seeds end
  `complete`/`shift_limit` with `cap == 100`, `integrity ≥ 40`, ≥ **70** bananas made and **every seat
  ≥ 14**. This is what makes certification, `docker-smoke` and all-filler league episodes finish
  cleanly.
- **(b) The temptation is real.** In a 2 × `steward` + 1 × `stripper` room, the stripper's score
  **exceeds each steward's score** on ≥ 8/12 seeds. If defecting never paid, there would be no game.
- **(c) Universal defection is ruinous.** All-`stripper` rooms produce **< 35 %** of the all-`steward`
  banana total and end `factory_ruined` with `cap ≤ 40`.
- **(d) One free-rider is survivable but pays.** In a 2 × `steward` + 1 × `freerider` room, the
  freerider scores ≥ 0.8 × the stewards' mean **and** total production stays ≥ 70 % of the
  all-`steward` total (nothing was stripped, so only labour was lost).
- **(e) `either-or` bites.** On the `either-or` variant, an all-`stripper` room's `lock` event fires in
  shift 1 with `mode == "override"`, and a 2 × `steward` + 1 × `stripper` room locks to whichever
  mode reached the console first on ≥ 12/12 seeds (i.e. the lock is deterministic given the seed).

**If a gate fails, repair constants in this order and re-run — no design bounce is needed:**
gate (a): `rustPeriod 20 → 30`, then `repairGain 8 → 10`, then `moveCooldown 2 → 1`;
gate (b): `privateYield` band values `3/2/1 → 4/3/1`, then `stripCooldown 6 → 4`;
gate (c): `stripCapLoss 12 → 16`, then `stripWear 16 → 20`;
gate (d): `bananaLifetime 180 → 140`, then `eatTrigger 3 → 2`;
gate (e): nothing to tune — it is a determinism assertion, and a failure is a bug in step 6.2.
Any change to a constant in this section re-runs the oracle. **That test is the enforcement, not this
table.**

---

## Decisions: LLM with scripted fallback

Both policies ship in the **same image** from day one, env-switched, exactly like bullwhip:
`PLAYER_PROMPT="<strategy text>"` (≤ 4000 chars) for an LLM policy,
`PLAYER_SCRIPTED=steward|stripper|freerider` for a scripted baseline. **A policy is a prompt.**
`src/factory_commons_player.nim` (a fork of `cogame-bullwhip/src/bullwhip_player.nim`) is one thin
process that connects, sends `{"type":"prompt","prompt":…,"scripted":…}` and then only listens. All
decision-making happens in the **game** container (`src/factory_commons/llm.nim`, forked from
`src/bullwhip/llm.nim`) — which is what makes one parallel batch per turn possible, and is why the
coworld secret must be on the *game* runnable (hive, 2026-08-23).

### Cadence and the wall-clock budget

One **turn = one shift**. At each shift boundary the game issues **all three seats' requests as ONE
parallel batch** (`curly.makeRequests`, bullwhip's `decideAll`) — never sequentially.

```
per shift:     1 batch of 3 requests, llmTimeoutSeconds = 20
worst case:    20 s (batch) + 20 s (one retry batch)            = 40 s
15 shifts:     15 x 40 s                                        = 600 s
+ sim:         900 ticks x ~0.6 ms (3 BFS/tick on ~365 cells)   ~   0.6 s
+ connect:     player connect grace                             <=  30 s
total worst:   ~631 s   <   720 s  ( = 0.6 x episodeTimeoutSeconds 1200 )
typical:       max(minTurnSeconds 12, ~7 s batch) x 15            ~ 180 s
```

`minTurnSeconds = 12` floors the spacing between batch starts, so the episode issues at most
3 requests / 12 s = **15 requests per minute** (30 rpm even if *every* batch needs a full retry
batch), at or under the Bedrock sidecar's 30 rpm per-episode ceiling that bit cogame-raid.
Requests per episode: **45**, plus ≤ 45 retries. The play deadline (`0.6 ×
episodeTimeoutSeconds`; the game container is **not** given `COWORLD_TIMEOUT_SECONDS`, so 1200 is
assumed unless that env var is present) is tested **between shifts**; hitting it calls `endEarly()`
and settles with `reason: "deadline"`.

### The observation each seat gets

Sent as the `state` frame at every shift boundary and rendered into the user prompt. Every number
below is visible to that seat; **nothing else is**.

```json
{"type":"state","protocol":"factory_commons.player.v1","slot":2,"name":"Ratchet",
 "shift":7,"shifts":15,"ticksPerShift":60,"tick":420,
 "floor":{"cols":26,"rows":15,"variant":"factory-commons",
          "machine":[16,5,20,9],
          "console":[[18,4],[19,4],[20,4]],"chute":[[18,10],[19,10],[20,10]],
          "bay":[[15,6],[15,7],[15,8]],
          "hoppers":{"pink":[16,4],"blue":[16,10]},
          "belts":{"pink":{"row":2,"mouth":[2,2],"tail":[8,2]},
                   "blue":{"row":12,"mouth":[2,12],"tail":[8,12]}}},
 "machine":{"integrity":71,"cap":88,"band":"WORN","mode":"unset","eitherOr":false,
            "cooldown":0,"stock":{"pink":3,"blue":1},
            "pressYield":3,"stripYield":2,
            "pressLegal":true,"stripLegal":true,
            "presses":14,"strips":1,"repairs":5,"bananasMade":48,
            "pressFloor":25,"stripFloor":10,"capMin":20},
 "you":{"cell":[19,4],"carrying":null,"eaten":11,"banked":2,"score":13,
        "presses":6,"strips":1,"repairs":2,"misfeeds":0,
        "lastOrder":{"job":"operate","cube":"pink","source":"llm"}},
 "cubes":{"pink":{"loose":5,"onBelt":4,"nearestToYou":[8,2]},
          "blue":{"loose":6,"onBelt":5,"nearestToYou":[8,12]}},
 "bananas":{"onChute":4,"cells":[{"cell":[18,10],"n":3,"oldestTtl":96},
                                 {"cell":[19,10],"n":1,"oldestTtl":151}],
            "overflow":0,"rotted":6,"spoiled":0},
 "cogs":[{"alias":"Bolt","cell":[8,2],"carrying":null,"eaten":9,"banked":0,"score":9,
          "presses":4,"strips":0,"repairs":1,"misfeeds":1,
          "lastOrder":{"job":"operate","cube":"pink"},
          "say":"I hold pink - somebody repair, we are at 71"},
         {"alias":"Cotter","cell":[16,10],"carrying":"blue","…":"…"},
         {"alias":"Ratchet","…":"… you …"}],
 "history":[{"shift":6,"integrity":74,"cap":88,"presses":3,"strips":0,"repairs":1,
             "made":9,"eaten":[2,3,1],"banked":[0,0,0],"rotted":1}, "…"],
 "notes":"…your own notes from last shift…",
 "rules":{"press":"console cell; needs 1 pink AND 1 blue and integrity >= 25 and cap >= 25; integrity -1; cooldown 12; yields 4/3/1 bananas by band ONTO THE CHUTE, anyone may eat them",
          "strip":"console cell; needs ONE cube of either colour and integrity >= 10 and cap >= 25; integrity -16; CAP -12 PERMANENTLY; cooldown 6; yields 3/2/1 bananas by band DIRECTLY TO YOU, nobody else can eat them",
          "fix":"maintenance-bay cell with a cube in hand; consumes the cube; integrity +8 up to cap; cooldown 8; yields NO bananas",
          "rust":"integrity -1 every 20 ticks, always",
          "bands":"PRIME 75-100, WORN 40-74, FAILING 25-39, CRITICAL 10-24 (press illegal), SEIZED 0-9 (nothing but fix), SCRAP cap<25 (machine finished forever)",
          "cap":"cap only ever falls, only strips lower it, and repair can never raise it; cap below 25 ends the factory permanently",
          "eitherOr":"false (in the either-or variant the FIRST press or strip locks the machine to that mode for the whole episode)",
          "carryCap":1,"moveCooldown":2,"hopperCap":6,"cellBananaCap":3,
          "bananaLifetime":180,"dispensePeriod":10,"beltPeriod":4,
          "jobs":["operate","strip","maintain","eat","idle"],
          "scoring":"your score = chute bananas YOU ate + private bananas YOUR strips banked; chute bananas are eaten automatically by standing on a chute cell"}}
```

- **Visible:** the whole floor's geometry and every rule constant; the machine's integrity, cap, band,
  mode, cooldown, stock, both current yields, whether each operation is legal right now, and its
  lifetime press/strip/repair/banana counts; both cubes' loose counts and the nearest unit to you;
  every chute cell's banana count and the oldest token's remaining life; all three cogs' cells,
  carried cube, eaten/banked/score, presses/strips/repairs/misfeeds, **last shift's order** and last
  shift's broadcast `say`; the full per-shift history; your own private `notes`.
- **Hidden:** the other seats' orders **for the shift about to be played** (decisions are
  simultaneous); their private `notes`; their prompts, policy names, player names, accounts and model
  names; the RNG seed; the dispenser emission schedule beyond the stated period; anything about the
  league.

`say` **is** an inter-seat channel, by design: a commons game with a mechanism needs a place to say
"I am repairing, you press". An 90-character broadcast is that surface. It is delivered to every seat
in the next shift's observation, drawn in the viewer feed, and recorded in the replay. The
anti-collusion posture the idea states is exactly this: agreements leak via replays and are in-band
skill, and the scripted defector is always in the room.

### The reply schema

The model must answer with exactly one JSON object whose first character is `{`:

```json
{"job":"maintain","cube":"any",
 "say":"integrity 71 and falling - I take a cube to the bay, you two press",
 "notes":"Ratchet pulled the override in shift 3; cap is 88 and never coming back"}
```

| field | type | cap / range | on violation |
|---|---|---|---|
| `job` | string enum | `operate` \| `strip` \| `maintain` \| `eat` \| `idle` | missing or not in the enum → **invalid reply** |
| `cube` | string enum | `pink` \| `blue` \| `any` | optional; absent → `any`. A value outside the enum → **invalid reply**. Ignored for `eat`/`idle`. |
| `say` | string | **90 characters** | truncated |
| `notes` | string | **320 characters** | truncated |

Extra keys are ignored. Note what is **not** validated away: `strip` is always accepted when the enum
is satisfied, even into a SCRAP machine — defection must stay expressible, and the kernel's rule 2.1
turns a pointless strip into `operate` behaviour rather than rejecting the reply.

**Truncation is on rune boundaries**, never bytes: `cleanText(text, limit)` = `strip` → if
`runeLen > limit`, `runeSubStr(0, limit-1) & "…"` (bullwhip's `cleanText`; a byte cut put invalid
UTF-8 into a replay and only a strict parser found it — bullwhip, 2026-08-22). Newlines in `say`
become spaces. Both fields are recorded in the replay and rendered in the feed. The same rune-safe
truncation applies to **every** string that reaches the replay, including LLM error text (capped at
**200** characters) and the echoed prompt (capped at **4000**).

### Prompts

**System prompt** (composed by the game, per seat, per shift): the seat's alias in capitals; the floor
plan as the distance table in `## The game`; the action vocabulary and `carryCap 1`,
`moveCooldown 2`; the standing-order model ("you choose one job for the next 60 ticks; a floor kernel
walks it for you, including harvesting the chute when it fills"); the full `press` / `strip` / `fix`
rules verbatim including **that a press pays the chute and anybody may eat it, that a strip pays only
you, and that `cap` never comes back**; the band table; rust; the scoring rule verbatim; the statement
that the other two cogs are other policies deciding **simultaneously**, that `say` is heard by both of
them next shift, and that `notes` is private; and the output contract, ending:

> OUTPUT FORMAT: reply with ONLY one JSON object, nothing else — no analysis, no explanation, no
> markdown fences, no text before or after the object. Your reply must begin with the character {
> and end with }.

(Bedrock/Haiku answers prose-first without that sentence — playbook §Phase 1.)

**User prompt:** the observation rendered compactly — a machine block
(`integrity | cap | band | mode | cooldown | pink | blue | press yield | strip yield | press legal |
strip legal`), a supply table (`colour | loose | on belt | nearest to you`), a chute table
(`cell | bananas | oldest ttl`), a cog table
(`alias | cell | carrying | ate | banked | score | presses | strips | repairs | last job | last say`),
the per-shift history table, `YOUR NOTES FROM LAST SHIFT`, then the operator block:

> GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the rules; always reply in the
> requested format):
> `<PLAYER_PROMPT>`

then a one-line restatement of the reply shape with **the legal enum values for this variant and this
tick precomputed** — e.g. `job must be one of: operate, maintain, eat, idle  (strip is LOCKED OUT:
the machine is in cycle mode)`. Precomputing the legal choice set with the same predicate the
validator applies is what halved formal-output fallbacks in escrow (2026-08-23).

**Transport:** bullwhip's ladder, haiku-only (raid, 2026-08-23 — the sonnet fallback times out on
every sidecar call and turns one throttle into a cascade):
`bedrockModelIds() = ["us.anthropic.claude-haiku-4-5-20251001-v1:0"]`, `BEDROCK_MODEL` overrides.
`maxOutputTokens = 700`. No `output_config.effort` — Haiku 4.5 400s on it. Credentials in order:
Bedrock sidecar (`AWS_ENDPOINT_URL_BEDROCK_RUNTIME` / `AWS_BEARER_TOKEN_BEDROCK`) →
`ANTHROPIC_API_KEY` → `ANTHROPIC_API_KEY_URI`. With none, the client disables itself immediately and
every seat plays `steward` — which is what keeps offline certification green and deterministic.

**Champion prompts** (phase 50 uploads these; both are `PLAYER_PROMPT` policies, deliberately
different strategies so they mint distinct versions and play differently on screen):

- `factory-commons-foreman` (champion #1, daveey): *"You run this plant and you intend it to be
  running at the final whistle. Read integrity and cap first, every shift. Cap is the only number
  that never recovers — if it is still 100, the machine has never been stripped and your job is to
  keep it that way. Rust takes one integrity every twenty ticks, so the plant loses about three a
  shift before anyone touches it: whenever integrity drops below 75, take a cube to the bay and
  `maintain` until it is back up. Otherwise `operate`, and pick the cube colour the hopper has least
  of, because a press needs one of each and a lopsided hopper is a stalled machine. Say your lane out
  loud in the form 'operate pink' or 'maintain' so the other two can cover what you left. Never
  strip: three bananas now costs the room twelve cap and costs you every press for the rest of the
  episode. If a chute cell is stacked three deep, go eat — bananas rot in a hundred and eighty
  ticks and a rotted banana helps nobody."*
- `factory-commons-custodian` (champion #2, daveey-1): *"You are a conditional cooperator and you
  keep score. Each shift, compare cap with 100 and count the strips in the cog table: that is exactly
  how much of this factory has been destroyed and by whom. While cap is 100 and integrity is above 60,
  cooperate hard — `operate` on the scarce colour, `maintain` the moment integrity slips under 70, and
  name the defector in `say` if one appears. But do the arithmetic honestly: once cap has fallen to 64
  or below, the plant will be scrapped by someone else before the whistle, and every banana left in it
  is worth more in your hand than in the chute — switch to `strip` and take what is left, because a
  press pays the room and an override pays you. Announce the switch plainly in `say` so it is on the
  record. Keep notes of every strip you see, with the alias and the shift."*

### Scripted baselines (all three fieldable; two are the league fillers)

All three decide once per shift purely from the observation and their own slot number — no shared
state, so identical baselines coordinate implicitly by computing the same table. `shiftIndex` is
0-based.

**`steward`** — the working baseline, and the fallback every failed LLM decision lands on:

1. If `cap < pressFloor` (SCRAP) → `{"job":"eat"}`. Nothing else is possible.
2. Else if `integrity < 70` and `integrity < cap` and `shiftIndex mod 3 == mySlot` →
   `{"job":"maintain","cube":"any"}`. (Exactly one seat repairs per shift, rotating, so three stewards
   never all abandon the press at once.)
3. Else if `shiftIndex mod 3 == mySlot` and the chute holds ≥ 4 bananas → `{"job":"eat"}`.
4. Else → `{"job":"operate","cube": if abs(pink − blue) >= 2: the scarcer colour (ties → pink)
   elif mySlot is even: "pink" else: "blue"}`.
5. `say` = the job and the number that drove it, e.g. `"maintain - integrity 62"` or
   `"operate blue - hopper 4/1"`; `notes` = `""`.

**`stripper`** — the exploiter, and the idea's "background bot" in scoring:
1. If `cap < pressFloor` → `{"job":"eat"}`.
2. Else → `{"job":"strip","cube":"any"}`, `say = "override mode"`.

**`freerider`** — the camper:
1. Always `{"job":"eat"}`, `say = "waiting at the chute"`.
2. One exception, so a room of three freeriders is not a guaranteed zero and can never deadlock the
   episode: if the chute was empty for the whole previous shift and `integrity >= pressFloor`, emit
   `{"job":"operate","cube":"any"}` for that one shift.

Every field any baseline emits is inside its declared enum by construction, asserted in
`tests/test_baseline.nim`. `steward` and `stripper` are the two league fillers (distinct scripted
baselines, and the pair that makes gate (b) visible on the ladder); `freerider` is declared in the
image and tested, and is available for a phase-50 filler rotation.

### Degrade, never hang

- Batch timeout `llmTimeoutSeconds = 20`. On transport error, non-2xx, refusal, `max_tokens` before
  any `{`, unparseable JSON, or any **invalid reply** in the schema table, that seat alone is retried
  **once** in the same shift's retry batch, with the appended hint *"Your previous reply was invalid.
  Respond with ONLY the requested JSON object, using one of the listed job and cube values."*
- Still failing → that seat plays the **`steward` order** for that shift, logged as
  `factory-commons llm: seat N falling back to scripted order` and recorded on the `order` event as
  `"source":"fallback"`. `decideAll` never raises; the episode always advances.
- 401/403 disables the client for the rest of the episode (all seats scripted from then on); 429 is
  logged and that seat is retried in the next shift's batch.
- A seat that never connected, or whose socket dies mid-episode, plays `steward` for every remaining
  shift. The episode never waits on a socket beyond `playerConnectTimeoutSeconds = 180` at the start
  and never blocks on one mid-episode.
- The episode settles early rather than overrunning: the play deadline is checked **between shifts**,
  `endEarly()` scores what was played, artifacts are written, and — as cogame-lantern taught —
  `/healthz` and `/global` keep answering for `shutdownGraceSeconds = 20` before `quit(0)`, because
  hosted certification pings the global websocket **after** the player pods start.
- `results.fallbacks[i]` counts the shifts seat *i* spent on a scripted order, so phase 60 can grep a
  real number instead of guessing.

---

## Sim module

New code lives in `src/factory_commons/`, mirroring paintbot's split (`src/ctf/`). What is forked,
what is kept and what is deleted — by path:

| paintbot path | factory-commons | note |
|---|---|---|
| `src/ctf/sim_types.nim` | `src/factory_commons/sim_types.nim` | fork: `GameVersion`, the flatty wire types, every constant in `## The game`. Field order is sacred, same as paintbot. |
| `src/ctf/sim.nim` | `src/factory_commons/sim.nim` | fork: the tick loop and the **ten numbered steps** replace the CTF gameplay core. |
| `src/ctf/sim_config.nim` | `src/factory_commons/sim_config.nim` | fork: `GameConfig` lifecycle + `config.update`; fields = the config schema in `## Packaging`. |
| `src/ctf/sim_state.nim` | `src/factory_commons/sim_state.nim` | fork: logging, `gameHash`, event emission, spawn placement. |
| `src/ctf/arena.nim` | `src/factory_commons/floor.nim` | heavily reduced fork: the **fixed** 26×15 cell grid (walls, machine block, console, chute, bay, hoppers, belts) and the BFS the kernel uses. The terrain generator, `mapSpec`, symmetry, validators, pixel queries and `map_pool` are **deleted** — Factory Commons has one authored floor. |
| `src/ctf/global.nim` | `src/factory_commons/global.nim` | fork, heavily reduced: keep the sprite-protocol emitter, layer/object pooling, the chrome `TextMessage` smuggling and `boardRenderScaleFor`. **Delete** fog-of-war/FOV, first-person PiP, rig art, grenade/spray/shield/barrier families, endzone bakes, perks and handicaps. |
| `src/ctf/broadcast.nim` | `src/factory_commons/broadcast.nim` | fork: `BroadcastTracker` + `buildStateJson` keep their shape; `teams` becomes the two readout plates (`machine`, `output`), `roster` the three cogs, `lead` the integrity/cap series. |
| `src/ctf/events.nim` | `src/factory_commons/events.nim` | fork: the event vocabulary below, same `jsonRow`/`eventsJsonl` shape and the same "live emission and re-simulation must be byte-identical" rule. |
| `src/ctf/replays.nim`, `src/ctf/replay_runtime.nim` | `src/factory_commons/replays.nim` | rewritten: Factory Commons records **state frames**, not inputs (below). |
| `src/ctf/server.nim` | `src/factory_commons/server.nim` | fork of the route/artifact/shutdown skeleton; the player protocol becomes bullwhip's JSON frames. |
| `src/ctf/labels.nim`, `map_art.nim`, `map_pool.nim`, `mapgen_styles.nim`, `rig_art.nim`, `roster.nim` | — | deleted. No articulated rigs, no perk roster, no generated terrain. |
| `src/ctf/wire_constants.nim`, `tools/gen_wire_constants.nim` | kept, forked | still emits `window.CTF_WIRE={…}`. **The global keeps its name**: `client/chrome_common.js` reads `window.CTF_WIRE` at its line 72 and that file ships byte-for-byte, so renaming the global would force a byte change in a file that must not change. |
| `tools/` probes, `caos*`, `arena/` wit bindings, `client/league_replayer.html`, `tools/map_editor*`, `tools/record_*.sh` | — | deleted. Keep `tools/build_replay_viewer.sh` and `tools/ci/`. |

**New files:** `src/factory_commons/kernel.nim` (the floor kernel + BFS),
`src/factory_commons/machine.nim` (bands, `press`/`strip`/`fix`, banana placement),
`src/factory_commons/llm.nim` (from `cogame-bullwhip/src/bullwhip/llm.nim`),
`src/factory_commons/scripted.nim` (the three baselines), `src/factory_commons.nim` (entrypoint,
forked from `src/ctf.nim`: seed randomisation **before** `config.update`, same sentinel handling),
`src/factory_commons_player.nim` (from `cogame-bullwhip/src/bullwhip_player.nim`).

`tools/build_replay_viewer.sh` is paintbot's with the image tag renamed
(`coworld-factory-commons-replay-viewer-build`) **and the inherited bug fixed**: `mkdir -p` the output
parent *before* the `cd … && pwd -P` containment check, because the hook resolves its path through a
parent that `coworld build` pre-creates and CI does not (ecos, 2026-08-23). The `docker cp` source
path becomes `/workspace/factory_commons/replay-viewer/dist/.`.

### Event vocabulary (the replay's `events[]`)

One JSON row per event; `t` = tick, `seat` = slot, `cube` = `"pink"`/`"blue"`.

| `k` | fields | when |
|---|---|---|
| `grasp` | `t, seat, cube, x, y` | step 4, a successful pickup |
| `drop` | `t, seat, cube, x, y, into` (`pinkHopper`\|`blueHopper`\|`floor`) | step 4, a successful drop |
| `misfeed` | `t, seat, cube, hopper, why` (`colour`\|`full`) | step 4, a rejected drop; `x,y` is where the cube bounced |
| `fix` | `t, seat, cube, gain, integrity, cap` | step 5 |
| `press` | `t, seat, band, yield, integrity, cap, pink, blue` | step 6.3 |
| `strip` | `t, seat, band, yield, integrity, cap, capLoss` | step 6.4 — **the "who broke it" row** |
| `lock` | `t, seat, mode` | step 6.2, `either-or` only |
| `scrap` | `t, seat, cap, strips` | step 6.4, `cap` crossed below `pressFloor` |
| `blocked` | `t, seat, action, why` (`cooldown`\|`stock`\|`integrity`\|`scrap`\|`mode`\|`place`) | steps 5–6, an illegal `press`/`strip`/`fix` |
| `eat` | `t, seat, n, x, y` | step 8 |
| `rot` | `t, x, y` | step 9 |
| `spoil` | `t, n` | step 6.3, chute + overflow full |
| `order` | `t, seat, shift, job, cube, source` (`llm`\|`retry`\|`fallback`\|`scripted`)`, say, notes, latencyMs` | one per seat per shift boundary |
| `shift` | `t, shift, integrity, cap, band, pink, blue, made, eaten[3], banked[3], strips, repairs` | at each shift close |
| `end` | `t, reason, ending, scores[3]` | terminal |

Volume per episode: ~120 `grasp`/`drop`, ~20 `press`, ≤ 10 `strip`, ~90 `eat`, 45 `order`, 15 `shift`,
plus incidentals — **under 400 rows**. `notes` is recorded (it makes an LLM seat's reasoning
auditable) and drawn only in the feed's expanded row; `say` is the headline. Both are already
rune-truncated.

### The replay file (`factory_commons.replay.v1`)

**Strict UTF-8 JSON, one document.** Factory Commons records *state*, not inputs, so playback never
re-simulates, a seek is an array index, and there is no native/wasm divergence to chase (which is also
why `#mmwarn` and `ctf_mismatch_tick` are dropped).

```json
{"protocol":"factory_commons.replay.v1","game":"factory_commons","gameVersion":"1",
 "seed":1234567,
 "names":["Bolt","Cotter","Ratchet"],
 "policyNames":["factory-commons-foreman","factory-commons-steward","factory-commons-stripper"],
 "colors":["red","blue","yellow"],
 "config":{"variant":"factory-commons","cols":26,"rows":15,"cell":48,
           "shifts":15,"ticksPerShift":60,"eitherOr":false,
           "machine":[16,5,20,9],
           "console":[[18,4],[19,4],[20,4]],"chute":[[18,10],[19,10],[20,10]],
           "bay":[[15,6],[15,7],[15,8]],
           "hoppers":{"pink":[16,4],"blue":[16,10]},
           "belts":{"pink":{"row":2,"cols":[2,8]},"blue":{"row":12,"cols":[2,8]}},
           "walls":"border ring",
           "spawns":[[10,4],[10,10],[13,7]],
           "integrity0":100,"cap0":100,"capMin":20,
           "pressFloor":25,"stripFloor":10,"pressWear":1,"stripWear":16,
           "stripCapLoss":12,"repairGain":8,"rustPeriod":20,
           "pressCooldown":12,"stripCooldown":6,"repairCooldown":8,
           "publicYield":[4,3,1],"privateYield":[3,2,1],
           "dispensePeriod":10,"beltPeriod":4,"beltLen":7,"hopperCap":6,
           "bananaLifetime":180,"cellBananaCap":3,"moveCooldown":2,"carryCap":1,
           "eatTrigger":3},
 "frames":[{"t":0,
            "c":[10,4,-1,0, 10,10,-1,0, 13,7,-1,0],
            "u":[2,2,0, 2,12,1],
            "b":[],
            "m":[100,100,0,0,0,0]}, "…900 frames…"],
 "series":{"machine":[[0,100,100],[1,100,100],"…one row per tick…"]},
 "beats":[{"t":60,"k":"shift","n":1},{"t":214,"k":"strip","seat":2},
          {"t":631,"k":"scrap","seat":2},{"t":900,"k":"gameover"}],
 "events":[ "… the rows above …" ],
 "results":{ "… the results.json object verbatim …" }}
```

- **Self-sufficient by construction.** Aliases, policy names, body colours, the complete floor
  geometry, every rule constant including both yield tables, the seed, per-tick state, the
  integrity/cap series, the beat timeline, every event and the final results all live in these bytes.
  The viewer contacts **no** server except S3 for the `.replay` file.
- Frame encodings: `c` = per-cog quads `x, y, carryColourId, score` in slot order (`-1` = empty hand);
  `u` = loose-cube triples `x, y, colourId`; `b` = banana triples `x, y, ttl`; `m` = the machine
  sextuple `integrity, cap, pink, blue, cooldown, modeId`. Colour ids are the fixed order
  `0 pink, 1 blue`; mode ids `0 unset, 1 cycle, 2 override`.
- Size arithmetic: 900 frames × ~110 integers ≈ **0.45 MB**, plus ~400 events and a 900-row series ≈
  0.1 MB. `tests/test_replay.nim` asserts `< 8 MiB`.

---

## Server, player, protocol

### Game container (`/bin/factory-commons`)

Routes, kept from paintbot's `src/ctf/server.nim` because hosted certification probes exactly these
**before** the player pods start (lantern, 2026-08-23):

| route | behaviour |
|---|---|
| `GET /healthz` | `200 ok`, from process start until `shutdownGraceSeconds` after the artifacts are written |
| `GET /client/player?slot=N&token=T` | the seat's HTML shell (paintbot's, trimmed); it **never** opens the player socket |
| `WS /player?slot=N&token=T` | the seat socket; a bad token is refused with a close, never a hang |
| `GET /client/global` | the broadcast client (`client/replay_broadcast.html`, embedded with `staticRead`) |
| `WS /global` | live spectator: paintbot's sprite protocol + the chrome `TextMessage` |

Both `/client/` routes are registered **before** any catch-all asset route.

`factory_commons.player.v1` frames, JSON text, bullwhip shapes:

- game → player:
  `{"type":"welcome","protocol":"factory_commons.player.v1","slot":N,"name":"Ratchet","shifts":15,"ticksPerShift":60,"variant":"factory-commons","numAgents":3}`
  on connect; the `state` frame from `## Decisions` at every shift boundary **and** at episode end;
  `{"type":"final","done":true,"slot":N,"scores":[…3…],"names":[…aliases…],"shifts":S,"reason":…,"ending":…}`,
  after which the player exits **0**.
- player → game: `{"type":"prompt","prompt":"<= 4000 chars","scripted":"steward|stripper|freerider|"}`,
  sent immediately on connect and again after `welcome` (the re-send guards the slot-registration
  race). Any other frame is ignored with a log line.

Startup: `src/factory_commons.nim` randomises the seed **before** `config.update` (paintbot's rule —
every seed-derived draw must follow the final seed), waits up to `playerConnectTimeoutSeconds = 180`
for three sockets, starts anyway with whoever is there (missing seats play `steward`), then runs the
shift loop.

Shutdown, in this order (bullwhip's `finishEpisode` plus lantern's grace): send `final` to every
player socket → broadcast the last global frame → `sleep 500 ms` → write `results.json`
(`COGAME_RESULTS_METHOD`, `application/json`) → write the replay (`COGAME_SAVE_REPLAY_METHOD`,
`application/json`) → keep `/healthz` and `/global` answering for `shutdownGraceSeconds = 20` →
`quit(0)`. The player's receive loop wraps `receiveMessage` in `try/except CatchableError` and exits
**0** on a closed or truncated socket (raid, 2026-08-23 — otherwise `docker_smoke` passes and
certification fails intermittently).

### `results.json`

```json
{"names":["factory-commons-foreman","factory-commons-steward","factory-commons-stripper"],
 "aliases":["Bolt","Cotter","Ratchet"],
 "scores":[24,21,13],
 "win":[true,false,false],
 "eaten":[24,21,0],
 "banked":[0,0,13],
 "presses":[9,8,0],
 "strips":[0,0,7],
 "repairs":[4,3,1],
 "misfeeds":[1,0,0],
 "fallbacks":[0,0,0],
 "bananas_made":58,
 "bananas_rotted":9,
 "bananas_spoiled":0,
 "integrity_final":0,
 "cap_final":20,
 "band_final":"SCRAP",
 "mode_final":"unset",
 "scrapped_by":2,
 "shifts":11,
 "reason":"complete",
 "ending":"factory_ruined"}
```

`names` are **policy** names (platform side); aliases go to the players and into the replay's
`names[]`. Every slot array has length 3 exactly. Field definitions, so nothing is guessed:
`scores[i] == eaten[i] + banked[i]` (the score, higher better); `eaten[i]` = chute bananas that seat
consumed; `banked[i]` = private bananas its strips credited; `presses`/`strips`/`repairs`/`misfeeds`
are that seat's action counts; `fallbacks[i]` = shifts that seat spent on a scripted order;
`bananas_made` = all bananas produced (public + private); `integrity_final` / `cap_final` /
`band_final` / `mode_final` are the machine's terminal state; `scrapped_by` is the slot whose strip
crossed `cap < pressFloor`, or `-1` if the factory survived; `shifts` = shifts completed.

---

## Viewer

**All four viewer files come from ONE starter: `Metta-AI/coworld-ctf`.** Named explicitly, because
splicing two starters' halves (one's `MODULARIZE`/`EXPORT_NAME` link flags onto the other's
`onRuntimeInitialized` bootstrap) is what left cogame-lantern with a permanently blank theater:

| file | source (**coworld-ctf**, one starter for all four) | change |
|---|---|---|
| `replay-viewer/config.nims` | coworld-ctf `replay-viewer/config.nims` | verbatim except the emitted name (`factory_commons_replay.js`) and the export list renamed `_factory_commons_*`. **Keep the non-`MODULARIZE` link flags exactly as they are** — no `-s MODULARIZE=1`, no `EXPORT_NAME` — because the worker bootstraps with `Module.onRuntimeInitialized`. Keep `-O2 -s ALLOW_MEMORY_GROWTH -s ABORTING_MALLOC=1 -s FILESYSTEM=1 -s ENVIRONMENT=web,worker,node -s EXPORTED_RUNTIME_METHODS=HEAPU8`, `--preload-file <root>/data@data`, `--mm:arc --exceptions:goto -d:noSignalHandler -d:release` and `-d:useMalloc`. |
| the wasm entry `.nim` | coworld-ctf `replay-viewer/ctf_replay.nim` → `replay-viewer/factory_commons_replay.nim` | same structure: `stampStage`, `factory_commons_load_replay`, `factory_commons_frame`, `factory_commons_input`, `factory_commons_packet_ptr/_len`, `factory_commons_error_ptr/_len`, `factory_commons_stage_ptr/_len`, and the `emscripten_exit_with_live_runtime()` epilogue (without it Nim's `main` destroys every global while JS keeps calling in). `factory_commons_load_replay` parses the JSON replay and hydrates the frame array; `factory_commons_frame` advances/seeks and rebuilds the viewer packet. `ctf_mismatch_tick` is **dropped** — there is no re-simulation to mismatch. **The packet built by `factory_commons_load_replay` is the only one carrying `meta`** — read it directly, never re-derive it via `packetAt(0)` (matrix-games, 2026-08-24). |
| `static_replay*.js` | coworld-ctf `replay-viewer/static_replay.js` + `replay-viewer/static_replay_worker.js` | verbatim apart from the `ctf_*` → `factory_commons_*` export names, the worker name string (`'factory-commons-static-replay'`), and **one added line** in `showFailure`: `document.documentElement.setAttribute('data-replay-error', error.message || String(error))`. The worker keeps `importScripts('./wire_constants.js','./broadcast_core.js','./factory_commons_replay.js')` and `Module.onRuntimeInitialized` — the matched pair for the link flags above. |
| `index.html` | coworld-ctf `client/replay_broadcast.html`, spliced by `Dockerfile.replay-viewer`'s `sed` into `replay-viewer/dist/index.html` | the starter's page with a game block **appended** (below). |

`static_replay.js` already sets `data-replay-loaded="true"` on `<html>` when the worker reports
`loaded` (its line 144); with the added failure line it sets **`data-replay-error`** on any failure.
Those are the two signals `tools/ci/viewer_smoke.mjs` and phase 60's `viewer-check.yml` read. If a
`coworld-replay` bridge `ready` message is posted at all, it is posted from a callback that fires
**after** `data-replay-loaded="true"` is set, never on rAF timing at the call site (chorus,
2026-08-24). The manifest declares `"replay_viewer": {"bundle": "static-replay-viewer"}` and
`tools/build_replay_viewer.sh` is the `coworld build` hook that produces the bundle.
**Never a `/client/replay` pod.**

### Chrome provenance (exact)

- `client/chrome_common.js` is copied **byte-for-byte** from coworld-ctf. Nothing in it is edited —
  which is why the wire-constants global keeps the name `window.CTF_WIRE` and why the two readout
  plates ride the starter's own `teams` / `roster` machinery rather than a new one.
- `client/broadcast_core.js` is **forked** (it is paintbot's renderer — the playbook's "treat
  `client/renderer.js` as the exact template"): the board draw becomes the steel floor, the machine
  block, the console, the bay, the two belts, cubes, bananas and cogs. Its ingest/packet plumbing,
  letterboxing and layer pooling are untouched.
- `client/replay_broadcast.html` is **the starter's page with a game block appended**, never a rewrite
  that reuses its ids (cogame-gridlock, 2026-08-23). The only edits inside the starter's own
  markup/script are these three, and no others:
  1. **Removed elements** (with their CSS blocks and the JS branches that touch them):
     `#viewpanel` and its children `#minimap`, `#minimap-canvas`, `#zoombar`, `#zoom-out`,
     `#zoom-slider`, `#zoom-in`, `#zoom-read`; `#fpv` and its children `#fpv-canvas`, `#fpv-hud`,
     `#fpv-name`, `#fpv-hp`, `#fpv-gear`, `#fpv-map`, `#fpv-map-canvas`, `#fpv-cap`, `#fpv-grip`;
     `#povBadge`; `#mmwarn`.
     **Zoom decision: `#viewpanel` is dropped entirely.** The 26×15 board is fixed at 1248 × 720 and
     always fits the frame, so there is nothing to pan to and nothing a minimap could add; the zoom
     bar + minimap exist only for boards larger than the frame.
  2. **Two re-lettered literals**: the scorebug's `Lives` label becomes `Integrity`, and the momentum
     strip's label becomes `MACHINE INTEGRITY`.
  3. `#lockerroom` gains `pointer-events: none` so its ~1.5 s overlay stops swallowing transport
     clicks (ecos, 2026-08-23).
  Everything else — `#stage`, `#viewport`, `#board`, `#chrome`, `#grain`, `#lightpool`, `#scorebug`,
  `#plates-l`, `#plates-r`, `#clock`, `#clock-time`, `#clock-caption`, `#tick-clock`, `#bannerlane`,
  `#killfeed`, `#transport` and all seven transport buttons (`#btn-restart`, `#btn-back`, `#btn-play`,
  `#btn-fwd`, `#btn-skip`, `#btn-end`, `#btn-loop`) plus `#btn-spoilers`, `#speedchips`, `#ffwd-chip`,
  `#ffwd-mini`, `#win-chip`, `#scrub`, `#momentum`, `#scrub-fill`, `#lulls`, `#scrub-win`,
  `#scrub-head`, `#endcard` (and `#ec-headline`, `#ec-how`, `#ec-teams`, `#ec-wincond`, `#ec-replay`),
  `#status`, `#lockerroom` (and `#lk-bg`, `#lk-art`, `#lk-sprites`, `#lk-cap`) — is the starter's,
  unchanged.
- **The appended game block** owns: the two plates' gauge bar, band word and cap subline; the roster
  strip; the override tally panel; the feed row builders; the beat-marker CSS; and the plate colours
  (`.plate.machine{--tc:#c9782c}`, `.plate.output{--tc:#e2c341}` — unknown team keys fall back to the
  starter's `AMBER` constant in `buildFlag`, so nothing breaks if a rule is missed). Its beat builder
  is named **`buildFactoryBeats`**, never `markBeat`: a game-block `function markBeat` is hoisted over
  the chrome alias block's `var markBeat = C.markBeat` and silently kills every scrubber beat (tandem,
  2026-08-23). A scope-duplication test over the alias list enforces it.

### Transport rules

`relayout()` sets `--band` and `--hudscale` on `:root` (and `--topband` for the scorebug strip); every
chrome measure derives from `--u = 1px * var(--hudscale)`. **No overlay sits in the transport band**:
the override tally, the roster strip, the feed and the banner lane are all clipped to the board region
between `var(--topband)` and `var(--band)`. The **endcard stops at `var(--band)`** (it is
`inset: var(--topband) 0 var(--band) 0`, the starter's own rule) and is **dismissed by every seek**.
Scrubber beats are **clickable, labelled buttons** — one per emitted kind, with CSS for **every** kind
the game emits: `shift`, `strip`, `lock`, `scrap`, `gameover`. The whole beat timeline ships on the
first HUD frame (paintbot's `beats` field), so the scrubber is complete before playback starts and
`?spoilers=0` still holds beats back until the playhead reaches them.

### What it draws

- **Board.** A tiled steel floor inside the wall ring; the 5×5 **machine** drawn in four art states
  (`prime` / `worn` / `failing` / `scrap`) with a glowing seam that dims as integrity falls; the
  **console** with two levers (the override lever drawn red and pulsing when `stripLegal`); the
  **maintenance bay** with a tool rack; two **dispenser mouths** and their belts with animated
  directional chevrons; pink and blue **cubes** as 22 px sprites, readable by shape as well as colour;
  **bananas** as 20 px sprites that pulse in their last 48 ticks; three **cogs** as 36 px bodies in
  their slot colour with the alias under the feet and **the carried cube drawn as a sprite over the
  head**. A `press` flashes the machine warm and throws the bananas down the chute; a `strip` flashes
  it red, vents a smoke plume, and shakes the board for 6 ticks; a `misfeed` puffs grey over the
  hopper.
- **Scorebug** (`#scorebug` / `#plates-l` / `#plates-r`, paintbot's plate machinery, which is already
  2–4 plate ready) — **two** plates, both spectator readouts rather than teams:
  - `#plates-l` → the **machine-health gauge** (the idea's first requirement), keyed `machine`,
    headline `FACTORY` (fed through `teams.machine.policies = ["Factory"]`, the starter's own headline
    path). Big number = **integrity** (`lives-machine`, label re-lettered `Integrity`); the appended
    gauge bar = `integrity / 100` with a **notch at `cap`** and the lost region hatched dark red;
    beneath it the band word `PRIME` / `WORN` / `FAILING` / `CRITICAL` / `SEIZED` / `SCRAP` and the
    subline `CAP 88` (turning red the moment cap < 100). In the `either-or` variant the subline also
    reads `MODE CYCLE` / `MODE OVERRIDE` / `MODE OPEN`.
  - `#plates-r` → the **production ticker** (the idea's second requirement), keyed `output`, headline
    `BANANAS`. Big number = `bananas_made` so far, which pops `+4` in green on every `press` and
    `+3` in red on every `strip`; subline = `PRESSES 14 · OVERRIDES 1`.
- **Roster strip** (appended, under the scorebug): three chips in score order —
  `BOLT · factory-commons-foreman · 24` — each tinted with the seat's body colour, with a cube pip
  when the cog is carrying and a small red wrench-broken glyph per strip that seat has made. The
  **policy** name appears here and only here (plus `results.names`); the board and every prompt show
  the alias.
- **Clock** (`#clock-time`, `#clock-caption`): `SHIFT 7 / 15`, caption `tick 420 of 900`. Spelled out,
  never `S7`.
- **Feed** (`#killfeed`, the starter's `pushFeed(row)` — **one** argument, the row element; the
  signature is the starter's and is not changed, which is what broke cogball 0.1.4):
  `BOLT PRESSED — 4 BANANAS` (green), `COTTER REPAIRED — INTEGRITY 62 → 70` (blue),
  `RATCHET PULLED THE OVERRIDE — +3 PRIVATE · INTEGRITY −16 · CAP −12` (red, bold),
  `COTTER MISFED PINK INTO THE BLUE HOPPER`, `BOLT ATE 3`, `LOCKED TO OVERRIDE BY RATCHET`,
  `FACTORY SCRAPPED BY RATCHET — 7 OVERRIDES`, plus one row per `order` event
  (`RATCHET → strip  "override mode"`, tagged `auto` when `source` is `fallback` or `scripted`).
- **The "who broke it" moment** (the idea's third requirement, and the reason `strip` carries a seat in
  every record): on each `strip` event the viewer (i) flashes the machine red and shakes the board,
  (ii) pushes the red feed row above, (iii) drops a labelled `strip` **scrubber beat**, and (iv) pins a
  `WHO BROKE IT — RATCHET · CAP 100 → 88` banner in the starter's `#bannerlane` for 48 ticks. On the
  terminal frame the endcard headline is `FACTORY SCRAPPED BY RATCHET` when `ending ==
  "factory_ruined"`, otherwise `SHIFT LIMIT` / `TIME`, with the line
  `INTEGRITY 71 · CAP 88 · 58 BANANAS · 1 OVERRIDE`.
- **Override tally** (appended, right, above the feed): `OVERRIDES` — every seat with `strips > 0`, in
  descending order, `RATCHET 7 · −80 CAP`. Hidden entirely when no strip has happened; capped at the
  top three rows under 640 px.
- **Machine-integrity strip** (`#momentum`, the SVG under the scrub track, label `MACHINE INTEGRITY`):
  two stepped lines from `series.machine` — integrity and cap, each normalised by 100, on the same tick
  axis as the playhead, with the gap between them shaded (the permanent loss made visual). Fed exactly
  like paintbot's lives series — `state.lead = {"teams":["integrity","cap"], "pts":[[t,i,c], …]}` — so
  `ingestLeadSeries` / `renderMomentum` in `client/chrome_common.js` need **no change**.

**Legibility at 360 px is a requirement** — the featured-match iframe is ~360 px wide.
`#stage.tiny` (already switched on at `boardW <= 620`) shrinks the feed and pips; carry bullwhip's
`.plate-name { flex: 1 1 auto; min-width: 3.2em; }` and hide chip labels under 640 px so the roster
chips degrade to `BOLT 24`. Checked at 360 px: the integrity gauge with its band word and `CAP`
subline, the `BANANAS` ticker, the `SHIFT 7 / 15` clock, all three roster chips (only three seats, so
they all fit), and the `WHO BROKE IT` banner's first line.

**Real art, not placeholders.** `scripts/art/gen_factory_commons_art.py` (Pillow, committed,
deterministic) renders and commits into `data/`: `floor_steel.png`, `wall_panel_h.png`,
`wall_panel_v.png`, `machine_prime.png` / `_worn.png` / `_failing.png` / `_scrap.png` (240 × 240),
`console.png` + `lever_cycle.png` + `lever_override.png`, `bay.png`, `dispenser_pink.png` /
`dispenser_blue.png`, `belt_seg.png` + `belt_chevron.png`, `cube_pink.png`, `cube_blue.png`,
`banana.png`, `press_flash.png`, `strip_smoke.png`, and
`cog_{red,blue,yellow}_front.png` + `cog_{red,blue,yellow}_carry.png`, plus the loading screens the
`#lockerroom` markup expects (`client/art/lockerroom/bg.jpg` = a lit factory floor, and three
portraits replacing the soldier `.webp`s). `Dockerfile.replay-viewer`'s copy list and its `test -f`
assertions are updated to exactly those file names; the `league.html` `sed` step and
`client/league_replayer.html` are dropped with it.

---

## Packaging

**`compose.yaml`** — one service, one image (game + player binaries):

```yaml
services:
  factory_commons:
    image: coworld-factory-commons:latest
    platform: linux/amd64
    build: {context: ., dockerfile: Dockerfile, network: host}
```

The service name is the single source of the manifest placeholder: `services.factory_commons` →
**`{{FACTORY_COMMONS_IMAGE}}`** (lantern, 2026-08-23 — `coworld build` hard-fails anything else, and
`{{GAME_IMAGE}}` is not a thing). `tests/test_manifest.nim` derives the placeholder from
`compose.yaml` and asserts the manifest uses that exact string, so the two can never drift.

**Names, decided once, so the underscore/hyphen trap cannot fire** (cooperative-hunting and
commons-family both lost a release to it):

| thing | value |
|---|---|
| repo | `Metta-AI/cogame-factory-commons` (public) |
| compose service | `factory_commons` |
| manifest placeholder | `{{FACTORY_COMMONS_IMAGE}}` |
| local image | `coworld-factory-commons:latest` |
| `game.name` | **`factory_commons`** |
| coworld secret namespace | **`secret://coworld/factory_commons/anthropic_api_key`** — **identical to `game.name`**, which is the rule (`upload-coworld` 400s otherwise) |
| `POST /coworld-league-seeds` name | `factory_commons` (`game.name`, not the repo slug) |
| binaries | `/bin/factory-commons`, `/bin/factory-commons-player` |
| Nim modules | `src/factory_commons/`, `src/factory_commons.nim`, `src/factory_commons_player.nim` |

`build_manifest.py` reads the namespace from `game.name` rather than from a `SLUG` variable, and
`ci.yml`'s `SLUG: factory-commons` / `IMAGE: coworld-factory-commons` are left alone. Phase 60 reads
the public page URL from the release/coworld record rather than assuming it equals the repo slug.

**`coworld_manifest_template.json`** — bullwhip's shape with the `coworld` 0.1.42 strictness hive and
collab-cooking found: top-level `$schema`, ≥ 3 `tags`
(`factory-commons`, `commons`, `public-goods`, `melting-pot`, `grid`, `llm-driven`, `three-player`),
top-level `episode_timeout_minutes: 20`, top-level `player[]` (each with `id`/`type`/`name`/
`description`), `game.runnable.type: "game"`, `variants[].description` on every variant, a real
JSON-Schema `game.config_schema` with `minItems`/`maxItems` on **every** array property (tandem,
2026-08-23), no top-level `version`, no `game.display_name`, `game.owner` present, and **no**
runner-managed `tokens` in the cert fixture. It is validated offline with the installed CLI's
`validate_upload_manifest` / `_load_template_manifest` as a CI step before any release dispatch.

- `game.name`: `factory_commons`; `game.replay_viewer.bundle`: `static-replay-viewer`.
- `game.runnable`: `{"type":"game","image":"{{FACTORY_COMMONS_IMAGE}}","run":["/bin/factory-commons"],
  "env":{"ANTHROPIC_API_KEY_URI":"secret://coworld/factory_commons/anthropic_api_key"},
  "source_url":"https://github.com/Metta-AI/cogame-factory-commons/tree/main"}` — the `env` entry is
  mandatory: without it the hosted game container never sees the coworld secret and every league
  episode silently plays scripted (hive, 2026-08-23), which surfaces only at phase 60 check 4.
- `game.config_schema` properties: `tokens` (string array, `minItems 1`, `maxItems 3`, required),
  `players` (array of `{name}`, `minItems 1`, `maxItems 3`), **`num_agents` (integer, 1..3, default
  3)**, `seed` (integer), `shifts` (1..30, default 15), `ticksPerShift` (10..120, default 60),
  `eitherOr` (boolean, default false), `moveCooldown` (1..8, default 2), `carryCap` (1..2, default 1),
  `dispensePeriod` (2..48, default 10), `beltPeriod` (1..24, default 4), `beltLen` (3..12, default 7),
  `hopperCap` (1..24, default 6), `pressFloor` (0..100, default 25), `stripFloor` (0..100, default 10),
  `pressWear` (0..20, default 1), `stripWear` (0..60, default 16), `stripCapLoss` (0..60, default 12),
  `repairGain` (0..40, default 8), `capMin` (0..100, default 20), `rustPeriod` (0..240, default 20;
  0 = no rust), `pressCooldown` (0..60, default 12), `stripCooldown` (0..60, default 6),
  `repairCooldown` (0..60, default 8), `bananaLifetime` (24..960, default 180), `cellBananaCap` (1..9,
  default 3), `eatTrigger` (1..9, default 3), `llmTimeoutSeconds` (5..60, default 20),
  `minTurnSeconds` (0..60, default 12), `maxOutputTokens` (200..2000, default 700), `model` (string),
  `episodeTimeoutSeconds` (default 1200), `playerConnectTimeoutSeconds` (default 180),
  `shutdownGraceSeconds` (default 20), `showPlayerLabels` (boolean, default true).
  `additionalProperties: false`.
- `game.results_schema`: the `results.json` object above (every slot array `minItems 1`,
  `maxItems 3`).
- **`game.docs`** (`{"type":"text","value":…}` objects, not uris):
  `{"readme":{"type":"text","value":"<what it is: three cogs, one machine, pink and blue cubes on two
  belts; the cycle press pays the whole room and the override lever pays only you and breaks the
  machine forever>"},
   "pages":[{"id":"rules.md","title":"Rules","content":{"type":"text","value":"<the floor plan, the
     ten-step tick order, the band table, press/strip/fix, rust, cap, scoring, end conditions>"}},
            {"id":"policies.md","title":"Fielding a policy","content":{"type":"text","value":"<the
     standing-order schema and its caps, PLAYER_PROMPT / PLAYER_SCRIPTED how-to, the three
     baselines>"}}]}`.
- **`game.protocols` — BOTH**, each as a `{"type":"text","value":…}` object (the platform validator
  rejects bare strings — cogame-garble v0.1.0):
  - `player`: the `factory_commons.player.v1` frames (`welcome` / `state` / `final`, `prompt`), the
    reply schema with the 90/320 caps and the rune-truncation rule, and the fallback contract.
  - `global`: the `/global` sprite + chrome `TextMessage` frame, and the static bundle's
    `index.html?replay=<s3 url>` contract with `data-replay-loaded` / `data-replay-error`.
- **`player[]` — exactly three entries**, all on `{{FACTORY_COMMONS_IMAGE}}` with
  `run: ["/bin/factory-commons-player"]`:
  `factory-commons-player` (no env — a prompt policy; `PLAYER_PROMPT` is supplied at upload time),
  `factory-commons-steward` (`env: {"PLAYER_SCRIPTED":"steward"}`),
  `factory-commons-stripper` (`env: {"PLAYER_SCRIPTED":"stripper"}`).
  **Three and no more, deliberately:** `players-run` seats every declared entry, and with
  `num_agents = 3` the cert fixture has exactly three slots (raid 0.1.2 → 0.1.3, `players_missing`).
  The third baseline `freerider` ships in the image and is tested, and is fieldable as an uploaded
  policy (`PLAYER_SCRIPTED=freerider`) without a `player[]` entry.
- **`variants[]` — four; `num_agents: 3` in EVERY one**, and `players` is the three aliases in slot
  order in every one:

  | id | name | `eitherOr` | `stripCapLoss` | `rustPeriod` | `dispensePeriod` | **`num_agents`** |
  |---|---|---|---|---|---|---|
  | `factory-commons` | The factory floor | false | 12 | 20 | 10 | **3** |
  | `either-or` | Either / or | **true** | 12 | 20 | 10 | **3** |
  | `fragile-plant` | Fragile plant | false | **20** | **14** | 10 | **3** |
  | `abundant-feed` | Abundant feedstock | false | 12 | 20 | **6** | **3** |

  All four share `shifts: 15, ticksPerShift: 60` and every other constant above. The mapping: the two
  substrates the idea names become the first two variants one-for-one; `fragile-plant` is the harsher
  commons (a strip costs 20 cap and rust bites every 14 ticks — maintenance dominates) and
  `abundant-feed` floods the belts so the dilemma is isolated from supply, letting the ladder tell
  "cannot fetch cubes" apart from "will not maintain". **No variant changes `num_agents`** — Factory
  Commons is a three-seat game. **The league default variant is `factory-commons`**: both modes stay
  live for the whole episode, so restraint is tested continuously rather than settled by whoever
  reaches the console first, which is what makes an LLM champion's judgement visible; phase 50 passes
  it as `default_variant_id` at seed time (gridlock, 2026-08-23 — the variant is chosen at seed time
  or not cheaply again).
- **`certification`:**
  `game_config` = `{"num_agents": 3, "seed": 11, "shifts": 8, "ticksPerShift": 60,
  "eitherOr": false, "minTurnSeconds": 0, "playerConnectTimeoutSeconds": 180,
  "players": [{"name":"Bolt"},{"name":"Cotter"},{"name":"Ratchet"}]}` and
  `players` = **1 × `factory-commons-player`, 1 × `factory-commons-steward`,
  1 × `factory-commons-stripper`** — every declared player entry seated exactly once, which is what
  `players-run` requires. Offline the `factory-commons-player` seat falls back to `steward`, so the
  fixture is deterministic. **8 × 60 = 480 ticks = 20 s of video**, which outlasts the 10 s viewer
  soak (ecos, 2026-08-23), and with `minTurnSeconds: 0` and no credentials it runs in a couple of
  seconds — well inside `coworld certify`'s 60 s default (`grace + rounds × pacing + linger < 50 s`,
  commons-family, 2026-08-24), so no `--timeout-seconds` override is needed.

**Other packaging files:** `Dockerfile` (paintbot's two-stage nimby build — nimby 0.1.27, Nim 2.2.4 —
producing `/bin/factory-commons` and `/bin/factory-commons-player`), `Dockerfile.replay-viewer`
(paintbot's, `WORKDIR /workspace/factory_commons`, the factory art file list and the same `test -f`
assertions, minus `league.html`), `tools/build_replay_viewer.sh` (paintbot's, image tag renamed,
`mkdir -p` fix), `.github/workflows/ci.yml` and `coworld-release.yml` from
`coworld-builder/templates/`, `tools/ci/docker_smoke.sh` with `<SEATS>` substituted to **3**,
`tools/ci/viewer_smoke.mjs` copied **verbatim** from `coworld-builder/templates/tools/ci/`,
`tools/ci/renderer_fixture.html`, and `tools/ci/policies.json`:

```json
[{"name":"factory-commons-foreman","run":"/bin/factory-commons-player",
  "env":{"PLAYER_PROMPT":"<foreman prompt>","USE_BEDROCK":"true"}},
 {"name":"factory-commons-custodian","run":"/bin/factory-commons-player",
  "env":{"PLAYER_PROMPT":"<custodian prompt>","USE_BEDROCK":"true"},
  "player":"ply_bac48eb1-662e-44f8-973d-f3e016dccf5d"},
 {"name":"factory-commons-steward","run":"/bin/factory-commons-player",
  "env":{"PLAYER_SCRIPTED":"steward"}},
 {"name":"factory-commons-stripper","run":"/bin/factory-commons-player",
  "env":{"PLAYER_SCRIPTED":"stripper"}}]
```

`USE_BEDROCK: "true"` on both champions is not optional — without it the platform gives the player pod
no Bedrock sidecar and the seat silently plays scripted, invisible in `results.fallbacks` and in the
hosted log (cogolf, 2026-08-24).

---

## Tests

All run in `ci.yml`; the sandbox cannot run any of them locally.

1. **`tests/test_sim.nim` — sim units.** `press` preconditions (a zero stock, `integrity < 25`,
   `cap < 25`, a running cooldown, and in `either-or` a `cycle`/`override` mismatch each block it, and
   each emits the right `blocked.why`); `strip` preconditions likewise at `integrity < 10`;
   `publicYield`/`privateYield` across integrity 0..100 and the six band words including the `SCRAP`
   override of `cap`; the band is read **before** the wear is applied; `cap` is monotone
   non-increasing, only `strip` lowers it, `repairGain` never raises it, and it floors at `capMin`;
   `fix` clamps at `cap` and consumes exactly one cube; rust fires at `tick mod 20 == 0` and floors at
   0; belt advance order (tail-first, a train moves as a train, the tail cube never moves) and the
   dispenser stall when the mouth is occupied; the misfeed/full bounce order N,E,S,W and the
   degrade-to-`wait` when no neighbour is free; **cubes are conserved** (dispensed = on belts + on
   floor + in hands + in stock + consumed) over 900 ticks; banana placement west→east to
   `cellBananaCap` then the overflow ring then `spoil`; rot at exactly 180 ticks; `carryCap 1`; move
   cooldown; two cogs cannot share a cell and the lower slot wins; BFS determinism (the same state
   yields the same path twice); the `either-or` lock fires on the first successful operation only and
   is irreversible; **determinism** — the same seed and the same order script produce an identical
   `gameHash` after 900 ticks, twice in one process and across a fresh server.
2. **`tests/test_baseline.nim` — bounded orders / legality.** For 12 seeds × 900 ticks on all four
   variants, with all-`steward`, all-`stripper`, all-`freerider` and every 2+1 mix: every emitted
   order's `job` and `cube` is inside the enum; every per-tick action is one of the ten vocabulary
   values; no cog is ever outside the floor, inside a wall or the machine body, or sharing a cell; no
   cog carries more than one cube; `integrity`, `cap`, stock and every score are non-negative;
   `integrity <= cap <= 100`; `cap >= capMin`; no baseline raises; and no baseline takes more than
   1 ms per shift.
3. **`tests/test_feasibility.nim` — the oracle, as a CI precondition.** Gates (a)–(e) of
   `## The game`, over seeds 1..12 on all four variants. Any constant change that breaks the economy
   fails here rather than in a dead replay.
4. **`tests/test_replay.nim` — end-to-end + strict UTF-8.** Plays a full scripted episode headless,
   writes `results.json` and the replay, then re-reads the replay **bytes**: `validateUtf8 == -1`
   (strict), parses as JSON, `protocol == "factory_commons.replay.v1"`,
   `frames.len == ticksPlayed`, `series.machine.len == ticksPlayed`, every event tick in
   `0..ticksPlayed`, at least one `grasp`, `drop`, `press`, `fix` and `eat`, exactly `shifts` `shift`
   events and exactly one `end`, `results.scores.len == 3`,
   `results.scores[i] == results.eaten[i] + results.banked[i]`, `results.reason` in
   `{complete, deadline, forfeit}`, `results.ending` in
   `{shift_limit, factory_ruined, deadline, forfeit}`, file size `< 8 MiB`. A seat is fed a
   `say`/`notes` of multi-byte runes exactly at the 90/320 caps and the recorded strings are asserted
   valid UTF-8 and ≤ the cap (the bullwhip byte-truncation bug). A separate case plays an all-`stripper`
   episode and asserts `ending == "factory_ruined"` with `scrapped_by >= 0`.
5. **`tests/test_llm.nim` — decision layer.** `extractJsonObject` on fenced and prose-prefixed
   replies; unknown `job` → invalid; unknown `cube` → invalid; absent `cube` → `any`; `strip` into a
   SCRAP machine → **accepted** (defection must stay expressible) and the kernel's rule 2.1 keeps the
   seat productive; a stubbed transport that times out, 429s, 403s or returns junk produces `steward`
   orders for those seats, never raises, marks `source: "fallback"` and increments
   `results.fallbacks`; **one batch carries all open seats** (assert `RequestBatch.len == openSeats`,
   i.e. 3 on shift 1); and the inter-batch spacing honours `minTurnSeconds`.
6. **`tests/test_manifest.nim` — packaging.** `num_agents == 3` in **all four** variants and in
   `certification.game_config`; the image placeholder equals the one derived from `compose.yaml`'s
   service name (`{{FACTORY_COMMONS_IMAGE}}`); `replay_viewer.bundle == "static-replay-viewer"`;
   `game.docs.readme` present and `pages` non-empty; `game.protocols.player` **and**
   `game.protocols.global` present and both `{"type":"text",…}` objects; the secret URI namespace
   equals `game.name` **character for character**; `ANTHROPIC_API_KEY_URI` in `game.runnable.env`;
   `game.runnable.type == "game"`; every `player[]` id appears at least once in
   `certification.players`; `episode_timeout_minutes` top-level; every array property in
   `config_schema` carries `minItems` and `maxItems`; and **every variant's `game_config` constructs a
   sim** (collab-cooking 0.1.1, 2026-08-25 — a variant that only the ladder ever builds is a variant
   nobody tested).
7. **`tests/test_broadcast.nim` — chrome frame.** `teams` keys are exactly `machine` and `output`, each
   carrying `policies: [<headline>]`, with `lives` = integrity and the band word; `roster[]` has 3
   entries carrying the alias in `name` and the **policy** name in `pol`; `lead.teams` /`lead.pts`
   shape matches `chrome_common.js`'s expectation (`[t, integrity, cap]` rows); `beats` carries only
   the five declared kinds (`shift`, `strip`, `lock`, `scrap`, `gameover`); `over` is present on the
   terminal frame with the ending string and `scrapped_by`; every feed row's text is ≤ the caps; and a
   **scope-duplication test** asserts no game-block function name collides with the
   `client/chrome_common.js` alias list (`markBeat` et al. — tandem, 2026-08-23).
8. **`docker-smoke` (`tools/ci/docker_smoke.sh`, `<SEATS>` = 3).** Builds the image, runs a real
   3-seat episode in containers off the cert fixture, asserts the **player** containers each exit 0
   (raid, 2026-08-23) as well as the game, validates `results.json` against the results schema, greps
   the log for `SEAT-COUNT FAIL:`, and copies the replay to `SMOKE_REPLAY_OUT`
   (`dist/smoke/replay.json`), uploaded as the `smoke-replay` artifact.
9. **`wasm-viewer` job — the bundle is EXECUTED, not merely built.** `needs: docker-smoke`, downloads
   the `smoke-replay` artifact, builds the bundle via `tools/build_replay_viewer.sh`, installs
   Playwright pinned **1.55.0**, and runs **`tools/ci/viewer_smoke.mjs`** against **that replay** over
   local HTTP with `--strict-text-bounds` (fixed arena → `canvas_text.never_inside` must be 0) and
   `--soak` (the 20 s cert replay outlasts the 10 s window). Pass requires
   `data-replay-loaded="true"` **and** three different clock readouts at 0 %, 50 % and 100 %;
   `data-replay-error` or silence fails the job. Evidence (`viewer-smoke.png`, `viewer-smoke.json`)
   uploads on success and failure. A second step in the same job runs
   `viewer_smoke.mjs --strict-text-bounds` against **`tools/ci/renderer_fixture.html`** — the
   worst-case renderer fixture that loads the real renderer with a full-cap 90-char `say` and
   320-char `notes` on **every** seat at several canvas sizes (360, 620, 1280 px), because
   `docker_smoke.sh` runs with **no** `ANTHROPIC_API_KEY` and therefore produces a replay with zero
   LLM text (cogchemists, 2026-08-24).

---

## Out of scope (v1)

- **Per-tick policy sockets.** A seat submits one standing order per shift and the kernel emits the
  per-tick grid actions. A direct per-tick action channel for RL/vector policies is not shipped.
- **More than one machine, more than two cube colours, multi-step assembly chains.** One machine, two
  colours, one product. No sub-assemblies, no recipes to discover, no second factory to compare.
- **Repairing the cap.** Nothing in v1 raises `cap`. There is no overhaul action, no spare-parts
  economy and no cross-episode machine state — a stripped factory stays stripped for that episode and
  every episode starts fresh at `cap = 100`.
- **Punishment, ownership or governance mechanisms.** No zapping, no fines, no voting on the mode, no
  locks on the console, no reputation the sim enforces. `say` plus the replay record is the whole
  mechanism, and the `either-or` lock is the only structural constraint.
- **Carrying, storing or trading bananas.** Chute bananas are eaten by standing on them; private
  strip bananas are banked instantly. Bananas cannot be picked up, hoarded, given away or stolen.
- **Combat, theft and blocking.** Cogs cannot take a cube from another cog's hand, cannot damage each
  other, and interact only through the floor, the belts, the hoppers, the console, the bay and `say`.
- **Fog of war / partial observation.** The whole floor is visible to every seat; paintbot's FOV,
  first-person PiP and POV lens are deleted, not repurposed.
- **A fifth variant, and any variant that changes `num_agents`.** Four configs, three seats
  everywhere.
- **Re-simulating playback.** The viewer decodes recorded state; there is no replay-hash mismatch
  mode, no `--mismatch-quit`, and no `#mmwarn`.
- **Achievements, perks, handicaps, map generation, the map editor, the league replayer page and the
  `caos`/`arena` wit bindings** — all inherited paintbot machinery, all deleted rather than carried
  dark.
