#!/bin/bash
# Calibration for the worker's sealed AWS key (03-headless §5 +
# seal-aws-profile.sh). The job identity used to be a static key in plaintext
# at ~/.aws/credentials (mode 600 — readable by anything running as the user,
# and by anyone who lifts the disk). Now it is a user-scoped systemd-creds blob
# bound to the TPM2 + host key + uid + machine-id, handed to the aws CLI by
# credential_process, and the doctor reads the blob header to tell a TPM seal
# from a host-key-only one (2026-09-16, ai-3090 gained a vTPM for this).
#
# Contract (stubbed aws / systemd-creds / systemd-analyze, no network, no sudo):
#   A. doctor, plaintext profile: WARN names plaintext, hint names the helper,
#      check mode seals nothing
#   B. doctor, blob sealed with the TPM2+host header, credential_process set: OK
#   C. doctor, blob sealed with the host-only header: WARN says host key only
#   D. doctor install, plaintext: blob written with the TPM header,
#      credential_process wired, [profile] gone from credentials, others kept
#   E. helper, STS fails through the sealed path: plaintext kept, exit 1
#   F. helper, host-only blob + TPM now present: re-sealed to the TPM header
#      without needing the plaintext back
#   G. helper, nothing to seal: refuses by name, exit 1
#   H. helper on an already-sealed profile: no-op, files byte-identical
#   I. helper, no TPM2: still seals (host key + uid), says so
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out"; fi; }

HDR_TPM=ef4ac13679a9480ea7db68897f9f165d    # CRED_AES256_GCM_BY_HOST_AND_TPM2_HMAC_SCOPED
HDR_HOST=55b9ed1d38594d43a8319d2ebb332ac6   # CRED_AES256_GCM_BY_HOST_SCOPED
mkdir -p "$TMP/bin"
# systemd-creds: encrypt = header (chosen by STUB_HDR) + plaintext, base64;
# decrypt = strip the header. --user/--name are accepted and ignored.
cat > "$TMP/bin/systemd-creds" <<'S'
#!/bin/bash
cmd=$1; shift; pos=(); for a; do [[ $a == -* && $a != - ]] || pos+=("$a"); done
in=${pos[0]}; out=${pos[1]}
[[ $in == - ]] && in=/dev/stdin; [[ $out == - ]] && out=/dev/stdout
case $cmd in
  encrypt) { printf "$(sed 's/../\\x&/g' <<<"$STUB_HDR")"; cat "$in"; } | base64 -w0 > "$out" ;;
  decrypt) base64 -d "$in" | tail -c +17 > "$out" ;;
esac
S
cat > "$TMP/bin/systemd-analyze" <<'S'
#!/bin/bash
[[ $1 == has-tpm2 ]] || exit 0; [[ ${STUB_TPM:-yes} == yes ]] && { echo yes; exit 0; }; echo no; exit 1
S
# aws: `configure set` appends to config; `sts get-caller-identity` answers
# unless STUB_STS_FAIL, or STUB_SEALED_FAIL when the static file is masked
# (that is how the helper proves the credential_process path on its own)
cat > "$TMP/bin/aws" <<'S'
#!/bin/bash
prof=default; sub=(); while (($#)); do case $1 in --profile) prof=$2; shift 2;; --*) shift 2;; *) sub+=("$1"); shift;; esac; done
case "${sub[0]} ${sub[1]}" in
  "configure set") printf '[profile %s]\n%s = %s\n' "$prof" "${sub[2]}" "${sub[3]}" >> "$HOME/.aws/config" ;;
  "sts get-caller-identity")
    [[ -n ${STUB_STS_FAIL:-} ]] && exit 255
    [[ ${AWS_SHARED_CREDENTIALS_FILE:-} == /dev/null && -n ${STUB_SEALED_FAIL:-} ]] && exit 255
    echo "arn:aws:iam::1:user/pub" ;;
  *) exit 1 ;;
esac
S
for s in systemctl loginctl sudo lspci; do printf '#!/bin/bash\ncase "$1" in get-default) echo multi-user.target;; show-user) echo yes;; esac\nexit 0\n' > "$TMP/bin/$s"; done
chmod +x "$TMP/bin/"*

