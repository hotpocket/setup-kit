#!/bin/bash
# Calibration for profiles/workstation/06-gpg-pass.sh:
#   - Section 5 pass store doctor: checks actual recipients per .gpg entry via
#     `gpg --list-only --list-packets` mapped to each listed key's encryption
#     subkey(s) (NOT just .gpg-id); warns per key that can't read N entries
#   - Section 6 admin-pat: scope hint includes `workflow`; no-card tag-18 SEIPD
#     length check warns on short non-token and accepts 40-char PAT; unknown
#     packet format (e.g. AEAD tag 20) says "length not judged"; opt-in
#     VERIFY_ADMIN_PAT=1 prints prompt count first, decrypts once, never prints
#     the secret value
#   - Section 4 no card loop: `gpg --card-status` prints 0 PIN, 0 touch first,
#     runs at most once in pass 1 and zero times on pass >= 2 (KIT_PASS=2)
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  GNUPGHOME="$TMP/home/.gnupg" gpgconf --kill gpg-agent 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

H="$TMP/home"; B="$TMP/bin"; STORE="$H/.password-store"; CALLS="$TMP/calls"
mkdir -p "$H/.gnupg" "$H/git/.configs/gnupg" "$STORE/github" "$B" "$TMP/logs"
chmod 700 "$H/.gnupg"
echo "pcsc-shared" > "$H/git/.configs/gnupg/scdaemon.conf"
ln -sf "$H/git/.configs/gnupg/scdaemon.conf" "$H/.gnupg/scdaemon.conf"

# Generate two real throwaway OpenPGP keys (no card involved)
export GNUPGHOME="$H/.gnupg"
gpg --batch --passphrase '' --quick-generate-key "Test Primary <primary@test.local>" default default never >/dev/null 2>&1
gpg --batch --passphrase '' --quick-generate-key "Test Backup <backup@test.local>" default default never >/dev/null 2>&1
mapfile -t FPRS < <(gpg --list-keys --with-colons | awk -F: '$1=="pub"{p=1;next} p&&$1=="fpr"{print $10;p=0}')
FPR1="${FPRS[0]}"
FPR2="${FPRS[1]}"
[[ -n "$FPR1" && -n "$FPR2" ]] || { echo "FAIL: could not generate test GPG keys"; exit 1; }
printf '%s:6:\n%s:6:\n' "$FPR1" "$FPR2" | gpg --import-ownertrust >/dev/null 2>&1

printf 'gpg_key_fpr="%s %s"\n' "$FPR1" "$FPR2" > "$TMP/host.conf"

# Fakes: systemctl active for pcscd; lsusb empty by default; pass records calls
cat > "$B/systemctl" <<'F'
#!/bin/bash
[[ "$1" == "is-active" ]] && exit 0
exit 0
F
cat > "$B/lsusb" <<'F'
#!/bin/bash
[[ "${FAKE_YK:-0}" == 1 ]] && echo "Bus 999 Device 999: ID 1050:0407 Yubico.com Yubikey"
exit 0
F
cat > "$B/scdaemon" <<'F'
#!/bin/bash
exit 0
F
cat > "$B/pass" <<F
#!/bin/bash
echo "pass \$*" >> "$CALLS"
if [[ "\$1" == "show" && "\$2" == "github/admin-pat" ]]; then
  echo "MARKER_PASS_SHOW" >&2
  printf '%s\n' "\${FAKE_PAT_PLAINTEXT:-}"
  exit 0
