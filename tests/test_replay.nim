## End-to-end: play a full scripted episode headless, write `results.json` and
## the replay, then re-read the replay BYTES.
##
## The strict-UTF-8 assertion is the one that matters most. A `say` truncated on
## a BYTE boundary renders fine in a browser and fails a strict parser, which is
## how it reaches production unnoticed (bullwhip, 2026-08-22) — so this test
## feeds a seat multi-byte runes exactly at the caps and then parses the bytes
## with `validateUtf8`.

import std/[json, strutils, tables, unicode]

import factory_commons/[sim, scripted, replays, events, llm, broadcast]

var checks = 0

template check(condition: untyped, message: string) =
  inc checks
  if not (condition):
    echo "FAIL: ", message
    quit(1)

proc baseConfig(shifts = 15): GameConfig =
  result = defaultGameConfig()
  result.shifts = shifts
  result.numAgents = SeatCount
  for seat in 0 ..< SeatCount:
    result.tokens.add("token-" & $seat)
    result.players.add(PlayerConfig(name: "factory-commons-p" & $seat))

proc runScripted(config: GameConfig,
                 kinds: array[SeatCount, ScriptKind]): Sim =
  result = initSim(config)
  while not result.done:
    for seat in 0 ..< result.cogs.len:
      result.applyOrder(seat, result.scriptedOrder(seat, kinds[seat]))
    result.playShift()
    result.checkEnd(false)

proc policyNames(config: GameConfig): seq[string] =
  for player in config.players:
    result.add(player.name)

# ---------------------------------------------------------------- the episode
let
  config = baseConfig()
  episode = runScripted(config, [skSteward, skSteward, skSteward])
  results = episode.resultsJson(config.policyNames())
  replayBytes = buildReplay(episode, config.policyNames(), results)

block resultsShape:
  check results["scores"].len == SeatCount, "results.scores has one entry per seat"
  check results["names"].len == SeatCount, "results.names has one entry per seat"
  for key in ["aliases", "win", "eaten", "banked", "presses", "strips",
              "repairs", "misfeeds", "fallbacks"]:
    check results[key].len == SeatCount, "results." & key & " has 3 entries"
  for seat in 0 ..< SeatCount:
    check results["scores"][seat].getInt() ==
      results["eaten"][seat].getInt() + results["banked"][seat].getInt(),
      "results.scores[i] == eaten[i] + banked[i]"
    check results["names"][seat].getStr() == "factory-commons-p" & $seat,
      "results.names carries the POLICY name, platform side"
    check results["aliases"][seat].getStr() == Aliases[seat],
      "results.aliases carries the in-game alias"
  check results["reason"].getStr() in ["complete", "deadline", "forfeit"],
    "results.reason is one of the three legal values"
  check results["ending"].getStr() in
    ["shift_limit", "factory_ruined", "deadline", "forfeit"],
    "results.ending is legal"
  check results["band_final"].getStr() in
    ["PRIME", "WORN", "FAILING", "CRITICAL", "SEIZED", "SCRAP"],
    "results.band_final is a band word"
  check results["mode_final"].getStr() in ["unset", "cycle", "override"],
    "results.mode_final is a mode word"
  var best = 0
  for seat in 0 ..< SeatCount:
    best = max(best, results["scores"][seat].getInt())
  for seat in 0 ..< SeatCount:
    check results["win"][seat].getBool() ==
      (results["scores"][seat].getInt() == best),
      "win[i] == (scores[i] == max(scores)); ties mark several winners"

block replayBytesAreStrictUtf8:
  ## `validateUtf8` returns -1 for valid UTF-8 and the byte index of the first
  ## invalid sequence otherwise. Nothing else in CI reads the replay this
  ## strictly, and a browser would happily render bytes a strict parser rejects.
  check validateUtf8(replayBytes) == -1,
    "the replay bytes are strict UTF-8 (first bad byte at " &
    $validateUtf8(replayBytes) & ")"
  check replaySizeOk(replayBytes),
    "the replay is under 8 MiB, got " & $replayBytes.len & " bytes"

let doc = parseReplay(replayBytes)

