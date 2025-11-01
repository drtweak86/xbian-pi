
#!/usr/bin/env bash
set -euo pipefail
LOG_DIR="/var/log/osmc-oneclick"; LOG="${LOG_DIR}/backup.log"
BACKUP_DIR="/opt/osmc-oneclick/backups"; DATE="$(date +%F_%H-%M-%S)"
TARGET="${BACKUP_DIR}/xbian_backup_${DATE}.zip"
RCLONE_REMOTE="${RCLONE_REMOTE:-gdrive:osmc-backups}"

mkdir -p "$LOG_DIR" "$BACKUP_DIR"
echo "[backup] ===== $(date) =====" >> "$LOG"

command -v zip >/dev/null 2>&1 || { echo "[backup] zip missing" >> "$LOG"; exit 1; }
command -v rclone >/dev/null 2>&1 || { echo "[backup] rclone missing" >> "$LOG"; exit 1; }

zip -qr "$TARGET" \
  /home/xbian/.kodi \
  /etc/wireguard \
  /opt/osmc-oneclick || { echo "[backup] zip failed" >> "$LOG"; exit 1; }

if rclone copy "$TARGET" "$RCLONE_REMOTE" >> "$LOG" 2>&1; then echo "[backup] upload ok: $(basename "$TARGET")" >> "$LOG"; else echo "[backup] upload FAILED" >> "$LOG"; exit 1; fi
rclone lsf --files-only --format "p" "$RCLONE_REMOTE" | grep -qx "$(basename "$TARGET")" || { echo "[backup] verify FAILED" >> "$LOG"; exit 1; }
rm -f "$TARGET"
echo "[backup] done" >> "$LOG"
