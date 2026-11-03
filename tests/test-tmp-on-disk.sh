#!/bin/bash
source "$(dirname "$0")/memory-fixture.sh"
conf tmp_on_disk=yes; run07
assert 'tmpfs: live type, reboot boundary and proposed mask are reported' 'grep -q "tmp: live.*tmpfs" "$TMP/out" && grep -q "next reboot" "$TMP/out" && grep -q "\[would\].*mask tmp.mount" "$TMP/out"'
assert 'doctor cannot mutate the machine' '[[ ! -L "$ROOT/etc/systemd/system/tmp.mount" ]] && ! grep -q "^sudo " "$CALLS"'
run07 install
assert 'install masks only future tmpfs and supplies aged cleanup' '[[ -L "$ROOT/etc/systemd/system/tmp.mount" ]] && grep -qx "q /tmp 1777 root root 10d" "$ROOT/etc/tmpfiles.d/tmp.conf" && ! grep -qE "(umount|stop tmp.mount|tmpfiles.*--clean)" "$CALLS"'
run07 install
assert 'second install is quiet about config and mask' '! grep -qE "sudo (tee|systemctl mask)" "$CALLS"'
rm -f "$ROOT/etc/systemd/system/tmp.mount"
printf 'UUID=disk /tmp ext4 relatime,nosuid,nodev 0 2\n' > "$ROOT/etc/fstab"
run07 install
assert 'existing fstab disk mount wins and is never masked or rewritten' '[[ ! -e "$ROOT/etc/systemd/system/tmp.mount" ]] && grep -qx "UUID=disk /tmp ext4 relatime,nosuid,nodev 0 2" "$ROOT/etc/fstab" && grep -q "fstab.*preserv" "$TMP/out"'
printf 'tmpfs /tmp tmpfs defaults 0 0\n' > "$ROOT/etc/fstab"; run07 install
assert 'explicit tmpfs entry requires a human, never a conflicting mask' 'grep -q "WARN.*fstab.*tmpfs" "$TMP/out" && [[ ! -e "$ROOT/etc/systemd/system/tmp.mount" ]]'
conf tmp_on_disk=no; run07
assert 'opt-out leaves policy alone' '! grep -q "tmp: live" "$TMP/out"'
conf tmp_on_disk=yes; : > "$ROOT/etc/fstab"; runv
assert 'independent verifier rejects live tmpfs' 'grep -q "FAIL.*tmp:.*tmpfs" "$TMP/out"'
echo ext4 > "$STATE/fstype"; runv
assert 'independent verifier accepts disk /tmp' 'grep -q "PASS.*tmp:.*ext4" "$TMP/out"'
conf tmp_on_disk=yes tmp_age_rule=yes; run07 check
assert 'age opt-in check reports content drift without sudo' 'grep -q "tmp: age rule.*drift" "$TMP/out" && ! grep -q "^sudo " "$CALLS"'
run07 install
assert 'age opt-in writes exact D mM rule at 644' '[[ "$(cat "$ROOT/etc/tmpfiles.d/tmp.conf")" == "D /tmp 1777 root root mM:10d" && "$(stat -c %a "$ROOT/etc/tmpfiles.d/tmp.conf")" == 644 ]]'
run07 install
assert 'age second install does not rewrite or clean' '! grep -qE "sudo (tee|install|mv)|tmpfiles.*--clean" "$CALLS"'
chmod 600 "$ROOT/etc/tmpfiles.d/tmp.conf"; run07 check
assert 'age check sees mode drift' 'grep -q "WARN.*tmp: age rule" "$TMP/out"'
run07 install
assert 'age install heals mode drift' '[[ "$(stat -c %a "$ROOT/etc/tmpfiles.d/tmp.conf")" == 644 ]]'
printf 'D /tmp 1777 root root mM:10d\n\n' > "$ROOT/etc/tmpfiles.d/tmp.conf"; run07 check
assert 'age rule rejects an extra blank line' 'grep -q "WARN.*tmp: age rule" "$TMP/out"'
run07 install
assert 'age rule repair is byte exact' 'python3 -c '\''import sys; assert open(sys.argv[1],"rb").read()==b"D /tmp 1777 root root mM:10d\n"'\'' "$ROOT/etc/tmpfiles.d/tmp.conf"'
finish
