#!/usr/bin/env bash
# Opening-book A/B test that also produces the next generation.
#
#   A (book):   the cluster generates POSITIONS from book openings
#   B (random): the Mac generates POSITIONS from random 8-9 ply openings
# Same net, same nodes; both datasets are trimmed to the same size, and two
# nets are trained identically on gen0..gen(N-1) + A or + B. SPRT A vs B
# measures the book's effect; the winner must then beat the current best.
#
# Tunables: GEN=5 POSITIONS=12000000 NODES=10000 BOOK=data/book.fen EPOCHS=15 START_HOSTS=...
set -euo pipefail
cd "$(dirname "$0")/.."

GEN=${GEN:-5}
POSITIONS=${POSITIONS:-12000000}
NODES=${NODES:-10000}
BOOK=${BOOK:-data/book.fen}
EPOCHS=${EPOCHS:-15}
BEST=$(cat nets/best.txt)
BIN=./zig-out/bin/zchess
A=data/gen${GEN}book.bin
B=data/gen${GEN}rand.bin
NET_A=nets/gen${GEN}-book.nnue
NET_B=nets/gen${GEN}-rand.nnue
MATCH="--games 2000 --nodes 10000 --sprt 0,10 --book $BOOK"

log() { echo "== $(date '+%H:%M') $*"; }

log "A/B gen$GEN: $POSITIONS positions each at $NODES nodes with $BEST"
if [ ! -f "$A.done" ]; then
    log "A: cluster generating from $BOOK"
    # START_HOSTS=cluster/hosts-lan.txt pushes the book over the home LAN
    # instead of through the hub; collection uses the overlay (works anywhere).
    HOSTS_FILE=${START_HOSTS:-cluster/hosts.txt} scripts/cluster.sh start "${GEN}book" "$BEST" "$NODES" "$BOOK"
fi

if [ ! -f "$B.done" ]; then
    # Timed games elsewhere on the Mac (the gauntlet) must not compete for CPU.
    while pgrep -f "scripts/[g]auntlet.sh" >/dev/null; do sleep 60; done
    log "B: Mac generating from random openings"
    $BIN datagen --out "$B" --positions "$POSITIONS" --nodes "$NODES" --net "$BEST"
    touch "$B.done"
fi

if [ ! -f "$A.done" ]; then
    while true; do
        n=$(scripts/cluster.sh count "${GEN}book")
        [ "$n" -ge "$POSITIONS" ] && break
        log "A: cluster at $n / $POSITIONS"
        sleep 300
    done
    scripts/cluster.sh collect "${GEN}book"
    touch "$A.done"
fi

# Same number of positions in both arms (drop the surplus tail of the larger).
python3 - "$A" "$B" <<'PY'
import os, sys
a, b = sys.argv[1], sys.argv[2]
n = min(os.path.getsize(a), os.path.getsize(b)) // 32 * 32
for f in (a, b):
    if os.path.getsize(f) > n:
        os.truncate(f, n)
print(f"both arms: {n // 32} positions")
PY

base=$(ls data/gen[0-9].bin | sort -V | grep -v "gen${GEN}" | paste -sd, -)
for arm in book rand; do
    net=nets/gen${GEN}-$arm.nnue
    data=data/gen${GEN}$arm.bin
    if [ ! -f "$net" ]; then
        log "training $net on $base,$data"
        $BIN train --data "$base,$data" --out "$net" --epochs "$EPOCHS" --seed 1
        $BIN viz "$net"
    fi
done

log "SPRT book vs random (book openings)"
$BIN match --a "$NET_A" --b "$NET_B" $MATCH | tr '\r' '\n' | tail -n 4 | tee "nets/gen${GEN}-ab.match.txt"
if grep -q 'H1 accepted' "nets/gen${GEN}-ab.match.txt"; then
    winner=$NET_A
elif grep -q 'H0 accepted' "nets/gen${GEN}-ab.match.txt"; then
    winner=$NET_B
else
    # Inconclusive: keep the arm with the better score.
    score=$(grep -o 'score [0-9.]*%' "nets/gen${GEN}-ab.match.txt" | grep -o '[0-9.]*')
    if awk "BEGIN { exit !($score >= 50) }"; then winner=$NET_A; else winner=$NET_B; fi
fi
log "A/B winner: $winner"

log "SPRT $winner vs $BEST"
$BIN match --a "$winner" --b "$BEST" $MATCH | tr '\r' '\n' | tail -n 4 | tee "nets/gen${GEN}.match.txt"
if grep -q 'H1 accepted' "nets/gen${GEN}.match.txt"; then
    cp "$winner" "nets/gen${GEN}.nnue"
    echo "nets/gen${GEN}.nnue" > nets/best.txt
    log "promoted: nets/gen${GEN}.nnue (from $winner)"
else
    log "not promoted; best stays $BEST"
fi
