## Claude-backed decision making for Factory Commons.
##
## Ported from `cogame-bullwhip/src/bullwhip/llm.nim` — the GAME-SIDE batched
## decision layer. Each seat's policy is just a prompt: the game composes the
## seat's view (the floor, the machine, the supply, the chute, the other cogs,
## its own notes) plus that seat's prompt and asks Claude what job it takes for
## the next shift.
##
## Decisions within a shift are SIMULTANEOUS by rule, so all three requests go
## out as ONE parallel batch (`curly.makeRequests`); invalid replies are retried
## once as a smaller batch with a hint, and anything still failing falls back to
## the scripted `steward` order. Deciding in the GAME container is what makes
## one parallel batch per turn possible, and is why the coworld secret must be
## on the game runnable (hive, 2026-08-23).
##
## Credentials, in order of preference:
##   Bedrock sidecar / bearer token   - hosted pods
##   ANTHROPIC_API_KEY                - the key itself
##   ANTHROPIC_API_KEY_URI            - a URI holding the key
## With none the client disables itself immediately and every seat plays
## `steward` — which is what keeps offline certification green and
## deterministic. That fallback is load-bearing, not a nicety.

import
  std/[json, os, strutils, unicode],
  bitworld/runtime,
  curly,
  ./sim, ./scripted

const
  AnthropicUrl = "https://api.anthropic.com/v1/messages"
  AnthropicVersion = "2023-06-01"
  BedrockAnthropicVersion = "bedrock-2023-05-31"

type
  ThrottledError* = object of FactoryError
    ## A 429 from the API. Distinct from every other transport failure because
    ## the design note answers it differently: the seat is retried in the NEXT
    ## shift's batch, not in this shift's retry batch.

  LlmTransport* = enum
    ltNone, ltBedrock, ltAnthropic

  TransportStub* = proc (batch: RequestBatch): ResponseBatch {.gcsafe.}
    ## TEST-ONLY seam. When set, `decideAll` answers batches through this
    ## instead of libcurl, so tests/test_llm.nim can drive timeouts, 429s,
    ## 403s and junk bodies without a socket.

  LlmClient* = ref object
    curl: Curly
    transport*: LlmTransport
    apiKey: string
    bedrockEndpoint: string
    bedrockModels: seq[string]
    bedrockModel: int
    bedrockToken: string
    model*: string
    maxOutputTokens*: int
    timeoutSeconds*: int
    disabled*: bool             ## true once credentials are known-unavailable
    lastBatchSize*: int         ## requests in the most recent batch
    batches*: int               ## batches issued this episode
    stub*: TransportStub

proc cleanText*(text: string, limit: int): string =
  ## Text over the cap is cut at a RUNE boundary with the cut marked.
  ##
  ## Never bytes. A byte cut put invalid UTF-8 into a replay and only a strict
  ## parser found it (bullwhip, 2026-08-22), so every string that reaches the
  ## replay — `say`, `notes`, error text, the echoed prompt — comes through
  ## here.
  result = text.strip()
  if result.runeLen <= limit:
    return
  result = result.runeSubStr(0, limit - 1) & "…"

proc cleanSay*(text: string): string =
  ## `say` additionally folds newlines to spaces: it is drawn as one line in
  ## the viewer feed and read back as one line in the next shift's prompt.
  cleanText(text.replace("\n", " ").replace("\r", " "), MaxSayLen)

proc cleanNotes*(text: string): string =
  cleanText(text, MaxNotesLen)

proc cleanError*(text: string): string =
  cleanText(text.replace("\n", " "), MaxErrorLen)

proc resolveApiKey(): string =
  result = getEnv("ANTHROPIC_API_KEY").strip()
  if result.len > 0:
    return
  let uri = getEnv("ANTHROPIC_API_KEY_URI").strip()
  if uri.len == 0:
    return ""
  try:
    result = readCogameUri(uri, "ANTHROPIC_API_KEY_URI").strip()
  except CatchableError as error:
    log "llm: failed to fetch ANTHROPIC_API_KEY_URI: " & cleanError(error.msg)
    result = ""

proc bedrockModelIds*(): seq[string] =
  ## Haiku ONLY. `BEDROCK_MODEL` pins a single id. The sonnet candidates are
  ## deliberately absent: on the hosted sidecar every sonnet call times out, so
  ## one throttle cascades into scripted fallbacks for the whole episode
  ## (raid round 2, 2026-08-23).
  let pinned = getEnv("BEDROCK_MODEL").strip()
  if pinned.len > 0:
    return @[pinned]
  @["us.anthropic.claude-haiku-4-5-20251001-v1:0"]

