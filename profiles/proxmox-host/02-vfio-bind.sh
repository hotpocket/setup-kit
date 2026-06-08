#!/bin/bash
# Bind the passthrough dGPU (and its HDMI audio function) to vfio-pci so the
# host doesn't grab it. Required before passing through to the workstation VM.

SCRIPT_NAME="proxmox-host-02-vfio-bind"
source "$(dirname "$0")/../../lib.sh"
require_root

# *** EDIT THESE for your card *** — find with: lspci -nn | grep -iE 'nvidia|amd/ati'
# A card reports a VGA id + an audio id; pass both. Verify on YOUR system.
# Example (GTX 1080 FE): 10de:1b80 (VGA) + 10de:10f0 (audio) — yours will differ.
GPU_IDS="10de:1b80,10de:10f0"

log "Binding PCI IDs to vfio-pci: $GPU_IDS"
log "If wrong, the host won't render or the VM won't see the GPU."

cat > /etc/modprobe.d/vfio.conf <<EOF
options vfio-pci ids=$GPU_IDS disable_vga=1
EOF

# Blacklist nouveau and nvidia on the host (so they don't claim the dGPU).
cat > /etc/modprobe.d/blacklist-nvidia.conf <<EOF
blacklist nouveau
blacklist nvidia
blacklist nvidia_drm
blacklist nvidia_modeset
blacklist nvidiafb
EOF

# Ensure vfio-pci loads before nvidia/nouveau would.
cat > /etc/modprobe.d/vfio-precedence.conf <<EOF
softdep nouveau pre: vfio-pci
softdep nvidia pre: vfio-pci
softdep nvidia_drm pre: vfio-pci
EOF

update-initramfs -u -k all

log "Done. REBOOT to apply."
log "After reboot, verify the GPU is bound to vfio-pci:"
log "  lspci -nnk | grep -A3 -iE 'vga|3d|audio'"
log "  Look for 'Kernel driver in use: vfio-pci'"
