# Worker — manual checklist (after `bootstrap.sh worker install`)

A worker runs unattended jobs. Everything here is what a human must do
because the kit refuses to: put secrets on the box, grant it identities,
and reboot it out of the desktop.

## First run (over ssh)
- [ ] `ssh-copy-id ai@<ip>` from your laptop — key auth before password login goes
- [ ] `./bootstrap.sh worker install` — it clones `.configs` (device-code
      login if the ssh key can't), installs the worker apt set, builds pyenv
      3.12 + the kokoro venv (GPU torch verified), whisper, Claude Code
- [ ] **Reboot.** The default target is now `multi-user.target`; the autologin
      GNOME session on the console keeps ~1 GB until you do
- [ ] `./bootstrap.sh worker` (doctor) comes back clean; triage `logs/missing.log`

## Machine credentials (never automated, never SSO)
- [ ] AWS: `aws configure --profile cron-deploy` with the job-scoped access key
      (bucket + CloudFront invalidation only). `chmod 600 ~/.aws/credentials`.
      The doctor proves it with `sts get-caller-identity`.
- [ ] Git: `03-headless` generated `~/.ssh/id_ed25519_worker`. Register the
      `.pub` as a **deploy key on the job repo** (GitHub allows one repo per
      key) or on a machine user if several repos are needed. No YubiKey keys
      on this box — a cron can't touch one.
- [ ] `.configs` was cloned via `gh` https if the deploy key couldn't open it;
      `gh auth status` shows the token. Rotate/revoke it from GitHub, not here.

## Wiring the job
- [ ] Run it as a `systemd --user` timer + service, not a crontab: journald
      logs (`journalctl --user -u <job>`), `OnFailure=`, `EnvironmentFile=`
      carrying `AWS_PROFILE=cron-deploy`, no PATH surprises. Linger is on, so
      it runs with nobody logged in.
- [ ] Voice/model caches are per-user (`~/.cache/huggingface`, kokoro
      weights) — run the job once by hand to warm them before trusting the timer.

## .configs on a headless box
- [ ] `setup.sh install` ran (it owns the claude hooks/router this box needs).
      Check `systemctl --user status tts-server` stays inactive (condition/
      target) and nothing complains about dconf without a session; if it
      does, add a headless gate in `.configs/setup.sh` — that repo's job.

## Bringing the console back (only if ever needed)
- [ ] `sudo systemctl start gdm3` — Proxmox noVNC shows the desktop again;
      `sudo systemctl stop gdm3` when done. The default target is untouched.
