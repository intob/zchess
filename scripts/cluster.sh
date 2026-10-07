#!/usr/bin/env bash
# Raspberry Pi cluster for self-play data generation.
# Hosts are listed one per line in cluster/hosts.txt (ssh names, # comments ok).
#
#   scripts/cluster.sh deploy <net>             build for Pi 5 and copy binary + net
#   scripts/cluster.sh start <gen> <net> <nodes> [book]  deploy, then start datagen for that generation
#   scripts/cluster.sh status                   last progress line from every host
#   scripts/cluster.sh stop                     stop datagen everywhere
#   scripts/cluster.sh collect <gen>            stop, fetch and append each host's data to data/gen<gen>.bin
#
# pipeline.sh calls `start` before its own datagen and `collect` before training.
# Files in data/cluster/gen<gen>-*.staged are appended by `collect` too.
set -euo pipefail
cd "$(dirname "$0")/.."

SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
REMOTE=zchess
PREFIX=zig-out-pi
RECORD=32

hosts() {
    grep -v '^[[:space:]]*#' cluster/hosts.txt | grep -v '^[[:space:]]*$'
}

build() {
    zig build -Dtarget=aarch64-linux-musl -Dcpu=cortex_a76 -Dart=false -p "$PREFIX"
}

deploy() {
    local net=$1
    build
    for h in $(hosts); do
        if ! $SSH "$h" "mkdir -p $REMOTE/data" 2>/dev/null; then
            echo "cluster: $h unreachable, skipping"
            continue
        fi
        scp -q "$PREFIX/bin/zchess" "$h:$REMOTE/zchess"
        [ "$net" != hce ] && scp -q "$net" "$h:$REMOTE/"
        echo "cluster: deployed to $h"
    done
}

start() {
    local gen=$1 net=$2 nodes=$3 book=${4:-}
    deploy "$net"
    local remote_net=hce
    [ "$net" != hce ] && remote_net=$(basename "$net")
    local book_opt=""
    if [ -n "$book" ]; then
        for h in $(hosts); do scp -q "$book" "$h:$REMOTE/" 2>/dev/null || true; done
        book_opt="--book $(basename "$book")"
    fi
    local i=0
    for h in $(hosts); do
        i=$((i + 1))
        local seed=$(( (gen * 1000 + i) * 2654435761 + RANDOM ))
        # `cd` must be its own statement: `cd && cmd &` backgrounds a subshell
        # that holds ssh's stdout open and ssh never returns.
        if $SSH -n "$h" "cd $REMOTE || exit 1; setsid nohup ./zchess datagen --out data/gen$gen.bin --positions 1000000000 \
            --nodes $nodes --threads \$(nproc) --net $remote_net --seed $seed $book_opt \
            > datagen-gen$gen.log 2>&1 < /dev/null &" < /dev/null 2>/dev/null; then
            echo "cluster: $h generating gen$gen ($remote_net, $nodes nodes, seed $seed)"
        else
            echo "cluster: $h unreachable, skipping"
        fi
    done
}

status() {
    for h in $(hosts); do
        local line
        line=$($SSH "$h" "cd $REMOTE 2>/dev/null && pgrep -f '^[.]/zchess datagen' >/dev/null && echo -n 'running: ' || echo -n 'idle: '; \
            ls -t datagen-gen*.log 2>/dev/null | head -n 1 | xargs -r tail -c 200 | tr '\r' '\n' | grep -a . | tail -n 1; \
            echo \" | \$(vcgencmd measure_temp 2>/dev/null)\"" 2>/dev/null || echo "unreachable")
        echo "$h: $line"
    done
}

stop() {
    for h in $(hosts); do
        $SSH "$h" "pkill -f '^[.]/zchess datagen'; for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f '^[.]/zchess datagen' >/dev/null || exit 0; sleep 1; done" 2>/dev/null || true
    done
}

collect() {
    local gen=$1
    local dest=data/gen$gen.bin
    stop
    mkdir -p data/cluster
    for h in $(hosts); do
        local remote_file=$REMOTE/data/gen$gen.bin
        local size
        size=$($SSH "$h" "stat -c %s $remote_file 2>/dev/null || echo 0" 2>/dev/null || echo 0)
        if [ "$size" -lt "$RECORD" ]; then
            echo "cluster: $h has no gen$gen data"
            continue
        fi
        local part=data/cluster/gen$gen-$h.bin
        scp -q "$h:$remote_file" "$part"
        local got
        got=$(stat -f %z "$part")
        if [ "$got" != "$size" ]; then
            echo "cluster: $h transfer size mismatch ($got != $size), leaving it on the Pi"
            rm -f "$part"
            continue
        fi
        # Drop a partial record from an interrupted write, then append.
        local whole=$(( got / RECORD * RECORD ))
        head -c "$whole" "$part" >> "$dest"
        rm -f "$part"
        # Keep the remote copy but mark it collected so it is never appended twice.
        $SSH "$h" "mv $remote_file $remote_file.collected-\$(date +%s)" 2>/dev/null || true
        echo "cluster: $h contributed $(( whole / RECORD )) positions to $dest"
    done
    # Data fetched earlier (e.g. from a host taken out of service mid-run).
    for part in data/cluster/gen$gen-*.staged; do
        [ -f "$part" ] || continue
        local bytes
        bytes=$(stat -f %z "$part")
        local whole=$(( bytes / RECORD * RECORD ))
        head -c "$whole" "$part" >> "$dest"
        rm -f "$part"
        echo "cluster: staged $(basename "$part") contributed $(( whole / RECORD )) positions to $dest"
    done
}

cmd=${1:-}
shift || true
case "$cmd" in
    deploy) deploy "$@" ;;
    start) start "$@" ;;
    status) status ;;
    stop) stop ;;
    collect) collect "$@" ;;
    *) sed -n '2,12p' "$0"; exit 2 ;;
esac
