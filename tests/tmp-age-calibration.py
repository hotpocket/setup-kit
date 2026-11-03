#!/usr/bin/env python3
"""Real tmpfiles cleanup; private ext4 roots, kernel timestamps, no fake clock."""
import ctypes
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tarfile
import tempfile
import time

passed = failed = 0


def check(label, condition):
    global passed, failed
    if condition:
        passed += 1
        print('  ok   ' + label, flush=True)
    else:
        failed += 1
        print('  FAIL ' + label, flush=True)


def timestamps(path):
    result = ctypes.create_string_buffer(256)
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.statx(-100, bytes(path), 0, 0xfff, ctypes.byref(result)) != 0:
        raise OSError(ctypes.get_errno(), 'statx failed')
    raw = result.raw
    def ns(offset):
        sec, nano = struct.unpack_from('qI', raw, offset)
        return sec * 10**9 + nano
    return dict(btime_supported=bool(struct.unpack_from('I', raw)[0] & 0x800),
                atime_ns=ns(64), birth_ns=ns(80), ctime_ns=ns(96), mtime_ns=ns(112))


def state(phase, path, rule):
    data = dict(phase=phase, file=path.name, rule=rule, **timestamps(path))
    print('STATE ' + json.dumps(data, sort_keys=True), flush=True)
    return data


def prepare(parent, label, age):
    root = parent / label
    (root / 'tmp').mkdir(parents=True)
    conf = root / 'etc/tmpfiles.d/tmp.conf'
    conf.parent.mkdir(parents=True)
    conf.write_text('D /tmp 1777 root root ' + age + '\n')
    return root, conf


def clean(root, conf):
    result = subprocess.run(['/usr/bin/systemd-tmpfiles', '--clean', '--root=' + str(root), str(conf)],
                            capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError('private tmpfiles cleanup failed: ' + result.stderr)


def extract(archive, root):
    subprocess.run(['/usr/bin/tar', '-xf', str(archive), '-C', str(root / 'tmp')], check=True)
    return root / 'tmp/just-extracted'


def main():
    with tempfile.TemporaryDirectory(prefix='tmp-age-', dir=sys.argv[1]) as work:
        parent = Path(work)
        fs = subprocess.check_output(['findmnt', '-rn', '-o', 'FSTYPE', '--target', str(parent)], text=True).strip()
        probe = parent / 'btime-probe'
        probe.write_text('birth-time probe\n')
        born = timestamps(probe)
        version = subprocess.check_output(['/usr/bin/systemd-tmpfiles', '--version'], text=True).splitlines()[0]
        print('SCRATCH ' + json.dumps(dict(filesystem=fs, systemd=version, **born)), flush=True)
        check('scratch is ext4 and statx returns a nonzero birth time',
              fs == 'ext4' and born['btime_supported'] and born['birth_ns'] > 0)
        if failed:
            print('Choose an ext4 scratch directory with statx birth time via TMP_AGE_SCRATCH.', flush=True)
            return
        archive = parent / 'preserved-mtime.tar'
        with tarfile.open(archive, 'w') as output:
            data = b'old mtime, freshly extracted bytes\n'
            item = tarfile.TarInfo('just-extracted')
            item.size, item.mtime = len(data), int(time.time()) - 20 * 86400
            output.addfile(item, io.BytesIO(data))
        # Exact proposed/default 10-day fields. Only mtime is old here.
        for label, age, survives in [('current', 'mM:10d', False), ('proposed', 'bcmBM:10d', True)]:
            root, conf = prepare(parent, 'exact-' + label, age)
            fresh = extract(archive, root)
            ts = state('exact-10d', fresh, age)
            cutoff = time.time_ns() - 10 * 86400 * 10**9
            check(label + ' extraction really has old mtime and fresh birth/ctime',
                  ts['mtime_ns'] < cutoff < min(ts['birth_ns'], ts['ctime_ns']))
            clean(root, conf)
            check(label + ' exact 10d rule ' + ('keeps' if survives else 'deletes') + ' fresh old-mtime extraction',
                  fresh.exists() == survives)
        # Birth/ctime cannot be backdated through normal file APIs. Shorten
        # ONLY the private cleanup age to 2s; keep the exact selector strings.
        # No clock or statx interception is used. The previous pass used 10d.
        roots = []
        for label, selector in [('current', 'mM'), ('proposed', 'bcmBM')]:
            root, conf = prepare(parent, 'bounded-' + label, selector + ':2s')
            for name in ('old-untouched', 'old-read'):
                path = root / 'tmp' / name
                path.write_text('old fixture\n')
                old = time.time_ns() - 20 * 86400 * 10**9
                os.utime(path, ns=(old, old))
            directory = root / 'tmp/old-directory'
            directory.mkdir()
            old = time.time_ns() - 20 * 86400 * 10**9
            os.utime(directory, ns=(old, old))
            roots.append((label, selector, root, conf))
        time.sleep(2.25)
        for label, selector, root, conf in roots:
            age = selector + ':2s'
            cutoff = time.time_ns() - 2 * 10**9
            before = [state('aged-before-read', root / 'tmp' / name, age)
                      for name in ('old-untouched', 'old-read')]
            check(label + ' bounded fixtures have genuinely aged birth/ctime/mtime',
                  all(max(row['birth_ns'], row['ctime_ns'], row['mtime_ns']) < cutoff for row in before))
            (root / 'tmp/old-read').read_bytes()
            after = state('aged-after-read', root / 'tmp/old-read', age)
            check(label + ' real read refreshes atime while leaving old birth/ctime unchanged',
                  after['atime_ns'] > cutoff and after['birth_ns'] == before[1]['birth_ns']
                  and after['ctime_ns'] == before[1]['ctime_ns'])
            directory = root / 'tmp/old-directory'
            # Updating directory entries changes ctime. Restore only mtime,
            # leaving ctime fresh; B/M should still allow the aged dir to expire.
            child = directory / 'entry'
            child.write_text('temporary entry\n')
            child.unlink()
            old = time.time_ns() - 20 * 86400 * 10**9
            os.utime(directory, ns=(old, old))
            dts = state('directory-fresh-ctime', directory, age)
            check(label + ' directory has old birth/mtime and fresh ctime',
                  max(dts['birth_ns'], dts['mtime_ns']) < cutoff < dts['ctime_ns'])
            fresh = extract(archive, root)
            state('fresh-before-clean', fresh, age)
            clean(root, conf)
            check(label + ' bounded rule ' + ('keeps' if label == 'proposed' else 'deletes') + ' fresh extraction',
                  fresh.exists() == (label == 'proposed'))
            check(label + ' bounded rule ignores directory ctime', not directory.exists())
            check(label + ' bounded rule deletes an old untouched file', not (root / 'tmp/old-untouched').exists())
            check(label + ' bounded rule deletes an old file despite a fresh read', not (root / 'tmp/old-read').exists())


if __name__ == '__main__':
    main()
    print(f'tmp-age-calibration: {passed} passed, {failed} failed')
    sys.exit(bool(failed))
