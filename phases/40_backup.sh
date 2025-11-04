#!/usr/bin/env bash
# XBian weekly snapshot → cloud (rclone), with verify & local cleanup
# Works without systemd; safe for cron. First run may ask you to set up rclone.

set -euo pipefail

# -------- settings you can tweak --------
REMOTE_NAME="${REMOTE_NAME:-cloud}"                 # rclone remote name
REMOTE_PATH="${REMOTE_PATH:-xbian-backups}"         # folder on the remote
BACKUP_ROOT="${BACKUP_ROOT:-/home/xbian/backups}"   # temp local staging
LOG_DIR="${LOG_DIR:-/var/log/xbian-pi}"             # logs live here
ZIP_LABEL="${ZIP_LABEL:-xbian_backup}"              # filename prefix
# Items to include in the snapshot:
INCLUDE_LIST=(/home/xbian/.kodi /etc/wireguard /opt/xbian-pi)
# ----------------------------------------

mkdir -p "$BACKUP_ROOT" "$LOG_DIR"
LOG_FILE="${LOG_DIR}/backup.log"
DATE="$(date +%F_%H-%M-%S)"
ZIP_PATH="${BACKUP_ROOT}/${ZIP_LABEL}_${DATE}.zip"
REMOTE="${REMOTE_NAME}:${REMOTE_PATH}"
exec >>"$LOG_FILE" 2>&1
echo "[backup] ===== $(date) ====="

# 0) Ensure rclone exists
if ! command -v rclone >/dev/null 2>&1; then
  echo "[backup] rclone missing → installing…"
  if ! curl -fsSL https://rclone.org/install.sh | sudo bash; then
    echo "[backup] rclone install FAILED"; exit 1
  fi
fi

# 1) Ensure rclone remote exists (interactive on TTY only)
if ! rclone listremotes | grep -qx "${REMOTE_NAME}:" ; then
  echo "[backup] rclone remote '${REMOTE_NAME}' not found."
  if [ -t 1 ]; then
    echo "[backup] Opening 'rclone config' to create it now…"
    rclone config   # user completes setup, returns 0 on success
  else
    echo "[backup] Non-interactive run. Please create the remote first:"
    echo "        rclone config   (make a remote called: ${REMOTE_NAME})"
    exit 1
  fi
fi

# 2) Make sure target folder exists on remote
rclone mkdir "$REMOTE" || true

# 3) Build the zip
echo "[backup] zipping → $ZIP_PATH"
command -v zip >/dev/null 2>&1 || { echo "[backup] 'zip' missing; installing…"; sudo apt-get update -y || true; sudo apt-get install -y zip || { echo "[backup] zip install FAILED"; exit 1; }; }

# double-check include paths that exist to avoid zip errors
TO_ZIP=()
for p in "${INCLUDE_LIST[@]}"; do
  if [ -e "$p" ]; then TO_ZIP+=("$p"); else echo "[backup] skip missing: $p"; fi
done
if [ "${#TO_ZIP[@]}" -eq 0 ]; then
  echo "[backup] nothing to back up (all sources missing)"; exit 1
fi

zip -qr "$ZIP_PATH" "${TO_ZIP[@]}"
LOCAL_SIZE=$(stat -c '%s' "$ZIP_PATH" 2>/dev/null || echo 0)
if [ "$LOCAL_SIZE" -le 1024 ]; then
  echo "[backup] zip looks too small ($LOCAL_SIZE bytes) → abort"; exit 1
fi
echo "[backup] zip ok ($((LOCAL_SIZE/1024)) KiB)"

# 4) Upload
echo "[backup] uploading to $REMOTE"
if ! rclone copyto "$ZIP_PATH" "${REMOTE}/$(basename "$ZIP_PATH")"; then
  echo "[backup] upload FAILED"; exit 1
fi

# 5) Verify (size match)
REMOTE_SIZE=$(rclone lsjson --files-only "${REMOTE}/$(basename "$ZIP_PATH")" | sed -n 's/.*"Size":\s*\([0-9]\+\).*/\1/p')
if [ -z "${REMOTE_SIZE:-}" ]; then
  echo "[backup] verify FAILED (remote not found)"; exit 1
fi
if [ "$REMOTE_SIZE" -ne "$LOCAL_SIZE" ]; then
  echo "[backup] verify FAILED (size mismatch: local=$LOCAL_SIZE remote=$REMOTE_SIZE)"; exit 1
fi
echo "[backup] verify ok"

# 6) Cleanup local copy
rm -f "$ZIP_PATH" || true
echo "[backup] cleaned local archive"

echo "[backup] DONE"
