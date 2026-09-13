#!/bin/bash
# The github ssh stanza must OFFER THE YUBIKEY FIRST, and the preamble's check
# must be able to see when it does not.
#
# 2026-09-13: every push asked for the passphrase of an old file key, then a
# YubiKey touch. ~/.ssh/config listed the passphrase key ahead of the resident
# -sk key ("primary: old git key") and had lost `IdentityAgent none`. ssh tries
# identities in order. The preamble's check mode asserted only that the -sk key
# was PRESENT (by exact text, so `~/.ssh/x` did not even match `$HOME/.ssh/x`)
# and said nothing about order or the agent lock — it watched a drift for two
# months and reported OK.
#
# Contract (check mode, stanza already present, one resident key on disk):
#   A. resident key first + IdentityAgent none          → no stanza warning
#   B. a non-resident IdentityFile BEFORE the resident   → WARN naming order
#   C. IdentityAgent none missing                        → WARN naming it
#   D. resident key written as ~/.ssh/... counts as pinned (no "not pinned")
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
H="$TMP/home"; mkdir -p "$H/.ssh" "$H/git/.configs/.git"   # .git: step 3 exits early, no network
SK="$H/.ssh/id_ed25519_sk_rk_github"; : > "$SK"; : > "$SK.pub"; : > "$H/.ssh/gitkey_old"
chmod 600 "$H/.ssh/"*
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
stanza() { printf 'Host github.com\n  HostName ssh.github.com\n  Port 443\n  IdentitiesOnly yes\n  ControlMaster auto\n%s\n' "$1" > "$H/.ssh/config"; chmod 600 "$H/.ssh/config"; }
run() { ( cd "$KIT_DIR" && HOME="$H" HOST_CONF=/dev/null KIT_LOG_DIR="$TMP/logs" KIT_QUIET=0 \
          bash profiles/workstation/preamble-github-auth.sh check 2>&1 | grep -i stanza ); }

echo "github stanza: identity order"
stanza "  IdentityAgent none
  IdentityFile $SK
  IdentityFile $H/.ssh/gitkey_old"
out="$(run)"
assert "A: resident first + agent lock — no WARN"      '[[ "$out" != *WARN* ]]'

stanza "  IdentityAgent none
  IdentityFile $H/.ssh/gitkey_old
  IdentityFile $SK"
out="$(run)"
assert "B: file key before resident — WARN about order" '[[ "$out" == *WARN* && "$out" == *"before"* ]]'

stanza "  IdentityFile $SK"
out="$(run)"
assert "C: IdentityAgent none missing — WARN names it"  '[[ "$out" == *WARN*"IdentityAgent none"* ]]'

stanza "  IdentityAgent none
  IdentityFile ~/.ssh/id_ed25519_sk_rk_github"
out="$(run)"
assert "D: ~/.ssh/ spelling counts as pinned"           '[[ "$out" != *"not pinned"* ]]'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
