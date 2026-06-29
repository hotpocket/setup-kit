#!/bin/bash
# Claude skills layer: clone the canonical skill repos and symlink each enabled
# skill into ~/.claude/skills/<name>. Edit skills at their source, never the link.
# Specs: components/{gstack,vault,conduct}.md
#   gstack         -> third-party, cloned from its own upstream (~/git/gstack)
#   vault, conduct -> our canonical repo ~/git/claude-conduct (github: hotpocket/claude-conduct)
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
  vault|conduct) echo "$HOME/git/claude-conduct" ;;
esac; }
skill_url() { case "$1" in
  gstack)        echo "git@github.com:garrytan/gstack.git" ;;
  vault|conduct) echo "git@github.com:hotpocket/claude-conduct.git" ;;
  *)             echo "" ;;
esac; }
skill_path() { case "$1" in
  gstack)  echo "$HOME/git/gstack" ;;            # SKILL.md lives at the repo root
  vault)   echo "$HOME/git/claude-conduct/skills/vault" ;;
  conduct) echo "$HOME/git/claude-conduct/skills/conduct" ;;
esac; }

ensure_repo() {            # dir url  -> 0 if present after, 1 otherwise
  local dir="$1" url="$2" name; name="$(basename "$dir")"
  [[ -d "$dir/.git" ]] && { ok "repo $name present"; return 0; }
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
