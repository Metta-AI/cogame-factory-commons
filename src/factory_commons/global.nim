## The board renderer: the bitworld sprite-protocol emitter, the layer/object
## pooling, `boardRenderScaleFor`, and the chrome-JSON smuggling.
##
## Heavily reduced fork of `coworld-ctf/src/ctf/global.nim`. DELETED, not
## repurposed: fog-of-war / FOV, the first-person PiP, the articulated rig art,
## the grenade / spray / shield / barrier families, the endzone bakes, the perks
## and the handicaps. What is kept is the part that makes a board render at all:
##
##   * the sprite-protocol packet shape (`addViewport` / `addLayer` /
##     `addSprite` / `addObject` / `addClearObjects`);
##   * the STATIC BAND pool — layer 0, object ids 40..99, z = -32768 — which is
##     the window `client/broadcast_core.js` caches into a baked base canvas.
##     A 1248x720 board in one sprite is ~1.09 MB raw and would blow the hosted
##     replay's 1 MiB WebSocket frame cap, so the authored floor ships as four
##     horizontal bands exactly as paintbot's map does;
##   * the chrome `TextMessage` smuggling: the broadcast chrome JSON rides as
##     the LABEL of a reserved 1x1 never-drawn sprite on the SAME binary
##     channel the board rides, so it survives every playback path (live serve,
##     generic client, hosted static replay).

import std/[json, tables]

import bitworld/spriteprotocol
import pixie

import ./sim_types, ./broadcast

const
  BroadcastChromeSpriteId* = 4090
    ## Reserved 1x1 never-drawn sprite whose LABEL carries the broadcast chrome
    ## JSON. The chrome used to ride a separate opt-in `TextMessage`; that
    ## interactive channel does NOT survive a hosted replay, so the HUD froze
    ## at its DOM defaults while the board played fine.
  MapLayerId = 0

  MapBandSpriteBase* = 30
  MapBandObjectBase* = 40
  MapBandHeight* = 192
  StaticBandZ* = -32768

  # Dynamic sprite ids. Kept clear of the band pool (30..33), the band object
  # pool (40..43) and the chrome sprite (4090).
  SpriteMachineBase = 100        ## + 0..3 for prime / worn / failing / scrap
  SpriteLeverCycle = 110
  SpriteLeverOverride = 111
  SpriteBeltChevron = 112
  SpriteCubeBase = 120           ## + colour id
  SpriteBanana = 122
  SpritePressFlash = 123
  SpriteStripSmoke = 124
  SpriteCogBase = 130            ## + slot * 2 + (carrying ? 1 : 0)
  SpriteLabelBase = 140          ## + slot

  # Dynamic object ids, all with z > StaticBandZ so the cached static prefix
  # stays the sorted prefix (broadcast_core.js refuses to cache otherwise).
  ObjectMachine = 200
  ObjectLeverCycle = 201
  ObjectLeverOverride = 202
  ObjectChevronBase = 210
  ObjectCubeBase = 300
  ObjectBananaBase = 420
  ObjectCogBase = 540
  ObjectFxBase = 600

  ZMachine = 5
  ZLever = 6
  ZChevron = 3
  ZCube = 10
  ZBanana = 12
  ZLabel = 18
  ZCog = 20
  ZCarry = 22
  ZFx = 30

  PressFlashTicks* = 6
  StripSmokeTicks* = 12

type
  ArtId* = enum
    aiFloor, aiWallH, aiWallV,
    aiMachinePrime, aiMachineWorn, aiMachineFailing, aiMachineScrap,
    aiConsole, aiLeverCycle, aiLeverOverride, aiBay,
    aiDispenserPink, aiDispenserBlue, aiHopperPink, aiHopperBlue,
    aiBeltSeg, aiBeltChevron, aiChute,
    aiCubePink, aiCubeBlue, aiBanana, aiPressFlash, aiStripSmoke,
    aiLabelBolt, aiLabelCotter, aiLabelRatchet,
    aiCogRedFront, aiCogRedCarry, aiCogBlueFront, aiCogBlueCarry,
    aiCogYellowFront, aiCogYellowCarry

  GlobalViewerState* = object
    ## One spectator's view state. The one-shot payload flags live here, not in
    ## the sim, so a viewer that connects mid-episode still gets the sprites,
    ## the bands, the lead series and the beat timeline.
    spritesSent*: bool
    leadSent*: bool
    beatsSent*: bool
    replaySeekTick*: int
    replayCommands*: seq[string]

