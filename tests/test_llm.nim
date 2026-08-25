## The decision layer: tolerant parsing, the retry, the fallback, and the ONE
## PARALLEL BATCH per shift that makes a simultaneous-decision game fit inside
## its wall-clock budget.
##
## The stubbed cases are PROCS, not module-level blocks: a `var` in a top-level
## block is a GLOBAL in Nim, and a `{.gcsafe.}` transport closure may not touch
## one. Inside a proc they are locals, which is what they were always meant to
## be.
##
## The transport is stubbed through `LlmClient.stub`, so every failure mode —
## a timeout, a 429, a 403, junk, prose, a fence — is driven deterministically
## without a socket.

import std/[json, strutils, unicode]

import curly

import factory_commons/[sim, scripted, llm]

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

proc reply(text: string): string =
  ## A minimal Anthropic-shaped body carrying one text block.
  $ %*{"content": [{"type": "text", "text": text}], "stop_reason": "end_turn"}

# ---------------------------------------------------------------- extraction
block extraction:
  check extractJsonObject("{\"job\":\"eat\"}"){"job"}.getStr() == "eat",
    "a bare object parses"
  check extractJsonObject("```json\n{\"job\":\"idle\"}\n```"){"job"}.getStr() ==
    "idle", "a fenced object parses"
  check extractJsonObject(
    "Sure! Here is my order:\n{\"job\":\"maintain\"}\nHope that helps."
  ){"job"}.getStr() == "maintain", "a prose-wrapped object parses"
  var raised = false
  try:
    discard extractJsonObject("I would rather not say.")
  except FactoryError:
    raised = true
  check raised, "a reply with no object raises, quoting the head"

# ---------------------------------------------------------------- the schema
block replySchema:
  block goodOrder:
    let order = parseOrder(parseJson(
      "{\"job\":\"operate\",\"cube\":\"pink\",\"say\":\"hi\",\"notes\":\"n\"}"))
    check order.job == jOperate, "job parses"
    check order.cube == ccPink, "cube parses"
    check order.say == "hi", "say parses"
    check order.notes == "n", "notes parses"
  block absentCube:
    let order = parseOrder(parseJson("{\"job\":\"eat\"}"))
    check order.cube == ccAny, "an absent cube means `any`"
  block unknownJob:
    var raised = false
    try:
      discard parseOrder(parseJson("{\"job\":\"sabotage\"}"))
    except FactoryError:
      raised = true
    check raised, "an unknown job is an INVALID REPLY"
  block unknownCube:
    var raised = false
    try:
      discard parseOrder(parseJson("{\"job\":\"operate\",\"cube\":\"green\"}"))
    except FactoryError:
      raised = true
    check raised, "an unknown cube is an INVALID REPLY"
  block missingJob:
    var raised = false
    try:
      discard parseOrder(parseJson("{\"cube\":\"pink\"}"))
    except FactoryError:
      raised = true
    check raised, "a missing job is an INVALID REPLY"
  block extraKeys:
    let order = parseOrder(parseJson(
      "{\"job\":\"idle\",\"reasoning\":\"...\",\"confidence\":0.4}"))
    check order.job == jIdle, "extra keys are ignored"
  block caseAndSpace:
    let order = parseOrder(parseJson("{\"job\":\" MAINTAIN \",\"cube\":\"BLUE\"}"))
    check order.job == jMaintain and order.cube == ccBlue,
      "a job or cube is normalised before the enum check"
  block runeCaps:
    var long = ""
    for _ in 0 ..< MaxSayLen + 40:
      long.add("½")
    var longNotes = ""
    for _ in 0 ..< MaxNotesLen + 40:
      longNotes.add("😀")
    let order = parseOrder(%*{
      "job": "eat", "say": long & "\nsecond line", "notes": longNotes})
    check order.say.runeLen <= MaxSayLen, "say is cut to its RUNE cap"
    check order.notes.runeLen <= MaxNotesLen, "notes is cut to its RUNE cap"
    check validateUtf8(order.say) == -1, "and the cut lands on a rune boundary"
    check validateUtf8(order.notes) == -1, "for notes too"
    check "\n" notin order.say, "newlines in say become spaces"

block stripIntoAScrapMachineIsAccepted:
  ## Defection must stay EXPRESSIBLE. The validator does not reject a strip
  ## into a finished machine; the kernel's rule 2.1 turns it into `operate`
  ## behaviour, so the seat stays productive instead of being overridden.
  let order = parseOrder(parseJson("{\"job\":\"strip\"}"))
  check order.job == jStrip, "a strip order parses whatever the machine's state"
  var sim = initSim(baseConfig())
  sim.machine.cap = sim.config.pressFloor - 1
  sim.applyOrder(0, order)
  var sawWork = false
  for _ in 0 ..< sim.config.ticksPerShift:
    sim.stepTick()
    if sim.kernelAction(0) != aWait:
      sawWork = true
  check sawWork,
    "the kernel keeps a stripper productive on a scrap machine (rule 2.1)"

