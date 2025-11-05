#!/usr/bin/env bash
# 30_vpn.sh — XBian-safe WireGuard setup + autostart + /boot import
# FrankeXBian edition 🧪⚡

set -euo pipefail

log(){ echo -e "[oneclick][30_vpn] $*"; }
warn(){ echo -e "[oneclick][WARN]  $*" >&2; }
has(){ command -v "$1" >/dev/null 2>&1; }
need_root(){ [ "$(id -u)" = 0 ] || { warn "Run as root"; exit 1; } }

need_root
export DEBIAN_FRONTEND=${DEBIAN_FRONTEND:-noninteractive}

# ---------- Options (override via env) ----------
REPO_VPN="${REPO_VPN:-}"                # e.g. git@github.com:drtweak86/osmc-vpn-configs.git
BRANCH_VPN="${BRANCH_VPN:-main}"
DEST_VPN="${DEST_VPN:-/opt/osmc-vpn-configs}"
IMPORT_BOOT="${IMPORT_BOOT:-1}"          # 1 = also import from /boot/wireguard/*.conf then remove
BOOT_WG_DIR="${BOOT_WG_DIR:-/boot/wireguard}"
AUTOSTART_FIRST="${AUTOSTART_FIRST:-}"   # e.g. uk-lon (else pick the first .conf)
APT_CLEAN="${APT_CLEAN:-1}"              # 1 = apt-get clean afterwards
# ------------------------------------------------

log "Installing WireGuard + DNS helper (resolvconf → openresolv fallback)…"
apt-get update -y || true
if ! apt-get install -y --no-install-recommends wireguard resolvconf git; then
  warn "resolvconf not available — falling back to openresolv"
  apt-get install -y --no-install-recommends wireguard openresolv git || true
fi
# keep footprint small
apt-get install -y --no-install-recommends ca-certificates curl || true

# ---------- Pull private repo (optional) ----------
if [ -n "$REPO_VPN" ]; then
  mkdir -p "$DEST_VPN"
  chown -R xbian:xbian "$(dirname "$DEST_VPN")" || true
  if [ -d "$DEST_VPN/.git" ]; then
    log "Updating VPN repo in $DEST_VPN ($BRANCH_VPN)"
    sudo -u xbian -H git -C "$DEST_VPN" fetch --depth=1 origin "$BRANCH_VPN" || warn "git fetch failed"
    sudo -u xbian -H git -C "$DEST_VPN" reset --hard "origin/$BRANCH_VPN"      || warn "git reset failed"
  else
    log "Cloning VPN repo → $DEST_VPN"
    sudo -u xbian -H git clone --depth=1 -b "$BRANCH_VPN" "$REPO_VPN" "$DEST_VPN" || warn "git clone failed (SSH key & access?)"
  fi
fi

# ---------- Stage configs into /etc/wireguard ----------
DEST="/etc/wireguard"
mkdir -p "$DEST"
chmod 700 "$DEST"

# Collect .conf candidates
shopt -s nullglob
declare -a confs=()

# from repo
if [ -n "$REPO_VPN" ] && compgen -G "$DEST_VPN/*.conf" >/dev/null; then
  for f in "$DEST_VPN"/*.conf; do confs+=("$f"); done
fi

# from /boot/wireguard (to keep /boot lean, we will move then delete)
if [ "${IMPORT_BOOT}" = "1" ] && compgen -G "$BOOT_WG_DIR/*.conf" >/dev/null; then
  log "Found configs on ${BOOT_WG_DIR} — importing & cleaning up"
  for f in "$BOOT_WG_DIR"/*.conf; do confs+=("$f"); done
fi

if [ ${#confs[@]} -eq 0 ]; then
  warn "No .conf files found (repo or ${BOOT_WG_DIR}). Place *.conf into ${DEST} or ${BOOT_WG_DIR} and re-run."
  exit 0
fi

log "Installing WireGuard configs → ${DEST}"
for f in "${confs[@]}"; do
  base="$(basename "$f")"
  cp -f "$f" "${DEST}/${base}"
done

# If imported from /boot, nuke originals to keep /boot tiny
if [ "${IMPORT_BOOT}" = "1" ] && compgen -G "$BOOT_WG_DIR/*.conf" >/dev/null; then
  rm -f "$BOOT_WG_DIR"/*.conf || true
fi

chmod 600 "${DEST}"/*.conf
chown root:root "${DEST}"/*.conf
log "Installed configs:"
ls -1 "${DEST}"/*.conf || true

# ---------- Pick autostart tunnel ----------
if [ -n "${AUTOSTART_FIRST}" ]; then
  FIRST_WG="${AUTOSTART_FIRST}"
else
  FIRST_WG="$(basename "$(ls "${DEST}"/*.conf | head -n1)" .conf)"
fi

if [ -z "${FIRST_WG:-}" ]; then
  warn "No WG name resolved for autostart"
  exit 0
fi
log "Autostart target: ${FIRST_WG}"

# ---------- Autostart: systemd if present, else rc.local ----------
if has systemctl; then
  if systemctl enable --now "wg-quick@${FIRST_WG}"; then
    log "wg-quick@${FIRST_WG} enabled and started (systemd)"
  else
    warn "wg-quick@${FIRST_WG} failed via systemd — trying manual up"
    wg-quick up "${FIRST_WG}" || warn "wg-quick up ${FIRST_WG} failed"
  fi
else
  RC=/etc/rc.local
  if [ ! -f "$RC" ]; then
    cat >"$RC"<<'RCEOF'
#!/bin/sh -e
# rc.local — user commands run at end of multi-user boot
exit 0
RCEOF
    chmod +x "$RC"
  fi
  if ! grep -q "wg-quick up ${FIRST_WG}" "$RC"; then
    log "Adding wg-quick up ${FIRST_WG} to $RC"
    # insert before exit 0
    sed -i "\#^exit 0#i /usr/bin/wg-quick up ${FIRST_WG} || true" "$RC"
  fi
  # bring it up now too
  if wg-quick up "${FIRST_WG}"; then
    log "wg-quick up ${FIRST_WG} started (non-systemd)"
  else
    warn "wg-quick up ${FIRST_WG} failed — check config/DNS"
  fi
fi

# ---------- DNS heads-up ----------
if has resolvconf; then
  log "resolvconf present — wg-quick will register tunnel DNS automatically if 'DNS=' is set in the .conf"
else
  warn "resolvconf missing — using openresolv (tunnel DNS may not be auto-applied unless configured)"
fi

# ---------- Quick health checks ----------
log "Health check: handshake / route / ping / curl"
( set +e
  wg show "${FIRST_WG}" || true
  ip route get 1.1.1.1 oif "${FIRST_WG}" || true
  ping -I "${FIRST_WG}" -c 3 -w 5 1.1.1.1 || true
  curl -4 --interface "${FIRST_WG}" --max-time 6 http://1.1.1.1 || true
)

# ---------- Keep rootfs lean ----------
if [ "${APT_CLEAN}" = "1" ]; then
  apt-get clean || true
fi

log "VPN phase complete. Tunnels in ${DEST}. Autostart: ${FIRST_WG}"
