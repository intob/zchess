#!/usr/bin/env bash
# Self-play data generation on this Mac, alongside the cluster, for the
# generation the cluster is making:
#
#   scripts/mac-datagen.sh start <gen> <net> [threads]   e.g. start 9book nets/gen8w.nnue
#   scripts/mac-datagen.sh stop
#   scripts/mac-datagen.sh status
#
# Same settings as the cluster (10k nodes, data/book.fen, a fresh seed), with
# a binary built from a clean worktree at HEAD (uncommitted experiments stay
# out), under caffeinate and nice 19; threads default to all cores but two.
# Writes data/cluster/gen<gen>-mac.staged, which `cluster.sh collect <gen>`
# appends to data/gen<gen>.bin and then deletes, so stop it before
# collecting (genw.sh does). A restart appends to the same file.
set -euo pipefail
cd "$(dirname "$0")/.."
PID=data/cluster/mac-datagen.pid
LOG=data/cluster/mac-datagen.log
NODES=${NODES:-10000}
running() { [ -f "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; }

start() {
    local gen=$1 net=$2 threads=${3:-$(( $(sysctl -n hw.ncpu) - 2 ))}
    if running; then
        echo "mac-datagen: already running (pid $(cat "$PID")); stop it first"
        return 1
    fi
    mkdir -p data/cluster
    local wt
    wt=$(mktemp -d)/wt
    git worktree add --detach --quiet "$wt" HEAD
    cp "$net" "$wt/$net"
    (cd "$wt" && zig build -Dart=false -Doptimize=ReleaseFast -Dnet="$net" -p "$PWD/../bin")
    mkdir -p bins/mac-datagen
    cp "$wt/../bin/bin/zchess" bins/mac-datagen/zchess
    git worktree remove --force "$wt"
    local out=data/cluster/gen$gen-mac.staged
    local seed
    seed=$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')
    echo "$(date '+%F %T') start: gen$gen, $net, $NODES nodes, $threads threads, seed $seed, from $(git rev-parse --short HEAD)" >> "$LOG"
    nohup caffeinate -i nice -n 19 bins/mac-datagen/zchess datagen --out "$out" --positions 1000000000 \
        --nodes "$NODES" --threads "$threads" --net "$net" --seed "$seed" --book data/book.fen >> "$LOG" 2>&1 &
    echo $! > "$PID"
    echo "mac-datagen: generating gen$gen with $net on $threads threads -> $out (log $LOG)"
}

stop() {
    if ! running; then
        echo "mac-datagen: not running"
        rm -f "$PID"
        return 0
    fi
    local pid
    pid=$(cat "$PID")
    pkill -TERM -P "$pid" 2>/dev/null || true
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    rm -f "$PID"
    echo "mac-datagen: stopped"
}

status() {
    local state=stopped
    running && state="running (pid $(cat "$PID"))"
    echo "mac-datagen: $state"
    for f in data/cluster/gen*-mac.staged; do
        [ -f "$f" ] && echo "  $f: $(( $(stat -f %z "$f") / 32 )) positions"
    done
    [ -f "$LOG" ] && tr '\r' '\n' < "$LOG" | grep -v '^$' | tail -n 1
    true
}

cmd=${1:-}
shift || true
case "$cmd" in
    start) start "$@" ;;
    stop) stop ;;
    status) status ;;
    *) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
