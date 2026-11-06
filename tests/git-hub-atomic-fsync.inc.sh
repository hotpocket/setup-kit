# shellcheck shell=bash disable=SC2034
# Class: every unattended temp-to-final state publication needs file fsync,
# rename, then directory fsync. Trace the public CLI, not an extracted helper.
AF="$TMP/atomic-fsync"; mkdir -p "$AF/bin"
export AF LC_ALL=C
mkdir -p "$AF/faults"
cat > "$AF/faults/sitecustomize.py" <<'PY'
# Fault only the requested semantic barrier, independent of ancestor count.
import errno, os, signal, stat
original_fsync = os.fsync
publication_dir = None
def fault_fsync(fd):
    global publication_dir
    path = os.readlink(f"/proc/self/fd/{fd}")
    mode = os.environ.get("AF_FAULT", "")
    regular = stat.S_ISREG(os.fstat(fd).st_mode)
    state = os.environ["AF_STATE"]
    temp = regular and path.startswith(state + "/") and ".tmp." in path
    ancestry = path == os.environ["HOME"]
    fail = ((mode == "file" and temp) or
            (mode == "directory" and path == publication_dir) or
            (mode in ("ancestry", "kill") and ancestry))
    if fail:
        with open(os.environ["AF_FAULT_LOG"], "a") as log:
            log.write(f"{mode} EIO {path}\n")
        if mode == "kill":
            os.kill(os.getppid(), signal.SIGKILL)
            os.kill(os.getpid(), signal.SIGKILL)
        raise OSError(errno.EIO, "injected fsync failure", path)
    original_fsync(fd)
    if temp:
        publication_dir = os.path.dirname(path)
