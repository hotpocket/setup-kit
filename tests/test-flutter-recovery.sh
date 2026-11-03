#!/bin/bash
source "$(dirname "$0")/tools-fixture.sh"
conf_tools component_flutter_headless=yes
# Metadata is written before upstream precache downloads its Android artifacts.
touch "$STATE/precache-fail"; run_tools install
assert 'failed precache leaves version metadata but no completion' '[[ -s "$HOME/development/flutter/bin/cache/flutter.version.json" && ! -e "$HOME/development/flutter/bin/cache/setup-kit-android.complete" ]]'
rm "$STATE/precache-fail"; run_tools install
assert 'metadata alone does not suppress the next precache' 'grep -q "^flutter precache --android" "$CALLS" && [[ -s "$HOME/development/flutter/bin/cache/setup-kit-android.complete" ]]'
rm -f "$HOME/development/flutter/bin/cache/setup-kit-android.complete"
touch "$STATE/precache-pause"
python3 - "$KIT_DIR" "$TMP/out" <<'PY2'
import os,sys,subprocess,time,signal,pathlib
p=subprocess.Popen(['bash',sys.argv[1]+'/profiles/workstation/07-components.sh','install'],stdout=open(sys.argv[2],'w'),stderr=subprocess.STDOUT,start_new_session=True)
try:
 for _ in range(400):
  if (pathlib.Path(os.environ['STATE'])/'precache-started').exists(): break
  if p.poll() is not None: raise RuntimeError('precache never reached interruption point')
  time.sleep(.025)
 else: raise RuntimeError('precache pause not observed')
finally:
 if p.poll() is None: os.killpg(p.pid,signal.SIGKILL)
 p.wait()
PY2
assert 'kill during precache never publishes completion' '[[ -s "$HOME/development/flutter/bin/cache/flutter.version.json" && ! -e "$HOME/development/flutter/bin/cache/setup-kit-android.complete" ]] && [[ -f "$STATE/precache-started" ]]'
rm "$STATE/precache-pause"; run_tools install
assert 'restart retries killed precache and then converges' 'grep -q "^flutter precache --android" "$CALLS" && [[ -s "$HOME/development/flutter/bin/cache/setup-kit-android.complete" ]]'
run_tools install
assert 'completed precache is not repeated' '! grep -q "^flutter precache" "$CALLS"'
finish
