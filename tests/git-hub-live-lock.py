"""Hold an actual prepared ref transaction while invoking the installed sweep."""
from pathlib import Path
import json
import os
import select
import subprocess
import sys
import time

sweep, root = map(Path, sys.argv[1:])
root.mkdir(parents=True)
repo = root / 'held.git'
env = os.environ | dict(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_COUNT='0',
                        GIT_AUTHOR_NAME='test', GIT_AUTHOR_EMAIL='test@example.invalid',
                        GIT_COMMITTER_NAME='test', GIT_COMMITTER_EMAIL='test@example.invalid')
env.pop('GIT_CONFIG_PARAMETERS', None)
subprocess.run(['git', 'init', '-q', '--bare', '-b', 'main', str(repo)], env=env, check=True)


def git(*args, data=None):
    return subprocess.check_output(['git', f'--git-dir={repo}', *args], env=env, input=data, text=True).strip()


tree = git('mktree', data='')
before = git('commit-tree', tree, '-m', 'before')
after = git('commit-tree', tree, '-p', before, '-m', 'after')
git('update-ref', 'refs/heads/main', before)
proc = subprocess.Popen(['git', f'--git-dir={repo}', 'update-ref', '--stdin'], env=env,
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    proc.stdin.write(f'start\nupdate refs/heads/main {after} {before}\nprepare\n'.encode())
    proc.stdin.flush()
    response = b''
    deadline = time.monotonic() + 10
    while response.count(b'\n') < 2:
        remaining = deadline - time.monotonic()
        assert remaining > 0 and select.select([proc.stdout], [], [], remaining)[0], 'Git prepare did not respond'
        chunk = os.read(proc.stdout.fileno(), 4096)
        assert chunk, 'Git exited before prepare'
        response += chunk
    assert response.splitlines() == [b'start: ok', b'prepare: ok'], response
    lock = repo / 'refs/heads/main.lock'
    assert lock.is_file() and proc.poll() is None, 'instrument must hold a real live Git lock'
    result = subprocess.run([str(sweep), str(root)], env=env, capture_output=True, text=True, timeout=20)
    metrics = dict(sweep_refused=result.returncode == 1,
                   git_alive=proc.poll() is None, lock_survived=lock.is_file())
    proc.stdin.write(b'commit\n'); proc.stdin.flush()
    proc.communicate(timeout=10)
    metrics['git_committed'] = proc.returncode == 0 and git('rev-parse', 'refs/heads/main') == after
    print(json.dumps(metrics))
finally:
    if proc.poll() is None:
        proc.kill()
        proc.wait()
