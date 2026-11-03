#!/bin/bash
# Worker phase 03 only. Prefix paths for calibration; normal runs use /.
worker_dhcp_identifier() {
  local root="${KIT_NETPLAN_ROOT:-/}" file want tmp backup="" state
  root="${root%/}"; root="${root:-/}"
  file="${root%/}/etc/netplan/90-dhcp-mac.yaml"
  if ! want=$(sudo /usr/bin/python3 "$KIT_DIR/profiles/worker/netplan-dhcp.py" "$root"); then
    fail "DHCP identifier: cannot read netplan; check netplan YAML before retrying"
    return 1
  fi
  if [[ -z "$want" ]]; then
    ok "DHCP identifier: no DHCP ethernets configured"; return 0
  fi
  if [[ -L "$file" || ( -e "$file" && ! -f "$file" ) ]]; then
    fail "DHCP identifier: $file is not a regular file; inspect it before retrying"
    return 1
  fi
  state=$(sudo stat -c '%a:%u:%g' "$file" 2>/dev/null) || state=""
  if [[ "$state" == 600:0:0 ]] && printf '%s\n' "$want" | sudo cmp -s "$file" -; then
    ok "DHCP identifier: $file matches (mac)"; return 0
  fi
  warn "DHCP identifier: $file missing or drifted (want mac, mode 600, root:root)"
  if (( ! INSTALL )); then
    hint "run worker install to write the DHCP identifier drop-in"; return 0
  fi
  if ! command -v netplan >/dev/null 2>&1; then
    fail "DHCP identifier: netplan missing; restore the netplan package before retrying"
    return 1
  fi
  sudo mkdir -p "${file%/*}" || return 1
  tmp=$(sudo mktemp "${file%/*}/.90-dhcp-mac.XXXXXX") || return 1
  if [[ -e "$file" ]]; then
    backup=$(sudo mktemp "${file%/*}/.90-dhcp-mac-backup.XXXXXX") || { sudo rm -f "$tmp"; return 1; }
    sudo cp --preserve=all "$file" "$backup" || { sudo rm -f "$tmp" "$backup"; return 1; }
  fi
  if ! { printf '%s\n' "$want" | sudo tee "$tmp" >/dev/null \
      && sudo chown root:root "$tmp" && sudo chmod 600 "$tmp" \
      && sudo mv -fT "$tmp" "$file"; }; then
    sudo rm -f "$tmp" ${backup:+"$backup"}
    fail "DHCP identifier: could not replace $file; fix the write error and retry"
    return 1
  fi
  local -a generate=(netplan generate)
  [[ "$root" == / ]] || generate+=(--root-dir "$root")
  if ! sudo "${generate[@]}"; then
    if { if [[ -n "$backup" ]]; then sudo mv -fT "$backup" "$file"; else sudo rm -f "$file"; fi; }; then
      fail "DHCP identifier: netplan generate failed; previous file state restored; fix netplan YAML and retry"
    else
      fail "DHCP identifier: rollback failed; restore ${backup:-the absent file} at $file before retrying"
    fi
    return 1
  fi
  [[ -z "$backup" ]] || sudo rm -f "$backup"
  log "DHCP identifier: wrote $file; takes effect at next reboot or DHCP renewal"
}