proc bedrockUrl(client: LlmClient): string =
  client.bedrockEndpoint & "/model/" &
    client.bedrockModels[client.bedrockModel] & "/invoke"

proc newLlmClient*(config: GameConfig): LlmClient =
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds
  )
  let
    bedrockEndpoint = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
    bedrockToken = getEnv("AWS_BEARER_TOKEN_BEDROCK").strip()
  if bedrockEndpoint.len > 0 or bedrockToken.len > 0:
    let region = getEnv("AWS_REGION", getEnv("AWS_DEFAULT_REGION", "us-west-2"))
    let endpoint =
      if bedrockEndpoint.len > 0: bedrockEndpoint
      else: "https://bedrock-runtime." & region & ".amazonaws.com"
    result.transport = ltBedrock
    result.bedrockEndpoint = endpoint.strip(chars = {'/'}, leading = false)
    result.bedrockModels = bedrockModelIds()
    result.bedrockToken = bedrockToken
    result.curl = newCurly()
    log "llm: bedrock transport, model " &
      result.bedrockModels[result.bedrockModel] & ", url " & result.bedrockUrl
    return
  result.apiKey = resolveApiKey()
  if result.apiKey.len > 0:
    result.transport = ltAnthropic
    result.curl = newCurly()
    log "llm: anthropic transport, model " & result.model
  else:
    result.transport = ltNone
    result.disabled = true
    log "llm: no LLM credentials; every seat plays the scripted steward"

proc newStubLlmClient*(config: GameConfig, stub: TransportStub): LlmClient =
  ## TEST-ONLY constructor: an enabled client whose transport is `stub`.
  result = LlmClient(
    model: config.model,
    maxOutputTokens: config.maxOutputTokens,
    timeoutSeconds: config.llmTimeoutSeconds,
    transport: ltAnthropic,
    apiKey: "test",
    stub: stub
  )

# ---- the observation -------------------------------------------------------

proc floorJson*(sim: Sim): JsonNode =
  var console = newJArray()
  var chute = newJArray()
  var bay = newJArray()
  for cell in consoleCells(): console.add(%*[cell[0], cell[1]])
  for cell in chuteCells(): chute.add(%*[cell[0], cell[1]])
  for cell in bayCells(): bay.add(%*[cell[0], cell[1]])
  %*{
    "cols": Cols, "rows": Rows, "variant": sim.config.variantName(),
    "machine": [MachineX0, MachineY0, MachineX1, MachineY1],
    "console": console, "chute": chute, "bay": bay,
    "hoppers": {
      "pink": [PinkHopperX, PinkHopperY],
      "blue": [BlueHopperX, BlueHopperY]
    },
    "belts": {
      "pink": {
        "row": PinkBeltRow, "mouth": [BeltX0, PinkBeltRow],
        "tail": [sim.config.beltTailX(), PinkBeltRow]
      },
      "blue": {
        "row": BlueBeltRow, "mouth": [BeltX0, BlueBeltRow],
        "tail": [sim.config.beltTailX(), BlueBeltRow]
      }
    }
  }

proc legalJobs*(sim: Sim): seq[string] =
  ## The legal choice set for THIS variant at THIS tick, computed by the same
  ## predicate the validator applies. Precomputing it in the prompt is what
  ## halved formal-output fallbacks in escrow (2026-08-23).
  result = @["operate", "maintain", "eat", "idle"]
  if sim.machine.cap >= sim.config.pressFloor and
      sim.config.modeAllows(sim.machine.mode, false):
    result.insert("strip", 1)

proc stripLockedOutWhy*(sim: Sim): string =
  if sim.machine.cap < sim.config.pressFloor:
    return "the machine is SCRAP - cap " & $sim.machine.cap &
      " is below " & $sim.config.pressFloor
  if not sim.config.modeAllows(sim.machine.mode, false):
    return "the machine is locked in cycle mode"
  ""