fi
exit 0
F
chmod +x "$B"/*

pass=0; fail=0
assert() {
  if eval "$2"; then ((pass++)); echo "  ok   $1"
  else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' <<<"${out:-}" | tail -25; fi
}

run06() { # [mode]
  : > "$CALLS"
  ( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" GNUPGHOME="$H/.gnupg" \
    PASSWORD_STORE_DIR="$STORE" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
    bash profiles/workstation/06-gpg-pass.sh "${1:-check}" 2>&1 )
}

# Realistic high-entropy 40-char classic PAT and 6-char non-token
GOOD_PAT="ghp_9xK2mP7vQ4nL8wR1tY6zB3cF5hJ0dS8uE4aG"   # 40 chars
BAD_SHORT="abcdef"                                    # 6 chars

echo "gpg + pass doctor"

# A. .gpg-id lists BOTH keys, but entries are encrypted to FPR1 ONLY -> warns FPR2 can't read N entries
printf '%s\n%s\n' "$FPR1" "$FPR2" > "$STORE/.gpg-id"
printf '%s\n' "$GOOD_PAT" | gpg --batch --trust-model always -e -r "$FPR1" -o "$STORE/github/admin-pat.gpg"
printf 'other-secret-value\n' | gpg --batch --trust-model always -e -r "$FPR1" -o "$STORE/other.gpg"
out="$(run06 check)"
assert "A1: entry encrypted to 1 of 2 listed keys warns missing key with entry count" \
  'grep -qE "\[WARN\].*${FPR2: -8}.*2" <<<"$out"'
assert "A2: keeps re-init hints" \
  'grep -q "pass init" <<<"$out"'
assert "A3: never runs pass show without opt-in" \
  '! grep -q "^pass show" "$CALLS"'

# B. Re-encrypt both entries to BOTH FPR1 and FPR2 -> OK, no recipient warning
printf '%s\n' "$GOOD_PAT" | gpg --batch --yes --trust-model always -e -r "$FPR1" -r "$FPR2" -o "$STORE/github/admin-pat.gpg"
printf 'other-secret-value\n' | gpg --batch --yes --trust-model always -e -r "$FPR1" -r "$FPR2" -o "$STORE/other.gpg"
out="$(run06 check)"
assert "B1: entries encrypted to all listed keys report OK without recipient warning" \
  'grep -qE "\[ OK \].*pass store" <<<"$out" && ! grep -qE "\[WARN\].*${FPR1: -8}" <<<"$out" && ! grep -qE "\[WARN\].*${FPR2: -8}" <<<"$out"'
assert "B2: 40-char admin-pat does NOT warn on length" \
  '! grep -qE "\[WARN\].*admin-pat" <<<"$out"'

# C. Short 6-char admin-pat warns (no card!) and hint includes workflow scope
printf '%s\n' "$BAD_SHORT" | gpg --batch --yes --trust-model always -e -r "$FPR1" -r "$FPR2" -o "$STORE/github/admin-pat.gpg"
out="$(run06 check)"
assert "C1: 6-char admin-pat warns as too short" \
  'grep -qE "\[WARN\].*admin-pat.*short" <<<"$out"'
assert "C2: scope hint includes workflow" \
  'grep -q "repo,read:org,project,workflow" <<<"$out"'
assert "C3: uncompressed (-z 0) 6-char admin-pat also warns" \
  'printf "%s\n" "$BAD_SHORT" | gpg --batch --yes -z 0 --trust-model always -e -r "$FPR1" -r "$FPR2" -o "$STORE/github/admin-pat.gpg" && run06 check | grep -qE "\[WARN\].*admin-pat.*short"'
SHORT_39="ghp_9xK2mP7vQ4nL8wR1tY6zB3cF5hJ0dS8uE4a"    # 39 chars (+ LF = 40 bytes)
printf '%s\n' "$SHORT_39" | gpg --batch --yes -z 0 --trust-model always -e -r "$FPR1" -r "$FPR2" -o "$STORE/github/admin-pat.gpg"
out="$(run06 check)"
assert "C4 (F12): uncompressed 39-char token + LF warns as too short (newline subtracted)" \
  'grep -qE "\[WARN\].*admin-pat.*short" <<<"$out"'

# D. Missing admin-pat hint also includes workflow scope
rm -f "$STORE/github/admin-pat.gpg"
out="$(run06 check)"
assert "D: missing admin-pat hint includes workflow scope" \
  'grep -q "repo,read:org,project,workflow" <<<"$out"'

# E. Unknown packet type (AEAD tag 20) -> says "length not judged"
printf '%s\n' "$GOOD_PAT" | gpg --batch --yes --trust-model always -e -r "$FPR1" -r "$FPR2" -o "$STORE/github/admin-pat.gpg"
B_AEAD="$TMP/bin-aead"; mkdir -p "$B_AEAD"
cat > "$B_AEAD/gpg" <<'F'
#!/bin/bash
if [[ " $* " == *"--list-packets"* && "$*" == *"admin-pat.gpg"* ]]; then
  echo "# off=0 ctb=84 tag=1 hlen=2 plen=94"
  echo ":pubkey enc packet: version 3, algo 18, keyid AAAAAAAAAAAAAAAA"
  echo "# off=96 ctb=d4 tag=20 hlen=2 plen=80 new-ctb"
  echo ":aead encrypted packet:"
  exit 0
fi
exec /usr/bin/gpg "$@"
F
chmod +x "$B_AEAD/gpg"
out="$( cd "$KIT_DIR" && PATH="$B_AEAD:$B:/usr/bin:/bin" HOME="$H" GNUPGHOME="$H/.gnupg" \
        PASSWORD_STORE_DIR="$STORE" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
        bash profiles/workstation/06-gpg-pass.sh check 2>&1 )"
assert "E: unknown packet type (tag 20) says length not judged" \
  'grep -qi "length not judged" <<<"$out"'

# F. Opt-in prefix check (VERIFY_ADMIN_PAT=1): prints prompt count first, decrypts once, never prints secret
out="$(VERIFY_ADMIN_PAT=1 FAKE_PAT_PLAINTEXT="$GOOD_PAT" run06 check)"
assert "F1: opt-in check prints numeric PIN/touch prompt count BEFORE pass show" \
  'awk "/[0-9]+ PIN.*[0-9]+ touch/{seen=1} /MARKER_PASS_SHOW/{hit=1; exit !seen} END{exit !(seen && hit)}" <<<"$out"'
assert "F2: opt-in check decrypts exactly once" \
  '[[ $(grep -c "^pass show github/admin-pat$" "$CALLS") -eq 1 ]]'
assert "F3: valid ghp_ PAT passes and NEVER prints the secret value" \
  'grep -qE "\[ OK \].*admin-pat.*(valid|ghp_)" <<<"$out" && ! grep -qF "$GOOD_PAT" <<<"$out"'

BAD_PREFIX="not_a_real_github_token_even_though_it_is_over_40_characters_long"
out="$(VERIFY_ADMIN_PAT=1 FAKE_PAT_PLAINTEXT="$BAD_PREFIX" run06 check)"
assert "F4: invalid prefix warns and NEVER prints the secret value" \
  'grep -qE "\[WARN\].*admin-pat" <<<"$out" && ! grep -qF "$BAD_PREFIX" <<<"$out"'

# F5 (D3/F2): under bash -x, synthetic PAT must NEVER appear in stdout or stderr
SYNTH_PAT="ghp_SYNTHETIC0123456789abcdef0123456789a"
: > "$TMP/xtrace.out"; : > "$TMP/xtrace.err"
( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" GNUPGHOME="$H/.gnupg" \
  PASSWORD_STORE_DIR="$STORE" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
  VERIFY_ADMIN_PAT=1 FAKE_PAT_PLAINTEXT="$SYNTH_PAT" \
  bash -x profiles/workstation/06-gpg-pass.sh check >"$TMP/xtrace.out" 2>"$TMP/xtrace.err" )
out="$(cat "$TMP/xtrace.out")"
assert "F5 (D3/F2): bash -x never leaks synthetic PAT to stdout or stderr" \
  'grep -qE "\[ OK \].*admin-pat" "$TMP/xtrace.out" && ! grep -qF "$SYNTH_PAT" "$TMP/xtrace.out" && ! grep -qF "$SYNTH_PAT" "$TMP/xtrace.err"'

FINE_PAT="github_pat_$(printf 'A%.0s' {1..22})_$(printf 'b%.0s' {1..59})"
out="$(VERIFY_ADMIN_PAT=1 FAKE_PAT_PLAINTEXT="$FINE_PAT" run06 check)"
assert "F6 (D3): exact fine-grained github_pat_ (93 chars) passes and never prints token" \
  'grep -qE "\[ OK \].*admin-pat.*github_pat_" <<<"$out" && ! grep -qF "$FINE_PAT" <<<"$out"'

BAD_SHAPE="ghp_9xK2mP7vQ4nL8wR1tY6zB3cF5hJ0dS8uE4aGEXTRA"
out="$(VERIFY_ADMIN_PAT=1 FAKE_PAT_PLAINTEXT="$BAD_SHAPE" run06 check)"
assert "F7 (D3): wrong-length ghp_ token warns and never prints token" \
  'grep -qE "\[WARN\].*admin-pat" <<<"$out" && ! grep -qF "$BAD_SHAPE" <<<"$out"'

# F8: xtrace INHERITED by child scripts (exported SHELLOPTS) must not trace the
# decrypted value: the fake pass is bash and prints it with printf.
: > "$TMP/xi.err"
( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" GNUPGHOME="$H/.gnupg" \
  PASSWORD_STORE_DIR="$STORE" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
  VERIFY_ADMIN_PAT=1 FAKE_PAT_PLAINTEXT="$SYNTH_PAT" \
  bash -c 'set -x; export SHELLOPTS; exec bash profiles/workstation/06-gpg-pass.sh check' >/dev/null 2>"$TMP/xi.err" )
assert "F8: inherited xtrace (exported SHELLOPTS) never traces the decrypted value" \
  'grep -q "MARKER_PASS_SHOW" "$TMP/xi.err" && ! grep -qF "$SYNTH_PAT" "$TMP/xi.err"'

# F10: BASH_ENV pointing at `set -x` must not trace the decrypted value either
echo 'set -x' > "$TMP/xenv"; : > "$TMP/xe.err"
( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" GNUPGHOME="$H/.gnupg" \
  PASSWORD_STORE_DIR="$STORE" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
  VERIFY_ADMIN_PAT=1 FAKE_PAT_PLAINTEXT="$SYNTH_PAT" BASH_ENV="$TMP/xenv" \
  bash profiles/workstation/06-gpg-pass.sh check >/dev/null 2>"$TMP/xe.err" )
assert "F10: BASH_ENV with set -x never traces the decrypted value" \
  'grep -q "MARKER_PASS_SHOW" "$TMP/xe.err" && ! grep -qF "$SYNTH_PAT" "$TMP/xe.err"'

# F9: entries but no .gpg-id: install must NOT run pass init (it would decrypt = YubiKey PIN)
mv "$STORE/.gpg-id" "$TMP/gpg-id.bak"
out="$(run06 install)"
assert "F9: populated store without .gpg-id: no pass init from a phase, hint names it" \
  '! grep -q "^pass init" "$CALLS" && grep -q "pass init" <<<"$out"'
# F11: an uppercase .GPG entry (pass matches -iname) counts as an entry too
mkdir -p "$TMP/store2/x"; echo junk > "$TMP/store2/x/E.GPG"
: > "$CALLS"
out="$( cd "$KIT_DIR" && PATH="$B:/usr/bin:/bin" HOME="$H" GNUPGHOME="$H/.gnupg" \
  PASSWORD_STORE_DIR="$TMP/store2" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
  bash profiles/workstation/06-gpg-pass.sh install 2>&1 )"
assert "F11: uppercase .GPG entry, no .gpg-id: no pass init from a phase" '! grep -q "^pass init" "$CALLS"'
mv "$TMP/gpg-id.bak" "$STORE/.gpg-id"

# G. No card loop: gpg --card-status prints 0 PIN, 0 touch first, runs <=1 time in pass 1, 0 times in pass 2
B_CARD="$TMP/bin-card"; mkdir -p "$B_CARD"
CARD_CALLS="$TMP/card-calls"; : > "$CARD_CALLS"
cat > "$B_CARD/gpg" <<F
#!/bin/bash
if [[ " \$* " == *"--card-status"* ]]; then
  echo "card-status" >> "$CARD_CALLS"
  echo "MARKER_CARD_STATUS" >&2
  echo "Signature key ....: 1111 2222 3333 4444"
  exit 0
fi
exec /usr/bin/gpg "\$@"
F
chmod +x "$B_CARD/gpg"

out="$( cd "$KIT_DIR" && PATH="$B_CARD:$B:/usr/bin:/bin" HOME="$H" GNUPGHOME="$H/.gnupg" \
        PASSWORD_STORE_DIR="$STORE" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
        FAKE_YK=1 KIT_PASS=1 bash profiles/workstation/06-gpg-pass.sh install 2>&1 )"
assert "G1: pass 1 prints 0 PIN, 0 touch BEFORE gpg --card-status" \
  'awk "/0 PIN.*0 touch/{seen=1} /MARKER_CARD_STATUS/{hit=1; exit !seen} END{exit !(seen && hit)}" <<<"$out"'
assert "G2: pass 1 calls gpg --card-status at most once (not twice)" \
  '[[ $(wc -l < "$CARD_CALLS") -eq 1 ]]'

: > "$CARD_CALLS"
out="$( cd "$KIT_DIR" && PATH="$B_CARD:$B:/usr/bin:/bin" HOME="$H" GNUPGHOME="$H/.gnupg" \
        PASSWORD_STORE_DIR="$STORE" HOST_CONF="$TMP/host.conf" KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
        FAKE_YK=1 KIT_PASS=2 bash profiles/workstation/06-gpg-pass.sh install 2>&1 )"
assert "G3: pass 2 does NOT call gpg --card-status again" \
  '[[ $(wc -l < "$CARD_CALLS") -eq 0 ]]'

echo
echo "test-gpg-pass-doctor: $pass passed, $fail failed"
(( fail == 0 ))
