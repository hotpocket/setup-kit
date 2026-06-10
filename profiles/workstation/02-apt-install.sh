#!/bin/bash
# Install apt packages from manifests, per enabled groups + conditionals.
# First install offers a size review (>review_over_mb); deselections are
# recorded in the host conf as skip_pkgs and honored forever after.
SCRIPT_NAME="ws-02-apt-install"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

APT_M="$MANIFEST_DIR/apt"
DEFAULT_GROUPS="cli-system desktop apps editors media network games wine
                dev-core dev-java dev-python dev-cloud dev-flutter-deps"

section "apt packages ($MODE)"

# ---- assemble the wanted-package list -------------------------------------
WANT=()
for grp in $DEFAULT_GROUPS; do
  group_on "$grp" || { ok "group $grp: off"; continue; }
  [[ -f "$APT_M/$grp.list" ]] || { warn "no manifest for $grp"; continue; }
  mapfile -t -O "${#WANT[@]}" WANT < <(manifest_pkgs "$APT_M/$grp.list")
done
# optional groups (off unless flipped in host conf)
for f in "$APT_M"/optional/*.list; do
  grp="$(basename "$f" .list)"
  group_on "$grp" || continue
  log "optional group enabled: $grp"
  mapfile -t -O "${#WANT[@]}" WANT < <(manifest_pkgs "$f")
done
# conditional groups
if nvidia_wanted; then
  mapfile -t -O "${#WANT[@]}" WANT < <(manifest_pkgs "$APT_M/conditional/nvidia.list")
  ok "conditional nvidia: supported GPU detected — included"
elif has_nvidia && [[ "$(conf_get cond_nvidia auto)" != no ]]; then
  warn "conditional nvidia: GPU present but unsupported by current driver (legacy card) — skipped, nouveau it is"
else
  ok "conditional nvidia: skipped"
fi
if ! is_vm && ! dpkg -s proxmox-ve >/dev/null 2>&1 \
   && [[ "$(conf_get cond_virtualbox auto)" != no ]]; then
  mapfile -t -O "${#WANT[@]}" WANT < <(manifest_pkgs "$APT_M/conditional/virtualbox.list")
  ok "conditional virtualbox: bare metal — included"
else
  ok "conditional virtualbox: skipped ($(virt_context))"
fi

# ---- nvidia: the nouveau blacklist must be IN the initramfs ------------------
# dpkg triggers normally regenerate it when the driver installs, but a missed
# trigger leaves nouveau loading early at boot and the nvidia module unable to
# bind — driver installed, nvidia-smi dead, persistenced/cdi-refresh restart-
# looping (caught in the wild: GTX 1080, driver 580 built, nouveau on the card).
# Runs before the early exits below so a converged re-run still checks it;
# a pass-1 missed trigger is caught on pass 2 (bootstrap loops until converged).
if nvidia_wanted && dpkg -l 'nvidia-driver-*' 2>/dev/null | grep -q '^ii'; then
  # no grep -q: early exit SIGPIPEs lsinitramfs and pipefail fails the match
  if lsinitramfs "/boot/initrd.img-$(uname -r)" 2>/dev/null \
       | grep 'nvidia-graphics-drivers\.conf' >/dev/null; then
    ok "nvidia: nouveau blacklist present in initramfs"
  elif (( INSTALL )); then
    warn "nvidia: nouveau blacklist missing from initramfs — regenerating"
    sudo update-initramfs -u -k all
    warn "nvidia: REBOOT required before the nvidia driver can take the GPU"
  else
    fail "nvidia: nouveau blacklist missing from initramfs (stale — nouveau will grab the GPU at boot)"
  fi
fi

# ---- subtract permanent skips ----------------------------------------------
SKIPS="$(conf_get skip_pkgs "")"
if [[ -n "$SKIPS" ]]; then
  mapfile -t WANT < <(printf '%s\n' "${WANT[@]}" | grep -Fxv -f <(tr ' ' '\n' <<<"$SKIPS"))
  ok "honoring skip_pkgs: $SKIPS"
fi

# ---- what's missing ---------------------------------------------------------
MISSING=()
for p in "${WANT[@]}"; do
  pkg_installed "$p" || MISSING+=("$p")
done
if (( ${#MISSING[@]} == 0 )); then
  ok "all ${#WANT[@]} wanted packages installed"
  exit 0
fi
warn "${#MISSING[@]} of ${#WANT[@]} wanted packages not installed"
if (( ! INSTALL )); then
  printf '  %s\n' "${MISSING[@]}" | head -40
  (( ${#MISSING[@]} > 40 )) && echo "  ... and $(( ${#MISSING[@]} - 40 )) more"
  exit 0
fi

# ---- size review (interactive, first install only) --------------------------
REVIEW_MB="$(conf_get review_over_mb 100)"
if [[ -t 0 && "$(conf_get size_review_done no)" != yes ]]; then
  BIG=()
  for p in "${MISSING[@]}"; do
    sz=$(apt-cache --no-all-versions show "$p" 2>/dev/null \
         | awk '/^Installed-Size:/{print int($2/1024); exit}')
    (( ${sz:-0} >= REVIEW_MB )) && BIG+=("$p:$sz")
  done
  if (( ${#BIG[@]} )); then
    section "size review — packages over ${REVIEW_MB} MB"
    i=0
    for e in "${BIG[@]}"; do
      printf '  %2d) %-40s %s MB\n' $((++i)) "${e%%:*}" "${e##*:}"
    done
    # 120s timeout → install all: a walked-away-from run must never stall here
    read -t 120 -rp "numbers to SKIP (space-separated, enter/timeout = install all): " nums || { nums=""; echo; }
    newskips=""
    for n in $nums; do
      [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#BIG[@]} )) || continue
      e="${BIG[$((n-1))]}"; newskips+=" ${e%%:*}"
    done
    if [[ -n "$newskips" ]]; then
      conf_set skip_pkgs "$(echo "$SKIPS$newskips" | xargs)"
      mapfile -t MISSING < <(printf '%s\n' "${MISSING[@]}" \
        | grep -Fxv -f <(tr ' ' '\n' <<<"$(echo "$newskips" | xargs)"))
      log "skipping:$newskips"
    fi
  fi
  conf_set size_review_done yes
fi

# ---- sanity: if apt can't even read its sources (e.g. a Signed-By conflict
# ---- like a bad steam repo), every name would look unknown — abort loud
KNOWN_COUNT=$(apt-cache pkgnames 2>/dev/null | wc -l)
if (( KNOWN_COUNT < 10000 )); then
  fail "apt index unreadable ($KNOWN_COUNT names) — fix sources first: apt-get update"
  apt-get update 2>&1 | grep -E '^(E:|Err)' | head -3
  exit 1
fi

# ---- drop names this release doesn't know (one bad name aborts the whole
# ---- apt transaction — e.g. wireless-tools, dropped on 26.04).
# awk set-membership, NOT sort|comm: Ubuntu 26.04's uutils sort and comm
# disagree on locale collation, which silently misclassified every package.
mapfile -t UNKNOWN < <(apt-cache pkgnames \
  | awk 'NR==FNR{want[$1];next} {delete want[$1]} END{for (p in want) print p}' \
        <(printf '%s\n' "${MISSING[@]}") -)
if (( ${#UNKNOWN[@]} )); then
  for p in "${UNKNOWN[@]}"; do miss "apt: $p (unknown on $(. /etc/os-release && echo "$VERSION_ID"))"; done
  mapfile -t MISSING < <(printf '%s\n' "${MISSING[@]}" | grep -Fxv -f <(printf '%s\n' "${UNKNOWN[@]}"))
  warn "${#UNKNOWN[@]} packages unknown on this release — logged, skipping"
fi

# ---- debconf preseeds: EULA/license dialogs answered up front so the bulk
# ---- install never stalls on a prompt (the kit's own prompts — size review,
# ---- components — stay interactive; package dialogs do not)
if (( INSTALL )); then
  sudo debconf-set-selections <<'PRESEED'
ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true
steam steam/question select I AGREE
steam steam/license note
steamcmd steam/question select I AGREE
steamcmd steam/license note
PRESEED
fi
# noninteractive frontend + keep-existing-conffiles: no mid-run dpkg dialogs
APT_INSTALL=(sudo DEBIAN_FRONTEND=noninteractive apt-get
             -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
             install -y --no-install-recommends)

# ---- preflight + install, retrying around no-candidate packages --------------
for attempt in 1 2 3; do
  (( ${#MISSING[@]} )) || break
  log "apt install attempt $attempt (${#MISSING[@]} packages)"
  sudo apt-get install -s --no-install-recommends "${MISSING[@]}" 2>&1 \
    | grep -E '^(After this|[0-9]+ upgraded)' || true
  "${APT_INSTALL[@]}" "${MISSING[@]}" \
    2>&1 | tee "$LOG_DIR/apt-install-out.tmp" | tail -3
  mapfile -t BAD < <({ grep -oP 'Unable to locate package \K\S+' "$LOG_DIR/apt-install-out.tmp"
                       grep -oP "Package '\K[^']+(?=' has no installation candidate)" "$LOG_DIR/apt-install-out.tmp"
                     } | sort -u)
  rm -f "$LOG_DIR/apt-install-out.tmp"
  (( ${#BAD[@]} )) || break
  for p in "${BAD[@]}"; do miss "apt: $p (no candidate)"; done
  mapfile -t MISSING < <(printf '%s\n' "${MISSING[@]}" | grep -Fxv -f <(printf '%s\n' "${BAD[@]}"))
  log "retrying without ${#BAD[@]} unavailable packages"
done

left=0
for p in "${MISSING[@]}"; do pkg_installed "$p" || ((left++)); done
if (( left )); then
  fail "$left packages still missing — see $LOG_DIR/missing.log"
else
  ok "all requested packages installed"
fi