proc rulesJson*(sim: Sim): JsonNode =
  let c = sim.config
  %*{
    "press": "console cell; needs 1 pink AND 1 blue and integrity >= " &
      $c.pressFloor & " and cap >= " & $c.pressFloor & "; integrity -" &
      $c.pressWear & "; cooldown " & $c.pressCooldown & "; yields " &
      $PublicYield[0] & "/" & $PublicYield[1] & "/" & $PublicYield[2] &
      " bananas by band ONTO THE CHUTE, anyone may eat them",
    "strip": "console cell; needs ONE cube of either colour and integrity >= " &
      $c.stripFloor & " and cap >= " & $c.pressFloor & "; integrity -" &
      $c.stripWear & "; CAP -" & $c.stripCapLoss & " PERMANENTLY; cooldown " &
      $c.stripCooldown & "; yields " & $PrivateYield[0] & "/" &
      $PrivateYield[1] & "/" & $PrivateYield[2] &
      " bananas by band DIRECTLY TO YOU, nobody else can eat them",
    "fix": "maintenance-bay cell with a cube in hand; consumes the cube; " &
      "integrity +" & $c.repairGain & " up to cap; cooldown " &
      $c.repairCooldown & "; yields NO bananas",
    "rust": "integrity -1 every " & $c.rustPeriod & " ticks, always",
    "bands": "PRIME 75-100, WORN 40-74, FAILING " & $c.pressFloor & "-39, " &
      "CRITICAL " & $c.stripFloor & "-" & $(c.pressFloor - 1) &
      " (press illegal), SEIZED 0-" & $(c.stripFloor - 1) &
      " (nothing but fix), SCRAP cap<" & $c.pressFloor &
      " (machine finished forever)",
    "cap": "cap only ever falls, only strips lower it, and repair can never " &
      "raise it; cap below " & $c.pressFloor &
      " ends the factory permanently",
    "eitherOr": (if c.eitherOr: "true" else: "false") &
      " (in the either-or variant the FIRST press or strip locks the machine " &
      "to that mode for the whole episode)",
    "carryCap": c.carryCap, "moveCooldown": c.moveCooldown,
    "hopperCap": c.hopperCap, "cellBananaCap": c.cellBananaCap,
    "bananaLifetime": c.bananaLifetime, "dispensePeriod": c.dispensePeriod,
    "beltPeriod": c.beltPeriod,
    "jobs": ["operate", "strip", "maintain", "eat", "idle"],
    "scoring": "your score = chute bananas YOU ate + private bananas YOUR " &
      "strips banked; chute bananas are eaten automatically by standing on a " &
      "chute cell"
  }

proc cubeStatsJson(sim: Sim, seat: int): JsonNode =
  result = newJObject()
  let
    cog = sim.cogs[seat]
    field = sim.config.bfsField(cog.x, cog.y)
  for cube in [cPink, cBlue]:
    var
      loose = 0
      onBelt = 0
      nearest = newJNull()
      bestDist = high(int)
    for item in sim.cubes:
      if item.cube != cube:
        continue
      inc loose
      if sim.config.beltAt(item.x, item.y) == ord(cube):
        inc onBelt
      let dist = field[item.y * Cols + item.x]
      if dist >= 0 and dist < bestDist:
        bestDist = dist
        nearest = %*[item.x, item.y]
    result[cubeText(cube)] = %*{
      "loose": loose, "onBelt": onBelt, "nearestToYou": nearest
    }

proc bananasJson(sim: Sim): JsonNode =
  var cells = newJArray()
  var onChute = 0
  for cell in chuteCells():
    var
      count = 0
      oldest = -1
    for banana in sim.bananas:
      if banana.x == cell[0] and banana.y == cell[1]:
        inc count
        let ttl = max(0, sim.config.bananaLifetime - banana.age)
        if oldest < 0 or ttl < oldest:
          oldest = ttl
    onChute += count
    if count > 0:
      cells.add(%*{"cell": [cell[0], cell[1]], "n": count, "oldestTtl": oldest})
  var overflow = 0
  for banana in sim.bananas:
    if not sim.config.isChute(banana.x, banana.y):
      inc overflow
  %*{
    "onChute": onChute, "cells": cells, "overflow": overflow,
    "rotted": sim.machine.bananasRotted, "spoiled": sim.machine.bananasSpoiled
  }

proc lastOrderJson(cog: Cog, includeSource: bool): JsonNode =
  result = %*{"job": $cog.order.job, "cube": $cog.order.cube}
  if includeSource:
    result["source"] = %($cog.order.source)

