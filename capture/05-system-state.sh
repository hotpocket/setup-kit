#!/bin/bash
# Capture system-level state: hostname, locale, timezone, groups, fstab,
# crontabs, custom systemd units, dconf, gnome extensions, ufw rules.

SCRIPT_NAME="capture-05-system-state"
source "$(dirname "$0")/../lib.sh"
require_user

OUT="$SNAPSHOT_DIR/system"
mkdir -p "$OUT"

log "Capturing system state..."

# Identity / locale.
hostnamectl > "$OUT/hostnamectl.txt" 2>&1
echo "$HOSTNAME" > "$OUT/hostname.txt"
timedatectl > "$OUT/timedatectl.txt" 2>&1
localectl > "$OUT/localectl.txt" 2>&1
cat /etc/locale.gen > "$OUT/locale.gen" 2>/dev/null || true

# User identity / groups.
id > "$OUT/id.txt"
groups > "$OUT/groups.txt"
getent passwd "$USER" > "$OUT/passwd-entry.txt"

# /etc system files — Ubuntu makes most of these world-readable.
copy_or_miss() {
  local src="$1" dst="$2"
  if [[ -e "$src" ]] && cp -r "$src" "$dst" 2>>"$LOG_DIR/${SCRIPT_NAME}.log"; then
    log "copied: $src"
  else
    miss "system: $src (unreadable or absent — sudo cp manually if needed)"
  fi
}
copy_or_miss /etc/fstab           "$OUT/fstab"
copy_or_miss /etc/hosts           "$OUT/hosts"
copy_or_miss /etc/hostname        "$OUT/hostname-file"
copy_or_miss /etc/sudoers.d       "$OUT/sudoers.d"
copy_or_miss /etc/modprobe.d      "$OUT/modprobe.d"
copy_or_miss /etc/modules-load.d  "$OUT/modules-load.d"
copy_or_miss /etc/sysctl.d        "$OUT/sysctl.d"

# Custom systemd units (user-defined, not from packages).
mkdir -p "$OUT/systemd-system"
for f in /etc/systemd/system/*.service /etc/systemd/system/*.timer; do
  [[ -e "$f" ]] || continue
  # Skip ones owned by packages.
  if ! dpkg -S "$f" >/dev/null 2>&1; then
    cp "$f" "$OUT/systemd-system/" 2>>"$LOG_DIR/${SCRIPT_NAME}.log" \
      || miss "system: $f (unreadable — sudo cp manually)"
  fi
done

# User-level systemd units.
[[ -d "$HOME/.config/systemd/user" ]] && \
  cp -r "$HOME/.config/systemd/user" "$OUT/systemd-user" 2>/dev/null || true

# Enabled units (so we know what to enable on restore).
systemctl list-unit-files --state=enabled --no-pager \
  > "$OUT/enabled-system.txt" 2>/dev/null || true
systemctl --user list-unit-files --state=enabled --no-pager \
  > "$OUT/enabled-user.txt" 2>/dev/null || true

# Crontabs.
crontab -l > "$OUT/crontab-user.txt" 2>/dev/null || echo "(none)" > "$OUT/crontab-user.txt"
# Root crontab needs sudo — log a miss so user can run manually.
if sudo -n crontab -l > "$OUT/crontab-root.txt" 2>/dev/null; then
  log "crontab-root captured"
else
  echo "(needs sudo: run \`sudo crontab -l > crontab-root.txt\` manually)" > "$OUT/crontab-root.txt"
  miss "system: root crontab (run: sudo crontab -l)"
fi
for d in /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
  copy_or_miss "$d" "$OUT/$(basename "$d")"
done

# Firewall — need sudo, miss-log if unavailable.
if out=$(sudo -n ufw status verbose 2>/dev/null); then
  printf '%s\n' "$out" > "$OUT/ufw.txt"
  log "ufw captured"
else
  echo "(needs sudo: run \`sudo ufw status verbose > ufw.txt\` manually)" > "$OUT/ufw.txt"
  miss "system: ufw status (run: sudo ufw status verbose)"
fi
if out=$(sudo -n iptables-save 2>/dev/null); then
  printf '%s\n' "$out" > "$OUT/iptables.txt"
  log "iptables captured"
else
  miss "system: iptables-save (run: sudo iptables-save > iptables.txt)"
fi

# dconf (GNOME / GTK settings — huge but valuable for desktop UX).
dconf dump / > "$OUT/dconf-dump.ini" 2>/dev/null
log "dconf-dump: $(wc -l < "$OUT/dconf-dump.ini") lines"

# GNOME Shell extensions.
if command -v gnome-extensions >/dev/null 2>&1; then
  gnome-extensions list --enabled > "$OUT/gnome-extensions-enabled.txt" 2>/dev/null || true
  gnome-extensions list > "$OUT/gnome-extensions-all.txt" 2>/dev/null || true
fi

# GPU / hardware state (NVIDIA-specific bits for the workstation rebuild).
nvidia-smi --query-gpu=driver_version,name --format=csv > "$OUT/nvidia-info.txt" 2>/dev/null || true
ubuntu-drivers devices > "$OUT/ubuntu-drivers.txt" 2>&1 || true
dpkg -l 'nvidia-*' > "$OUT/nvidia-packages.txt" 2>/dev/null || true
dpkg -l 'cuda*' > "$OUT/cuda-packages.txt" 2>/dev/null || true
[[ -d /etc/X11/xorg.conf.d ]] && copy_or_miss /etc/X11/xorg.conf.d "$OUT/xorg.conf.d"

# Docker — if you use it on the workstation (probably not after Proxmox transition).
if command -v docker >/dev/null 2>&1; then
  mkdir -p "$OUT/docker"
  docker images --format '{{.Repository}}:{{.Tag}}' > "$OUT/docker/images.txt" 2>/dev/null || true
  docker volume ls --format '{{.Name}}' > "$OUT/docker/volumes.txt" 2>/dev/null || true
  docker network ls --format '{{.Name}}' > "$OUT/docker/networks.txt" 2>/dev/null || true
fi

# Editor extensions (auto-syncable but capture for reference).
command -v code >/dev/null 2>&1 && code --list-extensions > "$OUT/vscode-extensions.txt" 2>/dev/null || true
command -v cursor >/dev/null 2>&1 && cursor --list-extensions > "$OUT/cursor-extensions.txt" 2>/dev/null || true

# Block device inventory — so future-you knows what was where.
lsblk -f > "$OUT/lsblk.txt"
lsblk -d -o NAME,MODEL,SERIAL,SIZE,TRAN > "$OUT/drives.txt"
if out=$(sudo -n blkid 2>/dev/null); then
  printf '%s\n' "$out" > "$OUT/blkid.txt"
  log "blkid captured"
else
  miss "system: blkid (run: sudo blkid > blkid.txt — needed for UUID-based fstab)"
fi

log "Done. Artifacts in $OUT"
