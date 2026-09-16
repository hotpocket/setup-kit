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
source "$(dirname "$0")/lib-aws-creds.sh"
require_user
init_mode "${1:-}"

section "headless boot ($MODE)"

# ---- 1. default target: boot_target in the host conf (multi-user default) ---
# A worker boots to a tty unless its owner wants the Proxmox console to show
# the desktop (boot_target=graphical). Either way the desktop stays installed.
WANT_TARGET="$(conf_get boot_target multi-user)"
case "$WANT_TARGET" in
  multi-user|graphical) WANT_TARGET="$WANT_TARGET.target" ;;
  *) warn "boot_target=$WANT_TARGET is not multi-user|graphical — leaving the default target alone"; WANT_TARGET="" ;;
esac
CUR_TARGET="$(systemctl get-default 2>/dev/null)"
if [[ -z "$WANT_TARGET" ]]; then :
elif [[ "$CUR_TARGET" == "$WANT_TARGET" ]]; then
  [[ "$WANT_TARGET" == multi-user.target ]] && ok "default target multi-user.target (no desktop at boot)"                                             || ok "default target graphical.target (desktop at boot, per boot_target)"
else
  [[ "$WANT_TARGET" == multi-user.target ]] && warn "default target is $CUR_TARGET — desktop starts at boot"                                             || warn "default target is $CUR_TARGET — boot_target wants the desktop"
  do_or_say sudo systemctl set-default "$WANT_TARGET"
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
#
# How the key is STORED is the kit's business (lib-aws-creds.sh): sealed as a
# user-scoped systemd-creds blob (TPM2 + host key + uid + machine-id) that the
# aws CLI opens through credential_process. Plaintext in ~/.aws/credentials is
# the human's seed; install mode converts it (seal-aws-profile.sh), check mode
# names it. The blob header says what it is bound to: a seal made before the
# VM had a TPM is host-key-only and is reported as such.
AWS_PROF="$(conf_get aws_profile cron-deploy)"
if aws_plaintext "$AWS_PROF"; then
  warn "aws profile $AWS_PROF: static key in plaintext at ~/.aws/credentials"
  hint "$(dirname "$0")/seal-aws-profile.sh $AWS_PROF   # → systemd-creds blob, TPM2 + host key, user-scoped"
  if (( INSTALL )) && command -v aws >/dev/null 2>&1; then
    bash "$(dirname "$0")/seal-aws-profile.sh" "$AWS_PROF" || miss "creds: aws profile $AWS_PROF still in plaintext (seal failed)"
  else
    miss "creds: aws profile $AWS_PROF stored in plaintext (run seal-aws-profile.sh)"
  fi
fi
if ! aws_plaintext "$AWS_PROF"; then
  _cp="$(aws_cred_process "$AWS_PROF")"; _cf="$(aws_cred_file "$AWS_PROF")"
  if [[ "$_cp" == *systemd-creds* && -s "$_cf" ]]; then
    case "$(aws_seal_kind "$_cf")" in
      tpm2+host) ok "aws profile $AWS_PROF: sealed to TPM2 + host key (user-scoped) — $_cf" ;;
      host) warn "aws profile $AWS_PROF: sealed to the host key only — no TPM2 when it was sealed"
            has_tpm2 && hint "$(dirname "$0")/seal-aws-profile.sh $AWS_PROF   # re-seals to the TPM2 now present" \
                     || hint "add a TPM 2.0 device to the VM (Proxmox: qm set <vmid> --tpmstate0 <storage>:1,version=v2.0), then seal-aws-profile.sh $AWS_PROF" ;;
      *) warn "aws profile $AWS_PROF: $_cf has a systemd-creds header this kit does not know — sealed to what?" ;;
    esac
  elif [[ -n "$_cp" ]]; then
    ok "aws profile $AWS_PROF: credential_process = $_cp"
  fi   # neither: the STS call below reports the missing profile
fi
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

# git: deploy keys and/or one PAT, per git_auth (lib-deploy-keys.sh); each
# repo is served by whichever covers it. The workstation's YubiKey FIDO2 keys need a physical
# press per signature — a cron hangs on them forever — so none live here.
if compgen -G "$HOME/.ssh/*_sk*" >/dev/null || compgen -G "$HOME/.ssh/github_yub_*" >/dev/null; then
  warn "FIDO2 (-sk) ssh key present in ~/.ssh — unusable by unattended jobs (needs a touch)"
fi
auth_has token || auth_has deploy-keys || warn "git_auth='$GIT_AUTH' names no mode (deploy-keys | token | both)"
if auth_has token && token_login; then
  # probe every https-served repo: configs_repo unless an alias serves it,
  # and each clone_repos entry without a deploy key of its own
  _cfg="$(conf_get configs_repo '')"
  [[ "$_cfg" == https://* ]] && token_probe "$(repo_slug "$_cfg")"
  for r in $CLONE_REPOS; do r="${r%%:*}"; deploy_name_for "$r" >/dev/null || token_probe "$r"; done
fi
if auth_has deploy-keys; then
  if [[ -z "$DEPLOY_REPOS" ]]; then
    warn "deploy_repos empty in host conf — no repo can be pulled by deploy key"
  else
    deploy_each deploy_ensure
    deploy_each deploy_probe
    _show_pub() { [[ -f "$3.pub" ]] && log "$1 public key: $(cat "$3.pub")"; }
    deploy_each _show_pub
  fi
fi
clone_wanted

exit 0
