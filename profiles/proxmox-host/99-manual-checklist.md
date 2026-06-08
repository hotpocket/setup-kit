# Proxmox host — manual checklist

Steps that can't (or shouldn't) be scripted.

## Before running any proxmox-host script

- [ ] Proxmox VE installed on the 2 TB Gen4 NVMe (boot drive).
- [ ] Logged into Proxmox web UI as root from another machine on the LAN.
- [ ] Reachable via SSH.
- [ ] Storage pools created:
  - `local-zfs` — should be auto-created on Proxmox install (on the 2TB).
  - `home-pool` — manually `zpool create home /dev/disk/by-id/...970-EVO-Plus...`
  - `cold-pool` — manually `zpool create cold /dev/disk/by-id/...850-EVO...`
  - Add as Proxmox storage in: Datacenter → Storage → Add → ZFS

## After 01-grub-iommu.sh

- [ ] Reboot.
- [ ] Verify: `dmesg | grep -E 'AMD-Vi|IOMMU'` shows "IOMMU enabled" or similar.
- [ ] Verify: `find /sys/kernel/iommu_groups/ -type l | sort -V` shows groups exist.
- [ ] The GTX 1080 should be in **its own IOMMU group** (or at least a group only containing the 1080 + its audio function). If it's sharing with other devices (USB controllers, NVMe, etc.), you'll need the ACS override patch:
  - Add `pcie_acs_override=downstream,multifunction` to GRUB_CMDLINE_LINUX_DEFAULT
  - Note: ACS override reduces security isolation. Acceptable for homelab use.

## After 02-vfio-bind.sh

- [ ] Reboot.
- [ ] Verify the 1080 is bound to vfio-pci:
  ```bash
  lspci -nnk -d 10de:
  ```
  Look for "Kernel driver in use: vfio-pci" on both the VGA and the audio function.
- [ ] If still bound to nouveau or nvidia: check `dmesg` for module load order issues.

## Before 04-create-workstation-vm.sh

- [ ] **Edit the script first.** Verify:
  - `VMID`, `VM_NAME` — fine as-is or change.
  - `GPU_PCI` — set to actual PCI bus address of your 1080 (`lspci | grep -i nvidia`).
  - `ISO_PATH` — upload Ubuntu 26.04 ISO via Proxmox UI first; path is shown there.
  - `DISK_GB` — workstation VM size. 400 GB is generous; lower if you want.
- [ ] Decide on USB passthrough strategy:
  - Easiest: pass through a single USB controller. Find with `lspci | grep -i usb`.
  - Edit the `hostpci1` line in the script accordingly.

## After VM is created and Ubuntu installed

- [ ] Remove the install ISO: `qm set <VMID> --boot order=scsi0` then in UI: Hardware → CD/DVD Drive → Remove.
- [ ] Install qemu-guest-agent inside the VM: `apt install qemu-guest-agent`.
- [ ] Verify GPU is detected inside the VM: `lspci | grep -i nvidia` should show the 1080.
- [ ] Install NVIDIA driver inside the VM (NOT on the host): `ubuntu-drivers autoinstall`.
- [ ] Reboot the VM. Display output should now drive your monitor.
- [ ] Provision the VM with the workstation profile (see README):
      `curl -fsSL .../get.sh | bash -s -- workstation install`.

## Backup setup on the host

Once the workstation VM is running and validated:

- [ ] Schedule `vzdump` backups of the workstation VM in: Datacenter → Backup → Add.
  - Target: `cold-pool` (the 850 EVO).
  - Schedule: daily, retain 7 daily / 4 weekly.
- [ ] Verify a backup runs successfully before disassembling the X170 box.

## When the headless server comes up later

The workstation will replicate snapshots to the headless server's `tank` pool. That's a separate setup step on the headless side, not part of this checklist.
