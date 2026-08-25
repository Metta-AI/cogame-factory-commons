## The gameplay core: the ten numbered tick steps, the shift boundary, the end
## conditions, and `results.json`.
##
## Forked from `coworld-ctf/src/ctf/sim.nim`, which also imports and
## RE-EXPORTS every sibling module — so `import factory_commons/sim` still sees
## everything, exactly as `import ctf/sim` does.

import std/[json, strutils]

import ./sim_types, ./sim_config, ./sim_state, ./floor, ./machine, ./kernel

export sim_types, sim_config, sim_state, floor, machine, kernel

# The ten numbered steps are each exported so a test can drive ONE step at a
# time against a hand-built state — the only way to pin a cross-cog race (two
# cogs into one cell, two grasps of one cube) without hunting for a seed that
# happens to produce it.

proc dispensersEmit*(sim: var Sim) =
  ## Step 1. A dispenser whose mouth cell is occupied STALLS; matter is never
  ## destroyed by a stall.
  if sim.config.dispensePeriod <= 0:
    return
  if sim.tick mod sim.config.dispensePeriod != 0:
    return
  for cube in [cPink, cBlue]:
    let
      x = BeltX0
      y = beltRow(cube)
    if sim.cubeIndexAt(x, y) >= 0:
      continue
    if sim.cogAt(x, y) >= 0:
      continue
    sim.cubes.add(LooseCube(x: x, y: y, cube: cube))
    sim.dispensed += 1

proc beltsAdvance*(sim: var Sim) =
  ## Step 2. Scan each belt from the TAIL westwards, so a train moves as a
  ## train. The tail cube never moves — it waits to be grasped and the train
  ## backs up behind it.
  if sim.config.beltPeriod <= 0:
    return
  if sim.tick mod sim.config.beltPeriod != 0:
    return
  let tail = sim.config.beltTailX()
  for cube in [cPink, cBlue]:
    let row = beltRow(cube)
    for x in countdown(tail - 1, BeltX0):
      let index = sim.cubeIndexAt(x, row)
      if index < 0:
        continue
      if sim.cubes[index].cube != cube:
        continue
      if sim.config.beltAt(x + 1, row) != ord(cube):
        continue
      if sim.cubeIndexAt(x + 1, row) >= 0:
        continue
      sim.cubes[index].x = x + 1

proc bounceCube(sim: var Sim, seat: int, cube: Cube, hopper: string, why: string) =
  ## A rejected drop bounces to the first free orthogonal neighbour in
  ## N, E, S, W order. With no free neighbour the drop degrades to `wait` and
  ## the cube stays in hand — cubes are never destroyed.
  let cog = sim.cogs[seat]
  for dir in 0 .. 3:
    let
      nx = cog.x + NeighbourDx[dir]
      ny = cog.y + NeighbourDy[dir]
    if not sim.config.walkable(nx, ny):
      continue
    if sim.cubeIndexAt(nx, ny) >= 0:
      continue
    sim.cubes.add(LooseCube(x: nx, y: ny, cube: cube))
    sim.cogs[seat].carrying = -1
    sim.cogs[seat].misfeeds += 1
    sim.emit("misfeed", %*{
      "seat": seat, "cube": cubeText(cube), "hopper": hopper, "why": why,
      "x": nx, "y": ny
    })
    return

