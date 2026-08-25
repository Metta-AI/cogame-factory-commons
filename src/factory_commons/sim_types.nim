## Factory Commons — constants, wire types and the sim record.
##
## Forked from `coworld-ctf/src/ctf/sim_types.nim`: the same split (consts,
## types, the game record) and the same discipline — FIELD ORDER IS SACRED,
## because the replay frame encodings below are positional integer arrays and
## a reordered field silently reinterprets every recorded episode.
##
## Everything in the sim is an INTEGER. No float ever enters sim state, so a
## seed reproduces a replay bit-exactly (tests/test_sim.nim depends on it).

import std/[json, tables]

const
  GameVersion* = "1"
    ## GV1: the shipping rules — press/strip/fix, the six bands, the
    ## irreversible cap, the either-or lock. Bump on any rule change; the
    ## replay records it so a consumer never has to infer which rules ran.

  ProtocolPlayer* = "factory_commons.player.v1"
  ProtocolReplay* = "factory_commons.replay.v1"
  GameName* = "factory_commons"

  # ---- the floor, authored once (there is no map generator) ----------------
  Cols* = 26
  Rows* = 15
  CellPx* = 48
  BoardW* = Cols * CellPx          ## 1248
  BoardH* = Rows * CellPx          ## 720

  MachineX0* = 16
  MachineX1* = 20
  MachineY0* = 5
  MachineY1* = 9

  ConsoleRow* = 4
  ChuteRow* = 10
  ConsoleX0* = 18
  ConsoleX1* = 20
  BayCol* = 15
  BayY0* = 6
  BayY1* = 8
  PinkHopperX* = 16
  PinkHopperY* = 4
  BlueHopperX* = 16
  BlueHopperY* = 10
  PinkBeltRow* = 2
  BlueBeltRow* = 12
  BeltX0* = 2

  SeatCount* = 3
    ## Factory Commons is a three-seat game in every variant. `num_agents`
    ## may narrow a fixture but never widens past this.

  Aliases*: array[SeatCount, string] = ["Bolt", "Cotter", "Ratchet"]
  SeatColors*: array[SeatCount, string] = ["red", "blue", "yellow"]
  SpawnCells*: array[SeatCount, array[2, int]] = [[10, 4], [10, 10], [13, 7]]

  # ---- playback / chrome wire constants -----------------------------------
  TargetFps* = 24
  PlaybackSpeeds*: array[6, int] = [1, 2, 3, 4, 8, 16]

  # ---- recorded-string caps (RUNE counts, never bytes) --------------------
  MaxSayLen* = 90
  MaxNotesLen* = 320
  MaxPromptLen* = 4000
  MaxErrorLen* = 200

  # ---- the two yield tables, indexed by the PRIME/WORN/FAILING band ------
  #
  # `PrivateYield` is 4/3/1, not the design note's authored 3/2/1: gate (b)
  # ("the temptation is real") failed at 3/2/1 once `stripCapLoss` rose to 16,
  # because five overrides then scrap the plant and 3+3+2+2+1 = 11 private
  # bananas did not reliably out-score a steward. 4/3/1 is rung ONE of the
  # note's own repair ladder for that gate, and tests/test_feasibility.nim is
  # the enforcement.
  PublicYield*: array[3, int] = [4, 3, 1]
  PrivateYield*: array[3, int] = [4, 3, 1]

