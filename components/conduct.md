# conduct — opt-in component (workstation profile)

Stamps a fresh repo with our reusable Claude conduct scaffold so we don't
re-instruct the agent on every new project: a `CLAUDE.md` preamble (orient from
the vault, rules of conduct, available-skills pointer, docs/ layout), a `vault/`
memory scaffold, and matching `.gitignore` lines.

- Source: `~/git/.configs/claude-conduct/skills/conduct` (canonical; the claude-conduct subtree inside .configs)
- Skill link: `~/.claude/skills/conduct`
- Invoke in a repo: `/conduct init` (or "stamp this repo")

## The docs/ convention it stamps

- `docs/` — generated documents (working notes, plans, analyses).
- `docs/reports/` — persistent, prepared deliverables to keep/share.
- `docs/logs/` — transient/ephemeral process output. **Gitignored.**

## Dependencies

- The `vault` skill (the scaffold uses `/vault init` for the vault structure).
- No system packages.

## Setup-kit integration

- Installed by `profiles/workstation/08-claude-skills.sh` alongside `vault`
  (same repo, `~/git/.configs`).
- Pure agent-behavior content — deliberately NOT in setup-kit (machines, not
  behavior). setup-kit only clones the repo and symlinks the skill.
- Canonical home is the `claude-conduct/` subtree of `hotpocket/.configs`
  (standalone `hotpocket/claude-conduct` archived 2026-07-03 — merged so
  settings.json hook registrations and the scripts they invoke land in one
  repo, atomically); phase 08 clones `.configs` and symlinks the skill.
