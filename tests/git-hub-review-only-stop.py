"""Kill an actual PASS at mark publication, then retry through the gate."""
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

sha = sys.argv[1]
root = Path(os.environ['RO'])
state = Path(os.environ['RO_STATE'])
marker = state / 'patches/main'
request = state / 'release/patches.request'
flag = root / 'kill-before-mark'
checkpoint = root / 'mark-started'
checkpoint.unlink(missing_ok=True)
flag.touch()
command = ['bash', os.environ['KIT_DIR'] + '/components/git-hub/git-hub', 'gate']
env = dict(os.environ, SSH_ORIGINAL_COMMAND=f'verdict patches {sha} pass --sol=fixture accepted')
process = subprocess.Popen(command, env=env, start_new_session=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
try:
    deadline = time.monotonic() + 8
    while not checkpoint.exists() and process.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)
    assert checkpoint.exists(), 'PASS never reached mark-publication checkpoint'
    assert not marker.exists() and request.exists(), 'mark published or review lost before checkpoint'
finally:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()
    flag.unlink(missing_ok=True)
# The release timer still exposes the same review after the crash.
subprocess.run(command[:-1] + ['release'], check=True, timeout=15)
assert request.exists() and not marker.exists(), 'release lost the interrupted verdict retry'
assert not list(marker.parent.glob('main.tmp.*')), 'interrupted mark temp was not recovered'
subprocess.run(command, env=env, check=True, timeout=15)
assert marker.read_text().strip() == sha, 'retry failed to record the reviewed SHA'
assert not request.exists(), 'retry did not retire the request'
subprocess.run(command[:-1] + ['release'], check=True, timeout=15)
assert not request.exists(), 'released commit was reviewed again'
