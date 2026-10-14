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
- [x] gen4: 20M on the Mac @ 10k nodes with `exp-all4-wdl10`, plus 6.7M from the cluster (5 Pis + bitch-box), trained on gen0–4 (~47M positions) with WDL 0.1. **H1: +67 ± 29** vs `exp-all4-wdl10` (+199 =111 −118, 428 games). **Promoted: current best.** (pi5's 837k offline positions were collected afterwards into `gen4.bin`, total 27.6M.)

The trainer's default `--wdl` is now 0.1.

### External rating: gen4 vs Stockfish (2026-10-07)
`scripts/gauntlet.sh`: fastchess, 10+0.1 s, 1 thread, book openings, 200 games per level
against Stockfish 19 with `UCI_LimitStrength` / `UCI_Elo`:

| Stockfish UCI_Elo | Result | Score | Implied gen4 rating |
|---|---|---|---|
| 2200 | +199 =0 −1 | 99.5% | (too lopsided) |
| 2500 | +195 =3 −2 | 98.3% | (too lopsided) |
| 2800 | +149 =36 −15 | 83.5% | ~3080 ± 48 |
| 3000 | +83 =68 −49 | 58.5% | ~3060 ± 38 |
| 3190 (max) | +35 =74 −91 | 36.0% | ~3090 ± 33 |

**gen4 ≈ 3080 on Stockfish's UCI_Elo scale.** The limiter is calibrated at slower time
controls, so this is a consistent yardstick between nets rather than an official rating.

### Run 3: gen5 with the opening-book A/B test (started 2026-10-07 15:45)
`scripts/ab-book.sh`: 12M positions each at 10k nodes with gen4. A = book openings
(cluster), B = random openings (Mac). Both trimmed to equal size; two nets trained
identically on gen0–4 + A or + B; SPRT A vs B (book openings), then the winner vs gen4.

- [x] A vs B (book vs random openings, 12M positions each, otherwise identical):
  **+8.5 ± 12.6**, inconclusive after 2000 games (+706 =637 −657). The book is at
  most a small gain; it stays the default because it keeps positions realistic.
- [x] gen5-book vs gen4: **+22 ± 16**, SPRT crossed the H1 bound and stopped at 1276
  games (+460 =438 −378). **Promoted as gen5** (`nets/gen5.nnue`). The run printed
  "inconclusive": `match` judged the SPRT on the final totals, after the games still
  in flight had pulled the LLR back to 2.81. Fixed: the decision is now fixed at the
  moment a bound is crossed.
- Early observation: book-opening games are drawn ~46% of the time vs ~38% from random openings.

### Pi cluster and remote access (2026-10-07)
Six Pi 5s (`pi1`–`pi6`) and the `bitch-box` VM generate data next to the Mac. On
each host datagen runs as a systemd service (`zchess-datagen`, via
`scripts/run-datagen.sh`): it comes back after reboots, power cuts and crashes,
with a fresh seed each start, and `cluster.sh stop`/`collect` disable it. Each Pi
runs a thermal guard (pause at 75 °C, resume at 68 °C). They dial out over WireGuard to the
`bitch-box` hub, so the laptop reaches them from anywhere as `pi1-wg`…`pi4-wg`
(`10.99.0.11`–`.16`). SSH is key-only, the hub can't reach them, and only the
laptop's overlay addresses may SSH in. Nothing at home accepts inbound traffic.

Known issue: pi5 and pi6 dropped off Wi-Fi a few minutes into full load (generation
continued offline). pi5 is fine on Ethernet; suspect power (Pi 5 needs a 5 V / 5 A
supply under sustained load).

```
scripts/cluster.sh status                        # from anywhere (cluster/hosts.txt = overlay)
HOSTS_FILE=cluster/hosts-lan.txt scripts/cluster.sh status   # faster at home
scripts/cluster.sh collect <gen>                 # stop the Pis and fetch their data
scripts/wg-enroll-pi.sh pi5.local pi5 10.99.0.15 # add another Pi (after scripts/pi-key-only.sh)
```

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

### Overnight 2026-10-07 → 08 (Mac off; everything on bitch-box and the cluster)
- Width nets trained on all data gen0–5 (~71M positions, 15 epochs, WDL 0.1):
  `nets/h256-all.nnue` (val loss ~0.0036) and `nets/h512-all.nnue` (val loss 0.00332).
- bitch-box `~/zchess-overnight/run-overnight.sh` (progress.log, done): after the gen5
  gauntlet, (1) h256-all vs gen5, 10k nodes, SPRT [0,5]: does more data alone help;
  (2) h512-all vs h256-all, 8+0.08, SPRT [0,10]: does width pay for its speed.
- bitch-box gauntlets (compare on this host only): gen4 ≈ 2980 (2800 70.3%,
  3000 47.5%, 3190 27.0%); gen5 at 2800: 77.8% (gen4 70.3%), rest pending in
  `~/zchess-gauntlet/20261007-2202-gen5`.
- Cluster (pi1–pi5, bitch-box) generating gen6 data as services: `gen6book`, gen5 net,
  book openings, 10k nodes. Collect in the morning: `scripts/cluster.sh collect 6book`.
  pi6 still offline (Wi-Fi under load); its service is still on `gen5book`.

Overnight results (bitch-box):
- **Width: h512-all vs h256-all (same data), 8+0.08: +38 ± 17, SPRT H1** at 686 games
  (+206 =349 −131). The 512-wide net wins even after paying for its lower speed.
- **Data: h256-all vs gen5, 10k nodes: −17 ± 13**, inconclusive (LLR −2.33, 2000 games).
  Training 256-wide on all of gen0–5 didn't beat gen5 (gen0–4 + book data); suspect
  the oldest, weakest generations dilute the data. Next: a window of recent gens.
- **gen5 gauntlet on bitch-box: ~3045** (2800 77.8%, 3000 54.5%, 3190 36.0%) vs gen4
  ~2980 on the same host, i.e. about +60–65 against Stockfish.
- Running: **h512-all vs gen5, 8+0.08, SPRT [0,10]** (`~/zchess-overnight/run-512-vs-gen5.sh`),
  the promotion decision for the 512-wide net.

### 2026-10-08: gen6w (512-wide, recent data only) promoted
- h512-all became `nets/gen5w.nnue`, the first 512-wide best net.
- `scripts/gen6w.sh`: collected gen6 from the cluster, restarted cluster datagen
  as `gen7book` (with gen5w), trained a 512-wide net on a window of recent data
  only (gen4, gen5book, gen5rand, gen6book; val loss 0.00304), SPRT vs gen5w.
- **gen6w vs gen5w, 8+0.08: +27 ± 10, SPRT H1** at 1876 games (+493 =1034 −349).
  Dropping the early generations helps, as the h256-all result suggested.
  `nets/best.txt` = gen6w.
- Next: collect gen7 (`scripts/cluster.sh collect 7book`), train gen7w on
  gen5–7 the same way; gauntlet gen6w on bitch-box to place it vs gen5 (~3045).

### Strength limit calibration (2026-10-08, bitch-box)
zchess at UCI_Elo X vs Stockfish 19 at the same X, 10+0.1, 100 games per level.
First mapping: 1400 scored 82.5%, 2000 95.5% (2600 lost on time: the limiter
ignored the clock, fixed). With the calibration table in `src/strength.zig`:
1400 −7 ± 65, 2000 +31 ± 63, 2600 +131 ± 65, so a fourth point (requested 2730
→ internal 2150) was added for the top end. Done with gen5w.

Re-measured with gen6w + continuation history (`scripts/remote-calibrate.sh`, 300 games
per level): 1400 **+7 ± 39**, 2000 **−19 ± 38**, 2600 **+127 ± 39**. The stronger engine
plays above the old top points, so the table now uses these measurements directly:
internal 1211 → 1407, 1630 → 1981, 2052 → 2727. A 100-game run just before gave
1400 +111, 2000 −60, 2600 +104: 100 games per level is too noisy for this.

### Search improvements (2026-10-08, Mac)
Each one SPRT'd binary vs binary (`scripts/sprt.sh`, 8+0.08, [0, 5]) against the
previous accepted change, all with gen6w embedded. Developed as stacked branches
`search/conthist` → `search/corrhist` → `search/singular`.

- [x] Continuation history (piece×to of the moves 1 and 2 plies back; in quiet
  ordering and the LMR history term): **+25.7 ± 9.7, H1** at 1790 games
  (+419 =1084 −287). Merged.
- [x] Correction history (pawn structure, per side to move), vs conthist:
  **−0.8 ± 5.2** after 8402 games (+2202 =3978 −2222, LLR −1.28), stopped. No gain;
  left on the `search/corrhist` branch. (The Mac slept overnight, so this took a day.)
- [x] Singular extensions (with multi-cut and negative extensions; depth ≥ 8, margin
  2×depth, double extension below margin −20 off the PV), vs conthist, SPRT'd on
  bitch-box: **+36.6 ± 12.0, H1** at 1372 games (+391 =734 −247).
  Merged 2026-10-12.

### Loss power, king buckets, longer schedule (started 2026-10-12 18:52, Mac + bitch-box)
New in the trainer and engine:
- `train --power <x>`: loss |prediction − target|^x (default 2). 2.5 is what bullet and
  Stockfish's trainer use; it weights large errors more.
- King buckets, `-Dking-buckets=N` (1, 4, 8 or 16; 0 = the old layout): each perspective
  picks an input weight set by its own king's square and mirrors files so that king is on
  a–d. Net format version 2 (20-byte header with the bucket count). `zig build -Dnet=...`
  now takes the width and king buckets from the net's header, so `-Dhidden` is optional.
  A king move that changes bucket refreshes that side's accumulator: ~8–13% lower NPS
  with 8 buckets (an accumulator cache can win most of it back if they pay off).

`scripts/exp-gen7.sh` (log `exp-gen7.log`, results `sprt/exp-gen7/*.txt`) trains each
variant on the gen7w window (gen5book, gen5rand, gen6book, gen7book; 147M positions,
512 wide, seed 1) and SPRTs it, 8+0.08 [0, 5], against the plain gen7w recipe. No
automatic promotion.

- [x] gen7w (baseline recipe) vs gen6w: **+32.6 ± 11.2, H1** at 1508 games (+428 =793 −287).
- [x] gen7w-p25 (loss power 2.5) vs gen7w: **+44.1 ± 13.0, H1** at 1054 games (+294 =599 −161).
- [x] gen7w-kb8 (8 king buckets) vs gen7w: **−60.3 ± 15.9, H0** at 774 games (+112 =417 −245).
  Overfitting, not a bug: its in-window validation loss was the best (0.00269 vs 0.00303),
  but on held-out games (gen4, not in the window; trainer `--init <ckpt>`, power 2) it is
  the worst: gen7w 0.003317, kb8 0.003592, e30 0.003284. 8× the input weights memorise
  147M positions, and the validation split (random positions of the training games)
  rewards that. Engine and trainer agree on evals and the 8-bucket tests pass. To retry:
  a factorised feature transformer and/or 4 buckets, judged on a game-disjoint
  validation set. Held-out loss also isn't comparable across loss powers (p25: 0.003352).
- [x] gen7w-e30 (30 epochs) vs gen7w: **+15.6 ± 7.5, H1** at 3166 games (+777 =1754 −635).
- [x] gen7w-p25-e30 (both winners) vs gen7w-p25: **+10.5 ± 6.0, H1** at 5024 games
  (+1197 =2782 −1045). They stack, partly: 30 epochs add less on top of power 2.5.
  (p25, kb8, e30 and p25-e30 were SPRT'd with singular extensions in both binaries.)

**gen7w-p25-e30 promoted** (`nets/best.txt`, 2026-10-13): about +87 over gen6w in
self-play SPRTs (+32.6, +44.1, +10.5). Recipe for the next generation: loss power 2.5,
30 epochs. Gauntlet vs Stockfish 19 on bitch-box (10+0.1, 200 games per level):
2800 +263 ± 57, 3000 +117 ± 40, 3190 −24 ± 37, so **3115** in `nets/ratings.txt`
(gen6w 3070: +45 against Stockfish, about half the self-play gain, as usual).

### Step 3: bigger net (trained; width confirmed, promotion test running)
512 hidden. `nnue.HIDDEN` is a compile-time constant, so the in-process `match`
can't compare a 512 net with a 256 net: build per size and SPRT the two binaries
with fastchess (now installed in `~/zchess-tools`).

### Later
- Search: singular extensions, continuation history, correction history (each
  SPRT'd binary vs binary with fastchess).
- King-relative input buckets (big gain in strong engines, but data-hungry).
- A playing-strength setting for practice games.
