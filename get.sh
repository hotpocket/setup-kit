#!/usr/bin/env bash
# setup-kit one-line bootstrap. On a fresh box:
#
#   curl -fsSL https://raw.githubusercontent.com/hotpocket/setup-kit/main/get.sh | bash
#   ~/git/setup-kit/bootstrap.sh workstation install
#
# or both at once:
#
#   curl -fsSL .../get.sh | bash -s -- workstation install
#
# Overrides: SETUP_KIT_REPO (e.g. a LAN git remote), SETUP_KIT_DIR.
set -euo pipefail
REPO="${SETUP_KIT_REPO:-https://github.com/hotpocket/setup-kit.git}"
DEST="${SETUP_KIT_DIR:-$HOME/git/setup-kit}"

command -v git >/dev/null 2>&1 || {
  echo "==> installing git"
  sudo apt-get update -qq && sudo apt-get install -y -qq git
}

if [[ -d "$DEST/.git" ]]; then
  echo "==> updating $DEST"
  git -C "$DEST" pull --ff-only
else
  mkdir -p "$(dirname "$DEST")"
  echo "==> cloning $REPO"
  git clone "$REPO" "$DEST"
fi

if [[ $# -gt 0 ]]; then
  exec "$DEST/bootstrap.sh" "$@"
fi
echo "setup-kit ready. Next:  $DEST/bootstrap.sh workstation install"
