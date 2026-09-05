#!/bin/bash
# Calibration for lib.sh conf_get: a quoted value in the host conf must come
# back WITHOUT its quotes. Caught in the wild (2026-09-05, fresh VM):
# claude_skills="gstack vault conduct" was split into '"gstack' and 'conduct"',
# two skills that exist nowhere — and the "missing" paths made phase 08 pull
# .configs over ssh every pass, which sat on a YubiKey PIN prompt for a minute
# each time. The class: every host-conf value someone wrote with quotes.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/host.conf" <<'CONF'
claude_skills="gstack vault conduct"  # which skills phase 08 installs
single='one'
bare=plain value   # trailing comment
empty=
CONF
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
get() { HOST_CONF="$TMP/host.conf" bash -c "source '$KIT_DIR/lib.sh'; conf_get $1 '${2:-}'"; }

echo "conf_get quoting"
assert 'double-quoted list loses its quotes'  '[[ "$(get claude_skills)" == "gstack vault conduct" ]]'
assert 'single-quoted value loses its quotes' '[[ "$(get single)" == "one" ]]'
assert 'bare value with comment unchanged'    '[[ "$(get bare)" == "plain value" ]]'
assert 'empty value falls back to default'    '[[ "$(get empty dflt)" == "dflt" ]]'
assert 'missing key falls back to default'    '[[ "$(get nope dflt)" == "dflt" ]]'
# the real template must survive the same reader — that is the file the VM used
assert 'example.conf claude_skills reads clean' \
  '[[ "$(HOST_CONF="$KIT_DIR/hosts/example.conf" bash -c "source \"$KIT_DIR/lib.sh\"; conf_get claude_skills")" == "gstack vault conduct" ]]'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
