#!/bin/sh
# FrankenPi prereqs: base tools + cron
# Works on Buildroot (no apt) and Debian/Xbian (apt present)

set -eu
. /usr/local/bin/frankenpi-compat.sh   # provides log/pkg_install/svc_* helpers

log "[04_prereqs] Installing base packages if available…"
# On Buildroot this will just log a hint; on Debian it will install.
pkg_install curl wget git jq zip unzip ca-certificates rng-tools rsync dnsutils \
            net-tools python3 python3-pip ffmpeg nano vim tmux build-essential \
            file lsof strace ncdu htop iotop nload cron || true

# Ensure cron is enabled/started (support several service names)
log "[04_prereqs] Ensuring cron service is enabled…"
for svc in cronie.service cron.service busybox-crond.service crond.service; do
  if systemctl list-unit-files | grep -q "^$svc"; then
    svc_enable "$svc" || true
    svc_start  "$svc" || true
    log "[04_prereqs] Started $svc"
    break
  fi
done

# Optional: rclone (best-effort) if curl is present and not already installed
if ! command -v rclone >/dev/null 2>&1; then
  if command -v curl >/dev/null 2>&1; then
    log "[04_prereqs] Installing rclone (best-effort)…"
    sh -c 'curl -fsSL https://rclone.org/install.sh | sh' || log "[04_prereqs] rclone install skipped/failed"
  else
    log "[04_prereqs] curl not available; skipping rclone install"
  fi
fi

log "[04_prereqs] Done."
