"""Exercise shared SSH block writers against a real sidecar flock."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

scenario, filename, output = sys.argv[1:]
target = Path(os.environ['HOME']) / '.ssh' / filename
before = target.read_bytes()
before_mode = target.stat().st_mode & 0o777
begin, end = '# >>> setup-kit lock-test', '# <<< setup-kit lock-test'
own = f'{begin}\nmanaged writer\n{end}'
admin = 'admin line\n'
other = '# >>> control block\ncontrol writer\n# <<< control block\n'
prefix = 'source "$KIT_DIR/lib.sh"; source "$KIT_DIR/components/git-hub/lib.sh"; '
generic = 'hub_block_ensure "$1" "$2" "$3" "$4" "$5"'
result = {}
client = None


def finish(p, bound):
    started = time.monotonic()
    try:
        out, err = p.communicate(timeout=bound)
        return p.returncode, out + err, time.monotonic() - started, True
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        out, err = p.communicate()
        return p.returncode, out + err, time.monotonic() - started, False


def wait_for(predicate, p, bound=3):
    deadline = time.monotonic() + bound
    while not predicate() and p.poll() is None and time.monotonic() < deadline:
        time.sleep(0.02)


try:
    with tempfile.TemporaryDirectory(prefix='block-lock-', dir=os.environ['TMP']) as directory:
        events = Path(directory)
        bin_dir = events / 'bin'
        bin_dir.mkdir()
        wrappers = {
            'flock': 'printf started > "$BLOCK_TEST_EVENTS/flock-started"\nexec /usr/bin/flock "$@"\n',
            'sed': '[[ "${@: -1}" != "$BLOCK_TEST_TARGET" ]] || touch "$BLOCK_TEST_EVENTS/read-started"\nexec /usr/bin/sed "$@"\n',
            'mv': '''if [[ "${@: -1}" == "$BLOCK_TEST_TARGET" && -n "${BLOCK_PAUSE_RENAME:-}" ]]; then
  touch "$BLOCK_TEST_EVENTS/rename-started"
  while [[ ! -e "$BLOCK_TEST_EVENTS/rename-go" ]]; do /bin/sleep 0.02; done
fi
exec /usr/bin/mv "$@"
''',
        }
        for name, body in wrappers.items():
            wrapper = bin_dir / name
            wrapper.write_text('#!/bin/bash\n' + body)
            wrapper.chmod(0o755)
        env = dict(os.environ, PATH=str(bin_dir) + ':' + os.environ['PATH'],
                   BLOCK_TEST_EVENTS=directory, BLOCK_TEST_TARGET=str(target))

        def start(body, mode=1, file=target):
            return subprocess.Popen(['bash', '-c', prefix + f'INSTALL={mode}; ' + body,
                                     'block-lock-test', str(file), begin, end, own, 'SSH test block'],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, start_new_session=True)

        target.write_text(admin + own + '\n')
        lock = Path(str(target) + '.lock')
        with lock.open('a') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            lock_inode = lock.stat().st_ino
            if scenario == 'timeout':
                public = 'hub_reviewers_ensure' if filename == 'authorized_keys' else 'hub_gate_ensure'
                client = start(public)
                code, detail, elapsed, bounded = finish(client, 35)
                result.update(failed=code != 0, bounded=bounded and 25 <= elapsed < 35,
                              loud='lock' in detail.lower() and str(lock) in detail and 'retry' in detail.lower(),
                              unchanged=target.read_text() == admin + own + '\n',
                              no_temp=not list(target.parent.glob(filename + '.tmp.*')),
                              stable_sidecar=lock.stat().st_ino == lock_inode,
                              rc=code, seconds=elapsed, detail=detail.splitlines()[-5:])
            elif scenario == 'sequence':
                env['BLOCK_PAUSE_RENAME'] = '1'
                client = start(generic)
                wait_for(lambda: (events / 'flock-started').exists() or (events / 'read-started').exists(), client)
                result['waited_before_read'] = (client.poll() is None and
                    (events / 'flock-started').exists() and not (events / 'read-started').exists())
                # The first writer replaces a file whose old managed block was
                # current. Reading before the lock would incorrectly skip repair.
                temporary = events / 'control.tmp'
                temporary.write_text(admin + other)
                temporary.chmod(0o600)
                os.replace(temporary, target)
                fcntl.flock(held, fcntl.LOCK_UN)
                wait_for(lambda: (events / 'rename-started').exists(), client)
                result['rename_seen'] = (events / 'rename-started').exists()
                with lock.open('a') as contender:
                    try:
                        fcntl.flock(contender, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        result['held_through_rename'] = False
                    except BlockingIOError:
                        result['held_through_rename'] = True
                (events / 'rename-go').touch()
                code, detail, _, bounded = finish(client, 5)
                result.update(success=code == 0 and bounded,
                              both_blocks=target.read_text() == admin + other + own + '\n',
                              stable_sidecar=lock.stat().st_ino == lock_inode,
                              mode_600=target.stat().st_mode & 0o777 == 0o600,
                              rc=code, detail=detail.splitlines()[-5:])
            else:
                raise ValueError(scenario)
        with lock.open('a') as released:
            try:
                fcntl.flock(released, fcntl.LOCK_EX | fcntl.LOCK_NB)
                result['lock_released'] = True
            except BlockingIOError:
                result['lock_released'] = False
        # Check mode must not create even a parent directory or a sidecar.
        absent = events / 'readonly' / filename
        code, _, _, bounded = finish(start(generic, mode=0, file=absent), 5)
        result['check_readonly'] = code == 0 and bounded and not absent.parent.exists()
finally:
    if client is not None and client.poll() is None:
        os.killpg(client.pid, signal.SIGKILL)
        client.communicate()
    target.write_bytes(before)
    target.chmod(before_mode)
Path(output).write_text(json.dumps(result))
print('git-hub block lock: ' + json.dumps(result))
