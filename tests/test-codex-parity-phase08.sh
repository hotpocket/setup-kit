#!/bin/bash
# Codex (Sol) gets its skills, MCP servers and hooks from .configs/setup.sh
# codex, which derives them from Claude's installed set. Phase 06 runs
# .configs/setup.sh install BEFORE this phase links Claude's skills, so on a
# fresh box Codex saw none of them (ai-3090 2026-11-03: Claude 4 skills, Sol 4).
# Phase 08 must re-derive after it links.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; CONDUCT="$H/git/.configs/claude-conduct"
mkdir -p "$H/git/.configs/.git" "$H/git/gstack/.git" "$CONDUCT/agents" "$CONDUCT/skills/conduct/templates"
touch "$CONDUCT/skills/conduct/templates/vault-digest"
mkdir -p "$CONDUCT/skills/vault"; echo "---" > "$CONDUCT/skills/vault/SKILL.md"
STUB="$(printf '#!/bin/sh\necho codex-out\necho ran "$@" >> "%s/calls"\n[ -L "%s/.claude/skills/vault" ] && echo linked > "%s/link-at-call"\n' "$TMP" "$H" "$TMP")"
printf '%s\n' "$STUB" > "$H/git/.configs/setup.sh"; chmod +x "$H/git/.configs/setup.sh"
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/bun"; chmod +x "$TMP/bin/bun"
# claude present, so phase 08 never reaches its real installer (curl) under the narrowed PATH
printf '#!/bin/sh\necho claude-stub\n' > "$TMP/bin/claude"; chmod +x "$TMP/bin/claude"
printf '#!/bin/sh\necho curl-called >> "%s/curl-calls"; exit 1\n' "$TMP" > "$TMP/bin/curl"; chmod +x "$TMP/bin/curl"
# codex lives only in ~/.local/bin, where a fresh install puts it (not on PATH)
mkdir -p "$H/.local/bin"; printf '#!/bin/sh\nexit 0\n' > "$H/.local/bin/codex"; chmod +x "$H/.local/bin/codex"
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
run() { HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" PATH="$TMP/bin:/usr/bin:/bin" \
        bash "$KIT_DIR/profiles/workstation/08-claude-skills.sh" check 2>&1; }

echo "phase 08: re-derives Codex parity after linking Claude's skills"
printf 'component_claude_skills=yes\nclaude_skills="vault"\n' > "$TMP/host.conf"
out="$(run)"
assert "check mode says it would run setup.sh codex" "grep -qE '\[would\].*\.configs/setup\.sh codex' <<<\"\$out\""
assert "check mode puts ~/.local/bin on its PATH"    "grep -qE '\\[would\\].*env PATH=$H/.local/bin:.*setup\\.sh codex' <<<\"\$out\""
assert "check mode does not run it"                  "[[ ! -e '$TMP/calls' ]]"
assert "it comes after the skill links"              "[[ \$(grep -nE 'setup\.sh codex' <<<\"\$out\" | head -1 | cut -d: -f1) -gt \$(grep -nE '\[would\].*ln .*/skills/vault\$' <<<\"\$out\" | head -1 | cut -d: -f1) ]]"

echo "phase 08: install mode runs it, logs it as output (not an action), fails loudly"
# Quiet is decided by lib.sh from KIT_RUN_LOG/KIT_VERBOSE (as under bootstrap), not KIT_QUIET.
runi() { local q=(); [[ "${1:-0}" == 1 ]] && q=(KIT_RUN_LOG="$TMP/run.log" KIT_VERBOSE=0)
         env "${q[@]}" HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" PATH="$TMP/bin:/usr/bin:/bin" \
         bash "$KIT_DIR/profiles/workstation/08-claude-skills.sh" install 2>&1; }
printf 'component_claude_skills=yes\nclaude_skills="vault"\n' > "$TMP/host.conf"
rm -f "$TMP/calls"; out="$(runi)"; rc=$?
assert "install runs setup.sh codex once"            "[[ \$(cat '$TMP/calls' 2>/dev/null) == 'ran codex' ]]"
assert "install succeeds when it succeeds"           "[[ $rc -eq 0 ]]"
assert "skill link existed when it ran"              "[[ \$(cat '$TMP/link-at-call' 2>/dev/null) == linked ]]"
assert "not recorded as a converge action"           "! grep -qE '\] \+ .*setup\.sh codex' '$TMP/logs/ws-08-claude-skills.log'"
assert "its output lands in the phase log"           "grep -q 'codex-out' '$TMP/logs/ws-08-claude-skills.log'"
printf '#!/bin/sh\necho codex-out\nexit 23\n' > "$H/git/.configs/setup.sh"
rm -f "$TMP/logs/missing.log"; out="$(runi 1)"; rc=$?
assert "a failing setup.sh codex fails the phase"    "[[ $rc -ne 0 ]]"
assert "failure is on the triage list"               "grep -q 'setup.sh codex' '$TMP/logs/missing.log'"
assert "quiet mode still shows the FAIL"             "grep -q 'FAIL.*codex' <<<\"\$out\""
printf '%s\n' "$STUB" > "$H/git/.configs/setup.sh"

echo "phase 08: agent role leaves Codex to .configs' own agent installer"
printf 'component_claude_skills=yes\nclaude_skills="vault"\nconfigs_role=agent\n' > "$TMP/host.conf"
out="$(GIT_HOME="$H/git" run)"   # agent boxes find .configs as a sibling of the kit
assert "agent role never runs setup.sh codex"        "! grep -q 'setup.sh codex' <<<\"\$out\""

echo "phase 08: Codex CLI absent → skipped with a warning, not a failure"
printf 'component_claude_skills=yes\nclaude_skills="vault"\n' > "$TMP/host.conf"
mv "$H/.local/bin/codex" "$TMP/codex.off"; rm -f "$TMP/calls"
out="$(runi)"; rc=$?
assert "no codex: setup.sh codex not run"            "[[ ! -e '$TMP/calls' ]]"
assert "no codex: phase still succeeds"              "[[ $rc -eq 0 ]]"
assert "no codex: a WARN that says why"              "grep -qE 'WARN.*codex.*not installed' <<<\"\$out\""
mv "$TMP/codex.off" "$H/.local/bin/codex"
printf '#!/bin/sh\ncommand -v codex > "%s/codex-seen"\n' "$TMP" > "$H/git/.configs/setup.sh"
runi >/dev/null 2>&1
assert "setup.sh codex sees ~/.local/bin/codex"      "grep -qx '$H/.local/bin/codex' '$TMP/codex-seen' 2>/dev/null"
printf '%s\n' "$STUB" > "$H/git/.configs/setup.sh"

echo "phase 08: configs=no has no .configs to run"
printf 'component_claude_skills=yes\nconfigs=no\n' > "$TMP/host.conf"
out="$(run)"
assert "configs=no skips codex parity"               "! grep -q 'setup.sh codex' <<<\"\$out\""

assert "no real installer was reached"               "[[ ! -e '$TMP/curl-calls' ]]"
echo; echo "$pass passed, $fail failed"; (( fail == 0 ))
