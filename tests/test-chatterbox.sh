#!/bin/bash
# Calibration for component_chatterbox (07-components + verify.sh). The
# audiobook line renders with Chatterbox-TTS from a pyenv virtualenv named
# `chatterbox` (chatterbook/build_book.sh, audiobook/scripts/render-book.sh and
# wbt all pin ~/.pyenv/versions/chatterbox/bin/python3) — and nothing in the
# kit built it: a worker provisioned to run the line could not render one
# chapter (2026-09-16, ai-3090). Now it is an opt-in component.
#
# Contract (fake HOME, stubbed pyenv/python, no network, no GPU):
#   A. flag unset: opt-in, reported off by name, no venv warning
#   B. yes, no venv: installer warns the venv is missing; install mode creates
#      it from the pyenv 3.12 and pip-installs the pinned package
#   C. yes, venv present, deps import: OK; chatterbook not importable from /
#      → warns and would `pip install -e` the checkout
#   D. yes, everything present, model cached: all OK, nothing proposed
#   E. verify.sh: yes + no venv fails by name; no → "not wanted"; unset → silent
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; grep -i 'chatter' "$TMP/out" | sed 's/^/       | /'; fi; }
H="$TMP/home"; VENV="$H/.pyenv/versions/chatterbox"
mkdir -p "$TMP/bin" "$H/.pyenv/bin" "$H/git/audiobook/chatterbook"; touch "$H/git/audiobook/chatterbook/pyproject.toml"
# pyenv stub: one 3.12 base; `virtualenv` drops a python stub into the venv
cat > "$H/.pyenv/bin/pyenv" <<'S'
#!/bin/bash
case "$1" in
  versions) echo 3.12.14 ;;
  virtualenv) mkdir -p "$HOME/.pyenv/versions/$3/bin"; cp "$STUB_PY" "$HOME/.pyenv/versions/$3/bin/python3"; ln -sf python3 "$HOME/.pyenv/versions/$3/bin/python"; echo "stub venv $3" ;;
esac
S
# python stub: imports succeed per STUB_* flags; pip calls are echoed
cat > "$TMP/py.stub" <<'S'
#!/bin/bash
args="$*"
case "$args" in
  *"-m pip "*) echo "PIP: $args"; exit 0 ;;
  *"local_files_only"*) [[ ${STUB_MODEL:-0} == 1 ]] ;;
  *"import chatterbook"*) [[ ${STUB_CB:-0} == 1 ]] ;;
  *"import chatterbox"*|*"tts_turbo"*) [[ ${STUB_DEPS:-0} == 1 ]] ;;
  *"cuda.is_available"*) exit 0 ;;
  *) exit 0 ;;
esac
S
chmod +x "$H/.pyenv/bin/pyenv" "$TMP/py.stub"
conf() { printf '%s\n' component_oom_zram=no component_docker_rootless=no component_herdr=no component_uutils_ls=no \
  component_ollama=no component_whisper=no component_mtga=no component_dictation=no component_ocr=no component_tts=no \
  component_claude_code=no component_claude_skills=no component_aws_cli=no component_lid_ignore=no "$@" > "$TMP/host.conf"; }
run07() { HOME="$H" STUB_PY="$TMP/py.stub" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/workstation/07-components.sh" "${MODE:-check}" >"$TMP/out" 2>&1; }
runv()  { ( cd "$KIT_DIR" && HOME="$H" KIT_HOST_CONF="$TMP/host.conf" KIT_VERBOSE=1 ./verify.sh ) >"$TMP/out" 2>&1; }
venv() { mkdir -p "$VENV/bin"; cp "$TMP/py.stub" "$VENV/bin/python3"; ln -sf python3 "$VENV/bin/python"; }

conf; run07
assert "A. flag unset: opt-in, off by name, no venv warning" \
  'grep -q "chatterbox: opt-in" "$TMP/out" && ! grep -q "chatterbox virtualenv missing" "$TMP/out"'

conf component_chatterbox=yes; run07
assert "B1. yes, no venv: warns by name (check mode creates nothing)" \
  'grep -q "chatterbox virtualenv missing" "$TMP/out" && [[ ! -e "$VENV" ]]'
MODE=install STUB_DEPS=0 run07
assert "B2. install: venv built from pyenv 3.12, pinned package installed into it" \
  '[[ -x "$VENV/bin/python3" ]] && grep -q "PIP: -m pip install.*chatterbox-tts==" "$TMP/out"'
rm -rf "$VENV"

venv; conf component_chatterbox=yes; STUB_DEPS=1 STUB_CB=0 STUB_MODEL=1 run07
assert "C. deps ok, chatterbook not importable from /: warns, proposes the editable install" \
  'grep -q "OK.*chatterbox venv deps" "$TMP/out" && grep -q "WARN.*chatterbook not installed" "$TMP/out" && grep -q "pip install .*-e .*audiobook/chatterbook" "$TMP/out"'

STUB_DEPS=1 STUB_CB=1 STUB_MODEL=1 run07
assert "D. everything present: all OK, nothing proposed" \
  'grep -q "OK.*chatterbook importable" "$TMP/out" && grep -q "OK.*Turbo weights cached" "$TMP/out" && ! grep -q "WARN.*chatter" "$TMP/out" && ! grep -q "pip install" "$TMP/out"'
STUB_DEPS=1 STUB_CB=1 STUB_MODEL=0 run07
assert "D2. weights not cached: warns, would download" \
  'grep -q "WARN.*Turbo weights not cached" "$TMP/out"'

echo "verifier (verify.sh)"
rm -rf "$VENV"; conf component_chatterbox=yes; runv
assert "E1. yes + no venv: fails by name" 'grep -qE "FAIL.*chatterbox venv" "$TMP/out"'
venv; STUB_DEPS=1 STUB_CB=1 runv
assert "E2. yes + venv: passes" 'grep -q "chatterbox venv: chatterbox-tts + chatterbook importable" "$TMP/out"'
conf component_chatterbox=no; runv
assert "E3. no: not wanted, no failure" 'grep -q "chatterbox venv: not wanted" "$TMP/out" && ! grep -qE "FAIL.*chatterbox" "$TMP/out"'
conf; runv
assert "E4. unset: opt-in, not wanted" 'grep -q "chatterbox venv: not wanted" "$TMP/out"'
echo "  $pass passed, $fail failed"; (( fail == 0 ))
