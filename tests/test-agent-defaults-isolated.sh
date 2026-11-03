#!/bin/bash
# The default comparison must work in a real clone with no sibling .configs
# and no ambient golden recordings. A mutation proves it still sees drift.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
/usr/bin/git clone -q --no-hardlinks "$KIT_DIR" "$TMP/kit"
cp -a "$KIT_DIR"/{lib.sh,profiles,components,manifests,tests} "$TMP/kit/"
rm -rf "$TMP/kit/tests/fixtures/agent-default-calls"
pass=0; fail=0
bash "$TMP/kit/tests/test-agent-defaults.sh" > "$TMP/out" 2>&1; rc=$?
if [[ $rc == 0 ]]; then echo '  ok   isolated defaults pin their own historical baseline'; ((pass++))
else echo '  FAIL isolated defaults pin their own historical baseline'; tail -4 "$TMP/out"; ((fail++)); fi
sed -i 's/for df in .bashrc .bash_aliases .gitconfig/for df in .bashrc .bash_aliases/' "$TMP/kit/profiles/workstation/06-configs.sh"
bash "$TMP/kit/tests/test-agent-defaults.sh" > "$TMP/out" 2>&1; rc=$?
if [[ $rc != 0 ]] && grep -q 'changed from' "$TMP/out"; then echo '  ok   default comparison detects a removed legacy link'; ((pass++))
else echo '  FAIL default comparison failed to detect a removed legacy link'; ((fail++)); fi
echo "test-agent-defaults-isolated: $pass passed, $fail failed"
(( fail == 0 ))