const ArtBytes: array[ArtId, string] = [
  staticRead("../../data/floor_steel.png"),
  staticRead("../../data/wall_panel_h.png"),
  staticRead("../../data/wall_panel_v.png"),
  staticRead("../../data/machine_prime.png"),
  staticRead("../../data/machine_worn.png"),
  staticRead("../../data/machine_failing.png"),
  staticRead("../../data/machine_scrap.png"),
  staticRead("../../data/console.png"),
  staticRead("../../data/lever_cycle.png"),
  staticRead("../../data/lever_override.png"),
  staticRead("../../data/bay.png"),
  staticRead("../../data/dispenser_pink.png"),
  staticRead("../../data/dispenser_blue.png"),
  staticRead("../../data/hopper_pink.png"),
  staticRead("../../data/hopper_blue.png"),
  staticRead("../../data/belt_seg.png"),
  staticRead("../../data/belt_chevron.png"),
  staticRead("../../data/chute.png"),
  staticRead("../../data/cube_pink.png"),
  staticRead("../../data/cube_blue.png"),
  staticRead("../../data/banana.png"),
  staticRead("../../data/press_flash.png"),
  staticRead("../../data/strip_smoke.png"),
  staticRead("../../data/label_bolt.png"),
  staticRead("../../data/label_cotter.png"),
  staticRead("../../data/label_ratchet.png"),
  staticRead("../../data/cog_red_front.png"),
  staticRead("../../data/cog_red_carry.png"),
  staticRead("../../data/cog_blue_front.png"),
  staticRead("../../data/cog_blue_carry.png"),
  staticRead("../../data/cog_yellow_front.png"),
  staticRead("../../data/cog_yellow_carry.png")
]
  ## Embedded rather than read from `data/` at runtime: the wasm bundle then
  ## needs no filesystem at all, and a missing asset is a BUILD failure instead
  ## of a blank board at playback time.

var
  artImages: array[ArtId, Image]
  artReady = false
  boardBake: seq[uint8]
  boardBakedFor = ""
  prologueCache: seq[uint8]
  prologueFor = ""

proc initGlobalViewerState*(): GlobalViewerState =
  GlobalViewerState(replaySeekTick: -1, replayCommands: @[])

proc boardRenderScaleFor*(boardWidth, boardHeight: int): int =
  ## Board pixels per LOGICAL board pixel. Factory Commons authors its floor at
  ## 48 px per cell and emits it at exactly that, so the scale is always 1 —
  ## kept as the named seam paintbot's chrome frame reports through (`bs`),
  ## because every viewer measure that converts board px <-> world px
  ## multiplies by it.
  discard boardWidth
  discard boardHeight
  1

proc ensureArt() =
  if artReady:
    return
  for id in ArtId:
    artImages[id] = decodeImage(ArtBytes[id])
  artReady = true

proc artOf*(id: ArtId): Image =
  ensureArt()
  artImages[id]

proc rgbaOf*(image: Image): seq[uint8] =
  ## Straight RGBA bytes for the sprite protocol.
  ##
  ## pixie stores PREMULTIPLIED alpha. Every sprite this game ships has BINARY
  ## alpha (`scripts/art/gen_factory_commons_art.py` thresholds it), and
  ## premultiplied equals straight exactly when alpha is 0 or 255 — so this is
  ## a straight copy and not a lossy round-trip.
  result = newSeq[uint8](image.width * image.height * 4)
  for i in 0 ..< image.width * image.height:
    let pixel = image.data[i]
    result[i * 4] = pixel.r
    result[i * 4 + 1] = pixel.g
    result[i * 4 + 2] = pixel.b
    result[i * 4 + 3] = pixel.a