os.fsync = fault_fsync
PY
cat > "$AF/bin/t3x" <<'SH'
#!/bin/bash
echo delivered >> "$AF/deliveries"
SH
cat > "$AF/bin/ssh" <<'SH'
#!/bin/bash
cat "$AF/pending"
SH
chmod +x "$AF/bin/"*
export GIT_CONFIG_GLOBAL="$AF/gitconfig"
printf '[init]\n defaultBranch = main\n[core]\n fsync = none\n' > "$GIT_CONFIG_GLOBAL"
afsetup() {
  CASE="$AF/$1"; mkdir -p "$CASE/home" "$CASE/upstream"
  git init -q --bare -b main "$CASE/upstream/books.git"
  git init -q --bare -b main "$CASE/hub/books.git"
  git init -q -b main "$CASE/work"
  git -C "$CASE/work" commit -q --allow-empty -m initial
  BASE=$(git -C "$CASE/work" rev-parse HEAD)
  git -C "$CASE/work" push -q "$CASE/upstream/books.git" main
  mkdir -p "$CASE/work/${2:-src}"
  printf content > "$CASE/work/${2:-src}/change"
  git -C "$CASE/work" add .; git -C "$CASE/work" commit -q -m next
  HEAD_SHA=$(git -C "$CASE/work" rev-parse HEAD)
  git -C "$CASE/work" push -q "$CASE/hub/books.git" main
  git --git-dir="$CASE/hub/books.git" config hub.upstream "$CASE/upstream/books.git"
  printf '%s\n' "git_hub_root=$CASE/hub" "git_hub_user=$ME" git_hub_repos=acme/books \
    git_hub_review_via=gate git_hub_review_thread=beast-vm:reviews git_hub_gate=fake > "$CASE/host.conf"
  STATE_AF="$CASE/home/.local/state/git-hub"
  printf '=== books %s 12345\nbooks main %s %s\nReview this change.\n# git-hub pending complete\n' \
    "$HEAD_SHA" "$BASE" "$HEAD_SHA" > "$AF/pending"
}
afcli() {
  local inject="${AF_INJECT:-}"
  # File/directory-publication faults use established parents. Fresh ancestry
  # has its own injected failure below, before any temp file is opened.
  if [[ -n "$inject" && "${AF_FRESH_INJECT:-0}" == 0 ]]; then
    mkdir -p "$STATE_AF/release/books.rejected.d" "$STATE_AF/relay" "$STATE_AF/books"
  fi
  env PYTHONPATH="$AF/faults" AF_FAULT="$inject" AF_STATE="$STATE_AF" AF_FAULT_LOG="$CASE/fault.log" PATH="$AF/bin:/usr/bin:/bin" HOME="$CASE/home" XDG_STATE_HOME="${AF_XDG_STATE_HOME:-$CASE/home/.local/state}" HOST_CONF="$CASE/host.conf" KIT_LOG_DIR="$CASE/logs" \
    strace -f -yy -o "$CASE/trace" -e trace=fsync,fdatasync,mkdir,mkdirat,rename,renameat,renameat2 \
    bash "$KIT_DIR/components/git-hub/git-hub" "$@" > "$TMP/out" 2>&1
  AF_RC=$?
}
aforder() {
  python3 - "$CASE/trace" "$STATE_AF" "$CASE/home" "$@" <<'PY'
import ast, pathlib, re, sys
root = pathlib.Path(sys.argv[2])
home = pathlib.Path(sys.argv[3])
expected = {root / name for name in sys.argv[4:]}
events, renamed = [], set()
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if not re.search(r'= 0\s*$', line):
        continue
    call = re.search(r'\b(?:mkdir|mkdirat)\(', line)
    if call:
        paths = re.findall(r'"(?:[^"\\]|\\.)*"', line)
        if paths:
            path = pathlib.Path(ast.literal_eval(paths[0]))
            if home in path.parents and any(path in dest.parents for dest in expected):
                events.append(('mkdir', path))
        continue
    call = re.search(r'\b(?:rename|renameat|renameat2)\(', line)
    if call:
        paths = [ast.literal_eval(p) for p in re.findall(r'"(?:[^"\\]|\\.)*"', line)]
        if len(paths) != 2:
            continue
        source, dest = map(pathlib.Path, paths)
        if root in dest.parents:
            events.append(('rename', source, dest)); renamed.add(dest)
        continue
    match = re.search(r'\bfsync\(\d+<([^>]+)>\)', line)
    if match:
        path = pathlib.Path(match[1])
        if path == home or home in path.parents:
            events.append(('sync', path))
assert renamed == expected, f'publications {renamed}, expected {expected}'
for offset, event in enumerate(events):
    if event[0] == 'rename':
        assert offset > 0 and events[offset-1] == ('sync', event[1]), f'temp not fsynced before rename: {events}'
        assert offset+1 < len(events) and events[offset+1] == ('sync', event[2].parent), f'directory not fsynced after rename: {events}'
    if event[0] == 'mkdir':
        publication = next(i for i in range(offset+1, len(events))
                           if events[i][0] == 'rename' and event[1] in events[i][2].parents)
        assert ('sync', event[1].parent) in events[offset+1:publication], f'new directory parent not fsynced before publication: {event[1]}'
print('every new directory entry and file publication has ordered fsync barriers')
PY
}
afclean() { [[ -z "$(find "$STATE_AF" -type f -name '*.tmp.*' -print 2>/dev/null)" ]]; }

afsetup release; afcli release; aforder release/books.lease release/books.request > "$CASE/order" 2>&1; ORDER_RC=$?
assert 'AF1. unattended release fsyncs each temp before rename and its directory afterward' \
  '(( AF_RC == 0 && ORDER_RC == 0 )) && afclean'
afsetup relay; afcli relay; aforder relay/books > "$CASE/order" 2>&1; ORDER_RC=$?
assert 'AF2. unattended relay delivery marker has file-rename-directory fsync order' \
  '(( AF_RC == 0 && ORDER_RC == 0 )) && afclean'
