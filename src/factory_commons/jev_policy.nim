## Jev selects a standing order from one Factory Commons seat observation.
## The game supplies visible state and validates the returned action.

import std/[json, os, strutils]
import curly

proc chooseAction*(observation: JsonNode, operatorPrompt: string): JsonNode =
  var criteria = newJObject()
  for item in observation["legalJobs"]:
    let job = item.getStr()
    if job in ["operate", "strip", "maintain"]:
      for cube in ["pink", "blue"]:
        criteria[job & "_" & cube] = %(job & " using a " & cube &
          " cube for the next shift")
    else:
      criteria[job] = %(job & " for the next shift")

  let sidecar = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  let capture = getEnv("METTA_CAPTURE_URL").strip()
  let directKey = getEnv("TYPESAFE_API_KEY").strip()
  var endpoint: string
  var model: string
  var key: string
  if sidecar.len > 0:
    endpoint = sidecar
    model = "typesafe/jev-1.13"
  elif capture.len > 0:
    endpoint = capture
    model = "typesafe/jev-1.13"
    key = getEnv("METTA_CAPTURE_KEY").strip()
  else:
    endpoint = getEnv("TYPESAFE_BASE_URL", "https://api.typesafe.ai")
    model = getEnv("TYPESAFE_DEFAULT_MODEL", "jev-latest")
    key = directKey
  if endpoint.len == 0 or (sidecar.len == 0 and key.len == 0):
    raise newException(ValueError, "Jev player has no model transport")

  var headers: HttpHeaders
  headers["content-type"] = "application/json"
  if key.len > 0:
    headers["authorization"] = "Bearer " & key
  let body = %*{
    "model": model,
    "state": "You are playing Factory Commons. Choose a standing order " &
      "from your seat observation. Account for your final banana score " &
      "and how the other cogs affect the shared factory. Operator guidance: " &
      operatorPrompt & "\nObservation:\n" & $observation,
    "questions": {"decision": {
      "type": "choice",
      "instructions": "Choose the standing order that best serves your goal under the game rules.",
      "criteria": criteria
    }}
  }
  let response = newCurly().post(endpoint.strip(chars = {'/'},
    leading = false) & "/v1/systemone", headers, $body, 30)
  if response.code < 200 or response.code >= 300:
    raise newException(ValueError, "Jev HTTP " & $response.code)
  let payload = parseJson(response.body)
  let answer = payload["answers"]["decision"]
  let probabilities = answer["probabilities"]
  if answer["type"].getStr() != "choice" or
      probabilities.len != criteria.len:
    raise newException(ValueError, "Jev returned the wrong choice set")
  var best = -1.0
  var total = 0.0
  var selected = ""
  for choice, probability in probabilities.pairs:
    if not criteria.hasKey(choice):
      raise newException(ValueError, "Jev returned an unknown choice")
    let value = probability.getFloat()
    if value < 0 or value > 1:
      raise newException(ValueError, "Jev probability outside [0, 1]")
    total += value
    if value > best:
      best = value
      selected = choice
  if abs(total - 1) > probabilities.len.float * 0.005 + 1e-6:
    raise newException(ValueError, "Jev probabilities do not sum to one")
  let parts = selected.split('_')
  result = %*{"job": parts[0], "cube":
    (if parts.len == 2: parts[1] else: "any"), "say": "", "notes": ""}
  echo "Factory Commons Jev player: choice ", selected,
    " model ", payload{"model"}.getStr(),
    " input_tokens ", payload["usage"]{"input_tokens"}.getInt(),
    " output_tokens ", payload["usage"]{"output_tokens"}.getInt()
