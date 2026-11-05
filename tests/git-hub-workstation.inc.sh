# shellcheck shell=bash
# Sourced by test-git-hub.sh. Workstation profile, real Git, isolated HOME and hub.
WS_HOME="$TMP/workstation-home"; WS_CLONES="$TMP/workstation-clones"
WS_SERVER="$TMP/workstation-server"; WS_PEER="$TMP/workstation-peer"
mkdir -p "$WS_HOME" "$WS_CLONES/site" "$WS_PEER"
for WS_NAME in books wbt; do git init -q --bare "$WS_PEER/$WS_NAME.git"; done
git init -q "$WS_CLONES/books"; git init -q "$WS_CLONES/site/wbt"
git -C "$WS_CLONES/books" remote add origin "file://$GH/acme/books.git"
git -C "$WS_CLONES/site/wbt" remote add origin "file://$GH/acme/wbt.git"
WS_SSH="$WS_HOME/.ssh/config"
wsconf() {
  printf '%s\n' profile=workstation configs=no tmp_on_disk=no component_resource_guards=no group_dev_cloud=no \
    component_oom_zram=no component_docker_rootless=no component_herdr=no component_uutils_ls=no \
    component_ollama=no component_whisper=no component_mtga=no component_dictation=no component_ocr=no component_tts=no \
    component_claude_code=no component_claude_skills=no component_aws_cli=no component_lid_ignore=no \
    component_chatterbox=no component_clipboard=no component_git_hub=no \
    "git_hub_repos=acme/books acme/wbt:site/wbt acme/absent" "git_hub_user=$ME" \
    "git_hub_root=$WS_SERVER" "git_hub_upstream_base=file://$GH/" "$@" > "$TMP/workstation.conf"
}
runws() {
  env PATH="$BIN:/usr/bin:/bin" HOME="$WS_HOME" GIT_HOME="$WS_CLONES" ROOT="${WS_PROBE_ROOT:-$WS_PEER}" \
    HOST_CONF="$TMP/workstation.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
    bash "$KIT_DIR/profiles/workstation/07-components.sh" "${MODE:-check}" >"$TMP/out" 2>&1
}
wsurl() { git -C "$WS_CLONES/$1" remote get-url "${2:-origin}"; }
wsstate() {
  { find "$WS_HOME" "$WS_CLONES" -printf '%p %y %m %l\n' | sort
    find "$WS_HOME" "$WS_CLONES" -type f -exec sha256sum {} + | sort
  } | sha256sum
}

wsconf; WS_BEFORE="$(wsstate)"; MODE=install runws
assert 'WS0. unset git_hub: install names off and leaves client files and remotes alone' \
  'grep -q "OK.*git hub: off" "$TMP/out" && [[ "$(wsstate)" == "$WS_BEFORE" ]]'
wsconf git_hub=hub-a.lan; WS_BEFORE="$(wsstate)"; runws
assert 'WS1. server disabled, check reports the missing client alias' \
  'grep -q "WARN.*git-hub alias.*hub-a.lan.*missing or drifted" "$TMP/out"'
assert 'WS2. check reports both origins that do not point at the hub' \
  'grep -q "WARN.*books origin.*want git-hub:books.git" "$TMP/out" && grep -q "WARN.*wbt origin.*want git-hub:wbt.git" "$TMP/out"'
assert 'WS3. fresh check changes no client file, mode or remote' \
  '[[ "$(wsstate)" == "$WS_BEFORE" ]]'
: > "$TMP/ssh.calls"; MODE=install runws
assert 'WS4. server disabled, install creates the client key and alias' \
  '[[ -s "$WS_HOME/.ssh/git_hub" ]] && grep -A8 "^Host git-hub$" "$WS_SSH" | grep -q "HostName hub-a.lan" && grep -q "IdentityFile $WS_HOME/.ssh/git_hub" "$WS_SSH"'
assert 'WS5. install routes both clone paths and keeps each old origin as github' \
  '[[ "$(wsurl books)" == git-hub:books.git && "$(wsurl site/wbt)" == git-hub:wbt.git && "$(wsurl books github)" == "file://$GH/acme/books.git" && "$(wsurl site/wbt github)" == "file://$GH/acme/wbt.git" ]]'
