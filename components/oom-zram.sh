#!/bin/bash
# Machine memory policy; sourced by workstation/worker phase 07.
source "$KIT_DIR/components/memory-common.sh"
section "oom-zram ($MODE) — components/oom-zram.md"
if pkg_installed systemd-oomd; then ok 'systemd-oomd installed'
else warn 'systemd-oomd missing'; apt_install systemd-oomd || miss 'systemd-oomd package installation failed'; fi
if (( RAM_CLASS_MB < 16384 )); then ZRAM_MB=$(( RAM_MB / 2 ))
else ZRAM_MB=$(( RAM_MB / 4 < 8192 ? RAM_MB / 4 : 8192 )); fi
if dpkg -s systemd-zram-generator >/dev/null 2>&1; then ok 'systemd-zram-generator installed'
else warn 'systemd-zram-generator missing'; apt_install systemd-zram-generator; fi
SWAPS=$(swapon --show=NAME,TYPE,SIZE,USED,PRIO --bytes --noheadings 2>/dev/null)
ZRAM_WANT=$(printf '[zram0]\nzram-size = %s\ncompression-algorithm = zstd\nswap-priority = 100' "$ZRAM_MB")
memory_write "$MEM_ROOT/etc/systemd/zram-generator.conf" "$ZRAM_WANT" root "zram-generator.conf (${ZRAM_MB} MB zstd, prio 100)"
if (( MEM_CHANGED )); then
  do_or_say sudo systemctl daemon-reload
fi
if grep -q zram <<< "$SWAPS"; then
  (( MEM_CHANGED )) && warn 'zram: new size/config takes effect at next reboot; active swap is never restarted'
  awk '$1 ~ /zram/ && $5 != 100 {bad=1} END {exit bad}' <<< "$SWAPS" \
    || warn 'zram: live priority is not 100 — reconcile at next reboot'
else
  warn 'zram: configured device is not active'
  do_or_say sudo systemctl start systemd-zram-setup@zram0.service
fi
# Also report a pending size change on subsequent checks (the file alone is
# not proof that the active device was resized).
LIVE_ZRAM_MB=$(awk '$1 ~ /zram/ {n+=$3} END {printf "%d",(n+1048575)/1048576}' <<< "$SWAPS")
(( LIVE_ZRAM_MB == ZRAM_MB )) || warn "zram: live ${LIVE_ZRAM_MB} MiB, configured ${ZRAM_MB} MiB — next reboot if already active"
memory_write "$MEM_ROOT/etc/sysctl.d/99-zram.conf" \
  $'# zram pairing: no swap-in readahead\nvm.page-cluster = 0' root 'sysctl page-cluster'
if (( MEM_CHANGED )) || [[ "$(sysctl -n vm.page-cluster)" != 0 ]]; then
  do_or_say sudo sysctl -p "$MEM_ROOT/etc/sysctl.d/99-zram.conf"
fi
memory_write "$MEM_ROOT/etc/sysctl.d/99-swappiness.conf" \
  $'# RAM before swap (Brandon, 2026-09-27)\nvm.swappiness = 10' root 'sysctl swappiness'
if (( MEM_CHANGED )) || [[ "$(sysctl -n vm.swappiness)" != 10 ]]; then
  do_or_say sudo sysctl -p "$MEM_ROOT/etc/sysctl.d/99-swappiness.conf"
fi

