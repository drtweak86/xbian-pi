
#!/usr/bin/env bash
set -euo pipefail
apt-get update -y || true
apt-get install -y --no-install-recommends curl iputils-ping jq ca-certificates || true

cat >/usr/local/sbin/if-speedtest <<'SH'
#!/usr/bin/env bash
set -euo pipefail
IFACE=""; BYTES=$((4*1024*1024)); TIMEOUT=6
while getopts ":i:b:t:" o; do case "$o" in i) IFACE="$OPTARG";; b) BYTES="$OPTARG";; t) TIMEOUT="$OPTARG";; esac; done
[ -n "$IFACE" ] || { echo "0"; exit 0; }
best=0
for url in "http://speed.hetzner.de/100MB.bin" "http://ipv4.download.thinkbroadband.com/100MB.zip"; do
  start=$(date +%s%3N)
  if curl --interface "$IFACE" --silent --show-error --max-time "$TIMEOUT" --range 0-$((BYTES-1)) -o /dev/null "$url" 2>/dev/null; then
    end=$(date +%s%3N); d=$((end-start)); (( d<1 )) && d=1
    mbit=$(( BYTES*8000/d/1000000 ))
    (( mbit>best )) && best=$mbit
  fi
done
echo "$best"
SH
chmod 0755 /usr/local/sbin/if-speedtest
echo "[33_install_speedtest] Installed /usr/local/sbin/if-speedtest"
