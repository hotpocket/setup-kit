#!/bin/bash
source "$(dirname "$0")/memory-fixture.sh"
conf component_oom_zram=yes
mkdir -p "$ROOT/etc/systemd/oomd.conf.d" "$HOME/.config/systemd/user/dbus.service.d"
printf '[OOM]\nDefaultMemoryPressureDurationSec=1s\n' > "$ROOT/etc/systemd/oomd.conf.d/20-longer-duration.conf"
printf '[Service]\nManagedOOMPreference=none\n' > "$HOME/.config/systemd/user/dbus.service.d/oomd-avoid.conf"
mkdir -p "$HOME/.config/systemd/user"
printf '[Service]\nExecStart=/fake/t3\nOOMPolicy=stop\n' > "$HOME/.config/systemd/user/t3code.service"
run07
assert 'content drift and live 50% pressure are visible even when files exist' 'grep -q "WARN.*oomd.*duration" "$TMP/out" && grep -q "WARN.*pressure limit.*50" "$TMP/out" && grep -q "WARN.*dbus.*shield" "$TMP/out"'
assert 'native SSH listener protection is retained; tailscaled guard is proposed' 'grep -q "ssh.service.*native" "$TMP/out" && grep -q "tailscaled.service.*-500" "$TMP/out"'
run07 install
assert 'oomd duration and pressure repaired without restarting login manager' 'grep -qx DefaultMemoryPressureDurationSec=60s "$ROOT/etc/systemd/oomd.conf.d/20-longer-duration.conf" && grep -q "set-property user@.*ManagedOOMMemoryPressureLimit=80%" "$CALLS" && ! grep -qE "restart (user@|dbus|org.gnome|t3code|ssh|tailscaled)" "$CALLS"'
assert 'session bus shield reconciles by content' 'grep -qx ManagedOOMPreference=avoid "$HOME/.config/systemd/user/dbus.service.d/oomd-avoid.conf"'
assert 'GNOME and T3 oomd shields leave agent scopes eligible' 'grep -qx ManagedOOMPreference=avoid "$HOME/.config/systemd/user/org.gnome.Shell@.service.d/oomd-avoid.conf" && grep -qx OOMPolicy=continue "$HOME/.config/systemd/user/t3code.service.d/20-oom.conf" && ! grep -R -qE "(OOMScoreAdjust=-|ManagedOOMPreference=omit)" "$HOME/.config/systemd/user"'
assert 'SSH listener keeps native protection without a negative score inherited by login jobs' '! grep -q OOMScoreAdjust "$ROOT/etc/systemd/system/ssh.service.d/20-oom.conf" && grep -qx ManagedOOMPreference=avoid "$ROOT/etc/systemd/system/ssh.service.d/20-oom.conf"'
assert 'tailscaled has next-start guard, no blanket user protection' 'grep -qx OOMScoreAdjust=-500 "$ROOT/etc/systemd/system/tailscaled.service.d/20-oom.conf" && [[ ! -d "$ROOT/etc/systemd/system/user@.service.d" ]]'
run07 install
assert 'second install performs no config rewrites or oomd restart' '! grep -qE "sudo tee|restart systemd-oomd" "$CALLS"'
echo none > "$STATE/ssh.service.ManagedOOMPreference"; run07
assert 'matching root drop-in cannot hide live oomd preference drift' 'grep -q "\[would\].*set-property ssh.service ManagedOOMPreference=avoid" "$TMP/out"'
run07 install
assert 'root live preference is repaired without restarting SSH' '[[ $(cat "$STATE/ssh.service.ManagedOOMPreference") == avoid ]] && ! grep -q "restart ssh" "$CALLS"'
echo -1000 > "$STATE/tailscaled.service.OOMScoreAdjust"; run07 install
assert 'existing stronger Tailscale kernel preference is preserved' 'grep -qx OOMScoreAdjust=-1000 "$ROOT/etc/systemd/system/tailscaled.service.d/20-oom.conf"'
echo 0 > "$STATE/ssh.service.MainPID"; touch "$STATE/active-ssh.socket"; runv
assert 'socket-activated SSH is reachable before its listener PID exists' 'grep -q "PASS.*ssh.socket.*native" "$TMP/out"'
rm "$STATE/active-ssh.socket"
echo -500 > "$STATE/ssh.service.OOMScoreAdjust"; echo 23 > "$STATE/ssh.service.MainPID"
mkdir -p "$ROOT/proc/23"; echo 0 > "$ROOT/proc/23/oom_score_adj"; runv
assert 'kernel verification reads the running PID, not just reloaded unit settings' 'grep -q "FAIL.*ssh.service kernel OOM preference" "$TMP/out"'
echo -500 > "$ROOT/proc/23/oom_score_adj"; runv
assert 'kernel verification positive control' 'grep -q "PASS.*ssh.service kernel OOM preference" "$TMP/out"'
echo -1000 > "$ROOT/proc/23/oom_score_adj"; runv
assert 'native stronger -1000 kernel protection passes verification' 'grep -q "PASS.*ssh.service kernel OOM preference" "$TMP/out"'
conf component_oom_zram=no; run07
assert 'component opt-out is honored' '! grep -qE "pressure limit|dbus.*shield|ssh.service.*-500" "$TMP/out"'
finish
