
#!/usr/bin/env bash
# Copy boot video into Kodi media and create autoexec to play it once
set -euo pipefail
source /opt/osmc-oneclick/phases/31_helpers.sh

SRC="/opt/osmc-oneclick/assets/boot/matrix_boot.mp4"
DST="/home/xbian/.kodi/media/matrix_boot.mp4"
AE="/home/xbian/.kodi/userdata/autoexec.py"

[ -f "$SRC" ] || { log "[bootvideo] No matrix_boot.mp4 bundled — skipping."; exit 0; }

install -d -m 0755 "$(dirname "$DST")" "$(dirname "$AE")"
cp -f "$SRC" "$DST"
chown -R xbian:xbian /home/xbian/.kodi

cat >"$AE"<<'PY'
import xbmc, os, time
VIDEO = xbmc.translatePath('special://home/media/matrix_boot.mp4')
if os.path.exists(VIDEO):
    p = xbmc.Player(); p.play(VIDEO)
    for _ in range(100):
        if p.isPlaying(): break
        time.sleep(0.1)
    time.sleep(7)
PY
chown xbian:xbian "$AE"
chmod 0644 "$AE"
log "[bootvideo] Staged to play on next Kodi start."
