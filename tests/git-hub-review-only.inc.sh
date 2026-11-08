# shellcheck shell=bash disable=SC2034
# Class: every review-only release path uses local marks, never an upstream.
# Exercise the public CLI with real history and logged transport/credential fakes.
RO="$TMP/review-only"; mkdir -p "$RO/bin"
export RO KIT_DIR
cat > "$RO/bin/git" <<'SH'
#!/bin/bash
printf '%s ' "$@" >> "$RO/git.calls"; echo >> "$RO/git.calls"
exec /usr/bin/git "$@"
SH
cat > "$RO/bin/ssh" <<'SH'
#!/bin/bash
echo "$*" >> "$RO/ssh.calls"
[[ "$1" == git-hub-gate && "$2" == pending ]] || exit 99
SSH_ORIGINAL_COMMAND=pending exec bash "$KIT_DIR/components/git-hub/git-hub" gate
SH
cat > "$RO/bin/systemd-creds" <<'SH'
#!/bin/bash
echo credential-use >> "$RO/creds.calls"
exit 99
SH
cat > "$RO/bin/t3x" <<'SH'
#!/bin/bash
printf '%s\n' "${@: -1}" >> "$RO/relay.calls"
SH
cat > "$RO/bin/mv" <<'SH'
#!/bin/bash
if [[ -e "$RO/kill-before-mark" && "${@: -1}" == "$RO_STATE/patches/main" ]]; then
  touch "$RO/mark-started"
  while [[ -e "$RO/kill-before-mark" ]]; do sleep 0.02; done
fi
exec /usr/bin/mv "$@"
SH
chmod +x "$RO/bin/"*
ro_setup() {
  RO_CASE="$RO/$1"; mkdir -p "$RO_CASE/home" "$RO_CASE/work"
  git init -q --bare -b main "$RO_CASE/hub/patches.git"
  git init -q -b main "$RO_CASE/work"
  mkdir -p "$RO_CASE/work/${2:-src}"
  printf '%s' "${3:-root}" > "$RO_CASE/work/${2:-src}/root"
  git -C "$RO_CASE/work" add .; git -C "$RO_CASE/work" commit -q -m root
  RO_ROOT="$(git -C "$RO_CASE/work" rev-parse HEAD)"
  git -C "$RO_CASE/work" push -q "$RO_CASE/hub/patches.git" main
  RO_SHA="$RO_ROOT"
  RO_CONF="$RO_CASE/host.conf"
  printf '%s\n' "git_hub_root=$RO_CASE/hub" "git_hub_user=$ME" git_hub_repos=local/patches \
    git_hub_review_only=patches git_hub_review_via=gate git_hub_gate=fake \
    git_hub_review_thread=beast-vm:reviews > "$RO_CONF"
  RO_STATE="$RO_CASE/home/.local/state/git-hub"; export RO_STATE
  RO_REQUEST="$RO_STATE/release/patches.request"; RO_MARK="$RO_STATE/patches/main"
  RO_ZERO=0000000000000000000000000000000000000000
  mkdir -p "$RO_CASE/home/.config/setup-kit"
  # A poisoned sealed credential exposes accidental token use before Git runs.
  printf invalid > "$RO_CASE/home/.config/setup-kit/hub-forward-token.cred"
  ro_clear
}
ro_clear() { : > "$RO/git.calls"; : > "$RO/ssh.calls"; : > "$RO/creds.calls"; }
ro_quiet() {
  ! grep -Eq '(^| )(ls-remote|fetch|push)( |$)|config --get hub.upstream' "$RO/git.calls" \
    && [[ ! -s "$RO/ssh.calls" && ! -s "$RO/creds.calls" ]]
}
ro_cli() {
  env PATH="$RO/bin:/usr/bin:/bin" HOME="$RO_CASE/home" HOST_CONF="$RO_CONF" KIT_LOG_DIR="$RO_CASE/logs" \
    bash "$KIT_DIR/components/git-hub/git-hub" "$@" > "$TMP/out" 2>&1
}
ro_lib() {
  env PATH="$RO/bin:/usr/bin:/bin" HOME="$RO_CASE/home" HOST_CONF="$RO_CONF" KIT_LOG_DIR="$RO_CASE/logs" \
    bash -c 'source "$KIT_DIR/lib.sh"; source "$KIT_DIR/components/git-hub/lib.sh"; INSTALL=0; "$@"' _ "$@" > "$TMP/out" 2>&1
}
ro_add() {
  mkdir -p "$(dirname "$RO_CASE/work/$1")"; printf '%s' "${2:-next}" > "$RO_CASE/work/$1"
  git -C "$RO_CASE/work" add .; git -C "$RO_CASE/work" commit -q -m "$1"
  git -C "$RO_CASE/work" push -q "$RO_CASE/hub/patches.git" main
  RO_SHA="$(git -C "$RO_CASE/work" rev-parse HEAD)"
}

