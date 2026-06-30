#!/usr/bin/env bash
# setup-kit entry point — provision a machine to work the way Brandon expects.
#
#   ./bootstrap.sh survey                  # read-only hardware report (live-CD friendly)
#   ./bootstrap.sh workstation [check]     # doctor: report what's missing, change nothing
#   ./bootstrap.sh workstation install     # provision (prompts once, records answers)
#   ./bootstrap.sh proxmox-host install    # IOMMU/VFIO/ZFS/nested-virt + VM creation
#   ./bootstrap.sh list                    # every group/component flag + its current value
#
# Answers live in hosts/$(hostname).conf — re-runs are non-interactive and
# idempotent; flip a group/component there and re-run install to add it.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$KIT_DIR/lib.sh"

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# Catalog of every toggleable group_/component_ flag, from the example.conf
# template (its inline comments are the descriptions), annotated with each
# flag's CURRENT value in this host's conf. The way to discover what's
# installable after first run: flip a 'no' to 'yes' here, re-run install.
list_components() {
  local tmpl="$KIT_DIR/hosts/example.conf"
  [[ -f "$tmpl" ]] || { echo "no template at $tmpl"; exit 1; }
  [[ -f "$HOST_CONF" ]] && echo "host conf: $HOST_CONF" \
                        || echo "host conf: (none yet — showing template defaults)"
  # Print one annotated row per template line whose key matches $1 (an
  # extended-regex prefix alternation). Tolerates `# key=val` lines (commented
  # cond_* defaults) by stripping a leading comment marker first.
  _list_rows() {
    local line key def cur desc
    while IFS= read -r line; do
      line="${line#\# }"                                      # uncomment cond_* defaults
      [[ "$line" =~ ^($1)[a-z0-9_]+= ]] || continue
      key="${line%%=*}"
      def="${line#*=}"; def="${def%%#*}"; def="${def//\"/}"; def="${def// /}"
      desc=""; [[ "$line" == *"#"* ]] && desc="${line#*#}"
      cur="$(conf_get "$key" "$def")"
      printf '  %s[%-4s]%s  %-26s %s%s%s\n' \
        "$([[ "$cur" =~ ^(yes|auto)$ || ( "$cur" != no && -n "$cur" ) ]] && echo "$C_OK" || echo "$C_DIM")" \
        "$cur" "$C_RST" "$key" "$C_DIM" "${desc# }" "$C_RST"
    done < "$tmpl"
  }
  section "groups & components — configurable on/off ([cur] = value in host conf)"
  _list_rows 'group_|component_'
  section "language stacks — configurable"
  _list_rows 'lang_'
  section "conditional — INFORMATIONAL, resolved by hardware detection (override only to force)"
  _list_rows 'cond_'
  echo
  echo "  flip a value in $HOST_CONF, then: ./bootstrap.sh workstation install"
}

