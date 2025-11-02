#!/bin/bash
# =====================================================================
# Bat-Net Wi-Fi Auto-Switch + QoS + Kodi Notify
# Version: 1.6-XB-QoS
# - Same SSID on 2.4/5G: auto-discovers BSSIDs
# - Decides using RSSI + latency + packet loss
# - Switches by BSSID so it sticks to the intended band
# - Optional Kodi on-screen notifications
# =====================================================================
set -Eeuo pipefail

LOGFILE="/var/log/wifi-autoswitch.log"
WLAN="wlan0"
SSID="Batcave"            # your Wi-Fi name (same on both bands is fine)
PING_TARGET="1.1.1.1"     # latency test target (can be your router IP)
PING_COUNT=5
MAX_LOSS=20               # % loss allowed before we consider switching
MAX_LAT_MS=70             # ms avg allowed on current band before we consider switching
RSSI_MIN_5G=-75           # only use 5G if at least this strong
FAVOR_5G_MARGIN=5         # dB 5G must beat 2.4G by this to prefer it
SCAN_SLEEP=6              # seconds to allow re-association

# Kodi notifications (set to 0 to disable)
KODI_NOTIFY=1
KODI_HOST="127.0.0.1"
KODI_PORT=8080            # needs Kodi web server enabled (Settings > Services)

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOGFILE"; }

notify(){
  local title="$1" msg="$2"
  [ "$KODI_NOTIFY" -ne 1 ] && return 0
  if command -v kodi-send >/dev/null 2>&1; then
    kodi-send -a "Notification(${title},${msg},5000)" >/dev/null 2>&1 || true
  else
    curl -s --max-time 1 -X POST \
      -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"GUI.ShowNotification\",\"params\":{\"title\":\"${title}\",\"message\":\"${msg}\"}}" \
      "http://${KODI_HOST}:${KODI_PORT}/jsonrpc" >/dev/null 2>&1 || true
  fi
}

# Parse iwlist once; awk blocks run per Cell
scan_once(){
  iwlist "$WLAN" scan 2>/dev/null
}

# Return BSSID + RSSI + band for our SSID (first match per band)
discover_bssids(){
  scan_once | awk -v ssid="$SSID" '
    BEGIN{RS="Cell "; b24=""; b5=""; r24=""; r5=""}
    /ESSID:/{
      match($0,/ESSID:"([^"]+)"/,m); s=m[1]
      if (s!=ssid) next
      match($0,/Address: ([0-9A-Fa-f:]+)/,b); mac=b[1]
      match($0,/Frequency: *([0-9.]+) GHz/,f); freq=f[1]
      match($0,/Signal level=(-?[0-9]+) dBm/,r); rssi=r[1]
      if (freq>=5.0 && b5==""){b5=mac; r5=rssi}
      if (freq<5.0  && b24==""){b24=mac; r24=rssi}
    }
    END{printf "%s %s %s %s\n", b24, r24, b5, r5}
  '
}

rssi_for_bssid(){
  local b="$1"
  scan_once | awk -v bssid="$1" '
    BEGIN{RS="Cell "}
    $0 ~ bssid {
      if (match($0,/Signal level=(-?[0-9]+) dBm/,m)) print m[1]
    }'
}

latency_check(){
  # prints "avg_ms loss_pct"
  local out; out=$(ping -q -c "$PING_COUNT" -w "$((PING_COUNT+2))" "$PING_TARGET" 2>/dev/null || true)
  local loss avg
  loss=$(echo "$out" | awk -F',' '/packet loss/{gsub(/%/,"",$3); gsub(/ /,"",$3); print $3}')
  avg=$(echo "$out" | awk -F'/' '/rtt min\/avg\/max/{print $5}')
  [ -z "$loss" ] && loss=100
  [ -z "$avg" ] && avg=9999
  echo "$avg $loss"
}

current_info(){
  iw dev "$WLAN" link | awk '
    /Connected to/{mac=$3}
    /SSID:/{ssid=$2}
    /freq:/{f=$2}
    END{
      band=(f>=5000)?"5":"2.4";
      printf "%s %s %s %s\n", ssid, mac, f, band
    }'
}

