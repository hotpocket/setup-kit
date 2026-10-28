#!/bin/bash
# Sourced by phase 07. The prefix is a calibration seam; normal runs use /.
# shellcheck disable=SC2034 # Variables are consumed by the sourcing components.
MEM_ROOT="${KIT_MEMORY_ROOT:-}"
MEM_ROOT="${MEM_ROOT%/}"
MEM_PROC="$MEM_ROOT/proc"
RAM_MB=$(awk '/^MemTotal:/{print int($2/1024)}' "$MEM_PROC/meminfo")
# Firmware/kernel reservations must not make a nominal 16 GiB machine small.
RAM_CLASS_MB=$(( (RAM_MB + 1023) / 1024 * 1024 ))

# Whole owned files, reconciled by content. Return state separately so a
# caller can reload only after a change. Never follows a user config symlink.
memory_write() {
  local path="$1" want="$2" owner="$3" label="$4" tmp
  MEM_CHANGED=0
  if [[ -f "$path" && "$(cat "$path")" == "$want" ]]; then
    ok "$label matches"; return 0
  fi
  warn "$label missing or drifted — $path"
  if (( ! INSTALL )); then
    echo "  [would] write $path ($label)"; return 0
  fi
  if [[ "$owner" == root ]]; then
    sudo mkdir -p "$(dirname "$path")" \
      && printf '%s\n' "$want" | sudo tee "$path" >/dev/null || { miss "cannot write $path"; return 1; }
  else
    mkdir -p "$(dirname "$path")" || return 1
    tmp=$(mktemp "${path}.XXXXXX") || return 1
    printf '%s\n' "$want" > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$path" \
      || { rm -f "$tmp"; miss "cannot write $path"; return 1; }
  fi
  MEM_CHANGED=1
}
