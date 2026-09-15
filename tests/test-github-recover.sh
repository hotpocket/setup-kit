#!/bin/bash
# `preamble-github-auth.sh recover` enrols the PLUGGED YubiKey on an
# already-provisioned machine. Without it: a second YubiKey's resident key is
# only ever recovered when the .configs clone FAILS — on a box where .configs
# is already cloned there was no path to add the other token (2026-09-14: the
# primary key was plugged, the stanza pinned only the backup's credential,
# every pull died with FIDO_ERR_NO_CREDENTIALS, and the fix lived in the repo
# that could not be pulled).
#
# Contract (recover mode, .configs already cloned, fake ssh-keygen/ykman/ssh):
#   A. recovers even though .configs is cloned; key lands at its serial's
#      canonical name (github_yub_primary) and is pinned in the stanza
#   B. re-run with the same token: file kept, no duplicate IdentityFile
#   C. the other serial: github_yub_backup added, both pinned, primary first
#   D. exits 0 when `ssh -T` greets; non-zero (and says so) when it does not
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; B="$TMP/bin"; mkdir -p "$H/.ssh" "$H/git/.configs/.git" "$B"
chmod 700 "$H/.ssh"
printf 'Host github.com\n  HostName ssh.github.com\n  Port 443\n  ControlMaster auto\n' > "$H/.ssh/config"; chmod 600 "$H/.ssh/config"

# fakes: ssh-keygen -K writes a stub pair into cwd (real ssh-keygen otherwise);
# ykman reports $SERIAL; lsusb sees a Yubico; ssh -T greets unless $SSH_FAIL.
cat > "$B/ssh-keygen" <<'F'
#!/bin/bash
if [[ " $* " == *" -K "* ]]; then
  echo "stub-$SERIAL" > id_ed25519_sk_rk_github; echo "sk-ssh-ed25519@openssh.com AAAA$SERIAL ssh:github" > id_ed25519_sk_rk_github.pub; exit 0
fi
exec /usr/bin/ssh-keygen "$@"
F
cat > "$B/ykman" <<'F'
#!/bin/bash
echo "$SERIAL"
F
cat > "$B/lsusb" <<'F'
#!/bin/bash
echo "Bus 002 Device 002: ID 1050:0407 Yubico.com Yubikey"
F
cat > "$B/ssh" <<'F'
#!/bin/bash
(( ${SSH_FAIL:-0} )) && { echo "git@ssh.github.com: Permission denied (publickey)." >&2; exit 255; }
echo "Hi hotpocket! You've successfully authenticated, but GitHub does not provide shell access." >&2
exit 1
F
chmod +x "$B"/*
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
run() { ( cd "$KIT_DIR" && PATH="$B:$PATH" SERIAL="$1" HOME="$H" HOST_CONF=/dev/null KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
          bash profiles/workstation/preamble-github-auth.sh recover 2>&1 ); }
idfiles() { sed -nE 's/^[[:space:]]*IdentityFile[[:space:]]+//p' "$H/.ssh/config"; }

echo "github recover mode"
out="$(run 37183681)"; rc=$?
assert "A: exit 0 on greeting"                 '[[ $rc -eq 0 ]]'
assert "A: primary key file created"           '[[ -f "$H/.ssh/github_yub_primary" && -f "$H/.ssh/github_yub_primary.pub" ]]'
assert "A: primary pinned"                     'idfiles | grep -qx "$H/.ssh/github_yub_primary"'
assert "A: IdentityAgent none added"           'grep -qE "^[[:space:]]*IdentityAgent none" "$H/.ssh/config"'
assert "A: says auth works"                    'grep -q "github ssh auth works" <<<"$out"'

echo "stub-37183681" > "$TMP/expect"
out="$(run 37183681)"
assert "B: file not overwritten"               'cmp -s "$H/.ssh/github_yub_primary" "$TMP/expect"'
assert "B: no duplicate IdentityFile"          '[[ $(idfiles | grep -cx "$H/.ssh/github_yub_primary") -eq 1 ]]'

out="$(run 37183574)"
assert "C: backup key file created"            '[[ -f "$H/.ssh/github_yub_backup" ]]'
assert "C: both pinned"                        'idfiles | grep -qx "$H/.ssh/github_yub_backup" && idfiles | grep -qx "$H/.ssh/github_yub_primary"'
assert "C: primary still first"                '[[ $(idfiles | head -1) == "$H/.ssh/github_yub_primary" ]]'

out="$(SSH_FAIL=1 run 37183681)"; rc=$?
assert "D: non-zero when auth fails"           '[[ $rc -ne 0 ]]'
assert "D: names the likely cause"             'grep -qi "registered on GitHub" <<<"$out"'

echo; echo "$pass passed, $fail failed"; exit $(( fail > 0 ))