connect_bssid(){
  local bssid="$1"
  local nid
  nid=$(wpa_cli -i "$WLAN" list_networks | awk -v s="$SSID" 'index($0,s){print $1; exit}')
  if [ -z "$nid" ]; then
    nid=$(wpa_cli -i "$WLAN" add_network | tail -n1)
    wpa_cli -i "$WLAN" set_network "$nid" ssid "\"$SSID\"" >/dev/null
    # PSK expected in wpa_supplicant config
  fi
  wpa_cli -i "$WLAN" disconnect >/dev/null 2>&1
  wpa_cli -i "$WLAN" bssid "$nid" "$bssid" >/dev/null 2>&1
  wpa_cli -i "$WLAN" select_network "$nid" >/dev/null 2>&1
  sleep "$SCAN_SLEEP"
}

main(){
  log "==== QoS auto-switch check ===="

  # 1) discover both bands for this SSID
  read -r BSSID24 RSSI24 BSSID5 RSSI5 <<<"$(discover_bssids)"
  log "Scan: 2.4G(${BSSID24:-NA}) RSSI=${RSSI24:-NA} | 5G(${BSSID5:-NA}) RSSI=${RSSI5:-NA}"

  # 2) current connection + latency
  read -r CURR_SSID CURR_BSSID CURR_FREQ CURR_BAND <<<"$(current_info)"
  read -r AVG_MS LOSS_PCT <<<"$(latency_check)"
  log "Now: SSID=${CURR_SSID:-none} BSSID=${CURR_BSSID:-none} band=${CURR_BAND:-NA} freq=${CURR_FREQ:-NA}MHz | latency=${AVG_MS}ms loss=${LOSS_PCT}%"

  local WANT=""
  # prefer 5G when visible & strong enough & materially better
  if [ -n "${RSSI5:-}" ] && [ "$RSSI5" -ge "$RSSI_MIN_5G" ]; then
    if [ -z "${RSSI24:-}" ] || [ $(( RSSI5 - RSSI24 )) -ge "$FAVOR_5G_MARGIN" ]; then
      WANT="5"
    fi
  fi
  [ -z "$WANT" ] && [ -n "${BSSID24:-}" ] && WANT="2.4"

  # 3) Consider latency/packet-loss on the *current* band
  if [ "$LOSS_PCT" -gt "$MAX_LOSS" ] || [ "${AVG_MS%.*}" -gt "$MAX_LAT_MS" ]; then
    log "QoS degraded (lat=${AVG_MS}ms loss=${LOSS_PCT}%). Considering switch…"
    if [ "$CURR_BAND" = "2.4" ] && [ -n "${BSSID5:-}" ] && [ -n "${RSSI5:-}" ] && [ "$RSSI5" -ge "$RSSI_MIN_5G" ]; then
      WANT="5"
    elif [ "$CURR_BAND" = "5" ] && [ -n "${BSSID24:-}" ]; then
      WANT="2.4"
    fi
  fi

  # 4) Switch if needed
  if [ "$WANT" = "5" ] && [ -n "${BSSID5:-}" ] && [ "$CURR_BAND" != "5" ]; then
    log "Switching to 5G ($BSSID5)…"; notify "Wi-Fi" "Quality improved — switching to 5 GHz"
    connect_bssid "$BSSID5"
  elif [ "$WANT" = "2.4" ] && [ -n "${BSSID24:-}" ] && [ "$CURR_BAND" != "2.4" ]; then
    log "Switching to 2.4G ($BSSID24)…"; notify "Wi-Fi" "Quality dropped — falling back to 2.4 GHz"
    connect_bssid "$BSSID24"
  else
    log "Staying put."
  fi

  # 5) Optional: trigger WireGuard profile selection
  if command -v /usr/local/sbin/wg-switch >/dev/null 2>&1; then
    /usr/local/sbin/wg-switch auto >>"$LOGFILE" 2>&1 || true
  fi

  log "Check complete."
}
main
