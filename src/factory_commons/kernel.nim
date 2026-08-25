## The floor kernel: one standing order in, one per-tick grid action out.
##
## A seat does not emit 900 actions by hand — no LLM can. Once per shift each
## seat submits one standing order and this deterministic kernel turns it into
## the per-tick action stream for the whole shift. The sim's policy interface
## is per-tick grid actions exactly as the idea asks; the LLM chooses the JOB,
## the kernel walks the floor.

import ./sim_types, ./sim_state, ./floor, ./machine

proc scarcerColour*(sim: Sim): Cube =
  ## The stock the machine has least of, ties to pink. `cube: "any"` resolves
  ## through here, which is what makes an "any" order still feed a press.
  if sim.machine.pink <= sim.machine.blue: cPink else: cBlue

proc targetColour*(sim: Sim, seat: int): Cube =
  let choice = sim.cogs[seat].order.cube
  case choice
  of ccPink: cPink
  of ccBlue: cBlue
  of ccAny: sim.scarcerColour()

proc nearestLooseCube*(sim: Sim, seat: int, cube: Cube): int =
  ## Index of the nearest loose cube of that colour, ties by (row, col). -1
  ## when none is loose. One distance field, not one BFS per cube.
  var
    best = -1
    bestDist = high(int)
  let
    cog = sim.cogs[seat]
    field = sim.config.bfsField(cog.x, cog.y)
  for i, loose in sim.cubes:
    if loose.cube != cube:
      continue
    let dist = field[loose.y * Cols + loose.x]
    if dist < 0:
      continue
    if dist < bestDist:
      bestDist = dist
      best = i
    elif dist == bestDist and best >= 0:
      let other = sim.cubes[best]
      if loose.y < other.y or (loose.y == other.y and loose.x < other.x):
        best = i
  best

proc fullestChuteCell*(sim: Sim): array[2, int] =
  ## The chute cell holding the most bananas, ties to the lowest col.
  var
    best = chuteCells()[0]
    bestCount = -1
  for cell in chuteCells():
    let count = sim.bananasAt(cell[0], cell[1])
    if count > bestCount:
      bestCount = count
      best = cell
  best

proc chuteTotal*(sim: Sim): int =
  for cell in chuteCells():
    result += sim.bananasAt(cell[0], cell[1])

proc stepToward*(sim: Sim, seat: int, targets: openArray[array[2, int]]): Action =
  ## One step of the planned route, with a deadlock breaker.
  ##
  ## The primary plan treats the other cogs as TRANSPARENT, which is the design
  ## note's rule and is what keeps a route stable while three cogs shuffle past
  ## each other. But two cogs meeting head-on on one row both compute the
  ## shortest path THROUGH the other, both moves are refused at step 7, and
  ## neither ever budges again — a silent hang that produces a 900-tick episode
  ## with zero presses. So: if the planned first step lands on another cog,
  ## re-plan with the cogs as obstacles and take that route instead. Degrade,
  ## never hang, applied to the floor as well as to the network.
  let cog = sim.cogs[seat]
  let action = sim.config.bfsFirstStep(cog.x, cog.y, targets)
  var dx = 0
  var dy = 0
  case action
  of aMoveN: dy = -1
  of aMoveS: dy = 1
  of aMoveE: dx = 1
  of aMoveW: dx = -1
  else: return action
  if sim.cogAt(cog.x + dx, cog.y + dy) < 0:
    return action
  var others: seq[array[2, int]]
  for other in 0 ..< sim.cogs.len:
    if other != seat:
      others.add([sim.cogs[other].x, sim.cogs[other].y])
  sim.config.bfsFirstStep(cog.x, cog.y, targets, others)

proc freeConsoleCells*(sim: Sim, seat: int): seq[array[2, int]] =
  ## Console cells nobody else is standing on — plus the one this cog is
  ## already on, so "go to the console" never walks off the console.
  for cell in consoleCells():
    let who = sim.cogAt(cell[0], cell[1])
    if who < 0 or who == seat:
      result.add(cell)

proc freeBayCells*(sim: Sim, seat: int): seq[array[2, int]] =
  for cell in bayCells():
    let who = sim.cogAt(cell[0], cell[1])
    if who < 0 or who == seat:
      result.add(cell)

proc freeChuteCells*(sim: Sim, seat: int): seq[array[2, int]] =
  for cell in chuteCells():
    let who = sim.cogAt(cell[0], cell[1])
    if who < 0 or who == seat:
      result.add(cell)

proc fetchAction(sim: Sim, seat: int, cube: Cube): Action =
  ## `operate` rule 4, shared by every job that needs a cube in hand: BFS to
  ## the nearest loose cube of `cube` and `grasp` on arrival; with none loose,
  ## wait at that belt's tail so the next dispense lands under your hand.
  let cog = sim.cogs[seat]
  let index = sim.nearestLooseCube(seat, cube)
  if index >= 0:
    let loose = sim.cubes[index]
    if loose.x == cog.x and loose.y == cog.y:
      return aGrasp
    return sim.stepToward(seat, [[loose.x, loose.y]])
  let tail = [sim.config.beltTailX(), beltRow(cube)]
  if cog.x == tail[0] and cog.y == tail[1]:
    return aWait
  sim.stepToward(seat, [tail])

