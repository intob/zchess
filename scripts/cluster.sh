#!/usr/bin/env bash
# Raspberry Pi cluster for self-play data generation.
# Hosts are listed one per line in cluster/hosts.txt (ssh names, # comments ok);
# hosts.txt uses the WireGuard overlay (works anywhere); HOSTS_FILE=cluster/hosts-lan.txt
# uses the home LAN directly.
#
#   scripts/cluster.sh deploy <net>             build for Pi 5 and copy binary + net
#   scripts/cluster.sh start <gen> <net> <nodes> [book]  deploy, then run datagen for that generation
#                                               as a systemd service (survives reboots and crashes)
#   scripts/cluster.sh status                   last progress line from every host
#   scripts/cluster.sh stop                     stop datagen everywhere and disable the service
#   scripts/cluster.sh collect <gen>            stop, fetch and append each host's data to data/gen<gen>.bin
#   scripts/cluster.sh count <gen>              total positions generated so far across hosts
#
# pipeline.sh calls `start` before its own datagen and `collect` before training.
# Files in data/cluster/gen<gen>-*.staged are appended by `collect` too.
set -euo pipefail
cd "$(dirname "$0")/.."

SSH="ssh -o BatchMode=yes -o ConnectTimeout=5"
REMOTE=zchess
PREFIX_ARM=zig-out-pi   # Raspberry Pi 5 (Cortex-A76)
PREFIX_X86=zig-out-x86  # x86-64 cloud VMs (AVX2 baseline)
RECORD=32
# Thermal guard: pause datagen at GUARD_HIGH C, resume at GUARD_LOW C.
GUARD_HIGH=${GUARD_HIGH:-75}
GUARD_LOW=${GUARD_LOW:-68}

HOSTS_FILE=${HOSTS_FILE:-cluster/hosts.txt}

hosts() {
    grep -v '^[[:space:]]*#' "$HOSTS_FILE" | grep -v '^[[:space:]]*$'
}

# Network width, read from the .nnue header (u32 at byte 8).
hidden_of() { od -An -tu4 -j8 -N4 "$1" | tr -d ' '; }

build() { # [net]: build for that net's width (default 256)
    local h=256
    [ -n "${1:-}" ] && [ "$1" != hce ] && h=$(hidden_of "$1")
    zig build -Dtarget=aarch64-linux-musl -Dcpu=cortex_a76 -Dart=false -Dhidden="$h" -p "$PREFIX_ARM"
    zig build -Dtarget=x86_64-linux-musl -Dcpu=x86_64_v3 -Dart=false -Dhidden="$h" -p "$PREFIX_X86"
}

# Copy binary, guard and net to the given hosts (default: all). Files are
# uploaded under a temporary name and renamed, so a running binary is never
# overwritten in place.
deploy() {
    local net=$1
    shift
    local targets=${*:-$(hosts)}
    build "$net"
    for h in $targets; do
        if ! $SSH "$h" "mkdir -p $REMOTE/data" 2>/dev/null; then
            echo "cluster: $h unreachable, skipping"
            continue
        fi
        local arch prefix
        arch=$($SSH "$h" uname -m)
        case "$arch" in
            aarch64) prefix=$PREFIX_ARM ;;
            x86_64) prefix=$PREFIX_X86 ;;
            *) echo "cluster: $h has unsupported arch $arch, skipping"; continue ;;
        esac
        scp -q "$prefix/bin/zchess" "$h:$REMOTE/zchess.new"
        scp -q scripts/pi-thermal-guard.sh "$h:$REMOTE/pi-thermal-guard.sh.new"
        scp -q scripts/run-datagen.sh "$h:$REMOTE/run-datagen.sh.new"
        [ "$net" != hce ] && scp -q "$net" "$h:$REMOTE/"
        $SSH "$h" "cd $REMOTE && mv zchess.new zchess && mv pi-thermal-guard.sh.new pi-thermal-guard.sh && mv run-datagen.sh.new run-datagen.sh && chmod +x zchess pi-thermal-guard.sh run-datagen.sh"
        echo "cluster: deployed to $h ($arch)"
    done
}

