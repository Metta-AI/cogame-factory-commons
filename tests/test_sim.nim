## Sim units. Every rule in the design note's `## The game`, pinned one at a
## time against a hand-built state — because a rule that is only ever exercised
## by a full episode is a rule nobody can see fail.

import std/json

import factory_commons/[sim, scripted]

var checks = 0

template check(condition: untyped, message: string) =
  inc checks
  if not (condition):
    echo "FAIL: ", message
    quit(1)

proc baseConfig(): GameConfig =
  result = defaultGameConfig()
  result.numAgents = SeatCount
  for seat in 0 ..< SeatCount:
    result.tokens.add("token-" & $seat)
    result.players.add(PlayerConfig(name: Aliases[seat]))

proc parked(): Sim =
  ## A sim with every cog on its spawn cell, nothing on the belts, and the
  ## machine at full health — the blank slate every unit test starts from.
  initSim(baseConfig())

proc atConsole(sim: var Sim, seat: int) =
  sim.cogs[seat].x = ConsoleX0
  sim.cogs[seat].y = ConsoleRow

proc atBay(sim: var Sim, seat: int) =
  sim.cogs[seat].x = BayCol
  sim.cogs[seat].y = BayY0

proc lastEvent(sim: Sim, kind: string): JsonNode =
  for i in countdown(sim.events.len - 1, 0):
    if sim.events[i]{"k"}.getStr() == kind:
      return sim.events[i]
  nil

# ---------------------------------------------------------------- the floor
block floorGeometry:
  let config = baseConfig()
  check config.cellKind(0, 0) == ckWall, "the border ring is wall"
  check config.cellKind(25, 14) == ckWall, "the border ring is wall"
  check config.cellKind(18, 7) == ckMachine, "the machine body is impassable"
  check not config.walkable(18, 7), "the machine body is not walkable"
  for x in ConsoleX0 .. ConsoleX1:
    check config.isConsole(x, ConsoleRow), "console cell " & $x
    check config.isChute(x, ChuteRow), "chute cell " & $x
    check config.walkable(x, ConsoleRow), "the console pad is walkable"
  for y in BayY0 .. BayY1:
    check config.isBay(BayCol, y), "bay cell " & $y
  check config.hopperAt(PinkHopperX, PinkHopperY) == ord(cPink), "pink hopper"
  check config.hopperAt(BlueHopperX, BlueHopperY) == ord(cBlue), "blue hopper"
  check config.beltAt(BeltX0, PinkBeltRow) == ord(cPink), "pink belt mouth"
  check config.beltTailX() == 8, "belt tail at col 8"
  ## The distance table in the design note. These are what make specialising by
  ## colour beat generalising, so they are pinned rather than assumed.
  check config.bfsDistance(8, 2, 16, 4) == 10, "pink tail -> pink hopper is 10"
  check config.bfsDistance(8, 12, 16, 10) == 10, "blue tail -> blue hopper is 10"
  check config.bfsDistance(16, 4, 18, 4) == 2, "pink hopper -> console is 2"
  check config.bfsDistance(16, 10, 18, 4) == 10, "blue hopper -> console is 10"
  check config.bfsDistance(18, 4, 18, 10) == 12, "console -> chute is 12"
  check config.bfsDistance(15, 7, 8, 2) == 12, "bay -> pink tail is 12"
  check config.bfsDistance(15, 7, 8, 12) == 12, "bay -> blue tail is 12"
  check config.bfsDistance(19, 10, 16, 10) == 3, "chute -> blue hopper is 3"

block bfsDeterminism:
  let config = baseConfig()
  let a = config.bfsFirstStep(10, 4, [[18, 4]])
  let b = config.bfsFirstStep(10, 4, [[18, 4]])
  check a == b, "the same state yields the same path twice"
  check a in {aMoveN, aMoveE, aMoveS, aMoveW}, "a path step is a move"
  check config.bfsFirstStep(18, 4, [[18, 4]]) == aWait,
    "already on the target is a wait"
  check config.bfsFirstStep(18, 7, [[18, 4]]) == aWait,
    "an unreachable start is a wait"

