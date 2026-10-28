#!/bin/bash
# Shared fake machine for the memory calibration scripts. No real sudo, mounts,
# swap operations, services, sysctls or HOME; even install runs stay in $TMP.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export ROOT="$TMP/root" HOME="$TMP/home" STATE="$TMP/state" CALLS="$TMP/calls"
export KIT_MEMORY_ROOT="$ROOT" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0
export HOST_CONF="$TMP/host.conf" KIT_HOST_CONF="$TMP/host.conf" KIT_VERBOSE=1
mkdir -p "$ROOT/etc/systemd/system" "$ROOT/proc" "$ROOT/sys/block/zram0" "$HOME" "$STATE" "$TMP/bin"
export PATH="$TMP/bin:/usr/bin:/bin"
unset DBUS_SESSION_BUS_ADDRESS DISPLAY WAYLAND_DISPLAY
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; tail -35 "$TMP/out"; fi; }
finish() { echo "${0##*/}: $pass passed, $fail failed"; (( fail == 0 )); }
mem() { printf 'MemTotal: %s kB\nMemAvailable: %s kB\n' "$(( $1 * 1024 ))" "$(( ${2:-2048} * 1024 ))" > "$ROOT/proc/meminfo"; }
conf() {
  printf '%s\n' configs=no group_dev_cloud=no component_docker_rootless=no component_oom_zram=no \
    component_uutils_ls=no component_clipboard=no component_herdr=no component_ollama=no component_whisper=no \
    component_aws_cli=no component_codex=no component_t3code=no component_git_hub=no component_lid_ignore=no \
    component_dictation=no component_ocr=no component_tts=no component_resource_guards=no tmp_on_disk=no "$@" > "$HOST_CONF"
}
run07() {
  : > "$CALLS"
  # Before implementation, ONLY run check against the old phase. It has no
  # fake-root seam and must never enter its install path on this desktop.
  if [[ "${1:-check}" == install ]] && ! grep -q 'components/oom-zram.sh' "$KIT_DIR/profiles/workstation/07-components.sh"; then
    echo 'fixture: install blocked until the fake-root implementation exists' > "$TMP/out"; return 1
  fi
  bash "$KIT_DIR/profiles/workstation/07-components.sh" "${1:-check}" > "$TMP/out" 2>&1
}
runv() { : > "$CALLS"; bash "$KIT_DIR/verify.sh" > "$TMP/out" 2>&1; }
cat > "$TMP/bin/sudo" <<'SH'
#!/bin/bash
echo "sudo $*" >> "$CALLS"
case "$1" in
  -n) exit 1 ;; # verify must not refresh real apt metadata
  systemctl|sysctl|fallocate|mkswap|swapon|swapoff|blkid) exec "$@" ;;
  tee|mkdir|chmod|mv|rm|install|cp)
    for a in "${@:2}"; do
      case "$a" in /*) [[ "$a" == "$ROOT"/* || "$a" == "$HOME"/* ]] || { echo "UNSAFE $*" >&2; exit 99; } ;; esac
    done
    exec "$@" ;;
  *) echo "UNSAFE sudo $*" >&2; exit 99 ;;
esac
SH
cat > "$TMP/bin/systemctl" <<'SH'
#!/bin/bash
echo "systemctl $*" >> "$CALLS"
scope=system
[[ "${1:-}" == --user ]] && { scope=user; shift; }
op="${1:-}"; shift || true
args="$*"
case "$op" in
  mask) ln -sfn /dev/null "$ROOT/etc/systemd/system/tmp.mount" ;;
  is-enabled)
    if [[ "$args" == *tmp.mount* ]]; then
      [[ -L "$ROOT/etc/systemd/system/tmp.mount" ]] && { echo masked; exit 1; }; echo disabled; exit 1
    fi
    [[ -e "$STATE/enabled-${*: -1}" ]]; exit $? ;;
  is-active) [[ -e "$STATE/active-${*: -1}" ]]; exit $? ;;
  start) touch "$STATE/active-${*: -1}" ;;
  enable) touch "$STATE/enabled-${*: -1}" "$STATE/active-${*: -1}" ;;
  show)
    if [[ "$*" == *Id,NRestarts* ]]; then cat "$STATE/calm-$scope-flap" 2>/dev/null; exit 0; fi
    unit="${1:-}"; prop="${*: -1}"; prop="${prop#--property=}"; prop="${prop#-p}";
    # The fixture accepts --value -p PROP UNIT and UNIT -p PROP --value.
    for ((i=1; i<=$#; i++)); do
      a="${!i}"; case "$a" in --property=*|-p=*) prop="${a#*=}" ;; -p|--property) j=$((i+1)); prop="${!j}" ;; *.service|*.slice) unit="$a" ;; esac
    done
    if [[ -e "$STATE/$unit.$prop" ]]; then cat "$STATE/$unit.$prop"
    else case "$prop" in LoadState) echo loaded ;; ManagedOOMMemoryPressureLimit) echo 5000 ;; ManagedOOMPreference) echo none ;; OOMScoreAdjust) echo 0 ;; OOMPolicy) echo stop ;; MainPID) echo 0 ;; esac; fi ;;
  set-property)
    unit="$1"; shift
    for p; do key="${p%%=*}"; val="${p#*=}"; [[ "$val" == 80% ]] && val=8000; echo "$val" > "$STATE/$unit.$key"; done ;;
  list-unit-files) cat "$STATE/units" 2>/dev/null ;;
  --failed) cat "$STATE/calm-$scope-failed" 2>/dev/null ;;
  list-units) cat "$STATE/calm-$scope-activating" 2>/dev/null ;;
  cat) cat "$STATE/unit-content" 2>/dev/null ;;
esac
exit 0
SH
cat > "$TMP/bin/swapon" <<'PY'
#!/usr/bin/python3
import os, sys
from pathlib import Path
p = Path(os.environ['STATE']) / 'swaps'
rows = [l.split() for l in p.read_text().splitlines()] if p.exists() else []
args = sys.argv[1:]
if any(a.startswith('--show') for a in args):
    fields = next((a.split('=',1)[1] for a in args if a.startswith('--show=')), 'NAME,TYPE,SIZE,USED,PRIO').split(',')
    keys = ['NAME','TYPE','SIZE','USED','PRIO']
    for row in rows: print(' '.join(row[keys.index(f)] for f in fields))
else:
    with open(os.environ['CALLS'],'a') as f: f.write('swapon ' + ' '.join(args) + '\n')
    if (Path(os.environ['STATE'])/'fail-swapon').exists(): sys.exit(1)
    name = args[-1]; size = Path(name).stat().st_size
    rows = [r for r in rows if r[0] != name]
    rows.append([name,'file',str(size-4096),'0',args[args.index('--priority')+1] if '--priority' in args else '-2'])
    p.write_text(''.join(' '.join(r)+'\n' for r in rows))
PY
cat > "$TMP/bin/swapoff" <<'PY'
#!/usr/bin/python3
import os,sys
from pathlib import Path
with open(os.environ['CALLS'],'a') as f: f.write('swapoff ' + ' '.join(sys.argv[1:]) + '\n')
if (Path(os.environ['STATE'])/'fail-swapoff').exists(): sys.exit(1)
p = Path(os.environ['STATE'])/'swaps'
p.write_text(''.join(l+'\n' for l in p.read_text().splitlines() if l.split()[0] != sys.argv[-1]))
PY
cat > "$TMP/bin/fallocate" <<'PY'
#!/usr/bin/python3
import os,sys
from pathlib import Path
with open(os.environ['CALLS'],'a') as f: f.write('fallocate ' + ' '.join(sys.argv[1:]) + '\n')
if (Path(os.environ['STATE'])/'fail-allocate').exists(): sys.exit(1)
name=sys.argv[-1]
assert name.startswith(os.environ['ROOT']+'/')
with open(name,'ab') as f: f.truncate(int(sys.argv[sys.argv.index('-l')+1]))
PY
cat > "$TMP/bin/sysctl" <<'SH'
#!/bin/bash
echo "sysctl $*" >> "$CALLS"
case "$*" in
  *vm.swappiness*) echo 10 ;; *vm.page-cluster*) echo 0 ;;
  *fs.inotify.max_user_watches*) cat "$STATE/watches" 2>/dev/null || echo 8192 ;;
  *fs.inotify.max_user_instances*) cat "$STATE/instances" 2>/dev/null || echo 128 ;;
  --system|*-p*) echo 524288 > "$STATE/watches"; echo 512 > "$STATE/instances" ;;
esac
SH
cat > "$TMP/bin/findmnt" <<'SH'
#!/bin/bash
case "$*" in *FSTYPE*) if [[ "${*: -1}" == "$ROOT/tmp" ]]; then cat "$STATE/fstype"; else echo ext4; fi ;; *AVAIL*) cat "$STATE/free" 2>/dev/null || echo 42949672960 ;; *OPTIONS*) echo rw,relatime ;; esac
SH
printf '#!/bin/sh\necho installed\nexit 0\n' > "$TMP/bin/dpkg"
printf '#!/bin/sh\n[ -e "$STATE/fail-uuid" ] && exit 1\necho swap-uuid\n' > "$TMP/bin/blkid"
printf '#!/bin/sh\necho "mkswap $*" >> "$CALLS"\n' > "$TMP/bin/mkswap"
printf '#!/bin/sh\ncase "$*" in *--grep*) cat "$STATE/oom-log" 2>/dev/null ;; esac\nexit 0\n' > "$TMP/bin/journalctl"
chmod +x "$TMP/bin"/*
mem 8192
echo tmpfs > "$STATE/fstype"
: > "$ROOT/etc/fstab"; : > "$STATE/swaps"
