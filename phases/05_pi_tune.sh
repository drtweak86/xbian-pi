
#!/usr/bin/env bash
# Raspberry Pi 4B media optimisation (include file in /boot/config.txt)
set -euo pipefail
say(){ echo "[oneclick][05_pi_tune] $*"; }

BOOT_CFG="/boot/config.txt"
[ -f /boot/firmware/config.txt ] && BOOT_CFG="/boot/firmware/config.txt"
CFG_DIR="$(dirname "$BOOT_CFG")/config.txt.d"
CFG_FILE="$CFG_DIR/99-media-tune.conf"

if ! grep -q "Raspberry Pi 4" /proc/device-tree/model 2>/dev/null; then
  say "Not a Raspberry Pi 4 — skipping."
  exit 0
fi

ARM_FREQ="${ARM_FREQ:-2000}"
GPU_FREQ="${GPU_FREQ:-750}"
OVER_VOLTAGE="${OVER_VOLTAGE:-6}"
GPU_MEM="${GPU_MEM:-320}"
DTO="${DTO:-vc4-kms-v3d,cma-512}"

clamp(){ local v=$1 lo=$2 hi=$3; [ "$v" -lt "$lo" ] && v=$lo; [ "$v" -gt "$hi" ] && v=$hi; echo "$v"; }
ARM_FREQ="$(clamp "$ARM_FREQ" 1500 2200)"
GPU_FREQ="$(clamp "$GPU_FREQ" 500 800)"
OVER_VOLTAGE="$(clamp "$OVER_VOLTAGE" -16 8)"
GPU_MEM="$(clamp "$GPU_MEM" 256 512)"

[ -f "${BOOT_CFG}.oneclick.bak" ] || cp -a "$BOOT_CFG" "${BOOT_CFG}.oneclick.bak" || true
mkdir -p "$CFG_DIR"
cat >"$CFG_FILE"<<EOF
arm_freq=${ARM_FREQ}
gpu_freq=${GPU_FREQ}
over_voltage=${OVER_VOLTAGE}
gpu_mem=${GPU_MEM}
dtoverlay=${DTO}
EOF

grep -Eq '^[[:space:]]*include[[:space:]]+config\.txt\.d/\*\.conf' "$BOOT_CFG" 2>/dev/null || {
  printf '\n# Include per-file configs (OneClick)\n[all]\ninclude config.txt.d/*.conf\n' >> "$BOOT_CFG"
}

say "Tuning staged in $CFG_FILE (reboot to apply)."
