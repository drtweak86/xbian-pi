
#!/usr/bin/env bash
# Install cron rules from repo cron/ directory
set -euo pipefail
SRC="/opt/osmc-oneclick/cron/osmc-oneclick"
if [ -f "$SRC" ]; then
  install -m 0644 "$SRC" /etc/cron.d/osmc-oneclick
  service cron restart >/dev/null 2>&1 || true
  echo "[32_enable_cron] Installed /etc/cron.d/osmc-oneclick"
else
  echo "[32_enable_cron] Missing cron file at $SRC"
fi
