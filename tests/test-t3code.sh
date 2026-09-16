#!/bin/bash
# Calibration for component_t3code (07-components + verify.sh). T3 Code is a
# web front end for the coding agents already on the box (it drives the
# `claude` CLI's own login; no key of its own). Self-contained `t3` binary from
# t3.codes/install.sh into ~/.local/bin, served by a systemd USER unit
# (t3code.service, written by `t3 service install`). The bind address lives in
# a drop-in the kit owns — `t3 service install` re-renders the unit on every
# update, so anything written INTO the unit would not survive `t3 update`.
#
# Contract (fake HOME, stubbed t3/systemctl/curl/claude, no network):
#   A. flag unset: opt-in, reported off by name, nothing proposed
#   B. yes, no t3: warns by name; check mode installs nothing; install mode
#      runs the installer, which links ~/.local/bin/t3
#   C. yes, t3 present, claude missing: warns the provider is absent; service
#      not installed → warns, would `t3 service install`
#   D. yes, everything present, drop-in matches: all OK, nothing proposed
#   D2. drop-in drifted (host changed in the conf): warns; install mode
#      rewrites it and restarts the unit
#   E. verify.sh: yes + no t3 fails by name; yes + service active passes;
#      no → "not wanted"; unset → not wanted
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; grep -i 't3' "$TMP/out" | sed 's/^/       | /'; fi; }
H="$TMP/home"; BIN="$TMP/bin"; STATE="$TMP/state"
UNIT="$H/.config/systemd/user/t3code.service"; DROPIN="$H/.config/systemd/user/t3code.service.d/setup-kit.conf"
mkdir -p "$BIN" "$H/.local/bin" "$STATE"
# t3 stub: --version; `service install` writes the unit and marks enabled+active
cat > "$TMP/t3.stub" <<'S'
#!/bin/bash
case "$*" in
  --version) echo "t3 v0.0.42" ;;
  "service install") mkdir -p "$HOME/.config/systemd/user"; printf '[Service]\nExecStart=t3 __service-launcher\n' > "$HOME/.config/systemd/user/t3code.service"
                     touch "$STATE/enabled" "$STATE/active"; echo "STUB: t3 service install" ;;
  *) echo "STUB t3 $*" ;;
esac
S
# systemctl stub: state lives in $STATE; restart/daemon-reload are recorded
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
case "$*" in
  *is-enabled*) [[ -e "$STATE/enabled" ]] ;;
  *is-active*)  [[ -e "$STATE/active" ]] ;;
  *daemon-reload*) echo "STUB: daemon-reload" >> "$STATE/calls" ;;
  *restart*)    echo "STUB: restart" >> "$STATE/calls"; touch "$STATE/active" ;;
  *) exit 0 ;;
esac
S
# curl stub: the installer script, which links the t3 stub like the real one
cat > "$BIN/curl" <<'S'
#!/bin/bash
printf 'mkdir -p "$HOME/.local/bin"; cp "$STUB_T3" "$HOME/.local/bin/t3"; chmod +x "$HOME/.local/bin/t3"; echo "Installed t3 0.0.42"\n'
S
chmod +x "$TMP/t3.stub" "$BIN/systemctl" "$BIN/curl"
have_claude() { printf '#!/bin/bash\necho 2.1.0\n' > "$H/.local/bin/claude"; chmod +x "$H/.local/bin/claude"; }
have_t3()     { cp "$TMP/t3.stub" "$H/.local/bin/t3"; }
conf() { printf '%s\n' component_oom_zram=no component_docker_rootless=no component_herdr=no component_uutils_ls=no \
  component_ollama=no component_whisper=no component_mtga=no component_dictation=no component_ocr=no component_tts=no \
  component_claude_code=no component_claude_skills=no component_aws_cli=no component_lid_ignore=no component_chatterbox=no "$@" > "$TMP/host.conf"; }