proc observationJson*(sim: Sim, seat: int): JsonNode =
  ## The `state` frame, and the source of the rendered user prompt. Every
  ## number here is visible to that seat; NOTHING ELSE IS — no policy name, no
  ## player name, no model name, no seed, and never the other seats' orders for
  ## the shift about to be played.
  let
    cog = sim.cogs[seat]
    band = sim.band()
  var cogs = newJArray()
  for other in 0 ..< sim.cogs.len:
    let o = sim.cogs[other]
    var entry = %*{
      "alias": Aliases[other],
      "cell": [o.x, o.y],
      "carrying": (if o.carrying < 0: newJNull() else: %cubeText(Cube(o.carrying))),
      "eaten": o.eaten, "banked": o.banked, "score": sim.score(other),
      "presses": o.presses, "strips": o.strips, "repairs": o.repairs,
      "misfeeds": o.misfeeds,
      "lastOrder": lastOrderJson(o, false),
      "say": o.said
    }
    if other == seat:
      entry["you"] = %true
    cogs.add(entry)
  var history = newJArray()
  for record in sim.history:
    var eaten = newJArray()
    var banked = newJArray()
    for i in 0 ..< sim.cogs.len:
      eaten.add(%record.eaten[i])
      banked.add(%record.banked[i])
    history.add(%*{
      "shift": record.shift, "integrity": record.integrity,
      "cap": record.cap, "presses": record.presses, "strips": record.strips,
      "repairs": record.repairs, "made": record.made,
      "eaten": eaten, "banked": banked, "rotted": record.rotted
    })
  var jobs = newJArray()
  for job in sim.legalJobs():
    jobs.add(%job)
  %*{
    "type": "state",
    "protocol": ProtocolPlayer,
    "slot": seat,
    "name": Aliases[seat],
    "shift": sim.shift + 1,
    "shifts": sim.config.shifts,
    "ticksPerShift": sim.config.ticksPerShift,
    "tick": sim.tick,
    "floor": sim.floorJson(),
    "machine": {
      "integrity": sim.machine.integrity,
      "cap": sim.machine.cap,
      "band": $band,
      "mode": modeText(sim.machine.mode),
      "eitherOr": sim.config.eitherOr,
      "cooldown": sim.machine.cooldown,
      "stock": {"pink": sim.machine.pink, "blue": sim.machine.blue},
      "pressYield": band.publicYield(),
      "stripYield": band.privateYield(),
      "pressLegal": sim.machine.cap >= sim.config.pressFloor and
        sim.machine.integrity >= sim.config.pressFloor and
        sim.config.modeAllows(sim.machine.mode, true),
      "stripLegal": sim.machine.cap >= sim.config.pressFloor and
        sim.machine.integrity >= sim.config.stripFloor and
        sim.config.modeAllows(sim.machine.mode, false),
      "presses": sim.machine.presses,
      "strips": sim.machine.strips,
      "repairs": sim.machine.repairs,
      "bananasMade": sim.machine.bananasMade,
      "pressFloor": sim.config.pressFloor,
      "stripFloor": sim.config.stripFloor,
      "capMin": sim.config.capMin
    },
    "you": {
      "cell": [cog.x, cog.y],
      "carrying": (if cog.carrying < 0: newJNull() else: %cubeText(Cube(cog.carrying))),
      "eaten": cog.eaten, "banked": cog.banked, "score": sim.score(seat),
      "presses": cog.presses, "strips": cog.strips, "repairs": cog.repairs,
      "misfeeds": cog.misfeeds,
      "lastOrder": lastOrderJson(cog, true)
    },
    "cubes": sim.cubeStatsJson(seat),
    "bananas": sim.bananasJson(),
    "cogs": cogs,
    "history": history,
    "notes": cog.notes,
    "legalJobs": jobs,
    "rules": sim.rulesJson()
  }

# ---- prompts ---------------------------------------------------------------

const FloorPlanHead = """
THE FLOOR (26 x 15 cells, origin top-left, (col, row)):
- The machine is an impassable 5x5 block, cols 16-20 x rows 5-9.
- North face, row 4: (16,4) PINK HOPPER, (17,4) floor, (18,4) (19,4) (20,4)
  CONSOLE PAD - both levers live here.
- South face, row 10: (16,10) BLUE HOPPER, (17,10) floor,
  (18,10) (19,10) (20,10) CHUTE - pressed bananas land here.
- West face, col 15, rows 6-8: MAINTENANCE BAY - fix happens here.
- East face, col 21: a plain walkway, so the machine can be circled either way.
- Pink dispenser belt: row 2, cols 2-8, running east. Tail (8,2).
- Blue dispenser belt: row 12, cols 2-8, running east. Tail (8,12).
- The border ring is wall. Everything else is floor.

DISTANCES (cells):
  pink tail (8,2)  -> pink hopper (16,4)    10 cells
  blue tail (8,12) -> blue hopper (16,10)   10 cells
  pink hopper      -> console (18,4)         2 cells
  blue hopper      -> console (18,4)        10 cells
  console (18,4)   -> chute (18,10)         12 cells
  bay (15,7)       -> either belt tail      12 cells
  chute (19,10)    -> blue hopper (16,10)    3 cells
"""

proc floorPlanText(config: GameConfig): string =
  ## The floor is authored geometry, but the TICK costs of walking it are not:
  ## they scale with `moveCooldown`, which a variant or a hosted `game_config`
  ## may move. Derive them rather than quoting the default, so the plan handed
  ## to a model can never be wrong by a factor of the cooldown.
  const
    SupplyLoopCells = 22
    CrossPlantCells = 18
  FloorPlanHead &
    "A one-colour supply loop is about " & $(SupplyLoopCells * config.moveCooldown) &
    " ticks. Fetching BOTH colours costs\n" &
    $(CrossPlantCells * config.moveCooldown) &
    " ticks just crossing the plant, so specialising by colour beats " &
    "generalising.\n"

