## Export complete certified Factory Commons games as Metta post-training examples.
## Usage: nim r --path:src tools/export_posttrain.nim OUTPUT GAMES [FIRST_SEED] [VARIANT]

import std/[json, os, osproc, strutils]
import factory_commons/[llm, scripted, sim, sim_config, sim_state, sim_types]

const OperatorPrompt = "Keep the factory productive and maximize your own banana score."
const Variants = ["factory-commons", "either-or", "fragile-plant",
  "abundant-feed"]

when isMainModule:
  let args = commandLineParams()
  if args.len notin 2 .. 4:
    quit("usage: export_posttrain OUTPUT GAMES [FIRST_SEED] [VARIANT]", 1)
  let output = args[0]
  let games = parseInt(args[1])
  let firstSeed = if args.len >= 3: parseInt(args[2]) else: 1
  let variant = if args.len == 4: args[3] else: Variants[0]
  if games < 10 or firstSeed < 1:
    quit("at least ten games and a positive first seed are required", 1)
  if variant notin Variants:
    quit("unknown variant: " & variant, 1)
  if dirExists(output) or fileExists(output):
    quit("output already exists: " & output, 1)
  createDir(output)
  let sourceRevision = execProcess("git rev-parse HEAD").strip()
  let manifest = parseFile("coworld_manifest_template.json")
  var variantConfig: JsonNode
  for entry in manifest["variants"]:
    if entry["id"].getStr() == variant:
      variantConfig = entry["game_config"]
  doAssert not variantConfig.isNil
  var
    trainRows: seq[string]
    validationRows: seq[string]
    runs = newJArray()
  for seed in firstSeed ..< firstSeed + games:
    var config = defaultGameConfig()
    let runtimeConfig = copy(variantConfig)
    runtimeConfig["tokens"] = %*["t0", "t1", "t2"]
    runtimeConfig["seed"] = %seed
    config.update($runtimeConfig)
    var sim = initSim(config)
    var rows: seq[string]
    while not sim.done:
      for seat in 0 ..< config.numAgents:
        let teacher = scriptedOrder(sim, seat, skSteward)
        let completion = %*{
          "job": $teacher.job,
          "cube": $teacher.cube,
          "say": teacher.say,
          "notes": teacher.notes
        }
        var parsed = parseOrder(completion)
        doAssert parsed.job == teacher.job and parsed.cube == teacher.cube and
          parsed.say == teacher.say and parsed.notes == teacher.notes
        parsed.source = osScripted
        rows.add($(%*{
          "episode_id": "factory-commons-" & variant & "-" & $seed,
          "seed": "factory-commons-" & variant & "-" & $seed,
          "decision_id": rows.len,
          "prompt": [
            {"role": "system", "content": systemPrompt(sim, seat)},
            {"role": "user", "content": userPrompt(sim, seat,
              OperatorPrompt)}
          ],
          "completion": [{"role": "assistant", "content": $completion}],
          "game": "factory-commons",
          "action_schema_revision": "factory-standing-order-v1"
        }))
        sim.applyOrder(seat, parsed)
      sim.playShift()
      sim.checkEnd(false)
    doAssert sim.reason == "complete"
    let outcome = sim.resultsJson(@["steward", "steward", "steward"])
    if seed mod 5 == 0:
      validationRows.add(rows)
    else:
      trainRows.add(rows)
    runs.add(%*{"seed": seed, "decisions": rows.len,
      "scores": outcome["scores"], "shifts_played": sim.shift,
      "ending": sim.ending})
  writeFile(output / "train.jsonl", trainRows.join("\n") & "\n")
  writeFile(output / "validation.jsonl", validationRows.join("\n") & "\n")
  writeFile(output / "manifest.json", pretty(%*{
    "schema_version": 1,
    "game": "factory-commons",
    "variant": variant,
    "source_revision": sourceRevision,
    "teacher": "scripted-steward",
    "operator_prompt": OperatorPrompt,
    "train_examples": trainRows.len,
    "validation_examples": validationRows.len,
    "runs": runs
  }) & "\n")
  echo "train=", trainRows.len, " validation=", validationRows.len
