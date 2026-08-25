## The grid harness behind the shipped baseline constants.
##
## `tests/test_feasibility.nim` is the GATE — it fails CI when the economy
## stops being a dilemma. This is the SWEEP that chose the numbers the gate now
## holds: it walks a grid over the three constants that differ from the design
## note's authored values (`moveCooldown`, `stripCapLoss`, `eatTrigger`) plus
## the note's own gate-(a) ladder rungs (`rustPeriod`, `repairGain`), plays
## seeds 1..12 for every cell, and prints each cell's gate-(a)..(d) outcome.
##
## Run it (a few seconds in release):
##
##   nim c -d:release -r tools/tune/feasibility_sweep.nim
##
## The recorded output of the run that chose the shipped values is in
## `docs/tuning.md`. Re-run it after any change to a constant in
## `src/factory_commons/sim_config.nim` and update that file.

import std/[strformat, strutils]

import factory_commons/[sim, scripted]

const Seeds = 12

type Cell = object
  label: string
  moveCooldown, rustPeriod, repairGain, stripCapLoss, eatTrigger: int

proc configFor(cell: Cell, seed: int): GameConfig =
  result = defaultGameConfig()
  result.seed = seed
  result.numAgents = SeatCount
  result.moveCooldown = cell.moveCooldown
  result.rustPeriod = cell.rustPeriod
  result.repairGain = cell.repairGain
  result.stripCapLoss = cell.stripCapLoss
  result.eatTrigger = cell.eatTrigger
  for seat in 0 ..< SeatCount:
    result.tokens.add("token-" & $seat)
    result.players.add(PlayerConfig(name: Aliases[seat]))

proc play(config: GameConfig, kinds: array[SeatCount, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    for seat in 0 ..< result.cogs.len:
      result.applyOrder(seat, result.scriptedOrder(seat, kinds[seat]))
    result.playShift()
    result.checkEnd(false)

proc worstSeat(sim: Sim): int =
  result = high(int)
  for seat in 0 ..< sim.cogs.len:
    result = min(result, sim.score(seat))

proc run(cell: Cell) =
  ## One grid cell: the four measurable gates over seeds 1..12.
  var
    cleanA = 0
    minSeat = high(int)
    madeTotal = 0
    winsB = 0
    ruinedC = 0
    worstShareC = 0.0
    okD = 0
  for seed in 1 .. Seeds:
    let
      config = cell.configFor(seed)
      steward = play(config, [skSteward, skSteward, skSteward])
      stripper = play(config, [skStripper, skStripper, skStripper])
      lone = play(config, [skSteward, skSteward, skStripper])
      freerider = play(config, [skSteward, skSteward, skFreerider])

    # (a) the working baseline sustains the plant
    var ok = steward.reason == "complete" and steward.ending == "shift_limit" and
      steward.machine.cap == 100 and steward.machine.integrity >= 40 and
      steward.machine.bananasMade >= 70 and steward.worstSeat() >= 14
    if ok:
      inc cleanA
    minSeat = min(minSeat, steward.worstSeat())
    madeTotal += steward.machine.bananasMade

    # (b) the temptation is real
    if lone.score(2) > lone.score(0) and lone.score(2) > lone.score(1):
      inc winsB

    # (c) universal defection is ruinous
    let share =
      if steward.machine.bananasMade == 0: 1.0
      else: stripper.machine.bananasMade.float /
        steward.machine.bananasMade.float
    worstShareC = max(worstShareC, share)
    if stripper.ending == "factory_ruined" and stripper.machine.cap <= 40:
      inc ruinedC

    # (d) one free-rider is survivable but pays
    let stewardMean = (freerider.score(0) + freerider.score(1)).float / 2.0
    let shareD =
      if steward.machine.bananasMade == 0: 1.0
      else: freerider.machine.bananasMade.float /
        steward.machine.bananasMade.float
    if freerider.score(2).float >= 0.8 * stewardMean and shareD >= 0.70 and
        freerider.machine.strips == 0:
      inc okD

  echo &"{cell.label:<34}" &
    &"{cleanA:>3}/{Seeds}  {minSeat:>4}  {madeTotal div Seeds:>5}   " &
    &"{winsB:>3}/{Seeds}   {worstShareC * 100.0:>5.1f}%  {ruinedC:>3}/{Seeds}   " &
    &"{okD:>3}/{Seeds}"

when isMainModule:
  let shipped = defaultGameConfig()
  echo "factory-commons baseline sweep — seeds 1..", Seeds,
    ", default variant, scripted rooms only"
  echo "gates: (a) all-steward sustains  (b) lone stripper out-scores both " &
    "stewards  (c) all-stripper ruinous  (d) free-rider survivable"
  echo ""
  echo &"{\"cell\":<34}{\"(a)\":>6}  {\"seat\":>4}  {\"made\":>5}   " &
    &"{\"(b)\":>6}   {\"(c) max\":>6}  {\"ruin\":>6}   {\"(d)\":>6}"
  echo repeat('-', 92)

  ## The note's authored values, then its gate-(a) ladder rung by rung, then
  ## the eatTrigger column at each of those rungs. `stripCapLoss` is swept
  ## last, against gate (c) alone.
  var cells: seq[Cell]
  for moveCooldown in [2, 1]:
    for rungs in [(20, 8), (30, 8), (30, 10)]:
      for eatTrigger in [3, 4, 6]:
        cells.add(Cell(
          label: &"move {moveCooldown} rust {rungs[0]} gain {rungs[1]} " &
            &"eat {eatTrigger}",
          moveCooldown: moveCooldown,
          rustPeriod: rungs[0],
          repairGain: rungs[1],
          stripCapLoss: shipped.stripCapLoss,
          eatTrigger: eatTrigger))
  for cell in cells:
    run(cell)

  echo ""
  echo "stripCapLoss column (shipped move/rust/gain/eat, gate (c) is the point)"
  echo repeat('-', 92)
  for stripCapLoss in [12, 16, 20]:
    run(Cell(
      label: &"stripCapLoss {stripCapLoss}",
      moveCooldown: shipped.moveCooldown,
      rustPeriod: shipped.rustPeriod,
      repairGain: shipped.repairGain,
      stripCapLoss: stripCapLoss,
      eatTrigger: shipped.eatTrigger))

  echo ""
  echo "shipped: move ", shipped.moveCooldown, " rust ", shipped.rustPeriod,
    " gain ", shipped.repairGain, " stripCapLoss ", shipped.stripCapLoss,
    " eat ", shipped.eatTrigger
