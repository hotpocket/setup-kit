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
finish
