
#!/usr/bin/env bash
# System-level tweaks (no systemd)
set -euo pipefail

echo "[oneclick][20_optimize] Installing unbound (local DNS cache) and rng-tools"
apt-get update -y || true
apt-get install -y --no-install-recommends unbound rng-tools || true

# Try to apply kernel TCP tuning (BBR if present)
SYSCTL_FILE="/etc/sysctl.d/99-oneclick.conf"
TCP_CC="bbr"
modprobe tcp_bbr 2>/dev/null || TCP_CC="cubic"

cat >"$SYSCTL_FILE"<<EOF
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152
net.ipv4.tcp_congestion_control = ${TCP_CC}
EOF

sysctl --system >/dev/null 2>&1 || true
echo "[oneclick][20_optimize] Applied tcp_congestion_control=${TCP_CC}"
