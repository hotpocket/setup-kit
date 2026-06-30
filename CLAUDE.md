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
- Same for **vscode**: the `code` package drops its own `vscode.sources` (signed-by `/usr/share/keyrings/microsoft.gpg`). Never add a `vscode.list` — apt compares keyring *paths*, not keys, so even the identical Microsoft key at a different path is a fatal Signed-By clash that kills all of apt. `01-apt-repos.sh` deliberately omits it and removes any stale `vscode.list`.
- **All `apt-get install` must be non-interactive** — use the `apt_install` helper (lib.sh) or the `02-apt-install.sh` array (`DEBIAN_FRONTEND=noninteractive` + `--force-confdef --force-confold`). A bare `apt-get install` can hit a dpkg conffile prompt; because phases pipe through `tee` and sudo uses `use_pty`, that prompt is *unanswerable* and wedges the run forever (seen on 24.04 with `systemd-zram-generator`). Configs the kit owns (e.g. `zram-generator.conf`) are reconciled by content, not by answering dpkg.
- The Android emulator needs `/dev/kvm` (BIOS virt on bare metal; nested virt + `cpu=host` in a Proxmox VM).

## Session conduct

Session-start orientation is injected by the global `SessionStart` router
(`~/bin/claude-orient`), which runs this repo's `scripts/session-start.sh`:
latest recap pointer + open-todo count. Go deeper on demand — read the recap body
in `vault/sessions/` or open `vault/todos/setup-kit.md`.

**Vault access is file-first.** Use `scripts/vault-digest` for cheap reads —
grep/awk over note frontmatter, no Obsidian app/CLI/GUI, safe across parallel
sessions:
- `scripts/vault-digest summaries [subdir]` — one-line gist per note (Level 0).
- `scripts/vault-digest type <t>` / `concern <c>` — filter by frontmatter.
- `scripts/vault-digest recap` / `todos` / `backlinks <note>` / `search <q>`.
Read a full note body (Level 2) only after a summary points you to it. The
`/vault` skill (Obsidian CLI) is an optional accelerator — never load-bearing.

When you discover something durable (architecture, a gotcha, a decision and its
why), write it back to the vault. **At session end**, offer `/vault recap`.

## Docs layout

- `docs/` — generated documents: working notes, plans, analyses.
- `docs/reports/` — persistent, prepared deliverables meant to be kept/shared.
- `docs/logs/` — transient/ephemeral output of repeatable processes (gitignored).

## Skills available here

- `vault` — persistent Obsidian memory (orient, look up, write back).
- `gstack` — drive a real browser to research the web and produce results.
- `code-review` — review the current diff for bugs and cleanups.

## Rules of conduct

(Idempotency, no-silent-sudo, and commit/push rules live in **Conventions** and
**Git — ABSOLUTE RULE** above.) Additionally:
- Be brief: no preamble, no recap of what the user knows, no surveying paths not taken.
- Reversible-by-default; confirm before hard-to-undo or outward-facing actions.