block replayContents:
  check doc.protocol == "factory_commons.replay.v1", "the replay protocol"
  check doc.game == GameName, "the replay names the game"
  check doc.gameVersion == GameVersion, "the replay carries its GameVersion"
  check doc.names.len == SeatCount, "the replay carries three aliases"
  check doc.policyNames.len == SeatCount, "and three policy names"
  check doc.colors.len == SeatCount, "and three body colours"
  for seat in 0 ..< SeatCount:
    check doc.names[seat] == Aliases[seat], "alias " & $seat
    check doc.colors[seat] == SeatColors[seat], "colour " & $seat
  check doc.frames.len == episode.ticksPlayed(),
    "frames.len == ticksPlayed (" & $doc.frames.len & " vs " &
    $episode.ticksPlayed() & ")"
  check doc.series.len == episode.ticksPlayed(),
    "series.machine.len == ticksPlayed"
  for i, frame in doc.frames:
    check frame.t == i, "frame " & $i & " records tick " & $i
    check frame.c.len == SeatCount * 4, "the cog quad array is 4 per seat"
    check frame.u.len mod 3 == 0, "the cube array is triples"
    check frame.b.len mod 3 == 0, "the banana array is triples"
  ## Every event tick inside the played range, and every kind declared.
  validateEvents(doc.events, episode.ticksPlayed())
  let counts = eventCounts(doc.events)
  for kind in ["grasp", "drop", "press", "fix", "eat"]:
    check counts.getOrDefault(kind) > 0,
      "a real episode contains at least one " & kind & " event"
  check counts.getOrDefault("shift") == config.shifts or
    results["ending"].getStr() != "shift_limit",
    "a full episode emits exactly one shift event per shift, got " &
    $counts.getOrDefault("shift")
  check counts.getOrDefault("end") == 1, "exactly one end event"
  check counts.getOrDefault("order") == config.shifts * SeatCount or
    results["ending"].getStr() != "shift_limit",
    "one order event per seat per shift"
  ## Beats: only the five declared kinds, and the gameover beat is last.
  check doc.beats.len > 0, "the replay carries a beat timeline"
  for row in doc.beats:
    var known = false
    for declared in BeatKinds:
      if declared == row{"k"}.getStr():
        known = true
    check known, "beat kind " & row{"k"}.getStr() & " is declared"
  check doc.beats[^1]{"k"}.getStr() == "gameover", "the last beat is gameover"
  ## The config block is self-sufficient: every constant the viewer needs.
  check doc.config.shifts == config.shifts, "the replay pins shifts"
  check doc.config.pressFloor == config.pressFloor, "and the press floor"
  check doc.config.stripCapLoss == config.stripCapLoss, "and the cap loss"
  check doc.variant == config.variantName(), "and the variant label"
  check doc.results{"scores"}.len == SeatCount, "and the whole results object"

block playbackModel:
  ## Every recorded frame must build a HudModel, because the wasm viewer does
  ## exactly that on every displayed frame and a raise there is a blank
  ## theater.
  for index in [0, doc.frames.len div 3, doc.frames.len div 2,
                doc.frames.len - 1]:
    let model = doc.hudFromReplay(index)
    check model.tick == doc.frames[index].t, "the model records its tick"
    check model.seats.len == SeatCount, "the model seats three cogs"
    check model.integrity >= 0 and model.integrity <= model.cap,
      "the model's integrity is inside 0..cap"
    check model.band in ["PRIME", "WORN", "FAILING", "CRITICAL", "SEIZED",
                         "SCRAP"], "the model's band is a band word"
    for seat in model.seats:
      check seat.policy.len > 0, "every seat carries a policy name"
      check seat.alias.len > 0, "and an alias"
      check seat.said.runeLen <= MaxSayLen,
        "every recorded say is inside the rune cap"
  let terminal = doc.hudFromReplay(doc.frames.len - 1)
  check terminal.over, "the terminal frame is marked over"
  check terminal.ending.len > 0, "and carries the ending"
  ## And the chrome frame the viewer reads must parse and carry the contract.
  let frame = parseJson(terminal.buildStateJson(
    newJArray(), true, 1, false, true, doc.series, doc.beatsJson()))
  check frame["teams"].len == 2, "the chrome frame has exactly two plates"
  check frame["roster"].len == SeatCount, "and a roster of three"
  check frame.hasKey("over"), "and an `over` block on the terminal frame"
  check frame["lead"]["pts"].len == doc.series.len,
    "and the whole integrity/cap series"

