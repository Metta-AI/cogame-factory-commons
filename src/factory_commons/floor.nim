## The authored factory floor: one fixed 26x15 cell grid, and the BFS the
## kernel walks it with.
##
## Heavily reduced fork of `coworld-ctf/src/ctf/arena.nim`. Everything that
## made that file 3800 lines — the terrain generator, `mapSpec`, symmetry,
## the validators, pixel queries and `map_pool` — is DELETED: Factory Commons
## has exactly one authored floor, so there is nothing to generate and nothing
## to validate.

import ./sim_types

type
  CellKind* = enum
    ckWall
    ckFloor
    ckMachine
    ckConsole
    ckChute
    ckBay
    ckPinkHopper
    ckBlueHopper
    ckPinkBelt
    ckBlueBelt

proc beltTailX*(config: GameConfig): int =
  BeltX0 + config.beltLen - 1

proc cellKind*(config: GameConfig, x, y: int): CellKind =
  ## The authored kind of one cell. Order matters: the border ring wins over
  ## everything, then the machine body, then the stations.
  if x <= 0 or y <= 0 or x >= Cols - 1 or y >= Rows - 1:
    return ckWall
  if x >= MachineX0 and x <= MachineX1 and y >= MachineY0 and y <= MachineY1:
    return ckMachine
  if y == ConsoleRow and x >= ConsoleX0 and x <= ConsoleX1:
    return ckConsole
  if y == ChuteRow and x >= ConsoleX0 and x <= ConsoleX1:
    return ckChute
  if x == BayCol and y >= BayY0 and y <= BayY1:
    return ckBay
  if x == PinkHopperX and y == PinkHopperY:
    return ckPinkHopper
  if x == BlueHopperX and y == BlueHopperY:
    return ckBlueHopper
  let tail = config.beltTailX()
  if y == PinkBeltRow and x >= BeltX0 and x <= tail:
    return ckPinkBelt
  if y == BlueBeltRow and x >= BeltX0 and x <= tail:
    return ckBlueBelt
  ckFloor

proc walkable*(config: GameConfig, x, y: int): bool =
  ## Everything but the border ring and the machine body is walkable — the
  ## hoppers, the console pad, the chute, the bay and both belts included.
  let kind = config.cellKind(x, y)
  kind != ckWall and kind != ckMachine

proc isConsole*(config: GameConfig, x, y: int): bool =
  config.cellKind(x, y) == ckConsole

proc isChute*(config: GameConfig, x, y: int): bool =
  config.cellKind(x, y) == ckChute

proc isBay*(config: GameConfig, x, y: int): bool =
  config.cellKind(x, y) == ckBay

proc hopperAt*(config: GameConfig, x, y: int): int =
  ## `ord` of the hopper's colour at this cell, or -1.
  case config.cellKind(x, y)
  of ckPinkHopper: ord(cPink)
  of ckBlueHopper: ord(cBlue)
  else: -1

proc beltAt*(config: GameConfig, x, y: int): int =
  ## `ord` of the belt's colour at this cell, or -1.
  case config.cellKind(x, y)
  of ckPinkBelt: ord(cPink)
  of ckBlueBelt: ord(cBlue)
  else: -1

proc beltRow*(cube: Cube): int =
  if cube == cPink: PinkBeltRow else: BlueBeltRow

proc hopperCell*(cube: Cube): array[2, int] =
  if cube == cPink: [PinkHopperX, PinkHopperY] else: [BlueHopperX, BlueHopperY]

proc consoleCells*(): seq[array[2, int]] =
  for x in ConsoleX0 .. ConsoleX1:
    result.add([x, ConsoleRow])

proc chuteCells*(): seq[array[2, int]] =
  for x in ConsoleX0 .. ConsoleX1:
    result.add([x, ChuteRow])

proc bayCells*(): seq[array[2, int]] =
  for y in BayY0 .. BayY1:
    result.add([BayCol, y])

# ---- BFS ------------------------------------------------------------------
#
# Over walkable cells only, expanding neighbours in N, E, S, W order, so every
# path is unique and deterministic. Other cogs are NOT obstacles for path
# planning — only for the move itself (step 7 resolves that against the live
# board) — which keeps a planned route stable while three cogs shuffle past
# each other.

const
  NeighbourDx*: array[4, int] = [0, 1, 0, -1]   ## N, E, S, W
  NeighbourDy*: array[4, int] = [-1, 0, 1, 0]
  NeighbourAction*: array[4, Action] = [aMoveN, aMoveE, aMoveS, aMoveW]

