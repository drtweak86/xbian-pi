
#!/usr/bin/env bash
# XBian Wi-Fi autoswitch (cron-based)
set -euo pipefail

CONF="/etc/default/wifi-autoswitch"
BIN="/usr/local/sbin/wifi-autoswitch"
CRON="/etc/cron.d/wifi-autoswitch"

apt-get update -y || true
apt-get install -y --no-install-recommends wireless-tools iw wpasupplicant || true

# Seed conf if missing
if [ ! -f "$CONF" ]; then
  cat >"$CONF"<<'CFG'
PREFERRED_SSIDS="HomeWiFi UpstairsWiFi"
WIFI_IFACE="wlan0"
MIN_RSSI="-75"
KODI_NOTIFY=1
CFG
  chmod 0644 "$CONF"
fi

# Worker binary
install -D -o root -g root -m 0755 /dev/stdin "$BIN" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
CONF="/etc/default/wifi-autoswitch"
[ -r "$CONF" ] && . "$CONF"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"; PREFERRED_SSIDS="${PREFERRED_SSIDS:-}"; MIN_RSSI="${MIN_RSSI:--75}"; KODI_NOTIFY="${KODI_NOTIFY:-1}"
notify(){ [ "$KODI_NOTIFY" = "1" ] && command -v kodi-send >/dev/null && kodi-send --action="Notification(WiFi,$1,3500)" >/dev/null 2>&1 || true; echo "[wifi-autoswitch] $1"; }
declare -A RSSI; cur=""
if command -v iw >/dev/null 2>&1; then
  while IFS= read -r line; do case "$line" in "BSS "*) ss="";; *"SSID: "*) ss="${line#*SSID: }";; *"signal: "*) [ -n "$ss" ] && r="${line#*signal: }" && RSSI["$ss"]="${r%.*}";; esac; done < <(iw dev "$WIFI_IFACE" scan 2>/dev/null || true)
fi
CUR_SSID="$(iwgetid -r 2>/dev/null || true)"; BEST_SSID=""; BEST_RSSI="-999"
for s in $PREFERRED_SSIDS; do r="${RSSI[$s]:--999}"; [ "$r" -gt "$BEST_RSSI" ] && BEST_RSSI="$r" && BEST_SSID="$s"; done
[ "$BEST_RSSI" -lt "$MIN_RSSI" ] && exit 0
[ "$CUR_SSID" = "$BEST_SSID" ] && exit 0
nid="$(wpa_cli -i "$WIFI_IFACE" list_networks 2>/dev/null | awk -F'\t' -v s="$BEST_SSID" '$2==s{print $1; exit}')"
[ -z "$nid" ] && { notify "SSID $BEST_SSID not configured"; exit 0; }
wpa_cli -i "$WIFI_IFACE" select_network "$nid" >/dev/null 2>&1 || exit 0
notify "Switching → ${BEST_SSID} (RSSI ${BEST_RSSI} dBm)"
SH

# Cron entry (every 2 minutes)
cat >"$CRON"<<CR
*/2 * * * * root $BIN >/dev/null 2>&1
CR
chmod 0644 "$CRON"
service cron restart >/dev/null 2>&1 || true
echo "[33_wifi_autoswitch] Installed cron + worker."
