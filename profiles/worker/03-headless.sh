#!/bin/bash
# Headless plumbing for a worker VM: boot to a tty, reachable by ssh, user
# services alive without a login, the GPU driver held still, and the machine
# credentials the jobs run under VERIFIED (never seeded — that is a human act,
# see 99-manual-checklist.md). Idempotent, doctor/install.
#
# The desktop stays INSTALLED. Only the default target changes: the kit never
# removes packages, disk is not what a desktop costs on a worker (RAM is), and
# `sudo systemctl start gdm3` brings the Proxmox noVNC console back any time.
# The switch is recorded for the next boot and never isolated live — this
# script is typically run from inside the GNOME session it would kill.
SCRIPT_NAME="wk-03-headless"
source "$(dirname "$0")/../../lib.sh"
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
if systemctl is-enabled --quiet ssh 2>/dev/null && systemctl is-active --quiet ssh 2>/dev/null; then
  ok "sshd enabled and running"
elif pkg_installed openssh-server; then
  warn "sshd installed but not enabled/running"
  do_or_say sudo systemctl enable --now ssh
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

# git: a plain ed25519 key that needs no touch. The workstation's YubiKey
# FIDO2 keys (github_yub_*) require a physical press per signature — a cron
# hangs on them forever. The kit generates the keypair (local, harmless); YOU
# register the public half (deploy key on the job repo, or a machine user).
KEY="$(conf_get git_deploy_key "$HOME/.ssh/id_ed25519_worker")"; KEY="${KEY/#\~/$HOME}"
if compgen -G "$HOME/.ssh/*_sk*" >/dev/null || compgen -G "$HOME/.ssh/github_yub_*" >/dev/null; then
  warn "FIDO2 (-sk) ssh key present in ~/.ssh — unusable by unattended jobs (needs a touch)"
fi
if [[ -f "$KEY" ]]; then
  ok "git deploy key present: ${KEY/#$HOME/\~}"
else
  warn "git deploy key missing: ${KEY/#$HOME/\~}"
  if (( INSTALL )); then
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    do_or_say ssh-keygen -q -t ed25519 -N '' -C "$USER@$(hostname) worker" -f "$KEY" \
      && log "generated ${KEY/#$HOME/\~} — register the .pub as a deploy key (see 99-manual-checklist.md)"
  fi
fi
if [[ -f "$KEY" ]]; then
  # GitHub answers "successfully authenticated" and exits 1 on a good key
  out="$(timeout 20 ssh -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none \
           -i "$KEY" -T git@github.com 2>&1 || true)"
  if [[ "$out" == *"successfully authenticated"* ]]; then
    ok "git deploy key accepted by GitHub"
  else
    warn "GitHub does not accept the deploy key yet"
    hint "register: cat ${KEY/#$HOME/\~}.pub  →  repo Settings › Deploy keys (one repo per key), or a machine user's SSH keys"
    miss "creds: git deploy key not registered with GitHub"
  fi
fi
[[ -f "$KEY.pub" ]] && log "public key: $(cat "$KEY.pub")"

exit 0
