#!/bin/bash
# Cap the ZFS ARC so VMs aren't starved of memory.
# 8 GB on a 64 GB host is the homelab consensus.

SCRIPT_NAME="restore-host-03-zfs-tune"
source "$(dirname "$0")/../../lib.sh"
require_root

ARC_MAX_BYTES=$((8 * 1024 * 1024 * 1024))   # 8 GiB
ARC_MIN_BYTES=$((4 * 1024 * 1024 * 1024))   # 4 GiB

log "Setting ARC max=$((ARC_MAX_BYTES / 1024 / 1024 / 1024))GiB min=$((ARC_MIN_BYTES / 1024 / 1024 / 1024))GiB"

cat > /etc/modprobe.d/zfs.conf <<EOF
options zfs zfs_arc_max=$ARC_MAX_BYTES
options zfs zfs_arc_min=$ARC_MIN_BYTES
EOF

# Apply live (won't reduce a larger current ARC — reboot for full effect).
echo $ARC_MAX_BYTES > /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null || true
echo $ARC_MIN_BYTES > /sys/module/zfs/parameters/zfs_arc_min 2>/dev/null || true

# Update initramfs so settings stick on next boot.
update-initramfs -u -k all

log "Done. Verify:  cat /sys/module/zfs/parameters/zfs_arc_max"
