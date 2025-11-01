
#!/usr/bin/env bash
set -euo pipefail
echo "[oneclick][30_vpn] Installing WireGuard + resolvconf"
apt-get update -y || true
apt-get install -y --no-install-recommends wireguard resolvconf || apt-get install -y --no-install-recommends wireguard openresolv || true

DEST="/etc/wireguard"
mkdir -p "$DEST"
chmod 700 "$DEST"
echo "[oneclick][30_vpn] If you have a private repo, place *.conf in $DEST"
