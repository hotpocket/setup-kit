#!/bin/bash
# Capture network config including WiFi credentials. Treat output as secret.

SCRIPT_NAME="capture-06-network-secrets"
source "$(dirname "$0")/../lib.sh"
require_user

OUT="$SNAPSHOT_DIR/network"
mkdir -p "$OUT"
chmod 700 "$OUT"   # WiFi PSKs live here

log "Capturing network state..."
log "WARNING: WiFi passwords and other secrets are stored in $OUT — protect this directory."

# Almost everything here needs root. Detect sudo upfront.
HAVE_SUDO=0
if sudo -n true 2>/dev/null; then
  HAVE_SUDO=1
elif [[ $EUID -eq 0 ]]; then
  HAVE_SUDO=1   # script was invoked via `sudo bash 06-...`
fi

# Helper: copy with sudo if available, otherwise miss-log.
sudo_copy() {
  local src="$1" dst="$2"
  if [[ ! -e "$src" ]]; then return 0; fi
  if (( HAVE_SUDO )); then
    if sudo cp -r "$src" "$dst" 2>>"$LOG_DIR/${SCRIPT_NAME}.log"; then
      sudo chown -R "$USER:$USER" "$dst" 2>/dev/null
      log "copied: $src"
    else
      miss "network: $src (sudo cp failed)"
    fi
  else
    miss "network: $src (needs sudo — rerun script with: sudo -E bash $0)"
  fi
}

sudo_copy /etc/NetworkManager/system-connections "$OUT/NM-system-connections"
[[ -d "$OUT/NM-system-connections" ]] && {
  chmod 700 "$OUT/NM-system-connections"
  chmod 600 "$OUT/NM-system-connections"/*.nmconnection 2>/dev/null
  log "NM profiles: $(ls "$OUT/NM-system-connections" 2>/dev/null | wc -l)"
}

sudo_copy /etc/netplan                       "$OUT/netplan"
sudo_copy /etc/network/interfaces            "$OUT/interfaces"
sudo_copy /etc/resolv.conf                   "$OUT/resolv.conf"
sudo_copy /etc/systemd/resolved.conf         "$OUT/resolved.conf"
sudo_copy /etc/systemd/resolved.conf.d       "$OUT/resolved.conf.d"
sudo_copy /etc/wireguard                     "$OUT/wireguard"
[[ -d "$OUT/wireguard" ]] && {
  chmod 700 "$OUT/wireguard"
  chmod 600 "$OUT/wireguard"/*.conf 2>/dev/null
}
sudo_copy /etc/openvpn                       "$OUT/openvpn"
[[ -d "$OUT/openvpn" ]] && chmod 700 "$OUT/openvpn"

# /etc/hosts is world-readable, no sudo needed.
cp /etc/hosts "$OUT/hosts" 2>>"$LOG_DIR/${SCRIPT_NAME}.log" \
  || miss "network: /etc/hosts (unreadable?)"

# Live state — works without sudo.
ip -br addr > "$OUT/ip-addr.txt"
ip route > "$OUT/ip-route.txt"
nmcli connection show > "$OUT/nmcli-connections.txt" 2>/dev/null || true

if (( HAVE_SUDO == 0 )); then
  log "NOTE: sudo unavailable — secret material NOT captured. Rerun: sudo -E bash $0"
fi
log "Done. Artifacts in $OUT (mode 700 — protect this)."
