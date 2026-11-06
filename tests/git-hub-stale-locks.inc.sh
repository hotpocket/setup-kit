# shellcheck shell=bash disable=SC2034
# Every Git-owned lock left by a killed hub transaction can block later work.
# Test the installed boot command and phase, using real local Git and fake root.
SL="$TMP/stale"; mkdir -p "$SL/home" "$SL/bin" "$SL/hub" "$SL/system/proc"
export KIT_GIT_HUB_SYSTEM_ROOT="$SL/system" KIT_MEMORY_ROOT="$SL/system"
export ROOT="$SL/hub" HH="$SL/home" BIN="$SL/bin" SL
printf 'MemTotal: 33554432 kB\n' > "$KIT_MEMORY_ROOT/proc/meminfo"
cp "$TMP/bin/sudo" "$TMP/bin/loginctl" "$TMP/bin/ssh" "$BIN/"
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
echo "$*" >> "$SL/systemctl.calls"
case "$*" in
  'show systemd-user-sessions.service -p InactiveExitTimestampMonotonic --value')
    [[ ! -f "$SL/no-barrier-state" ]] || exit 1
    [[ -f "$SL/login-started" ]] && echo 12345 || echo 0;;
  'is-enabled -q git-hub-stale-locks.service') [[ -f "$SL/enabled" ]];;
  'enable git-hub-stale-locks.service') touch "$SL/enabled";;
  *git-hub-stale-locks*) exit 98;;
esac
S
chmod +x "$BIN/"*
export PATH="$BIN:/usr/bin:/bin"
CONF="$SL/host.conf"
slconf() {
  printf '%s\n' configs=no configs_role=agent component_oom_zram=no component_resource_guards=no tmp_on_disk=no \
    component_docker_rootless=no component_aws_cli=no component_uutils_ls=no component_clipboard=no \
    "git_hub_root=$ROOT" "git_hub_user=$ME" 'git_hub_repos=acme/books' "$@" > "$CONF"
}
slphase() {
  env PATH="$BIN:/usr/bin:/bin" HOME="$HH" HOST_CONF="$CONF" KIT_LOG_DIR="$SL/logs" KIT_QUIET=0 \
    bash "$KIT_DIR/profiles/workstation/07-components.sh" "$1" > "$TMP/out" 2>&1
}
slverify() {
  # Run the real verifier in an isolated kit copy; unrelated machine failures
  # are expected. This checks its hub-specific diagnostics, never its exit code.
  env PATH="$BIN:/usr/bin:/bin" HOME="$HH" KIT_HOST_CONF="$CONF" KIT_VERBOSE=1 \
    bash "$SL/verify-kit/verify.sh" > "$TMP/out" 2>&1
}
UNIT="$KIT_GIT_HUB_SYSTEM_ROOT/etc/systemd/system/git-hub-stale-locks.service"
SWEEP="$KIT_GIT_HUB_SYSTEM_ROOT/usr/local/libexec/git-hub-stale-locks"
slsweep() {
  SWEEP_RC=0
  if [[ -x "$SWEEP" ]]; then "$SWEEP" "$ROOT" > "$TMP/out" 2>&1 || SWEEP_RC=$?
  else echo 'boot sweep not installed; locks remain' > "$TMP/out"; SWEEP_RC=127; fi
}
slconf component_git_hub=no; slphase install
assert 'SL1. non-hub install writes no boot sweep or unit' '[[ ! -e "$UNIT" && ! -e "$SWEEP" ]]'
slconf component_git_hub=yes; slphase check
assert 'SL2. hub check reports missing boot sweep, creates nothing' \
  'grep -q "WARN.*git-hub-stale-locks.*missing" "$TMP/out" && [[ ! -e "$UNIT" && ! -e "$SWEEP" ]]'
slphase install
assert 'SL3. hub installs executable and enabled system oneshot without starting it' \
  '[[ -x "$SWEEP" && -f "$UNIT" && -f "$SL/enabled" ]] && ! grep -Eq "(start|restart|--now).*git-hub-stale-locks" "$SL/systemctl.calls"'
assert 'SL4. boot unit precedes SSH service/socket and user-session barrier after local filesystems' \
  'grep -qx "DefaultDependencies=no" "$UNIT" && grep -qx "After=local-fs.target" "$UNIT" && grep -qx "Wants=local-fs.target" "$UNIT" && grep -qx "Before=ssh.service ssh.socket systemd-user-sessions.service" "$UNIT" && grep -qx "WantedBy=ssh.service ssh.socket systemd-user-sessions.service" "$UNIT" && grep -qx "Type=oneshot" "$UNIT" && grep -qx "RemainAfterExit=yes" "$UNIT" && ! grep -q "^Requires=" "$UNIT" && grep -Fqx "ExecStart=/usr/local/libexec/git-hub-stale-locks \"$ROOT\"" "$UNIT"'
