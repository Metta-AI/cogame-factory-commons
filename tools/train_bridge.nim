## Persistent JSONL decision bridge for Metta reinforcement learning.
## nim c -d:release --path:src -o:factory-train-bridge tools/train_bridge.nim
## factory-train-bridge coworld_manifest_template.json [VARIANT]

import std/[json, os]
import factory_commons/[llm, scripted, sim, sim_config, sim_state, sim_types]

const OperatorPrompt = "Keep the factory productive and maximize your own banana score."

proc seedOf(value: string): int =
  var hash = 2166136261'u32
  for ch in value:
    hash = (hash xor uint32(ord(ch))) * 16777619'u32
  int(hash and 0x7fffffff'u32)

proc decision(game: Sim, seat, id: int): JsonNode =
  %*{
    "kind": "decision",
    "game": "factory-commons",
    "decision_id": id,
    "seat": seat,
    "engine_seat": seat,
    "turn": game.shift + 1,
    "semantic_view": game.observationJson(seat),
    "inbox": [],
    "messages": [
      {"role": "system", "content": systemPrompt(game, seat)},
      {"role": "user", "content": userPrompt(game, seat, OperatorPrompt)}
    ],
    "speech_messages": [],
    "action_schema": {"type": "object", "required": ["job", "cube"]},
    "typed_question": newJNull()
  }

proc encoding(game: Sim, seat, id: int): JsonNode =
  let state = game.observationJson(seat)
  var values = newJArray()
  for other in 0 .. 2:
    values.add(%(if other == seat: 1 else: 0))
  for key in ["shift", "shifts", "ticksPerShift", "tick"]:
    values.add(state[key])
  let machine = state["machine"]
  for key in ["integrity", "cap", "cooldown", "pressYield", "stripYield",
      "presses", "strips", "repairs", "bananasMade", "pressFloor",
      "stripFloor", "capMin"]:
    values.add(machine[key])
  for key in ["pressLegal", "stripLegal", "eitherOr"]:
    values.add(%(if machine[key].getBool(): 1 else: 0))
  values.add(machine["stock"]["pink"])
  values.add(machine["stock"]["blue"])
  for cog in state["cogs"]:
    values.add(cog["cell"][0])
    values.add(cog["cell"][1])
    for key in ["eaten", "banked", "score", "presses", "strips", "repairs", "misfeeds"]:
      values.add(cog[key])
    values.add(%(if cog{"you"}.getBool(false): 1 else: 0))
  var jobs = newJArray()
  for job in Job:
    let name = $job
    jobs.add(if name in game.legalJobs(): %name else: newJNull())
  var cubes = newJArray()
  for cube in CubeChoice:
    cubes.add(%($cube))
  %*{
    "decision_id": id,
    "values": values,
    "action_heads": [
      {"name": "job", "choices": jobs},
      {"name": "cube", "choices": cubes}
    ]
  }

when isMainModule:
  let args = commandLineParams()
  if args.len notin 1 .. 2:
    quit("usage: factory-train-bridge MANIFEST [VARIANT]", 1)
  let variant = if args.len == 2: args[1] else: "factory-commons"
  let manifest = parseFile(args[0])
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil, "unknown variant: " & variant
  var game: Sim
  var seat = 0
  var id = 0
  while not stdin.endOfFile:
    let request = parseJson(stdin.readLine())
    var response: JsonNode
    case request["kind"].getStr()
    of "reset":
      doAssert request["players"].getInt() == 3
      var config = defaultGameConfig()
      let runtimeConfig = copy(variantConfig)
      runtimeConfig["tokens"] = %*["t0", "t1", "t2"]
      runtimeConfig["seed"] = %seedOf(request["seed"].getStr())
      config.update($runtimeConfig)
      game = initSim(config)
      seat = 0
      id = 0
      response = game.decision(seat, id)
    of "encode":
      doAssert not game.done
      response = game.encoding(seat, id)
    of "teacher":
      doAssert not game.done
      let order = scriptedOrder(game, seat, skSteward)
      response = %*{"response": $(%*{"job": $order.job, "cube": $order.cube})}
    of "step":
      doAssert not game.done and request["decision_id"].getInt() == id
      let action = parseJson(request["response"].getStr())
      var order = parseOrder(action)
      doAssert $order.job in game.legalJobs()
      order.source = osLlm
      game.applyOrder(seat, order)
      inc seat
      if seat == 3:
        game.playShift()
        game.checkEnd(false)
        seat = 0
      inc id
      var observation: JsonNode
      if game.done:
        let outcome = game.resultsJson(@["learner", "opponent", "opponent"])
        var scores = newJObject()
        for index in 0 .. 2:
          scores[$index] = outcome["scores"][index]
        observation = %*{"kind": "terminal", "scores": scores}
      else:
        observation = game.decision(seat, id)
      response = %*{"kind": "accepted", "action": action, "observation": observation}
    else:
      raise newException(ValueError, "unknown command: " & request["kind"].getStr())
    stdout.writeLine($response)
    stdout.flushFile()
