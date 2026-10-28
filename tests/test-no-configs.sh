#!/bin/bash
# Calibration for configs=no and dock=no — a box that is not the kit owner's
# (a friend's machine): no private .configs clone, none of the owner's
# YubiKey/GPG chain, no conduct skills sourced from .configs, and the owner's
# dock layout not forced over the user's own pins.
#
# Contract (fake HOME, stubbed git/ssh/systemctl/gsettings, no network):
#   A. preamble, configs=no: says so, clones nothing, leaves the GNOME ssh agent alone
#   A2. preamble, configs unset: still tries the .configs clone (the owner's default)
#   B. 06-configs, configs=no: skipped by name, no clone, no warnings
#   B2. 06-configs, configs unset: still reports .configs not cloned
#   C. 06-gpg-pass, configs=no: skipped by name, no warnings
#   D. 08-claude-skills, configs=no, claude_skills unset: gstack only, over
#      https (no GitHub ssh auth on the box), no conduct/vault-digest/agents noise
#   E. verify.sh, configs=no: no .configs dotfile or ~/bin failures
#   E2. 07, configs=no, dictation/ocr/tts unset: all three off — each serves a
#       .configs tool (Alt+s wrapper, ocrscr, the clipboard TTS client)
#   E3. 07, configs unset: the three still default on
#   F. 06y-dock, dock=no: dock left alone, nothing set
#   G. verify.sh, dock=no: no dock-pin failures
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out" | tail -25; fi; }
H="$TMP/home"; BIN="$TMP/bin"; CALLS="$TMP/calls"
mkdir -p "$H" "$BIN"
# every stub records its argv, so "nothing was cloned / set / masked" is checkable
for c in git ssh ssh-keygen ssh-keyscan gh gpg pass scdaemon gsettings gnome-extensions bun curl sysctl lsusb; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\n' "$c" "$CALLS" > "$BIN/$c"
done
# systemctl: record, and report nothing active/enabled
printf '#!/bin/bash\necho "systemctl $*" >> "%s"\nexit 1\n' "$CALLS" > "$BIN/systemctl"
# gsettings get answers a dock that is not the manifest's
printf '#!/bin/bash\necho "gsettings $*" >> "%s"\n[[ "$1" == get ]] && echo "['"'"'firefox_firefox.desktop'"'"']"\nexit 0\n' "$CALLS" > "$BIN/gsettings"
chmod +x "$BIN"/*
conf() { printf '%s\n' group_desktop=yes "$@" > "$TMP/host.conf"; }
run() {  # phase-script [mode]
  : > "$CALLS"
  PATH="$BIN:/usr/bin:/bin" HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
    DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/bus" \
    bash "$KIT_DIR/profiles/workstation/$1" "${2:-check}" >"$TMP/out" 2>&1
}
runv() {
  : > "$CALLS"
  ( cd "$KIT_DIR" && PATH="$BIN:/usr/bin:/bin" HOME="$H" KIT_HOST_CONF="$TMP/host.conf" KIT_VERBOSE=1 \
      DBUS_SESSION_BUS_ADDRESS="unix:path=$TMP/bus" ./verify.sh ) >"$TMP/out" 2>&1
}

conf configs=no; run preamble-github-auth.sh install
assert "A. preamble, configs=no: says so, clones nothing, leaves the gnome ssh agent alone" \
  'grep -q "configs=no" "$TMP/out" && ! grep -q "^git clone" "$CALLS" && ! grep -q "mask" "$CALLS" && [[ ! -e "$H/.config/autostart/gnome-keyring-ssh.desktop" ]]'
conf; run preamble-github-auth.sh install
assert "A2. preamble, configs unset: still tries the .configs clone" \
  'grep -q "^git clone git@github.com:hotpocket/.configs.git" "$CALLS"'

conf configs=no; run 06-configs.sh install
assert "B. 06-configs, configs=no: skipped by name, no clone, no warnings" \
  'grep -q "configs=no" "$TMP/out" && ! grep -q "^git clone" "$CALLS" && ! grep -q "WARN" "$TMP/out"'
conf; run 06-configs.sh check
assert "B2. 06-configs, configs unset: still reports .configs not cloned" \
  'grep -q "WARN.*\.configs not cloned" "$TMP/out"'

conf configs=no; run 06-gpg-pass.sh check
assert "C. 06-gpg-pass, configs=no: skipped by name, no warnings" \
  'grep -q "configs=no" "$TMP/out" && ! grep -q "WARN" "$TMP/out"'

conf configs=no component_claude_code=no; run 08-claude-skills.sh install
assert "D. 08, configs=no: gstack only, cloned over https, no conduct/vault-digest/agents noise" \
  'grep -q "^git clone https://github.com/garrytan/gstack.git" "$CALLS" && ! grep -q "hotpocket/.configs" "$CALLS" \
   && ! grep -qiE "claude-conduct|vault-digest|agents" "$TMP/out"'

conf configs=no; runv
assert "E. verify.sh, configs=no: no .configs dotfile or ~/bin failures" \
  '! grep -qE "FAIL.*(\.configs|dotfile)" "$TMP/out" && grep -q "configs=no" "$TMP/out"'

off07() { printf '%s\n' component_oom_zram=no component_docker_rootless=no component_herdr=no component_uutils_ls=no \
  component_ollama=no component_whisper=no component_mtga=no component_aws_cli=no component_lid_ignore=no \
  component_chatterbox=no component_t3code=no component_codex=no group_dev_cloud=no "$@" > "$TMP/host.conf"; }
off07 configs=no; run 07-components.sh check
assert "E2. 07, configs=no: dictation, ocr and tts default off, nothing asks for .configs" \
  '! grep -qE "^(dictation|ocr|tts)" "$TMP/out" && ! grep -qE "WARN.*(\.configs|06-configs)" "$TMP/out"'
off07; run 07-components.sh check
assert "E3. 07, configs unset: dictation, ocr and tts still default on" \
  'grep -q "^dictation" "$TMP/out" && grep -q "^ocr" "$TMP/out" && grep -q "^tts" "$TMP/out"'

# Copy the shipped answer file: defaults must survive the way a new box is
# actually configured. Keep unrelated components off in this fake machine.
template_conf() {
  off07
  cp "$TMP/host.conf" "$TMP/off07.conf"
  cp "$KIT_DIR/hosts/example.conf" "$TMP/host.conf"
  cat "$TMP/off07.conf" >> "$TMP/host.conf"
  printf '%s\n' configs=no tmp_on_disk=no component_resource_guards=no "$@" >> "$TMP/host.conf"
}
# OCR has no standalone verifier check yet. Exercise the verifier's real
# independent reader for all three, alongside its full runtime checks below.
verify_defaults() {
  CONF="$TMP/host.conf" bash -c '
    source <(sed -n "/^cv()/,/^dflt()/p" "$1")
    for key in component_dictation component_ocr component_tts; do
      printf "%s=%s\n" "$key" "$(dflt "$key")"
    done
  ' _ "$KIT_DIR/verify.sh" > "$TMP/defaults"
}
template_conf; run 07-components.sh check
assert "E4. copied template + configs=no: 07 leaves dictation, OCR and TTS off" \
  '! grep -qE "^(dictation|ocr|tts)" "$TMP/out" && grep -q "tts flutter client: not wanted" "$TMP/out"'
runv; verify_defaults
assert "E5. copied template + configs=no: verifier defaults all three off, no private client failure" \
  '[[ "$(grep -c "=no$" "$TMP/defaults")" == 3 ]] && grep -q "tts venv: not wanted" "$TMP/out" \
   && ! grep -qE "FAIL.*(vosk|tts|flutter client)" "$TMP/out"'
template_conf component_dictation=yes component_ocr=yes component_tts=yes
run 07-components.sh check
assert "E6. explicit host values still enable all three with configs=no" \
  'grep -q "^dictation" "$TMP/out" && grep -q "^ocr" "$TMP/out" && grep -q "^tts" "$TMP/out"'
runv; verify_defaults
assert "E7. verifier honors explicit yes values with configs=no" \
  '[[ "$(grep -c "=yes$" "$TMP/defaults")" == 3 ]] && grep -q "FAIL.*tts flutter client bundle missing" "$TMP/out" && grep -q "FAIL.*vosk venv missing" "$TMP/out"'

conf dock=no; run 06y-dock.sh install
assert "F. 06y-dock, dock=no: left alone by name, nothing set" \
  'grep -q "dock=no" "$TMP/out" && ! grep -q "gsettings set" "$CALLS"'
conf; run 06y-dock.sh install
assert "F2. 06y-dock, dock unset: still sets the manifest dock" \
  'grep -q "gsettings set org.gnome.shell favorite-apps" "$CALLS"'

conf dock=no; runv
assert "G. verify.sh, dock=no: no dock failures" \
  '! grep -qE "FAIL.*dock" "$TMP/out" && grep -q "dock=no" "$TMP/out"'

echo "test-no-configs: $pass passed, $fail failed"
(( fail == 0 ))
