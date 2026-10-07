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

Best after run 1: **gen2** (superseded by `exp-all4`, see step 1). The plateau at gen3 most likely comes from label quality
(5k-node searches) and data volume, not the training loop. Note that 400
games carries about ±30 Elo of error, so future decisions use SPRT.

## Plan

### Step 1: training experiments on existing data (done 2026-10-07)
`scripts/experiments.sh` trains three variants on the 20M existing positions
and runs SPRT [0, 10] (up to 2000 games) for each against the current best:

- [x] `all4`: all four generations instead of the last three. **H1: +56 ± 25** vs gen2 (+277 =126 −183, 586 games)
- [x] `wdl40`: WDL 0.4 instead of 0.25. **H0: −117 ± 40** vs gen2 (+60 =53 −143, 256 games). Game results from fast adjudicated games look like noisy labels; try going lower (0.1) instead
- [x] `e30`: 30 epochs instead of 15. **Inconclusive: +9 ± 14** vs gen2 after the full 2000 games (+818 =415 −767, LLR 0.81). At best a small gain

Promote any H1 winner by hand: `echo nets/exp-<name>.nnue > nets/best.txt`.

**Outcome:** `all4` promoted to best. Follow-ups worth one SPRT each before
step 2: all four generations with WDL 0.1 (the opposite direction from
`wdl40`), and `all4` with 30 epochs.

### Run 2 (started 2026-10-07 11:00)
One unattended chain: the two follow-ups vs `exp-all4` (strongest SPRT winner
promoted automatically), then generation 4 with 20M positions at 10k
nodes/move, trained on all five generations and promoted only on SPRT H1:

```
caffeinate -i bash -c 'PROMOTE=1 scripts/experiments.sh && GENS=5 NODES=10000 POSITIONS=20000000 WINDOW=5 scripts/pipeline.sh'
```

- [x] `all4-wdl10`: all four generations, WDL 0.1. **H1: +146 ± 49** vs `exp-all4` (+103 =37 −34, 174 games). **Promoted.** Search scores are far better labels than results of fast adjudicated games
- [x] `all4-e30`: all four generations, 30 epochs. Inconclusive: −2 ± 13 after 2000 games. More epochs don't help at this data size
- [ ] gen4: 20M @ 10k nodes with `exp-all4-wdl10`, trained on gen0–4, plus 350k positions from pi1 (staged in `data/cluster/`, appended before training). pi1 was stopped at 80 °C, then brought back at 12:49 under a thermal guard (`scripts/pi-thermal-guard.sh`: pause datagen at 75 °C, resume at 68 °C) for the rest of gen4 (~200 pos/s per Pi 5 at 10k nodes while running)

Note for the next training run: the default `--wdl` (0.25) is now known to be too high; use 0.1.

### Opening book (built 2026-10-07)
Self-play used to start from 8–9 random moves. `zchess book` builds a book from
the Lichess broadcast database (over-the-board tournament games, CC0):
all 81 months from 2020-01 to 2026-09 (715 MB, `data/lichess/`). That's 1.26M
games, of which 440k have both players rated 2000+, giving 493k distinct
positions from plies 8–20 in `data/book.fen` (67 s to build):

```
zchess book --out data/book.fen data/lichess/*.pgn.zst
```

Use it with `datagen --book data/book.fen` (and `match --book` for realistic
test openings). Not used by gen4, which was already running; first use is gen5,
which should be SPRT'd against gen4 to measure the book's effect.

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
