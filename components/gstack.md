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

## Host traps (learned 2026-07-16, Ubuntu 26.04)

Two independent layers break browse's default (Playwright-managed) browser;
phase 08 now guards both:

1. **Playwright < 1.61 cannot install browsers on Ubuntu 26.04** (no registry
   entry for `ubuntu26.04-x64`). Worse, `npx playwright install` garbage-collects
   the existing cached browsers *before* failing — it converts "old but working"
   into "nothing works". Fix: bump `playwright` to `^1.61` in gstack's
   package.json → `bun install` → `bun run build`. Ubuntu 26.04 support landed
   in Playwright 1.61 (microsoft/playwright#40117).
2. **AppArmor userns restriction** (`kernel.apparmor_restrict_unprivileged_userns=1`,
   Ubuntu 24.04+): Playwright-downloaded browsers have no AppArmor profile, so
   Chromium's sandbox aborts ("No usable sandbox!"). System Chrome only works
   because its deb ships `/etc/apparmor.d/chrome`. Phase 08 installs the
   equivalent `/etc/apparmor.d/playwright-chrome` (unconfined + userns, glob
   covers all `~/.cache/ms-playwright/**` versions). Never fall back to
   `--no-sandbox`.

`GSTACK_CHROMIUM_PATH=/usr/bin/google-chrome` remains a per-command escape
hatch, not the fix.

## Setup-kit integration

- Installed by `profiles/workstation/08-claude-skills.sh` when listed in
  `claude_skills` and `component_claude_skills=yes`.
- The phase clones `~/git/gstack` from upstream and symlinks the skill. It does
  NOT build the daemon — only flags the missing `bun`.
- Idempotent: re-runs are no-ops once the repo is cloned and the link exists.
