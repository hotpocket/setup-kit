#!/bin/bash
# The fstab-generated tmp.mount overrides Ubuntu's vendor tmpfs mount.
# Masking that generated unit would also block an existing ext4 /tmp.
source "$KIT_DIR/components/memory-common.sh"
if [[ "$(conf_get tmp_on_disk yes)" == yes ]]; then
  section "tmp on disk ($MODE) — components/oom-zram.md"
  # The age is one tmpfiles field, never text that can add fields or rules.
  # systemd-analyze uses the same duration parser as systemd-tmpfiles.
  if [[ "$(conf_get tmp_age_rule no)" == yes ]]; then
    source "$KIT_DIR/manifests/tmpfiles.conf"
    TMP_AGE="$(conf_get tmp_age "$TMP_AGE_DEFAULT")"
    TMP_DURATION=${TMP_AGE#\~}; TMP_DURATION=${TMP_DURATION##*:}
    if [[ ! "$TMP_AGE" =~ ^~?([abcmABCM]+:)?[^:[:space:]\\\"\']+$ ]] \
        || ! systemd-analyze timespan -- "$TMP_DURATION" >/dev/null 2>&1; then
      fail 'tmp: invalid tmp_age; use age-by letters and a systemd duration'
      miss 'tmp: invalid age; previous rule preserved'
      exit 1
    fi
  fi
  TMP_TYPE=$(findmnt -rn -o FSTYPE --target "$MEM_ROOT/tmp" 2>/dev/null)
  log "tmp: live fstype ${TMP_TYPE:-unknown}"
  TMP_FSTAB=$(awk '$1 !~ /^#/ && $2 == "/tmp" {print $3}' "$MEM_ROOT/etc/fstab")
  if [[ -n "$TMP_FSTAB" ]]; then
    if [[ "$TMP_FSTAB" == *tmpfs* || "$TMP_FSTAB" == *ramfs* ]]; then
      warn "tmp: fstab explicitly requests $TMP_FSTAB — edit that entry by hand; a mask would block it"
    else
      ok "tmp: fstab disk mount preserved ($TMP_FSTAB); no mask or fstab change"
      [[ "$(systemctl is-enabled tmp.mount 2>/dev/null || true)" == masked ]] \
        && warn "tmp: tmp.mount is masked despite its fstab entry — unmask it before reboot"
    fi
  elif [[ "$(systemctl is-enabled tmp.mount 2>/dev/null || true)" == masked ]]; then
    ok "tmp: vendor tmpfs masked; /tmp uses its backing filesystem at next reboot"
  else
    warn "tmp: vendor tmpfs can consume half of RAM; use disk at next reboot"
    do_or_say sudo systemctl mask tmp.mount
  fi
  if [[ "$TMP_TYPE" == tmpfs || "$TMP_TYPE" == ramfs ]]; then
    hint "tmp: disk policy takes effect at the next reboot; the live mount and active files stay in place"
  elif [[ -z "$TMP_TYPE" ]]; then
    warn "tmp: cannot read live filesystem type"
  fi
  # Override the vendor file by NAME, retaining /var/tmp's separate age.
  # No --clean now: ongoing agent/test scratch must not disappear mid-run.
  if [[ "$(conf_get tmp_age_rule no)" == yes ]]; then
    TMP_RULE="$MEM_ROOT/etc/tmpfiles.d/tmp.conf"
    TMP_WANT="D /tmp 1777 root root $TMP_AGE"
    if [[ -f "$TMP_RULE" && ! -L "$TMP_RULE" && "$(stat -c %a "$TMP_RULE")" == 644 ]] \
        && cmp -s <(printf '%s\n' "$TMP_WANT") "$TMP_RULE"; then
      ok "tmp: age rule matches"
    else
      warn "tmp: age rule missing or drifted ($TMP_RULE; mode 644)"
      tmp_age_write() (
        sudo mkdir -p "$(dirname "$TMP_RULE")" || exit 1
        stage=$(mktemp "$HOME/.setup-kit-tmp.XXXXXX") || exit 1
        trap 'rm -f "$stage"' EXIT
        printf '%s\n' "$TMP_WANT" > "$stage" || exit 1
        # Atomic rename on the target filesystem; no cleanup of live scratch.
        dest=$(sudo mktemp "${TMP_RULE}.XXXXXX") || exit 1
        sudo install -m 644 "$stage" "$dest" && sudo mv -Tf "$dest" "$TMP_RULE"
      )
      do_or_say tmp_age_write || miss "tmp: age rule write failed"
    fi
  else
    memory_write "$MEM_ROOT/etc/tmpfiles.d/tmp.conf" \
      $'# setup-kit: disk-backed scratch must age out\nq /tmp 1777 root root 10d\nq /var/tmp 1777 root root 30d' root 'tmp: aged cleanup (10d)'
  fi
  if ! systemctl is-active --quiet systemd-tmpfiles-clean.timer; then
    warn "tmp: cleanup timer inactive"
    do_or_say sudo systemctl start systemd-tmpfiles-clean.timer
  fi
fi
