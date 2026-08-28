## The JS wire-constants block: the handful of engine constants the browser
## chrome must agree with (playback speeds, fps, the chrome sprite id).
##
## Kept from `coworld-ctf/src/ctf/wire_constants.nim`, and **the global keeps
## its name**: `client/chrome_common.js` reads `window.CTF_WIRE` at its line 72
## and that file ships byte-for-byte, so renaming the global would force a byte
## change in a file that must not change.
##
## Historically each HTML client re-typed these as literals and nothing
## enforced agreement — a retuned `PlaybackSpeeds` would silently desync every
## client. This module renders them ONCE, from the same Nim consts the engine
## runs on; `server.nim` splices the block into every served client page and
## `tools/gen_wire_constants.nim` emits it for the static wasm bundle.

import std/strutils

import ./sim_types, ./global

proc jsIntArray(values: openArray[int]): string =
  result = "["
  for i, value in values:
    if i > 0: result.add ","
    result.add $value
  result.add "]"

const WireConstantsJs* =
  # 0.5 is the replay-only half speed (ReplayHalfSpeedIndex, command '5');
  # it rides ahead of the engine's integer PlaybackSpeeds.
  "window.CTF_WIRE={speeds:[0.5," & jsIntArray(PlaybackSpeeds)[1..^1] &
  ",fps:" & $TargetFps &
  ",chromeSpriteId:" & $BroadcastChromeSpriteId &
  ",cell:" & $CellPx &
  ",cols:" & $Cols &
  ",rows:" & $Rows &
  ",maxSay:" & $MaxSayLen &
  ",maxNotes:" & $MaxNotesLen &
  "};"

const WireConstantsMarker* = "<!-- WIRE_CONSTANTS -->"
  ## The placeholder the client HTML carries where the block belongs (before
  ## any script that reads window.CTF_WIRE).

proc spliceWireConstants*(page: string): string =
  ## Replaces the marker with the inline constants script. A page without the
  ## marker passes through unchanged.
  page.replace(WireConstantsMarker,
    "<script>" & WireConstantsJs & "</script>")
