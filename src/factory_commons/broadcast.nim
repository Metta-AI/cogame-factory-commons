## The broadcast chrome frame: the JSON the viewer reads to draw the scorebug,
## the roster strip, the feed, the banners, the transport and the end card.
##
## Forked from `coworld-ctf/src/ctf/broadcast.nim`. `BroadcastTracker` and
## `buildStateJson` keep their shape and every field name the starter's
## `client/chrome_common.js` reads, because that file ships BYTE-FOR-BYTE:
##
##   * `teams` becomes the two spectator readout plates, `machine` and
##     `output` — not sides. `activeTeams` sorts unknown keys alphabetically,
##     so `machine` lands on `#plates-l` and `output` on `#plates-r`.
##   * `roster` is the three cogs. `name` is the ALIAS and `pol` the POLICY
##     name: two name spaces, both present, and the policy name reaches the
##     roster strip and nothing else.
##   * `lead` is the integrity/cap series — `{"teams":["integrity","cap"],
##     "pts":[[t,i,c], …]}` — which is exactly the shape `ingestLeadSeries`
##     and `renderMomentum` already expect, so neither needs a change.
##
## Everything Factory Commons adds rides under one `fc` key, so the starter's
## own fields stay untouched and a diff against paintbot reads clean.

import std/[json, strutils]

import ./sim_types, ./machine

type
  SeatHud* = object
    slot*: int
    alias*, policy*, color*: string
    x*, y*, carrying*: int
    score*, eaten*, banked*: int
    presses*, strips*, repairs*, misfeeds*, fallbacks*: int
    said*, job*, cube*, source*: string

  HudModel* = object
    ## Everything the chrome frame needs, filled either from the live sim
    ## (`server.nim`) or from the recorded frames (`factory_commons_replay.nim`).
    ## One model means the live spectator view and the replay cannot drift.
    tick*, maxTick*, startTick*: int
    shift*, shifts*, ticksPerShift*: int
    integrity*, cap*: int
    band*, mode*, variant*: string
    eitherOr*: bool
    pink*, blue*, cooldown*: int
    pressYield*, stripYield*: int
    pressLegal*, stripLegal*: bool
    presses*, strips*, repairs*: int
    bananasMade*, bananasRotted*, bananasSpoiled*: int
    onChute*, scrappedBy*: int
    seats*: seq[SeatHud]
    cubes*: seq[LooseCube]
    bananas*: seq[Banana]
    beltLen*: int
    showLabels*: bool
    reason*, ending*: string
    over*: bool
    lastPressTick*, lastStripTick*: int

  BroadcastTracker* = object
    ## Per-viewer snapshot: which one-shot payloads (the lead series, the beat
    ## timeline) have already been sent. They ship ONCE, on the first HUD
    ## frame, so the scrubber and the momentum strip are complete before
    ## playback starts.
    initialized*: bool
    leadSent*: bool
    beatsSent*: bool

proc initBroadcastTracker*(): BroadcastTracker =
  BroadcastTracker(initialized: true)

proc resync*(tracker: var BroadcastTracker) =
  ## After a seek/loop: nothing to re-diff (Factory Commons records state, not
  ## inputs, so there are no phantom beats to guard against), but keep the
  ## named seam paintbot's chrome path goes through.
  tracker.initialized = true

proc plateJson(headline: string, big: int, extra: JsonNode): JsonNode =
  ## One readout plate in the starter's own team shape. `policies` is the
  ## headline path `teamName` reads; `lives` is the plate's big number;
  ## `flag`/`carrier`/`prog` keep `updateFlag` quiet.
  result = %*{
    "lives": big,
    "flag": "home",
    "carrier": -1,
    "prog": 0,
    "policies": [headline]
  }
  if not extra.isNil:
    for key, value in extra:
      result[key] = value

proc seatJson(seat: SeatHud): JsonNode =
  %*{
    "s": seat.slot,
    # Not `machine`/`output`: the cogs are not on either readout plate, so the
    # starter's squad-pip strips stay empty and the appended roster strip owns
    # the per-seat chrome.
    "team": "cog",
    "name": seat.alias,
    "pol": seat.policy,
    "col": seat.color,
    "alive": true,
    "lives": 0,
    "hp": 100,
    "carry": seat.carrying >= 0,
    "k": seat.presses,
    "d": seat.strips,
    "cap": seat.repairs,
    "x": seat.x,
    "y": seat.y,
    "carrying": (if seat.carrying < 0: newJNull()
                 else: %cubeText(Cube(seat.carrying))),
    "score": seat.score,
    "eaten": seat.eaten,
    "banked": seat.banked,
    "presses": seat.presses,
    "strips": seat.strips,
    "repairs": seat.repairs,
    "misfeeds": seat.misfeeds,
    "fallbacks": seat.fallbacks,
    "say": seat.said,
    "job": seat.job,
    "cube": seat.cube,
    "source": seat.source
  }

