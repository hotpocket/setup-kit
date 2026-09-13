---
tags: [session]
type: session
concerns: [ops, infra, security, testing]
audience: []
summary: "verify.sh run for the first time in months: 14 fails. Three were the kit's model disagreeing with the machine, not the machine being wrong. (1) virtualbox: was auto-on for any bare-metal host; now opt-in (cond_virtualbox=yes) because it ships a dkms kernel module, and verify.sh now reads cond_virtualbox/cond_nvidia at all — before, an opt-out made the installer skip a package the verifier failed forever. (2) awscli: the apt manifest wanted Ubuntu's v1 on a box running Amazon's v2 bundle, which dpkg cannot see; v2 is the one that does sso_session logins, so 07-components now installs the bundle and verify.sh requires aws-cli/2.*. (3) Every git push asked for an old key's passphrase before the YubiKey touch: ~/.ssh/config listed the file key first and had lost IdentityAgent none; the preamble's check only asserted the -sk key was present (by exact text) and never read order or the lock. Fixed the machine and taught the check to see order, the lock, and ~-spelled paths. Three commits, each test hand-mutated; one test's first cut measured SIGPIPE from `verify | grep -q` under pipefail instead of the report."
created: 2026-09-13
status: completed
projects: [setup-kit]
branch: main
---

# 2026-09-13 — the verifier believed the manifest

## For Humans

- `verify.sh`, the read-only check of this machine against the kit's manifests, had not been run in months. Fourteen failures. Three of them were the kit being wrong about what "correct" means, and each is now fixed at the source.
- **VirtualBox is opt-in.** It used to install on any bare-metal machine by default. It ships a kernel module and changes core system state, so the host conf now has to say `cond_virtualbox=yes`. Even then it is refused inside a VM or on a Proxmox host. The verifier also ignored every `cond_*` override before; now it reads them with the same meaning as the installer.
- **aws-cli comes from Amazon's v2 bundle, not apt.** Ubuntu's apt package is v1, which cannot do the IAM Identity Center logins that `.configs/bin/sso` drives. The kit now installs or updates v2 to `/usr/local/bin`, removes an apt v1 if it finds one, and verification requires v2. A fresh box provisioned before today got an `aws` that could not log in.
- **Git pushes now ask for one YubiKey touch and nothing else.** The ssh config listed an old passphrase key ahead of the YubiKey and had lost the agent lock, so every push was a passphrase prompt, then a touch. Fixed on this machine, and the kit's github-auth check now warns when the order or the lock is wrong instead of only checking the YubiKey key is mentioned somewhere.
- Remaining verify failures are real machine drift, not kit defects: two `.configs` tools unlinked from `~/bin`, five packages in the manifest but not installed, dock pins out of sync with the manifest both ways, and a stale icon cache. None touched.

## Next Steps

- **Introduce `GIT_HOME`** (already in the TODO file): phase 08 and `components/gstack.md` hardcode `$HOME/git` eleven times. Design decision on where the one definition lives, then a fresh-VM verification.
- **Reconcile the dock manifest with reality.** Five mismatches in both directions. Needs a decision per app on which side is right, so not a drive-by.

## For Agents

Context: read § For Humans first; this section adds the operational detail.

- Three commits carry the detail: `2754126` (virtualbox opt-in + `verify.sh` honoring `cond_*`, plus `KIT_HOST_CONF` so tests can point the verifier at a fake host conf), `4d47c63` (aws-cli v2: `lib.sh` helpers, the 07 block, the verify check, `components/aws-cli.md`, `dropped.list` entry so a re-capture does not re-propose apt awscli), `d495811` (`audit_github_stanza` in the preamble). Each has a `tests/test-*.sh` that was hand-mutated per hunk.
- The class the first two share: `verify.sh` re-derives conditionals independently on purpose, but "independent" had drifted into "reads a different set of inputs". Any future `cond_*` or install-method decision in `lib.sh` needs its twin in `verify.sh`, and a test that drives both under the same fake conf is the only thing that keeps them agreeing.
- Host confs (`hosts/<Host>.conf`) are gitignored; only `example.conf` travels. A machine's `cond_virtualbox=no` therefore lives on that machine alone, which is why the default had to change rather than the conf.
- `verify.sh` writes its FAIL lines to stderr and dies of SIGPIPE if the reader closes early. In a test under `pipefail`, `verify | grep -q` reports the pipe, not the content, in both directions. Capture to a variable, then grep. `tests/test-virtualbox-opt-in.sh` records this.
- The github-auth preamble's `pin_resident_keys` matched `IdentityFile` lines by exact text. A key written as `~/.ssh/x` was invisible to it and would have been re-added under the absolute spelling in install mode. `stanza_has_identity` now expands `~` before comparing. The audit warns only; it never reorders a user's ssh config.
- `.configs/.bash_aliases` still has an `s` alias that loads the old file key into an agent. Harmless for GitHub now that the stanza sets `IdentityAgent none`, but it is the last place that key is treated as primary.