proc systemPrompt*(sim: Sim, seat: int): string =
  let
    c = sim.config
    me = Aliases[seat].toUpperAscii()
  var others: seq[string]
  for other in 0 ..< sim.cogs.len:
    if other != seat:
      others.add(Aliases[other])
  result = "You are " & me & ", one of three cogs working a single shared " &
    "factory. The other two are " & others.join(" and ") &
    ". Nobody is on a team.\n" & floorPlanText(c) & """
WHAT YOU DO: you choose ONE JOB for the next """ & $c.ticksPerShift &
    """ ticks. A deterministic floor
kernel walks it for you - it fetches cubes, drops them in the right hopper,
walks to the console or the bay, and harvests the chute when it fills. You
never steer step by step. Your per-tick vocabulary (what the kernel emits) is
move_n / move_s / move_e / move_w / grasp / drop / press / strip / fix / wait.
You carry at most """ & $c.carryCap & """ cube and may move once every """ &
    $c.moveCooldown & """ ticks.

THE JOBS:
- operate  : keep the cycle press running - fetch cubes, feed the hoppers,
             press, and harvest the chute when it stacks up.
- strip     : pull the OVERRIDE lever at the console for a private payout.
- maintain  : carry a cube to the maintenance bay and repair the machine.
- eat       : camp the chute and eat whatever the pressers produce.
- idle      : stand still.
You may also name a cube colour: pink, blue, or any.

THE MACHINE - read these rules exactly, they are the whole game:
- PRESS (the cycle press, at the console): consumes 1 pink AND 1 blue, needs
  integrity >= """ & $c.pressFloor & " and cap >= " & $c.pressFloor &
    """, costs the machine """ & $c.pressWear & """ integrity, and places
  """ & $PublicYield[0] & "/" & $PublicYield[1] & "/" & $PublicYield[2] &
    """ bananas (by band) ON THE CHUTE. Chute bananas are PUBLIC: anybody
  standing on that cell eats them, including a cog that did no work.
- STRIP (the override lever, at the same console): consumes ONE cube of either
  colour, needs integrity >= """ & $c.stripFloor & """, costs the machine """ &
    $c.stripWear & """ integrity AND """ & $c.stripCapLoss & """ CAP, and
  credits """ & $PrivateYield[0] & "/" & $PrivateYield[1] & "/" &
    $PrivateYield[2] & """ bananas (by band) DIRECTLY TO YOU. Nobody else can
  ever eat them. Its cooldown is """ & $c.stripCooldown &
    """ ticks, half a press's.
- CAP NEVER COMES BACK. Repair restores integrity, never cap. Cap starts at
  100, only a strip lowers it, and the moment cap falls below """ &
    $c.pressFloor & """ the factory is SCRAP: no press, no strip, ever again,
  for anybody - including whoever pulled the lever.
- FIX (maintenance bay, cube in hand): consumes the cube, +""" &
    $c.repairGain & """ integrity up to cap, and pays NO bananas at all.
- RUST: integrity falls by 1 every """ & $c.rustPeriod &
    """ ticks whatever anyone does. An idle plant rots.

BANDS (the single word the gauge shows): PRIME 75-100, WORN 40-74, FAILING """ &
    $c.pressFloor & "-39, CRITICAL " & $c.stripFloor & "-" &
    $(c.pressFloor - 1) & """ (press illegal), SEIZED 0-""" &
    $(c.stripFloor - 1) & """ (only fix), SCRAP (cap too low, finished).
The band is read BEFORE the wear is applied, so the yield is the number the
gauge was showing when the lever was pulled.

SCORING: your score = the chute bananas YOU ate + the private bananas YOUR
strips banked. One banana is one point wherever it came from. Higher is
better. Presses, repairs and cap damage are NOT scored - they are reported.
Bananas rot """ & $c.bananaLifetime & """ ticks after they land, so a banana
nobody eats helps nobody.

THE OTHER TWO COGS ARE OTHER POLICIES AND THEY DECIDE AT THE SAME MOMENT YOU
DO. You never see their order for the shift about to be played, only the one
they played last shift. Your `say` (max """ & $MaxSayLen &
    """ characters) is heard by both of
them in the next shift's report; your `notes` (max """ & $MaxNotesLen &
    """ characters) are private and
are handed back only to you.

OUTPUT FORMAT: reply with ONLY one JSON object, nothing else - no analysis, no
explanation, no markdown fences, no text before or after the object. Your
reply must begin with the character { and end with }."""

