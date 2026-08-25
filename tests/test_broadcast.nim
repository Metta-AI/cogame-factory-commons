## The chrome frame, and the two things about it that have broken viewers
## before: the shape the byte-for-byte `client/chrome_common.js` expects, and a
## SCOPE-DUPLICATION check over that file's alias list.
##
## The scope test is not decoration. A game-block `function markBeat` is HOISTED
## over the chrome alias block's `var markBeat = C.markBeat` and silently kills
## every scrubber beat — every static grep stays green and the markers render as
## unlabelled divs that never seek (tandem, 2026-08-23).

import std/[json, os, sets, strutils, tables]

import factory_commons/[sim, scripted, broadcast, global, replays,
                        wire_constants]

var checks = 0

template check(condition: untyped, message: string) =
  inc checks
  if not (condition):
    echo "FAIL: ", message
    quit(1)

proc repoRoot(): string =
  for candidate in [".", "..", currentSourcePath().parentDir() / ".."]:
    if fileExists(candidate / "client" / "chrome_common.js"):
      return candidate
  ""

let root = repoRoot()
check root.len > 0, "client/chrome_common.js must be findable"

proc baseConfig(shifts = 3): GameConfig =
  result = defaultGameConfig()
  result.shifts = shifts
  result.numAgents = SeatCount
  for seat in 0 ..< SeatCount:
    result.tokens.add("token-" & $seat)
    result.players.add(PlayerConfig(name: "factory-commons-pol" & $seat))

proc policyNames(config: GameConfig): seq[string] =
  for player in config.players:
    result.add(player.name)

let config = baseConfig()
var game = initSim(config)
for _ in 0 ..< config.shifts:
  for seat in 0 ..< game.cogs.len:
    var order = game.scriptedOrder(seat, if seat == 2: skStripper else: skSteward)
    order.say = "hopper 3/1 - somebody repair, we are at " & $game.machine.integrity
    game.applyOrder(seat, order)
  game.playShift()
  game.checkEnd(false)
game.checkEnd(false)
if not game.done:
  game.endEarly()

let
  results = game.resultsJson(config.policyNames())
  replayBytes = buildReplay(game, config.policyNames(), results)
  doc = parseReplay(replayBytes)

proc frameAt(index: int, withLead = false): JsonNode =
  let model = doc.hudFromReplay(index)
  parseJson(model.buildStateJson(
    doc.eventsBetween(-1, doc.frames[index].t),
    playing = true, speed = 1, looping = false, transportEnabled = true,
    leadSeries = (if withLead: doc.series else: @[]),
    beats = (if withLead: doc.beatsJson() else: nil)))

# ---------------------------------------------------------------- the plates
block twoReadoutPlates:
  let frame = frameAt(doc.frames.len div 2)
  var keys: HashSet[string]
  for key, _ in frame["teams"]:
    keys.incl(key)
  check keys.len == 2, "exactly two plates"
  check "machine" in keys and "output" in keys,
    "and they are `machine` and `output` — readouts, not sides"
  ## `activeTeams` in chrome_common.js sorts unknown keys alphabetically, so
  ## `machine` lands on #plates-l and `output` on #plates-r. Pin the ordering
  ## the layout depends on.
  check "machine" < "output",
    "the alphabetical order the chrome sorts by puts machine on the left"
  let machine = frame["teams"]["machine"]
  check machine["policies"].len == 1, "the machine plate has one headline"
  check machine["policies"][0].getStr() == "Factory",
    "and it reads FACTORY through the starter's own teamName path"
  check machine["lives"].getInt() == frame["fc"]["integrity"].getInt(),
    "the plate's big number IS integrity (the re-lettered `Lives` label)"
  check machine["band"].getStr() in
    ["PRIME", "WORN", "FAILING", "CRITICAL", "SEIZED", "SCRAP"],
    "and it carries the band word"
  check machine.hasKey("flag") and machine["carrier"].getInt() == -1,
    "the inherited flag fields are present and inert, so updateFlag stays quiet"
  let output = frame["teams"]["output"]
  check output["policies"][0].getStr() == "Bananas", "the ticker headline"
  check output["lives"].getInt() == frame["fc"]["made"].getInt(),
    "the ticker's big number is the production total"

block rosterCarriesBothNameSpaces:
  let frame = frameAt(doc.frames.len - 1)
  check frame["roster"].len == SeatCount, "three roster entries"
  for seat in 0 ..< SeatCount:
    let entry = frame["roster"][seat]
    check entry["s"].getInt() == seat, "keyed by slot"
    check entry["name"].getStr() == Aliases[seat],
      "`name` is the in-game ALIAS"
    check entry["pol"].getStr() == "factory-commons-pol" & $seat,
      "`pol` is the POLICY name — spectator side only"
    check entry["col"].getStr() == SeatColors[seat], "and the body colour"
    check entry["team"].getStr() notin ["machine", "output"],
      "a cog is on neither readout plate, so the starter's squad-pip strips " &
      "stay empty and the appended roster strip owns the per-seat chrome"
    check entry["score"].getInt() ==
      entry["eaten"].getInt() + entry["banked"].getInt(),
      "score == eaten + banked"
    check entry["say"].getStr().len <= MaxSayLen * 4,
      "and every drawn string is inside its cap"

