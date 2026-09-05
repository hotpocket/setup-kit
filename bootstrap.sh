#!/usr/bin/env bash
# setup-kit entry point — provision a machine to work the way Brandon expects.
#
#   ./bootstrap.sh survey                  # read-only hardware report (live-CD friendly)
#   ./bootstrap.sh workstation [check]     # doctor: report what's missing, change nothing
#   ./bootstrap.sh workstation install     # provision (prompts once, records answers)
#   ./bootstrap.sh workstation check -v    # verbose: per-line [ OK ] (also verbose=yes in host conf)
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
      printf '  %s%-7s%s%-26s %s%s%s\n' \
        "$([[ "$cur" =~ ^(yes|auto)$ || ( "$cur" != no && -n "$cur" ) ]] && echo "$C_OK" || echo "$C_DIM")" \
        "[$cur]" "$C_RST" "$key" "$C_DIM" "${desc# }" "$C_RST"
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
    echo "--- free space (00-disk-space checks this against the install size) ---"
    df -h -x tmpfs -x devtmpfs -x squashfs --output=target,size,avail,pcent 2>/dev/null \
      || df -h -x tmpfs -x devtmpfs -x squashfs
    echo "--- NICs ---"
    ip -br link | grep -v '^lo'
    ;;

  workstation)
    [[ "$mode" == doctor ]] && mode=check   # alias — same thing
    # overridable so the phase-loop semantics (notably the exit-3 abort) can be
    # exercised against stub phases; unset everywhere except tests/
    PHASE_DIR="${KIT_PHASE_DIR:-$KIT_DIR/profiles/workstation}"
    case "$mode" in check|install) ;; *) usage ;; esac
    # -v (or verbose=yes in host conf): per-line [ OK ] output instead of the
    # quiet per-section rollup. Detail always lands in the run log either way.
    [[ "${3:-}" == "-v" || "$(conf_get verbose no)" == yes ]] && export KIT_VERBOSE=1
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
    chmod +x "$PHASE_DIR/preamble-github-auth.sh" 2>/dev/null || true
    [[ -f "$PHASE_DIR/preamble-github-auth.sh" ]] && bash "$PHASE_DIR/preamble-github-auth.sh" "$mode" || true
    # install mode loops passes until a pass changes nothing, then runs the
    # independent verifier — one command does the whole job.
    # missing.log is THIS run's triage list: rotate the previous run's out so
    # "Misses to triage" never points at entries an earlier run already fixed
    [[ "$mode" == install && -s "$LOG_DIR/missing.log" ]] && mv -f "$LOG_DIR/missing.log" "$LOG_DIR/missing.prev.log"
    rc=0; settled=0
    for pass in 1 2 3; do
      RUN_LOG="$LOG_DIR/run-$(date +%Y%m%d-%H%M%S)-p$pass.log"
      export KIT_RUN_LOG="$RUN_LOG"   # quiet mode routes [ OK ] detail here
      # A phase exiting 3 means "do not continue" — the run is unsafe to
      # carry on with, not merely failed (00-disk-space when the install
      # can't fit). Everything after it would be writing into a condition
      # it has already been told about, so stop the whole run here.
      aborted=0
      (( pass > 1 )) && printf '\n%s━━ pass %s — re-checking what pass %s changed ━━%s\n' "$C_HDR" "$pass" "$((pass-1))" "$C_RST"
      # pass ≥2: a WARN/FAIL/hint line identical to one in the previous pass
      # is not news — hold it back from the terminal (the run log keeps it)
      # and say how many were held. Actions and everything else stream.
      PREV_LOG="${RUN_LOG_PREV:-/dev/null}"; HELD="$LOG_DIR/.held-p$pass"; : > "$HELD"
      _unchanged() {
        # FILENAME, not NR==FNR: with an empty previous log (pass 1) NR==FNR
        # holds for every line of stdin too, and the whole pass goes silent
        awk -v held="$HELD" 'FILENAME != "-" { seen[$0]=1; next }
          (index($0,"[WARN]") || index($0,"[FAIL]") || index($0,"↳")) && ($0 in seen) { print > held; next }
          { print; fflush() }' "$PREV_LOG" -
      }
      for phase in "$PHASE_DIR/"[0-9][0-9]*-*.sh; do
        # tally per phase: what this phase found, and how long it took
        l0=0; [[ -f "$RUN_LOG" ]] && l0=$(wc -l < "$RUN_LOG"); t0=$SECONDS
        bash "$phase" "$mode" 2>&1 | tee -a "$RUN_LOG" | _unchanged
        prc="${PIPESTATUS[0]}"
        [[ "$prc" -eq 0 ]] || rc=1
        if [[ -z "${KIT_VERBOSE:-}" ]]; then
          delta="$(tail -n +"$((l0+1))" "$RUN_LOG")"
          p_ok=$(grep -c '\[ OK \]' <<<"$delta"); p_w=$(grep -c '\[WARN\]' <<<"$delta"); p_f=$(grep -c '\[FAIL\]' <<<"$delta")
          p_a=$(grep -cE '^  \+ |apt install attempt' <<<"$delta")
          if (( p_ok + p_w + p_f + p_a )); then
            gl="${C_OK}✔"; (( p_w )) && gl="${C_WARN}!"; (( p_f )) && gl="${C_FAIL}✗"
            line="$gl$C_RST $(basename "$phase" .sh) · $p_ok ok"
            (( p_w )) && line+=" · $p_w warn"; (( p_f )) && line+=" · $p_f fail"; (( p_a )) && line+=" · $p_a actions"
            printf '  %s · %ss\n' "$line" "$((SECONDS - t0))"
          fi
        fi
        if [[ "$prc" -eq 3 ]]; then
          aborted=1
          echo "  ⛔ ABORTED by $(basename "$phase") — nothing further was run"
          break
        fi
      done
      n_held=$(grep -c '\[WARN\]\|\[FAIL\]' "$HELD" 2>/dev/null || true)
      (( n_held )) && echo "  ($n_held warning(s) unchanged from pass $((pass-1)) not repeated — all replay in the final summary)"
      RUN_LOG_PREV="$RUN_LOG"
      (( aborted )) && { echo "  Full log: $RUN_LOG"; exit 1; }
      # summary that answers "did anything change?" from stdout alone
      n_ok=$(grep -c '\[ OK \]'   "$RUN_LOG" || true)
      n_warn=$(grep -c '\[WARN\]' "$RUN_LOG" || true)
      n_fail=$(grep -c '\[FAIL\]' "$RUN_LOG" || true)
      # actions = do_or_say invocations, kit "installed:" log lines, apt runs —
      # NOT phrases like "already installed" from chained tools
      # quiet lines ('  + cmd ✓ 3s', '  installed: x') and verbose ones ('[ts] + cmd')
      n_act=$(grep -cE '^  \+ |\] \+ |^  installed: |\] installed: |apt install attempt' "$RUN_LOG" || true)
      # the same actions, normalised (no timestamps, no mktemp names) — a pass
      # that would redo exactly what the last one did is not converging, it is
      # cycling: an install whose "done?" check can't see its own result
      grep -E '^  \+ |\] \+ |^  installed: |\] installed: |apt install attempt' "$RUN_LOG" \
        | sed -E 's/^\[[^]]*\] //; s/ ✓ [0-9]+s$//; s/ ✗ exit.*$//; s#/tmp/tmp\.[A-Za-z0-9]+#/tmp/tmp.X#g' | sort > "$LOG_DIR/.actions-p$pass"
      printf '\n%spass %s: %s ok · %s warn · %s fail · %s actions%s\n' "$C_HDR" "$pass" "$n_ok" "$n_warn" "$n_fail" "$n_act" "$C_RST"
      # surface WHAT failed/warned, not just the counts — last occurrence of
      # each unique message (later passes supersede earlier ones)
      # Replay each unique message WITH the ↳ hint lines that follow it — the
      # hint carries the fix, and in quiet mode the summary is the only place
      # it can still reach the terminal.
      # index/substr, never a regex: the tags are '[WARN]'/'[FAIL]' and brackets
      # in an awk regex are a character class, which silently matches anything.
      _replay() {   # tag glyph
        awk -v tag="$1" -v gl="$2" '
          { i = index($0, tag) }
          i { msg = substr($0, i + length(tag)); sub(/^ +/, "", msg)
              if (!seen[msg]++) { print "    " gl " " msg; cur = 1 } else cur = 0; next }
          cur && index($0, "↳") { h = $0; sub(/^ +/, "      ", h)
                                  if (!seen[h]++) print h; next }
          { cur = 0 }' "$RUN_LOG"
      }
      _final_summary() {   # once, after the last pass — every open WARN/FAIL with its hint
        section "summary — $(hostname) ($mode, $pass pass(es))"
        echo "  ok: $n_ok   warn: $n_warn   fail: $n_fail   actions: $n_act"
        (( n_fail > 0 )) && { echo "  FAIL:"; _replay '[FAIL]' '✗'; }
        (( n_warn > 0 )) && { echo "  WARN:"; _replay '[WARN]' '!'; }
        return 0
      }
      [[ "$mode" == check ]] && { _final_summary; echo "  doctor only — 'install' applies. Full log: $RUN_LOG"; break; }
      if (( n_act == 0 )); then
        _final_summary
        if (( n_warn == 0 && n_fail == 0 )); then
          echo "  ✔ CONVERGED — nothing to change; system matches the manifests"
        else
          echo "  ✔ stable — no actions left; remaining warn/fail need a human"
          echo "    (see profiles/workstation/99-manual-checklist.md)"
        fi
        settled=1
        break
      fi
      if (( pass == 3 )) || { (( pass > 1 )) && cmp -s "$LOG_DIR/.actions-p$pass" "$LOG_DIR/.actions-p$((pass-1))"; }; then
        _final_summary
      fi
      if (( pass > 1 )) && cmp -s "$LOG_DIR/.actions-p$pass" "$LOG_DIR/.actions-p$((pass-1))"; then
        echo "  ⟳ pass $pass repeated the same actions as pass $((pass-1)) — a third would too; stopping"
        echo "    (an action that never sticks: its check can't see the result, or a dependency is missing)"
        break
      fi
      echo "  changes applied — running another pass..."
    done
    if [[ "$mode" == install ]]; then
      (( settled )) || { echo "  ⚠ NOT converged after $pass passes — still applying changes; re-run install"; rc=1; }
      [[ -s "$LOG_DIR/missing.log" ]] && echo "  Misses to triage: $LOG_DIR/missing.log"
      # KIT_SKIP_VERIFY: tests exercise the loop against stub phases; a real
      # verify there would grade this box against the manifests, not the loop
      if [[ -z "${KIT_SKIP_VERIFY:-}" ]]; then
        section "independent verification (verify.sh)"
        "$KIT_DIR/verify.sh" --settle 30 | grep -E '^(FAIL|===|    )'
        # verify's own exit code (not grep's) folds into the run result
        [[ "${PIPESTATUS[0]}" -eq 0 ]] || rc=1
      fi
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
