#!/bin/bash
# The kernel ranks individual processes; oomd ranks cgroups. Protect the
# control plane without protecting a whole user tree or T3's agent scopes.
memory_write "$MEM_ROOT/etc/systemd/oomd.conf.d/20-longer-duration.conf" \
  $'[OOM]\nDefaultMemoryPressureDurationSec=60s' root 'oomd pressure duration (60s)'
if (( MEM_CHANGED )); then do_or_say sudo systemctl restart systemd-oomd.service; fi
OOM_LIMIT=$(systemctl show "user@$(id -u).service" -p ManagedOOMMemoryPressureLimit --value 2>/dev/null)
if [[ "$OOM_LIMIT" == 8000 || "$OOM_LIMIT" == 80% ]]; then
  ok 'oomd user pressure limit 80%'
else
  warn "oomd user pressure limit ${OOM_LIMIT:-unknown} (50% is the Ubuntu default); want 80%"
  do_or_say sudo systemctl set-property "user@$(id -u).service" ManagedOOMMemoryPressureLimit=80%
fi
if ! systemctl is-active --quiet systemd-oomd.service; then
  warn 'systemd-oomd inactive — the kernel OOM killer is the last fallback'
  do_or_say sudo systemctl start systemd-oomd.service
fi

OOM_USER_RELOAD=0; OOM_SYSTEM_RELOAD=0
for OOM_UNIT in dbus.service dbus-broker.service org.gnome.Shell@.service; do
  memory_write "$HOME/.config/systemd/user/$OOM_UNIT.d/oomd-avoid.conf" \
    $'[Service]\nManagedOOMPreference=avoid' user "$OOM_UNIT oomd shield"
  (( MEM_CHANGED )) && OOM_USER_RELOAD=1
done
# T3 already marks its agents at +800, isolates them in scopes, and ships
# OOMPolicy=continue / ManagedOOMPreference=avoid in current versions.
# Older installed units need the same control-plane policy. NEVER put a
# negative OOMScoreAdjust on T3, user@, app.slice or agent scopes: it would
# be inherited by work that is supposed to lose first.
if [[ "$(conf_get component_t3code no)" == yes || -f "$HOME/.config/systemd/user/t3code.service" ]]; then
  memory_write "$HOME/.config/systemd/user/t3code.service.d/20-oom.conf" \
    $'[Service]\nOOMPolicy=continue\nManagedOOMPreference=avoid' user 't3code control-plane OOM policy'
  (( MEM_CHANGED )) && OOM_USER_RELOAD=1
  hint 'T3 agent/browser children retain +800 and their own scopes; no blanket user OOM exemption'
fi
if (( OOM_USER_RELOAD )); then do_or_say systemctl --user daemon-reload; fi
# Preference is mutable and safe to apply without stopping a live session.
# The template drop-in covers both Wayland/X11 at their next activation.
for OOM_UNIT in dbus.service dbus-broker.service org.gnome.Shell@wayland.service org.gnome.Shell@x11.service t3code.service; do
  [[ "$(systemctl --user show "$OOM_UNIT" -p LoadState --value 2>/dev/null)" == loaded ]] || continue
  [[ "$OOM_UNIT" == t3code.service && ! -f "$HOME/.config/systemd/user/t3code.service.d/20-oom.conf" ]] && continue
  if [[ "$(systemctl --user show "$OOM_UNIT" -p ManagedOOMPreference --value 2>/dev/null)" != avoid ]]; then
    warn "$OOM_UNIT live oomd preference needs avoid"
    do_or_say systemctl --user set-property "$OOM_UNIT" ManagedOOMPreference=avoid
  fi
done
for OOM_UNIT in ssh.service tailscaled.service snap.tailscale.tailscaled.service; do
  [[ "$(systemctl show "$OOM_UNIT" -p LoadState --value 2>/dev/null)" == loaded ]] || continue
  if [[ "$OOM_UNIT" == ssh.service ]]; then
    # OpenSSH raises only its listener to -1000 and restores the original
    # score in login children. A negative service score changes that saved
    # baseline and would protect every SSH-launched job as well.
    OOM_REMOTE_WANT=$'[Service]\nManagedOOMPreference=avoid'
    OOM_REMOTE_LABEL='ssh.service native listener OOM protection (no inherited adjustment)'
  else
    OOM_REMOTE_SCORE=$(systemctl show "$OOM_UNIT" -p OOMScoreAdjust --value 2>/dev/null)
    if [[ ! "$OOM_REMOTE_SCORE" =~ ^-[0-9]+$ ]] || (( OOM_REMOTE_SCORE > -500 )); then OOM_REMOTE_SCORE=-500; fi
    OOM_REMOTE_WANT=$(printf '[Service]\nOOMScoreAdjust=%s\nManagedOOMPreference=avoid' "$OOM_REMOTE_SCORE")
    OOM_REMOTE_LABEL="$OOM_UNIT kernel OOM preference $OOM_REMOTE_SCORE"
  fi
  memory_write "$MEM_ROOT/etc/systemd/system/$OOM_UNIT.d/20-oom.conf" "$OOM_REMOTE_WANT" root "$OOM_REMOTE_LABEL"
  (( MEM_CHANGED )) && OOM_SYSTEM_RELOAD=1
  if [[ "$(systemctl show "$OOM_UNIT" -p ManagedOOMPreference --value 2>/dev/null)" != avoid ]]; then
    do_or_say sudo systemctl set-property "$OOM_UNIT" ManagedOOMPreference=avoid
  fi
  OOM_PID=$(systemctl show "$OOM_UNIT" -p MainPID --value 2>/dev/null)
  OOM_SCORE='unknown'
  if [[ "$OOM_PID" =~ ^[1-9][0-9]*$ ]]; then OOM_SCORE=$(cat "$MEM_PROC/$OOM_PID/oom_score_adj" 2>/dev/null) || OOM_SCORE=unknown; fi
  if [[ ! "$OOM_SCORE" =~ ^-[0-9]+$ ]] || (( OOM_SCORE > -500 )); then
    if [[ "$OOM_UNIT" == ssh.service ]]; then
      hint 'ssh.service: native listener protection is checked when its socket starts the daemon; no access restart'
    else
      hint "$OOM_UNIT: kernel preference takes effect at next service start/reboot; no remote-access restart"
    fi
  fi

done
if (( OOM_SYSTEM_RELOAD )); then do_or_say sudo systemctl daemon-reload; fi
