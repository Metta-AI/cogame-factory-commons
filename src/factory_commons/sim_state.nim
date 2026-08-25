## Logging, the determinism hash, event emission and spawn placement.
##
## Forked from `coworld-ctf/src/ctf/sim_state.nim`. Nothing here reads the
## floor or the machine rules, so it sits below both in the import graph and
## `machine.nim` can emit through it.

import std/[json, strutils]

import ./sim_types

proc removeAt*[T](items: var seq[T], index: int) =
  ## Order-preserving removal. Spelled out rather than `system.delete` so the
  ## semantics are the same on every Nim in the pinned range.
  if index < 0 or index >= items.len:
    return
  for i in index ..< items.len - 1:
    items[i] = items[i + 1]
  items.setLen(items.len - 1)

proc log*(message: string) =
  ## One line, one prefix, so a hosted log is greppable.
  echo "factory-commons: ", message

proc emitBlocked*(sim: var Sim, seat: int, action, why: string) =
  ## An illegal `press` / `strip` / `fix` degrades to `wait` and is recorded so
  ## a policy's mistakes are auditable instead of invisible.
  ##
  ## Consecutive IDENTICAL rows for one seat collapse to the first: a cog
  ## parked at the console through a twelve-tick cooldown produces one row, not
  ## twelve. The moment the reason changes (or the seat does something else)
  ## the next row is written, so nothing distinct is ever dropped.
  let signature = action & ":" & why
  if seat >= 0 and seat < sim.lastBlocked.len and
      sim.lastBlocked[seat] == signature:
    return
  if seat >= 0 and seat < sim.lastBlocked.len:
    sim.lastBlocked[seat] = signature
  var row = newJObject()
  row["t"] = %sim.tick
  row["k"] = %"blocked"
  row["seat"] = %seat
  row["action"] = %action
  row["why"] = %why
  sim.events.add(row)

proc clearBlocked*(sim: var Sim, seat: int) =
  ## Called whenever a seat does something legal, so the next illegal attempt
  ## is recorded even if it repeats an earlier reason.
  if seat >= 0 and seat < sim.lastBlocked.len:
    sim.lastBlocked[seat] = ""

proc boundaryTick*(sim: Sim): int =
  ## The tick a shift-close or a terminal event is recorded AT.
  ##
  ## `stepTick` records the tick it resolved and then advances the counter, so
  ## at a shift boundary `sim.tick` is already one PAST the last recorded frame.
  ## An event stamped there would sit outside `0 ..< frames.len` — which the
  ## replay's own validator rejects, and which would also make
  ## `eventsBetween` unable to ever deliver it to the feed.
  max(0, sim.tick - 1)

proc emitAt*(sim: var Sim, tick: int, kind: string, fields: JsonNode) =
  ## `emit`, at an explicit tick. Only the shift close and the terminal event
  ## need it; everything else fires during the tick it belongs to.
  var row = newJObject()
  row["t"] = %tick
  row["k"] = %kind
  if not fields.isNil and fields.kind == JObject:
    for key, value in fields:
      row[key] = value
  sim.events.add(row)

proc beatAt*(sim: var Sim, tick: int, kind: string, fields: JsonNode) =
  doAssert kind in BeatKinds, "unknown beat kind: " & kind
  var row = newJObject()
  row["t"] = %tick
  row["k"] = %kind
  if not fields.isNil and fields.kind == JObject:
    for key, value in fields:
      row[key] = value
  sim.beats.add(row)

proc emit*(sim: var Sim, kind: string, fields: JsonNode) =
  ## Appends one event row. `t` and `k` are always present and always first,
  ## so live emission and a re-read of the replay are byte-identical (the rule
  ## paintbot's `events.nim` states and this module keeps).
  var row = newJObject()
  row["t"] = %sim.tick
  row["k"] = %kind
  if not fields.isNil and fields.kind == JObject:
    for key, value in fields:
      row[key] = value
  sim.events.add(row)

proc beat*(sim: var Sim, kind: string, fields: JsonNode) =
  ## Appends one scrubber beat. Only the five `BeatKinds` may appear; the
  ## viewer has CSS for exactly those.
  doAssert kind in BeatKinds, "unknown beat kind: " & kind
  var row = newJObject()
  row["t"] = %sim.tick
  row["k"] = %kind
  if not fields.isNil and fields.kind == JObject:
    for key, value in fields:
      row[key] = value
  sim.beats.add(row)

proc score*(sim: Sim, seat: int): int =
  sim.cogs[seat].eaten + sim.cogs[seat].banked

proc bananasAt*(sim: Sim, x, y: int): int =
  for banana in sim.bananas:
    if banana.x == x and banana.y == y:
      inc result

proc cubeIndexAt*(sim: Sim, x, y: int): int =
  ## Index into `sim.cubes` of the loose cube on this cell, or -1.
  for i, cube in sim.cubes:
    if cube.x == x and cube.y == y:
      return i
  -1

