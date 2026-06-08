#!/bin/bash
# User config layer: clone hotpocket/.configs and run its setup.
# The kit never duplicates dotfiles — .configs owns them.
SCRIPT_NAME="ws-06-configs"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

REPO="$(conf_get configs_repo 'git@github.com:hotpocket/.configs.git')"
DEST="$HOME/git/.configs"

section ".configs ($MODE)"
if [[ -d "$DEST/.git" ]]; then
  ok ".configs cloned at $DEST"
else
  warn ".configs not cloned"
  if (( INSTALL )); then
    mkdir -p "$(dirname "$DEST")"
    git clone "$REPO" "$DEST" 2>&1 | tee -a "$LOG_DIR/$SCRIPT_NAME.log"
    # private repo + fresh box = no auth yet. At a real terminal, fix it
    # inline instead of bouncing the user out to re-run.
    if [[ ! -d "$DEST/.git" ]] && [[ -t 0 ]] && command -v gh >/dev/null 2>&1; then
      warn ".configs is private and this box has no GitHub auth yet"
      read -rp "Authenticate with GitHub now (gh auth login)? [Y/n] " a
      if [[ ! "$a" =~ ^[Nn] ]]; then
        gh auth login && gh auth setup-git \
          && git clone "$REPO" "$DEST" 2>&1 | tee -a "$LOG_DIR/$SCRIPT_NAME.log"
      fi
    fi
    if [[ ! -d "$DEST/.git" ]]; then
      fail ".configs clone failed — needs GitHub auth"
      hint "gh auth login   (or restore your ssh key), then re-run install"
      miss ".configs: clone blocked on auth"
      exit 1
    fi
  else
    hint "git clone $REPO $DEST"
  fi
fi

if [[ -x "$DEST/setup.sh" ]]; then
  if (( INSTALL )) && [[ "$(conf_get configs_run_setup yes)" == yes ]]; then
    log "running .configs/setup.sh install..."
    (cd "$DEST" && ./setup.sh install) 2>&1 | tee -a "$LOG_DIR/$SCRIPT_NAME.log"
  else
    log ".configs doctor:"
    (cd "$DEST" && ./setup.sh check) || true
  fi
else
  [[ -d "$DEST" ]] && warn ".configs has no setup.sh (old checkout?)"
fi

# --- one symlink-or-heal primitive for every .configs subtree (3a/3b) ------
# link_one <src-file> <target>: make $target a symlink to $src, healing a
# stale REAL file in the way (which would otherwise shadow the .configs copy).
# Identical real files are replaced silently; DIVERGENT ones are backed up to
# .pre-setup-kit and flagged loudly (a real file may be NEWER — never lose it).
# Sets LINK_CHANGED=1 when it links something. check-mode only reports.
LINK_CHANGED=0
link_one() {
  local src="$1" tgt="$2" rel="${2/#$HOME/\~}"
  [[ -e "$src" ]] || return 0
  if [[ -L "$tgt" && "$(readlink -f "$tgt")" == "$(readlink -f "$src")" ]]; then
    return 0                                   # already correct
  fi
  if [[ -e "$tgt" && ! -L "$tgt" ]]; then      # real file in the way
    if (( ! INSTALL )); then
      warn "$rel is a real file shadowing .configs (run install to heal)"; return 0
    fi
    if cmp -s "$src" "$tgt"; then
      rm -f "$tgt"                             # redundant identical copy
    else
      mv "$tgt" "$tgt.pre-setup-kit"
      warn "DIVERGENT $rel → backed up .pre-setup-kit (differs from .configs — may be newer; review)"
    fi
  elif (( ! INSTALL )); then
    warn "$rel not linked to .configs"; return 0
  fi
  mkdir -p "$(dirname "$tgt")"
  ln -sf "$src" "$tgt" && { log "linked $rel → ${src/#$HOME/\~}"; LINK_CHANGED=1; }
}

