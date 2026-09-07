#!/bin/bash
# Headless plumbing for a worker VM: boot to a tty, reachable by ssh, user
# services alive without a login, the GPU driver held still, and the machine
# credentials the jobs run under VERIFIED (never seeded — that is a human act,
# see 99-manual-checklist.md). Idempotent, doctor/install.
#
# The desktop stays INSTALLED. Only the default target changes: the kit never
# removes packages, disk is not what a desktop costs on a worker (RAM is), and
# `sudo systemctl start gdm3` brings the Proxmox noVNC console back any time.
# The switch is recorded for the next boot and never isolated live: a
# console session may be open, and a reboot is the honest moment anyway.
SCRIPT_NAME="wk-03-headless"
source "$(dirname "$0")/../../lib.sh"
source "$(dirname "$0")/lib-deploy-keys.sh"
require_user
init_mode "${1:-}"

section "headless boot ($MODE)"

# ---- 1. default target: multi-user (no display manager at boot) -------------
if [[ "$(systemctl get-default 2>/dev/null)" == multi-user.target ]]; then
  ok "default target multi-user.target (no desktop at boot)"
else
  warn "default target is $(systemctl get-default 2>/dev/null) — desktop starts at boot"
  do_or_say sudo systemctl set-default multi-user.target
  (( INSTALL )) && log "takes effect at next boot; the current session is left alone"
fi
if systemctl is-active --quiet graphical.target 2>/dev/null; then
  hint "a desktop session is running now — reboot when convenient to reclaim its RAM"
fi

# ---- 2. ssh in, guest agent up ----------------------------------------------
# 26.04 socket-activates sshd: ssh.socket is what's enabled, ssh.service
# reports "disabled" while serving you. Either unit enabled = reachable.
if { systemctl is-enabled --quiet ssh.socket || systemctl is-enabled --quiet ssh; } 2>/dev/null \
   && { systemctl is-active --quiet ssh.socket || systemctl is-active --quiet ssh; } 2>/dev/null; then
  ok "sshd enabled and running"
elif pkg_installed openssh-server; then
  warn "sshd installed but not enabled/running"
  do_or_say sudo systemctl enable --now ssh.socket
else
  warn "openssh-server not installed yet (group_worker → 02-apt-install)"
fi
AK="$HOME/.ssh/authorized_keys"
if [[ -s "$AK" ]]; then
  ok "authorized_keys: $(grep -cE '^(ssh|ecdsa|sk-)' "$AK") key(s)"
else
  warn "authorized_keys is empty — no way in without the console"
  hint "from your laptop: ssh-copy-id $USER@$(hostname -I 2>/dev/null | awk '{print $1}')"
  miss "headless: authorized_keys empty (add your laptop's public key)"
fi

# ---- 3. linger: user services/timers run with nobody logged in --------------
if [[ "$(loginctl show-user "$USER" -p Linger --value 2>/dev/null)" == yes ]]; then
  ok "linger enabled for $USER (user timers run without a login)"
else
  warn "linger off — systemd --user timers would only run while logged in"
  do_or_say sudo loginctl enable-linger "$USER"
fi

# ---- 4. hold the GPU driver still under unattended-upgrades -----------------
# A driver userspace bump on a live box mismatches the loaded kernel module:
# CUDA dies until reboot (2026-07-24, driver 580 vs 595). Kernel/security
# updates keep flowing; only the nvidia stack waits for a deliberate apt run.
if nvidia_wanted; then
  HOLD=/etc/apt/apt.conf.d/51-worker-nvidia-hold
  HOLD_WANT='// setup-kit worker (profiles/worker/03-headless.sh): unattended-upgrades must not
// bump the nvidia userspace under a running CUDA job — the loaded kernel module
// then mismatches and every GPU call fails until reboot. Update nvidia by hand.
Unattended-Upgrade::Package-Blacklist { "nvidia-"; "libnvidia-"; };'
  if [[ -f "$HOLD" && "$(cat "$HOLD")" == "$HOLD_WANT" ]]; then
    ok "unattended-upgrades: nvidia held"
  else
    warn "unattended-upgrades may replace the nvidia driver mid-job"
    if (( INSTALL )); then
      printf '%s\n' "$HOLD_WANT" | sudo tee "$HOLD" >/dev/null && log "wrote $HOLD"
    else
      hint "write $HOLD (Package-Blacklist nvidia-, libnvidia-)"
    fi
  fi
fi

# ---- 5. machine credentials — verify, never seed ---------------------------
section "machine credentials ($MODE) — verified only; seeding is manual"

# aws: a named profile with keys scoped to the jobs (S3 bucket, CloudFront
# invalidation, ...). SSO sessions expire in hours and need a human; they are
# not a cron identity. The check is a real STS call, not a file grep.
AWS_PROF="$(conf_get aws_profile cron-deploy)"
if command -v aws >/dev/null 2>&1; then
  if arn="$(timeout 20 aws --profile "$AWS_PROF" sts get-caller-identity --query Arn --output text 2>/dev/null)" \
     && [[ -n "$arn" ]]; then
    ok "aws profile $AWS_PROF: $arn"
  else
    warn "aws profile '$AWS_PROF' can't authenticate (missing, wrong, or no network)"
    hint "aws configure --profile $AWS_PROF   # the job-scoped access key, NOT an SSO login"
    miss "creds: aws profile $AWS_PROF not working"
  fi
else
  warn "awscli not installed yet (group_worker → 02-apt-install); aws profile $AWS_PROF unverified"
fi

# git: one read-only deploy key per private repo, each on its own ssh alias
# (lib-deploy-keys.sh). The workstation's YubiKey FIDO2 keys need a physical
# press per signature — a cron hangs on them forever — so none live here.
if compgen -G "$HOME/.ssh/*_sk*" >/dev/null || compgen -G "$HOME/.ssh/github_yub_*" >/dev/null; then
  warn "FIDO2 (-sk) ssh key present in ~/.ssh — unusable by unattended jobs (needs a touch)"
fi
if [[ "$GIT_AUTH" == token ]]; then
  if token_login; then
    _cfg="$(conf_get configs_repo '')"
    [[ -n "$_cfg" ]] && token_probe "$(sed -E 's#^(https://github.com/|git@[^:]+:)##; s#\.git$##' <<<"$_cfg")"
    for r in $CLONE_REPOS; do token_probe "$r"; done
  fi
  clone_wanted
elif [[ -z "$DEPLOY_REPOS" ]]; then
  warn "deploy_repos empty in host conf — no private repo can be pulled"
else
  deploy_each deploy_ensure
  deploy_each deploy_probe
  _show_pub() { [[ -f "$3.pub" ]] && log "$1 public key: $(cat "$3.pub")"; }
  deploy_each _show_pub
  clone_wanted
fi

exit 0
