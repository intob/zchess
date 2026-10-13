#!/usr/bin/env bash
# A rented Hetzner Cloud server for bursts of SPRTs (and datagen), deleted when
# idle. Uses hcloud's active context (`hcloud context list`), so the API token
# stays in hcloud's own config.
#
#   scripts/hetzner.sh up [type]   create the server (default ccx63: 48 dedicated
#                                  vCPUs = 24 cores), wait for ssh, install fastchess
#   scripts/hetzner.sh host        print its ssh host (root@<ip>) for HOST=...
#   scripts/hetzner.sh status      our servers, their type and age, what's running
#   scripts/hetzner.sh allow       let this laptop's current public IP in (after moving networks)
#   scripts/hetzner.sh down        delete it; refuses while an SPRT or datagen runs
#                                  or datagen output is still there (FORCE=1 overrides)
#
# Billing: a cloud server costs money from creation until deletion, powered off
# or not, by the hour (minimum one). `down` is the off switch.
#
# Use it like bitch-box, with CONC at the core count:
#   HOST=$(scripts/hetzner.sh host) CONC=24 scripts/remote-sprt.sh start ...
#   HOST=$(scripts/hetzner.sh host) CONC=24 scripts/exp-gen7.sh sprt remote
#
# Tunables: TYPE=ccx63 LOCATION=fsn1 NAME=zchess-burst SSH_KEY=<hcloud ssh-key name>
set -euo pipefail
cd "$(dirname "$0")/.."
log() { echo "hetzner: $*"; }

NAME=${NAME:-zchess-burst}
LOCATION=${LOCATION:-fsn1}
IMAGE=ubuntu-24.04
FIREWALL=$NAME-ssh
LABEL=zchess=burst
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

ip_of() { hcloud server ip "$NAME" 2>/dev/null; }
my_ip() { dig +short -4 myip.opendns.com @resolver1.opendns.com; }

allow() {
    local me
    me=$(my_ip)
    [ -n "$me" ] || { log "couldn't find this machine's public IP"; exit 1; }
    hcloud firewall describe "$FIREWALL" >/dev/null 2>&1 ||
        hcloud firewall create --name "$FIREWALL" --label "$LABEL" >/dev/null
    local rules
    rules=$(mktemp)
    printf '[{"direction":"in","protocol":"tcp","port":"22","source_ips":["%s/32"]}]\n' "$me" > "$rules"
    hcloud firewall replace-rules "$FIREWALL" --rules-file "$rules" >/dev/null
    rm -f "$rules"
    log "ssh allowed from $me only"
}

up() {
    local type=${1:-${TYPE:-ccx63}}
    if ip_of >/dev/null; then
        log "$NAME already exists ($(ip_of)); 'down' it first or use it"
        exit 1
    fi
    local key=${SSH_KEY:-$(hcloud ssh-key list -o noheader -o columns=name | head -n 1)}
    [ -n "$key" ] || { log "no ssh key in this hcloud project (hcloud ssh-key create ...)"; exit 1; }
    allow
    log "creating $NAME: $type in $LOCATION, $IMAGE, ssh key '$key' (billed from now until 'down')"
    hcloud server create --name "$NAME" --type "$type" --location "$LOCATION" --image "$IMAGE" \
        --ssh-key "$key" --firewall "$FIREWALL" --label "$LABEL" >/dev/null
    local ip
    ip=$(ip_of)
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    log "waiting for ssh on $ip"
    until ssh-keyscan -T 5 -t ed25519 "$ip" 2>/dev/null | grep -q ed25519; do sleep 5; done
    ssh-keyscan -t ed25519 "$ip" 2>/dev/null >> ~/.ssh/known_hosts
    until $SSH "root@$ip" true 2>/dev/null; do sleep 5; done
    # Key-only root login (no password is set, but make it explicit).
    $SSH "root@$ip" "printf 'PasswordAuthentication no\nKbdInteractiveAuthentication no\n' > /etc/ssh/sshd_config.d/10-zchess.conf && systemctl reload ssh; mkdir -p zchess-tools zchess/data"
    # fastchess is a static binary: take bitch-box's.
    scp -q -3 -o BatchMode=yes bitch-box:zchess-tools/fastchess "root@$ip:zchess-tools/fastchess"
    log "ready: root@$ip ($($SSH "root@$ip" nproc) vCPUs). Delete it with: scripts/hetzner.sh down"
}

host() {
    local ip
    ip=$(ip_of) || { log "no server $NAME (scripts/hetzner.sh up)" >&2; exit 1; }
    echo "root@$ip"
}

busy() { # prints what's running or left on the server, if anything
    $SSH "root@$1" "pgrep -fa 'run-sprt.sh|fastchess|zchess datagen' | grep -v pgrep; ls zchess/data/*.bin 2>/dev/null" 2>/dev/null || true
}

status() {
    hcloud server list -l "$LABEL" -o columns=name,type,status,ipv4,location,age
    local ip
    if ip=$(ip_of); then
        local b
        b=$(busy "$ip")
        if [ -n "$b" ]; then echo "running or left on $NAME:"; echo "$b"; else echo "$NAME is idle"; fi
    fi
}

down() {
    local ip
    ip=$(ip_of) || { log "no server $NAME"; exit 0; }
    local b
    b=$(busy "$ip")
    if [ -n "$b" ] && [ "${FORCE:-0}" != 1 ]; then
        log "not deleting: still running or holding data (FORCE=1 to delete anyway):"
        echo "$b"
        exit 1
    fi
    hcloud server delete "$NAME" >/dev/null
    ssh-keygen -R "$ip" >/dev/null 2>&1 || true
    log "deleted $NAME ($ip); billing stopped"
}

case "${1:-}" in
    up) up "${2:-}" ;;
    host) host ;;
    status) status ;;
    allow) allow ;;
    down) down ;;
    *) sed -n '2,24p' "$0"; exit 2 ;;
esac
