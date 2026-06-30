---
tags: [session]
type: session
concerns: [ops, infra]
audience: []
summary: "Added `bootstrap.sh list` (aliases components/--list) — a post-install discoverability subcommand that reads hosts/example.conf as the catalog and overlays each flag's current value from the host conf. Three headings: groups & components + language stacks (configurable), conditional (informational, hardware-detected). Rewrote every group_/component_/lang_ description in example.conf to state purpose, not contents/state. Documented in CLAUDE.md. Commits 1969693 + 262236c."
created: 2026-06-30
status: completed
projects: [setup-kit]
branch: main
---

## Context

Discoverability gap: enabling a component after first install (e.g. mtga) meant hand-editing `hosts/<host>.conf` with no way to list what's available. The first-run opt-in menu (`bootstrap.sh:62`) fires once, gated on `groups_selected`, and only ever covered *groups* — components were always conf-file-only.

## Work Done

1. New `bootstrap.sh list` (aliases `components`, `--list`): parses `hosts/example.conf` as the source catalog, annotates each flag with its current value via `conf_get`. Added to usage header + dispatch.
2. Widened to three headings — **groups & components** (configurable), **language stacks** (configurable), **conditional — INFORMATIONAL, hardware-detected**. `cond_*` lines are parsed by stripping the leading `# ` (they're commented defaults).
3. Rewrote every `group_`/`component_`/`lang_` description in `example.conf` to state *purpose* ("what it's for"), not contents or state.
4. Documented the subcommand in `CLAUDE.md` under Entry points.

## Discoveries

- `list` reads the **template** (`example.conf`), not the host conf, so it shows the full menu even on a fresh box with current values overlaid.
- `--list` is NOT a full inventory of setup-kit: it omits sub-settings (`swap_policy`, `claude_skills`, `review_over_mb`, `calm_*`), dotfiles (`configs_*`), and always-on items (clipboard TTS, unconditional phases 00–08) — nothing to toggle there.
- Descriptions are single-sourced in `example.conf` comments; `list` just renders them.

## Decisions

- Catalog source = `example.conf` template (full menu), current state = `conf_get` overlay. Keeps fresh-box and configured-box output identical in shape.
- Good flag descriptions state purpose/why-you'd-flip-it, not the package list or on/off default. Tautologies (`PHP`="PHP") and state-strings (`oom_zram`="default ON") were treated as failures and rewritten.

## Next Steps

Nothing loose — feature complete, verified (`./bootstrap.sh list` runs clean), committed (`1969693`, `262236c`), unpushed. No open TODOs.
