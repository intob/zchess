#!/usr/bin/env bash
# Self-play reinforcement loop:
#   generate data with the current best evaluation -> train a new network on
#   recent generations -> SPRT it against the current best -> promote on H1.
# Generation 0 bootstraps from the hand-crafted evaluation.
#
# Safe to re-run: finished datagen steps are skipped (marked with .done files).
#
# Tunables (environment variables):
#   GENS=4 POSITIONS=5000000 NODES=5000 EPOCHS=15 MATCH_GAMES=2000 MATCH_NODES=10000 WINDOW=3
set -euo pipefail
cd "$(dirname "$0")/.."

GENS=${GENS:-4}
POSITIONS=${POSITIONS:-5000000}
NODES=${NODES:-5000}
EPOCHS=${EPOCHS:-15}
MATCH_GAMES=${MATCH_GAMES:-2000} # upper bound; the SPRT usually stops much earlier
MATCH_NODES=${MATCH_NODES:-10000}
WINDOW=${WINDOW:-3} # how many recent generations of data to train on
BIN=./zig-out/bin/zchess

# Build with the current best net embedded so the play/UCI binary keeps it.
NET_OPT=""
hidden_of() { od -An -tu4 -j8 -N4 "$1" | tr -d ' '; }
if [ -f nets/best.txt ] && [ "$(cat nets/best.txt)" != hce ]; then NET_OPT="-Dnet=$(cat nets/best.txt) -Dhidden=$(hidden_of "$(cat nets/best.txt)")"; fi
zig build $NET_OPT
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
        # Optional: Raspberry Pi cluster generates extra data for this generation.
        if [ -x scripts/cluster.sh ] && [ -f cluster/hosts.txt ]; then scripts/cluster.sh start "$g" "$best" "$NODES" || true; fi
        $BIN datagen --out "$data" --positions "$POSITIONS" --nodes "$NODES" --net "$best"
        touch "$data.done"
    fi
    if [ -x scripts/cluster.sh ] && [ -f cluster/hosts.txt ]; then scripts/cluster.sh collect "$g" || true; fi

    files=$(ls data/gen*.bin | sort -V | tail -n "$WINDOW" | paste -sd, -)
    echo "== gen $g: training on $files"
    $BIN train --data "$files" --out "$net" --epochs "$EPOCHS"
    $BIN viz "$net"

    echo "== gen $g: match $net vs $best"
    $BIN match --a "$net" --b "$best" --games "$MATCH_GAMES" --nodes "$MATCH_NODES" --sprt 0,10 | tr '\r' '\n' | tail -n 4 | tee "nets/gen$g.match.txt"

    if grep -q 'H1 accepted' "nets/gen$g.match.txt"; then
        best=$net
        echo "$best" > nets/best.txt
        echo "== gen $g promoted (SPRT H1)"
    else
        echo "== gen $g not promoted (no SPRT H1), keeping $best"
    fi
done

echo "== best network: $best"
echo "build it into the engine with:  zig build -Dnet=$best"
