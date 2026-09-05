#!/bin/bash
# Install apt packages from manifests, per enabled groups + conditionals.
# First install offers a size review (>review_over_mb); deselections are
# recorded in the host conf as skip_pkgs and honored forever after.
SCRIPT_NAME="ws-02-apt-install"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

section "apt packages ($MODE)"

# ---- assemble the wanted-package list -------------------------------------
# Shared with the space preflight (00-disk-space.sh) via lib.sh — one
# definition of "what this host wants", so the preflight's total and this
# transaction can never answer for different package sets. Notes the assembler
# emitted (groups off, conditionals, skips) are replayed here.
apt_want_into WANT notes

# ---- nvidia: nouveau must not grab the GPU at boot --------------------------
# A missed dpkg trigger can leave nouveau loading early and the nvidia module
# unable to bind — driver installed, nvidia-smi dead, persistenced/cdi-refresh
# restart-looping (caught in the wild: GTX 1080, driver 580 built, nouveau on
# the card). We check the actual invariant, generator-agnostic: the blacklist
# conf exists on disk AND nouveau isn't currently loaded. We deliberately do
# NOT introspect the initramfs: lsinitramfs (initramfs-tools) can't read a
# dracut-built image — Ubuntu 26.04 uses dracut, update-initramfs is a shim —
# and the image is 0600 root-only, so the old `lsinitramfs ... | grep` ran
# empty on every pass and regenerated forever, fixing nothing.
# Runs before the early exits below so a converged re-run still checks it;
# a pass-1 missed trigger is caught on pass 2 (bootstrap loops until converged).
if nvidia_wanted && dpkg -l 'nvidia-driver-*' 2>/dev/null | grep -q '^ii'; then
  if grep -rsqE '^[[:space:]]*blacklist[[:space:]]+nouveau' \
       /etc/modprobe.d /usr/lib/modprobe.d /lib/modprobe.d \
     && ! lsmod | grep -q '^nouveau'; then
    ok "nvidia: nouveau blacklisted, not holding the GPU"
  elif (( INSTALL )); then
    warn "nvidia: nouveau not yet excluded — regenerating initramfs"
    sudo update-initramfs -u -k all
    warn "nvidia: REBOOT required before the nvidia driver can take the GPU"
  else
    fail "nvidia: nouveau still able to grab the GPU at boot (blacklist missing or nouveau loaded)"
  fi
fi

# ---- release reconciliation: manifests target 26.04; a box provisioned
# ---- before a package swap needs the old package handled, not fought --------
# (steam's steam-installer/steam-launcher reconciliation is list assembly and
# lives in lib.sh apt_wanted_pkgs; what follows is an ACTION, so it stays here.)
# tldr: tealdeer replaces the Haskell client (tldr/tldr-hs — gone from 26.04,
# and its page downloader is broken upstream). The legacy pair owns
# /usr/bin/tldr via update-alternatives; remove it BEFORE tealdeer lands so
# tealdeer's real /usr/bin/tldr never fights the alternatives symlink.
# (process substitution, not a pipe: grep -q exits at first match, printf's
# SIGPIPE would fail the pipeline under pipefail — a timing-dependent miss)
if grep -Fxq tealdeer < <(printf '%s\n' "${WANT[@]}") && ! pkg_installed tealdeer \
   && { pkg_installed tldr || pkg_installed tldr-hs; }; then
  warn "tldr: legacy Haskell client present — removing (tealdeer replaces it)"
  do_or_say sudo "${APT_NI[@]}" remove -y tldr tldr-hs
fi