ro_setup root
# A root-only code file must be seen even when the tip itself changes only docs.
ro_add docs/next; ro_clear; ro_cli release; RO_RC=$?
assert 'RO1. no upstream or mark: first review includes whole history and root code' \
  '(( RO_RC == 0 )) && [[ -s "$RO_REQUEST" && "$(head -1 "$RO_REQUEST")" == "patches main $RO_ZERO $RO_SHA" ]] && grep -q "whole-history release review (2 commits)" "$RO_REQUEST" && grep -q "src/root" "$RO_REQUEST" && ! grep -q "fatal:" "$RO_REQUEST"'
assert 'RO2. first-release brief has no trusted baseline gate or GitHub-forward promise' \
  '[[ -s "$RO_REQUEST" ]] && grep -q "no trusted prior gate" "$RO_REQUEST" && grep -q "do not forward it anywhere" "$RO_REQUEST" && ! grep -q "git show 000000000" "$RO_REQUEST"'
lease_before="$(cat "$RO_STATE/release/patches.lease" 2>/dev/null)"; request_before="$(cat "$RO_REQUEST" 2>/dev/null)"
ro_cli release; RO_RC=$?
assert 'RO3. root request remains valid and retains its lease on retry' \
  '(( RO_RC == 0 )) && [[ -n "$request_before" && "$(cat "$RO_REQUEST" 2>/dev/null)" == "$request_before" && "$(cat "$RO_STATE/release/patches.lease" 2>/dev/null)" == "$lease_before" ]] && ! grep -q "recovered" "$TMP/out"'
SSH_ORIGINAL_COMMAND=pending ro_cli gate
assert 'RO4. gate pending serves first-release zero-base request' \
  'grep -q "^=== patches $RO_SHA " "$TMP/out" && grep -q "patches main $RO_ZERO $RO_SHA" "$TMP/out"'
ro_cli relay; RO_RC=$?
assert 'RO5. relay delivers first-release request through existing framing' \
  '(( RO_RC == 0 )) && [[ -s "$RO_STATE/relay/patches" ]] && grep -q "whole-history release review" "$RO/relay.calls"'
ro_clear
# Review only the queued SHA even when main has moved further in the meantime.
RO_REVIEWED="$RO_SHA"; ro_add src/later; ro_clear
SSH_ORIGINAL_COMMAND="verdict patches $RO_REVIEWED pass --sol=fixture accepted" ro_cli gate; RO_RC=$?
assert 'RO6. PASS records exactly reviewed SHA and removes matching queued request' \
  '(( RO_RC == 0 )) && [[ "$(cat "$RO_MARK" 2>/dev/null)" == "$RO_REVIEWED" && ! -e "$RO_REQUEST" ]] && grep -q "released (reviewed Sol fixture, not pushed)" "$TMP/out"'
assert 'RO7. review-only PASS never queries upstream, transports Git, or decrypts token' \
  '[[ "$(cat "$RO_MARK" 2>/dev/null)" == "$RO_REVIEWED" ]] && ro_quiet'