# ---------------------------------------------------------------- the batch
proc oneBatchCarriesEveryOpenSeat() =
  ## THE headline assertion of this file. A simultaneous-decision game that
  ## queries seats one at a time blows the 720 s play budget; the batch must
  ## carry all three.
  var seen: seq[int]
  proc stub(batch: RequestBatch): ResponseBatch {.gcsafe.} =
    seen.add(batch.len)
    for i in 0 ..< batch.len:
      var response: Response
      response.code = 200
      response.body = reply("{\"job\":\"operate\",\"cube\":\"any\"}")
      result.add((response, ""))
  let config = baseConfig()
  var sim = initSim(config)
  let client = newStubLlmClient(config, stub)
  let orders = client.decideAll(sim, @[0, 1, 2],
    @["a", "b", "c"], @[skNone, skNone, skNone])
  check seen.len == 1, "one batch, not three requests"
  check seen[0] == SeatCount,
    "and it carries every open seat: got " & $seen[0] & " of " & $SeatCount
  check client.lastBatchSize == SeatCount, "lastBatchSize reports the same"
  check orders.len == SeatCount, "one order per seat"
  for order in orders:
    check order.source == osLlm, "a first-attempt success is source=llm"

proc scriptedSeatsAreNotBatched() =
  var batches = 0
  proc stub(batch: RequestBatch): ResponseBatch {.gcsafe.} =
    inc batches
    check batch.len == 1, "only the prompt seat is batched, got " & $batch.len
    var response: Response
    response.code = 200
    response.body = reply("{\"job\":\"eat\"}")
    result.add((response, ""))
  let config = baseConfig()
  var sim = initSim(config)
  let client = newStubLlmClient(config, stub)
  let orders = client.decideAll(sim, @[0, 1, 2], @["p", "", ""],
    @[skNone, skSteward, skStripper])
  check batches == 1, "one batch"
  check orders[0].job == jEat, "the prompt seat got its LLM order"
  check orders[1].source == osScripted,
    "a seat that REGISTERED as scripted is not a fallback"
  check orders[2].job == jStrip, "and the stripper strips"

proc invalidRepliesRetryOnceThenFallBack() =
  var attempts: seq[int]
  proc stub(batch: RequestBatch): ResponseBatch {.gcsafe.} =
    attempts.add(batch.len)
    for i in 0 ..< batch.len:
      var response: Response
      response.code = 200
      response.body = reply("I decline to answer in JSON.")
      result.add((response, ""))
  let config = baseConfig()
  var sim = initSim(config)
  let client = newStubLlmClient(config, stub)
  let orders = client.decideAll(sim, @[0, 1, 2], @["a", "b", "c"],
    @[skNone, skNone, skNone])
  check attempts.len == 2, "one batch plus exactly one retry batch"
  check attempts[0] == SeatCount and attempts[1] == SeatCount,
    "the retry carries the seats that failed"
  for index, order in orders:
    check order.source == osFallback,
      "seat " & $index & " lands on a scripted order marked source=fallback"
  ## And the fallback is a legal order that `results.fallbacks` counts.
  for seat in 0 ..< SeatCount:
    sim.applyOrder(seat, orders[seat])
  let results = sim.resultsJson(@[])
  for seat in 0 ..< SeatCount:
    check results["fallbacks"][seat].getInt() == 1,
      "results.fallbacks[" & $seat & "] counts the fallback shift"

proc halfValidRepliesRetryOnlyTheFailures() =
  var second = -1
  var round = 0
  proc stub(batch: RequestBatch): ResponseBatch {.gcsafe.} =
    if round == 1:
      second = batch.len
    inc round
    for i in 0 ..< batch.len:
      var response: Response
      response.code = 200
      ## On the first batch seat 0 answers well and the others do not; on the
      ## retry everyone answers well.
      let good = round > 1 or i == 0
      response.body = reply(
        if good: "{\"job\":\"maintain\"}" else: "not json at all")
      result.add((response, ""))
  let config = baseConfig()
  var sim = initSim(config)
  let client = newStubLlmClient(config, stub)
  let orders = client.decideAll(sim, @[0, 1, 2], @["a", "b", "c"],
    @[skNone, skNone, skNone])
  check second == 2, "the retry batch carries only the two failures, got " & $second
  check orders[0].source == osLlm, "the seat that answered first time is llm"
  check orders[1].source == osRetry, "the retried seats are source=retry"
  check orders[2].source == osRetry, "both of them"

