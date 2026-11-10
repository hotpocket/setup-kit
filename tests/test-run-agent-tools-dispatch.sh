#!/bin/bash
# run-agent-tools.sh never runs its calibrations on the calling box: it sends the whole
# suite to dev through dev-run, takes no Beast heavy lock, and fails (never runs locally)
# when dev-run fails. Stub dev-run only; no suite runs here.
set -uo pipefail
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then echo "  ok   $1"; pass=$((pass+1)); else echo "  FAIL $1"; fail=$((fail+1)); fi; }
mkdir -p "$TMP/bin"
cat > "$TMP/bin/flock" <<'S'
#!/bin/bash
echo "flock $*" >> "$STUB_LOG"; exit 97
S
cat > "$TMP/dev-run" <<'S'
#!/bin/bash
{ echo "cwd=$PWD"; printf 'arg=%s\n' "$@"; } >> "$STUB_LOG"; exit "${STUB_RC:-0}"
S
chmod +x "$TMP/bin/flock" "$TMP/dev-run"
run() { env PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" KIT_DEV_RUN="$TMP/dev-run" "$@" bash "$KIT/tests/run-agent-tools.sh" </dev/null >"$TMP/out" 2>&1; }
: > "$TMP/log"; run env STUB_RC=0; rc=$?
assert "D1. the suite goes to dev-run from the kit checkout, marked as already on dev" \
  '(( rc == 0 )) && grep -qx "cwd=$KIT" "$TMP/log" && grep -q "^arg=KIT_AGENT_TESTS_ON_DEV=1 bash tests/run-agent-tools.sh" "$TMP/log"'
assert "D2. no flock (no Beast heavy lock) on the calling box" '! grep -q "^flock" "$TMP/log"'
: > "$TMP/log"; run env STUB_RC=125; rc=$?
assert "D3. dev-run fails: runner fails with its code and runs nothing locally" '(( rc == 125 )) && ! grep -q "test-uv" "$TMP/out"'
: > "$TMP/log"; run env KIT_DEV_RUN="$TMP/missing"; rc=$?
assert "D4. dev-run missing: loud failure, nothing runs locally" '(( rc != 0 )) && grep -q "dev-run" "$TMP/out"'
echo "  $pass passed, $fail failed"; (( fail == 0 ))
