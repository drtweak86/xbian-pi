#!/bin/sh
# FrankenPi: Argon One setup (Pi 4)
set -eu
. /usr/local/bin/frankenpi-compat.sh   # log, pkg_install, svc_*

log "[22_argon_one] Detecting Pi 4…"
grep -q "Raspberry Pi 4" /proc/device-tree/model 2>/dev/null || {
  log "[22_argon_one] Not a Pi 4 — skip."
  exit 0
}

# Prefer the official Argon installer when possible
if command -v curl >/dev/null 2>&1 && command -v bash >/dev/null 2>&1; then
  log "[22_argon_one] Running Argon official installer…"
  if curl -fsSL https://download.argon40.com/argon1.sh | bash >/tmp/argon1.log 2>&1; then
    log "[22_argon_one] Argon installer finished (check /tmp/argon1.log if needed)."
    # If the installer created a systemd service, enable it
    for svc in argononed.service argon-one.service; do
      if systemctl list-unit-files | grep -q "^$svc"; then
        svc_enable "$svc" || true
        svc_start  "$svc" || true
        log "[22_argon_one] Enabled $svc"
        exit 0
      fi
    end
  else
    log "[22_argon_one] Argon installer failed; falling back to FrankenPi fan."
  fi
else
  log "[22_argon_one] curl/bash missing; falling back to FrankenPi fan."
fi

# ---- Fallback: FrankenPi fan control ----
# Install our simple fan service if not present
if [ ! -f /etc/systemd/system/frankenpi-argon-fan.service ]; then
  cat >/etc/systemd/system/frankenpi-argon-fan.service <<'UNIT'
[Unit]
Description=FrankenPi Argon Fan Control
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/frankenpi-argon-fan.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT
fi

if [ ! -x /usr/local/bin/frankenpi-argon-fan.sh ]; then
  cat >/usr/local/bin/frankenpi-argon-fan.sh <<'SH'
#!/bin/sh
# Simple SoC temp-based fan control (works for many Argon One cases)
# Tune these if needed:
MIN_DUTY=40   # %
MAX_DUTY=100  # %
T1=45         # °C start ramp
T2=65         # °C full
while :; do
  TEMP_C=$(awk '{print $1/1000}' /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 50)
  if [ "$TEMP_C" -lt "$T1" ]; then duty=$MIN_DUTY
  elif [ "$TEMP_C" -gt "$T2" ]; then duty=$MAX_DUTY
  else duty=$(( MIN_DUTY + ( (TEMP_C - T1) * (MAX_DUTY - MIN_DUTY) / (T2 - T1) ) ))
  fi
  # If argononed exists, let it set duty (many installs provide this tool)
  if command -v argononed >/dev/null 2>&1; then
    argononed --set "$duty" >/dev/null 2>&1 || true
  fi
  sleep 5
done
SH
  chmod +x /usr/local/bin/frankenpi-argon-fan.sh
fi

svc_enable frankenpi-argon-fan.service || true
svc_start  frankenpi-argon-fan.service || true
log "[22_argon_one] FrankenPi fan control enabled."
