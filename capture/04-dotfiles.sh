#!/bin/bash
# Capture curated dotfiles into a tarball. Selective — not every file in $HOME
# is worth migrating (caches, build artifacts, language SDKs are re-fetchable).

SCRIPT_NAME="capture-04-dotfiles"
source "$(dirname "$0")/../lib.sh"
require_user

OUT="$SNAPSHOT_DIR/dotfiles"
mkdir -p "$OUT"

log "Building curated dotfiles tarball..."

# Whitelist of paths under $HOME worth shipping.
# Edit this list if Brandon has additional config locations.
INCLUDE=(
  .bashrc .bash_profile .profile .bash_logout .bash_aliases
  .zshrc .zsh_history .zsh_aliases
  .gitconfig .gitignore_global
  .ssh/config .ssh/known_hosts
  .tmux.conf
  .vimrc .config/nvim
  .config/htop
  .config/lazygit
  .config/Code/User/settings.json
  .config/Code/User/keybindings.json
  .config/Code/User/snippets
  .config/Cursor/User/settings.json
  .config/Cursor/User/keybindings.json
  .config/Cursor/User/snippets
  .config/gh
  .config/git
  .config/fish
  .config/alacritty
  .config/kitty
  .config/wezterm
  .config/i3
  .config/sway
  .config/hypr
  .config/picom
  .config/polybar
  .config/rofi
  .config/gtk-3.0
  .config/gtk-4.0
  .config/autostart
  .config/systemd/user
  .config/mimeapps.list
  .config/user-dirs.dirs
  .gnupg/gpg.conf .gnupg/gpg-agent.conf
  .npmrc
  .yarnrc .yarnrc.yml
  .gradle/init.d
  .docker/config.json
  bin
  .local/bin
  .local/share/applications
  .local/share/icons
  .local/share/fonts
  .fonts
  .claude
)

# Build a tar list of files that actually exist, to avoid noisy errors.
TAR_LIST=$(mktemp)
trap 'rm -f "$TAR_LIST"' EXIT

cd "$HOME" || exit 1
for p in "${INCLUDE[@]}"; do
  if [[ -e "$p" || -L "$p" ]]; then
    echo "$p" >> "$TAR_LIST"
  fi
done

log "Including $(wc -l < "$TAR_LIST") top-level paths"

# Create the tarball. Use --null + -T for clean file-list handling.
tar -czf "$OUT/dotfiles.tar.gz" -C "$HOME" -T "$TAR_LIST" 2> "$OUT/tar-errors.log"
log "Tarball size: $(du -h "$OUT/dotfiles.tar.gz" | cut -f1)"

# Also save the list for reference.
cp "$TAR_LIST" "$OUT/included.txt"

# Capture SSH key fingerprints (NOT the keys — those are in the tarball
# already if you included .ssh/, but it's worth a manifest for verifying).
ssh-add -l > "$OUT/ssh-keys-loaded.txt" 2>/dev/null || true
for k in "$HOME"/.ssh/id_*.pub; do
  [[ -e "$k" ]] || continue
  ssh-keygen -lf "$k" 2>/dev/null
done > "$OUT/ssh-pubkey-fingerprints.txt"

log "Done. Artifacts in $OUT"
