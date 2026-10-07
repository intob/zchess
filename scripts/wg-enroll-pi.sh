#!/usr/bin/env bash
# Put a Pi on the WireGuard overlay (hub: bitch-box) so the laptop can reach it
# from anywhere. The Pi dials out; nothing at home accepts inbound traffic.
#
#   scripts/wg-enroll-pi.sh <lan-ssh-host> <name> <overlay-ip>
#   e.g. scripts/wg-enroll-pi.sh pi2.local pi2 10.99.0.12
#
# Refuses Pis that still accept SSH passwords: once on the overlay, the Pi's
# SSH key check is the boundary against the internet-facing hub.
# Overlay IPs must lie in 10.99.0.8/29 or 10.99.0.16/29 (the hub's laptop->Pi
# forwarding rules).
set -euo pipefail

LAN=$1
NAME=$2
IP=$3
HUB=bitch-box
HUB_PUBKEY=${HUB_PUBKEY:?the hub\'s WireGuard public key (sudo wg show wg0 public-key on the hub)}
HUB_ENDPOINT=${HUB_ENDPOINT:?the hub\'s public address and WireGuard port, host:port}
SSH="ssh -o BatchMode=yes -o ConnectTimeout=8 -o ServerAliveInterval=15 -o ServerAliveCountMax=4"

auth=$($SSH "$LAN" 'sudo -n sshd -T | awk "/^passwordauthentication/{print \$2}"')
if [ "$auth" != no ]; then
    echo "$LAN still accepts SSH passwords (passwordauthentication=$auth); make it key-only first." >&2
    exit 1
fi

echo "== $LAN: install, key, config"
pubkey=$($SSH "$LAN" "set -e
    sudo -n env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wireguard-tools nftables >/dev/null 2>&1
    sudo -n test -f /etc/wireguard/privatekey || sudo -n sh -c 'umask 077; wg genkey > /etc/wireguard/privatekey'
    sudo -n tee /etc/wireguard/wg-guard.nft >/dev/null <<'EOF'
# Only the laptop (10.99.0.2, 10.99.0.3) may reach this Pi over the overlay, and
# only for SSH and ping. Everything else arriving on wg0, including traffic
# from the hub itself (10.99.0.1), is dropped.
table inet wg_guard {
    chain input {
        type filter hook input priority 0; policy accept;
        iifname \"wg0\" ct state established,related accept
        iifname \"wg0\" ip saddr { 10.99.0.2, 10.99.0.3 } tcp dport 22 accept
        iifname \"wg0\" ip saddr { 10.99.0.2, 10.99.0.3 } icmp type echo-request accept
        iifname \"wg0\" drop
    }
}
EOF
    sudo -n tee /etc/wireguard/wg0.conf >/dev/null <<'EOF'
# zchess cluster: outbound tunnel to the bitch-box hub, so the laptop can reach
# this Pi from anywhere. Split tunnel: only 10.99.0.0/24 goes through it.
# The private key is not inline; PostUp loads it from a 0600 file.
[Interface]
Address = $IP/24
PostUp = wg set %i private-key /etc/wireguard/privatekey
PostUp = /usr/sbin/nft list table inet wg_guard >/dev/null 2>&1 && /usr/sbin/nft delete table inet wg_guard; /usr/sbin/nft -f /etc/wireguard/wg-guard.nft
PostDown = /usr/sbin/nft delete table inet wg_guard

[Peer]
# bitch-box hub
PublicKey = $HUB_PUBKEY
Endpoint = $HUB_ENDPOINT
AllowedIPs = 10.99.0.0/24
PersistentKeepalive = 25
EOF
    sudo -n chmod 600 /etc/wireguard/wg0.conf /etc/wireguard/wg-guard.nft
    sudo -n /usr/sbin/nft -c -f /etc/wireguard/wg-guard.nft
    sudo -n cat /etc/wireguard/privatekey | wg pubkey")
echo "   public key $pubkey"

echo "== $HUB: peer $NAME -> $IP"
$SSH "$HUB" "set -e
    if ! sudo -n grep -q '$pubkey' /etc/wireguard/wg0.conf; then
        sudo -n cp /etc/wireguard/wg0.conf /etc/wireguard/wg0.conf.bak-\$(date +%Y%m%d-%H%M%S)
        printf '\n[Peer]\n# zchess $NAME (dials out from home; only the laptop may SSH to it, see ufw route rules)\nPublicKey = $pubkey\nAllowedIPs = $IP/32\n' | sudo -n tee -a /etc/wireguard/wg0.conf >/dev/null
    fi
    sudo -n wg set wg0 peer '$pubkey' allowed-ips $IP/32"

echo "== $LAN: bring up tunnel"
$SSH "$LAN" 'sudo -n systemctl enable --now wg-quick@wg0 >/dev/null 2>&1; sudo -n systemctl restart wg-quick@wg0'

if ! grep -q "^Host $NAME-wg\$" ~/.ssh/config; then
    printf '\nHost %s-wg\n\tHostName %s\n\tHostKeyAlias %s\n' "$NAME" "$IP" "$LAN" >> ~/.ssh/config
fi
# The first handshake can take a few seconds; retry for up to ~30 s.
for _ in 1 2 3 4 5 6; do
    if out=$($SSH -o ConnectTimeout=5 "$NAME-wg" 'echo "$(hostname) reachable over the overlay"' 2>/dev/null); then
        echo "== verify: $out"
        echo "Add '$NAME-wg' to cluster/hosts.txt."
        exit 0
    fi
    sleep 5
done
echo "== verify: $NAME-wg not reachable yet; check 'sudo wg show' on $LAN and on $HUB" >&2
exit 1
