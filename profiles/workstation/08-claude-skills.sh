#!/bin/bash
# Claude skills layer: clone the canonical skill repos and symlink each enabled
# skill into ~/.claude/skills/<name>. Edit skills at their source, never the link.
# Specs: components/{gstack,vault,conduct}.md
#   gstack         -> third-party, cloned from its own upstream (~/git/gstack)
#   vault, conduct -> canonical source is the claude-conduct/ subtree inside
#                     ~/git/.configs (github: hotpocket/.configs). The standalone
#                     hotpocket/claude-conduct repo is archived — subtree-merged
#                     2026-07-03 so config (hooks in settings.json) and the
#                     scripts they invoke land in ONE repo, atomically.
SCRIPT_NAME="ws-08-claude-skills"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

[[ "$(conf_get component_claude_skills yes)" == yes ]] || exit 0

SKILLS="$(conf_get claude_skills 'gstack vault conduct')"
SKILLS_DIR="$HOME/.claude/skills"

section "claude skills ($MODE) — components/{gstack,vault,conduct}.md"

# registry: source repo, clone url (empty = local-only), skill dir within repo
skill_repo() { case "$1" in
  gstack)        echo "$HOME/git/gstack" ;;
  vault|conduct) echo "$HOME/git/.configs" ;;
esac; }
skill_url() { case "$1" in
  gstack)        echo "git@github.com:garrytan/gstack.git" ;;
  vault|conduct) echo "git@github.com:hotpocket/.configs.git" ;;
  *)             echo "" ;;
esac; }
skill_path() { case "$1" in
  gstack)  echo "$HOME/git/gstack" ;;            # SKILL.md lives at the repo root
  vault)   echo "$HOME/git/.configs/claude-conduct/skills/vault" ;;
  conduct) echo "$HOME/git/.configs/claude-conduct/skills/conduct" ;;
esac; }

ensure_repo() {            # dir url  -> 0 if present after, 1 otherwise
  local dir="$1" url="$2" name; name="$(basename "$dir")"
  if [[ -d "$dir/.git" ]]; then
    # keep it fresh: a stale clone means missing templates/skills (caught in
    # the wild: a pre-vault-digest claude-conduct left ~/bin/vault-digest
    # unlinkable forever). ff-only + soft-fail: offline or locally-diverged
    # just uses what's there.
    if (( INSTALL )) && [[ -n "$url" ]]; then
      if git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
        ok "repo $name present (fresh)"
      else
        warn "repo $name present but not updated (offline / diverged) — using as-is"
      fi
    else
      ok "repo $name present"
    fi
    return 0
  fi
  if [[ -z "$url" ]]; then
    warn "repo $name missing and local-only (no remote to clone)"
    miss "claude-skills: $name is local-only — create/restore it manually at $dir"
    return 1
  fi
  warn "repo $name not cloned"
  do_or_say mkdir -p "$(dirname "$dir")"   # ~/git just needs to exist
  do_or_say git clone "$url" "$dir"
  (( INSTALL )) || return 1                 # check mode: nothing cloned, don't assert
  [[ -d "$dir/.git" ]] || { miss "claude-skills: clone $url failed"; return 1; }
}

mkdir -p "$SKILLS_DIR"
declare -A REPO_DONE
for s in $SKILLS; do
  repo="$(skill_repo "$s")"; url="$(skill_url "$s")"; src="$(skill_path "$s")"
  [[ -n "$repo" ]] || { warn "unknown skill '$s' — skipping"; continue; }

  if [[ -z "${REPO_DONE[$repo]:-}" ]]; then
    if ensure_repo "$repo" "$url"; then REPO_DONE[$repo]=0; else REPO_DONE[$repo]=1; fi
  fi
  (( REPO_DONE[$repo] == 0 )) || { warn "skill '$s' unavailable (repo missing)"; continue; }

  link="$SKILLS_DIR/$s"
  if [[ -L "$link" && "$(readlink -f "$link")" == "$(readlink -f "$src")" ]]; then
    ok "skill '$s' linked"
  elif [[ ! -d "$src" ]]; then
    warn "skill '$s' source missing at $src"; miss "claude-skills: $s source absent at $src"
  else
    warn "skill '$s' not linked"
    do_or_say ln -sfnT "$src" "$link"   # -n keep, -f replace, -T treat link as the target name
  fi
done

