# Friend control box: memory and stability batch

Implemented on `feature/friend-box` in this worktree. Earlier uncommitted work
is retained. No commit, push, merge, host sudo, live provisioning or remote
machine changes. The only write outside the worktree is the explicitly
requested `../friend-host.conf` answer file.

## Lesson sweep

Read setup-kit's components, vault, docs, PROGRESS, system-calm verification
and worker headless phase; proxmox_setup_plan's vault and change manifest;
.configs' vault and user units; all matching Claude project memory notes.
Also inspected the Ubuntu SSH/user-manager/dbus/GNOME units, current T3's
installed binary and boot-service renderer. No indexer/inotify exhaustion
incident was recorded in those notes; those two additions have stated design
reasons rather than an invented incident.

Paths below are relative to setup-kit unless prefixed. `$GIT_HOME` names the
owner's Git root; new runtime code derives paths from KIT_DIR/HOME. Historical `HEAD:` citations
identify coverage before this batch; current code has moved into components.

- **applied-now** — `/tmp` tmpfs can consume half of RAM; move scratch to disk at reboot (source: `$GIT_HOME/proxmox_setup_plan/vault/decisions/2026-10-11-nvme9100-layout.md:83`; `components/tmp-on-disk.sh:5`).
- **applied-now** — an existing fstab `/tmp` disk mount wins; masking it would break it, so preserve it (same source `:87`; `components/tmp-on-disk.sh:9`).
- **applied-now** — disk scratch needs aged cleanup and space diagnosis, without deleting live results (source: `$HOME/.claude/projects/-home-brandon-git-accidentalcommune/memory/tmp-scratch-cleanup.md:13`; `components/tmp-on-disk.sh:29`, `components/resource-guards.sh:14`).
- **not-applicable** — application-specific review/deploy scratch deletion remains its owner's job; the provisioner cannot tell whether an arbitrary artifact is still needed (same scratch note `:11`; preservation rule: `$HOME/.claude/projects/-home-brandon-git-raise-the-bar/memory/keep-run-results.md:11`; `components/oom-zram.md:17`).
- **applied-before** — compressed zram, zstd and priority 100 cushion desktop pressure (`HEAD:profiles/workstation/07-components.sh:12`; now `components/oom-zram.sh:5`).
- **applied-before** — page-cluster 0 avoids pointless swap-in readahead (`HEAD:profiles/workstation/07-components.sh:41`; now `components/oom-zram.sh:27`; proxmox decision above `:25`).
- **applied-before** — Brandon requires swappiness 10: prefer RAM over early idle-page eviction (`HEAD:profiles/workstation/07-components.sh:51`; now `components/oom-zram.sh:32`).
- **applied-now** — small machines need more than quarter-RAM zram plus an unmeasured 4 GiB overflow: use half-RAM zram and disk >= rounded RAM (source: proxmox decision above `:35`, RAM and swap both full; `components/oom-zram.sh:5`, `:58`).
- **applied-now** — reserved RAM must not cause nominal 16 GiB boxes to receive small-box size/cap changes (`components/memory-common.sh:7`; concrete boundary reason, independently calibrated).
- **applied-before** — `swap_policy=zram+disk` lets ai-3090 retain its intentional overflow above the auto boundary (source: `$GIT_HOME/proxmox_setup_plan/vault/sessions/2026-10-11-ai-3090-swap-ram-disk-pause.md:19`; `HEAD:profiles/workstation/07-components.sh:81`).
- **applied-now** — never automatically delete an existing disk swap tier under zram-only; report the mismatch for deliberate human action (`components/oom-zram.sh:48`; the same ai-3090 policy incident).
- **applied-now** — live zram resizing and disk swapoff can themselves exhaust memory; defer active zram changes, check physical headroom before file growth, stop on swapoff failure (`components/oom-zram.sh:12`, `:78`, `:114`; concrete safety requirement).
- **applied-now** — unknown/ambiguous storage must not be formatted: touch only known active regular files with a readable preserved UUID, never swap partitions or unknown inactive files (source: proxmox session above `:29`, ambiguous blkid fast-swap finding; `components/oom-zram.sh:70`, `:91`).
- **applied-now** — free disk must cover real additional allocation plus reserve; an already allocated tail cannot count as disk that resizing will free (`components/oom-zram.sh:107`; concrete failure-path safety requirement).
- **not-applicable** — moving VM swap away from ZFS to a dedicated thin disk is a VM storage remedy; the OptiPlex has one disk, so use a regular ext4/XFS overflow file (source: proxmox decision above `:49`; unsupported CoW filesystems are reported, not reformatted).
- **not-applicable** — thick LVM swap broke whole-VM snapshots, so disk changes must check snapshot/backup/migration capabilities; this batch creates no VM disks or host storage (source: same decision `:65`).
- **applied-before** — oomd's 80%/60s policy avoids abrupt whole-session eviction (`HEAD:profiles/workstation/07-components.sh:62`; now `components/oom-order.sh:4`).
- **applied-now** — a duration file's presence did not prove correct content or the live 80% property; reconcile content and inspect/set the property independently (`components/oom-order.sh:4`).
- **applied-before** — dbus death collapses GNOME; a missing dbus oomd shield was already installed even with no .configs (`HEAD:profiles/workstation/07-components.sh:117`).
- **applied-now** — shield content/live state matters, and GNOME's own cgroup also needs oomd avoidance; reload/apply preferences without restarting the session (`components/oom-order.sh:20`, `:39`).
- **applied-before** — current upstream T3 raises agent launches to OOM score 800 and gives them separate scopes; retain that rather than protecting the entire user tree (installed CLI binary 0.1.2, embedded `packages/shared/src/AgentScope.ts`; documented in `components/oom-order.sh:24`).
- **applied-before** — T3's `OOMPolicy=continue` prevents one killed child from stopping the server; its service/linger survives closing the browser (`components/t3code.md:26`; `vault/sessions/2026-09-30 - thread consolidation (setup-kit).md:20`; upstream `$GIT_HOME/t3code/apps/server/src/cloud/bootService.ts:113`).
- **applied-before** — Ubuntu's GNOME Shell service already sets kernel OOM score -1000; do not duplicate or weaken it (`/usr/lib/systemd/user/org.gnome.Shell@.service:33`; `components/oom-order.sh:24`).
- **applied-before** — Linux OpenSSH protects only its listener at -1000 and restores login children's score; a negative service-wide override would change that restored baseline, so do not add one (compiled sshd markers and [upstream implementation](https://github.com/openssh/openssh-portable/blob/V_9_9_P2/openbsd-compat/port-linux.c#L231); `components/oom-order.sh:49`).
- **applied-before** — Ubuntu 26.04 socket-activates SSH, so an active socket can be healthy before the listener PID exists (`profiles/worker/03-headless.sh:39`); the independent verifier now honors this too.
- **applied-now** — SSH gets oomd avoidance; deb/snap tailscaled gets -500/avoid while preserving stronger settings; T3 keeps continue/avoid, with no negative user/T3 inheritance (`components/oom-order.sh:30`, `:47`).
- **applied-now** — reloaded unit settings do not prove the running daemon's kernel score; verify MainPID's proc value, with a reboot/next-start diagnostic (`verify.sh:483`).
- **applied-now** — size concurrency from peaks, not a single free-memory snapshot: bounded CPU-only memory history modeled on ai-3090's mem-log (source: proxmox session above `:22`; `components/memory-sample.py:18`, `components/resource-guards.sh:55`).
- **applied-now** — parallel builds/emulators/browser suites OOM-killed Chrome/Gradle and disrupted T3; `kit-heavy` serializes and nices heavy jobs, with a memory limit and disposable OOM score (sources: `$HOME/.claude/projects/-home-brandon-git-t3-voice/memory/one-heavy-job-at-a-time.md:10`, `$HOME/.claude/projects/-home-brandon-git-raise-the-bar/memory/beast-heavy-job-lock.md:14`; `components/heavy-job.py:18`, `:81`).
- **applied-now** — stopped holders and inherited orphan lock FDs blocked Beast's queue: pidfd-bound ownership, closed stdin, non-inherited lock, whole-job cleanup (same heavy-lock note `:16`, `:21`; `components/heavy-job.py:33`, `:61`).
- **applied-now** — leaked chatterbook test hooks held ai-3090's real pause lock across runs; new work wrapped in kit-heavy ends with its wrapper/caller, without signalling unowned production hooks (source: `$GIT_HOME/proxmox_setup_plan/docs/change-manifest.md:49`; `components/heavy-job.py:18`; existing application tests still need their own lifecycle discipline).
- **not-applicable** — a provisioner cannot retrofit app checkpoints, container removal or ownership rules into every existing job; use the guarded runner, keep application-specific guards/checkpoints, and do not kill unknown holders (source: proxmox session above `:23`, crash-safety rule; heavy-lock note `:21`; limitations in `components/oom-zram.md:115`).
- **applied-before** — failed/flapping services, journal warning storms, recent cores and optional load/fork churn were already measured (source: nvidia-cdi 1500+ restart incident in `verify.sh:540`; current checks `verify.sh:547`, `:572`, `:590`).
- **applied-now** — system-only calm checks miss user-service loops; now cover both managers and recent kernel OOM evidence (source: `$GIT_HOME/.configs/.config/systemd/user/tts-server.service:10`, 94 restarts; `verify.sh:547`).
- **applied-before** — .configs' TTS unit gates on its venv to avoid missing-interpreter respawn loops (`$GIT_HOME/.configs/.config/systemd/user/tts-server.service:13`); friend explicitly disables this workload.
- **applied-now** — journal storms must not consume the single disk or volatile RAM; small-box journal caps and rate controls bound it without vacuuming history (`components/resource-guards.sh:24`; concrete consequence of the recorded restart/journal noise).
- **applied-before** — provisioning checks disk headroom before downloading packages (`profiles/workstation/00-disk-space.sh:32`).
- **applied-now** — runtime root/tmp checks report regrowing-cache pressure without deleting caches (`components/resource-guards.sh:14`; source: `$HOME/.claude/projects/-home-brandon-git-tmp/memory/ai-3090-local-llm-test.md:11`, 95% full and hardlink overcount).
- **applied-now** — GNOME background indexing must share scarce RAM/CPU with agents: bound discovered Tracker/LocalSearch units, retain packages, rate-limit starts (`components/resource-guards.sh:43`; stated design reason, no prior indexer incident found).
- **applied-now** — VS Code/agent/watch-based tools need adequate inotify ceilings; raise floors without preallocation or lowering higher live limits (`components/resource-guards.sh:27`; stated design reason, .configs' watcher uses inotify but records no exhaustion incident).
- **not-applicable** — CUDA/local-model tests killed ai-3090's voice/desktop and consumed critical VRAM; friend has no GPU and explicitly disables local models/TTS, and this code never stops those services (sources: `$HOME/.claude/projects/-home-brandon-git-landry-bot-family/memory/pixal3d-preferred.md:15`, ai-3090 local-LLM note above `:11`).
- **not-applicable** — worker-only multi-user boot frees desktop RAM, but friend deliberately wants GNOME (`profiles/worker/03-headless.sh:15`).
- **not-applicable** — LinuxBeast2 USB/board hard hangs and Zenbuntu thermal power cuts were not OOM incidents; do not transplant USB/VFIO or laptop-specific RAPL settings to an OptiPlex (sources: `$HOME/.claude/projects/-home-brandon-git-tmp/memory/linuxbeast2-usb-freeze.md:52`; `vault/sessions/2026-07-10 - zenbuntu thermal forensics + RAPL-EPP defaults.md:16`).
- **not-applicable** — an unowned Chrome crash and audio units stopping during a GNOME restart do not establish OOM; keep kernel OOM evidence separate and avoid automatic recovery actions on unowned processes (source: `$GIT_HOME/.configs/vault/fleet/2026-10-13.md:15`; independent evidence check in `verify.sh:572`).

## Files in this batch

- `profiles/workstation/07-components.sh`: replace the old inline memory block with sourced memory components; worker's shared phase inherits them. Earlier component work after the docker marker is byte-for-byte retained.
- `components/memory-common.sh`: fake-root seam, rounded RAM class, content reconciliation and whole-file writes.
- `components/tmp-on-disk.sh`: respect fstab, mask only vendor tmpfs, reboot/live-type diagnosis and aged cleanup.
- `components/oom-zram.sh`: tier sizing, live zram checks, safe overflow growth/recovery and whole fstab persistence.
- `components/oom-order.sh`: content/live oomd repairs, session/T3 avoidance and remote-daemon kernel preference.
- `components/resource-guards.sh`: low-RAM journal/indexer/inotify guards, live disk reports and owned tool/timer installation.
- `components/memory-sample.py`: daily memory CSVs with 30-day retention; no GPU or process changes.
- `components/heavy-job.py`: installable `kit-heavy` runner with serialized, bounded, owner-bound job lifecycle.
- `verify.sh`: independently check live memory safeguards; extend calm checks to user units/recent OOMs. Earlier configs/clipboard/Tailscale/deb changes are retained.
- `hosts/example.conf`, `hosts/worker.example.conf`: expose/document new defaults and updated swap sizing.
- `../friend-host.conf`: explicitly enable disk tmp and resource guards, retain auto swap policy; update its obsolete 4 GiB comment.
- `tests/memory-fixture.sh`: fake HOME/root/meminfo, swap/UUID/free-space/service state and strictly scoped sudo/command stubs.
- `tests/test-tmp-on-disk.sh`: tmpfs/disk/fstab/opt-out, cleanup, reboot and independent verification cases.
- `tests/test-oom-swap.sh`: sizing, existing undersized file/partition, unsafe/failed swapoff, UUID preservation, disk headroom, policy validation, nominal 16 GiB boundary and independent size failure.
- `tests/test-oom-order.sh`: content/live drift, no session/remote restarts, service shields and real PID-score verification controls.
- `tests/test-resource-guards.sh`: caps, watch floors, executable drift, runtime drift, retention/process sampling and small/large boundary.
- `tests/test-heavy-job.sh`: serialization, owner SIGKILL/stop cleanup, lock release, exit status and transient service properties.
- `tests/test-calm-user.sh`: defective/healthy user units and kernel OOM log controls.
- `components/oom-zram.md`: replace the stale no-disk-swap specification with implemented policy, rationale and limits.
- This report and `vault/decisions/2026-10-27-small-control-box-memory.md`: durable findings and review handoff.

## Calibration evidence

Every new behavior started with a failing calibration. All six scripts were
also run with only their implementing hunk reverted, then restored. Captured
stdout/stderr remains in `docs/logs/friend-memory-batch/` (ignored).

- `test-tmp-on-disk.sh`: 9 assertions; removing the tmp component call went red; restoration green.
- `test-oom-swap.sh`: 19 assertions; restoring quarter-RAM/4 GiB sizing went red; restoration green. Extra failing controls covered nominal 16 GiB, missing live zram, unreadable UUID planning, header overhead and falsely credited disk space; disk-headroom and header/probe implementing hunks were separately reverted/red/restored/green.
- `test-oom-order.sh`: 16 assertions; removing the OOM component call went red; restoration green. Extra failing controls cover live proc truth, native/stronger SSH protection, socket activation, stronger Tailscale settings and root preference drift; their implementing hunks were separately reverted/red/restored/green.
- `test-resource-guards.sh`: 15 assertions; removing the resource component call went red; restoration green. Lost executable-bit handling was separately reverted/red/restored/green; runtime cap drift, disk pressure and nominal 16 GiB controls also failed before their fixes.
- `test-heavy-job.sh`: 6 checks; removing flock went red; restoring green. Disabling owner-death, stopped-owner and joint wrapper/caller detection each separately went red, then green after restoration; the last case leaves a wrapper alive while killing its caller.
- `test-calm-user.sh`: 5 assertions; restoring the old system-only calm block and removing OOM evidence went red; restoration green. The read-only assertion's initial fixture PATH issue was corrected before relying on it.

The full `for t in tests/test-*.sh; do bash "$t"; done` run uses
`GIT_HOME=/home/brandon/git` for no-push-guard. A verification-only BASH_ENV
guard refuses the host sudo binary while allowing each test's own stub; a
fake memory root isolates legacy install fixtures from new machine defaults.
The complete suite passes **40 scripts, zero failures**; final stdout is in
`docs/logs/friend-memory-batch/suite-final.log`.
The six new scripts contain 70 calibration assertions/check groups in total.
ShellCheck (warning level) passes for all new shell files; Python compile and
git whitespace checks also pass. Real mounting, mkswap and systemd execution
are intentionally left for provisioning the friend box after review.
The verifier's header positive control initially matched the priority PASS
instead of the size PASS; mutation caught this, and it now requires the
numeric capacity result and rejects a capacity FAIL explicitly.

## Reboot/human steps and existing boxes

After the friend's reviewed install, reboot to activate disk `/tmp`, any
active zram size change and kernel preferences of existing Tailscale
processes. No automatic reboot or remote/session restart. If overflow growth
is refused, retry while quiet; non-ext4/XFS swap-file setups or explicit
tmpfs fstab policy require a human. Use `kit-heavy` for outer heavy jobs:
unwrapped work, daemon-owned containers and existing app-specific locks are
not globally serialized by installing this tool. Respect container limits.
Memory history is approximate RSS+swap, so shared pages can be counted twice.

Next **install** runs, not doctor runs, change Brandon's machines as follows:

- **Beast-VM**: its recorded ext4 fstab `/tmp` is preserved, never masked. RAM is above the small-box boundary, so zram sizing and resource caps stay as before. Session/T3 avoidance is reconciled; installed Tailscale gets a -500 floor at its next start/reboot. SSH keeps native listener protection and gains oomd avoidance, without protecting login jobs. Whole-file tmp cleanup is reconciled. Existing disk swap, if present despite auto zram-only, is now reported/preserved instead of deleted. User-loop/recent-OOM diagnosis improves immediately in verify.
- **ai-3090**: recorded 16 GiB RAM, explicit zram+disk and 16 GiB disk swap remain; its ext4 `/tmp` is preserved. The rounded RAM class prevents reserved memory from enabling small-box policies. Same applicable OOM/cleanup/diagnostic repairs; absent Tailscale is not installed by these guards. Existing mem-log remains untouched; no duplicate small-box sampler is enabled by auto at 16 GiB.
- **Zenbuntu and any other workstation/worker**: default tmp-on-disk prevents vendor tmpfs at the next reboot when no fstab `/tmp` entry exists. If already disk-backed, its location does not change. Same installed-service OOM/cleanup repairs. Only machines classified below 16 GiB get half-RAM zram, sized overflow and auto resource guards. Current RAM/fstab state was not remotely probed, so smaller-box effects are conditional, not asserted as observed facts. Set the documented flags to opt out where desired.
- **Proxmox host profile/LinuxBeast2 host**: unaffected; these components are only in the workstation/worker phase. Other boxes that do not run those profiles are unaffected.

No T3 binary is modified. Current installed CLI code supports scopes/+800;
the kit preserves that behavior. An older running service is not proven
current merely because the CLI symlink was updated: check its program/version
when upgrading. Existing T3 boot-unit `OOMPolicy=continue` is retained, and
the kit drop-in repairs control-plane avoidance without shielding all agents.

Read-only version caveat: Beast's saved unit still names the
0.0.46-preview.20261009.2891 program, whose binary lacks the scope/+800 markers
found in the installed 0.1.2 CLI. A launcher may select another runtime, so
this is a concrete upgrade/version check for the existing service, not proof
of its live agent behavior. No real T3 service was restarted or rewritten.