assert 'WS6. both client probes reach the hub through the alias' \
  'grep -q "OK.*books: origin is the hub" "$TMP/out" && grep -q "OK.*wbt: origin is the hub" "$TMP/out" && [[ "$(grep -c "SSH.*git-hub.*git-upload-pack" "$TMP/ssh.calls")" == 2 ]]'
assert 'WS7. a listed missing clone is named and skipped' \
  'grep -q "WARN.*acme/absent has no clone" "$TMP/out" && [[ ! -e "$WS_CLONES/absent" ]]'
assert 'WS8. client install enables neither the hub server nor the review relay' \
  '[[ ! -e "$WS_SERVER" && ! -e "$WS_HOME/.config/systemd/user/git-hub-relay.timer" ]]'
assert 'WS9. client routing sets no pushurl on either clone' \
  '! git -C "$WS_CLONES/books" config --get-regexp "^remote\..*\.pushurl$" && ! git -C "$WS_CLONES/site/wbt" config --get-regexp "^remote\..*\.pushurl$"'
WS_BEFORE="$(wsstate)"; MODE=install runws
assert 'WS10. repeated client install changes no client file or remote' \
  '[[ "$(wsstate)" == "$WS_BEFORE" ]]'
sed -i 's/HostName hub-a.lan/HostName stale.lan/' "$WS_SSH"
git -C "$WS_CLONES/books" remote set-url origin "file://$GH/drifted.git"
WS_BEFORE="$(wsstate)"; runws
assert 'WS11. check reports alias and origin drift without changing client files' \
  'grep -q "WARN.*git-hub alias.*missing or drifted" "$TMP/out" && grep -q "WARN.*books origin.*want git-hub:books.git" "$TMP/out" && [[ "$(wsstate)" == "$WS_BEFORE" ]]'
MODE=install runws
assert 'WS12. install repairs alias and origin drift while preserving github' \
  '[[ "$(grep -c "^Host git-hub$" "$WS_SSH")" == 1 && "$(wsurl books)" == git-hub:books.git && "$(wsurl books github)" == "file://$GH/acme/books.git" ]] && grep -q "HostName hub-a.lan" "$WS_SSH" && ! grep -q stale.lan "$WS_SSH"'

# Reset the client drift before each flag combination so an earlier install
# cannot make a missing profile call look successful.
wsdrift() {
  sed -i 's/HostName hub-a.lan/HostName stale.lan/' "$WS_SSH"
  git -C "$WS_CLONES/books" remote set-url origin "file://$GH/acme/books.git"
}
wsdrift; wsconf git_hub=hub-a.lan component_git_hub=yes; WS_PROBE_ROOT="$WS_SERVER" MODE=install runws
assert 'WS13. server enabled plus git_hub provisions the server before probing the client' \
  '[[ "$(git --git-dir="$WS_SERVER/books.git" config core.bare)" == true && "$(wsurl books)" == git-hub:books.git ]] && grep -q "HostName hub-a.lan" "$WS_SSH" && grep -q "OK.*books: origin is the hub" "$TMP/out"'
wsdrift; wsconf git_hub_gate=review.lan; WS_REMOTES="$(sha256sum "$WS_CLONES/books/.git/config" "$WS_CLONES/site/wbt/.git/config")"; MODE=install runws
assert 'WS14. relay enabled with git_hub unset leaves clone remotes alone' \
  '[[ "$(sha256sum "$WS_CLONES/books/.git/config" "$WS_CLONES/site/wbt/.git/config")" == "$WS_REMOTES" ]] && grep -q "^Host git-hub-gate$" "$WS_SSH" && [[ -f "$WS_HOME/.config/systemd/user/git-hub-relay.timer" ]]'
wsconf git_hub=hub-a.lan component_git_hub=yes git_hub_gate=review.lan; MODE=install runws
assert 'WS15. server and relay enabled together still reconcile the hub client' \
  '[[ "$(git --git-dir="$WS_SERVER/books.git" config core.bare)" == true && "$(wsurl books)" == git-hub:books.git ]] && grep -q "HostName hub-a.lan" "$WS_SSH" && grep -q "^Host git-hub-gate$" "$WS_SSH"'

