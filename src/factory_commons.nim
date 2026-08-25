## Factory Commons game entrypoint.
##
## Forked from `coworld-ctf/src/ctf.nim`, including its one non-negotiable
## ordering rule: the seed is randomised BEFORE `config.update`, so every
## seed-derived draw follows the FINAL seed. The same sentinel handling is kept
## — a config that pins the legacy compiled-in seed (or pins none at all) gets a
## fresh random one, because a publicly known fixed seed is a publicly known
## episode.

import
  std/[json, os, sysrand],
  bitworld/runtime,
  factory_commons/sim,
  factory_commons/server

const LegacyFixedSeed = 1234567
  ## The compiled-in default. Hosted variant configs may carry this exact
  ## value, so it doubles as the "nobody chose a seed" sentinel.

proc seedPinned(configJson: string): bool =
  ## True when the runtime config explicitly pins a seed other than the default
  ## (fixture recordings, the certification fixture, forensic re-runs).
  if configJson.len == 0:
    return false
  try:
    let node = parseJson(configJson)
    node.kind == JObject and node.hasKey("seed") and
      node["seed"].getInt != LegacyFixedSeed
  except CatchableError:
    false  # config.update reports the real parse error.

proc randomSeed(): int =
  ## A crypto-random 31-bit seed from the OS.
  var buf: array[4, byte]
  if not urandom(buf):
    raise newException(FactoryError, "OS entropy source unavailable")
  (int(buf[0]) shl 24 or int(buf[1]) shl 16 or
    int(buf[2]) shl 8 or int(buf[3])) and 0x7FFF_FFFF

proc stripUnpinnedSeed(configJson: string): string =
  ## Drops the sentinel seed from an unpinned config so it cannot clobber the
  ## randomised seed injected before `config.update`.
  if configJson.len == 0:
    return configJson
  try:
    let node = parseJson(configJson)
    if node.kind == JObject and node.hasKey("seed"):
      node.delete("seed")
    $node
  except CatchableError:
    configJson  # config.update reports the real parse error.

proc echoStartupConfig(config: GameConfig, runtimeConfig: RuntimeConfig) =
  ## Prints the effective startup config. Never the tokens — they are secrets.
  log "config: host=" & runtimeConfig.host &
    " port=" & $runtimeConfig.port &
    " variant=" & config.variantName() &
    " seed=" & $config.seed &
    " seats=" & $config.numAgents &
    " shifts=" & $config.shifts &
    " ticksPerShift=" & $config.ticksPerShift &
    " eitherOr=" & $config.eitherOr &
    " rustPeriod=" & $config.rustPeriod &
    " stripCapLoss=" & $config.stripCapLoss &
    " dispensePeriod=" & $config.dispensePeriod &
    " minTurnSeconds=" & $config.minTurnSeconds &
    " llmTimeoutSeconds=" & $config.llmTimeoutSeconds

when isMainModule:
  let runtimeConfig = readRuntimeConfig()
  var config = defaultGameConfig()
  if seedPinned(runtimeConfig.config):
    config.update(runtimeConfig.config)
  else:
    ## Randomise BEFORE parsing: `config.update` resolves everything
    ## seed-derived, so the randomised seed must already be in place.
    config.seed = randomSeed()
    config.update(stripUnpinnedSeed(runtimeConfig.config))
    log "seed not pinned; randomized"
  if config.tokens.len == 0:
    ## A bare local run with no tokens still has to seat somebody, so mint the
    ## development tokens `tools/ci/docker_smoke.sh` uses.
    for seat in 0 ..< config.numAgents:
      config.tokens.add("token-" & $seat)
    log "no tokens in config; using development tokens"
  config.echoStartupConfig(runtimeConfig)
  runGameServer(config, runtimeConfig)
