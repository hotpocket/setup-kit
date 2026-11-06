"""Reject reverse-order witnesses for every ordinary pre-login Git starter."""
from pathlib import Path
import json
import shutil
import subprocess
import sys

unit, output = map(Path, sys.argv[1:])
original = unit.read_text()
output.mkdir(parents=True, exist_ok=True)


def graph(name, consumer, witness=False, old=False, with_ssh=False):
    root = output / name
    units = root / 'etc/systemd/system'
    units.mkdir(parents=True)
    (root / 'bin').mkdir()
    shutil.copyfile('/bin/true', root / 'bin/true')
    (root / 'bin/true').chmod(0o755)
    helper = root / 'usr/local/libexec/git-hub-stale-locks'
    helper.parent.mkdir(parents=True)
    shutil.copyfile(root / 'bin/true', helper)
    helper.chmod(0o755)
    for target in ('local-fs', 'sysinit', 'sockets', 'basic', 'shutdown'):
        text = '[Unit]\nDefaultDependencies=no\n'
        if target == 'local-fs':
            text += 'Before=sysinit.target\n'
        if target in ('sysinit', 'sockets'):
            text += 'Before=basic.target\n'
        if target == 'basic':
            text += 'Requires=sysinit.target sockets.target\nAfter=sysinit.target sockets.target\n'
        (units / f'{target}.target').write_text(text)
    text = original
    if old:
        text = '\n'.join(
            line.split('=', 1)[0] + '=' + ' '.join(v for v in line.split('=', 1)[1].split() if v != 'basic.target')
            if line.startswith(('Before=', 'WantedBy=')) else line
            for line in text.splitlines()) + '\n'
    (units / unit.name).write_text(text)
    for line in text.splitlines():
        if line.startswith('WantedBy='):
            for target in line.split('=', 1)[1].split():
                wants = units / f'{target}.wants'
                wants.mkdir(exist_ok=True)
                (wants / unit.name).symlink_to('../' + unit.name)
    before = 'Before=git-hub-stale-locks.service\n' if witness else ''
    (units / consumer).write_text('[Unit]\n' + before + '[Service]\nExecStart=/bin/true\n')
    if with_ssh:
        (units / 'ssh.service').write_text('[Service]\nExecStart=/bin/true\n')
    (units / 'systemd-journald.socket').write_text('[Socket]\nListenDatagram=/run/systemd/journal/socket\n')
    (units / 'multi-user.target').write_text(
        f'[Unit]\nDefaultDependencies=no\nWants=basic.target {consumer}{" ssh.service" if with_ssh else ""}\nAfter=basic.target\n')
    result = subprocess.run(
        ['systemd-analyze', f'--root={root}', '--generators=no', '--man=no', 'verify', 'multi-user.target'],
        capture_output=True, text=True, timeout=20)
    diagnostics = result.stdout + result.stderr
    (root / 'verify.log').write_text(diagnostics)
    cycle = 'ordering cycle' in diagnostics or 'deleted to break' in diagnostics
    return result.returncode, cycle


metrics = {}
for name, consumer in [('service-only-ssh', 'git-daemon.service'),
                       ('git-daemon', 'git-daemon.service'),
                       ('root-manager', 'user@0.service')]:
    with_ssh = name == 'service-only-ssh'
    normal_rc, normal_cycle = graph(name + '-normal', consumer, with_ssh=with_ssh)
    _, witness_cycle = graph(name + '-witness', consumer, witness=True, with_ssh=with_ssh)
    old_rc, old_cycle = graph(name + '-old', consumer, witness=True, old=True, with_ssh=with_ssh)
    metrics[name] = dict(normal_ok=normal_rc == 0 and not normal_cycle,
                         witness_refused=witness_cycle,
                         old_order_accepted=old_rc == 0 and not old_cycle)
print(json.dumps(metrics))
