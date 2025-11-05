#!/usr/bin/env bash
set -euo pipefail

# -------- SETTINGS YOU CAN TWEAK ----------
# Where to keep a local mirror/cache of repo zips (mounted phone dir or git checkout)
CACHE_DIR="${CACHE_DIR:-/opt/repo-cache}"
# Optional GitHub fallback where you pre-upload repo zips (latest only is fine)
# e.g. https://raw.githubusercontent.com/drtweak86/kodi-repo-cache/main/
GITHUB_CACHE="${GITHUB_CACHE:-}"
# Wait a bit after each install so Kodi can settle first-run popups/indexing etc.
SETTLE_SECS="${SETTLE_SECS:-6}"
# Auto-restart Kodi once skin + helpers are in (0=no, 1=yes)
AUTO_RESTART="${AUTO_RESTART:-1}"
# Optional fonts folder to copy post-restart (put your *.ttf/*.otf here)
FONTS_SRC="${FONTS_SRC:-/opt/kodi-fonts}"
# Where Kodi lives for user xbian
KODI_HOME="${KODI_HOME:-/home/xbian/.kodi}"
# Try to use JSON-RPC if web server is on (http://127.0.0.1:8080)
KODI_RPC="${KODI_RPC:-http://127.0.0.1:8080/jsonrpc}"

# -------- LOG HELPERS ----------
log(){ printf "[addons] %s\n" "$*"; }
warn(){ printf "[addons][WARN] %s\n" "$*" >&2; }

# -------- MINI CURL HELPERS ----------
http_head(){
  # $1=url -> outputs HTTP code or 'ERR'
  curl -fsSIL --max-time 10 --retry 2 --retry-delay 1 -o /dev/null -w "%{http_code}" "$1" 2>/dev/null || echo "ERR"
}
download_to(){
  # $1=url $2=dest
  curl -fL --max-time 60 --retry 2 --retry-delay 2 -o "$2" "$1"
}

# -------- INSTALL HELPERS (safe even without your 31_helpers.sh) ----------
kodi_addon_dir(){ echo "$KODI_HOME/addons/$1"; }
wait_settle(){ sleep "$SETTLE_SECS"; }

install_zip_via_files(){
  # Works without JSON-RPC: drop zip into "addons/packages" and trigger local install via kodi-send if available.
  # $1: zipfile path
  local zip="$1"
  mkdir -p "$KODI_HOME/addons/packages"
  cp -f "$zip" "$KODI_HOME/addons/packages/"
  # Best-effort: if jsonrpc is available, use it
  if curl -s "$KODI_RPC" >/dev/null 2>&1; then
    curl -s -H "Content-Type: application/json" -X POST "$KODI_RPC" \
      -d '{"jsonrpc":"2.0","id":1,"method":"Addons.Install", "params":{"addonid":null,"addonpath":"'"$zip"'"}}' >/dev/null 2>&1 || true
  fi
}

install_repo_zip(){
  # $1 zipfile path
  local zip="$1"
  log "Installing repo from: $zip"
  install_zip_via_files "$zip" || true
  wait_settle
}

install_addon_id(){
  # $1 addon id
  local addon="$1"
  # If JSON-RPC is up, ask Kodi to install properly
  if curl -s "$KODI_RPC" >/dev/null 2>&1; then
    curl -s -H "Content-Type: application/json" -X POST "$KODI_RPC" \
      -d '{"jsonrpc":"2.0","id":1,"method":"Addons.Install","params":{"addonid":"'"$addon"'"}}' >/dev/null 2>&1 || true
  else
    # Fallback: ask Kodi to refresh repos by touching sources; let dependencies resolve on next GUI cycle
    warn "JSON-RPC not reachable; installing $addon will rely on GUI cycle/deps."
  fi
  wait_settle
}

