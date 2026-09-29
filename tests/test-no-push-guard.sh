#!/bin/bash
# No push guard, no allow markers (Brandon, 2026-09-29).
#
# Claude pushes and deploys; Brandon approves by asking, by voice. The old
# PreToolUse hook (.configs/.../deny-git-push.sh) denied every `git push`, and
# two marker files (~/.claude/git-push-allowed, written by 03-headless from
# git_push=allow, and ~/.claude/deploy-allowed) existed only to lift it — an
# exemption for something that is simply allowed. All of it is gone. This test
# guards the class: every place that installs the hook, registers it, or writes
# a marker.
#   A. .configs ships no deny-git-push.sh template
#   B. .configs' settings.json registers no deny-git-push hook
#   C. phase 08 does not link ~/bin/deny-git-push.sh, even with a template present
#   D. phase 03-headless writes no marker, even for a conf still saying git_push=allow
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# repos are siblings; GIT_HOME overridable, derived from this checkout otherwise
GIT_HOME="${GIT_HOME:-$(dirname "$KIT_DIR")}"
CONFIGS="$GIT_HOME/.configs"
if [[ ! -d "$CONFIGS/claude-conduct" ]]; then
  echo "  FAIL cannot find \$GIT_HOME/.configs/claude-conduct ($CONFIGS)"
  exit 1
fi

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out"; fi; }
: > "$TMP/out"

assert "A. no deny-git-push.sh template in .configs" \
  '[[ ! -e "$CONFIGS/claude-conduct/skills/conduct/templates/deny-git-push.sh" ]]'
grep -n 'deny-git-push' "$CONFIGS/.claude/settings.json" > "$TMP/out"
assert "B. .configs settings.json registers no deny-git-push hook" '[[ ! -s "$TMP/out" ]]'

# ---- C. phase 08, fake HOME with a (stale) template present ----------------
H="$TMP/home"; CONDUCT="$H/git/.configs/claude-conduct"
mkdir -p "$H/git/.configs/.git" "$CONDUCT/agents" "$CONDUCT/skills/conduct/templates" "$TMP/bin"
touch "$CONDUCT/skills/conduct/templates/vault-digest" "$CONDUCT/skills/conduct/templates/deny-git-push.sh"
echo "---" > "$CONDUCT/skills/conduct/SKILL.md"
printf 'component_claude_skills=yes\nclaude_skills="conduct"\n' > "$TMP/host.conf"
HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" PATH="$TMP/bin:$PATH" \
  bash "$KIT_DIR/profiles/workstation/08-claude-skills.sh" check 2>&1 | grep -i 'deny-git-push' > "$TMP/out"
assert "C. phase 08 neither links nor mentions deny-git-push.sh" '[[ ! -s "$TMP/out" ]]'

# ---- D. phase 03-headless install, conf still says git_push=allow ----------
for s in systemctl loginctl sudo lspci nvidia-smi; do
  printf '#!/bin/bash\ncase "$1" in get-default) echo multi-user.target;; show-user) echo yes;; is-enabled|is-active) exit 0;; esac\nexit 0\n' > "$TMP/bin/$s"
done
printf '#!/bin/bash\necho "arn:aws:iam::1:user/pub"\nexit 0\n' > "$TMP/bin/aws"
chmod +x "$TMP/bin/"*
rm -rf "$H"; mkdir -p "$H/.ssh" "$H/.aws" "$H/.claude"; : > "$H/.aws/credentials"
printf 'profile=worker\nheadless=yes\ngit_push=allow\n' > "$TMP/testbox.conf"
env PATH="$TMP/bin:$PATH" HOME="$H" HOST_CONF="$TMP/testbox.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/worker/03-headless.sh" install 2>&1 | grep -i 'git push\|git_push\|allowed' > "$TMP/out"
assert "D. 03-headless writes no marker" '[[ ! -e "$H/.claude/git-push-allowed" && ! -e "$H/.claude/deploy-allowed" ]]'
assert "D2. 03-headless has no push-policy section" '[[ ! -s "$TMP/out" ]]'

echo "  $pass passed, $fail failed"; (( fail == 0 ))
