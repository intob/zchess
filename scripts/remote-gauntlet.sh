#!/usr/bin/env bash
# Run a Stockfish gauntlet on a remote x86-64 host (default bitch-box), so the
# Mac stays free for datagen, training and promotion SPRTs. Same fastchess and
# Stockfish 19 as scripts/gauntlet.sh, installed in ~/zchess-tools on the host.
#
#   scripts/remote-gauntlet.sh start [net]   build, upload and launch (default: nets/best.txt)
#   scripts/remote-gauntlet.sh status        progress of the current job
#   scripts/remote-gauntlet.sh fetch         copy finished results into gauntlet/
#
# Ratings from different hardware aren't directly comparable: compare nets
# gauntleted on the same host (gen4 is the baseline on bitch-box).
#
# Tunables: HOST=bitch-box LEVELS="2800 3000 3190" GAMES=200 TC=10+0.1 CONC=3
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=${HOST:-bitch-box}
LEVELS=${LEVELS:-"2800 3000 3190"}
GAMES=${GAMES:-200}
TC=${TC:-10+0.1}
CONC=${CONC:-3}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
hidden_of() { od -An -tu4 -j8 -N4 "$1" | tr -d ' '; }

start() {
    local net=${1:-$(cat nets/best.txt)}
    if $SSH "$HOST" "pgrep -f 'run-[g]auntlet.sh' >/dev/null"; then
        echo "remote-gauntlet: a gauntlet is already running on $HOST" >&2
        return 1
    fi
    local name dir
    name=$(date +%Y%m%d-%H%M)-$(basename "$net" .nnue)
    dir=zchess-gauntlet/$name
    zig build -Dtarget=x86_64-linux-musl -Dcpu=x86_64_v3 -Dart=false -Dnet="$net" -Dhidden="$(hidden_of "$net")" -p zig-out-x86-gauntlet

    local tmp
    tmp=$(mktemp -d)
    cp zig-out-x86-gauntlet/bin/zchess "$tmp/zchess"
    # Same 20k shuffled book openings as the local gauntlet (seed 42).
    awk 'BEGIN { srand(42) } { print rand() "\t" $1 " " $2 " " $3 " " $4 }' data/book.fen |
        sort -n | awk -F'\t' 'NR <= 20000 { print $2 }' > "$tmp/openings.epd"
    cat > "$tmp/run-gauntlet.sh" <<EOF
#!/bin/sh
# Remote gauntlet job: $net vs Stockfish UCI_Elo [$LEVELS], $GAMES games each at $TC.
cd "\$(dirname "\$0")" || exit 1
T=\$HOME/zchess-tools
for elo in $LEVELS; do
    "\$T/fastchess" -engine cmd=./zchess name=zchess \\
        -engine cmd="\$T/stockfish" name="sf\$elo" option.UCI_LimitStrength=true option.UCI_Elo="\$elo" \\
        -each tc=$TC option.Threads=1 option.Hash=16 \\
        -openings file=openings.epd format=epd order=random \\
        -rounds $((GAMES / 2)) -games 2 -repeat -concurrency $CONC \\
        -pgnout file="sf\$elo.pgn" > "sf\$elo.txt" 2>&1
    echo "== vs sf\$elo: \$(grep -E '^Games:' "sf\$elo.txt" | tail -n 1) | \$(grep -E '^Elo:' "sf\$elo.txt" | tail -n 1)" >> summary.txt
done
touch done
EOF
    chmod +x "$tmp/run-gauntlet.sh"
    $SSH "$HOST" "mkdir -p $dir"
    scp -q "$tmp/zchess" "$tmp/openings.epd" "$tmp/run-gauntlet.sh" "$HOST:$dir/"
    rm -rf "$tmp"
    # `cd` as its own statement so ssh returns at once (see cluster.sh start).
    $SSH -n "$HOST" "cd $dir || exit 1; setsid nohup ./run-gauntlet.sh > run.log 2>&1 < /dev/null &" < /dev/null
    echo "$dir" > gauntlet/remote-latest.txt
    echo "remote-gauntlet: $net on $HOST [$LEVELS], $GAMES games each at $TC, concurrency $CONC -> $HOST:$dir"
}

status() {
    local dir
    dir=$(cat gauntlet/remote-latest.txt)
    $SSH "$HOST" "cd $dir 2>/dev/null || exit 0; echo \"$dir: \$(test -f done && echo finished || echo running)\"; cat summary.txt 2>/dev/null; \
        cur=\$(ls -t sf*.txt 2>/dev/null | head -n 1); [ -n \"\$cur\" ] && [ ! -f done ] && echo \"current \${cur%.txt}: \$(tr '\r' '\n' < \$cur | grep -E '^Games:' | tail -n 1)\"; true"
}

fetch() {
    local dir
    dir=$(cat gauntlet/remote-latest.txt)
    mkdir -p gauntlet
    scp -q -r "$HOST:$dir" gauntlet/
    echo "remote-gauntlet: fetched into gauntlet/$(basename "$dir")"
}

mkdir -p gauntlet
cmd=${1:-}
shift || true
case "$cmd" in
    start) start "$@" ;;
    status) status ;;
    fetch) fetch ;;
    *) sed -n '2,13p' "$0"; exit 2 ;;
esac
