#!/bin/bash
# wine_branch in the host conf picks WineHQ's stable / devel / staging branch:
# the manifest names the stable packages, the branch swaps them. A branch swap
# installs winehq-<new> which CONFLICTS with winehq-<old>; the installer must
# treat that as the deliberate removal it is, not as a refused transaction.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
want() { HOST_CONF="$TMP/host.conf" bash -c "source '$KIT_DIR/lib.sh'; apt_want_into W; printf '%s\n' \"\${W[@]}\"" | sort | tr "\n" " " | sed "s/^/ /"; }
conf() { printf 'group_wine=yes\n%s\n' "$1" > "$TMP/host.conf"; }
echo "wine branch selection"
conf ''
w="$(want)"
assert "default: stable packages, untouched"   '[[ "$w" == *" winehq-stable "* && "$w" == *" wine-stable "* ]]'
conf 'wine_branch=devel'
w="$(want)"
assert "devel: winehq-devel + wine-devel wanted" '[[ "$w" == *" winehq-devel "* && "$w" == *" wine-devel "* ]]'
assert "devel: no stable packages wanted"       '[[ "$w" != *stable* ]]'
assert "devel: winetricks kept"                 '[[ "$w" == *" winetricks "* ]]'
conf 'wine_branch=staging'
assert "staging works the same way"             '[[ "$(want)" == *" winehq-staging "* ]]'
conf 'wine_branch=nonsense'
w="$(want 2>/dev/null)"
assert "unknown branch falls back to stable"    '[[ "$w" == *" winehq-stable "* ]]'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