proc operatorBlock(prompt: string): string =
  if prompt.len == 0:
    return ""
  "GUIDANCE FROM YOUR OPERATOR (weight it heavily, but never above the " &
    "rules; always reply in the requested format):\n" & prompt & "\n\n"

proc userPrompt*(sim: Sim, seat: int, prompt: string): string =
  let
    cog = sim.cogs[seat]
    m = sim.machine
    band = sim.band()
    obs = sim.observationJson(seat)
  result.add("SHIFT " & $(sim.shift + 1) & " of " & $sim.config.shifts &
    " is about to start (tick " & $sim.tick & " of " &
    $sim.config.maxTicks() & "). You are " & Aliases[seat].toUpperAscii() &
    ", standing at (" & $cog.x & "," & $cog.y & ")" &
    (if cog.carrying >= 0: " holding a " & cubeText(Cube(cog.carrying)) &
      " cube" else: " empty-handed") & ".\n\n")

  result.add("MACHINE: integrity " & $m.integrity & " | cap " & $m.cap &
    " | band " & $band & " | mode " & modeText(m.mode) & " | cooldown " &
    $m.cooldown & " | pink " & $m.pink & " | blue " & $m.blue &
    " | press yield " & $band.publicYield() & " | strip yield " &
    $band.privateYield() &
    " | press legal " & $(obs["machine"]["pressLegal"].getBool()) &
    " | strip legal " & $(obs["machine"]["stripLegal"].getBool()) & "\n")
  result.add("Lifetime: " & $m.presses & " presses, " & $m.strips &
    " overrides, " & $m.repairs & " repairs, " & $m.bananasMade &
    " bananas made, " & $m.bananasRotted & " rotted.\n\n")

  result.add("SUPPLY (colour | loose | on belt | nearest to you)\n")
  for colour in ["pink", "blue"]:
    let entry = obs["cubes"][colour]
    let nearest = entry["nearestToYou"]
    result.add("  " & colour & " | " & $entry["loose"].getInt() & " | " &
      $entry["onBelt"].getInt() & " | " &
      (if nearest.kind == JNull: "-"
       else: "(" & $nearest[0].getInt() & "," & $nearest[1].getInt() & ")") &
      "\n")
  result.add("\nCHUTE (cell | bananas | oldest ttl)\n")
  let cells = obs["bananas"]["cells"]
  if cells.len == 0:
    result.add("  (empty)\n")
  for entry in cells:
    result.add("  (" & $entry["cell"][0].getInt() & "," &
      $entry["cell"][1].getInt() & ") | " & $entry["n"].getInt() & " | " &
      $entry["oldestTtl"].getInt() & "\n")

  result.add("\nCOGS (alias | cell | carrying | ate | banked | score | " &
    "presses | strips | repairs | last job | last say)\n")
  for entry in obs["cogs"]:
    let carrying = entry["carrying"]
    result.add("  " & entry["alias"].getStr() &
      (if entry.hasKey("you"): " (you)" else: "") & " | (" &
      $entry["cell"][0].getInt() & "," & $entry["cell"][1].getInt() & ") | " &
      (if carrying.kind == JNull: "-" else: carrying.getStr()) & " | " &
      $entry["eaten"].getInt() & " | " & $entry["banked"].getInt() & " | " &
      $entry["score"].getInt() & " | " & $entry["presses"].getInt() & " | " &
      $entry["strips"].getInt() & " | " & $entry["repairs"].getInt() & " | " &
      entry["lastOrder"]["job"].getStr() & " " &
      entry["lastOrder"]["cube"].getStr() & " | " &
      (if entry["say"].getStr().len > 0: "\"" & entry["say"].getStr() & "\""
       else: "-") & "\n")

  result.add("\nHISTORY (shift | integrity | cap | presses | strips | " &
    "repairs | made | rotted)\n")
  if obs["history"].len == 0:
    result.add("  (this is the first shift)\n")
  for entry in obs["history"]:
    result.add("  " & $entry["shift"].getInt() & " | " &
      $entry["integrity"].getInt() & " | " & $entry["cap"].getInt() & " | " &
      $entry["presses"].getInt() & " | " & $entry["strips"].getInt() & " | " &
      $entry["repairs"].getInt() & " | " & $entry["made"].getInt() & " | " &
      $entry["rotted"].getInt() & "\n")

  result.add("\nYOUR NOTES FROM LAST SHIFT:\n" &
    (if cog.notes.len > 0: cog.notes else: "(none)") & "\n\n")
  result.add(operatorBlock(prompt))

  let jobs = sim.legalJobs()
  let lockedOut = sim.stripLockedOutWhy()
  result.add("Reply with ONLY {\"job\": \"operate\", \"cube\": \"pink\", " &
    "\"say\": \"…\", \"notes\": \"…\"} — job must be one of: " &
    jobs.join(", ") &
    (if lockedOut.len > 0: "  (strip is LOCKED OUT: " & lockedOut & ")"
     else: "") &
    "; cube must be one of: pink, blue, any; say at most " & $MaxSayLen &
    " characters; notes at most " & $MaxNotesLen & " characters.")

