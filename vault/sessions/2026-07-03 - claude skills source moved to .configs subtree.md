---
tags: [session]
type: session
concerns: [ops]
audience: []
summary: "Phase 08 now installs vault/conduct skills from the claude-conduct/ subtree inside hotpocket/.configs (standalone claude-conduct repo subtree-merged + archived 2026-07-03), and links ~/bin/deny-git-push.sh — the globally-registered PreToolUse no-push guard — closing the registration-without-script gap on fresh boxes."
created: 2026-07-03
status: completed
---

# claude skills source moved to .configs subtree (session ran in ~/git/hh)

- `profiles/workstation/08-claude-skills.sh`: vault/conduct repo/url/path → `~/git/.configs` (`claude-conduct/` subtree); added `~/bin/deny-git-push.sh` link (chmod+x, miss-flag if template absent). Rationale: settings.json hook registrations (.configs) and the scripts they invoke (were: claude-conduct) must land in ONE repo atomically — a bootstrap re-run had stranded them.
- `components/{conduct,vault}.md` + `vault/todos/setup-kit.md` updated to the new paths; session ledgers untouched.
- Commit `35fd395`, unpushed. Full story in .configs' recap [[2026-07-03 - conduct subtree-merge + global no-push guard]] (its vault).

Next: re-verify `bootstrap.sh workstation check` end-to-end wires skills + both ~/bin links from the subtree (existing todo updated).
