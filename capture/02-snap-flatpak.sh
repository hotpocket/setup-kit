#!/bin/bash
# Capture snap and flatpak installations.

SCRIPT_NAME="capture-02-snap-flatpak"
source "$(dirname "$0")/../lib.sh"
require_user

OUT="$SNAPSHOT_DIR/snap-flatpak"
mkdir -p "$OUT"

# --- Snap ---
if command -v snap >/dev/null 2>&1; then
  log "Capturing snap state..."
  snap list --all > "$OUT/snap-list-all.txt" 2>/dev/null || true

  # Just current versions (cleaner for restore).
  snap list 2>/dev/null | awk 'NR>1 {print $1, $4}' > "$OUT/snap-current.txt"
  log "snaps: $(wc -l < "$OUT/snap-current.txt")"

  # Connections — interfaces granted to snaps.
  snap connections > "$OUT/snap-connections.txt" 2>/dev/null || true
else
  log "snap not installed"
fi

# --- Flatpak ---
if command -v flatpak >/dev/null 2>&1; then
  log "Capturing flatpak state..."
  flatpak list --app --columns=application,origin,branch \
    > "$OUT/flatpak-apps.txt" 2>/dev/null || true
  flatpak remotes --columns=name,url > "$OUT/flatpak-remotes.txt" 2>/dev/null || true
  log "flatpaks: $(wc -l < "$OUT/flatpak-apps.txt")"
else
  log "flatpak not installed"
fi

log "Done. Artifacts in $OUT"
