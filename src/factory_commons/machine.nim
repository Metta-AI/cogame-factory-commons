## The machine: bands, the two yield tables, `press` / `strip` / `fix`, and
## banana placement.
##
## New in Factory Commons (paintbot has no common-pool asset). The two
## operations differ along exactly two axes — WHO GETS THE GOODS and WHAT IT
## COSTS THE MACHINE — and everything else (input cost, cooldown) follows from
## those two.

import std/[algorithm, json]

import ./sim_types, ./sim_state, ./floor

proc bandOf*(config: GameConfig, integrity, cap: int): Band =
  ## The band is read from `cap` FIRST, then `integrity`, and it is the single
  ## word the gauge shows. The two lower bounds are the two floors, so a
  ## variant that moves a floor moves the band with it.
  if cap < config.pressFloor:
    bScrap
  elif integrity >= 75:
    bPrime
  elif integrity >= 40:
    bWorn
  elif integrity >= config.pressFloor:
    bFailing
  elif integrity >= config.stripFloor:
    bCritical
  else:
    bSeized

proc band*(sim: Sim): Band =
  sim.config.bandOf(sim.machine.integrity, sim.machine.cap)

proc publicYield*(band: Band): int =
  ## Bananas a `press` puts ON THE CHUTE. 0 in every band where a press is
  ## illegal, so the number and the legality can never disagree.
  case band
  of bPrime: PublicYield[0]
  of bWorn: PublicYield[1]
  of bFailing: PublicYield[2]
  else: 0

proc privateYield*(band: Band): int =
  ## Bananas a `strip` credits DIRECTLY to the acting seat.
  case band
  of bPrime: PrivateYield[0]
  of bWorn: PrivateYield[1]
  of bFailing, bCritical: PrivateYield[2]
  else: 0

proc modeAllows*(config: GameConfig, mode: Mode, wantCycle: bool): bool =
  ## The `either-or` gate. Outside that variant both operations stay live for
  ## the whole episode.
  if not config.eitherOr or mode == mUnset:
    return true
  if wantCycle: mode == mCycle else: mode == mOverride

proc pressBlockedWhy*(sim: Sim, seat: int): string =
  ## "" when the press is legal, else the `blocked.why` for the FIRST rule it
  ## breaks. Order is fixed so a policy's mistakes read the same every time.
  let
    cog = sim.cogs[seat]
    m = sim.machine
    c = sim.config
  if not c.isConsole(cog.x, cog.y): return "place"
  if m.cap < c.pressFloor: return "scrap"
  if not c.modeAllows(m.mode, true): return "mode"
  if m.cooldown > 0: return "cooldown"
  if m.integrity < c.pressFloor: return "integrity"
  if m.pink < 1 or m.blue < 1: return "stock"
  ""

proc stripBlockedWhy*(sim: Sim, seat: int): string =
  let
    cog = sim.cogs[seat]
    m = sim.machine
    c = sim.config
  if not c.isConsole(cog.x, cog.y): return "place"
  if m.cap < c.pressFloor: return "scrap"
  if not c.modeAllows(m.mode, false): return "mode"
  if m.cooldown > 0: return "cooldown"
  if m.integrity < c.stripFloor: return "integrity"
  if m.pink + m.blue < 1: return "stock"
  ""

proc fixBlockedWhy*(sim: Sim, seat: int): string =
  let
    cog = sim.cogs[seat]
    m = sim.machine
    c = sim.config
  if not c.isBay(cog.x, cog.y): return "place"
  if m.cooldown > 0: return "cooldown"
  if cog.carrying < 0: return "stock"
  if m.integrity >= m.cap: return "integrity"
  ""

proc pressLegal*(sim: Sim, seat: int): bool = sim.pressBlockedWhy(seat).len == 0
proc stripLegal*(sim: Sim, seat: int): bool = sim.stripBlockedWhy(seat).len == 0
proc fixLegal*(sim: Sim, seat: int): bool = sim.fixBlockedWhy(seat).len == 0

proc byRowThenCol(a, b: array[2, int]): int =
  ## (row, col) order — the order a surplus press spills onto the ring in.
  result = cmp(a[1], b[1])
  if result == 0:
    result = cmp(a[0], b[0])

proc overflowCells*(config: GameConfig): seq[array[2, int]] =
  ## The free floor cells orthogonally adjacent to the chute, in (row, col)
  ## order — the ring a surplus press spills onto before anything spoils.
  var cells: seq[array[2, int]]
  for chute in chuteCells():
    for dir in 0 .. 3:
      let
        nx = chute[0] + NeighbourDx[dir]
        ny = chute[1] + NeighbourDy[dir]
      if not config.walkable(nx, ny):
        continue
      if config.isChute(nx, ny):
        continue
      var seen = false
      for cell in cells:
        if cell[0] == nx and cell[1] == ny:
          seen = true
      if not seen:
        cells.add([nx, ny])
  cells.sort(byRowThenCol)
  cells

