#!/bin/bash
# Phase 08 linked only what claude_skills= named, and every host conf (and the
# script's own default) named three. The other eight conduct skills in
# .configs/claude-conduct/skills were never considered, and a fresh VM
# (2026-09-08) came up with /filmstrip, /vet, /wargame ... absent. The class:
# every skill dir added to claude-conduct after the conf was written.
# Same shape for gstack: the router was linked, the two sub-skills the user
# actually wants (browse, setup-browser-cookies) were not — gstack's own
# relink is never run, and would link all ~40.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; CONDUCT="$H/git/.configs/claude-conduct"; GSTACK="$H/git/gstack"
# fake repos: .git so ensure_repo says "present" and never pulls
mkdir -p "$H/git/.configs/.git" "$GSTACK/.git" "$CONDUCT/agents" "$CONDUCT/skills/conduct/templates"
touch "$CONDUCT/skills/conduct/templates/vault-digest" "$CONDUCT/skills/conduct/templates/deny-git-push.sh"
for s in conduct vault filmstrip vet wargame zebra; do mkdir -p "$CONDUCT/skills/$s"; echo "---" > "$CONDUCT/skills/$s/SKILL.md"; done
mkdir -p "$CONDUCT/skills/not-a-skill"              # no SKILL.md: must be skipped
echo "---" > "$GSTACK/SKILL.md"
for s in browse setup-browser-cookies design careful; do mkdir -p "$GSTACK/$s"; echo "---" > "$GSTACK/$s/SKILL.md"; done
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/bun"; chmod +x "$TMP/bin/bun"
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
run() { HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" PATH="$TMP/bin:$PATH" \
        bash "$KIT_DIR/profiles/workstation/08-claude-skills.sh" check 2>&1; }
would_link() { grep -qE "\[would\].*ln .* $1\$" <<<"$out"; }   # link target is the last word

echo "phase 08: every conduct skill by default"
printf 'component_claude_skills=yes\n' > "$TMP/host.conf"          # claude_skills unset
out="$(run)"
for s in conduct vault filmstrip vet wargame zebra; do
  assert "links conduct skill '$s' with claude_skills unset" "would_link '$H/.claude/skills/$s'"
done
assert "skips a conduct dir with no SKILL.md"       "! grep -q 'not-a-skill' <<<\"\$out\""
assert "gstack router still linked"                  "would_link '$H/.claude/skills/gstack'"

echo "phase 08: claude_skills= is still an explicit override"
printf 'component_claude_skills=yes\nclaude_skills="gstack vault"\n' > "$TMP/host.conf"
out="$(run)"
assert "explicit list links what it names"           "would_link '$H/.claude/skills/vault'"
assert "explicit list does NOT link the rest"        "! would_link '$H/.claude/skills/filmstrip'"

echo "phase 08: chosen gstack sub-skills, gstack's own layout (dir + SKILL.md link)"
printf 'component_claude_skills=yes\n' > "$TMP/host.conf"          # gstack_skills unset -> default pair
out="$(run)"
for s in browse setup-browser-cookies; do
  assert "links gstack/$s/SKILL.md into skills/$s/"  "would_link '$H/.claude/skills/$s/SKILL.md'"
done
assert "does not link every gstack skill (design)"   "! grep -q 'skills/design' <<<\"\$out\""
printf 'component_claude_skills=yes\ngstack_skills="careful"\n' > "$TMP/host.conf"
out="$(run)"
assert "gstack_skills= overrides the default pair"   "would_link '$H/.claude/skills/careful/SKILL.md' && ! would_link '$H/.claude/skills/browse/SKILL.md'"

echo "  $pass passed, $fail failed"
(( fail == 0 ))
