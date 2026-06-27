#!/bin/bash
# GNOME Shell extensions from extensions.gnome.org, per manifests/gnome-
# extensions.list. User-level (~/.local/share/gnome-shell/extensions) — the apt
# snapshot can't see these, so they live here, not in .configs' dconf dumps.
#
# check : report which are missing / installed-but-disabled, change nothing.
# install: download the build matching THIS shell version, install, enable.
#   Wayland caveat: a just-installed extension can't load until the next login,
#   so we still write it into the enabled list (gsettings) and flag a relogin.
SCRIPT_NAME="ws-06z-gnome-extensions"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

section "gnome extensions ($MODE)"

# Gate: only meaningful on a GNOME session with the CLI + a live DBus session
# (the kit runs from a desktop terminal). Headless/server boxes: skip cleanly.
if ! command -v gnome-extensions >/dev/null 2>&1; then
  ok "gnome-extensions CLI absent — not a GNOME box, skipping"; exit 0
fi
if [[ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ]] || ! command -v gsettings >/dev/null 2>&1; then
  warn "no DBus session — run from a desktop terminal to manage extensions"
  exit 0
fi

SHELL_VER="$(gnome-shell --version 2>/dev/null | grep -oE '[0-9]+' | head -1)"
[[ -n "$SHELL_VER" ]] || { warn "can't determine GNOME Shell version — skipping"; exit 0; }
EGO="https://extensions.gnome.org"

# is $1 present in the org.gnome.shell enabled-extensions array?
ext_enabled() { gnome-extensions list --enabled 2>/dev/null | grep -qxF "$1"; }
# append uuid to enabled-extensions if absent (idempotent). Used as a Wayland-
# safe fallback: `gnome-extensions enable` refuses a not-yet-loaded extension,
# but writing the gsettings array directly makes it load on next login.
ext_enable() {
  local uuid="$1"
  gnome-extensions enable "$uuid" 2>/dev/null && return 0   # works if already loaded
  local cur new
  cur="$(gsettings get org.gnome.shell enabled-extensions 2>/dev/null)"
  [[ "$cur" == *"'$uuid'"* ]] && return 0
  if [[ "$cur" == "@as []" || "$cur" == "[]" ]]; then
    new="['$uuid']"
  else
    new="${cur%]}, '$uuid']"
  fi
  gsettings set org.gnome.shell enabled-extensions "$new"
}

installed=0 enabled_now=0 pending=0
while IFS= read -r entry; do
  entry="${entry%%#*}"; entry="$(echo "$entry" | xargs)"; [[ -z "$entry" ]] && continue
  grp=""
  if [[ "$entry" == *" @"* ]]; then grp="${entry##*@}"; entry="${entry% @*}"; fi
  uuid="${entry%% *}"
  if [[ -n "$grp" ]] && ! group_on "$grp"; then
    ok "$uuid: gated off (@$grp)"; continue
  fi

  if gnome-extensions list 2>/dev/null | grep -qxF "$uuid"; then
    if ext_enabled "$uuid"; then
      ok "$uuid: installed + enabled"
    elif (( INSTALL )); then
      ext_enable "$uuid" && { log "enabled $uuid"; enabled_now=$((enabled_now+1)); } \
                         || warn "$uuid: installed but enable failed"
    else
      warn "$uuid: installed but not enabled (install enables it)"
    fi
    continue
  fi

  # not installed
  if (( ! INSTALL )); then
    warn "$uuid: not installed"; continue
  fi
  command -v curl >/dev/null 2>&1 || { fail "curl needed to fetch $uuid"; miss "gnome-ext: curl missing for $uuid"; continue; }
  url="$(curl -fsSL "$EGO/extension-info/?uuid=$uuid&shell_version=$SHELL_VER" 2>/dev/null \
        | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("download_url",""))
except Exception: pass' 2>/dev/null)"
  if [[ -z "$url" ]]; then
    warn "$uuid: no build for GNOME Shell $SHELL_VER on e.g.o"
    miss "gnome-ext: $uuid has no release for shell $SHELL_VER"; continue
  fi
  tmp="$(mktemp --suffix=.zip)"
  if curl -fsSL "$EGO$url" -o "$tmp" && do_or_say gnome-extensions install --force "$tmp"; then
    installed=$((installed+1))
    # on Wayland the new extension isn't loaded yet; enable still records intent
    ext_enable "$uuid" && pending=$((pending+1))
    log "installed $uuid (enabled; active after next login on Wayland)"
  else
    fail "$uuid: install failed"; miss "gnome-ext: $uuid install failed"
  fi
  rm -f "$tmp"
done < <(grep -hvE '^[[:space:]]*(#|$)' "$MANIFEST_DIR/gnome-extensions.list")

if (( pending )); then
  hint "$pending newly-installed extension(s) need a log out / log in to activate (Wayland)"
fi
ok "gnome extensions: ${installed} installed, ${enabled_now} enabled this run"