block leadSeriesShape:
  ## `{"teams":["integrity","cap"], "pts":[[t,i,c], ...]}` is exactly what
  ## `ingestLeadSeries` and `renderMomentum` in chrome_common.js already
  ## normalise, so neither needs a change.
  let frame = frameAt(0, withLead = true)
  check frame.hasKey("lead"), "the first HUD frame ships the lead series"
  check frame["lead"]["teams"].len == 2, "two series"
  check frame["lead"]["teams"][0].getStr() == "integrity", "integrity first"
  check frame["lead"]["teams"][1].getStr() == "cap", "then cap"
  check frame["lead"]["pts"].len == doc.series.len, "and the whole timeline"
  for row in frame["lead"]["pts"]:
    check row.len == 3, "each point is [tick, integrity, cap]"
    check row[1].getInt() <= row[2].getInt(),
      "integrity never exceeds cap, which is what makes the shaded gap the " &
      "permanent loss"
  ## And it ships ONCE.
  let later = frameAt(1)
  check not later.hasKey("lead"), "later frames do not repeat it"

block beatsAreOnlyTheDeclaredKinds:
  let frame = frameAt(0, withLead = true)
  check frame.hasKey("beats"), "the beat timeline ships on the first HUD frame"
  var kinds: HashSet[string]
  for row in frame["beats"]:
    kinds.incl(row{"k"}.getStr())
  for kind in kinds:
    var declared = false
    for known in BeatKinds:
      if known == kind:
        declared = true
    check declared,
      "beat kind `" & kind & "` has CSS in the appended game block — a sixth " &
      "kind would render as an unlabelled div"
  check "shift" in kinds, "shifts are beats"
  check "strip" in kinds, "and so is every override — the who-broke-it marker"
  check "gameover" in kinds, "and the terminal beat"

block terminalFrameCarriesTheVerdict:
  let frame = frameAt(doc.frames.len - 1)
  check frame["ph"].getStr() == "gameover", "the terminal frame is gameover"
  check frame.hasKey("over"),
    "the end card is STATE, so a viewer who seeks straight to the end sees it"
  let over = frame["over"]
  check over["ending"].getStr() in
    ["shift_limit", "factory_ruined", "deadline", "forfeit"],
    "the ending string is legal, got " & over["ending"].getStr()
  check over.hasKey("scrapped_by"), "and names who broke it, or -1"
  check over.hasKey("winner") and over.hasKey("draw"),
    "and carries the two fields chrome_common.js's setVerdict reads"
  check over["winners"].len >= 1, "at least one winner; a tie marks several"

block fcBlockIsComplete:
  let frame = frameAt(doc.frames.len div 3)
  let fc = frame["fc"]
  for key in ["variant", "shift", "shifts", "ticksPerShift", "integrity", "cap",
              "band", "mode", "eitherOr", "pink", "blue", "cooldown",
              "pressYield", "stripYield", "pressLegal", "stripLegal",
              "presses", "strips", "repairs", "made", "rotted", "spoiled",
              "onChute", "scrappedBy", "lastPressTick", "lastStripTick"]:
    check fc.hasKey(key), "the appended game block reads fc." & key
  check fc["cap"].getInt() >= fc["integrity"].getInt(),
    "cap >= integrity, so the gauge's notch is never left of the fill"
  check frame["bs"].getInt() == 1,
    "the board is emitted at its authored 1248x720, so bs is 1"
  check frame["mt"].getInt() == doc.maxTick(),
    "and the tick span is the one the replay actually recorded — a replay is " &
    "not a schedule, and the scrubber's axis has to match the frames it has"

