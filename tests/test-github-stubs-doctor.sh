#!/bin/bash
# Calibration for profiles/workstation/preamble-github-auth.sh:
#   - Both canonical GitHub FIDO2 stubs (primary 37183681, backup 37183574)
#     reported by .pub blob (not filename), verified against `gh ssh-key list`
#   - Explicit "not verified against GitHub" + distinct local pair count when gh is absent/unauth
#   - Copy route (`copy <user@host>`): single announced ssh tar stream with accept-new + ConnectTimeout,
#     keeps only `sk-ssh-ed25519@openssh.com ... ssh:github` pairs, never overwrites, exits nonzero on
#     incomplete transfer, runs regardless of configs_repo
#   - Prompt-count announcements before ssh-keygen -K, ssh -T, and git clone (counting only -sk keys)
#   - D1 offline URL resolution: phases never touch card; insteadOf HTTPS and plain SSH keep retries
set -uo pipefail
unset GH_TOKEN GH_CONFIG_DIR
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

BLOB_PRI="AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIPq7tk0LLYkQ0tCvzhbIV6jpLsurASPl/AQABO8Q+KJPAAAACnNzaDpnaXRodWI="
BLOB_BAK="AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIExgpqLE/gbbz8dyFdxO1Bv5efCDLJTP6eC6T2w0TLnkAAAACnNzaDpnaXRodWI="
BLOB_UNREG="AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAnNzaDpnaXRodWI="
BLOB_OTHER="AAAAC3NzaC1lZDI1NTE5AAAAINotASecurityKeyBlobAtAll1234567890"

pass=0; fail=0
assert() {
  if eval "$2"; then ((pass++)); echo "  ok   $1"
  else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' <<<"${out:-}" | tail -25; fi
}

new_env() {
  rm -rf "$TMP/home" "$TMP/bin" "$TMP/logs" "$TMP/calls"
  H="$TMP/home"; B="$TMP/bin"; CALLS="$TMP/calls"
  mkdir -p "$H/.ssh" "$H/git/.configs/.git" "$B" "$TMP/logs"
  chmod 700 "$H/.ssh"
  : > "$CALLS"
  printf 'Host github.com\n  HostName ssh.github.com\n  Port 443\n  ControlMaster auto\n  IdentitiesOnly yes\n  IdentityAgent none\n' > "$H/.ssh/config"
  chmod 600 "$H/.ssh/config"

  cat > "$B/gh" <<F
#!/bin/bash
echo "gh \$*" >> "$CALLS"
if [[ "\${GH_FAIL:-0}" == 1 ]]; then
  echo "To get started with GitHub CLI, please run: gh auth login" >&2
  exit 4
fi
if [[ "\$1 \$2" == "ssh-key list" ]]; then
  printf 'YubiKey 5C NFC (37183681)\tsk-ssh-ed25519@openssh.com %s\t2026-06-08T12:50:44Z\t101\tauthentication\n' "$BLOB_PRI"
  printf 'YubiKey 5C NFC backup (37183574)\tsk-ssh-ed25519@openssh.com %s\t2026-06-08T13:27:22Z\t102\tauthentication\n' "$BLOB_BAK"
  exit 0
fi
exit 0
F
  chmod +x "$B/gh"
}

make_stub() { # name blob [app] [type]
  local name="$1" blob="$2" app="${3:-ssh:github}" typ="${4:-sk-ssh-ed25519@openssh.com}"
  echo "private-stub-$name" > "$H/.ssh/$name"
  echo "$typ $blob $app" > "$H/.ssh/$name.pub"
  chmod 600 "$H/.ssh/$name"
}

run_pre() { # [args...]
  ( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" HOST_CONF=/dev/null KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
    bash profiles/workstation/preamble-github-auth.sh "$@" 2>&1 )
}

echo "github stubs doctor + copy route"

# A. Missing backup stub warns; primary identified by .pub blob even with legacy filename
new_env
make_stub id_ed25519_sk_rk_github_primary "$BLOB_PRI"
printf '  IdentityFile %s\n' "$H/.ssh/id_ed25519_sk_rk_github_primary" >> "$H/.ssh/config"
out="$(run_pre check)"
assert "A1: missing backup stub warns" \
  'grep -qE "\[WARN\].*(github_yub_backup|37183574).*missing" <<<"$out"'
assert "A2: primary identified by blob under legacy filename (not warned missing)" \
  'grep -qE "\[ OK \].*(github_yub_primary|37183681)" <<<"$out" && ! grep -qE "\[WARN\].*(github_yub_primary|37183681).*missing" <<<"$out"'
