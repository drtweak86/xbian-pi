#!/bin/sh
# FrankenPi: WireGuard setup + autostart + optional /boot import + optional repo sync
# POSIX sh, works on Debian/RPi OS; no-ops gracefully on pure Buildroot (no apt).

set -eu
. /usr/local/bin/frankenpi-compat.sh   # log, pkg_install, svc_* helpers

# ---------- Options (override via env) ----------
REPO_VPN="${REPO_VPN:-}"                 # e.g. git@github.com:drtweak86/osmc-vpn-configs.git
BRANCH_VPN="${BRANCH_VPN:-main}"
DEST_VPN="${DEST_VPN:-/opt/vpn-configs}"
IMPORT_BOOT="${IMPORT_BOOT:-1}"          # 1 = import from /boot/wireguard/*.conf then remove
BOOT_WG_DIR="${BOOT_WG_DIR:-/boot/wireguard}"
AUTOSTART_FIRST="${AUTOSTART_FIRST:-}"   # e.g. uk-lon (else first .conf)
# ------------------------------------------------

log "[30_vpn] Installing WireGuard tools if available…"
# Debian/RPi OS:
pkg_install wireguard wireguard-tools resolvconf git ca-certificates curl || true
# If resolvconf not present, try openresolv (some distros):
pkg_install openresolv || true

DEST="/etc/wireguard"
mkdir -p "$DEST"
chmod 700 "$DEST"

# ---------- Pull private repo (optional) ----------
if [ -n "$REPO_VPN" ]; then
  log "[30_vpn] Syncing VPN repo → $DEST_VPN ($BRANCH_VPN)"
  mkdir -p "$DEST_VPN"
  if [ -d "$DEST_VPN/.git" ]; then
    ( cd "$DEST_VPN" && git fetch --depth=1 origin "$BRANCH_VPN" && git reset --hard "origin/$BRANCH_VPN" ) || log "[30_vpn] repo update failed"
  else
    git clone --depth=1 -b "$BRANCH_VPN" "$REPO_VPN" "$DEST_VPN" || log "[30_vpn] repo clone failed (SSH key?)"
  fi
fi

# ---------- Collect .conf candidates ----------
found=0

# from repo
if [ -n "$REPO_VPN" ] && ls "$DEST_VPN"/*.conf >/dev/null 2>&1; then
  for f in "$DEST_VPN"/*.conf; do
    cp -f "$f" "$DEST/$(basename "$f")"
    found=1
  done
fi

# from /boot/wireguard
if [ "$IMPORT_BOOT" = "1" ] && ls "$BOOT_WG_DIR"/*.conf >/dev/null 2>&1; then
  log "[30_vpn] Importing configs from $BOOT_WG_DIR"
  for f in "$BOOT_WG_DIR"/*.conf; do
    cp -f "$f" "$DEST/$(basename "$f")"
    found=1
  done
  rm -f "$BOOT_WG_DIR"/*.conf || true
fi

if [ "$found" -ne 1 ] && ! ls "$DEST"/*.conf >/dev/null 2>&1; then
  log "[30_vpn] No WireGuard *.conf found. Place files in $DEST or $BOOT_WG_DIR and re-run."
  exit 0
fi

chmod 600 "$DEST"/*.conf 2>/dev/null || true
chown root:root "$DEST"/*.conf 2>/dev/null || true
log "[30_vpn] Installed configs:"
ls -1 "$DEST"/*.conf 2>/dev/null || true

# ---------- Pick autostart tunnel ----------
if [ -n "$AUTOSTART_FIRST" ]; then
  FIRST_WG="$AUTOSTART_FIRST"
else
  FIRST_WG=""
  for c in "$DEST"/*.conf; do
    FIRST_WG="$(basename "$c" .conf)"
    break
  done
fi

if [ -z "${FIRST_WG:-}" ]; then
  log "[30_vpn] No tunnel name resolved for autostart — done."
  exit 0
fi
log "[30_vpn] Autostart target: $FIRST_WG"

# ---------- Autostart ----------
if command -v systemctl >/dev/null 2>&1; then
  if systemctl enable --now "wg-quick@$FIRST_WG" >/dev/null 2>&1; then
    log "[30_vpn] Enabled and started wg-quick@$FIRST_WG (systemd)"
  else
    log "[30_vpn] systemd start failed, trying manual up"
    wg-quick up "$FIRST_WG" || log "[30_vpn] wg-quick up failed (check config/DNS)"
  fi
else
  # Fallback for non-systemd
  RC=/etc/rc.local
  if [ ! -f "$RC" ]; then
    cat >"$RC"<<'RCEOF'
#!/bin/sh -e
# rc.local — user commands run at end of multi-user boot
exit 0
RCEOF
    chmod +x "$RC"
  fi
  if ! grep -q "wg-quick up $FIRST_WG" "$RC"; then
    sed -i "\#^exit 0#i /usr/bin/wg-quick up $FIRST_WG || true" "$RC"
  fi
  wg-quick up "$FIRST_WG" || log "[30_vpn] wg-quick up failed (non-systemd)"
fi

# ---------- DNS heads-up ----------
if command -v resolvconf >/dev/null 2>&1; then
  log "[30_vpn] resolvconf present — WG 'DNS=' entries will apply automatically."
elif command -v resolvconf >/dev/null 2>&1 || command -v resolvectl >/dev/null 2>&1; then
  log "[30_vpn] openresolv/systemd-resolved present — DNS may be managed externally."
else
  log "[30_vpn] No resolvconf — ensure DNS handled inside the tunnel or via NM."
fi

# ---------- Quick health checks (best-effort) ----------
( wg show "$FIRST_WG" 2>/dev/null || true )
( ip route get 1.1.1.1 2>/dev/null || true )
( ping -c 2 -w 4 1.1.1.1 >/dev/null 2>&1 && log "[30_vpn] ping ok" || log "[30_vpn] ping failed" )
( command -v curl >/dev/null 2>&1 && curl -4 --interface "$FIRST_WG" --max-time 6 http://1.1.1.1 >/dev/null 2>&1 && log "[30_vpn] curl via WG ok" || true )

log "[30_vpn] Done. Autostart: $FIRST_WG"
