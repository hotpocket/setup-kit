# shellcheck shell=bash disable=SC2034
# Every Git-owned lock left by a killed hub transaction can block later work.
# Test the installed boot command and phase, using real local Git and fake root.
SL="$TMP/stale"; mkdir -p "$SL/home" "$SL/bin" "$SL/hub" "$SL/system/proc"
export KIT_GIT_HUB_SYSTEM_ROOT="$SL/system" KIT_MEMORY_ROOT="$SL/system"
export INVOCATION_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export ROOT="$SL/hub" HH="$SL/home" BIN="$SL/bin" SL
printf 'MemTotal: 33554432 kB\n' > "$KIT_MEMORY_ROOT/proc/meminfo"
cp "$TMP/bin/sudo" "$TMP/bin/loginctl" "$TMP/bin/ssh" "$BIN/"
cat > "$BIN/systemctl" <<'S'
#!/bin/bash
echo "$*" >> "$SL/systemctl.calls"
case "$*" in
  'show git-hub-stale-locks.service -p MainPID --value')
    [[ ! -f "$SL/no-unit-state" ]] || exit 1
    [[ -f "$SL/manual-run" ]] && echo 1 || echo "$PPID";;
  'show basic.target -p InactiveExitTimestampMonotonic --value')
    [[ ! -f "$SL/no-basic-state" ]] || exit 1
    [[ -f "$SL/basic-started" ]] && echo 12345 || echo 0;;
  'show systemd-user-sessions.service -p InactiveExitTimestampMonotonic --value')
    [[ ! -f "$SL/no-barrier-state" ]] || exit 1
    [[ -f "$SL/login-started" ]] && echo 12345 || echo 0;;
  'is-enabled -q git-hub-stale-locks.service') [[ -f "$SL/enabled" ]];;
  'enable git-hub-stale-locks.service')
    touch "$SL/enabled"
    ud="$KIT_GIT_HUB_SYSTEM_ROOT/etc/systemd/system"
    for target in $(sed -n 's/^WantedBy=//p' "$ud/git-hub-stale-locks.service"); do
      mkdir -p "$ud/$target.wants"
      ln -sfn ../git-hub-stale-locks.service "$ud/$target.wants/git-hub-stale-locks.service"
    done;;
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
SWEEP_TEST="$SL/test-stale-locks"
slsweep() {
  SWEEP_RC=0
  if [[ -x "$SWEEP" ]]; then "$SWEEP_TEST" "$ROOT" > "$TMP/out" 2>&1 || SWEEP_RC=$?
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
  'grep -qx "DefaultDependencies=no" "$UNIT" && grep -qx "After=local-fs.target" "$UNIT" && grep -qx "Wants=local-fs.target" "$UNIT" && grep -qx "Before=basic.target ssh.service ssh.socket systemd-user-sessions.service" "$UNIT" && grep -qx "WantedBy=basic.target ssh.service ssh.socket systemd-user-sessions.service" "$UNIT" && grep -qx "Type=oneshot" "$UNIT" && grep -qx "RemainAfterExit=yes" "$UNIT" && ! grep -q "^Requires=" "$UNIT" && grep -Fqx "ExecStart=/usr/local/libexec/git-hub-stale-locks \"$ROOT\"" "$UNIT"'
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

# Change only a private test copy's executable constant. The installed helper
# keeps its trusted absolute executable; caller environment cannot select it.
python3 - "$SWEEP" "$SWEEP_TEST" "$BIN/systemctl" <<'PY'
from pathlib import Path
import sys
source, dest, executable = sys.argv[1:]
text = Path(source).read_text()
constant = "SYSTEMCTL = '/usr/bin/systemctl'"
assert text.count(constant) == 1, 'test seam must rewrite exactly one fixed constant'
Path(dest).write_text(text.replace(constant, f'SYSTEMCTL = {executable!r}'))
Path(dest).chmod(0o755)
PY

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
  python3 - "$SWEEP_TEST" "$ROOT" > "$TMP/out" 2>&1 <<'PY'
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

if [[ -x "$SWEEP" ]]; then "$SWEEP_TEST" "$SL/missing-root" > "$TMP/out" 2>&1; FAILURE_RC=$?; else FAILURE_RC=127; fi
assert 'SL26. unavailable hub storage fails sweep with a diagnostic, not a false empty result' \
  '(( FAILURE_RC == 1 )) && grep -q "sweep failed" "$TMP/out" && ! grep -q "no stale Git locks" "$TMP/out"'

printf preserve > "$ROOT/books.git/refs/heads/main.lock"
ln -s "$ROOT" "$SL/root-link"
if [[ -x "$SWEEP" ]]; then "$SWEEP_TEST" "$SL/root-link" > "$TMP/out" 2>&1; ROOT_LINK_RC=$?; else ROOT_LINK_RC=127; fi
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
rm "$SL/no-barrier-state"

# An old SSH-only enablement must not hide a missing basic.target pull-in.
BASIC_WANT="$KIT_GIT_HUB_SYSTEM_ROOT/etc/systemd/system/basic.target.wants/git-hub-stale-locks.service"
rm -f "$BASIC_WANT"; slconf component_git_hub=yes; slphase check
assert 'SL30. check reports missing basic-target pull-in despite SSH enablement' \
  'grep -q "WARN.*git-hub-stale-locks.*basic.target" "$TMP/out" && [[ ! -e "$BASIC_WANT" ]]'
slphase install
assert 'SL31. install repairs interrupted basic-target enablement with current files' \
  '[[ "$(readlink -f "$BASIC_WANT")" == "$UNIT" ]]'

python3 "$KIT_DIR/tests/git-hub-boot-order.py" "$UNIT" "$SL/boot-order" > "$SL/boot-order.json"
BOOT_PROBE_RC=$?
for scenario in service-only-ssh git-daemon root-manager; do
  case "$scenario" in service-only-ssh) graph_id=SL32;; git-daemon) graph_id=SL33;; root-manager) graph_id=SL34;; esac
  assert "$graph_id. sweep is before $scenario without a login or socket barrier; old ordering is detected" \
    '(( BOOT_PROBE_RC == 0 )) && python3 -c '\''import json,sys; r=json.load(open(sys.argv[1]))[sys.argv[2]]; sys.exit(not all(r.values()))'\'' "$SL/boot-order.json" "$scenario"'
