---
tags: [session]
type: session
concerns: [infra, ops, security, testing]
audience: []
summary: "The kit gained two opt-in components and ai-3090 runs both: component_t3code (T3 Code, a web front end for the coding agents on a box — self-contained t3 binary, systemd user unit from `t3 service install`, bind address in a kit-owned drop-in reconciled by content, port pinned; live on 0.0.0.0:3773, verified from the LAN) and component_codex (OpenAI Codex CLI from its standalone installer, login by the user via device-code, doctor reads `codex login status`). Both have doctors, verify.sh coverage and calibration tests (tests/test-t3code.sh, tests/test-codex.sh). Hermes Agent is planned for the same box; the integration questions are in the TODO file, undecided."
created: 2026-09-17
status: completed
projects: [setup-kit]
branch: main
---

# 2026-09-17 — t3code and codex on ai-3090; hermes pending

## For Humans

- The worker VM ai-3090 now runs T3 Code, a web front end for the coding
  agents on the box, as a user service reachable from the LAN. Phones and
  desktops pair once with a one-time link (`t3 pair`).
- It fronts two agents: Claude Code (already signed in) and OpenAI's Codex
  CLI, newly installed and signed in with the ChatGPT subscription via
  device-code login.
- Both are opt-in setup-kit components with a doctor, a verifier and
  calibration tests. Both installed clean on first run; sizes were measured
  and recorded (`~/.t3` 206M, `~/.codex` 324M).
- Hermes Agent (Nous Research's autonomous agent with cron, memory and
  messaging) is planned for the same box. The integration questions — Claude
  auth sharing, blast radius of its shell tool, ports — are written down for a
  deliberate decision before anything is installed.

## Next Steps

- [ ] `component_hermes` for ai-3090: decide auth (own API key or own
  `CLAUDE_CONFIG_DIR`, never the borrowed Claude Code login) and scoping
  (`terminal.home_mode: profile`) before installing; shape it like t3code with
  `hermes gateway install` and a drop-in by content. Tracked in
  `vault/todos/setup-kit.md`.

## For Agents

Context: read § For Humans first; this section adds the operational detail.

- 6f018cf (t3code) and 11358a0 (codex): read before touching either
  component. The messages hold the mechanism: why the bind address is a
  systemd drop-in (`t3 service install` re-renders the unit on every update;
  the launcher spawns `serve` with inherited env, so `T3CODE_HOST`/`T3CODE_PORT`
  in a drop-in reach the server), why the port is pinned (unset, T3 picks the
  next free port and no doctor can probe that), and why verify.sh grades
  "listening", not "binary present".
- Neither kit phase ever logs in. `claude auth login` and
  `codex login --device-auth` are the user's; the doctors only read
  `codex login status` (exit 0 = logged in). Device-code login must be enabled
  in ChatGPT security settings first, or the command fails without saying why.
- The t3 service PATH leads with `~/.local/bin` because the systemd user
  environment here does, so both agents are found without provider config. On
  a box where it does not, T3's Settings → Providers has a Binary path field.
- Hermes reads Claude Code's credential store by default, and refreshing that
  borrowed token can invalidate the owner's — which would take down t3code's
  Claude provider and the wbt line together. That is the constraint the hermes
  TODO exists for. Its ports (API 8642, dashboard 9119, proxy 8645; bare
  gateway none) do not clash with t3code's 3773.
