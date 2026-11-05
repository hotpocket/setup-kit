"""Check a stalled gate verdict's timeout, child cleanup, lock and retry."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

sha, output = sys.argv[1:3]
cooperative = len(sys.argv) > 3 and sys.argv[3] == 'cooperative'
root = Path(os.environ['TMP'])
state = Path(os.environ['HOME']) / '.local/state/git-hub'
request = state / 'release/books.request'
lease = state / 'release/books.lease'
expected_request = request.read_bytes() if request.exists() else None
expected_lease = lease.read_bytes() if lease.exists() else None
original_command = f'verdict books {sha} pass --sol=task-timeout "bounded retry"'
command = ['bash', os.environ['KIT_DIR'] + '/components/git-hub/git-hub', 'gate']
env = dict(os.environ, SSH_ORIGINAL_COMMAND=original_command)
required = root / 'require-network-env'
was_required = required.exists()
required.unlink(missing_ok=True)
(root / 'upstream-started').unlink(missing_ok=True)
(root / 'upstream-pids').unlink(missing_ok=True)
(root / 'block-upstream').write_text('push\n')
if cooperative:
    (root / 'stall-cooperative').touch()
exits = root / 'network-exits'
before_exits = len(exits.read_text().splitlines()) if exits.exists() else 0
release_log = state / 'release.log'
before_log = len(release_log.read_text().splitlines()) if release_log.exists() else 0
result = {}


def run_client():
    # EOF can lag the client's exit because inherited pipes have other writers.
    # Measure process exit here; check the upstream PIDs independently below.
    with tempfile.TemporaryFile(mode='w+t') as log:
        p = subprocess.Popen(command, env=env, stdout=log, stderr=log,
                             text=True, start_new_session=True)
        started = time.monotonic()
        result.setdefault('first_session', p.pid)
        bounded = True
        try:
            p.wait(timeout=8)
        except subprocess.TimeoutExpired:
            bounded = False
            try:
                os.killpg(p.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            cleanup_upstream(p.pid)
            p.wait(timeout=2)
        elapsed = time.monotonic() - started
        log.seek(0)
        return p.returncode, bounded, log.read().splitlines()[-12:], elapsed


def same_live_process(pid, start):
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().split()
        return fields[21] == start and fields[2] != 'Z'
    except (OSError, IndexError):
        return False


def cleanup_upstream(session):
    pid_file = root / 'upstream-pids'
    if not pid_file.exists():
        return
    for line in pid_file.read_text().splitlines():
        pid, start = line.split()
        pid = int(pid)
        if same_live_process(pid, start):
            try:
                # The client has its own session. Reuse of a recorded PID or
                # another test's process group cannot authorize a kill.
                if os.getsid(pid) == session:
                    group = os.getpgid(pid)
                    if group != os.getpgrp():
                        os.killpg(group, signal.SIGKILL)
            except ProcessLookupError:
                pass


try:
    first_rc, server_bounded, first_detail, first_seconds = run_client()
    result.update(first_rc=first_rc, client_finished=server_bounded, first_detail=first_detail, first_seconds=first_seconds)
    result.update(started=(root / 'upstream-started').exists(), server_bounded=server_bounded and first_rc != 0)
    first_exits = exits.read_text().splitlines()[before_exits:] if exits.exists() else []
    result['exit_124'] = first_exits == ['124']
    first_log = release_log.read_text().splitlines()[before_log:] if release_log.exists() else []
    result['timeout_logged'] = (len(first_log) == 1 and
                                f'books main {sha[:9]}:' in first_log[0] and
                                'forward timed out -- retry' in first_log[0])
    pids = []
    if (root / 'upstream-pids').exists():
        pids = [line.split() for line in (root / 'upstream-pids').read_text().splitlines()]
    alive = [(int(pid), start) for pid, start in pids if same_live_process(int(pid), start)]
    children_by = time.monotonic() + 3
    while alive and time.monotonic() < children_by:
        time.sleep(0.02)
        alive = [(pid, start) for pid, start in alive if same_live_process(pid, start)]
    result['remaining_children'] = len(alive)
    result['children_dead'] = bool(pids) and not alive and server_bounded
    # Reap the operation's whole group on a failed probe.
    if alive:
        cleanup_upstream(result['first_session'])
    try:
        with (state / 'release.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result['lock_free'] = True
    except BlockingIOError:
        result['lock_free'] = False
    result['request_kept'] = (expected_request is not None and expected_lease is not None
                              and request.exists() and request.read_bytes() == expected_request
                              and lease.exists() and lease.read_bytes() == expected_lease)
    (root / 'block-upstream').unlink(missing_ok=True)
    retry_rc, retry_bounded, _, _ = run_client()
    result['retry_ok'] = retry_rc == 0 and retry_bounded and not request.exists() and not lease.exists()
    upstream = subprocess.check_output(['/usr/bin/git', '--git-dir=' + os.environ['GH'] + '/acme/books.git',
                                        'rev-parse', 'main'], text=True).strip()
    result['exact_sha'] = upstream == sha
finally:
    (root / 'block-upstream').unlink(missing_ok=True)
    (root / 'stall-cooperative').unlink(missing_ok=True)
    if was_required:
        required.touch()
Path(output).write_text(json.dumps(result))
print('network stall instrument completed')