# ------------------------------------------------------ scope duplication
block noGameBlockNameCollidesWithTheChromeAliases:
  ## chrome_common.js returns an object whose keys the page aliases into its own
  ## scope (`var markBeat = C.markBeat`). A game-block FUNCTION DECLARATION of
  ## any of those names is hoisted over the alias and silently wins.
  let
    chrome = readFile(root / "client" / "chrome_common.js")
    page = readFile(root / "client" / "replay_broadcast.html")
  ## The alias list, read out of the page's own alias block rather than
  ## hand-copied, so it cannot go stale.
  const Banner = "factory-commons additions to the inherited coworld-ctf chrome"
  ## `rfind`, not `find`: the banner appears twice — once over the appended CSS
  ## and once over the appended script — and it is the SCRIPT one that divides
  ## inherited scope from ours.
  let bannerAt = page.rfind(Banner)
  check bannerAt > 0, "the appended game block carries its banner comment"
  check page.find(Banner) < bannerAt,
    "and it appears over the appended CSS as well as the appended script"
  ## Everything before the banner is inherited; everything after is ours.
  let
    inherited = page[0 ..< bannerAt]
    appended = page[bannerAt .. ^1]
  var aliases: HashSet[string]
  for line in inherited.splitLines():
    let text = line.strip()
    if not text.startsWith("var ") or " = C." notin text:
      continue
    for part in text[4 .. ^1].split(','):
      let piece = part.strip()
      let eq = piece.find(" = C.")
      if eq > 0:
        aliases.incl(piece[0 ..< eq].strip())
  check aliases.len >= 20,
    "the alias list was found in the page (got " & $aliases.len & " names)"
  check "markBeat" in aliases, "and markBeat is one of them"
  ## No appended `function <alias>(` anywhere.
  for name in aliases:
    check ("function " & name & "(") notin appended,
      "the game block must not DECLARE " & name & " — the declaration is " &
      "hoisted over `var " & name & " = C." & name & "` and silently wins. " &
      "Rename it (the beat builder is buildFactoryBeats for exactly this " &
      "reason)."
  ## And the one the trap is named after is present under its safe name.
  check "function buildFactoryBeats(" in appended,
    "the game block's beat builder is buildFactoryBeats"
  check "markBeat(" in appended,
    "and it CALLS the chrome's markBeat rather than replacing it"
  ## The chrome file itself is untouched: it must still export every alias.
  for name in aliases:
    check (name & ":") in chrome or ("function " & name & "(") in chrome,
      "chrome_common.js still exports " & name

block chromeCommonIsByteForByte:
  ## The one file that must not change at all. Its own wire-constants global is
  ## why `window.CTF_WIRE` keeps that name.
  let chrome = readFile(root / "client" / "chrome_common.js")
  check "window.CTF_WIRE" in chrome, "chrome_common.js reads window.CTF_WIRE"
  check "window.CTF_WIRE" in WireConstantsJs,
    "and wire_constants.nim emits exactly that global"
  check "factory_commons" notin chrome,
    "nothing in chrome_common.js was renamed for this game"
  check WireConstantsJs.startsWith("window.CTF_WIRE={"),
    "the emitted block starts with the global the Dockerfile greps for"
  check ("chromeSpriteId:" & $BroadcastChromeSpriteId) in WireConstantsJs,
    "and states the chrome sprite id the client keys on"

# ------------------------------------------------------ sprite ids
block spriteIdsDoNotCollide:
  ## Two families sharing a sprite id is a silent clobber: the later definition
  ## wins and the earlier family draws the wrong art.
  var seen: HashSet[int]
  for id in spriteIdsInUse():
    check id notin seen, "sprite id " & $id & " is used twice"
    seen.incl(id)
  check BroadcastChromeSpriteId in seen, "the chrome sprite is accounted for"
  for band in 0 ..< bandCount():
    check (MapBandSpriteBase + band) in seen, "band " & $band & " is accounted for"
    ## The static-band OBJECT pool the client caches is ids 40..99 on layer 0
    ## at z = -32768; the bands must fit it.
    check MapBandObjectBase + band <= 99,
      "band object " & $band & " is inside the client's static-band window"
  check bandCount() == 4, "720 rows of board is four 192px bands"

block artIsTheRightSizeForTheRenderer:
  ## The renderer's offsets assume these sizes; a resized asset would silently
  ## draw a machine off its own block.
  let art = artInventory()
  check art["aiFloor"] == [CellPx, CellPx], "the floor tile is one cell"
  check art["aiWallH"] == [CellPx, CellPx], "and so is a wall panel"
  check art["aiMachinePrime"] == [CellPx * 5, CellPx * 5],
    "the machine art covers the whole 5x5 block"
  for state in ["aiMachineWorn", "aiMachineFailing", "aiMachineScrap"]:
    check art[state] == art["aiMachinePrime"],
      state & " is the same size as the prime state"
  check art["aiConsole"] == [CellPx * 3, CellPx], "the console pad is three cells"
  check art["aiChute"] == [CellPx * 3, CellPx], "and so is the chute"
  check art["aiBay"] == [CellPx, CellPx * 3], "the bay is one cell by three"
  check art["aiCogRedFront"][1] == CellPx,
    "a cog is one cell tall, anchored at the feet"
  check art["aiCogRedFront"][0] < CellPx, "and narrower than its cell"
  check art["aiCubePink"] == art["aiCubeBlue"],
    "both cube colours are the same size"
  check art["aiPressFlash"] == art["aiMachinePrime"],
    "the effect plates cover the machine exactly"

echo "test_broadcast: ", checks, " checks passed"
