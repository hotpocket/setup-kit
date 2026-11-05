"""Kill release at request rename and inspect recovery through release/pending."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

sha, output = sys.argv[1:]
root = Path(os.environ['TMP'])
queue = Path(os.environ['HOME']) / '.local/state/git-hub/release'
lease = queue / 'books.lease'
request = queue / 'books.request'
flag = root / 'crash-request-rename'
marker = root / 'request-rename-started'
marker.unlink(missing_ok=True)
flag.touch()
command = ['bash', os.environ['KIT_DIR'] + '/components/git-hub/git-hub']
p = subprocess.Popen(command + ['release'], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, start_new_session=True)
deadline = time.monotonic() + 8
try:
    while not marker.exists() and p.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)
    before = lease.read_bytes() if lease.exists() else None
    result = dict(checkpoint_seen=marker.exists(), lease_only=lease.exists() and not request.exists(),
                  had_temp=bool(list(queue.glob('*.tmp.*'))))
finally:
    try:
        os.killpg(p.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    p.wait()
    flag.unlink(missing_ok=True)
# Include stale names no longer in the current repo list, including dotfiles.
queue.mkdir(parents=True, exist_ok=True)
(queue / '.old-repo.lease.tmp.orphan').touch()
replay = subprocess.Popen(command + ['release'], stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, start_new_session=True)
try:
    replay_rc = replay.wait(timeout=8)
except subprocess.TimeoutExpired:
    os.killpg(replay.pid, signal.SIGKILL)
    replay.wait()
    replay_rc = -1
result['replay_ok'] = replay_rc == 0
result['lease_unchanged'] = before is not None and lease.exists() and lease.read_bytes() == before
result['attempt_preserved'] = (before is not None and lease.exists()
                               and lease.read_bytes().split()[4] == before.split()[4])
result['attempt_two'] = lease.exists() and lease.read_bytes().split()[4] == b'2'
header = request.read_text().splitlines()[0].split() if request.exists() else []
result['request_valid'] = len(header) == 4 and header[0] == 'books' and header[1] == 'main' and header[3] == sha
result['temps_swept'] = not list(queue.glob('*.tmp.*'))
pending = subprocess.run(command + ['gate'], env=dict(os.environ, SSH_ORIGINAL_COMMAND='pending'),
                         capture_output=True, text=True, timeout=30)
result['pending_visible'] = pending.returncode == 0 and ('=== books ' + sha + ' ') in pending.stdout
Path(output).write_text(json.dumps(result))
print('queue crash instrument completed')