ro_cli release; RO_RC=$?
assert 'RO8. later code push reviews only last mark through new tip' \
  '(( RO_RC == 0 )) && [[ "$(head -1 "$RO_REQUEST" 2>/dev/null)" == "patches main $RO_REVIEWED $RO_SHA" ]] && grep -q "1 commit(s)" "$RO_REQUEST" && ! grep -q "whole-history" "$RO_REQUEST" && ro_quiet'
queued=0; [[ -s "$RO_REQUEST" ]] && queued=1
SSH_ORIGINAL_COMMAND="verdict patches $RO_SHA reject rejected" ro_cli gate; RO_RC=$?
ro_cli release
assert 'RO9. reject persists without advancing mark or reopening the same SHA' \
  '(( queued && RO_RC == 0 )) && [[ -s "$RO_STATE/release/patches.rejected.d/$RO_SHA" && "$(cat "$RO_MARK" 2>/dev/null)" == "$RO_REVIEWED" && ! -e "$RO_REQUEST" ]] && ro_quiet'
ro_cli verdict patches "$RO_SHA" pass --sol=fixture fixed
ro_cli verdict patches "$RO_REVIEWED" pass --sol=fixture stale; RO_RC=$?
assert 'RO24. late ancestor PASS cannot move an existing release mark backwards' \
  '(( RO_RC != 0 )) && [[ "$(cat "$RO_MARK" 2>/dev/null)" == "$RO_SHA" ]] && ro_quiet'
ro_cli status
assert 'RO25. status labels review-only marks released without claiming a forward' \
  'grep -q "patches  main  ${RO_SHA:0:9}  released" "$TMP/out" && ! grep -q forwarded "$TMP/out"'
ro_add src/pending; ro_clear; ro_cli status
assert 'RO26. status directs an unreleased review-only tip to release' \
  'grep -q "not released" "$TMP/out" && grep -q "git-hub release" "$TMP/out" && ! grep -q "git-hub forward" "$TMP/out"'

ro_setup content docs; ro_cli release; RO_RC=$?
assert 'RO10. root content-only release records mark without a review or upstream' \
  '(( RO_RC == 0 )) && [[ "$(cat "$RO_MARK" 2>/dev/null)" == "$RO_SHA" && ! -e "$RO_REQUEST" && ! -e "$RO_STATE/release/patches.lease" ]] && ro_quiet'
