# herdr — opt-in component (workstation profile)

Terminal multiplexer purpose-built for running multiple AI coding agents
(Claude Code, Codex, etc.) concurrently. tmux-style server/client with an
agent-state sidebar (blocked / working / done / idle), mouse-native
panes/tabs/workspaces, and a local JSON socket API agents can use to manage
their own layout. Single Rust binary, no Electron, Linux + macOS only.

- Site: https://herdr.dev
- Repo: https://github.com/ogulcancelik/herdr (AGPL-3.0, v0.6.8 as of 2026-06)
- Maturity: young but solid — ~41k LOC Rust, ~12k lines tests, 7 CI workflows

## Why it's wanted

Solves "N agent sessions, which one is waiting on me?" — dashboard of all
agents with attention states, plus detach/reattach persistence so agents
survive terminal/SSH disconnects.

## Install options (offer as a choice; prefer package-managed)

1. `brew install herdr` — macOS/Linuxbrew; updates via brew
2. `mise use -g herdr` — if mise is already in the kit
3. Nix flake (repo has flake.nix) — if nix-based setup
4. `curl -fsSL https://herdr.dev/install.sh | sh` — installs to
   `~/.local/bin`, no root, SHA256-verified against
   https://herdr.dev/latest.json manifest
5. `cargo build --release` from source — fully self-hosted option

## Post-install

- Run `herdr` in a project dir; prefix is ctrl+b (tmux-like; configurable —
  NOTE: conflicts with tmux default prefix if both used)
- Server persists after detach (prefix+q); `herdr server stop` kills it
- Config: TOML, `[update]` channel + `[keys]` prefix etc.
- Optional per-agent integrations (Codex/Copilot/Kimi/Droid…) write hook
  scripts into the agent's own config dir — opt-in only

## Remote access model

- NO listening TCP ports; IPC is a Unix socket chmod 0600
- Remote attach = SSH only: `ssh host` + `herdr`, or `herdr --remote=host`
  (bootstraps/binary-syncs remote side over SSH stdio)
- Tailscale-friendly: nothing exposed on tailnet; trust boundary is SSH

## Security/privacy audit findings (source-reviewed 2026-06-05)

- No telemetry/analytics/crash reporting of any kind
- ONE outbound call: automatic update check on TUI startup + periodic —
  GET https://herdr.dev/latest.json (or brew API) via curl subprocess;
  notify-only, never auto-installs; NO config flag to disable (only
  debug/no-session builds skip it). Firewall-block herdr.dev if needed;
  failure is silent.
- No sudo/setuid/services/shell-rc edits; user-scoped install only
- Deps: ~17 mainstream crates.io crates, no git forks; vendors only
  libghostty-vt (Ghostty terminal emulation lib)
- Verdict: low risk, fine as an opt-in install

## Setup-kit integration

- **OPT-IN component** (it changes the daily terminal workflow) — never
  default-installed by the workstation profile
- Detect tmux usage and warn about ctrl+b prefix collision; offer alternate
  prefix in generated config
- Template `~/.config/herdr/` config TOML — candidate for promotion into
  `~/git/.configs` once a preferred config stabilizes
- Pair with Tailscale/SSH component as the "attach from anywhere" story
- For air-gapped/strict-egress profiles, note the un-disableable update
  check (block herdr.dev or build from source at a pinned tag)