done

touch "$SL/basic-started"
python3 "$KIT_DIR/tests/git-hub-live-lock.py" "$SWEEP_TEST" "$SL/live-basic" > "$SL/live-basic.json"
LIVE_PROBE_RC=$?
assert 'SL35. after basic.target a live prepared Git ref lock survives and commits' \
  '(( LIVE_PROBE_RC == 0 )) && python3 -c '\''import json,sys; sys.exit(not all(json.load(open(sys.argv[1])).values()))'\'' "$SL/live-basic.json"'
rm "$SL/basic-started"; touch "$SL/no-basic-state"
python3 "$KIT_DIR/tests/git-hub-live-lock.py" "$SWEEP_TEST" "$SL/live-unknown" > "$SL/live-unknown.json"
LIVE_PROBE_RC=$?
assert 'SL36. unknown basic-target state preserves a live prepared Git ref lock' \
  '(( LIVE_PROBE_RC == 0 )) && python3 -c '\''import json,sys; sys.exit(not all(json.load(open(sys.argv[1])).values()))'\'' "$SL/live-unknown.json"'
rm "$SL/no-basic-state"
rm -f "$BASIC_WANT"; slverify
assert 'SL37. independent verify rejects missing basic-target pull-in' \
  'grep -q "FAIL.*git-hub stale-lock sweep.*basic.target" "$TMP/out"'

printf preserve > "$ROOT/books.git/refs/heads/main.lock"
: > "$SL/systemctl.calls"
touch "$SL/manual-run"; slsweep
assert 'SL38. unmanaged invocation with inherited invocation ID refuses before boot queries' \
  '(( SWEEP_RC == 1 )) && [[ "$(cat "$ROOT/books.git/refs/heads/main.lock")" == preserve ]] && grep -Fq "systemctl start git-hub-stale-locks.service" "$TMP/out" && ! grep -Fq "show basic.target" "$SL/systemctl.calls"'
rm "$SL/manual-run"
printf preserve > "$ROOT/books.git/refs/heads/main.lock"
INVOCATION_ID= slsweep
assert 'SL39. missing invocation ID refuses even if the manager names this PID' \
  '(( SWEEP_RC == 1 )) && [[ "$(cat "$ROOT/books.git/refs/heads/main.lock")" == preserve ]] && grep -Fq "systemctl start git-hub-stale-locks.service" "$TMP/out"'