# ---------------------------------------------------------------- bands
block bandTable:
  let config = baseConfig()
  check config.bandOf(100, 100) == bPrime, "integrity 100 is PRIME"
  check config.bandOf(75, 100) == bPrime, "integrity 75 is PRIME"
  check config.bandOf(74, 100) == bWorn, "integrity 74 is WORN"
  check config.bandOf(40, 100) == bWorn, "integrity 40 is WORN"
  check config.bandOf(39, 100) == bFailing, "integrity 39 is FAILING"
  check config.bandOf(25, 100) == bFailing, "integrity 25 is FAILING"
  check config.bandOf(24, 100) == bCritical, "integrity 24 is CRITICAL"
  check config.bandOf(10, 100) == bCritical, "integrity 10 is CRITICAL"
  check config.bandOf(9, 100) == bSeized, "integrity 9 is SEIZED"
  check config.bandOf(0, 100) == bSeized, "integrity 0 is SEIZED"
  ## cap is read FIRST: a scrap machine is scrap at every integrity.
  for integrity in 0 .. 100:
    check config.bandOf(integrity, 24) == bScrap,
      "cap 24 overrides integrity " & $integrity
  var words: seq[string]
  for integrity in 0 .. 100:
    let word = $config.bandOf(integrity, 100)
    if word notin words:
      words.add(word)
  check words.len == 5,
    "integrity 0..100 at full cap covers five band words, got " & $words
  for band in Band:
    check ($band).len > 0, "every band has a word"

block yieldTables:
  check bPrime.publicYield() == PublicYield[0], "PRIME presses the top yield"
  check bWorn.publicYield() == PublicYield[1], "WORN presses the middle one"
  check bFailing.publicYield() == PublicYield[2], "FAILING presses the last one"
  check bCritical.publicYield() == 0, "a press is illegal at CRITICAL"
  check bSeized.publicYield() == 0, "a press is illegal at SEIZED"
  check bScrap.publicYield() == 0, "a press is illegal at SCRAP"
  check bPrime.privateYield() == PrivateYield[0], "PRIME strips the top private yield"
  check bWorn.privateYield() == PrivateYield[1], "WORN strips the middle one"
  check bFailing.privateYield() == PrivateYield[2], "FAILING strips the last one"
  check bCritical.privateYield() == PrivateYield[2],
    "CRITICAL strips the same as FAILING — the last band a lever still pays in"
  check bSeized.privateYield() == 0, "a strip is illegal at SEIZED"
  check bScrap.privateYield() == 0, "a strip is illegal at SCRAP"

# ---------------------------------------------------------------- press
block pressPreconditions:
  block wrongPlace:
    var sim = parked()
    sim.machine.pink = 1
    sim.machine.blue = 1
    check sim.pressBlockedWhy(0) == "place", "off the console is `place`"
    sim.doPress(0)
    check sim.lastEvent("blocked"){"why"}.getStr() == "place", "blocked place"
    check sim.machine.presses == 0, "an illegal press does nothing"
  block noStock:
    var sim = parked()
    sim.atConsole(0)
    check sim.pressBlockedWhy(0) == "stock", "a zero stock is `stock`"
    sim.machine.pink = 1
    check sim.pressBlockedWhy(0) == "stock", "one colour only is still `stock`"
  block lowIntegrity:
    var sim = parked()
    sim.atConsole(0)
    sim.machine.pink = 1
    sim.machine.blue = 1
    sim.machine.integrity = sim.config.pressFloor - 1
    check sim.pressBlockedWhy(0) == "integrity",
      "integrity below the press floor is `integrity`"
  block scrapCap:
    var sim = parked()
    sim.atConsole(0)
    sim.machine.pink = 1
    sim.machine.blue = 1
    sim.machine.cap = sim.config.pressFloor - 1
    check sim.pressBlockedWhy(0) == "scrap", "cap below the press floor is `scrap`"
    check sim.stripBlockedWhy(0) == "scrap", "and a strip is scrap too, forever"
  block runningCooldown:
    var sim = parked()
    sim.atConsole(0)
    sim.machine.pink = 1
    sim.machine.blue = 1
    sim.machine.cooldown = 3
    check sim.pressBlockedWhy(0) == "cooldown", "a running cooldown is `cooldown`"
  block modeMismatch:
    var config = baseConfig()
    config.eitherOr = true
    var sim = initSim(config)
    sim.atConsole(0)
    sim.machine.pink = 1
    sim.machine.blue = 1
    sim.machine.mode = mOverride
    check sim.pressBlockedWhy(0) == "mode", "an override-locked machine is `mode`"
    sim.machine.mode = mCycle
    check sim.stripBlockedWhy(0) == "mode", "a cycle-locked machine is `mode`"
    sim.machine.mode = mUnset
    check sim.pressBlockedWhy(0) == "", "an unset mode allows both"
    check sim.stripBlockedWhy(0) == "", "an unset mode allows both"

