#!/bin/bash
# Calibration for the lid-ignore component (profiles/workstation/07-components.sh
# + verify.sh). A laptop that serves as a node — lid shut, reached over ssh —
# must not suspend when the lid closes. That is a ROLE choice, not a hardware
# fact, so it is opt-in per host (component_lid_ignore=yes), and the phase
# refuses to act on anything that is not a laptop.
#
# Contract (installer, check mode — never touches /etc):
#   A. flag unset: component reports disabled, no drop-in warning
#   B. yes, laptop, drop-in absent: doctor WARNS it is missing
#      (the positive control — proves C is not vacuous)
#   C. yes, laptop, drop-in present with the wanted content: OK
#   D. yes, laptop, drop-in present but drifted: doctor warns drifted
#   E. yes, but chassis is not a laptop: refuses (warn), no drop-in talk
# Contract (verifier — asks logind over D-Bus, never the file):
#   F. flag unset: no lid FAIL
#   G. yes, logind says "suspend": FAIL
#   H. yes, logind says "ignore" on all three: pass
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="$KIT_DIR/profiles/workstation/07-components.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CONF="$TMP/host.conf"; DROPIN="$TMP/etc/logind.conf.d/10-lid-ignore.conf"
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out"; fi; }

# Stubs: chassis and logind answers are the test's inputs, not this box's.
mkdir -p "$TMP/bin"
chassis() { printf '#!/bin/sh\n[ "$1" = chassis ] && { echo %s; exit 0; }\nexec /usr/bin/hostnamectl "$@"\n' "$1" > "$TMP/bin/hostnamectl"; chmod +x "$TMP/bin/hostnamectl"; }
logind()  { printf '#!/bin/sh\nfor p; do :; done\ncase "$*" in *HandleLidSwitch*) for _ in 1 2 3; do echo "s \\"%s\\""; done ;; *) exec /usr/bin/busctl "$@" ;; esac\n' "$1" > "$TMP/bin/busctl"; chmod +x "$TMP/bin/busctl"; }
# Every other component off, so the only thing under test is lid-ignore.
conf() {
  cat > "$CONF" <<EOC
component_oom_zram=no
component_uutils_ls=no
component_herdr=no
component_ollama=no
component_whisper=no
component_dictation=no
component_ocr=no
component_docker_rootless=no
component_claude_code=no
component_claude_skills=no
component_aws_cli=no
EOC
  printf '%s\n' "$@" >> "$CONF"
}
run() { PATH="$TMP/bin:$PATH" HOST_CONF="$CONF" KIT_LID_DROPIN="$DROPIN" bash "$PHASE" check >"$TMP/out" 2>&1; }
WANT=$'[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\nHandleLidSwitchDocked=ignore'

echo "installer (07-components.sh, check mode)"
chassis laptop
conf; run
assert "A: flag unset — reports disabled, no missing-drop-in warning" \
  'grep -q "lid-ignore: disabled" "$TMP/out" && ! grep -q "lid-ignore:.*missing" "$TMP/out"'
conf component_lid_ignore=yes; run
assert "B: yes, laptop, no drop-in — doctor warns missing"  'grep -q "lid-ignore:.*missing" "$TMP/out"'
mkdir -p "$(dirname "$DROPIN")"; printf '%s\n' "$WANT" > "$DROPIN"; run
assert "C: yes, laptop, drop-in matches — OK"                 'grep -q "OK.*lid-ignore:.*in place" "$TMP/out"'
printf '[Login]\nHandleLidSwitch=suspend\n' > "$DROPIN"; run
assert "D: yes, laptop, drop-in drifted — doctor warns drifted" 'grep -q "lid-ignore:.*drifted" "$TMP/out"'
rm -f "$DROPIN"; chassis desktop; run
assert "E: yes, not a laptop — refuses, no drop-in talk" \
  'grep -q "lid-ignore:.*not a laptop" "$TMP/out" && ! grep -qE "lid-ignore:.*(missing|in place)" "$TMP/out"'

echo "verifier (verify.sh)"
verify() { ( cd "$KIT_DIR" && PATH="$TMP/bin:$PATH" KIT_HOST_CONF="$CONF" ./verify.sh 2>&1 ); }
logind suspend
conf; v="$(verify)"
assert "F: flag unset — verify does not fail on lid"          '[[ "$v" != *"lid:"* ]]'
conf component_lid_ignore=yes; v="$(verify)"
assert "G: yes, logind would suspend — verify FAILS"          '[[ "$v" == *"lid:"*suspend* ]]'
logind ignore; v="$(verify)"
assert "H: yes, logind ignores all three — verify passes"     '[[ "$v" != *"FAIL"*"lid:"* ]]'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