proc placeBananas*(sim: var Sim, count: int) =
  ## Fixed west->east chute order, each cell up to `cellBananaCap`, then the
  ## overflow ring in (row, col) order, then `spoil`.
  ##
  ## Fixed order rather than nearest-to-presser is deliberate: the presser
  ## stands twelve cells from the chute either way round, so it has NO
  ## positional advantage on its own output. That is the point of the press.
  var left = count
  if left <= 0:
    return
  for cell in chuteCells():
    while left > 0 and sim.bananasAt(cell[0], cell[1]) < sim.config.cellBananaCap:
      sim.bananas.add(Banana(x: cell[0], y: cell[1], age: 0))
      dec left
  if left > 0:
    for cell in overflowCells(sim.config):
      while left > 0 and sim.bananasAt(cell[0], cell[1]) < sim.config.cellBananaCap:
        sim.bananas.add(Banana(x: cell[0], y: cell[1], age: 0))
        dec left
  if left > 0:
    sim.machine.bananasSpoiled += left
    sim.emit("spoil", %*{"n": left})

proc lockMode(sim: var Sim, seat: int, wantCycle: bool) =
  ## Step 6.2. In the `either-or` variant the FIRST successful operation of the
  ## episode locks the factory's regime for everybody, irreversibly.
  if not sim.config.eitherOr or sim.machine.mode != mUnset:
    return
  sim.machine.mode = if wantCycle: mCycle else: mOverride
  let text = if wantCycle: "cycle" else: "override"
  sim.emit("lock", %*{"seat": seat, "mode": text})
  sim.beat("lock", %*{"seat": seat, "mode": text})

proc doPress*(sim: var Sim, seat: int) =
  ## Step 6.3. Sustainable. The output is PUBLIC — it lands on the chute and
  ## anybody may eat it, including a cog that did no work.
  let why = sim.pressBlockedWhy(seat)
  if why.len > 0:
    sim.emitBlocked(seat, "press", why)
    return
  ## The band is read BEFORE the wear is applied, so the yield is always the
  ## number the gauge was showing when the lever was pulled.
  sim.clearBlocked(seat)
  ## The band is read BEFORE the wear is applied.
  let
    band = sim.band()
    yielded = band.publicYield()
  sim.lockMode(seat, true)
  sim.machine.pink -= 1
  sim.machine.blue -= 1
  sim.consumed += 2
  sim.machine.integrity = max(0, sim.machine.integrity - sim.config.pressWear)
  sim.machine.cooldown = sim.config.pressCooldown
  sim.machine.presses += 1
  sim.cogs[seat].presses += 1
  sim.machine.bananasMade += yielded
  sim.emit("press", %*{
    "seat": seat, "band": $band, "yield": yielded,
    "integrity": sim.machine.integrity, "cap": sim.machine.cap,
    "pink": sim.machine.pink, "blue": sim.machine.blue
  })
  sim.placeBananas(yielded)

proc doStrip*(sim: var Sim, seat: int) =
  ## Step 6.4. Exploitative. The output is PRIVATE — credited straight to the
  ## acting seat, never touching the floor — and the cap loss is permanent.
  let why = sim.stripBlockedWhy(seat)
  if why.len > 0:
    sim.emitBlocked(seat, "strip", why)
    return
  sim.clearBlocked(seat)
  let
    band = sim.band()
    yielded = band.privateYield()
    capBefore = sim.machine.cap
  sim.lockMode(seat, false)
  ## Half the input of a press: one cube, the colour the machine has more of.
  if sim.machine.pink >= sim.machine.blue:
    sim.machine.pink -= 1
  else:
    sim.machine.blue -= 1
  sim.consumed += 1
  sim.machine.integrity = max(0, sim.machine.integrity - sim.config.stripWear)
  sim.machine.cap =
    max(sim.config.capMin, sim.machine.cap - sim.config.stripCapLoss)
  sim.machine.integrity = min(sim.machine.integrity, sim.machine.cap)
  sim.machine.cooldown = sim.config.stripCooldown
  sim.machine.strips += 1
  sim.cogs[seat].strips += 1
  sim.cogs[seat].banked += yielded
  sim.machine.bananasMade += yielded
  sim.emit("strip", %*{
    "seat": seat, "band": $band, "yield": yielded,
    "integrity": sim.machine.integrity, "cap": sim.machine.cap,
    "capLoss": capBefore - sim.machine.cap
  })
  sim.beat("strip", %*{"seat": seat})
  if capBefore >= sim.config.pressFloor and
      sim.machine.cap < sim.config.pressFloor:
    sim.machine.scrappedBy = seat
    sim.emit("scrap", %*{
      "seat": seat, "cap": sim.machine.cap, "strips": sim.machine.strips
    })
    sim.beat("scrap", %*{"seat": seat})

proc doFix*(sim: var Sim, seat: int) =
  ## Step 5. Pure cost, shared benefit: the public-goods contribution, priced
  ## in labour. Repair restores integrity and NEVER the cap.
  let why = sim.fixBlockedWhy(seat)
  if why.len > 0:
    sim.emitBlocked(seat, "fix", why)
    return
  sim.clearBlocked(seat)
  let
    cube = Cube(sim.cogs[seat].carrying)
    before = sim.machine.integrity
  sim.cogs[seat].carrying = -1
  sim.consumed += 1
  sim.machine.integrity =
    min(sim.machine.cap, sim.machine.integrity + sim.config.repairGain)
  sim.machine.cooldown = sim.config.repairCooldown
  sim.machine.repairs += 1
  sim.cogs[seat].repairs += 1
  sim.emit("fix", %*{
    "seat": seat, "cube": cubeText(cube),
    "gain": sim.machine.integrity - before,
    "integrity": sim.machine.integrity, "cap": sim.machine.cap
  })
