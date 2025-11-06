#!/bin/sh
# FrankenPi: Wi-Fi autoswitch (prefers NetworkManager, falls back to wpa_cli)
set -eu
. /usr/local/bin/frankenpi-compat.sh   # log, svc_*

BIN="/usr/local/sbin/wifi-autoswitch"
CFG="/etc/default/wifi-autoswitch"
SVC="/etc/systemd/system/frankenpi-wifi-autoswitch.service"
TMR="/etc/systemd/system/frankenpi-wifi-autoswitch.timer"

# ---- seed config (editable) ----
if [ ! -f "$CFG" ]; then
  mkdir -p /etc/default
  cat >"$CFG"<<'CFG'
# SSIDs in preference order (space-separated)
PREFERRED_SSIDS="HomeWiFi UpstairsWiFi"

# Wi-Fi interface
WIFI_IFACE="wlan0"

# Thresholds:
# If NetworkManager is available, SIGNAL is in % (0–100)
MIN_SIGNAL_PCT=50

# If using iw/wpa_cli path, MIN_RSSI is in dBm (e.g., -75 = better than -75 dBm)
MIN_RSSI="-75"

# Kodi notification on switch (1=yes, 0=no)
KODI_NOTIFY=1
CFG
fi

# ---- install worker (POSIX sh) ----
cat >"$BIN"<<'SH'
#!/bin/sh
set -eu
CONF="/etc/default/wifi-autoswitch"
[ -r "$CONF" ] && . "$CONF"

PREFERRED_SSIDS="${PREFERRED_SSIDS:-}"
WIFI_IFACE="${WIFI_IFACE:-wlan0}"
MIN_SIGNAL_PCT="${MIN_SIGNAL_PCT:-50}"
MIN_RSSI="${MIN_RSSI:--75}"
KODI_NOTIFY="${KODI_NOTIFY:-1}"

notify() {
  if [ "$KODI_NOTIFY" = "1" ] && command -v kodi-send >/dev/null 2>&1; then
    kodi-send --action="Notification(WiFi,$1,3000)" >/dev/null 2>&1 || true
  fi
  echo "[wifi-autoswitch] $1"
}

has(){ command -v "$1" >/dev/null 2>&1; }

# --------- NetworkManager path (preferred) ----------
nm_best() {
  # Output: "SSID|SIGNAL"
  # Ignore hidden entries with blank SSID
  nmcli -f SSID,SIGNAL dev wifi list ifname "$WIFI_IFACE" 2>/dev/null \
    | awk -v pref="$PREFERRED_SSIDS" '
      BEGIN{
        n=split(pref, P, " ");
        for(i=1;i<=n;i++) rank[P[i]]=i;
      }
      NR>1 && $1!=""{
        # SSID may contain spaces: rebuild columns
        sig=$NF; $NF="";
        ssid=substr($0, 1, length($0)-length(sig)-1);
        gsub(/^[ \t]+|[ \t]+$/, "", ssid);
        if (ssid!="") {
          r=(ssid in rank)?rank[ssid]:9999;
          printf("%s|%s|%d\n", ssid, sig, r);
        }
      }
    ' | sort -t'|' -k3,3n -k2,2nr | head -n1
}

nm_current_ssid() {
  nmcli -t -f ACTIVE,SSID connection show --active 2>/dev/null \
    | awk -F: '$1=="yes"{print $2; exit}'
}

nm_switch() {
  ssid="$1"
  # Try exact match connection; if none, let NM auto-connect
  cid="$(nmcli -t -f NAME connection show 2>/dev/null | awk -F: -v s="$ssid" '$1==s{print $1; exit}')"
  if [ -n "$cid" ]; then
    nmcli connection up id "$cid" >/dev/null 2>&1
  else
    nmcli device wifi connect "$ssid" ifname "$WIFI_IFACE" >/dev/null 2>&1
  fi
}

# --------- iw/wpa_cli fallback ----------
scan_rssi() {
  # Output lines: "SSID|RSSI"
  if has iw; then
    iw dev "$WIFI_IFACE" scan 2>/dev/null \
      | awk '
        BEGIN{ ss=""; }
        /^BSS / { ss=""; next }
        /SSID:/ { ss=$0; sub(/^.*SSID: /,"",ss); next }
        /signal:/ && ss!="" { sig=$0; sub(/^.*signal: /,"",sig); sub(/ dBm.*/,"",sig); printf("%s|%s\n", ss, sig); ss="" }
      '
  elif has wpa_cli; then
    wpa_cli -i "$WIFI_IFACE" scan >/dev/null 2>&1 || true
    sleep 1
    wpa_cli -i "$WIFI_IFACE" scan_results 2>/dev/null \
      | awk 'NR>2{printf("%s|%s\n",$5,$3)}'   # SSID|RSSI
  fi
}

wpa_current_ssid() {
  iwgetid -r 2>/dev/null || true
}

wpa_switch() {
  ssid="$1"
  nid="$(wpa_cli -i "$WIFI_IFACE" list_networks 2>/dev/null | awk -F'\t' -v s="$ssid" '$2==s{print $1; exit}')"
  [ -n "$nid" ] && wpa_cli -i "$WIFI_IFACE" select_network "$nid" >/dev/null 2>&1
}

main() {
  [ -n "$PREFERRED_SSIDS" ] || exit 0

  if has nmcli; then
    best="$(nm_best || true)"
    [ -n "$best" ] || exit 0
    b_ssid="$(echo "$best" | cut -d'|' -f1)"
    b_sigp="$(echo "$best" | cut -d'|' -f2)"
    cur="$(nm_current_ssid || true)"
    # threshold in %
    [ "${b_sigp:-0}" -ge "$MIN_SIGNAL_PCT" ] || exit 0
    [ "$cur" = "$b_ssid" ] && exit 0
    nm_switch "$b_ssid" && notify "Switching → $b_ssid (${b_sigp}%)"
    exit 0
  fi

  # Fallback path (RSSI dBm)
  if has iw || has wpa_cli; then
    best_ssid=""; best_rssi="-999"
    scan_rssi | while IFS='|' read -r ss rssi; do
      for want in $PREFERRED_SSIDS; do
        if [ "$ss" = "$want" ] && [ "$rssi" -gt "$best_rssi" ]; then
          best_ssid="$ss"; best_rssi="$rssi"
        fi
      done
    done

    [ -n "$best_ssid" ] || exit 0
    [ "$best_rssi" -ge "$MIN_RSSI" ] || exit 0

    cur="$(wpa_current_ssid || true)"
    [ "$cur" = "$best_ssid" ] && exit 0

    wpa_switch "$best_ssid" && notify "Switching → $best_ssid (${best_rssi} dBm)"
  fi
}
main "$@"
SH
chmod 0755 "$BIN"

# ---- systemd timer every 2 minutes ----
cat >"$SVC"<<'UNIT'
[Unit]
Description=FrankenPi Wi-Fi Autoswitch
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wifi-autoswitch
UNIT

cat >"$TMR"<<'UNIT'
[Unit]
Description=Run FrankenPi Wi-Fi Autoswitch periodically

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
UNIT

svc_enable frankenpi-wifi-autoswitch.timer || true
svc_start  frankenpi-wifi-autoswitch.timer || true

log "[33_wifi_autoswitch] installed; timer active."
