# setup-kit — TODOs

Open work for the setup-kit repo.

- [ ] Verify a fresh `bootstrap.sh workstation install` wires the new bits end to
      end: phase 08 clones .configs (claude-conduct subtree), links skills + ~/bin/{vault-digest,deny-git-push.sh}, and
      .configs installs the global SessionStart router + ~/.claude/CLAUDE.md.
      Also now: component_whisper (pipx + CUDA wheels + model pre-warm) and
      deno in 04-languages (yt-dlp JS runtime).
- [ ] Audit remaining `grep -q` pipelines under lib.sh's `pipefail` — grep's
      first-match exit SIGPIPEs the producer and flakes the pipeline (bit
      has_nvidia, fixed 2026-07-03; others may lurk). ~15 min, mechanical.
