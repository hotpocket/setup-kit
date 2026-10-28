# Memory and small-box resource safeguards

Phase 07 runs these idempotent checks for workstations and workers. `check`
reports drift and `[would]` actions; only `install` applies them. Calibration
uses fake HOME, command stubs and `KIT_MEMORY_ROOT`. The incident inventory
and before/after coverage are in `docs/reports/friend-box-memory-lessons.md`.

## /tmp on disk (`tmp_on_disk=yes`, default)

Ubuntu 26.04's vendor `tmp.mount` permits tmpfs to consume half of RAM.
Without a `/tmp` fstab entry, mask that unit so `/tmp` uses the root filesystem
at next reboot. Do not unmount or delete live scratch. An existing fstab disk
mount wins and is preserved without masking: a mask would block it too.
Beast-VM and ai-3090 already have dedicated ext4 mounts. An explicit tmpfs/ramfs
fstab entry, or a masked disk mount, is reported for human correction.
`tmp_on_disk=no` leaves policy alone.

Reconcile `/etc/tmpfiles.d/tmp.conf`: `/tmp` mode 1777, age 10 days;
`/var/tmp` age 30 days. Start the vendor cleanup timer if inactive; never run
immediate cleanup. Aging is not a space quota: clean unused job scratch when
the job ends, preserve active results. Doctor prints the live type and reboot
boundary; independent verify fails while `/tmp` remains tmpfs.

## Swap (`component_oom_zram=yes`, default)

Use detected MemTotal in MiB for zram; classify RAM rounded up to GiB
so reserved RAM does not misclassify a nominal 16 GiB box. Below 16 GiB: zram RAM/2, usable disk overflow at least RAM rounded up to GiB.
An 8 GiB box gets about 4 GiB zram plus 8 GiB disk. Zram is a logical limit,
not reserved RAM or guaranteed compression. It absorbs idle agent/browser
pages; disk handles incompressible spikes. Swap buys recovery room, not
permission for unlimited concurrent builds.

At/above 16 GiB, retain `min(RAM/4, 8192)` MiB zram and auto's zram-only
policy. Explicit `swap_policy=zram+disk` retains the previous 4 GiB disk minimum
there; never shrink an existing tier. **Existing disk swap is now preserved
under zram-only too:** warn and require a human to drain/disable it. An invalid
policy warns without changing disk swap. This avoids deleting a deliberately
provisioned overflow tier such as ai-3090's.

Zram stays zstd, priority 100; overflow uses -2. Keep page-cluster 0 and
Brandon's swappiness 10. Reconcile whole generator/sysctl files by content.
Never restart active zram for a size/config change: reboot to apply it.
A missing device can be started without draining live swap.

Measure aggregate active non-zram swap SIZE. Grow only known active regular
`/swap.img`, `/swapfile` or `/swap.setup-kit`, preserving its UUID. Otherwise
add missing capacity in an unused conventional file. Never format partitions
or overwrite unknown inactive files. Add one header page so usable swap meets
the target without repeated growth. Existing swap checks allow 1 MiB of
header/metadata overhead; a formatted nominal 8 GiB tier stays healthy.
Automatic allocation supports ext4/XFS;
CoW/other filesystems require manual setup. Write whole fstab, preserving
unrelated lines and UUID entries.

Before swapoff, re-read used bytes and MemAvailable. Require used bytes plus
512 MiB of desktop headroom; do not count logical free zram as physical RAM.
Unsafe/failed swapoff leaves the file intact. Require free disk for growth
plus `disk_headroom_gb` (10 by default). Failed growth attempts to reactivate
the old tier and reports a recovery failure. A quiet run may be needed.

## OOM selection and control services

The kernel kills processes; oomd kills cgroups. Current T3 already gives agent
launches `oom_score_adj=800` and separate scopes, and supplies `OOMPolicy=continue`
plus `ManagedOOMPreference=avoid` for its server. GNOME's packaged Shell unit
already has `OOMScoreAdjust=-1000`. Preserve these rather than adding another
killer or a blanket user exemption.

- Reconcile oomd duration 60s; check/set the live user@UID pressure limit 80%
  even when the duration file already exists. Restart only the oomd monitor.
