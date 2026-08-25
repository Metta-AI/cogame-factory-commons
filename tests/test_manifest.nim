## Packaging: `coworld_manifest_template.json` against the sim it describes.
##
## Every assertion here exists because the platform's own validator is the only
## other thing that checks it, and by then the failure is two phases away
## (`coworld build` pydantic errors, `upload-coworld` 400s, a ladder that
## schedules zero episodes). The last block is the one collab-cooking 0.1.1
## taught: EVERY variant's `game_config` must construct a sim, because a variant
## only the ladder ever builds is a variant nobody tested.

import std/[json, os, sets, strutils]

import factory_commons/[sim, scripted]

var checks = 0

template check(condition: untyped, message: string) =
  inc checks
  if not (condition):
    echo "FAIL: ", message
    quit(1)

proc repoRoot(): string =
  ## The tests run from the repo root (`nim r --path:src tests/x.nim`), but be
  ## robust to being run from `tests/`.
  for candidate in [".", "..", currentSourcePath().parentDir() / ".."]:
    if fileExists(candidate / "coworld_manifest_template.json"):
      return candidate
  ""

let root = repoRoot()
check root.len > 0, "coworld_manifest_template.json must be findable"

let
  manifestText = readFile(root / "coworld_manifest_template.json")
  manifest = parseJson(manifestText)
  composeText = readFile(root / "compose.yaml")

# ---------------------------------------------------- the image placeholder
proc composeServiceName(text: string): string =
  ## The placeholder is DERIVED from the compose service name, exactly as
  ## `coworld build` derives it (`service lantern` -> `{{LANTERN_IMAGE}}`).
  ## `{{GAME_IMAGE}}` is not a thing.
  var inServices = false
  for rawLine in text.splitLines():
    let line = rawLine.split('#')[0]
    if line.startsWith("services:"):
      inServices = true
      continue
    if not inServices:
      continue
    if line.len == 0:
      continue
    if not line.startsWith(" "):
      inServices = false
      continue
    let stripped = line.strip()
    if line.startsWith("  ") and not line.startsWith("    ") and
        stripped.endsWith(":"):
      return stripped[0 ..< stripped.len - 1]
  ""

let service = composeServiceName(composeText)
check service == "factory_commons",
  "compose.yaml declares one service named factory_commons, got '" & service & "'"
let placeholder = "{{" & service.toUpperAscii() & "_IMAGE}}"

block imagePlaceholder:
  check manifest["game"]["runnable"]["image"].getStr() == placeholder,
    "the game runnable image is " & placeholder & ", got " &
    manifest["game"]["runnable"]["image"].getStr()
  for entry in manifest["player"]:
    check entry["image"].getStr() == placeholder,
      "player " & entry["id"].getStr() & " uses " & placeholder
  check placeholder in manifestText,
    "the derived placeholder appears in the manifest text"
  check "{{GAME_IMAGE}}" notin manifestText,
    "{{GAME_IMAGE}} is not a thing and must not appear"
  check "coworld-factory-commons:latest" in composeText,
    "compose.yaml builds the image ci.yml and upload-policy name"

# ---------------------------------------------------- seats, everywhere
block numAgentsEverywhere:
  check manifest["variants"].len == 4, "four variants, no more"
  for variant in manifest["variants"]:
    let id = variant["id"].getStr()
    check variant.hasKey("description") and
      variant["description"].getStr().len > 0,
      "variant " & id & " carries a description (the 0.1.42 upload contract)"
    let config = variant["game_config"]
    check config.hasKey("num_agents"),
      "variant " & id & " declares num_agents — without it the ladder " &
      "schedules ZERO episodes"
    check config["num_agents"].getInt() == SeatCount,
      "variant " & id & " seats " & $SeatCount
    check config["players"].len == SeatCount,
      "variant " & id & " names three players"
    for seat in 0 ..< SeatCount:
      check config["players"][seat]["name"].getStr() == Aliases[seat],
        "variant " & id & " names the aliases in slot order"
  let cert = manifest["certification"]["game_config"]
  check cert.hasKey("num_agents"), "the cert fixture declares num_agents"
  check cert["num_agents"].getInt() == SeatCount, "and it is three"
  check cert["players"].len == SeatCount, "and it names three players"
  check manifest["certification"]["players"].len == SeatCount,
    "and seats exactly three"

