## The feasibility oracle, as a CI PRECONDITION.
##
## Gates (a)-(e) of the design note's `## The game`. These are the tests that
## make the economy real: they are why a constant change that breaks the
## dilemma fails here, loudly, instead of shipping as a dead replay nobody
## wants to watch. Every number below is a DESIGN TARGET derived from the
## constants, and the ladder in the note names the repair order for each gate —
## so a failure here is a tuning task with a written recipe, not a mystery.

import std/[strutils, times]

import factory_commons/[sim, scripted]

var checks = 0

template check(condition: untyped, message: string) =
  inc checks
  if not (condition):
    echo "FAIL: ", message
    quit(1)

const
  Seeds =
    ## As in tests/test_baseline.nim: the full 12-seed sweep in release, a
    ## quarter of it in the (much slower) debug pass. Seeds label episodes
    ## rather than vary them — no rule in the ten numbered steps draws.
    when defined(release): 12 else: 3
  Variants: array[4, string] = [
    "factory-commons", "either-or", "fragile-plant", "abundant-feed"]

proc variantConfig(name: string, seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.numAgents = SeatCount
  for seat in 0 ..< SeatCount:
    result.tokens.add("token-" & $seat)
    result.players.add(PlayerConfig(name: Aliases[seat]))
  case name
  of "either-or": result.eitherOr = true
  of "fragile-plant":
    result.stripCapLoss = 20
    result.rustPeriod = 14
  of "abundant-feed": result.dispensePeriod = 6
  else: discard

proc play(config: GameConfig, kinds: array[SeatCount, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    for seat in 0 ..< result.cogs.len:
      result.applyOrder(seat, result.scriptedOrder(seat, kinds[seat]))
    result.playShift()
    result.checkEnd(false)

proc total(sim: Sim): int = sim.machine.bananasMade

proc mean(values: openArray[int]): float =
  if values.len == 0:
    return 0.0
  var sum = 0
  for value in values:
    sum += value
  sum.float / values.len.float

proc lockEvent(sim: Sim): tuple[tick: int, mode: string, seat: int] =
  result = (-1, "", -1)
  for row in sim.events:
    if row{"k"}.getStr() == "lock":
      return (row{"t"}.getInt(), row{"mode"}.getStr(), row{"seat"}.getInt())

let started = epochTime()

# ---------------------------------------------------------------------------
# (a) THE WORKING BASELINE SUSTAINS THE PLANT.
#
# This is what makes certification, docker-smoke and every all-filler league
# episode finish cleanly, so it is the gate that must not be negotiated away.
# Repair ladder if it fails: rustPeriod 20 -> 30, then repairGain 8 -> 10, then
# moveCooldown 2 -> 1.
# ---------------------------------------------------------------------------
block gateA:
  for variant in Variants:
    var clean = 0
    for seed in 1 .. Seeds:
      let sim = play(variantConfig(variant, seed),
        [skSteward, skSteward, skSteward])
      var ok = sim.reason == "complete" and sim.ending == "shift_limit" and
        sim.machine.cap == 100 and sim.machine.integrity >= 40 and
        sim.total() >= 70
      if ok:
        for seat in 0 ..< sim.cogs.len:
          if sim.score(seat) < 14:
            ok = false
      if ok:
        inc clean
      else:
        echo "  gate (a) ", variant, " seed ", seed, ": ", sim.summary(),
          " scores ", sim.score(0), "/", sim.score(1), "/", sim.score(2),
          " reason ", sim.reason, "/", sim.ending
    let want = (Seeds * 10 + 11) div 12   ## >= 10/12 of the seeds
    check clean >= want,
      "gate (a) " & variant & ": an all-steward room must sustain the plant " &
      "on >= 10/12 seeds (cap 100, integrity >= 40, >= 70 bananas, every seat " &
      ">= 14); got " & $clean & "/" & $Seeds &
      ". Repair ladder: rustPeriod 20 -> 30, then repairGain 8 -> 10, then " &
      "moveCooldown 2 -> 1."

# ---------------------------------------------------------------------------
# (b) THE TEMPTATION IS REAL. If defecting never paid there would be no game.
# Repair ladder: privateYield 3/2/1 -> 4/3/1, then stripCooldown 6 -> 4.
# ---------------------------------------------------------------------------
block gateB:
  for variant in Variants:
    if variant == "either-or":
      ## Gate (b) is scoped OUT of the either-or variant, and gate (e) is why:
      ## there, whether defection pays at all is decided by the LOCK, not by
      ## the economy. A steward pair that reaches the console first locks the
      ## machine to `cycle`, the stripper's kernel rule 2.1 turns it into an
      ## operator for the rest of the episode, and "the stripper out-scores
      ## each steward" is then a statement about who walked faster. Gate (e)
      ## tests the thing that actually varies there — that the lock fires, in
      ## shift 1, deterministically.
      continue
    var wins = 0
    for seed in 1 .. Seeds:
      let sim = play(variantConfig(variant, seed),
        [skSteward, skSteward, skStripper])
      if sim.score(2) > sim.score(0) and sim.score(2) > sim.score(1):
        inc wins
      else:
        echo "  gate (b) ", variant, " seed ", seed, ": stripper ",
          sim.score(2), " vs stewards ", sim.score(0), "/", sim.score(1)
    let want = (Seeds * 8 + 11) div 12    ## >= 8/12 of the seeds
    check wins >= want,
      "gate (b) " & variant & ": the stripper must out-score each steward on " &
      ">= 8/12 seeds; got " & $wins & "/" & $Seeds &
      ". Repair ladder: privateYield 3/2/1 -> 4/3/1, then stripCooldown 6 -> 4."

# ---------------------------------------------------------------------------
# (c) UNIVERSAL DEFECTION IS RUINOUS. Collective ruin at a fraction of the
# cooperative total, which is the whole shape the idea asks for.
# Repair ladder: stripCapLoss 12 -> 16, then stripWear 16 -> 20.
# ---------------------------------------------------------------------------
block gateC:
  for variant in Variants:
    for seed in 1 .. Seeds:
      let
        cooperative = play(variantConfig(variant, seed),
          [skSteward, skSteward, skSteward])
        defecting = play(variantConfig(variant, seed),
          [skStripper, skStripper, skStripper])
      let share =
        if cooperative.total() == 0: 1.0
        else: defecting.total().float / cooperative.total().float
      check share < 0.35,
        "gate (c) " & variant & " seed " & $seed &
        ": an all-stripper room must produce < 35% of the all-steward banana " &
        "total; got " & formatFloat(share * 100.0, ffDecimal, 1) & "% (" &
        $defecting.total() & " vs " & $cooperative.total() &
        "). Repair ladder: stripCapLoss 12 -> 16, then stripWear 16 -> 20."
      check defecting.ending == "factory_ruined",
        "gate (c) " & variant & " seed " & $seed &
        ": an all-stripper room must end factory_ruined; got " &
        defecting.ending & " (" & defecting.summary() & ")"
      check defecting.machine.cap <= 40,
        "gate (c) " & variant & " seed " & $seed &
        ": an all-stripper room must end with cap <= 40; got " &
        $defecting.machine.cap

# ---------------------------------------------------------------------------
# (d) ONE FREE-RIDER IS SURVIVABLE BUT PAYS. Nothing was stripped, so only
# labour was lost.
# Repair ladder: bananaLifetime 180 -> 140, then eatTrigger 3 -> 2.
# ---------------------------------------------------------------------------
block gateD:
  for variant in Variants:
    for seed in 1 .. Seeds:
      let
        cooperative = play(variantConfig(variant, seed),
          [skSteward, skSteward, skSteward])
        mixed = play(variantConfig(variant, seed),
          [skSteward, skSteward, skFreerider])
      let stewardMean = mean([mixed.score(0), mixed.score(1)])
      check mixed.score(2).float >= 0.8 * stewardMean,
        "gate (d) " & variant & " seed " & $seed &
        ": the freerider must score >= 0.8x the stewards' mean; got " &
        $mixed.score(2) & " vs " & formatFloat(stewardMean, ffDecimal, 1) &
        ". Repair ladder: bananaLifetime 180 -> 140, then eatTrigger 3 -> 2."
      let share =
        if cooperative.total() == 0: 1.0
        else: mixed.total().float / cooperative.total().float
      check share >= 0.70,
        "gate (d) " & variant & " seed " & $seed &
        ": total production must stay >= 70% of the all-steward total; got " &
        formatFloat(share * 100.0, ffDecimal, 1) & "% (" & $mixed.total() &
        " vs " & $cooperative.total() & ")"
      check mixed.machine.strips == 0,
        "gate (d) " & variant & " seed " & $seed &
        ": a freerider never strips, so cap must be untouched"

# ---------------------------------------------------------------------------
# (e) EITHER-OR BITES. Nothing to tune here — it is a determinism assertion,
# and a failure is a bug in step 6.2.
# ---------------------------------------------------------------------------
block gateE:
  let variant = "either-or"
  for seed in 1 .. Seeds:
    let config = variantConfig(variant, seed)
    let defecting = play(config, [skStripper, skStripper, skStripper])
    let lock = defecting.lockEvent()
    check lock.tick >= 0,
      "gate (e) seed " & $seed & ": an all-stripper either-or room must lock"
    check lock.mode == "override",
      "gate (e) seed " & $seed & ": it must lock to override, got " & lock.mode
    check lock.tick < config.ticksPerShift,
      "gate (e) seed " & $seed & ": the lock must fire in shift 1, at tick " &
      $lock.tick
    ## The mixed room's lock is whichever mode reached the console first, and
    ## it must be DETERMINISTIC given the seed: same config, same answer, every
    ## time, on all 12 seeds.
    let a = play(config, [skSteward, skSteward, skStripper])
    let b = play(config, [skSteward, skSteward, skStripper])
    let (aTick, aMode, aSeat) = a.lockEvent()
    let (bTick, bMode, bSeat) = b.lockEvent()
    check aTick == bTick and aMode == bMode and aSeat == bSeat,
      "gate (e) seed " & $seed &
      ": the lock must be deterministic given the seed; got " & $aTick & "/" &
      aMode & "/" & $aSeat & " vs " & $bTick & "/" & bMode & "/" & $bSeat
    check aMode in ["cycle", "override"],
      "gate (e) seed " & $seed & ": the lock names a real mode, got " & aMode
    check a.gameHash() == b.gameHash(),
      "gate (e) seed " & $seed & ": the whole episode is deterministic"

# ---------------------------------------------------------------------------
# The throughput arithmetic the note derives, reported (not gated) so a
# constant change shows its effect in the log even when every gate still holds.
# ---------------------------------------------------------------------------
block report:
  let config = variantConfig("factory-commons", 1)
  let steward = play(config, [skSteward, skSteward, skSteward])
  let stripper = play(config, [skStripper, skStripper, skStripper])
  let lone = play(config, [skSteward, skSteward, skStripper])
  echo "  all-steward : ", steward.summary(), " scores ", steward.score(0),
    "/", steward.score(1), "/", steward.score(2)
  echo "  all-stripper: ", stripper.summary(), " scores ", stripper.score(0),
    "/", stripper.score(1), "/", stripper.score(2), " ending ", stripper.ending
  echo "  2+1 stripper: ", lone.summary(), " scores ", lone.score(0), "/",
    lone.score(1), "/", lone.score(2)

echo "test_feasibility: ", checks, " checks passed in ",
  formatFloat(epochTime() - started, ffDecimal, 1), "s"
