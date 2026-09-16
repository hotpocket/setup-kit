#!/bin/bash
# Calibration for the worker's git credential modes (lib-deploy-keys.sh).
# git_auth used to be one word, and clone_repos always cloned over https —
# so a deploy-keys box with a repo in clone_repos tried an https clone with
# no credential behind it, and a box that needed BOTH (.configs read-only by
# key, the job repos read-write by PAT — 2026-09-16, ai-3090) had no way to say
# so. Now git_auth is a set and each repo picks the credential that covers it.
#
# Contract (all in check mode, fake HOME, no network):
#   A. git_auth="deploy-keys token": auth_has sees both
#   B. a clone_repos entry named in deploy_repos clones over its alias
#   C. one not named clones over https when token is on
#   D. ...and is refused by name when token is off (no blind https clone)
#   E. a repo already at ~/git/<repo> is reported present, never re-cloned
#   F. owner/repo:path clones to ~/git/<path>, and the probe slug drops the path
#   G. token mode: git@github.com: remotes are rewritten to https, once, and the
#      deploy-key alias prefix is not caught by it
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; sed 's/^/       | /' "$TMP/out"; fi; }
# run <conf-body> <shell-snippet>: source lib + deploy lib under a fake conf/HOME
run() {
  printf '%b\n' "$1" > "$TMP/host.conf"
  HOME="$TMP/home" HOST_CONF="$TMP/host.conf" LOG_DIR="$TMP" SCRIPT_NAME=t KIT_QUIET=0 bash -c "
    source '$KIT_DIR/lib.sh'; init_mode check; source '$KIT_DIR/profiles/worker/lib-deploy-keys.sh'; $2" > "$TMP/out" 2>&1
}
mkdir -p "$TMP/home/.ssh"

run 'git_auth="deploy-keys token"' 'auth_has token && echo T; auth_has deploy-keys && echo D'
assert "A. both modes parsed from one value" 'grep -qx T "$TMP/out" && grep -qx D "$TMP/out"'

run 'git_auth="deploy-keys token"\ndeploy_repos="configs=o/.configs"\nclone_repos="o/.configs o/job"' \
    'INSTALL=1; do_or_say() { echo "WOULD: $*"; }; clone_wanted'
assert "B. deploy-keyed repo clones over its alias" 'grep -q "WOULD: git clone git@github.com-configs:o/.configs.git" "$TMP/out"'
assert "C. token-covered repo clones over https"   'grep -q "WOULD: git clone https://github.com/o/job.git" "$TMP/out"'

run 'git_auth=deploy-keys\ndeploy_repos="configs=o/.configs"\nclone_repos="o/job"' \
    'INSTALL=1; do_or_say() { echo "WOULD: $*"; }; clone_wanted'
assert "D. no credential for a repo: refused by name, no https attempt" \
  '! grep -q "WOULD:" "$TMP/out" && grep -q "o/job: no deploy key" "$TMP/out"'

mkdir -p "$TMP/home/git/job/.git"
run 'git_auth=token\nclone_repos="o/job"' 'INSTALL=1; do_or_say() { echo "WOULD: $*"; }; clone_wanted'
assert "E. present repo reported, not re-cloned" '! grep -q "WOULD:" "$TMP/out" && grep -q "repo o/job at" "$TMP/out"'

run 'git_auth=token\nclone_repos="o/books:landry.bot/books"' 'INSTALL=1; do_or_say() { echo "WOULD: $*"; }; clone_wanted'
assert "F. owner/repo:path clones into ~/git/<path>" 'grep -q "WOULD: git clone https://github.com/o/books.git $TMP/home/git/landry.bot/books" "$TMP/out"'

run 'git_auth=token' 'INSTALL=1; token_rewrite_ssh >/dev/null; token_rewrite_ssh; git config --global --get-all url.https://github.com/.insteadOf'
assert "G. ssh prefix rewritten once and reported ok on the second pass" \
  '[[ $(grep -c "git@github.com:" "$TMP/out") -eq 1 ]] && grep -q "rewritten to https" "$TMP/out"'
assert "G. deploy-key alias survives the rewrite" \
  '[[ "$(cd "$TMP/home" && HOME="$TMP/home" git -c "url.https://github.com/.insteadOf=git@github.com:" ls-remote --get-url git@github.com-configs:o/r.git 2>/dev/null)" == "git@github.com-configs:o/r.git" ]]'

echo "  $pass passed, $fail failed"; (( fail == 0 ))
