#!/usr/bin/env bash
# 2026-10-08 morning chain: collect gen6 (cluster), start gen7 datagen with the
# current best, train a 512-wide gen6 on recent generations only (gen4, gen5,
# gen6; the early low-quality gens are left out), SPRT it against the best,
# promote on H1.
set -euo pipefail
cd "$(dirname "$0")/.."
log() { echo "== $(date '+%H:%M') $*"; }
hidden_of() { od -An -tu4 -j8 -N4 "$1" | tr -d ' '; }

BEST=$(cat nets/best.txt)
WINDOW=data/gen4.bin,data/gen5book.bin,data/gen5rand.bin,data/gen6book.bin
NET=nets/gen6w.nnue

if [ ! -f data/gen6book.bin.done ]; then
    log "collecting gen6 from the cluster"
    scripts/cluster.sh collect 6book
    touch data/gen6book.bin.done
fi
log "gen6: $(( $(stat -f %z data/gen6book.bin) / 32 )) positions"

log "cluster: gen7 datagen with $BEST"
scripts/cluster.sh start 7book "$BEST" 10000 data/book.fen

if [ ! -f "$NET" ]; then
    zig build -Dart=false -Dhidden=512 -p bins/train512
    log "training $NET (512 wide) on $WINDOW"
    bins/train512/bin/zchess train --data "$WINDOW" --out "$NET" --epochs 15 --seed 1
    bins/train512/bin/zchess viz "$NET"
fi

zig build -Dart=false -Dhidden=512 -Dnet="$NET" -p bins/gen6w
zig build -Dart=false -Dhidden="$(hidden_of "$BEST")" -Dnet="$BEST" -p bins/best
log "SPRT gen6w vs $BEST (8+0.08)"
ELO1=5 scripts/sprt.sh bins/gen6w/bin/zchess bins/best/bin/zchess gen6w-vs-best | tee nets/gen6w.match.txt
llr=$(grep -o "LLR: -\?[0-9.]*" nets/gen6w.match.txt | tail -n 1 | awk '{print $2}')
if awk "BEGIN { exit !($llr >= 2.94) }"; then
    echo "$NET" > nets/best.txt
    zig build -Dhidden=512 -Dnet="$NET"
    log "promoted $NET; engine rebuilt"
else
    log "not promoted (LLR $llr); best stays $BEST"
fi
