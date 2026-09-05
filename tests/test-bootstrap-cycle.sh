#!/bin/bash
# The pass loop must not re-run a pass that will do exactly what the last one
# did. bootstrap.sh loops "until a pass changes nothing" — but a phase whose
# action never sticks (an install whose "is it done?" check can't see the
# result) reports the same action every pass, and the loop just repeats it,
# three times, each with its own timeouts (2026-09-05: deno reinstalled, two
# GNOME extensions reinstalled, pass init retried, a YubiKey prompt waited out
# — per pass, identical, ~4 minutes each for zero change).
#
# Stub phases (KIT_PHASE_DIR), install mode, a stub `sudo` on PATH (bootstrap
# validates sudo upfront; the stub phases never call it), verify skipped.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/phases"
# emits one action every pass; a marker file counts how many times it ran
cat > "$TMP/phases/01-groundhog.sh" <<EOF2
#!/bin/bash
echo "\$(date +%s)" >> "$TMP/runs"
echo "  + reinstall-the-same-thing /tmp/tmp.\$RANDOM.zip ✓ 1s"
echo "  [WARN]  thing missing"
EOF2
mkdir -p "$TMP/bin"; printf '#!/bin/bash\nexit 0\n' > "$TMP/bin/sudo"
chmod +x "$TMP/phases/"*.sh "$TMP/bin/sudo"
cat > "$TMP/host.conf" <<'EOF2'
groups_selected=yes
size_review_done=yes
EOF2
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
echo "bootstrap pass-loop cycling"
PATH="$TMP/bin:$PATH" KIT_PHASE_DIR="$TMP/phases" HOST_CONF="$TMP/host.conf" KIT_SKIP_VERIFY=1 \
  bash "$KIT_DIR/bootstrap.sh" workstation install </dev/null >"$TMP/out" 2>&1
n=$(wc -l < "$TMP/runs")
assert "a second pass runs (the first pass DID act)"      '(( n >= 2 ))'
assert "a THIRD identical pass does not"                   '(( n == 2 ))'
assert "each phase ends with a one-line tally"              'grep -qE "01-groundhog.*[0-9]+ warn" "$TMP/out"'
assert "the loop says why it stopped"                      'grep -qi "same actions" "$TMP/out"'
assert "still reported as not converged (needs a human)"   'grep -q "NOT converged" "$TMP/out"'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
