#!/bin/bash
# Calibration for component_tts (07-components + verify.sh). The kokoro venv
# was "ALWAYS provisioned, NOT opt-in" — so a worker with no desktop session
# to speak from got a 5.9 GB torch venv it never runs (2026-09-16, ai-3090),
# and verify.sh failed it as missing once removed. Now it is a flag: default
# yes (the workstation's .configs client needs the backend), no = skipped by
# the installer AND the verifier, both saying so by name.
#
# Contract (check mode, fake HOME with no venv, no network):
#   A. flag unset: installer warns the venv is missing (default on)
#   B. component_tts=no: installer reports disabled, never mentions a missing venv
#   C. verify.sh, flag unset: fails "tts venv missing"
#   D. verify.sh, component_tts=no: passes "not wanted", no tts failure
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; grep -i tts "$TMP/out" | sed 's/^/       | /'; fi; }
mkdir -p "$TMP/home" "$TMP/bin"
# every other component off so the phase is quick and quiet; pyenv absent → no 3.12
conf() { printf '%s\n' component_oom_zram=no component_docker_rootless=no component_herdr=no component_uutils_ls=no \
  component_ollama=no component_whisper=no component_mtga=no component_dictation=no component_ocr=no \
  component_claude_code=no component_claude_skills=no component_aws_cli=no component_lid_ignore=no "$@" > "$TMP/host.conf"; }
run07() { HOME="$TMP/home" HOST_CONF="$TMP/host.conf" LOG_DIR="$TMP" bash "$KIT_DIR/profiles/workstation/07-components.sh" check >"$TMP/out" 2>&1; }
runv()  { ( cd "$KIT_DIR" && HOME="$TMP/home" KIT_HOST_CONF="$TMP/host.conf" KIT_VERBOSE=1 ./verify.sh ) >"$TMP/out" 2>&1; }

echo "installer (07-components.sh, check mode)"
conf; run07
assert "A. flag unset: default on, venv reported missing" 'grep -q "tts virtualenv missing" "$TMP/out"'
conf component_tts=no; run07
assert "B. no: disabled by name, no missing-venv warning" \
  'grep -q "tts (kokoro): disabled" "$TMP/out" && ! grep -q "tts virtualenv missing" "$TMP/out"'

echo "verifier (verify.sh)"
conf; runv
assert "C. flag unset: tts venv failure" 'grep -q "tts venv missing" "$TMP/out"'
conf component_tts=no; runv
assert "D. no: passes as not wanted, no tts failure" \
  'grep -q "tts venv: not wanted" "$TMP/out" && ! grep -qE "FAIL.*tts venv" "$TMP/out"'
echo "  $pass passed, $fail failed"; (( fail == 0 ))
