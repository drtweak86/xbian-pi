
#!/usr/bin/env bash
set -euo pipefail
. /opt/osmc-oneclick/phases/31_helpers.sh

log "[addons] Starting add-on repo + addon installation"

REPOS=(
  "Umbrella|https://umbrella-plugins.github.io/|repository\.umbrella.*\.zip"
  "Nixgates (Seren)|https://nixgates.github.io/packages/|repository\.nixgates.*\.zip"
  "A4KSubtitles|https://a4k-openproject.github.io/a4kSubtitles/packages/|repository\.a4k.*\.zip"
  "Otaku|https://goldenfreddy0703.github.io/repository.otaku/|repository\.otaku.*\.zip"
  "CocoScrapers|https://cocojoe2411.github.io/|repository\.cocoscrapers.*\.zip"
  "OptiKlean|https://www.digitalking.it/kodi-repo/|repository\.optiklean.*\.zip"
  "jurialmunkey|https://jurialmunkey.github.io/repository.jurialmunkey/|repository\.jurialmunkey.*\.zip"
  "RectorStuff|https://github.com/rmrector/repository.rector.stuff/raw/master/latest/|repository\.rector\.stuff.*\.zip"
)

for entry in "${REPOS[@]}"; do
  IFS="|" read -r NAME PAGE PATTERN <<<"$entry"
  log "[addons] Repo: $NAME"
  ZIP_URL="$(fetch_latest_zip "$PAGE" "$PATTERN" || true)"
  if [[ -z "${ZIP_URL:-}" && "$NAME" == "RectorStuff" ]]; then
    ZIP_URL="https://github.com/rmrector/repository.rector.stuff/raw/master/latest/repository.rector.stuff-latest.zip"
  fi
  if [[ -z "${ZIP_URL:-}" ]]; then
    warn "[addons] Could not auto-detect $NAME from $PAGE"
    continue
  fi
  install_repo_from_url "$ZIP_URL" || warn "[addons] repo install failed: $NAME"
done

ADDONS=(
  "plugin.video.umbrella"
  "plugin.video.seren"
  "service.subtitles.a4ksubtitles"
  "plugin.video.otaku"
  "script.module.cocoscrapers"
  "script.trakt"
  "script.artwork.dump"
  "plugin.program.optiklean"
  "skin.arctic.fuse.2"
)
for addon in "${ADDONS[@]}"; do
  log "[addons] Installing $addon"
  install_addon "$addon" || true
done

# Seren patch (best-effort)
BBV_PAGE="https://bbviking.github.io/"
BBV_ZIP="$(fetch_latest_zip "$BBV_PAGE" "\.zip$" || true)"
[ -n "${BBV_ZIP:-}" ] && install_zip_from_url "$BBV_ZIP" || true

log "[addons] Done."