block stripPreconditions:
  var sim = parked()
  sim.atConsole(0)
  sim.machine.pink = 1
  check sim.stripBlockedWhy(0) == "", "one cube of either colour is enough"
  sim.machine.integrity = sim.config.stripFloor - 1
  check sim.stripBlockedWhy(0) == "integrity",
    "integrity below the strip floor is `integrity`"
  sim.machine.integrity = sim.config.stripFloor
  check sim.stripBlockedWhy(0) == "", "exactly at the strip floor is legal"
  sim.machine.pink = 0
  sim.machine.blue = 0
  check sim.stripBlockedWhy(0) == "stock", "no cube at all is `stock`"

block pressEffects:
  var sim = parked()
  sim.atConsole(0)
  sim.machine.pink = 2
  sim.machine.blue = 3
  sim.doPress(0)
  check sim.machine.pink == 1, "a press consumes one pink"
  check sim.machine.blue == 2, "a press consumes one blue"
  check sim.machine.integrity == 100 - sim.config.pressWear, "press wear"
  check sim.machine.cap == 100, "a press never touches the cap"
  check sim.machine.cooldown == sim.config.pressCooldown, "press cooldown"
  check sim.machine.bananasMade == PublicYield[0], "PRIME pays into the pot"
  check sim.bananas.len == PublicYield[0],
    "and every one lands on the floor, not in a score"
  check sim.cogs[0].banked == 0, "a press banks nothing privately"
  let row = sim.lastEvent("press")
  check row{"band"}.getStr() == "PRIME", "the press records its band"
  check row{"yield"}.getInt() == PublicYield[0], "the press records its yield"

block bandReadBeforeWear:
  ## integrity 75 is PRIME and pays 3 privately; the wear that follows drops it
  ## to WORN, and the recorded yield must still be the PRIME number.
  var sim = parked()
  sim.atConsole(0)
  sim.machine.integrity = 75
  sim.machine.pink = 1
  sim.doStrip(0)
  check sim.cogs[0].banked == PrivateYield[0],
    "the band is read BEFORE the wear is applied, so a strip at integrity 75 " &
    "pays the PRIME number even though the wear drops it to WORN"
  check sim.machine.integrity == 75 - sim.config.stripWear, "strip wear"
  check sim.lastEvent("strip"){"band"}.getStr() == "PRIME", "recorded band"

block capIsIrreversible:
  var sim = parked()
  sim.atConsole(0)
  var previousCap = sim.machine.cap
  for _ in 0 ..< 10:
    sim.machine.pink = 2
    sim.machine.cooldown = 0
    sim.machine.integrity = max(sim.machine.integrity, sim.config.stripFloor)
    sim.machine.integrity = min(sim.machine.integrity, sim.machine.cap)
    let before = sim.machine.cap
    sim.doStrip(0)
    check sim.machine.cap <= before, "cap is monotone non-increasing"
    check sim.machine.cap >= sim.config.capMin, "cap floors at capMin"
    check sim.machine.integrity <= sim.machine.cap, "integrity never exceeds cap"
    previousCap = sim.machine.cap
  check previousCap == sim.config.capMin,
    "ten pulls reach the cap floor at any stripCapLoss the schema allows"
  ## Repair lifts integrity and NEVER the cap.
  let capped = sim.machine.cap
  sim.atBay(0)
  sim.machine.cooldown = 0
  sim.cogs[0].carrying = ord(cPink)
  sim.machine.integrity = 0
  sim.doFix(0)
  check sim.machine.cap == capped, "repairGain never raises the cap"
  check sim.machine.integrity == min(capped, sim.config.repairGain), "repair gain"