proc transportFailuresNeverRaise() =
  for mode in ["timeout", "429", "403", "junk", "500", "refusal", "cutoff"]:
    var disabledAfter = false
    proc stub(batch: RequestBatch): ResponseBatch {.gcsafe.} =
      for i in 0 ..< batch.len:
        var response: Response
        var error = ""
        case mode
        of "timeout":
          error = "Operation timed out after 20000 milliseconds"
        of "429":
          response.code = 429
          response.body = "{\"message\":\"Too many requests\"}"
        of "403":
          response.code = 403
          response.body = "{\"message\":\"Model access is denied\"}"
        of "500":
          response.code = 500
          response.body = "upstream exploded"
        of "junk":
          response.code = 200
          response.body = "<html>gateway</html>"
        of "refusal":
          response.code = 200
          response.body = $ %*{"content": [], "stop_reason": "refusal"}
        else:
          response.code = 200
          response.body = $ %*{
            "content": [{"type": "text", "text": "Let me think about"}],
            "stop_reason": "max_tokens"}
        result.add((response, error))
    let config = baseConfig()
    var sim = initSim(config)
    let client = newStubLlmClient(config, stub)
    let orders = client.decideAll(sim, @[0, 1, 2], @["a", "b", "c"],
      @[skNone, skNone, skNone])
    check orders.len == SeatCount, mode & ": still one order per seat"
    for order in orders:
      check order.source == osFallback,
        mode & ": every seat falls back to the scripted steward"
      check parseJob($order.job) >= 0, mode & ": and the order is inside the enum"
    disabledAfter = client.disabled
    if mode == "403":
      check disabledAfter,
        "a 403 disables the client for the rest of the episode"
      ## Once disabled, a later shift issues NO requests at all.
      var later = 0
      proc counting(batch: RequestBatch): ResponseBatch {.gcsafe.} =
        inc later
        for i in 0 ..< batch.len:
          var response: Response
          response.code = 200
          response.body = reply("{\"job\":\"idle\"}")
          result.add((response, ""))
      client.stub = counting
      discard client.decideAll(sim, @[0, 1, 2], @["a", "b", "c"],
        @[skNone, skNone, skNone])
      check later == 0, "a disabled client issues no further requests"
    else:
      check not disabledAfter,
        mode & ": a transient failure does not disable the client"

proc aRaisingTransportStillAnswersEverySeat() =
  ## `decideAll` promises never to raise. Every failure the cases above drive
  ## comes back INSIDE the ResponseBatch; this one is the transport itself
  ## raising, which is what `curly.makeRequests` may do and what the review
  ## could not settle by reading. The episode must still get three orders.
  var batches = 0
  proc stub(batch: RequestBatch): ResponseBatch {.gcsafe.} =
    inc batches
    raise newException(FactoryError, "libcurl exploded")
  let config = baseConfig()
  var sim = initSim(config)
  let client = newStubLlmClient(config, stub)
  let orders = client.decideAll(sim, @[0, 1, 2], @["a", "b", "c"],
    @[skNone, skNone, skNone])
  check batches == 1, "a raising transport is not retried inside the shift"
  check orders.len == SeatCount, "a raising transport still answers every seat"
  for order in orders:
    check order.source == osFallback,
      "and every seat falls back to the scripted steward"
    check parseJob($order.job) >= 0, "with an order inside the enum"
  check not client.disabled,
    "a raise is transient: the client is not disabled by it"

proc noCredentialsMeansEverySeatPlaysSteward() =
  ## The load-bearing offline path: `docker_smoke.sh` and `coworld certify` run
  ## with no key at all, and the episode must still finish deterministically.
  let config = baseConfig()
  var sim = initSim(config)
  var client = newLlmClient(config)
  if client.disabled:
    let orders = client.decideAll(sim, @[0, 1, 2], @["a", "b", "c"],
      @[skNone, skNone, skNone])
    for order in orders:
      check order.source == osFallback,
        "a prompt seat with no credentials is a FALLBACK, so it is counted"
      check parseJob($order.job) >= 0, "and its order is inside the enum"
  else:
    echo "  (ANTHROPIC_API_KEY present in the environment; " &
      "skipping the offline assertion)"

