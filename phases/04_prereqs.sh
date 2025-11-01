
#!/usr/bin/env bash
# XBian prereqs: cron + tools (no systemd usage)
set -euo pipefail
source /opt/osmc-oneclick/phases/31_helpers.sh
export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}

log "[04_prereqs] Installing base packages…"
PKGS=(curl wget git jq zip unzip ca-certificates rng-tools rsync dnsutils net-tools python3 python3-pip ffmpeg nano vim tmux build-essential file lsof strace ncdu htop iotop nload cron)
apt-get update -y || true
apt-get install -y --no-install-recommends "${PKGS[@]}" || true

log "[04_prereqs] Ensuring cron is running at boot"
update-rc.d cron defaults >/dev/null 2>&1 || true
service cron start >/dev/null 2>&1 || true

# Optional: rclone latest (best-effort)
if ! command -v rclone >/dev/null 2>&1; then
  log "[04_prereqs] Installing rclone…"
  bash -c 'curl -fsSL https://rclone.org/install.sh | bash' || true
fi

log "[04_prereqs] Done."
