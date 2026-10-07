# Training log and plan

## Run 1 (2026-10-07), M2 Pro

Setup: (768 → 256)×2 → 1 SCReLU, 8 output buckets. Each generation: 5M
self-play positions at 5k nodes/move, trained on the last 3 generations for
15 epochs, WDL 0.25. Matches: 400 games at 10k nodes/move.

| Net | Opponent | Result | Score | Elo |
|---|---|---|---|---|
| gen0 | hand-crafted eval | +204 =96 −100 | 63.0% | +92 ± 31 |
| gen1 | gen0 | +200 =107 −93 | 63.4% | +95 ± 30 |
| gen2 | gen1 | +193 =77 −130 | 57.9% | +55 ± 31 |
| gen3 | gen2 | +152 =85 −163 | 48.6% | −10 ± 30 (rejected) |
| gen2 | hand-crafted eval (direct) | +281 =56 −63 | 77.3% | +212 ± 37 |

Best: **gen2**. The plateau at gen3 most likely comes from label quality
(5k-node searches) and data volume, not the training loop. Note that 400
games carries about ±30 Elo of error, so future decisions use SPRT.

## Plan

### Step 1: training experiments on existing data (running 2026-10-07)
`scripts/experiments.sh` trains three variants on the 20M existing positions
and runs SPRT [0, 10] (up to 2000 games) for each against the current best:

- [x] `all4`: all four generations instead of the last three. **H1: +56 ± 25** vs gen2 (+277 =126 −183, 586 games)
- [ ] `wdl40`: WDL 0.4 instead of 0.25
- [ ] `e30`: 30 epochs instead of 15

Promote any H1 winner by hand: `echo nets/exp-<name>.nnue > nets/best.txt`.

### Step 2: better data, overnight (~3–4 h)
20M positions at 10k nodes/move with the best net, keeping the Mac awake on
mains power:

```
GENS=5 NODES=10000 POSITIONS=20000000 caffeinate -i scripts/pipeline.sh
```

(gen0–3 are skipped as already done; this produces gen4 trained on gen2–4.)

### Step 3: bigger net, once there are ~30M+ good positions
512 hidden. `nnue.HIDDEN` is a compile-time constant, so the in-process
`match` can't compare a 512 net with a 256 net. That needs a build option per
size plus `cutechess-cli` for cross-binary matches, or a runtime-sized network.

### Later
- King-relative input buckets (big gain in strong engines, but data-hungry).
- Search parameter tuning (separate from training).
