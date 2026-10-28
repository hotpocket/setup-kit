---
type: decision
date: 2026-10-27
concern: provisioning
summary: "8 GiB control boxes: disk /tmp, half-RAM zram + RAM-sized overflow, safe growth, separate OOM preferences, bounded background work/history and owner-bound kit-heavy; preserve existing big-box sizing and fstab mounts"
---

# Small control boxes need recovery room and owned work

Use the machine-level defaults in `components/oom-zram.md`. The full recorded
lesson sweep, source/coverage citations, changed files, calibration mutation
controls and existing-box effects are in
`docs/reports/friend-box-memory-lessons.md`.

Never mask an fstab-backed disk `/tmp`. Never restart active zram just to
resize it or assume its logical unused size is free physical RAM. Preserve
existing swap tiers; do not blindly swapoff or format unknown files/devices.
Nominal 16 GiB machines stay above the small-box boundary despite reserved RAM.

T3 scopes/+800 and GNOME's kernel preference already do part of the job.
Kernel process scores and oomd cgroup preferences are different mechanisms;
negative parent scores would also protect disposable children. Whole files
and live state both matter. A reload alone does not change a daemon's kernel
score. Prefer recovery paths that do not restart a user's session or access.

Heavy job guards must own work until cleanup finishes and release the queue
when the caller dies or stops. A raw inherited flock FD is insufficient.
Application checkpoints and daemon-owned containers still need their own
resource/lifecycle limits. Keep machine changes and operational limitations
explicit when applying these defaults to Brandon's existing boxes.
