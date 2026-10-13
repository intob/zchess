#!/usr/bin/env bash
# Training experiments on the gen7w data window, each changing one thing from
# the gen7w recipe (512 wide, 15 epochs, loss power 2, no king buckets):
#
#   gen7w        the baseline (what genw.sh 7 trains)
#   gen7w-p25    loss power 2.5
#   gen7w-kb8    8 king buckets, mirrored
#   gen7w-e30    30 epochs
#   gen7w-p25-e30  loss power 2.5 and 30 epochs (the two winners combined)
#
# The Mac trains them in turn; SPRTs (8+0.08, [0, 5]) run as nets become ready,
# on bitch-box while the Mac trains and also on the Mac once training is done,
# from one shared queue. Nothing is promoted: compare the results by hand.
#
#   scripts/exp-gen7.sh            everything (resumes: finished steps are skipped)
#   scripts/exp-gen7.sh train      just the training chain
#   scripts/exp-gen7.sh sprt <remote|local>   one SPRT runner; more remote ones can join,
#                                  e.g. HOST=$(scripts/hetzner.sh host) CONC=24 ... sprt remote
#
# Tunables: WINDOW=... HOST=bitch-box CONC (remote: 3, local: 10)
set -euo pipefail
cd "$(dirname "$0")/.."
log() { echo "== $(date '+%m-%d %H:%M') $*"; }

WINDOW=${WINDOW:-data/gen5book.bin,data/gen5rand.bin,data/gen6book.bin,data/gen7book.bin}
HOST=${HOST:-bitch-box}
STATE=sprt/exp-gen7
mkdir -p "$STATE"

# name | king buckets | extra train flags
EXPERIMENTS=(
    "gen7w|0|"
    "gen7w-p25|0|--power 2.5"
    "gen7w-kb8|8|"
    "gen7w-e30|0|--epochs 30"
    "gen7w-p25-e30|0|--power 2.5 --epochs 30"
)
# new | base, in the order they should run
SPRTS=(
    "gen7w|gen6w"
    "gen7w-p25|gen7w"
    "gen7w-kb8|gen7w"
    "gen7w-e30|gen7w"
    "gen7w-p25-e30|gen7w-p25"
)

ready() { [ -f "nets/$1.nnue.done" ] || [ "$1" = gen6w ]; }

train_all() {
    for e in "${EXPERIMENTS[@]}"; do
        IFS='|' read -r name kb flags <<< "$e"
        ready "$name" && continue
        zig build -Dart=false -Dec=false -Dhidden=512 -Dking-buckets="$kb" -p "bins/train512kb$kb"
        log "training nets/$name.nnue (king buckets $kb, flags '$flags')"
        # shellcheck disable=SC2086
        "bins/train512kb$kb/bin/zchess" train --data "$WINDOW" --out "nets/$name.nnue" --epochs 15 --seed 1 $flags
        "bins/train512kb$kb/bin/zchess" viz "nets/$name.nnue" || true
        touch "nets/$name.nnue.done"
        log "trained nets/$name.nnue"
    done
    touch "$STATE/train.done"
}

# Claims the next SPRT whose nets are ready; prints "new|base" or nothing.
# Waits while unclaimed jobs are still waiting for nets.
claim() {
    while :; do
        local waiting=0
        for j in "${SPRTS[@]}"; do
            IFS='|' read -r new base <<< "$j"
            [ -d "$STATE/$new.claimed" ] && continue
            if ready "$new" && ready "$base"; then
                mkdir "$STATE/$new.claimed" 2>/dev/null && { echo "$j"; return; }
            else
                waiting=1
            fi
        done
        [ "$waiting" = 1 ] || return 0
        sleep 60
    done
}

sprt_runner() {
    local where=$1
    if [ "$where" = local ]; then
        # The Mac only plays once it has finished training.
        while [ ! -f "$STATE/train.done" ]; do sleep 60; done
    fi
    while :; do
        local job new base
        job=$(claim)
        [ -n "$job" ] || break
        IFS='|' read -r new base <<< "$job"
        log "SPRT $new vs $base ($where$([ "$where" = remote ] && echo " on $HOST, concurrency ${CONC:-3}"))"
        if [ "$where" = local ]; then
            zig build -Dart=false -Dec=false -Dnet="nets/$new.nnue" -p "bins/$new"
            zig build -Dart=false -Dec=false -Dnet="nets/$base.nnue" -p "bins/$base"
            scripts/sprt.sh "bins/$new/bin/zchess" "bins/$base/bin/zchess" "$new-vs-$base" > "$STATE/$new.txt"
        else
            for n in "$new" "$base"; do
                zig build -Dtarget=x86_64-linux-musl -Dcpu=x86_64_v3 -Dart=false -Dnet="nets/$n.nnue" -p "bins/x86-$n"
            done
            local started dir
            until started=$(HOST=$HOST scripts/remote-sprt.sh start "bins/x86-$new/bin/zchess" "bins/x86-$base/bin/zchess" "$new-vs-$base"); do
                log "couldn't start on $HOST; retrying in 5 min"
                sleep 300
            done
            echo "$started"
            # From its own output, not sprt/remote-latest.txt: other runners share that file.
            dir=${started##*:}
            until ssh -o BatchMode=yes -o ConnectTimeout=8 "$HOST" "test -f $dir/done"; do sleep 300; done
            until scp -q -r -o BatchMode=yes "$HOST:$dir" sprt/; do sleep 300; done
            cp "sprt/$(basename "$dir")/summary.txt" "$STATE/$new.txt"
        fi
        log "SPRT $new vs $base done: $(grep -E '^(Elo|LLR)' "$STATE/$new.txt" | tr '\n' ' ')"
    done
    log "SPRT runner ($where) finished"
}

case "${1:-all}" in
    train) train_all ;;
    sprt) sprt_runner "$2" ;;
    all)
        trap 'kill $(jobs -p) 2>/dev/null || true' EXIT
        sprt_runner remote &
        sprt_runner local &
        train_all
        wait
        log "all done"
        for j in "${SPRTS[@]}"; do
            IFS='|' read -r new base <<< "$j"
            echo "$new vs $base: $(grep -E '^(Elo|LLR)' "$STATE/$new.txt" 2>/dev/null | tr '\n' ' ')"
        done
        ;;
    *) sed -n '2,19p' "$0"; exit 2 ;;
esac
