# Factory Commons Jev pilot

The results below used the superseded game-side Jev path in production
version 0.1.4. The corrective player-policy integration is merged in source but
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

Run the deterministic suite with `nimby sync nimby.lock` and `nim r --hints:off --path:src tests/test_llm.nim`. The seven repository test files passed locally.

## Production canary

Version 0.1.4 passed hosted smoke and all ten certification checks. The release job reported failure while certification was still running; the live Coworld became canonical afterward. Private Experience Request `xreq_87c64656-b83d-40ca-9522-9459d2f176ae` seated relh-owned `factory-commons-jev-20260924:v1` against two active coordinator v2 policies. The request had a $0.05 combined player model cap and made no ladder submission.

The three-shift episode completed with scores 16/3/0. The Jev seat made three model-sourced orders with zero fallback, confirmed by the replay and game log. Its five strip actions reduced cap to 20 and ruined the factory, so the win does not show socially useful play. The recorded 3,350–4,994 ms latencies are whole decision batches shared with the two prompt opponents, not Jev-only response times. Hosted player-model spend was not available at readback; the episode's $0.007427 execution cost is a separate charge. Resolve the local TypeSafe alias against the hosted model and run more matched episodes before making a cost or performance claim.
