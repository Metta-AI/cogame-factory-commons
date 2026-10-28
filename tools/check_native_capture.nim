## Reconstruct an ordinary native episode without any network/provider client.
## Usage: check_native_capture CONFIG TRAJECTORY REPLAY OPERATOR_PROMPT
import std/[base64, json, os, strutils]
import crunchy
import bitworld/spriteprotocol
import factory_commons/[sim, scripted, llm, prompts, native_capture, replays, global]

let args = commandLineParams()
if args == @["--identity-guard"]:
  let game = initSim(defaultGameConfig())
  const fields = ["COWORLD_EPISODE_ID", "COWORLD_GAME_VERSION", "COWORLD_SOURCE_REVISION", "COWORLD_GAME_NAME"]
  for field in fields: putEnv(field, "local-constructor-fixture")
  putEnv("COGAME_SAVE_TRAJECTORY_URI", "file:///tmp/factory-identity-fixture-private.jsonl")
  for field in fields:
    for invalid in ["\xed\xb0\x80", "\x80"]:
      putEnv(field, invalid)
      doAssert newRuntimeCapture(game, "file:///tmp/factory-identity-fixture-results.json", "file:///tmp/factory-identity-fixture-replay.json") == nil
      putEnv(field, "local-constructor-fixture")
  doAssert newRuntimeCapture(game, "file:///tmp/factory-identity-fixture-results.json", "file:///tmp/factory-identity-fixture-replay.json") != nil
  echo "all eight invalid identity cases refused; valid control accepted; zero writes/network/game ticks"
  quit(0)
if args == @["--destination-alias"]:
  let game = initSim(defaultGameConfig())
  putEnv("COWORLD_EPISODE_ID", "local-alias-fixture")
  putEnv("COWORLD_GAME_VERSION", "local-alias-fixture")
  putEnv("COWORLD_SOURCE_REVISION", "local-alias-fixture")
  for pair in [("file:///tmp/factory-private-alias/./results.json", "file:///tmp/factory-private-alias/results.json"),
      ("http://127.0.0.1:9/shared?local=private", "http://127.0.0.1:9/shared?local=public"),
      ("http://127.0.0.1:9/a/%2e%2e/shared", "http://127.0.0.1:9/shared")]:
    putEnv("COGAME_SAVE_TRAJECTORY_URI", pair[0])
    doAssert newRuntimeCapture(game, pair[1], "file:///tmp/separate-replay.json") == nil
  echo "all three private/public destination aliases refused before any write or network"
  quit(0)
if args.len == 2 and args[0] == "--viewer":
  let raw = readFile(args[1])
  var bytes: seq[uint8]
  for character in raw: bytes.add(uint8(character))
  let messages = parseSpritePacket(bytes)
  doAssert messages.len > 0
  var chrome = false
  for message in messages:
    if message.kind == spkSprite and message.sprite.id == BroadcastChromeSpriteId:
      let frame = parseJson(message.sprite.label)
      doAssert frame.hasKey("fc") and frame["fc"]["variant"].kind == JString
      chrome = true
  doAssert chrome, "viewer packet lacks contract-valid factory chrome"
  echo "valid native Sprite packet and factory chrome"
  quit(0)
doAssert args.len == 4
let configNode = parseFile(args[0])
var config = defaultGameConfig()
config.update($configNode)
let selection = promptSelection(configNode)
var game = initSim(config)
let ids = identities(game)
let replay = parseFile(args[2])
var rows: seq[JsonNode]
var summary: JsonNode
for line in lines(args[1]):
  var row = parseJson(line)
  if row["event_type"].getStr() == "decision":
    if row["observation"].hasKey("invalid_native_evidence_json_b64"):
      doAssert row["selected_attempt_id"].kind == JNull and row["executed_action"].kind == JNull
      doAssert row["attempts"].len == 0 and row["action_status"].getStr() in ["rejected", "fallback"]
      let original = parseJson(decode(row["observation"]["invalid_native_evidence_json_b64"].getStr()))
      row["observation"] = original["observation"]
      row["attempts"] = original["attempts"]
      row["executed_action"] = original["executed_action"]
      # Reconstruction of native play never promotes this forensic row to a label.
    rows.add(row)
  else: summary = row
