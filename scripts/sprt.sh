#!/usr/bin/env bash
# SPRT one zchess binary against another with fastchess: for search changes and
# network sizes, which the in-process `zchess match` can't compare.
#
#   scripts/sprt.sh <new-binary> <base-binary> [label]
#
# Build variants side by side first, e.g.
#   zig build -Dart=false -Dnet=nets/gen5.nnue -p bins/base
#   zig build -Dart=false -Dhidden=512 -Dnet=nets/h512.nnue -p bins/h512
#   scripts/sprt.sh bins/h512/bin/zchess bins/base/bin/zchess h512
#
# Time control by default: different net sizes have different speeds, and a
# node limit would hide that. NODES=... switches to a node limit for pure
# search experiments.
#
# Tunables: TC=8+0.08 NODES= ELO0=0 ELO1=5 CONC=10 MAX_ROUNDS=10000 BOOK=data/book.fen
set -euo pipefail
cd "$(dirname "$0")/.."

NEW=$1
BASE=$2
LABEL=${3:-$(basename "$(dirname "$(dirname "$NEW")")")}
FASTCHESS=${FASTCHESS:-$HOME/zchess-tools/fastchess/fastchess}
TC=${TC:-8+0.08}
NODES=${NODES:-}
ELO0=${ELO0:-0}
ELO1=${ELO1:-5}
CONC=${CONC:-10}
MAX_ROUNDS=${MAX_ROUNDS:-10000}
BOOK=${BOOK:-data/book.fen}
OUT=sprt/$(date +%Y%m%d-%H%M)-$LABEL
mkdir -p "$OUT"
cp "$NEW" "$OUT/new"
cp "$BASE" "$OUT/base"

# Shuffled book openings (awk stops at 20k itself; see gauntlet.sh).
awk 'BEGIN { srand(7) } { print rand() "\t" $1 " " $2 " " $3 " " $4 }' "$BOOK" |
    sort -n | awk -F'\t' 'NR <= 20000 { print $2 }' > "$OUT/openings.epd"

if [ -n "$NODES" ]; then limit="nodes=$NODES"; else limit="tc=$TC"; fi
echo "sprt: $LABEL ($NEW) vs base ($BASE), $limit, SPRT [$ELO0, $ELO1], concurrency $CONC -> $OUT"
"$FASTCHESS" \
    -engine cmd="$OUT/new" name="$LABEL" \
    -engine cmd="$OUT/base" name=base \
    -each "$limit" option.Threads=1 option.Hash=16 \
    -openings file="$OUT/openings.epd" format=epd order=random \
    -rounds "$MAX_ROUNDS" -games 2 -repeat -concurrency "$CONC" \
    -sprt elo0="$ELO0" elo1="$ELO1" alpha=0.05 beta=0.05 \
    -report penta=true \
    -pgnout file="$OUT/games.pgn" > "$OUT/log.txt" 2>&1 || true
grep -E "^(Results|Elo|SPRT|LLR|Games|Ptnml)" "$OUT/log.txt" | tail -n 6 | tee "$OUT/summary.txt"