# link_tree <src-dir> <dst-dir> [exec_gate] : link every file under src into
# dst (mirrored). exec_gate=1 → skip .desktop entries whose Exec binary isn't
# installed here (e.g. a launcher for a tool this box doesn't have). Reads
# extra find predicates from $LINK_FIND[@] if set.
link_tree() {
  local src="$1" dst="$2" gate="${3:-0}" f exe
  [[ -d "$src" ]] || return 0
  while IFS= read -r f; do
    if (( gate )); then
      exe="$(sed -n 's/^Exec=//p' "$f" | head -1 | tr -d '"' | awk '{print $1}')"
      if [[ -n "$exe" ]] && ! command -v "$exe" >/dev/null 2>&1 && [[ ! -x "$exe" ]]; then
        log "skip $(basename "$f") (Exec '$exe' not installed here)"; continue
      fi
    fi
    link_one "$f" "$dst/${f#"$src"/}"
  done < <(find "$src" -type f "${LINK_FIND[@]}" 2>/dev/null)
}

# 1) core dotfiles (specific files at the repo root)  2) ~/bin executables
_w=$DOCTOR_WARN
for df in .bashrc .bash_aliases .gitconfig; do
  link_one "$DEST/$df" "$HOME/$df"
done
mkdir -p "$HOME/bin"
LINK_FIND=(-maxdepth 1 -executable); link_tree "$DEST/bin" "$HOME/bin"; LINK_FIND=()
(( DOCTOR_WARN == _w )) && ok "dotfiles + ~/bin: all linked to .configs"

# Launcher assets: .configs tracks ~/.local/share/{applications,icons} for
# custom tools (ocrscr, tts). setup.sh copies the .desktop files but NOT the
# hicolor icons → iconless entries, unpinned. Mirror both, refresh caches,
# pin to the dock.
LS_SRC="$DEST/.local/share"
if [[ -d "$LS_SRC" ]]; then
  LINK_CHANGED=0
  LINK_FIND=(\( -path '*/applications/*.desktop' -o -path '*/icons/*' \))
  link_tree "$LS_SRC" "$HOME/.local/share"; LINK_FIND=()
  changed=$LINK_CHANGED
  if (( INSTALL && changed )); then
    log "linked launcher assets; refreshing desktop db"
    update-desktop-database "$HOME/.local/share/applications" 2>/dev/null || true
    # Do NOT build a per-user icon cache: ~/.local/share/icons/hicolor has
    # no index.theme, so gtk-update-icon-cache yields a DEGENERATE cache
    # that GTK trusts as authoritative and serves nothing from — worse than
    # none (it hides the icons entirely). Remove any stale cache and
    # let GTK live-scan the dir against the system hicolor index.theme.
    rm -f "$HOME/.local/share/icons/hicolor/icon-theme.cache"
  fi
  (( changed )) || ok "launcher assets (applications + icons) present"

  # Pin .configs-shipped launchers to the dock (merge, don't clobber others)
  if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] && command -v gsettings >/dev/null; then
    cur="$(gsettings get org.gnome.shell favorite-apps 2>/dev/null)"
    add=()
    for d in "$LS_SRC"/applications/*.desktop; do
      n="$(basename "$d")"; [[ "$cur" == *"'$n'"* ]] || add+=("$n")
    done
    if (( ${#add[@]} )); then
      warn "dock: ${add[*]} not pinned"
      if (( INSTALL )); then
        new="${cur%]}"; [[ "$new" == "[" ]] || new+=", "
        for n in "${add[@]}"; do new+="'$n', "; done
        new="${new%, }]"
        gsettings set org.gnome.shell favorite-apps "$new" && log "pinned: ${add[*]}"
      fi
    else
      ok "dock: custom launchers pinned"
    fi
  fi
fi

# Autostart entries: .configs tracks ~/.config/autostart (tts-server etc.)
# but setup.sh doesn't wire them. Same symlink convention as launcher assets,
# exec-gated so each box only autostarts apps it actually has.
AS_SRC="$DEST/.config/autostart"
if [[ -d "$AS_SRC" ]]; then
  mkdir -p "$HOME/.config/autostart"
  _w=$DOCTOR_WARN
  link_tree "$AS_SRC" "$HOME/.config/autostart" 1
  (( DOCTOR_WARN == _w )) && ok "autostart entries linked"
fi

# dconf: .configs carries the dumps (dconf/ dir); load only in a session
if [[ -d "$DEST/dconf" ]] && compgen -G "$DEST/dconf/*.ini" >/dev/null; then
  if [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]]; then
    for ini in "$DEST/dconf"/*.ini; do
      # files are named for their dconf path: notifications.ini -> /org/gnome/desktop/notifications/
      ok "dconf dump available: $(basename "$ini") (loaded by .configs/setup.sh)"
    done
  else
    warn "no DBus session — dconf loads must run from a desktop terminal"
  fi
fi
