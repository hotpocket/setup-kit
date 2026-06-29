# vault — opt-in component (workstation profile)

Persistent Obsidian-based memory skill for coding agents: orient from a
knowledge vault at session start, look up architecture/component notes, and
write discoveries back across sessions.

- Source: `~/git/claude-conduct/skills/vault` (our canonical copy)
- Origin: MIT, vendored out of a private repo (upstream
  adamtylerlynch/obsidian-agent-memory-skills). We own the copy now.
- Skill link: `~/.claude/skills/vault`

## Dependencies

- **obsidian** — already provisioned (`manifests/debs.list`).
- A per-project `vault/` dir (the `conduct` skill scaffolds one). Cross-project
  discovery is via symlinks under `~/Documents/AgentMemory/<project>` — created at
  project-init time, NOT by setup-kit.

## Setup-kit integration

- Installed by `profiles/workstation/08-claude-skills.sh` (clones
  `~/git/claude-conduct`, symlinks the skill).
- Do NOT track Obsidian runtime state: `~/.config/obsidian/obsidian.json`
  (GUIDs, absolute paths, open-state) is machine-specific — let Obsidian
  regenerate it.
- claude-conduct lives at `git@github.com:hotpocket/claude-conduct.git`; phase 08
  clones it on a fresh box and symlinks the skill into `~/.claude/skills/vault`.
