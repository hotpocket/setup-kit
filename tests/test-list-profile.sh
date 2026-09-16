#!/bin/bash
# Calibration for `bootstrap.sh list` being profile-aware. The catalog used to
# be built from the workstation template alone, so on a worker it omitted
# group_worker (the one group that box turns on) and told the reader to run
# `workstation install` — the reader concluded the group was not flagged.
#
# Contract:
#   A. host conf says profile=worker: group_worker row appears with its value
#      and a description; footer names `worker install`
#   B. worker rows with no inline comment borrow the workstation description
#      (group_cli_system is uncommented in worker.example.conf)
#   C. no profile= key: workstation template, footer names `workstation install`
#      (the positive control — proves A is the profile's doing, not a default)
#   D. no host conf at all: still prints the template defaults, no crash
#   E. unknown profile: refuses by name instead of silently showing another
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out"; fi; }
run() { HOST_CONF="$1" "$KIT_DIR/bootstrap.sh" list > "$TMP/out" 2>&1; echo $? > "$TMP/rc"; }

printf 'profile=worker\ngroup_worker=yes\n' > "$TMP/worker.conf"
run "$TMP/worker.conf"
assert "A. worker: group_worker row present and on" \
  'grep -qE "^\s+\[yes\]\s+group_worker\s+\S" "$TMP/out"'
assert "A. worker: footer names worker install" \
  'grep -q "bootstrap.sh worker install" "$TMP/out" && ! grep -q "workstation install" "$TMP/out"'
assert "B. uncommented worker row borrows the workstation description" \
  'grep -qE "group_cli_system\s+base OS glue" "$TMP/out"'

printf 'group_media=yes\n' > "$TMP/ws.conf"
run "$TMP/ws.conf"
assert "C. no profile key: workstation, no group_worker row" \
  '! grep -q group_worker "$TMP/out" && grep -q "bootstrap.sh workstation install" "$TMP/out"'

run "$TMP/absent.conf"
assert "D. no host conf: template defaults, exit 0" \
  '[[ $(cat "$TMP/rc") -eq 0 ]] && grep -q "none yet" "$TMP/out" && grep -q group_cli_system "$TMP/out"'

printf 'profile=toaster\n' > "$TMP/bad.conf"
run "$TMP/bad.conf"
assert "E. unknown profile refused by name" \
  '[[ $(cat "$TMP/rc") -ne 0 ]] && grep -q "toaster" "$TMP/out"'

echo; echo "list-profile: $pass passed, $fail failed"; [[ $fail -eq 0 ]]
