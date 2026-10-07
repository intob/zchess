#!/usr/bin/env bash
# Rate zchess against Stockfish's calibrated strength limiter (UCI_Elo) with
# fastchess. Stockfish's UCI_Elo is calibrated to CCRL-style ratings at longer
# time controls, so treat the result as a rough rating, not an official one.
#
# Tunables: NET (default nets/best.txt) LEVELS="2200 2500 2800" GAMES=200
#           TC=10+0.1 CONC=5 FASTCHESS=... STOCKFISH=...
set -euo pipefail
cd "$(dirname "$0")/.."

FASTCHESS=${FASTCHESS:-$HOME/zchess-tools/fastchess/fastchess}
STOCKFISH=${STOCKFISH:-$(command -v stockfish)}
LEVELS=${LEVELS:-"2200 2500 2800"}
GAMES=${GAMES:-200}
TC=${TC:-10+0.1}
CONC=${CONC:-5}
NET=${NET:-$(cat nets/best.txt)}
OUT=gauntlet/$(date +%Y%m%d-%H%M)-$(basename "$NET" .nnue)
mkdir -p "$OUT"

# Freeze a binary with this net embedded.
zig build -Dnet="$NET" -Dhidden="$(od -An -tu4 -j8 -N4 "$NET" | tr -d ' ')"
cp zig-out/bin/zchess "$OUT/zchess"

# 20k shuffled book positions as EPD (fixed seed, so runs are comparable).
# (awk stops at 20k itself: `head` would close the pipe early, and under
# pipefail the resulting SIGPIPE in sort would abort the script.)
awk 'BEGIN { srand(42) } { print rand() "\t" $1 " " $2 " " $3 " " $4 }' data/book.fen |
    sort -n | awk -F'\t' 'NR <= 20000 { print $2 }' > "$OUT/openings.epd"

echo "gauntlet: $NET vs Stockfish UCI_Elo [$LEVELS], $GAMES games each at $TC, concurrency $CONC -> $OUT"
for elo in $LEVELS; do
    "$FASTCHESS" \
        -engine cmd="$OUT/zchess" name=zchess \
        -engine cmd="$STOCKFISH" name="sf$elo" option.UCI_LimitStrength=true option.UCI_Elo="$elo" \
        -each tc="$TC" option.Threads=1 option.Hash=16 \
        -openings file="$OUT/openings.epd" format=epd order=random \
        -rounds $((GAMES / 2)) -games 2 -repeat -concurrency "$CONC" \
        -pgnout file="$OUT/sf$elo.pgn" > "$OUT/sf$elo.txt" 2>&1
    echo "== vs sf$elo: $(grep -E '^Games:' "$OUT/sf$elo.txt" | tail -n 1) | $(grep -E '^Elo:' "$OUT/sf$elo.txt" | tail -n 1)"
done | tee "$OUT/summary.txt"
