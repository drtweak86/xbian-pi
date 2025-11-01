
#!/usr/bin/env bash
set -euo pipefail
. /opt/osmc-oneclick/phases/31_helpers.sh

CANDIDATE_SKINS=("skin.arctic.fuse.2")
ASSETS_ROOT="/opt/osmc-oneclick/assets"
FONT_XML_SRC="${ASSETS_ROOT}/config/Font.xml"
FONTS_SRC_DIR="${ASSETS_ROOT}/fonts"
NEEDED_TTFS=("Exo2-Regular.ttf" "Exo2-Light.ttf" "Exo2-Bold.ttf")

find_skin_path() {
  for sid in "${CANDIDATE_SKINS[@]}"; do
    local p="/home/xbian/.kodi/addons/${sid}"
    [ -d "$p" ] && { echo "$sid|$p"; return 0; }
  done
  return 1
}

pair="$(find_skin_path)" || { warn "[fonts] Target skin not installed yet"; exit 0; }
SKIN_ID="${pair%%|*}"; SKIN_PATH="${pair##*|}"
FONTS_DIR="${SKIN_PATH}/media/fonts"; LAYOUT_DIR="${SKIN_PATH}/1080i"

[ -f "$FONT_XML_SRC" ] || { warn "[fonts] Missing Font.xml"; exit 1; }
for f in "${NEEDED_TTFS[@]}"; do [ -f "${FONTS_SRC_DIR}/${f}" ] || { warn "[fonts] Missing ${f}"; exit 1; }; done

mkdir -p "$FONTS_DIR" "$LAYOUT_DIR"
cp -f "${FONTS_SRC_DIR}/"*.ttf "$FONTS_DIR/"
cp -f "$FONT_XML_SRC" "${LAYOUT_DIR}/Font.xml"
chown -R xbian:xbian "$SKIN_PATH" || true
kodi_send -a "ReloadSkin()" >/dev/null 2>&1 || true
echo "[fonts] Installed EXO2 fonts for ${SKIN_ID}"