proc blit(dst: var seq[uint8], src: Image, dx, dy: int) =
  ## Source-over blit into the board bake. Binary alpha, so a copy is enough.
  for sy in 0 ..< src.height:
    let ty = dy + sy
    if ty < 0 or ty >= BoardH:
      continue
    for sx in 0 ..< src.width:
      let tx = dx + sx
      if tx < 0 or tx >= BoardW:
        continue
      let pixel = src.data[sy * src.width + sx]
      if pixel.a == 0:
        continue
      let offset = (ty * BoardW + tx) * 4
      dst[offset] = pixel.r
      dst[offset + 1] = pixel.g
      dst[offset + 2] = pixel.b
      dst[offset + 3] = pixel.a

proc bakeKey(config: GameConfig): string =
  $config.beltLen & ":" & $Cols & "x" & $Rows

proc ensureBoardBake(config: GameConfig) =
  ## The authored floor, baked once per process: the steel floor, the wall
  ## ring, both belts with their dispenser mouths, both hopper intakes, the
  ## maintenance bay, the console pad and the chute. The MACHINE is deliberately
  ## NOT baked — its art state follows the band, so it rides as a dynamic
  ## object over the bake.
  ensureArt()
  let key = config.bakeKey()
  if boardBakedFor == key and boardBake.len > 0:
    return
  boardBake = newSeq[uint8](BoardW * BoardH * 4)
  let tail = BeltX0 + config.beltLen - 1
  for y in 0 ..< Rows:
    for x in 0 ..< Cols:
      let px = x * CellPx
      let py = y * CellPx
      if x == 0 or x == Cols - 1:
        boardBake.blit(artOf(aiWallV), px, py)
      elif y == 0 or y == Rows - 1:
        boardBake.blit(artOf(aiWallH), px, py)
      else:
        boardBake.blit(artOf(aiFloor), px, py)
  for row in [PinkBeltRow, BlueBeltRow]:
    for x in BeltX0 .. tail:
      boardBake.blit(artOf(aiBeltSeg), x * CellPx, row * CellPx)
  boardBake.blit(artOf(aiDispenserPink), BeltX0 * CellPx, PinkBeltRow * CellPx)
  boardBake.blit(artOf(aiDispenserBlue), BeltX0 * CellPx, BlueBeltRow * CellPx)
  boardBake.blit(artOf(aiHopperPink), PinkHopperX * CellPx, PinkHopperY * CellPx)
  boardBake.blit(artOf(aiHopperBlue), BlueHopperX * CellPx, BlueHopperY * CellPx)
  boardBake.blit(artOf(aiBay), BayCol * CellPx, BayY0 * CellPx)
  boardBake.blit(artOf(aiConsole), ConsoleX0 * CellPx, ConsoleRow * CellPx)
  boardBake.blit(artOf(aiChute), ConsoleX0 * CellPx, ChuteRow * CellPx)
  boardBakedFor = key

proc bandCount*(): int = (BoardH + MapBandHeight - 1) div MapBandHeight

proc bandBytes(band: int): seq[uint8] =
  let
    y0 = band * MapBandHeight
    height = min(MapBandHeight, BoardH - y0)
  result = newSeq[uint8](BoardW * height * 4)
  for y in 0 ..< height:
    let
      src = ((y0 + y) * BoardW) * 4
      dst = (y * BoardW) * 4
    copyMem(result[dst].addr, boardBake[src].addr, BoardW * 4)

