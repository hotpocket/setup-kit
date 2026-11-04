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
[[ "${1:-}" != --with-key=* ]] || shift
case "$verb" in
 encrypt) [[ ! -e "$TMP/encrypt-fail" ]] || exit 1; { printf 'sealed:'; base64 -w0; } > "$2" ;;
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
[[ "${1:-}" == git-hub-gate ]] || exit 2
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
touch "$TMP/no-tpm"; ctok "$TEST_TOKEN" 2099-01-01; rc=$?; rm "$TMP/no-tpm"
assert 'S03. token-set requires TPM2 binding' '(( rc != 0 )) && grep -q TPM2 "$TMP/out" && [[ ! -e "$TOK.cred" ]]'
ctok "$TEST_TOKEN" 2099-02-30; rc=$?
assert 'S04. invalid expiry refused without writing' '(( rc != 0 )) && grep -qi date "$TMP/out" && [[ ! -e "$TOK.cred" ]]'
touch "$TMP/roundtrip-fail"; ctok "$TEST_TOKEN" 2099-01-01; rc=$?; rm "$TMP/roundtrip-fail"
assert 'S05. failed credential round-trip leaves no blob' '(( rc != 0 )) && grep -qi round.trip "$TMP/out" && [[ ! -e "$TOK.cred" ]]'
git --git-dir="$ROOT/books.git" config hub.upstream git@github.com:acme/books.git
ctok "$TEST_TOKEN" 2099-01-01; rc=$?
assert 'S06. token-set seals mode 600, records expiry and proves GitHub through decrypted token' \
  '(( rc == 0 )) && [[ -s "$TOK.cred" && "$(stat -c %a "$TOK.cred")" == 600 && "$(cat "$TOK.expires")" == 2099-01-01 && -s "$TMP/auth.calls" ]]'
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
