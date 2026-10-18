## Stream complete private candidates; shared review owns training admission.
import std/[json, os, osproc, strutils]
import factory_commons/[llm, scripted, sim, prompts, evidence, replays]

const OperatorPrompt = "Keep the factory productive and maximize your own banana score."

when isMainModule:
  let args = commandLineParams()
  if args.len notin [2, 3, 4, 6]:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT [PROMPT_VARIANT PROMPT_SEED]]", 1)
  let output = absolutePath(args[0])
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len >= 4: args[3] else: "factory-commons"
  let selection = promptSelection(if args.len == 6:
    %*{"promptVariant": args[4], "promptSeed": parseInt(args[5])} else: newJObject())
  if selection.selectedVariant in {pvHeldoutBriefing, pvHeldoutReference}:
    raise newException(ValueError, "held-out wording is evaluation-only")
  doAssert games >= 10 and firstSeed >= 1
  doAssert not dirExists(output) and not fileExists(output)
  let status = execCmdEx("git status --porcelain")
  doAssert status.exitCode == 0 and status.output.strip().len == 0,
    "Commit qualified source before generating a pinned candidate corpus"
  let head = execCmdEx("git rev-parse HEAD")
  doAssert head.exitCode == 0
  let revision = head.output.strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig = newJNull()
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant: variantConfig = entry["game_config"]
  doAssert variantConfig.kind == JObject
  writePrivate(output / "trajectories.jsonl", "")
  writePrivate(output / "execution.jsonl", "")
  let stream = open(output / "trajectories.jsonl", fmAppend)
  let execution = open(output / "execution.jsonl", fmAppend)
  var runs = newJArray()
  try:
    for seed in firstSeed ..< firstSeed + games:
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2"]
      runtimeConfig["seed"] = %seed
      config.update($runtimeConfig)
      var sim = initSim(config)
      let family = "factory-commons-" & $seed
      let episode = family & "-" & variant & "-" & $selection.selectedVariant & "-" & $selection.seed
      var count = 0
      while not sim.done:
        let turn = sim.shift + 1
        let snapshot = sim
        var orders: array[SeatCount, Order]
        var records: array[SeatCount, JsonNode]
        for seat in 0 ..< SeatCount:
          let system = systemPrompt(snapshot, seat, selection)
          let user = userPrompt(snapshot, seat, OperatorPrompt)
          let messages = %*[{"role": "system", "content": system}, {"role": "user", "content": user}]
          var view = snapshot.observationJson(seat)
          view["prompt_template"] = selection.promptMetadata(system, user)
          let proposal = orderJson(scriptedOrder(snapshot, seat, skSteward))
          var parsed = parseOrder(proposal)
          parsed.source = osScripted
          orders[seat] = parsed
          let installed = orderJson(parsed)
          let accepted = proposal == installed
          let id = count + seat
          let attemptId = $id & "-teacher"
          let attempt = %*{
            "attempt_id": attemptId, "policy": "scripted-steward", "origin": "teacher",
            "inference_mode": "text_action", "prompt": messages,
            "response": $proposal, "parsed_action": proposal, "accepted": accepted,
            "request": newJNull(), "platform_call_id": newJNull(), "behavior_logprobs": newJNull(),
            "rejection_reason": (if accepted: newJNull() else: %"engine-normalized-submission")
          }
          records[seat] = %*{
            "schema_version": "1", "event_type": "decision", "episode_id": episode,
            "decision_id": $id, "decision_index": id,
            "game": "factory-commons", "game_version": "source-" & revision,
            "source_revision": revision, "seat": $seat, "visibility": "private",
            "observation": view, "prompt": (if accepted: messages else: newJNull()),
            "attempts": [attempt], "selected_attempt_id": (if accepted: %attemptId else: newJNull()),
            "executed_action": installed, "action_status": (if accepted: "accepted" else: "fallback"),
            "fallback_origin": (if accepted: newJNull() else: %"engine-normalized-submission"),
            "terminal": false
          }
        let eventStart = sim.events.len
        for seat in 0 ..< SeatCount: sim.applyOrder(seat, orders[seat])
        let startTick = sim.tick
        let actions = sim.playShift()
        sim.checkEnd(false)
        var frames, events, decisionIds = newJArray()
        for tick in startTick ..< sim.tick: frames.add(frameJson(sim.frames[tick]))
        for index in eventStart ..< sim.events.len: events.add(sim.events[index])
        for seat in 0 ..< SeatCount:
          decisionIds.add(%($(count + seat)))
          records[seat]["terminal"] = %(sim.done and seat == SeatCount - 1)
        execution.writeLine($(%*{
          "schema_version": 1, "event_type": "turn_execution", "episode_id": episode,
          "decision_ids": decisionIds, "source_revision": revision,
          "visibility": "private", "turn": turn, "start_tick": startTick, "end_tick": sim.tick,
          "event_start": eventStart, "event_end": sim.events.len, "events": events,
          "kernel_actions": kernelActionsJson(actions), "frames": frames, "terminal": sim.done}))
        for record in records: stream.writeLine($record)
        count += SeatCount
      doAssert sim.reason == "complete"
      let outcome = sim.resultsJson(@["steward", "steward", "steward"])
      var participants = newJObject()
      for seat in 0 ..< SeatCount: participants[$seat] = %*{"score": sim.score(seat)}
      stream.writeLine($(%*{
        "schema_version": "1", "event_type": "episode", "episode_id": episode,
        "seed_family": family, "game": "factory-commons", "game_version": "source-" & revision,
        "source_revision": revision, "status": "completed", "outcome": outcome,
        "participant_outcomes": participants
      }))
      runs.add(%*{"seed": seed, "decisions": count, "scores": outcome["scores"],
        "shifts_played": sim.shift, "ticks_played": sim.tick, "ending": sim.ending})
  finally:
    execution.close()
    stream.close()
  writePrivate(output / "manifest.json", pretty(%*{
    "schema_version": 1, "game": "factory-commons", "variant": variant,
    "source_revision": revision, "teacher": "scripted-steward",
    "prompt_selection": selection.selectionMetadata(),
    "split_authority": "shared Coworld SDK and application importer by seed_family",
    "execution_evidence": "execution.jsonl", "runs": runs}) & "\n")
  echo "complete games=", games
