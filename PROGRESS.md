# Setup-Kit — Progress Log  (formerly Migration Kit)

Pick up where you left off. Each session appends a dated entry.

---

## 2026-05-15 — kit drafted

Built `homelab-2026.md` (architecture doc) and the full `migration-kit/` tree
(capture + restore-host + restore-vm). 23 scripts, ~1700 lines. Nothing
executed yet.

## 2026-05-15 (late) — capture phase user-mode pass complete

Ran `capture/01-packages.sh` through `capture/06-network-secrets.sh` end-to-end
on the current Ubuntu. Caught + fixed several bugs:

- `01-packages.sh`: `sudo cp` calls silently failed (no TTY for password
  prompt). Switched to direct cp — `/etc/apt/*` is world-readable except
  `auth.conf.d`, which goes to missing.log.
- `03-languages.sh`: `local py=` declared outside a function (bash error);
  pyenv version names with `/` (e.g. `3.13.2/envs/zonos`) created broken
  output paths. Sanitized to `__` separator.
- `05-system-state.sh`: same silent-sudo problem; also `> file` was
  truncating files to 0 bytes BEFORE the sudo error fired. Fixed via
  capture-to-var-then-write pattern.
- `06-network-secrets.sh`: needed root but had no detection — would
  silently capture nothing. Now detects sudo upfront, logs gaps to
  `missing.log` if absent.

Added new file: **`capture/99-sudo-extras.sh`** — consolidates every
sudo-required capture step into one script so the user enters their
password once.

Captured artifacts: **295 MB** in `snapshot/`. Of that, **294 MB is the
dotfiles tarball** (which includes `.claude/` at 472 MB uncompressed →
~280 MB compressed). The rest of the snapshot is tiny:
- `snapshot/apt/` 516 KB (manual.txt: 723 packages; selections.txt: 4821)
- `snapshot/snap-flatpak/` 52 KB (28 snaps, 1 flatpak)
- `snapshot/languages/` 140 KB (pyenv versions, pip freezes, etc.)
- `snapshot/system/` 608 KB (dconf 1856 lines, cron, modprobe, systemd…)
- `snapshot/network/` 20 KB (ip state, nmcli — no PSKs yet, no sudo)
- `snapshot/dotfiles/dotfiles.tar.gz` 294 MB

`snapshot/logs/missing.log` lists everything still needing sudo.

## TODO — next session

1. **Run the sudo pass.** From `~/git/tmp/migration-kit/`:
   ```bash
   sudo -E bash capture/99-sudo-extras.sh
   ```
   This grabs: auth.conf.d, sudoers.d, root crontab, ufw rules, iptables,
   blkid UUIDs (for fstab reconstruction), NetworkManager WiFi PSKs,
   wireguard, openvpn, netplan, resolv.conf, resolved.conf.d.
   It also chowns the whole snapshot back to you when done.

   Verify after: `cat snapshot/logs/missing.log` should be empty or only
   list things that genuinely don't exist on this system.

2. **Consider trimming `.claude/`** from `04-dotfiles.sh` if you don't
   want 472 MB of Claude Code session/project history migrated. Easiest
   way: remove `.claude` from the INCLUDE list, rerun
   `bash capture/04-dotfiles.sh`. Or leave it — disk is cheap.

3. **Copy `snapshot/` off-machine** before you wipe. Options:
   - The 20 TB Expansion drive (mounted now)
   - A spare USB stick (snapshot is <300 MB, fits anywhere)
   - The headless server once Proxmox is up

   `snapshot/network/` is mode 700 and contains WiFi passwords — don't
   sync it to anywhere unencrypted.

4. **Lint `restore-host/` and `restore-vm/` scripts.** They've never
   executed. A static pass (shellcheck, smoke-read) would catch the same
   class of bugs we hit in capture (silent-sudo, redirect-before-fail,
   pyenv-style escaping). Not blocking; do before the rebuild.

5. **Inspect 2TB NVMe model** on current system — pcbuild-2026.md says
   "model TBD". Find out before wipe:
   ```bash
   sudo nvme list
   # or
   lsblk -d -o NAME,MODEL,SERIAL,SIZE -e7
   ```

6. **Open items in `homelab-2026.md`** — none blocking but worth pinning
   before the rebuild:
   - PSU pick (CX750M bundle vs old 800W)
   - UPS purchase (~$120 CyberPower)
   - Offsite backup destination (cloud vs rotated USB)
   - 2080 Ti deploy mode (VFIO-VM vs LXC bind-mount)
   - USB controller passthrough strategy
   - `pcbuild-2026.md` doc update reflecting the homelab divergences