# Each refusal starts with unrouted clones so a previous install cannot hide it.
wsfresh() {
  WS_HOME="$TMP/workstation-$1/home"; WS_CLONES="$TMP/workstation-$1/clones"
  WS_SSH="$WS_HOME/.ssh/config"
  mkdir -p "$WS_HOME/.ssh" "$WS_CLONES/site"
  git init -q "$WS_CLONES/books"; git init -q "$WS_CLONES/site/wbt"
  git -C "$WS_CLONES/books" remote add origin "file://$GH/acme/books.git"
  git -C "$WS_CLONES/site/wbt" remote add origin "file://$GH/acme/wbt.git"
  wsconf git_hub=hub-a.lan
}
wsremotes() { sha256sum "$WS_CLONES/books/.git/config" "$WS_CLONES/site/wbt/.git/config"; }
wseffective() { /usr/bin/ssh -F "$WS_SSH" -G git-hub 2>/dev/null | awk '$1 == "hostname" { print $2; exit }'; }
cat > "$BIN/flock" <<'S'
#!/bin/bash
[[ ! -e "$TMP/ws-flock-fail" ]] || exit 1
if [[ -e "$TMP/ws-flock-fast" ]]; then exec /usr/bin/flock -n "${@: -1}"; fi
exec /usr/bin/flock "$@"
S
cat > "$BIN/ssh-keygen" <<'S'
#!/bin/bash
[[ ! -e "$TMP/ws-key-fail" ]] || exit 1
exec /usr/bin/ssh-keygen "$@"
S
chmod +x "$BIN/flock" "$BIN/ssh-keygen"

wsfresh lock-failure
# The existing alias resolves correctly. Effective-host checking must not hide
# a writer failure just because this previous configuration is still usable.
printf 'Host git-hub\n  HostName hub-a.lan\n  User %s\n  IdentityFile %s/.ssh/git_hub\n  IdentitiesOnly yes\n  IdentityAgent none\n  StrictHostKeyChecking accept-new\n' "$ME" "$WS_HOME" > "$WS_SSH"
WS_CONFIG_BEFORE="$(sha256sum "$WS_SSH")"; WS_REMOTES="$(wsremotes)"; : > "$TMP/ssh.calls"
touch "$TMP/ws-flock-fail"; MODE=install runws; WS_RC=$?; rm "$TMP/ws-flock-fail"
assert 'WS16. failed alias locking reports a failed workstation phase' \
  '(( WS_RC != 0 )) && grep -q "lock.*retry install" "$TMP/out" && grep -q "FAIL.*git hub" "$TMP/out"'
assert 'WS17. failed alias setup changes no remote and starts no hub probe' \
  '[[ "$(sha256sum "$WS_SSH")" == "$WS_CONFIG_BEFORE" && "$(wsremotes)" == "$WS_REMOTES" ]] && ! grep -q "git-upload-pack" "$TMP/ssh.calls"'

wsfresh key-failure; WS_REMOTES="$(wsremotes)"
touch "$TMP/ws-key-fail"; MODE=install runws; WS_RC=$?; rm "$TMP/ws-key-fail"
assert 'WS18. failed client key generation stops the phase before any route' \
  '(( WS_RC != 0 )) && [[ ! -e "$WS_SSH" && "$(wsremotes)" == "$WS_REMOTES" ]] && grep -q "FAIL.*git hub" "$TMP/out"'

wsfresh unmanaged-alias
printf 'Host git-hub\n  HostName old-hub.lan\n  User previous\n' > "$WS_SSH"
WS_EFFECTIVE_BEFORE="$(wseffective)"; WS_REMOTES="$(wsremotes)"
MODE=install runws; WS_RC=$?
assert 'WS19. real OpenSSH sees an earlier alias win and install refuses routing' \
  '[[ "$WS_EFFECTIVE_BEFORE" == old-hub.lan && "$(wseffective)" == old-hub.lan && "$(wsremotes)" == "$WS_REMOTES" ]] && (( WS_RC != 0 )) && grep -q "WARN.*effective.*old-hub.lan.*hub-a.lan.*fix" "$TMP/out"'
