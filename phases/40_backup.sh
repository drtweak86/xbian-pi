#!/bin/sh
# FrankenPi: weekly snapshot -> cloud via rclone (with verify + local cleanup)
set -eu

. /usr/local/bin/frankenpi-compat.sh   # log, svc_*

BIN="/usr/local/sbin/frankenpi-backup"
CFG="/etc/default/frankenpi-backup"
LOGDIR="/var/log/frankenpi"
SVC="/etc/systemd/system/frankenpi-backup.service"
TMR="/etc/systemd/system/frankenpi-backup.timer"

mkdir -p /etc/default "$LOGDIR"

# Seed editable config on first install
if [ ! -f "$CFG" ]; then
  cat >"$CFG" <<'CFG'
# rclone remote (create with: rclone config)
REMOTE_NAME="cloud"
REMOTE_PATH="frankenpi-backups"

# Archive name prefix
ZIP_LABEL="frankenpi_backup"

# What to include (space-separated paths). Edit as you wish.
INCLUDE_LIST="/root/.kodi /etc/wireguard /usr/local/bin/frankenpi-phases /etc/systemd/system/frankenpi-*.service /etc/systemd/system/frankenpi-*.timer"
CFG
fi

# Backup worker
cat >"$BIN" <<'SH'
#!/bin/sh
set -eu
CFG="/etc/default/frankenpi-backup"
[ -r "$CFG" ] && . "$CFG"

LOGDIR="/var/log/frankenpi"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/backup.log"

ts() { date '+%F %T'; }

# Choose a sane HOME/.kodi if running as root vs user
if [ "$(id -u)" = "0" ]; then
  : "${ZIP_LABEL:=frankenpi_backup}"
  : "${REMOTE_NAME:=cloud}"
  : "${REMOTE_PATH:=frankenpi-backups}"
  : "${INCLUDE_LIST:=/root/.kodi /etc/wireguard}"
else
  UHOME="$(getent passwd "$(id -un)" | awk -F: '{print $6}')"
  [ -n "${UHOME:-}" ] || UHOME="$HOME"
  INCLUDE_LIST="${INCLUDE_LIST:-$UHOME/.kodi /etc/wireguard}"
fi

BACKUP_ROOT="${BACKUP_ROOT:-/var/cache/frankenpi/backups}"
mkdir -p "$BACKUP_ROOT"
DATE="$(date +%F_%H-%M-%S)"
ZIP_PATH="${BACKUP_ROOT}/${ZIP_LABEL}_${DATE}.zip"
REMOTE="${REMOTE_NAME}:${REMOTE_PATH}"

{
  echo "[backup] ===== $(ts) ====="

  # rclone presence (best-effort install if curl available)
  if ! command -v rclone >/dev/null 2>&1; then
    echo "[backup] rclone missing → attempting install"
    if command -v curl >/dev/null 2>&1; then
      sh -c 'curl -fsSL https://rclone.org/install.sh | sh' || echo "[backup] rclone install failed (continue if preinstalled some other way)"
    else
      echo "[backup] curl not found; cannot auto-install rclone"
    fi
  fi

  # Require rclone to proceed
  if ! command -v rclone >/dev/null 2>&1; then
    echo "[backup] rclone unavailable — abort"
    exit 1
  fi

  # Ensure remote exists (non-interactive fail with hint)
  if ! rclone listremotes | grep -qx "${REMOTE_NAME}:" ; then
    echo "[backup] rclone remote '${REMOTE_NAME}' not found."
    echo "[backup] Create it with: rclone config    (then rerun)"
    exit 1
  fi

  rclone mkdir "$REMOTE" || true

  # Build include list safely (skip missing)
  TO_ZIP=""
  for p in $INCLUDE_LIST; do
    if [ -e "$p" ]; then
      TO_ZIP="$TO_ZIP \"$p\""
    else
      echo "[backup] skip missing: $p"
    fi
  done
  if [ -z "$TO_ZIP" ]; then
    echo "[backup] nothing to back up"
    exit 1
  fi

  # Ensure zip exists (prereqs usually install it)
  if ! command -v zip >/dev/null 2>&1; then
    echo "[backup] 'zip' not found; install zip or adjust script to tar.gz"
    exit 1
  fi

  echo "[backup] zipping → $ZIP_PATH"
  # shellcheck disable=SC2086
  eval zip -qr "\"$ZIP_PATH\"" $TO_ZIP

  LOCAL_SIZE=$(stat -c '%s' "$ZIP_PATH" 2>/dev/null || echo 0)
  if [ "$LOCAL_SIZE" -le 1024 ]; then
    echo "[backup] zip too small ($LOCAL_SIZE bytes) → abort"
    rm -f "$ZIP_PATH" || true
    exit 1
  fi
  echo "[backup] zip ok ($((LOCAL_SIZE/1024)) KiB)"

  echo "[backup] uploading to $REMOTE"
  if ! rclone copyto "$ZIP_PATH" "${REMOTE}/$(basename "$ZIP_PATH")"; then
    echo "[backup] upload FAILED"
    exit 1
  fi

  REMOTE_SIZE=$(rclone lsjson --files-only "${REMOTE}/$(basename "$ZIP_PATH")" | sed -n 's/.*"Size":\s*\([0-9]\+\).*/\1/p')
  if [ -z "${REMOTE_SIZE:-}" ] || [ "$REMOTE_SIZE" -ne "$LOCAL_SIZE" ]; then
    echo "[backup] verify FAILED (local=$LOCAL_SIZE remote=${REMOTE_SIZE:-0})"
    exit 1
  fi
  echo "[backup] verify ok"

  rm -f "$ZIP_PATH" || true
  echo "[backup] cleaned local archive"
  echo "[backup] DONE"
} >>"$LOGFILE" 2>&1
SH
chmod 0755 "$BIN"

# systemd oneshot service + weekly timer (Sun 04:30)
cat >"$SVC"<<'UNIT'
[Unit]
Description=FrankenPi Backup (rclone snapshot)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/frankenpi-backup
Nice=10
IOSchedulingClass=best-effort
UNIT

cat >"$TMR"<<'UNIT'
[Unit]
Description=Weekly FrankenPi backup

[Timer]
OnCalendar=Sun *-*-* 04:30:00
Persistent=true
AccuracySec=1m

[Install]
WantedBy=timers.target
UNIT

svc_enable frankenpi-backup.timer || true
svc_start  frankenpi-backup.timer || true

log "[40_backup] Installed backup tool and enabled weekly timer."
