#!/bin/bash
# =====================================================================
#  Bat-Net Wi-Fi Auto-Switch (XBian/OSMC)
#  Version: 1.4-XB-RSSI
#  Prefers 5 GHz, falls back to 2.4 GHz, optional WireGuard trigger.
#  Place at: /usr/local/sbin/wifi-autoswitch.sh
# =====================================================================

set -e

LOGFILE="/var/log/wifi-autoswitch.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

# ---- USER SETTINGS ---------------------------------------------------
WLAN="wlan0"
PREF5="Home_5GHz"        # your 5 GHz SSID
PREF24="Home_2.4GHz"     # your 2.4 GHz SSID
RSSI_MIN_5G=-70          # only switch to 5 GHz if signal is better than this
WG_SWITCH="/usr/local/sbin/wg-switch"   # optional
# ---------------------------------------------------------------------

log(){ echo "[$DATE] $*" >> "$LOGFILE"; }

# Return RSSI (dBm) for an SSID (first match), or empty if not found
rssi_for_ssid() {
  local ssid="$1"
  iwlist "$WLAN" scan 2>/dev/null \
    | awk -v s="$ssid" '
        /Cell/ {sig=""; ss=""; freq=""}
        /ESSID:/ {ss=$0; gsub(/.*ESSID:"|".*/,"",ss)}
        /Signal level=/ {sig=$0; gsub(/.*Signal level=|-| dBm/,"",sig); sig=-sig}
        /Frequency:/ {freq=$0; gsub(/.*Frequency:| GHz.*/,"",freq); freq=freq*1000}
        ss==s { if (sig!="") {print sig; exit} }
      '
}

# Is SSID present on 5 GHz band?
ssid_is_5g() {
  local ssid="$1"
  iwlist "$WLAN" scan 2>/dev/null \
    | awk -v s="$ssid" '
        /Cell/ {ss=""; freq=""}
        /ESSID:/ {ss=$0; gsub(/.*ESSID:"|".*/,"",ss)}
        /Frequency:/ {freq=$0; gsub(/.*Frequency:| GHz.*/,"",freq); mhz=freq*1000}
        ss==s { if (mhz>=5000) {print "yes"; exit} }
      ' | grep -q yes
}

log "==== Bat-Net Auto-Switch check ===="

CURR_SSID=$(iwgetid -r 2>/dev/null || true)

# If not connected, try 5 GHz first
if [ -z "$CURR_SSID" ]; then
  log "Not connected — trying $PREF5 first."
  nid=$(wpa_cli -i "$WLAN" list_networks | awk -v s="$PREF5" '$0~s{print $1; exit}')
  [ -n "$nid" ] && wpa_cli -i "$WLAN" select_network "$nid" >/dev/null 2>&1
  sleep 8
  CURR_SSID=$(iwgetid -r 2>/dev/null || true)
fi

# If we’re on 2.4 GHz, see if a good 5 GHz is around
if [ "$CURR_SSID" = "$PREF24" ]; then
  if ssid_is_5g "$PREF5"; then
    RSSI=$(rssi_for_ssid "$PREF5")
    if [ -n "$RSSI" ] && [ "$RSSI" -ge "$RSSI_MIN_5G" ]; then
      log "5 GHz ($PREF5) visible with RSSI ${RSSI}dBm ≥ ${RSSI_MIN_5G} — switching."
      wpa_cli -i "$WLAN" disconnect >/dev/null 2>&1
      nid=$(wpa_cli -i "$WLAN" list_networks | awk -v s="$PREF5" '$0~s{print $1; exit}')
      [ -n "$nid" ] && wpa_cli -i "$WLAN" select_network "$nid" >/dev/null 2>&1
      sleep 8
      log "Reconnected to: $(iwgetid -r 2>/dev/null)"
    else
      log "5 GHz present but weak (RSSI=${RSSI:-unknown}) — staying on 2.4 GHz."
    fi
  else
    log "5 GHz SSID not found — staying on 2.4 GHz."
  fi
else
  [ -z "$CURR_SSID" ] && CURR_SSID="(none)"
  log "Connected to: $CURR_SSID"
fi

# Optional: trigger WireGuard auto profile switch
if [ -x "$WG_SWITCH" ]; then
  log "Triggering wg-switch auto…"
  "$WG_SWITCH" auto >> "$LOGFILE" 2>&1 || true
fi

log "Check complete."