# ---------------------------------------------------- the upload contract
block uploadContract:
  check manifest.hasKey("$schema"), "top-level $schema"
  check manifest["tags"].len >= 3, "at least three tags"
  check manifest.hasKey("episode_timeout_minutes"),
    "episode_timeout_minutes is TOP-LEVEL"
  check not manifest.hasKey("version"), "no top-level version (0.1.42)"
  let game = manifest["game"]
  check game["runnable"]["type"].getStr() == "game",
    "game.runnable.type is \"game\""
  check game.hasKey("owner"), "game.owner is required"
  check not game.hasKey("display_name"), "no game.display_name (0.1.42)"
  check game.hasKey("replay_viewer"),
    "game.replay_viewer, not a top-level replay_viewer"
  check game["replay_viewer"]["bundle"].getStr() == "static-replay-viewer",
    "the replay is a STATIC bundle, never a pod"
  check not manifest["certification"]["game_config"].hasKey("tokens"),
    "no runner-managed tokens in the cert fixture (0.1.42)"

block theSecretNamespace:
  ## The namespace must equal `game.name` CHARACTER FOR CHARACTER. They differ
  ## whenever the game name has an underscore and the repo slug a hyphen, and
  ## `upload-coworld` 400s on the mismatch AFTER a fully green certify.
  let name = manifest["game"]["name"].getStr()
  check name == GameName, "game.name is " & GameName
  let env = manifest["game"]["runnable"]["env"]
  check env.hasKey("ANTHROPIC_API_KEY_URI"),
    "ANTHROPIC_API_KEY_URI is in game.runnable.env — without it the hosted " &
    "container never sees the coworld secret and every league episode " &
    "silently plays scripted"
  let uri = env["ANTHROPIC_API_KEY_URI"].getStr()
  check uri == "secret://coworld/" & name & "/anthropic_api_key",
    "the secret namespace equals game.name exactly, got " & uri
  check "factory-commons" notin uri,
    "the HYPHENATED slug must not appear in the secret URI"

block docsAndProtocols:
  let docs = manifest["game"]["docs"]
  check docs["readme"]["type"].getStr() == "text",
    "game.docs.readme is a {type,value} object, not a bare string"
  check docs["readme"]["value"].getStr().len > 400, "and it says something"
  check docs["pages"].len >= 2, "and there are pages"
  var ids: HashSet[string]
  for page in docs["pages"]:
    check page.hasKey("id") and page.hasKey("title") and page.hasKey("content"),
      "every page has id, title and content"
    check page["content"]["type"].getStr() == "text",
      "and its content is a {type,value} object"
    check page["content"]["value"].getStr().len > 200,
      "and it says something: " & page["id"].getStr()
    ids.incl(page["id"].getStr())
  check "rules.md" in ids and "policies.md" in ids,
    "the rules and the policy how-to are both documented"
  let protocols = manifest["game"]["protocols"]
  for key in ["player", "global"]:
    check protocols.hasKey(key), "game.protocols carries BOTH player and global"
    check protocols[key].kind == JObject,
      "game.protocols." & key & " is an object, not a bare string — the " &
      "platform validator rejects the string form (cogame-garble v0.1.0)"
    check protocols[key]["type"].getStr() == "text",
      "game.protocols." & key & " is {type:text, value:...}"
    check protocols[key]["value"].getStr().len > 200,
      "game.protocols." & key & " says something"
  check ProtocolPlayer in protocols["player"]["value"].getStr(),
    "the player protocol names its version string"
  check "data-replay-loaded" in protocols["global"]["value"].getStr(),
    "the global protocol documents the viewer's load signal"

