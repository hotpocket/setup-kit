# uutils-ls — temporary distro-bug shim (workstation profile)

Ubuntu resolute ships uutils (Rust) coreutils **0.8.0**, whose `ls` has a real
bug: `--group-directories-first` silently breaks `-t` (time) sorting — files
come out in nonsensical order. Our `.configs` `ls`/`ll` aliases use both flags,
so every directory listing was mis-sorted.

- Upstream bug: https://github.com/uutils/coreutils/issues/12393 (dupes: #12410, #11997)
- Fixed upstream 2026-05-01 in commit `5a25c70c1` ("fix(ls): respect sorting
  when grouping directories"), first released in **0.9.0**.
- Ubuntu resolute is frozen at `rust-coreutils 0.8.0-0ubuntu3`; no SRU as of
  2026-07. The fix won't arrive via `apt upgrade`.

## What the shim does

Shadows **only `ls`** with the upstream 0.9.0 static (musl) multicall binary:

- Binary: `/usr/local/lib/uutils/coreutils` — deliberately OFF `$PATH`, so
  `coreutils`, `cp`, `mv`, … all still resolve to the distro's 0.8.0.
- Symlink: `/usr/local/bin/ls` → that binary (uutils dispatches on argv[0]).
  `/usr/local/bin` precedes `/usr/bin`, so every shell picks it up; apt never
  touches `/usr/local`, so it sticks across upgrades.
- Download is version+sha256-pinned from the GitHub release (no `curl | sh`).

## Self-removal

The phase compares dpkg's `rust-coreutils` version against the pinned shim
version every run. The day the distro ships >= 0.9.0, `check` flags the shim
as obsolete and `install` removes it (symlink + binary + dir). Manual
reversal any time: `sudo rm /usr/local/bin/ls /usr/local/lib/uutils/coreutils`.

## Setup-kit integration

- Flag: `component_uutils_ls` (default **yes** — the bug bites every listing).
- Installed by `profiles/workstation/07-components.sh`; idempotent; check
  mode reports only.
- Verify: `type -a ls` lists `/usr/local/bin/ls` first, and
  `ls -alhtr --group-directories-first` in a busy dir sorts newest-last.
