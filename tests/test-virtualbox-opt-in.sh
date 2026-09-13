#!/bin/bash
# VirtualBox is OPT-IN. It ships a dkms kernel module (vboxdrv) and rewrites
# core system state, so "bare metal" is not consent. Default: skipped
# everywhere. cond_virtualbox=yes installs it, still gated on bare-metal
# non-Proxmox because it cannot work inside a VM anyway.
#
# Both halves must agree. verify.sh re-derives conditionals on its own by
# design (a bug shared with the installer would lie twice), but until
# 2026-09-13 it never read cond_* at all — so an opt-out in the host conf made
# the installer skip a package the verifier then failed on forever.
#
# Contract:
#   A. installer, default conf, bare metal: virtualbox NOT wanted
#   B. installer, cond_virtualbox=yes, bare metal: wanted
#   C. installer, cond_virtualbox=yes, inside a VM: not wanted
#   D. verifier, default conf: no virtualbox FAIL
#   E. verifier, cond_virtualbox=yes on a box without it: virtualbox FAIL
#      (the positive control — proves D is not vacuous; skipped if this box
#      has virtualbox installed)
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }

# stub the virt probe so the test means the same thing on a VM or on metal
mkdir -p "$TMP/bin"
virt() { printf '#!/bin/sh\necho %s\n' "$1" > "$TMP/bin/systemd-detect-virt"; chmod +x "$TMP/bin/systemd-detect-virt"; }
want() { PATH="$TMP/bin:$PATH" HOST_CONF="$TMP/host.conf" bash -c "source '$KIT_DIR/lib.sh'; apt_want_into W; printf '%s\n' \"\${W[@]}\"" 2>/dev/null | sort | tr "\n" " " | sed "s/^/ /"; }
conf() { printf '%s\n' "$1" > "$TMP/host.conf"; }

echo "installer (lib.sh apt_want_into)"
virt none
conf ''
assert "A: default on bare metal — virtualbox not wanted"      '[[ "$(want)" != *" virtualbox "* ]]'
conf 'cond_virtualbox=yes'
assert "B: cond_virtualbox=yes on bare metal — wanted"         '[[ "$(want)" == *" virtualbox "* ]]'
virt kvm
assert "C: cond_virtualbox=yes inside a VM — still not wanted" '[[ "$(want)" != *" virtualbox "* ]]'

echo "verifier (verify.sh)"
virt none
verify() { ( cd "$KIT_DIR" && PATH="$TMP/bin:$PATH" KIT_HOST_CONF="$TMP/host.conf" ./verify.sh 2>&1 ); }
conf ''
# capture, THEN grep: `verify | grep -q` closes the pipe on first match, verify
# dies of SIGPIPE, and pipefail hands that 141 to the assertion — both D and E
# would then measure the pipe, not the report.
v="$(verify)"
assert "D: default conf — verify does not fail on virtualbox"  '[[ "$v" != *"apt: virtualbox"* ]]'
if dpkg-query -W -f='${Status}' virtualbox 2>/dev/null | grep -q "install ok installed"; then
  echo "  skip E: virtualbox is installed here, positive control unavailable"
else
  conf 'cond_virtualbox=yes'
  v="$(verify)"
  assert "E: cond_virtualbox=yes, not installed — verify FAILS on it" '[[ "$v" == *"apt: virtualbox"* ]]'
fi
echo "  $pass passed, $fail failed"
(( fail == 0 ))
