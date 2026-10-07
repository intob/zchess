#!/usr/bin/env bash
# Step 1 of TRAINING.md: train variants on existing data and SPRT each against
# the current best. By default nothing is promoted: read the results in
# nets/exp-*.match.txt and update nets/best.txt by hand, or run with PROMOTE=1
# to promote the strongest SPRT winner automatically.
set -euo pipefail
cd "$(dirname "$0")/.."

BIN=./zig-out/bin/zchess
BEST=$(cat nets/best.txt)
SPRT=${SPRT:-0,10}
MAX_GAMES=${MAX_GAMES:-2000}
MATCH_NODES=${MATCH_NODES:-10000}

# Build with the current best net embedded so the play/UCI binary keeps it.
NET_OPT=""
if [ -f nets/best.txt ] && [ "$(cat nets/best.txt)" != hce ]; then NET_OPT="-Dnet=$(cat nets/best.txt)"; fi
zig build $NET_OPT

RAN=()

run() {
    local name=$1; shift
    local net=nets/exp-$name.nnue
    if [ -f "nets/exp-$name.match.txt" ] && grep -q 'A vs B' "nets/exp-$name.match.txt"; then
        echo "== $name already done"
        return
    fi
    echo "== $name: train $*"
    $BIN train --out "$net" "$@"
    $BIN viz "$net"
    echo "== $name: SPRT [$SPRT] vs $BEST"
    $BIN match --a "$net" --b "$BEST" --games "$MAX_GAMES" --nodes "$MATCH_NODES" --sprt "$SPRT" |
        tr '\r' '\n' | tail -n 4 | tee "nets/exp-$name.match.txt"
    RAN+=("$name")
}

ALL4=data/gen0.bin,data/gen1.bin,data/gen2.bin,data/gen3.bin
LAST3=data/gen1.bin,data/gen2.bin,data/gen3.bin

run all4  --data "$ALL4"  --epochs 15 --wdl 0.25
run wdl40 --data "$LAST3" --epochs 15 --wdl 0.4
run e30   --data "$LAST3" --epochs 30 --wdl 0.25
# Follow-ups against exp-all4 (2026-10-07).
run all4-wdl10 --data "$ALL4" --epochs 15 --wdl 0.1
run all4-e30   --data "$ALL4" --epochs 30 --wdl 0.25

echo "== experiments finished"

# PROMOTE=1: make the strongest H1 winner from this invocation the new best.
if [ "${PROMOTE:-0}" = 1 ] && [ ${#RAN[@]} -gt 0 ]; then
    winner=""
    winner_elo=-9999
    for name in "${RAN[@]}"; do
        f=nets/exp-$name.match.txt
        grep -q 'H1 accepted' "$f" || continue
        elo=$(grep -o 'Elo [-0-9.]*' "$f" | head -n 1 | awk '{print $2}')
        if awk "BEGIN { exit !($elo > $winner_elo) }"; then
            winner=$name
            winner_elo=$elo
        fi
    done
    if [ -n "$winner" ]; then
        echo "nets/exp-$winner.nnue" > nets/best.txt
        echo "== promoted exp-$winner (Elo $winner_elo vs $BEST)"
    else
        echo "== no H1 winner, keeping $BEST"
    fi
fi
grep -H 'A vs B\|SPRT' nets/exp-*.match.txt
