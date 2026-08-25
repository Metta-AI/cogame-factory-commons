## Bounded orders / legality, over 12 seeds x every variant x every seat mix.
##
## The point is not the scores (test_feasibility owns those) — it is that no
## baseline can ever emit an order outside its enum, drive a cog through a wall,
## put two cogs on one cell, carry two cubes, or take a state negative. A
## baseline that raises, or that quietly walks a cog into the machine body, is
## a broken game long before it is a bad player.

import std/times

import factory_commons/[sim, scripted]

var checks = 0
var episodes = 0

template check(condition: untyped, message: string) =
  inc checks
  if not (condition):
    echo "FAIL: ", message
    quit(1)

const
  Seeds =
    ## The design note's matrix is 12 seeds x 4 variants x 6 seat mixes. The
    ## full matrix runs in RELEASE, which is where a codegen bug would hide; the
    ## debug pass — whose job is range and overflow checks, and which is 10-50x
    ## slower through the kernel's per-tick BFS — runs a third of the seeds.
    ## Nothing in Factory Commons draws from the seed (every tie in the ten
    ## numbered steps is broken by slot or by (row, col) order), so a seed
    ## varies the LABEL and not the episode; the seed loop is kept because the
    ## note asks for it and because it is the guard that would catch a future
    ## rule that does draw.
    when defined(release): 12 else: 4
  Variants: array[4, string] = [
    "factory-commons", "either-or", "fragile-plant", "abundant-feed"]

proc variantConfig(name: string, seed: int): GameConfig =
  ## The four manifest variants, by the four constants the variant table
  ## actually varies. Keep in step with `coworld_manifest_template.json`.
  result = defaultGameConfig()
  result.seed = seed
  result.numAgents = SeatCount
  for seat in 0 ..< SeatCount:
    result.tokens.add("token-" & $seat)
    result.players.add(PlayerConfig(name: Aliases[seat]))
  case name
  of "either-or":
    result.eitherOr = true
  of "fragile-plant":
    result.stripCapLoss = 20
    result.rustPeriod = 14
  of "abundant-feed":
    result.dispensePeriod = 6
  else:
    discard
  check result.variantName() == name,
    "the derived variant label must be " & name & ", got " & result.variantName()

proc assertOrder(order: Order, label: string) =
  ## Every field any baseline emits is inside its declared enum BY
  ## CONSTRUCTION; this is the assertion that keeps it that way.
  check ord(order.job) >= ord(Job.low) and ord(order.job) <= ord(Job.high),
    label & ": job is inside the enum"
  check ord(order.cube) >= ord(CubeChoice.low) and
    ord(order.cube) <= ord(CubeChoice.high),
    label & ": cube is inside the enum"
  check parseJob($order.job) >= 0, label & ": job round-trips its wire name"
  check parseCubeChoice($order.cube) >= 0,
    label & ": cube round-trips its wire name"
  check order.say.len <= MaxSayLen * 4,
    label & ": say is inside its cap (runes, so at most 4 bytes each)"
  check order.notes.len <= MaxNotesLen * 4, label & ": notes is inside its cap"

proc assertState(sim: Sim, label: string) =
  let c = sim.config
  check sim.machine.integrity >= 0, label & ": integrity >= 0"
  check sim.machine.integrity <= sim.machine.cap, label & ": integrity <= cap"
  check sim.machine.cap <= 100, label & ": cap <= 100"
  check sim.machine.cap >= c.capMin, label & ": cap >= capMin"
  check sim.machine.pink >= 0 and sim.machine.pink <= c.hopperCap,
    label & ": pink stock inside 0..hopperCap"
  check sim.machine.blue >= 0 and sim.machine.blue <= c.hopperCap,
    label & ": blue stock inside 0..hopperCap"
  check sim.machine.cooldown >= 0, label & ": the cooldown never goes negative"
  for seat in 0 ..< sim.cogs.len:
    let cog = sim.cogs[seat]
    check cog.x >= 0 and cog.x < Cols, label & ": cog inside the board (x)"
    check cog.y >= 0 and cog.y < Rows, label & ": cog inside the board (y)"
    check c.walkable(cog.x, cog.y),
      label & ": cog " & $seat & " is on a walkable cell, not a wall or the " &
      "machine body, at (" & $cog.x & "," & $cog.y & ")"
    check cog.carrying >= -1 and cog.carrying <= 1,
      label & ": at most one cube, and it is a colour"
    check cog.eaten >= 0 and cog.banked >= 0, label & ": counts are non-negative"
    check sim.score(seat) >= 0, label & ": scores are non-negative"
    for other in seat + 1 ..< sim.cogs.len:
      check not (cog.x == sim.cogs[other].x and cog.y == sim.cogs[other].y),
        label & ": cogs " & $seat & " and " & $other & " share cell (" &
        $cog.x & "," & $cog.y & ")"
  for cube in sim.cubes:
    check c.walkable(cube.x, cube.y),
      label & ": a loose cube is on a walkable cell"
  for banana in sim.bananas:
    check c.walkable(banana.x, banana.y),
      label & ": a banana is on a walkable cell"
    check banana.age >= 0 and banana.age < c.bananaLifetime,
      label & ": a banana inside its lifetime"

