# Factory Commons Jev pilot

The results below used the superseded game-side Jev path in production
version 0.1.4. The corrective player-policy integration is under review and
has not been published to production. These scores are historical smoke
evidence, not proof of the corrected observation/action path.

The `PLAYER_JEV=1` policy asks System One to rank the legal standing orders for each shift. It uses the seat's game-side sidecar in hosted play and the TypeSafe API for local tests. The game still batches simultaneous model seats, attributes sidecar calls to the player slot, and falls back to the steward order after two failed attempts. Jev chooses a job and cube colour; it does not write the optional public `say` or private `notes` text.

## Local paired episodes

Each arm starts with the same game seed and learner seat. Other seats run the named scripted policy. Local calls used TypeSafe `jev-latest`, whose response identified `jev-1.13.0`. The direct response has token counts but no dollar spend field.

| Opponents | Seed | Jev seat 0 | Steward seat 0 | Jev calls | Ending |
| --- | ---: | ---: | ---: | ---: | --- |
| Steward, stripper | 7 | 2 | 2 | 3 | Factory ruined |
| Steward, stripper | 8 | 2 | 2 | 3 | Factory ruined |
| Steward, stripper | 9 | 2 | 2 | 3 | Factory ruined |
| Steward, steward | 7 | 26 | 26 | 15 | Shift limit |
| Steward, steward | 8 | 26 | 26 | 15 | Shift limit |
| Steward, steward | 9 | 15 | 26 | 4 | Factory ruined |

In the cooperative room, Jev chose `strip_pink` once in seeds 7 and 8 and twice in seed 9. Seed 9 ended early after the second override. The three seeds do not establish a performance difference; they do expose a decision failure worth testing with a larger opponent mix.

## Container proof

A `linux/amd64` image built and completed the repository's raw Docker smoke with `SMOKE_EXTRA_ENV=PLAYER_JEV=1` and a TypeSafe key forwarded only to the game container. The Jev seat made eight model decisions, all recorded as `source: llm` in the replay, with zero fallbacks. The eight decision batches averaged 259 ms and peaked at 469 ms. The episode ended normally; seat 0 scored 12 against steward 3 and stripper 10. This is an integration check, not a score comparison.

Run the deterministic suite with `nimby sync nimby.lock` and `nim r --hints:off --path:src tests/test_llm.nim`. The seven repository test files passed locally. A private production canary is still needed to verify the hosted sidecar and measure player model spend. The local Direct TypeSafe model alias and hosted sidecar name need resolved-model comparison before using these runs as a cost benchmark.