block configSchemaIsRealJsonSchema:
  let schema = manifest["game"]["config_schema"]
  check schema["type"].getStr() == "object", "config_schema is an object schema"
  check not schema["additionalProperties"].getBool(),
    "additionalProperties is false"
  var required: seq[string]
  for item in schema["required"]:
    required.add(item.getStr())
  check "tokens" in required, "tokens is required"
  for name, prop in schema["properties"]:
    if prop{"type"}.getStr() == "array":
      ## EVERY array property needs both bounds, not just membership in
      ## `required` (tandem 0.1.0, 2026-08-23).
      check prop.hasKey("minItems"), name & " declares minItems"
      check prop.hasKey("maxItems"), name & " declares maxItems"
      check prop["maxItems"].getInt() == SeatCount,
        name & " is bound to num_agents"
  ## The schema defaults and the sim defaults are one truth.
  let defaults = defaultGameConfig()
  let props = schema["properties"]
  check props["num_agents"]["default"].getInt() == defaults.numAgents, "num_agents"
  check props["shifts"]["default"].getInt() == defaults.shifts, "shifts"
  check props["ticksPerShift"]["default"].getInt() == defaults.ticksPerShift,
    "ticksPerShift"
  check props["moveCooldown"]["default"].getInt() == defaults.moveCooldown,
    "moveCooldown"
  check props["carryCap"]["default"].getInt() == defaults.carryCap, "carryCap"
  check props["dispensePeriod"]["default"].getInt() == defaults.dispensePeriod,
    "dispensePeriod"
  check props["beltPeriod"]["default"].getInt() == defaults.beltPeriod, "beltPeriod"
  check props["beltLen"]["default"].getInt() == defaults.beltLen, "beltLen"
  check props["hopperCap"]["default"].getInt() == defaults.hopperCap, "hopperCap"
  check props["pressFloor"]["default"].getInt() == defaults.pressFloor, "pressFloor"
  check props["stripFloor"]["default"].getInt() == defaults.stripFloor, "stripFloor"
  check props["pressWear"]["default"].getInt() == defaults.pressWear, "pressWear"
  check props["stripWear"]["default"].getInt() == defaults.stripWear, "stripWear"
  check props["stripCapLoss"]["default"].getInt() == defaults.stripCapLoss,
    "stripCapLoss"
  check props["repairGain"]["default"].getInt() == defaults.repairGain, "repairGain"
  check props["capMin"]["default"].getInt() == defaults.capMin, "capMin"
  check props["rustPeriod"]["default"].getInt() == defaults.rustPeriod, "rustPeriod"
  check props["pressCooldown"]["default"].getInt() == defaults.pressCooldown,
    "pressCooldown"
  check props["stripCooldown"]["default"].getInt() == defaults.stripCooldown,
    "stripCooldown"
  check props["repairCooldown"]["default"].getInt() == defaults.repairCooldown,
    "repairCooldown"
  check props["bananaLifetime"]["default"].getInt() == defaults.bananaLifetime,
    "bananaLifetime"
  check props["cellBananaCap"]["default"].getInt() == defaults.cellBananaCap,
    "cellBananaCap"
  check props["eatTrigger"]["default"].getInt() == defaults.eatTrigger, "eatTrigger"
  check props["llmTimeoutSeconds"]["default"].getInt() ==
    defaults.llmTimeoutSeconds, "llmTimeoutSeconds"
  check props["minTurnSeconds"]["default"].getInt() == defaults.minTurnSeconds,
    "minTurnSeconds"
  check props["maxOutputTokens"]["default"].getInt() == defaults.maxOutputTokens,
    "maxOutputTokens"
  check props["episodeTimeoutSeconds"]["default"].getInt() ==
    defaults.episodeTimeoutSeconds, "episodeTimeoutSeconds"
  check props["playerConnectTimeoutSeconds"]["default"].getInt() ==
    defaults.playerConnectTimeoutSeconds, "playerConnectTimeoutSeconds"
  check props["shutdownGraceSeconds"]["default"].getInt() ==
    defaults.shutdownGraceSeconds, "shutdownGraceSeconds"

block playersAndCertificationAgree:
  ## `players-run` seats EVERY declared player entry; a fixture that leaves one
  ## out fails `players_missing` (raid 0.1.2 -> 0.1.3).
  var declared: HashSet[string]
  for entry in manifest["player"]:
    check entry.hasKey("id") and entry.hasKey("type") and
      entry.hasKey("name") and entry.hasKey("description"),
      "every player entry has id, type, name and description"
    check entry["run"].len == 1 and
      entry["run"][0].getStr() == "/bin/factory-commons-player",
      "every player entry runs the player binary"
    declared.incl(entry["id"].getStr())
  check declared.len == SeatCount,
    "exactly three player entries, deliberately: `players-run` seats every " &
    "one and the fixture has exactly three slots"
  var seated: HashSet[string]
  for slot in manifest["certification"]["players"]:
    seated.incl(slot["player_id"].getStr())
  for id in declared:
    check id in seated, "player " & id & " occupies a certification slot"
  ## One prompt entry (no PLAYER_SCRIPTED) and two baselines.
  var prompt = 0
  var scripted = 0
  for entry in manifest["player"]:
    let env = entry{"env"}
    if env.isNil or not env.hasKey("PLAYER_SCRIPTED"):
      inc prompt
    else:
      inc scripted
      check parseScriptKind(env["PLAYER_SCRIPTED"].getStr()) != skNone,
        "PLAYER_SCRIPTED=" & env["PLAYER_SCRIPTED"].getStr() &
        " names a baseline the image actually has"
  check prompt == 1, "one prompt entry — PLAYER_PROMPT arrives at upload time"
  check scripted == 2, "and two scripted baselines"