proc cogAt*(sim: Sim, x, y: int): int =
  ## Slot of the cog standing on this cell, or -1.
  for i, cog in sim.cogs:
    if cog.x == x and cog.y == y:
      return i
  -1

proc captureFrame*(sim: var Sim) =
  ## Appends this tick's state frame and its integrity/cap series row. Factory
  ## Commons records STATE, not inputs, so playback is an array index and
  ## there is no native/wasm divergence to chase.
  var frame = Frame(t: sim.tick)
  for seat, cog in sim.cogs:
    frame.c.add(cog.x)
    frame.c.add(cog.y)
    frame.c.add(cog.carrying)
    frame.c.add(cog.eaten + cog.banked)
  for cube in sim.cubes:
    frame.u.add(cube.x)
    frame.u.add(cube.y)
    frame.u.add(ord(cube.cube))
  for banana in sim.bananas:
    frame.b.add(banana.x)
    frame.b.add(banana.y)
    frame.b.add(max(0, sim.config.bananaLifetime - banana.age))
  frame.m = [
    sim.machine.integrity, sim.machine.cap, sim.machine.pink,
    sim.machine.blue, sim.machine.cooldown, ord(sim.machine.mode)
  ]
  sim.frames.add(frame)
  sim.series.add([sim.tick, sim.machine.integrity, sim.machine.cap])

proc mix(hash: var uint64, value: int) =
  ## FNV-1a over one integer, little-endian, byte at a time.
  var raw = cast[uint64](int64(value))
  for _ in 0 ..< 8:
    hash = hash xor (raw and 0xFF'u64)
    hash = hash * 0x100000001B3'u64
    raw = raw shr 8

proc gameHash*(sim: Sim): string =
  ## A deterministic digest of everything the rules touch. `events`, `frames`
  ## and `series` are DELIBERATELY excluded: they are records of the state, not
  ## state, so a change to how a row is written can never move the hash.
  var hash = 0xCBF29CE484222325'u64
  hash.mix(sim.tick)
  hash.mix(sim.shift)
  hash.mix(sim.machine.integrity)
  hash.mix(sim.machine.cap)
  hash.mix(sim.machine.pink)
  hash.mix(sim.machine.blue)
  hash.mix(sim.machine.cooldown)
  hash.mix(ord(sim.machine.mode))
  hash.mix(sim.machine.presses)
  hash.mix(sim.machine.strips)
  hash.mix(sim.machine.repairs)
  hash.mix(sim.machine.bananasMade)
  hash.mix(sim.machine.bananasRotted)
  hash.mix(sim.machine.bananasSpoiled)
  hash.mix(sim.machine.scrappedBy)
  hash.mix(sim.dispensed)
  hash.mix(sim.consumed)
  for cog in sim.cogs:
    hash.mix(cog.x)
    hash.mix(cog.y)
    hash.mix(cog.carrying)
    hash.mix(cog.moveCd)
    hash.mix(cog.eaten)
    hash.mix(cog.banked)
    hash.mix(cog.presses)
    hash.mix(cog.strips)
    hash.mix(cog.repairs)
    hash.mix(cog.misfeeds)
  for cube in sim.cubes:
    hash.mix(cube.x)
    hash.mix(cube.y)
    hash.mix(ord(cube.cube))
  for banana in sim.bananas:
    hash.mix(banana.x)
    hash.mix(banana.y)
    hash.mix(banana.age)
  result = toHex(hash)

proc placeSpawns*(sim: var Sim) =
  ## Seats every cog on its authored spawn cell. Aliases are fixed to slots
  ## and never rotate, so the spawn table is a constant and there is no
  ## placement search to get wrong.
  sim.cogs = @[]
  for seat in 0 ..< sim.config.numAgents:
    sim.cogs.add(Cog(
      x: SpawnCells[seat][0],
      y: SpawnCells[seat][1],
      carrying: -1,
      moveCd: 0,
      order: initOrder()
    ))

proc initSim*(config: GameConfig): Sim =
  result.config = config
  result.tick = 0
  result.shift = 0
  result.machine = Machine(
    integrity: 100,
    cap: 100,
    pink: 0,
    blue: 0,
    cooldown: 0,
    mode: mUnset,
    scrappedBy: -1
  )
  result.reason = ""
  result.ending = ""
  result.connected = newSeq[bool](config.numAgents)
  result.lastBlocked = newSeq[string](config.numAgents)
  result.placeSpawns()
  ## No frame is captured here: `stepTick` records the tick it just resolved,
  ## so `frames.len` equals the number of ticks PLAYED and frame `i` is the
  ## board after tick `i`. A pre-roll frame would make every later index off
  ## by one for the viewer's seek-is-an-array-index contract.
