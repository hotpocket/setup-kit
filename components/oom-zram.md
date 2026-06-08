# oom-zram — default component (workstation profile)

Memory-pressure hardening for any desktop machine: zram swap (in-RAM,
compressed, zero SSD writes) + systemd-oomd tuning + session-bus shield.
Without it, Ubuntu's stock config force-logs-out the whole GNOME session
under memory pressure — happened on LinuxBeast 2026-06-05 22:11 (Chrome 8G +
4 Claude Code terminals, 31G RAM, no swap → oomd killed user `dbus.service`
→ session collapse, all apps lost).

**Constraint (owner preference): NO disk swap, ever** — SSD-wear concern.
`#/swapfile` in fstab stays commented out. zram is the only acceptable swap.

Working reference script (applied + verified on LinuxBeast 2026-06-05):
`~/git/tmp/fix-oom-setup.sh` — fold into the workstation provisioning stage.

## What it does (4 parts)

1. **zram** — `apt install systemd-zram-generator` +
   `/etc/systemd/zram-generator.conf`:
   ```ini
   [zram0]
   zram-size = 8192
   compression-algorithm = zstd
   swap-priority = 100
   ```
   TODO for setup-kit: derive `zram-size` from RAM (e.g. `min(ram/4, 8192)`)
   instead of hardcoding 8G.
2. **sysctl** — `/etc/sysctl.d/99-zram.conf`: `vm.page-cluster = 0`
   (single-page swap-ins; standard zram pairing).
3. **Soften oomd** — Ubuntu default kills the user slice at 50% pressure /
   20s, far too trigger-happy on swapless boxes. Raise to 80% / 60s:
   - `systemctl set-property user@1000.service ManagedOOMMemoryPressureLimit=80%`
     (live + persistent; avoids restarting user@.service which would log
     the user out — do NOT use a template drop-in + restart on a live box)
   - `/etc/systemd/oomd.conf.d/20-longer-duration.conf`:
     `[OOM]` `DefaultMemoryPressureDurationSec=60s`, then
     `systemctl restart systemd-oomd` (safe, monitor daemon only)
   - TODO: parameterize the uid in `user@1000.service` for multi-user.
4. **Shield the session bus** (user-level, no sudo) —
   `~/.config/systemd/user/dbus.service.d/oomd-avoid.conf`:
   ```ini
   [Service]
   ManagedOOMPreference=avoid
   ```
   then `systemctl --user daemon-reload`. This is the part that prevents
   force-logout: oomd may still kill Chrome/terminals, never dbus.
   NOTE: user-level config → belongs in `.configs` (it lives under
   `~/.config`), but the kit must doctor-check it exists.

## Verify

- `swapon --show` → `/dev/zram0  partition  8G  prio 100`
- `oomctl` → user-slice `Memory Pressure Limit: 80.00%`, duration `1min`
- `python3 -c "import os; print(os.getxattr('/sys/fs/cgroup' +
  open('/proc/self/cgroup').read().split('::')[1].strip().rsplit('/',1)[0] +
  '/dbus.service', 'user.oomd_avoid'))"` → `b'1'` (or just getfattr on the
  dbus.service cgroup)

## Profile placement

- `workstation` profile: all 4 parts, default-on (doctor/install convention).
- `proxmox-host` profile: parts 1–2 only (no GNOME session on the host);
  the main VM gets the full set via its workstation provisioning.
