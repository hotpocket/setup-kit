#!/bin/bash
# The exit-3 contract: a phase can declare the run unsafe to continue, and
# bootstrap.sh must stop THERE — not log a failure and keep provisioning into
# a disk it was just told won't hold the install.
#
# Exercised against stub phases (KIT_PHASE_DIR), because the real ones install
# things: the point is the loop's behaviour, and a test that has to run a real
# provision to check it would never be run.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/phases"
cat > "$TMP/phases/00-first.sh"  <<'EOF'
#!/bin/bash
echo "FIRST RAN"
EOF
cat > "$TMP/phases/01-stop.sh"   <<'EOF'
#!/bin/bash
echo "STOPPER RAN"
exit 3
EOF
cat > "$TMP/phases/02-after.sh"  <<'EOF'
#!/bin/bash
echo "AFTER RAN"
EOF
chmod +x "$TMP/phases/"*.sh
cat > "$TMP/host.conf" <<'EOF'
groups_selected=yes
EOF

pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }

echo "bootstrap exit-3 abort"
# check mode: no sudo, no preamble, just the phase loop
KIT_PHASE_DIR="$TMP/phases" HOST_CONF="$TMP/host.conf" \
  bash "$KIT_DIR/bootstrap.sh" workstation check >"$TMP/out" 2>&1
rc=$?
assert "phases before the stopper ran"      'grep -q "FIRST RAN"   "$TMP/out"'
assert "the stopping phase ran"             'grep -q "STOPPER RAN" "$TMP/out"'
assert "phases AFTER the stopper did NOT run" '! grep -q "AFTER RAN" "$TMP/out"'
assert "the abort is announced by name"     'grep -q "ABORTED by 01-stop.sh" "$TMP/out"'
assert "bootstrap exits non-zero"           '[[ "$rc" -ne 0 ]]'

# and the control: without a stopper, every phase runs
rm "$TMP/phases/01-stop.sh"
KIT_PHASE_DIR="$TMP/phases" HOST_CONF="$TMP/host.conf" \
  bash "$KIT_DIR/bootstrap.sh" workstation check >"$TMP/out2" 2>&1
assert "control: with no exit 3, later phases DO run" 'grep -q "AFTER RAN" "$TMP/out2"'

echo "  $pass passed, $fail failed"
(( fail == 0 ))
