#!/usr/bin/env bash
# Next 512-wide generation, as gen8w was made: collect gen<N>book from the
# cluster, restart cluster datagen as gen<N+1>book with the current best,
# train a 512-wide net on a window of recent data, SPRT it against the best
# (8+0.08, [0, 5]) and promote on H1, switching the cluster to the new net.
#
#   scripts/genw.sh <N> <window>
#   e.g. scripts/genw.sh 9 data/gen7book.bin,data/gen8book.bin,data/gen9book.bin
#
# Everything is built from a clean worktree at HEAD (default ~/zchess-gen<N>,
# data/ linked to this tree's), so uncommitted experiments in this tree stay
# out of the cluster binary, both SPRT engines and the En Croissant engine.
# Commit what should be in the net first. The net, its SPRT result and, on
# promotion, nets/best.txt land in this tree; nothing is committed. Run it
# again after a stop and it resumes (collection and training are skipped once
# done). Run it under caffeinate on a laptop.
#
# Tunables: TRAIN_FLAGS (default gen7's winners: --power 2.5 --epochs 30 --seed 1),
#           WT (worktree path), NODES=10000 (datagen nodes per move),
#           FT8=1 (train an int8-feature-weight net, format version 3; the
#           engine builds below follow the net's header).
set -euo pipefail
cd "$(dirname "$0")/.."
MAIN=$(pwd)
log() { echo "== $(date '+%m-%d %H:%M') $*"; }

N=$1
WINDOW=$2
TRAIN_FLAGS=${TRAIN_FLAGS:---power 2.5 --epochs 30 --seed 1}
WT=${WT:-$HOME/zchess-gen$N}
NODES=${NODES:-10000}
BEST=$(cat nets/best.txt)
NET=nets/gen${N}w.nnue

if [ ! -d "$WT" ]; then
    git worktree add --detach "$WT" HEAD
    ln -s "$MAIN/data" "$WT/data"
fi
cd "$WT"
log "building from $(git rev-parse --short HEAD) in $WT"
# The worktree checks out the tracked nets at HEAD; the best may be newer.
cp "$MAIN/$BEST" "$BEST"

if [ ! -f "data/gen${N}book.bin.done" ]; then
    # This Mac's share (scripts/mac-datagen.sh) is collected as a staged file:
    # stop it first, as it's about to be needed for training anyway.
    "$MAIN/scripts/mac-datagen.sh" stop
    log "collecting gen$N from the cluster"
    scripts/cluster.sh collect "${N}book"
    touch "data/gen${N}book.bin.done"
fi
log "gen$N: $(( $(stat -f %z "data/gen${N}book.bin") / 32 )) positions"

log "cluster: gen$((N + 1)) datagen with $BEST"
scripts/cluster.sh start "$((N + 1))book" "$BEST" "$NODES" data/book.fen

if [ ! -f "$MAIN/$NET" ]; then
    zig build -Dart=false -Dhidden=512 -Dft8="$([ "${FT8:-0}" = 1 ] && echo true || echo false)" -p bins/train512
    log "training $NET (512 wide, FT8=${FT8:-0}, $TRAIN_FLAGS) on $WINDOW"
    # shellcheck disable=SC2086 # TRAIN_FLAGS is deliberately split into words
    bins/train512/bin/zchess train --data "$WINDOW" --out "$NET" $TRAIN_FLAGS
    bins/train512/bin/zchess viz "$NET" || true
    cp "$NET" "$MAIN/$NET"
    log "trained $NET"
fi
cp "$MAIN/$NET" "$NET"

zig build -Dart=false -Dhidden=512 -Dnet="$NET" -p "bins/gen${N}w"
zig build -Dart=false -Dnet="$BEST" -p bins/best
log "SPRT gen${N}w vs $BEST (8+0.08, [0, 5])"
ELO1=5 scripts/sprt.sh "bins/gen${N}w/bin/zchess" bins/best/bin/zchess "gen${N}w-vs-best" | tee "$MAIN/nets/gen${N}w.match.txt"
llr=$(grep -o "LLR: -\?[0-9.]*" "$MAIN/nets/gen${N}w.match.txt" | tail -n 1 | awk '{print $2}')
log "SPRT done: $(grep -o 'Elo: .*' "$MAIN/nets/gen${N}w.match.txt" | tail -n 1)"
if awk "BEGIN { exit !($llr >= 2.94) }"; then
    echo "$NET" > "$MAIN/nets/best.txt"
    # The En Croissant engine (and zig-out generally), from this clean tree.
    zig build -Doptimize=ReleaseFast -Dnet="$NET" -p "$MAIN/zig-out"
    log "promoted $NET (nets/best.txt, not committed); zig-out rebuilt"
    # The rest of gen<N+1> from the new net. Datagen appends, so the earlier
    # positions stay: note where the generator changed.
    scripts/cluster.sh stop
    log "gen$((N + 1))book so far, from $BEST: $(scripts/cluster.sh count "$((N + 1))book") positions"
    scripts/cluster.sh start "$((N + 1))book" "$NET" "$NODES" data/book.fen
    log "cluster: gen$((N + 1)) datagen now with $NET"
else
    log "not promoted (LLR $llr); best stays $BEST"
fi

cd "$MAIN"
rm "$WT/data"
git worktree remove --force "$WT"
log "all done (worktree removed)"
