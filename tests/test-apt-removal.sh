#!/bin/bash
# Calibration for lib.sh apt_conflict_triggers: given packages apt's resolver
# would REMOVE, name the WANTED packages that cause it, so the installer can
# prune those instead of refusing the whole transaction.
#
# Caught in the wild (2026-09-05, fresh EFI VM): the manifest pinned grub-pc
# and systemd-timesyncd; apt wanted to remove grub-efi-amd64 and chrony to fit
# them, the guard refused, and 187 packages — pipx, pass, cmake, libssl-dev —
# never installed. Every later phase failed on their absence, three passes in
# a row.
#
# Real apt, real simulation, nothing installed. Needs a box where chrony and
# grub-efi-amd64 are installed (any EFI Ubuntu 26.04 default) — otherwise the
# defect can't be reproduced here and the test says so instead of passing.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
inst() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]; }

echo "apt removal attribution"
if ! inst chrony || ! inst grub-efi-amd64; then
  echo "  SKIP: needs chrony + grub-efi-amd64 installed to reproduce the conflict"
  exit 0
fi
source "$KIT_DIR/lib.sh"
# the VM's exact transaction shape: two conflicting pins plus innocent packages
# gimp: an innocent with a long dependency chain — when apt gives up on the
# pinned set it lists every one of gimp's deps as "not going to be
# installed", and a parser that takes every name in that block blames gimp
# (2026-09-05: 28 media packages skipped for pulseaudio's conflict)
WANT=(systemd-timesyncd grub-pc tree htop gimp)
REMV=(chrony grub-efi-amd64)
out="$(apt_conflict_triggers WANT REMV | sort | tr '\n' ' ')"
assert "names systemd-timesyncd (conflicts chrony via time-daemon)" '[[ " $out" == *" systemd-timesyncd "* ]]'
assert "names grub-pc (conflicts grub-efi-amd64)"                   '[[ " $out" == *" grub-pc "* ]]'
assert "does NOT name the innocent packages"                         '[[ "$out" != *tree* && "$out" != *htop* ]]'
assert "does NOT name gimp (deps unsatisfiable only because apt gave up)" '[[ "$out" != *gimp* ]]'
assert "exactly the two triggers"                                    '[[ "$out" == "grub-pc systemd-timesyncd " ]]'
# control: no removals → nothing to attribute, and no apt call needed
NONE=()
assert "no removals → empty" '[[ -z "$(apt_conflict_triggers WANT NONE)" ]]'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