: > "$SL/systemctl.calls"; slphase install
assert 'SL5. identical install does not reload system manager' '! grep -qx daemon-reload "$SL/systemctl.calls"'
rm -f "$SL/enabled"; slphase check
assert 'SL6. check detects disabled boot sweep without enabling it' \
  'grep -q "WARN.*git-hub-stale-locks.*not enabled" "$TMP/out" && [[ ! -e "$SL/enabled" ]]'
slphase install
assert 'SL7. interrupted enablement is repaired independently of file content' '[[ -f "$SL/enabled" ]]'
[[ ! -f "$UNIT" ]] || printf '\n# drift\n' >> "$UNIT"
slphase check
assert 'SL8. unit content drift is reported without writes' \
  'grep -q "WARN.*git-hub-stale-locks.*drift" "$TMP/out" && grep -q "# drift" "$UNIT"'
: > "$SL/systemctl.calls"; slphase install
assert 'SL9. changed unit is replaced whole and reloads system manager once' \
  '[[ -f "$UNIT" ]] && ! grep -q "# drift" "$UNIT" && [[ "$(grep -cx daemon-reload "$SL/systemctl.calls")" == 1 ]]'

W="$SL/work"; git init -q -b main "$W"; git -C "$W" commit -q --allow-empty -m initial
git -C "$W" push -q "$ROOT/books.git" main > "$TMP/out" 2>&1
git -C "$W" commit -q --allow-empty -m next
printf 'left by killed git\n' > "$ROOT/books.git/refs/heads/main.lock"
if git -C "$W" push "$ROOT/books.git" main > "$TMP/out" 2>&1; then PUSH_REFUSED=0; else PUSH_REFUSED=1; fi
assert 'SL10. stale ref lock demonstrably refuses a real push' \
  '(( PUSH_REFUSED )) && grep -Eq "reference already exists|cannot lock ref|[Ff]ile exists" "$TMP/out"'
LOCK_SIZE=$(stat -c %s "$ROOT/books.git/refs/heads/main.lock")
LOCK_MTIME=$(stat -c %Y "$ROOT/books.git/refs/heads/main.lock")
slsweep
assert 'SL11. sweep removes stale ref lock' '(( SWEEP_RC == 0 )) && [[ ! -e "$ROOT/books.git/refs/heads/main.lock" ]]'
assert 'SL12. removal journal line records path, size and mtime' \
  'grep -Fq "$ROOT/books.git/refs/heads/main.lock" "$TMP/out" && grep -q "size=$LOCK_SIZE" "$TMP/out" && grep -q "mtime=$LOCK_MTIME" "$TMP/out"'
if git -C "$W" push "$ROOT/books.git" main > "$TMP/out" 2>&1; then PUSH_RECOVERED=1; else PUSH_RECOVERED=0; fi
assert 'SL13. real push succeeds after sweep' \
  '(( PUSH_RECOVERED )) && [[ "$(git --git-dir="$ROOT/books.git" rev-parse main)" == "$(git -C "$W" rev-parse HEAD)" ]]'

mkdir -p "$SL/outside" "$ROOT/books.git/hooks" "$ROOT/books.git/objects/tmp_objdir-incoming-unit" \
  "$ROOT/books.git/objects/info/commit-graphs" "$ROOT/books.git/objects/pack/multi-pack-index.d"
printf preserve > "$SL/outside/main.lock"; cp "$SL/outside/main.lock" "$SL/outside/HEAD.lock"
ln -s "$SL/outside/main.lock" "$ROOT/books.git/refs/heads/link.lock"
ln -s "$SL/outside" "$ROOT/books.git/refs/escape"
ln -s "$SL/outside" "$ROOT/escape.git"
printf preserve > "$ROOT/not-a-repo.lock"
printf preserve > "$ROOT/books.git/hooks/tool.lock"
printf preserve > "$ROOT/books.git/custom.lock"
printf preserve > "$ROOT/books.git/refs/heads/non-lock"
printf preserve > "$ROOT/books.git/objects/info/custom.lock"
printf preserve > "$ROOT/books.git/objects/tmp_objdir-incoming-unit/HEAD.lock"
mkdir -p "$ROOT/not-bare.git"; printf preserve > "$ROOT/not-bare.git/HEAD.lock"
LOCKS=(HEAD.lock packed-refs.lock config.lock shallow.lock index.lock refs/heads/next.lock refs/tags/tag.lock \
  objects/info/packs.lock objects/info/commit-graph.lock objects/info/commit-graphs/commit-graph-chain.lock \
  objects/pack/multi-pack-index.lock objects/pack/multi-pack-index.d/multi-pack-index-chain.lock)