block fixRules:
  var sim = parked()
  sim.atBay(0)
  check sim.fixBlockedWhy(0) == "stock", "an empty hand cannot fix"
  sim.cogs[0].carrying = ord(cBlue)
  check sim.fixBlockedWhy(0) == "integrity",
    "a machine already at cap has nothing to fix"
  sim.machine.integrity = 50
  check sim.fixBlockedWhy(0) == "", "a cube in hand below cap is legal"
  sim.doFix(0)
  check sim.cogs[0].carrying == -1, "fix consumes exactly one cube"
  check sim.machine.integrity == 58, "repairGain 8"
  check sim.machine.cooldown == sim.config.repairCooldown, "repair cooldown"
  ## The clamp at cap.
  sim.machine.integrity = sim.machine.cap - 2
  sim.machine.cooldown = 0
  sim.cogs[0].carrying = ord(cPink)
  sim.doFix(0)
  check sim.machine.integrity == sim.machine.cap, "fix clamps at cap"
  ## And nothing outside the bay.
  sim.cogs[0].x = 10
  check sim.fixBlockedWhy(0) == "place", "fix is bay-only"

# ---------------------------------------------------------------- rust
block rustFires:
  var sim = parked()
  ## Rust is skipped at tick 0 and fires on every later multiple.
  for _ in 0 ..< sim.config.rustPeriod:
    sim.stepTick()
  check sim.tick == sim.config.rustPeriod, "ticks advanced"
  check sim.machine.integrity == 100, "tick 0 does not rust"
  sim.stepTick()
  check sim.machine.integrity == 99, "rust fires at tick mod rustPeriod == 0"
  sim.machine.integrity = 0
  for _ in 0 ..< sim.config.rustPeriod * 2:
    sim.stepTick()
  check sim.machine.integrity == 0, "rust floors at 0"

# ---------------------------------------------------------------- belts
block beltsAndDispensers:
  var sim = parked()
  ## Tick 0 dispenses onto both mouths.
  sim.dispensersEmit()
  check sim.cubes.len == 2, "both dispensers emit at tick 0"
  check sim.dispensed == 2, "and both are counted"
  ## A blocked mouth stalls its dispenser; matter is never destroyed.
  sim.dispensersEmit()
  check sim.cubes.len == 2, "an occupied mouth stalls the dispenser"
  ## Belt advance moves the train east one cell.
  sim.tick = sim.config.beltPeriod
  sim.beltsAdvance()
  check sim.cubeIndexAt(BeltX0 + 1, PinkBeltRow) >= 0, "the cube moved east"
  check sim.cubeIndexAt(BeltX0, PinkBeltRow) < 0, "and left its old cell"
  ## The tail cube never moves, and a train backs up behind it.
  var train = parked()
  let tail = train.config.beltTailX()
  for x in BeltX0 .. tail:
    train.cubes.add(LooseCube(x: x, y: PinkBeltRow, cube: cPink))
    train.dispensed += 1
  train.tick = train.config.beltPeriod
  train.beltsAdvance()
  for x in BeltX0 .. tail:
    check train.cubeIndexAt(x, PinkBeltRow) >= 0,
      "a full belt does not move at all: cell " & $x
  ## A gap lets the whole train step, tail-first.
  var gapped = parked()
  gapped.cubes.add(LooseCube(x: BeltX0, y: PinkBeltRow, cube: cPink))
  gapped.cubes.add(LooseCube(x: BeltX0 + 1, y: PinkBeltRow, cube: cPink))
  gapped.dispensed = 2
  gapped.tick = gapped.config.beltPeriod
  gapped.beltsAdvance()
  check gapped.cubeIndexAt(BeltX0 + 1, PinkBeltRow) >= 0, "a train moves as a train"
  check gapped.cubeIndexAt(BeltX0 + 2, PinkBeltRow) >= 0, "a train moves as a train"
  check gapped.cubeIndexAt(BeltX0, PinkBeltRow) < 0, "and vacates the mouth"