proc playMix(config: GameConfig, kinds: array[SeatCount, ScriptKind],
             label: string) =
  inc episodes
  var sim = initSim(config)
  var shift = 0
  while not sim.done:
    for seat in 0 ..< sim.cogs.len:
      let order = sim.scriptedOrder(seat, kinds[seat])
      assertOrder(order, label & " shift " & $shift & " seat " & $seat)
      sim.applyOrder(seat, order)
    for _ in 0 ..< config.ticksPerShift:
      sim.stepTick()
      assertState(sim, label & " tick " & $sim.tick)
    sim.closeShift()
    sim.checkEnd(false)
    inc shift
    check shift <= config.shifts,
      label & ": the episode must end at or before the shift limit"
  check sim.cubesConserved(), label & ": cubes are conserved to the last tick"
  check sim.reason in ["complete", "deadline", "forfeit"],
    label & ": reason is one of the three legal values, got " & sim.reason
  check sim.ending in
    ["shift_limit", "factory_ruined", "deadline", "forfeit"],
    label & ": ending is legal, got " & sim.ending
  ## Every recorded action came out of the ten-value vocabulary by
  ## construction (the kernel returns an `Action`), so the check that matters
  ## is that every EVENT is a declared kind.
  for row in sim.events:
    let kind = row{"k"}.getStr()
    var known = false
    for declared in EventKinds:
      if declared == kind:
        known = true
    check known, label & ": unknown event kind " & kind
  for row in sim.beats:
    let kind = row{"k"}.getStr()
    var known = false
    for declared in BeatKinds:
      if declared == kind:
        known = true
    check known, label & ": unknown beat kind " & kind

const Mixes: array[6, array[SeatCount, ScriptKind]] = [
  [skSteward, skSteward, skSteward],
  [skStripper, skStripper, skStripper],
  [skFreerider, skFreerider, skFreerider],
  [skSteward, skSteward, skStripper],
  [skSteward, skSteward, skFreerider],
  [skSteward, skStripper, skFreerider]
]

for variant in Variants:
  for seed in 1 .. Seeds:
    let config = variantConfig(variant, seed)
    for mix in Mixes:
      playMix(config, mix,
        variant & " seed " & $seed & " " & $mix[0] & "/" & $mix[1] & "/" &
        $mix[2])

## No baseline may take more than 1 ms to decide a shift: the whole point of
## the standing-order cadence is that the SIM is free and the LLM batch is the
## only thing worth waiting for.
block decisionCost:
  var sim = initSim(variantConfig("factory-commons", 3))
  for _ in 0 ..< 300:
    sim.stepTick()
  for kind in [skSteward, skStripper, skFreerider]:
    let started = epochTime()
    const Rounds = 200
    for _ in 0 ..< Rounds:
      for seat in 0 ..< sim.cogs.len:
        discard sim.scriptedOrder(seat, kind)
    let perShiftMs = (epochTime() - started) * 1000.0 / Rounds.float
    check perShiftMs < 1.0,
      $kind & " decides a whole shift in " & $perShiftMs & " ms, want < 1 ms"

## Each baseline decides from the observation and its own slot number only, so
## the order it returns must not depend on being asked twice.
block stateless:
  var sim = initSim(variantConfig("factory-commons", 7))
  for _ in 0 ..< 120:
    sim.stepTick()
  for seat in 0 ..< sim.cogs.len:
    for kind in [skSteward, skStripper, skFreerider]:
      let a = sim.scriptedOrder(seat, kind)
      let b = sim.scriptedOrder(seat, kind)
      check a.job == b.job and a.cube == b.cube,
        "a baseline asked twice answers the same: " & $kind

echo "test_baseline: ", episodes, " episodes, ", checks, " checks passed"