assert "A3: missing stub hint names both recover and copy routes" \
  'grep -q "preamble-github-auth.sh recover" <<<"$out" && grep -q "preamble-github-auth.sh copy" <<<"$out"'

# B. Both stubs present under legacy filenames -> both OK, no missing warning
new_env
make_stub id_ed25519_sk_rk_github_primary "$BLOB_PRI"
make_stub id_ed25519_sk_rk_github "$BLOB_BAK"
printf '  IdentityFile %s\n  IdentityFile %s\n' "$H/.ssh/id_ed25519_sk_rk_github_primary" "$H/.ssh/id_ed25519_sk_rk_github" >> "$H/.ssh/config"
out="$(run_pre check)"
assert "B: both legacy-named stubs matched by blob with no missing warning" \
  'grep -qE "\[ OK \].*github_yub_primary" <<<"$out" && grep -qE "\[ OK \].*github_yub_backup" <<<"$out" && ! grep -qE "\[WARN\].*missing" <<<"$out"'

# C. Two files with canonical names, BOTH containing primary blob -> backup still warned missing!
new_env
make_stub github_yub_primary "$BLOB_PRI"
make_stub github_yub_backup "$BLOB_PRI"
printf '  IdentityFile %s\n  IdentityFile %s\n' "$H/.ssh/github_yub_primary" "$H/.ssh/github_yub_backup" >> "$H/.ssh/config"
out="$(run_pre check)"
assert "C: misnamed backup holding primary blob still warns backup missing" \
  'grep -qE "\[WARN\].*(github_yub_backup|37183574).*missing" <<<"$out"'

# D. Local stub not registered on GitHub warns
new_env
make_stub github_yub_primary "$BLOB_PRI"
make_stub github_yub_backup "$BLOB_BAK"
make_stub github_yub_stale "$BLOB_UNREG"
printf '  IdentityFile %s\n  IdentityFile %s\n  IdentityFile %s\n' "$H/.ssh/github_yub_primary" "$H/.ssh/github_yub_backup" "$H/.ssh/github_yub_stale" >> "$H/.ssh/config"
out="$(run_pre check)"
assert "D: unregistered local stub warns" \
  'grep -qE "\[WARN\].*github_yub_stale.*not registered on GitHub" <<<"$out"'

# D2 (F8). Signing-only row does not satisfy auth check; later signing row does not overwrite auth mapping
new_env
cat > "$B/gh" <<F
#!/bin/bash
if [[ "\$1 \$2" == "ssh-key list" ]]; then
  printf 'YubiKey 5C NFC (37183681)\tsk-ssh-ed25519@openssh.com %s\t2026-06-08T12:50:44Z\t101\tauthentication\n' "$BLOB_PRI"
  printf 'YubiKey 5C NFC sign (37183681)\tsk-ssh-ed25519@openssh.com %s\t2026-06-08T12:55:00Z\t103\tsigning\n' "$BLOB_UNREG"
  printf 'YubiKey 5C NFC backup (37183574)\tsk-ssh-ed25519@openssh.com %s\t2026-06-08T13:27:22Z\t102\tsigning\n' "$BLOB_BAK"
  exit 0
fi
exit 0
F
chmod +x "$B/gh"
make_stub github_yub_primary "$BLOB_PRI"
make_stub github_yub_backup "$BLOB_BAK"
printf '  IdentityFile %s\n  IdentityFile %s\n' "$H/.ssh/github_yub_primary" "$H/.ssh/github_yub_backup" >> "$H/.ssh/config"
out="$(run_pre check)"
assert "D2 (F8): signing rows ignored (primary auth kept, backup signing-only rejected)" \
  'grep -qE "\[ OK \].*github_yub_primary" <<<"$out" && grep -qE "\[WARN\].*github_yub_backup.*not registered on GitHub" <<<"$out" && grep -qE "\[WARN\].*37183574" <<<"$out"'

