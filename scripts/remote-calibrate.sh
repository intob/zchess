#!/usr/bin/env bash
# Strength-limit calibration on a remote host (default bitch-box): zchess with
# UCI_LimitStrength at UCI_Elo X vs Stockfish 19 limited to the same X. A 50%
# score means X is accurate; otherwise the Elo difference is the error. Waits
# for a running remote gauntlet to finish first so the two don't share cores.
#
#   scripts/remote-calibrate.sh start [net]   build, upload and launch (default: nets/best.txt)
#   scripts/remote-calibrate.sh status        progress of the current job
#   scripts/remote-calibrate.sh fetch         copy finished results into gauntlet/
#
# Tunables: HOST=bitch-box LEVELS="1400 2000 2600" GAMES=100 TC=10+0.1 CONC=3
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=${HOST:-bitch-box}
LEVELS=${LEVELS:-"1400 2000 2600"}
GAMES=${GAMES:-100}
TC=${TC:-10+0.1}
CONC=${CONC:-3}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"
hidden_of() { od -An -tu4 -j8 -N4 "$1" | tr -d ' '; }

start() {
    local net=${1:-$(cat nets/best.txt)}
    if $SSH "$HOST" "pgrep -f 'run-[c]alibrate.sh' >/dev/null"; then
        echo "remote-calibrate: a calibration is already running on $HOST" >&2
        return 1
    fi
    local name dir
    name=$(date +%Y%m%d-%H%M)-$(basename "$net" .nnue)
    dir=zchess-calibrate/$name
    zig build -Dtarget=x86_64-linux-musl -Dcpu=x86_64_v3 -Dart=false -Dnet="$net" -Dhidden="$(hidden_of "$net")" -p zig-out-x86-calibrate

    local tmp
    tmp=$(mktemp -d)
    cp zig-out-x86-calibrate/bin/zchess "$tmp/zchess"
    awk 'BEGIN { srand(42) } { print rand() "\t" $1 " " $2 " " $3 " " $4 }' data/book.fen |
        sort -n | awk -F'\t' 'NR <= 20000 { print $2 }' > "$tmp/openings.epd"
    cat > "$tmp/run-calibrate.sh" <<EOF
#!/bin/sh
# Strength calibration: $net, UCI_Elo [$LEVELS] vs Stockfish at the same Elo, $GAMES games each at $TC.
cd "\$(dirname "\$0")" || exit 1
T=\$HOME/zchess-tools
while pgrep -f 'run-[g]auntlet.sh' >/dev/null; do sleep 60; done
for elo in $LEVELS; do
    echo "\$(date '+%F %T') level \$elo" >> progress.log
    "\$T/fastchess" \\
        -engine cmd=./zchess name="zchess\$elo" option.UCI_LimitStrength=true option.UCI_Elo="\$elo" \\
        -engine cmd="\$T/stockfish" name="sf\$elo" option.UCI_LimitStrength=true option.UCI_Elo="\$elo" \\
        -each tc=$TC option.Threads=1 option.Hash=16 \\
        -openings file=openings.epd format=epd order=random \\
        -rounds $((GAMES / 2)) -games 2 -repeat -concurrency $CONC \\
        -pgnout file="cal\$elo.pgn" > "cal\$elo.txt" 2>&1
    echo "== \$elo: \$(grep -E '^Games:' "cal\$elo.txt" | tail -n 1) | \$(grep -E '^Elo:' "cal\$elo.txt" | tail -n 1)" >> summary.txt
done
touch done
EOF
    chmod +x "$tmp/run-calibrate.sh"
    $SSH "$HOST" "mkdir -p $dir"
    scp -q "$tmp/zchess" "$tmp/openings.epd" "$tmp/run-calibrate.sh" "$HOST:$dir/"
    rm -rf "$tmp"
    $SSH -n "$HOST" "cd $dir || exit 1; setsid nohup ./run-calibrate.sh > run.log 2>&1 < /dev/null &" < /dev/null
    echo "$dir" > gauntlet/calibrate-latest.txt
    echo "remote-calibrate: $net on $HOST [$LEVELS], $GAMES games each at $TC -> $HOST:$dir"
}

status() {
    local dir
    dir=$(cat gauntlet/calibrate-latest.txt)
    $SSH "$HOST" "cd $dir 2>/dev/null || exit 0; echo \"$dir: \$(test -f done && echo finished || { test -f progress.log && echo running || echo waiting; })\"; cat summary.txt 2>/dev/null; \
        cur=\$(ls -t cal*.txt 2>/dev/null | head -n 1); [ -n \"\$cur\" ] && [ ! -f done ] && echo \"current \${cur%.txt}: \$(tr '\r' '\n' < \$cur | grep -E '^Games:' | tail -n 1)\"; true"
}

fetch() {
    local dir
    dir=$(cat gauntlet/calibrate-latest.txt)
    mkdir -p gauntlet
    scp -q -r "$HOST:$dir" gauntlet/
    echo "remote-calibrate: fetched into gauntlet/$(basename "$dir")"
}

mkdir -p gauntlet
cmd=${1:-}
shift || true
case "$cmd" in
    start) start "$@" ;;
    status) status ;;
    fetch) fetch ;;
    *) sed -n '2,12p' "$0"; exit 2 ;;
esac
