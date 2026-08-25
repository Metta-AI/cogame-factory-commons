## The event WIRE FORMAT, shared by live emission and a re-read of the replay.
##
## Forked from `coworld-ctf/src/ctf/events.nim`, and it keeps that file's one
## non-negotiable rule: both paths must produce BYTE-IDENTICAL rows. A consumer
## cannot be asked to tell them apart, and a second serializer would drift the
## moment a field is added — which is why the sim emits finished `JsonNode`
## rows through `sim_state.emit` and this module only ever reads them.
##
## Events never enter `gameHash`, so nothing here can affect determinism.

import std/[json, strutils, tables]

import ./sim_types

proc isKnownEventKind*(kind: string): bool =
  ## True when `kind` is in the declared vocabulary. tests/test_replay.nim
  ## sweeps every recorded row through this, so a typo cannot reach a replay.
  for known in EventKinds:
    if known == kind:
      return true
  false

proc validateEvents*(events: openArray[JsonNode], ticks: int) =
  ## Raises on any row that is not a well-formed event of a declared kind
  ## inside `0 ..< ticks`.
  for row in events:
    if row.kind != JObject:
      raise newException(FactoryError, "event row is not an object")
    let kind = row{"k"}.getStr()
    if not isKnownEventKind(kind):
      raise newException(FactoryError, "unknown event kind: " & kind)
    let tick = row{"t"}
    if tick.isNil or tick.kind != JInt:
      raise newException(FactoryError, "event row has no integer tick")
    if tick.getInt() < 0 or tick.getInt() >= max(1, ticks):
      raise newException(FactoryError,
        "event tick " & $tick.getInt() & " outside 0 ..< " & $ticks)

proc eventCounts*(events: openArray[JsonNode]): Table[string, int] =
  result = initTable[string, int]()
  for row in events:
    let kind = row{"k"}.getStr()
    result[kind] = result.getOrDefault(kind) + 1

proc jsonRow*(event: JsonNode): JsonNode =
  ## One JSON-lines row. The sim already emits finished rows, so this is the
  ## identity — kept as the named seam every consumer goes through, exactly as
  ## paintbot's `jsonRow` is.
  event

proc eventsJsonl*(
    events: openArray[JsonNode], ticks: int, summaryExtra: JsonNode = nil
): string =
  ## The full JSON-lines stream: one row per event, then a summary.
  ##
  ## The trailing summary row is part of the contract, not decoration — it is
  ## how a reader distinguishes "this episode had no events" from "the file was
  ## truncated", and it carries the GameVersion the events were produced under
  ## so a consumer never has to infer it.
  var lines = newSeqOfCap[string](events.len + 1)
  for event in events:
    lines.add($event.jsonRow())
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %ticks
  summary["events"] = %events.len
  summary["gameVersion"] = %GameVersion
  if summaryExtra != nil:
    for key, value in summaryExtra:
      summary[key] = value
  lines.add($summary)
  result = ""
  for line in lines:
    result.add(line)
    result.add('\n')