# gstack's browse daemon is built with bun; the skill is useless without it.
if [[ " $SKILLS " == *" gstack "* ]] && ! command -v bun >/dev/null 2>&1; then
  warn "gstack browse daemon needs 'bun' to build — not installed"
  miss "claude-skills: gstack linked but 'bun' missing — build the browse daemon"
fi

# gstack browse runs Playwright-managed Chromium. Two host-level traps
# (both hit 2026-07-16 on Ubuntu 26.04 — see components/gstack.md):
#   1. playwright < 1.61 has no ubuntu26.04 browser registry: `npx playwright
#      install` fails AND garbage-collects working cached browsers first.
#   2. Ubuntu 24.04+ sets kernel.apparmor_restrict_unprivileged_userns=1;
#      Playwright-downloaded browsers ship no AppArmor profile, so their
#      sandbox aborts at launch ("No usable sandbox!"). Ship them the same
#      unconfined+userns profile the google-chrome deb installs for itself.
if [[ " $SKILLS " == *" gstack "* ]]; then
  OS_VER="$(. /etc/os-release && echo "$VERSION_ID")"
  PW_MIN="$(grep -oP '"playwright":\s*"\^?1\.\K[0-9]+' "$HOME/git/gstack/package.json" 2>/dev/null || true)"
  if [[ -n "$PW_MIN" && "${OS_VER%%.*}" -ge 26 && "$PW_MIN" -lt 61 ]]; then
    warn "gstack pins playwright 1.$PW_MIN (< 1.61) — browsers can't install on Ubuntu $OS_VER."
    warn "  Fix: bump to ^1.61 in ~/git/gstack/package.json, bun install, bun run build."
    warn "  NEVER 'npx playwright install' before bumping — it deletes cached browsers first."
    miss "claude-skills: gstack playwright pin 1.$PW_MIN too old for Ubuntu $OS_VER"
  fi

  if [[ "$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null)" == "1" ]]; then
    AA_FILE=/etc/apparmor.d/playwright-chrome
    AA_WANT=$(cat <<'EOF'
# Allow Playwright-managed Chromium builds to use unprivileged user
# namespaces for their sandbox (Ubuntu 24.04+ AppArmor restriction).
# Mirrors /etc/apparmor.d/chrome shipped by the google-chrome deb.

abi <abi/5.0>,
include <tunables/global>

profile playwright-chrome /home/*/.cache/ms-playwright/**/chrome{,-headless-shell} flags=(unconfined) {
  userns,
  @{exec_path} mr,

  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/playwright-chrome>
}
EOF
)
    if [[ -f "$AA_FILE" && "$(cat "$AA_FILE")" == "$AA_WANT" ]]; then
      ok "playwright-chrome AppArmor profile present"
    else
      [[ -f "$AA_FILE" ]] \
        && warn "playwright-chrome AppArmor profile drifted — reconciling" \
        || warn "Playwright browsers blocked by AppArmor userns restriction — installing profile"
      if (( INSTALL )); then
        printf '%s\n' "$AA_WANT" | sudo tee "$AA_FILE" >/dev/null
        sudo apparmor_parser -r "$AA_FILE"
      fi
    fi
  fi
fi

# Shared vault-digest in ~/bin: the file-based vault reader used by the global
# SessionStart router (claude-orient) for repos you don't own (external vaults
# under ~/Documents/AgentMemory/<repo>). Owned repos carry their own copy in
# scripts/ via `/conduct init`. Canonical source is the conduct skill template.
vd="$HOME/git/.configs/claude-conduct/skills/conduct/templates/vault-digest"
if [[ -f "$vd" ]]; then
  do_or_say mkdir -p "$HOME/bin"
  do_or_say ln -sfnT "$vd" "$HOME/bin/vault-digest"
  ok "~/bin/vault-digest linked"
else
  warn "vault-digest template missing (claude-conduct subtree not present?)"
fi

# No-push guard in ~/bin: the PreToolUse hook registered in the global
# .claude/settings.json (same .configs repo) mechanically denies any agent
# `git push`. The registration and this script MUST land together — that's
# why conduct lives inside .configs. Canonical source is the conduct template.
dgp="$HOME/git/.configs/claude-conduct/skills/conduct/templates/deny-git-push.sh"
if [[ -f "$dgp" ]]; then
  do_or_say chmod +x "$dgp"
  do_or_say ln -sfnT "$dgp" "$HOME/bin/deny-git-push.sh"
  ok "~/bin/deny-git-push.sh linked"
else
  warn "deny-git-push template missing (claude-conduct subtree not present?)"
  miss "claude-skills: settings.json registers deny-git-push.sh but script is absent"
fi
