#!/bin/bash
source "$(dirname "$0")/memory-fixture.sh"
conf component_oom_zram=yes; run07
assert '8 GiB: doctor sizes zram at half RAM and disk at least RAM' 'grep -q "4096 MB.*zstd" "$TMP/out" && grep -q "disk overflow.*8192 MiB" "$TMP/out"'
run07 install
assert 'empty machine: sized file, whole fstab and low priority' '[[ $(stat -c %s "$ROOT/swap.img") == 8589938688 ]] && grep -qx "/swap.img none swap sw,pri=-2 0 0" "$ROOT/etc/fstab" && grep -q "swapon --priority -2" "$CALLS"'
run07 install
assert 'repeat install does not allocate, format or swapoff' '! grep -qE "sudo (fallocate|mkswap|swapoff)" "$CALLS" && [[ $(grep -c "^/swap.img " "$ROOT/etc/fstab") == 1 ]]'
run07
assert 'configured but missing zram is started again, not mistaken for healthy' 'grep -q "\[would\].*start systemd-zram-setup@zram0.service" "$TMP/out"'
# Existing Ubuntu swap must be measured, not merely present.
truncate -s 4294967296 "$ROOT/swap.img"
printf '%s file 4294963200 1073741824 -2\n/dev/zram0 partition 2147483648 0 100\n' "$ROOT/swap.img" > "$STATE/swaps"
mem 8192 256; run07
assert 'small overflow under load: reports undersized and unsafe' 'grep -q "WARN.*disk overflow.*4095.*8192" "$TMP/out" && grep -q "unsafe to swapoff" "$TMP/out"'
run07 install
assert 'unsafe swapoff never formats, truncates or removes active swap' '! grep -qE "sudo (swapoff|fallocate|mkswap|rm)" "$CALLS" && [[ $(stat -c %s "$ROOT/swap.img") == 4294967296 ]]'
mem 8192 4096; run07 install
assert 'safe growth: swapoff then allocate, preserve UUID, reactivate' 'grep -q "swapoff $ROOT/swap.img" "$CALLS" && grep -q "mkswap.*-U swap-uuid" "$CALLS" && [[ $(stat -c %s "$ROOT/swap.img") == 8589938688 ]] && grep -q "swapon --priority -2" "$CALLS"'
# Active zram is never swapped off for a config change, even under pressure.
assert 'zram drift is deferred without restart' 'grep -q "next reboot" "$TMP/out" && ! grep -q "restart systemd-zram" "$CALLS"'
printf '%s file 4294963200 0 -2\n' "$ROOT/swap.img" > "$STATE/swaps"; touch "$STATE/fail-swapoff"; run07 install
assert 'swapoff failure blocks allocation and formatting' '! grep -qE "sudo (fallocate|mkswap)" "$CALLS" && grep -q "swapoff failed" "$TMP/out"'
rm "$STATE/fail-swapoff"
touch "$STATE/fail-uuid"; run07
assert 'unreadable UUID in doctor proposes a conditional root probe, never sudo' 'grep -q "\[would\].*probe.*UUID.*root" "$TMP/out" && ! grep -q "^sudo " "$CALLS"'
run07 install
assert 'ambiguous root UUID probe never reformats active swap' 'grep -q "cannot read swap UUID" "$TMP/out" && ! grep -qE "sudo (swapoff|fallocate|mkswap)" "$CALLS"'
rm "$STATE/fail-uuid"
truncate -s 17179869184 "$ROOT/swap.img"
echo 3221225472 > "$STATE/free"; run07 install
assert 'preallocated tail is not counted as space that a resize will free' 'grep -q "insufficient free disk" "$TMP/out" && ! grep -qE "sudo (swapoff|fallocate|mkswap)" "$CALLS"'
rm "$STATE/free"
printf '/dev/sda3 partition 2147483648 0 -2\n' > "$STATE/swaps"; rm -f "$ROOT/swap.img"; : > "$ROOT/etc/fstab"; run07 install
assert 'small swap partition: add overflow without formatting the partition' 'grep -q "swapon --priority -2.*swap.img" "$CALLS" && ! grep -q "mkswap.*sda3" "$CALLS"'
printf '/dev/sda3 partition 8589930496 0 -2\n/dev/zram0 partition 4294963200 0 100\n' > "$STATE/swaps"; run07
assert 'one swap header page does not make healthy 8G disk/4G zram look undersized' '! grep -qE "WARN.*(disk overflow|zram: live)" "$TMP/out" && grep -q "OK.*overflow" "$TMP/out"'
runv
assert 'independent verifier accepts normal swap header overhead' 'grep -q "PASS.*disk overflow [0-9].*MiB" "$TMP/out" && grep -q "PASS.*zram size" "$TMP/out" && ! grep -q "FAIL.*disk overflow [0-9].*MiB" "$TMP/out"'
mem 32768; : > "$STATE/swaps"; conf component_oom_zram=yes; run07
assert '32 GiB retains quarter-RAM zram and zram-only auto' 'grep -q "8192 MB.*zstd" "$TMP/out" && grep -q "policy zram-only" "$TMP/out" && ! grep -q "disk overflow target" "$TMP/out"'
mem 15872; run07
assert 'nominal 16 GiB with reserved RAM retains quarter-RAM zram' 'grep -q "3968 MB.*zstd" "$TMP/out" && grep -q "policy zram-only" "$TMP/out"'
conf component_oom_zram=yes swap_policy=typo; run07 install
assert 'invalid policy never mutates disk swap' 'grep -q "invalid swap_policy" "$TMP/out" && ! grep -qE "sudo (swapoff|swapon|fallocate|mkswap)" "$CALLS"'
mem 8192; conf component_oom_zram=yes; printf '/dev/sda3 partition 2147483648 0 -2\n' > "$STATE/swaps"; runv
assert 'independent verifier fails on overflow size' 'grep -q "FAIL.*disk overflow.*2048.*8192" "$TMP/out"'
finish
