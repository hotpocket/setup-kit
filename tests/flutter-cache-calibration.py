#!/usr/bin/env python3
"""Check real vendor pins. Opt in with downloaded --archive and --archives paths.

Cache filenames match flutter-cache.sh: HOST.zip, GRADLE.tgz, ENGINE_INFO.file,
and so on. This never downloads or provisions a host.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import tarfile
import zipfile


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, type=Path)
    parser.add_argument('--archives', required=True, type=Path)
    parser.add_argument('--manifest', type=Path, default=Path(__file__).resolve().parents[1] /
                        'manifests/tool-versions.conf')
    args = parser.parse_args()
    values = dict((key, shlex.split(value)[0]) for key, value in
                  (line.split('=', 1) for line in args.manifest.read_text().splitlines()
                   if line.startswith('FLUTTER_') and '=' in line))
    passed = failed = 0

    def check(name, condition):
        nonlocal passed, failed
        passed += bool(condition)
        failed += not condition
        print(('PASS ' if condition else 'FAIL ') + name, flush=True)
        return condition

    if not check('FLUTTER_RELEASE_SHA256', digest(args.archive) == values['FLUTTER_RELEASE_SHA256']):
        return 1
    members = {name: None for name in ('bin/cache/flutter.version.json',
               'bin/internal/engine.version', 'bin/internal/material_fonts.version',
               'bin/internal/gradle_wrapper.version')}
    with tarfile.open(args.archive, 'r|xz') as archive:
        for item in archive:
            name = item.name.removeprefix('flutter/')
            if name in members:
                members[name] = archive.extractfile(item).read().decode().strip()
                if all(value is not None for value in members.values()):
                    break
    metadata = json.loads(members['bin/cache/flutter.version.json'])
    for key, field in (('FLUTTER_VERSION', 'frameworkVersion'),
                       ('FLUTTER_REVISION', 'frameworkRevision'),
                       ('FLUTTER_DART_VERSION', 'dartSdkVersion')):
        check(key, values[key] == metadata[field])
    for key, name in (('FLUTTER_ENGINE_REVISION', 'engine'),
                      ('FLUTTER_FONTS_VERSION', 'material_fonts'),
                      ('FLUTTER_GRADLE_VERSION', 'gradle_wrapper')):
        check(key, values[key] == members['bin/internal/' + name + '.version'])
    rows = {key: row.split('|') for key, row in values.items() if key.startswith('FLUTTER_CACHE_')}
    check('cache manifest is populated', bool(rows))
    for key, (kind, path, dest, entry, sha) in rows.items():
        payload = args.archives / (key.removeprefix('FLUTTER_CACHE_') + '.' + kind)
        if not check(key + ' SHA256', payload.is_file() and digest(payload) == sha):
            continue
        if kind == 'zip':
            with zipfile.ZipFile(payload) as archive:
                found = any(item.filename == entry and not item.is_dir() and item.file_size > 0
                            for item in archive.infolist())
        elif kind == 'tgz':
            with tarfile.open(payload, 'r:gz') as archive:
                found = any(item.name.removeprefix('./') == entry and item.isfile() and item.size > 0
                            for item in archive)
        else:
            found = kind == 'file' and payload.stat().st_size > 0
        check(key + ' payload ' + entry, found)
        if key in ('FLUTTER_CACHE_FONTS', 'FLUTTER_CACHE_GRADLE'):
            version = 'FLUTTER_FONTS_VERSION' if key.endswith('FONTS') else 'FLUTTER_GRADLE_VERSION'
            check(key + ' revision', path == values[version])
    print(f'{passed} passed, {failed} failed')
    return 1 if failed else 0


if __name__ == '__main__':
    raise SystemExit(main())
