---
tags: [session]
type: session
concerns: [infra, ops, testing]
audience: []
summary: "ai-3090 took over the Diary of a CEO line: the worker needed only the learn-video skill (claude_skills in the host conf; whisper-ctranslate2 and the headless claude login were already there) and a seed of the published audio from S3. lang_node=yes brought node + aws-cdk for deploy-stack.sh; the sizes.conf row was 700M from a workstation with cached node versions and is 278M measured (aws-cdk 24M), corrected in 4dc1147. The kit gained git_push=allow|deny (02b127a): 03-headless writes ~/.claude/git-push-allowed and the conduct hook reads it, so Claude and the line's cron push on a worker while a workstation keeps pushes manual. Live: the PAT pushes audiobook, chatterbook, books, wbt, bookshelf; GitHub 403s setup-kit and landry-ui; .configs is a read-only deploy key here. A seed done by hand left .book_id out of the build dir and the first auto-publish minted a phantom book id."
created: 2026-09-16
status: completed
projects: [setup-kit]
branch: main
---

# 2026-09-16 — ai-3090 takes the DOAC line; the worker pushes

## What happened

- The Diary of a CEO line (bookshelf `books/diary-of-a-ceo`) now runs on ai-3090 under the audiobook tick. The kit side was small: `learn-video` added to `claude_skills` in `hosts/ai-3090.conf` and phase 08 re-run (the skill holds the two gate scripts make-chapter.sh calls); `whisper-ctranslate2`, `yt-dlp`, `ffmpeg` and the logged-in `claude` were already provisioned. `claude -p` was smoke-tested before the line started.
- The audio for three published books was pulled back from S3 (`books/scripts/fetch-book.sh`) into `chatterbook/books/<slug>/chapter_audio` — a hand procedure, not a kit step. The fetch writes `.book_id` next to the audio and the brief left it in the fetch dir: the first auto-publish generated a new id (8bb21ab680e6) and uploaded 138 objects before it was killed. The real ids were then written into all three build dirs. The chatterbook and transcript-side consequences of a seed without WAVs are in chatterbook's recap.
- `lang_node=yes` on ai-3090: deploy-stack.sh needs cdk, cdk needs node. A fresh nvm + one LTS + aws-cdk/corepack/tsx measured 278M (aws-cdk 24M); the row said 700M, measured on a workstation with several node versions cached. Corrected with its provenance (4dc1147). cdk is present; the `landry` SSO profile is not, so a stack deploy from this box still needs `aws sso login --profile landry --use-device-code` or a deploy-scoped machine credential.
- **git_push knob** (02b127a): `hosts/worker.example.conf` gains `git_push=allow|deny` (default deny); `03-headless.sh install` writes or removes `~/.claude/git-push-allowed` (one line: host, conf, value, date) and `check` reports it; `.configs`' `deny-git-push.sh` exits 0 when the marker exists; both CLAUDE.md rules became two-mode (workstation: the user pushes; worker in allow mode: Claude and the line's scripts push and say what they pushed; never force-push on either). `tests/test-git-push-allowed.sh` runs the hook with a fake HOME: 9 of 13 cases red against the unmodified hook and phase, 13 green after. The `.configs` commits (d21ef0b hook + rule, 3f4dafb root CLAUDE.md) cannot be pushed from this box.
- Pushes exercised the same hour: audiobook, chatterbook, books, wbt and bookshelf pushed; setup-kit and landry-ui returned 403 (`gh api repos/.../permissions` shows the account's rights, not the fine-grained token's repository list); `.configs` returns 404 to the PAT and its remote is the read-only deploy-key alias.
- Memory notes written for this project: `delegate-mundane-work-to-agents` (tests, seeding, polling go to sonnet/opus agents; the main thread keeps decisions), `verify-agent-work` (check an agent's claims against the tree, never redo its task), `ai-3090-git-push` (allow mode and which repos the token can actually push).

## Decisions

- Pushes are decided by the box, not by the rule text alone: the marker is written by the kit from a declared conf value, so a fresh worker gets the same answer as this one.
- `sizes.conf` rows are corrected on a real install, as the file's rule says; this one was off by 2.5x.

## Next

See [[setup-kit]] todos: widen the PAT; `bootstrap.sh list` filter; a seed script that carries `.book_id`; the phantom-id cleanup.
