# Clipboard helpers for interactive bash — sourced from ~/.bashrc
# (components/clipboard.md). Session-aware: Wayland → wl-copy/wl-paste,
# X11 → xclip (xclip is X11-only and silently fails on Wayland).

# pbcopy/pbpaste — macOS-style: the CLIPBOARD selection only (Ctrl+V).
pbcopy()  { if [ "${XDG_SESSION_TYPE:-}" = wayland ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then wl-copy; else xclip -selection clipboard; fi; }
pbpaste() { if [ "${XDG_SESSION_TYPE:-}" = wayland ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then wl-paste -n; else xclip -selection clipboard -o; fi; }

# copy <file> — file onto BOTH selections. VTE ≥26.04 pastes PRIMARY on
# Shift+Ins/middle-click (and a TTS reader may read PRIMARY too); CLIPBOARD
# covers Ctrl+V.
copy() {
  [ -f "${1:-}" ] || { echo "usage: copy <file>" >&2; return 1; }
  if [ "${XDG_SESSION_TYPE:-}" = wayland ] || [ -n "${WAYLAND_DISPLAY:-}" ]; then
    wl-copy < "$1" && wl-copy --primary < "$1"
  else
    xclip -selection clipboard < "$1" && xclip -selection primary < "$1"
  fi
}
