# Tuning the baseline constants

`tests/test_feasibility.nim` is the **gate** — it fails CI when the economy stops being a dilemma.
`tools/tune/feasibility_sweep.nim` is the **sweep** that chose the numbers the gate holds, so the
shipped constants are measured rather than guessed. Re-run it after any change to a constant in
`src/factory_commons/sim_config.nim` and paste the new table here:

```
nim c -d:release -r tools/tune/feasibility_sweep.nim
```

Columns: **(a)** seeds where an all-steward room ends `complete`/`shift_limit` with `cap == 100`,
`integrity >= 40`, `>= 70` bananas and **every seat `>= 14`**; **seat** the worst seat score seen on
any seed; **made** the mean all-steward banana total; **(b)** seeds where a lone stripper out-scores
both stewards; **(c) max** the worst (highest) all-stripper share of the all-steward total (the gate
wants `< 35 %`) and **ruin** the seeds that end `factory_ruined` with `cap <= 40`; **(d)** seeds
where one free-rider is survivable but pays.

## The run that chose the shipped values

```
factory-commons baseline sweep — seeds 1..12, default variant, scripted rooms only
gates: (a) all-steward sustains  (b) lone stripper out-scores both stewards  (c) all-stripper ruinous  (d) free-rider survivable

cell                                 (a)  seat   made      (b)   (c) max    ruin      (d)
--------------------------------------------------------------------------------------------
move 2 rust 20 gain 8 eat 3         0/12     6     46    12/12    32.6%   12/12     0/12
move 2 rust 20 gain 8 eat 4         0/12    15     50    12/12    30.0%   12/12     0/12
move 2 rust 20 gain 8 eat 6         0/12    14     49    12/12    30.6%   12/12     0/12
move 2 rust 30 gain 8 eat 3         0/12     7     48    12/12    31.2%   12/12    12/12
move 2 rust 30 gain 8 eat 4         0/12    14     51    12/12    29.4%   12/12    12/12
move 2 rust 30 gain 8 eat 6         0/12    13     51    12/12    29.4%   12/12    12/12
move 2 rust 30 gain 10 eat 3        0/12     7     49    12/12    30.6%   12/12    12/12
move 2 rust 30 gain 10 eat 4        0/12    14     51    12/12    29.4%   12/12    12/12
move 2 rust 30 gain 10 eat 6        0/12    13     52    12/12    28.8%   12/12    12/12
move 1 rust 20 gain 8 eat 3        12/12    25     83    12/12    18.1%   12/12    12/12
move 1 rust 20 gain 8 eat 4         0/12    11     66    12/12    22.7%   12/12    12/12
move 1 rust 20 gain 8 eat 6        12/12    21     76    12/12    19.7%   12/12    12/12
move 1 rust 30 gain 8 eat 3        12/12    19     72    12/12    20.8%   12/12    12/12
move 1 rust 30 gain 8 eat 4        12/12    30     92    12/12    16.3%   12/12     0/12
move 1 rust 30 gain 8 eat 6        12/12    25     83    12/12    18.1%   12/12    12/12
move 1 rust 30 gain 10 eat 3        0/12    19     69    12/12    21.7%   12/12    12/12
move 1 rust 30 gain 10 eat 4       12/12    25     93    12/12    16.1%   12/12     0/12
move 1 rust 30 gain 10 eat 6       12/12    24     86    12/12    17.4%   12/12    12/12

stripCapLoss column (shipped move/rust/gain/eat, gate (c) is the point)
--------------------------------------------------------------------------------------------
stripCapLoss 12                    12/12    25     83    12/12    19.3%    0/12    12/12
stripCapLoss 16                    12/12    25     83    12/12    18.1%   12/12    12/12
stripCapLoss 20                    12/12    25     83    12/12    14.5%   12/12    12/12

shipped: move 1 rust 20 gain 8 stripCapLoss 16 eat 3
```

## What the table decides

- **`moveCooldown 2 -> 1`** (rung 3 of the design note's gate-(a) ladder) is the only cell in the
  `move 2` half that gets anywhere: at `moveCooldown 2` gate (a) is 0/12 on *every* combination of
  the other four constants, because the all-steward room makes ~46–52 of the required 70 bananas.
  Rungs 1 and 2 (`rustPeriod 20 -> 30`, `repairGain 8 -> 10`) move the total by 2–6 bananas and never
  clear the bar, which is why they keep their authored values.
- **`eatTrigger` keeps the note's authored 3.** At the shipped `move 1 rust 20 gain 8` it is the best
  cell in the table on every column that matters (12/12, worst seat 25, 83 bananas) — better than the
  6 this repo shipped before review (12/12, worst seat 21, 76). `eatTrigger 4` measures 0/12 with a
  worst seat of 11 at the same rung, which is the sharpest illustration in the table that these
  numbers cannot be reasoned out: 4 sits between two values that both pass.
- **`stripCapLoss 12 -> 16`** (rung 1 of the note's gate-(c) ladder) is load-bearing: at 12 an
  all-stripper room ends `factory_ruined` on **0/12** seeds — it stalls at `SEIZED` with cap stuck
  above `pressFloor` instead of scrapping the plant. At 16 it ruins on 12/12. The consequence the
  note's prose does not carry is that the plant now scraps after **five** overrides rather than
  seven, and the private campaign is ~15 bananas rather than 13 — still a fifth of the cooperative
  total, which is the invariant gate (c) states.
- The ladder is **not monotone**: `move 1 rust 30 gain 10 eat 3` is 0/12 while both of its neighbours
  are 12/12. That is the reason this file exists rather than a paragraph of arithmetic.
