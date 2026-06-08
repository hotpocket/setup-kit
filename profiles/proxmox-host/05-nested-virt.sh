#!/usr/bin/env bash
# Enable nested virtualization so guests get /dev/kvm — REQUIRED for the
# Android emulator (and any VM-in-VM) inside the workstation VM.
# Run on the Proxmox host. Idempotent.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../../lib.sh"

if grep -qi amd /proc/cpuinfo; then MOD=kvm_amd; else MOD=kvm_intel; fi

if [[ "$(cat /sys/module/${MOD}/parameters/nested 2>/dev/null)" =~ ^(1|Y)$ ]]; then
  log "nested virt already enabled (${MOD})"
else
  echo "options ${MOD} nested=1" > /etc/modprobe.d/kvm-nested.conf
  log "wrote /etc/modprobe.d/kvm-nested.conf — reload ${MOD} (or reboot):"
  log "  modprobe -r ${MOD} && modprobe ${MOD}   # requires all VMs stopped"
fi

cat <<'EOF'
Per-guest requirements (manual checklist):
  VM  : set CPU type to 'host'   (qm set <vmid> --cpu host)
        verify inside guest: ls -l /dev/kvm  &&  kvm-ok
  LXC : pass the device through — in /etc/pve/lxc/<ctid>.conf:
          dev0: /dev/kvm,gid=<kvm-gid-in-ct>
        (older syntax: lxc.cgroup2.devices.allow: c 10:232 rwm
                       lxc.mount.entry: /dev/kvm dev/kvm none bind,optional,create=file)
The workstation profile's doctor checks /dev/kvm and points back here.
EOF
