---
tags: [session]
type: session
concerns: [security, infra, ops, testing]
audience: []
summary: "ai-3090 (Proxmox VM 102 'Audiobooks' on linuxbeast2) got a vTPM 2.0 and its books-publisher AWS key is no longer plaintext: it is a user-scoped systemd-creds blob bound to TPM2 + host key + uid + machine-id, opened by the aws CLI through credential_process, verified live from a systemd --user service. The kit gained seal-aws-profile.sh (plaintext → blob, plaintext dropped only after STS succeeds through the sealed path), a doctor check that reads the blob header to tell a TPM seal from a host-key-only one, tpmstate0 in the VM-creation script, and tests/test-aws-sealed.sh. The user's root snapshot of VM 102 postdates the seal."
created: 2026-09-16
status: completed
projects: [setup-kit]
branch: main
---

# 2026-09-16 — vTPM on ai-3090; the aws job key is sealed

## For Humans

- ai-3090 is Proxmox VM 102 ("Audiobooks") on host linuxbeast2. It had no TPM chip at all, virtual or otherwise, so the AWS key its publishing jobs use sat as plain text in a file. The VM now has a virtual TPM 2.0, added from the host with a cold start.
- The AWS key is sealed: it lives as an encrypted blob that only this user, on this machine, with this TPM can open. The aws command opens it itself when a job runs, so nothing else on the box changes. Proven live: the publishing identity authenticates with the plain-text file hidden, and from a background systemd user service (how the timers will run).
- The kit now does this for any worker: install mode converts a hand-seeded key, and the doctor reports whether a key is plain text, sealed to the TPM, or sealed to the host key only (a seal made before the box had a TPM). The plain text is deleted only after the sealed path has authenticated, so a failure anywhere leaves the key usable.
- Every VM the kit creates gets a vTPM from now on. Existing VMs need one added by hand.
- The root snapshot of VM 102 is taken after the seal (the user's decision, assume it holds). Rolling back to it or anything later keeps the sealed key working. Only an older restore, a new VM, or a re-minted vTPM needs the key re-seeded.
- The box boots to GNOME on the Proxmox console as its host conf asks (`boot_target=graphical`); the doctor reports it OK.

## Next Steps

- [ ] `tests/test-aws-cli-v2.sh` case C ("no aws on PATH") fails on any box with `/usr/bin/aws` (ai-3090 has the Ubuntu 26.04 package), because the test's base PATH keeps `/usr/bin` for coreutils. Pre-existing; needs the test to build a bin dir of just the tools it uses instead of inheriting `/usr/bin`.

## For Agents

Context: read § For Humans first; this section adds the operational detail.

- Commit to read before touching worker credentials: 9243d58 (`profiles/worker/seal-aws-profile.sh`, `lib-aws-creds.sh`, the doctor's §5 block, `tests/test-aws-sealed.sh`, `tpmstate0` in `profiles/proxmox-host/04-create-workstation-vm.sh`). Its message records the order of operations that makes the conversion safe and the header-UUID instrument.
- Why user-scoped systemd-creds and not a system unit: `systemd-creds encrypt --user` goes through the system's credentials service at `/run/systemd/io.systemd.Credentials`, so the user needs no `tss` group and no direct TPM access, and the aws CLI's `credential_process` runs `systemd-creds decrypt` wherever a job runs (timer, cron, shell). `--with-key=tpm2` is refused in user scope by design; `auto`, `host` and `host+tpm2` all produce the `HOST_AND_TPM2_HMAC_SCOPED` header (`ef4ac136…`) when a TPM is present and `HOST_SCOPED` (`55b9ed1d…`) when not. There is no TPM-only user-scoped type. The doctor's kind table lists the newer `_PINNED_SRK` and `_WITH_PK` scoped UUIDs too.
- The seal is proven with the static file masked (`AWS_SHARED_CREDENTIALS_FILE=/dev/null`) because botocore consults the shared credentials file before `credential_process`; while both exist, plaintext wins silently, so a success without the mask proves nothing about the sealed path.
- Rejected: a plaintext backup of the key before sealing (defeats the purpose; the key is re-mintable from IAM on VM 101 as recorded in the previous recap); a wrapper script or user unit to feed the key (credential_process makes both unnecessary).
- Host-side facts not visible from the guest: `qm set 102 --tpmstate0 local-zfs:1,version=v2.0` (size ignored, 4 MiB swtpm state); the VM's snapshots were collapsed to a new root `tpm-baseline` that includes `drive-tpmstate0`; the Proxmox host is unreachable from the guest (password-only ssh), so every `qm` command is the user's to run.
- `systemd-creds encrypt` writes its output file mode 0644 — the helper writes to a temp file and chmods 600 before moving it into place. `systemd-analyze has-tpm2` (systemd 259) prints `yes|partial|no`; `partial` was this VM before the vTPM: tss2 libraries present, no firmware, no driver.