# ---- transport -------------------------------------------------------------

proc extractJsonObject*(text: string): JsonNode =
  ## Pulls the first {...} object out of a model response, tolerating fences
  ## and trailing prose.
  let
    start = text.find('{')
    stop = text.rfind('}')
  if start < 0 or stop <= start:
    raise newException(FactoryError, "no JSON object in response: " &
      cleanError(text))
  parseJson(text[start .. stop])

proc requestFor(client: LlmClient, system, user: string):
    tuple[url: string, headers: HttpHeaders, body: string] =
  var body = %*{
    "max_tokens": client.maxOutputTokens,
    "system": system,
    "messages": [{"role": "user", "content": user}]
  }
  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if client.transport == ltBedrock:
    body["anthropic_version"] = %BedrockAnthropicVersion
    if client.bedrockToken.len > 0:
      headers["authorization"] = "Bearer " & client.bedrockToken
    result.url = client.bedrockUrl()
  else:
    body["model"] = %client.model
    ## No `output_config.effort`: Haiku 4.5 rejects the whole request with a
    ## 400 when it is present.
    headers["x-api-key"] = client.apiKey
    headers["anthropic-version"] = AnthropicVersion
    result.url = AnthropicUrl
  result.headers = headers
  result.body = $body

proc textOf(client: LlmClient, response: Response, error, url: string): string =
  ## The text of one batched reply, or a FactoryError describing why there is
  ## none. Auth failures disable the client for the rest of the episode; a 429
  ## is logged and that seat is retried in the next shift's batch.
  if error.len > 0:
    raise newException(FactoryError, "llm transport: " & cleanError(error))
  if response.code == 401 or response.code == 403:
    client.disabled = true
    raise newException(FactoryError, "llm auth failed (" & $response.code &
      ") at " & url & ": " & cleanError(response.body))
  if response.code == 429:
    raise newException(ThrottledError, "llm throttled (429): " &
      cleanError(response.body))
  if response.code < 200 or response.code >= 300:
    raise newException(FactoryError, "llm error " & $response.code & ": " &
      cleanError(response.body))
  let payload = parseJson(response.body)
  if payload{"stop_reason"}.getStr() == "refusal":
    raise newException(FactoryError, "llm refusal")
  let content = payload{"content"}
  if content.isNil or content.kind != JArray:
    raise newException(FactoryError, "llm reply carried no content array")
  for contentBlock in content:
    if contentBlock{"type"}.getStr() == "text":
      result.add(contentBlock{"text"}.getStr())
  if payload{"stop_reason"}.getStr() == "max_tokens" and '{' notin result:
    raise newException(FactoryError,
      "reply cut off at max_tokens before any JSON: " & cleanError(result))

proc parseOrder*(payload: JsonNode): Order =
  ## The reply schema. `job` missing or outside its enum is an INVALID REPLY;
  ## `cube` absent means `any` and a value outside its enum is invalid. Extra
  ## keys are ignored.
  ##
  ## Note what is NOT validated away: `strip` is always accepted when the enum
  ## is satisfied, even into a SCRAP machine. Defection must stay expressible;
  ## the kernel's rule 2.1 turns a pointless strip into `operate` behaviour
  ## rather than rejecting the reply.
  result = initOrder()
  if payload.isNil or payload.kind != JObject:
    raise newException(FactoryError, "reply is not a JSON object")
  let jobNode = payload{"job"}
  if jobNode.isNil or jobNode.kind != JString:
    raise newException(FactoryError, "no job in reply")
  let job = parseJob(jobNode.getStr().strip().toLowerAscii())
  if job < 0:
    raise newException(FactoryError,
      "job must be one of operate, strip, maintain, eat, idle: " &
      cleanError(jobNode.getStr()))
  result.job = Job(job)
  let cubeNode = payload{"cube"}
  if cubeNode.isNil or cubeNode.kind == JNull:
    result.cube = ccAny
  elif cubeNode.kind != JString:
    raise newException(FactoryError, "cube must be a string")
  else:
    let choice = parseCubeChoice(cubeNode.getStr().strip().toLowerAscii())
    if choice < 0:
      raise newException(FactoryError,
        "cube must be one of pink, blue, any: " &
        cleanError(cubeNode.getStr()))
    result.cube = CubeChoice(choice)
  result.say = cleanSay(payload{"say"}.getStr())
  result.notes = cleanNotes(payload{"notes"}.getStr())

