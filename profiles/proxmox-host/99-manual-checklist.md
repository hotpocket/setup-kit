# Proxmox host — manual checklist

Steps that can't (or shouldn't) be scripted.

## Before running any proxmox-host script

- [ ] Proxmox VE installed on the boot NVMe.
- [ ] Logged into Proxmox web UI as root from another machine on the LAN.
- [ ] Reachable via SSH.
- [ ] Storage pools created (example layout — adjust to your disks):
  - `local-zfs` — auto-created on Proxmox install (on the boot drive).
  - any extra data/backup pools — `zpool create <name> /dev/disk/by-id/<your-disk>`
  - Add as Proxmox storage in: Datacenter → Storage → Add → ZFS

## After 01-grub-iommu.sh

- [ ] Reboot.
- [ ] Verify: `dmesg | grep -E 'AMD-Vi|IOMMU'` shows "IOMMU enabled" or similar.
- [ ] Verify: `find /sys/kernel/iommu_groups/ -type l | sort -V` shows groups exist.
- [ ] The passthrough GPU should be in **its own IOMMU group** (or at least a group only containing the GPU + its audio function). If it's sharing with other devices (USB controllers, NVMe, etc.), you'll need the ACS override patch:
  - Add `pcie_acs_override=downstream,multifunction` to GRUB_CMDLINE_LINUX_DEFAULT
  - Note: ACS override reduces security isolation. Acceptable for homelab use.

## After 02-vfio-bind.sh

- [ ] Reboot.
- [ ] Verify the GPU is bound to vfio-pci:
  ```bash
  lspci -nnk | grep -A3 -iE 'vga|3d|audio'
  ```
  Look for "Kernel driver in use: vfio-pci" on both the VGA and the audio function.
- [ ] If still bound to nouveau or nvidia: check `dmesg` for module load order issues.

## Before 04-create-workstation-vm.sh

- [ ] **Edit the script first.** Verify:
  - `VMID`, `VM_NAME` — fine as-is or change.
  - `GPU_PCI` — set to the actual PCI bus address of your GPU (`lspci | grep -iE 'vga|3d'`).
  - `ISO_PATH` — upload Ubuntu 26.04 ISO via Proxmox UI first; path is shown there.
  - `DISK_GB` — workstation VM size. 400 GB is generous; lower if you want.
- [ ] Decide on USB passthrough strategy:
  - Easiest: pass through a single USB controller. Find with `lspci | grep -i usb`.
  - Edit the `hostpci1` line in the script accordingly.

## After VM is created and Ubuntu installed

- [ ] Remove the install ISO: `qm set <VMID> --boot order=scsi0` then in UI: Hardware → CD/DVD Drive → Remove.
- [ ] Install qemu-guest-agent inside the VM: `apt install qemu-guest-agent`.
- [ ] Verify GPU is detected inside the VM: `lspci | grep -iE 'vga|3d'` should show it.
- [ ] Install the GPU driver inside the VM (NOT on the host): `ubuntu-drivers autoinstall`.
- [ ] Reboot the VM. Display output should now drive your monitor.
- [ ] Provision the VM with the workstation profile (see README):
      `curl -fsSL .../get.sh | bash -s -- workstation install`.

## Backup setup on the host

Once the workstation VM is running and validated:

- [ ] Schedule `vzdump` backups of the workstation VM in: Datacenter → Backup → Add.
  - Target: a backup pool/storage.
  - Schedule: daily, retain 7 daily / 4 weekly.
- [ ] Verify a backup runs successfully before relying on it.

## Off-host replication (optional)

If you run a second box, replicate the VM's snapshots to a pool on that host. That's a separate setup step on the receiving side, not part of this checklist.
