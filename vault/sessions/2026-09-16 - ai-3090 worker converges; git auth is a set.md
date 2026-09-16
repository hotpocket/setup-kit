---
tags: [session]
type: session
concerns: [security, infra, ops, testing]
audience: []
summary: "ai-3090 (RTX 3090 Proxmox VM) provisioned as an audiobook-line worker and verified live: .configs read-only by deploy key, the audiobook repos (audiobook, wbt, books, repo-story, landry-ui) by one no-expiry read-write fine-grained PAT, publishing as the books-publisher AWS identity the books repo defines. The kit gained git_auth as a set (deploy keys + token on one box, each repo served by what covers it, refusal by name when nothing does), a global git@github.com:→https rewrite so manifests naming ssh remotes clone through the token, clone_repos owner/repo:path, a boot_target knob (this box keeps GNOME on the console), and component_tts opt-out. Left: no vTPM yet so the AWS key is a mode-600 file; authorized_keys empty; graphical target set in conf but unapplied."
created: 2026-09-16
status: completed
projects: [setup-kit]
branch: main
---

# 2026-09-16 — ai-3090 worker converges; git auth is a set

## For Humans

- ai-3090 (the RTX 3090 Proxmox VM) is now provisioned as an audiobook-line worker. It clones the private `.configs` dotfiles with a read-only deploy key and the audiobook repos (audiobook, wbt, books, repo-story, landry-ui) with one fine-grained GitHub token (a *PAT*, a personal access token limited to named repos) that can push. It publishes to books.landry.bot as the `books-publisher` AWS identity the books repo already defines. All verified live.
- The kit could not express "deploy key for one repo, token for the rest" before. Now it can, and it refuses by name when a repo has no credential instead of failing a blind clone.
- A worker's boot target is now a host-conf choice; this box keeps GNOME on the Proxmox console. The kokoro clipboard-TTS venv is opt-out; this box renders with Chatterbox and dropped 5.9 GB of torch.
- The voice-agent / control-plane architecture the user is designing lives on other hosts and stays out of this repo.
- Not done: no vTPM (virtual TPM chip) on the VM yet, so the AWS key sits in the credentials file at mode 600; `~/.ssh/authorized_keys` is empty; graphical target set in conf but not yet applied (needs the user's sudo + reboot).

## Next Steps

- [ ] Seal the `books-publisher` AWS key with systemd-creds once the VM has a TPM 2.0 device, and teach the worker doctor (`profiles/worker/03-headless.sh` §5) to verify the sealed credential and the unit that loads it instead of a plaintext profile.

## For Agents

Context: read § For Humans first; this section adds the operational detail.

- Commits to read before touching worker auth: 7386e22 (git_auth as a set, `clone_repos` `owner/repo:path`, the global `url.insteadOf` that turns `git@github.com:` into https — audiobook's repos.yml names ssh remotes and this box must never hold an account ssh key; `tests/test-git-auth-mixed.sh`), 8d24c67 (`boot_target`, `tests/test-boot-target.sh`), 4e64973 (`component_tts` opt-out), 5f48eaa (tests must export `KIT_LOG_DIR`, not `LOG_DIR`, or they append to the real `logs/missing.log`).
- Rejected: per-repo PATs on one box (same reader, same disk — no isolation gained); a separate `worker` service user (the .configs setup targets the login user's home; `ai` is the worker); deploy keys for the audiobook repos (they cannot push or open PRs; a PAT's permissions are uniform across its selected repos, hence one read-write token for that set and a deploy key for read-only `.configs`). The token has no expiry by the user's decision: a silent expiry breaking an unattended cron is worse than a leak of a repo-scoped token.
- Cross-repo coupling: `hotpocket/audiobook` (singular) is the orchestrator; its `scripts/bootstrap` clones `bookshelf` and `chatterbook` inside it, so the kit lists only the parent. `books` must live at `$GIT_HOME/landry.bot/books` (audiobook's `scripts/lib/env.sh` expects it there). The publisher IAM user, its three policy statements (S3 Put/Get/List on the content bucket, DynamoDB Get/Put/Query on the books table, one CloudFront invalidation), and `BOOKS_AWS_PROFILE=books-publisher` are all defined in the books repo; the setup-kit host conf only names the profile.
- `.configs` is the source of two live gaps on this box: `.bashrc` hardcoded `/home/brandon/.pyenv/bin` (fixed and committed locally in `.configs` as 10a6837; the deploy key is read-only, so it pushes from VM 101), and 11 more files name `/home/brandon` (bin/tts-clipboard-server, bin/tts-clipboard-client, bin/magic, bin/transcribe_and_play.py, setup.sh, .bash_aliases, four .desktop files). `logs/missing.log` also shows `.configs` `settings.json` registering `deny-git-push.sh` with no such script, and gstack linked with no `bun`.
- Tool gotcha: `bootstrap.sh` run under sudo makes every phase refuse (`must run as your normal user`); the 2026-09-16 04:07 run log is that, not a real failure.
