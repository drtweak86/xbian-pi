#!/usr/bin/env bash
set -euo pipefail

# =============================
# XBian-Pi Installer – The Full Shebang
# =============================
# Features:
#  - Install all assets + phases to /opt/xbian-pi
#  - Configure cron + systemd firstboot
#  - Optional immediate phase execution with progress bar + spinner
# =============================

# --- color setup ---
RED=$(tput setaf 1 || true)
GREEN=$(tput setaf 2 || true)
YELLOW=$(tput setaf 3 || true)
BLUE=$(tput setaf 4 || true)
RESET=$(tput sgr0 || true)
BOLD=$(tput bold || true)

# --- spinner for sub-steps ---
spinner() {
  local pid=$1
  local spin='-\|/'
  local i=0
  tput civis
  while kill -0 $pid 2>/dev/null; do
    i=$(( (i+1) %4 ))
    printf "\r${YELLOW}${spin:$i:1}${RESET} "
    sleep 0.1
  done
  tput cnorm
}

# --- progress bar ---
progress_bar() {
  local progress=$1 total=$2 width=40
  local filled=$(( progress * width / total ))
  local empty=$(( width - filled ))
  printf "\r[${GREEN}"
  printf "%0.s#" $(seq 1 $filled)
  printf "${RESET}"
  printf "%0.s " $(seq 1 $empty)
  printf "] %3d%%" $(( progress * 100 / total ))
}

# --- ensure correct user ---
if [ "$(id -un)" != "xbian" ] || [ "$(id -u)" -ne 1000 ]; then
  echo "${RED}[install] Please run as user 'xbian' (default XBian user).${RESET}"
  exit 1
fi

# --- paths & vars ---
SRC="$(cd "$(dirname "$0")" && pwd)"
DST="/opt/xbian-pi"
LOG="/var/log/xbian-install.log"
RUN_MODE="${1:-install}"   # modes: install | all | phase:<name>

echo "${BOLD}${BLUE}== XBian-Pi Installer ==${RESET}"
echo "[install] Source: $SRC"
echo "[install] Destination: $DST"
echo "[install] Mode: $RUN_MODE"
sleep 1

# --- helper to copy folders with spinner ---
copy_with_spinner() {
  local src="$1" dst="$2"
  echo -n "[install] Syncing ${src##*/} -> ${dst} ..."
  (
    if command -v rsync >/dev/null 2>&1; then
      sudo rsync -a "$src/" "$dst/"
    else
      sudo mkdir -p "$dst"
      sudo cp -r "$src/." "$dst/"
    fi
  ) & spinner $!
  echo " ${GREEN}done${RESET}"
}

# --- create destination + copy assets ---
sudo mkdir -p "$DST"
for d in phases assets cron; do
  [ -d "$SRC/$d" ] && copy_with_spinner "$SRC/$d" "$DST/$d"
done

# --- cron setup ---
echo -n "[install] Checking cron..."
(
  if ! command -v cron >/dev/null 2>&1 && ! command -v crond >/dev/null 2>&1; then
    sudo apt-get update -y && sudo apt-get install -y --no-install-recommends cron
  fi
) & spinner $!
echo " ${GREEN}ok${RESET}"

if [ -f "$SRC/cron/xbian-pi" ]; then
  sudo install -m 0644 "$SRC/cron/xbian-pi" /etc/cron.d/xbian-pi
elif [ -f "$SRC/cron/osmc-oneclick" ]; then
  sudo install -m 0644 "$SRC/cron/osmc-oneclick" /etc/cron.d/xbian-pi
fi
sudo chmod 644 /etc/cron.d/xbian-pi 2>/dev/null || true
sudo service cron reload >/dev/null 2>&1 || sudo service cron restart >/dev/null 2>&1 || true
sudo update-rc.d cron defaults >/dev/null 2>&1 || true