H="$TMP/home"; CRED="$H/.config/credstore.encrypted/aws-pub.cred"
reset() {  # <plaintext yes|no> [blob-header]
  rm -rf "$H"; mkdir -p "$H/.aws" "$H/.ssh"
  printf '[other]\naws_access_key_id = AKIAOTHER\naws_secret_access_key = so\n' > "$H/.aws/credentials"
  [[ $1 == yes ]] && printf '[pub]\naws_access_key_id = AKIAPUB\naws_secret_access_key = sekrit\n' >> "$H/.aws/credentials"
  printf '[profile pub]\nregion = us-east-1\n' > "$H/.aws/config"
  if [[ -n ${2:-} ]]; then
    mkdir -p "$(dirname "$CRED")"
    STUB_HDR=$2 "$TMP/bin/systemd-creds" encrypt --user --name=aws-pub <(printf '{"Version":1,"AccessKeyId":"AKIAPUB","SecretAccessKey":"sekrit"}') "$CRED"
    printf 'credential_process = systemd-creds decrypt --user --name=aws-pub %s -\n' "$CRED" >> "$H/.aws/config"
  fi
  printf 'profile=worker\naws_profile=pub\n' > "$TMP/host.conf"
}
ENV=(PATH="$TMP/bin:$PATH" HOME="$H" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 STUB_HDR="$HDR_TPM")
doctor() { env "${ENV[@]}" "$@" bash "$KIT_DIR/profiles/worker/03-headless.sh" "${MODE:-check}" 2>&1 | sed -n '/machine credentials/,/git:/p' > "$TMP/out"; }
helper() { env "${ENV[@]}" "$@" bash "$KIT_DIR/profiles/worker/seal-aws-profile.sh" pub > "$TMP/out" 2>&1; echo "rc=$?" >> "$TMP/out"; }
hdr_of() { base64 -d "$1" | head -c 16 | od -An -tx1 | tr -d ' \n'; }

reset yes
doctor
assert "A. plaintext: warned by name, helper hinted, nothing sealed in check mode" \
  'grep -q "WARN.*plaintext" "$TMP/out" && grep -q "seal-aws-profile.sh pub" "$TMP/out" && [[ ! -e "$CRED" ]] && grep -q "^\[pub\]" "$H/.aws/credentials"'

reset no "$HDR_TPM"
doctor
assert "B. TPM-sealed blob + credential_process: OK names TPM2" \
  'grep -q "OK.*sealed.*TPM2" "$TMP/out" && ! grep -q "WARN.*aws profile" "$TMP/out"'

reset no "$HDR_HOST"
doctor
assert "C. host-only blob: WARN says host key only" 'grep -q "WARN.*host key only" "$TMP/out"'

reset yes
MODE=install doctor
assert "D. install: TPM header blob, credential_process wired, plaintext section gone, others kept" \
  '[[ "$(hdr_of "$CRED")" == "$HDR_TPM" ]] && grep -q "credential_process = systemd-creds decrypt --user --name=aws-pub $CRED -" "$H/.aws/config" \
   && ! grep -q "^\[pub\]" "$H/.aws/credentials" && ! grep -q sekrit "$H/.aws/credentials" && grep -q "^\[other\]" "$H/.aws/credentials" && grep -q AKIAOTHER "$H/.aws/credentials" \
   && grep -q "OK.*sealed.*TPM2" "$TMP/out"'
assert "D2. install: blob and its dir are private" '[[ "$(stat -c %a "$CRED")" == 600 && "$(stat -c %a "$(dirname "$CRED")")" == 700 ]]'

reset yes
helper STUB_SEALED_FAIL=1
assert "E. sealed path can't authenticate: plaintext kept, exit 1" \
  'grep -q "rc=1" "$TMP/out" && grep -q "^\[pub\]" "$H/.aws/credentials" && grep -q "plaintext kept" "$TMP/out"'

reset no "$HDR_HOST"
helper
assert "F. host-only blob re-sealed to the TPM header, no plaintext needed" \
  'grep -q "rc=0" "$TMP/out" && [[ "$(hdr_of "$CRED")" == "$HDR_TPM" ]] && [[ "$(base64 -d "$CRED" | tail -c +17)" == *AKIAPUB* ]]'

reset no
helper
assert "G. nothing to seal: refused by name" 'grep -q "rc=1" "$TMP/out" && grep -q "nothing to seal" "$TMP/out" && grep -q "aws configure --profile pub" "$TMP/out"'

reset no "$HDR_TPM"
before="$(cat "$CRED" "$H/.aws/config" "$H/.aws/credentials" | md5sum)"
helper
assert "H. already sealed: no-op, files untouched" \
  'grep -q "rc=0" "$TMP/out" && grep -q "already sealed" "$TMP/out" && [[ "$(cat "$CRED" "$H/.aws/config" "$H/.aws/credentials" | md5sum)" == "$before" ]]'

reset yes
helper STUB_TPM=no STUB_HDR="$HDR_HOST"
assert "I. no TPM2: seals to the host key and says so" \
  'grep -q "rc=0" "$TMP/out" && grep -qi "no TPM2" "$TMP/out" && [[ "$(hdr_of "$CRED")" == "$HDR_HOST" ]] && ! grep -q "^\[pub\]" "$H/.aws/credentials"'

echo "  $pass passed, $fail failed"; (( fail == 0 ))
