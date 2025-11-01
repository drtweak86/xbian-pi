
#!/usr/bin/env bash
set -euo pipefail
echo "[argon] Setting up Argon One (Pi4) if present"

grep -q "Raspberry Pi 4" /proc/device-tree/model 2>/dev/null || exit 0
curl -fsSL https://download.argon40.com/argon1.sh | bash || true