# ---------------------------------------------------------------- hoppers
block misfeedBounce:
  var sim = parked()
  sim.cogs[0].x = PinkHopperX
  sim.cogs[0].y = PinkHopperY
  sim.cogs[0].carrying = ord(cBlue)
  sim.resolveGraspDrop([aDrop, aWait, aWait])
  check sim.machine.blue == 0, "a blue cube is not blue stock at the pink hopper"
  check sim.machine.pink == 0, "and it is certainly not pink stock"
  check sim.cogs[0].carrying == -1, "the cube left the hand"
  check sim.cubes.len == 1, "cubes are never destroyed"
  ## N, E, S, W order: north of (16,4) is (16,3), plain floor.
  check sim.cubes[0].x == PinkHopperX and sim.cubes[0].y == PinkHopperY - 1,
    "the bounce takes the first free neighbour in N, E, S, W order"
  check sim.cogs[0].misfeeds == 1, "and it is a misfeed against that seat"
  let row = sim.lastEvent("misfeed")
  check row{"why"}.getStr() == "colour", "a wrong-colour drop is why=colour"

block hopperFullBounce:
  var sim = parked()
  sim.cogs[0].x = PinkHopperX
  sim.cogs[0].y = PinkHopperY
  sim.cogs[0].carrying = ord(cPink)
  sim.machine.pink = sim.config.hopperCap
  sim.resolveGraspDrop([aDrop, aWait, aWait])
  check sim.machine.pink == sim.config.hopperCap, "a full hopper takes no more"
  check sim.cubes.len == 1, "the cube bounced instead of vanishing"
  check sim.lastEvent("misfeed"){"why"}.getStr() == "full", "why=full"

block bounceWithNoRoomStaysInHand:
  var sim = parked()
  sim.cogs[0].x = PinkHopperX
  sim.cogs[0].y = PinkHopperY
  sim.cogs[0].carrying = ord(cBlue)
  ## Fill every orthogonal neighbour of the pink hopper.
  for dir in 0 .. 3:
    let
      nx = PinkHopperX + NeighbourDx[dir]
      ny = PinkHopperY + NeighbourDy[dir]
    if sim.config.walkable(nx, ny):
      sim.cubes.add(LooseCube(x: nx, y: ny, cube: cPink))
      sim.dispensed += 1
  let before = sim.cubes.len
  sim.resolveGraspDrop([aDrop, aWait, aWait])
  check sim.cogs[0].carrying == ord(cBlue),
    "with nowhere to bounce the drop degrades to wait and the cube stays in hand"
  check sim.cubes.len == before, "and nothing is created or destroyed"

block goodDrop:
  var sim = parked()
  sim.cogs[0].x = BlueHopperX
  sim.cogs[0].y = BlueHopperY
  sim.cogs[0].carrying = ord(cBlue)
  sim.resolveGraspDrop([aDrop, aWait, aWait])
  check sim.machine.blue == 1, "the right colour enters stock"
  check sim.cogs[0].carrying == -1, "and leaves the hand"
  check sim.lastEvent("drop"){"into"}.getStr() == "blueHopper", "into=blueHopper"

block graspRules:
  var sim = parked()
  sim.cubes.add(LooseCube(x: sim.cogs[0].x, y: sim.cogs[0].y, cube: cPink))
  sim.dispensed = 1
  sim.resolveGraspDrop([aGrasp, aWait, aWait])
  check sim.cogs[0].carrying == ord(cPink), "grasp picks up the cube underfoot"
  check sim.cubes.len == 0, "and takes it off the floor"
  ## carryCap 1: a second grasp with a full hand does nothing.
  sim.cubes.add(LooseCube(x: sim.cogs[0].x, y: sim.cogs[0].y, cube: cBlue))
  sim.dispensed = 2
  sim.resolveGraspDrop([aGrasp, aWait, aWait])
  check sim.cogs[0].carrying == ord(cPink), "carryCap 1: the hand is full"
  check sim.cubes.len == 1, "so the cube stays put"

block lowerSlotWinsTheGrasp:
  var sim = parked()
  ## Both cogs on one cell is impossible in play, so put the cube where slot 0
  ## stands and move slot 1 onto the same cell by hand: only the LOWER slot
  ## gets it, and the higher slot's grasp finds nothing.
  sim.cogs[1].x = sim.cogs[0].x
  sim.cogs[1].y = sim.cogs[0].y
  sim.cubes.add(LooseCube(x: sim.cogs[0].x, y: sim.cogs[0].y, cube: cPink))
  sim.dispensed = 1
  sim.resolveGraspDrop([aGrasp, aGrasp, aWait])
  check sim.cogs[0].carrying == ord(cPink), "the lower slot takes it"
  check sim.cogs[1].carrying == -1, "the higher slot finds it gone"

