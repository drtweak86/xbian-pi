#!/bin/bash
# =====================================================================
#  Bat-Net Wi-Fi Auto-Switch + QoS + Kodi Notify
#  Version: 1.6.5-XB-StreamSmooth
#  Profile : Internet / HTTPS streaming (AllDebrid, CDN, etc.)
#  ---------------------------------------------------------------------
#  • Auto-discovers 2.4/5 GHz BSSIDs for one SSID
#  • Decides by RSSI + rolling-average latency + packet loss
#  • Switches by BSSID to lock the band
#  • Kodi OSD notifications on change
# =====================================================================
set -Eeuo pipefail

LOGFILE="/var/log/wifi-autoswitch.log"
WLAN="wlan0"
SSID="Batcave"

# QoS tuning for internet streaming
PING_TARGET="1.1.1.1"
PING_COUNT=5
MAX_LOSS=3              # % loss threshold
MAX_LAT_MS=90           # avg ms threshold (after smoothing)

# Radio preference
RSSI_MIN_5G=-72
FAVOR_5G_MARGIN=3
SCAN_SLEEP=6

# Kodi notifications
KODI_NOTIFY=1
KODI_HOST="127.0.0.1"
KODI_PORT=8080

log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >>"$LOGFILE"; }

notify(){
  local title="$1" msg="$2"
  (( KODI_NOTIFY )) || return 0
  if command -v kodi-send >/dev/null 2>&1; then
    kodi-send -a "Notification(${title},${msg},5000)" >/dev/null 2>&1 || true
  else
    curl -s --max-time 1 -H 'Content-Type: application/json' \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"GUI.ShowNotification\",\"params\":{\"title\":\"${title}\",\"message\":\"${msg}\"}}" \
      "http://${KODI_HOST}:${KODI_PORT}/jsonrpc" >/dev/null 2>&1 || true
  fi
}

# ---------------- Helpers ----------------
scan_once(){ iwlist "$WLAN" scan 2>/dev/null; }

discover_bssids(){  # -> bssid24 rssi24 bssid5 rssi5
  scan_once | awk -v ssid="$SSID" '
    BEGIN{RS="Cell "; b24=""; b5=""; r24=""; r5=""}
    /ESSID:/{match($0,/ESSID:"([^"]+)"/,m); s=m[1]; if(s!=ssid) next
             match($0,/Address: ([0-9A-Fa-f:]+)/,b); mac=b[1]
             match($0,/Frequency: *([0-9.]+) GHz/,f); fr=f[1]
             match($0,/Signal level=(-?[0-9]+) dBm/,r); rs=r[1]
             if(fr>=5.0 && b5==""){b5=mac; r5=rs}
             if(fr<5.0  && b24==""){b24=mac; r24=rs}}
    END{printf "%s %s %s %s\n", b24, r24, b5, r5}'
}

latency_check(){  # -> avg_ms loss_pct (sanitized)
  local out; out=$(ping -q -c "$PING_COUNT" -w "$((PING_COUNT+2))" "$PING_TARGET" 2>/dev/null || true)
  local loss avg
  loss=$(echo "$out" | awk -F',' '/packet loss/{gsub(/[^0-9]/,"",$3); print $3}')
  avg=$(echo "$out" | awk -F'/' '/rtt min\/avg\/max/{print $5}')
  [ -z "$loss" ] && loss=100
  [ -z "$avg" ] && avg=9999

  # rolling average (3 runs) stored in /tmp
  local AVG_FILE=/tmp/wifi_avg.log
  [ -f "$AVG_FILE" ] || echo "0 0 0" > "$AVG_FILE"
  read -r a b c < "$AVG_FILE"
  a=$b; b=$c; c=$(printf "%.0f" "$avg")
  echo "$a $b $c" > "$AVG_FILE"
  avg=$(( (a + b + c) / 3 ))

  echo "$avg" "$loss"
}

current_info(){  # -> ssid bssid freq band
  iw dev "$WLAN" link | awk '
    /Connected to/{mac=$3}
    /SSID:/{ssid=$2}
    /freq:/{f=$2}
    END{band=(f>=5000)?"5":"2.4"; printf "%s %s %s %s\n", ssid, mac, f, band}'
}

connect_bssid(){
  local bssid="$1" nid
  nid=$(wpa_cli -i "$WLAN" list_networks | awk -v s="$SSID" 'index($0,s){print $1; exit}')
  if [ -z "$nid" ]; then
    nid=$(wpa_cli -i "$WLAN" add_network | tail -n1)
    wpa_cli -i "$WLAN" set_network "$nid" ssid "\"$SSID\"" >/dev/null
  fi
  wpa_cli -i "$WLAN" disconnect >/dev/null 2>&1
  wpa_cli -i "$WLAN" bssid "$nid" "$bssid" >/dev/null 2>&1
  wpa_cli -i "$WLAN" select_network "$nid" >/dev/null 2>&1
  sleep "$SCAN_SLEEP"
}