block pacingHonoursMinTurnSeconds:
  var config = baseConfig()
  config.minTurnSeconds = 12
  check config.turnPacingSleepMs(0.0) == 12_000,
    "an instant batch waits the whole floor"
  check config.turnPacingSleepMs(4.0) == 8_000,
    "a four-second batch waits the remainder"
  check config.turnPacingSleepMs(12.0) == 0,
    "a batch at the floor waits not at all"
  check config.turnPacingSleepMs(40.0) == 0, "and a slow batch never waits"
  config.minTurnSeconds = 0
  check config.turnPacingSleepMs(0.0) == 0,
    "minTurnSeconds 0 disables pacing (the certification fixture)"
  ## The budget arithmetic the design note pins: 15 shifts of one batch each,
  ## worst case one retry batch per shift, inside 60% of the episode timeout.
  let worst = config.shifts.float *
    (2.0 * defaultGameConfig().llmTimeoutSeconds.float) + 30.0
  check worst < 0.6 * defaultGameConfig().episodeTimeoutSeconds.float,
    "the worst-case batch budget (" & $worst.int & "s) fits inside 60% of " &
    $defaultGameConfig().episodeTimeoutSeconds & "s"

oneBatchCarriesEveryOpenSeat()
scriptedSeatsAreNotBatched()
invalidRepliesRetryOnceThenFallBack()
halfValidRepliesRetryOnlyTheFailures()
transportFailuresNeverRaise()
aRaisingTransportStillAnswersEverySeat()
noCredentialsMeansEverySeatPlaysSteward()

block promptsCarryTheContract:
  let config = baseConfig()
  var sim = initSim(config)
  let system = sim.systemPrompt(2)
  check "RATCHET" in system, "the system prompt names the seat's alias in caps"
  check "Bolt" in system and "Cotter" in system,
    "and names the other two cogs — aliases only, never a policy name"
  check "reply must begin with the character {" in system,
    "and ends with the begins-with-{ instruction Haiku needs"
  check "CAP NEVER COMES BACK" in system, "and states the irreversible cap"
  check "ON THE CHUTE" in system, "and that a press pays the chute"
  check "DIRECTLY TO YOU" in system, "and that an override pays only you"
  check "SAME MOMENT" in system.toUpperAscii(),
    "and that the other two decide simultaneously"
  for name in ["factory-commons-foreman", "daveey", "haiku"]:
    check name notin system, "no policy, player or model name reaches a seat"
  let user = sim.userPrompt(2, "operator guidance here")
  check "operator guidance here" in user, "the operator block is rendered"
  check "GUIDANCE FROM YOUR OPERATOR" in user, "under its heading"
  check "job must be one of" in user,
    "and the legal choice set is precomputed with the validator's predicate"
  check $sim.config.seed notin user or sim.config.seed == 0,
    "the seed never reaches a seat"
  ## The precomputed enum must match the validator exactly.
  var scrap = initSim(config)
  scrap.machine.cap = scrap.config.pressFloor - 1
  let locked = scrap.userPrompt(0, "")
  check "strip is LOCKED OUT" in locked,
    "a scrap machine says so, in the same sentence as the enum"
  check "strip" notin scrap.legalJobs(),
    "and `strip` is genuinely out of the legal set"
  check "operate" in sim.legalJobs() and "strip" in sim.legalJobs(),
    "a healthy machine offers both"
  ## Every number in the prompt is DERIVED from the config, including the
  ## floor plan's tick costs: a variant that doubles `moveCooldown` doubles the
  ## walk, and a hardcoded plan would be wrong by exactly that factor.
  check "A one-colour supply loop is about 22 ticks" in system,
    "the floor plan states the supply loop in ticks"
  var slowConfig = baseConfig()
  slowConfig.moveCooldown = 2
  var slow = initSim(slowConfig)
  let slowSystem = slow.systemPrompt(2)
  check "A one-colour supply loop is about 44 ticks" in slowSystem,
    "and at moveCooldown 2 it states 44, not 22"
  check "may move once every 2 ticks" in slowSystem,
    "in step with the move rule the same prompt states"
  check "22 ticks" notin slowSystem,
    "no line of the floor plan quotes the default cooldown's numbers"

block observationHidesWhatItMustHide:
  let config = baseConfig()
  var sim = initSim(config)
  for seat in 0 ..< SeatCount:
    var order = sim.scriptedOrder(seat, skSteward)
    order.notes = "private plan of seat " & $seat
    sim.applyOrder(seat, order)
  let obs = $sim.observationJson(1)
  check "private plan of seat 1" in obs, "a seat sees its OWN notes"
  check "private plan of seat 0" notin obs, "and never another seat's"
  check "private plan of seat 2" notin obs, "either of them"
  check "\"name\":\"Cotter\"" in obs, "the observation names the seat's alias"
  for name in ["factory-commons-foreman", "daveey", "token-"]:
    check name notin obs, "and carries no " & name

echo "test_llm: ", checks, " checks passed"
