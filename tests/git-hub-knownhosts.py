"""Prove workstation check cannot save host keys, against an isolated loopback sshd."""
import hashlib
import json
import os
import pwd
from pathlib import Path
import re
import shlex
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
PubkeyAuthentication yes
KbdInteractiveAuthentication no
PermitEmptyPasswords no
AuthorizedKeysFile {home}/.ssh/git_hub.pub
StrictModes no
PermitUserRC no
PermitUserEnvironment no
ForceCommand internal-sftp -Q requests
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
control = home / '.ssh' / 'mux'
local_marker = home / 'check-ran-local-command'
base_command = env['GIT_SSH_COMMAND']


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


def control_status():
    status = subprocess.run(['/usr/bin/ssh', '-F', str(ssh_config), '-S', str(control),
                             '-O', 'check', 'git-hub'], capture_output=True, text=True, timeout=5)
    pid = re.search(r'Master running \(pid=(\d+)\)', status.stderr)
    return status.returncode == 0, int(pid.group(1)) if pid else None


def stop_control():
    live, pid = control_status()
    if live:
        subprocess.run(['/usr/bin/ssh', '-F', str(ssh_config), '-S', str(control),
                        '-O', 'exit', 'git-hub'], capture_output=True, timeout=5)
        deadline = time.monotonic() + 5
        while control.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        if control_status()[0] and pid is not None:
            os.kill(pid, signal.SIGTERM)
        if control_status()[0]:
            raise RuntimeError('fixture control master did not stop')
    control.unlink(missing_ok=True)


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
        public = key.with_suffix('.pub').read_text().split()
        known.write_text(f'[127.0.0.1]:{port} {public[0]} {public[1]}\n')
        authenticated = subprocess.run(['/usr/bin/ssh', '-v', '-F', str(ssh_config),
            '-o', 'StrictHostKeyChecking=yes', '-o', 'UpdateHostKeys=no',
            '-o', 'ControlPath=none', '-o', 'ControlMaster=no', '-o', 'PermitLocalCommand=no',
            'git-hub', 'ignored'], capture_output=True, text=True, timeout=10)
        # The forced SFTP command can reject the session after authentication.
        # Measure the completed public-key handshake, calibrated with a wrong key.
        rejected = subprocess.run(['/usr/bin/ssh', '-v', '-F', '/dev/null', '-p', str(port),
            '-l', pwd.getpwuid(os.getuid()).pw_name, '-i', str(alternate),
            '-o', 'BatchMode=yes', '-o', 'IdentityAgent=none', '-o', 'IdentitiesOnly=yes',
            '-o', 'PreferredAuthentications=publickey', '-o', 'StrictHostKeyChecking=yes',
            '-o', f'UserKnownHostsFile={known}', '-o', 'GlobalKnownHostsFile=/dev/null',
            '127.0.0.1', 'ignored'], capture_output=True, text=True, timeout=10)
        result['authenticated'] = (bool(re.search(r'Authenticated to .* using "publickey"', authenticated.stderr))
            and rejected.returncode != 0 and 'Permission denied (publickey)' in rejected.stderr
            and 'Authenticated to ' not in rejected.stderr)
        base_config = ssh_config.read_text()
        ssh_config.write_text(f'Host *\n  ControlMaster auto\n  ControlPath {control}\n  ControlPersist 60\n' + base_config)
        env['GIT_SSH_COMMAND'] = base_command + f' -o ControlMaster=auto -o ControlPath={control} -o ControlPersist=60'
        before = state()
        try:
            control_check = run('check', 'control-master-check')
            result['control_check_readonly'] = (control_check.returncode == 0 and
                state() == before and not control.exists() and not control_status()[0])
        finally:
            stop_control()
        before = state()
        try:
            control_install = run('install', 'control-master-install')
            result['install_control_observed'] = (control_install.returncode == 0 and
                state() != before and control.is_socket() and control_status()[0])
        finally:
            stop_control()
        # No multiplexing in this case. The marker can only come from LocalCommand.
        ssh_config.write_text(f'Host *\n  PermitLocalCommand yes\n  LocalCommand /usr/bin/touch {local_marker}\n' + base_config)
        env['GIT_SSH_COMMAND'] = base_command + ' -o PermitLocalCommand=yes -o ' + shlex.quote(f'LocalCommand=/usr/bin/touch {local_marker}')
        before = state()
        local_check = run('check', 'local-command-check')
        result['local_command_check_readonly'] = (local_check.returncode == 0 and
            state() == before and not local_marker.exists())
        local_marker.unlink(missing_ok=True)
        before = state()
        local_install = run('install', 'local-command-install')
        result['install_local_command_observed'] = (local_install.returncode == 0 and
            state() != before and local_marker.exists())
        report.write_text(json.dumps(result))
        print('git hub real sshd: ' + json.dumps(result))
    finally:
        real_ssh.unlink(missing_ok=True)
        try:
            stop_control()
        finally:
            try:
                os.killpg(server.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                server.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(server.pid, signal.SIGKILL)
                server.wait()
