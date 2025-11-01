
#!/usr/bin/env bash
set -euo pipefail

# Must be run as xbian (with sudo available)
if [ "$(id -u)" -ne 1000 ] && [ "$(id -un)" != "xbian" ]; then
  echo "[install] Please run this as user 'xbian' (default XBian user)."
fi

SRC="$(cd "$(dirname "$0")" && pwd)"
DST="/opt/osmc-oneclick"

echo "[install] Copying assets + phases to $DST"
sudo mkdir -p "$DST"
sudo rsync -a "$SRC/phases" "$SRC/assets" "$DST/" 2>/dev/null || sudo cp -r "$SRC/phases" "$SRC/assets" "$DST/"

echo "[install] Installing cron rules"
if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1; then
  echo "[install] Installing cron daemon"
  sudo apt-get update -y || true
  sudo apt-get install -y --no-install-recommends cron || true
fi
sudo install -m 0644 "$SRC/cron/osmc-oneclick" /etc/cron.d/osmc-oneclick || {
  echo "[install] Warning: /etc/cron.d unavailable — falling back to user crontab"
  crontab -l 2>/dev/null | grep -v '# oneclick' | { cat; cat "$SRC/cron/user-crontab.snippet"; } | crontab -
}

echo "[install] Enabling cron at boot (SysV)"
sudo update-rc.d cron defaults >/dev/null 2>&1 || true
sudo service cron start >/dev/null 2>&1 || true

echo "[install] Staging first-boot runner"
sudo tee /boot/firstboot.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
LOG=/home/xbian/firstboot.log
exec >>"$LOG" 2>&1
echo "=== oneclick firstboot $(date) ==="
PHASES="/opt/osmc-oneclick/phases"
if [ -d "$PHASES" ]; then
  for s in "$PHASES"/*.sh; do
    [ -x "$s" ] || chmod +x "$s" || true
    echo "Running $(basename "$s")"
    bash "$s" || echo "WARN: $s failed ($?)"
  done
else
  echo "no phases dir found"
fi
echo "firstboot done"
SH
sudo chmod +x /boot/firstboot.sh
sudo chown root:root /boot/firstboot.sh

echo "[install] Creating XBian boot.d hook"
sudo mkdir -p /etc/boot.d
sudo tee /etc/boot.d/99-oneclick >/dev/null <<'SH'
#!/bin/sh
# Run OneClick firstboot once at startup, then mark done
if [ -x /boot/firstboot.sh ] && [ ! -f /boot/firstboot.done ]; then
  /boot/firstboot.sh || true
  touch /boot/firstboot.done
fi
SH
sudo chmod +x /etc/boot.d/99-oneclick

echo "[install] Done. You can reboot now: sudo reboot"
