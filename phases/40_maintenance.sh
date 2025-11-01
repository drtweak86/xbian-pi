
#!/usr/bin/env bash
set -euo pipefail

install -d -m 0755 /opt/osmc-oneclick/scripts

cat >/opt/osmc-oneclick/scripts/run-weekly-maint.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
log(){ echo "[weekly-maint] $*"; }
export DEBIAN_FRONTEND=noninteractive
log "APT update/upgrade"
apt-get update -y || true
apt-get -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" dist-upgrade -y || true
apt-get autoremove -y || true
apt-get clean -y || true
log "Kodi cleanup"
find /home/xbian/.kodi/temp -type f -mtime +7 -delete 2>/dev/null || true
find /home/xbian/.kodi/userdata/Thumbnails -type f -mtime +30 -delete 2>/dev/null || true
log "Done."
SH
chmod +x /opt/osmc-oneclick/scripts/run-weekly-maint.sh
