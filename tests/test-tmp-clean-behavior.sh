#!/bin/bash
# shellcheck disable=SC2034 # assert evaluates its expression strings at runtime
# Documents CURRENT policy behaviour. This does not endorse mtime-only aging.
# Flip TMP_EXPECT_OLD when the policy decision changes; never clean host /tmp.
source "$(dirname "$0")/memory-fixture.sh"
conf tmp_on_disk=yes tmp_age_rule=yes; run07 install
mkdir -p "$ROOT/tmp"
make_files() {
  python3 - "$ROOT/tmp" <<'PY'
import os,pathlib,sys,time
root=pathlib.Path(sys.argv[1]); now=time.time_ns()
for name,age in [('old-mtime-fresh-atime',11*86400),('fresh',0)]:
 p=root/name; p.write_text('private calibration\n')
 os.utime(p,ns=(now,now-age*10**9))
PY
}
make_files
/usr/bin/systemd-tmpfiles --clean --root="$ROOT" "$ROOT/etc/tmpfiles.d/tmp.conf" > "$TMP/out" 2>&1; rc=$?
if [[ -e "$ROOT/tmp/old-mtime-fresh-atime" ]]; then observed=kept; else observed=deleted; fi
echo "CURRENT tmp rule: old mtime + fresh atime was $observed. Documentation only, not endorsement."
assert 'real tmpfiles records the current old-mtime/fresh-atime behaviour' '[[ $rc == 0 && "$observed" == "${TMP_EXPECT_OLD:-deleted}" ]]'
assert 'fresh control survives real cleanup' '[[ -f "$ROOT/tmp/fresh" ]]'
# Prove the instrument sees an age that retains the same old-mtime file.
make_files
sed 's/mM:10d/mM:100d/' "$ROOT/etc/tmpfiles.d/tmp.conf" > "$ROOT/control.conf"
/usr/bin/systemd-tmpfiles --clean --root="$ROOT" "$ROOT/control.conf" > "$TMP/out" 2>&1; rc=$?
assert 'negative control keeps the same file under a longer age' '[[ $rc == 0 && -f "$ROOT/tmp/old-mtime-fresh-atime" ]]'
finish
