# shellcheck shell=bash disable=SC2034
# Class: every unattended temp-to-final state publication needs file fsync,
# rename, then directory fsync. Trace the public CLI, not an extracted helper.
AF="$TMP/atomic-fsync"; mkdir -p "$AF/bin"
export AF LC_ALL=C
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
  local inject="${AF_INJECT:-}"; local -a opts=()
  [[ -z "$inject" ]] || opts=(-e "inject=fsync:error=EIO:when=$inject")
  env PATH="$AF/bin:/usr/bin:/bin" HOME="$CASE/home" HOST_CONF="$CASE/host.conf" KIT_LOG_DIR="$CASE/logs" \
    strace -f -yy -o "$CASE/trace" -e trace=fsync,fdatasync,rename,renameat,renameat2 "${opts[@]}" \
    bash "$KIT_DIR/components/git-hub/git-hub" "$@" > "$TMP/out" 2>&1
  AF_RC=$?
}
aforder() {
  python3 - "$CASE/trace" "$STATE_AF" "$@" <<'PY'
import ast, pathlib, re, sys
root = pathlib.Path(sys.argv[2])
expected = {root / name for name in sys.argv[3:]}
events, renamed = [], set()
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    if not re.search(r'= 0\s*$', line):
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
        if path == root or root in path.parents:
            events.append(('sync', path))
assert renamed == expected, f'publications {renamed}, expected {expected}'
assert len(events) == 3 * len(expected), f'expected file fsync, rename, dir fsync for every publication; got {events}'
for offset in range(0, len(events), 3):
    before, rename, after = events[offset:offset+3]
    assert rename[0] == 'rename', f'publication order: {events}'
    assert before == ('sync', rename[1]), f'temp not fsynced before rename: {events}'
    assert after == ('sync', rename[2].parent), f'directory not fsynced after rename: {events}'
print('every state publication: file fsync -> rename -> directory fsync')
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

afsetup file-failure; AF_INJECT=1 afcli release
assert 'AF4. failed file fsync fails release before publication and removes its temp' \
  '(( AF_RC != 0 )) && grep -Eq "fsync.*EIO.*INJECTED" "$CASE/trace" && [[ ! -e "$STATE_AF/release/books.lease" && ! -e "$STATE_AF/release/books.request" ]] && afclean'
afsetup dir-failure; AF_INJECT=2 afcli release
assert 'AF5. failed directory fsync is reported even after rename, and removes its temp' \
  '(( AF_RC != 0 )) && grep -Eq "fsync.*EIO.*INJECTED" "$CASE/trace" && [[ -s "$STATE_AF/release/books.lease" && ! -e "$STATE_AF/release/books.request" ]] && afclean'
afcli release
assert 'AF6. release retries a failed directory sync without losing the queued review' \
  '(( AF_RC == 0 )) && [[ -s "$STATE_AF/release/books.lease" && -s "$STATE_AF/release/books.request" ]] && grep -q "$HEAD_SHA" "$STATE_AF/release/books.request" && afclean'

afsetup relay-file-failure; AF_INJECT=1 afcli relay
assert 'AF7. failed relay marker file fsync reaches caller and leaves delivery unrecorded' \
  '(( AF_RC != 0 )) && grep -Eq "fsync.*EIO.*INJECTED" "$CASE/trace" && [[ ! -e "$STATE_AF/relay/books" ]] && ! grep -q "git-hub relay:.*sent" "$TMP/out" && afclean'
afsetup relay-dir-failure; AF_INJECT=2 afcli relay
assert 'AF8. failed relay marker directory fsync reaches caller without reporting success' \
  '(( AF_RC != 0 )) && grep -Eq "fsync.*EIO.*INJECTED" "$CASE/trace" && [[ -s "$STATE_AF/relay/books" ]] && ! grep -q "git-hub relay:.*sent" "$TMP/out" && afclean'
afsetup forward-failure; AF_INJECT=1 afcli forward books main
assert 'AF9. shared forward marker sync failure reaches the forwarding caller' \
  '(( AF_RC != 0 )) && grep -Eq "fsync.*EIO.*INJECTED" "$CASE/trace" && [[ ! -e "$STATE_AF/books/main" ]] && afclean'
afsetup reject-failure; afcli release; AF_INJECT=1 afcli verdict books "$HEAD_SHA" reject rejected
assert 'AF10. rejection sync failure preserves the request and lease for retry' \
  '(( AF_RC != 0 )) && grep -Eq "fsync.*EIO.*INJECTED" "$CASE/trace" && [[ ! -e "$STATE_AF/release/books.rejected.d/$HEAD_SHA" && -s "$STATE_AF/release/books.request" && -s "$STATE_AF/release/books.lease" ]] && afclean'
afsetup pass-failure; afcli release; AF_INJECT=1 afcli verdict books "$HEAD_SHA" pass --sol=limit accepted
assert 'AF11. verdict forward-marker sync failure preserves the request and lease' \
  '(( AF_RC != 0 )) && grep -Eq "fsync.*EIO.*INJECTED" "$CASE/trace" && [[ ! -e "$STATE_AF/books/main" && -s "$STATE_AF/release/books.request" && -s "$STATE_AF/release/books.lease" ]] && afclean'
afsetup t3x-failure; echo git_hub_review_via=t3x >> "$CASE/host.conf"; : > "$AF/deliveries"
AF_INJECT=1 afcli release
assert 'AF12. review lease sync failure stops T3 delivery and reaches caller' \
  '(( AF_RC != 0 )) && grep -Eq "fsync.*EIO.*INJECTED" "$CASE/trace" && [[ ! -s "$AF/deliveries" && ! -e "$STATE_AF/release/books.lease" ]] && afclean'
afsetup content-failure docs; AF_INJECT=1 afcli release
assert 'AF13. unattended content-forward marker sync failure reaches release caller' \
  '(( AF_RC != 0 )) && grep -Eq "fsync.*EIO.*INJECTED" "$CASE/trace" && [[ ! -e "$STATE_AF/books/main" ]] && afclean'