proc harvestAction(sim: Sim, seat: int): Action =
  ## Stand on the fullest chute cell; auto-eat (step 8) does the rest.
  let
    cog = sim.cogs[seat]
    cell = sim.fullestChuteCell()
  if cog.x == cell[0] and cog.y == cell[1]:
    return aWait
  ## Another cog may be parked on the fullest cell; take any free chute cell
  ## rather than shuffling forever behind it.
  let free = sim.freeChuteCells(seat)
  if free.len == 0:
    return aWait
  var targets = @[cell]
  if sim.cogAt(cell[0], cell[1]) >= 0:
    targets = free
  sim.stepToward(seat, targets)

proc dropAction(sim: Sim, seat: int): Action =
  ## Hand full: take it to its own colour's hopper and drop on arrival.
  let
    cog = sim.cogs[seat]
    hopper = hopperCell(Cube(cog.carrying))
  if cog.x == hopper[0] and cog.y == hopper[1]:
    return aDrop
  sim.stepToward(seat, [hopper])

proc operateAction(sim: Sim, seat: int): Action =
  let cog = sim.cogs[seat]
  ## 1.1 — harvesting is part of operating. Without this rule a room of pure
  ## operators watches its own output rot.
  if cog.carrying < 0 and sim.chuteTotal() >= sim.config.eatTrigger:
    return sim.harvestAction(seat)
  if cog.carrying >= 0:
    return sim.dropAction(seat)
  ## The `cap` guard is extended with the either-or mode gate for the same
  ## reason it carries the cap gate at all: a press that is STRUCTURALLY
  ## impossible for the rest of the episode must not park an operator at the
  ## console forever. Everything transient (a running cooldown, a lower slot
  ## getting there first) is left to step 6, which records it as `blocked`.
  if sim.machine.pink >= 1 and sim.machine.blue >= 1 and
      sim.machine.cap >= sim.config.pressFloor and
      sim.config.modeAllows(sim.machine.mode, true):
    if sim.config.isConsole(cog.x, cog.y):
      return aPress
    let free = sim.freeConsoleCells(seat)
    if free.len > 0:
      return sim.stepToward(seat, free)
    return aWait
  sim.fetchAction(seat, sim.targetColour(seat))

proc maintainAction(sim: Sim, seat: int): Action =
  let cog = sim.cogs[seat]
  ## 3.1 — nothing to repair, or nothing worth repairing: operate instead.
  if sim.machine.integrity >= sim.machine.cap or
      sim.machine.cap < sim.config.pressFloor:
    return sim.operateAction(seat)
  if cog.carrying >= 0:
    if sim.config.isBay(cog.x, cog.y):
      return aFix
    let free = sim.freeBayCells(seat)
    if free.len > 0:
      return sim.stepToward(seat, free)
    return aWait
  sim.fetchAction(seat, sim.targetColour(seat))

proc stripAction(sim: Sim, seat: int): Action =
  let cog = sim.cogs[seat]
  ## 2.1 — a stripper never deadlocks the episode: with the plant scrapped, or
  ## the either-or lock set to `cycle`, it behaves as `operate` for this tick.
  if sim.machine.cap < sim.config.pressFloor or
      (sim.config.eitherOr and sim.machine.mode == mCycle):
    return sim.operateAction(seat)
  if cog.carrying >= 0:
    return sim.dropAction(seat)
  if sim.machine.pink + sim.machine.blue >= 1 and
      sim.machine.integrity >= sim.config.stripFloor:
    if sim.config.isConsole(cog.x, cog.y):
      return aStrip
    let free = sim.freeConsoleCells(seat)
    if free.len > 0:
      return sim.stepToward(seat, free)
    return aWait
  sim.fetchAction(seat, sim.targetColour(seat))

proc eatAction(sim: Sim, seat: int): Action =
  let cog = sim.cogs[seat]
  if sim.chuteTotal() > 0:
    return sim.harvestAction(seat)
  let free = sim.freeChuteCells(seat)
  if free.len == 0:
    return aWait
  for cell in free:
    if cog.x == cell[0] and cog.y == cell[1]:
      return aWait
  sim.stepToward(seat, free)

proc kernelAction*(sim: Sim, seat: int): Action =
  ## Step 3. One action, from this seat's standing order and the state at the
  ## start of the step. A cog whose move cooldown is still running emits
  ## `wait` instead of a `move_*` — the kernel plans the route anyway, so the
  ## next legal tick resumes it without re-deciding.
  let action =
    case sim.cogs[seat].order.job
    of jOperate: sim.operateAction(seat)
    of jStrip: sim.stripAction(seat)
    of jMaintain: sim.maintainAction(seat)
    of jEat: sim.eatAction(seat)
    of jIdle: aWait
  if sim.cogs[seat].moveCd > 0 and action in {aMoveN, aMoveS, aMoveE, aMoveW}:
    return aWait
  action
