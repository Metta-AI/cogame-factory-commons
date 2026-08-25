## The game server: the Coworld game contract, the shift loop, the player
## protocol and the shutdown order.
##
## Forked from `coworld-ctf/src/ctf/server.nim` for the route/artifact/shutdown
## skeleton — hosted certification probes exactly these routes, in this order,
## BEFORE the player pods start (lantern, 2026-08-23) — with bullwhip's JSON
## player protocol in place of paintbot's binary one.
##
## Routes:
##   GET /healthz                  liveness, from process start until
##                                 `shutdownGraceSeconds` after the artifacts
##   GET /client/player?slot&token  the seat's HTML shell; it NEVER opens the
##                                 player socket
##   WS  /player?slot&token         the seat socket; a bad token is refused with
##                                 a close, never a hang
##   GET /client/global             the broadcast client, embedded and spliced
##   WS  /global                    live spectator: the sprite protocol plus the
##                                 chrome JSON on the same binary channel
##
## `factory_commons.player.v1`, all JSON text frames:
##   game -> player: welcome / state (every shift boundary and at the end) /
##                   final, after which the player exits 0
##   player -> game: {"type":"prompt","prompt":"<= 4000 chars",
##                    "scripted":"steward|stripper|freerider|"}

import
  std/[json, locks, os, sets, strutils, tables, times, unicode],
  bitworld/runtime,
  bitworld/spriteprotocol,
  curly,
  mummy,
  mummy/routers,
  ./sim, ./scripted, ./llm, ./broadcast, ./global, ./replays, ./wire_constants

const
  BroadcastEveryTicks = 6
    ## The live spectator gets a frame every sixth tick. The static replay is
    ## the product; `/global` exists so certification's WebSocket ping is
    ## answered and a human can watch a hosted episode land.
  PlayBudgetFraction* = 0.6
    ## Share of the platform's episode timeout spent playing. The rest covers
    ## container start, player connects and writing the artifacts — the part
    ## that must never be the thing that runs out of time.

  GlobalPage = staticRead("../../client/replay_broadcast.html")
  ChromeCommonJs = staticRead("../../client/chrome_common.js")
  BroadcastCoreJs = staticRead("../../client/broadcast_core.js")
  ChromeCommonMarker = "<!-- CHROME_COMMON -->"
  BroadcastCoreMarker = "<!-- BROADCAST_CORE -->"

  PlayerPage = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<title>Factory Commons — seat</title>
