#!/bin/bash
# Shared helpers for setup-kit. Source from each script:
#   source "$(dirname "$0")/../../lib.sh"   (profile scripts)
#   source "$(dirname "$0")/../lib.sh"      (capture scripts)

set -uo pipefail   # no -e: we log misses, we don't abort

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_DIR="$KIT_DIR/snapshot"
MANIFEST_DIR="$KIT_DIR/manifests"
LOG_DIR="$KIT_DIR/logs"
HOST_CONF="$KIT_DIR/hosts/$(hostname).conf"

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------- output
if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_FAIL=$'\e[31m'; C_HDR=$'\e[1m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
  C_OK=''; C_WARN=''; C_FAIL=''; C_HDR=''; C_DIM=''; C_RST=''
fi
DOCTOR_WARN=0; DOCTOR_FAIL=0
section() { printf '\n%s%s%s\n' "$C_HDR" "$*" "$C_RST"; }
ok()      { printf '  %s[ OK ]%s  %s\n' "$C_OK"   "$C_RST" "$*"; }
warn()    { printf '  %s[WARN]%s  %s\n' "$C_WARN" "$C_RST" "$*"; DOCTOR_WARN=$((DOCTOR_WARN+1)); }
fail()    { printf '  %s[FAIL]%s  %s\n' "$C_FAIL" "$C_RST" "$*"; DOCTOR_FAIL=$((DOCTOR_FAIL+1)); }
hint()    { printf '          %s↳ %s%s\n' "$C_DIM" "$*" "$C_RST"; }

log() {
  local msg="[$(date -Iseconds)] $*"
  echo "$msg"
  echo "$msg" >> "$LOG_DIR/${SCRIPT_NAME:-unknown}.log"
}

miss() { echo "$*" >> "$LOG_DIR/missing.log"; log "MISS: $*"; }

# ---------------------------------------------------------------- modes
require_root() {
  [[ $EUID -eq 0 ]] || { echo "ERROR: ${SCRIPT_NAME:-this} must run as root." >&2; exit 2; }
}
require_user() {
  [[ $EUID -ne 0 ]] || { echo "ERROR: ${SCRIPT_NAME:-this} must run as your normal user." >&2; exit 2; }
}
# Every profile script takes mode as $1: check (default, read-only) | install
init_mode() {
  MODE="${1:-check}"
  case "$MODE" in
    check)   INSTALL=0 ;;
    install) INSTALL=1 ;;
    *) echo "usage: $0 [check|install]" >&2; exit 1 ;;
  esac
}
# Run cmd only in install mode; in check mode print what would happen.
do_or_say() {
  if (( INSTALL )); then
    log "+ $*"
    "$@" 2>&1 | tee -a "$LOG_DIR/${SCRIPT_NAME:-unknown}.log"
    return "${PIPESTATUS[0]}"
  else
    printf '  %s[would]%s %s\n' "$C_DIM" "$C_RST" "$*"
  fi
}

# ---------------------------------------------------------------- host conf
# Answer file: KEY=value lines. conf_get KEY DEFAULT
conf_get() {
  local v
  v=$(grep -E "^${1}=" "$HOST_CONF" 2>/dev/null | tail -1 | cut -d= -f2- \
      | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//')
  echo "${v:-${2:-}}"
}
conf_set() {
  touch "$HOST_CONF"
  if grep -qE "^${1}=" "$HOST_CONF"; then
    sed -i "s|^${1}=.*|${1}=${2}|" "$HOST_CONF"
  else
    echo "${1}=${2}" >> "$HOST_CONF"
  fi
}
group_on() { [[ "$(conf_get "group_${1//-/_}" no)" == yes ]]; }

# ---------------------------------------------------------------- detection
has_nvidia()   { lspci 2>/dev/null | grep -qi nvidia; }
# nvidia stack wanted? GPU present AND (cond_nvidia=yes forces, =no blocks,
# auto requires ubuntu-drivers to back the card). Legacy GPUs the current
# driver dropped (e.g. Kepler) get nouveau, not a restart-looping 580 stack.
nvidia_wanted() {
  has_nvidia || return 1
  case "$(conf_get cond_nvidia auto)" in
    no)  return 1 ;;
    yes) return 0 ;;
  esac
  ubuntu-drivers devices 2>/dev/null | grep -q 'nvidia-driver'
}
virt_context() { local v; v="$(systemd-detect-virt 2>/dev/null)"; echo "${v:-none}"; }  # none|kvm|lxc|...
is_vm()        { [[ "$(virt_context)" != none ]]; }
has_kvm_dev()  { [[ -e /dev/kvm ]]; }

# ---------------------------------------------------------------- manifests
# manifest_pkgs <file> -> package names, comments/blank stripped
manifest_pkgs() { grep -hvE '^[[:space:]]*(#|$)' "$1" 2>/dev/null | awk '{print $1}'; }

# strictly installed — NOT just known to dpkg. `dpkg -s` exits 0 for
# removed-but-config-files packages, which would hide a removed package from
# the installer (the kind of drift verify.sh exists to catch).
pkg_installed() {
  [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]
}

# packages from a manifest file not yet installed
manifest_missing() {
  local p
  while IFS= read -r p; do
    pkg_installed "$p" || echo "$p"
  done < <(manifest_pkgs "$1")
}

apt_install_one() {
  local pkg="$1"
  pkg_installed "$pkg" && return 0
  if sudo apt-get install -y --no-install-recommends "$pkg" >/dev/null 2>&1; then
    log "installed: $pkg"
  else
    miss "apt: $pkg"
  fi
}
