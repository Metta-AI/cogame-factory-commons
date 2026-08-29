## The replay file (`factory_commons.replay.v1`): writer and reader.
##
## Rewritten rather than forked — paintbot's `replays.nim` / `replay_runtime.nim`
## record INPUTS and re-simulate on playback. Factory Commons records STATE, so
## playback never re-simulates, a seek is an array index, and there is no
## native/wasm divergence to chase (which is also why `#mmwarn` and
## `ctf_mismatch_tick` are dropped).
##
## Strict UTF-8 JSON, one document, self-sufficient by construction: aliases,
## policy names, body colours, the complete floor geometry, every rule constant
## including both yield tables, the seed, per-tick state, the integrity/cap
## series, the beat timeline, every event and the final results all live in
## these bytes. The viewer contacts no server except S3 for the file.

import std/json

import ./sim_types, ./sim_config, ./floor, ./machine, ./broadcast

export broadcast

type
  ReplayDoc* = object
    protocol*: string
    game*: string
    gameVersion*: string
    seed*: int
    names*: seq[string]
    policyNames*: seq[string]
    colors*: seq[string]
    config*: GameConfig
    variant*: string
    frames*: seq[Frame]
    series*: seq[array[3, int]]
    beats*: seq[JsonNode]
    events*: seq[JsonNode]
    results*: JsonNode

proc configJson*(config: GameConfig): JsonNode =
  ## Every rule constant the viewer, an analyst or a future reader could want.
  ## Nothing is derived on read — the bytes are the contract.
  var
    console = newJArray()
    chute = newJArray()
    bay = newJArray()
    spawns = newJArray()
    publicY = newJArray()
    privateY = newJArray()
  for cell in consoleCells(): console.add(%*[cell[0], cell[1]])
  for cell in chuteCells(): chute.add(%*[cell[0], cell[1]])
  for cell in bayCells(): bay.add(%*[cell[0], cell[1]])
  for seat in 0 ..< SeatCount:
    spawns.add(%*[SpawnCells[seat][0], SpawnCells[seat][1]])
  for value in PublicYield: publicY.add(%value)
  for value in PrivateYield: privateY.add(%value)
  %*{
    "variant": config.variantName(),
    "cols": Cols, "rows": Rows, "cell": CellPx,
    "shifts": config.shifts, "ticksPerShift": config.ticksPerShift,
    "eitherOr": config.eitherOr,
    "machine": [MachineX0, MachineY0, MachineX1, MachineY1],
    "console": console, "chute": chute, "bay": bay,
    "hoppers": {
      "pink": [PinkHopperX, PinkHopperY],
      "blue": [BlueHopperX, BlueHopperY]
    },
    "belts": {
      "pink": {"row": PinkBeltRow, "cols": [BeltX0, config.beltTailX()]},
      "blue": {"row": BlueBeltRow, "cols": [BeltX0, config.beltTailX()]}
    },
    "walls": "border ring",
    "spawns": spawns,
    "integrity0": 100, "cap0": 100, "capMin": config.capMin,
    "pressFloor": config.pressFloor, "stripFloor": config.stripFloor,
    "pressWear": config.pressWear, "stripWear": config.stripWear,
    "stripCapLoss": config.stripCapLoss, "repairGain": config.repairGain,
    "rustPeriod": config.rustPeriod,
    "pressCooldown": config.pressCooldown,
    "stripCooldown": config.stripCooldown,
    "repairCooldown": config.repairCooldown,
    "publicYield": publicY, "privateYield": privateY,
    "dispensePeriod": config.dispensePeriod, "beltPeriod": config.beltPeriod,
    "beltLen": config.beltLen, "hopperCap": config.hopperCap,
    "bananaLifetime": config.bananaLifetime,
    "cellBananaCap": config.cellBananaCap,
    "moveCooldown": config.moveCooldown, "carryCap": config.carryCap,
    "eatTrigger": config.eatTrigger,
    "numAgents": config.numAgents
  }

proc frameJson*(frame: Frame): JsonNode =
  var c = newJArray()
  var u = newJArray()
  var b = newJArray()
  var m = newJArray()
  for value in frame.c: c.add(%value)
  for value in frame.u: u.add(%value)
  for value in frame.b: b.add(%value)
  for value in frame.m: m.add(%value)
  %*{"t": frame.t, "c": c, "u": u, "b": b, "m": m}

