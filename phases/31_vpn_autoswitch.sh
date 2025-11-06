#!/bin/sh
# FrankenPi: install & enable WireGuard autoswitcher
set -eu
. /usr/local/bin/frankenpi-compat.sh  # log, svc_*

BIN="/usr/local/sbin/wg-autoswitch"
CFG="/etc/default/wg-autoswitch"
SVC="/etc/systemd/system/frankenpi-vpn-autoswitch.service"
TMR="/etc/systemd/system/frankenpi-vpn-autoswitch.timer"
CRON="/etc/cron.d/frankenpi-vpn-autoswitch"

# --- install config (defaults; user can edit later) ---
mkdir -p /etc/default
if [ ! -f "$CFG" ]; then
  cat >"$CFG" <<'CFG'
# wg-autoswitch defaults
MIN_DL_MBIT=12
MAX_RTT_MS=80
MAX_LOSS_PCT=2
PING_TARGET=1.1.1.1
TEST_BYTES=$((4*1024*1024))
CFG
fi

# --- install autoswitch binary (POSIX sh) ---
cat >"$BIN" <<'SH'
#!/bin/sh
set -eu
CFG="/etc/default/wg-autoswitch"
[ -f "$CFG" ] && . "$CFG"

: "${MIN_DL_MBIT:=12}"
: "${MAX_RTT_MS:=80}"
: "${MAX_LOSS_PCT:=2}"
: "${TEST_BYTES:=$((4*1024*1024))}"
: "${PING_TARGET:=1.1.1.1}"

has(){ command -v "$1" >/dev/null 2>&1; }

current_iface() {
  wg show 2>/dev/null | awk '/interface:/{print $2; exit}'
}

probe_rtt_loss() {
  # prints: "<rtt_ms> <loss_pct>"
  iface="$1"
  out="$(ping -I "$iface" -c 3 -w 4 -n "$PING_TARGET" 2>/dev/null | tail -n2 || true)"
  loss="$(printf '%s\n' "$out" | sed -n 's/.* \([0-9.]\+\)% packet loss.*/\1/p')"
  avg="$(printf '%s\n' "$out" | sed -n 's/.*= \([0-9.]\+\)\/\([0-9.]\+\)\/.*/\2/p')"
  [ -z "$loss" ] && loss=100
  rtt="${avg%.*}"
  [ -z "$rtt" ] && rtt=9999
  printf '%s %s\n' "$rtt" "$loss"
}

probe_throughput_mbit() {
  iface="$1"
  bytes="${2:-$TEST_BYTES}"
  # Use curl timing to avoid date math
  for url in \
    "http://speed.hetzner.de/100MB.bin" \
    "http://ipv4.download.thinkbroadband.com/100MB.zip"
  do
    if has curl; then
      t="$(curl --interface "$iface" --silent --show-error --max-time 8 \
               --range 0:$((bytes-1)) -o /dev/null -w '%{time_total}' "$url" 2>/dev/null || echo 0)"
      # guard against 0 or empty
      awk -v B="$bytes" -v T="$t" 'BEGIN{
        if(T<=0){print 0; exit}
        print int((B*8)/(T*1000000))
      }' 2>/dev/null && return 0
    fi
  done
  echo 0
}

# score link quality: lower better (favor high DL, low RTT, low loss)
score_link() {
  dl="$1"; rtt="$2"; loss="$3"
  # Simple heuristic: 10000 - dl + rtt + loss*50
  awk -v D="$dl" -v R="$rtt" -v L="$loss" 'BEGIN{print int(10000 - D + R + (L*50))}'
}

main() {
  has wg-quick || exit 0
  cur="$(current_iface || true)"
  best=""
  best_score=999999

  for cfg in /etc/wireguard/*.conf; do
    [ -f "$cfg" ] || continue
    name="${cfg##*/}"; name="${name%.conf}"

    if [ "$cur" != "$name" ]; then
      [ -n "$cur" ] && wg-quick down "$cur" >/dev/null 2>&1 || true
      wg-quick up "$name" >/dev/null 2>&1 || continue
      cur="$name"
      # brief settle
      sleep 1
    fi

    set -- $(probe_rtt_loss "$name")
    rtt="$1"; loss="$2"
    dl="$(probe_throughput_mbit "$name" "$TEST_BYTES")"

    # thresholds: if too lossy/slow, demote via score
    s="$(score_link "$dl" "$rtt" "$loss")"
    # hard filter: if RTT > MAX_RTT or loss > MAX_LOSS or DL < MIN_DL => add penalty
    [ "$rtt"  -gt "$MAX_RTT_MS" ]   && s=$((s+5000))
    loss_i="${loss%.*}"
    [ "$loss_i" -gt "$MAX_LOSS_PCT" ] && s=$((s+5000))
    [ "$dl"    -lt "$MIN_DL_MBIT" ] && s=$((s+5000))

    if [ "$s" -lt "$best_score" ]; then
      best="$name"; best_score="$s"
    fi
  done

  if [ -n "$best" ] && [ "$cur" != "$best" ]; then
    [ -n "$cur" ] && wg-quick down "$cur" >/dev/null 2>&1 || true
    wg-quick up "$best" >/dev/null 2>&1 || true
  fi
}
main "$@"
SH
chmod 0755 "$BIN"

# --- systemd timer (preferred) ---
if command -v systemctl >/dev/null 2>&1; then
  cat >"$SVC" <<'UNIT'
[Unit]
Description=FrankenPi WireGuard Auto Switch
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-autoswitch
Nice=5
IOSchedulingClass=best-effort
UNIT

  cat >"$TMR" <<'UNIT'
[Unit]
Description=Run FrankenPi WG autoswitch periodically

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
UNIT

  svc_enable frankenpi-vpn-autoswitch.timer || true
  svc_start  frankenpi-vpn-autoswitch.timer || true

else
  # --- cron fallback (non-systemd) ---
  echo '*/5 * * * * root /usr/local/sbin/wg-autoswitch >/dev/null 2>&1' > "$CRON"
fi

log "[31_vpn_autoswitch] Installed $BIN and scheduled periodic switching"
