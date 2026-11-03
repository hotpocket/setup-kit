#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
cat > "$TMP/bin/python3" <<'SH2'
#!/bin/bash
if [[ "$*" == *components/emudhra-check* ]]; then
 echo "admission $*" >> "$CALLS"
 [[ "${*: -1}" == --check ]] || exit 9
 [[ ! -f "$STATE/admission-fail" ]]
 exit $?
fi
exec /usr/bin/python3 "$@"
SH2
chmod +x "$TMP/bin/python3"
conf_tools component_emudhra=yes
run_tools check
assert 'phase 07 doctor invokes only checker --check' 'grep -q "^admission .*components/emudhra-check --check$" "$CALLS"'
run_tools install
assert 'phase 07 install still invokes only checker --check' 'grep -q "^admission .*components/emudhra-check --check$" "$CALLS" && [[ -z "$(mutations)" ]]'
runv
assert 'independent verification invokes only checker --check' 'grep -q "^admission .*components/emudhra-check --check$" "$CALLS"'
touch "$STATE/admission-fail"; runv
assert 'independent verification rejects failed admission' 'grep -q "FAIL.*eMudhra admission" "$TMP/out"'
finish
