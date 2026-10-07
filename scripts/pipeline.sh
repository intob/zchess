#!/usr/bin/env bash
# Self-play reinforcement loop:
#   generate data with the current best evaluation -> train a new network on
#   recent generations -> match it against the current best -> promote if it wins.
# Generation 0 bootstraps from the hand-crafted evaluation.
#
# Safe to re-run: finished datagen steps are skipped (marked with .done files).
#
# Tunables (environment variables):
#   GENS=4 POSITIONS=5000000 NODES=5000 EPOCHS=15 MATCH_GAMES=400 MATCH_NODES=10000 WINDOW=3
set -euo pipefail
cd "$(dirname "$0")/.."

GENS=${GENS:-4}
POSITIONS=${POSITIONS:-5000000}
NODES=${NODES:-5000}
EPOCHS=${EPOCHS:-15}
MATCH_GAMES=${MATCH_GAMES:-400}
MATCH_NODES=${MATCH_NODES:-10000}
WINDOW=${WINDOW:-3} # how many recent generations of data to train on
BIN=./zig-out/bin/zchess

zig build
mkdir -p data nets

best=$(cat nets/best.txt 2>/dev/null || echo hce)
echo "== starting from best = $best"

for g in $(seq 0 $((GENS - 1))); do
    data=data/gen$g.bin
    net=nets/gen$g.nnue
    if [ -f "$net" ] && [ -f "nets/gen$g.match.txt" ]; then
        echo "== gen $g already trained, skipping"
        continue
    fi

    if [ ! -f "$data.done" ]; then
        echo "== gen $g: datagen with $best"
        $BIN datagen --out "$data" --positions "$POSITIONS" --nodes "$NODES" --net "$best"
        touch "$data.done"
    fi

    files=$(ls data/gen*.bin | sort -V | tail -n "$WINDOW" | paste -sd, -)
    echo "== gen $g: training on $files"
    $BIN train --data "$files" --out "$net" --epochs "$EPOCHS"

    echo "== gen $g: match $net vs $best"
    $BIN match --a "$net" --b "$best" --games "$MATCH_GAMES" --nodes "$MATCH_NODES" | tr '\r' '\n' | tail -n 3 | tee "nets/gen$g.match.txt"

    score=$(grep -o 'score [0-9.]*%' "nets/gen$g.match.txt" | grep -o '[0-9.]*' || echo 0)
    if awk "BEGIN { exit !($score > 50) }"; then
        best=$net
        echo "$best" > nets/best.txt
        echo "== gen $g promoted (score $score%)"
    else
        echo "== gen $g rejected (score $score%), keeping $best"
    fi
done

echo "== best network: $best"
echo "build it into the engine with:  zig build -Dnet=$best"