## Sequencing reminder (from homelab-2026.md)

**Do NOT wipe the old machine before:**
1. New 9950X build is assembled and POSTs cleanly.
2. Proxmox installed on the 2 TB NVMe in the new box.
3. Workstation VM created and proven usable for a few days.
4. `migration-kit/snapshot/` copied off the old machine to two locations.

Only then move the old motherboard/CPU/RAM into the second case and start
the Proxmox-server install on it. The old box is still your daily driver
right now — protect it.

---

## 2026-06-05 — session recovery + consolidated plan

Audited the May 21 transcripts after another interruption. Finding: **no
work was lost.** The May 21 mtime on this file was just the log write
itself; the capture work all happened May 15 and is fully recorded above.
Verified on disk: sudo pass still not run (`missing.log` unchanged), no
snapshot artifacts newer than May 15.

### Current state

- Kit complete: 23 scripts across `capture/`, `restore-host/`, `restore-vm/`
- Capture user-mode pass: **done** (May 15), bugs fixed, idempotency-tested
- Snapshot: **295 MB** (294 MB = dotfiles tarball; `.claude/` is 472 MB
  uncompressed → ~280 MB of it)
- Counts: 723 manual apt pkgs, 4821 selections, 2 PPAs, 28 snaps,
  1 flatpak, 16 pyenv versions
- VM sizing / ZFS layout reasoning lives in
  `../session-2026-05-15-rebuild-planning.jsonl`; architecture in
  `../homelab-2026.md`; hardware in `../pcbuild-2026.md`

### Plan — ordered

1. **Sudo capture pass** (only blocking item):
   `sudo -E bash capture/99-sudo-extras.sh`
   → grabs WiFi PSKs, ufw/iptables, blkid UUIDs, sudoers.d, root crontab,
   netplan, resolv.conf, auth.conf.d. Verify `missing.log` is clean after.
2. **`.claude/` trim decision** — leaning *keep* (disk is cheap). If
   trimming: drop `.claude` from INCLUDE in `capture/04-dotfiles.sh`,
   rerun it (snapshot drops ~295 MB → ~15 MB).
3. **Copy `snapshot/` off-machine, two places** (20 TB Expansion, USB
   stick, or server). `snapshot/network/` holds WiFi PSKs after step 1 —
   encrypted destinations only.
4. **Shellcheck + smoke-read `restore-host/` and `restore-vm/`** — never
   executed. Hunt the known bug class: silent-sudo, redirect-truncates-
   before-fail, special-chars-in-paths.
5. **ID the 2 TB NVMe model** (`sudo nvme list`) and update
   pcbuild-2026.md ("model TBD").
6. **Open homelab decisions** (none blocking):
   - PSU: CX750M bundle vs old 800W
   - UPS: ~$120 CyberPower
   - Offsite backup: cloud vs rotated USB
   - 2080 Ti: VFIO-VM vs LXC bind-mount
   - USB controller passthrough strategy
   - pcbuild-2026.md update for homelab divergences

### Guardrail (unchanged)

Do NOT wipe the old box before: 9950X build POSTs → Proxmox on the 2 TB
NVMe → workstation VM proven for days → snapshot in two off-machine
locations. Old box is the daily driver.

### Unrelated loose ends (diagnosed May 21, never applied)

- **apt i386 warning**: duplicate Chrome repo —
  `/etc/apt/sources.list.d/google-chrome.sources` lacks `Architectures:`;
  delete it, keep `google-chrome.list`.
- **MTGA/Wine update loop**: 32-bit installer needs x86 VC++ ≥
  14.29.30135; prefix only has x64. Fix: `winetricks vcrun2022`.
- **`magic` alias** (`~/.bash_aliases:86`): uses `$( ... )` command
  substitution — captures output instead of running wine. Rewrite without
  the substitution.

---

## 2026-06-05 (later) — purpose reframed: migration-kit → setup-kit

The kit is **no longer a one-shot migration** of the current box. It is a
**reusable new-machine provisioning tool ("setup-kit")**: run from a Linux
terminal (minimum a live Ubuntu CD), it makes any machine work as expected
without manually reinstalling everything. Agreed direction (restructure ON
HOLD while `~/git/.configs` is being updated by hand):

- **Two layers**: `~/git/.configs` (github.com/hotpocket/.configs) owns
  user-level config/dotfiles/bin/dconf and stays its own repo; setup-kit
  owns machine-level provisioning and ends by cloning + running `.configs`.
