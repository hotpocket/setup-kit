#!/bin/bash
# Seal an aws profile's static key: plaintext in ~/.aws/credentials → a
# user-scoped systemd-creds blob (TPM2 + host key + uid + machine-id) read by
# the aws CLI through credential_process. The key is NOT seeded here — it was
# put on the box by a human (`aws configure --profile X`); this only changes
# how it is stored. Idempotent; 03-headless.sh runs it in install mode.
#
#   seal-aws-profile.sh [profile]     default: aws_profile from the host conf
#
# Order of operations is the safety: encrypt, prove the round trip, wire the
# profile, prove STS through the sealed path with the plaintext MASKED, and
# only then drop the plaintext section. A failure anywhere keeps the plaintext.
# A blob sealed before the box had a TPM (header = host key only) is re-sealed
# from its own decrypted content once a TPM2 is present.
SCRIPT_NAME="wk-seal-aws-profile"
source "$(dirname "$0")/../../lib.sh"
source "$(dirname "$0")/lib-aws-creds.sh"
require_user
PROF="${1:-$(conf_get aws_profile cron-deploy)}"
FILE="$(aws_cred_file "$PROF")"; NAME="$(aws_cred_name "$PROF")"

command -v systemd-creds >/dev/null 2>&1 || { fail "systemd-creds not on PATH (systemd ≥ 256 for user-scoped credentials)"; exit 1; }
command -v aws >/dev/null 2>&1 || { fail "aws CLI not installed — nothing can verify the sealed profile"; exit 1; }

# ---- where the key comes from ----------------------------------------------
json=""; source_desc=""
if aws_plaintext "$PROF"; then
  if [[ -n "$(aws_ini_get "$HOME/.aws/credentials" "$PROF" aws_session_token)" ]]; then
    fail "aws profile $PROF carries a session token — that is a temporary login, not a machine credential; refusing to seal it"
    exit 1
  fi
  json="$(printf '{"Version":1,"AccessKeyId":"%s","SecretAccessKey":"%s"}' \
          "$(aws_ini_get "$HOME/.aws/credentials" "$PROF" aws_access_key_id)" \
          "$(aws_ini_get "$HOME/.aws/credentials" "$PROF" aws_secret_access_key)")"
  source_desc="plaintext ~/.aws/credentials [$PROF]"
elif [[ -s "$FILE" ]]; then
  json="$(systemd-creds decrypt --user --name="$NAME" "$FILE" - 2>/dev/null)" \
    || { fail "$FILE exists but this user on this machine cannot decrypt it — re-seed: aws configure --profile $PROF, then re-run"; exit 1; }
  source_desc="the existing blob $FILE"
else
  fail "nothing to seal: no [$PROF] key in ~/.aws/credentials and no $FILE"
  hint "aws configure --profile $PROF   # the job-scoped static key; then re-run this"
  exit 1
fi

# ---- seal (or re-seal) -----------------------------------------------------
kind=""; [[ -s "$FILE" ]] && kind="$(aws_seal_kind "$FILE")"
need_seal=0
if [[ -z "$kind" ]]; then need_seal=1
elif [[ "$kind" == host ]] && has_tpm2; then log "blob is sealed to the host key only and a TPM2 is present now — re-sealing"; need_seal=1
fi
tpm_note="TPM2 + host key"
if ! has_tpm2; then
  tpm_note="host key only — no TPM2 on this box"
  warn "no TPM2 device: the seal binds to the host secret + uid + machine-id, not to hardware (add a vTPM and re-run to upgrade)"
fi
if (( need_seal )); then
  ( umask 077; mkdir -p "$AWS_CRED_DIR" ) && chmod 700 "$AWS_CRED_DIR"
  tmp="$(mktemp "$AWS_CRED_DIR/.$NAME.XXXXXX")"
  if ! printf '%s' "$json" | systemd-creds encrypt --user --name="$NAME" - "$tmp" 2>"$tmp.err"; then
    fail "systemd-creds encrypt failed: $(tr '\n' ' ' < "$tmp.err")"; rm -f "$tmp" "$tmp.err"; exit 1
  fi
  rm -f "$tmp.err"; chmod 600 "$tmp"
  if [[ "$(systemd-creds decrypt --user --name="$NAME" "$tmp" - 2>/dev/null)" != "$json" ]]; then
    fail "sealed blob does not decrypt back to what went in — not installed; plaintext kept"; rm -f "$tmp"; exit 1
  fi
  mv -f "$tmp" "$FILE"
  log "sealed [$PROF] from $source_desc → $FILE ($tpm_note)"
fi

# ---- wire the profile ------------------------------------------------------
want="$(aws_cred_process_want "$PROF")"
if [[ "$(aws_cred_process "$PROF")" != "$want" ]]; then
  aws configure set --profile "$PROF" credential_process "$want" \
    || { fail "aws configure set credential_process failed; plaintext kept"; exit 1; }
  log "~/.aws/config [$(aws_cfg_section "$PROF")]: credential_process → systemd-creds decrypt"
  changed=1
fi
if (( need_seal == 0 && ${changed:-0} == 0 )) && ! aws_plaintext "$PROF"; then
  ok "aws profile $PROF already sealed ($kind) at $FILE — nothing to do"
  exit 0
fi

# ---- prove the sealed path, then drop the plaintext ------------------------
# AWS_SHARED_CREDENTIALS_FILE=/dev/null hides the static key from the CLI, so
# a success here can only have come through credential_process.
if arn="$(AWS_SHARED_CREDENTIALS_FILE=/dev/null timeout 20 aws --profile "$PROF" sts get-caller-identity --query Arn --output text 2>/dev/null)" \
   && [[ -n "$arn" ]]; then
  ok "sealed profile $PROF authenticates: $arn"
else
  fail "sealed profile $PROF can't authenticate through credential_process (no network? wrong key?); plaintext kept"
  hint "AWS_SHARED_CREDENTIALS_FILE=/dev/null aws --profile $PROF sts get-caller-identity"
  exit 1
fi
if aws_plaintext "$PROF"; then
  tmp="$(mktemp "$HOME/.aws/.credentials.XXXXXX")"
  aws_ini_drop "$HOME/.aws/credentials" "$PROF" > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$HOME/.aws/credentials" \
    || { fail "could not rewrite ~/.aws/credentials; plaintext still there"; rm -f "$tmp"; exit 1; }
  log "removed plaintext [$PROF] from ~/.aws/credentials"
fi
ok "aws profile $PROF sealed ($tpm_note): $FILE"
exit 0
