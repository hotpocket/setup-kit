#!/bin/bash
# Calibration for component_codex (07-components + verify.sh). OpenAI's Codex
# CLI: a musl binary from chatgpt.com/codex/install.sh into ~/.local/bin, no
# node. t3code drives it like it drives claude. Login is the USER's action
# (`codex login --device-auth`); the kit only reports it.
#
# Contract (fake HOME, stubbed codex/curl, no network):
#   A. flag unset: opt-in, reported off by name, nothing proposed
#   B. yes, no codex: warns by name; check mode installs nothing; install
#      mode runs the installer, which drops ~/.local/bin/codex
#   C. yes, codex present, not logged in: warns and names the device-auth
#      login; proposes nothing (credentials are never the kit's)
#   D. yes, codex present, logged in: all OK
#   E. verify.sh: yes + no codex fails; yes + not logged in fails by name;
#      yes + logged in passes; no → "not wanted"; unset → not wanted
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; grep -i 'codex' "$TMP/out" | sed 's/^/       | /'; fi; }
H="$TMP/home"; BIN="$TMP/bin"; STATE="$TMP/state"
mkdir -p "$BIN" "$H/.local/bin" "$STATE"
# codex stub: --version; `login status` exits 0 iff $STATE/auth exists
cat > "$TMP/codex.stub" <<'S'
#!/bin/bash
case "$*" in
  --version) echo "codex-cli 0.143.0" ;;
  "login status") if [[ -e "$STATE/auth" ]]; then echo "Logged in using ChatGPT"; else echo "Not logged in"; exit 1; fi ;;
  *) echo "STUB codex $*" ;;
esac
S
# curl stub: the installer script, which drops the codex stub like the real one
cat > "$BIN/curl" <<'S'
#!/bin/bash
printf 'mkdir -p "$HOME/.local/bin"; cp "$STUB_CODEX" "$HOME/.local/bin/codex"; chmod +x "$HOME/.local/bin/codex"; echo "Installed codex"\n'
S
chmod +x "$TMP/codex.stub" "$BIN/curl"
have_codex() { cp "$TMP/codex.stub" "$H/.local/bin/codex"; }
conf() { printf '%s\n' component_oom_zram=no component_docker_rootless=no component_herdr=no component_uutils_ls=no \
  component_ollama=no component_whisper=no component_mtga=no component_dictation=no component_ocr=no component_tts=no \
  component_claude_code=no component_claude_skills=no component_aws_cli=no component_lid_ignore=no component_chatterbox=no \
  component_t3code=no "$@" > "$TMP/host.conf"; }
run07() { PATH="$BIN:$H/.local/bin:/usr/bin:/bin" HOME="$H" STATE="$STATE" STUB_CODEX="$TMP/codex.stub" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/workstation/07-components.sh" "${MODE:-check}" >"$TMP/out" 2>&1; }
runv()  { ( cd "$KIT_DIR" && PATH="$BIN:$H/.local/bin:/usr/bin:/bin" HOME="$H" STATE="$STATE" KIT_HOST_CONF="$TMP/host.conf" KIT_VERBOSE=1 ./verify.sh ) >"$TMP/out" 2>&1; }

conf; run07
assert "A. flag unset: opt-in, off by name, nothing proposed" \
  'grep -q "codex: opt-in" "$TMP/out" && ! grep -q "codex missing" "$TMP/out" && ! grep -q "\[would\].*codex" "$TMP/out"'

conf component_codex=yes; run07
assert "B1. yes, no codex: warns by name, check mode installs nothing" \
  'grep -q "WARN.*codex missing" "$TMP/out" && grep -q "\[would\].*chatgpt.com/codex/install.sh" "$TMP/out" && [[ ! -e "$H/.local/bin/codex" ]]'
MODE=install run07
assert "B2. install: installer ran, ~/.local/bin/codex present" \
  '[[ -x "$H/.local/bin/codex" ]] && grep -q "Installed codex" "$TMP/out"'

rm -f "$H/.local/bin/codex"; have_codex; conf component_codex=yes; run07
assert "C. present, not logged in: warns, names device-auth login, proposes nothing" \
  'grep -q "OK.*codex-cli 0.143.0" "$TMP/out" && grep -q "WARN.*codex not logged in.*codex login --device-auth" "$TMP/out" && ! grep -q "\[would\].*codex" "$TMP/out"'
touch "$STATE/auth"; run07
assert "D. present, logged in: all OK" \
  'grep -q "OK.*codex logged in" "$TMP/out" && ! grep -q "WARN.*codex" "$TMP/out"'

echo "verifier (verify.sh)"
rm -f "$H/.local/bin/codex" "$STATE/auth"; conf component_codex=yes; runv
assert "E1. yes + no codex: fails by name" 'grep -qE "FAIL.*codex.*missing" "$TMP/out"'
have_codex; runv
assert "E2. yes + not logged in: fails by name" 'grep -qE "FAIL.*codex.*not logged in" "$TMP/out"'
touch "$STATE/auth"; runv
assert "E3. yes + logged in: passes" 'grep -q "PASS.*codex: codex-cli 0.143.0, logged in" "$TMP/out"'
conf component_codex=no; runv
assert "E4. no: not wanted, no failure" 'grep -q "codex: not wanted" "$TMP/out" && ! grep -qE "FAIL.*codex" "$TMP/out"'
conf; runv
assert "E5. unset: opt-in, not wanted" 'grep -q "codex: not wanted" "$TMP/out"'
echo "  $pass passed, $fail failed"; (( fail == 0 ))