proc buildPrologue(config: GameConfig): seq[uint8] =
  ## Viewport, layer definition, every dynamic sprite's pixels, and the four
  ## static board bands with their objects. Sent ONCE per viewer; cached per
  ## process so a second spectator does not re-compress a megabyte of steel.
  ensureBoardBake(config)
  let key = config.bakeKey()
  if prologueFor == key and prologueCache.len > 0:
    return prologueCache
  var packet: seq[uint8]
  packet.addLayer(MapLayerId, SpriteLayerMap, SpriteLayerZoomableFlag)
  packet.addViewport(MapLayerId, BoardW, BoardH)

  proc sprite(id: int, art: ArtId) =
    let image = artOf(art)
    packet.addSprite(id, image.width, image.height, rgbaOf(image))

  sprite(SpriteMachineBase + 0, aiMachinePrime)
  sprite(SpriteMachineBase + 1, aiMachineWorn)
  sprite(SpriteMachineBase + 2, aiMachineFailing)
  sprite(SpriteMachineBase + 3, aiMachineScrap)
  sprite(SpriteLeverCycle, aiLeverCycle)
  sprite(SpriteLeverOverride, aiLeverOverride)
  sprite(SpriteBeltChevron, aiBeltChevron)
  sprite(SpriteCubeBase + ord(cPink), aiCubePink)
  sprite(SpriteCubeBase + ord(cBlue), aiCubeBlue)
  sprite(SpriteBanana, aiBanana)
  sprite(SpritePressFlash, aiPressFlash)
  sprite(SpriteStripSmoke, aiStripSmoke)
  const CogArt: array[3, array[2, ArtId]] = [
    [aiCogRedFront, aiCogRedCarry],
    [aiCogBlueFront, aiCogBlueCarry],
    [aiCogYellowFront, aiCogYellowCarry]
  ]
  const LabelArt: array[3, ArtId] = [aiLabelBolt, aiLabelCotter, aiLabelRatchet]
  for slot in 0 ..< SeatCount:
    sprite(SpriteCogBase + slot * 2, CogArt[slot][0])
    sprite(SpriteCogBase + slot * 2 + 1, CogArt[slot][1])
    sprite(SpriteLabelBase + slot, LabelArt[slot])

  for band in 0 ..< bandCount():
    let
      y0 = band * MapBandHeight
      height = min(MapBandHeight, BoardH - y0)
    packet.addSprite(MapBandSpriteBase + band, BoardW, height, bandBytes(band))
  prologueCache = packet
  prologueFor = key
  packet

proc machineSpriteFor(band: string): int =
  case band
  of "PRIME": SpriteMachineBase + 0
  of "WORN": SpriteMachineBase + 1
  of "FAILING", "CRITICAL", "SEIZED": SpriteMachineBase + 2
  else: SpriteMachineBase + 3

proc cogArtIndex(color: string): int =
  case color
  of "red": 0
  of "blue": 1
  else: 2