# wine: switching WineHQ branch (wine_branch in host conf) is a DELIBERATE swap
# — winehq-<new> conflicts with winehq-<old> AND with Ubuntu's own `wine`, and
# the removal guard below would read either as a manifest pin fighting the box
# and skip the new branch. ONE transaction does the swap: install new, remove
# old and distro wine together. Not two steps — removing wine-stable first left
# winetricks (Depends: wine) unsatisfied, apt auto-installed distro wine 10.0
# to fill it, and that then blocked winehq-devel (2026-09-05). ~/.wine is kept.
WB_WANT="$(printf '%s\n' "${WANT[@]}" | grep -oE '^winehq-(stable|devel|staging)$' | head -1)"
WB_HAVE="$(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 'winehq-*' 2>/dev/null | awk '/^ii /{print $2; exit}')"
if [[ -n "$WB_WANT" ]] && ! pkg_installed "$WB_WANT" \
   && { [[ -n "$WB_HAVE" ]] || pkg_installed wine; }; then
  new="${WB_WANT#winehq-}"; swap=("$WB_WANT" "wine-$new")
  [[ -n "$WB_HAVE" ]] && swap+=("$WB_HAVE-" "wine-${WB_HAVE#winehq-}-")
  pkg_installed wine && swap+=(wine- wine64- libwine-)   # Ubuntu's wine, pulled in as a dep
  warn "wine: switching to branch $new — replacing ${WB_HAVE:-distro wine} in one transaction (prefix ~/.wine untouched)"
  do_or_say sudo "${APT_NI[@]}" install -y --no-install-recommends "${swap[@]}" \
    || miss "wine: branch swap to $new failed — see logs/$SCRIPT_NAME.log"
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
  { printf '  %s\n' "${MISSING[@]}" | head -40
    (( ${#MISSING[@]} > 40 )) && echo "  ... and $(( ${#MISSING[@]} - 40 )) more"; } | extout
  exit 0
fi

# ---- size review (interactive, first install only) --------------------------
REVIEW_MB="$(conf_get review_over_mb 100)"
SKIPS="$(conf_get skip_pkgs "")"      # appended to, not replaced, on deselect
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
for attempt in 1 2 3 4; do
  (( ${#MISSING[@]} )) || break
  log "apt install attempt $attempt (${#MISSING[@]} packages)"
  # HARD GUARD: an install phase must never remove packages. If the resolver
  # wants removals (a manifest pin conflicting with something installed, like
  # a different nvidia driver series), abort THIS transaction loudly — the box
  # keeps working, the human decides. Deliberate removals (tealdeer above)
  # are explicit `remove` commands, never resolver side effects.
  # FAIL CLOSED: if the simulation itself fails (lock held, sources broken,
  # sudo gone) its empty output would show zero removals and wave the real
  # transaction through — the guard would be decorative exactly when the
  # system is already unhealthy. No simulation = no permission to install.
  if ! SIM_OUT="$(sudo apt-get install -s --no-install-recommends "${MISSING[@]}" 2>&1)"; then
    fail "apt dry-run failed — refusing to install blind (can't prove it removes nothing):"
    printf '          %s\n' "$(grep -E '^(E:|Err)' <<<"$SIM_OUT" | head -3)"
    miss "apt: dry-run failed, install skipped — fix apt, then re-run"
    exit 1
  fi
  grep -E '^(After this|[0-9]+ upgraded)' <<<"$SIM_OUT" | sed 's/^/  apt: /' || true
  mapfile -t REMV < <(awk '/^Remv /{print $2}' <<<"$SIM_OUT")
  if (( ${#REMV[@]} )); then
    # The host keeps what it runs. A manifest captured on one box pins choices
    # the HOST makes, not the manifest: its bootloader (grub-pc vs
    # grub-efi-amd64 follows the firmware) and its time daemon (chrony is the
    # 26.04 default; systemd-timesyncd conflicts with it). Installing the pin
    # would remove the live one — so name the wanted package(s) forcing each
    # removal, drop THEM, and let the other N-2 packages install (2026-09-05:
    # two such pins refused all 187 packages, three passes running).
    mapfile -t TRIG < <(apt_conflict_triggers MISSING REMV)
    if (( ${#TRIG[@]} )); then
      warn "apt: ${#TRIG[@]} wanted package(s) conflict with what this box already runs — skipped: ${TRIG[*]}"
      hint "installing them would remove: ${REMV[*]} — add to skip_pkgs in $HOST_CONF to silence"
      miss "apt: skipped ${TRIG[*]} — would remove installed ${REMV[*]} (host keeps what it runs)"
      mapfile -t MISSING < <(printf '%s\n' "${MISSING[@]}" | grep -Fxv -f <(printf '%s\n' "${TRIG[@]}"))
      log "retrying without ${#TRIG[@]} conflicting package(s)"
      continue
    fi
    # Could not attribute (removal via a chain apt won't name) — refuse, loudly.
    fail "apt transaction would REMOVE ${#REMV[@]} installed packages — NOT applying:"
    printf '          %s\n' "${REMV[@]}" | head -20
    miss "apt: refused transaction (would remove: ${REMV[*]:0:6} ...) — resolve by hand or skip_pkgs the trigger"
    exit 1
  fi
  # live counter on one line (fetched / unpacked / configured) — the full
  # transcript goes to the log; the terminal needs to see it is still moving
  "${APT_INSTALL[@]}" "${MISSING[@]}" 2>&1 | tee "$LOG_DIR/apt-install-out.tmp" \
    | awk -v n="$(grep -oE '[0-9]+ newly installed' <<<"$SIM_OUT" | grep -oE '^[0-9]+')" '
        /^Get:/        { g++ } /^Unpacking /  { u++ } /^Setting up / { s++ }
        /^(Get:|Unpacking |Setting up )/ { printf "\r  apt: fetched %d · unpacked %d · configured %d of %s", g, u, s, n; fflush() }
        END { if (g+u+s) print "" }'
  # a failed exit lands in the transcript below; the pipeline's own rc is awk'"'"'s
  grep -E '^E: ' "$LOG_DIR/apt-install-out.tmp" | head -3
  # Installing GPU kernel modules on a LIVE desktop is not inert: once dpkg
  # runs depmod, udev autoloads the new module into the running session —
  # it seizes the framebuffer from the compositor and the GPU can wedge
  # (2026-07-24: both monitors dead ~30s after apt "finished", NVRM watchdog
  # assert, recovered only by reboot). Nothing here can undo that, so say it
  # loudly and do NOT touch the GPU again this run.
  # SIM_OUT (the dry-run above) is authoritative: `Inst nvidia-…` says the
  # transaction really brings in driver/module packages.
  if grep -qE '^Inst (nvidia-|linux-modules-nvidia-|libnvidia-)' <<<"$SIM_OUT"; then
    warn "nvidia kernel packages installed — REBOOT before trusting the GPU"
    hint "a graphical session running now may lose its displays when udev loads the new module; reboot ends it"
    miss "nvidia: driver/module packages installed — reboot required"
  fi
  # Packages that ship udev rules (libccid for the YubiKey, ydotool's uinput,
  # android's adb rules) only govern devices plugged AFTER they land — udev
  # applies rules at add time. Re-apply so what is already plugged gets its
  # group/ACL now (2026-09-05: pcscd LIBUSB_ERROR_ACCESS on a YubiKey plugged
  # 40 minutes before libccid). Cheap, idempotent.
  if grep -q '^Setting up ' "$LOG_DIR/apt-install-out.tmp"; then
    # --action=add: rules like libccid's are gated ACTION=="add"; the default
    # 'change' event would walk past them
    sudo udevadm control --reload 2>/dev/null && sudo udevadm trigger --action=add --subsystem-match=usb --subsystem-match=misc 2>/dev/null \
      && log "udev rules reloaded and re-applied to plugged devices"
  fi
  mapfile -t BAD < <({ grep -oP 'Unable to locate package \K\S+' "$LOG_DIR/apt-install-out.tmp"
                       grep -oP "Package '\K[^']+(?=' has no installation candidate)" "$LOG_DIR/apt-install-out.tmp"
                     } | sort -u)
  # unmet-dependency offenders (indented ' pkg : Depends: ...' lines) abort
  # the ENTIRE transaction — one bad version pin fails all N packages. Prune
  # them like no-candidates and retry so they can't sink the innocent rest.
  # Intersected with MISSING: dep lines can name packages we never asked for.
  mapfile -t UNMET < <(awk '/unmet dependencies:/{f=1;next} f&&/^ [^ ]/{print $1} f&&!/^ /{f=0}' \
                         "$LOG_DIR/apt-install-out.tmp" \
                       | grep -Fxf <(printf '%s\n' "${MISSING[@]}") | sort -u)
  rm -f "$LOG_DIR/apt-install-out.tmp"
  (( ${#BAD[@]} + ${#UNMET[@]} )) || break
  for p in "${BAD[@]}"; do miss "apt: $p (no candidate)"; done
  for p in "${UNMET[@]}"; do miss "apt: $p (unmet dependencies — pruned so the rest can install)"; done
  BAD+=("${UNMET[@]}")
  mapfile -t MISSING < <(printf '%s\n' "${MISSING[@]}" | grep -Fxv -f <(printf '%s\n' "${BAD[@]}"))
  log "retrying without ${#BAD[@]} unavailable packages"
done

# every survivor that still isn't installed goes to missing.log — the FAIL
# below points there, so the file must actually name them
left=0
for p in "${MISSING[@]}"; do
  pkg_installed "$p" && continue
  ((left++)); miss "apt: $p (still missing after ${attempt} attempt(s))"
done
if (( left )); then
  fail "$left packages still missing — see $LOG_DIR/missing.log"
else
  ok "all requested packages installed"
fi
