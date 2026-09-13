# Session Log

Most-recent-last index of session recaps for setup-kit.

| Date | Branch | Summary |
|------|--------|---------|
| 2026-06-29 | master | Local LLM coding stack (qwen3-coder/opencode) + Proxmox-sandbox decision — [[2026-06-29-local-llm-opencode-proxmox]] |
| 2026-06-29 | master | TTS controls + VLC→sounddevice + systemd; claude-conduct skill wired in — [[2026-06-29 - TTS client controls + VLC-to-sounddevice + systemd]] |
| 2026-06-30 | main | `bootstrap.sh list` discoverability subcommand + purpose-first conf descriptions — [[2026-06-30 - bootstrap list subcommand + purpose-first conf descriptions]] |
| 2026-06-30 | main | TTS GPU-first torch backend: cuDNN-op probe → default/cu118-Pascal/CPU; fixed silent sm_61 death — [[2026-06-30 - TTS GPU-first torch backend (cu118 Pascal fallback)]] |
| 2026-07-03 | main | Phase 08 installs skills from .configs claude-conduct subtree + links deny-git-push.sh — [[2026-07-03 - claude skills source moved to .configs subtree]] |
| 2026-07-03 | main | component_whisper (faster-whisper via pipx, srt output, ydat/ydv) + lib.sh grep -q/pipefail GPU-detection fix + deno for yt-dlp — [[2026-07-03 - whisper transcription component + lib.sh pipefail fix]] |
| 2026-09-05 | main | Fresh-VM install converges: host-decided pins skipped by conflict attribution, narrative quiet output, dock.list (exact), wine_branch, Claude Code/bun/cmdline-tools/ydotool provisioned, both YubiKey keys — [[2026-09-05 - fresh-VM install converges; narrative output, dock manifest, wine branch, YubiKey pair]] |
| 2026-09-13 | main | verify.sh run after months: three of 14 fails were the kit wrong about "correct" — virtualbox now opt-in (cond_virtualbox=yes) and verify.sh finally reads cond_* like lib.sh does; awscli moved from apt v1 to Amazon's v2 bundle (07-components + verify requires 2.x; v1 cannot do sso_session logins); github ssh stanza offered an old passphrase key before the YubiKey and the preamble check only looked for presence — fixed the machine, audit now reads order + IdentityAgent none + ~ paths. 2754126 / 4d47c63 / d495811, tests hand-mutated; one test first measured SIGPIPE not content — [[2026-09-13 - the verifier believed the manifest; virtualbox opt-in, aws-cli v2, YubiKey first]] |
