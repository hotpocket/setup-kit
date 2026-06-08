#!/bin/bash
# Fills in the bits the user-mode capture scripts couldn't read.
# Run AFTER the others: `sudo -E bash capture/99-sudo-extras.sh`
# It needs $SUDO_USER (set automatically by sudo) so files end up owned by you.

SCRIPT_NAME="capture-99-sudo-extras"
source "$(dirname "$0")/../lib.sh"

if [[ $EUID -ne 0 ]]; then
  echo "ERROR: must be run as root. Use: sudo -E bash $0" >&2
  exit 2
fi

TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"

log "Capturing sudo-only artifacts as root (target user: $TARGET_USER)..."

# 1. /etc/apt/auth.conf.d (Ubuntu Pro tokens etc).
if [[ -d /etc/apt/auth.conf.d ]]; then
  cp -r /etc/apt/auth.conf.d "$SNAPSHOT_DIR/apt/auth.conf.d" \
    && log "copied: /etc/apt/auth.conf.d" \
    || miss "sudo: /etc/apt/auth.conf.d"
fi

# 2. /etc/sudoers.d
if [[ -d /etc/sudoers.d ]]; then
  rm -rf "$SNAPSHOT_DIR/system/sudoers.d"
  cp -r /etc/sudoers.d "$SNAPSHOT_DIR/system/sudoers.d" \
    && log "copied: /etc/sudoers.d" \
    || miss "sudo: /etc/sudoers.d"
fi

# 3. Root crontab.
crontab -l > "$SNAPSHOT_DIR/system/crontab-root.txt" 2>/dev/null \
  || echo "(no root crontab)" > "$SNAPSHOT_DIR/system/crontab-root.txt"
log "captured: root crontab"

# 4. ufw status.
ufw status verbose > "$SNAPSHOT_DIR/system/ufw.txt" 2>/dev/null \
  || echo "(ufw not installed)" > "$SNAPSHOT_DIR/system/ufw.txt"
log "captured: ufw status"

# 5. iptables-save.
iptables-save > "$SNAPSHOT_DIR/system/iptables.txt" 2>/dev/null
log "captured: iptables-save"

# 6. blkid (for UUID-based fstab reconstruction).
blkid > "$SNAPSHOT_DIR/system/blkid.txt" 2>/dev/null
log "captured: blkid"

# 7. Network secrets (NM profiles, wireguard, openvpn).
NET="$SNAPSHOT_DIR/network"
mkdir -p "$NET"
for src_dst in \
  "/etc/NetworkManager/system-connections:$NET/NM-system-connections" \
  "/etc/netplan:$NET/netplan" \
  "/etc/network/interfaces:$NET/interfaces" \
  "/etc/resolv.conf:$NET/resolv.conf" \
  "/etc/systemd/resolved.conf:$NET/resolved.conf" \
  "/etc/systemd/resolved.conf.d:$NET/resolved.conf.d" \
  "/etc/wireguard:$NET/wireguard" \
  "/etc/openvpn:$NET/openvpn" \
; do
  src="${src_dst%%:*}"
  dst="${src_dst##*:}"
  [[ -e "$src" ]] || continue
  rm -rf "$dst"
  if cp -r "$src" "$dst" 2>>"$LOG_DIR/${SCRIPT_NAME}.log"; then
    log "copied: $src"
  else
    miss "sudo: $src"
  fi
done

# Tighten perms on secret material.
[[ -d "$NET/NM-system-connections" ]] && {
  chmod 700 "$NET/NM-system-connections"
  chmod 600 "$NET/NM-system-connections"/*.nmconnection 2>/dev/null
}
[[ -d "$NET/wireguard" ]] && {
  chmod 700 "$NET/wireguard"
  chmod 600 "$NET/wireguard"/*.conf 2>/dev/null
}
[[ -d "$NET/openvpn" ]] && chmod 700 "$NET/openvpn"
chmod 700 "$NET" 2>/dev/null

# 8. Hand the whole snapshot back to the user so they can read/edit it freely.
chown -R "$TARGET_USER:$TARGET_USER" "$SNAPSHOT_DIR"

log "Done. All sudo-required artifacts captured. Review $SNAPSHOT_DIR/logs/missing.log for anything still pending."
