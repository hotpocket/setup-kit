#!/bin/bash
# Snaps + flatpaks from manifests/snap.list and manifests/flatpak.list.
SCRIPT_NAME="ws-03-snap-flatpak"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

section "snaps ($MODE)"
if ! command -v snap >/dev/null 2>&1; then
  warn "snapd not installed"
  do_or_say sudo apt-get install -y snapd
fi
while IFS= read -r entry; do
  entry="${entry%%#*}"; entry="$(echo "$entry" | xargs)"; [[ -z "$entry" ]] && continue
  grp=""
  if [[ "$entry" == *" @"* ]]; then grp="${entry##*@}"; entry="${entry% @*}"; fi
  name="${entry%% *}"; flags="${entry#"$name"}"
  if [[ -n "$grp" ]] && ! group_on "$grp"; then
    ok "snap $name: gated off (@$grp)"
    continue
  fi
  if snap list "$name" >/dev/null 2>&1; then
    ok "snap $name"
  else
    warn "snap $name missing"
    # shellcheck disable=SC2086 — flags is intentionally word-split (--classic)
    do_or_say sudo snap install "$name" $flags || miss "snap: $name"
  fi
done < <(grep -hvE '^[[:space:]]*(#|$)' "$MANIFEST_DIR/snap.list")

section "flatpaks ($MODE)"
if ! command -v flatpak >/dev/null 2>&1; then
  warn "flatpak not installed"
  do_or_say sudo apt-get install -y flatpak
fi
if command -v flatpak >/dev/null 2>&1; then
  if flatpak remotes --user 2>/dev/null | grep -q flathub \
     || flatpak remotes 2>/dev/null | grep -q flathub; then
    ok "flathub remote configured"
  else
    warn "flathub remote missing"
    do_or_say flatpak remote-add --if-not-exists --user flathub \
      https://dl.flathub.org/repo/flathub.flatpakrepo
  fi
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | xargs)"; [[ -z "$line" ]] && continue
    grp=""; app="$line"
    if [[ "$line" == *" @"* ]]; then grp="${line##*@}"; app="${line% @*}"; fi
    if [[ -n "$grp" ]] && ! group_on "$grp"; then
      ok "flatpak $app: gated off (@$grp)"
      continue
    fi
    if flatpak info "$app" >/dev/null 2>&1; then
      ok "flatpak $app"
    else
      warn "flatpak $app missing"
      do_or_say flatpak install --user -y --noninteractive flathub "$app" \
        || miss "flatpak: $app"
    fi
  done < <(grep -hvE '^[[:space:]]*(#|$)' "$MANIFEST_DIR/flatpak.list")
fi
