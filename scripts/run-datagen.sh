#!/bin/sh
# Started by systemd (zchess-datagen.service) on cluster hosts, so datagen
# comes back by itself after a reboot, power cut or crash. Settings come from
# datagen.env, written by `scripts/cluster.sh start`.
cd "$(dirname "$0")" || exit 1
. ./datagen.env
# A fresh seed on every start: node-limited search is deterministic, so a
# restart with the same seed would replay the same games.
SEED=$(od -An -N8 -tu8 /dev/urandom | tr -d ' ')
echo "$(date '+%F %T') start: gen$GEN, $NET, $NODES nodes, seed $SEED" >> service.log
./pi-thermal-guard.sh "$GUARD_HIGH" "$GUARD_LOW" >> guard.log 2>&1 &
# shellcheck disable=SC2086 # BOOK_OPT is deliberately split into words
exec ./zchess datagen --out "data/gen$GEN.bin" --positions 1000000000 --nodes "$NODES" \
    --threads "$(nproc)" --net "$NET" --seed "$SEED" $BOOK_OPT >> "datagen-gen$GEN.log" 2>&1
