# Workstation — manual checklist (after `bootstrap.sh workstation install`)

## Verify the run
- [ ] `./bootstrap.sh workstation` (doctor) comes back clean
- [ ] Review `logs/missing.log` — triage anything the installers couldn't get
- [ ] Log out + back in (groups: docker/kvm; shell init for pyenv/nvm)

## Credentials & sign-ins (never automated)
- [ ] SSH keys: restore from password manager / hardware backup → `~/.ssh`
      (the kit does NOT migrate keys); then `ssh -T git@github.com`
- [ ] Flip `.configs` remote back to ssh if it was cloned via https:
      `git -C ~/git/.configs remote set-url origin git@github.com:hotpocket/.configs.git`
- [ ] `gh auth login` · `aws configure` / SSO · `gcloud auth login`
- [ ] GPG: import secret keys from offline backup
- [ ] Browsers (Chrome/Brave/Firefox): sign in + sync
- [ ] VS Code settings sync · Zoom · Steam
- [ ] WiFi password (if WiFi machine) — type it once, NM remembers
- [ ] Ubuntu Pro: `sudo pro attach` (livepatch, esm)

## Flutter / Android
- [ ] Launch Studio once (`~/android-studio/bin/studio.sh`) → SDK wizard
- [ ] Create an AVD in Device Manager; `flutter doctor` then
      `flutter doctor --android-licenses`
- [ ] Emulator boots AND is hardware-accelerated
      (`emulator -accel-check` → KVM ok; if not, see /dev/kvm doctor output)

## Dev smoke tests
- [ ] `pyenv versions` · build one project env (e.g. mbox-parser) from its pip freeze
- [ ] `nvm current` = LTS · `npx tsx --version`
- [ ] `docker run --rm hello-world` (after re-login for group)
- [ ] `java -version` (current JDK) · `mvn -v`
- [ ] open a flutter project: `flutter pub get && flutter run -d linux`
- [ ] GPU (if NVIDIA): `nvidia-smi`

## VM-specific (workstation under Proxmox)
- [ ] `qm set <vmid> --cpu host` was applied (emulator needs it)
- [ ] qemu-guest-agent active (host shows IP in Proxmox UI)
- [ ] First `vzdump` backup scheduled on the host; restore tested once
