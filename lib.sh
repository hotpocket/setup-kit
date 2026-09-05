#!/bin/bash
# Shared helpers for setup-kit. Source from each script:
#   source "$(dirname "$0")/../../lib.sh"   (profile scripts)
#   source "$(dirname "$0")/../lib.sh"      (capture scripts)

set -uo pipefail   # no -e: we log misses, we don't abort

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAPSHOT_DIR="$KIT_DIR/snapshot"
MANIFEST_DIR="$KIT_DIR/manifests"
LOG_DIR="$KIT_DIR/logs"
# Per-host answer file. Overridable by the environment so the phases can be
# exercised against a throwaway conf (tests/) without touching a real one.
HOST_CONF="${HOST_CONF:-$KIT_DIR/hosts/$(hostname).conf}"

mkdir -p "$LOG_DIR"

# ---------------------------------------------------------------- output
if [[ -t 1 ]]; then
  C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_FAIL=$'\e[31m'; C_HDR=$'\e[1m'; C_DIM=$'\e[2m'; C_RST=$'\e[0m'
else
  C_OK=''; C_WARN=''; C_FAIL=''; C_HDR=''; C_DIM=''; C_RST=''
fi
DOCTOR_WARN=0; DOCTOR_FAIL=0

# Quiet mode (under bootstrap: KIT_RUN_LOG set, KIT_VERBOSE unset): pytest-style
# progress marks — '.' ok, '!' warn, 'x' fail — written straight to the tty so
# the tee'd run log stays clean. Full detail lines go to the run log, and the
# bootstrap summary replays every unique WARN/FAIL at the end (the report).
# Actions (log/do_or_say) still print inline on their own lines, breaking the
# mark stream. KIT_VERBOSE=1 (bootstrap -v, or verbose=yes in host conf) and
# standalone phase runs: full per-line output, no marks.
KIT_QUIET=0
[[ -n "${KIT_RUN_LOG:-}" && "${KIT_VERBOSE:-0}" != 1 ]] && KIT_QUIET=1
DOTS=0
_mark()       { { printf '%s' "$1" > /dev/tty; } 2>/dev/null || true; DOTS=1; }
_break_dots() { (( DOTS )) && { { printf '\n' > /dev/tty; } 2>/dev/null || true; }; DOTS=0; }
_rlog()       { printf '%s\n' "$*" >> "$KIT_RUN_LOG"; }
trap _break_dots EXIT

section() {
  if (( KIT_QUIET )); then _rlog ""; _rlog "$*"
  else printf '\n%s%s%s\n' "$C_HDR" "$*" "$C_RST"; fi
}
ok() {
  if (( KIT_QUIET )); then _rlog "  [ OK ]  $*"; _mark '.'
  else printf '  %s[ OK ]%s  %s\n' "$C_OK" "$C_RST" "$*"; fi
}
warn() {
  if (( KIT_QUIET )); then _rlog "  [WARN]  $*"; _mark '!'
  else printf '  %s[WARN]%s  %s\n' "$C_WARN" "$C_RST" "$*"; fi
  DOCTOR_WARN=$((DOCTOR_WARN+1))
}
fail() {
  if (( KIT_QUIET )); then _rlog "  [FAIL]  $*"; _mark 'x'
  else printf '  %s[FAIL]%s  %s\n' "$C_FAIL" "$C_RST" "$*"; fi
  DOCTOR_FAIL=$((DOCTOR_FAIL+1))
}
hint() {
  if (( KIT_QUIET )); then _rlog "          ↳ $*"
  else printf '          %s↳ %s%s\n' "$C_DIM" "$*" "$C_RST"; fi
}