# --- immediate execution modes ---
PHASES_DIR="$SRC/phases"
if [ "$RUN_MODE" = "all" ] || [[ "$RUN_MODE" == phase:* ]]; then
  echo "${BOLD}${BLUE}[install] Running phases immediately...${RESET}"
  phases=( "$PHASES_DIR"/*.sh )
  total=${#phases[@]}
  count=0
  echo "${YELLOW}Progress:${RESET}"

  if [ "$RUN_MODE" = "all" ]; then
    for s in "${phases[@]}"; do
      ((count++))
      progress_bar "$count" "$total"
      name=$(basename "$s")
      echo -ne " ${YELLOW}$name${RESET}"
      (
        chmod +x "$s" || true
        bash "$s" >>"$LOG" 2>&1 || echo "[WARN] $name failed ($?)"
      ) & spinner $!
      sleep 0.3
    done
  else
    PHASE="${RUN_MODE#phase:}"
    PHASE_FILE="$PHASES_DIR/${PHASE}.sh"
    if [ -f "$PHASE_FILE" ]; then
      echo "[phase] Running $PHASE_FILE"
      (
        chmod +x "$PHASE_FILE" || true
        bash "$PHASE_FILE" >>"$LOG" 2>&1 || echo "[WARN] $PHASE_FILE failed ($?)"
      ) & spinner $!
    else
      echo "${RED}[install] Phase ${PHASE} not found!${RESET}"
      exit 1
    fi
  fi
  echo -e "\n${GREEN}[install] All requested phases complete.${RESET}"
  echo "[log] See $LOG"
  exit 0
fi

# --- create firstboot runner ---
sudo tee /boot/firstboot.sh >/dev/null <<'SH'
#!/usr/bin/env bash
set -euo pipefail
LOG=/home/xbian/firstboot.log
PHASES="/opt/xbian-pi/phases"
exec >>"$LOG" 2>&1
echo "=== xbian-pi firstboot $(date) ==="
if [ -d "$PHASES" ]; then
  for s in "$PHASES"/*.sh; do
    [ -e "$s" ] || continue
    chmod +x "$s" || true
    echo "[firstboot] Running $(basename "$s")"
    if ! bash "$s"; then
      echo "[WARN] $(basename "$s") failed with $?"
    fi
  done
else
  echo "[firstboot] No phases dir found"
fi
echo "firstboot done"
SH
sudo chmod +x /boot/firstboot.sh
sudo chown root:root /boot/firstboot.sh

# --- systemd one-shot firstboot service ---
if command -v systemctl >/dev/null 2>&1; then
  sudo tee /etc/systemd/system/xbian-firstboot.service >/dev/null <<'UNIT'
[Unit]
Description=XBian one-time phase runner
After=network-online.target
Wants=network-online.target
ConditionPathExists=/boot/firstboot.sh
ConditionPathExists=!/boot/firstboot.done

[Service]
Type=oneshot
ExecStart=/boot/firstboot.sh
ExecStartPost=/bin/touch /boot/firstboot.done
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
UNIT
  sudo systemctl daemon-reload
  sudo systemctl enable xbian-firstboot.service
else
  sudo mkdir -p /etc/boot.d
  sudo tee /etc/boot.d/99-xbian-firstboot >/dev/null <<'SH'
#!/bin/sh
if [ -x /boot/firstboot.sh ] && [ ! -f /boot/firstboot.done ]; then
  /boot/firstboot.sh || true
  touch /boot/firstboot.done
fi
SH
  sudo chmod +x /etc/boot.d/99-xbian-firstboot
fi

echo -e "\n${GREEN}[✔] Install complete.${RESET}"
echo "Log file: $LOG"
echo "To run all phases immediately: ${BOLD}bash install_xbian.sh all${RESET}"
echo "To run a single phase: ${BOLD}bash install_xbian.sh phase:22_argon_one${RESET}"
echo "Reboot when ready: ${BOLD}sudo reboot${RESET}"
