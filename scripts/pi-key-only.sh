#!/bin/sh
# Make the given Pis accept SSH keys only (no passwords). Validates the sshd
# config before reloading, so a mistake can't lock you out; existing sessions
# are unaffected. Run it yourself:  sh scripts/pi-key-only.sh pi2.local pi3.local
for h in "$@"; do
    echo "== $h"
    ssh "$h" 'printf "# Key-only SSH: this Pi is reachable over the WireGuard overlay.\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n" |
        sudo tee /etc/ssh/sshd_config.d/00-key-only.conf >/dev/null &&
        sudo sshd -t && sudo systemctl reload ssh &&
        sudo sshd -T | grep -i "^passwordauthentication"'
done