- **Profiles**: `proxmox-host` (IOMMU/VFIO, ZFS, GPU passed to a "main" VM
  that is the de-facto OS, remaining resources subdivided into LAN-workload
  VMs — absorbs `restore-host/`) and `workstation` (absorbs `restore-vm/`;
  same script for VM or bare metal).
- **Stages**: 0) live-CD `survey` — hardware probe (virt flags, IOMMU
  groups, GPU/NIC/disks) to qualify a box for passthrough BEFORE install;
  1) base OS install (Proxmox from its own ISO; kit provides checklist/
  answer file); 2) profile provisioning on the installed OS.
- **Dumps → manifests**: curate the 723-pkg list into grouped, committed
  manifests; `capture/` becomes a refresh/diff step. The 294 MB dotfiles
  tarball dissolves — anything worth keeping gets promoted into `.configs`.
- Adopt `.configs` `setup.sh` **doctor/install** convention kit-wide.
- Old TODO list above is largely superseded: sudo pass demoted (machine-
  specific state mostly drops out; keep WiFi PSKs/ufw policy as a small
  secrets side-channel, gitignored/encrypted). Homelab/pcbuild items move
  back to their own docs.
- New: **`components/herdr.md`** — opt-in multi-agent terminal multiplexer,
  source-audited 2026-06-05, install + integration notes captured there.
  (Research clone at `/tmp/herdr` intentionally not kept — installs pull
  fresh from upstream.)

### Manifest curation — sizes + first decisions (2026-06-05)