# ---------------------------------------------------------------- movement
block moveRules:
  var sim = parked()
  let (x0, y0) = (sim.cogs[0].x, sim.cogs[0].y)
  sim.resolveMoves([aMoveE, aWait, aWait])
  check sim.cogs[0].x == x0 + 1 and sim.cogs[0].y == y0, "a legal move lands"
  check sim.cogs[0].moveCd == sim.config.moveCooldown, "and starts the cooldown"
  sim.resolveMoves([aMoveE, aWait, aWait])
  check sim.cogs[0].x == x0 + 1, "a move on cooldown degrades to wait"
  sim.cogs[0].moveCd = 0
  ## Into the machine body: refused.
  sim.cogs[0].x = MachineX0 - 1
  sim.cogs[0].y = MachineY0 + 1
  sim.resolveMoves([aMoveE, aWait, aWait])
  check sim.cogs[0].x == MachineX0 - 1, "a move into the machine is refused"
  ## Into a wall: refused.
  sim.cogs[0].moveCd = 0
  sim.cogs[0].x = 1
  sim.cogs[0].y = 1
  sim.resolveMoves([aMoveW, aWait, aWait])
  check sim.cogs[0].x == 1, "a move into the wall ring is refused"

block twoCogsCannotShareACell:
  var sim = parked()
  ## Slot 0 at (10,7), slot 1 at (12,7): both step toward (11,7). The lower
  ## slot resolves first against the LIVE board, so the higher slot finds the
  ## cell taken and waits.
  sim.cogs[0].x = 10
  sim.cogs[0].y = 7
  sim.cogs[1].x = 12
  sim.cogs[1].y = 7
  sim.cogs[2].x = 5
  sim.cogs[2].y = 5
  sim.resolveMoves([aMoveE, aMoveW, aWait])
  check sim.cogs[0].x == 11, "the lower slot enters the contested cell"
  check sim.cogs[1].x == 12, "and the higher slot is refused"
  check not (sim.cogs[0].x == sim.cogs[1].x and sim.cogs[0].y == sim.cogs[1].y),
    "no two cogs ever share a cell"

# ---------------------------------------------------------------- bananas
block bananaPlacement:
  var sim = parked()
  sim.placeBananas(9)
  for cell in chuteCells():
    check sim.bananasAt(cell[0], cell[1]) == sim.config.cellBananaCap,
      "the chute fills west to east to cellBananaCap"
  check sim.bananas.len == 9, "nine bananas fit the chute exactly"
  ## The tenth overflows onto the ring, in (row, col) order.
  sim.placeBananas(1)
  let ring = overflowCells(sim.config)
  check ring.len > 0, "the chute has an overflow ring"
  check sim.bananasAt(ring[0][0], ring[0][1]) == 1,
    "the overflow starts at the first ring cell in (row, col) order"
  ## And a flood past chute + ring spoils, with a count.
  var flooded = parked()
  let capacity = (3 + ring.len) * flooded.config.cellBananaCap
  flooded.placeBananas(capacity + 5)
  check flooded.machine.bananasSpoiled == 5, "the surplus spoils"
  check flooded.lastEvent("spoil"){"n"}.getInt() == 5, "and the count is recorded"

block bananaRotsAtExactlyLifetime:
  var sim = parked()
  sim.bananas.add(Banana(x: ConsoleX0, y: ChuteRow, age: 0))
  for _ in 0 ..< sim.config.bananaLifetime - 1:
    sim.bananaRot()
  check sim.bananas.len == 1, "a banana lives its full lifetime"
  sim.bananaRot()
  check sim.bananas.len == 0, "and rots at exactly bananaLifetime ticks"
  check sim.machine.bananasRotted == 1, "rot is counted"

