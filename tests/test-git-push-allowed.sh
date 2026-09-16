#!/bin/bash
# Calibration for the two-mode git-push policy (2026-09-16).
#
# The conduct hook (deny-git-push.sh, .configs/claude-conduct/skills/conduct/
# templates/, wired as PreToolUse(Bash) in ~/.claude/settings.json) used to deny
# EVERY `git push` unconditionally: the human pushed, always. A headless worker
# has no human watching — its agents and its cron ship work upstream for other
# bots to consume — so the hook now yields to a marker file, and this kit's
# worker phase is what writes it:
#
#   hosts/<host>.conf  git_push=allow|deny   (deny is the default, workstations)
#        ↓ profiles/worker/03-headless.sh §6 (install)
#   $HOME/.claude/git-push-allowed           one line: who authorised it
#        ↓ read by the hook
#   push allowed, or denied exactly as before
#
# Contract:
#   A. no marker, `git push`                 → the hook's deny JSON (unchanged)
#   B. marker present, `git push`            → allowed (no output)
#   C. a non-push git command                → allowed in BOTH states
#      (guards the regression where the marker check denies everything, and the
#      one where the marker makes the hook stop matching anything at all)
#   D. marker present, `git push --force`    → allowed. Decided: the marker
#      allows ALL pushes; force-pushing is governed by the rule text, not by
#      the hook. If someone later wants force blocked mechanically, this
#      assertion is the one to flip, deliberately.
#   E. phase, git_push=allow: check warns while the marker is missing, install
#      writes it naming host + conf, a second install is a no-op (byte-identical)
#   F. phase, git_push=deny: check warns while a marker exists, install removes
#      it; with no marker the doctor says pushes are blocked
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# repos are siblings; GIT_HOME overridable, derived from this checkout otherwise
GIT_HOME="${GIT_HOME:-$(dirname "$KIT_DIR")}"
HOOK="$GIT_HOME/.configs/claude-conduct/skills/conduct/templates/deny-git-push.sh"
[[ -f "$HOOK" ]] || HOOK="$HOME/bin/deny-git-push.sh"
if [[ ! -f "$HOOK" ]]; then
  echo "  FAIL cannot find deny-git-push.sh (looked in \$GIT_HOME/.configs/claude-conduct/skills/conduct/templates/ and ~/bin)"
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out"; fi; }

H="$TMP/home"; MARKER="$H/.claude/git-push-allowed"

# ---- the hook: stdin is the PreToolUse payload, stdout is the decision ------
hook() {  # $1 = the Bash tool's command string
  jq -n --arg c "$1" '{tool_input:{command:$c}}' \
    | env HOME="$H" bash "$HOOK" > "$TMP/out" 2>&1
  echo "rc=$?" >> "$TMP/out"
}
denied() { grep -q '"permissionDecision":"deny"' "$TMP/out"; }

rm -rf "$H"; mkdir -p "$H/.claude"

hook 'git push'
assert "A. no marker: git push denied" 'denied'
hook 'cd /tmp && git commit -m "push it" && git status'
assert "C1. no marker: a non-push git command is allowed" '! denied'

printf 'testbox hosts/testbox.conf git_push=allow 2026-09-16\n' > "$MARKER"
hook 'git push'
assert "B. marker present: git push allowed" '! denied'
hook 'cd /tmp && git commit -m "push it" && git status'
assert "C2. marker present: a non-push git command is allowed" '! denied'
hook 'git push --force origin main'
assert "D. marker present: force-push allowed too (policy is prose, not hook)" '! denied'

rm -f "$MARKER"
hook 'git push'
assert "A2. marker removed: denied again" 'denied'

# ---- the phase that writes the marker --------------------------------------
mkdir -p "$TMP/bin"
for s in systemctl loginctl sudo lspci nvidia-smi; do
  printf '#!/bin/bash\ncase "$1" in get-default) echo multi-user.target;; show-user) echo yes;; is-enabled|is-active) exit 0;; esac\nexit 0\n' > "$TMP/bin/$s"
done
printf '#!/bin/bash\necho "arn:aws:iam::1:user/pub"\nexit 0\n' > "$TMP/bin/aws"
chmod +x "$TMP/bin/"*

reset() {  # $1 = git_push value (empty = key absent)
  rm -rf "$H"; mkdir -p "$H/.ssh" "$H/.aws"
  printf 'profile=worker\nheadless=yes\n' > "$TMP/testbox.conf"
  [[ -n "${1:-}" ]] && printf 'git_push=%s\n' "$1" >> "$TMP/testbox.conf"
  : > "$H/.aws/credentials"
}
phase() {  # $1 = check|install
  env PATH="$TMP/bin:$PATH" HOME="$H" HOST_CONF="$TMP/testbox.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
    bash "$KIT_DIR/profiles/worker/03-headless.sh" "$1" 2>&1 | grep -i 'git push\|git_push' > "$TMP/out"
}

reset allow
phase check
assert "E1. git_push=allow, no marker: doctor warns and changes nothing" \
  'grep -q "WARN.*git_push=allow but .* is missing" "$TMP/out" && [[ ! -e "$MARKER" ]]'
phase install
assert "E2. install writes the marker naming the host and the conf" \
  '[[ -f "$MARKER" ]] && grep -q "^$(hostname) hosts/testbox.conf git_push=allow [0-9]\{4\}-[0-9]\{2\}-[0-9]\{2\}$" "$MARKER"'
before="$(md5sum < "$MARKER")"
phase install
assert "E3. second install: no-op, marker byte-identical, doctor says OK" \
  '[[ "$(md5sum < "$MARKER")" == "$before" ]] && grep -q "OK.*git push allowed" "$TMP/out"'

reset deny
mkdir -p "$(dirname "$MARKER")"; printf 'stale\n' > "$MARKER"
phase check
assert "F1. git_push=deny with a marker present: doctor warns, removes nothing" \
  'grep -q "WARN.*git_push=deny but" "$TMP/out" && [[ -f "$MARKER" ]]'
phase install
assert "F2. install removes the stale marker" '[[ ! -e "$MARKER" ]]'
phase check
assert "F3. no marker, git_push=deny: OK says pushes are blocked" 'grep -q "OK.*git push denied" "$TMP/out"'

reset ""
phase check
assert "F4. key absent from the conf: deny is the default" 'grep -q "OK.*git push denied" "$TMP/out"'

echo "  $pass passed, $fail failed"; (( fail == 0 ))
