import
  std/json,
  factory_commons/[broadcast, global, replays, sim]

## The static replay-viewer wasm entry.
##
## Same structure as `coworld-ctf/replay-viewer/ctf_replay.nim`: `stampStage`,
## a load/advance/input triple, packet and error accessors, and the
## `emscripten_exit_with_live_runtime()` epilogue.
##
## `ctf_mismatch_tick` is DROPPED. Factory Commons records STATE, not inputs, so
## playback never re-simulates and there is no hash to mismatch — which is also
## why `#mmwarn` is gone from the page.

var
  runtimeLoaded = false
  doc: ReplayDoc
  viewer: GlobalViewerState
  tracker: BroadcastTracker
  packet: seq[uint8]
  lastError: string

  frameIndex = 0
  playing = true
  speedIndex = 0
    ## Index into PlaybackSpeeds, or ReplayHalfSpeedIndex (-1) for the
    ## replay-only 1/2x speed (one frame every other presentation frame).
  halfPhase = false
    ## Frame parity while at 1/2x speed: the playhead advances only on the
    ## odd frames, toggled once per frame() call.
  looping = false

## --- Progress stage note ---
## wasm32 has no memory protection: when emscripten's malloc fails, a write
## through the nil pointer lands at address 0 and silently corrupts the
## module's own globals instead of trapping. The bundle is therefore linked
## with -s ABORTING_MALLOC=1 — allocation failure aborts the runtime loudly —
## and this fixed buffer, stamped BEFORE each risky phase, stays readable from
## JS after the abort (aborting kills the call stack, not the linear memory),
## so the page can still report what the runtime was doing.
var
  stageNote: array[192, char]
  stageNoteLen: int
  currentStage: string
  frameStage: string

proc stampStage(stage: string) =
  currentStage = stage
  stageNoteLen = min(stage.len, stageNote.len)
  if stageNoteLen > 0:
    copyMem(stageNote[0].addr, stage[0].unsafeAddr, stageNoteLen)

proc bytesFromPointer(data: ptr uint8, length: int): string =
  result = newString(length)
  if length > 0:
    copyMem(result[0].addr, data, length)

proc renderCurrent(events: JsonNode) =
  var nextViewer: GlobalViewerState
  let model = doc.hudFromReplay(frameIndex)
  packet = buildViewerPacket(
    model, doc.config, viewer, nextViewer, events,
    playing = playing,
    speed = replayDisplaySpeed(speedIndex),
    looping = looping,
    transportEnabled = true,
    leadSeries = doc.series,
    beats = doc.beatsJson()
  )
  viewer = nextViewer

proc loadReplay(data: ptr uint8, length: cint): cint
    {.exportc: "factory_commons_load_replay", cdecl.} =
  try:
    lastError = ""
    stampStage("parse replay")
    doc = parseReplay(data.bytesFromPointer(int(length)))
    stampStage("initialize playback")
    viewer = initGlobalViewerState()
    tracker = initBroadcastTracker()
    frameIndex = 0
    playing = true
    speedIndex = 0
    halfPhase = false
    looping = false
    runtimeLoaded = true
    let note = " (" & $doc.frames.len & " frames, " & $doc.events.len &
      " events)"
    frameStage = "advance replay" & note
    stampStage("render first frame" & note)
    ## THIS packet is the only one that carries the one-shot payloads — the
    ## sprite pixels, the four static board bands, the integrity/cap series and
    ## the whole beat timeline. Read it directly; never re-derive it by asking
    ## for frame 0 again (matrix-games, 2026-08-24).
    renderCurrent(newJArray())
    return 1
  except Exception as error:
    runtimeLoaded = false
    lastError = currentStage & ": " & error.msg & "\n" & error.getStackTrace()
    return 0

proc input(data: ptr uint8, length: cint)
    {.exportc: "factory_commons_input", cdecl.} =
  if runtimeLoaded:
    viewer.applyGlobalViewerMessage(data.bytesFromPointer(int(length)))

