## The three scripted baselines. All three are fieldable policies; `steward`
## and `stripper` are the league fillers, and `steward` is also the order every
## failed LLM decision lands on.
##
## Each decides once per shift purely from the observation and its own slot
## number — no shared state, so identical baselines coordinate implicitly by
## computing the same table.

import std/strutils

import ./sim_types, ./sim_state, ./floor

type
  ScriptKind* = enum
    skNone = "none"
    skSteward = "steward"
    skStripper = "stripper"
    skFreerider = "freerider"

proc parseScriptKind*(text: string): ScriptKind =
  ## `PLAYER_SCRIPTED` values. "1"/"true"/"yes" mean the working baseline,
  ## which is what a bare boolean should get.
  case text.strip().toLowerAscii()
  of "1", "true", "yes", "steward": skSteward
  of "stripper", "exploiter": skStripper
  of "freerider", "free-rider", "camper": skFreerider
  else: skNone

proc chuteBananas(sim: Sim): int =
  for cell in chuteCells():
    result += sim.bananasAt(cell[0], cell[1])

proc scarcerChoice(sim: Sim): CubeChoice =
  if sim.machine.pink <= sim.machine.blue: ccPink else: ccBlue

proc stewardOrder*(sim: Sim, seat: int): Order =
  ## The working baseline. Exactly one seat repairs per shift, rotating, so
  ## three stewards never all abandon the press at once.
  result = initOrder()
  result.source = osScripted
  let
    m = sim.machine
    shiftIndex = sim.shift          ## 0-based: the shift about to be played
    mine = shiftIndex mod SeatCount == seat
  if m.cap < sim.config.pressFloor:
    result.job = jEat
    result.cube = ccAny
    result.say = "scrap - cap " & $m.cap
    return
  if m.integrity < 70 and m.integrity < m.cap and mine:
    result.job = jMaintain
    result.cube = ccAny
    result.say = "maintain - integrity " & $m.integrity
    return
  ## The harvest rotation is OFFSET from the repair rotation, so no seat is
  ## ever asked to do both jobs in one shift and every seat gets five harvest
  ## shifts in fifteen.
  ##
  ## The `behind` clause is the fairness half, and it is why gate (a)'s "every
  ## seat >= 14" holds rather than nearly holding: without it the harvest is a
  ## RACE, whoever is in the blue lane (three cells from the chute, against
  ## twelve for the pink lane) wins nearly every banana, and a seat can finish
  ## an all-steward episode on 4. Every seat's `eaten` is in the observation, so
  ## this is still a pure function of the observation and the seat's own slot.
  ## It is deliberately gated on the rotation as well: an ungated catch-up
  ## against a FREE-RIDER (whose `eaten` runs away) parks both stewards at the
  ## chute and collapses production, which is gate (d).
  let harvestShift = (shiftIndex + 1) mod SeatCount == seat
  var lead = 0
  for other in 0 ..< sim.cogs.len:
    lead = max(lead, sim.cogs[other].eaten)
  let behind = sim.cogs[seat].eaten + 4 <= lead
  if harvestShift and (sim.chuteBananas() >= 4 or behind):
    result.job = jEat
    result.cube = ccAny
    result.say =
      if behind: "eat - " & $(lead - sim.cogs[seat].eaten) & " behind"
      else: "eat - chute " & $sim.chuteBananas()
    return
  result.job = jOperate
  result.cube =
    if abs(m.pink - m.blue) >= 2: sim.scarcerChoice()
    elif seat mod 2 == 0: ccPink
    else: ccBlue
  result.say = "operate " & $result.cube & " - hopper " & $m.pink & "/" & $m.blue

proc stripperOrder*(sim: Sim, seat: int): Order =
  ## The exploiter, and the idea's "background bot" in scoring: every champion
  ## is graded in a room that already contains one.
  result = initOrder()
  result.source = osScripted
  if sim.machine.cap < sim.config.pressFloor:
    result.job = jEat
    result.cube = ccAny
    result.say = "scrap - cap " & $sim.machine.cap
    return
  result.job = jStrip
  result.cube = ccAny
  result.say = "override mode"

proc freeriderOrder*(sim: Sim, seat: int): Order =
  ## The camper. One exception keeps a room of three freeriders off a
  ## guaranteed zero and stops it deadlocking the episode.
  result = initOrder()
  result.source = osScripted
  result.job = jEat
  result.cube = ccAny
  result.say = "waiting at the chute"
  ## `made` is cumulative, so the previous shift's production is the difference
  ## between the last two rows (or the last row itself on shift 1).
  var madeLastShift = -1
  if sim.history.len == 1:
    madeLastShift = sim.history[0].made
  elif sim.history.len >= 2:
    madeLastShift = sim.history[^1].made - sim.history[^2].made
  if madeLastShift == 0 and sim.chuteBananas() == 0 and
      sim.machine.integrity >= sim.config.pressFloor:
    result.job = jOperate
    result.cube = ccAny
    result.say = "nothing on the chute - pressing"

proc scriptedOrder*(sim: Sim, seat: int, kind: ScriptKind): Order =
  ## Rule-based order for `seat`. Always inside both enums by construction
  ## (asserted in tests/test_baseline.nim) and never raises.
  case kind
  of skStripper: sim.stripperOrder(seat)
  of skFreerider: sim.freeriderOrder(seat)
  else: sim.stewardOrder(seat)
