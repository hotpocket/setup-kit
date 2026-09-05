---
tags: [session]
type: session
concerns: [ops, infra, security]
audience: []
summary: "A clean 26.04 EFI VM ran three identical passes and installed almost nothing: the manifests pinned host-decided packages (grub-pc, systemd-timesyncd, pulseaudio) and apt refused the whole transaction. Phase 02 now attributes each forced removal to the wanted package on a Conflicts:/Breaks: line and skips only that; those pins are dropped for good. Bootstrap stops on a repeated pass, quiet mode is a narrative (one line per phase, repeats held back, one summary), and the kit now provisions Claude Code (native installer), bun, Android cmdline-tools + SDK + AVD, ydotool via a uinput uaccess ACL, WineHQ branch selection, the dock (manifests/dock.list, exact), and both YubiKey OpenPGP keys. Beast-VM ended converged: verify 64 pass / 0 fail."
created: 2026-09-05
status: completed
projects: [setup-kit]
branch: main
---

# fresh-VM install converges; narrative output, dock manifest, wine branch, YubiKey pair

## For Humans

- A clean 26.04 EFI VM (Beast-VM) ran three identical passes and installed
  almost nothing. Root cause: the manifests pinned packages the host decides
  (grub-pc, systemd-timesyncd, later pulseaudio); apt refused the whole
  187-package transaction to protect the live ones, and every later phase
  failed on what never arrived. The installer now attributes each forced
  removal to the wanted package causing it, skips only that, and installs the
  rest. Those pins are recorded as drops so a re-capture cannot bring them back.
- Passes cycled because four checks could not see their own results (deno not
  on PATH, GNOME extensions invisible until relogin, a quoted conf value read
  with its quotes, git pulls sitting on a YubiKey PIN prompt). All fixed, and
  bootstrap stops when a pass repeats the previous pass's actions.
- Terminal output is a narrative now: one line per phase, sections only above
  a warning or action, warnings repeated from the previous pass held back, one
  summary at the end, transcripts in `logs/`.
- Provisioned what the kit only warned about: Claude Code (native installer
  only, `component_claude_code`, default on), bun, Android cmdline-tools plus
  SDK packages and a default AVD, ydotool for Wayland dictation, WineHQ branch
  selection (`wine_branch`; Beast-VM on devel 11.17 for MTGA's mouse-capture
  fix), the media group, `code` as a deb.
- The GNOME dock is declared in `manifests/dock.list` and set exactly by phase
  `06y-dock`; Ubuntu's defaults leave by not being listed. Obsidian is purged
  from the kit (the vault is plain markdown).
- YubiKey: pcscd could not open a key plugged before libccid's udev rule
  existed; fixed by re-adding the device. The plugged card is the backup key,
  so `gpg_key_fpr` now lists both keys and the pass store must be encrypted to
  all of them.
- End state on Beast-VM: converged in two passes, verify 64 pass / 0 fail, wine
  11.17, ydotoold running under a uinput ACL. Pending on the user's side:
  re-init the pass store to both keys and re-insert `github/admin-pat`; remove
  the Claude Desktop apt source (needs sudo); push setup-kit and `.configs`.

## Next Steps

Nothing session-sized is open. The two prior TODOs (fresh-install verification;
`grep -q` under pipefail audit) are closed.

## For Agents

Context: read § For Humans first; this section adds the operational detail.

- Read `590ea13` and `5289d7b` before touching phase 02's removal guard.
  Attribution re-simulates the transaction with the to-be-removed packages
  pinned, then takes only wanted packages that appear on a `Conflicts:` or
  `Breaks:` line, stated by either side (the wanted side for a virtual target
  like `time-daemon`; the removed side for `pipewire-audio : Conflicts:
  pulseaudio`). Taking every name in apt's unmet-dependencies block blamed 27
  innocents once. `tests/test-apt-removal.sh` reproduces the real conflict on
  any EFI box with chrony installed.
- `c3baaa2` and `5dfa2d9` define quiet mode's contract: nothing printed to
  stdout may also be written to the run log directly, because bootstrap tees
  stdout into it and counts `[WARN]`/`[FAIL]` tags there. `_ctx` prints the
  pending section header once, above the first noisy line.
  `tests/test-quiet-output.sh` guards each channel.
- `2c12dad` records a platform fact no diff shows fully: with `Linger=yes` the
  `systemd --user` manager survives logout and keeps its login-time groups, so
  group-based device access never reaches user services, relogin or not. Use a
  udev `uaccess` tag (a per-uid ACL for the active seat) instead; the rule file
  must sort before `73-seat-late.rules`, which is what applies the tag.
- `3e35174` and `ce263da`: udev rules apply at `add` time only. A device
  plugged before its rule's package lands stays root-owned; `udevadm trigger
  --action=add` is the re-apply, and the default `change` event walks past
  `ACTION=="add"` rules. Phase 02 re-triggers after every apt transaction.
- `6f85d50`: a wine branch swap must be one apt transaction. Removing the old
  branch first lets apt refill winetricks' `Depends: wine` with Ubuntu's wine,
  which then conflicts with winehq-devel and the guard skips it.
- `3e35174`: `sdkmanager --list` tokens are matched whole; `platforms;android-37`
  was a prefix of `android-37.0/37.1/37.2` and not a package.
- Cross-repo coupling with `.configs`: its `setup.sh` links launchers and loads
  dconf (terminal profile, `f0587e1`) but no longer pins the dock (`e9a320c`);
  the dock is setup-kit's job. Its `*.local` gitignore matched the `.local`
  directory and hid `screenshots-folder.desktop` for a month (`7e24e64`);
  `tts-server.service` now has `ConditionPathExists` on the kokoro venv so a
  half-provisioned box does not restart-loop it.
- `verify.sh` and `lib.sh` both carry the `| grep -q` under pipefail trap; only
  a producer that writes past the 64 KiB pipe buffer after grep's first match
  can flake. `find` was the last such producer and uses `-print -quit` now.