proc buildReplay*(
  sim: Sim,
  policyNames: seq[string],
  results: JsonNode
): string =
  ## The whole episode as one strict-UTF-8 JSON document.
  var
    names = newJArray()
    pols = newJArray()
    colors = newJArray()
    frames = newJArray()
    series = newJArray()
    beats = newJArray()
    events = newJArray()
  for seat in 0 ..< sim.cogs.len:
    names.add(%Aliases[seat])
    pols.add(%(if seat < policyNames.len and policyNames[seat].len > 0:
      policyNames[seat] else: Aliases[seat]))
    colors.add(%SeatColors[seat])
  for frame in sim.frames:
    frames.add(frame.frameJson())
  for row in sim.series:
    series.add(%*[row[0], row[1], row[2]])
  for row in sim.beats:
    beats.add(row)
  for row in sim.events:
    events.add(row)
  $ %*{
    "protocol": ProtocolReplay,
    "game": GameName,
    "gameVersion": GameVersion,
    "seed": sim.config.seed,
    "names": names,
    "policyNames": pols,
    "colors": colors,
    "config": sim.config.configJson(),
    "frames": frames,
    "series": {"machine": series},
    "beats": beats,
    "events": events,
    "results": results
  }

proc intAt(node: JsonNode, index: int): int =
  if node.isNil or node.kind != JArray or index >= node.len:
    return 0
  node[index].getInt()

proc parseFrame*(node: JsonNode): Frame =
  result.t = node{"t"}.getInt()
  let c = node{"c"}
  if not c.isNil and c.kind == JArray:
    for item in c: result.c.add(item.getInt())
  let u = node{"u"}
  if not u.isNil and u.kind == JArray:
    for item in u: result.u.add(item.getInt())
  let b = node{"b"}
  if not b.isNil and b.kind == JArray:
    for item in b: result.b.add(item.getInt())
  let m = node{"m"}
  for i in 0 .. 5:
    result.m[i] = m.intAt(i)

