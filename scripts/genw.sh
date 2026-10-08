#!/usr/bin/env bash
# Next 512-wide generation, as scripts/gen6w.sh did for gen6: collect
# gen<N>book from the cluster, restart cluster datagen as gen<N+1>book with the
# current best, train a 512-wide net on a window of recent data, SPRT it
# against the best (8+0.08) and promote on H1.
#
#   scripts/genw.sh <N> <window>
#   e.g. scripts/genw.sh 7 data/gen5book.bin,data/gen5rand.bin,data/gen6book.bin,data/gen7book.bin
#
# Run it on main: the cluster binary is built from the working tree.
set -euo pipefail
cd "$(dirname "$0")/.."
log() { echo "== $(date '+%H:%M') $*"; }
hidden_of() { od -An -tu4 -j8 -N4 "$1" | tr -d ' '; }

N=$1
WINDOW=$2
BEST=$(cat nets/best.txt)
NET=nets/gen${N}w.nnue

if [ ! -f "data/gen${N}book.bin.done" ]; then
    log "collecting gen$N from the cluster"
    scripts/cluster.sh collect "${N}book"
    touch "data/gen${N}book.bin.done"
fi
log "gen$N: $(( $(stat -f %z "data/gen${N}book.bin") / 32 )) positions"

log "cluster: gen$((N + 1)) datagen with $BEST"
scripts/cluster.sh start "$((N + 1))book" "$BEST" 10000 data/book.fen

if [ ! -f "$NET" ]; then
    zig build -Dart=false -Dhidden=512 -p bins/train512
    log "training $NET (512 wide) on $WINDOW"
    bins/train512/bin/zchess train --data "$WINDOW" --out "$NET" --epochs 15 --seed 1
    bins/train512/bin/zchess viz "$NET"
fi

zig build -Dart=false -Dhidden=512 -Dnet="$NET" -p "bins/gen${N}w"
zig build -Dart=false -Dhidden="$(hidden_of "$BEST")" -Dnet="$BEST" -p bins/best
log "SPRT gen${N}w vs $BEST (8+0.08)"
ELO1=5 scripts/sprt.sh "bins/gen${N}w/bin/zchess" bins/best/bin/zchess "gen${N}w-vs-best" | tee "nets/gen${N}w.match.txt"
llr=$(grep -o "LLR: -\?[0-9.]*" "nets/gen${N}w.match.txt" | tail -n 1 | awk '{print $2}')
if awk "BEGIN { exit !($llr >= 2.94) }"; then
    echo "$NET" > nets/best.txt
    zig build -Dhidden=512 -Dnet="$NET"
    log "promoted $NET; engine rebuilt"
else
    log "not promoted (LLR $llr); best stays $BEST"
fi