log() {
  local msg="[$(date -Iseconds)] $*"
  (( KIT_QUIET )) && _break_dots
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
# Under bootstrap (quiet mode) the command's own output goes to the script log
# only; the terminal sees the "+ cmd" line and, when the command FAILS, its
# last lines and exit code. Standalone/verbose runs stream everything. (A fresh
# VM install printed every apt transcript and installer banner — thousands of
# lines that hid the four that mattered.)
do_or_say() {
  if (( INSTALL )); then
    log "+ $*"
    local slog="$LOG_DIR/${SCRIPT_NAME:-unknown}.log" rc
    if (( KIT_QUIET )); then
      "$@" >> "$slog" 2>&1; rc=$?
      if (( rc )); then
        printf '  %s[FAILED]%s exit %s — last output lines:\n' "$C_FAIL" "$C_RST" "$rc"
        tail -n 8 "$slog" | sed 's/^/    | /'
      fi
      return "$rc"
    fi
    "$@" 2>&1 | tee -a "$slog"
    return "${PIPESTATUS[0]}"
  else
    (( KIT_QUIET )) && _break_dots
    printf '  %s[would]%s %s\n' "$C_DIM" "$C_RST" "$*"
  fi
}

# External-tool output (flutter doctor, .configs setup.sh, listings): always
# captured in the script log; shown on the terminal only in verbose mode.
#   some_tool 2>&1 | extout
extout() {
  tee -a "$LOG_DIR/${SCRIPT_NAME:-unknown}.log" \
    | { if (( KIT_QUIET )); then cat >/dev/null; else cat; fi; }
}

# ---------------------------------------------------------------- host conf
# Answer file: KEY=value lines. conf_get KEY DEFAULT
# A value written with quotes (claude_skills="gstack vault conduct") comes back
# without them: the conf is not sourced by a shell, so nothing else would strip
# them, and a quote glued to the first and last word is how phase 08 went
# looking for skills named '"gstack' and 'conduct"' (2026-09-05).
conf_get() {
  local v
  v=$(grep -E "^${1}=" "$HOST_CONF" 2>/dev/null | tail -1 | cut -d= -f2- \
      | sed 's/[[:space:]]*#.*//; s/[[:space:]]*$//; s/^"\(.*\)"$/\1/; s/^'"'"'\(.*\)'"'"'$/\1/')
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
# Is the nvidia kernel module ALREADY loaded? /proc/driver/nvidia exists only
# once it is, so reading it cannot load anything. Never probe with `nvidia-smi`
# alone: where nvidia-modprobe is installed (setuid root) it INSERTS the module,
# and inserting a GPU module into a live desktop seizes the framebuffer
# (2026-07-24: both monitors dead until reboot). Gate every nvidia-smi call.
nvidia_live()  { [[ -r /proc/driver/nvidia/version ]]; }
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

# ---------------------------------------------------------------- sizes
# Human size -> KiB. Accepts "9G", "205MB", "18.4 GB", "991kB"; a bare number
# is KiB (apt's Installed-Size unit). Unknown/garbage -> 0, never an error:
# a bad row in sizes.conf must not sink the whole preflight.
to_kb() {
  local s n u
  s="${1//[[:space:]]/}"
  [[ -n "$s" ]] || { echo 0; return; }
  n="${s%%[A-Za-z]*}"; u="${s#"$n"}"; u="${u^^}"; u="${u%B}"
  [[ "$n" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { echo 0; return; }
  case "$u" in
    ''|K) awk -v n="$n" 'BEGIN{printf "%.0f", n}' ;;
    M)    awk -v n="$n" 'BEGIN{printf "%.0f", n*1024}' ;;
    G)    awk -v n="$n" 'BEGIN{printf "%.0f", n*1024*1024}' ;;
    T)    awk -v n="$n" 'BEGIN{printf "%.0f", n*1024*1024*1024}' ;;
    *)    echo 0 ;;
  esac
}

# KiB -> short human string ("18.4G", "412G", "0")
kb_human() {
  awk -v k="${1:-0}" 'BEGIN{
    split("K M G T P", u, " "); i = 1
    while (k >= 1024 && i < 5) { k /= 1024; i++ }
    if (i == 1) printf "%dK", k
    else if (k < 100) printf "%.1f%s", k, u[i]
    else printf "%.0f%s", k, u[i]
  }'
}

# "<mountpoint>\t<free KiB>" for the filesystem that will hold PATH. Walks up
# to the nearest EXISTING ancestor: the target dir usually doesn't exist yet
# (that's the point — we're asked whether to create it), and df on a missing
# path answers nothing at all.
fs_stats() {
  local p="${1:-/}"
  while [[ ! -e "$p" && "$p" != / && "$p" != . ]]; do p="$(dirname "$p")"; done
  df -Pk "$p" 2>/dev/null | awk 'NR==2{print $6"\t"$4}'
}

