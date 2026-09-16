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
      (bucket + CloudFront invalidation only), then
      `profiles/worker/seal-aws-profile.sh cron-deploy` (install mode runs it
      for you): the key becomes a user-scoped systemd-creds blob bound to the
      TPM2 + host key + uid + machine-id at
      `~/.config/credstore.encrypted/aws-cron-deploy.cred`, the profile gets a
      `credential_process`, and the plaintext section is dropped only after
      STS succeeds through the sealed path. The doctor reads the blob header:
      a seal made before the VM had a TPM is reported as host-key-only and
      upgraded by re-running the helper once a vTPM exists (Proxmox:
      `qm set <vmid> --tpmstate0 <storage>:1,version=v2.0`, cold start).
      A restored snapshot or a new machine cannot open the blob — re-seed.
- [ ] Git (`git_auth=token`): one **fine-grained PAT** (user › Settings ›
      Developer settings › Fine-grained tokens), "only select repositories" =
      the repos in `clone_repos` (+ `.configs` if it is https). Repository
      permissions: Contents read-only, or read-and-write when the job pushes;
      nothing under Account permissions. Paste it into `github_token_file`
      (mode 600). Install logs `gh` in with it and sets the credential helper;
      the doctor proves it can read each https repo. Revoke/rotate from
      GitHub; on the box just replace the file and re-run.
- [ ] Git (`git_auth=deploy-keys`): one read-only deploy key per repo from
      `deploy_repos`; register each `~/.ssh/deploy_<name>.pub` on that repo's
      Settings › Deploy keys. GitHub allows one repo per key.
- [ ] Both (`git_auth="deploy-keys token"`): the two lines above, each for its
      own repos — a repo named in `deploy_repos` never touches the token.
- [ ] `git_push=allow` (this box's agents and cron may push): the credential
      covering EVERY repo it is expected to push must be **read-write**. A
      deploy key is read-only by default (tick "Allow write access" per repo)
      and a fine-grained PAT needs Contents: read-and-write. A read-only
      credential turns a push into a 403 at 3am with nobody watching — list the
      repos the jobs push and check each one. `./bootstrap.sh worker install`
      then writes `~/.claude/git-push-allowed`; without it the conduct hook
      denies every push no matter what the credential allows.

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
