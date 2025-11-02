#!/bin/bash
# =====================================================================
#  Bat-Net Wi-Fi Auto-Switch for XBian / OSMC
#  ---------------------------------------------------------------
#  Version: 1.3-XB-Stable
#  Author : drtweak86 (Jordan)
#  Purpose: Automatically prefer 5GHz Wi-Fi networks, fall back to 2.4GHz,
#           and trigger WireGuard profile switching when connected.
#  Location: /usr/local/sbin/wifi-autoswitch.sh
# =====================================================================

LOGFILE="/var/log/wifi-autoswitch.log"
DATE=$(date '+%Y-%m-%d %H:%M:%S')

# --- USER SETTINGS ---------------------------------------------------
PREF5="Home_5GHz"       # change to your 5GHz SSID
PREF24="Home_2.4GHz"    # change to your 2.4GHz SSID
WLAN="wlan0"            # network interface name
WG_SWITCH="/usr/local/sbin/wg-switch"
# ---------------------------------------------------------------------

echo "[$DATE] ==== Bat-Net Auto-Switch Check Started ====" >> "$LOGFILE"

# Get current SSID
CURR_SSID=$(iwgetid -r 2>/dev/null)

# If not connected, try 5GHz first
if [ -z "$CURR_SSID" ]; then
    echo "[$DATE] Not connected — trying preferred 5GHz first..." >> "$LOGFILE"
    wpa_cli -i "$WLAN" select_network $(wpa_cli -i "$WLAN" list_networks | grep "$PREF5" | awk '{print $1}') >/dev/null 2>&1
    sleep 10
    CURR_SSID=$(iwgetid -r 2>/dev/null)
fi

# If currently on 2.4GHz, check if 5GHz is available
if [ "$CURR_SSID" = "$PREF24" ]; then
    iwlist "$WLAN" scan | grep -q "$PREF5"
    if [ $? -eq 0 ]; then
        echo "[$DATE] 5GHz visible — switching from 2.4GHz to 5GHz..." >> "$LOGFILE"
        wpa_cli -i "$WLAN" disconnect >/dev/null 2>&1
        wpa_cli -i "$WLAN" select_network $(wpa_cli -i "$WLAN" list_networks | grep "$PREF5" | awk '{print $1}') >/dev/null 2>&1
        sleep 10
        CURR_SSID=$(iwgetid -r 2>/dev/null)
        echo "[$DATE] Reconnected to: $CURR_SSID" >> "$LOGFILE"
    else
        echo "[$DATE] 5GHz not found — remaining on 2.4GHz" >> "$LOGFILE"
    fi
else
    echo "[$DATE] Connected to: $CURR_SSID" >> "$LOGFILE"
fi

# Optional: Trigger WireGuard profile auto-switch
if [ -x "$WG_SWITCH" ]; then
    echo "[$DATE] Triggering WireGuard auto-switch..." >> "$LOGFILE"
    "$WG_SWITCH" auto >> "$LOGFILE" 2>&1
fi

echo "[$DATE] ==== Check Complete ====" >> "$LOGFILE"
