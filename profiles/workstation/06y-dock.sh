#!/bin/bash
# GNOME dock — favorite-apps declared by manifests/dock.list. Desktop installs
# only (group_desktop). Runs after 06-configs so the .configs launchers exist,
# and sets the list EXACTLY: manifest order, only entries whose .desktop file
# is installed (a favorite GNOME can't resolve gets silently dropped by the
# shell anyway — see 2026-09-05, the TTS client pinned before it was known).
# Ubuntu's defaults leave the dock by not being listed.
SCRIPT_NAME="ws-06y-dock"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

group_on desktop || exit 0
DOCK_LIST="${DOCK_LIST:-$MANIFEST_DIR/dock.list}"
[[ -f "$DOCK_LIST" ]] || exit 0

section "dock ($MODE) — manifests/dock.list"

if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || ! command -v gsettings >/dev/null 2>&1; then
  warn "no DBus session — run from a desktop terminal to manage the dock"
  exit 0
fi

# where .desktop files live; overridable so tests/ can present a fake set
APP_DIRS="${DOCK_APP_DIRS:-$HOME/.local/share/applications:/usr/share/applications:/usr/local/share/applications:/var/lib/snapd/desktop/applications}"
app_installed() { local d; for d in ${APP_DIRS//:/ }; do [[ -f "$d/$1" ]] && return 0; done; return 1; }

WANT=()
while IFS= read -r entry; do
  entry="${entry%%#*}"; entry="$(echo "$entry" | xargs)"; [[ -z "$entry" ]] && continue
  grp=""; [[ "$entry" == *" @"* ]] && { grp="${entry##*@}"; entry="${entry% @*}"; }
  id="${entry%% *}"
  if [[ -n "$grp" ]] && ! group_on "$grp"; then ok "$id: gated off (@$grp)"; continue; fi
  if app_installed "$id"; then WANT+=("$id"); ok "$id"
  else warn "$id: not installed — not pinned (install its package, re-run)"; fi
done < "$DOCK_LIST"

want_str="["; for id in "${WANT[@]}"; do want_str+="'$id', "; done; want_str="${want_str%, }]"
cur="$(gsettings get org.gnome.shell favorite-apps 2>/dev/null)"
# normalise gsettings' spacing/@as prefix before comparing
norm() { sed -E "s/^@as //; s/, */, /g; s/\[ /[/; s/ \]/]/" <<<"$1"; }
if [[ "$(norm "$cur")" == "$(norm "$want_str")" ]]; then
  ok "dock matches manifest (${#WANT[@]} entries)"
elif (( INSTALL )); then
  warn "dock differs from manifest — setting ${#WANT[@]} entries"
  gsettings set org.gnome.shell favorite-apps "$want_str" && log "dock set: ${WANT[*]}"
else
  warn "dock differs from manifest"
  printf '  %s[would]%s set favorite-apps to: %s\n' "$C_DIM" "$C_RST" "${WANT[*]}"
fi