type
  FactoryError* = object of CatchableError

  Cube* = enum
    ## Colour ids are the fixed replay order: 0 pink, 1 blue.
    cPink = 0
    cBlue = 1

  Band* = enum
    bPrime = "PRIME"
    bWorn = "WORN"
    bFailing = "FAILING"
    bCritical = "CRITICAL"
    bSeized = "SEIZED"
    bScrap = "SCRAP"

  Mode* = enum
    ## Mode ids are the fixed replay order: 0 unset, 1 cycle, 2 override.
    mUnset = 0
    mCycle = 1
    mOverride = 2

  Job* = enum
    jOperate = "operate"
    jStrip = "strip"
    jMaintain = "maintain"
    jEat = "eat"
    jIdle = "idle"

  CubeChoice* = enum
    ccPink = "pink"
    ccBlue = "blue"
    ccAny = "any"

  Action* = enum
    ## The whole per-tick grid vocabulary. Ten values, nothing else.
    aWait = "wait"
    aMoveN = "move_n"
    aMoveS = "move_s"
    aMoveE = "move_e"
    aMoveW = "move_w"
    aGrasp = "grasp"
    aDrop = "drop"
    aPress = "press"
    aStrip = "strip"
    aFix = "fix"

  OrderSource* = enum
    osScripted = "scripted"
    osLlm = "llm"
    osRetry = "retry"
    osFallback = "fallback"

  Order* = object
    ## One seat's standing order for a shift. The kernel turns it into the
    ## per-tick action stream.
    job*: Job
    cube*: CubeChoice
    say*: string
    notes*: string
    source*: OrderSource
    latencyMs*: int

  Cog* = object
    x*, y*: int
    carrying*: int          ## -1 = empty hand, else `ord(Cube)`
    moveCd*: int
    eaten*, banked*: int
    presses*, strips*, repairs*, misfeeds*: int
    fallbacks*: int
    order*: Order
    said*: string           ## last shift's broadcast, echoed to every seat
    notes*: string          ## private notebook, echoed back to this seat only

  LooseCube* = object
    x*, y*: int
    cube*: Cube

  Banana* = object
    x*, y*, age*: int

  Machine* = object
    integrity*, cap*: int
    pink*, blue*: int
    cooldown*: int
    mode*: Mode
    presses*, strips*, repairs*: int
    bananasMade*, bananasRotted*, bananasSpoiled*: int
    scrappedBy*: int        ## slot whose strip crossed cap < pressFloor, or -1

  ShiftRecord* = object
    shift*: int
    integrity*, cap*: int
    presses*, strips*, repairs*, made*, rotted*: int
    eaten*, banked*: array[SeatCount, int]

  Frame* = object
    ## One recorded tick. The four arrays are the replay's positional
    ## encodings; see `## The replay file` in the design note.
    t*: int
    c*: seq[int]            ## per-cog quads x, y, carryColourId, score
    u*: seq[int]            ## loose-cube triples x, y, colourId
    b*: seq[int]            ## banana triples x, y, ttl
    m*: array[6, int]       ## integrity, cap, pink, blue, cooldown, modeId

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    ## Every field is a `config.update` key; the JSON-Schema in
    ## `coworld_manifest_template.json` bounds each one. Defaults here and the
    ## schema's defaults must agree (tests/test_manifest.nim asserts it).
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    numAgents*: int
    seed*: int
    shifts*: int
    ticksPerShift*: int
    eitherOr*: bool
    moveCooldown*: int
    carryCap*: int
    dispensePeriod*: int
    beltPeriod*: int
    beltLen*: int
    hopperCap*: int
    pressFloor*: int
    stripFloor*: int
    pressWear*: int
    stripWear*: int
    stripCapLoss*: int
    repairGain*: int
    capMin*: int
    rustPeriod*: int
    pressCooldown*: int
    stripCooldown*: int
    repairCooldown*: int
    bananaLifetime*: int
    cellBananaCap*: int
    eatTrigger*: int
    llmTimeoutSeconds*: int
    minTurnSeconds*: int
    maxOutputTokens*: int
    model*: string
    episodeTimeoutSeconds*: int
    playerConnectTimeoutSeconds*: int
    shutdownGraceSeconds*: int
    showPlayerLabels*: bool

  Sim* = object
    ## The whole game. Copied by value for the LLM snapshot (bullwhip's
    ## pattern), so it must stay a plain value object.
    config*: GameConfig
    tick*: int
    shift*: int                    ## shifts COMPLETED (0 before shift 1)
    cogs*: seq[Cog]
    cubes*: seq[LooseCube]
    bananas*: seq[Banana]
    machine*: Machine
    dispensed*: int                ## every cube ever emitted (conservation)
    consumed*: int                 ## every cube the machine ate
    events*: seq[JsonNode]
    frames*: seq[Frame]
    series*: seq[array[3, int]]    ## [tick, integrity, cap], one row per tick
    beats*: seq[JsonNode]
    history*: seq[ShiftRecord]
    done*: bool
    reason*: string                ## complete | deadline | forfeit
    ending*: string                ## shift_limit | factory_ruined | deadline | forfeit
    connected*: seq[bool]
    lastBlocked*: seq[string]      ## per-seat `blocked` dedupe key (record
                                   ## keeping, never state: excluded from
                                   ## `gameHash` like `events`)

proc maxTicks*(config: GameConfig): int =
  ## The scheduled episode length in ticks.
  config.shifts * config.ticksPerShift

proc cubeText*(cube: Cube): string =
  if cube == cPink: "pink" else: "blue"

proc parseCube*(text: string): int =
  ## `ord` of the cube colour, or -1.
  case text
  of "pink": ord(cPink)
  of "blue": ord(cBlue)
  else: -1

proc parseJob*(text: string): int =
  ## `ord` of the job, or -1 when the value is outside the enum.
  for job in Job:
    if $job == text:
      return ord(job)
  -1

proc parseCubeChoice*(text: string): int =
  ## `ord` of the cube choice, or -1 when the value is outside the enum.
  for choice in CubeChoice:
    if $choice == text:
      return ord(choice)
  -1

proc parseOrderSource*(text: string): OrderSource =
  for source in OrderSource:
    if $source == text:
      return source
  osScripted

proc initOrder*(): Order =
  Order(job: jOperate, cube: ccAny, source: osScripted)

const EventKinds* = [
  "grasp", "drop", "misfeed", "fix", "press", "strip", "lock", "scrap",
  "blocked", "eat", "rot", "spoil", "order", "shift", "end"
]
  ## The whole event vocabulary. tests/test_replay.nim asserts every recorded
  ## row's `k` is in here, so a typo cannot reach a replay.

const BeatKinds* = ["shift", "strip", "lock", "scrap", "gameover"]
  ## The five scrubber-beat kinds the viewer has CSS for. A sixth kind would
  ## render as an unlabelled div, so tests/test_broadcast.nim gates on this.

proc eventKindsTable*(): Table[string, bool] =
  result = initTable[string, bool]()
  for kind in EventKinds:
    result[kind] = true