cmd="${1:-}"; mode="${2:-check}"
case "$cmd" in
  survey)
    # Stage 0 — qualify hardware before committing to an install.
    echo "=== setup-kit hardware survey: $(hostname) ==="
    echo "--- CPU virt ---"
    grep -qE 'svm|vmx' /proc/cpuinfo && echo "OK: virtualization flags present" \
      || echo "FAIL: no svm/vmx — no KVM, no android emulator, no proxmox"
    echo "--- /dev/kvm ---"
    [[ -e /dev/kvm ]] && echo "OK: /dev/kvm present" \
      || echo "MISSING: bare metal→enable virt in BIOS; Proxmox VM→nested virt (profiles/proxmox-host/05-nested-virt.sh); LXC→device passthrough"
    echo "--- virtualization context ---"
    echo "systemd-detect-virt: $(systemd-detect-virt 2>/dev/null || true)"
    echo "--- GPUs ---"
    lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || echo "(lspci unavailable)"
    echo "--- IOMMU groups (passthrough quality) ---"
    if [[ -d /sys/kernel/iommu_groups ]] && ls /sys/kernel/iommu_groups/ &>/dev/null; then
      for g in /sys/kernel/iommu_groups/*/devices/*; do
        echo "group ${g#/sys/kernel/iommu_groups/}" | sed 's|/devices/| |'
      done | sort -V | head -40
    else
      echo "IOMMU disabled — boot with amd_iommu=on/intel_iommu=on to evaluate passthrough"
    fi
    echo "--- disks ---"
    lsblk -d -o NAME,MODEL,SERIAL,SIZE -e7
    echo "--- NICs ---"
    ip -br link | grep -v '^lo'
    ;;

  workstation)
    [[ "$mode" == doctor ]] && mode=check   # alias — same thing
    case "$mode" in check|install) ;; *) usage ;; esac
    # first run: create the host answer file from the template
    if [[ ! -f "$HOST_CONF" ]]; then
      cp "$KIT_DIR/hosts/example.conf" "$HOST_CONF"
      echo "Created $HOST_CONF from template."
      if [[ -t 0 && "$mode" == install ]]; then
        read -rp "Review/edit it now? [Y/n] " a
        [[ "$a" =~ ^[Nn] ]] || "${EDITOR:-nano}" "$HOST_CONF"
      else
        echo "Defaults will be used — edit it to change groups/components."
      fi
    fi
    # first interactive install: present the opt-in group menu once.
    # Defaults (already on) are the dev-on-a-VM set; this lists the rest.
    if [[ -t 0 && "$mode" == install && "$(conf_get groups_selected no)" != yes ]]; then
      OPTIN=(media wine games printing dev_db dev_php dev_rust dev_go dev_r)
      section "optional groups (dev + GUI defaults already on)"
      i=0
      for g in "${OPTIN[@]}"; do
        printf '  %2d) %-10s [%s]\n' $((++i)) "${g//_/-}" "$(conf_get "group_$g" no)"
      done
      read -rp "numbers to toggle ON (space-separated, enter = none): " nums || nums=""
      for n in $nums; do
        [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#OPTIN[@]} )) || continue
        conf_set "group_${OPTIN[$((n-1))]}" yes
      done
      conf_set groups_selected yes
    fi
    # one sudo upfront so phases don't stall on password prompts mid-run.
    # NB: don't gate on bare `sudo -v` — with verifypw=all it demands a
    # password even when NOPASSWD covers every command.
    if [[ "$mode" == install ]]; then
      sudo -n true 2>/dev/null || sudo -v || { echo "sudo required"; exit 1; }
      ( while true; do sleep 50; sudo -n true 2>/dev/null || exit; done ) &
      SUDO_KEEPALIVE=$!
      trap '[[ -n "${SUDO_KEEPALIVE:-}" ]] && kill "$SUDO_KEEPALIVE" 2>/dev/null' EXIT
    fi
    # Front-load the REST of the interaction here (GitHub host keys, YubiKey
    # PIN + touches, .configs clone) — after this, the phase loop is unaided.
    # Deliberately not piped: it needs the tty for PIN/touch prompts.
    chmod +x "$KIT_DIR/profiles/workstation/preamble-github-auth.sh" 2>/dev/null || true
    bash "$KIT_DIR/profiles/workstation/preamble-github-auth.sh" "$mode" || true
    # install mode loops passes until a pass changes nothing, then runs the
    # independent verifier — one command does the whole job.
    rc=0; settled=0
    for pass in 1 2 3; do
      RUN_LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S)-p$pass.log"
      for phase in "$KIT_DIR/profiles/workstation/"[0-9][0-9]*-*.sh; do
        bash "$phase" "$mode" 2>&1 | tee -a "$RUN_LOG"
        [[ "${PIPESTATUS[0]}" -eq 0 ]] || rc=1
      done
      # summary that answers "did anything change?" from stdout alone
      n_ok=$(grep -c '\[ OK \]'   "$RUN_LOG" || true)
      n_warn=$(grep -c '\[WARN\]' "$RUN_LOG" || true)
      n_fail=$(grep -c '\[FAIL\]' "$RUN_LOG" || true)
      # actions = do_or_say invocations, kit "installed:" log lines, apt runs —
      # NOT phrases like "already installed" from chained tools
      n_act=$(grep -cE '\] \+ |^\[[0-9T:.+-]+\] installed: |apt install attempt' "$RUN_LOG" || true)
      section "summary — $(hostname) ($mode, pass $pass)"
      echo "  ok: $n_ok   warn: $n_warn   fail: $n_fail   actions: $n_act"
      # surface WHAT failed/warned, not just the counts — last occurrence of
      # each unique message (later passes supersede earlier ones)
      if (( n_fail > 0 )); then
        echo "  FAIL:"
        grep '\[FAIL\]' "$RUN_LOG" | sed 's/.*\[FAIL\]  *//' | awk '!seen[$0]++' | sed 's/^/    ✗ /'
      fi
      if (( n_warn > 0 )); then
        echo "  WARN:"
        grep '\[WARN\]' "$RUN_LOG" | sed 's/.*\[WARN\]  *//' | awk '!seen[$0]++' | sed 's/^/    ! /'
      fi
      [[ "$mode" == check ]] && { echo "  doctor only — 'install' applies. Full log: $RUN_LOG"; break; }
      if (( n_act == 0 )); then
        if (( n_warn == 0 && n_fail == 0 )); then
          echo "  ✔ CONVERGED — nothing to change; system matches the manifests"
        else
          echo "  ✔ stable — no actions left; remaining warn/fail need a human"
          echo "    (see profiles/workstation/99-manual-checklist.md)"
        fi
        settled=1
        break
      fi
      echo "  changes applied — running another pass..."
    done
    if [[ "$mode" == install ]]; then
      (( settled )) || { echo "  ⚠ NOT converged after $pass passes — still applying changes; re-run install"; rc=1; }
      [[ -s "$LOG_DIR/missing.log" ]] && echo "  Misses to triage: $LOG_DIR/missing.log"
      section "independent verification (verify.sh)"
      "$KIT_DIR/verify.sh" --settle 30 | grep -E '^(FAIL|===|    )'
      # verify's own exit code (not grep's) folds into the run result
      [[ "${PIPESTATUS[0]}" -eq 0 ]] || rc=1
    fi
    exit "$rc"
    ;;

  list|components|--list)
    list_components
    ;;

  proxmox-host)
    case "$mode" in check|install) ;; *) usage ;; esac
    [[ "$mode" == install ]] || {
      echo "proxmox-host has no doctor yet — scripts are reviewed-but-unrun; read them first:"
      ls "$KIT_DIR/profiles/proxmox-host/"
      exit 0
    }
    [[ $EUID -eq 0 ]] || { echo "proxmox-host install must run as root"; exit 2; }
    echo "Running proxmox-host phases (01 grub-iommu, 02 vfio, 03 zfs, 05 nested-virt)."
    echo "04-create-workstation-vm is NOT auto-run — review its tunables, then run it directly."
    for phase in 01-grub-iommu 02-vfio-bind 03-zfs-tune 05-nested-virt; do
      bash "$KIT_DIR/profiles/proxmox-host/$phase.sh" || true
    done
    ;;

  *) usage ;;
esac
