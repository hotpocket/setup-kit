#!/bin/bash
# Extra limits for a small control box. Reasons and source incidents are in
# docs/reports/friend-box-memory-lessons.md; larger boxes opt in explicitly.
source "$KIT_DIR/components/memory-common.sh"
RESOURCE_POLICY=$(conf_get component_resource_guards auto)
if [[ "$RESOURCE_POLICY" == auto ]]; then
  (( RAM_CLASS_MB < 16384 )) && RESOURCE_POLICY=yes || RESOURCE_POLICY=no
fi
if [[ "$RESOURCE_POLICY" != yes ]]; then
  ok "resource guards: disabled (component_resource_guards=$RESOURCE_POLICY)"
  return 0
fi
section "small-box resource guards ($MODE)"
DISK_RESERVE=$(conf_get disk_headroom_gb 10)
[[ "$DISK_RESERVE" =~ ^[0-9]+$ ]] || DISK_RESERVE=10
for DISK_PATH in "$MEM_ROOT/" "$MEM_ROOT/tmp"; do
  DISK_FREE=$(findmnt -brn -o AVAIL --target "$DISK_PATH" 2>/dev/null)
  if [[ ! "$DISK_FREE" =~ ^[0-9]+$ ]]; then
    warn "disk headroom: cannot measure $DISK_PATH"
  elif (( DISK_FREE < DISK_RESERVE * 1073741824 )); then
    warn "disk headroom: $DISK_PATH has $((DISK_FREE/1073741824)) GiB free, want ${DISK_RESERVE} GiB; inspect scratch/caches, no automatic deletion"
  fi
done
memory_write "$MEM_ROOT/etc/systemd/journald.conf.d/60-setup-kit.conf" \
  $'[Journal]\nSystemMaxUse=512M\nSystemKeepFree=1G\nRuntimeMaxUse=64M\nRateLimitIntervalSec=30s\nRateLimitBurst=1000' root 'journal disk/RAM cap'
if (( MEM_CHANGED )); then do_or_say sudo systemctl restart systemd-journald.service; fi
# Watch exhaustion breaks VS Code/agent file watching. Raising the ceiling
# does not preallocate kernel memory. Do not lower a host's larger limits.
WATCHES=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null)
INSTANCES=$(sysctl -n fs.inotify.max_user_instances 2>/dev/null)
[[ "$WATCHES" =~ ^[0-9]+$ ]] || WATCHES=0
[[ "$INSTANCES" =~ ^[0-9]+$ ]] || INSTANCES=0
(( WATCHES < 524288 )) && WATCHES=524288
(( INSTANCES < 512 )) && INSTANCES=512
INOTIFY_WANT=$(printf 'fs.inotify.max_user_watches=%s\nfs.inotify.max_user_instances=%s' "$WATCHES" "$INSTANCES")
memory_write "$MEM_ROOT/etc/sysctl.d/60-setup-kit-inotify.conf" "$INOTIFY_WANT" root 'inotify watch/instance floors'
if (( MEM_CHANGED )) || [[ "$(sysctl -n fs.inotify.max_user_watches)" -lt 524288 || "$(sysctl -n fs.inotify.max_user_instances)" -lt 512 ]]; then
  do_or_say sudo sysctl -p "$MEM_ROOT/etc/sysctl.d/60-setup-kit-inotify.conf"
fi
# Keep GNOME search, but bound its unattended crawl of node_modules/builds.
# Discover installed names (Ubuntu has used Tracker and LocalSearch).
RESOURCE_USER_RELOAD=0
while read -r INDEX_UNIT _; do
  [[ "$INDEX_UNIT" =~ ^(localsearch|tracker-miner|tracker-extract)[A-Za-z0-9@_.-]*\.service$ ]] || continue
  memory_write "$HOME/.config/systemd/user/$INDEX_UNIT.d/60-setup-kit.conf" \
    $'[Unit]\nStartLimitIntervalSec=300\nStartLimitBurst=3\n[Service]\nCPUWeight=20\nIOWeight=20\nCPUQuota=25%\nMemoryHigh=192M\nMemoryMax=256M\nOOMScoreAdjust=600\nRestartSec=30s' user "indexer $INDEX_UNIT bounds"
  (( MEM_CHANGED )) && RESOURCE_USER_RELOAD=1
  LIVE_INDEX_MAX=$(systemctl --user show "$INDEX_UNIT" -p MemoryMax --value 2>/dev/null)
  if (( MEM_CHANGED )) || [[ "$LIVE_INDEX_MAX" != 268435456 && "$LIVE_INDEX_MAX" != 256M ]]; then
    warn "indexer $INDEX_UNIT live memory cap needs 256 MiB"
    do_or_say systemctl --user set-property "$INDEX_UNIT" CPUWeight=20 IOWeight=20 CPUQuota=25% MemoryHigh=192M MemoryMax=256M
  fi
done < <(systemctl --user list-unit-files --type=service --no-legend 2>/dev/null)

SAMPLER_SRC="$KIT_DIR/components/memory-sample.py"
SAMPLER_DST="$HOME/.local/lib/setup-kit/memory-sample.py"
memory_write "$SAMPLER_DST" "$(cat "$SAMPLER_SRC")" user 'memory history sampler (30 days)'
if [[ ! -x "$SAMPLER_DST" ]]; then do_or_say chmod +x "$SAMPLER_DST"; fi
memory_write "$HOME/.config/systemd/user/setup-kit-memory.service" \
  $'[Unit]\nDescription=Bounded memory history for agent control boxes\n[Service]\nType=oneshot\nExecStart=%h/.local/lib/setup-kit/memory-sample.py\nNice=19\nMemoryMax=64M' user 'memory history service'
(( MEM_CHANGED )) && RESOURCE_USER_RELOAD=1
memory_write "$HOME/.config/systemd/user/setup-kit-memory.timer" \
  $'[Unit]\nDescription=Sample RAM, swap, agents and browsers each minute\n[Timer]\nOnBootSec=60s\nOnUnitActiveSec=60s\n[Install]\nWantedBy=timers.target' user 'memory history timer'
(( MEM_CHANGED )) && RESOURCE_USER_RELOAD=1
if (( RESOURCE_USER_RELOAD )); then do_or_say systemctl --user daemon-reload; fi
if ! systemctl --user is-active --quiet setup-kit-memory.timer; then
  warn 'memory history timer inactive'
  do_or_say systemctl --user enable --now setup-kit-memory.timer
fi
memory_write "$HOME/.local/bin/kit-heavy" "$(cat "$KIT_DIR/components/heavy-job.py")" user 'kit-heavy job owner/lock'
if [[ ! -x "$HOME/.local/bin/kit-heavy" ]]; then do_or_say chmod +x "$HOME/.local/bin/kit-heavy"; fi