proc resolveGraspDrop*(sim: var Sim, actions: openArray[Action]) =
  ## Step 4, ascending slot order. A `grasp` of a cube a lower slot already
  ## took this tick fails (the cube is gone), which is exactly what the
  ## re-read of `sim.cubes` gives.
  for seat in 0 ..< sim.cogs.len:
    let cog = sim.cogs[seat]
    case actions[seat]
    of aGrasp:
      if cog.carrying >= 0:
        continue
      let index = sim.cubeIndexAt(cog.x, cog.y)
      if index < 0:
        continue
      let cube = sim.cubes[index].cube
      sim.cubes.removeAt(index)
      sim.cogs[seat].carrying = ord(cube)
      sim.emit("grasp", %*{
        "seat": seat, "cube": cubeText(cube), "x": cog.x, "y": cog.y
      })
    of aDrop:
      if cog.carrying < 0:
        continue
      let cube = Cube(cog.carrying)
      let hopper = sim.config.hopperAt(cog.x, cog.y)
      if hopper >= 0:
        if hopper != ord(cube):
          sim.bounceCube(seat, cube, cubeText(Cube(hopper)) & "Hopper", "colour")
          continue
        let stock =
          if cube == cPink: sim.machine.pink else: sim.machine.blue
        if stock >= sim.config.hopperCap:
          sim.bounceCube(seat, cube, cubeText(Cube(hopper)) & "Hopper", "full")
          continue
        if cube == cPink: sim.machine.pink += 1 else: sim.machine.blue += 1
        sim.cogs[seat].carrying = -1
        sim.emit("drop", %*{
          "seat": seat, "cube": cubeText(cube), "x": cog.x, "y": cog.y,
          "into": cubeText(cube) & "Hopper"
        })
        continue
      if sim.cubeIndexAt(cog.x, cog.y) >= 0:
        continue
      sim.cubes.add(LooseCube(x: cog.x, y: cog.y, cube: cube))
      sim.cogs[seat].carrying = -1
      sim.emit("drop", %*{
        "seat": seat, "cube": cubeText(cube), "x": cog.x, "y": cog.y,
        "into": "floor"
      })
    else:
      discard

proc resolveMoves*(sim: var Sim, actions: openArray[Action]) =
  ## Step 7, ascending slot order, against the LIVE board: a move into a cell
  ## a lower slot has already entered this tick fails.
  for seat in 0 ..< sim.cogs.len:
    var dx = 0
    var dy = 0
    case actions[seat]
    of aMoveN: dy = -1
    of aMoveS: dy = 1
    of aMoveE: dx = 1
    of aMoveW: dx = -1
    else: continue
    if sim.cogs[seat].moveCd > 0:
      continue
    let
      nx = sim.cogs[seat].x + dx
      ny = sim.cogs[seat].y + dy
    if not sim.config.walkable(nx, ny):
      continue
    if sim.cogAt(nx, ny) >= 0:
      continue
    sim.cogs[seat].x = nx
    sim.cogs[seat].y = ny
    sim.cogs[seat].moveCd = sim.config.moveCooldown

proc autoEat*(sim: var Sim) =
  ## Step 8. Eating is not an action: any cog standing on a chute cell eats
  ## EVERY banana on that cell, whether or not it moved. That is what makes
  ## camping the chute a strategy and free-riding a temptation.
  for seat in 0 ..< sim.cogs.len:
    let cog = sim.cogs[seat]
    if not sim.config.isChute(cog.x, cog.y):
      continue
    var eaten = 0
    var i = 0
    while i < sim.bananas.len:
      if sim.bananas[i].x == cog.x and sim.bananas[i].y == cog.y:
        sim.bananas.removeAt(i)
        inc eaten
      else:
        inc i
    if eaten > 0:
      sim.cogs[seat].eaten += eaten
      sim.emit("eat", %*{"seat": seat, "n": eaten, "x": cog.x, "y": cog.y})

proc bananaRot*(sim: var Sim) =
  ## Step 9. A rotted banana helps nobody, which is what puts a clock on the
  ## chute and makes harvesting part of operating.
  var i = 0
  while i < sim.bananas.len:
    sim.bananas[i].age += 1
    if sim.bananas[i].age >= sim.config.bananaLifetime:
      let banana = sim.bananas[i]
      sim.bananas.removeAt(i)
      sim.machine.bananasRotted += 1
      sim.emit("rot", %*{"x": banana.x, "y": banana.y})
    else:
      inc i

proc stepTick*(sim: var Sim) =
  ## Resolves the tick numbered `sim.tick` through the ten numbered steps, in
  ## order, then records it and advances the counter. Within a step, seats
  ## resolve in ASCENDING SLOT ORDER; belts and dispensers resolve pink then
  ## blue.
  sim.dispensersEmit()                                            # 1
  sim.beltsAdvance()                                              # 2

  var actions = newSeq[Action](sim.cogs.len)                       # 3
  for seat in 0 ..< sim.cogs.len:
    actions[seat] = sim.kernelAction(seat)
  for seat in 0 ..< sim.cogs.len:
    if actions[seat] notin {aPress, aStrip, aFix}:
      sim.clearBlocked(seat)

  sim.resolveGraspDrop(actions)                                   # 4

  for seat in 0 ..< sim.cogs.len:                                  # 5
    if actions[seat] == aFix:
      sim.doFix(seat)

  for seat in 0 ..< sim.cogs.len:                                  # 6
    case actions[seat]
    of aPress: sim.doPress(seat)
    of aStrip: sim.doStrip(seat)
    else: discard

  sim.resolveMoves(actions)                                       # 7
  sim.autoEat()                                                   # 8
  sim.bananaRot()                                                 # 9

  # 10 — rust, cooldowns, record.
  if sim.config.rustPeriod > 0 and sim.tick > 0 and
      sim.tick mod sim.config.rustPeriod == 0:
    sim.machine.integrity = max(0, sim.machine.integrity - 1)
  if sim.machine.cooldown > 0:
    sim.machine.cooldown -= 1
  for seat in 0 ..< sim.cogs.len:
    if sim.cogs[seat].moveCd > 0:
      sim.cogs[seat].moveCd -= 1
  sim.captureFrame()
  sim.tick += 1

