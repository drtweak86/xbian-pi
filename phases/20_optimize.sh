#!/bin/sh
# FrankenPi: system/network optimizations (safe on Debian/Xbian; no-op on pure Buildroot)
set -eu

. /usr/local/bin/frankenpi-compat.sh   # log, pkg_install, svc_*

log "[20_optimize] Installing unbound (DNS cache) + rng-tools if available…"
pkg_install unbound rng-tools || true

# Try BBR; fallback to cubic
TCP_CC="bbr"
modprobe tcp_bbr 2>/dev/null || TCP_CC="cubic"

SYSCTL_DROP="/etc/sysctl.d/99-frankenpi.conf"
if [ -d /etc/sysctl.d ]; then
  cat >"$SYSCTL_DROP" <<EOF
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152
net.ipv4.tcp_congestion_control = ${TCP_CC}
EOF
  sysctl --system >/dev/null 2>&1 || true
else
  # Fallback: append to sysctl.conf if sysctl.d doesn’t exist
  sed -i '/^net\.ip/d' /etc/sysctl.conf 2>/dev/null || true
  cat >>/etc/sysctl.conf <<EOF
net.core.rmem_max = 2500000
net.core.wmem_max = 2500000
net.ipv4.tcp_rmem = 4096 87380 2097152
net.ipv4.tcp_wmem = 4096 65536 2097152
net.ipv4.tcp_congestion_control = ${TCP_CC}
EOF
  sysctl -p >/dev/null 2>&1 || true
fi
log "[20_optimize] tcp_congestion_control=${TCP_CC}"

# Start services if they exist
for svc in unbound.service rng-tools.service rngd.service; do
  if systemctl list-unit-files | grep -q "^$svc"; then
    svc_enable "$svc" || true
    svc_start  "$svc" || true
    log "[20_optimize] enabled $svc"
  fi
done

log "[20_optimize] Done."