mkdir -p "$ROOT/books.git/refs/tags"
for lock in "${LOCKS[@]}"; do printf stale > "$ROOT/books.git/$lock"; done
slsweep
LEFT=0; for lock in "${LOCKS[@]}"; do [[ ! -e "$ROOT/books.git/$lock" ]] || ((LEFT++)); done
assert 'SL14. every supported Git transaction lock is recovered' '(( SWEEP_RC == 0 && LEFT == 0 ))'
assert 'SL15. symlinked lock, symlinked ref directory and symlinked repo never escape' \
  '[[ -L "$ROOT/books.git/refs/heads/link.lock" && -L "$ROOT/books.git/refs/escape" && -L "$ROOT/escape.git" && "$(cat "$SL/outside/main.lock")" == preserve && "$(cat "$SL/outside/HEAD.lock")" == preserve ]]'
assert 'SL16. hooks, custom locks, non-locks and outside-repo files survive' \
  '[[ "$(cat "$ROOT/books.git/hooks/tool.lock")" == preserve && "$(cat "$ROOT/books.git/custom.lock")" == preserve && "$(cat "$ROOT/books.git/refs/heads/non-lock")" == preserve && "$(cat "$ROOT/books.git/objects/info/custom.lock")" == preserve && "$(cat "$ROOT/not-a-repo.lock")" == preserve && "$(cat "$ROOT/not-bare.git/HEAD.lock")" == preserve ]]'
assert 'SL17. quarantine/temp object dirs survive' \
  '[[ "$(cat "$ROOT/books.git/objects/tmp_objdir-incoming-unit/HEAD.lock")" == preserve ]]'
slsweep
assert 'SL18. repeated sweep logs exactly one no-locks line' \
  '(( SWEEP_RC == 0 )) && [[ "$(wc -l < "$TMP/out")" == 1 ]] && grep -q "no stale Git locks" "$TMP/out"'

# A kill after a logged removal must leave a restartable sweep. A pipe stops
# the child once its stdout fills, giving a bounded, deterministic kill point.
if [[ -x "$SWEEP" ]]; then
  python3 - "$SWEEP" "$ROOT" > "$TMP/out" 2>&1 <<'PY'
import pathlib, subprocess, sys
refs = pathlib.Path(sys.argv[2]) / 'books.git/refs/heads'
for i in range(1200):
    (refs / f'interrupted-{i}.lock').write_text('stale')
