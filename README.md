# zchess

A chess engine and NNUE training pipeline written in pure Zig (0.16), with no
dependencies. The engine, the self-play data generator, the neural-network
trainer and the match runner are one binary.

```
zig build                     # ReleaseFast by default
zig build test                # unit tests (perft, NNUE incremental updates, SEE, data format)
./zig-out/bin/zchess play     # play against it in the terminal (--black, --time 5, hint/undo/moves)
./zig-out/bin/zchess          # UCI mode: point any chess GUI at this binary
./zig-out/bin/zchess perft-suite
./zig-out/bin/zchess bench
```

## Engine

| Part | File | Notes |
|---|---|---|
| Board | `position.zig` | Bitboards + mailbox, copy-make, incremental Zobrist keys |
| Attacks | `attacks.zig` | Leaper tables built at compile time; magic bitboards for sliders (no PEXT on Apple Silicon) |
| Move generation | `movegen.zig` | Fully legal (check masks + pin rays), ~400M nodes/s perft with bulk counting on an M2 Pro |
| Search | `search.zig` | PVS, iterative deepening, aspiration windows, TT, null move, reverse futility, LMR, LMP, futility and SEE pruning, IIR, check extensions, killers and history, quiescence with SEE and delta pruning |
| Threads | `uci.zig` | Lazy SMP over a lock-free shared TT (`tt.zig`, XOR-validated entries) |
| Evaluation | `nnue.zig` | (768 → 256)×2 → 1, SCReLU, 8 output buckets, int16 quantisation, NEON through `@Vector`, incremental accumulator updates |
| Bootstrap eval | `eval.zig` | Tapered PSTs and mobility, used only to generate the first data |

UCI options: `Hash`, `Threads`, `EvalFile` (path to a `.nnue`), `UseNNUE`.
Extra commands in UCI mode: `d` (show the board), `eval`, `perft <depth>`.

## Training pipeline

```
scripts/pipeline.sh           # GENS=4 POSITIONS=5000000 ... (see the header of the script)
```

Each generation:

1. **datagen**: every core plays node-limited self-play games (5k nodes/move)
   from random 8–9-ply openings, discarding unbalanced ones. Quiet positions
   (side to move not in check, best move not a capture or promotion) are
   stored as 32-byte records: board, search score and final result
   (`data.zig`).
2. **train**: a float32 copy of the network is trained in Zig
   (`train.zig`). Forward and backward passes are hand-written, with AdamW,
   cosine LR decay and data parallelism over all cores. Target =
   `0.75·sigmoid(score/400) + 0.25·result`. After every epoch the quantised
   net is checked against the float net (typically within ~2–3 cp).
3. **match**: the new net plays the current best over colour-reversed
   pairs of openings, with Elo ± 95% CI and an optional SPRT
   (`match.zig`). It is promoted if it scores over 50%.

Generation 0 plays with the hand-crafted eval. Every later generation plays
with the previous best net, so the network learns from its own games.

Run the steps by hand:

```
zchess datagen --out data/gen0.bin --positions 5000000 --net hce
zchess train   --data data/gen0.bin --out nets/gen0.nnue --epochs 15
zchess match   --a nets/gen0.nnue --b hce --games 400 --sprt 0,10
```

Embed the best network in the binary so it becomes the default evaluation:

```
zig build -Dnet=nets/gen2.nnue   # the current best
```

## Results (first run, M2 Pro, about 2.5 hours of compute)

Each generation: 5M self-play positions at 5k nodes/move, 15 epochs; matches
are 400 games at 10k nodes/move.

| Net | Opponent | Result | Score | Elo |
|---|---|---|---|---|
| gen0 | hand-crafted eval | +204 =96 −100 | 63.0% | +92 ± 31 |
| gen1 | gen0 | +200 =107 −93 | 63.4% | +95 ± 30 |
| gen2 | gen1 | +193 =77 −130 | 57.9% | +55 ± 31 |
| gen3 | gen2 | +152 =85 −163 | 48.6% | −10 ± 30 (rejected) |
| **gen2** | **hand-crafted eval** | **+281 =56 −63** | **77.3%** | **+212 ± 37** |

Gains levelled off by gen3. The next steps would be more nodes per move in
datagen, more positions per generation, and a wider hidden layer.

## Formats

- **Training record** (32 bytes): `occ: u64`, 32 packed piece nibbles,
  `score: i16` (white POV, cp), `result: u8` (0/1/2 = black win/draw/white
  win), `stm: u8`, `ply: u16`, 2 bytes padding.
- **Network** (`.nnue`): `"ZCNN"`, version, hidden size and bucket count as
  u32 LE, then i16 LE arrays `ft_w[768·256]`, `ft_b[256]`,
  `out_w[8][512]`, `out_b[8]`. QA = 255, QB = 64, eval scale 400.
- **Checkpoint** (`.nnue.ckpt`): float32 parameters, for `train --init`.
