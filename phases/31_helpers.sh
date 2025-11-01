
#!/usr/bin/env bash
# Common helpers for XBian
set -euo pipefail

LOG_TAG="${LOG_TAG:-oneclick}"
KODI_USER="${KODI_USER:-xbian}"
KODI_HOME="${KODI_HOME:-/home/${KODI_USER}/.kodi}"
ADDONS_DIR="${ADDONS_DIR:-${KODI_HOME}/addons}"
PKG_DIR="${PKG_DIR:-${ADDONS_DIR}/packages}"

log()  { printf '[%s] %s\n' "$LOG_TAG" "$*"; }
warn() { printf '[%s][WARN] %s\n' "$LOG_TAG" "$*" >&2; }

# ---- Kodi helpers ----
kodi_running() {
  pgrep -f "kodi.bin" >/dev/null 2>&1 || pgrep -f "xbmc.bin" >/dev/null 2>&1
}
kodi_start() {
  service xbmc start >/dev/null 2>&1 || true
}
kodi_restart() {
  service xbmc restart >/dev/null 2>&1 || true
}
kodi_send() {
  if command -v kodi-send >/dev/null 2>&1; then
    kodi-send "$@"
  else
    return 1
  fi
}

# ---- Zip / Repo installers ----
fetch_latest_zip() {
  local page_url="$1" pattern="$2"
  local ua="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126 Safari/537.36"
  local page zip_url
  page="$(curl -fsSL -A "$ua" "$page_url")" || return 1
  zip_url="$(printf '%s' "$page" | grep -Eo 'https?://[^"]+\.zip' | grep -Ei "$pattern" | head -n1 || true)"
  [ -n "$zip_url" ] || return 1
  echo "$zip_url"
}

kodi_install_zip() {
  local zip="$1"
  [ -f "$zip" ] || { warn "zip not found: $zip"; return 1; }
  mkdir -p "$PKG_DIR"
  cp -f "$zip" "$PKG_DIR/" || true
  local tmp; tmp="$(mktemp -d)"
  unzip -o "$zip" -d "$tmp" >/dev/null
  shopt -s nullglob
  for d in "$tmp"/*; do
    [ -d "$d" ] || continue
    local addon_id; addon_id="$(basename "$d")"
    rm -rf "$ADDONS_DIR/$addon_id"
    mv "$d" "$ADDONS_DIR/$addon_id"
    chown -R "${KODI_USER}:${KODI_USER}" "$ADDONS_DIR/$addon_id"
    log "Installed addon: $addon_id"
  done
  rm -rf "$tmp"
}

install_repo_from_url() {
  local url="$1"
  local tmpzip; tmpzip="$(mktemp --suffix=.zip)"
  curl -fsSL -o "$tmpzip" "$url" || { warn "repo download failed: $url"; return 1; }
  kodi_install_zip "$tmpzip"
  rm -f "$tmpzip"
}

install_zip_from_url() {
  local url="$1"
  local tmpzip; tmpzip="$(mktemp --suffix=.zip)"
  curl -fsSL -o "$tmpzip" "$url" || { warn "zip download failed: $url"; return 1; }
  kodi_install_zip "$tmpzip"
  rm -f "$tmpzip"
}

install_addon() {
  local addon_id="$1"
  mkdir -p "$ADDONS_DIR" "$PKG_DIR"
  # Ask Kodi to install via JSON-RPC
  kodi_running || kodi_start
  sleep 5
  if command -v kodi-send >/dev/null 2>&1; then
    sudo -u "$KODI_USER" kodi-send -a "InstallAddon(${addon_id})" || true
    sudo -u "$KODI_USER" kodi-send -a "EnableAddon(${addon_id})" || true
  fi
}
