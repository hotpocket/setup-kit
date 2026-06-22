#!/bin/bash
# System identity + virt guest plumbing. Idempotent, doctor/install.
SCRIPT_NAME="ws-00-identity"
source "$(dirname "$0")/../../lib.sh"
require_user
init_mode "${1:-}"

section "identity ($MODE)"

TZ_WANT="$(conf_get timezone America/Los_Angeles)"
TZ_CUR="$(timedatectl show -p Timezone --value 2>/dev/null)"
if [[ "$TZ_CUR" == "$TZ_WANT" ]]; then
  ok "timezone $TZ_CUR"
else
  warn "timezone is '$TZ_CUR', want '$TZ_WANT'"
  do_or_say sudo timedatectl set-timezone "$TZ_WANT"
fi

LOCALE_WANT="$(conf_get locale en_US.UTF-8)"
if locale -a 2>/dev/null | grep -qi "^${LOCALE_WANT/UTF-8/utf8}$"; then
  ok "locale $LOCALE_WANT available"
else
  warn "locale $LOCALE_WANT not generated"
  do_or_say sudo locale-gen "$LOCALE_WANT"
  do_or_say sudo update-locale "LANG=$LOCALE_WANT"
fi

# Guest agent only when we ARE a kvm guest (Proxmox VM)
if [[ "$(virt_context)" == kvm ]]; then
  if dpkg -s qemu-guest-agent >/dev/null 2>&1; then
    ok "qemu-guest-agent installed (kvm guest)"
  else
    warn "kvm guest without qemu-guest-agent"
    apt_install qemu-guest-agent
    do_or_say sudo systemctl enable --now qemu-guest-agent
  fi
else
  ok "not a kvm guest ($(virt_context)) — no guest agent needed"
fi

# Group memberships — only for groups that exist (created by their packages)
for g in docker kvm libvirt dialout; do
  getent group "$g" >/dev/null || continue
  if id -nG "$USER" | grep -qw "$g"; then
    ok "user in group $g"
  else
    warn "user not in group $g"
    do_or_say sudo usermod -aG "$g" "$USER"
    (( INSTALL )) && hint "log out/in (or 'newgrp $g') to take effect"
  fi
done
