#!/bin/bash
# Calibration: the daily-use desktop apps among the direct debs (zoom, discord,
# master-pdf-editor, ganttproject) ride group_apps, so a server/control box
# (group_apps=no) gets none of them, while VS Code (a programming tool) stays.
#
# Contract (real manifest, fake HOME, no installs — check mode):
#   A. group_apps=no: 02b reports each daily-use deb gated off; code is not gated
#   B. group_apps=yes: none of them is gated (the owner's workstations, unchanged)
#   C. verify.sh, group_apps=no: no deb failure for any of them
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
DAILY="zoom discord master-pdf-editor-5 ganttproject"
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; grep -E "$(echo $DAILY code | tr ' ' '|')" "$TMP/out" | sed 's/^/       | /'; fi; }
mkdir -p "$TMP/home"
run02b() { printf '%s\n' "$@" > "$TMP/host.conf"; HOME="$TMP/home" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/workstation/02b-debs.sh" check >"$TMP/out" 2>&1; }
gated_all() { local n; for n in $DAILY; do grep -q "$n: gated off (group_apps)" "$TMP/out" || return 1; done; }
gated_none() { local n; for n in $DAILY; do grep -q "$n: gated off" "$TMP/out" && return 1; done; return 0; }

run02b group_apps=no
assert "A. group_apps=no: daily-use debs gated off, code not" 'gated_all && ! grep -q "code: gated off" "$TMP/out"'
run02b group_apps=yes
assert "B. group_apps=yes: none gated" 'gated_none'
printf 'group_apps=no\n' > "$TMP/host.conf"
# dpkg reports nothing installed, so a deb the verifier still wants shows as a failure
mkdir -p "$TMP/bin"; printf '#!/bin/sh\nexit 1\n' > "$TMP/bin/dpkg"; chmod +x "$TMP/bin/dpkg"
( cd "$KIT_DIR" && PATH="$TMP/bin:$PATH" HOME="$TMP/home" KIT_HOST_CONF="$TMP/host.conf" KIT_VERBOSE=1 ./verify.sh ) >"$TMP/out" 2>&1
assert "C. verify, group_apps=no: no failure for a daily-use deb" '! grep -qE "FAIL.*deb: (zoom|discord)" "$TMP/out"'

echo "test-debs-gate: $pass passed, $fail failed"
(( fail == 0 ))
