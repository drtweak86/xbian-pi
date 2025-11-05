#!/usr/bin/env bash
# Ultra-redundant local-first add-on installer for XBian
# Prefers SD-card / Repositories; falls back to other locals, then web.
set -euo pipefail

# ---- PATHS (local-first) ----
# Your SD card “Repositories” folder. Change if you mount elsewhere.
DEFAULT_SD="/opt/Repositories"
FALLBACKS=(
  "${CACHE_DIR:-}"               # allow env override
  "$DEFAULT_SD"
  "/home/xbian/Repositories"
  "/mnt/xbroot/data/Repositories"
  "/media/phone/Repositories"
)
pick_cache_dir() {
  for d in "${FALLBACKS[@]}"; do
    [[ -n "$d" && -d "$d" ]] && { echo "$d"; return; }
  done
  # last resort: create default
  mkdir -p "$DEFAULT_SD"
  echo "$DEFAULT_SD"
}
CACHE_DIR="$(pick_cache_dir)"
KODI_HOME="${KODI_HOME:-/home/xbian/.kodi}"
KODI_RPC="${KODI_RPC:-http://127.0.0.1:8080/jsonrpc}"
SETTLE_SECS="${SETTLE_SECS:-6}"
AUTO_RESTART="${AUTO_RESTART:-1}"
FONTS_SRC="${FONTS_SRC:-/opt/kodi-fonts}"

log(){ printf "[addons] %s\n" "$*"; }
warn(){ printf "[addons][WARN] %s\n" "$*" >&2; }

http_head(){ curl -fsSIL --max-time 10 --retry 2 -o /dev/null -w "%{http_code}" "$1" 2>/dev/null || echo "ERR"; }
download_to(){ curl -fL --max-time 90 --retry 2 -o "$2" "$1"; }
wait_settle(){ sleep "$SETTLE_SECS"; }

jsonrpc(){ curl -s -H "Content-Type: application/json" -X POST "$KODI_RPC" -d "$1" 2>/dev/null || true; }

wait_for_jsonrpc() {
  local timeout="${1:-60}" i=0
  while (( i<timeout )); do
    if curl -s "$KODI_RPC" >/dev/null 2>&1; then return 0; fi
    sleep 2; i=$((i+2))
  done
  return 1
}

# enable GUI before installs (if possible)
gui_ready(){
  jsonrpc '{"jsonrpc":"2.0","id":1,"method":"GUI.GetProperties","params":{"properties":["currentwindow"]}}' \
  | grep -q '"id":1'
}

is_addon_enabled(){
  local id="$1"
  jsonrpc '{"jsonrpc":"2.0","id":1,"method":"Addons.GetAddonDetails","params":{"addonid":"'"$id"'","properties":["enabled"]}}' \
    | grep -q '"enabled":true'
}
wait_for_addon_enabled(){
  local id="$1" timeout="${2:-120}" i=0
  while (( i<timeout )); do
    is_addon_enabled "$id" && return 0
    sleep 2; i=$((i+2))
  done
  return 1
}

install_zip_via_files(){
  local zip="$1"
  mkdir -p "$KODI_HOME/addons/packages"
  cp -f "$zip" "$KODI_HOME/addons/packages/"
  jsonrpc '{"jsonrpc":"2.0","id":1,"method":"Addons.Install","params":{"addonid":null,"addonpath":"'"$zip"'"}}' >/dev/null || true
}

install_repo_zip(){ log "Installing repo zip: $1"; install_zip_via_files "$1"; wait_settle; }
install_addon_id(){
  local addon="$1"
  jsonrpc '{"jsonrpc":"2.0","id":1,"method":"Addons.Install","params":{"addonid":"'"$addon"'"}}' >/dev/null || true
  wait_settle
}

