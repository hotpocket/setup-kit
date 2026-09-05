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

# Claude Code (the `claude` binary) is its own flag, default ON: the conduct
# skills in .configs are useless without it, so skills=yes implies it.
if [[ "$(conf_get component_claude_code yes)" == yes || "$(conf_get component_claude_skills yes)" == yes ]]; then
  section "claude code ($MODE)"
  # Claude Code itself: the native installer, and ONLY that (no npm global, no
  # deb) — it self-updates in ~/.local/share/claude and links ~/.local/bin/claude.
  # Checked by path too: ~/.local/bin is not on PATH in a fresh box's shell.
  if command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]]; then
    ok "claude code installed ($("$HOME/.local/bin/claude" --version 2>/dev/null | head -1 || echo present))"
  else
    warn "claude code missing"
    do_or_say bash -c 'curl -fsSL https://claude.ai/install.sh | bash' || miss "claude-code: native installer failed"
  fi
fi

[[ "$(conf_get component_claude_skills yes)" == yes ]] || exit 0

SKILLS="$(conf_get claude_skills 'gstack vault conduct repo-story')"
SKILLS_DIR="$HOME/.claude/skills"

section "claude skills ($MODE) — components/{gstack,vault,conduct}.md"

# registry: source repo, clone url (empty = local-only), skill dir within repo
skill_repo() { case "$1" in
  gstack)        echo "$HOME/git/gstack" ;;
  *)             echo "$HOME/git/.configs" ;;   # every other skill lives in claude-conduct
esac; }
skill_url() { case "$1" in
  gstack)        echo "git@github.com:garrytan/gstack.git" ;;
  *)             echo "git@github.com:hotpocket/.configs.git" ;;
esac; }
skill_path() { case "$1" in
  gstack)  echo "$HOME/git/gstack" ;;            # SKILL.md lives at the repo root
  *)       echo "$HOME/git/.configs/claude-conduct/skills/$1" ;;
esac; }

# Everything this phase links out of the repos. A checkout that already has all
# of it is complete — no pull. Pulling costs a YubiKey PIN + touch per repo
# (ssh with the resident -sk key), so freshness is bought only when a wanted
# path is actually missing (the stale-clone failure the pull exists to fix:
# a pre-vault-digest claude-conduct left ~/bin/vault-digest unlinkable forever).
AGENTS_SRC="$HOME/git/.configs/claude-conduct/agents"
VD_SRC="$HOME/git/.configs/claude-conduct/skills/conduct/templates/vault-digest"
DGP_SRC="$HOME/git/.configs/claude-conduct/skills/conduct/templates/deny-git-push.sh"
WANT_PATHS=("$VD_SRC" "$DGP_SRC" "$AGENTS_SRC")
for s in $SKILLS; do
  p="$(skill_path "$s")"; [[ -n "$p" ]] && WANT_PATHS+=("$p")
done