printf preserve > "$ROOT/books.git/refs/heads/main.lock"
touch "$SL/no-unit-state"; slsweep
assert 'SL40. unavailable unit membership fails closed with the service command' \
  '(( SWEEP_RC == 1 )) && [[ "$(cat "$ROOT/books.git/refs/heads/main.lock")" == preserve ]] && grep -Fq "systemctl start git-hub-stale-locks.service" "$TMP/out"'
rm "$SL/no-unit-state"
printf preserve > "$ROOT/books.git/refs/heads/main.lock"; slsweep
assert 'SL41. helper as the service main PID with invocation ID sweeps before basic and login' \
  '(( SWEEP_RC == 0 )) && [[ ! -e "$ROOT/books.git/refs/heads/main.lock" ]]'

touch "$SL/manual-run"
python3 "$KIT_DIR/tests/git-hub-live-lock.py" "$SWEEP_TEST" "$SL/live-manual" > "$SL/live-manual.json"
LIVE_PROBE_RC=$?
assert 'SL42. unmanaged early-boot helper preserves a real live ref transaction' \
  '(( LIVE_PROBE_RC == 0 )) && python3 -c '\''import json,sys; sys.exit(not all(json.load(open(sys.argv[1])).values()))'\'' "$SL/live-manual.json"'
rm "$SL/manual-run"

# Class: every sweep authorization/boot query must bypass caller PATH lookup.
# Test the unmodified installed helper against a forged manager in PATH.
mkdir -p "$SL/shadow"
cat > "$SL/shadow/systemctl" <<'S'
#!/bin/bash
echo "$*" >> "$SL/shadow.calls"
case "$*" in
  *MainPID*) echo "$PPID";;
  *) echo 0;;
esac
S
chmod +x "$SL/shadow/systemctl"
printf preserve > "$ROOT/books.git/refs/heads/main.lock"
: > "$SL/shadow.calls"
env INVOCATION_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb SYSTEMCTL="$SL/shadow/systemctl" \
  PATH="$SL/shadow:$BIN:/usr/bin:/bin" "$SWEEP" "$ROOT" > "$TMP/out" 2>&1
SHADOW_RC=$?
assert 'SL43. forged invocation ID and shadow systemctl cannot authorize the installed helper' \
  '(( SHADOW_RC == 1 )) && [[ -f "$ROOT/books.git/refs/heads/main.lock" && "$(cat "$ROOT/books.git/refs/heads/main.lock")" == preserve && ! -s "$SL/shadow.calls" ]] && grep -Fq "systemctl start git-hub-stale-locks.service" "$TMP/out"'

env INVOCATION_ID=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb SYSTEMCTL="$SL/shadow/systemctl" \
  PATH="$SL/shadow:$BIN:/usr/bin:/bin" python3 "$KIT_DIR/tests/git-hub-live-lock.py" \
  "$SWEEP" "$SL/live-shadow" > "$SL/live-shadow.json"
LIVE_PROBE_RC=$?
assert 'SL44. shadow systemctl cannot remove a real prepared ref lock or prevent its commit' \
  '(( LIVE_PROBE_RC == 0 )) && [[ ! -s "$SL/shadow.calls" ]] && python3 -c '\''import json,sys; sys.exit(not all(json.load(open(sys.argv[1])).values()))'\'' "$SL/live-shadow.json"'

touch "$SL/basic-started"; printf preserve > "$ROOT/books.git/refs/heads/main.lock"
: > "$SL/shadow.calls"
env PATH="$SL/shadow:$BIN:/usr/bin:/bin" "$SWEEP_TEST" "$ROOT" > "$TMP/out" 2>&1
SHADOW_RC=$?
assert 'SL45. managed basic-target query ignores a PATH shadow that claims boot has not started' \
  '(( SHADOW_RC == 1 )) && [[ -f "$ROOT/books.git/refs/heads/main.lock" && ! -s "$SL/shadow.calls" ]] && grep -q "basic target" "$TMP/out"'
rm "$SL/basic-started"; touch "$SL/login-started"
printf preserve > "$ROOT/books.git/refs/heads/main.lock"; : > "$SL/shadow.calls"
env PATH="$SL/shadow:$BIN:/usr/bin:/bin" "$SWEEP_TEST" "$ROOT" > "$TMP/out" 2>&1
SHADOW_RC=$?
assert 'SL46. managed login-barrier query ignores a PATH shadow that claims boot has not started' \
  '(( SHADOW_RC == 1 )) && [[ -f "$ROOT/books.git/refs/heads/main.lock" && ! -s "$SL/shadow.calls" ]] && grep -q "login barrier" "$TMP/out"'
rm "$SL/login-started"