# -------- URL → ZIP RESOLUTION WITH MIRRORS & CACHE ----------
# Each entry supports: NAME|PRIMARY_PAGE|ZIP_PATTERN|MIRRORS_SEMICOLON
# If page scan fails, we try:
#  1) well-known "latest.zip" if defined (special casing below)
#  2) GITHUB_CACHE (if set) → ${GITHUB_CACHE}/${NAME}.zip
#  3) CACHE_DIR/${NAME}.zip (pre-dropped by you / your phone)

mkdir -p "$CACHE_DIR"

# curl the page & pick latest zip by regex
page_latest_zip(){
  # $1 url $2 pattern
  local page="$1" pat="$2"
  curl -fsSL --max-time 15 "$page" 2>/dev/null | \
    grep -Eo 'href="[^"]+\.zip"' | sed -E 's/^href="([^"]+)".*/\1/' | \
    grep -E "$pat" | head -n1 || true
}

resolve_zip(){
  # $1 name $2 page $3 pattern $4 mirrors
  local name="$1" page="$2" pat="$3" mirrors="${4:-}"

  # 0) sanity check page
  local code
  code="$(http_head "$page")"
  if [[ "$code" != "200" && "$code" != "301" && "$code" != "302" ]]; then
    warn "$name: page unhealthy ($code) → will try mirrors/cache"
  fi

  # 1) try scrape primary page
  local href rel abs
  href="$(page_latest_zip "$page" "$pat" || true)"
  if [[ -n "$href" ]]; then
    # absolutize if href is relative
    if [[ "$href" =~ ^https?:// ]]; then abs="$href"; else
      abs="${page%/}/$href"
    fi
    code="$(http_head "$abs")"
    if [[ "$code" == "200" ]]; then echo "$abs"; return 0; fi
    warn "$name: primary zip bad code ($code)"
  fi

  # 2) mirrors (semicolon separated URLs that point directly to zip or to another listing)
  IFS=";" read -r -a MIR <<< "$mirrors"
  for m in "${MIR[@]}"; do
    [[ -z "$m" ]] && continue
    if [[ "$m" =~ \.zip$ ]]; then
      code="$(http_head "$m")"
      if [[ "$code" == "200" ]]; then echo "$m"; return 0; fi
    else
      href="$(page_latest_zip "$m" "$pat" || true)"
      if [[ -n "$href" ]]; then
        if [[ "$href" =~ ^https?:// ]]; then abs="$href"; else abs="${m%/}/$href"; fi
        code="$(http_head "$abs")"
        if [[ "$code" == "200" ]]; then echo "$abs"; return 0; fi
      fi
    fi
  done

  # 3) special hard-coded “latest.zip” fallbacks where applicable
  if [[ "$name" == "RectorStuff" ]]; then
    abs="https://github.com/rmrector/repository.rector.stuff/raw/master/latest/repository.rector.stuff-latest.zip"
    code="$(http_head "$abs")"
    if [[ "$code" == "200" ]]; then echo "$abs"; return 0; fi
  fi

  # 4) GitHub cache (if provided)
  if [[ -n "$GITHUB_CACHE" ]]; then
    abs="${GITHUB_CACHE%/}/${name}.zip"
    code="$(http_head "$abs")"
    if [[ "$code" == "200" ]]; then echo "$abs"; return 0; fi
  fi

  # 5) Local cache on disk
  if [[ -f "$CACHE_DIR/$name.zip" ]]; then
    echo "file://$CACHE_DIR/$name.zip"
    return 0
  fi

  return 1
}

get_zip_to_cache(){
  # $1 name $2 url -> returns absolute path to zip in cache (or original if file://)
  local name="$1" url="$2"
  if [[ "$url" =~ ^file:// ]]; then
    echo "${url#file://}"
    return 0
  fi
  local out="$CACHE_DIR/$name.zip"
  download_to "$url" "$out"
  echo "$out"
}

# --------- START ----------
log "Starting add-on repo + addon installation"

# Repos with mirrors you can add (4th field). Example keeps most blank.
REPOS=(
  "Umbrella|https://umbrella-plugins.github.io/|repository\.umbrella.*\.zip|"
  "Nixgates (Seren)|https://nixgates.github.io/packages/|repository\.nixgates.*\.zip|"
  "A4KSubtitles|https://a4k-openproject.github.io/a4kSubtitles/packages/|repository\.a4k.*\.zip|"
  "Otaku|https://goldenfreddy0703.github.io/repository.otaku/|repository\.otaku.*\.zip|"
  "CocoScrapers|https://cocojoe2411.github.io/|repository\.cocoscrapers.*\.zip|"
  "OptiKlean|https://www.digitalking.it/kodi-repo/|repository\.optiklean.*\.zip|"
  "jurialmunkey|https://jurialmunkey.github.io/repository.jurialmunkey/|repository\.jurialmunkey.*\.zip|"
  "RectorStuff|https://github.com/rmrector/repository.rector.stuff/raw/master/latest/|repository\.rector\.stuff.*\.zip|"
)

dead_repos=()

for entry in "${REPOS[@]}"; do
  IFS="|" read -r NAME PAGE PATTERN MIRRORS <<<"$entry"
  log "Repo: $NAME"
  if zip_url="$(resolve_zip "$NAME" "$PAGE" "$PATTERN" "$MIRRORS")"; then
    log "Resolved: $zip_url"
    if zip_path="$(get_zip_to_cache "$NAME" "$zip_url" 2>/dev/null)"; then
      install_repo_zip "$zip_path" || warn "Repo install failed: $NAME"
    else
      warn "Failed to cache zip for $NAME"
      dead_repos+=("$NAME ($PAGE)")
    fi
  else
    warn "Could not auto-detect $NAME from $PAGE"
    dead_repos+=("$NAME ($PAGE)")
  fi
  wait_settle
done

if ((${#dead_repos[@]})); then
  warn "Some repos were unreachable or invalid:"
  for r in "${dead_repos[@]}"; do warn " - $r"; done
fi

# ---- Addons in correct order (TMDb Helper BEFORE skin) ----
ADDONS=(
  "plugin.video.umbrella"
  "plugin.video.seren"
  "service.subtitles.a4ksubtitles"
  "plugin.video.otaku"
  "script.module.cocoscrapers"
  "script.trakt"
  "script.artwork.dump"
  "plugin.program.optiklean"
  "plugin.video.themoviedb.helper"  # TMDb Helper first
  "skin.arctic.fuse.2"              # skin last
)

for addon in "${ADDONS[@]}"; do
  log "Installing addon: $addon"
  install_addon_id "$addon" || warn "Install request failed or deferred: $addon"
  wait_settle
done

# ---- Suggest or perform restart so skin can load cleanly ----
do_restart(){
  if command -v systemctl >/dev/null 2>&1; then
    sudo systemctl restart kodi || sudo systemctl restart mediacenter || true
  elif command -v initctl >/dev/null 2>&1; then
    # XBian upstart job
    sudo initctl restart xbmc || true
  else
    warn "No known service manager; please reboot manually."
  fi
}

if [[ "$AUTO_RESTART" == "1" ]]; then
  log "Restarting Kodi so skin + deps can come up cleanly…"
  do_restart
else
  log "Please restart Kodi to finish skin activation."
fi

# ---- Post-restart: fonts drop-in (idempotent) ----
# If Kodi is already running by the time this runs, files will still copy safely.
if [[ -d "$FONTS_SRC" && -n "$(ls -1 "$FONTS_SRC" 2>/dev/null)" ]]; then
  log "Installing custom fonts from $FONTS_SRC …"
  mkdir -p "$KODI_HOME/media/Fonts"
  cp -fn "$FONTS_SRC"/* "$KODI_HOME/media/Fonts/" || true
  chown -R xbian:xbian "$KODI_HOME/media/Fonts" || true
  log "Fonts present: $(ls -1 "$KODI_HOME/media/Fonts" | wc -l)"
else
  log "No custom fonts folder ($FONTS_SRC). Skipping fonts."
fi

log "Add-ons phase done."
