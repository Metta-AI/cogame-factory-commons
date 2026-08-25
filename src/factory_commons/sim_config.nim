## GameConfig lifecycle: defaults, `config.update`, and the variant label.
##
## Forked from `coworld-ctf/src/ctf/sim_config.nim`. Every default here is
## mirrored by a `default` in `coworld_manifest_template.json`'s
## `game.config_schema`; tests/test_manifest.nim asserts the two agree, so a
## knob can never mean one thing to the sim and another to the platform.

import std/[json, strutils]

import ./sim_types

## TWO CONSTANTS DIFFER FROM THE DESIGN NOTE'S AUTHORED VALUES, each one a
## rung of that note's own repair ladder, each measured rather than guessed
## (`tests/test_feasibility.nim` is the enforcement, not the note's table;
## `tools/tune/feasibility_sweep.nim` is the grid that chose them and
## `docs/tuning.md` records its output):
##
##   moveCooldown  2 -> 1   gate (a). Rungs 1 and 2 (rustPeriod 20 -> 30, then
##                          repairGain 8 -> 10) were measured and did NOT move
##                          the binding constraint, which is the banana TOTAL:
##                          an all-steward room made ~50 of the required 70,
##                          because the harvest and console legs eat the supply
##                          loop. Rung 3 does move it (~83). rustPeriod and
##                          repairGain therefore keep their authored values.
##   stripCapLoss 12 -> 16  gate (c). At 12 an all-stripper room STALLS instead
##                          of ruining the plant: seven overrides need a repair
##                          in between (the note's own walk says so) and no
##                          stripper ever repairs, so integrity seizes at 4 with
##                          cap stuck at 28 — above pressFloor, so the episode
##                          ends `shift_limit`, not `factory_ruined`. At 16 five
##                          overrides take cap to 20 and the plant is scrap.
##
## `eatTrigger` keeps the note's authored 3: with `moveCooldown 1` and the
## steward's rotating harvest shift the sweep measures 12/12 clean gate-(a)
## seeds, worst seat 25, 83 bananas — better on every column than the 6 this
## file shipped before (12/12, worst seat 21, 76).
##
## Every default here is mirrored by a `default` in
## `coworld_manifest_template.json`'s `game.config_schema`, and
## tests/test_manifest.nim asserts the two agree.

proc defaultGameConfig*(): GameConfig =
  GameConfig(
    tokens: @[],
    players: @[],
    numAgents: SeatCount,
    seed: 1234567,
    shifts: 15,
    ticksPerShift: 60,
    eitherOr: false,
    moveCooldown: 1,
    carryCap: 1,
    dispensePeriod: 10,
    beltPeriod: 4,
    beltLen: 7,
    hopperCap: 6,
    pressFloor: 25,
    stripFloor: 10,
    pressWear: 1,
    stripWear: 16,
    stripCapLoss: 16,
    repairGain: 8,
    capMin: 20,
    rustPeriod: 20,
    pressCooldown: 12,
    stripCooldown: 6,
    repairCooldown: 8,
    bananaLifetime: 180,
    cellBananaCap: 3,
    eatTrigger: 3,
    llmTimeoutSeconds: 20,
    minTurnSeconds: 12,
    maxOutputTokens: 700,
    model: "claude-haiku-4-5-20251001",
    episodeTimeoutSeconds: 1200,
    playerConnectTimeoutSeconds: 180,
    shutdownGraceSeconds: 20,
    showPlayerLabels: true
  )

proc clampInt(value, lo, hi: int): int =
  max(lo, min(hi, value))

proc readInt(node: JsonNode, key: string, current, lo, hi: int): int =
  let field = node{key}
  if field.isNil:
    return current
  case field.kind
  of JInt: clampInt(field.getInt(), lo, hi)
  of JFloat: clampInt(int(field.getFloat()), lo, hi)
  of JString:
    try: clampInt(parseInt(field.getStr().strip()), lo, hi)
    except ValueError: current
  else: current

proc readBool(node: JsonNode, key: string, current: bool): bool =
  let field = node{key}
  if field.isNil:
    return current
  case field.kind
  of JBool: field.getBool()
  of JInt: field.getInt() != 0
  of JString: field.getStr().strip().toLowerAscii() in ["1", "true", "yes"]
  else: current

