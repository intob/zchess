#!/usr/bin/env bash
# scripts/sprt.sh on a remote x86-64 host (default bitch-box), so the Mac stays
# free. Same fastchess, book openings and SPRT settings; the binaries must be
# x86-64 Linux builds, e.g.
#   zig build -Dtarget=x86_64-linux-musl -Dcpu=x86_64_v3 -Dart=false -Dhidden=512 -Dnet=nets/gen6w.nnue -p zig-out-x86-sprt-base
#
#   scripts/remote-sprt.sh start <new-binary> <base-binary> <label>
#   scripts/remote-sprt.sh status        progress of the latest job
#   scripts/remote-sprt.sh fetch         copy it into sprt/
#
# Remote results come from a 4-core VM next to datagen, so they're slower but
# just as valid as an SPRT on the Mac.
#
# Tunables: HOST=bitch-box TC=8+0.08 ELO0=0 ELO1=5 CONC=3 MAX_ROUNDS=10000 BOOK=data/book.fen
#           THREADS=1 HASH=16 (per engine; for multi-threaded tests keep
#           THREADS x CONC at the host's cores: only the side to move thinks)
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=${HOST:-bitch-box}
TC=${TC:-8+0.08}
ELO0=${ELO0:-0}
ELO1=${ELO1:-5}
CONC=${CONC:-3}
MAX_ROUNDS=${MAX_ROUNDS:-10000}
BOOK=${BOOK:-data/book.fen}
THREADS=${THREADS:-1}
HASH=${HASH:-16}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

start() {
    local new=$1 base=$2 label=$3
    local dir
    dir=zchess-sprt/$(date +%Y%m%d-%H%M)-$label
    local tmp
    tmp=$(mktemp -d)
    cp "$new" "$tmp/new"
    cp "$base" "$tmp/base"
    # Same shuffled openings as sprt.sh (seed 7).
    awk 'BEGIN { srand(7) } { print rand() "\t" $1 " " $2 " " $3 " " $4 }' "$BOOK" |
        sort -n | awk -F'\t' 'NR <= 20000 { print $2 }' > "$tmp/openings.epd"
    cat > "$tmp/run-sprt.sh" <<EOF
#!/bin/sh
# Remote SPRT: $label ($new) vs base ($base), tc=$TC, $THREADS threads, SPRT [$ELO0, $ELO1].
cd "\$(dirname "\$0")" || exit 1
"\$HOME/zchess-tools/fastchess" \\
    -engine cmd=./new name=$label \\
    -engine cmd=./base name=base \\
    -each tc=$TC option.Threads=$THREADS option.Hash=$HASH \\
    -openings file=openings.epd format=epd order=random \\
    -rounds $MAX_ROUNDS -games 2 -repeat -concurrency $CONC \\
    -sprt elo0=$ELO0 elo1=$ELO1 alpha=0.05 beta=0.05 \\
    -report penta=true \\
    -pgnout file=games.pgn > log.txt 2>&1
grep -E "^(Results|Elo|SPRT|LLR|Games|Ptnml)" log.txt | tail -n 6 > summary.txt
touch done
EOF
    chmod +x "$tmp/run-sprt.sh"
    $SSH "$HOST" "mkdir -p $dir"
    scp -q -o BatchMode=yes "$tmp/new" "$tmp/base" "$tmp/openings.epd" "$tmp/run-sprt.sh" "$HOST:$dir/"
    rm -rf "$tmp"
    # `cd` as its own statement so ssh returns at once (see cluster.sh start).
    $SSH -n "$HOST" "cd $dir || exit 1; setsid nohup ./run-sprt.sh > run.log 2>&1 < /dev/null &" < /dev/null
    mkdir -p sprt
    echo "$dir" > sprt/remote-latest.txt
    echo "remote-sprt: $label vs base on $HOST, tc=$TC, $THREADS threads, SPRT [$ELO0, $ELO1], concurrency $CONC -> $HOST:$dir"
}

status() {
    local dir
    dir=$(cat sprt/remote-latest.txt)
    $SSH "$HOST" "cd $dir 2>/dev/null || exit 0; echo \"$dir: \$(test -f done && echo finished || echo running)\"; \
        tr '\r' '\n' < log.txt | grep -E '^(Results|Elo|LLR|Games)' | tail -n 4"
}

fetch() {
    local dir
    dir=$(cat sprt/remote-latest.txt)
    scp -q -r -o BatchMode=yes "$HOST:$dir" sprt/
    echo "remote-sprt: fetched into sprt/$(basename "$dir")"
}

cmd=${1:-}
shift || true
case "$cmd" in
    start) start "$@" ;;
    status) status ;;
    fetch) fetch ;;
    *) sed -n '2,14p' "$0"; exit 2 ;;
esac