ro_add notes/next; echo git_hub_content=patches=notes/* >> "$RO_CONF"; ro_clear; ro_cli release
assert 'RO11. declared content records a later mark without review or upstream' \
  '[[ "$(cat "$RO_MARK" 2>/dev/null)" == "$RO_SHA" && ! -e "$RO_REQUEST" ]] && ro_quiet'
ro_setup secret docs '-----BEGIN PRIVATE KEY-----'
ro_add docs/root removed
ro_clear; ro_cli release
assert 'RO12. suspicious content in first history queues review and keeps mark absent' \
  '[[ -s "$RO_REQUEST" && ! -e "$RO_MARK" ]] && grep -q "possible secret" "$RO_REQUEST" && ro_quiet'
queued=0; [[ -s "$RO_REQUEST" ]] && queued=1
ro_cli verdict patches "$RO_SHA" reject secret
assert 'RO13. first-release reject writes rejection and leaves no release mark' \
  '(( queued )) && [[ -s "$RO_STATE/release/patches.rejected.d/$RO_SHA" && ! -e "$RO_MARK" && ! -e "$RO_REQUEST" ]] && ro_quiet'

ro_setup manual; ro_cli forward patches main; RO_RC=$?
assert 'RO14. manual forward refuses review-only before reading upstream or credential' \
  '(( RO_RC != 0 )) && grep -q "review-only" "$TMP/out" && ro_quiet'
echo git_hub_hold=patches >> "$RO_CONF"
ro_cli release; release_held="$(cat "$TMP/out")"
ro_cli verdict patches "$RO_SHA" pass --sol=fixture held; held_rc=$?
ro_cli forward patches main; RO_RC=$?
assert 'RO15. hold takes precedence for release, PASS, and manual forward' \
  '(( held_rc != 0 && RO_RC != 0 )) && [[ "$release_held" == *"held (git_hub_hold)"* && ! -e "$RO_MARK" && ! -e "$RO_REQUEST" ]] && grep -q "held (git_hub_hold)" "$TMP/out" && ! grep -q "review-only" "$TMP/out" && ro_quiet'
ro_setup unknown
git --git-dir="$RO_CASE/hub/patches.git" config hub.upstream ssh://unreachable.invalid/nonexistent
ro_clear; ro_cli release
assert 'RO16. configured unreachable upstream is never contacted' \
  '[[ -s "$RO_REQUEST" ]] && ro_quiet'
ro_lib hub_repo_ensure patches local/patches unused
assert 'RO17. provisioning doctor does not require an upstream for review-only repo' \
  '! grep -q "hub.upstream" "$TMP/out" && ro_quiet'
ro_lib hub_token_check
assert 'RO18. review-only doctor skips token expiry and credential checks' \
  '[[ ! -s "$TMP/out" ]] && ro_quiet'
echo 'git_hub_repos="local/patches local/forwarding"' >> "$RO_CONF"; ro_lib hub_token_check
assert 'RO19. mixed hub still checks forwarding token' \
  'grep -q "forward token: expiry unknown" "$TMP/out"'

ro_setup invalid; mkdir -p "$(dirname "$RO_MARK")"; echo broken > "$RO_MARK"
ro_cli release; RO_RC=$?
assert 'RO20. malformed release mark pauses instead of releasing whole history' \
  '(( RO_RC != 0 )) && grep -q "release mark is invalid" "$TMP/out" && [[ ! -e "$RO_REQUEST" && "$(cat "$RO_MARK")" == broken ]] && ro_quiet'
printf '%040d\n' 1 > "$RO_MARK"; ro_cli release; RO_RC=$?
assert 'RO21. missing-object release mark pauses without upstream fallback' \
  '(( RO_RC != 0 )) && grep -q "release mark is invalid" "$TMP/out" && [[ ! -e "$RO_REQUEST" ]] && ro_quiet'
git -C "$RO_CASE/work" checkout -q --orphan unrelated; git -C "$RO_CASE/work" commit -q -m unrelated
other="$(git -C "$RO_CASE/work" rev-parse HEAD)"; git -C "$RO_CASE/work" push -q "$RO_CASE/hub/patches.git" HEAD:refs/heads/unrelated
echo "$other" > "$RO_MARK"; ro_clear; ro_cli release; RO_RC=$?
assert 'RO22. diverged release mark pauses without overwriting it' \
  '(( RO_RC != 0 )) && grep -q "release mark has diverged" "$TMP/out" && [[ "$(cat "$RO_MARK")" == "$other" && ! -e "$RO_REQUEST" ]] && ro_quiet'

ro_setup crash; ro_cli release; queued=0; [[ -s "$RO_REQUEST" ]] && queued=1
env PATH="$RO/bin:/usr/bin:/bin" HOME="$RO_CASE/home" HOST_CONF="$RO_CONF" KIT_LOG_DIR="$RO_CASE/logs" \
  python3 "$KIT_DIR/tests/git-hub-review-only-stop.py" "$RO_SHA" > "$TMP/out" 2>&1; RO_RC=$?
assert 'RO23. kill -9 after verdict before mark leaves a retry that converges' \
  '(( queued && RO_RC == 0 )) && [[ "$(cat "$RO_MARK" 2>/dev/null)" == "$RO_SHA" && ! -e "$RO_REQUEST" && ! -e "$RO_STATE/release/patches.lease" ]] && ro_quiet'