WS_BEFORE="$(wsstate)"; runws; WS_RC=$?
assert 'WS20. check reports the effective alias conflict without writes' \
  '(( WS_RC != 0 )) && [[ "$(wsstate)" == "$WS_BEFORE" ]] && grep -q "WARN.*effective.*old-hub.lan.*fix" "$TMP/out"'
git -C "$WS_CLONES/books" remote set-url origin git-hub:books.git
git -C "$WS_CLONES/site/wbt" remote set-url origin git-hub:wbt.git
WS_BEFORE="$(wsstate)"; : > "$TMP/ssh.calls"; runws; WS_RC=$?
assert 'WS21. an invalid effective alias is never probed even for already routed clones' \
  '(( WS_RC != 0 )) && [[ "$(wsstate)" == "$WS_BEFORE" ]] && ! grep -q "git-upload-pack" "$TMP/ssh.calls"'

wsfresh query-failure; WS_REMOTES="$(wsremotes)"
touch "$TMP/ws-ssh-g-fail"; MODE=install runws; WS_RC=$?; rm "$TMP/ws-ssh-g-fail"
assert 'WS22. failed effective SSH evaluation refuses every remote change' \
  '(( WS_RC != 0 )) && [[ "$(wsremotes)" == "$WS_REMOTES" ]] && grep -q "WARN.*effective.*fix" "$TMP/out"'

wsfresh symlink-config; mkdir -p "$WS_HOME/dotfiles"
WS_SOURCE="$WS_HOME/dotfiles/ssh-config"
printf '# preserved admin settings\nHost admin\n  HostName admin.lan\n' > "$WS_SOURCE"
ln -s ../dotfiles/ssh-config "$WS_SSH"
touch "$WS_SSH.lock"; WS_LOCK_INODE="$(stat -c %i "$WS_SSH.lock")"
MODE=install runws; WS_RC=$?
assert 'WS23. symlinked SSH config keeps the link and reconciles its source before routing' \
  '(( WS_RC == 0 )) && [[ -L "$WS_SSH" && "$(readlink "$WS_SSH")" == ../dotfiles/ssh-config && "$(stat -c %a "$WS_SOURCE")" == 600 && "$(wseffective)" == hub-a.lan && "$(wsurl books)" == git-hub:books.git && "$(wsurl books github)" == "file://$GH/acme/books.git" && "$(stat -c %i "$WS_SSH.lock")" == "$WS_LOCK_INODE" ]] && grep -q "HostName hub-a.lan" "$WS_SOURCE" && grep -q "HostName admin.lan" "$WS_SOURCE"'
WS_BEFORE="$(wsstate)"; MODE=install runws; WS_RC=$?; runws; WS_CHECK_RC=$?
assert 'WS24. symlink reconciliation remains unchanged on repeated install and check' \
  '(( WS_RC == 0 && WS_CHECK_RC == 0 )) && [[ -L "$WS_SSH" && "$(wsstate)" == "$WS_BEFORE" ]]'

# Real lock contention on the original sidecar, shortened only by this fixture.
wsfresh symlink-lock; mkdir -p "$WS_HOME/dotfiles"
WS_SOURCE="$WS_HOME/dotfiles/ssh-config"; printf '# admin\n' > "$WS_SOURCE"
ln -s ../dotfiles/ssh-config "$WS_SSH"
WS_SOURCE_BEFORE="$(sha256sum "$WS_SOURCE")"; WS_REMOTES="$(wsremotes)"
touch "$TMP/ws-flock-fast"
{
  /usr/bin/flock -x 8
  MODE=install runws; WS_RC=$?
} 8> "$WS_SSH.lock"
rm "$TMP/ws-flock-fast"
assert 'WS25. a symlinked config still honors the original config.lock before target writes' \
  '(( WS_RC != 0 )) && [[ -L "$WS_SSH" && "$(sha256sum "$WS_SOURCE")" == "$WS_SOURCE_BEFORE" && "$(wsremotes)" == "$WS_REMOTES" ]] && grep -q "config.lock.*retry install" "$TMP/out"'