proc bfsFirstStep*(
  config: GameConfig,
  sx, sy: int,
  targets: openArray[array[2, int]],
  avoid: seq[array[2, int]] = @[]
): Action =
  ## The first move along the unique shortest walkable path from (sx, sy) to
  ## the nearest of `targets`. `aWait` when already standing on a target, when
  ## no target is reachable, or when `targets` is empty.
  ##
  ## `avoid` names cells the path may not pass THROUGH (a target cell in
  ## `avoid` is still reachable, so "walk to the console cell somebody is
  ## leaving" still plans). It is empty on the primary plan — the design note's
  ## rule is that other cogs are not obstacles for path PLANNING — and carries
  ## the other cogs only on the kernel's second attempt, which is what breaks a
  ## head-on pair that would otherwise both insist on the shortest path through
  ## each other for the rest of the episode.
  if targets.len == 0:
    return aWait
  var isTarget: array[Cols * Rows, bool]
  var anyTarget = false
  for cell in targets:
    if cell[0] < 0 or cell[1] < 0 or cell[0] >= Cols or cell[1] >= Rows:
      continue
    if not config.walkable(cell[0], cell[1]):
      continue
    isTarget[cell[1] * Cols + cell[0]] = true
    anyTarget = true
  if not anyTarget:
    return aWait
  if isTarget[sy * Cols + sx]:
    return aWait

  var
    parent: array[Cols * Rows, int]
    seen: array[Cols * Rows, bool]
    blocked: array[Cols * Rows, bool]
    queue = newSeqOfCap[int](Cols * Rows)
  for i in 0 ..< Cols * Rows:
    parent[i] = -1
  for cell in avoid:
    if cell[0] < 0 or cell[1] < 0 or cell[0] >= Cols or cell[1] >= Rows:
      continue
    let index = cell[1] * Cols + cell[0]
    if not isTarget[index]:
      blocked[index] = true
  let start = sy * Cols + sx
  seen[start] = true
  queue.add(start)
  var head = 0
  var found = -1
  while head < queue.len:
    let node = queue[head]
    inc head
    if isTarget[node]:
      found = node
      break
    let
      x = node mod Cols
      y = node div Cols
    for dir in 0 .. 3:
      let
        nx = x + NeighbourDx[dir]
        ny = y + NeighbourDy[dir]
      if nx < 0 or ny < 0 or nx >= Cols or ny >= Rows:
        continue
      if not config.walkable(nx, ny):
        continue
      let next = ny * Cols + nx
      if seen[next] or blocked[next]:
        continue
      seen[next] = true
      parent[next] = node
      queue.add(next)
  if found < 0:
    return aWait

  ## Walk the parent chain back to the cell adjacent to the start, then name
  ## the direction that leaves the start.
  var node = found
  while parent[node] != start and parent[node] >= 0:
    node = parent[node]
  if parent[node] != start:
    return aWait
  let
    dx = (node mod Cols) - sx
    dy = (node div Cols) - sy
  for dir in 0 .. 3:
    if NeighbourDx[dir] == dx and NeighbourDy[dir] == dy:
      return NeighbourAction[dir]
  aWait

proc bfsField*(config: GameConfig, sx, sy: int): array[Cols * Rows, int] =
  ## Shortest walkable distance from (sx, sy) to every cell, -1 unreachable.
  ## One field per cog per tick is what keeps the kernel cheap: picking the
  ## nearest of fourteen loose cubes used to cost fourteen BFS walks.
  for i in 0 ..< Cols * Rows:
    result[i] = -1
  if not config.walkable(sx, sy):
    return
  var queue = newSeqOfCap[int](Cols * Rows)
  let start = sy * Cols + sx
  result[start] = 0
  queue.add(start)
  var head = 0
  while head < queue.len:
    let node = queue[head]
    inc head
    let
      x = node mod Cols
      y = node div Cols
    for dir in 0 .. 3:
      let
        nx = x + NeighbourDx[dir]
        ny = y + NeighbourDy[dir]
      if nx < 0 or ny < 0 or nx >= Cols or ny >= Rows:
        continue
      if not config.walkable(nx, ny):
        continue
      let next = ny * Cols + nx
      if result[next] >= 0:
        continue
      result[next] = result[node] + 1
      queue.add(next)

proc bfsDistance*(
  config: GameConfig,
  sx, sy, tx, ty: int
): int =
  ## Shortest walkable distance in cells, or -1 when unreachable. Used by the
  ## tests to pin the leg table in the design note.
  if sx == tx and sy == ty:
    return 0
  if tx < 0 or ty < 0 or tx >= Cols or ty >= Rows:
    return -1
  let field = config.bfsField(sx, sy)
  field[ty * Cols + tx]
