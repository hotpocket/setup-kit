# shellcheck shell=bash disable=SC2034
# Sourced by test-git-hub.sh. Real local git, fake network and credential service.
SL="$TMP/control"; mkdir -p "$SL/bin" "$SL/home" "$SL/role" "$SL/clones"
export HH="$SL/home" ROOT="$SL/hub" GH="$SL/upstream" GIT_HOME="$SL/clones"
BIN="$SL/bin"; cp "$TMP/bin/sudo" "$TMP/bin/systemctl" "$TMP/bin/loginctl" "$BIN/"
mkdir -p "$ROOT" "$GH/acme"
git init -q --bare -b main "$ROOT/books.git"; git init -q --bare -b main "$GH/acme/books.git"
git init -q -b main "$GIT_HOME/books"; git -C "$GIT_HOME/books" commit -q --allow-empty -m initial
base="$(git -C "$GIT_HOME/books" rev-parse HEAD)"
git -C "$GIT_HOME/books" push -q "$ROOT/books.git" main; git -C "$GIT_HOME/books" push -q "$GH/acme/books.git" main
git --git-dir="$ROOT/books.git" config hub.upstream git@github.com:acme/books.git
CONF="$SL/role/host.conf"; export CONF
printf '%s\n' "git_hub_repos=acme/books" "git_hub_root=$ROOT" "git_hub_user=$ME" > "$CONF"
cat > "$BIN/systemd-creds" <<'S'
#!/bin/bash
verb=$1; shift; [[ "$1" == --user && "$2" == --name=hub-forward-token ]] || exit 1
shift 2
case "$verb" in
 encrypt)
   [[ $# == 3 && "$1" == --with-key=host+tpm2 && "$2" == - ]] || exit 64
   printf '%s\n' "$1" > "$TMP/last-seal-key"; shift
   [[ ! -e "$TMP/encrypt-fail" ]] || exit 1
   { printf 'sealed:'; base64 -w0; } > "$2" ;;
 decrypt) [[ ! -e "$TMP/decrypt-fail" ]] || exit 1
   v=$(cat "$1"); [[ "$v" == sealed:* ]] || exit 1
   [[ ! -e "$TMP/roundtrip-fail" ]] || { echo different; exit; }
   printf '%s' "${v#sealed:}" | base64 -d ;;
esac
S
cat > "$BIN/systemd-analyze" <<'S'
#!/bin/bash
[[ ! -e "$TMP/no-tpm" ]] && echo yes || echo no
S
cat > "$BIN/git" <<'S'
#!/bin/bash
args=(); github=0
for a; do
  if [[ "$a" == https://github.com/acme/books.git ]]; then a="file://$GH/acme/books.git"; github=1; fi
  args+=("$a")
done
if (( github )); then
  [[ "${GIT_CONFIG_KEY_0:-}" == http.https://github.com/.extraHeader && "${GIT_CONFIG_VALUE_0:-}" == "Authorization: Basic $(printf 'x-access-token:%s' "$TEST_TOKEN" | base64 -w0)" ]] || exit 97
  echo authenticated >> "$TMP/auth.calls"
  [[ ! -e "$TMP/github-down" ]] || exit 1
fi
exec /usr/bin/git "${args[@]}"
S
cat > "$BIN/t3x" <<'S'
#!/bin/bash
[[ ! -e "$TMP/send-fail" ]] || exit 1
[[ "$1" == send && "$2" == beast-vm:reviews ]] || exit 2
printf '%s\n' "${@: -1}" >> "$TMP/relay.calls"
if [[ -e "$TMP/block-send" ]]; then
  touch "$TMP/send-started"
  while [[ -e "$TMP/block-send" ]]; do sleep 0.05; done
fi
S
cat > "$BIN/ssh" <<'S'
#!/bin/bash
printf '%s\037' "$@" >> "$TMP/control-ssh.calls"; echo >> "$TMP/control-ssh.calls"
[[ ! -e "$TMP/hub-down" ]] || exit 255
# Git's OpenSSH transport adds -o SendEnv=GIT_PROTOCOL before the host.
while [[ "${1:-}" == -o && $# -ge 2 ]]; do shift 2; done
[[ "${1:-}" == git-hub-gate || "${1:-}" == git-hub ]] || exit 2
shift
if [[ "$1" == pending ]]; then cat "$TMP/pending"; exit; fi
# Git's upload-pack request uses the same forced-command entry as a real SSH key.
HOST_CONF="${GATE_HOST_CONF:-$HOST_CONF}" SSH_ORIGINAL_COMMAND="$*" exec bash "$KIT_DIR/components/git-hub/git-hub" gate
S
chmod +x "$BIN/"*
export KIT_DIR TEST_TOKEN=github_pat_synthetic_control_test_value
ccli() { env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  bash "$KIT_DIR/components/git-hub/git-hub" "$@" > "$TMP/out" 2>&1; }
clib() { env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  bash -c 'source "$KIT_DIR/lib.sh"; source "$KIT_DIR/components/git-hub/lib.sh"; INSTALL=$1; shift; "$@"' _ "$@" > "$TMP/out" 2>&1; }
gate() { SSH_ORIGINAL_COMMAND="$1" ccli gate; }
ctok() { env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  python3 "$KIT_DIR/tests/git-hub-tty.py" "$1" "$2" > "$TMP/out" 2>&1; }
ctouch() { mkdir -p "$(dirname "$GIT_HOME/books/$1")"; echo "${2:-test}" > "$GIT_HOME/books/$1"; \
  git -C "$GIT_HOME/books" add .; git -C "$GIT_HOME/books" commit -q -m "$1"; git -C "$GIT_HOME/books" push -q "$ROOT/books.git" main; }
TOK="$HH/.config/setup-kit/hub-forward-token"; RS="$HH/.local/state/git-hub/release"; RLOG="$HH/.local/state/git-hub/release.log"

ccli token-set </dev/null; rc=$?
assert 'S01. token-set requires a tty' '(( rc != 0 )) && grep -qi tty "$TMP/out"'
ctok malformed 2099-01-01; rc=$?
assert 'S02. malformed token refused before any file is written' '(( rc != 0 )) && grep -q fine-grained "$TMP/out" && [[ ! -e "$TOK" && ! -e "$TOK.cred" ]]'
touch "$TMP/no-tpm"; ctok "$TEST_TOKEN" 2099-01-01; no_tpm_rc=$?; cp "$TMP/out" "$TMP/no-tpm.out"; rm "$TMP/no-tpm"
no_tpm_wrote_blob=0; [[ ! -e "$TOK.cred" ]] || no_tpm_wrote_blob=1
ctok "$TEST_TOKEN" 2099-01-01; has_tpm_rc=$?
assert 'S03. token-set requires TPM2 binding' \
  '(( no_tpm_rc != 0 && no_tpm_wrote_blob == 0 && has_tpm_rc == 0 )) && grep -q TPM2 "$TMP/no-tpm.out" && [[ -s "$TOK.cred" && "$(cat "$TMP/last-seal-key")" == --with-key=host+tpm2 ]]'
rm -f "$TOK.cred" "$TOK.expires"
ctok "$TEST_TOKEN" 2099-02-30; rc=$?
assert 'S04. invalid expiry refused without writing' '(( rc != 0 )) && grep -qi date "$TMP/out" && [[ ! -e "$TOK.cred" ]]'
touch "$TMP/roundtrip-fail"; ctok "$TEST_TOKEN" 2099-01-01; rc=$?; rm "$TMP/roundtrip-fail"
assert 'S05. failed credential round-trip leaves no blob' '(( rc != 0 )) && grep -qi round.trip "$TMP/out" && [[ ! -e "$TOK.cred" ]]'
git --git-dir="$ROOT/books.git" config hub.upstream git@github.com:acme/books.git
ctok "$TEST_TOKEN" 2099-01-01; rc=$?
assert 'S06. token-set seals mode 600, records expiry and proves GitHub through decrypted token' \
  '(( rc == 0 )) && [[ -s "$TOK.cred" && "$(stat -c %a "$TOK.cred")" == 600 && "$(cat "$TOK.expires")" == 2099-01-01 && -s "$TMP/auth.calls" && "$(cat "$TMP/last-seal-key")" == --with-key=host+tpm2 ]]'
assert 'S07. token and temporary files never contain plaintext or echo it' \
  '[[ ! -e "$TOK" ]] && ! grep -RFq "$TEST_TOKEN" "$HH" "$TMP/out" && [[ -z "$(find "$(dirname "$TOK")" -name "*.tmp.*")" ]]'
ccli forward books main; rc=$?
assert 'S08. forward authenticates with sealed token' '(( rc == 0 )) && grep -q forwarded "$TMP/out"'
echo broken > "$TOK.cred"; echo "$TEST_TOKEN" > "$TOK"; ccli forward books main; rc=$?
assert 'S09. bad blob fails closed despite plaintext fallback' '(( rc != 0 )) && grep -qi decrypt "$TMP/out"'
rm "$TOK"; ctok "$TEST_TOKEN" 2099-01-01
clib 0 hub_token_check
assert 'S10. doctor reads sealed-token expiry' 'grep -q "forward token valid until 2099-01-01" "$TMP/out"'
rm "$TOK.cred" "$TOK.expires"; git --git-dir="$ROOT/books.git" config hub.upstream "file://$GH/acme/books.git"
# Source the CLI through its real entry, then call its internal push seam to inject forbidden refspecs.
cpush() { env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  bash -c 'source "$KIT_DIR/components/git-hub/git-hub" help >/dev/null; push_up "$ROOT/books.git" "file://$GH/acme/books.git" "$1"' _ "$1" > "$TMP/out" 2>&1; }
cpush +main:refs/heads/force; rc=$?
assert 'S11. push refuses force refspec even for an otherwise fast-forward push' '(( rc == 2 )) && grep -qi refspec "$TMP/out" && ! git --git-dir="$GH/acme/books.git" show-ref --verify --quiet refs/heads/force'
cpush :refs/heads/main; rc=$?
assert 'S12. push refuses deletion refspec' '(( rc == 2 )) && grep -qi refspec "$TMP/out" && git --git-dir="$GH/acme/books.git" show-ref --verify --quiet refs/heads/main'
log_before=$(wc -l < "$RLOG"); ccli forward books main
assert 'S13. manual forward logs exactly one push outcome' '[[ "$(wc -l < "$RLOG")" == "$((log_before + 1))" ]] && tail -1 "$RLOG" | grep -q "forwarded (manual)"'
# Non-fast-forward upstream failure must also be one log entry.
git -C "$GIT_HOME/books" commit -q --allow-empty -m upstream; newer=$(git -C "$GIT_HOME/books" rev-parse HEAD)
git -C "$GIT_HOME/books" push -q "$GH/acme/books.git" main; ccli forward books main; rc=$?
assert 'S14. refused manual forward logged' '(( rc != 0 )) && grep -q "manual.*refused" "$RLOG"'
git -C "$GIT_HOME/books" push -q "$ROOT/books.git" main
printf '%s\n' git_hub_review_via=gate >> "$CONF"
ctouch src/one.py; sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ccli release
assert 'S15. gate release writes atomic request, gate lease, no t3x' \
  '[[ "$(head -1 "$RS/books.request")" == "books main $newer $sha" && "$(cut -d" " -f3 "$RS/books.lease")" == gate && ! -e "$TMP/relay.calls" ]]'
assert 'S16. gate brief names remote clone, verdict, base gate and mandatory Sol' \
  'grep -q "git-hub-gate:books.git" "$RS/books.request" && grep -q "ssh git-hub-gate verdict books $sha" "$RS/books.request" && grep -q "as defined at ${newer:0:9}" "$RS/books.request" && grep -q "reasoning xhigh" "$RS/books.request" && grep -q "Every release gets Sol" "$RS/books.request"'
# Make owner_alive report dead if called; gate leases still wait for expiry.
echo git_hub_review_grace_secs=0 >> "$CONF"; oldlease=$(cat "$RS/books.lease")
env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  bash -c 'source "$KIT_DIR/components/git-hub/git-hub" help >/dev/null; owner_alive() { touch "$TMP/owner-consulted"; return 1; }; cmd_release' > "$TMP/out" 2>&1
assert 'S17. gate lease stays until expiry without local owner liveness' '[[ "$(cat "$RS/books.lease")" == "$oldlease" && ! -e "$TMP/owner-consulted" ]]'
read -r _ _ owner sent tries < "$RS/books.lease"; echo "$sha 1 $owner $sent $tries" > "$RS/books.lease"; ccli release
assert 'S18. expired gate lease reissues request' '[[ "$(cut -d" " -f2 "$RS/books.lease")" -gt 1 && -s "$RS/books.request" ]]'
gate pending; cp "$TMP/out" "$TMP/pending"; gate_issued=$(cut -d" " -f4 "$RS/books.lease")
assert 'S19. gate pending serves open request with separator' 'grep -q "^=== books $sha $gate_issued$" "$TMP/out" && grep -q "^books main $newer $sha$" "$TMP/out"'
bad_n=0
for bad in '' 'pending extra' 'pending;' 'pending $(id)' 'git-receive-pack '\''books.git'\''' \
  'git-upload-pack '\''../books.git'\''' 'git-upload-pack '\''unknown.git'\''' 'git-upload-pack '\''books.git'\'' extra' \
  'git-upload-archive '\''books.git'\''' 'sh' 'verdict books bad pass --sol=x ok' \
  "verdict unknown $sha reject no" "verdict books $sha pass --sol=\$(id) yes" \
  "verdict books $sha pass --sol=x;id yes" "verdict ../books $sha reject no" \
  "verdict books $sha pass --sol=x" "verdict books $sha reject" $'pending\nwhoami' \
  "verdict books $sha pass --sol=x 'unclosed"; do
  gate "$bad"; rc=$?
  assert "S20.$((++bad_n)). forbidden gate input [$bad]" '(( rc == 2 )) && [[ "$(wc -l < "$TMP/out")" == 1 ]] && grep -q refused "$TMP/out"'
done
# Clone goes through the forced command and real upload-pack, not a fake result.
env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  git clone -q git-hub-gate:books.git "$SL/fetched" > "$TMP/out" 2>&1; rc=$?
assert 'S21. gate serves known repo through upload-pack' '(( rc == 0 )) && [[ "$(git -C "$SL/fetched" rev-parse HEAD)" == "$sha" ]]'
ctouch src/two.py; tip=$(git -C "$GIT_HOME/books" rev-parse HEAD)
gate "verdict books $sha pass --sol=task-42 'checked exactly this range'"; rc=$?
assert 'S22. gate verdict forwards exactly reviewed sha and clears its request' \
  '(( rc == 0 )) && [[ "$(git --git-dir="$GH/acme/books.git" rev-parse main)" == "$sha" && ! -e "$RS/books.request" && ! -e "$RS/books.lease" ]]'
ccli release; gate "verdict books $tip reject 'failed gate'"; rc=$?
assert 'S23. gate reject records reason and clears matching request' \
  '(( rc == 0 )) && [[ -e "$RS/books.rejected.d/$tip" && ! -e "$RS/books.request" && "$(git --git-dir="$GH/acme/books.git" rev-parse main)" == "$sha" ]]'
printf '%s\n' git_hub_gate=control.lan git_hub_review_thread=beast-vm:reviews >> "$CONF"
ccli relay; ccli relay
assert 'S24. relay sends one request once per name and sha' '[[ "$(grep -c "Release review:" "$TMP/relay.calls")" == 1 ]]'
printf '# git-hub pending complete\n' > "$TMP/pending"; ccli relay
assert 'S25. relay forgets cleared requests' '[[ -z "$(find "$HH/.local/state/git-hub/relay" -type f)" ]]'
printf '=== books %s 1\nbooks main %s %s\nretry brief\n# git-hub pending complete\n' "$sha" "$newer" "$sha" > "$TMP/pending"
touch "$TMP/send-fail"; ccli relay; rm "$TMP/send-fail"; ccli relay; ccli relay
assert 'S26. failed relay send retries and successful send is remembered' '[[ "$(grep -c "retry brief" "$TMP/relay.calls")" == 1 ]]'
touch "$TMP/hub-down"; ccli relay; rc=$?; rm "$TMP/hub-down"
assert 'S27. hub unreachable is one line, exit zero, retains relay state' \
  '(( rc == 0 )) && [[ "$(wc -l < "$TMP/out")" == 1 ]] && grep -q unreachable "$TMP/out" && [[ -n "$(find "$HH/.local/state/git-hub/relay" -type f)" ]]'
# Reviewer has no local bare repo; the SSH fixture uses the separate hub conf.
cp "$CONF" "$SL/gate-host.conf"; export GATE_HOST_CONF="$SL/gate-host.conf"
echo "git_hub_root=$SL/no-local-hub" >> "$CONF"
# stage remote source while still honoring exact reviewed sha, dirty and diverged refusals.
git -C "$GIT_HOME/books" reset -q --hard "$base"; ccli stage books "$sha"; rc=$?
assert 'S28. reviewer stage fetches remote gate and stops at reviewed sha' '(( rc == 0 )) && [[ "$(git -C "$GIT_HOME/books" rev-parse HEAD)" == "$sha" ]]'
echo dirty > "$GIT_HOME/books/tracked"; git -C "$GIT_HOME/books" add tracked; ccli stage books "$tip"; rc=$?
assert 'S29. remote stage still refuses dirty clone' '(( rc != 0 )) && grep -qi dirty "$TMP/out"'
git -C "$GIT_HOME/books" reset -q --hard "$base"; git -C "$GIT_HOME/books" commit -q --allow-empty -m diverged; ccli stage books "$sha"; rc=$?
assert 'S30. remote stage still refuses divergence' '(( rc != 0 )) && grep -qi diverged "$TMP/out"'
echo "git_hub_root=$ROOT" >> "$CONF"; unset GATE_HOST_CONF
# Managed reviewer keys preserve unrelated admin lines and resolve relative source at real conf.
mkdir -p "$HH/.ssh"; printf 'ssh-ed25519 ADMIN cloud-init\n' > "$HH/.ssh/authorized_keys"
printf 'from="192.0.2.1" ssh-ed25519 REVIEW1 first\n' > "$SL/role/reviewers.pub"
echo git_hub_reviewers=reviewers.pub >> "$CONF"
clib 0 hub_reviewers_ensure
assert 'S31. check reports reviewers drift without writing' 'grep -q WARN "$TMP/out" && [[ "$(cat "$HH/.ssh/authorized_keys")" == "ssh-ed25519 ADMIN cloud-init" ]]'
clib 1 hub_reviewers_ensure; before=$(sha256sum "$HH/.ssh/authorized_keys")
assert 'S32. install adds forced gate block with supplied restrictions and preserves admin' \
  'grep -q "^ssh-ed25519 ADMIN cloud-init$" "$HH/.ssh/authorized_keys" && grep -Fq "restrict,command=\"$KIT_DIR/components/git-hub/git-hub gate\",from=\"192.0.2.1\" ssh-ed25519 REVIEW1 first" "$HH/.ssh/authorized_keys" && [[ "$(stat -c %a "$HH/.ssh/authorized_keys")" == 600 ]]'
clib 1 hub_reviewers_ensure
assert 'S33. reviewer block second install changes nothing' '[[ "$(sha256sum "$HH/.ssh/authorized_keys")" == "$before" ]] && ! grep -q WARN "$TMP/out"'
printf 'ssh-ed25519 REVIEW2 second\n' > "$SL/role/reviewers.pub"; clib 1 hub_reviewers_ensure
assert 'S34. reviewer block removes old keys by content, keeps admin' 'grep -q REVIEW2 "$HH/.ssh/authorized_keys" && ! grep -q REVIEW1 "$HH/.ssh/authorized_keys" && grep -q ADMIN "$HH/.ssh/authorized_keys"'
clib 0 hub_gate_ensure
assert 'S35. gate reviewer check writes no alias, key or units' 'grep -q WARN "$TMP/out" && [[ ! -e "$HH/.ssh/git_hub_gate" && ! -e "$HH/.ssh/config" && ! -e "$HH/.config/systemd/user/git-hub-relay.timer" ]]'
clib 1 hub_gate_ensure
assert 'S36. reviewer installs isolated key, alias, relay timer, CLI and linger' \
  '[[ -s "$HH/.ssh/git_hub_gate" && -s "$HH/.ssh/git_hub_gate.pub" && -L "$HH/.local/bin/git-hub" ]] && grep -q "HostName control.lan" "$HH/.ssh/config" && grep -q "User control" "$HH/.ssh/config" && grep -q "IdentityAgent none" "$HH/.ssh/config" && grep -q "OnUnitActiveSec=2min" "$HH/.config/systemd/user/git-hub-relay.timer" && grep -q OnBootSec "$HH/.config/systemd/user/git-hub-relay.timer" && grep -q "git-hub relay" "$HH/.config/systemd/user/git-hub-relay.service" && grep -q "reviewers file needs:" "$TMP/out"'
before=$(sha256sum "$HH/.ssh/config"); clib 1 hub_gate_ensure
assert 'S37. reviewer setup idempotent' '[[ "$(sha256sum "$HH/.ssh/config")" == "$before" ]] && ! grep -q WARN "$TMP/out"'
sed -i 's/git_hub_gate=control.lan/git_hub_gate=control-new.lan/' "$CONF"; echo git_hub_gate_user=reviewer >> "$CONF"; clib 1 hub_gate_ensure
assert 'S38. reviewer move reconciles only managed alias' '[[ "$(grep -c "^Host git-hub-gate$" "$HH/.ssh/config")" == 1 ]] && grep -q "HostName control-new.lan" "$HH/.ssh/config" && grep -q "User reviewer" "$HH/.ssh/config"'

# A different sha for the same repo is new work, without waiting for disappearance.
printf '=== books %s 1\nbooks main %s %s\nnew sha brief\n# git-hub pending complete\n' "$tip" "$sha" "$tip" > "$TMP/pending"
ccli relay; ccli relay
assert 'S39. changed sha for the same name is relayed once' '[[ "$(grep -c "new sha brief" "$TMP/relay.calls")" == 1 ]] && [[ "$(cat "$HH/.local/state/git-hub/relay/books")" == "$tip 1" ]]'
# Passing/rejecting an older review must leave the current request in place.
git -C "$GIT_HOME/books" reset -q --hard "$tip"; ctouch src/three.py; latest=$(git -C "$GIT_HOME/books" rev-parse HEAD); ccli release
request_before=$(sha256sum "$RS/books.request")
gate "verdict books $sha reject 'late response'"; rc=$?
assert 'S40. late gate verdict preserves newer request and lease' '(( rc == 0 )) && [[ "$(sha256sum "$RS/books.request")" == "$request_before" && "$(cut -d" " -f1 "$RS/books.lease")" == "$latest" ]]'
# Seal failure preserves an existing credential; a network failure reports the installed seal.
git --git-dir="$ROOT/books.git" config hub.upstream git@github.com:acme/books.git
ctok "$TEST_TOKEN" 2099-01-01; sealed_before=$(sha256sum "$TOK.cred")
touch "$TMP/encrypt-fail"; ctok "$TEST_TOKEN" 2099-01-02; rc=$?; rm "$TMP/encrypt-fail"
assert 'S41. encryption failure preserves previous seal and expiry' '(( rc != 0 )) && [[ "$(sha256sum "$TOK.cred")" == "$sealed_before" && "$(cat "$TOK.expires")" == 2099-01-01 ]]'
touch "$TMP/github-down"; ctok "$TEST_TOKEN" 2099-01-02; rc=$?; rm "$TMP/github-down"
assert 'S42. network verification failure is explicit and keeps the installed sealed token' '(( rc != 0 )) && grep -q "GitHub check failed" "$TMP/out" && [[ -s "$TOK.cred" && "$(cat "$TOK.expires")" == 2099-01-02 ]]'
# The delivery log can precede its durable marker. Kill the entire fixture process group,
# then prove the next run delivers again and writes one whole completion record.
printf '# git-hub pending complete\n' > "$TMP/pending"; ccli relay
printf '=== books %s 1\nbooks main %s %s\ncrash brief\n# git-hub pending complete\n' "$latest" "$sha" "$latest" > "$TMP/pending"
touch "$TMP/block-send"; rm -f "$TMP/send-started"
env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  python3 "$KIT_DIR/tests/git-hub-stop.py" > "$TMP/out" 2>&1; rc=$?
assert 'S43. killed relay leaves no partial or completed delivery marker' '(( rc == 0 )) && [[ -e "$TMP/send-started" && ! -e "$HH/.local/state/git-hub/relay/books" ]]'
rm "$TMP/block-send"; ccli relay; ccli relay
assert 'S44. relay retries after kill, records whole sha, then skips completed work' '[[ "$(grep -c "crash brief" "$TMP/relay.calls")" == 2 && "$(cat "$HH/.local/state/git-hub/relay/books")" == "$latest 1" && -z "$(find "$HH/.local/state/git-hub" -maxdepth 1 -name ".relay-pending.*")" ]]'

# A configured hidden repo basename is valid; its delivery marker is a dotfile.
git clone -q --bare "$ROOT/books.git" "$ROOT/.configs.git"
echo 'git_hub_repos="acme/books acme/.configs"' >> "$CONF"
env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  git clone -q git-hub-gate:.configs.git "$SL/hidden" > "$TMP/out" 2>&1; rc=$?
assert 'S45. gate can fetch configured hidden repo names' '(( rc == 0 )) && [[ "$(git -C "$SL/hidden" rev-parse HEAD)" == "$latest" ]]'
printf '=== .configs %s 1\n.configs main %s %s\nhidden brief\n# git-hub pending complete\n' "$latest" "$sha" "$latest" > "$TMP/pending"
ccli relay; hidden_sent=$(cat "$HH/.local/state/git-hub/relay/.configs")
printf '# git-hub pending complete\n' > "$TMP/pending"; ccli relay
assert 'S46. relay remembers and forgets configured hidden repo names' '[[ "$hidden_sent" == "$latest 1" && ! -e "$HH/.local/state/git-hub/relay/.configs" ]]'

# R2: issue identity survives relay dedupe, and two unattended review expiries
# stop re-offering until main moves. Freeze the clock to exercise same-tick retries.
echo git_hub_repos=acme/books >> "$CONF"
gate "verdict books $latest pass --sol=task-r2-setup 'advance retry fixture'"
git -C "$GIT_HOME/books" reset -q --hard "$latest"
ctouch src/reoffer.py; reoffer_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
date +%s > "$TMP/date-epoch"
cat > "$BIN/date" <<'S'
#!/bin/bash
if [[ "$*" == +%s ]]; then cat "$TMP/date-epoch"; else exec /usr/bin/date "$@"; fi
S
chmod +x "$BIN/date"
ccli release; gate pending; cp "$TMP/out" "$TMP/pending"
issued1=$(awk '$1=="===" && $2=="books" {print $4}' "$TMP/pending")
assert 'S47. pending exposes the issue id from the lease sent epoch' \
  '[[ "$issued1" =~ ^[1-9][0-9]*$ && "$issued1" == "$(cut -d" " -f4 "$RS/books.lease")" ]]'
offers_before=$(grep -c '^Release review: books ' "$TMP/relay.calls")
ccli relay; ccli relay
assert 'S48. first issue is delivered once and remembered as sha plus issue id' \
  '[[ "$(grep -c "^Release review: books " "$TMP/relay.calls")" == "$((offers_before + 1))" && "$(cat "$HH/.local/state/git-hub/relay/books")" == "$reoffer_sha $issued1" ]]'
# Expire only the deadline, preserving the issue identity and attempt count.
read -r _ _ owner sent tries < "$RS/books.lease"
echo "$reoffer_sha 1 $owner $sent $tries" > "$RS/books.lease"
ccli release; gate pending; cp "$TMP/out" "$TMP/pending"
issued2=$(awk '$1=="===" && $2=="books" {print $4}' "$TMP/pending")
ccli relay; ccli relay
assert 'S49. first expiry reissues the same sha once with a new issue id and try two' \
  '[[ "$issued2" =~ ^[1-9][0-9]*$ ]] && (( issued2 > issued1 )) && [[ "$(cut -d" " -f5 "$RS/books.lease")" == 2 && "$(grep -c "^Release review: books " "$TMP/relay.calls")" == "$((offers_before + 2))" && "$(cat "$HH/.local/state/git-hub/relay/books")" == "$reoffer_sha $issued2" ]]'
# A busy pending command emits no snapshot. Keep dedupe state until a complete
# response proves a request disappeared, so contention cannot duplicate delivery.
cp "$TMP/pending" "$TMP/r2-pending-saved"; : > "$TMP/pending"; ccli relay
busy_state=$(cat "$HH/.local/state/git-hub/relay/books")
cp "$TMP/r2-pending-saved" "$TMP/pending"; ccli relay
assert 'S50. an empty busy response preserves delivery state and does not resend' \
  '[[ "$busy_state" == "$reoffer_sha $issued2" && "$(grep -c "^Release review: books " "$TMP/relay.calls")" == "$((offers_before + 2))" ]]'
# Real flock held by another process: the instrument sees an existing request
# before and after, and the contended pending invocation must be silent and bounded.
if [[ -z "${GIT_HUB_ASSERT_ONLY:-}" || ",$GIT_HUB_ASSERT_ONLY," == *,S51,* ]]; then
env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  python3 "$KIT_DIR/tests/git-hub-pending-lock.py" "$reoffer_sha" > "$TMP/out" 2>&1; rc=$?
assert 'S51. pending waits at most its short lock bound and returns an empty successful response' '(( rc == 0 ))'
fi
read -r _ _ owner sent tries < "$RS/books.lease"
echo "$reoffer_sha 1 $owner $sent $tries" > "$RS/books.lease"
ccli release; gate pending; cp "$TMP/out" "$TMP/pending"
assert 'S52. second expiry records stuck, drops request and excludes it from pending' \
  '[[ "$(cat "$RS/books.stuck")" == "$reoffer_sha" && ! -e "$RS/books.request" ]] && ! grep -q "^=== books " "$TMP/pending" && [[ "$(grep -c "books.*review ended twice without a verdict via gate -- needs a human" "$RLOG")" == 1 ]]'
ccli release; ccli release; ccli relay
assert 'S53. stuck sha is not re-offered or logged repeatedly' \
  '[[ ! -e "$RS/books.request" && "$(grep -c "books.*review ended twice without a verdict via gate -- needs a human" "$RLOG")" == 1 && "$(grep -c "^Release review: books " "$TMP/relay.calls")" == "$((offers_before + 2))" ]]'
gate "verdict books $reoffer_sha pass --sol=task-r2 'late completed review'"; rc=$?
assert 'S54. verdict for a stuck sha still forwards it and clears stuck and lease' \
  '(( rc == 0 )) && [[ "$(git --git-dir="$GH/acme/books.git" rev-parse main)" == "$reoffer_sha" && ! -e "$RS/books.stuck" && ! -e "$RS/books.lease" ]]'
# Moving main also escapes stuck, resetting the attempt count for the new sha.
ctouch src/after-stuck.py; after_stuck=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ccli release
read -r _ _ owner sent _ < "$RS/books.lease"
echo "$after_stuck 1 $owner $sent 2" > "$RS/books.lease"; ccli release
ctouch src/after-move.py; after_move=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ccli release; gate pending
assert 'S55. new main after a stuck review opens a fresh first attempt' \
  '[[ "$(cut -d" " -f1 "$RS/books.lease")" == "$after_move" && "$(cut -d" " -f5 "$RS/books.lease")" == 1 && -s "$RS/books.request" ]] && grep -q "^=== books $after_move " "$TMP/out"'
# Rejecting a stuck review is also an explicit outcome and clears the stuck marker.
read -r _ _ owner sent _ < "$RS/books.lease"
echo "$after_move 1 $owner $sent 2" > "$RS/books.lease"; ccli release
gate "verdict books $after_move reject 'review completed with findings'"; rc=$?
assert 'S56. reject for a stuck sha records rejection and clears stuck' \
  '(( rc == 0 )) && [[ -e "$RS/books.rejected.d/$after_move" && ! -e "$RS/books.stuck" && ! -e "$RS/books.request" && ! -e "$RS/books.lease" ]]'

# R3-1: an external forward satisfies the old review independently of its lease.
# Reset only fixture state at scenario boundaries so one failed cleanup cannot
# contaminate the next graph. The assertions use release/pending/relay entry points.
gate "verdict books $after_move pass --sol=task-r3-setup 'advance withdrawal fixture'"
ctouch src/withdraw-equal.py; withdrawn_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ccli release; gate pending; cp "$TMP/out" "$TMP/pending"; ccli relay
withdraw_was_open=$(grep -c "^=== books $withdrawn_sha " "$TMP/pending")
relay_was_present=0; [[ -s "$HH/.local/state/git-hub/relay/books" ]] && relay_was_present=1
withdraw_logs_before=$(grep -c 'review request withdrawn: already upstream' "$RLOG" || true)
git -C "$GIT_HOME/books" push -q "$GH/acme/books.git" main
ccli release; ccli release
assert 'S57. out-of-band forward withdraws request and lease with one log line' \
  '[[ "$withdraw_was_open" == 1 && ! -e "$RS/books.request" && ! -e "$RS/books.lease" && "$(grep -c "review request withdrawn: already upstream" "$RLOG")" == "$((withdraw_logs_before + 1))" ]]'
gate pending; cp "$TMP/out" "$TMP/pending"
assert 'S58. pending lists no request after upstream withdrawal' \
  '! grep -q "^=== books " "$TMP/pending" && grep -qx "# git-hub pending complete" "$TMP/pending"'
ccli relay
assert 'S59. relay forgets the withdrawn request on a complete pending snapshot' \
  '[[ "$relay_was_present" == 1 && ! -e "$HH/.local/state/git-hub/relay/books" ]]'
rm -f "$RS/books.request" "$RS/books.lease"

# Manual forward already records a cheap, local proof even before release runs.
ctouch src/withdraw-manual.py; manual_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ccli release; gate pending
manual_was_open=$(grep -c "^=== books $manual_sha " "$TMP/out")
ccli forward books main; gate pending
assert 'S60. pending suppresses a request covered by a locally recorded forward' \
  '[[ "$manual_was_open" == 1 && -s "$RS/books.request" && -s "$RS/books.lease" ]] && ! grep -q "^=== books " "$TMP/out" && grep -qx "# git-hub pending complete" "$TMP/out"'
ccli release; rm -f "$RS/books.request" "$RS/books.lease"

# The externally advanced upstream commit initially exists only in another clone.
ctouch src/withdraw-ahead.py; ahead_lease_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ccli release
outside="$SL/external-forward"; git clone -q "$ROOT/books.git" "$outside"
git -C "$outside" commit -q --allow-empty -m externally-ahead
outside_sha=$(git -C "$outside" rev-parse HEAD)
git -C "$outside" push -q "$GH/acme/books.git" main
upstream_was_absent=0; git --git-dir="$ROOT/books.git" cat-file -e "$outside_sha^{commit}" 2>/dev/null || upstream_was_absent=1
ccli release
assert 'S61. fetched upstream descendant withdraws the lease before back-propagation' \
  '[[ "$upstream_was_absent" == 1 && "$(git --git-dir="$ROOT/books.git" rev-parse main)" == "$outside_sha" && ! -e "$RS/books.request" && ! -e "$RS/books.lease" ]] && grep -q "${ahead_lease_sha:0:9}: review request withdrawn: already upstream" "$RLOG"'
rm -f "$RS/books.request" "$RS/books.lease"
git -C "$GIT_HOME/books" fetch -q "$ROOT/books.git" main; git -C "$GIT_HOME/books" reset -q --hard "$outside_sha"

# An older lease being satisfied must not suppress review of the remaining code.
ctouch src/withdraw-older.py; older_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ccli release
ctouch src/still-unreviewed.py; remaining_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
git -C "$GIT_HOME/books" push -q "$GH/acme/books.git" "$older_sha:refs/heads/main"
ccli release
assert 'S62. upstream covering an older lease opens a review for the remaining head' \
  '[[ "$(cut -d" " -f1 "$RS/books.lease")" == "$remaining_sha" && "$(head -1 "$RS/books.request")" == "books main $older_sha $remaining_sha" && "$(git --git-dir="$GH/acme/books.git" rev-parse main)" == "$older_sha" ]] && grep -q "${older_sha:0:9}: review request withdrawn: already upstream" "$RLOG"'
rm -f "$RS/books.request" "$RS/books.lease"

# Default t3x mode retains its existing lease behaviour at equal upstream.
ccli forward books main
echo git_hub_review_via=t3x >> "$CONF"
ctouch src/t3x-unchanged.py; t3x_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ccli release; t3x_lease_before=$(sha256sum "$RS/books.lease")
t3x_withdraw_before=$(grep -c 'review request withdrawn: already upstream' "$RLOG" || true)
git -C "$GIT_HOME/books" push -q "$GH/acme/books.git" main
ccli release
assert 'S63. t3x mode keeps its lease and emits no gate withdrawal log' \
  '[[ "$(sha256sum "$RS/books.lease")" == "$t3x_lease_before" && "$(cut -d" " -f1 "$RS/books.lease")" == "$t3x_sha" && "$(grep -c "review request withdrawn: already upstream" "$RLOG" || true)" == "$t3x_withdraw_before" ]]'

# F1: exercise every network entry point against a strict environment checker.
# Timeout's production argv is recorded, then scaled only inside this fixture.
# Ubuntu can expose uutils as timeout and GNU coreutils as gnutimeout. This
# contract is GNU timeout; the override reproduces the incompatible utility.
export GIT_HUB_TEST_TIMEOUT="${GIT_HUB_TEST_TIMEOUT:-$(command -v gnutimeout || command -v timeout)}"
"$GIT_HUB_TEST_TIMEOUT" --version | head -n 1
cp "$BIN/git" "$BIN/git.base"
cat > "$BIN/git" <<'S'
#!/bin/bash
verb=""
for a; do case "$a" in push|fetch|ls-remote) verb=$a; break ;; esac; done
if [[ -n "$verb" ]]; then
  printf '%s\n' "$verb" >> "$TMP/network.calls"
  if [[ -e "$TMP/require-network-env" ]]; then
    [[ "${GIT_TERMINAL_PROMPT:-}" == 0 && "${GIT_HTTP_LOW_SPEED_LIMIT:-}" == 1000 && "${GIT_HTTP_LOW_SPEED_TIME:-}" == 60 && "${GIT_SSH_COMMAND:-}" == *'BatchMode=yes'* && "${GIT_SSH_COMMAND:-}" == *'ConnectTimeout=20'* ]] || { echo 'git fixture: missing noninteractive transport settings' >&2; exit 97; }
  fi
  if [[ -e "$TMP/block-upstream" && "$(cat "$TMP/block-upstream")" == "$verb" ]]; then
    [[ -e "$TMP/stall-cooperative" ]] || trap '' TERM
    /bin/sleep 60 & child=$!
    awk '{print $1 " " $22}' "/proc/$$/stat" "/proc/$child/stat" > "$TMP/upstream-pids"
    touch "$TMP/upstream-started"
    wait "$child"; exit
  fi
fi
exec "$(dirname "$0")/git.base" "$@"
S
cat > "$BIN/timeout" <<'S'
#!/bin/bash
printf '%s\n' "$(basename "$0")" >> "$TMP/timeout-names"
if [[ "${1:-}" == --kill-after=10 ]]; then
  printf '%s\n' "$2" >> "$TMP/network-deadlines"
  shift 2
  "$GIT_HUB_TEST_TIMEOUT" --kill-after=0.2 2 "$@"
  rc=$?; printf '%s\n' "$rc" >> "$TMP/network-exits"; exit "$rc"
fi
exec "$GIT_HUB_TEST_TIMEOUT" "$@"
S
cp "$BIN/timeout" "$BIN/gnutimeout"   # both names, as on Ubuntu 26.04: production must pick GNU's
chmod +x "$BIN/git" "$BIN/timeout" "$BIN/gnutimeout"
metrics_true() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if all(d.get(k) is True for k in sys.argv[2:]) else 1)' "$@"; }
net_deadlines() { if [[ -f "$TMP/network-deadlines" ]]; then grep -c "^${1:-120}$" "$TMP/network-deadlines" || true; else echo 0; fi; }
rm -f "$RS/books.request" "$RS/books.lease"
echo git_hub_review_via=gate >> "$CONF"
touch "$TMP/require-network-env"
ctouch src/network-verdict.py; network_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ccli release; before_deadlines=$(net_deadlines)
gate "verdict books $network_sha pass --sol=task-net 'network contract'"; rc=$?
assert 'S64. gate verdict uses noninteractive transport and a server wall-clock deadline' \
  '(( rc == 0 )) && [[ "$(net_deadlines)" -gt "$before_deadlines" ]]'
assert 'S90. with uutils timeout and GNU gnutimeout both present (Ubuntu 26.04), the deadline is GNU'"'"'s (it kills the whole process group)' \
  '[[ -s "$TMP/timeout-names" ]] && ! grep -qvx gnutimeout "$TMP/timeout-names"'
# Keep cases independent even when a deliberately removed network policy fails.
git -C "$GIT_HOME/books" push -q "$GH/acme/books.git" main; rm -f "$RS/books.request" "$RS/books.lease"
ctouch src/network-forward.py; before_deadlines=$(net_deadlines)
ccli forward books main; rc=$?
assert 'S65. manual forward uses the same noninteractive settings and deadline' \
  '(( rc == 0 )) && [[ "$(net_deadlines)" -gt "$before_deadlines" ]]'
git -C "$GIT_HOME/books" push -q "$GH/acme/books.git" main
before_deadlines=$(net_deadlines); ctok "$TEST_TOKEN" 2099-01-02; rc=$?
assert 'S66. token-set read-only verification uses the shared transport and deadline' \
  '(( rc == 0 )) && [[ "$(net_deadlines)" -gt "$before_deadlines" ]]'
network_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
cp "$CONF" "$SL/network-hub.conf"; export GATE_HOST_CONF="$SL/network-hub.conf"
echo "git_hub_root=$SL/no-network-local-hub" >> "$CONF"
git -C "$GIT_HOME/books" reset -q --hard "$base"; before_deadlines=$(net_deadlines)
ccli stage books "$network_sha"; rc=$?
assert 'S67. reviewer stage bounds both remote HEAD lookup and fetch' \
  '(( rc == 0 )) && [[ "$(net_deadlines)" -ge "$((before_deadlines + 2))" && "$(git -C "$GIT_HOME/books" rev-parse HEAD)" == "$network_sha" ]]'
echo "git_hub_root=$ROOT" >> "$CONF"; unset GATE_HOST_CONF
git -C "$GIT_HOME/books" reset -q --hard "$network_sha"
git -C "$GIT_HOME/books" remote add origin git-hub:books.git
before_deadlines=$(net_deadlines 20); clib 0 hub_remote_ensure books acme/books "$GIT_HOME/books"; rc=$?
assert 'S68. worker hub probe is noninteractive and retains its shorter deadline' \
  '(( rc == 0 )) && [[ "$(net_deadlines 20)" -gt "$before_deadlines" ]] && grep -q "OK.*books: origin is the hub" "$TMP/out"'
# A real TERM-ignoring Git+child pair proves KILL escalation, lock release and retry.
ctouch src/network-stall.py; stalled_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ccli release
net_report="$TMP/network-result.json"
env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  python3 "$KIT_DIR/tests/git-hub-gate-timeout.py" "$stalled_sha" "$net_report" > "$TMP/out" 2>&1; net_probe_rc=$?
[[ ! -f "$net_report" ]] || { printf 'git-hub timeout: '; cat "$net_report"; echo; } > "$TMP/out"
assert 'S69. stalled gate push ends by the server deadline rather than the test deadline' \
  '(( net_probe_rc == 0 )) && metrics_true "$net_report" started server_bounded'
assert 'S70. timeout terminates upstream children, frees the lock and preserves the request' \
  'metrics_true "$net_report" started server_bounded children_dead lock_free request_kept'
assert 'S71. timed-out verdict retries idempotently and forwards exactly the reviewed sha' \
  'metrics_true "$net_report" request_kept retry_ok exact_sha'
rm -f "$RS/books.request" "$RS/books.lease"
# A cooperative stall takes timeout's normal exit-124 path, not KILL escalation.
ctouch src/network-timeout-log.py; log_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ccli release
timeout_report="$TMP/network-timeout-result.json"
env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  python3 "$KIT_DIR/tests/git-hub-gate-timeout.py" "$log_sha" "$timeout_report" cooperative > "$TMP/out" 2>&1; timeout_probe_rc=$?
[[ ! -f "$timeout_report" ]] || { printf 'git-hub timeout: '; cat "$timeout_report"; echo; } > "$TMP/out"
assert 'S83. exit 124 logs one timeout outcome and leaves the gate verdict retryable' \
  '(( timeout_probe_rc == 0 )) && metrics_true "$timeout_report" started server_bounded exit_124 timeout_logged lock_free request_kept retry_ok exact_sha'
rm -f "$RS/books.request" "$RS/books.lease"
# Retry success is isolated from transport-policy mutants in the following cases.
git -C "$GIT_HOME/books" push -q "$GH/acme/books.git" main

# F2: kill at the request rename, after publishing a whole lease.
cat > "$BIN/mv" <<'S'
#!/bin/bash
if [[ -e "$TMP/crash-request-rename" && "${@: -1}" == "$HOME/.local/state/git-hub/release/books.request" ]]; then
  touch "$TMP/request-rename-started"
  /bin/sleep 60
fi
exec /usr/bin/mv "$@"
S
chmod +x "$BIN/mv"
queue_base_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
ctouch src/crash-queue.py; crash_sha=$(git -C "$GIT_HOME/books" rev-parse HEAD)
queue_report="$TMP/queue-result.json"
env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  python3 "$KIT_DIR/tests/git-hub-queue-stop.py" "$crash_sha" "$queue_report" > "$TMP/out" 2>&1; queue_probe_rc=$?
assert 'S72. SIGKILL between lease and request renames recovers the missing request immediately' \
  '(( queue_probe_rc == 0 )) && metrics_true "$queue_report" checkpoint_seen lease_only had_temp replay_ok request_valid pending_visible'
assert 'S73. recovery preserves the lease attempt and sweeps abandoned queue temp files' \
  'metrics_true "$queue_report" lease_unchanged temps_swept'
# Mismatched headers must recover too, without replacing the active lease.
lease_before=$(sha256sum "$RS/books.lease")
printf 'unknown main %s %s\nwrong request\n' "$network_sha" "$crash_sha" > "$RS/books.request"
ccli release
assert 'S74. mismatched request is rebuilt without consuming a lease attempt' \
  '[[ "$(sha256sum "$RS/books.lease")" == "$lease_before" && "$(head -1 "$RS/books.request")" == "books main $queue_base_sha $crash_sha" ]] && grep -q "Release review: books" "$RS/books.request"'
# A second-issuance crash must recover try two, not become stuck without delivery.
read -r _ _ owner sent tries < "$RS/books.lease"
echo "$crash_sha $(( $(cat "$TMP/date-epoch") + 21600 )) $owner $((sent + 1)) 2" > "$RS/books.lease"
rm -f "$RS/books.request"
second_report="$TMP/second-queue-result.json"
env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  python3 "$KIT_DIR/tests/git-hub-queue-stop.py" "$crash_sha" "$second_report" > "$TMP/out" 2>&1; queue_probe_rc=$?
# A restart after the old deadline must repair the undelivered pair too.
read -r _ _ owner sent tries < "$RS/books.lease"
echo "$crash_sha 1 $owner $sent $tries" > "$RS/books.lease"; rm -f "$RS/books.request"
ccli release
expired_pair_recovered=0
if [[ -s "$RS/books.request" && ! -e "$RS/books.stuck" && "$(cut -d" " -f5 "$RS/books.lease")" == 2 && "$(cut -d" " -f4 "$RS/books.lease")" == "$sent" && "$(cut -d" " -f2 "$RS/books.lease")" -gt "$(cat "$TMP/date-epoch")" ]]; then expired_pair_recovered=1; fi
assert 'S75. interrupted reissue recovers without a third attempt or a stuck sha' \
  '(( queue_probe_rc == 0 )) && metrics_true "$second_report" checkpoint_seen request_valid lease_unchanged attempt_preserved attempt_two pending_visible temps_swept && [[ "$expired_pair_recovered" == 1 && ! -e "$RS/books.stuck" ]]'

# F3: start from a valid independent queue even when F2 recovery is removed.
rm -f "$RS/books.request" "$RS/books.lease" "$RS/books.stuck"
ccli release
# Held queues stay on disk but never reach the reviewer relay.
gate pending; hold_was_open=$(grep -c "^=== books $crash_sha " "$TMP/out")
hold_lease=$(sha256sum "$RS/books.lease"); hold_request=$(sha256sum "$RS/books.request")
hold_sends=$(grep -c '^Release review: books ' "$TMP/relay.calls")
echo git_hub_hold=books >> "$CONF"
gate pending; cp "$TMP/out" "$TMP/pending"; ccli relay
assert 'S76. pending and relay suppress held repos without changing their queue state' \
  '[[ "$hold_was_open" == 1 && "$(sha256sum "$RS/books.lease")" == "$hold_lease" && "$(sha256sum "$RS/books.request")" == "$hold_request" && "$(grep -c "^Release review: books " "$TMP/relay.calls")" == "$hold_sends" ]] && ! grep -q "^=== books " "$TMP/pending"'
after_hold_sends=$(grep -c '^Release review: books ' "$TMP/relay.calls")
echo git_hub_hold= >> "$CONF"
gate pending; cp "$TMP/out" "$TMP/pending"; ccli relay; ccli relay
assert 'S77. unhold advertises the preserved issue and relays it once' \
  'grep -q "^=== books $crash_sha " "$TMP/pending" && [[ "$(sha256sum "$RS/books.lease")" == "$hold_lease" && "$(sha256sum "$RS/books.request")" == "$hold_request" && "$(grep -c "^Release review: books " "$TMP/relay.calls")" == "$((after_hold_sends + 1))" ]]'

# B3-03: exercise real sidecar locks at both shared SSH files. Focused runs
# avoid the real 30-second timeout probes unless their assertions are selected.
for lock_case in 'S79 timeout authorized_keys' 'S80 timeout config' 'S81 sequence authorized_keys' 'S82 sequence config'; do
  read -r lock_id lock_scenario lock_file <<< "$lock_case"
  if [[ -n "${GIT_HUB_ASSERT_ONLY:-}" && ",${GIT_HUB_ASSERT_ONLY}," != *",$lock_id,"* ]]; then continue; fi
  lock_report="$TMP/$lock_id-lock.json"
  env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
    python3 "$KIT_DIR/tests/git-hub-block-lock.py" "$lock_scenario" "$lock_file" "$lock_report" > "$TMP/out" 2>&1; lock_probe_rc=$?
  if (( lock_probe_rc != 0 )); then cat "$TMP/out"; fi
  if [[ "$lock_scenario" == timeout ]]; then
    assert "$lock_id. $lock_file writer fails loudly within its sidecar lock bound" \
      '(( lock_probe_rc == 0 )) && metrics_true "$lock_report" failed bounded loud unchanged no_temp stable_sidecar lock_released check_readonly'
  else
    assert "$lock_id. $lock_file writers serialize the read through rename and preserve both blocks" \
      '(( lock_probe_rc == 0 )) && metrics_true "$lock_report" waited_before_read rename_seen held_through_rename success both_blocks stable_sidecar mode_600 lock_released check_readonly'
  fi
done

# F5: both real public SSH config writers must participate in the same lock.
public_lock_report="$TMP/public-lock.json"
env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL" \
  python3 "$KIT_DIR/tests/git-hub-block-lock.py" public config "$public_lock_report" > "$TMP/out" 2>&1; public_lock_rc=$?
assert 'S84. worker alias waits while the public gate writer holds config.lock' \
  '(( public_lock_rc == 0 )) && metrics_true "$public_lock_report" initial_alias gate_prepared gate_holds_lock worker_waited'
assert 'S85. concurrent public worker and gate writers preserve the new aliases and admin config' \
  '(( public_lock_rc == 0 )) && metrics_true "$public_lock_report" success worker_updated gate_preserved admin_preserved unique_blocks stable_sidecar mode_600 lock_released check_readonly'

# F6: a supported repo name containing .tmp. is persistent state, not a temp.
dot_name=topic.tmp.repo
git clone -q --bare "$GH/acme/books.git" "$ROOT/$dot_name.git"
git clone -q --bare "$GH/acme/books.git" "$GH/acme/$dot_name.git"
git clone -q "$ROOT/$dot_name.git" "$GIT_HOME/$dot_name"
git --git-dir="$ROOT/$dot_name.git" config hub.upstream "file://$GH/acme/$dot_name.git"
mkdir -p "$GIT_HOME/$dot_name/src"; echo code > "$GIT_HOME/$dot_name/src/cleanup.py"
git -C "$GIT_HOME/$dot_name" add .; git -C "$GIT_HOME/$dot_name" commit -q -m cleanup-regression
git -C "$GIT_HOME/$dot_name" push -q origin main
dot_sha=$(git -C "$GIT_HOME/$dot_name" rev-parse HEAD)
echo "git_hub_repos=acme/$dot_name" >> "$CONF"
ccli release
gate pending; dot_was_visible=$(grep -c "^=== $dot_name $dot_sha " "$TMP/out")
read -r _ dot_exp dot_owner dot_sent _ < "$RS/$dot_name.lease"
printf '%s\n' "$dot_sha $dot_exp $dot_owner $((dot_sent + 1)) 2" > "$RS/$dot_name.lease"
dot_request_before=$(sha256sum "$RS/$dot_name.request"); dot_lease_before=$(sha256sum "$RS/$dot_name.lease")
cleanup_genuine=("$RS/$dot_name.request.tmp.$$" "$RS/$dot_name.lease.tmp.$$" "$RS/$dot_name.stuck.tmp.$$")
cleanup_keep=("$RS/$dot_name.request.tmp.not-a-pid" "$RS/$dot_name.request.tmp.$$.bak" "$RS/$dot_name.other.tmp.$$" "$RS/$dot_name.request.tmp.12.part")
touch "${cleanup_genuine[@]}" "${cleanup_keep[@]}"
ccli release
assert 'S86. dotted repo request and attempt-two lease survive a release sweep' \
  '[[ "$dot_was_visible" == 1 && "$(sha256sum "$RS/$dot_name.request")" == "$dot_request_before" && "$(sha256sum "$RS/$dot_name.lease")" == "$dot_lease_before" ]]'
genuine_gone=1; for cleanup_file in "${cleanup_genuine[@]}"; do [[ ! -e "$cleanup_file" ]] || genuine_gone=0; done
lookalikes_kept=1; for cleanup_file in "${cleanup_keep[@]}"; do [[ -e "$cleanup_file" ]] || lookalikes_kept=0; done
assert 'S87. sweep removes complete numeric queue temps and preserves lookalikes' \
  '[[ "$genuine_gone" == 1 && "$lookalikes_kept" == 1 ]]'
# Terminal pause is independent of the preceding live-queue scenario.
printf '%s\n' "$dot_sha 1 gate $dot_sent 2" > "$RS/$dot_name.lease"
printf '%s\n' "$dot_sha" > "$RS/$dot_name.stuck"; rm -f "$RS/$dot_name.request"
dot_stuck_before=$(sha256sum "$RS/$dot_name.stuck"); dot_lease_before=$(sha256sum "$RS/$dot_name.lease")
ccli release; gate pending
assert 'S88. dotted repo terminal pause survives release and stays absent from pending' \
  '[[ "$(sha256sum "$RS/$dot_name.stuck")" == "$dot_stuck_before" && "$(sha256sum "$RS/$dot_name.lease")" == "$dot_lease_before" && ! -e "$RS/$dot_name.request" ]] && ! grep -q "^=== $dot_name " "$TMP/out"'
# A verdict rejected after taking the lock must leave the queued review intact.
rm -f "$RS/$dot_name.stuck" "$RS/$dot_name.lease" "$RS/$dot_name.request"
ccli release
dot_request_before=$(sha256sum "$RS/$dot_name.request"); dot_lease_before=$(sha256sum "$RS/$dot_name.lease")
gate "verdict $dot_name ffffffffffffffffffffffffffffffffffffffff reject 'unknown commit'"; dot_verdict_rc=$?
cp "$TMP/out" "$TMP/dot-verdict.out"; gate pending
assert 'S89. verdict lock sweep preserves the dotted repo queue when the commit is unknown' \
  '(( dot_verdict_rc == 2 )) && grep -q "no such commit" "$TMP/dot-verdict.out" && [[ "$(sha256sum "$RS/$dot_name.request")" == "$dot_request_before" && "$(sha256sum "$RS/$dot_name.lease")" == "$dot_lease_before" ]] && grep -q "^=== $dot_name $dot_sha " "$TMP/out"'