wsfresh dangling-link; ln -s ../missing/config "$WS_SSH"; WS_REMOTES="$(wsremotes)"
MODE=install runws; WS_RC=$?
assert 'WS26. an unresolved config symlink refuses routing and preserves the link' \
  '(( WS_RC != 0 )) && [[ -L "$WS_SSH" && ! -e "$WS_SSH" && "$(wsremotes)" == "$WS_REMOTES" ]] && grep -q "WARN.*symlink.*fix" "$TMP/out"'
rm "$BIN/flock" "$BIN/ssh-keygen"

# Real OpenSSH resolves the right hostname but earlier authentication settings.
wsfield() { /usr/bin/ssh -F "$WS_SSH" -G git-hub 2>/dev/null | awk -v key="$1" '$1 == key { $1=""; sub(/^ /, ""); print }'; }
wsfresh wrong-user
printf 'Host git-hub\n  HostName hub-a.lan\n  User previous\n' > "$WS_SSH"
WS_REMOTES="$(wsremotes)"; : > "$TMP/ssh.calls"; MODE=install runws; WS_RC=$?
assert 'WS27. same-host wrong User refuses routing before any probe' \
  '(( WS_RC != 0 )) && [[ "$(wseffective)" == hub-a.lan && "$(wsfield user)" == previous && "$(wsremotes)" == "$WS_REMOTES" ]] && grep -q "WARN.*effective.*user.*previous.*fix" "$TMP/out" && ! grep -q git-upload-pack "$TMP/ssh.calls"'
wsfresh identities-only
printf 'Host git-hub\n  HostName hub-a.lan\n  IdentitiesOnly no\n' > "$WS_SSH"
WS_REMOTES="$(wsremotes)"; MODE=install runws; WS_RC=$?
assert 'WS28. same-host IdentitiesOnly no refuses routing' \
  '(( WS_RC != 0 )) && [[ "$(wseffective)" == hub-a.lan && "$(wsfield identitiesonly)" == no && "$(wsremotes)" == "$WS_REMOTES" ]] && grep -q "WARN.*effective.*identitiesonly.*fix" "$TMP/out"'
wsfresh other-agent
printf 'Host git-hub\n  HostName hub-a.lan\n  IdentityAgent /nonexistent-agent\n' > "$WS_SSH"
WS_REMOTES="$(wsremotes)"; MODE=install runws; WS_RC=$?
assert 'WS29. same-host another IdentityAgent refuses routing' \
  '(( WS_RC != 0 )) && [[ "$(wseffective)" == hub-a.lan && "$(wsfield identityagent)" == /nonexistent-agent && "$(wsremotes)" == "$WS_REMOTES" ]] && grep -q "WARN.*effective.*identityagent.*fix" "$TMP/out"'
wsfresh unsafe-host-policy
printf 'Host git-hub\n  HostName hub-a.lan\n  StrictHostKeyChecking no\n' > "$WS_SSH"
WS_REMOTES="$(wsremotes)"; MODE=install runws; WS_RC=$?
assert 'WS30. an override of the managed host-key policy refuses routing' \
  '(( WS_RC != 0 )) && [[ "$(wseffective)" == hub-a.lan && "$(wsfield stricthostkeychecking)" != accept-new && "$(wsremotes)" == "$WS_REMOTES" ]] && grep -q "WARN.*effective.*stricthostkeychecking.*fix" "$TMP/out"'
wsfresh multiple-identities
printf 'Host git-hub\n  HostName hub-a.lan\n  IdentityFile ~/.ssh/another-key\n' > "$WS_SSH"
MODE=install runws; WS_RC=$?
assert 'WS31. the managed identity may appear alongside another configured identity' \
  '(( WS_RC == 0 )) && [[ "$(wsurl books)" == git-hub:books.git ]] && wsfield identityfile | grep -qx "$WS_HOME/.ssh/git_hub" && wsfield identityfile | grep -qx "~/.ssh/another-key"'
