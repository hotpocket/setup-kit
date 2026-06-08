#!/bin/bash
# Create the workstation VM in Proxmox via `qm`.
# Run AFTER 01-grub-iommu, 02-vfio-bind, and a reboot.

SCRIPT_NAME="restore-host-04-create-workstation-vm"
source "$(dirname "$0")/../../lib.sh"
require_root

# --- Tunables ---
VMID=100
VM_NAME="LinuxBeast"        # Keep current hostname for continuity
CORES=14                    # 16 phys cores; leave 2 for host
MEMORY_MB=49152             # 48 GB; leaves 16 GB for host + ARC
DISK_GB=400                 # Workstation VM root + /home, on rpool
ISO_PATH="local:iso/ubuntu-26.04-desktop-amd64.iso"   # adjust filename
GPU_PCI="0000:01:00"        # Bus address WITHOUT function — passes the device + audio together
USB_HOST_DEVICE_FILTERS=""  # Set to e.g. "usb-host,vendorid=0x046d,productid=0xc52b"
                            # OR pass a whole USB controller (preferred).

# --- Sanity checks ---
if qm status "$VMID" >/dev/null 2>&1; then
  log "VM $VMID already exists. Refusing to overwrite."
  log "If you want to recreate: qm destroy $VMID --purge --destroy-unreferenced-disks 1"
  exit 1
fi

# --- Create VM ---
log "Creating VM $VMID ($VM_NAME)..."

qm create "$VMID" \
  --name "$VM_NAME" \
  --memory "$MEMORY_MB" \
  --cores "$CORES" \
  --cpu host \
  --sockets 1 \
  --bios ovmf \
  --machine q35 \
  --efidisk0 "local-zfs:0,format=raw,efitype=4m,pre-enrolled-keys=0" \
  --scsihw virtio-scsi-single \
  --net0 "virtio,bridge=vmbr0,firewall=1" \
  --ostype l26 \
  --agent enabled=1 \
  --boot "order=scsi0;ide2" \
  --ide2 "$ISO_PATH,media=cdrom"

# Main disk — on local-zfs (the workstation's 2TB NVMe rpool).
qm set "$VMID" --scsi0 "local-zfs:$DISK_GB,format=raw,discard=on,iothread=1,ssd=1"

# PCI passthrough for the GTX 1080.
# x-vga=1 = use this as primary VGA (host doesn't draw to monitor through it).
# pcie=1 = use PCIe instead of legacy PCI.
qm set "$VMID" --hostpci0 "$GPU_PCI,pcie=1,x-vga=1"

# Optional: pass through USB devices for keyboard/mouse.
# Run `lsusb` on the host to find vendor:product IDs.
# qm set "$VMID" --usb0 "host=046d:c52b"     # Logitech receiver example
# qm set "$VMID" --usb1 "host=05ac:024f"     # Apple keyboard example
# BETTER: pass through an entire USB controller — find its PCI bus address
# via `lspci | grep -i usb` then:
# qm set "$VMID" --hostpci1 "0000:03:00.0,pcie=1"

log "VM $VMID created."
log
log "NEXT STEPS:"
log "  1. Connect monitor to the 1080's HDMI/DP output."
log "  2. Edit the USB passthrough lines in this script if you want keyboard/mouse in the VM."
log "  3. Start the VM:  qm start $VMID"
log "  4. Install Ubuntu 26.04 from the ISO."
log "  5. After install, edit boot order to remove the ISO:  qm set $VMID --boot order=scsi0"
log "  6. In the VM: clone setup-kit and run ./bootstrap.sh workstation install"