# ------------------------------------------------- wanted package selection
# The apt package set this host wants: default groups + optional groups turned
# on in the host conf + hardware conditionals, minus permanent skip_pkgs and
# release-reconciliation exclusions.
#
# ONE definition, two callers — the installer (02-apt-install.sh) and the space
# preflight (00-disk-space.sh). A preflight that estimated from its own copy of
# this logic would answer for a different package set than the one that
# actually installs, and would drift further at every manifest change.
#
# Prints one package name per line. Commentary can't go through ok()/warn():
# stdout IS the list, and callers read it in a subshell where globals don't
# survive. So notes ride inline as '@ok '/'@warn '/'@log ' lines for the
# caller to replay (the installer) or drop (the preflight).
APT_DEFAULT_GROUPS="cli-system desktop apps editors media network games wine
                    dev-core dev-java dev-python dev-cloud dev-flutter-deps"
apt_wanted_pkgs() {
  local APT_M="$MANIFEST_DIR/apt" grp f p WANT=() PIN_DRV CUR_DRV SKIPS
  for grp in $APT_DEFAULT_GROUPS; do
    group_on "$grp" || { echo "@ok group $grp: off"; continue; }
    [[ -f "$APT_M/$grp.list" ]] || { echo "@warn no manifest for $grp"; continue; }
    mapfile -t -O "${#WANT[@]}" WANT < <(manifest_pkgs "$APT_M/$grp.list")
  done
  # optional groups (off unless flipped in host conf)
  for f in "$APT_M"/optional/*.list; do
    [[ -f "$f" ]] || continue
    grp="$(basename "$f" .list)"
    group_on "$grp" || continue
    echo "@log optional group enabled: $grp"
    mapfile -t -O "${#WANT[@]}" WANT < <(manifest_pkgs "$f")
  done
  # conditional: nvidia
  if nvidia_wanted; then
    mapfile -t -O "${#WANT[@]}" WANT < <(manifest_pkgs "$APT_M/conditional/nvidia.list")
    echo "@ok conditional nvidia: supported GPU detected — included"
    # A working driver of ANY version satisfies the driver requirement. The
    # manifest's exact pin is only for boxes with NO driver: installing a
    # different series over a live one makes apt REMOVE the running stack —
    # userspace swaps immediately but the old kernel module stays loaded, so
    # GL/NVML die until reboot (caught 2026-07-24: pin 580 vs running 595
    # removed 17 packages mid-session and broke OpenGL for every app).
    # dpkg-query, not `dpkg -l`: the latter formats to terminal width and can
    # truncate long package names (nvidia-driver-595-open-kernel-source-…).
    PIN_DRV="$(printf '%s\n' "${WANT[@]}" | grep -m1 -E '^nvidia-driver-[0-9]+' || true)"
    CUR_DRV="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'nvidia-driver-*' 2>/dev/null \
               | awk '/^ii /{print $2; exit}')"
    if [[ -n "$PIN_DRV" && -n "$CUR_DRV" && "$PIN_DRV" != "$CUR_DRV" ]]; then
      mapfile -t WANT < <(printf '%s\n' "${WANT[@]}" | grep -Fxv "$PIN_DRV")
      echo "@ok nvidia: $CUR_DRV already active — working driver satisfies manifest ($PIN_DRV not forced)"
    fi
  elif has_nvidia && [[ "$(conf_get cond_nvidia auto)" != no ]]; then
    echo "@warn conditional nvidia: GPU present but unsupported by current driver (legacy card) — skipped, nouveau it is"
  else
    echo "@ok conditional nvidia: skipped"
  fi
  # conditional: virtualbox
  if ! is_vm && ! dpkg -s proxmox-ve >/dev/null 2>&1 \
     && [[ "$(conf_get cond_virtualbox auto)" != no ]]; then
    mapfile -t -O "${#WANT[@]}" WANT < <(manifest_pkgs "$APT_M/conditional/virtualbox.list")
    echo "@ok conditional virtualbox: bare metal — included"
  else
    echo "@ok conditional virtualbox: skipped ($(virt_context))"
  fi
  # permanent skips recorded by the size review
  SKIPS="$(conf_get skip_pkgs "")"
  if [[ -n "$SKIPS" && ${#WANT[@]} -gt 0 ]]; then
    mapfile -t WANT < <(printf '%s\n' "${WANT[@]}" | grep -Fxv -f <(tr ' ' '\n' <<<"$SKIPS"))
    echo "@ok honoring skip_pkgs: $SKIPS"
  fi
  # release reconciliation — steam: a box already running Valve's
  # steam-launcher (self-managed repo) has steam-libs newer than the exact
  # version multiverse's steam-installer pins; installing it is an unmet-dep
  # abort that sinks the WHOLE apt transaction (caught on 24.04: steam-libs-i386
  # 1.0.0.85 installed, = 1.0.0.79~ds-2 required). Valve keeps itself updated;
  # never migrate an existing install.
  if pkg_installed steam-launcher && (( ${#WANT[@]} )); then
    mapfile -t WANT < <(printf '%s\n' "${WANT[@]}" | grep -Fxv steam-installer)
    echo "@ok steam: Valve steam-launcher installed — steam-installer not applicable"
  fi
  (( ${#WANT[@]} )) && printf '%s\n' "${WANT[@]}"
  return 0
}

# Split apt_wanted_pkgs output: package names into the array named by $1,
# '@' note lines replayed through ok()/warn()/log() when $2 is 'notes'.
apt_want_into() {
  local -n _out="$1"; local notes="${2:-quiet}" row
  _out=()
  while IFS= read -r row; do
    case "$row" in
      '@ok '*)   [[ "$notes" == notes ]] && ok   "${row#@ok }"   ;;
      '@warn '*) [[ "$notes" == notes ]] && warn "${row#@warn }" ;;
      '@log '*)  [[ "$notes" == notes ]] && log  "${row#@log }"  ;;
      '') ;;
      *) _out+=("$row") ;;
    esac
  done < <(apt_wanted_pkgs)
  return 0
}

# Of the given package names, the ones apt can actually install on THIS release
# — a real candidate version exists. Names that were dropped between releases
# (wireless-tools on 26.04) or that survive only as a reference from another
# package's dependency (tldr) abort an entire apt transaction, INCLUDING a
# dry-run: one bad name and the simulation answers nothing at all, so the space
# preflight has to prune before it asks. `apt-cache policy` on an unknown name
# prints nothing, so both failure shapes fall out of the same filter.
# (02-apt-install.sh keeps its own retry loop instead: it must report each drop
# to missing.log with a reason, and a candidate can still vanish mid-run.)
apt_installable() {
  (( $# )) || return 0
  apt-cache policy "$@" 2>/dev/null \
    | awk '/^[^ ]/ { p = $0; sub(/:$/, "", p) } /^  Candidate:/ { if ($2 != "(none)") print p }'
}

# ------------------------------------------------ removal attribution
# apt_conflict_triggers WANT_ARRAY REMV_ARRAY -> wanted package names that make
# apt's resolver remove the packages in REMV. Method: re-simulate the same
# transaction with the to-be-removed packages ALSO pinned as wanted; apt can no
# longer resolve by removal, so it prints the conflict as "unmet dependencies"
# naming BOTH sides (chrony : Conflicts: time-daemon / systemd-timesyncd :
# Conflicts: time-daemon). The offenders intersected with WANT are the
# triggers. Virtual packages (time-daemon) and dependency chains (grub-pc ->
# grub-pc-bin) are apt's problem, not ours — that is why the resolver, not a
# Conflicts-field parse, does the attribution. Empty output = could not
# attribute; the caller must then refuse, not guess. Simulation needs no root.
apt_conflict_triggers() {
  local -n _want="$1"; local -n _remv="$2"
  (( ${#_remv[@]} && ${#_want[@]} )) || return 0
  apt-get install -s --no-install-recommends "${_want[@]}" "${_remv[@]}" 2>&1 \
    | awk '/unmet dependencies:/{f=1;next} f&&/^ [^ ]/{print $1} f&&!/^ /{f=0}' \
    | grep -Fxf <(printf '%s\n' "${_want[@]}") | sort -u
  return 0
}

# ------------------------------------------------ github release assets
# gh_pick_asset <suffix-regex>  (releases JSON on stdin: /repos/X/releases)
# URL of the matching asset in the NEWEST non-prerelease, non-draft release
# that has one. /releases/latest is the wrong question: a project that ships
# mobile and desktop from one release stream (obsidian) can have a latest with
# only an .apk, one release above the .deb (2026-09-05). Exit 1 when none.
gh_pick_asset() {
  python3 -c '
import sys, json, re
suf = re.compile(sys.argv[1] + "$")
try:
    rels = json.load(sys.stdin)
except Exception:
    sys.exit(1)
for r in rels if isinstance(rels, list) else []:
    if r.get("prerelease") or r.get("draft"):
        continue
    for a in r.get("assets", []):
        u = a.get("browser_download_url", "")
        if suf.search(u):
            print(u); sys.exit(0)
sys.exit(1)' "$1"
}