afsetup content docs; afcli release; aforder books/main > "$CASE/order" 2>&1; ORDER_RC=$?
assert 'AF3. unattended content-forward marker has file-rename-directory fsync order' \
  '(( AF_RC == 0 && ORDER_RC == 0 )) && afclean'

afsetup file-failure; AF_INJECT=file afcli release
assert 'AF4. failed file fsync fails release before publication and removes its temp' \
  '(( AF_RC != 0 )) && grep -q "EIO" "$CASE/fault.log" && [[ ! -e "$STATE_AF/release/books.lease" && ! -e "$STATE_AF/release/books.request" ]] && afclean'
afsetup dir-failure; AF_INJECT=directory afcli release
assert 'AF5. failed directory fsync is reported even after rename, and removes its temp' \
  '(( AF_RC != 0 )) && grep -q "EIO" "$CASE/fault.log" && [[ -s "$STATE_AF/release/books.lease" && ! -e "$STATE_AF/release/books.request" ]] && afclean'
afcli release
assert 'AF6. release retries a failed directory sync without losing the queued review' \
  '(( AF_RC == 0 )) && [[ -s "$STATE_AF/release/books.lease" && -s "$STATE_AF/release/books.request" ]] && grep -q "$HEAD_SHA" "$STATE_AF/release/books.request" && afclean'

afsetup relay-file-failure; AF_INJECT=file afcli relay
assert 'AF7. failed relay marker file fsync reaches caller and leaves delivery unrecorded' \
  '(( AF_RC != 0 )) && grep -q "EIO" "$CASE/fault.log" && [[ ! -e "$STATE_AF/relay/books" ]] && ! grep -q "git-hub relay:.*sent" "$TMP/out" && afclean'
afsetup relay-dir-failure; AF_INJECT=directory afcli relay
assert 'AF8. failed relay marker directory fsync reaches caller without reporting success' \
  '(( AF_RC != 0 )) && grep -q "EIO" "$CASE/fault.log" && [[ -s "$STATE_AF/relay/books" ]] && ! grep -q "git-hub relay:.*sent" "$TMP/out" && afclean'
afsetup forward-failure; AF_INJECT=file afcli forward books main
assert 'AF9. shared forward marker sync failure reaches the forwarding caller' \
  '(( AF_RC != 0 )) && grep -q "EIO" "$CASE/fault.log" && [[ ! -e "$STATE_AF/books/main" ]] && afclean'
afsetup reject-failure; afcli release; AF_INJECT=file afcli verdict books "$HEAD_SHA" reject rejected
assert 'AF10. rejection sync failure preserves the request and lease for retry' \
  '(( AF_RC != 0 )) && grep -q "EIO" "$CASE/fault.log" && [[ ! -e "$STATE_AF/release/books.rejected.d/$HEAD_SHA" && -s "$STATE_AF/release/books.request" && -s "$STATE_AF/release/books.lease" ]] && afclean'
afsetup pass-failure; afcli release; AF_INJECT=file afcli verdict books "$HEAD_SHA" pass --sol=limit accepted
assert 'AF11. verdict forward-marker sync failure preserves the request and lease' \
  '(( AF_RC != 0 )) && grep -q "EIO" "$CASE/fault.log" && [[ ! -e "$STATE_AF/books/main" && -s "$STATE_AF/release/books.request" && -s "$STATE_AF/release/books.lease" ]] && afclean'
afsetup t3x-failure; echo git_hub_review_via=t3x >> "$CASE/host.conf"; : > "$AF/deliveries"
AF_INJECT=file afcli release
assert 'AF12. review lease sync failure stops T3 delivery and reaches caller' \
  '(( AF_RC != 0 )) && grep -q "EIO" "$CASE/fault.log" && [[ ! -s "$AF/deliveries" && ! -e "$STATE_AF/release/books.lease" ]] && afclean'
