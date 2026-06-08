#!/bin/bash
# Capture apt package state + sources + keys.
# Run as your normal user (will sudo for /etc/apt reads).

SCRIPT_NAME="capture-01-packages"
source "$(dirname "$0")/../lib.sh"
require_user

OUT="$SNAPSHOT_DIR/apt"
mkdir -p "$OUT"

log "Capturing apt state..."

# Manually installed packages (the ones you actually chose).
apt-mark showmanual > "$OUT/manual.txt"
log "manual: $(wc -l < "$OUT/manual.txt") packages"

# Complete dpkg selections — fallback reference.
dpkg --get-selections > "$OUT/selections.txt"
log "selections: $(wc -l < "$OUT/selections.txt") entries"

# Architectures (for multi-arch like i386).
dpkg --print-foreign-architectures > "$OUT/architectures.txt"

# APT sources + keyrings — /etc/apt is world-readable on Ubuntu, no sudo needed.
copy_or_miss() {
  local src="$1" dst="$2"
  if [[ -e "$src" ]] && cp -r "$src" "$dst" 2>>"$LOG_DIR/${SCRIPT_NAME}.log"; then
    log "copied: $src"
  else
    miss "apt-config: $src (unreadable or absent)"
  fi
}
copy_or_miss /etc/apt/sources.list      "$OUT/sources.list"
copy_or_miss /etc/apt/sources.list.d    "$OUT/sources.list.d"
copy_or_miss /etc/apt/keyrings          "$OUT/keyrings"
copy_or_miss /etc/apt/trusted.gpg.d     "$OUT/trusted.gpg.d"
copy_or_miss /etc/apt/trusted.gpg       "$OUT/trusted.gpg"

# auth.conf.d holds Ubuntu Pro tokens etc — needs sudo. Log it for manual capture.
if [[ -d /etc/apt/auth.conf.d ]]; then
  if [[ -r /etc/apt/auth.conf.d/90ubuntu-advantage ]] 2>/dev/null; then
    cp -r /etc/apt/auth.conf.d "$OUT/auth.conf.d" && log "copied: auth.conf.d"
  else
    miss "apt-config: /etc/apt/auth.conf.d (root-only — sudo cp manually if Ubuntu Pro is in use)"
  fi
fi

# PPAs — distinct from regular sources, easier to re-add by name.
grep -rh "^deb " /etc/apt/sources.list.d/ 2>/dev/null \
  | grep -oP 'ppa\.launchpadcontent\.net/\K[^/]+/[^/]+' \
  | sort -u > "$OUT/ppas.txt"
log "ppas: $(wc -l < "$OUT/ppas.txt")"

# Snap, if installed (handled fully in 02).
# Flatpak, same.

# Held packages (don't auto-upgrade).
apt-mark showhold > "$OUT/held.txt"

log "Done. Artifacts in $OUT"
