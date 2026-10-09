# Proxmox: PCI passthrough by resource mapping (linuxbeast2)

2026-10-09. Live on `linuxbeast2` (192.168.5.54, PVE 9.2.11, qemu-server 9.2.7,
kernel 7.0.14-15). Not yet in `profiles/proxmox-host/` — see **Gaps**.

## Why

VMs passed devices through by **bus address** (`hostpci0: 0000:79:00.0`). The
firmware numbers buses by counting devices at boot, so adding or unpowering a
device renumbers everything behind it. Two failures from one hardware change:

- **VM refuses to start.** A new NVMe (Samsung 9100 PRO, now `02:00.0`) pushed
  the AMD-side buses +1: iGPU `79→7a`, ASM4242 USB `77→78`. VM 101 onboot:
  `no PCI device found for '0000:79:00.1'`.
- **VM takes the wrong device.** First boot after install, the 3090 had no
  power cable, so the NVMe enumerated at `01:00` — VM 102's address — and 102
  grabbed the raw drive. No error; a bus address carries no identity.

The class: *every place that names a passthrough device by bus address.*

## What's on the box now

**Resource mappings** (`/etc/pve/mapping/pci.cfg`, Datacenter → Resource
Mappings → PCI). VMs name the mapping; the mapping holds path + identity.

| mapping | path | id | VM |
|---|---|---|---|
| `igpu` | `0000:7a:00.0` | `1002:13c0` | 101 hostpci0 (`romfile=vbios_9950x.bin`) |
| `igpu-audio` | `0000:7a:00.1` | `1002:1640` | 101 hostpci1 (`romfile=AMDGopDriver.rom`) |
| `hd-audio` | `0000:7a:00.6` | `1022:15e3` | 101 hostpci2 |
| `usb-asm4242` | `0000:78:00.0` | `1b21:2426` | 101 hostpci3 |
| `rtx3090` | `0000:01:00` (all functions) | `10de:2204` | 102 hostpci0 |

Each map also carries `iommugroup` and `subsystem-id`. **Both are mandatory in
practice:** PVE's `assert_valid` (`PVE/Mapping/PCI.pm`) dies with `missing
expected property` if the device has one and the mapping omits it — so a
mapping without them makes the VM unstartable. At VM start PVE compares id,
iommugroup and subsystem-id against the live device and refuses on mismatch
(`PCI device mapping invalid (hardware probably changed)`). That closes the
wrong-device failure.

**`pci-remap` boot service** (`/usr/local/sbin/pci-remap`,
`pci-remap.service`, `Before=pve-guests.service`). Before guests autostart, it
finds each device by vendor:device ID, reads iommugroup/subsystem-id from
sysfs, and rewrites any mapping whose values moved. That closes the
won't-start failure. If an ID matches zero or several devices it **skips** that
mapping, so the stale one stays and PVE refuses that VM rather than guess.
Dry-run unless `--apply`.

Source: `$GIT_HOME/tmp/proxmox/pci-remap/` — `pci-remap`, `pci-remap.service`,
`install.sh` (idempotent: dry run → abort on SKIP → back up VM confs → install
+ enable service → apply → `pvesh get /cluster/mapping/pci --check-node` → abort
on any error → `qm set` both VMs), `explore.sh` (read-only preflight; runs PVE's
own `assert_valid` against the proposed mappings without writing them).

Backup of pre-change configs: `/root/pci-remap-backup/20261009-132448/`.

## Verified

- `explore.sh`: all 5 proposed mappings `VALID` under PVE's `assert_valid`;
  `romfile` coexists with `mapping` (only `host` + `mapping` are exclusive,
  `QemuServer/PCI.pm:442`); each ID matches exactly one device; all bound to
  `vfio-pci`.
- Install: `--check-node` reported no errors; both VMs restarted on mappings.
- Host `shutdown -h` + cold boot: `pci-remap` ran before `pve-guests`, 5× `ok`,
  both VMs autostarted.

**Not yet exercised on real hardware:** the `move` path (an actual bus shift).
After the next card add/remove, check
`journalctl -b -u pci-remap -u pve-guests` for `move` lines and both VMs up.

## Expected noise (benign)

VM 101 start always prints these; it starts anyway:

- `failed to reset PCI device '0000:7a:00.0'` — AMD iGPUs don't support reset.
- `Cannot reset device 0000:7a:00.6, depends on group 29 which is not owned` —
  the reset would touch IOMMU group 29, which isn't passed through (members
  not yet listed: `ls /sys/kernel/iommu_groups/29/devices/`).

## Gaps for setup-kit

- `profiles/proxmox-host/04-create-workstation-vm.sh` still sets
  `GPU_PCI="0000:01:00"` and `hostpci0 "$GPU_PCI,..."` — a member of the same
  class. A new host built from the kit gets bus-address passthrough.
- `pci-remap` lives in the `tmp` repo; its natural home is a
  `profiles/proxmox-host/` phase (with the device list moved to host config).
- `99-manual-checklist.md` has no step for mappings, or for re-checking
  `journalctl -u pci-remap` after hardware changes.
- Adding a device to the mappings means editing the `MAPS` list in `pci-remap`
  and running `install.sh` again (plus a `qm set` line for the new hostpci).