# Find a zip locally first by regex pattern; fallback to web page scrape
find_local_zip(){
  local pattern="$1"
  compgen -G "${CACHE_DIR%/}/*.zip" > /dev/null || return 1
  ls -1 "${CACHE_DIR%/}"/*.zip 2>/dev/null | grep -E "$pattern" | head -n1 || true
}

page_latest_zip(){ curl -fsSL --max-time 15 "$1" 2>/dev/null \
  | grep -Eo 'href="[^"]+\.zip"' | sed -E 's/^href="([^"]+)".*/\1/' | grep -E "$2" | head -n1 || true; }

resolve_repo_zip(){
  local name="$1" page="$2" pattern="$3"
  # 1) local
  local local_zip; local_zip="$(find_local_zip "$pattern" || true)"
  [[ -n "$local_zip" ]] && { echo "$local_zip"; return 0; }
  # 2) web
  local href abs code
  href="$(page_latest_zip "$page" "$pattern" || true)"
  if [[ -n "$href" ]]; then
    if [[ "$href" =~ ^https?:// ]]; then abs="$href"; else abs="${page%/}/$href"; fi
    code="$(http_head "$abs")"
    [[ "$code" == "200" ]] && { echo "$abs"; return 0; }
  fi
  # 3) known forced latest for RectorStuff
  if [[ "$name" == "RectorStuff" ]]; then
    abs="https://github.com/rmrector/repository.rector.stuff/raw/master/latest/repository.rector.stuff-latest.zip"
    code="$(http_head "$abs")"
    [[ "$code" == "200" ]] && { echo "$abs"; return 0; }
  fi
  return 1
}

fetch_zip_to_cache(){
  local name="$1" src="$2"
  [[ -f "$src" ]] && { echo "$src"; return 0; }
  local out="${CACHE_DIR%/}/${name}.zip"
  download_to "$src" "$out"
  echo "$out"
}

# ---- Definitions ----
REPOS=(
  "Umbrella|https://umbrella-plugins.github.io/|repository\.umbrella.*\.zip"
  "Nixgates (Seren)|https://nixgates.github.io/packages/|repository\.nixgates.*\.zip"
  "A4KSubtitles|https://a4k-openproject.github.io/a4kSubtitles/packages/|repository\.a4k.*\.zip"
  "Otaku|https://goldenfreddy0703.github.io/repository.otaku/|repository\.otaku.*\.zip"
  "CocoScrapers|https://cocojoe2411.github.io/|repository\.cocoscrapers.*\.zip"
  "jurialmunkey|https://jurialmunkey.github.io/repository.jurialmunkey/|repository\.jurialmunkey.*\.zip"
  "RectorStuff|https://github.com/rmrector/repository.rector.stuff/raw/master/latest/|repository\.rector\.stuff.*\.zip"
)

# Local direct zips you said you’ll keep on SD:
OPTI_KLEAN_ZIP="${CACHE_DIR%/}/OptiKlean.zip"  # direct addon zip
BBVIKING_SEREN_PATCH="${CACHE_DIR%/}/Seren.zip" # apply after Seren

log "Using local repository folder: $CACHE_DIR"
mkdir -p "$CACHE_DIR" "$KODI_HOME/addons/packages" || true

# Ensure Kodi RPC is reachable (don’t fail hard if not)
if wait_for_jsonrpc 90; then
  log "Kodi JSON-RPC reachable."
else
  warn "Kodi JSON-RPC not reachable; proceeding best-effort."
fi

# Optional: wait for GUI API to be responsive
if gui_ready; then
  log "Kodi GUI API responds."
else
  warn "GUI not fully ready; installs will still be attempted."
fi

# 1) Repos (local first, then web)
dead_repos=()
for entry in "${REPOS[@]}"; do
  IFS="|" read -r NAME PAGE PATTERN <<<"$entry"
  log "Repo: $NAME"
  if zip_url="$(resolve_repo_zip "$NAME" "$PAGE" "$PATTERN")"; then
    log "Resolved zip: $zip_url"
    if zip_path="$(fetch_zip_to_cache "$NAME" "$zip_url" 2>/dev/null)"; then
      install_repo_zip "$zip_path" || warn "Repo install failed: $NAME"
    else
      warn "Could not fetch zip for $NAME"
      dead_repos+=("$NAME")
    fi
  else
    warn "No zip found for $NAME (local/web)"
    dead_repos+=("$NAME")
  fi
  wait_settle
done
((${#dead_repos[@]})) && warn "Unresolved repos: ${dead_repos[*]}"

# 2) Core addon order (Seren before BBViking; TMDb Helper before skin)
ADDONS=(
  "plugin.video.umbrella"
  "plugin.video.seren"
  "service.subtitles.a4ksubtitles"
  "plugin.video.otaku"
  "script.module.cocoscrapers"
  "script.trakt"
  "script.artwork.dump"
  "plugin.video.themoviedb.helper"
  "skin.arctic.fuse.2"
)
for addon in "${ADDONS[@]}"; do
  log "Install request: $addon"
  install_addon_id "$addon"
  wait_settle
  if [[ "$addon" == "plugin.video.seren" ]]; then
    if wait_for_addon_enabled "plugin.video.seren" 180; then
      log "Seren enabled; applying BBViking patch if present."
      if [[ -f "$BBVIKING_SEREN_PATCH" ]]; then
        install_zip_via_files "$BBVIKING_SEREN_PATCH"
        wait_settle
      else
        warn "BBViking patch not found at $BBVIKING_SEREN_PATCH"
      fi
    else
      warn "Seren not enabled within timeout; skipping BBViking patch."
    fi
  fi
done

# 3) OptiKlean direct zip
if [[ -f "$OPTI_KLEAN_ZIP" ]]; then
  log "Installing OptiKlean from $OPTI_KLEAN_ZIP"
  install_zip_via_files "$OPTI_KLEAN_ZIP"
  wait_settle
else
  warn "OptiKlean zip missing at $OPTI_KLEAN_ZIP"
fi

# 4) Optional fonts drop
if [[ -d "$FONTS_SRC" && -n "$(ls -A "$FONTS_SRC" 2>/dev/null)" ]]; then
  log "Installing custom fonts from $FONTS_SRC"
  mkdir -p "$KODI_HOME/media/Fonts"
  cp -fn "$FONTS_SRC"/* "$KODI_HOME/media/Fonts/" || true
  chown -R xbian:xbian "$KODI_HOME/media/Fonts" || true
fi

# 5) Restart Kodi cleanly (XBian = upstart)
do_restart(){
  if command -v initctl >/dev/null 2>&1; then
    initctl restart xbmc || true
  elif command -v systemctl >/dev/null 2>&1; then
    systemctl restart kodi || systemctl restart mediacenter || true
  else
    warn "No known service manager; please reboot manually."
  fi
}
if [[ "$AUTO_RESTART" == "1" ]]; then
  log "Restarting Kodi to settle skin + deps…"
  do_restart
else
  log "Please restart Kodi manually."
fi

log "Add-ons phase complete."
