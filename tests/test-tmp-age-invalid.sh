#!/bin/bash
# shellcheck disable=SC2034 # assert evaluates runtime expressions
source "$(dirname "$0")/memory-fixture.sh"
echo ext4 > "$STATE/fstype"
mkdir -p "$ROOT/etc/tmpfiles.d"
printf 'D /tmp 1777 root root mM:10d\n' > "$ROOT/etc/tmpfiles.d/tmp.conf"
chmod 644 "$ROOT/etc/tmpfiles.d/tmp.conf"
for age in invalid-age z:10d mM:bad mM:10garbage mM: mM:1d:2h 'mM:10d injected' $'mM:10d\nD /other 0777 root root 0' 99999999999999999999999999999d; do
  conf tmp_on_disk=yes tmp_age_rule=yes "tmp_age=\"$age\""
  cp -p "$ROOT/etc/tmpfiles.d/tmp.conf" "$TMP/previous"
  run07 install; rc=$?
  assert "invalid age rejected before replacing the rule: ${age//$'\n'/ newline }" '[[ $rc != 0 ]] && cmp -s "$TMP/previous" "$ROOT/etc/tmpfiles.d/tmp.conf" && ! grep -q "^sudo " "$CALLS"'
  printf 'D /tmp 1777 root root %s\n' "$age" > "$ROOT/etc/tmpfiles.d/tmp.conf"
  touch "$STATE/active-systemd-tmpfiles-clean.timer"
  runv
  assert "byte-matching invalid age fails independent verification: ${age//$'\n'/ newline }" 'grep -q "FAIL.*tmp: aged cleanup" "$TMP/out"'
  cp -p "$TMP/previous" "$ROOT/etc/tmpfiles.d/tmp.conf"
done
for age in mM:10d bcmBM:10d bcBM:12h abcmABCM:1d12h 10d mM:0 '~mM:1h30min' mM:1.5h; do
  conf tmp_on_disk=yes tmp_age_rule=yes "tmp_age=$age"
  run07 install; rc=$?; runv
  assert "valid systemd age is accepted: $age" '[[ $rc == 0 ]] && grep -qx "D /tmp 1777 root root $age" "$ROOT/etc/tmpfiles.d/tmp.conf" && grep -q "PASS.*tmp: aged cleanup" "$TMP/out"'
done
finish
