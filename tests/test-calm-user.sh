#!/bin/bash
source "$(dirname "$0")/memory-fixture.sh"
conf
printf 'leaked.service loaded failed failed\n' > "$STATE/calm-user-failed"
printf 'Id=leaked.service\nNRestarts=94\n' > "$STATE/calm-user-flap"
printf 'stuck.service loaded activating start\n' > "$STATE/calm-user-activating"
printf 'Out of memory: Killed process 123 (chrome)\n' > "$STATE/oom-log"
runv
assert 'user failures cannot hide behind a healthy system manager' 'grep -q "FAIL.*calm: user.*failed" "$TMP/out"'
assert 'user respawn loops and stuck activation are detected' 'grep -q "FAIL.*calm: user.*restart-loop" "$TMP/out" && grep -q "FAIL.*calm: user.*stuck activating" "$TMP/out"'
assert 'recent kernel OOM kills are diagnosed by name' 'grep -q "FAIL.*calm:.*OOM kill" "$TMP/out" && grep -q "Killed process 123" "$TMP/out"'
rm "$STATE/calm-user-failed" "$STATE/calm-user-flap" "$STATE/calm-user-activating" "$STATE/oom-log"; runv
assert 'positive control: healthy user manager and no recent OOM pass' 'grep -q "PASS.*calm: user.*no failed" "$TMP/out" && grep -q "PASS.*calm:.*no recent.*OOM" "$TMP/out" && ! grep -q "FAIL.*calm: user" "$TMP/out"'
assert 'verifier stays read-only' '! grep "^sudo " "$CALLS" | grep -vx "sudo -n true"'
finish