var promptsChecked, orderCount, tickCount, blockedStrip = 0
var uniquePromptViews = newJArray()
for shift in 0 ..< config.shifts:
  if game.done: break
  let frozen = game
  var orders: seq[Order]
  var current: seq[JsonNode]
  var startEvents = game.events.len
  let startFrame = game.frames.len
  for seat in 0 ..< config.numAgents:
    let row = rows[orderCount]
    inc orderCount
    current.add(row)
    doAssert row["seat"].getStr() == $seat
    doAssert row["decision_id"].getStr() == $(shift + 1) & "-" & $seat
    let observation = row["observation"]
    var view = copy(observation)
    for field in ["scenario_family", "task_identity", "prompt_selection",
        "pre_native_sha256", "native_parsed_proposals", "native_requests",
        "native_execution", "capture_errors"]:
      if view.hasKey(field): view.delete(field)
    doAssert view == frozen.observationJson(seat), "native view or frozen simultaneous order differs"
    doAssert observation["pre_native_sha256"].getStr() == frozen.nativeStateHash()
    doAssert observation["prompt_selection"] == selection.selectionMetadata()
    doAssert observation["scenario_family"].getStr() == ids.family
    doAssert observation["task_identity"].getStr() == ids.task
    var order: Order
    var parsed = false
    for attemptIndex, attempt in row["attempts"].getElems():
      let request = attempt["request"]
      doAssert request.kind == JObject
      let system = frozen.systemPrompt(seat, selection)
      var user = frozen.userPrompt(seat, args[3])
      if attemptIndex > 0:
        user.add("\nYour previous reply was invalid. Respond with ONLY the " &
          "requested JSON object, using one of the listed job and cube values.")
      doAssert request["system"].getStr() == system
      doAssert request["messages"] == %*[{"role": "user", "content": user}]
      doAssert request["max_tokens"].getInt() == config.maxOutputTokens
      inc promptsChecked
      var responseText = ""
      if attempt["response"].kind == JString:
        responseText = attempt["response"].getStr()
      elif attempt["response_body_b64"].kind == JString and
          attempt["http_status"].getInt() in 200 .. 299:
        # Native decoder can accept non-scalar text. Reconstruct from retained
        # bytes for execution verification only; the forensic row stays excluded.
        let response = parseJson(decode(attempt["response_body_b64"].getStr()))
        for part in response{"content"}:
          if part{"type"}.getStr() == "text": responseText.add(part{"text"}.getStr())
      if responseText.len > 0:
        try:
          order = parseOrder(extractJsonObject(responseText))
          order.source = if attemptIndex == 0: osLlm else: osRetry
          parsed = true
        except CatchableError: discard
    let execution = observation["native_execution"]
    let origin = execution["origin"].getStr()
    if origin == "external":
      order = parseOrder(row["executed_action"])
      order.source = osLlm
      parsed = true # Explicit external authority; never a selected model target.
      doAssert row["selected_attempt_id"].kind == JNull and row["attempts"].len == 0
    elif origin != "model":
      order = frozen.scriptedOrder(seat, parseScriptKind(origin))
      parsed = true
      doAssert row["attempts"].len == 0
    if row["action_status"].getStr() == "fallback":
      order = frozen.scriptedOrder(seat, skSteward)
      order.source = osFallback
      parsed = true
    doAssert parsed, "no native parsed proposal or actual baseline origin"
    doAssert nativeOrderJson(order) == row["executed_action"]
    doAssert $order.source == execution["standing_order_source"].getStr()
    orders.add(order)
    uniquePromptViews.add(view)
    if order.job == jStrip and frozen.config.eitherOr and frozen.machine.mode == mCycle:
      inc blockedStrip
  for seat, order in orders:
    game.applyOrder(seat, order)
  var hashes: seq[string]
  for _ in 0 ..< config.ticksPerShift:
    game.stepTick()
    hashes.add(game.nativeStateHash())
    inc tickCount
  game.closeShift()
  game.checkEnd(false)
  var events: seq[JsonNode]
  for index in startEvents ..< game.events.len: events.add(game.events[index])
  var frames = newJArray()
  for index in startFrame ..< game.frames.len: frames.add(game.frames[index].frameJson())
  for seat, row in current:
    let execution = row["observation"]["native_execution"]
    # Latency is actual wall telemetry; it never changes simulator state.
    let recorded = execution["events"]
    var expected = seatEvents(events, seat)
    for index in 0 ..< expected.len:
      if expected[index].hasKey("latencyMs"):
        expected[index]["latencyMs"] = recorded[index]["latencyMs"]
    doAssert expected == recorded, "native installed order/events differ"
    doAssert execution["events_sha256"].getStr() == sha256($recorded).toHex.toLowerAscii()
    doAssert execution["frames"] == frames, "actual native tick frames differ"
    doAssert execution["tick_state_sha256"] == %hashes
    doAssert execution["post_native_sha256"].getStr() == game.nativeStateHash()
    doAssert execution["start_tick"].getInt() == startFrame
    doAssert execution["end_tick"].getInt() == game.tick

doAssert game.done and game.reason == "complete"
doAssert orderCount == rows.len and game.tick == config.shifts * config.ticksPerShift
var frames = newJArray()
for frame in game.frames: frames.add(frame.frameJson())
doAssert frames == replay["frames"]
var events = newJArray()
for event in game.events: events.add(copy(event))
for index in 0 ..< events.len:
  if events[index].hasKey("latencyMs"):
    events[index]["latencyMs"] = replay["events"][index]["latencyMs"]
doAssert events == replay["events"], "full native replay events differ"
var names: seq[string]
for name in replay["policyNames"]: names.add(name.getStr())
let results = game.resultsJson(names)
var outcome = copy(summary["outcome"])
if outcome.hasKey("capture_errors"): outcome.delete("capture_errors")
doAssert outcome == results and replay["results"] == results
let initial = initSim(config)
var alias = config
inc alias.seed
alias.model = "unused-label-identity-audit"
inc alias.minTurnSeconds
for player in alias.players.mitems: player.name = "unused display label"
doAssert identities(initSim(alias)) == ids
var variants = newJArray()
for node in parseFile("coworld_manifest_template.json")["variants"]:
  var variant = defaultGameConfig()
  variant.update($node["game_config"])
  let identity = identities(initSim(variant))
  doAssert identity.family == ids.family, "same physical root must remain grouped"
  variants.add(%*{"variant": node["id"], "family": identity.family, "condition": identity.task})
var after = initial
after.stepTick()
var refused = false
try: discard identities(after)
except ValueError: refused = true
doAssert refused, "family binding after history must fail closed"
echo pretty(%*{"complete_episode": true, "ticks": tickCount, "decisions": orderCount,
  "native_prompt_requests": promptsChecked, "all_frozen_views_prompts_applied_orders_ticks_events_frames_outcome_verified": true,
  "same_physical_root_all_variants_and_seed_policy_clock_aliases": true,
  "conservative_physical_root": ids.family, "causal_conditions": variants,
  "installed_strip_orders_while_cycle_locked": blockedStrip,
  "real_provider_calls": 0, "teacher_targets": 0})
