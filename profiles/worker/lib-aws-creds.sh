#!/bin/bash
# Sealed AWS job identity, shared by 03-headless.sh §5 (verify) and
# seal-aws-profile.sh (convert). Source after lib.sh.
#
# The job's static key lives as a USER-SCOPED systemd-creds blob under
# ~/.config/credstore.encrypted/aws-<profile>.cred, and the aws profile reaches
# it through credential_process (aws CLI runs `systemd-creds decrypt` itself,
# so no unit, no wrapper, works from a timer, a cron, or a shell). User scope
# encrypts through the system's credentials service (/run/systemd/
# io.systemd.Credentials), so the user needs no tss group and no direct TPM
# access; the key is HMAC(host secret ⊕ TPM2, uid + username + machine-id).
# A blob therefore dies with the VM: another box, another user, or a restored
# vTPM state cannot open it — re-seed from the key's owner instead.
#
# The first 16 bytes of the decoded blob name the key type (systemd
# src/shared/creds-util.h). That header is the doctor's instrument: it tells a
# TPM2-bound seal from a host-key-only one made on a box that had no TPM yet.
AWS_CRED_DIR="$HOME/.config/credstore.encrypted"
aws_cred_file() { echo "$AWS_CRED_DIR/aws-$1.cred"; }
aws_cred_name() { echo "aws-$1"; }
# the credential_process line the profile must carry, verbatim
aws_cred_process_want() { echo "systemd-creds decrypt --user --name=$(aws_cred_name "$1") $(aws_cred_file "$1") -"; }

# aws_ini_get <file> <section> <key> — first value of key inside [section]
aws_ini_get() {
  [[ -r "$1" ]] || return 1
  awk -v s="[$2]" -v k="$3" '
    /^[[:space:]]*\[/ { insec = ($0 == s) ; next }
    insec && $1 == k && $2 == "=" { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }
    insec && index($0, k "=") == 1 { sub(/^[^=]*=[[:space:]]*/, ""); print; exit }
  ' "$1"
}
# aws_ini_drop <file> <section> — remove [section] and its keys, keep the rest
aws_ini_drop() {
  awk -v s="[$2]" '
    /^[[:space:]]*\[/ { skip = ($0 == s) }
    !skip
  ' "$1"
}
# the config section for a profile: [profile X], except [default]
aws_cfg_section() { [[ "$1" == default ]] && echo default || echo "profile $1"; }

aws_plaintext()    { [[ -n "$(aws_ini_get "$HOME/.aws/credentials" "$1" aws_secret_access_key)" ]]; }
aws_cred_process() { aws_ini_get "$HOME/.aws/config" "$(aws_cfg_section "$1")" credential_process; }

# aws_seal_kind <blob> → tpm2+host | host | other, from the header UUID
aws_seal_kind() {
  local h; h="$(base64 -d "$1" 2>/dev/null | head -c 16 | od -An -tx1 | tr -d ' \n')"
  case "$h" in
    ef4ac13679a9480ea7db68897f9f165d|2a1f877a4275431ab3f9ed1f5d8f6601|\
    adbc4ca3efb64201ba881b6f2e4095ea|16e492949f94400286758f94b7c52bc7) echo tpm2+host ;;  # *_HOST_AND_TPM2_HMAC[_WITH_PK]_SCOPED[_PINNED_SRK]
    55b9ed1d38594d43a8319d2ebb332ac6) echo host ;;                                        # CRED_AES256_GCM_BY_HOST_SCOPED
    *) echo other ;;
  esac
}
has_tpm2() { [[ "$(systemd-analyze has-tpm2 2>/dev/null | head -1)" == yes ]]; }