# PATH: stubs first, then the fake HOME's bin, then coreutils — no real t3/systemctl/claude
run07() { PATH="$BIN:$H/.local/bin:/usr/bin:/bin" HOME="$H" STATE="$STATE" STUB_T3="$TMP/t3.stub" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/workstation/07-components.sh" "${MODE:-check}" >"$TMP/out" 2>&1; }
runv()  { ( cd "$KIT_DIR" && PATH="$BIN:$H/.local/bin:/usr/bin:/bin" HOME="$H" STATE="$STATE" KIT_HOST_CONF="$TMP/host.conf" KIT_VERBOSE=1 ./verify.sh ) >"$TMP/out" 2>&1; }
reset() { rm -rf "$H/.local/bin"/* "$H/.config" "$STATE"/*; }

conf; run07
assert "A. flag unset: opt-in, off by name, nothing proposed" \
  'grep -q "t3code: opt-in" "$TMP/out" && ! grep -q "t3 missing" "$TMP/out" && ! grep -q "\[would\].*t3" "$TMP/out"'

conf component_t3code=yes; run07
assert "B1. yes, no t3: warns by name, check mode installs nothing" \
  'grep -q "WARN.*t3 missing" "$TMP/out" && [[ ! -e "$H/.local/bin/t3" ]] && [[ ! -e "$UNIT" ]]'
MODE=install run07
assert "B2. install: installer ran, ~/.local/bin/t3 linked, service installed and drop-in written" \
  '[[ -x "$H/.local/bin/t3" ]] && [[ -f "$UNIT" ]] && grep -q "T3CODE_HOST=127.0.0.1" "$DROPIN" && grep -q "T3CODE_PORT=3773" "$DROPIN"'

reset; have_t3; conf component_t3code=yes; run07
assert "C1. t3 present, claude missing: warns the provider is absent" \
  'grep -q "OK.*t3 v0.0.42" "$TMP/out" && grep -q "WARN.*claude.*not on PATH" "$TMP/out"'
assert "C2. service not installed: warns, would install (check mode writes nothing)" \
  'grep -q "WARN.*t3code.service not installed" "$TMP/out" && grep -q "\[would\].*t3 service install" "$TMP/out" && [[ ! -e "$UNIT" ]]'

reset; have_t3; have_claude; conf component_t3code=yes; MODE=install run07; MODE=check run07
assert "D. everything present, drop-in matches: all OK, nothing proposed" \
  'grep -q "OK.*t3code.service installed" "$TMP/out" && grep -q "OK.*t3code.service active" "$TMP/out" && grep -q "OK.*t3code bind" "$TMP/out" && ! grep -q "WARN.*t3" "$TMP/out" && ! grep -q "\[would\].*t3" "$TMP/out"'
: > "$STATE/calls"; conf component_t3code=yes t3code_host=0.0.0.0; run07
assert "D2a. drop-in drifted: warns, check mode leaves it" \
  'grep -q "WARN.*t3code bind.*drifted" "$TMP/out" && grep -q "T3CODE_HOST=127.0.0.1" "$DROPIN" && [[ ! -s "$STATE/calls" ]]'
MODE=install run07
assert "D2b. install: drop-in rewritten, daemon-reload + restart" \
  'grep -q "T3CODE_HOST=0.0.0.0" "$DROPIN" && grep -q "daemon-reload" "$STATE/calls" && grep -q "restart" "$STATE/calls"'
rm -f "$STATE/active"; run07
assert "D3. unit enabled but not running: warns, would restart" \
  'grep -q "WARN.*t3code.service not running" "$TMP/out" && grep -q "\[would\].*restart t3code.service" "$TMP/out"'

echo "verifier (verify.sh)"
reset; conf component_t3code=yes; runv
assert "E1. yes + no t3: fails by name" 'grep -qE "FAIL.*t3code" "$TMP/out"'
have_t3; touch "$STATE/active"; runv
assert "E2. yes + t3 + service active: passes" 'grep -q "PASS.*t3code: t3 v0.0.42, t3code.service active" "$TMP/out"'
rm -f "$STATE/active"; runv
assert "E3. yes + t3 but service down: fails by name" 'grep -qE "FAIL.*t3code.*not active" "$TMP/out"'
conf component_t3code=no; runv
assert "E4. no: not wanted, no failure" 'grep -q "t3code: not wanted" "$TMP/out" && ! grep -qE "FAIL.*t3code" "$TMP/out"'
conf; runv
assert "E5. unset: opt-in, not wanted" 'grep -q "t3code: not wanted" "$TMP/out"'
echo "  $pass passed, $fail failed"; (( fail == 0 ))