proc = subprocess.Popen(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert proc.stdout.readline().startswith(b'removed ')
proc.kill()
proc.wait(timeout=10)
assert list(refs.glob('interrupted-*.lock')), 'kill must interrupt unfinished work'
done = subprocess.run(sys.argv[1:], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
assert done.returncode == 0 and not list(refs.glob('interrupted-*.lock'))
print('restart recovered remaining locks')
PY
  RESTART_RC=$?
else RESTART_RC=127; fi
assert 'SL19. killed sweep resumes without partial lock cleanup state' '(( RESTART_RC == 0 ))'

mkdir -p "$SL/verify-kit"
cp "$KIT_DIR/verify.sh" "$SL/verify-kit/"
ln -s "$KIT_DIR/manifests" "$SL/verify-kit/manifests"
slverify
assert 'SL20. independent verify accepts installed enabled boot sweep' 'grep -q "PASS.*git-hub stale-lock sweep" "$TMP/out"'
rm -f "$SL/enabled"; slverify
assert 'SL21. independent verify rejects disabled boot sweep' 'grep -q "FAIL.*git-hub stale-lock sweep.*disabled" "$TMP/out"'
touch "$SL/enabled"; [[ ! -f "$UNIT" ]] || mv "$UNIT" "$UNIT.saved"; slverify
assert 'SL22. independent verify rejects missing boot unit' 'grep -q "FAIL.*git-hub stale-lock sweep.*missing" "$TMP/out"'
[[ ! -f "$UNIT.saved" ]] || mv "$UNIT.saved" "$UNIT"
[[ ! -f "$SWEEP" ]] || mv "$SWEEP" "$SWEEP.saved"; slverify
assert 'SL23. independent verify rejects missing helper' 'grep -q "FAIL.*git-hub stale-lock sweep.*missing" "$TMP/out"'
[[ ! -f "$SWEEP.saved" ]] || mv "$SWEEP.saved" "$SWEEP"
slconf component_git_hub=no; slverify
assert 'SL24. independent verify has no boot-sweep requirement on non-hub' '! grep -q "git-hub stale-lock sweep" "$TMP/out"'

# Exercise systemd's actual graph checker, including the socket -> sockets ->
# basic default edges. A normal service's implicit After=basic creates a cycle.
mkdir -p "$KIT_GIT_HUB_SYSTEM_ROOT/bin"
cp /bin/true "$KIT_GIT_HUB_SYSTEM_ROOT/bin/true"
GD="$KIT_GIT_HUB_SYSTEM_ROOT/etc/systemd/system"
for target in local-fs sysinit sockets basic shutdown; do
  printf '[Unit]\nDefaultDependencies=no\n' > "$GD/$target.target"
done
printf 'Before=sysinit.target\n' >> "$GD/local-fs.target"
printf 'Before=basic.target\n' >> "$GD/sysinit.target"
printf 'Before=basic.target\n' >> "$GD/sockets.target"
printf 'Requires=sysinit.target sockets.target\nAfter=sysinit.target sockets.target\n' >> "$GD/basic.target"
for service in ssh systemd-user-sessions; do
  printf '[Unit]\nWants=git-hub-stale-locks.service\n[Service]\nExecStart=/bin/true\n' > "$GD/$service.service"
done
printf '[Unit]\nWants=git-hub-stale-locks.service\n[Socket]\nListenStream=2222\n' > "$GD/ssh.socket"
printf '[Socket]\nListenDatagram=/run/systemd/journal/socket\n' > "$GD/systemd-journald.socket"
printf '[Unit]\nDefaultDependencies=no\nWants=basic.target ssh.socket ssh.service systemd-user-sessions.service\nAfter=basic.target\n' > "$GD/multi-user.target"
systemd-analyze --root="$KIT_GIT_HUB_SYSTEM_ROOT" --generators=no --man=no verify \
  multi-user.target > "$TMP/out" 2>&1
GRAPH_RC=$?
# verify can return zero after deleting a wanted job to break its cycle.
assert 'SL25. systemd accepts the early boot graph without an ordering cycle' \
  '(( GRAPH_RC == 0 )) && ! grep -Eq "ordering cycle|deleted to break" "$TMP/out"'

if [[ -x "$SWEEP" ]]; then "$SWEEP" "$SL/missing-root" > "$TMP/out" 2>&1; FAILURE_RC=$?; else FAILURE_RC=127; fi
assert 'SL26. unavailable hub storage fails sweep with a diagnostic, not a false empty result' \
  '(( FAILURE_RC == 1 )) && grep -q "sweep failed" "$TMP/out" && ! grep -q "no stale Git locks" "$TMP/out"'

printf preserve > "$ROOT/books.git/refs/heads/main.lock"
ln -s "$ROOT" "$SL/root-link"
if [[ -x "$SWEEP" ]]; then "$SWEEP" "$SL/root-link" > "$TMP/out" 2>&1; ROOT_LINK_RC=$?; else ROOT_LINK_RC=127; fi
assert 'SL27. symlinked hub root is refused without removing its target locks' \
  '(( ROOT_LINK_RC == 1 )) && [[ "$(cat "$ROOT/books.git/refs/heads/main.lock")" == preserve ]]'

# Wants lets SSH survive failure. A later consumer may retry a failed sweep,
# so the command must also refuse once the login barrier has started.
touch "$SL/login-started"; slsweep
assert 'SL28. retry after login barrier started refuses to delete potentially live locks' \
  '(( SWEEP_RC == 1 )) && [[ "$(cat "$ROOT/books.git/refs/heads/main.lock")" == preserve ]] && grep -q "login barrier" "$TMP/out"'
rm "$SL/login-started"; printf preserve > "$ROOT/books.git/refs/heads/main.lock"
touch "$SL/no-barrier-state"; slsweep
assert 'SL29. unavailable boot-barrier state refuses cleanup' \
  '(( SWEEP_RC == 1 )) && [[ "$(cat "$ROOT/books.git/refs/heads/main.lock")" == preserve ]] && grep -q "login barrier" "$TMP/out"'
