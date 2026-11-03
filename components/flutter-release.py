#!/usr/bin/env python3
"""Receipt for bootstrap bytes shipped by the verified Flutter release archive."""
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
from urllib.parse import quote, unquote, urlsplit


def files(root):
    paths = [root / name for name in (
        'bin/flutter', 'bin/dart', 'bin/cache/flutter_tools.snapshot',
        'bin/cache/flutter_tools.stamp', 'bin/cache/engine-dart-sdk.stamp',
        'packages/flutter_tools/pubspec.yaml', 'packages/flutter_tools/pubspec.lock',
        'packages/flutter_tools/.dart_tool/package_config.json')]
    for directory in ('bin/internal', 'bin/cache/dart-sdk', '.setup-kit-pub-cache', '.pub-preload-cache'):
        paths.extend(p for p in (root / directory).rglob('*') if p.is_file())
    return {p.relative_to(root).as_posix(): {
        'sha256': digest(p), 'executable': os.access(p, os.X_OK)} for p in paths}


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def prepare(root):
    """Use only packages inside the hash-checked archive, without a registry."""
    cache = root / '.setup-kit-pub-cache'
    archives = sorted((root / '.pub-preload-cache').glob('*.tar.gz'))
    if not archives:
        raise ValueError('release has no vendored Pub archives')
    env = dict(os.environ, PUB_CACHE=str(cache), PUB_HOSTED_URL='https://pub.dev',
               FLUTTER_ROOT=str(root), CI='true')
    dart = str(root / 'bin/cache/dart-sdk/bin/dart')
    subprocess.run([dart, 'pub', 'cache', 'preload', *map(str, archives)], env=env, check=True)
    tools = root / 'packages/flutter_tools'
    subprocess.run([dart, 'pub', 'get', '--offline', '--enforce-lockfile'],
                   env=env, cwd=tools, check=True)
    path = tools / '.dart_tool/package_config.json'
    config = json.loads(path.read_text())
    # Pub writes absolute stage paths. Use relative URIs so the whole prepared
    # tree can be published by rename and moved without another Pub operation.
    for package in config['packages']:
        uri = urlsplit(package['rootUri'])
        directory = Path(unquote(uri.path))
        if not directory.is_absolute():
            directory = path.parent / directory
        directory = directory.resolve()
        if uri.scheme not in ('', 'file') or uri.netloc or not directory.is_relative_to(root):
            raise ValueError('package root escapes verified release')
        package['rootUri'] = quote(os.path.relpath(directory, path.parent), safe='/')
    for name, directory in (('pubCache', cache), ('flutterRoot', root)):
        if name in config:
            config[name] = quote(os.path.relpath(directory, path.parent), safe='/')
    path.write_text(json.dumps(config, sort_keys=True) + '\n')
    # Flutter otherwise imports these into the caller's default Pub cache and
    # deletes them on a later pub command. The prepared private cache owns them.
    shutil.rmtree(root / '.pub-preload-cache')


def packages_ready(root):
    path = root / 'packages/flutter_tools/.dart_tool/package_config.json'
    config = json.loads(path.read_text())
    if config['configVersion'] != 2 or not config['packages']:
        return False
    for package in config['packages']:
        uri = urlsplit(package['rootUri'])
        directory = (path.parent / unquote(uri.path)).resolve()
        if (uri.scheme or uri.netloc or uri.path.startswith('/') or
                not directory.is_relative_to(root) or not (directory / 'pubspec.yaml').is_file()):
            return False
    return True


def main():
    action, kit, directory = sys.argv[1:]
    root = Path(directory).resolve()
    receipt_path = root / '.setup-kit-release.json'
    if action == 'prepare':
        prepare(root)
        return 0 if packages_ready(root) else 1
    if action == 'managed':
        receipt = json.loads(receipt_path.read_text())
        return 0 if (receipt.get('schema') == 1 and receipt.get('files') and
                     re.fullmatch('[a-f0-9]{64}', receipt['pins']['FLUTTER_RELEASE_SHA256'])) else 1
    keys = ('FLUTTER_VERSION', 'FLUTTER_REVISION', 'FLUTTER_DART_VERSION',
            'FLUTTER_ENGINE_REVISION', 'FLUTTER_RELEASE_URL', 'FLUTTER_RELEASE_SHA256')
    pins = {}
    for line in (Path(kit) / 'manifests/tool-versions.conf').read_text().splitlines():
        if '=' in line:
            key, value = line.split('=', 1)
            if key in keys:
                pins[key] = shlex.split(value)[0]
    cache = root / 'bin/cache'
    if (not packages_ready(root) or
            (cache / 'flutter_tools.stamp').read_text().strip() != pins['FLUTTER_REVISION'] + ':' or
            (cache / 'engine-dart-sdk.stamp').read_text().strip() != pins['FLUTTER_ENGINE_REVISION'] or
            not (cache / 'flutter_tools.snapshot').stat().st_size or
            not (cache / 'dart-sdk/bin/dart').stat().st_size or
            not os.access(cache / 'dart-sdk/bin/dart', os.X_OK) or
            (root / 'packages/flutter_tools/pubspec.yaml').stat().st_mtime_ns >
            (root / 'packages/flutter_tools/pubspec.lock').stat().st_mtime_ns):
        return 1
    actual = {'schema': 1, 'pins': pins, 'files': files(root)}
    if action == 'seal':
        receipt_path.write_text(json.dumps(actual, sort_keys=True) + '\n')
    return 0 if json.loads(receipt_path.read_text()) == actual else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, KeyError, TypeError, subprocess.CalledProcessError):
        sys.exit(1)
