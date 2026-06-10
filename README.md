# setup-kit

Reusable machine provisioning: point it at a fresh Linux box (or a live
Ubuntu CD for the survey) and it becomes a machine that works the way I
expect — packages, dev toolchains, configs, conventions — without
reinstalling everything by hand.

Profile-based and idempotent: re-run any time — already-installed is success.

## Layout

```
bootstrap.sh          entry point (survey | workstation | proxmox-host)
lib.sh                shared helpers
manifests/            WHAT to install (curated, size-annotated)
  apt/                grouped package lists + optional/ + conditional/ + repos.md
  lang/               pyenv / nvm / flutter+android / optional stacks
  snap.list flatpak.list
profiles/
  workstation/        full dev desktop (bare metal or VM — same scripts)
  proxmox-host/       IOMMU/VFIO, ZFS, nested-virt, GPU-passthrough main VM
components/           opt-in/conditional extras (herdr, oom-zram, dictation/ocr/tts)
hosts/                per-machine answer files (example.conf is the template)
capture/              refresh tooling: re-snapshot a machine, regen manifests
snapshot/             raw capture data (gitignored; large + contains secrets)
```

## New box — two commands

```bash
curl -fsSL https://raw.githubusercontent.com/hotpocket/setup-kit/main/get.sh | bash
~/git/setup-kit/bootstrap.sh workstation install
```

(or one: `curl -fsSL .../get.sh | bash -s -- workstation install`)

`install` prompts once (sudo password, group menu, size review), loops
passes until nothing changes, runs the independent verifier, and offers
`gh auth login` inline when the private .configs repo needs it. Re-run any
time — it's idempotent. On a LAN without GitHub:
`SETUP_KIT_REPO=brandon@<host>:/path/to/setup-kit ... get.sh | bash`.

## Other commands

```bash
./bootstrap.sh survey                # live-CD friendly: virt flags, IOMMU
                                     # groups, GPUs, disks — qualify the box
./bootstrap.sh workstation           # doctor: report, change nothing
./bootstrap.sh proxmox-host install  # host: VFIO, ZFS, nested virt, main VM
./verify.sh                          # independent system-vs-manifest check,
                                     # plus "system calm": no failed/flapping
                                     # units, quiet journal (--settle 30 adds
                                     # load + fork-churn sampling)
```

Re-runs are idempotent: flip a group in `hosts/<name>.conf` (e.g.
`group_dev_go=yes`) and re-run install.

Dotfiles/user config are NOT duplicated here — the workstation profile
ends by cloning `github.com:hotpocket/.configs` and running its
`setup.sh install`.

## Design principles

- **Idempotent** — re-runnable; already-installed is success, not failure.
- **Doctor/install split** (the `.configs/setup.sh` convention): every
  profile has a read-only check mode that reports drift and changes nothing.
- **No silent sudo** — detect root needs upfront; one consolidated sudo
  pass; log gaps to `missing.log` instead of failing silently.
- **Capture-to-var-then-write** — never `> file` before a privileged
  command can fail.
- **Log everything** — each script writes `<script>.log` alongside stdout.
- **Detection-gated nvidia** — driver/toolkit install only when
  `ubuntu-drivers` actually supports the card (legacy GPUs → nouveau).

## Android emulator note

The emulator needs `/dev/kvm`. Bare metal: enable virtualization in BIOS.
Workstation-as-Proxmox-VM: the host MUST enable nested virtualization and
the VM CPU type must be `host` (`profiles/proxmox-host/05-nested-virt.sh`).
LXC: pass `/dev/kvm` through. The doctor checks this.

## Status

The `workstation` profile is tested and idempotent on bare-metal Ubuntu
24.04 and 26.04. The `proxmox-host` scripts are reviewed but not yet run on
a real host — read them before use. `survey` is read-only and safe anywhere.