# E. gh absent -> explicitly says "not verified against GitHub"
new_env
make_stub github_yub_primary "$BLOB_PRI"
make_stub github_yub_backup "$BLOB_BAK"
NOGH="$TMP/bin-nogh"; rm -rf "$NOGH"; mkdir -p "$NOGH"
ln -s /usr/bin/* "$NOGH/" 2>/dev/null || true
rm -f "$NOGH/gh"
out="$( cd "$KIT_DIR" && PATH="$NOGH" HOME="$H" HOST_CONF=/dev/null KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
        bash profiles/workstation/preamble-github-auth.sh check 2>&1 )"
assert "E: gh absent explicitly says not verified against GitHub" \
  'grep -qi "not verified against GitHub" <<<"$out" && grep -q "\[WARN\]" <<<"$out"'

# F. gh not logged in -> explicitly says "not verified against GitHub" + distinct pair count (no filename fallback)
new_env
make_stub id_ed25519_sk_rk_github_primary "$BLOB_PRI"
out="$(GH_FAIL=1 run_pre check)"
assert "F1: gh not logged in explicitly says not verified against GitHub" \
  'grep -qi "not verified against GitHub" <<<"$out" && grep -q "\[WARN\]" <<<"$out"'
assert "F2 (F10): reports 1 distinct local pair without filename-based missing-serial warnings" \
  'grep -qE "1 distinct local stub pair" <<<"$out" && ! grep -qE "37183681.*missing|37183574.*missing" <<<"$out"'

# G. Copy route (D4/F3/F6/F11): single announced ssh tar stream, filters strictly, never overwrites, exits nonzero on incomplete, ignores configs_repo
new_env
REM_HOME="$TMP/remote-home"; REM="$REM_HOME/.ssh"
rm -rf "$REM_HOME"; mkdir -p "$REM"
echo "remote-primary" > "$REM/github_yub_primary"
echo "sk-ssh-ed25519@openssh.com $BLOB_PRI ssh:github" > "$REM/github_yub_primary.pub"
echo "remote-backup" > "$REM/github_yub_backup"
echo "sk-ssh-ed25519@openssh.com $BLOB_BAK ssh:github" > "$REM/github_yub_backup.pub"
echo "remote-regular" > "$REM/id_ed25519"
echo "ssh-ed25519 $BLOB_OTHER user@box" > "$REM/id_ed25519.pub"
echo "remote-other-app" > "$REM/id_ed25519_sk_rk_other"
echo "sk-ssh-ed25519@openssh.com $BLOB_UNREG ssh:otherapp" > "$REM/id_ed25519_sk_rk_other.pub"

# Pre-existing local primary that must NOT be overwritten
echo "local-existing-primary" > "$H/.ssh/github_yub_primary"
echo "sk-ssh-ed25519@openssh.com $BLOB_PRI ssh:github" > "$H/.ssh/github_yub_primary.pub"
chmod 600 "$H/.ssh/github_yub_primary"

cat > "$B/ssh" <<F
#!/bin/bash
echo "ssh \$*" >> "$CALLS"
echo "MARKER_COPY_SSH" >&2
# Parse ssh options, then host and remote command
while (( \$# )); do
  case "\$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
host="\$1"; shift
cmd="\$*"
HOME="$REM_HOME" /bin/sh -c "\$cmd"
F
cat > "$B/scp" <<F
#!/bin/bash
echo "scp \$*" >> "$CALLS"
exit 99
F
chmod +x "$B/ssh" "$B/scp"

out="$(run_pre copy brandon@LinuxBeast)"; rc=$?
assert "G1: copy route exits 0" \
  '[[ $rc -eq 0 ]]'
assert "G2 (F3): single announced ssh connection (0 scp), accept-new + ConnectTimeout, notice before ssh" \
  '[[ $(grep "^ssh " "$CALLS" | grep -vc -- " -G ") -eq 1 ]] && [[ $(grep -c "^scp " "$CALLS") -eq 0 ]] && grep -q "StrictHostKeyChecking=accept-new" "$CALLS" && grep -q "ConnectTimeout=" "$CALLS" && awk "/1 .*connection.*brandon@LinuxBeast.*YubiKey/{seen=1} /MARKER_COPY_SSH/{hit=1; exit !seen} END{exit !(seen && hit)}" <<<"$out"'
assert "G3: backup github sk stub copied and pinned" \
  '[[ -f "$H/.ssh/github_yub_backup" && -f "$H/.ssh/github_yub_backup.pub" ]] && grep -qx "remote-backup" "$H/.ssh/github_yub_backup" && grep -q "IdentityFile $H/.ssh/github_yub_backup" "$H/.ssh/config"'
assert "G4: non-github / non-sk keys NOT copied" \
  '[[ ! -e "$H/.ssh/id_ed25519" && ! -e "$H/.ssh/id_ed25519.pub" && ! -e "$H/.ssh/id_ed25519_sk_rk_other" && ! -e "$H/.ssh/id_ed25519_sk_rk_other.pub" ]]'
assert "G5: existing stub file NEVER overwritten" \
  'grep -qx "local-existing-primary" "$H/.ssh/github_yub_primary"'

# G6 (F6): incomplete transfer (matching .pub without private stub) exits nonzero and installs no half-pair
rm -f "$H/.ssh/github_yub_backup" "$H/.ssh/github_yub_backup.pub" "$REM/github_yub_backup"
out="$(run_pre copy brandon@LinuxBeast)"; rc=$?
assert "G6 (F6): incomplete pair exits nonzero and installs no half-pair" \
  '[[ $rc -ne 0 ]] && [[ ! -e "$H/.ssh/github_yub_backup" && ! -e "$H/.ssh/github_yub_backup.pub" ]] && grep -qi "incomplete" <<<"$out" && ! grep -q "copy done" <<<"$out"'

# G7 (F11): copy runs even when configs_repo is HTTPS
echo "remote-backup" > "$REM/github_yub_backup"
printf 'configs_repo=https://github.com/hotpocket/.configs.git\n' > "$TMP/https.conf"
out="$( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" HOST_CONF="$TMP/https.conf" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
        bash profiles/workstation/preamble-github-auth.sh copy brandon@LinuxBeast 2>&1 )"; rc=$?
assert "G7 (F11): copy runs and pins even when configs_repo is HTTPS" \
  '[[ $rc -eq 0 ]] && [[ -f "$H/.ssh/github_yub_backup" && -f "$H/.ssh/github_yub_backup.pub" ]]'

# H. Prompt counts (D2/F9): printed BEFORE ssh-keygen -K, ssh -T, git clone; counts only -sk keys; exact D2 wording; no BatchMode claim
new_env
rm -rf "$H/git/.configs"
make_stub github_yub_primary "$BLOB_PRI"
make_stub github_yub_backup "$BLOB_BAK"
make_stub id_ed25519_plain "$BLOB_OTHER" "user@box" "ssh-ed25519"
printf '  IdentityFile %s\n  IdentityFile %s\n  IdentityFile %s\n' \
  "$H/.ssh/github_yub_primary" "$H/.ssh/github_yub_backup" "$H/.ssh/id_ed25519_plain" >> "$H/.ssh/config"
cat > "$B/ssh-keygen" <<F
#!/bin/bash
if [[ " \$* " == *" -K "* ]]; then
  echo "MARKER_SSH_KEYGEN_K"
  echo "stub-37183681" > id_ed25519_sk_rk_github
  echo "sk-ssh-ed25519@openssh.com $BLOB_PRI ssh:github" > id_ed25519_sk_rk_github.pub
  exit 0
fi
exec /usr/bin/ssh-keygen "\$@"
F
cat > "$B/ykman" <<'F'
#!/bin/bash
echo "37183681"
F
cat > "$B/lsusb" <<'F'
#!/bin/bash
echo "Bus 999 Device 999: ID 1050:0407 Yubico.com Yubikey"
F
cat > "$B/ssh" <<'F'
#!/bin/bash
echo "MARKER_SSH_TEST"
echo "Hi hotpocket! You've successfully authenticated, but GitHub does not provide shell access." >&2
exit 1
F
cat > "$B/git" <<'F'
#!/bin/bash
if [[ "$1" == "ls-remote" || ( "$1" == "-C" && "$3" == "ls-remote" ) ]]; then
  exec /usr/bin/git "$@"
fi
echo "MARKER_GIT_CLONE"
exit 1
F
chmod +x "$B/ssh-keygen" "$B/ykman" "$B/lsusb" "$B/ssh" "$B/git"

out="$(run_pre recover)"
assert "H1: recover prints numeric PIN & touch counts BEFORE ssh-keygen -K" \
  'awk "/[0-9]+ PIN.*[0-9]+ touch/{seen=1} /MARKER_SSH_KEYGEN_K/{hit=1; exit !seen} END{exit !(seen && hit)}" <<<"$out"'
assert "H2 (F9/D2): ssh -T notice counts only -sk keys (2, not 3), uses D2 wording, no BatchMode claim" \
  'awk "/MARKER_SSH_KEYGEN_K/{after=1; next} after && /YubiKey: up to 4 touches and 2 PIN \(per pinned key/{seen=1} /MARKER_SSH_TEST/{hit=1; exit !seen} END{exit !(seen && hit)}" <<<"$out" && ! grep -qi "BatchMode" <<<"$out"'

out="$(run_pre install </dev/null)"
assert "H3 (F9/D2): clone prints D2 wording with N=2 sk keys BEFORE git clone" \
  'awk "/YubiKey: up to 4 touches and 2 PIN \(per pinned key/{seen=1} /MARKER_GIT_CLONE/{hit=1; exit !seen} END{exit !(seen && hit)}" <<<"$out"'

# I. D1 / F1 / F4: offline URL resolution; phases never touch card; insteadOf HTTPS & plain SSH keep current behaviour
# I1: preamble with insteadOf -> HTTPS does NOT print YubiKey notice and does NOT run ssh-keygen -K on failed clone
printf '[url "https://github.com/"]\n\tinsteadOf = git@github.com:\n' > "$H/.gitconfig"
out="$(run_pre install </dev/null)"
assert "I1 (F1): preamble with insteadOf HTTPS prints no YubiKey touch notice and skips card recovery" \
  '! grep -q "YubiKey: up to" <<<"$out" && ! grep -q "MARKER_SSH_KEYGEN_K" <<<"$out"'

# I2: phase 06 with real SSH GitHub + pinned sk key skips clone on pass 1 and points to preamble
rm -f "$H/.gitconfig"
: > "$CALLS"
cat > "$B/git" <<F
#!/bin/bash
if [[ "\$1" == "ls-remote" || ( "\$1" == "-C" && "\$3" == "ls-remote" ) ]]; then
  exec /usr/bin/git "\$@"
fi
echo "git \$*" >> "$CALLS"
exit 1
F
chmod +x "$B/git"
out="$( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" HOST_CONF=/dev/null KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 KIT_PASS=1 \
        bash profiles/workstation/06-configs.sh install </dev/null 2>&1 )"
assert "I2 (D1/F4): phase 06 skips card-backed SSH clone on pass 1 and points to preamble" \
  '! grep -q "^git clone" "$CALLS" && grep -qi "preamble" <<<"$out" && grep -q "preamble-github-auth.sh" <<<"$out"'

# I3: phase 06 with insteadOf -> HTTPS still runs git clone on pass 2 (no card skip, no YubiKey notice)
printf '[url "https://github.com/"]\n\tinsteadOf = git@github.com:\n' > "$H/.gitconfig"
: > "$CALLS"
out="$( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" HOST_CONF=/dev/null KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 KIT_PASS=2 \
        bash profiles/workstation/06-configs.sh install </dev/null 2>&1 )"
assert "I3 (D1/F1): phase 06 with insteadOf HTTPS still clones on pass 2 with no YubiKey notice" \
  'grep -q "^git clone" "$CALLS" && ! grep -qi "YubiKey" <<<"$out"'

# I4: phase 06 with plain SSH (only ssh-ed25519 pinned, no -sk key) still clones on pass 2
rm -f "$H/.gitconfig"
printf 'Host github.com\n  HostName ssh.github.com\n  Port 443\n  IdentityFile %s\n' "$H/.ssh/id_ed25519_plain" > "$H/.ssh/config"
: > "$CALLS"
out="$( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" HOST_CONF=/dev/null KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 KIT_PASS=2 \
        bash profiles/workstation/06-configs.sh install </dev/null 2>&1 )"
assert "I4 (D1): phase 06 with plain SSH (no pinned -sk key) still clones on pass 2" \
  'grep -q "^git clone" "$CALLS"'

# I5: phase 08 stale pull — skips when card transport (pass 1), still pulls when insteadOf HTTPS (pass 2)
printf 'Host github.com\n  HostName ssh.github.com\n  Port 443\n  IdentityFile %s\n' "$H/.ssh/github_yub_primary" > "$H/.ssh/config"
printf '#!/bin/bash\necho "claude 2.0.0"\n' > "$B/claude"; chmod +x "$B/claude"
/usr/bin/git init -q "$H/git/.configs"
/usr/bin/git -C "$H/git/.configs" remote add origin git@github.com:hotpocket/.configs.git
printf 'component_claude_code=no\nclaude_skills=conduct\n' > "$TMP/p08.conf"
: > "$CALLS"
out="$( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" HOST_CONF="$TMP/p08.conf" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 KIT_PASS=1 \
        bash profiles/workstation/08-claude-skills.sh install </dev/null 2>&1 )"
assert "I5a (D1): phase 08 skips card-backed SSH stale pull on pass 1 and warns" \
  '! grep -q "pull" "$CALLS" && grep -q "\[WARN\]" <<<"$out" && grep -q "git -C" <<<"$out"'

printf '[url "https://github.com/"]\n\tinsteadOf = git@github.com:\n' > "$H/.gitconfig"
: > "$CALLS"
out="$( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" HOST_CONF="$TMP/p08.conf" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 KIT_PASS=2 \
        bash profiles/workstation/08-claude-skills.sh install </dev/null 2>&1 )"
assert "I5b (D1/F1): phase 08 with insteadOf HTTPS still runs stale pull on pass 2 with no YubiKey notice" \
  'grep -q "pull" "$CALLS" && ! grep -qi "YubiKey" <<<"$out"'

echo
echo "test-github-stubs-doctor: $pass passed, $fail failed"
(( fail == 0 ))
