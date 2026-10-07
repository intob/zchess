#!/usr/bin/env bash
# Step 1 of TRAINING.md: train variants on existing data and SPRT each against
# the current best. Nothing is promoted automatically: read the results in
# nets/exp-*.match.txt and update nets/best.txt by hand.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=./zig-out/bin/zchess
BEST=$(cat nets/best.txt)
SPRT=${SPRT:-0,10}
MAX_GAMES=${MAX_GAMES:-2000}
MATCH_NODES=${MATCH_NODES:-10000}

zig build -Dart=false

run() {
    local name=$1; shift
    local net=nets/exp-$name.nnue
    if [ -f "nets/exp-$name.match.txt" ] && grep -q 'A vs B' "nets/exp-$name.match.txt"; then
        echo "== $name already done"
        return
    fi
    echo "== $name: train $*"
    $BIN train --out "$net" "$@"
    echo "== $name: SPRT [$SPRT] vs $BEST"
    $BIN match --a "$net" --b "$BEST" --games "$MAX_GAMES" --nodes "$MATCH_NODES" --sprt "$SPRT" |
        tr '\r' '\n' | tail -n 4 | tee "nets/exp-$name.match.txt"
}

ALL4=data/gen0.bin,data/gen1.bin,data/gen2.bin,data/gen3.bin
LAST3=data/gen1.bin,data/gen2.bin,data/gen3.bin

run all4  --data "$ALL4"  --epochs 15 --wdl 0.25
run wdl40 --data "$LAST3" --epochs 15 --wdl 0.4
run e30   --data "$LAST3" --epochs 30 --wdl 0.25

echo "== experiments finished"
grep -H 'A vs B\|SPRT' nets/exp-*.match.txt