proc update*(config: var GameConfig, configJson: string) =
  ## Folds one runtime config document into the config. Unknown keys are
  ## ignored; out-of-range values are clamped to the schema's bounds rather
  ## than raising, so a hostile variant cannot take the episode down.
  if configJson.len == 0:
    return
  var node: JsonNode
  try:
    node = parseJson(configJson)
  except CatchableError as error:
    raise newException(FactoryError, "bad config JSON: " & error.msg)
  if node.kind != JObject:
    raise newException(FactoryError, "config must be a JSON object")

  let tokens = node{"tokens"}
  if not tokens.isNil and tokens.kind == JArray:
    config.tokens = @[]
    for item in tokens:
      config.tokens.add(item.getStr())

  let players = node{"players"}
  if not players.isNil and players.kind == JArray:
    config.players = @[]
    for item in players:
      if item.kind == JObject:
        config.players.add(PlayerConfig(name: item{"name"}.getStr()))
      else:
        config.players.add(PlayerConfig(name: item.getStr()))

  config.numAgents = node.readInt("num_agents", config.numAgents, 1, SeatCount)
  config.seed = node.readInt("seed", config.seed, 0, high(int32))
  config.shifts = node.readInt("shifts", config.shifts, 1, 30)
  config.ticksPerShift = node.readInt("ticksPerShift", config.ticksPerShift, 10, 120)
  config.eitherOr = node.readBool("eitherOr", config.eitherOr)
  config.moveCooldown = node.readInt("moveCooldown", config.moveCooldown, 1, 8)
  config.carryCap = node.readInt("carryCap", config.carryCap, 1, 2)
  config.dispensePeriod = node.readInt("dispensePeriod", config.dispensePeriod, 2, 48)
  config.beltPeriod = node.readInt("beltPeriod", config.beltPeriod, 1, 24)
  config.beltLen = node.readInt("beltLen", config.beltLen, 3, 12)
  config.hopperCap = node.readInt("hopperCap", config.hopperCap, 1, 24)
  config.pressFloor = node.readInt("pressFloor", config.pressFloor, 0, 100)
  config.stripFloor = node.readInt("stripFloor", config.stripFloor, 0, 100)
  config.pressWear = node.readInt("pressWear", config.pressWear, 0, 20)
  config.stripWear = node.readInt("stripWear", config.stripWear, 0, 60)
  config.stripCapLoss = node.readInt("stripCapLoss", config.stripCapLoss, 0, 60)
  config.repairGain = node.readInt("repairGain", config.repairGain, 0, 40)
  config.capMin = node.readInt("capMin", config.capMin, 0, 100)
  config.rustPeriod = node.readInt("rustPeriod", config.rustPeriod, 0, 240)
  config.pressCooldown = node.readInt("pressCooldown", config.pressCooldown, 0, 60)
  config.stripCooldown = node.readInt("stripCooldown", config.stripCooldown, 0, 60)
  config.repairCooldown = node.readInt("repairCooldown", config.repairCooldown, 0, 60)
  config.bananaLifetime = node.readInt("bananaLifetime", config.bananaLifetime, 24, 960)
  config.cellBananaCap = node.readInt("cellBananaCap", config.cellBananaCap, 1, 9)
  config.eatTrigger = node.readInt("eatTrigger", config.eatTrigger, 1, 9)
  config.llmTimeoutSeconds = node.readInt("llmTimeoutSeconds", config.llmTimeoutSeconds, 5, 60)
  config.minTurnSeconds = node.readInt("minTurnSeconds", config.minTurnSeconds, 0, 60)
  config.maxOutputTokens = node.readInt("maxOutputTokens", config.maxOutputTokens, 200, 2000)
  config.episodeTimeoutSeconds =
    node.readInt("episodeTimeoutSeconds", config.episodeTimeoutSeconds, 0, 86_400)
  config.playerConnectTimeoutSeconds =
    node.readInt("playerConnectTimeoutSeconds", config.playerConnectTimeoutSeconds, 0, 3600)
  config.shutdownGraceSeconds =
    node.readInt("shutdownGraceSeconds", config.shutdownGraceSeconds, 0, 300)
  config.showPlayerLabels = node.readBool("showPlayerLabels", config.showPlayerLabels)
  let model = node{"model"}
  if not model.isNil and model.kind == JString and model.getStr().len > 0:
    config.model = model.getStr()

  ## `num_agents` is the seat count of record; tokens/players are padded up to
  ## it so a fixture that names fewer still seats a full room (the missing
  ## seats play the scripted steward).
  while config.players.len < config.numAgents:
    config.players.add(PlayerConfig(name: Aliases[config.players.len]))
  if config.players.len > config.numAgents:
    config.players.setLen(config.numAgents)

proc variantName*(config: GameConfig): string =
  ## The variant label the observation, the prompt and the replay carry.
  ##
  ## `coworld build` does not hand a variant id down into `game_config`, and
  ## the config schema is closed (`additionalProperties: false`), so the label
  ## is DERIVED from the four constants the manifest's variant table actually
  ## varies. Keep this in step with `variants[]`.
  if config.eitherOr:
    "either-or"
  elif config.stripCapLoss >= 20 and config.rustPeriod <= 14:
    "fragile-plant"
  elif config.dispensePeriod <= 6:
    "abundant-feed"
  else:
    "factory-commons"