afsetup content-failure docs; AF_INJECT=file afcli release
assert 'AF13. unattended content-forward marker sync failure reaches release caller' \
  '(( AF_RC != 0 )) && grep -q "EIO" "$CASE/fault.log" && [[ ! -e "$STATE_AF/books/main" ]] && afclean'

afsetup fresh-ancestry
AF_XDG_STATE_HOME="$CASE/home/fresh/nested/state"; STATE_AF="$AF_XDG_STATE_HOME/git-hub"
git --git-dir="$CASE/hub/books.git" update-ref refs/heads/feature/deep/topic "$HEAD_SHA"
afcli forward books feature/deep/topic
aforder books/feature/deep/topic > "$CASE/order" 2>&1; ORDER_RC=$?
(( ORDER_RC == 0 )) || cat "$CASE/order"
assert 'AF14. fresh nested state directories have each parent fsynced before publication' \
  '(( AF_RC == 0 && ORDER_RC == 0 )) && [[ -s "$STATE_AF/books/feature/deep/topic" ]] && afclean'
unset AF_XDG_STATE_HOME

afsetup ancestry-failure
AF_FRESH_INJECT=1 AF_INJECT=ancestry afcli release
assert 'AF15. new-directory parent fsync failure reaches caller before file publication' \
  '(( AF_RC != 0 )) && grep -Fxq "ancestry EIO $CASE/home" "$CASE/fault.log" && [[ ! -e "$STATE_AF/release/books.lease" ]] && afclean'

# The failed attempt left .local behind. Its existence is not durability proof.
afancestry() {
  python3 - "$CASE/trace" "$CASE/home" "$STATE_AF" <<'PY'
import pathlib, re, sys
trace, parent, state = sys.argv[1:]
lines = pathlib.Path(trace).read_text().splitlines()
publication = next(i for i, line in enumerate(lines)
                   if re.search(r"\b(?:rename|renameat|renameat2)\(", line) and state in line and re.search(r"= 0\s*$", line))
assert any(re.search(r"fsync\(\d+<" + re.escape(parent) + r">\)\s*= 0\s*$", line)
           for line in lines[:publication]), f"retry skipped fsync of existing directory's parent: {parent}"
PY
}
[[ -d "$CASE/home/.local" && ! -e "$STATE_AF/release/books.lease" ]] && LEFTOVER_DIR=1 || LEFTOVER_DIR=0
cp "$CASE/trace" "$CASE/first.trace"
afcli release; afancestry > "$CASE/retry-order" 2>&1; RETRY_ORDER_RC=$?
(( RETRY_ORDER_RC == 0 )) || cat "$CASE/retry-order"
assert 'AF16. retry after parent EIO re-fsyncs that parent despite existing directories' \
  '(( AF_RC == 0 && RETRY_ORDER_RC == 0 && LEFTOVER_DIR == 1 )) && [[ -s "$STATE_AF/release/books.request" ]] && afclean'

afsetup ancestry-interrupted
AF_FRESH_INJECT=1 AF_INJECT=kill afcli release
INTERRUPTED_RC=$AF_RC
[[ -d "$CASE/home/.local" && ! -e "$STATE_AF/release/books.lease" ]] && LEFTOVER_DIR=1 || LEFTOVER_DIR=0
cp "$CASE/trace" "$CASE/first.trace"
afcli release; afancestry > "$CASE/retry-order" 2>&1; RETRY_ORDER_RC=$?
(( RETRY_ORDER_RC == 0 )) || cat "$CASE/retry-order"
assert 'AF17. retry after kill at parent barrier re-fsyncs existing ancestry and finishes' \
  '(( INTERRUPTED_RC != 0 && AF_RC == 0 && RETRY_ORDER_RC == 0 && LEFTOVER_DIR == 1 )) && grep -Fxq "kill EIO $CASE/home" "$CASE/fault.log" && [[ -s "$STATE_AF/release/books.request" ]] && afclean'