proc buildStateJson*(
  model: HudModel,
  events: JsonNode,
  playing: bool,
  speed: float,
  looping: bool,
  transportEnabled: bool,
  leadSeries: seq[array[3, int]] = @[],
  beats: JsonNode = nil
): string =
  ## Assembles the chrome frame. Board-derived STATE (integrity, cap, the
  ## roster, the verdict) is always present, so a frame reached by a seek still
  ## hydrates the scorebug and the end card with no events at all.
  var roster = newJArray()
  for seat in model.seats:
    roster.add(seatJson(seat))

  var teams = newJObject()
  teams["machine"] = plateJson("Factory", model.integrity, %*{
    "band": model.band, "cap": model.cap, "mode": model.mode
  })
  teams["output"] = plateJson("Bananas", model.bananasMade, %*{
    "presses": model.presses, "strips": model.strips
  })

  var state = %*{
    "t": model.tick,
    "mt": model.maxTick,
    "ph": (if model.over: "gameover" else: "playing"),
    "lob": 0,
    "pl": playing,
    "sp": speed,
    "mx": max(1, model.maxTick),
    "st": model.startTick,
    "lp": looping,
    "sk": false,
    "ff": false,
    "en": transportEnabled,
    "mm": -1,
    # Board pixels per LOGICAL board pixel. The 26x15 board is emitted at its
    # authored 1248x720, so this is 1 and every viewer measure that multiplies
    # through it is a no-op — unlike paintbot, which supersamples.
    "bs": 1,
    "pov": -1,
    "teams": teams,
    "roster": roster,
    "events": (if events.isNil: newJArray() else: events),
    "fc": {
      "variant": model.variant,
      "shift": model.shift,
      "shifts": model.shifts,
      "ticksPerShift": model.ticksPerShift,
      "integrity": model.integrity,
      "cap": model.cap,
      "band": model.band,
      "mode": model.mode,
      "eitherOr": model.eitherOr,
      "pink": model.pink,
      "blue": model.blue,
      "cooldown": model.cooldown,
      "pressYield": model.pressYield,
      "stripYield": model.stripYield,
      "pressLegal": model.pressLegal,
      "stripLegal": model.stripLegal,
      "presses": model.presses,
      "strips": model.strips,
      "repairs": model.repairs,
      "made": model.bananasMade,
      "rotted": model.bananasRotted,
      "spoiled": model.bananasSpoiled,
      "onChute": model.onChute,
      "scrappedBy": model.scrappedBy,
      "lastPressTick": model.lastPressTick,
      "lastStripTick": model.lastStripTick
    }
  }

  ## Full-timeline integrity/cap series, sent ONCE per viewer so the momentum
  ## strip draws its whole width immediately instead of accumulating to the
  ## playhead. Team-keyed, exactly the shape chrome_common.js normalises.
  if leadSeries.len > 0:
    var pts = newJArray()
    for row in leadSeries:
      pts.add(%*[row[0], row[1], row[2]])
    state["lead"] = %*{"teams": ["integrity", "cap"], "pts": pts}

  ## The whole beat timeline on the first HUD frame, so the scrubber is
  ## complete before playback starts and `?spoilers=0` still holds beats back
  ## until the playhead reaches them.
  if not beats.isNil and beats.len > 0:
    state["beats"] = beats

  ## The end card is STATE, not an event: present on every game-over frame so a
  ## viewer who seeks straight to the end still sees the verdict.
  if model.over:
    var best = 0
    for seat in model.seats:
      best = max(best, seat.score)
    var winners = newJArray()
    for seat in model.seats:
      if seat.score == best:
        winners.add(%seat.alias)
    state["over"] = %*{
      "ending": model.ending,
      "reason": model.reason,
      "scrapped_by": model.scrappedBy,
      "integrity": model.integrity,
      "cap": model.cap,
      "made": model.bananasMade,
      "strips": model.strips,
      "winners": winners,
      # `winner`/`draw` are what chrome_common.js's `setVerdict` reads. A tie
      # is correct for a commons game and needs no tiebreak, so it is a draw.
      "winner": (if winners.len == 1: winners[0].getStr().toLowerAscii()
                 else: ""),
      "draw": winners.len != 1
    }

  $state

proc bandFor*(config: GameConfig, integrity, cap: int): string =
  $config.bandOf(integrity, cap)

## The viewer's feed rows quote `say` verbatim, so the server-side cap IS the
## feed's cap. tests/test_broadcast.nim asserts every frame's strings honour it,
## which is what lets the renderer reserve a band for them.
proc feedRowLimit*(): int = MaxSayLen
