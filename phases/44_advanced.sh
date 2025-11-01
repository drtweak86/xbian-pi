
#!/usr/bin/env bash
set -euo pipefail
. /opt/osmc-oneclick/phases/31_helpers.sh

USER="xbian"
KODI_HOME="/home/${USER}/.kodi"
USERDATA="${KODI_HOME}/userdata"
ASSET_AS="/opt/osmc-oneclick/assets/config/advancedsettings.xml"
DEST_AS="${USERDATA}/advancedsettings.xml"

[ -f "$ASSET_AS" ] || { warn "[advanced] Source missing"; exit 0; }
mkdir -p "$USERDATA"

if [ -f "$DEST_AS" ] && cmp -s "$ASSET_AS" "$DEST_AS"; then
  log "[advanced] Up to date"
  exit 0
fi

[ -f "$DEST_AS" ] && cp -a "$DEST_AS" "${DEST_AS}.bak.$(date +%Y%m%d%H%M%S)" || true
install -o "$USER" -g "$USER" -m 0644 "$ASSET_AS" "$DEST_AS"
chown -R "$USER:$USER" "$KODI_HOME" || true
kodi_send -a "Notification(Advanced,advancedsettings.xml installed,6000)" >/dev/null 2>&1 || true
log "[advanced] Installed."