Measured: the 723 manual packages = **13.1 GB** installed (top 25 ≈ 10 GB).
Setup-kit design: manifests carry size annotations from capture time; a
`--review-over=100M` checklist at install time records deselections in the
per-host config; on-target preflight via `apt-get install -s` ("After this
operation…") checked against free disk.

Decisions so far:
- **KEEP**: `zoom`, `code`
- **DROP**: `webmin` (151 MB; root web panel, redundant — Proxmox UI /
  Cockpit cover it. Found ACTIVE + enabled on 0.0.0.0:10000 on the current
  box; user confirmed not needed → disable/purge locally too)
- **DROP (install piecemeal if ever needed)**: `mssql-server`+`-fts`
  (1.65 GB), `rstudio` (541 MB), `azuredatastudio` (552 MB),
  `mysql-workbench` (117 MB), `cursor` (858 MB), `code-insiders` (778 MB),
  `signal-desktop` (432 MB), `bruno` (477 MB), `dotnet-sdk-6.0` (329 MB),
  `openshot-qt` (137 MB)
- **REPLACE**: `jdk-21` (331 MB) → whatever the *current* JDK is at
  install time (manifest entry should resolve "latest", not pin 21)
- **CONDITIONAL** (new manifest concept — resolved by detection at install
  time, feeds off the stage-0 survey):
  - `virtualbox` (268 MB): only on bare-metal non-Proxmox targets — skip
    when provisioning a proxmox-host or inside a Proxmox VM
    (`systemd-detect-virt`)
  - `nvidia-cuda-toolkit` (167 MB): only when an NVIDIA GPU is present
    (`lspci | grep -i nvidia`)
- **DROP** also: `tofu` (110 MB) — verified zero usage: no invocations in
  eternal history, no own .tf projects (only fixtures inside a clone of
  hashicorp/terraform source), installed 2026-05-27 and never run
- **KEEP** also: `brave-browser`, `google-chrome-stable`, `obsidian`,
  `docker-ce`, plus system-ish auto-keeps (snapd, ibus-data,
  yaru-theme-icon)

**Heavy-tier (>100 MB) curation COMPLETE 2026-06-05.** ~6.1 GB dropped,
~0.4 GB moved to conditional; baseline manifest ≈ **6.5 GB** (was 13.1).
Remaining curation work: the long tail of <100 MB packages (~700 pkgs,
~3 GB total) — lower stakes, can be reviewed in bulk by category when the
manifests get built.

---

## 2026-06-05 (night) — OOM hardening component added

Context: systemd-oomd force-killed the entire GNOME session at 22:11
(Chrome 8G + 4 Claude Code terminals on 31G RAM with zero swap → pressure
spike → oomd killed user `dbus.service` → force logout, all apps dead).
Root-caused via journalctl; fixed live on LinuxBeast the same night.

- New: **`components/oom-zram.md`** — default-on workstation component:
  zram (8G zstd, NO disk swap ever — SSD-wear constraint), page-cluster
  sysctl, oomd softened 50%/20s → 80%/60s, dbus shielded with
  `ManagedOOMPreference=avoid`. Working script: `~/git/tmp/fix-oom-setup.sh`.
  All four parts applied + verified on this box; the kit needs to make them
  provisioning steps (TODOs in the component doc: derive zram size from RAM,
  parameterize uid, dbus drop-in belongs to `.configs` with a kit doctor
  check).
- Open question from last session still pending: package size
  calculation/filtering during setup (size-annotated 723-pkg list, let the
  user weed out the big ones — mssql 1.1G, cursor, code-insiders flagged).


## 2026-06-06 — dev-stack curation (workstation profile)

Goal: new machine ready to develop software. Manifest gets toggleable
`dev-*` groups, each recorded in the per-host answer file so idempotent
re-runs can flip them on later.

**ON by default:**
- `dev-core` — build-essential, gcc, clang, cmake, ninja-build,
  pkg-config, libtool, git, gh, jq, docker-ce(+buildx+compose), sqlite3,
  **+ add: shellcheck, git-lfs** (not currently installed)
- `dev-java` — `default-jdk` (current, not pinned 21) + maven
- `dev-flutter` — scripted clone → `~/development/flutter` + Android
  SDK + adb udev rules + Linux desktop build deps; dart globals:
  serverpod, melos, coverage tools
- `dev-node` — nvm + current LTS only (not the 5 old versions) +
  npm globals (aws-cdk…)
- `dev-python` — pyenv **+ build deps** (libssl-dev, libbz2-dev,
  libreadline-dev, libsqlite3-dev, liblzma-dev, libffi-dev, tk-dev — the
  fresh-box trap), pipx + poetry
- `dev-cloud` — awscli, **+ add: gcloud** (Google Cloud CLI via its apt
  repo — wanted as install option, the "AWS-like console tool")

**OFF by default (selectable on any run):**
- `dev-db` — postgresql
- `dev-go` — go + gopls/staticcheck
- `dev-php` — php + composer
- `dev-rust` — via rustup (not apt's stale rustc/cargo)

**Decided (2026-06-06):**
- **pyenv scope**: interpreters only; the 6 project envs (tts, chatterbox,
  zonos…) rebuild per-project — pip-freeze snapshots archived as reference.
- **Android: full Android Studio + SDK + emulator** (emulator wanted).
  Today's install is a manual tarball at `~/android-studio` + SDK at
  `~/Android/Sdk` + 4 AVDs (Pixel 4/5/6 Pro/C). Kit scripts: Studio
  (tarball or snap — pick at build time), sdkmanager packages
  (platform-tools, build-tools, emulator, a current system image), one
  default AVD.
  ⚠ **Emulator needs /dev/kvm → proxmox-host profile MUST enable nested
  virtualization** (`kvm-amd nested=1`, VM CPU type `host`) or emulation
  falls back to software. Hard requirement for the workstation-as-VM case.

## 2026-06-06 — ocr-tts component spec added (from .configs session)

New `components/ocr-tts.md`: the OCR/TTS custom tools (kokoro TTS
clipboard server, nerd-dictation, ocrscr) move here from
`.configs/ocr-and-tts-setup.sh` + `setup.sh install`. Key requirements
from owner: **prompt the user** instead of installing unconditionally,
and **gate TTS on a qualified GPU** (floor TBD — kokoro is only ~82M
params, so decide whether CPU opt-in is allowed). The `.configs` scripts
remain the working reference until absorbed; python version installs are
explicitly setup-kit's responsibility now, not .configs/setup.sh.

---

## 2026-06-06 — restructure + manifests DONE (steps 1 & 2)

Folder renamed `migration-kit` → `setup-kit` (symlink left behind for old
references). Git repo initialized, v0 committed. New layout: bootstrap.sh /
manifests/ / profiles/{workstation,proxmox-host} / hosts/ / components/.

- **Manifests generated** (capture/90-generate-manifests.py — re-runnable
  after any capture refresh): **5.13 GB default-on** across 13 groups
  (was 13.1 raw). 242 manually-pinned libs parked in libs-review.list
  (0.74 GB — apt re-pulls real deps automatically). Kernel-pinned pkgs
  excluded. optional/{db,php,rust,r}, conditional/{nvidia,virtualbox,
  printer-brother}, dropped.list keeps refresh runs from re-proposing.
- **repos.md**: third-party repo → group map; adds cloud-sdk (gcloud);
  drops microsoft-prod/opentofu/webmin/bruno/cursor repos; flags maxmind.
- **lang/ manifests**: python (3 interpreters + pipx:poetry), node
  (nvm lts/* + aws-cdk/corepack/tsx), flutter+android (Studio tarball,
  sdkmanager pkgs, default AVD), optional (go/rustup).
- **snap.list**: 10 apps kept of 28 (bases auto-resolve); bruno dropped;
  hover + wine-platform-* flagged as leftovers; multipass flagged.
- **bootstrap.sh survey works** — ran on LinuxBeast: 2080 Ti is in IOMMU
  group 1 with only its own functions + root port (clean passthrough).
- **Emulator-in-Proxmox accounted for**: profiles/proxmox-host/
  05-nested-virt.sh (kvm_amd nested=1 + per-VM cpu=host + LXC /dev/kvm
  passthrough recipes); survey + future workstation doctor check /dev/kvm.
- hosts/example.conf: full answer-file template (groups, conditionals,
  review_over_mb, components, lang stacks, .configs hookup).

### Next (step 3 — the remaining build work)
1. Rework profiles/workstation/ scripts: replace restore-vm logic with
   manifest+answer-file driven install, doctor mode, size-review prompt,
   component hooks (oom-zram default, herdr opt-in, ocr-tts GPU-gated),
   /dev/kvm doctor check, .configs clone+setup handoff.
2. Update profiles/proxmox-host/04-create-workstation-vm.sh: cpu=host.
3. shellcheck everything (shellcheck now in dev-core manifest; install it).
4. Throwaway test: fresh Ubuntu VM, run workstation install end-to-end.
5. Decide GitHub remote (hotpocket/setup-kit?) — snapshot/ is gitignored
   so the repo is safe to push once reviewed.

## 2026-06-06 (later) — step 3 DONE: workstation profile rewritten

`profiles/workstation/` is now 8 manifest+answer-file driven phases, each
idempotent with doctor(check)/install modes (old restore-vm code in git
history). bootstrap.sh orchestrates: creates hosts/<name>.conf from the
template on first run, one sudo keepalive, runs phases in order.

Smoke-tested the full doctor pass on LinuxBeast — **exit 0, accurate**:
flagged exactly the 6 not-yet-installed additions (shellcheck, git-lfs,
default-jdk, libncursesw5-dev, google-cloud-cli, nvidia-container-toolkit),
chained .configs' own doctor, flutter doctor green, oom-zram all green.
Bugs caught live: pipefail+grep -q SIGPIPE false negatives; detect-virt
"none" dup; dev_flutter_deps conf-key mismatch.

### Remaining before first real use (steps 4-6)
4. shellcheck pass (blocked on installing shellcheck — it's in dev-core;
   running `workstation install` on this box would pull it in).
5. **The gate**: throwaway fresh-Ubuntu VM end-to-end install test.
6. GitHub remote decision (hotpocket/setup-kit) + push.

Note: running `./bootstrap.sh workstation install` on LinuxBeast itself is
safe + useful (installs the 6 missing additions, prompts for ocr-tts) —
the doctor confirms everything else is already converged.

## 2026-06-06 — one stable version per language (kit-wide)

Owner decision during the LeBuntu live test: a base install gets **one
version per language**, a step or two behind latest for stability.
- python: pyenv `3.12` only (aligns with .configs PYTHON_VERSION=3.12.11);
  supersedes the earlier "3 interpreters" call
- node: nvm `lts/*` (already one LTS) · java: default-jdk · flutter:
  stable channel · go/rust (opt-in): single stable
Old projects install their pinned versions per-project, on demand.

Refinement (same day): for languages WITH an LTS track (node, java), one
version = the **latest LTS** — not "a version behind". The behind-latest
heuristic applies only where no LTS exists (python → 3.12).

## 2026-06-06 — swap policy + 26.04 package modernization

- **swap_policy=auto** (owner-approved): zram always first tier; RAM <16G
  adds a 4G disk overflow at pri -2 (emergency only — negligible SSD wear);
  RAM ≥16G stays zram-only (LinuxBeast constraint unchanged). Per-host
  override in the answer file.
- 16 packages gone/renamed on 26.04 encoded in the generator (cheese,
  vino, pulseeffects→easyeffects, neofetch→fastfetch, wireless-tools,
  gnome-shell-extensions now in-desktop, libncursesw5-dev→libncurses-dev…)
- Ubuntu 26.04 ships uutils coreutils: sort|comm collation mismatch broke
  the apt pre-filter — rewritten as awk set-membership. Watch for more
  uutils/GNU gaps in any scripting on 26.04.

## 2026-06-06 — LeBuntu live test COMPLETE: converged + independently verified

12 install runs on the Lenovo laptop (bare-metal 26.04). 19 issues found
and fixed — full table in TEST-REPORT.html (delivered to the laptop at
~/git/setup-kit/TEST-REPORT.html). Highlights: steam repo Signed-By
conflict broke all of apt; uutils sort|comm collation bug; paprefs vs
pipewire flap; dpkg -s config-files lie (caught by verify.sh).

Final state: run 12 = actions:0 (idempotent); **verify.sh 33/0** —
independent traditional-tool verification (new kit file, run it after any
install). NOPASSWD test scaffolding removed. Laptop manual follow-ups:
BIOS VT-x, Studio first launch, gh auth login.

Kit is ready for: pristine-VM from-zero test → 9950X bare metal →
Proxmox VMs. shellcheck sweep + GitHub remote still pending.

## 2026-06-06 — .configs wiring gaps (found post-test) + auth-prompt validation

- **gh-auth prompt is UNTESTED CODE**: written after the laptop's .configs
  was rsync-seeded; never executed (non-TTY test runs skip prompts by
  design). VALIDATION STEP: at the laptop's own terminal —
  `rm -rf ~/git/.configs && cd ~/git/setup-kit && ./bootstrap.sh
  workstation install` → expect the inline gh device-flow prompt.
- **Dotfiles were cloned but inert**: ~/.bashrc, ~/.bash_aliases,
  ~/.gitconfig are hand-made symlinks on LinuxBeast (2023-2025); nothing
  automated them. Phase 06 now links them (with .pre-setup-kit backups);
  verify.sh independently checks all three.
- **~/bin wiring**: phase 06 now symlinks every EXECUTABLE in .configs/bin
  into ~/bin (LinuxBeast convention, automated; PDFs/docs skipped; real
  files never clobbered).
- **OPEN CURATION (owner)**: LinuxBeast ~/bin has ~41 real files never
  versioned in .configs/bin (dexec, mvs, git-heatmap, dlmp3, title,
  mem_usage, update_node, zig, odin, heimdall, ghostty, … + junk like
  old-ffmpeg-wrapper*, bak-ocrscr, a stray mp3). Decide which get
  promoted into .configs/bin (then they auto-link on every machine) vs
  deleted. The kit does NOT migrate unversioned ~/bin strays by design.

## 2026-06-06 — config-layer audit (post-test) + docker-rootless

Owner-prompted audit of non-package configuration found:
- **docker is ROOTLESS on LinuxBeast** (rootful disabled, user dockerd,
  DOCKER_HOST in .bashrc). New component_docker_rootless (default yes):
  rootless-extras+uidmap in dev-core, disables rootful, runs
  dockerd-rootless-setuptool, enables linger for node boxes. verify.sh
  checks `docker info` reports rootless. Owner's original install script
  not located — standard setuptool path reproduces the verified state.
- dconf only 2 sections versioned in .configs (media-keys, notifications);
  ~250 sections incl. org/gnome/desktop (84 keys), shell extensions,
  deja-dup remain UNCURATED — owner to pick conventions worth promoting.
- ~/bin/aws is a DIRECTORY in PATH — phase 06 file-only linker misses it
  (TODO: link dirs too). nerd-dictation unprovisioned → Alt+s bound but
  broken until ocr-tts component grows a nerd-dictation+vosk step (TODO).
- .bashrc references unprovisioned: ~/.bun, ~/.opencode, /usr/local/go.
- Laptop dotfile/bin linking STILL PENDING — run 13 refused (no sudo
  without NOPASSWD scaffolding). Next laptop session at its own keyboard:
  validates gh-auth prompt + linking + docker-rootless conversion in one
  `./bootstrap.sh workstation install`.

## 2026-06-06 — laptop fully converged: verify 36/0

Run 14b (TTY-driven) + manual completion: dotfiles/bin linked, dictation
chain provisioned (nerd-dictation clone, vosk in pyenv global, lgraph
model — wrapper made version-agnostic in .configs), docker converted to
rootless (stale rootful socket was the blocker — now cleared by the
component) with linger for lid-closed operation. hello-world runs rootless.
verify.sh: **36 pass / 0 fail**.

Remaining manual on LeBuntu: BIOS VT-x, Studio first launch, gh auth
(device flow — validates the untested prompt), Wayland typing check for
dictation (ydotool if needed).

## 2026-06-06 — LeBuntu in-session test: ocrscr + TTS VERIFIED WORKING

Laptop-side Claude ran the HANDOFF-LeBuntu.md interactive tests at the real
GNOME Wayland session (not SSH). All three custom tools now confirmed live.

- **ocrscr: WORKS** after one fix. The portal helper stripped `file://` but
  not percent-encoding — GNOME saves "Screenshot From <date>.png", the URI
  encodes the spaces, the decoded-less path didn't exist → silent exit 0.
  Fixed with `GLib.filename_from_uri` (.configs 41f911d). End-to-end pass:
  portal area-select → tesseract → wl-copy text matched the capture exactly.
- **TTS: WORKS** (kokoro on CPU, ~1 min model load, vlc → PipeWire, audio
  confirmed by owner). Two provisioning gaps found and encoded:
  1. `~/bin/tts-clipboard-{client,server}` were STALE REAL COPIES (rsync
     seed, mode 644, shebang → nonexistent kokoro-tts venv) silently
     shadowing the fixed .configs versions — phase 06 "never clobber" warn
     wasn't enough. Replaced with symlinks live; verify.sh now FAILS on any
     real file shadowing a .configs/bin tool (new check 4d).
  2. `~/.config/autostart` was never wired (dir didn't exist) — tts-server
     would never autostart. Linked live; 06-configs.sh now links
     .configs/.config/autostart/*.desktop; verify.sh checks it (4e).
- **Icons/dock: CONFIRMED** by owner — both launchers in app search with
  correct icons. tts.desktop wasn't pinned (favorites had only ocrscr);
  added via gsettings. verify.sh now checks dock pins in-session (4f).
- Note: tts-server reads the PRIMARY selection (xsel default = highlighted
  text), not Ctrl+C clipboard — works through Mutter's XWayland sync. By
  design; documented here so nobody "fixes" it.

## 2026-06-06 — dictation on Wayland (resolved, no action needed)

Alt+s on LeBuntu works end-to-end. The "allow remote interaction" dialog
is GNOME/Wayland gating synthetic keystroke injection (xdotool/XTEST) — a
per-app, revocable, LOCAL input-injection consent (not network). LinuxBeast
never showed it because it runs X11 (ungated). Owner accepted the one-time
grant ("remember" ticked → no re-prompt). Component's Wayland warn stays
informational; ydotool auto-fix NOT wired (rejected: standing uinput daemon
is a broader privilege than the one-time consent). Xorg session would also
avoid it. No further work.

## 2026-06-07 — reconciled LeBuntu's in-session fixes; hardened wiring

Laptop-side Claude tested the 3 custom tools in a live GNOME Wayland session
(owner watched/listened): ocrscr, TTS (kokoro on CPU), dictation — all ✅,
verify.sh 44/0 there. Reconciled its 3 commits via git am -3 (clean, no
conflicts):
- .configs: portal helper URI decode (GLib.filename_from_uri — GNOME's
  "Screenshot From <date>.png" percent-encodes spaces; bare file:// strip
  gave a nonexistent path → silent OCR no-op) + gitignore __pycache__.
- setup-kit: verify 4d/4e/4f + autostart linking + this entry's base.

**Hardening from the lesson (handoff 3a/3b):** rewrote 06-configs' four
hand-written symlink blocks into one `link_one`/`link_tree` primitive that
HEALS stale ~/bin real files (identical → silent relink; DIVERGENT → backup
to .pre-setup-kit + loud flag, since a source-box real file may be newer).
detect (verify 4d) + heal now symmetric. Autostart is exec-gated in the
helper. X11/maim ocrscr path confirmed intact on LinuxBeast (this box).

**Note (handoff 3d, not automated):** TTS first `speak` pulls the kokoro
model from HuggingFace + loads torch on CPU (~1 min, no progress UI) — looks
like a hang on a fresh box. Pre-warm or a "downloading model…" notify is a
future nicety.

**Surfaced on LinuxBeast (not acted on — daily driver):** verify flags
~/bin real files shadowing .configs/bin (dbash, search, genpass, uspace,
simple-scan-postprocessing.sh) + some unlinked (pulse_recorder, mountbug,
pdfstrip) — likely uncommitted ~/bin edits. Owner to reconcile into .configs.

## 2026-06-07 — python policy: global=system; TTS in a dedicated venv

Owner caught it: pinning pyenv global to 3.12 (the prior policy) made the
.fancy_prompt pyenv-version indicator fire in EVERY dir, defeating its
purpose (it should flag only projects that diverge from system via a
.python-version). Fix:
- **Kit policy: pyenv global stays `system`.** 04-languages no longer pins
  it; installs 3.12 as an *available* version. system python3 ships via apt.
- **TTS deps → dedicated `kokoro-tts` pyenv virtualenv** (NOT global, NOT
  the bare 3.12). Shebangs: #!~/.pyenv/versions/kokoro-tts/bin/python —
  stable across machines (name, not patch), resolves regardless of global.
  Name is `kokoro-tts` (not `tts`) to avoid colliding with the owner's
  existing 3.10.16 `tts` env.
- verify: python check now = global==system + 3.12 available + system
  python3; tts check probes the kokoro-tts venv.
- dictation already global-independent (its wrapper scans versions for vosk).
- Applied to both boxes: LinuxBeast (global was already system) + laptop
  (reverted 3.12.13→system); kokoro-tts venv built + deps installed on each.

## 2026-06-07 (later) — 3.12 cleanup + dictation also gets its own venv

Cleaning the laptop's bare 3.12.13 (5.2G of redundant kokoro/torch) was
unsafe at first: 3.12.13 was the ONLY python with vosk, and the dictation
wrapper resolved to it. Fixed by mirroring the TTS pattern:
- **vosk → dedicated `vosk` pyenv venv**; nerd-dictation wrapper now PREFERS
  ~/.pyenv/versions/vosk (deterministic), scans as fallback.
- kit dictation component installs vosk into the `vosk` venv (was: pyenv
  global, which is `system` now → would have failed on fresh boxes).
- Then stripped laptop 3.12.13 to a clean interpreter (5.2G → 23M). Both
  audio tools verified after: dictation→vosk venv, TTS→kokoro-tts venv,
  nerd-dictation launches. vosk venv created on LinuxBeast too.
- verify: added vosk-venv check.
Net: global=system, bare 3.12 is a clean available version, and each audio
tool's heavy deps live in their own named venv (kokoro-tts, vosk).

---

## 2026-06-08 — COMPACTION POINT → Phase 2: make it public & curl-foolproof

### Where things are (state to carry forward)
- **setup-kit** lives at `~/git/setup-kit` (moved out of git/tmp). Clean: 70
  files / 416K tracked, no secrets tracked, `snapshot/` gitignored (has the
  WiFi PSKs + capture data). Remote `origin=git@github.com:hotpocket/setup-kit.git`,
  **NOT pushed**. Works from new location; deploy entry points present
  (get.sh, bootstrap.sh, verify.sh, hosts/example.conf).
- **Proven** on bare-metal 24.04/X11 (LinuxBeast, this box) + 26.04/Wayland
  (LeBuntu laptop, 192.168.5.33, ssh key ~/.ssh/id_ed25519_lan). Next real
  target = a fresh 26.04 bare-metal box, off-harness.
- **.configs** (github hotpocket/.configs) is **PRIVATE**, integral to
  setup-kit (phase 06 clones it + runs its setup.sh). Today's .configs fixes
  (kokoro-tts/vosk venvs, ocrscr/TTS/pbcopy Wayland, etc.) are committed
  locally, **NOT pushed**.

### The Phase-2 blocker (the decision to make)
To make `curl …/get.sh | bash` foolproof on a fresh machine, BOTH repos must
be cloneable without auth → both must be **public**. But **.configs contains
private data** (current files AND git history):
- `bin/aws/*.json` — Route53 DR backups: domains (brandonlandry, qualiasys,
  blackredwood, backyard-barbershop, sse.ninja), public EC2 IPs, cert tokens.
  **Functionally needed** by `bin/aws/domains` restore path (owner's DR plan
  — KEEP, but must relocate out of a public repo).
- `Desktop/DailyReprieve.desktop` — private Google Sheet link.
- `.gitconfig` email; `s` alias references ssh key filename (low risk).
- (graf ssh alias already moved → ~/.bashrc_local; restore-batch.json is a
  transient temp artifact, cruft.)

### Phase-2 plan (proposed, not yet done)
1. Decide: split .configs into public dotfiles vs private store, OR scrub.
2. Move private bits (bin/aws DR data, sheet link) to a SEPARATE PRIVATE repo
   / encrypted store (owner wants to grow this DR pattern anyway).
3. Scrub .configs git history of those paths (git filter-repo), gitignore the
   transient *-batch.json.
4. Make setup-kit's `.configs` clone point at the now-public .configs (it
   already does); confirm no auth needed.
5. Push both public. Test curl|bash on the fresh 26.04 box.

### Hard rules (unchanged)
NEVER push — owner pushes. Two repos: ~/git/setup-kit + ~/git/.configs.
Commit trailer: Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>.