proc addBoardObjects(packet: var seq[uint8], model: HudModel) =
  ## Every dynamic placement for one frame. `addClearObjects` first, so the
  ## whole board is described by this one packet and a viewer that missed a
  ## frame cannot accumulate a ghost.
  packet.addClearObjects()

  for band in 0 ..< bandCount():
    packet.addObject(
      MapBandObjectBase + band, 0, band * MapBandHeight, StaticBandZ,
      MapLayerId, MapBandSpriteBase + band)

  packet.addObject(ObjectMachine, MachineX0 * CellPx, MachineY0 * CellPx,
    ZMachine, MapLayerId, machineSpriteFor(model.band))

  ## The two levers. The override lever is its own sprite so the viewer can
  ## draw it hot exactly when a strip is legal right now.
  packet.addObject(ObjectLeverCycle, ConsoleX0 * CellPx + 12,
    ConsoleRow * CellPx, ZLever, MapLayerId, SpriteLeverCycle)
  if model.stripLegal:
    packet.addObject(ObjectLeverOverride, ConsoleX1 * CellPx + 12,
      ConsoleRow * CellPx, ZLever, MapLayerId, SpriteLeverOverride)

  ## Marching chevrons: which belt cells carry one cycles with the tick, so the
  ## belts read as running without any object actually moving (a gliding object
  ## would fight the client's motion interpolation).
  var chevron = 0
  let tail = BeltX0 + model.beltLen - 1
  for row in [PinkBeltRow, BlueBeltRow]:
    for x in BeltX0 .. tail:
      if ((x + model.tick div 4) mod 2) == 0:
        packet.addObject(ObjectChevronBase + chevron, x * CellPx + 12,
          row * CellPx + 12, ZChevron, MapLayerId, SpriteBeltChevron)
      inc chevron

  for i, cube in model.cubes:
    if i >= ObjectBananaBase - ObjectCubeBase:
      break
    packet.addObject(ObjectCubeBase + i, cube.x * CellPx + 13,
      cube.y * CellPx + 13, ZCube, MapLayerId, SpriteCubeBase + ord(cube.cube))

  for i, banana in model.bananas:
    if i >= ObjectCogBase - ObjectBananaBase:
      break
    ## Stack a cell's bananas with a small fan so three on one chute cell read
    ## as three, not one.
    let fan = (i mod 3) * 6
    packet.addObject(ObjectBananaBase + i, banana.x * CellPx + 8 + fan,
      banana.y * CellPx + 18 - fan, ZBanana, MapLayerId, SpriteBanana)

  for seat in model.seats:
    let
      base = ObjectCogBase + seat.slot * 4
      art = cogArtIndex(seat.color)
      carrying = seat.carrying >= 0
    packet.addObject(base, seat.x * CellPx + 6, seat.y * CellPx, ZCog,
      MapLayerId, SpriteCogBase + art * 2 + (if carrying: 1 else: 0))
    if carrying:
      packet.addObject(base + 1, seat.x * CellPx + 13,
        seat.y * CellPx - 16, ZCarry, MapLayerId,
        SpriteCubeBase + seat.carrying)
    if model.showLabels:
      let label = artOf(ArtId(ord(aiLabelBolt) + seat.slot))
      packet.addObject(base + 2, seat.x * CellPx + (CellPx - label.width) div 2,
        seat.y * CellPx + CellPx - 6, ZLabel, MapLayerId,
        SpriteLabelBase + seat.slot)

  ## Effect plates over the machine. A press flashes it warm; a strip vents a
  ## plume — the "who broke it" moment, on the board as well as in the feed.
  if model.lastPressTick >= 0 and model.tick - model.lastPressTick < PressFlashTicks:
    packet.addObject(ObjectFxBase, MachineX0 * CellPx, MachineY0 * CellPx,
      ZFx, MapLayerId, SpritePressFlash)
  if model.lastStripTick >= 0 and model.tick - model.lastStripTick < StripSmokeTicks:
    packet.addObject(ObjectFxBase + 1, MachineX0 * CellPx, MachineY0 * CellPx,
      ZFx, MapLayerId, SpriteStripSmoke)

