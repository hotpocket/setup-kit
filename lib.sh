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

# Quiet mode: per-line [ OK ] confirmations are noise on the terminal — signal
# is drift and actions. Under bootstrap (KIT_RUN_LOG set) each ok() goes to the
# run log only (so summary counts and the audit trail are unchanged) and the
# terminal gets one dim "N ok" rollup per section. warn/fail/hints/actions
# always print. KIT_VERBOSE=1 (bootstrap -v, or verbose=yes in host conf)
# restores per-line output; standalone phase runs are always verbose.
KIT_QUIET=0
[[ -n "${KIT_RUN_LOG:-}" && "${KIT_VERBOSE:-0}" != 1 ]] && KIT_QUIET=1
SECTION_OK=0
_flush_ok() {
  (( KIT_QUIET && SECTION_OK )) && printf '  %s%d ok%s\n' "$C_DIM" "$SECTION_OK" "$C_RST"
  SECTION_OK=0
}
trap _flush_ok EXIT

section() { _flush_ok; printf '\n%s%s%s\n' "$C_HDR" "$*" "$C_RST"; }
ok() {
  if (( KIT_QUIET )); then
    printf '  [ OK ]  %s\n' "$*" >> "$KIT_RUN_LOG"
    SECTION_OK=$((SECTION_OK+1)); LAST_OK=1
  else
    printf '  %s[ OK ]%s  %s\n' "$C_OK" "$C_RST" "$*"
  fi
}
warn()    { printf '  %s[WARN]%s  %s\n' "$C_WARN" "$C_RST" "$*"; DOCTOR_WARN=$((DOCTOR_WARN+1)); LAST_OK=0; }
fail()    { printf '  %s[FAIL]%s  %s\n' "$C_FAIL" "$C_RST" "$*"; DOCTOR_FAIL=$((DOCTOR_FAIL+1)); LAST_OK=0; }
# a hint annotates the line above it — if that was a quiet-suppressed ok(),
# the hint follows it into the log instead of dangling on the terminal
LAST_OK=0
hint() {
  if (( KIT_QUIET )) && (( LAST_OK )); then
    printf '          ↳ %s\n' "$*" >> "$KIT_RUN_LOG"
  else
    printf '          %s↳ %s%s\n' "$C_DIM" "$*" "$C_RST"
  fi
}

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
    # escape sed-special chars in the value (\, |, &) so a value like a URL or
    # model tag can't corrupt the replacement; preserves the line's position
    local esc=${2//\\/\\\\}; esc=${esc//|/\\|}; esc=${esc//&/\\&}
    sed -i "s|^${1}=.*|${1}=${esc}|" "$HOST_CONF"
  else
    echo "${1}=${2}" >> "$HOST_CONF"
  fi
}
group_on() { [[ "$(conf_get "group_${1//-/_}" no)" == yes ]]; }

# ---------------------------------------------------------------- detection
# grep -q would exit at first match → SIGPIPE kills the producer → pipefail
# (line 6) fails the whole pipeline whenever output exceeds the pipe buffer.
# Redirecting instead of -q makes grep read to EOF: no SIGPIPE, no flake.
has_nvidia()   { lspci 2>/dev/null | grep -i nvidia >/dev/null; }
# nvidia stack wanted? GPU present AND (cond_nvidia=yes forces, =no blocks,
# auto requires ubuntu-drivers to back the card). Legacy GPUs the current
# driver dropped (e.g. Kepler) get nouveau, not a restart-looping 580 stack.
nvidia_wanted() {
  has_nvidia || return 1
  case "$(conf_get cond_nvidia auto)" in
    no)  return 1 ;;
    yes) return 0 ;;
  esac
  ubuntu-drivers devices 2>/dev/null | grep 'nvidia-driver' >/dev/null
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

# apt-get install that NEVER blocks on an interactive prompt. It must be
# non-interactive for two reasons: (1) do_or_say pipes stdout through tee, and
# with sudo's use_pty the conffile prompt's relay can't be answered from the
# terminal — dpkg wedges forever (caught on 24.04: systemd-zram-generator's
# conffile prompt hung the whole run); (2) an unattended "walk away" run must
# never stall. force-confold keeps the on-disk conffile — the kit manages its
# own configs explicitly, not by answering dpkg prompts.
APT_NI=(DEBIAN_FRONTEND=noninteractive apt-get
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
apt_install() { do_or_say sudo "${APT_NI[@]}" install -y "$@"; }

apt_install_one() {
  local pkg="$1"
  pkg_installed "$pkg" && return 0
  # honor the doctor/install split: never mutate in check mode (mirrors do_or_say)
  if (( ${INSTALL:-0} == 0 )); then
    printf '  %s[would]%s apt install %s\n' "$C_DIM" "$C_RST" "$pkg"
    return 0
  fi
  if sudo "${APT_NI[@]}" install -y --no-install-recommends "$pkg" >/dev/null 2>&1; then
    log "installed: $pkg"
  else
    miss "apt: $pkg"
  fi
}
