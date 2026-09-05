#!/bin/bash
# Calibration for lib.sh do_or_say under bootstrap's quiet mode: a command's
# own output goes to the script log, not the terminal. The terminal gets the
# one-line "+ cmd" and, on FAILURE only, the tail of the output.
#
# Why: a fresh-VM install printed every apt-get transcript, every pub-get
# package list, every installer banner — thousands of lines nobody can read
# (2026-09-05), and the four lines that mattered were buried in them.
set -uo pipefail
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
assert() { if eval "$2"; then ((pass++)); echo "  ok   $1"; else ((fail++)); echo "  FAIL $1"; fi; }
run() { # quiet(1/0) cmd...
  local q="$1"; shift
  KIT_RUN_LOG="$( (( q )) && echo "$TMP/run.log" || echo "")" \
  LOG_DIR_OVERRIDE="$TMP" SCRIPT_NAME=quiet-test \
    bash -c 'source "$1"; shift; LOG_DIR="$LOG_DIR_OVERRIDE"; INSTALL=1; do_or_say "$@"' _ "$KIT_DIR/lib.sh" "$@" \
    >"$TMP/out" 2>"$TMP/err"; echo $?
}
echo "quiet do_or_say"
rc=$(run 1 bash -c 'echo CHAT""TER-LINE-1; echo CHAT""TER-LINE-2; exit 0')
assert "success: exit code passes through"          '[[ "$rc" == 0 ]]'
assert "success: command output NOT on the terminal" '! grep -q CHATTER "$TMP/out" "$TMP/err"'
assert "success: the '+ cmd' line still shows"       'grep -q "+ bash -c" "$TMP/out"'
assert "success: output landed in the script log"    'grep -q CHATTER-LINE-2 "$TMP/quiet-test.log"'
rc=$(run 1 bash -c 'echo noise; echo THE-""ERROR; exit 7')
assert "failure: exit code passes through"           '[[ "$rc" == 7 ]]'
assert "failure: tail of the output IS shown"        'grep -q THE-ERROR "$TMP/out"'
assert "failure: the exit code is stated"            'grep -q "✗ exit 7" "$TMP/out"'
: > "$TMP/quiet-test.log"
rc=$(run 0 bash -c 'echo VERB""OSE-LINE; exit 0')
assert "verbose (standalone) mode still streams output" 'grep -q VERBOSE-LINE "$TMP/out"'

# --- the terminal must tell the user what is going on, not just dots ---
# section headers, WARN/FAIL lines and actions are the narrative; OK detail
# and timestamps belong in the log. Nothing may land in the run log twice
# (bootstrap tees stdout into it AND counts [WARN] lines there).
: > "$TMP/run.log"
KIT_RUN_LOG="$TMP/run.log" LOG_DIR_OVERRIDE="$TMP" SCRIPT_NAME=quiet-test \
  bash -c 'source "$1"; LOG_DIR="$LOG_DIR_OVERRIDE"; INSTALL=1
           section "apt packages (install)"; ok "all good"; warn "python 3.12 not built"; hint "pyenv install 3.12"
           fail "something broke"; log "downloading zoom"; do_or_say true' _ "$KIT_DIR/lib.sh" \
  >"$TMP/out" 2>/dev/null
assert "section header reaches the terminal"        'grep -q "apt packages (install)" "$TMP/out"'
assert "WARN line reaches the terminal, inline"     'grep -q "python 3.12 not built" "$TMP/out"'
assert "hint follows its WARN on the terminal"      'grep -q "pyenv install 3.12" "$TMP/out"'
assert "FAIL line reaches the terminal"             'grep -q "something broke" "$TMP/out"'
assert "OK detail does NOT (dots only)"             '! grep -q "all good" "$TMP/out"'
assert "WARN not written to the run log directly (tee does it; else counted twice)" \
                                                     '[[ "$(grep -c "python 3.12" "$TMP/run.log")" == 0 ]]'
assert "OK detail IS in the run log (only path for it)" 'grep -q "all good" "$TMP/run.log"'
assert "no timestamps on the terminal"              '! grep -qE "^\[20[0-9]{2}-" "$TMP/out"'
assert "timestamps kept in the script log"          'grep -qE "^\[20[0-9]{2}-.*downloading zoom" "$TMP/quiet-test.log"'
assert "action line ends with a ✓ and a duration"   'grep -qE "true.*✓ [0-9]+s" "$TMP/out"'
echo "  $pass passed, $fail failed"
(( fail == 0 ))