- Reconcile dbus/dbus-broker and GNOME Shell oomd `avoid`; apply live preferences
  without restarting the session, including `configs=no`. T3's drop-in preserves
  `OOMPolicy=continue` and `avoid`; its agent scopes remain normal candidates.
- OpenSSH already protects its listener at -1000 and restores login children's
  original score. Preserve that; add only oomd `avoid` to SSH, with no negative
  service-wide score inherited by jobs. See [OpenSSH's Linux implementation](https://github.com/openssh/openssh-portable/blob/V_9_9_P2/openbsd-compat/port-linux.c#L231).
- Deb/snap tailscaled get kernel preference -500 (retain a stronger configured
  value) and oomd `avoid`. The kernel setting applies at next start/reboot;
  never restart remote-access daemons here. Verify reads MainPID's live proc
  score and accepts stronger protection. An active SSH socket is healthy
  before its listener PID exists; the native guard applies on activation.

`avoid` prefers other candidates; it is not immunity or recursive. User-owned
preferences apply when the monitored ancestor has the same owner (Ubuntu
monitors user@UID); a root-wide swap monitor can ignore them. Do not give
user@, app.slice or T3 a negative inherited adjustment. Upgrade old T3 versions
without scopes: a drop-in cannot create those scopes. Use current T3 or
`kit-heavy` for disposable heavy work.

## Small-box extras (`component_resource_guards=auto`)

Auto applies below the rounded 16 GiB boundary; yes/no overrides. Concrete reasons: indexing
large developer trees competes with agents for scarce RAM, VS Code/agents
need enough watches, and a noisy daemon must not fill the single disk/RAM.
`no` skips management; it does not undo previously applied limits or timers.
Choose it before the first install to opt out; later rollback is deliberate.

- Journald: SystemMaxUse 512M, SystemKeepFree 1G, RuntimeMaxUse 64M; rate
  interval 30s/burst 1000 (journald can scale burst with disk space). Restart
  journald after changed content; do not vacuum history. Arbitrary app logs
  and caches remain outside this cap.
- Discover installed Tracker/LocalSearch services. Keep search installed:
  CPUQuota 25% of one CPU, CPU/IO weight 20, MemoryHigh 192M, MemoryMax 256M,
  OOM score +600, RestartSec 30s, three starts/300s. Resource bounds apply
  live; execution/restart settings apply next activation. Large files can
  fail to index at this cap.
- Inotify floors: 524288 watches/512 instances; keep higher live limits.
  These ceilings do not preallocate memory.
- Doctor checks live disk headroom for `/` and `/tmp`; never deletes caches
  (they regrow, and hardlinks can overstate savings).
- A user timer records available RAM, swap tiers and aggregate agent/browser
  resident+swapped memory every minute in private daily CSVs under
  `$HOME/.local/state/setup-kit-memory`, retained 30 days. Requires a running
  user manager; T3's service installation provides linger for a control box.
- `kit-heavy COMMAND ...` serializes per-user heavy builds/browser suites via
  `$HOME/.cache/setup-kit-heavy.lock`, nice 10, OOM score +800, MemoryHigh 5/8
  RAM, MemoryMax 3/4 RAM. A transient user service owns/kills its tree on OOM.
  Pidfd guards watch both wrapper and caller: death or stop cancels the job,
  including an orphan wrapper; children cannot inherit
  the lock. Working directory/PATH are retained; stdin is closed. Pass extra
  environment as `kit-heavy env NAME=value COMMAND`. Wrap outermost commands;
  do not nest. This lock is separate from Beast's established app-specific lock.

Callers must use `kit-heavy`: provisioning cannot serialize arbitrary commands
or cap the aggregate of rootless containers. Limit container/agent/browser
concurrency to available RAM. Flutter tests, when wanted, use `-j 2`. The
friend's answer file disables Flutter/emulators, local models and TTS/media.
System-calm verification now includes user units and recent kernel OOM evidence,
without killing unknown processes or restarting critical services.

Primary references: [oomd](https://www.freedesktop.org/software/systemd/man/latest/systemd-oomd.service.html),
[cgroup preferences](https://www.freedesktop.org/software/systemd/man/latest/systemd.resource-control.html),
[kernel OOM scores](https://docs.kernel.org/filesystems/proc.html),
[tmpfiles](https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html),
[LocalSearch](https://gnome.pages.gitlab.gnome.org/localsearch/commandline.html).
