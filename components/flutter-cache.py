#!/usr/bin/env python3
"""Seal verified staged cache bytes, or check them without invoking Flutter."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import sys


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def pins(kit):
    result = {}
    for line in (kit / 'manifests/tool-versions.conf').read_text().splitlines():
        if line.startswith('FLUTTER_') and '=' in line:
            key, value = line.split('=', 1)
            result[key] = shlex.split(value)[0]
    return result


def stamps(values):
    engine = values['FLUTTER_ENGINE_REVISION']
    return {**{name + '.stamp': engine for name in
               ('android-sdk', 'android-internal-build-artifacts', 'flutter_sdk', 'font-subset', 'engine_stamp')},
            'material_fonts.stamp': values['FLUTTER_FONTS_VERSION'],
            'gradle_wrapper.stamp': values['FLUTTER_GRADLE_VERSION']}


def valid(cache, values):
    receipt = json.loads((cache / 'setup-kit-cache.json').read_text())
    if receipt['pins'] != values or not receipt['files']:
        return False
    for key, row in values.items():
        if key.startswith('FLUTTER_CACHE_'):
            _, _, dest, entry, _ = row.split('|')
            if (Path(dest) / entry).as_posix().removeprefix('./') not in receipt['files']:
                return False
    for name, expected in stamps(values).items():
        if (cache / name).read_text().strip() != expected:
            return False
    for name, data in receipt['files'].items():
        path = cache / name
        if not path.is_file() or digest(path) != data['sha256'] or (data['executable'] and not os.access(path, os.X_OK)):
            return False
    return True


def main():
    action, kit, directory = sys.argv[1:]
    cache = Path(directory)
    values = pins(Path(kit))
    if action == 'seal':
        for name, value in stamps(values).items():
            (cache / name).write_text(value + '\n')
        files = {path.relative_to(cache).as_posix(): {'sha256': digest(path), 'executable': os.access(path, os.X_OK)}
                 for path in cache.rglob('*') if path.is_file()}
        (cache / 'setup-kit-cache.json').write_text(json.dumps({'pins': values, 'files': files}, sort_keys=True) + '\n')
    return 0 if valid(cache, values) else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError):
        sys.exit(1)