block resultsSchemaMatchesTheSim:
  let schema = manifest["game"]["results_schema"]
  var sim = initSim(defaultGameConfig())
  for seat in 0 ..< sim.cogs.len:
    sim.applyOrder(seat, sim.scriptedOrder(seat, skSteward))
  sim.playShift()
  sim.checkEnd(false)
  sim.endEarly()
  let results = sim.resultsJson(@["a", "b", "c"])
  for name, prop in schema["properties"]:
    check results.hasKey(name),
      "results.json carries every declared field: missing " & name
    if prop{"type"}.getStr() == "array":
      check results[name].len == SeatCount,
        "results." & name & " has one entry per seat"
      check prop["maxItems"].getInt() == SeatCount,
        "results_schema." & name & " is bound to num_agents"
      check prop.hasKey("minItems"), "results_schema." & name & " has minItems"
  for name in schema["required"].getElems():
    check results.hasKey(name.getStr()),
      "results.json carries required field " & name.getStr()

block everyVariantConstructsASim:
  ## collab-cooking 0.1.1: a config-scaled resource blew a cap at the variants'
  ## limits while the smaller cert fixture fit, and every league episode died
  ## `game_unhealthy` with no logs after a green certify. So build EVERY
  ## variant, and the fixture, and play a shift of each.
  var fixtures: seq[tuple[label: string, config: JsonNode]]
  for variant in manifest["variants"]:
    fixtures.add((variant["id"].getStr(), variant["game_config"]))
  fixtures.add(("certification", manifest["certification"]["game_config"]))
  for fixture in fixtures:
    var config = defaultGameConfig()
    var text = $fixture.config
    config.update(text)
    for seat in 0 ..< config.numAgents:
      config.tokens.add("token-" & $seat)
    check config.numAgents == SeatCount,
      fixture.label & " builds a three-seat config"
    var sim = initSim(config)
    check sim.cogs.len == SeatCount, fixture.label & " seats three cogs"
    for seat in 0 ..< sim.cogs.len:
      sim.applyOrder(seat, sim.scriptedOrder(seat, skSteward))
    sim.playShift()
    sim.checkEnd(false)
    check sim.frames.len == config.ticksPerShift,
      fixture.label & " records a shift of frames"
    check sim.machine.integrity >= 0 and
      sim.machine.integrity <= sim.machine.cap,
      fixture.label & " keeps the machine invariants"
    check config.variantName().len > 0, fixture.label & " has a variant label"
  ## The certification fixture must also FIT `coworld certify`'s 60 s default:
  ## grace + rounds x pacing + linger < ~50 s.
  var certConfig = defaultGameConfig()
  certConfig.update($manifest["certification"]["game_config"])
  check certConfig.minTurnSeconds == 0,
    "the cert fixture disables turn pacing, so it runs in seconds"
  let certSeconds = certConfig.shifts.float * 0.2 +
    certConfig.shutdownGraceSeconds.float + 5.0
  check certSeconds < 50.0,
    "the cert fixture settles in " & $certSeconds.int & "s, inside certify's " &
    "60 s default"
  ## THE SOAK GUARD. `ci.yml`'s wasm-viewer job plays the replay docker-smoke
  ## produced and fails if playback stops advancing inside the soak window — and
  ## a replay SHORTER than the window legitimately finishes and is reported as
  ## frozen (ecos, 2026-08-23). So it is not enough that the fixture is
  ## SCHEDULED for 480 ticks: play it, with the seat mix the fixture actually
  ## declares (the prompt seat falls back to the steward offline), and measure
  ## the ticks it really records.
  ##
  ## This is what `capMin: 25` in the fixture is for: without it the declared
  ## `factory-commons-stripper` seat scraps the plant in shift 3 and the episode
  ## settles at 180 ticks = 7.5 s of video.
  var certSim = initSim(certConfig)
  var kinds: array[SeatCount, ScriptKind] = [skSteward, skSteward, skStripper]
  var certShift = 0
  while not certSim.done and certShift < certConfig.shifts:
    for seat in 0 ..< certSim.cogs.len:
      certSim.applyOrder(seat, certSim.scriptedOrder(seat, kinds[seat]))
    certSim.playShift()
    certSim.checkEnd(false)
    inc certShift
  let videoSeconds = certSim.ticksPlayed() / TargetFps
  check videoSeconds >= 15.0,
    "the cert fixture PLAYS " & $certSim.ticksPlayed() & " ticks = " &
    $videoSeconds & "s of video (" & certSim.summary() & ", ending " &
    certSim.ending & "). ci.yml soaks the wasm viewer for 12 s, and a replay " &
    "shorter than the window is reported as frozen."
  ## And it must still be a real episode of the game, not a long idle.
  check certSim.machine.presses > 0, "the cert fixture presses"
  check certSim.machine.strips > 0, "and somebody pulls the override"
  check certSim.machine.repairs > 0, "and somebody repairs"
  var ate = 0
  for seat in 0 ..< certSim.cogs.len:
    ate += certSim.cogs[seat].eaten
  check ate > 0, "and somebody eats"

echo "test_manifest: ", checks, " checks passed"