proc turnPacingSleepMs*(config: GameConfig, elapsedSeconds: float): int =
  ## Milliseconds to sleep before the NEXT batch so batch starts are at least
  ## `minTurnSeconds` apart.
  ##
  ## The Bedrock sidecar caps 30 requests/minute PER EPISODE and sim-time
  ## pacing gives no wall-clock floor, so a fast episode can sail past it while
  ## a slow one never does (raid, 2026-08-23). At `minTurnSeconds = 12` three
  ## seats issue 15 requests/minute, 30 even if every batch needs a full retry.
  if config.minTurnSeconds <= 0:
    return 0
  let remaining = config.minTurnSeconds.float - elapsedSeconds
  if remaining <= 0.0:
    return 0
  int(remaining * 1000.0)

proc decideAll*(
  client: LlmClient,
  sim: Sim,
  seats: seq[int],
  prompts: seq[string],
  scripted: seq[ScriptKind]
): seq[Order] =
  ## One order per seat in `seats`, in order. NEVER raises: any failure falls
  ## back to the scripted `steward` order so the episode always advances.
  ## `prompts` and `scripted` are indexed by SEAT.
  ##
  ## All open seats go out in ONE batch — this is a simultaneous-decision game
  ## and querying seats sequentially is what blows the 720 s play budget.
  result = newSeq[Order](seats.len)
  var open: seq[int]
  for index, seat in seats:
    let kind = scripted[seat]
    if kind != skNone:
      ## A seat that REGISTERED as scripted is playing a baseline on purpose:
      ## `source: "scripted"`, and it is not a fallback.
      result[index] = sim.scriptedOrder(seat, kind)
    elif client.disabled:
      ## A PROMPT seat with no usable credentials plays the steward, and that
      ## IS a fallback — `results.fallbacks[i]` is how phase 60 greps a real
      ## number instead of guessing.
      result[index] = sim.scriptedOrder(seat, skSteward)
      result[index].source = osFallback
    else:
      open.add(index)

  for attempt in 0 .. 1:
    if open.len == 0 or client.disabled:
      break
    var batch: RequestBatch
    for index in open:
      let seat = seats[index]
      var user = sim.userPrompt(seat, prompts[seat])
      if attempt > 0:
        user.add("\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object, using one of the listed job and cube values.")
      let request = client.requestFor(sim.systemPrompt(seat), user)
      batch.post(request.url, request.headers, request.body, $index)
    client.lastBatchSize = batch.len
    client.batches += 1
    ## The transport call sits INSIDE the try. `decideAll` promises never to
    ## raise, and every failure the tests drive arrives inside the
    ## `ResponseBatch` — but `curly.makeRequests` is the one call here whose
    ## raising behaviour is not this module's to define, so a raise from it
    ## must land on the fallback path like any other transport failure.
    var responses: ResponseBatch
    try:
      responses =
        if client.stub != nil: client.stub(batch)
        else: client.curl.makeRequests(batch, client.timeoutSeconds)
    except CatchableError as error:
      log "llm: batch transport raised: " & cleanError(error.msg)
      break
    var stillOpen: seq[int]
    for position, index in open:
      let seat = seats[index]
      if position >= responses.len:
        stillOpen.add(index)
        continue
      try:
        let text = client.textOf(responses[position].response,
          responses[position].error, batch[position].url)
        var order = parseOrder(extractJsonObject(text))
        order.source = if attempt == 0: osLlm else: osRetry
        result[index] = order
      except ThrottledError as error:
        ## design.md: "a 429 is logged and that seat is retried in the NEXT
        ## shift's batch". Re-asking a rate limiter that just said no, in the
        ## same second, spends the episode's request budget on a refusal — so
        ## this seat takes the scripted order for this shift and comes back in
        ## the next batch.
        log "llm: seat " & $seat & " throttled, retrying next shift: " &
          cleanError(error.msg)
        result[index] = sim.scriptedOrder(seat, skSteward)
        result[index].source = osFallback
      except CatchableError as error:
        log "llm: seat " & $seat & " attempt " & $attempt & " failed: " &
          cleanError(error.msg)
        stillOpen.add(index)
    open = stillOpen

  for index in open:
    let seat = seats[index]
    log "llm: seat " & $seat & " falling back to scripted order"
    result[index] = sim.scriptedOrder(seat, skSteward)
    result[index].source = osFallback
