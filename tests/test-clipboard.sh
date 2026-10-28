#!/bin/bash
# Calibration for component_clipboard (07-components + verify.sh +
# components/clipboard.bash). Copy/paste in GNOME Terminal on 26.04: VTE pastes
# PRIMARY on Shift+Ins and middle-click, and 26.04's gschema turned
# middle-click paste off. The component turns it back on and gives every
# shell pbcopy/pbpaste (CLIPBOARD, macOS semantics) and copy <file> (BOTH
# selections), session-aware: wl-clipboard on Wayland, xclip on X11.
#
# Contract (fake HOME, stubbed gsettings/wl-copy/wl-paste/xclip):
#   A. unset (default on), primary paste off: check warns + changes nothing;
#      install turns it on
#   B. ~/.bashrc a real file without the line: install links
#      ~/.local/share/setup-kit/clipboard.bash and appends ONE source line;
#      a second install adds nothing
#   C. ~/.bashrc a symlink that already sources clipboard.bash: OK, untouched
#   D. ~/.bashrc a symlink that doesn't: warns it's managed elsewhere, untouched
#   E. component_clipboard=no: nothing reported, nothing changed
#   F. the functions: Wayland copy fills clipboard AND primary, pbcopy clipboard
#      only; X11 the same through xclip
#   G. verify.sh: primary paste off fails, on passes — with dock=no too;
#      .bashrc not sourcing fails; no: not wanted
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; grep -iE 'clip|paste|bashrc' "$TMP/out" | sed 's/^/       | /'; fi; }
H="$TMP/home"; BIN="$TMP/bin"; CALLS="$TMP/calls"; STATE="$TMP/state"
LINK="$H/.local/share/setup-kit/clipboard.bash"
mkdir -p "$H" "$BIN" "$STATE"
# gsettings: primary-paste lives in $STATE/pp (true|false); every call recorded
cat > "$BIN/gsettings" <<'S'
#!/bin/bash
echo "gsettings $*" >> "$CALLS"
case "$1 $3" in
  "get gtk-enable-primary-paste") cat "$STATE/pp" ;;
  "set gtk-enable-primary-paste") echo "$4" > "$STATE/pp" ;;
esac
exit 0
S
# clipboard tools record argv + what they were fed
for c in wl-copy wl-paste xclip; do
  printf '#!/bin/bash\necho "%s $* <$(cat)" >> "%s"\n' "$c" "$CALLS" > "$BIN/$c"