repo_stale() {             # dir -> 0 if a wanted path INSIDE dir is absent
  local dir="$1" p found=0
  for p in "${WANT_PATHS[@]}"; do
    [[ "$p" == "$dir"/* ]] || continue      # strictly inside; the repo root
    found=1                                 # itself is not evidence of anything
    [[ -e "$p" ]] || return 0
  done
  # No path inside this repo to test (gstack: the skill IS the repo root).
  # Nothing the kit consumes can go missing, so there is no staleness signal
  # and no reason to spend a YubiKey touch — third-party repos update by hand.
  (( found )) || return 1
  return 1
}

ensure_repo() {            # dir url  -> 0 if present after, 1 otherwise
  local dir="$1" url="$2" name; name="$(basename "$dir")"
  if [[ -d "$dir/.git" ]]; then
    if (( INSTALL )) && [[ -n "$url" ]] && repo_stale "$dir"; then
      # ff-only + soft-fail: offline or locally-diverged just uses what's there.
      # BatchMode: the phase loop is unaided (the preamble front-loads every
      # PIN/touch); a key that needs one here must fail now, not hold the run
      # on a prompt nobody is watching (2026-09-05: ~1 min per pass, x3).
      if GIT_SSH_COMMAND='ssh -o BatchMode=yes' git -C "$dir" pull --ff-only --quiet 2>/dev/null; then
        ok "repo $name present (pulled — wanted path was missing)"
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

# Subagent definitions. Model pins live in these files and nowhere else (the
# narrator's Fable pin is the load-bearing one), so an unlinked agent is a
# silent downgrade to whatever model the caller happened to be on — not an
# error anyone would see. Per-file because ~/.claude/agents holds a flat set
# of .md files; there is no per-agent directory to point at.
AGENTS_DIR="$HOME/.claude/agents"
if [[ -d "$AGENTS_SRC" ]]; then
  [[ -d "$AGENTS_DIR" ]] || do_or_say mkdir -p "$AGENTS_DIR"
  for a in "$AGENTS_SRC"/*.md; do
    [[ -e "$a" ]] || continue
    name="$(basename "$a")"; link="$AGENTS_DIR/$name"
    if [[ -L "$link" && "$(readlink -f "$link")" == "$(readlink -f "$a")" ]]; then
      ok "agent '$name' linked"
    elif [[ -e "$link" && ! -L "$link" ]]; then
      # A real file here predates this loop and is the only copy of itself.
      # Overwriting it would delete the original, so say so and move on.
      warn "agent '$name' is a real file, not a link — move it into $AGENTS_SRC"
      miss "claude-skills: $name unmanaged at $link"
    else
      warn "agent '$name' not linked"
      do_or_say ln -sfnT "$a" "$link"
    fi
  done
else
  warn "claude-conduct/agents missing (subtree not present?)"
fi

# gstack's browse daemon is built with bun; the skill is useless without it.
# bun's official installer lands in ~/.bun/bin (the .configs bashrc adds it).
if [[ " $SKILLS " == *" gstack "* ]]; then
  if command -v bun >/dev/null 2>&1 || [[ -x "$HOME/.bun/bin/bun" ]]; then
    ok "bun present (gstack browse daemon builds)"
  else
    warn "bun missing — gstack's browse daemon needs it to build"
    do_or_say bash -c 'curl -fsSL https://bun.sh/install | bash' || miss "claude-skills: bun install failed"
  fi
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
if [[ -f "$VD_SRC" ]]; then
  if [[ -L "$HOME/bin/vault-digest" \
        && "$(readlink -f "$HOME/bin/vault-digest")" == "$(readlink -f "$VD_SRC")" ]]; then
    ok "~/bin/vault-digest linked"
  else
    warn "~/bin/vault-digest not linked"
    do_or_say mkdir -p "$HOME/bin"
    do_or_say ln -sfnT "$VD_SRC" "$HOME/bin/vault-digest"
  fi
else
  warn "vault-digest template missing (claude-conduct subtree not present?)"
fi

# No-push guard in ~/bin: the PreToolUse hook registered in the global
# .claude/settings.json (same .configs repo) mechanically denies any agent
# `git push`. The registration and this script MUST land together — that's
# why conduct lives inside .configs. Canonical source is the conduct template.
if [[ -f "$DGP_SRC" ]]; then
  [[ -x "$DGP_SRC" ]] || do_or_say chmod +x "$DGP_SRC"
  if [[ -L "$HOME/bin/deny-git-push.sh" \
        && "$(readlink -f "$HOME/bin/deny-git-push.sh")" == "$(readlink -f "$DGP_SRC")" ]]; then
    ok "~/bin/deny-git-push.sh linked"
  else
    warn "~/bin/deny-git-push.sh not linked"
    do_or_say mkdir -p "$HOME/bin"
    do_or_say ln -sfnT "$DGP_SRC" "$HOME/bin/deny-git-push.sh"
  fi
else
  warn "deny-git-push template missing (claude-conduct subtree not present?)"
  miss "claude-skills: settings.json registers deny-git-push.sh but script is absent"
fi