# ------------------------------------------------- the rune-cap replay case
block fullCapRunesSurviveTheReplay:
  ## A seat is fed a `say` and `notes` of MULTI-BYTE runes exactly at the caps.
  ## Both must come back out of the replay bytes valid and inside the cap.
  var fixtureConfig = baseConfig(shifts = 2)
  var fixture = initSim(fixtureConfig)
  var say = ""
  var notes = ""
  ## Four-byte runes as well as two-byte ones, so a byte cut lands mid-sequence
  ## whichever cap it hits.
  const Palette = ["á", "ç", "ñ", "ö", "þ", "—", "½", "😀"]
  for i in 0 ..< MaxSayLen:
    say.add(Palette[i mod Palette.len])
  for i in 0 ..< MaxNotesLen:
    notes.add(Palette[(i + 3) mod Palette.len])
  check say.runeLen == MaxSayLen, "the fixture say is exactly at the cap"
  check notes.runeLen == MaxNotesLen, "the fixture notes is exactly at the cap"
  check say.len > MaxSayLen, "and it is genuinely multi-byte"

  ## Over the cap by one rune: cleanText must cut on a RUNE boundary.
  let overSay = say & "😀"
  let cleaned = cleanSay(overSay)
  check cleaned.runeLen <= MaxSayLen,
    "an over-cap say is cut to the cap, got " & $cleaned.runeLen & " runes"
  check validateUtf8(cleaned) == -1, "and the cut lands on a rune boundary"
  let cleanedNotes = cleanNotes(notes & "½½½")
  check cleanedNotes.runeLen <= MaxNotesLen, "an over-cap notes is cut too"
  check validateUtf8(cleanedNotes) == -1, "on a rune boundary"

  for _ in 0 ..< fixtureConfig.shifts:
    for seat in 0 ..< fixture.cogs.len:
      var order = fixture.scriptedOrder(seat, skSteward)
      order.say = cleanSay(overSay)
      order.notes = cleanNotes(notes)
      order.source = osLlm
      fixture.applyOrder(seat, order)
    fixture.playShift()
    fixture.checkEnd(false)
  let
    fixtureResults = fixture.resultsJson(fixtureConfig.policyNames())
    fixtureBytes = buildReplay(fixture, fixtureConfig.policyNames(),
      fixtureResults)
  check validateUtf8(fixtureBytes) == -1,
    "a replay carrying full-cap multi-byte strings is still strict UTF-8"
  let fixtureDoc = parseReplay(fixtureBytes)
  var sawSay = 0
  for row in fixtureDoc.events:
    if row{"k"}.getStr() != "order":
      continue
    let recordedSay = row{"say"}.getStr()
    let recordedNotes = row{"notes"}.getStr()
    check validateUtf8(recordedSay) == -1, "the recorded say is valid UTF-8"
    check validateUtf8(recordedNotes) == -1, "the recorded notes is valid UTF-8"
    check recordedSay.runeLen <= MaxSayLen,
      "the recorded say is <= the cap, got " & $recordedSay.runeLen
    check recordedNotes.runeLen <= MaxNotesLen,
      "the recorded notes is <= the cap, got " & $recordedNotes.runeLen
    inc sawSay
  check sawSay == fixtureConfig.shifts * SeatCount,
    "every seat's order was recorded with its strings"

# ------------------------------------------------------- the all-stripper case
block allStripperRuinsTheFactory:
  let ruined = runScripted(baseConfig(), [skStripper, skStripper, skStripper])
  let ruinedResults = ruined.resultsJson(baseConfig().policyNames())
  check ruinedResults["ending"].getStr() == "factory_ruined",
    "an all-stripper episode ends factory_ruined, got " &
    ruinedResults["ending"].getStr() & " (" & ruined.summary() & ")"
  check ruinedResults["reason"].getStr() == "complete",
    "a ruined factory is a COMPLETED game, not an error"
  check ruinedResults["scrapped_by"].getInt() >= 0,
    "and it names the seat whose override crossed the floor"
  check ruinedResults["cap_final"].getInt() < baseConfig().pressFloor,
    "with cap below the press floor"
  let ruinedBytes = buildReplay(ruined, baseConfig().policyNames(),
    ruinedResults)
  check validateUtf8(ruinedBytes) == -1, "and its replay is strict UTF-8"
  let ruinedDoc = parseReplay(ruinedBytes)
  check ruinedDoc.frames.len == ruined.ticksPlayed(),
    "a short episode records exactly the ticks it played"
  var sawScrap = false
  for row in ruinedDoc.beats:
    if row{"k"}.getStr() == "scrap":
      sawScrap = true
  check sawScrap, "and drops a `scrap` scrubber beat"

echo "test_replay: ", checks, " checks passed (",
  replayBytes.len, " replay bytes, ", episode.events.len, " events, ",
  doc.frames.len, " frames)"
