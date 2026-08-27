#!/bin/bash
# Calibration for the disk-space preflight (profiles/workstation/00-disk-space.sh).
#
# A space check that always says "fits" is indistinguishable from no check at
# all, and that is exactly how it would fail: silently, on the one box where it
# mattered. So before trusting a PASS, make it report the shortfall on purpose.
#
# Runs against a throwaway host conf (lib.sh lets HOST_CONF be overridden for
# exactly this) — never touches the real one, never installs anything.
#   ./tests/test-disk-space.sh
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PHASE="$KIT_DIR/profiles/workstation/00-disk-space.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CONF="$TMP/host.conf"
pass=0; fail=0
check() { # description  expected-exit  actual-exit  [grep-pattern  output-file]
  local desc="$1" want="$2" got="$3" pat="${4:-}" out="${5:-}"
  local bad=""
  [[ "$got" == "$want" ]] || bad="exit $got, wanted $want"
  [[ -z "$pat" ]] || grep -q "$pat" "$out" || bad="${bad:+$bad; }output missing /$pat/"
  if [[ -z "$bad" ]]; then ((pass++)); echo "  ok   $desc"
  else ((fail++)); echo "  FAIL $desc — $bad"; [[ -n "$out" ]] && sed 's/^/       | /' "$out"; fi
}
run() { HOST_CONF="$CONF" bash "$PHASE" "${1:-check}" >"$TMP/out" 2>&1; echo $?; }

# Minimal conf: everything optional off, so the only variable under test is the
# space arithmetic — not which components happen to be installed on this box.
base_conf() {
  cat > "$CONF" <<EOF
group_cli_system=no
group_desktop=no
group_apps=no
group_editors=no
group_network=no
group_dev_core=no
group_dev_java=no
group_dev_python=no
group_dev_cloud=no
group_dev_flutter_deps=no
lang_python=no
lang_node=no
lang_flutter=no
component_dictation=no
component_ocr=no
component_tts=no
component_claude_skills=no
EOF
  printf '%s\n' "$@" >> "$CONF"      # one key per line, never joined by $*
}

echo "disk-space preflight calibration"

# 1. off means off — no report at all
base_conf "space_check=no"
rc=$(run); check "space_check=no skips the phase" 0 "$rc" "preflight: off" "$TMP/out"

# 2. the ordinary case: a real box with real free space fits
base_conf "space_check=enforce" "disk_headroom_gb=1"
rc=$(run); check "normal box reports a per-filesystem verdict" 0 "$rc" "free" "$TMP/out"

# 3. CAN IT SEE THE DEFECT? Demand more headroom than any disk has. If this
#    does not fail, every green result above measured nothing.
base_conf "space_check=enforce" "disk_headroom_gb=100000"
rc=$(run install); check "impossible headroom stops an install (exit 3)" 3 "$rc" "SHORT BY" "$TMP/out"

# 3b. ...but the doctor still reports it and keeps going — a check that ends
#     the report early hides the rest of the drift it exists to find.
rc=$(run check); check "doctor reports the shortfall without exit 3" 1 "$rc" "an install would stop here" "$TMP/out"

# 4. ...and the policy switch actually switches: same shortfall, warn only
base_conf "space_check=warn" "disk_headroom_gb=100000"
rc=$(run); check "space_check=warn reports the shortfall but continues" 0 "$rc" "continuing anyway" "$TMP/out"

# 5. the free-space side is read from the real filesystem, not invented
base_conf "space_check=enforce" "disk_headroom_gb=0"
rc=$(run)
want_free="$(df -Pk / | awk 'NR==2{print $4}')"
got_free="$(grep -oP 'free \K[0-9.]+[KMGTP]' "$TMP/out" | head -1)"
src_free="$(cd "$KIT_DIR" && HOST_CONF="$CONF" source lib.sh >/dev/null 2>&1; kb_human "$want_free")"
[[ "$got_free" == "$src_free" ]] \
  && { ((pass++)); echo "  ok   reported free space matches df ($got_free)"; } \
  || { ((fail++)); echo "  FAIL free space '$got_free' != df '$src_free'"; }

# 6. to_kb/kb_human round-trip — the arithmetic under every verdict above
(cd "$KIT_DIR" && HOST_CONF="$CONF" source lib.sh >/dev/null 2>&1
 [[ "$(to_kb 1G)" == 1048576 && "$(to_kb 500M)" == 512000 && "$(to_kb 991kB)" == 991 \
    && "$(to_kb 1024)" == 1024 && "$(to_kb nonsense)" == 0 && "$(to_kb '')" == 0 \
    && "$(kb_human 1048576)" == 1.0G && "$(kb_human 0)" == 0K ]]) \
  && { ((pass++)); echo "  ok   to_kb/kb_human parse the units they are given"; } \
  || { ((fail++)); echo "  FAIL to_kb/kb_human unit handling"; }

echo "  $pass passed, $fail failed"
(( fail == 0 ))
