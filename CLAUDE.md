# setup-kit

Reusable machine provisioning for a fresh Linux box (bare metal or VM):
point it at a clean Ubuntu install and it becomes a working dev machine —
packages, toolchains, configs — idempotently.

## Entry points

- `bootstrap.sh <profile> [check|install]` — the orchestrator.
  - `survey` — read-only hardware probe (virt flags, IOMMU, GPUs, disks); safe on a live CD.
  - `workstation check` — doctor: report drift, change nothing.
  - `workstation install` — provision; prompts once, loops passes until converged, then runs `verify.sh`.
  - `proxmox-host install` — IOMMU/VFIO/ZFS/nested-virt (run as root; reviewed-but-unrun).
- `get.sh` — one-line fetcher: clones the repo, optionally execs `bootstrap.sh`.
- `verify.sh` — independent system-vs-manifest check. Deliberately does NOT source `lib.sh` (a shared bug shouldn't lie twice).

## Layout

- `lib.sh` — shared helpers: output, modes, host-conf, detection, manifest/apt.
- `manifests/` — WHAT to install: grouped apt lists, lang stacks, snap/flatpak, direct debs.
- `profiles/workstation/` — ordered idempotent phases (`00-identity` … `08-claude-skills`).
- `profiles/proxmox-host/` — host-side passthrough / ZFS / VM-creation scripts.
- `components/` — opt-in/conditional extras; one spec per `components/*.md`.
- `hosts/<hostname>.conf` — per-machine answer file (`example.conf` is the template).
- `capture/` — refresh tooling: re-snapshot a machine, regenerate the manifests.

## Conventions

- **Idempotent** — re-runnable; already-installed is success. Every phase takes a mode arg: `check` (read-only) or `install` (apply).
- **Doctor/install split** — `check` reports drift and changes nothing.
- **No silent sudo** — detect root needs upfront, one consolidated sudo pass; log gaps to `logs/missing.log` instead of failing silently.
- **Manifests are generated** — `capture/90-generate-manifests.py` writes `manifests/apt/*`. Edit the generator (its strings become the file comments), not the `.list` files by hand — a regen overwrites them.
- **Two repos** — setup-kit owns machine-level provisioning; `~/git/.configs` (private) owns user dotfiles/bin/dconf and is cloned + run by phase 06. setup-kit never duplicates dotfiles.

## Git — ABSOLUTE RULE

- Claude commits. The user pushes. NEVER run `git push` — any remote, any protocol (SSH/HTTPS/gh), tags, force, anything. No exceptions, ever.
- Never ask to push, never offer to push, never suggest pushing. Pushing is exclusively the user's action, done on their schedule.
- After committing, just report the commit and stop.

## Gotchas

- `snapshot/` is gitignored (large, machine-specific, holds WiFi PSKs). Never commit it.
- Don't add a steam apt repo — the steam package manages its own source; a duplicate breaks all of apt (Signed-By clash).
- The Android emulator needs `/dev/kvm` (BIOS virt on bare metal; nested virt + `cpu=host` in a Proxmox VM).