block autoEatIsNotAnAction:
  var sim = parked()
  sim.cogs[0].x = ConsoleX0
  sim.cogs[0].y = ChuteRow
  for _ in 0 ..< 3:
    sim.bananas.add(Banana(x: ConsoleX0, y: ChuteRow, age: 0))
  sim.autoEat()
  check sim.cogs[0].eaten == 3, "a cog on a chute cell eats EVERY banana on it"
  check sim.bananas.len == 0, "and the cell is emptied"
  check sim.lastEvent("eat"){"n"}.getInt() == 3, "with the count recorded"

# ---------------------------------------------------------------- either-or
block eitherOrLock:
  var config = baseConfig()
  config.eitherOr = true
  var sim = initSim(config)
  sim.atConsole(0)
  sim.machine.pink = 2
  sim.machine.blue = 2
  check sim.machine.mode == mUnset, "the mode starts unset"
  ## A BLOCKED operation must not lock anything.
  sim.machine.cooldown = 5
  sim.doPress(0)
  check sim.machine.mode == mUnset, "a blocked press locks nothing"
  sim.machine.cooldown = 0
  sim.doPress(0)
  check sim.machine.mode == mCycle, "the first successful press locks cycle"
  check sim.lastEvent("lock"){"mode"}.getStr() == "cycle", "and records it"
  ## Irreversible, and the other operation is illegal from that tick.
  sim.machine.cooldown = 0
  check sim.stripBlockedWhy(0) == "mode", "the override is locked out"
  sim.doStrip(0)
  check sim.machine.mode == mCycle, "and it cannot re-lock the machine"
  check sim.machine.strips == 0, "nor can it pull"
  var beats = 0
  for row in sim.beats:
    if row{"k"}.getStr() == "lock":
      inc beats
  check beats == 1, "the lock fires exactly once"

# ---------------------------------------------------------- conservation
proc runScripted(config: GameConfig, kinds: array[SeatCount, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    for seat in 0 ..< result.cogs.len:
      result.applyOrder(seat, result.scriptedOrder(seat, kinds[seat]))
    result.playShift()
    result.checkEnd(false)

block cubesAreConserved:
  var config = baseConfig()
  var sim = initSim(config)
  for seat in 0 ..< SeatCount:
    sim.applyOrder(seat, sim.scriptedOrder(seat, skSteward))
  for _ in 0 ..< config.maxTicks():
    sim.stepTick()
    if sim.tick mod config.ticksPerShift == 0:
      sim.closeShift()
      for seat in 0 ..< sim.cogs.len:
        sim.applyOrder(seat, sim.scriptedOrder(seat, skSteward))
    check sim.cubesConserved(),
      "dispensed == on the floor + in hands + in stock + consumed, at tick " &
      $sim.tick
  check sim.tick == config.maxTicks(), "900 ticks played"
  check sim.frames.len == config.maxTicks(), "one frame per tick played"
  check sim.series.len == config.maxTicks(), "one series row per tick played"

block invariantsHold:
  let sim = runScripted(baseConfig(), [skSteward, skSteward, skStripper])
  check sim.machine.integrity >= 0, "integrity is non-negative"
  check sim.machine.integrity <= sim.machine.cap, "integrity <= cap"
  check sim.machine.cap <= 100, "cap <= 100"
  check sim.machine.cap >= sim.config.capMin, "cap >= capMin"
  for seat in 0 ..< sim.cogs.len:
    check sim.cogs[seat].carrying >= -1 and sim.cogs[seat].carrying <= 1,
      "a carried cube is a colour or nothing"
    check sim.score(seat) >= 0, "scores are non-negative"

# ---------------------------------------------------------------- determinism
block determinism:
  let config = baseConfig()
  let a = runScripted(config, [skSteward, skSteward, skStripper])
  let b = runScripted(config, [skSteward, skSteward, skStripper])
  check a.gameHash() == b.gameHash(),
    "the same seed and the same order script produce an identical gameHash"
  check a.tick == b.tick, "and the same tick count"
  check a.events.len == b.events.len, "and the same event stream length"
  for i in 0 ..< a.events.len:
    check $a.events[i] == $b.events[i], "byte-identical event row " & $i
  ## A different order script must produce a different hash, or the hash is
  ## not measuring anything.
  let c = runScripted(config, [skStripper, skStripper, skStripper])
  check a.gameHash() != c.gameHash(), "a different script moves the hash"

echo "test_sim: ", checks, " checks passed"