proc ticksPlayed*(sim: Sim): int = sim.tick

proc floorBananas*(sim: Sim): int = sim.bananas.len

proc closeShift*(sim: var Sim) =
  ## Shift accounting plus the `shift` event and beat. Called once the tick
  ## counter crosses a multiple of `ticksPerShift`.
  sim.shift += 1
  var record = ShiftRecord(
    shift: sim.shift,
    integrity: sim.machine.integrity,
    cap: sim.machine.cap,
    presses: sim.machine.presses,
    strips: sim.machine.strips,
    repairs: sim.machine.repairs,
    made: sim.machine.bananasMade,
    rotted: sim.machine.bananasRotted
  )
  var eaten = newJArray()
  var banked = newJArray()
  for seat in 0 ..< sim.cogs.len:
    record.eaten[seat] = sim.cogs[seat].eaten
    record.banked[seat] = sim.cogs[seat].banked
    eaten.add(%sim.cogs[seat].eaten)
    banked.add(%sim.cogs[seat].banked)
  sim.history.add(record)
  sim.emit("shift", %*{
    "shift": sim.shift,
    "integrity": sim.machine.integrity,
    "cap": sim.machine.cap,
    "band": $sim.band(),
    "pink": sim.machine.pink,
    "blue": sim.machine.blue,
    "made": sim.machine.bananasMade,
    "eaten": eaten,
    "banked": banked,
    "strips": sim.machine.strips,
    "repairs": sim.machine.repairs
  })
  sim.beat("shift", %*{"n": sim.shift})

proc finish(sim: var Sim, reason, ending: string) =
  if sim.done:
    return
  sim.done = true
  sim.reason = reason
  sim.ending = ending
  var scores = newJArray()
  for seat in 0 ..< sim.cogs.len:
    scores.add(%sim.score(seat))
  sim.emit("end", %*{"reason": reason, "ending": ending, "scores": scores})
  sim.beat("gameover", %*{"ending": ending})

proc checkEnd*(sim: var Sim, deadlineReached: bool) =
  ## The episode ends at the FIRST of these, all checked at a shift boundary.
  ## `complete`, `deadline` and `forfeit` are the only legal reasons — a
  ## ruined factory is a COMPLETED game of Factory Commons, not an error.
  if sim.done:
    return
  if sim.shift >= sim.config.shifts:
    sim.finish("complete", "shift_limit")
    return
  if sim.machine.cap < sim.config.pressFloor and sim.bananas.len == 0:
    sim.finish("complete", "factory_ruined")
    return
  if deadlineReached:
    sim.finish("deadline", "deadline")

proc endEarly*(sim: var Sim) =
  ## The play deadline passed between shifts: score what was played and settle.
  ## The platform keeps NOTHING from an episode that outruns its timeout, so
  ## giving up shifts is always better than giving up the whole result.
  sim.finish("deadline", "deadline")

proc forfeit*(sim: var Sim) =
  ## No seat connected inside `playerConnectTimeoutSeconds`. Results AND the
  ## replay are still written; every score is zero.
  sim.finish("forfeit", "forfeit")

proc playShift*(sim: var Sim) =
  ## One turn: `ticksPerShift` ticks, then the shift close.
  if sim.done:
    return
  for _ in 0 ..< sim.config.ticksPerShift:
    sim.stepTick()
  sim.closeShift()

