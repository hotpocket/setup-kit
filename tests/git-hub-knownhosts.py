"""Prove workstation check cannot save host keys, against an isolated loopback sshd."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import sys
import time

report = Path(sys.argv[1])
home = Path(os.environ['HOME'])
temporary = Path(os.environ['TMP']) / 'loopback-sshd'
temporary.mkdir()
sshd = shutil.which('sshd') or '/usr/sbin/sshd'
if not Path(sshd).is_file():
    print('sshd binary missing; SSH argv checks still run')
    sys.exit(77)
key = temporary / 'host-key'
alternate = temporary / 'alternate-key'
for path in (key, alternate):
    subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(path)],
                   check=True, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL)
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    port = listener.getsockname()[1]
configuration = temporary / 'sshd.conf'
configuration.write_text(f'''Port {port}
ListenAddress 127.0.0.1
HostKey {key}
PidFile {temporary}/pid
UsePAM no
PasswordAuthentication no
PubkeyAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthorizedKeysFile none
LogLevel QUIET
''')
ssh_config = home / '.ssh' / 'config'
known = home / '.ssh' / 'known_hosts'
ssh_config.write_text(f'''Host *
  Port {port}
  UserKnownHostsFile {known}
  GlobalKnownHostsFile /dev/null
  UpdateHostKeys yes
''')
phase = Path(__file__).resolve().parents[1] / 'profiles/workstation/07-components.sh'
env = dict(os.environ)
# Earlier command-line values win too. Read-only probe options must precede
# caller-supplied flags, rather than merely appearing somewhere in the argv.
env['GIT_SSH_COMMAND'] = 'ssh -o StrictHostKeyChecking=accept-new -o UpdateHostKeys=yes'
env.pop('GIT_SSH', None)
real_ssh = Path(os.environ['TMP']) / 'ws-real-ssh'


def run(mode, name):
    result = subprocess.run(['bash', str(phase), mode], env=env, capture_output=True,
                            text=True, stdin=subprocess.DEVNULL, timeout=30)
    (temporary / (name + '.log')).write_text(result.stdout + result.stderr)
    return result


def state():
    digest = hashlib.sha256()
    for root in (home, Path(os.environ['GIT_HOME'])):
        for path in sorted([root, *root.rglob('*')]):
            digest.update(str(path).encode())
            digest.update(str(path.lstat().st_mode).encode())
            if path.is_symlink():
                digest.update(os.readlink(path).encode())
            elif path.is_file():
                digest.update(path.read_bytes())
    return digest.hexdigest()


with (temporary / 'server.log').open('w') as log:
    server = subprocess.Popen([sshd, '-D', '-e', '-f', str(configuration)],
                              stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                              start_new_session=True)
    try:
        ready = False
        deadline = time.monotonic() + 5
        while server.poll() is None and time.monotonic() < deadline:
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=0.2) as connection:
                    ready = connection.recv(128).startswith(b'SSH-')
                if ready:
                    break
            except OSError:
                time.sleep(0.02)
        if not ready:
            print('loopback sshd did not start; ' + (temporary / 'server.log').read_text().strip())
            sys.exit(77)
        # First provision through the existing local Git stub. The subsequent
        # probes use real SSH with -F pointing only at this fixture config.
        setup = run('install', 'setup')
        if setup.returncode:
            raise RuntimeError('profile setup failed: ' + setup.stdout + setup.stderr)
        real_ssh.touch()
        known.unlink(missing_ok=True)
        before = state()
        check = run('check', 'unknown-check')
        unchanged = state() == before and not known.exists()
        unknown = 'host key not yet trusted; install accepts it' in check.stdout
        # Reset the absent state even on a broken implementation so the install
        # calibration measures a fresh write rather than the preceding defect.
        known.unlink(missing_ok=True)
        before = state()
        install = run('install', 'accept-new-install')
        lookup = subprocess.run(['/usr/bin/ssh-keygen', '-F', f'[127.0.0.1]:{port}', '-f', str(known)],
                                capture_output=True, text=True)
        accepted = known.is_file() and lookup.returncode == 0
        written = state() != before and accepted
        before = state()
        trusted = run('check', 'trusted-check')
        trusted_readonly = trusted.returncode == 0 and state() == before
        # A changed key must never suggest that accept-new will repair it.
        public = alternate.with_suffix('.pub').read_text().split()
        known.write_text(f'[127.0.0.1]:{port} {public[0]} {public[1]}\n')
        before = state()
        changed = run('check', 'changed-key-check')
        result = dict(server_ready=True,
                      check_readonly=check.returncode == 0 and unchanged,
                      unknown_warning=unknown,
                      install_accepts_key=install.returncode == 0 and accepted,
                      detector_saw_write=written,
                      trusted_check_readonly=trusted_readonly,
                      changed_key_readonly=changed.returncode == 0 and state() == before,
                      changed_key_not_unknown='host key not yet trusted; install accepts it' not in changed.stdout
                          and 'the hub does not answer' in changed.stdout)
        report.write_text(json.dumps(result))
        print('real sshd: ' + json.dumps(result))
    finally:
        real_ssh.unlink(missing_ok=True)
        try:
            os.killpg(server.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            server.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(server.pid, signal.SIGKILL)
            server.wait()