proc parseReplay*(data: string): ReplayDoc =
  ## Parses the recorded bytes into the playback document. Raises with a
  ## readable message on anything malformed — the wasm entry turns that into
  ## `data-replay-error` rather than a blank theater.
  var node: JsonNode
  try:
    node = parseJson(data)
  except CatchableError as error:
    raise newException(FactoryError, "replay is not JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(FactoryError, "replay is not a JSON object")
  result.protocol = node{"protocol"}.getStr()
  if result.protocol != ProtocolReplay:
    raise newException(FactoryError,
      "replay protocol is " & result.protocol & ", expected " & ProtocolReplay)
  result.game = node{"game"}.getStr()
  result.gameVersion = node{"gameVersion"}.getStr()
  result.seed = node{"seed"}.getInt()
  for item in node{"names"}.getElems(): result.names.add(item.getStr())
  for item in node{"policyNames"}.getElems():
    result.policyNames.add(item.getStr())
  for item in node{"colors"}.getElems(): result.colors.add(item.getStr())

  result.config = defaultGameConfig()
  let configNode = node{"config"}
  if not configNode.isNil and configNode.kind == JObject:
    ## The replay pins the episode's constants; never re-derive them.
    result.variant = configNode{"variant"}.getStr("factory-commons")
    var narrowed = newJObject()
    for key in ["shifts", "ticksPerShift", "eitherOr", "moveCooldown",
                "carryCap", "dispensePeriod", "beltPeriod", "beltLen",
                "hopperCap", "pressFloor", "stripFloor", "pressWear",
                "stripWear", "stripCapLoss", "repairGain", "capMin",
                "rustPeriod", "pressCooldown", "stripCooldown",
                "repairCooldown", "bananaLifetime", "cellBananaCap",
                "eatTrigger"]:
      if configNode.hasKey(key):
        narrowed[key] = configNode[key]
    if configNode.hasKey("numAgents"):
      narrowed["num_agents"] = configNode["numAgents"]
    result.config.update($narrowed)
  if result.variant.len == 0:
    result.variant = result.config.variantName()

  for item in node{"frames"}.getElems():
    result.frames.add(parseFrame(item))
  if result.frames.len == 0:
    raise newException(FactoryError, "replay carries no frames")
  let seriesNode = node{"series"}
  if not seriesNode.isNil and seriesNode.kind == JObject:
    for row in seriesNode{"machine"}.getElems():
      result.series.add([row.intAt(0), row.intAt(1), row.intAt(2)])
  for item in node{"beats"}.getElems(): result.beats.add(item)
  for item in node{"events"}.getElems(): result.events.add(item)
  result.results = node{"results"}
  if result.results.isNil:
    result.results = newJObject()

proc maxTick*(doc: ReplayDoc): int =
  if doc.frames.len == 0: 0 else: doc.frames[^1].t

proc frameIndexFor*(doc: ReplayDoc, tick: int): int =
  ## Seek is an array index: frame `i` is the board after tick `i`.
  if doc.frames.len == 0:
    return 0
  max(0, min(doc.frames.len - 1, tick))

proc eventsBetween*(doc: ReplayDoc, fromTick, toTick: int): JsonNode =
  ## The events in `(fromTick, toTick]`, in recorded order — what the chrome
  ## frame carries so the feed sees each beat exactly once during playback.
  result = newJArray()
  for row in doc.events:
    let tick = row{"t"}.getInt(-1)
    if tick > fromTick and tick <= toTick:
      result.add(row)

proc replaySizeOk*(data: string): bool =
  ## 900 frames x ~110 integers is ~0.45 MB, plus events and the series.
  ## tests/test_replay.nim asserts the real file against this bound.
  data.len < 8 * 1024 * 1024

# ---- playback model -------------------------------------------------------
#
# One `HudModel` per recorded frame, so the replay viewer and the live
# spectator view are fed by the SAME chrome builder and cannot drift. The
# per-seat and per-machine running totals are not in the frame encoding (they
# are derivable, and a replay that stored them could disagree with its own
# events), so they are folded from the event rows up to this tick — under 400
# rows per episode, so a linear fold per frame is free.

proc hudFromReplay*(doc: ReplayDoc, index: int): HudModel =
  let
    frame = doc.frames[max(0, min(doc.frames.len - 1, index))]
    seats = frame.c.len div 4
    config = doc.config
  result.tick = frame.t
  result.maxTick = doc.maxTick()
  result.startTick = 0
  result.shifts = config.shifts
  result.ticksPerShift = config.ticksPerShift
  result.shift = (if config.ticksPerShift > 0:
    (frame.t + 1) div config.ticksPerShift else: 0)
  result.integrity = frame.m[0]
  result.cap = frame.m[1]
  result.pink = frame.m[2]
  result.blue = frame.m[3]
  result.cooldown = frame.m[4]
  result.mode = (case frame.m[5]
    of 1: "cycle"
    of 2: "override"
    else: "unset")
  result.band = $config.bandOf(result.integrity, result.cap)
  result.variant = doc.variant
  result.eitherOr = config.eitherOr
  result.beltLen = config.beltLen
  result.showLabels = true
  let band = config.bandOf(result.integrity, result.cap)
  result.pressYield = band.publicYield()
  result.stripYield = band.privateYield()
  result.pressLegal = result.cap >= config.pressFloor and
    result.integrity >= config.pressFloor and
    config.modeAllows(Mode(frame.m[5]), true)
  result.stripLegal = result.cap >= config.pressFloor and
    result.integrity >= config.stripFloor and
    config.modeAllows(Mode(frame.m[5]), false)
  result.scrappedBy = -1
  result.lastPressTick = -1
  result.lastStripTick = -1

  var i = 0
  while i + 2 < frame.u.len:
    result.cubes.add(LooseCube(
      x: frame.u[i], y: frame.u[i + 1], cube: Cube(frame.u[i + 2])))
    i += 3
  i = 0
  while i + 2 < frame.b.len:
    result.bananas.add(Banana(
      x: frame.b[i], y: frame.b[i + 1],
      age: max(0, config.bananaLifetime - frame.b[i + 2])))
    i += 3
  for banana in result.bananas:
    if config.isChute(banana.x, banana.y):
      inc result.onChute

  for seat in 0 ..< seats:
    result.seats.add(SeatHud(
      slot: seat,
      alias: (if seat < doc.names.len: doc.names[seat] else: Aliases[seat]),
      policy: (if seat < doc.policyNames.len: doc.policyNames[seat]
               else: Aliases[seat]),
      color: (if seat < doc.colors.len: doc.colors[seat] else: SeatColors[seat]),
      x: frame.c[seat * 4],
      y: frame.c[seat * 4 + 1],
      carrying: frame.c[seat * 4 + 2],
      score: frame.c[seat * 4 + 3],
      job: "operate",
      cube: "any",
      source: "scripted"
    ))

  for row in doc.events:
    let tick = row{"t"}.getInt(-1)
    if tick < 0 or tick > frame.t:
      continue
    let
      kind = row{"k"}.getStr()
      seat = row{"seat"}.getInt(-1)
    case kind
    of "press":
      inc result.presses
      result.bananasMade += row{"yield"}.getInt()
      result.lastPressTick = tick
      if seat >= 0 and seat < result.seats.len:
        inc result.seats[seat].presses
    of "strip":
      inc result.strips
      result.bananasMade += row{"yield"}.getInt()
      result.lastStripTick = tick
      if seat >= 0 and seat < result.seats.len:
        inc result.seats[seat].strips
        result.seats[seat].banked += row{"yield"}.getInt()
    of "fix":
      inc result.repairs
      if seat >= 0 and seat < result.seats.len:
        inc result.seats[seat].repairs
    of "misfeed":
      if seat >= 0 and seat < result.seats.len:
        inc result.seats[seat].misfeeds
    of "eat":
      if seat >= 0 and seat < result.seats.len:
        result.seats[seat].eaten += row{"n"}.getInt()
    of "rot":
      inc result.bananasRotted
    of "spoil":
      result.bananasSpoiled += row{"n"}.getInt()
    of "scrap":
      result.scrappedBy = seat
    of "order":
      if seat >= 0 and seat < result.seats.len:
        result.seats[seat].job = row{"job"}.getStr("operate")
        result.seats[seat].cube = row{"cube"}.getStr("any")
        result.seats[seat].source = row{"source"}.getStr("scripted")
        result.seats[seat].said = row{"say"}.getStr()
        result.seats[seat].fallbacks =
          result.seats[seat].fallbacks +
          (if row{"source"}.getStr() == "fallback": 1 else: 0)
    else:
      discard

  result.over = index >= doc.frames.len - 1
  if result.over:
    result.reason = doc.results{"reason"}.getStr("complete")
    result.ending = doc.results{"ending"}.getStr("shift_limit")
    let scrapped = doc.results{"scrapped_by"}
    if not scrapped.isNil and scrapped.kind == JInt:
      result.scrappedBy = scrapped.getInt()

proc beatsJson*(doc: ReplayDoc): JsonNode =
  result = newJArray()
  for row in doc.beats:
    result.add(row)

# ---------------------------------------------------------------- the speeds
# The playhead itself lives in `replay-viewer/factory_commons_replay.nim`
# (state playback is just an array index), but the speed vocabulary is here so
# the native tests can exercise it — the wasm entry only runs in a browser.

const ReplayHalfSpeedIndex* = -1
  ## `speedIndex` sentinel for the replay-only 1/2x playback (command '5'):
  ## one frame is spent every other presentation frame (halfPhase parity).

proc replaySpeed*(speedIndex: int): int =
  ## The integer playback multiplier (1 while at 1/2x — the fractional pace
  ## lives in replayStepBudget's frame parity).
  PlaybackSpeeds[clamp(speedIndex, 0, PlaybackSpeeds.high)]

proc replayDisplaySpeed*(speedIndex: int): float =
  ## The speed the chrome shows: 0.5 at the half-speed sentinel, else the
  ## integer multiplier.
  if speedIndex == ReplayHalfSpeedIndex: 0.5
  else: float(replaySpeed(speedIndex))

proc replayStepBudget*(speedIndex: int, halfPhase: bool): int =
  ## How many frames playback advances this presentation frame: the chosen
  ## speed, except at 1/2x a frame is spent only every other call (halfPhase
  ## parity).
  if speedIndex == ReplayHalfSpeedIndex:
    (if halfPhase: 1 else: 0)
  else:
    replaySpeed(speedIndex)

proc applySpeedCommand*(speedIndex: var int, command: char) =
  ## Applies one playback speed command. '5' selects the 1/2x replay speed
  ## (ReplayHalfSpeedIndex), and '-' floors there.
  case command
  of '+', '=':
    speedIndex = min(speedIndex + 1, PlaybackSpeeds.high)
  of '-', '_':
    speedIndex = max(speedIndex - 1, ReplayHalfSpeedIndex)
  of '1':
    speedIndex = 0
  of '2':
    speedIndex = 1
  of '3':
    speedIndex = 2
  of '4':
    speedIndex = 3
  of '5':
    speedIndex = ReplayHalfSpeedIndex
  of '8':
    speedIndex = 4
  of '6':
    speedIndex = 5
  else:
    discard