memory_disk_swap() {
  local policy target_mb target_bytes disk_bytes deficit file='' name type size used prio
  local available alloc_bytes old_bytes growth uuid='' off=0 fstab fs free headroom
  policy=$(conf_get swap_policy auto)
  case "$policy" in
    auto) (( RAM_CLASS_MB < 16384 )) && policy=zram+disk || policy=zram-only ;;
    zram-only|zram+disk) ;;
    *) warn "invalid swap_policy=$policy — leaving disk swap alone"; return ;;
  esac
  disk_bytes=$(awk '$1 !~ /zram/ {s+=$3} END {printf "%.0f",s}' <<< "$SWAPS")
  if [[ "$policy" == zram-only ]]; then
    if (( disk_bytes == 0 )); then ok 'swap policy zram-only: no disk swap'
    else
      # Never delete a human-provisioned swap tier (ai-3090 pins zram+disk).
      warn 'swap policy zram-only but disk swap present — preserved; drain and disable it by hand if intended'
    fi
    return
  fi
  # Round up to GiB, so a nominal 8 GB box gets 8 GiB of usable overflow.
  # Explicit disk policy on >=16G keeps the previous 4 GiB target.
  target_mb=4096
  (( RAM_CLASS_MB < 16384 )) && target_mb=$(( (RAM_MB + 1023) / 1024 * 1024 ))
  target_bytes=$(( target_mb * 1048576 ))
  log "disk overflow target: ${target_mb} MiB (zram first at priority 100)"
  # Existing formatted swaps lose a header page. Allow at most 1 MiB of
  # metadata rather than swapping off a healthy 8 GiB tier for a few KiB.
  if (( disk_bytes + 1048576 >= target_bytes )); then
    ok "swap policy zram+disk: disk overflow $(((disk_bytes+1048575)/1048576)) MiB >= ${target_mb} MiB (metadata tolerance 1 MiB)"
    awk '$1 !~ /zram/ && $5 >= 100 {print $1}' <<< "$SWAPS" | while read -r name; do
      warn "disk swap $name priority >= zram 100 — lower it by hand before the next boot"
    done
    return
  fi
  warn "disk overflow $((disk_bytes/1048576)) MiB < ${target_mb} MiB — undersized"
  # Resize only conventional regular swap files. Partitions/devices and
  # custom files are left intact; add a file for the missing capacity.
  while read -r name type size used prio; do
    [[ "$type" == file ]] || continue
    case "$name" in "$MEM_ROOT/swap.img"|"$MEM_ROOT/swapfile"|"$MEM_ROOT/swap.setup-kit")
      [[ -f "$name" && ! -L "$name" ]] && { file="$name"; break; } ;;
    esac
  done <<< "$SWAPS"
  deficit=$(( target_bytes - disk_bytes ))
  if [[ -n "$file" ]]; then
    # Logical free zram is NOT free physical RAM. Use only MemAvailable,
    # minus 512 MiB for the live desktop; this is deliberately conservative
    # even if zram could absorb more. Re-read immediately before swapoff.
    available=$(awk '/^MemAvailable:/{printf "%.0f",$2*1024}' "$MEM_PROC/meminfo")
    if (( ${available:-0} < used + 536870912 )); then
      warn "unsafe to swapoff $file: used $((used/1048576)) MiB, available $(( ${available:-0}/1048576 )) MiB (512 MiB reserve); leave it for a quiet run"
      return
    fi
    old_bytes=$(stat -c %s "$file")
    alloc_bytes=$(( size + deficit + 4096 ))
    # A UUID= fstab reference must survive mkswap. Refuse ambiguous probes.
    if ! uuid=$(sudo_probe_uuid "$file"); then
      if (( ! INSTALL )); then
        warn "swap UUID for $file is unreadable without root"
        echo "  [would] probe swap UUID as root in install, then grow $file only with an unambiguous UUID and safe headroom"
        return
      fi
      warn "cannot read swap UUID for $file — refusing to reformat it"; return
    fi
  else
    file="$MEM_ROOT/swap.img"
    [[ -e "$file" || -L "$file" ]] && file="$MEM_ROOT/swap.setup-kit"
    if [[ -e "$file" || -L "$file" ]]; then
      warn "$file exists but is not active known swap — inspect it by hand; never overwritten"; return
    fi
    old_bytes=0; alloc_bytes=$(( deficit + 4096 )); used=0; prio=-2
  fi
  fs=$(findmnt -rn -o FSTYPE --target "$(dirname "$file")" 2>/dev/null)
  case "$fs" in ext4|xfs) ;; *) warn "disk overflow: $fs needs manual swap-file setup (no holes/CoW); leaving it alone"; return ;; esac
  free=$(findmnt -brn -o AVAIL --target "$(dirname "$file")" 2>/dev/null)
  headroom=$(conf_get disk_headroom_gb 10)
  [[ "$headroom" =~ ^[0-9]+$ ]] || headroom=10
  growth=$(( alloc_bytes > old_bytes ? alloc_bytes - old_bytes : 0 ))
  if [[ ! "$free" =~ ^[0-9]+$ ]] || (( free < growth + headroom * 1073741824 )); then
    warn "disk overflow: insufficient free disk for growth plus ${headroom} GiB headroom"; return
  fi
  if (( ! INSTALL )); then
    echo "  [would] grow/create $file to $alloc_bytes bytes; preserve UUID, priority -2 and whole fstab"
    return
  fi
  if (( old_bytes > 0 )); then
    # Refresh the two volatile inputs after disk/UUID probes.
    used=$(swapon --show=NAME,USED --bytes --noheadings | awk -v f="$file" '$1 == f {print $2}')
    available=$(awk '/^MemAvailable:/{printf "%.0f",$2*1024}' "$MEM_PROC/meminfo")
    if [[ ! "$used" =~ ^[0-9]+$ ]] || (( ${available:-0} < used + 536870912 )); then
      warn "unsafe to swapoff $file: memory use changed; leaving it alone"; return
    fi
    sudo swapoff "$file" || { warn "swapoff failed for $file — no allocation or formatting attempted"; return; }
    off=1
  fi
  local -a format=(sudo mkswap)
  [[ -n "$uuid" ]] && format+=(-U "$uuid")
  if sudo fallocate -l "$alloc_bytes" "$file" && sudo chmod 600 "$file" \
     && "${format[@]}" "$file" >/dev/null && sudo swapon --priority -2 "$file"; then
    # File names in fstab are rooted at /, never at the calibration prefix.
    name="${file#"$MEM_ROOT"}"
    fstab=$(cat "$MEM_ROOT/etc/fstab")
    # Preserve UUID entries and every unrelated line; add only if no entry
    # already names the file or its preserved UUID.
    if ! awk -v f="$name" -v u="${uuid:+UUID=$uuid}" '$1 !~ /^#/ && $3 == "swap" && ($1 == f || (u != "" && $1 == u)) {found=1} END {exit !found}' "$MEM_ROOT/etc/fstab"; then
      memory_write "$MEM_ROOT/etc/fstab" "${fstab:+$fstab$'\n'}$name none swap sw,pri=-2 0 0" root 'fstab swap overflow'
    fi
    log "disk overflow active: $file, $(( (alloc_bytes-4096)/1048576 )) MiB, priority -2"
  else
    warn "disk overflow growth failed for $file — inspect allocation/header before retrying"
    (( off )) && { sudo swapon --priority "$prio" "$file" || miss "URGENT: $file could not be reactivated"; }
  fi
}

# blkid's unprivileged cache can return nothing. Doctor may not sudo; install
# may probe the known active swap file with root, but never guesses a UUID.
sudo_probe_uuid() {
  local value
  value=$(blkid -p -s UUID -o value "$1" 2>/dev/null) || value=''
  if [[ -z "$value" ]] && (( INSTALL )); then value=$(sudo blkid -p -s UUID -o value "$1" 2>/dev/null) || value=''; fi
  [[ "$value" =~ ^[a-zA-Z0-9-]+$ ]] || return 1
  printf '%s' "$value"
}
memory_disk_swap
source "$KIT_DIR/components/oom-order.sh"