proc applyCommands() =
  ## The transport vocabulary the inherited chrome sends: space toggles play,
  ## `,` restarts, `.` skips five seconds, `b` steps back, `e` jumps to the end,
  ## `r` loops, and the digits pick a playback speed.
  for command in viewer.replayCommands:
    if command.len == 0:
      continue
    case command[0]
    of ' ': playing = not playing
    of ',': frameIndex = 0
    of '.': frameIndex = min(doc.frames.len - 1, frameIndex + TargetFps * 5)
    of 'b': frameIndex = max(0, frameIndex - 1)
    of 'e': frameIndex = doc.frames.len - 1
    of 'r': looping = not looping
    of 'f': discard          ## no lull spans: every shift is a beat
    of '1', '2', '3', '4', '5', '8', '6', '+', '=', '-', '_':
      applySpeedCommand(speedIndex, command[0])
    else: discard
  viewer.replayCommands = @[]

proc frame(): cint {.exportc: "factory_commons_frame", cdecl.} =
  if not runtimeLoaded:
    return 0
  stampStage(frameStage)
  halfPhase = not halfPhase
  try:
    let previous = frameIndex
    var seeked = false
    if viewer.replaySeekTick >= 0:
      frameIndex = doc.frameIndexFor(viewer.replaySeekTick)
      viewer.replaySeekTick = -1
      seeked = true
    let beforeCommands = frameIndex
    applyCommands()
    if frameIndex != beforeCommands:
      seeked = true
    if playing and not seeked:
      # At 1/2x (ReplayHalfSpeedIndex) the budget is one frame every OTHER
      # presentation frame; otherwise it is the integer speed.
      frameIndex += replayStepBudget(speedIndex, halfPhase)
      if frameIndex > doc.frames.len - 1:
        if looping:
          frameIndex = 0
          seeked = true
        else:
          frameIndex = doc.frames.len - 1
          playing = false
    if seeked:
      tracker.resync()
    ## Events are handed to the chrome only for a forward step, so a seek
    ## cannot replay a banner the viewer already watched (and a backward scrub
    ## cannot fire one in reverse).
    let events =
      if seeked or frameIndex <= previous: newJArray()
      else: doc.eventsBetween(doc.frames[previous].t, doc.frames[frameIndex].t)
    renderCurrent(events)
    return 1
  except Exception as error:
    lastError = "advance replay: " & error.msg & "\n" & error.getStackTrace()
    return -1

proc packetPointer(): ptr uint8
    {.exportc: "factory_commons_packet_ptr", cdecl.} =
  if packet.len == 0:
    nil
  else:
    packet[0].addr

proc packetLength(): cint {.exportc: "factory_commons_packet_len", cdecl.} =
  cint(packet.len)

proc errorPointer(): ptr uint8
    {.exportc: "factory_commons_error_ptr", cdecl.} =
  if lastError.len == 0:
    nil
  else:
    cast[ptr uint8](lastError[0].addr)

proc errorLength(): cint {.exportc: "factory_commons_error_len", cdecl.} =
  cint(lastError.len)

proc stagePointer(): ptr uint8
    {.exportc: "factory_commons_stage_ptr", cdecl.} =
  ## The progress note. Unlike the error buffer this stays valid after an
  ## allocation-failure abort, so JS can report what the runtime was doing.
  if stageNoteLen == 0:
    nil
  else:
    cast[ptr uint8](stageNote[0].addr)

proc stageLength(): cint {.exportc: "factory_commons_stage_len", cdecl.} =
  cint(stageNoteLen)

when defined(emscripten):
  proc emscriptenExitWithLiveRuntime() {.
    importc: "emscripten_exit_with_live_runtime", cdecl.}

when isMainModule and defined(emscripten):
  # Nim's generated main runs every module-global destructor when it returns,
  # freeing the parsed replay, the art images and the packet buffer — while the
  # wasm module stays alive and JS keeps calling in. The whole session would
  # then run on freed globals. Unwinding main through emscripten's live-runtime
  # exit skips the destructor epilogue entirely, so globals stay valid for the
  # life of the page.
  emscriptenExitWithLiveRuntime()
