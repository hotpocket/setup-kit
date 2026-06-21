# gstack — opt-in component (workstation profile)

A browser-driving toolkit + Claude skill: lets an agent open a real browser,
navigate, and produce results for the user (research, scraping, form flows)
far more realistically than fetch-and-parse. Prominent in our Claude workflows.

- Repo: `git@github.com:garrytan/gstack.git` (third-party upstream)
- Lives at: `~/git/gstack` (cloned, not vendored — we track upstream)
- Skill: `SKILL.md` at the repo root; symlinked to `~/.claude/skills/gstack`

## Why it's wanted

Turns "go look this up on the web and report back" into something an agent can
actually do against live, JS-heavy sites. The per-repo `.gstack/` dirs it writes
(`browse-console.log`, `browse-network.log`) are runtime scratch — gitignore them.

## Dependencies

- **chromium** — already provisioned (`manifests/snap.list`).
- **bun** — builds the browse daemon. NOT in the kit yet; phase 08 warns and logs
  to `missing.log` if absent. (Install via the node/lang stack or `mise`.)

## Setup-kit integration

- Installed by `profiles/workstation/08-claude-skills.sh` when listed in
  `claude_skills` and `component_claude_skills=yes`.
- The phase clones `~/git/gstack` from upstream and symlinks the skill. It does
  NOT build the daemon — only flags the missing `bun`.
- Idempotent: re-runs are no-ops once the repo is cloned and the link exists.