<style>
  html,body{margin:0;height:100%;background:#120d0a;color:#f2e8d8;
    font:14px/1.5 ui-monospace,Menlo,Consolas,monospace}
  main{max-width:44rem;margin:0 auto;padding:2rem}
  h1{font-size:1.1rem;letter-spacing:.14em;text-transform:uppercase;
    color:#e8a33d;margin:0 0 1rem}
  code{background:#1e1611;padding:.1rem .3rem;color:#ddc531}
  p{margin:.6rem 0}
</style></head><body><main>
<h1>Factory Commons — seat view</h1>
<p>Three cogs, one machine. The cycle press pays the whole room; the override
lever pays only you and breaks the machine forever.</p>
<p>A policy here <strong>is a prompt</strong>. This page is informational only:
it never opens the player socket. Decisions are made in the game container,
which asks every seat's prompt at each shift boundary as one parallel batch.</p>
<p>Field your own policy by reusing this image and setting
<code>PLAYER_PROMPT</code>, or play a baseline with
<code>PLAYER_SCRIPTED=steward|stripper|freerider</code>.</p>
<p>The spectator board is at <code>/client/global</code>; the replay is a static
wasm bundle, never a pod.</p>
</main></body></html>
"""

type
  GameState = object
    config: GameConfig
    sim: Sim
    prompts: seq[string]
    scripted: seq[ScriptKind]
    playerSockets: Table[int, WebSocket]
    socketSlots: Table[WebSocket, int]
    globalSockets: HashSet[WebSocket]
    viewerStates: Table[WebSocket, GlobalViewerState]
    started: bool
    finished: bool
    servingAfterEnd: bool

var
  stateLock: Lock
  state: GameState
  gameServer: Server
  runtimeConfigGlobal: RuntimeConfig

initLock(stateLock)

proc policyNames(gs: GameState): seq[string] =
  ## Seats play under anonymous cog aliases; the POLICY names ride alongside for
  ## the spectator views and `results.names` only. Both name spaces, never
  ## either.
  for player in gs.config.players:
    result.add(player.name)

proc hudModel(gs: GameState): HudModel =
  let
    sim = gs.sim
    band = sim.band()
  result.tick = max(0, sim.tick - 1)
  result.maxTick = sim.config.maxTicks()
  result.startTick = 0
  result.shift = sim.shift
  result.shifts = sim.config.shifts
  result.ticksPerShift = sim.config.ticksPerShift
  result.integrity = sim.machine.integrity
  result.cap = sim.machine.cap
  result.band = $band
  result.mode = modeText(sim.machine.mode)
  result.variant = sim.config.variantName()
  result.eitherOr = sim.config.eitherOr
  result.pink = sim.machine.pink
  result.blue = sim.machine.blue
  result.cooldown = sim.machine.cooldown
  result.pressYield = band.publicYield()
  result.stripYield = band.privateYield()
  result.pressLegal = sim.machine.cap >= sim.config.pressFloor and
    sim.machine.integrity >= sim.config.pressFloor and
    sim.config.modeAllows(sim.machine.mode, true)
  result.stripLegal = sim.machine.cap >= sim.config.pressFloor and
    sim.machine.integrity >= sim.config.stripFloor and
    sim.config.modeAllows(sim.machine.mode, false)
  result.presses = sim.machine.presses
  result.strips = sim.machine.strips
  result.repairs = sim.machine.repairs
  result.bananasMade = sim.machine.bananasMade
  result.bananasRotted = sim.machine.bananasRotted
  result.bananasSpoiled = sim.machine.bananasSpoiled
  result.scrappedBy = sim.machine.scrappedBy
  result.cubes = sim.cubes
  result.bananas = sim.bananas
  result.beltLen = sim.config.beltLen
  result.showLabels = sim.config.showPlayerLabels
  result.reason = sim.reason
  result.ending = sim.ending
  result.over = sim.done
  result.lastPressTick = -1
  result.lastStripTick = -1
  for cell in chuteCells():
    result.onChute += sim.bananasAt(cell[0], cell[1])
  let names = gs.policyNames()
  for seat in 0 ..< sim.cogs.len:
    let cog = sim.cogs[seat]
    result.seats.add(SeatHud(
      slot: seat,
      alias: Aliases[seat],
      policy: (if seat < names.len and names[seat].len > 0: names[seat]
               else: Aliases[seat]),
      color: SeatColors[seat],
      x: cog.x, y: cog.y, carrying: cog.carrying,
      score: sim.score(seat), eaten: cog.eaten, banked: cog.banked,
      presses: cog.presses, strips: cog.strips, repairs: cog.repairs,
      misfeeds: cog.misfeeds, fallbacks: cog.fallbacks,
      said: cog.said, job: $cog.order.job, cube: $cog.order.cube,
      source: $cog.order.source
    ))
  for row in sim.events:
    let kind = row{"k"}.getStr()
    if kind == "press":
      result.lastPressTick = row{"t"}.getInt()
    elif kind == "strip":
      result.lastStripTick = row{"t"}.getInt()

proc eventsSince(gs: GameState, fromTick: int): JsonNode =
  result = newJArray()
  for row in gs.sim.events:
    if row{"t"}.getInt(-1) > fromTick:
      result.add(row)

proc beatsJson(gs: GameState): JsonNode =
  result = newJArray()
  for row in gs.sim.beats:
    result.add(row)

var lastBroadcastTick = -1

proc broadcastLocked(gs: var GameState) =
  ## Callers hold stateLock. One packet per spectator, because each carries its
  ## own one-shot payloads (sprites, bands, the lead series, the beats).
  if gs.globalSockets.len == 0:
    lastBroadcastTick = max(0, gs.sim.tick - 1)
    return
  let
    model = gs.hudModel()
    events = gs.eventsSince(lastBroadcastTick)
    beats = gs.beatsJson()
  var sockets: seq[WebSocket]
  for socket in gs.globalSockets:
    sockets.add(socket)
  for socket in sockets:
    var current = gs.viewerStates.getOrDefault(socket, initGlobalViewerState())
    var nextState: GlobalViewerState
    let packet = buildViewerPacket(
      model, gs.config, current, nextState, events,
      playing = not gs.sim.done, speed = 1, looping = false,
      transportEnabled = false,
      leadSeries = gs.sim.series, beats = beats)
    gs.viewerStates[socket] = nextState
    for chunk in chunkSpritePacket(packet, MaxWsFrameBytes):
      socket.send(blobFromBytes(chunk), BinaryMessage)
  lastBroadcastTick = max(0, gs.sim.tick - 1)

proc sendPlayerStates(gs: GameState) =
  for slot, socket in gs.playerSockets:
    if slot < gs.sim.cogs.len:
      socket.send($gs.sim.observationJson(slot))

proc writeArtifact(uri, data, contentType, methodEnv: string) =
  ## Writes a Coworld artifact, honouring the platform's PUT/POST method hint.
  if uri.len == 0:
    return
  let httpMethod = getEnv(methodEnv, "PUT").toUpperAscii()
  if uri.isHttpCogameUri() and httpMethod == "POST":
    let curl = newCurly()
    var headers: HttpHeaders
    headers["content-type"] = contentType
    let response = curl.post(uri, headers, data, 60)
    if response.code < 200 or response.code >= 300:
      raise newException(IOError, "artifact POST failed: " & $response.code)
  else:
    writeCogameUri(uri, data, contentType, methodEnv)

proc finishEpisode(runtimeConfig: RuntimeConfig) =
  ## Shutdown, in this order: `final` to every player socket, the last global
  ## frame, a 500 ms flush, `results.json`, the replay, then `/healthz` and
  ## `/global` stay answering for `shutdownGraceSeconds` before `quit(0)`.
  ## Hosted certification pings the global websocket AFTER the player pods
  ## start, and a short episode would otherwise already be gone (lantern).
  var
    results: JsonNode
    replayData: string
    grace = 20
  withLock stateLock:
    if state.finished:
      return
    state.finished = true
    grace = state.config.shutdownGraceSeconds
    results = state.sim.resultsJson(state.policyNames())
    replayData = buildReplay(state.sim, state.policyNames(), results)

    ## The final frame goes to the PLAYER sockets, so it carries the aliases —
    ## `results.names` carries the policy names for the platform.
    var aliasNames = newJArray()
    for seat in 0 ..< state.sim.cogs.len:
      aliasNames.add(%Aliases[seat])
    var final = %*{
      "type": "final",
      "done": true,
      "scores": results["scores"],
      "names": aliasNames,
      "shifts": results["shifts"],
      "reason": results["reason"],
      "ending": results["ending"]
    }
    ## The last observation, then the final frame: a seat sees the state it
    ## ended in before it is told the episode is over.
    state.sendPlayerStates()
    for slot, socket in state.playerSockets:
      final["slot"] = %slot
      socket.send($final)
    state.broadcastLocked()

  sleep(500)
  log "writing results and replay"
  writeArtifact(runtimeConfig.resultsUri, $results, "application/json",
    "COGAME_RESULTS_METHOD")
  writeArtifact(runtimeConfig.replayUri, replayData, "application/json",
    "COGAME_SAVE_REPLAY_METHOD")
  log "artifacts written (" & $replayData.len & " replay bytes); serving " &
    $grace & "s of shutdown grace"
  withLock stateLock:
    state.servingAfterEnd = true
  sleep(grace * 1000)
  log "episode complete, shutting down"
  quit(0)

proc runGame(runtimeConfig: RuntimeConfig) {.gcsafe.} =
  {.gcsafe.}:
    let
      config = state.config
      gameStart = epochTime()
      connectDeadline = gameStart + config.playerConnectTimeoutSeconds.float
    var anyConnected = false
    while epochTime() < connectDeadline:
      var allConnected = false
      withLock stateLock:
        allConnected = state.playerSockets.len >= config.numAgents
        anyConnected = anyConnected or state.playerSockets.len > 0
      if allConnected:
        break
      sleep(200)

    withLock stateLock:
      state.started = true
      anyConnected = anyConnected or state.playerSockets.len > 0
      log "starting with " & $state.playerSockets.len & "/" &
        $config.numAgents & " seats connected"
      state.broadcastLocked()

    if not anyConnected:
      ## Nobody arrived inside the connect timeout. Results AND the replay are
      ## still written, every score zero, so the episode is a record rather
      ## than a hole.
      log "no seat connected within " &
        $config.playerConnectTimeoutSeconds & "s; forfeiting"
      withLock stateLock:
        state.sim.forfeit()
      finishEpisode(runtimeConfig)
      return

    let client = newLlmClient(config)

    ## The platform kills an episode that outruns its timeout and keeps
    ## NOTHING, so play inside a fraction of it. The hosted dispatcher hands
    ## the timeout only to its own worker sidecar, never to the game container,
    ## so when the env is silent assume the configured platform default rather
    ## than playing open-ended.
    let hostedTimeout = getEnv("COWORLD_TIMEOUT_SECONDS", "").strip()
    var timeoutSeconds =
      if hostedTimeout.len > 0:
        try: parseFloat(hostedTimeout) except ValueError: 0.0
      else: 0.0
    if timeoutSeconds <= 0.0:
      timeoutSeconds = config.episodeTimeoutSeconds.float
    let playDeadline =
      if timeoutSeconds > 0.0: gameStart + timeoutSeconds * PlayBudgetFraction
      else: 0.0
    if playDeadline > 0.0:
      log "episode timeout " & $timeoutSeconds.int & "s (" &
        (if hostedTimeout.len > 0: "from env" else: "assumed") &
        "); the last shift must START by " &
        $(timeoutSeconds * PlayBudgetFraction -
          (config.shiftBudgetSeconds() + config.settleBudgetSeconds()).float).int &
        "s so the episode SETTLES by " &
        $(timeoutSeconds * PlayBudgetFraction).int & "s"

    while true:
      var
        simCopy: Sim
        seats: seq[int]
        prompts: seq[string]
        scripted: seq[ScriptKind]
      withLock stateLock:
        if state.sim.done:
          break
        if not config.shiftFitsBeforeDeadline(epochTime(), playDeadline):
          log "play deadline reached after " & $state.sim.shift & "/" &
            $config.shifts & " shifts (a shift needs " &
            $config.shiftBudgetSeconds() & "s and settling " &
            $config.settleBudgetSeconds() & "s); ending early"
          state.sim.endEarly()
          state.broadcastLocked()
          break
        for seat in 0 ..< state.sim.cogs.len:
          seats.add(seat)
        simCopy = state.sim
        prompts = state.prompts
        scripted = state.scripted
        ## A seat that never connected, or whose socket died, plays the steward
        ## for every remaining shift — the episode never blocks on a socket.
        for seat in seats:
          if not state.playerSockets.hasKey(seat) and
              scripted[seat] == skNone:
            scripted[seat] = skSteward
        log "shift " & $(state.sim.shift + 1) & " of " & $config.shifts &
          " at " & $(epochTime() - gameStart).int & "s"

      ## The slow part (Claude, ONE parallel batch for the whole shift) runs
      ## outside the lock on a snapshot; only this thread mutates the sim, so
      ## the snapshot cannot go stale.
      let batchStart = epochTime()
      let orders = client.decideAll(simCopy, seats, prompts, scripted)
      let batchSeconds = epochTime() - batchStart

      withLock stateLock:
        for index, seat in seats:
          var order = orders[index]
          order.latencyMs = int(batchSeconds * 1000.0)
          log "shift " & $(state.sim.shift + 1) & " " & Aliases[seat] &
            " -> " & $order.job & " " & $order.cube & " (" & $order.source &
            ")" & (if order.say.len > 0: " says \"" & order.say & "\"" else: "")
          state.sim.applyOrder(seat, order)
        ## The tick loop, with a spectator frame every few ticks.
        for _ in 0 ..< config.ticksPerShift:
          state.sim.stepTick()
          if state.sim.tick mod BroadcastEveryTicks == 0:
            state.broadcastLocked()
        state.sim.closeShift()
        state.sim.checkEnd(false)
        state.sendPlayerStates()
        state.broadcastLocked()

      ## Floor the spacing between batch STARTS so the episode cannot exceed
      ## the Bedrock sidecar's 30 rpm per-episode ceiling.
      let pacing = config.turnPacingSleepMs(epochTime() - batchStart)
      if pacing > 0:
        sleep(pacing)

    finishEpisode(runtimeConfig)

var gameThread: Thread[RuntimeConfig]

proc healthzHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "application/json"
  request.respond(200, headers, """{"ok": true}""")

proc globalPageHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    var headers: HttpHeaders
    headers["Content-Type"] = "text/html; charset=utf-8"
    var page = spliceWireConstants(GlobalPage)
    page = page.replace(ChromeCommonMarker,
      "<script>" & ChromeCommonJs & "</script>")
    page = page.replace(BroadcastCoreMarker,
      "<script>" & BroadcastCoreJs & "</script>")
    request.respond(200, headers, page)

proc playerPageHandler(request: Request) {.gcsafe.} =
  var headers: HttpHeaders
  headers["Content-Type"] = "text/html; charset=utf-8"
  request.respond(200, headers, PlayerPage)

proc playerUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let
      slotText = request.queryParams["slot"]
      token = request.queryParams["token"]
    var slot = -1
    try:
      slot = parseInt(slotText)
    except ValueError:
      discard
    var authorized = false
    withLock stateLock:
      authorized = slot >= 0 and slot < state.config.tokens.len and
        state.config.tokens[slot] == token
    if not authorized:
      ## A bad token is refused outright — never a hang.
      request.respond(401)
      return
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.playerSockets[slot] = websocket
      state.socketSlots[websocket] = slot
      if slot < state.sim.connected.len:
        state.sim.connected[slot] = true
      log "seat " & $slot & " (" & Aliases[slot] & ") connected (" &
        $state.playerSockets.len & "/" & $state.config.numAgents & ")"
      websocket.send($ %*{
        "type": "welcome",
        "protocol": ProtocolPlayer,
        "slot": slot,
        "name": Aliases[slot],
        "shifts": state.config.shifts,
        "ticksPerShift": state.config.ticksPerShift,
        "variant": state.config.variantName(),
        "numAgents": state.config.numAgents
      })

proc globalUpgradeHandler(request: Request) {.gcsafe.} =
  {.gcsafe.}:
    let websocket = request.upgradeToWebSocket()
    withLock stateLock:
      state.globalSockets.incl(websocket)
      state.viewerStates[websocket] = initGlobalViewerState()
      state.broadcastLocked()

proc websocketHandler(
  websocket: WebSocket,
  event: WebSocketEvent,
  message: Message
) {.gcsafe.} =
  {.gcsafe.}:
    case event
    of OpenEvent:
      discard
    of MessageEvent:
      ## mummy hands Ping frames to the application instead of answering them
      ## itself, and the platform's certifier pings /global to check the game is
      ## alive — an unanswered ping fails certification.
      if message.kind == Ping:
        websocket.send(message.data, Pong)
        return
      if message.kind == BinaryMessage:
        withLock stateLock:
          if websocket in state.globalSockets:
            var viewer = state.viewerStates.getOrDefault(
              websocket, initGlobalViewerState())
            viewer.applyGlobalViewerMessage(message.data)
            ## Live play has no transport: seeks and speed changes belong to
            ## the recorded replay, so they are accepted and ignored here.
            viewer.replaySeekTick = -1
            viewer.replayCommands = @[]
            state.viewerStates[websocket] = viewer
        return
      if message.kind != TextMessage:
        return
      var slot = -1
      withLock stateLock:
        slot = state.socketSlots.getOrDefault(websocket, -1)
      if slot < 0:
        return
      try:
        let payload = parseJson(message.data)
        if payload{"type"}.getStr() != "prompt":
          log "ignoring player frame of type " & payload{"type"}.getStr()
          return
        var prompt = payload{"prompt"}.getStr()
        if prompt.runeLen > MaxPromptLen:
          prompt = prompt.runeSubStr(0, MaxPromptLen)
        let node = payload{"scripted"}
        let kind =
          if node.isNil: skNone
          elif node.kind == JBool: (if node.getBool(): skSteward else: skNone)
          else: parseScriptKind(node.getStr())
        withLock stateLock:
          state.prompts[slot] = prompt
          state.scripted[slot] = kind
        log "seat " & $slot & " delivered a prompt (" & $prompt.len &
          " chars" & (if kind != skNone: ", scripted " & $kind else: "") & ")"
      except CatchableError as error:
        log "ignoring bad player frame: " & cleanError(error.msg)
    of ErrorEvent:
      discard
    of CloseEvent:
      withLock stateLock:
        if websocket in state.socketSlots:
          let slot = state.socketSlots[websocket]
          state.socketSlots.del(websocket)
          if state.playerSockets.getOrDefault(slot) == websocket:
            state.playerSockets.del(slot)
        state.globalSockets.excl(websocket)
        state.viewerStates.del(websocket)

proc buildRouter(): Router =
  ## Both `/client/` routes are registered BEFORE any catch-all asset route:
  ## the episode runner probes `/healthz`, `GET /client/player`, a bad-token
  ## player websocket and `GET /client/global` before starting player pods, and
  ## a 404 on any of them is a `game_contract_violation`.
  result.get("/healthz", healthzHandler)
  result.get("/client/global", globalPageHandler)
  result.get("/client/player", playerPageHandler)
  result.get("/global", globalUpgradeHandler)
  result.get("/player", playerUpgradeHandler)

proc runGameServer*(config: GameConfig, runtimeConfig: RuntimeConfig) =
  if config.tokens.len < config.numAgents:
    raise newException(FactoryError,
      "config declares " & $config.numAgents & " seats but only " &
      $config.tokens.len & " tokens")
  state.config = config
  state.sim = initSim(config)
  state.prompts = newSeq[string](config.numAgents)
  state.scripted = newSeq[ScriptKind](config.numAgents)
  runtimeConfigGlobal = runtimeConfig

  let router = buildRouter()
  gameServer = newServer(router, websocketHandler)
  createThread(gameThread, runGame, runtimeConfig)
  log "serving on " & runtimeConfig.host & ":" & $runtimeConfig.port
  gameServer.serve(Port(runtimeConfig.port), runtimeConfig.host)
