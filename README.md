# zchess

A chess engine and NNUE training pipeline written in pure Zig (0.16), with no
dependencies. The engine, the self-play data generator, the neural-network
trainer and the match runner are one binary.

```
zig build                     # ReleaseFast by default
zig build test                # unit tests (perft, NNUE incremental updates, SEE, data format)
./zig-out/bin/zchess play     # play against it in the terminal (--black, --time 5, hint/undo/moves)
./zig-out/bin/zchess viz nets/gen4.nnue   # "brain scan" poster of a network -> nets/gen4.png
./zig-out/bin/zchess review --user <name> games.pgn   # mistakes, blunders, annotated PGN
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

UCI options: `Hash`, `Threads`, `EvalFile` (path to a `.nnue`), `UseNNUE`, `MultiPV`,
`Ponder`, `Move Overhead`, `Clear Hash`, and `UCI_LimitStrength` + `UCI_Elo` (100–3000:
smaller search, more candidate moves and a weighted random pick at lower ratings;
`zchess play --elo N` does the same in the terminal).
`Coach`, `CoachOpponent`, `CoachLog`, `CoachGames`, `CoachUser`: a comment on each of your moves (see Game review).
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
   `0.9·sigmoid(score/400) + 0.1·result`. After every epoch the quantised
   net is checked against the float net (typically within ~2–3 cp).
3. **match**: the new net plays the current best over colour-reversed
   pairs of openings, with Elo ± 95% CI and an optional SPRT
   (`match.zig`). It is promoted if it scores over 50%.

Openings can come from real games instead of random moves:
`zchess book --out data/book.fen <lichess .pgn.zst files>` builds a FEN book
(streams zstd and replays the moves with the engine's own move parser), and
`datagen`/`match` take `--book data/book.fen`.

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

## Visualisations

- `zig build` also writes `zig-out/zchess.png`. The binary hashes itself, plays a
  short game seeded by that hash and draws the final position (`src/art.zig`).
- `zchess viz <net.nnue> [--fen <fen>]` renders a poster of a network
  (`src/viz.zig`). It shows the two accumulators as brain hemispheres, with every
  hidden neuron glowing by its contribution to the evaluation of a real position,
  and fibres from pieces to neurons and from neurons to the output. Below that are
  the piece values and square tables the network learned, measured by adding
  pieces to real positions. The training scripts render one for every new net.

## Game review

`zchess review --user <name> <pgn files>` searches every position of a player's
games and flags inaccuracies, mistakes and blunders by lost winning chances
(Lichess's win% method), each with a plain-language label, the better move and
its line. It writes a JSON report and an annotated PGN.

The label says what went wrong (`src/tactics.zig`): a piece left hanging (also
when the opponent takes it only after an in-between check), a missed capture,
an allowed or missed mate (back-rank and smothered mates by name), or the
tactic behind it: a fork, pin, skewer, discovered attack or check, double
check, trapped piece or removed defender, either one the opponent's reply
plays against you or one you missed. It looks for the tactic in the first
moves of the punishing line and of the better line, so "after Bxf2+, Nf2 hits
your queen and rook" counts too. Failing that, a deeper combination that wins
material, an attack on your king, or a positional mistake:

    9. Be2? Mistake: walked into a knight fork: Nxc2+ hits your king and rook.
    6... Nxb5?? Blunder: allowed a discovered check: Nxc6+ uncovers check, and the knight wins your queen.

Each flagged move gets a `lesson` (`hung_piece`, `allowed_fork`, `missed_pin`,
...) that everything downstream groups by. The JSON also lists the player's
moves while the game is still in opening theory (`opening_moves`), with what
strong players play there.

`scripts/leaks.py review.json` ranks the lessons by how many of your last 20
games they cost something in, and gives the habit that fixes the top one:

    #1 leak: You left a piece hanging in 13 of your last 20 games (24 times, mostly your knights).
       habit: Before every move, check what your opponent's last move attacks, and that every
              piece you own is still defended after the move you want to play.

`scripts/review-report.py review.json > report.html` turns the JSON into a page
that leads with that leak, and a trainer with puzzles from your own mistakes
(*find the win*, *spot the threat*) and opening drills (positions you reached
in theory: play what strong players play). Puzzles come back on a spaced
schedule (1, 3, 7, 16, 35 days when right first time; tomorrow when missed),
at most 15 new ones a day, your #1 leak first; progress is kept in the
browser (vector pieces: cburnett, GPLv2+). *Blunder check* drills the habit
itself: a move you played is shown on the board and you say whether it is
safe or loses something, then show how. Two in five are real mistakes; the
rest are sound moves that still left a piece attacked (the review JSON's
`checks`), so the answer takes counting attackers and defenders. Rounds of
20, misses first next time.

`scripts/ec-sync.py [--user fingjoey]` is the En Croissant bridge: it fetches new
Chess.com games, reviews them and writes one annotated PGN per game into
`~/Documents/EnCroissant/zchess` (Files tab). It then writes your #1 leak to
`.focus` in that folder (for the live coach, below), runs `scripts/ec-puzzles.py`,
which turns the mistakes into a puzzle database in En Croissant's own format
("<user> mistakes" in the Puzzles tab, tagged with Lichess's theme names: fork,
pin, discoveredAttack, ...): *spot the threat* (your bad move is played, find the
punishment) and *find the win* (find the capture, mate or tactic you missed), and
rebuilds the report page as `data/review/<user>-report.html`.

Live coaching while you play: set the UCI option `Coach` to true and, while it
thinks about its reply, zchess judges the move you just made the same way (300k
nodes for the position before and after it, on a thread of its own; the reply waits
for it, so it costs the engine a few tenths of a second of its own clock, and it's
skipped when the engine has under a second for the move). The comment is sent as
`info string coach: ...` just before `bestmove` (so it shows in En Croissant's engine
logs: search for "coach") and appended to `CoachLog`
(default `~/zchess-coach.log`, `<none>` to turn the file off), one line per move
with a header per game:

    2... Qh4?? Blunder: left your queen hanging (win chance 49% -> 2%). Better was Nc6 (Nc6 Nc3 Nf6 Bc4). The punishment: Nxh4 Nf6 Nc3 Bc5. Eval: -9.99

The first comment of each game starts with your #1 leak and its habit (from the
`.focus` file `scripts/ec-sync.py` writes into the `CoachGames` folder), and a
mistake of that same kind says so:

    Focus this game: You left a piece hanging in 13 of your last 20 games (24 times, mostly your knights). Before every move, check what your opponent's last move attacks, ... | 1. e4: best move. ...
    7... Ng4?? Blunder: left your knight hanging (win chance 57% -> 8%). Better was O-O ... That's your #1 leak again. Before every move, check what your opponent's last move attacks, ...

`go infinite` (analysis) and ponder misses aren't commented on.

In the opening the comment also names the opening when it changes (Lichess's
[chess-openings](https://github.com/lichess-org/chess-openings) list, CC0, matched by
position so transpositions count), says whether the move is theory (how often 2000+
players chose it in the Lichess broadcast games, or what they play instead when it
leaves the book), adds an opening-principle tip (early queen, same piece twice,
undeveloped pieces, uncastled king) when the engine also flags the move, and how you
have done from the position in your own games:

    3. Bc4: good. Nc3 was also strong. Opening: Italian Game (C50). Book move: played in 30% of 49241 games between 2000+ players. Eval: +0.07

With `CoachOpponent` on, the engine's own moves get a comment too, just before its
`bestmove` (two 150k-node searches): opening name and theory, what it took, and what it
threatens, found by letting it move twice (a null move) and seeing what that wins:

    Opponent played 6. Qh5. Threatens mate: Qxf7#. Eval: +0.34

With `CoachHints` on (training wheels; turn it off once the check is a habit), each
engine move is followed by your pieces that can now be taken for profit: attacked,
and undefended or attacked by something cheaper. It needs no search:

    After 7. Nxc6+: Watch: your queen on d8 is attacked by a knight.

In the terminal: `zchess play --coach --threats --hints`.

Your games come from `CoachGames` (a PGN file or a folder of them; default
`~/Documents/EnCroissant/zchess`, where `scripts/ec-sync.py` puts them, re-read every
new game) as `CoachUser` (default: whoever plays in most of them). In the terminal:
`zchess play --coach --games <pgn or folder> [--user <name>]`.

The names and the move tree are one file built by `zchess openings` and embedded by
`zig build` when `data/openings.bin` exists (`-Dopenings=<file>` for another):

    zchess openings --names data/openings/a.tsv,...,data/openings/e.tsv \
        --out data/openings.bin data/lichess/*.pgn.zst   # about a minute

## Formats

- **Training record** (32 bytes): `occ: u64`, 32 packed piece nibbles,
  `score: i16` (white POV, cp), `result: u8` (0/1/2 = black win/draw/white
  win), `stm: u8`, `ply: u16`, 2 bytes padding.
- **Network** (`.nnue`): `"ZCNN"`, version, hidden size and bucket count as
  u32 LE, then i16 LE arrays `ft_w[768·256]`, `ft_b[256]`,
  `out_w[8][512]`, `out_b[8]`. QA = 255, QB = 64, eval scale 400.
- **Checkpoint** (`.nnue.ckpt`): float32 parameters, for `train --init`.