proc buildViewerPacket*(
  model: HudModel,
  config: GameConfig,
  state: GlobalViewerState,
  nextState: var GlobalViewerState,
  events: JsonNode,
  playing: bool,
  speed: int,
  looping: bool,
  transportEnabled: bool,
  leadSeries: seq[array[3, int]],
  beats: JsonNode
): seq[uint8] =
  ## One frame: the board and the chrome, on one binary channel.
  nextState = state
  if not state.spritesSent:
    result.add(buildPrologue(config))
    nextState.spritesSent = true
  result.addBoardObjects(model)

  let
    sendLead = not state.leadSent and leadSeries.len > 0
    sendBeats = not state.beatsSent and not beats.isNil and beats.len > 0
  result.addSprite(
    BroadcastChromeSpriteId, 1, 1, [0'u8, 0, 0, 0],
    model.buildStateJson(
      events, playing, speed, looping, transportEnabled,
      (if sendLead: leadSeries else: @[]),
      (if sendBeats: beats else: nil)
    )
  )
  if sendLead:
    nextState.leadSent = true
  if sendBeats:
    nextState.beatsSent = true

const MaxWsFrameBytes* = 900_000
  ## The hosted replay closes any WebSocket frame over 1 MiB with 1009, so the
  ## board is banded AND the packet is chunked at message boundaries.

proc chunkSpritePacket*(packet: seq[uint8], maxBytes: int): seq[seq[uint8]] =
  ## Splits one sprite-protocol packet into WS-frame-sized chunks at MESSAGE
  ## boundaries. The client parses each binary WS message independently and
  ## accumulates sprite/object state across them, so a packet delivered as N
  ## frames is equivalent to one frame — as long as no frame is cut
  ## mid-message. Forked verbatim in behaviour from paintbot's.
  ##
  ## A single message larger than maxBytes is emitted as its own (oversized)
  ## chunk rather than split; the map bands guarantee that never happens.
  result = @[]
  if packet.len == 0:
    return
  var
    offset = 0
    chunkStart = 0
  while offset < packet.len:
    let msgStart = offset
    let messageType = packet[offset]
    inc offset
    case messageType
    of 0x01:  # sprite: id,w,h (6) + clen (4) + pixels + llen (2) + label
      let clen = packet.readU32(offset + 6)
      offset += 10 + clen
      let llen = packet.readU16(offset)
      offset += 2 + llen
    of 0x02: offset += 11   # object
    of 0x03: offset += 2    # delete object
    of 0x04: discard        # clear objects (no payload)
    of 0x05: offset += 5    # viewport
    of 0x06: offset += 3    # layer
    else:
      break
    if offset - chunkStart > maxBytes and msgStart > chunkStart:
      result.add(packet[chunkStart ..< msgStart])
      chunkStart = msgStart
  if chunkStart < packet.len:
    result.add(packet[chunkStart ..< packet.len])

proc applyGlobalViewerMessage*(
  state: var GlobalViewerState,
  message: string
) =
  ## Applies one or more global-protocol client messages. Whole-string commands
  ## are intercepted before the char-by-char transport path, so a multi-digit
  ## tick is never mangled into speed keystrokes.
  for item in message.parseSpriteClientMessages():
    case item.kind
    of SpriteClientChatMessage:
      if item.text.len == 0:
        discard
      elif item.text.len > 2 and item.text[0] == 's' and item.text[1] == ':':
        var tick = 0
        var ok = item.text.len > 2
        for i in 2 ..< item.text.len:
          if item.text[i] < '0' or item.text[i] > '9':
            ok = false
            break
          tick = tick * 10 + (ord(item.text[i]) - ord('0'))
        if ok:
          state.replaySeekTick = tick
      elif item.text.len > 2 and item.text[0] == 'v' and item.text[1] == ':':
        ## The POV lens is deleted with `#fpv` — the whole floor is visible to
        ## every seat, so there is nothing to reveal. Swallow it rather than
        ## letting it fall through as a transport keystroke.
        discard
      else:
        state.replayCommands.add(item.text)
    else:
      discard

proc spriteIdsInUse*(): seq[int] =
  ## Every sprite id this module can emit, for the collision audit in
  ## tests/test_broadcast.nim. Two families sharing an id is a silent clobber:
  ## the later definition wins and the earlier family draws the wrong art.
  result.add(BroadcastChromeSpriteId)
  for band in 0 ..< bandCount():
    result.add(MapBandSpriteBase + band)
  for i in 0 .. 3:
    result.add(SpriteMachineBase + i)
  result.add(SpriteLeverCycle)
  result.add(SpriteLeverOverride)
  result.add(SpriteBeltChevron)
  result.add(SpriteCubeBase + ord(cPink))
  result.add(SpriteCubeBase + ord(cBlue))
  result.add(SpriteBanana)
  result.add(SpritePressFlash)
  result.add(SpriteStripSmoke)
  for slot in 0 ..< SeatCount:
    result.add(SpriteCogBase + slot * 2)
    result.add(SpriteCogBase + slot * 2 + 1)
    result.add(SpriteLabelBase + slot)

proc artInventory*(): Table[string, array[2, int]] =
  ## Name -> [width, height] for every embedded asset, so a test can pin the
  ## sizes the renderer's offsets assume (a 240x240 machine on a 5x5 block, a
  ## 36x48 cog anchored at the feet in a 48px cell).
  ensureArt()
  result = initTable[string, array[2, int]]()
  for id in ArtId:
    result[$id] = [artImages[id].width, artImages[id].height]
