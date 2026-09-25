#!/bin/bash
# A host conf may be a symlink to the machine's record kept elsewhere (a private repo: this one is
# public, so real answer files stay out of it). conf_set used a bare `sed -i`, which replaces the
# link with a plain file: the answer lands in a stray copy and the record silently stops changing
# (2026-09-25). Contract:
#   A. changing an existing answer through a symlinked conf keeps the link
#   B. ...and the change reaches the file it points to
#   C. a new answer (append path) also reaches the target
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
printf 'profile=worker\ngit_push=deny\n' > "$TMP/record.conf"
ln -s record.conf "$TMP/host.conf"
HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" bash -c 'source "$1/lib.sh"; conf_set git_push allow; conf_set boot_target graphical' _ "$KIT_DIR" >/dev/null 2>&1
assert "A. the conf is still a symlink" '[ -L "$TMP/host.conf" ]'
assert "B. the changed answer is in the target" 'grep -qx "git_push=allow" "$TMP/record.conf"'
assert "C. the new answer is in the target" 'grep -qx "boot_target=graphical" "$TMP/record.conf"'
echo "$pass passed, $fail failed"; [ "$fail" -eq 0 ]
