#!/bin/bash
source "$(dirname "$0")/memory-fixture.sh"
printf 'localsearch-3.service static\ntracker-miner-fs-3.service static\n' > "$STATE/units"
conf component_resource_guards=auto; run07
assert '8 GiB auto: journal, indexer, inotify and history gaps reported' 'grep -q "WARN.*journal.*cap" "$TMP/out" && grep -q "WARN.*indexer" "$TMP/out" && grep -q "WARN.*inotify" "$TMP/out" && grep -q "WARN.*memory history" "$TMP/out"'
assert 'doctor writes no user or system configuration' '[[ ! -e "$ROOT/etc/systemd/journald.conf.d/60-setup-kit.conf" ]] && [[ ! -e "$HOME/.config/systemd/user/setup-kit-memory.timer" ]] && ! grep -q "^sudo " "$CALLS"'
run07 install
assert 'journal is bounded on disk and in RAM without vacuuming history' 'grep -qx SystemMaxUse=512M "$ROOT/etc/systemd/journald.conf.d/60-setup-kit.conf" && grep -qx RuntimeMaxUse=64M "$ROOT/etc/systemd/journald.conf.d/60-setup-kit.conf" && ! grep -q vacuum "$CALLS"'
assert 'indexers are throttled and capped, packages remain installed' 'grep -qx MemoryHigh=192M "$HOME/.config/systemd/user/localsearch-3.service.d/60-setup-kit.conf" && grep -qx MemoryMax=256M "$HOME/.config/systemd/user/localsearch-3.service.d/60-setup-kit.conf" && ! grep -qE "(mask|apt.*remove)" "$CALLS"'
assert 'watch limits raised, not lowered' 'grep -qx fs.inotify.max_user_watches=524288 "$ROOT/etc/sysctl.d/60-setup-kit-inotify.conf" && grep -qx fs.inotify.max_user_instances=512 "$ROOT/etc/sysctl.d/60-setup-kit-inotify.conf"'
assert 'bounded memory sampler has a user timer' 'grep -qx OnUnitActiveSec=60s "$HOME/.config/systemd/user/setup-kit-memory.timer" && [[ -x "$HOME/.local/lib/setup-kit/memory-sample.py" ]] && grep -q "enable --now setup-kit-memory.timer" "$CALLS"'
run07 install
assert 'second install is idempotent' '! grep -qE "sudo tee|restart systemd-journald|write.*indexer" "$CALLS"'
chmod -x "$HOME/.local/lib/setup-kit/memory-sample.py" "$HOME/.local/bin/kit-heavy"; run07
assert 'matching script content still reports lost executable bits' 'grep -q "\[would\].*chmod.*memory-sample.py" "$TMP/out" && grep -q "\[would\].*chmod.*kit-heavy" "$TMP/out"'
run07 install
assert 'install repairs executable bits without a content rewrite' '[[ -x "$HOME/.local/lib/setup-kit/memory-sample.py" && -x "$HOME/.local/bin/kit-heavy" ]]'
echo infinity > "$STATE/localsearch-3.service.MemoryMax"; run07
assert 'matching indexer file cannot hide missing live memory cap' 'grep -q "WARN.*indexer.*live.*cap" "$TMP/out" && grep -q "\[would\].*set-property localsearch-3.service" "$TMP/out"'
echo 1048576 > "$STATE/watches"; echo 1024 > "$STATE/instances"; run07 install
assert 'existing higher watch limits stay higher' 'grep -qx fs.inotify.max_user_watches=1048576 "$ROOT/etc/sysctl.d/60-setup-kit-inotify.conf" && grep -qx fs.inotify.max_user_instances=1024 "$ROOT/etc/sysctl.d/60-setup-kit-inotify.conf"'
echo 1073741824 > "$STATE/free"; run07
assert 'runtime disk pressure is diagnosed without deleting caches' 'grep -q "WARN.*disk headroom.*1 GiB.*10 GiB" "$TMP/out" && ! grep -q "sudo rm" "$CALLS"'
rm "$STATE/free"
mem 32768; conf component_resource_guards=auto; run07
assert 'large machines retain their resource policy by default' 'grep -q "resource guards:.*disabled" "$TMP/out" && ! grep -q "WARN.*indexer" "$TMP/out"'
mem 15872; run07
assert 'reserved RAM does not opt a nominal 16 GiB box into new caps' 'grep -q "resource guards:.*disabled" "$TMP/out"'
# Exercise the real sampler against proc fixtures, including PID-exit races.
mem 8192 512
mkdir -p "$ROOT/proc/10" "$ROOT/proc/11" "$ROOT/proc/12" "$HOME/.local/state/setup-kit-memory"
printf 'claude\0--resume\0' > "$ROOT/proc/10/cmdline"
printf 'VmRSS: 1048576 kB\nVmSwap: 524288 kB\n' > "$ROOT/proc/10/status"
printf 'chrome\0--headless\0' > "$ROOT/proc/11/cmdline"
printf 'VmRSS: 262144 kB\nVmSwap: 0 kB\n' > "$ROOT/proc/11/status"
printf 'Filename Type Size Used Priority\n/dev/zram0 partition 4194304 1024 100\n/swap.img file 8388608 2048 -2\n' > "$ROOT/proc/swaps"
touch -d '40 days ago' "$HOME/.local/state/setup-kit-memory/2000-01-01.csv"
if [[ -f "$KIT_DIR/components/memory-sample.py" ]]; then
  KIT_MEMORY_PROC="$ROOT/proc" python3 "$KIT_DIR/components/memory-sample.py" > "$TMP/out" 2>&1
else echo 'memory sampler missing' > "$TMP/out"; fi
assert 'sampler records low memory, tiers, agent/browser counts; prunes old history' 'csv=$(find "$HOME/.local/state/setup-kit-memory" -name "*.csv" | head -1); [[ -n "$csv" ]] && grep -q "agent_mb" "$csv" && grep -q ",512,1,2,1,1536,1,256" "$csv" && [[ ! -f "$HOME/.local/state/setup-kit-memory/2000-01-01.csv" ]]'
finish