proc applyOrder*(sim: var Sim, seat: int, order: Order) =
  ## Installs one seat's standing order for the shift about to be played and
  ## records the `order` event. Raises on a job or cube outside its enum, so
  ## the LLM layer can validate by attempting the apply on a copy.
  if seat < 0 or seat >= sim.cogs.len:
    raise newException(FactoryError, "order for unknown seat " & $seat)
  sim.cogs[seat].order = order
  sim.cogs[seat].said = order.say
  sim.cogs[seat].notes = order.notes
  if order.source == osFallback:
    sim.cogs[seat].fallbacks += 1
  sim.emit("order", %*{
    "seat": seat,
    "shift": sim.shift + 1,
    "job": $order.job,
    "cube": $order.cube,
    "source": $order.source,
    "say": order.say,
    "notes": order.notes,
    "latencyMs": order.latencyMs
  })

proc resultsJson*(sim: Sim, policyNames: seq[string]): JsonNode =
  ## `names` are POLICY names (platform side); the aliases go to the players
  ## and into the replay's `names[]`. Every slot array has length numAgents
  ## exactly.
  var
    names = newJArray()
    aliases = newJArray()
    scores = newJArray()
    win = newJArray()
    eaten = newJArray()
    banked = newJArray()
    presses = newJArray()
    strips = newJArray()
    repairs = newJArray()
    misfeeds = newJArray()
    fallbacks = newJArray()
  var best = 0
  for seat in 0 ..< sim.cogs.len:
    best = max(best, sim.score(seat))
  for seat in 0 ..< sim.cogs.len:
    names.add(%(if seat < policyNames.len and policyNames[seat].len > 0:
      policyNames[seat] else: Aliases[seat]))
    aliases.add(%Aliases[seat])
    scores.add(%sim.score(seat))
    win.add(%(sim.score(seat) == best))
    eaten.add(%sim.cogs[seat].eaten)
    banked.add(%sim.cogs[seat].banked)
    presses.add(%sim.cogs[seat].presses)
    strips.add(%sim.cogs[seat].strips)
    repairs.add(%sim.cogs[seat].repairs)
    misfeeds.add(%sim.cogs[seat].misfeeds)
    fallbacks.add(%sim.cogs[seat].fallbacks)
  let modeFinal =
    case sim.machine.mode
    of mUnset: "unset"
    of mCycle: "cycle"
    of mOverride: "override"
  let reasonText = if sim.reason.len > 0: sim.reason else: "complete"
  let endingText = if sim.ending.len > 0: sim.ending else: "shift_limit"
  %*{
    "names": names,
    "aliases": aliases,
    "scores": scores,
    "win": win,
    "eaten": eaten,
    "banked": banked,
    "presses": presses,
    "strips": strips,
    "repairs": repairs,
    "misfeeds": misfeeds,
    "fallbacks": fallbacks,
    "bananas_made": sim.machine.bananasMade,
    "bananas_rotted": sim.machine.bananasRotted,
    "bananas_spoiled": sim.machine.bananasSpoiled,
    "integrity_final": sim.machine.integrity,
    "cap_final": sim.machine.cap,
    "band_final": $sim.band(),
    "mode_final": modeFinal,
    "scrapped_by": sim.machine.scrappedBy,
    "shifts": sim.shift,
    "reason": reasonText,
    "ending": endingText
  }

proc cubesOnFloor*(sim: Sim): int = sim.cubes.len

proc cubesInHands*(sim: Sim): int =
  for cog in sim.cogs:
    if cog.carrying >= 0:
      inc result

proc cubesConserved*(sim: Sim): bool =
  ## Dispensed = on belts/floor + in hands + in stock + consumed. Cubes are
  ## never destroyed; the cost of a mistake is wasted seconds, not lost matter.
  sim.dispensed ==
    sim.cubes.len + sim.cubesInHands() + sim.machine.pink + sim.machine.blue +
    sim.consumed

proc bandWord*(sim: Sim): string = $sim.band()

proc modeText*(mode: Mode): string =
  case mode
  of mUnset: "unset"
  of mCycle: "cycle"
  of mOverride: "override"

proc summary*(sim: Sim): string =
  "tick " & $sim.tick & " shift " & $sim.shift & "/" & $sim.config.shifts &
    " integrity " & $sim.machine.integrity & " cap " & $sim.machine.cap &
    " band " & sim.bandWord() & " made " & $sim.machine.bananasMade &
    " presses " & $sim.machine.presses & " strips " & $sim.machine.strips &
    " repairs " & $sim.machine.repairs