start() {
    local gen=$1 net=$2 nodes=$3 book=${4:-}
    # Only touch hosts that are idle.
    local idle=""
    for h in $(hosts); do
        if ! $SSH "$h" true 2>/dev/null; then
            echo "cluster: $h unreachable, skipping"
        elif $SSH "$h" "pgrep -f '^[.]/zchess datagen' >/dev/null || pgrep -f 'pi-[t]hermal-guard' >/dev/null" 2>/dev/null; then
            echo "cluster: $h already running datagen or a guard; run 'cluster.sh stop' first"
        else
            idle="$idle $h"
        fi
    done
    [ -z "$idle" ] && return 0
    deploy "$net" $idle
    local remote_net=hce
    [ "$net" != hce ] && remote_net=$(basename "$net")
    local book_opt=""
    if [ -n "$book" ]; then
        for h in $idle; do scp -q "$book" "$h:$REMOTE/" 2>/dev/null || true; done
        book_opt="--book $(basename "$book")"
    fi
    for h in $idle; do
        # Settings for run-datagen.sh; the service re-reads them on every (re)start.
        printf 'GEN=%s\nNET=%s\nNODES=%s\nBOOK_OPT="%s"\nGUARD_HIGH=%s\nGUARD_LOW=%s\n' \
            "$gen" "$remote_net" "$nodes" "$book_opt" "$GUARD_HIGH" "$GUARD_LOW" |
            $SSH "$h" "cat > $REMOTE/datagen.env"
        # systemd unit: restarts datagen after reboots, power cuts and crashes.
        local user dir
        user=$($SSH "$h" whoami)
        dir=$($SSH "$h" 'echo $HOME')/$REMOTE
        if printf '%s\n' \
            '[Unit]' \
            'Description=zchess self-play data generation' \
            'After=network-online.target' \
            'Wants=network-online.target' \
            '' \
            '[Service]' \
            "User=$user" \
            "ExecStart=$dir/run-datagen.sh" \
            'Nice=19' \
            'Restart=always' \
            'RestartSec=30' \
            '' \
            '[Install]' \
            'WantedBy=multi-user.target' |
            $SSH "$h" "sudo -n tee /etc/systemd/system/zchess-datagen.service >/dev/null && sudo -n systemctl daemon-reload && sudo -n systemctl enable --now zchess-datagen >/dev/null 2>&1"; then
            echo "cluster: $h generating gen$gen as a service ($remote_net, $nodes nodes, thermal guard ${GUARD_HIGH}C/${GUARD_LOW}C)"
        else
            echo "cluster: $h: could not install the service (needs passwordless sudo)"
        fi
    done
}

status() {
    for h in $(hosts); do
        local line
        line=$($SSH "$h" "cd $REMOTE 2>/dev/null || exit 0; \
            if pgrep -f '^[.]/zchess datagen' >/dev/null; then echo -n 'running: '; else echo -n 'idle: '; fi; \
            ls -t datagen-gen*.log 2>/dev/null | head -n 1 | xargs -r tail -c 200 | tr '\r' '\n' | grep -a . | tail -n 1; \
            if command -v vcgencmd >/dev/null; then hw=\$(vcgencmd measure_temp); \
            else hw=\"cpu steal \$(vmstat 1 2 | awk 'NR==2{for(i=1;i<=NF;i++) if(\$i==\"st\") c=i} END{print \$c}')%\"; fi; \
            echo \" | \$hw | guard: \$(tail -n 1 guard.log 2>/dev/null)\"" 2>/dev/null || echo "unreachable")
        echo "$h: $line"
    done
}

stop() {
    for h in $(hosts); do
        # Bracketed patterns so pkill never matches the remote shell running this.
        $SSH "$h" "sudo -n systemctl disable --now zchess-datagen >/dev/null 2>&1; pkill -f 'pi-[t]hermal-guard'; for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f 'pi-[t]hermal-guard' >/dev/null || break; sleep 1; done; \
            pkill -CONT -f '^[.]/zchess datagen'; pkill -f '^[.]/zchess datagen'; \
            for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -f '^[.]/zchess datagen' >/dev/null || exit 0; sleep 1; done" 2>/dev/null || true
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

# Total positions generated for <gen> across all reachable hosts.
count() {
    local gen=$1 total=0 n
    for h in $(hosts); do
        n=$($SSH "$h" "stat -c %s $REMOTE/data/gen$gen.bin 2>/dev/null || echo 0" 2>/dev/null || echo 0)
        total=$((total + n / RECORD))
    done
    echo "$total"
}

cmd=${1:-}
shift || true
case "$cmd" in
    deploy) deploy "$@" ;;
    start) start "$@" ;;
    status) status ;;
    stop) stop ;;
    collect) collect "$@" ;;
    count) count "$@" ;;
    *) sed -n '2,12p' "$0"; exit 2 ;;
esac