# IdentityFile is additive in OpenSSH. Remove only the required identity from
# its real dump to prove the validator rejects an incomplete successful query.
wsfresh missing-identity; WS_REMOTES="$(wsremotes)"
touch "$TMP/ws-hide-identity"; MODE=install runws; WS_RC=$?; rm "$TMP/ws-hide-identity"
assert 'WS32. an effective dump missing the managed identity refuses routing' \
  '(( WS_RC != 0 )) && [[ "$(wsremotes)" == "$WS_REMOTES" ]] && wsfield identityfile | grep -qx "$WS_HOME/.ssh/git_hub" && grep -q "WARN.*effective.*identityfile.*fix" "$TMP/out"'

wsfresh readonly-probe; MODE=install runws
WS_BEFORE="$(wsstate)"; : > "$TMP/ssh.calls"; runws; WS_RC=$?
assert 'WS33. workstation check probes refuse new host keys and disable updates' \
  '(( WS_RC == 0 )) && [[ "$(wsstate)" == "$WS_BEFORE" && "$(grep -c git-upload-pack "$TMP/ssh.calls")" == 2 ]] && ! grep git-upload-pack "$TMP/ssh.calls" | grep -v -- "-o StrictHostKeyChecking=yes -o UpdateHostKeys=no"'
: > "$TMP/ssh.calls"; MODE=install runws; WS_RC=$?
assert 'WS34. install probes retain accept-new rather than forcing check policy' \
  '(( WS_RC == 0 )) && [[ "$(wsfield stricthostkeychecking)" == accept-new && "$(grep -c git-upload-pack "$TMP/ssh.calls")" == 2 ]] && ! grep git-upload-pack "$TMP/ssh.calls" | grep -q -- "StrictHostKeyChecking=yes"'
wsconf git_hub=hub-a.lan profile=worker headless=yes reach=ssh git_auth=none
: > "$TMP/ssh.calls"
env PATH="$BIN:/usr/bin:/bin" HOME="$WS_HOME" GIT_HOME="$WS_CLONES" ROOT="$WS_PEER" \
  HOST_CONF="$TMP/workstation.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  bash "$KIT_DIR/profiles/worker/03-headless.sh" check > "$TMP/out" 2>&1; WS_RC=$?
assert 'WS35. the worker uses the same read-only host-key probe policy' \
  '(( WS_RC == 0 )) && [[ "$(grep -c git-upload-pack "$TMP/ssh.calls")" == 2 ]] && ! grep git-upload-pack "$TMP/ssh.calls" | grep -v -- "-o StrictHostKeyChecking=yes -o UpdateHostKeys=no"'

wsfresh known-hosts; wsconf git_hub=127.0.0.1
WS_KNOWN_REPORT="$TMP/known-hosts-result.json"
env PATH="$BIN:/usr/bin:/bin" HOME="$WS_HOME" GIT_HOME="$WS_CLONES" ROOT="$WS_PEER" \
  HOST_CONF="$TMP/workstation.conf" KIT_LOG_DIR="$TMP" KIT_QUIET=0 \
  python3 "$KIT_DIR/tests/git-hub-knownhosts.py" "$WS_KNOWN_REPORT" > "$TMP/out" 2>&1; WS_KNOWN_RC=$?
if (( WS_KNOWN_RC == 77 )); then
  echo "  SKIP WS36-WS38. real sshd unavailable: $(cat "$TMP/out")"
else
  assert 'WS36. real unknown-host check leaves all client state unchanged and names trust drift' \
    '(( WS_KNOWN_RC == 0 )) && jq -e ".server_ready and .check_readonly and .unknown_warning and .trusted_check_readonly" "$WS_KNOWN_REPORT" >/dev/null'
  assert 'WS37. real install accepts the new host key, calibrating the write detector' \
    '(( WS_KNOWN_RC == 0 )) && jq -e ".install_accepts_key and .detector_saw_write" "$WS_KNOWN_REPORT" >/dev/null'
  assert 'WS38. a changed host key stays unchanged and is not described as newly untrusted' \
    '(( WS_KNOWN_RC == 0 )) && jq -e ".changed_key_readonly and .changed_key_not_unknown" "$WS_KNOWN_REPORT" >/dev/null'
fi
