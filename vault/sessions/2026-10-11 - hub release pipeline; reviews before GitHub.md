---
tags: [session]
type: session
concerns: [infra, ops, security, testing]
audience: []
summary: "git-hub release: a user path unit on the hub's receive log turns 'worker pushed main to the hub' into a release. Content forwards unattended (vault/, docs/, git_hub_content globs) only if no secret, big blob, instruction file or rejected sha is anywhere in the range; code opens one leased review thread in beast-vm:setup-kit that ends in `git-hub verdict <repo> <sha> pass|reject`, which forwards exactly the reviewed sha. Hub behind GitHub is back-propagated; branches already in main are deleted; feature branches are never merged. Sol found 18 fail-open/race defects across four rounds, all fixed with a test each. Backlog cleared through it the same day."
created: 2026-10-11
status: completed
projects: [setup-kit, .configs, books, proxmox_setup_plan]
branch: main
---

# 2026-10-11 — hub release pipeline; reviews before GitHub

## For Humans

When ai-3090 finishes work it merges into main and pushes to the hub on Beast-VM. Before today nothing acted on that, and finished work sat on the hub. Now a push wakes `git-hub release`. Data-only pushes (vault notes, docs, bookshelf book data) go to GitHub on their own. Anything that changes code opens a review thread on Beast: Opus runs the repo's tests, Sol reviews code with broad impact, and only a pass sends that exact commit to GitHub. A reject goes back to the worker with the reason. Every outcome is one line in `~/.local/state/git-hub/release.log`.

## Decisions and why

- **Trigger = systemd path unit on `/srv/git/log/receive.jsonl`** (+30-min timer backstop), not a T3 `schedule_task`: it fires on the event and costs no tokens when idle. Linger must be on (the install checks it).
- **Base = GitHub's main via ls-remote**, not a local state file: hand forwards from elsewhere stay visible.
- **Fail closed everywhere.** The class Sol kept finding: a check whose failure, or whose narrow view, reads as "clean". Producers go to files with their status checked. Every commit in the range is classified, not just the endpoints. Agent instruction files (CLAUDE*, AGENTS*, .cursor/, .github/ …) are never content.
- **A rejected sha holds its range.** Content on top neither forwards it nor reopens its review. Without this, bookshelf's frequent data pushes would re-review the same rejected code and burn Sol.
- **books mutation gate keys survivors by mutation**, not mutmut's positional ID (scripts/mutant_keys.py). This cut 58 false "new" survivors to 17 real ones. The worker then killed or accepted those.

## Gotchas

- `~/.local/bin/git-hub` links into this working tree, so uncommitted edits run live. It caused one duplicate audiobook review mid-development. Open: pin the link to a checkout of pushed main.
- Pushing to GitHub by hand from Beast can carry hub commits that haven't been reviewed. Check that hub main is an ancestor of origin/main before you push.
- The t3x CLI is a bun script, so the user unit's PATH needs `~/.bun/bin`.
