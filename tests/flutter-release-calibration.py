#!/usr/bin/env python3
"""Real first launch, private HOME and network namespace; no host provisioning."""
import argparse
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import threading
import time


KIT = Path(__file__).resolve().parents[1]


def pins():
    return dict(line.split('=', 1) for line in
                (KIT / 'manifests/tool-versions.conf').read_text().splitlines()
                if line and not line.startswith('#') and '=' in line)


def run(command, env, log, timeout=30):
    with log.open('w') as stream:
        process = subprocess.Popen(command, env=env, stdin=subprocess.DEVNULL,
                                   stdout=stream, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            return 124


def registry_control(clone, env, work):
    # Same harmless fabricated packages as the release review's registry repro.
    versions = dict(re.findall(r'^  ([a-z_][a-z_0-9]*): ([0-9][^\s]*)$',
                    (clone / 'packages/flutter_tools/pubspec.yaml').read_text(), re.M))
    archives, requests = {}, []
    for name, version in versions.items():
        spec = dict(name=name, version=version, environment={'sdk': '>=3.0.0 <4.0.0'})
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w:gz') as archive:
            for file, data in [('pubspec.yaml', json.dumps(spec)),
                               ('lib/' + name + '.dart', 'const calibration = true;\n')]:
                data = data.encode()
                item = tarfile.TarInfo(file)
                item.size = len(data)
                archive.addfile(item, io.BytesIO(data))
        archives[name] = buf.getvalue(), spec

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            requests.append(self.path)
            if self.path.startswith('/api/packages/'):
                name = self.path.split('/')[-1]
                if name not in archives:
                    self.send_error(404)
                    return
                data, spec = archives[name]
                version = dict(version=versions[name], pubspec=spec,
                               archive_url=base + '/archives/' + name + '.tar.gz',
                               archive_sha256=hashlib.sha256(data).hexdigest(),
                               published='2026-11-03T00:00:00Z')
                body = json.dumps(dict(name=name, latest=version, versions=[version])).encode()
            elif self.path.startswith('/archives/'):
                name = self.path.split('/')[-1].removesuffix('.tar.gz')
                if name not in archives:
                    self.send_error(404)
                    return
                body = archives[name][0]
            else:
                self.send_error(404)
                return
            self.send_response(200)
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    base = 'http://127.0.0.1:' + str(server.server_port)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    env = dict(env, PUB_HOSTED_URL=base, PUB_CACHE=str(work / 'registry-pub'))
    with (work / 'registry.log').open('w') as log:
        process = subprocess.Popen([str(clone / 'bin/flutter'), 'precache', '--android'],
                                   env=env, stdin=subprocess.DEVNULL, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        found = []
        try:
            deadline = time.monotonic() + 30
            while time.monotonic() < deadline:
                found = list(Path(env['PUB_CACHE']).glob('hosted/*/*/lib/*.dart'))
                if found or process.poll() is not None:
                    break
                time.sleep(.1)
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            server.shutdown()
            server.server_close()
    (work / 'registry-requests.json').write_text(json.dumps(requests, indent=2) + '\n')
    return dict(metadata_requests=sum(x.startswith('/api/packages/') for x in requests),
                archive_requests=sum(x.startswith('/archives/') for x in requests),
                extracted_sources=len(found))


def inside(args):
    work, config = Path(args.output), pins()
    checks = {}

    def check(name, condition):
        checks[name] = bool(condition)
        print(('PASS ' if condition else 'FAIL ') + name, flush=True)

    with open(args.archive, 'rb') as stream:
        digest = hashlib.file_digest(stream, 'sha256').hexdigest()
    check('official archive SHA256 matches committed pin', digest == config['FLUTTER_RELEASE_SHA256'])
    if not all(checks.values()):
        return 1
    home = work / 'release-home'
    home.mkdir()
    prepare_env = dict(HOME=str(home), PATH='/usr/bin:/bin', LANG='C.UTF-8', CI='true')
    stage = work / 'stage'
    stage.mkdir()
    release = stage / 'flutter'
    subprocess.run(['tar', '--no-same-owner', '-xJf', args.archive, '-C', str(stage)], check=True)
    with (work / 'prepare.log').open('w') as log:
        subprocess.run(['python3', '-I', str(KIT / 'components/flutter-release.py'),
                        'prepare', str(KIT), str(release)], env=prepare_env,
                       stdout=log, stderr=subprocess.STDOUT, check=True)
    subprocess.run(['python3', '-I', str(KIT / 'components/flutter-release.py'),
                    'seal', str(KIT), str(release)], check=True)
    release.rename(work / 'flutter')
    release = work / 'flutter'
    cache = release / 'bin/cache'
    # Only copy the separately pinned engine payloads and their receipt. Dart and
    # flutter_tools must come from the archive under test, never the host cache.
    subprocess.run(['python3', '-I', str(KIT / 'components/flutter-cache.py'),
                    'check', str(KIT), args.engine_cache], check=True)
    source = Path(args.engine_cache)
    for name in ('artifacts', 'pkg'):
        shutil.rmtree(cache / name, ignore_errors=True)
        shutil.copytree(source / name, cache / name, symlinks=True)
    for path in source.iterdir():
        if path.is_file():
            shutil.copy2(path, cache / path.name)
    env = dict(HOME=str(home), PATH='/usr/bin:/bin', LANG='C.UTF-8', CI='true',
               PUB_CACHE=str(release / '.setup-kit-pub-cache'), PUB_HOSTED_URL='setup-kit-verified://offline',
               FLUTTER_STORAGE_BASE_URL='setup-kit-verified://offline',
               FLUTTER_PREBUILT_ENGINE_VERSION=config['FLUTTER_ENGINE_REVISION'],
               FLUTTER_TOOL_ARGS='', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
    for label, command in [('version', ['--version']), ('precache', ['precache', '--android'])]:
        rc = run([str(release / 'bin/flutter'), *command], env, work / (label + '.log'))
        check('release ' + label + ' succeeds without networking', rc == 0)
    check('release never bootstraps Pub or uses a user Pub cache',
          not (home / '.pub-cache').exists() and not (release / '.pub-preload-cache').exists() and
          all('Building flutter tool' not in (work / (name + '.log')).read_text()
              for name in ('version', 'precache')))
    check('release bootstrap receipt remains valid', subprocess.run(
        ['python3', '-I', str(KIT / 'components/flutter-release.py'), 'check', str(KIT), str(release)],
        env=env).returncode == 0)
    check('pinned engine cache receipt remains valid', subprocess.run(
        ['python3', '-I', str(KIT / 'components/flutter-cache.py'), 'check', str(KIT), str(cache)],
        env=env).returncode == 0)
    clone = work / 'old-clone'
    subprocess.run(['git', 'clone', '--quiet', '--shared', '--no-checkout', str(release), str(clone)],
                   env=env, check=True)
    subprocess.run(['git', '-C', str(clone), 'checkout', '--quiet', '--detach',
                    config['FLUTTER_REVISION']], env=env, check=True)
    old_cache = clone / 'bin/cache'
    old_cache.mkdir(parents=True)
    (old_cache / 'dart-sdk').symlink_to(cache / 'dart-sdk', target_is_directory=True)
    for path in cache.iterdir():
        if path.name not in ('dart-sdk', 'flutter_tools.snapshot', 'flutter_tools.stamp'):
            if path.is_dir():
                (old_cache / path.name).symlink_to(path, target_is_directory=True)
            elif path.is_file():
                shutil.copy2(path, old_cache / path.name)
    old_home = work / 'clone-home'
    old_home.mkdir()
    old_env = dict(env, HOME=str(old_home), PUB_CACHE=str(old_home / 'pub'))
    rc = run([str(clone / 'bin/flutter'), '--version'], old_env, work / 'old-offline.log', timeout=8)
    check('old Git clone fails offline first launch at Pub bootstrap',
          rc != 0 and 'Building flutter tool' in (work / 'old-offline.log').read_text() and
          not (old_cache / 'flutter_tools.snapshot').exists())
    registry = registry_control(clone, old_env, work)
    check('loopback registry proves old bootstrap fetches and extracts unpinned code',
          registry['archive_requests'] > 0 and registry['extracted_sources'] > 0)
    result = dict(checks=checks, passed=sum(checks.values()), failed=sum(not x for x in checks.values()),
                  archive_sha256=digest, registry=registry, network='bubblewrap --unshare-net')
    (work / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result), flush=True)
    return 0 if all(checks.values()) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--archive', required=True, help='official Linux stable tar.xz')
    parser.add_argument('--engine-cache', required=True, help='r3 verified bin/cache directory')
    parser.add_argument('--output', required=True, help='parent for disposable calibration data')
    parser.add_argument('--inside', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.inside:
        return inside(args)
    parent = Path(args.output).resolve()
    parent.mkdir(parents=True, exist_ok=True)
    work = Path(tempfile.mkdtemp(prefix='first-launch-', dir=parent))
    command = ['bwrap', '--die-with-parent', '--ro-bind', '/', '/', '--unshare-net',
               '--unshare-pid', '--dev', '/dev', '--proc', '/proc', '--tmpfs', '/tmp',
               '--ro-bind', str(KIT), str(KIT),
               '--ro-bind', str(Path(args.archive).resolve()), str(Path(args.archive).resolve()),
               '--ro-bind', str(Path(args.engine_cache).resolve()), str(Path(args.engine_cache).resolve()),
               '--bind', str(work), str(work), 'python3', '-I', str(Path(__file__).resolve()),
               '--inside', '--archive', str(Path(args.archive).resolve()),
               '--engine-cache', str(Path(args.engine_cache).resolve()), '--output', str(work)]
    print('COMMAND ' + shlex.join(command), flush=True)
    return subprocess.run(command, stdin=subprocess.DEVNULL).returncode


if __name__ == '__main__':
    sys.exit(main())