done
chmod +x "$BIN"/*
export CALLS STATE
conf() { printf '%s\n' group_desktop=yes component_oom_zram=no component_docker_rootless=no component_herdr=no \
  component_uutils_ls=no component_ollama=no component_whisper=no component_mtga=no component_aws_cli=no \
  component_lid_ignore=no component_chatterbox=no component_t3code=no component_codex=no group_dev_cloud=no \
  component_dictation=no component_ocr=no component_tts=no "$@" > "$TMP/host.conf"; }
run07() { : > "$CALLS"; PATH="$BIN:/usr/bin:/bin" HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/bus" bash "$KIT_DIR/profiles/workstation/07-components.sh" "${MODE:-check}" >"$TMP/out" 2>&1; }
runv() { ( cd "$KIT_DIR" && PATH="$BIN:/usr/bin:/bin" HOME="$H" KIT_HOST_CONF="$TMP/host.conf" KIT_VERBOSE=1 \
  DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/bus" ./verify.sh ) >"$TMP/out" 2>&1; }
reset() { rm -rf "$H"; mkdir -p "$H"; echo false > "$STATE/pp"; printf '# stock ubuntu bashrc\n' > "$H/.bashrc"; }

reset; conf; run07
assert "A1. unset, primary paste off: check warns by name, changes nothing" \
  'grep -q "WARN.*primary" "$TMP/out" && [[ "$(cat "$STATE/pp")" == false ]] && ! grep -q "gsettings set" "$CALLS"'
MODE=install run07
assert "A2. install turns middle-click primary paste on" '[[ "$(cat "$STATE/pp")" == true ]]'

reset; conf; MODE=install run07; MODE=install run07
assert "B. real ~/.bashrc: link made, ONE source line after two installs" \
  '[[ "$(readlink -f "$LINK")" == "$KIT_DIR/components/clipboard.bash" ]] && [[ "$(grep -c "setup-kit/clipboard.bash" "$H/.bashrc")" == 1 ]]'

reset; printf '. "$GIT_HOME/setup-kit/components/clipboard.bash"\n' > "$TMP/managed"; ln -sfn "$TMP/managed" "$H/.bashrc"
conf; MODE=install run07
assert "C. symlinked ~/.bashrc that sources it: OK, untouched" \
  'grep -q "OK.*bashrc" "$TMP/out" && [[ "$(cat "$TMP/managed")" == ". \"\$GIT_HOME/setup-kit/components/clipboard.bash\"" ]]'

reset; printf '# owned elsewhere\n' > "$TMP/managed"; ln -sfn "$TMP/managed" "$H/.bashrc"
conf; MODE=install run07
assert "D. symlinked ~/.bashrc that doesn't: warns it's managed elsewhere, untouched" \
  'grep -q "WARN.*bashrc.*managed elsewhere" "$TMP/out" && [[ "$(cat "$TMP/managed")" == "# owned elsewhere" ]]'

reset; conf component_clipboard=no; MODE=install run07
assert "E. no: nothing reported, nothing changed" \
  '! grep -qiE "primary|clipboard" "$TMP/out" && [[ "$(cat "$STATE/pp")" == false ]] && [[ ! -e "$LINK" ]] && [[ "$(cat "$H/.bashrc")" == "# stock ubuntu bashrc" ]]'

echo hello > "$TMP/f"
fn() { : > "$CALLS"; env -i PATH="$BIN:/usr/bin:/bin" CALLS="$CALLS" "$@" bash -c ". '$KIT_DIR/components/clipboard.bash'; copy '$TMP/f'; echo pb | pbcopy"; }
fn WAYLAND_DISPLAY=wayland-0
assert "F1. Wayland: copy fills clipboard and primary, pbcopy clipboard only" \
  'grep -qx "wl-copy  <hello" "$CALLS" && grep -qx "wl-copy --primary <hello" "$CALLS" && grep -qx "wl-copy  <pb" "$CALLS" && [[ "$(grep -c primary "$CALLS")" == 1 ]]'
fn DISPLAY=:0
assert "F2. X11: the same through xclip" \
  'grep -qx "xclip -selection clipboard <hello" "$CALLS" && grep -qx "xclip -selection primary <hello" "$CALLS" && grep -qx "xclip -selection clipboard <pb" "$CALLS"'

reset; conf; runv
assert "G1. verify: primary paste off fails by name" 'grep -q "FAIL.*primary paste" "$TMP/out"'
echo true > "$STATE/pp"; conf dock=no; runv
assert "G2. verify: primary paste on passes, dock=no doesn't hide it" 'grep -q "PASS.*primary paste enabled" "$TMP/out"'
assert "G3. verify: ~/.bashrc not sourcing clipboard.bash fails by name" 'grep -q "FAIL.*clipboard.bash" "$TMP/out"'
conf component_clipboard=no; runv
assert "G4. verify: no — not wanted, no clipboard failure" \
  'grep -q "clipboard: not wanted" "$TMP/out" && ! grep -qE "FAIL.*(clipboard\.bash|primary paste)" "$TMP/out"'

reset; conf
printf '%s\n' '  # . "$HOME/.local/share/setup-kit/clipboard.bash"' > "$H/.bashrc"
cp "$H/.bashrc" "$TMP/before.bashrc"; run07
assert "H1. commented source: check warns and leaves bashrc untouched" \
  'grep -q "WARN.*bashrc.*doesn.*source" "$TMP/out" && ! grep -q "OK.*bashrc" "$TMP/out" && cmp -s "$H/.bashrc" "$TMP/before.bashrc"'
runv
assert "H2. commented source: verifier reports missing clipboard functions" 'grep -q "FAIL.*clipboard.bash" "$TMP/out"'
MODE=install run07; MODE=install run07
assert "H3. commented source: install adds one active source, new shells have all three functions" \
  '[[ "$(grep -c "^\[ -f .*clipboard.bash" "$H/.bashrc")" == 1 ]] \
   && HOME="$H" bash -c '\''. "$HOME/.bashrc"; declare -F pbcopy && declare -F pbpaste && declare -F copy'\'' >/dev/null'

reset; conf
printf '%s\n' '# source "$HOME/.local/share/setup-kit/clipboard.bash"' > "$TMP/managed"
cp "$TMP/managed" "$TMP/before.bashrc"; ln -sfn "$TMP/managed" "$H/.bashrc"
MODE=install run07
assert "H4. symlinked commented source: warns managed elsewhere, never written through" \
  'grep -q "WARN.*bashrc.*managed elsewhere" "$TMP/out" && [[ -L "$H/.bashrc" ]] && cmp -s "$TMP/managed" "$TMP/before.bashrc"'
runv
assert "H5. symlinked commented source: verifier fails too" 'grep -q "FAIL.*clipboard.bash" "$TMP/out"'

reset; conf
printf '%s\n' '[[ -f "${GIT_HOME:-$HOME/git}/setup-kit/components/clipboard.bash" ]] && source "${GIT_HOME:-$HOME/git}/setup-kit/components/clipboard.bash"' > "$TMP/managed"
cp "$TMP/managed" "$TMP/before.bashrc"; ln -sfn "$TMP/managed" "$H/.bashrc"
MODE=install run07
assert "H6. owner-style conditional source with GIT_HOME fallback: recognized, symlink untouched" \
  'grep -q "OK.*bashrc" "$TMP/out" && [[ -L "$H/.bashrc" ]] && cmp -s "$TMP/managed" "$TMP/before.bashrc"'
runv
assert "H7. verifier recognizes the owner-style active source" 'grep -q "PASS.*bashrc sources clipboard.bash" "$TMP/out"'

reset; conf
printf '%s\n' 'echo harmless # source clipboard.bash' > "$H/.bashrc"; run07
assert "H8. inline comment: check still reports missing source" 'grep -q "WARN.*bashrc.*doesn.*source" "$TMP/out"'
runv
assert "H9. inline comment: verifier still reports missing source" 'grep -q "FAIL.*clipboard.bash" "$TMP/out"'

echo "test-clipboard: $pass passed, $fail failed"
(( fail == 0 ))
