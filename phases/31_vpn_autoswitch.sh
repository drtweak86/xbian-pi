
#!/usr/bin/env bash
# Install wg-autoswitch to /usr/local/sbin and seed defaults for cron usage
set -euo pipefail

BIN="/usr/local/sbin/wg-autoswitch"
CONF="/etc/default/wg-autoswitch"
mkdir -p /etc/default

cat >"$BIN"<<'SH'
#!/usr/bin/env bash
set -euo pipefail
: "${MIN_DL_MBIT:=12}"
: "${MAX_RTT_MS:=80}"
: "${MAX_LOSS_PCT:=2}"
: "${TEST_BYTES:=$((4*1024*1024))}"
: "${PING_TARGET:=1.1.1.1}"

# Return current WireGuard interface name (if any)
current_iface() { wg show 2>/dev/null | awk '/interface:/{print $2; exit}'; }

# Measure RTT/loss via ping -I <iface>
probe_rtt_loss() {
  local iface="$1" line loss avg rtt
  line="$(ping -I "$iface" -c 3 -w 3 -n "$PING_TARGET" 2>/dev/null | tail -n2 || true)"
  loss="$(printf '%s\n' "$line" | sed -n 's/.* \([0-9.]\+\)% packet loss.*/\1/p')"
  avg="$(printf '%s\n' "$line" | sed -n 's/.*= \([0-9.]\+\)\/\([0-9.]\+\)\/.*/\2/p')"
  rtt="${avg%.*}"; [ -z "${rtt:-}" ] && rtt=9999
  [ -z "${loss:-}" ] && loss=0
  printf '%s %s\n' "$rtt" "$loss"
}

# Quick downlink estimate (MiB range fetch); returns integer Mbps
probe_throughput_mbit() {
  local iface="$1" url bytes start end dur_ms bits_per_s mbit
  bytes=$((4*1024*1024))
  for url in "http://speed.hetzner.de/100MB.bin" "http://ipv4.download.thinkbroadband.com/100MB.zip"; do
    start=$(date +%s%3N)
    if curl --interface "$iface" --silent --show-error --max-time 6 --range 0-$((bytes-1)) -o /dev/null "$url" 2>/dev/null; then
      end=$(date +%s%3N); dur_ms=$((end - start)); (( dur_ms < 1 )) && dur_ms=1
      bits_per_s=$(( bytes * 8000 / dur_ms )); mbit=$(( bits_per_s / 1000000 ))
      echo "$mbit"; return 0
    fi
  done
  echo "0"
}

# Prefer the .conf with highest throughput that meets rtt/loss thresholds
main() {
  shopt -s nullglob
  local best="" best_score=999999
  local cur="$(current_iface || true)"
  for cfg in /etc/wireguard/*.conf; do
    local name="${cfg##*/}"; name="${name%.conf}"
    # Bring up/down to test path
    [ "$cur" = "$name" ] || { [ -n "$cur" ] && wg-quick down "$cur" >/dev/null 2>&1 || true; wg-quick up "$name" >/dev/null 2>&1 || continue; cur="$name"; }
    read -r r l < <(probe_rtt_loss "$name")
    d="$(probe_throughput_mbit "$name")"
    # Simple score: lower is better
    s=$(( 10000 - d + r + (${l%.*} * 50) ))
    if (( s < best_score )); then best="$name"; best_score="$s"; fi
  done
  # Ensure we're on best
  if [ -n "$best" ] && [ "$cur" != "$best" ]; then
    [ -n "$cur" ] && wg-quick down "$cur" >/dev/null 2>&1 || true
    wg-quick up "$best" >/dev/null 2>&1 || true
  fi
}
main "$@"
SH
chmod 0755 "$BIN"

# seed default (edit later as you like)
cat >"$CONF"<<'CFG'
# wg-autoswitch defaults
MIN_DL_MBIT=12
MAX_RTT_MS=80
MAX_LOSS_PCT=2
PING_TARGET=1.1.1.1
CFG

echo "[31_vpn_autoswitch] Installed $BIN and /etc/default/wg-autoswitch"
