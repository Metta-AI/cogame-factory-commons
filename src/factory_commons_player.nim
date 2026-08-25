## Factory Commons player: a policy is just a prompt.
##
## Ported from `cogame-bullwhip/src/bullwhip_player.nim`. Connects to the game,
## delivers its prompt, then only listens. ALL decision making happens inside
## the game container, which sends this seat's prompt to Claude at every shift
## boundary — as one parallel batch with the other two seats, because decisions
## in a shift are simultaneous by rule.
##
## `PLAYER_SCRIPTED=steward|stripper|freerider` registers the seat as a built-in
## baseline instead. The game plays those deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <factory-commons-image> --name my-factory-commons \
##     --run /bin/factory-commons-player \
##     --secret-env PLAYER_PROMPT="<your strategy>" --secret-env USE_BEDROCK=true

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
You run this plant and you intend it to be running at the final whistle. Read
integrity and cap first, every shift. Cap is the only number that never
recovers - if it is still 100, the machine has never been stripped and your job
is to keep it that way. Rust takes one integrity every twenty ticks, so the
plant loses about three a shift before anyone touches it: whenever integrity
drops below 75, take a cube to the bay and `maintain` until it is back up.
Otherwise `operate`, and pick the cube colour the hopper has least of, because
a press needs one of each and a lopsided hopper is a stalled machine. Say your
lane out loud in the form 'operate pink' or 'maintain' so the other two can
cover what you left. Never strip: four bananas now costs the room sixteen cap
and costs you every press for the rest of the episode. If a chute cell is
stacked three deep, go eat - bananas rot in a hundred and eighty ticks and a
rotted banana helps nobody.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "factory-commons player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "factory-commons player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## The receive loop is wrapped in `try/except CatchableError` and exits 0 on a
  ## closed or truncated socket. whisky's `receiveMessage` RAISES on a close
  ## frame or a truncated read (only a timeout returns `none`), and the game's
  ## `quit(0)` can outrun its own flushed `final` frame — so without this the
  ## player exits 1 on a race that passes one dispatch and fails the next
  ## (raid 0.1.3 -> 0.1.4, 2026-08-23).
  var running = true
  while running:
    var received: Option[Message]
    try:
      received = socket.receiveMessage()
    except CatchableError as error:
      echo "factory-commons player: socket closed (", error.msg,
        "); exiting cleanly"
      break
    if received.isNone:
      echo "factory-commons player: connection closed, exiting"
      break
    let message = received.get()
    if message.kind != TextMessage:
      continue
    try:
      let payload = parseJson(message.data)
      case payload{"type"}.getStr()
      of "welcome":
        echo "factory-commons player: seated at slot ",
          payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
          " (variant ", payload{"variant"}.getStr(), ", ",
          payload{"shifts"}.getInt(), " shifts)"
        ## Re-deliver the prompt after the welcome, in case the first send
        ## raced the server's slot registration.
        socket.send(promptFrame())
      of "state":
        ## Informational: the seat does not decide here. Log one compact line so
        ## a hosted player log shows the episode progressing.
        let machine = payload{"machine"}
        echo "factory-commons player: shift ", payload{"shift"}.getInt(),
          "/", payload{"shifts"}.getInt(),
          " integrity ", machine{"integrity"}.getInt(),
          " cap ", machine{"cap"}.getInt(),
          " band ", machine{"band"}.getStr(),
          " score ", payload{"you"}{"score"}.getInt()
      of "final":
        echo "factory-commons player: final scores ", payload{"scores"},
          " reason ", payload{"reason"}.getStr(),
          " ending ", payload{"ending"}.getStr()
        running = false
      else:
        discard
    except CatchableError as error:
      echo "factory-commons player: ignoring bad frame: ", error.msg
  try:
    socket.close()
  except CatchableError:
    discard
