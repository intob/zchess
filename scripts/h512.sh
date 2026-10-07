#!/usr/bin/env bash
# Network width experiment: train a 512-wide and a 256-wide net on the same data
# (all generations), SPRT 512 vs 256 under a time control (so the slower, wider
# net pays for its speed), then the winner vs the current best.
#
# Tunables: EPOCHS=15 TC=8+0.08 CONC=10
set -euo pipefail
cd "$(dirname "$0")/.."

EPOCHS=${EPOCHS:-15}
BEST=$(cat nets/best.txt)
DATA=$(ls data/gen*.bin | sort -V | paste -sd, -)
log() { echo "== $(date '+%H:%M') $*"; }
# Network width, read from the .nnue header (u32 at byte 8).
hidden_of() { od -An -tu4 -j8 -N4 "$1" | tr -d ' '; }


build() { # <prefix> <hidden> [net]
    local opts=(-Dart=false -Dhidden="$2")
    [ -n "${3:-}" ] && opts+=(-Dnet="$3")
    zig build "${opts[@]}" -p "$1"
}

log "width experiment on $DATA"
for h in 256 512; do
    net=nets/h$h-all.nnue
    if [ ! -f "$net" ]; then
        build "bins/train$h" "$h"
        log "training $net ($h wide)"
        "bins/train$h/bin/zchess" train --data "$DATA" --out "$net" --epochs "$EPOCHS" --seed 1
        "bins/train$h/bin/zchess" viz "$net"
    fi
    build "bins/h$h" "$h" "$net"
done

log "SPRT 512 vs 256 (same data, width only)"
ELO1=10 scripts/sprt.sh bins/h512/bin/zchess bins/h256/bin/zchess h512-vs-h256 | tee nets/h512-vs-h256.txt
# fastchess prints the LLR; positive past the upper bound means the new one won.
llr=$(grep -o "LLR: -\?[0-9.]*" nets/h512-vs-h256.txt | tail -n 1 | awk '{print $2}')
if awk "BEGIN { exit !($llr >= 2.94) }"; then winner=512; else winner=256; fi
log "width winner: $winner (LLR $llr)"

build bins/best "$(hidden_of "$BEST")" "$BEST"
log "SPRT h$winner-all vs current best ($BEST)"
ELO1=5 scripts/sprt.sh "bins/h$winner/bin/zchess" bins/best/bin/zchess "h$winner-vs-best" | tee "nets/h$winner-vs-best.txt"
llr=$(grep -o "LLR: -\?[0-9.]*" "nets/h$winner-vs-best.txt" | tail -n 1 | awk '{print $2}')
if awk "BEGIN { exit !($llr >= 2.94) }"; then
    echo "nets/h$winner-all.nnue" > nets/best.txt
    zig build -Dhidden="$winner" -Dnet="nets/h$winner-all.nnue"
    log "promoted nets/h$winner-all.nnue ($winner wide); zig-out rebuilt with it"
else
    log "not promoted; best stays $BEST"
fi
