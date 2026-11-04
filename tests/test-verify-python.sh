#!/bin/bash
# The independent verifier grades only requested pyenv toolchains, while system
# python3 remains mandatory. Run the full real verifier in a minimal healthy
# headless fixture, stubbing host health commands and refusing sudo/network work.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
K="$TMP/kit"; H="$TMP/home"; BIN="$TMP/bin"; CONF="$TMP/host.conf"
mkdir -p "$K" "$H" "$BIN"
cp "$KIT_DIR/verify.sh" "$K/verify.sh"
cp -a "$KIT_DIR/manifests" "$K/manifests"
# A closed PATH makes absence of python3 observable even on a Python-equipped
# dev VM. Shell commands used by the verifier are real traditional tools.
for tool in awk basename date dirname grep head mkdir sed sort tail wc; do
  ln -s "$(command -v "$tool")" "$BIN/$tool"
done
ln -s "$(command -v python3)" "$BIN/python3"
for tool in lspci systemctl journalctl coredumpctl dpkg gh; do
  printf '#!/bin/bash\nexit 0\n' > "$BIN/$tool"
  chmod +x "$BIN/$tool"
done
printf '#!/bin/bash\nexit 1\n' > "$BIN/sudo"
printf '#!/bin/bash\necho fixture-python\n' > "$BIN/hostname"
chmod +x "$BIN/sudo" "$BIN/hostname"
conf() {
  printf '%s\n' profile=worker headless=yes configs=no cond_nvidia=no \
    lang_node=no lang_flutter=no component_oom_zram=no \
    component_resource_guards=no component_clipboard=no tmp_on_disk=no \
    "$@" > "$CONF"
}
run() {
  env HOME="$H" PATH="$BIN" KIT_HOST_CONF="$CONF" KIT_VERBOSE=1 \
    /bin/bash "$K/verify.sh" > "$TMP/out" 2>&1
  # Used in the assertion expressions evaluated below.
  # shellcheck disable=SC2034
  RC=$?
}
pass=0; fail=0
assert() {
  [[ -z "${VERIFY_ASSERT_ONLY:-}" || "$1" == "$VERIFY_ASSERT_ONLY."* ]] || return 0
  if eval "$2"; then ((pass++)); echo "  ok   $1"
  else ((fail++)); echo "  FAIL $1"; cat "$TMP/out"; fi
  if [[ -n "${VERIFY_ASSERT_ONLY:-}" ]]; then (( fail == 0 )); exit $?; fi
}
conf lang_python=no; run
assert 'V1. lang_python=no: full verification passes without pyenv' \
  '(( RC == 0 )) && grep -q "^PASS  python: system python3 present" "$TMP/out" && ! grep -q "^FAIL" "$TMP/out" && [[ ! -e "$H/.pyenv" ]]'
conf lang_python=yes; run
assert 'V2. lang_python=yes: missing pyenv still fails verification' \
  '(( RC != 0 )) && grep -qx "FAIL  python: pyenv missing" "$TMP/out" && [[ "$(grep -c "^FAIL" "$TMP/out")" == 1 ]]'
conf; run
assert 'V3. unspecified lang_python retains the pyenv requirement' \
  '(( RC != 0 )) && grep -qx "FAIL  python: pyenv missing" "$TMP/out" && [[ "$(grep -c "^FAIL" "$TMP/out")" == 1 ]]'
# Remove only this fixture link, proving the opt-out cannot hide absent system Python.
mv "$BIN/python3" "$TMP/python3-link"
conf lang_python=no; run
assert 'V4. lang_python=no still fails without system python3' \
  '(( RC != 0 )) && grep -qx "FAIL  python: no system python3" "$TMP/out" && [[ "$(grep -c "^FAIL" "$TMP/out")" == 1 ]] && ! grep -q "pyenv missing" "$TMP/out"'
echo "verify-python: $pass passed, $fail failed"
(( fail == 0 ))
