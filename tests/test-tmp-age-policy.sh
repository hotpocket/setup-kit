#!/bin/bash
# Host-conf owns the selected age. Installer and independent doctor read the
# same default data, while existing machines keep the current policy.
# shellcheck disable=SC2034 # assert evaluates expression strings at runtime
source "$(dirname "$0")/memory-fixture.sh"
conf tmp_on_disk=yes tmp_age_rule=yes; echo ext4 > "$STATE/fstype"
run07 install
assert 'unset tmp_age preserves the current exact rule' '[[ "$(cat "$ROOT/etc/tmpfiles.d/tmp.conf")" == "D /tmp 1777 root root mM:10d" ]]'
conf tmp_on_disk=yes tmp_age_rule=yes tmp_age=bcmBM:10d; run07 check
assert 'configured age drift is reported without writing' 'grep -q "WARN.*tmp: age rule" "$TMP/out" && ! grep -q "^sudo " "$CALLS" && grep -qx "D /tmp 1777 root root mM:10d" "$ROOT/etc/tmpfiles.d/tmp.conf"'
run07 install
assert 'configured proposed rule is written exactly without cleanup' '[[ "$(cat "$ROOT/etc/tmpfiles.d/tmp.conf")" == "D /tmp 1777 root root bcmBM:10d" && "$(stat -c %a "$ROOT/etc/tmpfiles.d/tmp.conf")" == 644 ]] && ! grep -q "tmpfiles.*--clean" "$CALLS"'
# Populate the expected operator-owned result independently of the installer.
printf 'D /tmp 1777 root root bcmBM:10d\n' > "$ROOT/etc/tmpfiles.d/tmp.conf"
runv
assert 'independent verifier accepts the configured proposed rule' 'grep -q "PASS.*tmp: aged cleanup configured" "$TMP/out"'
printf 'D /tmp 1777 root root mM:10d\n' > "$ROOT/etc/tmpfiles.d/tmp.conf"; runv
assert 'independent verifier refuses the old rule when a proposed age is selected' 'grep -q "FAIL.*tmp: aged cleanup" "$TMP/out"'
conf tmp_on_disk=yes tmp_age_rule=yes 'tmp_age="bcmBM:10d"'; run07 install; runv
assert 'quoted host age selects the same rule in both callers' 'grep -qx "D /tmp 1777 root root bcmBM:10d" "$ROOT/etc/tmpfiles.d/tmp.conf" && grep -q "PASS.*tmp: aged cleanup configured" "$TMP/out"'
conf tmp_on_disk=yes tmp_age_rule=yes tmp_age=bcBM:12h; run07 install; runv
assert 'the complete age field is data rather than a policy switch' 'grep -qx "D /tmp 1777 root root bcBM:12h" "$ROOT/etc/tmpfiles.d/tmp.conf" && grep -q "PASS.*tmp: aged cleanup configured" "$TMP/out"'
# Changing the default data alone must affect both readers. This fixture is
# a separate archive and never modifies the checked-out manifest.
K="$TMP/kit"; mkdir -p "$K"
cp -a "$KIT_DIR"/{lib.sh,profiles,components,manifests,verify.sh} "$K/"
printf 'TMP_AGE_DEFAULT=bcmBM:10d\n' > "$K/manifests/tmpfiles.conf"
conf tmp_on_disk=yes tmp_age_rule=yes
bash "$K/profiles/workstation/07-components.sh" install > "$TMP/out" 2>&1
assert 'installer derives an unset age from the single default data file' 'grep -qx "D /tmp 1777 root root bcmBM:10d" "$ROOT/etc/tmpfiles.d/tmp.conf"'
printf 'D /tmp 1777 root root bcmBM:10d\n' > "$ROOT/etc/tmpfiles.d/tmp.conf"
bash "$K/verify.sh" > "$TMP/out" 2>&1
assert 'independent verifier derives an unset age from that same data file' 'grep -q "PASS.*tmp: aged cleanup configured" "$TMP/out"'
conf tmp_on_disk=yes tmp_age_rule=yes
run07 install; runv
assert 'removing the override restores current default agreement' 'grep -qx "D /tmp 1777 root root mM:10d" "$ROOT/etc/tmpfiles.d/tmp.conf" && grep -q "PASS.*tmp: aged cleanup configured" "$TMP/out"'
finish
