#!/bin/bash
# Enable IOMMU + reserve resources for PCI passthrough on the Proxmox host.
# Run AFTER fresh Proxmox install, BEFORE creating the workstation VM.

SCRIPT_NAME="proxmox-host-01-grub-iommu"
source "$(dirname "$0")/../../lib.sh"
require_root

GRUB_FILE=/etc/default/grub
PARAMS="amd_iommu=on iommu=pt video=efifb:off"

log "Configuring GRUB for AMD IOMMU + vfio handoff..."

if ! grep -q 'GRUB_CMDLINE_LINUX_DEFAULT' "$GRUB_FILE"; then
  echo 'ERROR: cannot find GRUB_CMDLINE_LINUX_DEFAULT in /etc/default/grub' >&2
  exit 3
fi

# Pull existing line.
current=$(grep '^GRUB_CMDLINE_LINUX_DEFAULT=' "$GRUB_FILE" | sed -E 's/^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"$/\1/')

# Idempotent: only add params that aren't there.
new="$current"
for p in $PARAMS; do
  key="${p%%=*}"
  if ! grep -qE "(^| )$key(=|$)" <<<"$new"; then
    new="$new $p"
  fi
done
new=$(echo "$new" | xargs)   # trim

if [[ "$new" == "$current" ]]; then
  log "GRUB already configured. No change."
else
  log "Old: $current"
  log "New: $new"
  cp "$GRUB_FILE" "$GRUB_FILE.bak-$(date +%s)"
  sed -Ei "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"$new\"|" "$GRUB_FILE"
  update-grub
fi

# Load required modules at boot.
mkdir -p /etc/modules-load.d
cat > /etc/modules-load.d/vfio.conf <<EOF
vfio
vfio_iommu_type1
vfio_pci
EOF

# Make sure these modules go in the initramfs (Proxmox uses initramfs-tools).
cat > /etc/modules-load.d/vfio-initramfs.conf <<EOF
vfio
vfio_iommu_type1
vfio_pci
EOF

# Ensure /etc/initramfs-tools/modules has them too.
for m in vfio vfio_iommu_type1 vfio_pci; do
  if ! grep -q "^$m\$" /etc/initramfs-tools/modules 2>/dev/null; then
    echo "$m" >> /etc/initramfs-tools/modules
  fi
done

update-initramfs -u -k all

log "Done. REBOOT required for kernel parameters to take effect."
log "After reboot, verify:  dmesg | grep -i 'iommu enabled'  AND  find /sys/kernel/iommu_groups/ | head"