qos_label(){ # avg_ms loss_pct -> GOOD/FAIR/POOR
  local a l
  a=$(printf '%s' "$1" | cut -d. -f1); [ -z "$a" ] && a=0
  l=$(printf '%s' "$2" | tr -cd '0-9'); [ -z "$l" ] && l=0
  if   [ "$l" -gt 50 ] || [ "$a" -gt 150 ]; then echo "POOR"
  elif [ "$l" -gt 20 ] || [ "$a" -gt  90 ]; then echo "FAIR"
  else echo "GOOD"; fi
}

# ---------------- Main -------------------
main(){
  log "==== QoS auto-switch check (target ${PING_TARGET}) ===="

  read -r BSSID24 RSSI24 BSSID5 RSSI5 <<<"$(discover_bssids)"
  log "Scan: 2.4G(${BSSID24:-NA}) RSSI=${RSSI24:-NA} | 5G(${BSSID5:-NA}) RSSI=${RSSI5:-NA}"

  read -r CURR_SSID CURR_BSSID CURR_FREQ CURR_BAND <<<"$(current_info)"
  read -r AVG_MS LOSS_PCT <<<"$(latency_check)"

  # safe integers
  a_int=$(printf '%s' "$AVG_MS" | tr -cd '0-9'); [ -z "$a_int" ] && a_int=0
  l_int=$(printf '%s' "$LOSS_PCT" | tr -cd '0-9'); [ -z "$l_int" ] && l_int=0

  local LABEL; LABEL=$(qos_label "$AVG_MS" "$LOSS_PCT")
  log "Now: SSID=${CURR_SSID:-none} BSSID=${CURR_BSSID:-none} band=${CURR_BAND:-NA} freq=${CURR_FREQ:-NA}MHz | QoS=${LABEL} avg=${AVG_MS}ms loss=${LOSS_PCT}%"

  # choose desired band from radio metrics first
  local WANT=""
  if [ -n "${RSSI5:-}" ] && [ "$RSSI5" -ge "$RSSI_MIN_5G" ]; then
    if [ -z "${RSSI24:-}" ] || [ $(( RSSI5 - RSSI24 )) -ge "$FAVOR_5G_MARGIN" ]; then
      WANT="5"
    fi
  fi
  [ -z "$WANT" ] && [ -n "${BSSID24:-}" ] && WANT="2.4"

  # history gate: require 3 consecutive non-GOOD results to react
  local HIST=/tmp/wifi_qos_history.log
  [ -f "$HIST" ] || echo "GOOD GOOD GOOD" > "$HIST"
  read -r q1 q2 q3 < "$HIST"
  q1=$q2; q2=$q3; q3="$LABEL"
  echo "$q1 $q2 $q3" > "$HIST"
  local BAD_TRIPLE=0
  if [ "$q1" != "GOOD" ] && [ "$q2" != "GOOD" ] && [ "$q3" != "GOOD" ]; then BAD_TRIPLE=1; fi

  # React to QoS deterioration only if consistently bad
  if [ "$BAD_TRIPLE" -eq 1 ] && { [ "$l_int" -gt "$MAX_LOSS" ] || [ "$a_int" -gt "$MAX_LAT_MS" ]; }; then
    log "QoS consistently degraded (avg=${AVG_MS}ms loss=${LOSS_PCT}%) — re-evaluating band."
    if [ "$CURR_BAND" = "2.4" ] && [ -n "${BSSID5:-}" ] && [ -n "${RSSI5:-}" ] && [ "$RSSI5" -ge "$RSSI_MIN_5G" ]; then
      WANT="5"
    elif [ "$CURR_BAND" = "5" ] && [ -n "${BSSID24:-}" ]; then
      WANT="2.4"
    fi
  fi

  # Switch if needed
  if   [ "$WANT" = "5" ] && [ -n "${BSSID5:-}" ] && [ "$CURR_BAND" != "5" ]; then
    log "Switching to 5G ($BSSID5)…"; notify "Wi-Fi" "Quality improved — switching to 5 GHz"
    connect_bssid "$BSSID5"
  elif [ "$WANT" = "2.4" ] && [ -n "${BSSID24:-}" ] && [ "$CURR_BAND" != "2.4" ]; then
    log "Switching to 2.4G ($BSSID24)…"; notify "Wi-Fi" "Quality dropped — falling back to 2.4 GHz"
    connect_bssid "$BSSID24"
  else
    log "Staying put."
  fi

  # Optional WireGuard kick
  if command -v /usr/local/sbin/wg-switch >/dev/null 2>&1; then
    /usr/local/sbin/wg-switch auto >>"$LOGFILE" 2>&1 || true
  fi

  log "Check complete."
}
main
